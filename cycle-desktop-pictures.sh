#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Cycle the desktop picture through every wallpaper that comes with
# Ubuntu 26.04 LTS, changing it every 5 minutes (or every MINUTES minutes).
#
# This uses GNOME's own slideshow feature: it writes a slideshow file listing
# all the pictures and makes that your background. GNOME saves the choice, so
# the slideshow resumes every time you log in.
#
# To see a particular picture, pick it in Settings > Appearance as usual. It
# shows right away and the slideshow carries on from it: a small helper, which
# systemd starts when you log in, notices the change and starts a new
# slideshow with your picture first.
#
# Usage: ./cycle-desktop-pictures.sh [MINUTES]   start, or change the interval
#        ./cycle-desktop-pictures.sh --stop      keep the current picture, stop
#                                                cycling and remove the helper
#
# Run it again at any time to reshuffle the order or change the interval.

set -euo pipefail

wallpaper_dir=/usr/share/backgrounds
slideshow_dir=$HOME/.local/share/wallpaper-slideshow
helper=$slideshow_dir/cycle-desktop-pictures.sh
unit=wallpaper-slideshow.service
unit_file=$HOME/.config/systemd/user/$unit
# Earlier versions listed the slideshow in Settings > Appearance, to switch
# back to it. Picking a picture no longer stops it, so that entry is removed.
old_settings_entry=$HOME/.local/share/gnome-background-properties/all-ubuntu-wallpapers.xml
fade=5  # seconds of crossfade between pictures, as in Ubuntu's own slideshow

usage() {
    echo "Usage: $0 [MINUTES]   (whole minutes per picture, default 5)" >&2
    echo "       $0 --stop      (keep the current picture and stop cycling)" >&2
    exit 2
}

action=start
case ${1-} in
    --stop | --watch) action=${1#--}; shift ;;
esac
minutes=${1:-5}
[[ $minutes =~ ^[1-9][0-9]*$ ]] || usage
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

# Write a slideshow that starts now and make it the background. It has every
# picture in the wallpaper folder in random order, after the picture given
# as $1, if any.
start_slideshow() {
    local first=${1-} pictures i now slideshow current next uri
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
    slideshow=$slideshow_dir/slideshow-$now.xml
    mkdir -p "$slideshow_dir"
    {
        echo '<background>'
        date -d "@$now" '+  <starttime><year>%Y</year><month>%m</month><day>%d</day><hour>%H</hour><minute>%M</minute><second>%S</second></starttime>'
        for (( i = 0; i < count; i++ )); do
            current=$(xml_escape "${pictures[i]}")
            next=$(xml_escape "${pictures[(i + 1) % count]}")
            echo "  <static><duration>$(( minutes * 60 - fade ))</duration><file>$current</file></static>"
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
}

# The picture that a slideshow made by start_slideshow is showing right now.
picture_showing() {
    local slideshow=$1 start seconds pictures
    start=${slideshow##*-}  # the file name holds the start time
    start=${start%.xml}
    seconds=$(sed -n '/<static>/{s:.*<duration>\([0-9]*\)<.*:\1:p;q}' "$slideshow")
    mapfile -t pictures < <(sed -n 's:.*<static>.*<file>\(.*\)</file>.*:\1:p' "$slideshow")
    xml_unescape "${pictures[($(date +%s) - start) / (seconds + fade) % ${#pictures[@]}]}"
}

# If a picture was picked (in Settings, say), start a new slideshow with it.
follow_pick() {
    local key path
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

install_helper() {
    local script
    script=$(realpath -- "${BASH_SOURCE[0]}")
    # The helper runs its own copy, so you can delete the one you downloaded.
    [[ $script -ef $helper ]] || install -D -m 755 -- "$script" "$helper"
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
    start)
        start_slideshow
        install_helper
        rm -f "$old_settings_entry"
        echo "Done: your background now cycles through $count pictures, $minutes minutes each."
        echo "Pick a picture in Settings > Appearance at any time, and the slideshow carries on from it."
        ;;
esac
