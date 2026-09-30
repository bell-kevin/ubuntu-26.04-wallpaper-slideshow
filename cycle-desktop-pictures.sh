#!/usr/bin/env bash
#
# Cycle the desktop picture through every wallpaper that comes with
# Ubuntu 26.04 LTS, changing it every 30 minutes (or every MINUTES minutes).
#
# This uses GNOME's own slideshow feature: it writes a slideshow file listing
# all the pictures and makes that your background. GNOME saves the choice, so
# the slideshow resumes every time you log in and nothing extra runs in the
# background.
#
# Usage: ./cycle-desktop-pictures.sh [MINUTES]
#
# Run it again at any time to reshuffle the order or change the interval.
# To stop, pick any other background in Settings > Appearance. To go back,
# pick the tile with the slideshow icon there.

set -euo pipefail

minutes=${1:-30}
if [[ ! $minutes =~ ^[0-9]+$ ]] || (( minutes < 1 )); then
    echo "Usage: $0 [MINUTES]   (whole minutes per picture, default 30)" >&2
    exit 2
fi
if (( EUID == 0 )); then
    echo "Run this as yourself, without sudo: it sets your own background." >&2
    exit 1
fi

wallpaper_dir=/usr/share/backgrounds
slideshow_dir=$HOME/.local/share/wallpaper-slideshow
slideshow=$slideshow_dir/slideshow-$(date +%s).xml
settings_entry=$HOME/.local/share/gnome-background-properties/all-ubuntu-wallpapers.xml
fade=5  # seconds of crossfade between pictures, as in Ubuntu's own slideshow

xml_escape() {
    local s=$1
    s=${s//'&'/'&amp;'}
    s=${s//'<'/'&lt;'}
    s=${s//'>'/'&gt;'}
    printf '%s' "$s"
}

# Every picture in the wallpaper folder, in random order. Symlinks are
# resolved so a picture that has two names is only shown once.
mapfile -t pictures < <(
    find -L "$wallpaper_dir" -maxdepth 1 -type f \
        -regextype posix-extended -iregex '.*\.(png|jpe?g|webp|jxl)' \
        -exec realpath {} + | sort -u | shuf
)
count=${#pictures[@]}
if (( count == 0 )); then
    echo "No pictures found in $wallpaper_dir" >&2
    exit 1
fi

mkdir -p "$slideshow_dir" "${settings_entry%/*}"

# The slideshow starts now, so the first picture gets its full time.
{
    echo '<background>'
    date '+  <starttime><year>%Y</year><month>%m</month><day>%d</day><hour>%H</hour><minute>%M</minute><second>%S</second></starttime>'
    for (( i = 0; i < count; i++ )); do
        current=$(xml_escape "${pictures[i]}")
        next=$(xml_escape "${pictures[(i + 1) % count]}")
        echo "  <static><duration>$(( minutes * 60 - fade ))</duration><file>$current</file></static>"
        echo "  <transition><duration>$fade</duration><from>$current</from><to>$next</to></transition>"
    done
    echo '</background>'
} > "$slideshow"

# Also list the slideshow in Settings > Appearance, so it can be picked
# again after trying another background.
cat > "$settings_entry" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper deleted="false">
    <name>All Ubuntu 26.04 wallpapers</name>
    <filename>$(xml_escape "$slideshow")</filename>
    <options>zoom</options>
  </wallpaper>
</wallpapers>
EOF

# Terminals inside snap apps (VS Code, for one) point gsettings at the snap's
# own outdated list of settings, which lacks picture-uri-dark. Use the system's.
unset GSETTINGS_SCHEMA_DIR GIO_MODULE_DIR
export XDG_DATA_DIRS=/usr/local/share:/usr/share

# GNOME uses picture-uri in light style and picture-uri-dark in dark style.
gsettings set org.gnome.desktop.background picture-options zoom
gsettings set org.gnome.desktop.background picture-uri "file://$slideshow"
gsettings set org.gnome.desktop.background picture-uri-dark "file://$slideshow"

# GNOME remembers a slideshow by its file name, so each run writes a new
# file (otherwise changes would wait until the next login). Remove old ones.
find "$slideshow_dir" -maxdepth 1 -name 'slideshow-*.xml' ! -samefile "$slideshow" -delete

echo "Done: your background now cycles through $count pictures, $minutes minutes each."
