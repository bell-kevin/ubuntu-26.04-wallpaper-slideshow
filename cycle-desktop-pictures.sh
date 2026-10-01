#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Cycle the desktop picture through every wallpaper that comes with
# Ubuntu 26.04 LTS, changing it every 5 minutes (or every MINUTES minutes).
#
# This uses GNOME's own slideshow feature: it writes a slideshow file listing
# all the pictures and makes that your background. GNOME saves the choice, so
# the slideshow carries on every time you log in, unless you have paused it.
#
# To see a particular picture, pick it in Settings > Appearance as usual. It
# shows right away and the slideshow carries on from it: a small helper, which
# systemd starts when you log in, notices the change and starts a new
# slideshow with your picture first.
# Use --pause to keep the current picture until you explicitly --resume.
#
# Usage: ./cycle-desktop-pictures.sh [MINUTES]   start, or change the interval
#        ./cycle-desktop-pictures.sh --pause [PICTURE]
#                                              keep a picture until resumed
#        ./cycle-desktop-pictures.sh --resume    resume the paused rotation
#        ./cycle-desktop-pictures.sh --set-duration MINUTES [PICTURE]
#                                              remember one picture's duration
#        ./cycle-desktop-pictures.sh --reset-duration [PICTURE]
#                                              restore its normal duration
#        ./cycle-desktop-pictures.sh --stop      keep the current picture, stop
#                                                cycling and remove the helper
#
# PICTURE defaults to the picture on screen; otherwise give an image file path.
# Run it again to reshuffle or change the interval; a paused rotation stays paused.

set -euo pipefail

wallpaper_dir=/usr/share/backgrounds
slideshow_dir=$HOME/.local/share/wallpaper-slideshow
helper=$slideshow_dir/cycle-desktop-pictures.sh
interval_file=$slideshow_dir/interval
durations_dir=$slideshow_dir/durations
pause_file=$slideshow_dir/paused
unit=wallpaper-slideshow.service
unit_file=$HOME/.config/systemd/user/$unit
# Earlier versions listed the slideshow in Settings > Appearance, to switch
# back to it. Picking a picture no longer stops it, so that entry is removed.
old_settings_entry=$HOME/.local/share/gnome-background-properties/all-ubuntu-wallpapers.xml
fade=5  # seconds of crossfade between pictures, as in Ubuntu's own slideshow

usage() {
    echo "Usage: $0 [MINUTES]   (whole minutes per picture, default 5)" >&2
    echo "       $0 --pause [PICTURE]   (keep this picture until you resume)" >&2
    echo "       $0 --resume           (or --unpause; resume the rotation)" >&2
    echo "       $0 --set-duration MINUTES [PICTURE]" >&2
    echo "                     (remember this picture's duration; default: current picture)" >&2
    echo "       $0 --reset-duration [PICTURE]   (restore its normal duration)" >&2
    echo "       $0 --stop      (keep the current picture and stop cycling)" >&2
    echo "MINUTES must be a positive whole number, at most 999999999." >&2
    exit 2
}

valid_minutes() {
    # Bound input before doing arithmetic, including values read from disk.
    [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]
}

action=start
minutes=5
picture_arg=
custom_minutes=
case ${1-} in
    --pause)
        (( $# == 1 || $# == 2 )) || usage
        action=pause
        picture_arg=${2-}
        (( $# != 2 )) || [[ $picture_arg ]] || usage
        ;;
    --resume | --unpause)
        (( $# == 1 )) || usage
        action=resume
        ;;
    --stop)
        (( $# == 1 )) || usage
        action=stop
        ;;
    --set-duration)
        (( $# == 2 || $# == 3 )) || usage
        action=set-duration
        custom_minutes=$2
        valid_minutes "$custom_minutes" || usage
        picture_arg=${3-}
        (( $# != 3 )) || [[ $picture_arg ]] || usage
        ;;
    --reset-duration)
        (( $# == 1 || $# == 2 )) || usage
        action=reset-duration
        picture_arg=${2-}
        (( $# != 2 )) || [[ $picture_arg ]] || usage
        ;;
    --watch)
        (( $# == 2 )) || usage
        action=watch
        minutes=$2
        valid_minutes "$minutes" || usage
        ;;
    *)
        (( $# <= 1 )) || usage
        minutes=${1-5}
        valid_minutes "$minutes" || usage
        ;;
esac
if (( EUID == 0 )); then
    echo "Run this as yourself, without sudo: it sets your own background." >&2
    exit 1
fi

# Terminals inside snap apps (VS Code, for one) point gsettings at the snap's
# own outdated list of settings, which lacks picture-uri-dark. Use the system's.
unset GSETTINGS_SCHEMA_DIR GIO_MODULE_DIR
export XDG_DATA_DIRS=/usr/local/share:/usr/share

xml_escape() {
    local s=$1
    s=${s//'&'/'&amp;'}
    s=${s//'<'/'&lt;'}
    s=${s//'>'/'&gt;'}
    printf '%s' "$s"
}

xml_unescape() {
    local s=$1
    s=${s//'&lt;'/'<'}
    s=${s//'&gt;'/'>'}
    s=${s//'&amp;'/'&'}
    printf '%s' "$s"
}

# GNOME's settings hold file:// URIs, while slideshow files list paths.
uri_of() {
    gio info -a standard::name -- "$1" | sed -n 's/^uri: //p'
}

# The file a background setting points to. Fails if it isn't a local file
# that exists.
background_file() {
    local uri path
    uri=$(gsettings get org.gnome.desktop.background "$1")
    uri=${uri:1:-1}  # without the quotes gsettings adds
    path=$(gio info -a standard::name -- "$uri" 2>/dev/null | sed -n 's/^local path: //p')
    [[ -f $path ]] && printf '%s\n' "$path"
}

# The background setting that's on screen: GNOME uses picture-uri in light
# style and picture-uri-dark in dark style.
shown_key() {
    if [[ $(gsettings get org.gnome.desktop.interface color-scheme) == "'prefer-dark'" ]]; then
        echo picture-uri-dark
    else
        echo picture-uri
    fi
}

# Give each canonical image path its own preference, including paths with spaces.
duration_file() {
    local hash
    hash=$(printf '%s' "$1" | sha256sum)
    printf '%s/%s\n' "$durations_dir" "${hash%% *}"
}

minutes_for_picture() {
    local file value
    file=$(duration_file "$1")
    if [[ -f $file ]]; then
        value=$(cat -- "$file")
        if ! valid_minutes "$value"; then
            echo "Invalid saved duration in $file" >&2
            return 1
        fi
        printf '%s\n' "$value"
    else
        printf '%s\n' "$minutes"
    fi
}

# Keep the existing normal interval when pausing, resuming or changing one picture. Older
# installations saved it only in the helper's service command.
load_interval() {
    local saved=5
    if [[ -f $interval_file ]]; then
        saved=$(cat -- "$interval_file")
    elif [[ -f $unit_file ]]; then
        saved=$(sed -n 's/^ExecStart=.* --watch \([0-9][0-9]*\)$/\1/p' "$unit_file")
        saved=${saved:-5}
    fi
    if ! valid_minutes "$saved"; then
        echo "Invalid saved interval. Run $0 MINUTES to choose it again." >&2
        return 1
    fi
    minutes=$saved
}

# Write a slideshow that starts now and make it the background. It has every
# picture in the wallpaper folder in random order, after the picture given
# as $1, if any.
start_slideshow() {
    local first=${1-} pictures i now slideshow current next uri picture_minutes lock
    mkdir -p "$slideshow_dir"
    # The helper and a terminal command can both rebuild the slideshow.
    exec {lock}> "$slideshow_dir/.lock"
    flock "$lock"
    # Also check under the lock, in case a pick was queued just before pausing.
    if [[ -f $pause_file && $action != resume ]]; then
        exec {lock}>&-
        return
    fi
    # Symlinks are resolved so a picture that has two names is only shown once.
    mapfile -t pictures < <(
        find -L "$wallpaper_dir" -maxdepth 1 -type f \
            -regextype posix-extended -iregex '.*\.(png|jpe?g|webp|jxl)' \
            -exec realpath {} + | sort -u | shuf
    )
    if [[ $first ]]; then
        first=$(realpath -- "$first")
        for i in "${!pictures[@]}"; do
            [[ ${pictures[i]} != "$first" ]] || unset 'pictures[i]'
        done
        pictures=("$first" "${pictures[@]}")
    fi
    count=${#pictures[@]}
    if (( count == 0 )); then
        echo "No pictures found in $wallpaper_dir" >&2
        exit 1
    fi

    now=$(date +%s)
    slideshow=$(mktemp "$slideshow_dir/slideshow-$now-XXXXXXXX.xml")
    {
        echo '<background>'
        date -d "@$now" '+  <starttime><year>%Y</year><month>%m</month><day>%d</day><hour>%H</hour><minute>%M</minute><second>%S</second></starttime>'
        for (( i = 0; i < count; i++ )); do
            current=$(xml_escape "${pictures[i]}")
            next=$(xml_escape "${pictures[(i + 1) % count]}")
            picture_minutes=$(minutes_for_picture "${pictures[i]}")
            echo "  <static><duration>$(( picture_minutes * 60 - fade ))</duration><file>$current</file></static>"
            echo "  <transition><duration>$fade</duration><from>$current</from><to>$next</to></transition>"
        done
        echo '</background>'
    } > "$slideshow"

    uri=$(uri_of "$slideshow")
    gsettings set org.gnome.desktop.background picture-options zoom
    gsettings set org.gnome.desktop.background picture-uri "$uri"
    gsettings set org.gnome.desktop.background picture-uri-dark "$uri"

    # GNOME remembers a slideshow by its file name, so each new slideshow gets
    # a new file (otherwise changes would wait until the next login). Remove old ones.
    find "$slideshow_dir" -maxdepth 1 -name 'slideshow-*.xml' ! -samefile "$slideshow" -delete
    exec {lock}>&-
}

# The picture that a slideshow made by start_slideshow is showing right now.
picture_showing() {
    local slideshow=$1 start elapsed total=0 i duration pictures durations
    start=${slideshow##*/slideshow-}  # accepts the older slideshow-EPOCH.xml too
    start=${start%%-*}
    start=${start%.xml}
    mapfile -t pictures < <(sed -n 's:.*<static>.*<file>\(.*\)</file>.*:\1:p' "$slideshow")
    mapfile -t durations < <(sed -n 's:.*<static><duration>\([0-9]*\)</duration>.*:\1:p' "$slideshow")
    [[ $start =~ ^[0-9]+$ && ${#pictures[@]} -gt 0 && ${#pictures[@]} == ${#durations[@]} ]] || return 1
    for duration in "${durations[@]}"; do
        total=$(( total + duration + fade ))
    done
    elapsed=$(( $(date +%s) - start ))
    # If the clock moved backwards, keep the first picture until the start.
    (( elapsed >= 0 )) || elapsed=0
    elapsed=$(( elapsed % total ))
    for i in "${!pictures[@]}"; do
        duration=$(( durations[i] + fade ))
        if (( elapsed < duration )); then
            # During a crossfade, keep the outgoing picture as before.
            xml_unescape "${pictures[i]}"
            return
        fi
        elapsed=$(( elapsed - duration ))
    done
}

selected_picture() {
    local path=$picture_arg
    if [[ ! $path ]]; then
        path=$(background_file "$(shown_key)") || {
            echo "Pick a picture in Settings > Appearance first, or give its file path." >&2
            return 1
        }
        if [[ $path == "$slideshow_dir"/slideshow-*.xml ]]; then
            path=$(picture_showing "$path") || return 1
        fi
    fi
    if [[ ! -f $path || ! ${path,,} =~ \.(png|jpe?g|webp|jxl)$ ]]; then
        echo "Choose an existing image file (PNG, JPEG, WebP or JXL): $path" >&2
        return 1
    fi
    realpath -- "$path"
}

# Resolve the current picture after the helper exits, so it cannot replace
# and delete the XML while we are reading it. Restore it if selection fails.
select_without_helper() {
    local picture helper_running=false
    if [[ -e $unit_file ]] && systemctl --user is-active --quiet "$unit"; then
        helper_running=true
    fi
    stop_helper || return
    if ! picture=$(selected_picture); then
        if "$helper_running"; then
            systemctl --user start "$unit"
        fi
        return 1
    fi
    printf '%s\n' "$picture"
}

pause_slideshow() {
    local picture uri lock
    load_interval
    picture=$(select_without_helper)
    uri=$(uri_of "$picture")
    mkdir -p "$slideshow_dir"
    exec {lock}> "$slideshow_dir/.lock"
    flock "$lock"
    # A persistent flag makes both the running helper and future logins leave
    # static pictures alone. Keep the interval and per-picture preferences.
    touch "$pause_file"
    gsettings set org.gnome.desktop.background picture-uri "$uri"
    gsettings set org.gnome.desktop.background picture-uri-dark "$uri"
    exec {lock}>&-
    install_helper
    rm -f "$old_settings_entry"
    echo "Paused: ${picture##*/} stays until you run: $0 --resume"
    echo "Picking another picture keeps the rotation paused, including after login or restart."
}

resume_slideshow() {
    local picture
    if [[ ! -f $pause_file ]]; then
        echo "The slideshow is not paused. To start it or change the interval, run: $0 MINUTES"
        return
    fi
    load_interval
    picture=$(select_without_helper)
    start_slideshow "$picture"
    # Clear the flag only after a new slideshow has been successfully applied.
    rm -f "$pause_file"
    install_helper
    rm -f "$old_settings_entry"
    echo "Resumed: starting a fresh interval with ${picture##*/}, using your saved durations."
}

change_duration() {
    local picture file
    load_interval
    picture=$(select_without_helper)
    file=$(duration_file "$picture")
    if [[ $action == set-duration ]]; then
        mkdir -p "$durations_dir"
        # Rename a complete preference so the helper never reads half a write.
        local temporary
        temporary=$(mktemp "$durations_dir/.duration-XXXXXXXX")
        printf '%s\n' "$custom_minutes" > "$temporary"
        mv -- "$temporary" "$file"
    else
        rm -f -- "$file"
    fi
    if [[ ! -f $pause_file ]]; then
        start_slideshow "$picture"
    fi
    install_helper
    rm -f "$old_settings_entry"
    if [[ $action == set-duration ]]; then
        echo "Saved: ${picture##*/} stays for $custom_minutes minutes on every rotation."
    else
        echo "Reset: ${picture##*/} uses the normal interval of $minutes minutes."
    fi
    if [[ -f $pause_file ]]; then
        echo "The rotation stays paused. Use $0 --resume when you're ready."
    else
        echo "Starting a fresh interval for this picture now."
    fi
    echo "Other pictures keep their existing durations. The last $fade seconds are the crossfade."
}

# If a picture was picked (in Settings, say), start a new slideshow with it.
follow_pick() {
    local key path
    [[ ! -f $pause_file ]] || return 0
    # The setting that's on screen comes first; then both, since some apps
    # only set picture-uri.
    for key in "$(shown_key)" picture-uri picture-uri-dark; do
        path=$(background_file "$key") || continue
        case $path in
            "$slideshow_dir"/*) ;;                 # our own slideshow
            *.xml) return ;;                       # another slideshow: leave it
            *) start_slideshow "$path"; return ;;
        esac
    done
}

# The helper, which systemd runs as "--watch MINUTES" while you're logged in.
watch_for_picks() {
    follow_pick  # in case a picture was picked while this wasn't running
    gsettings monitor org.gnome.desktop.background | while read -r _; do
        # Settings changes several keys one after another. Let them all land.
        while read -r -t 1 _; do :; done
        follow_pick
    done
}

stop_helper() {
    # Finish any pending pick before a terminal command changes the slideshow
    # or replaces the helper's script. install_helper starts it again.
    if [[ -e $unit_file ]]; then
        systemctl --user stop "$unit"
    fi
}

install_helper() {
    local script
    script=$(realpath -- "${BASH_SOURCE[0]}")
    # The helper runs its own copy, so you can delete the one you downloaded.
    [[ $script -ef $helper ]] || install -D -m 755 -- "$script" "$helper"
    printf '%s\n' "$minutes" > "$interval_file"
    mkdir -p "${unit_file%/*}"
    cat > "$unit_file" <<EOF
[Unit]
Description=Keep the wallpaper slideshow going after you pick a picture
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=%h/.local/share/wallpaper-slideshow/cycle-desktop-pictures.sh --watch $minutes
Restart=always

[Install]
WantedBy=graphical-session.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --quiet "$unit"
    systemctl --user restart "$unit"
}

# Stop on the picture that's showing, and remove the helper and the files
# this script made.
stop_slideshow() {
    local slideshow picture uri
    # The helper goes first, or it would take the new picture as a pick.
    if [[ -e $unit_file ]]; then
        systemctl --user disable --now --quiet "$unit"
        rm "$unit_file"
        systemctl --user daemon-reload
    fi
    if slideshow=$(background_file "$(shown_key)") &&
        [[ $slideshow == "$slideshow_dir"/slideshow-*.xml ]]; then
        picture=$(picture_showing "$slideshow")
        if [[ -f $picture ]]; then
            uri=$(uri_of "$picture")
            gsettings set org.gnome.desktop.background picture-uri "$uri"
            gsettings set org.gnome.desktop.background picture-uri-dark "$uri"
        fi
    fi
    rm -rf "$slideshow_dir" "$old_settings_entry"
}

case $action in
    watch)
        watch_for_picks
        ;;
    stop)
        stop_slideshow
        echo "Stopped: the current picture stays. Run the script again to restart the slideshow."
        ;;
    pause)
        pause_slideshow
        ;;
    resume)
        resume_slideshow
        ;;
    set-duration | reset-duration)
        change_duration
        ;;
    start)
        stop_helper
        if [[ ! -f $pause_file ]]; then
            start_slideshow
        fi
        install_helper
        rm -f "$old_settings_entry"
        if [[ -f $pause_file ]]; then
            echo "Saved: normal interval is $minutes minutes. The rotation stays paused."
            echo "To resume, run: $0 --resume"
            exit 0
        fi
        echo "Done: your background now cycles through $count pictures, $minutes minutes each unless a custom duration is saved."
        echo "Pick a picture in Settings > Appearance at any time, and the slideshow carries on from it."
        echo "To keep the current picture until you're ready to move on, run: $0 --pause"
        echo "To keep that picture longer each time, run: $0 --set-duration MINUTES"
        ;;
esac
