# Ubuntu 26.04 Wallpaper Slideshow

Cycle your desktop background through every wallpaper that ships with
Ubuntu 26.04 LTS, changing every 30 minutes with a 5-second crossfade.

It uses GNOME's built-in slideshow support, so nothing extra keeps running,
and the slideshow carries on after every login.

**Website:** <https://bell-kevin.github.io/ubuntu-26.04-wallpaper-slideshow/>

## Why this exists

Ubuntu 26.04 comes with an "Ubuntu 26.04 Community Slideshow", but it never
appears in **Settings → Appearance**. Its entry points to
`/usr/share/backgrounds/resolute.xml`, while the file is actually installed at
`/usr/share/backgrounds/contest/resolute.xml`, and Settings hides entries whose
file doesn't exist. This is reported as Launchpad bugs
[#2152826](https://bugs.launchpad.net/bugs/2152826) and
[#2155126](https://bugs.launchpad.net/bugs/2155126), and is still unfixed in
`ubuntu-wallpapers-resolute` 26.04.2.

Ubuntu's slideshow also covers only 21 of the 26 pictures. It leaves out the
default wallpaper itself (both its light and dark versions). This script
includes all of them.

## Install

Open Terminal (<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>T</kbd>) and run:

```bash
wget https://raw.githubusercontent.com/bell-kevin/ubuntu-26.04-wallpaper-slideshow/main/cycle-desktop-pictures.sh
chmod +x cycle-desktop-pictures.sh
./cycle-desktop-pictures.sh
```

Your background changes right away. Run the script as yourself, not with
`sudo`. It's short and commented, so feel free to read it first.

## What it does

- Builds a slideshow of every picture in `/usr/share/backgrounds` (the 26 that
  ship with Ubuntu 26.04, on a standard install) in random order.
- Shows each one for 30 minutes, then fades into the next over 5 seconds.
- Sets it for both light and dark style, since GNOME keeps a separate
  background for each. The lock screen shows it too, blurred.
- Adds the slideshow to **Settings → Appearance** as a tile with a slideshow
  icon, so you can switch back to it later.

GNOME saves your background as a setting, so the slideshow keeps going after
every login and reboot, and nothing runs in the background.

## Everyday use

| To | Do this |
| --- | --- |
| Change the interval | `./cycle-desktop-pictures.sh 20` (minutes per picture) |
| Reshuffle the order | Run the script again |
| Stop | Pick any other background in Settings → Appearance |
| Start again | Pick the tile with the slideshow icon in Settings → Appearance |

The setting is per account: each person who wants the slideshow runs the
script once while logged in as themselves.

To uninstall, pick another background first, then remove the two files the
script created:

```bash
rm -r ~/.local/share/wallpaper-slideshow ~/.local/share/gnome-background-properties/all-ubuntu-wallpapers.xml
```

## Only want Ubuntu's own slideshow?

To switch to Ubuntu's built-in slideshow (21 pictures, 30 minutes each) for
your account:

```bash
gsettings set org.gnome.desktop.background picture-uri file:///usr/share/backgrounds/contest/resolute.xml
gsettings set org.gnome.desktop.background picture-uri-dark file:///usr/share/backgrounds/contest/resolute.xml
```

Or fix the broken entry for everyone on the computer, so the slideshow shows
up in Settings. This edits a file that belongs to the
`ubuntu-wallpapers-resolute` package, so a future update to that package will
replace it (hopefully with the fix):

```bash
sudo sed -i 's:backgrounds/resolute.xml:backgrounds/contest/resolute.xml:' /usr/share/gnome-background-properties/resolute-wallpapers.xml
```

If `gsettings` says `No such key "picture-uri-dark"`, you're in the terminal
of a snap app such as VS Code. Use the regular Terminal app instead.

## How it works

GNOME Shell can play a slideshow described by an XML file: a list of pictures
with how long to show each one and how long to fade between them. The script:

1. Finds every picture in `/usr/share/backgrounds`, resolving symlinks so a
   picture with two names only appears once.
2. Writes a shuffled slideshow file to `~/.local/share/wallpaper-slideshow/`.
3. Lists it in `~/.local/share/gnome-background-properties/`, which is where
   Settings looks for extra backgrounds.
4. Points `org.gnome.desktop.background` `picture-uri` and `picture-uri-dark`
   at it.

A few details:

- GNOME Shell caches a slideshow by file name, so each run writes a new file
  and deletes the old one. Otherwise a new interval or order wouldn't show
  until the next login.
- Terminals inside snap apps point `gsettings` at an outdated copy of GNOME's
  settings list that has no `picture-uri-dark`. The script clears those
  variables before calling `gsettings`, so it works from any terminal.

## Troubleshooting

**Only a few pictures are included.** The 21 community wallpapers come from
the `ubuntu-wallpapers-resolute` package, which a standard install includes.
If it's missing, install it with `sudo apt install ubuntu-wallpapers`, then
run the script again.

**Some pictures stopped showing after upgrading Ubuntu.** A new release
replaces the wallpaper packages. Run the script again to rebuild the list.

Tested on Ubuntu 26.04.1 LTS with GNOME Shell 50.1.

## License

MIT; see [LICENSE](LICENSE). The wallpapers aren't included here; they come
from Ubuntu's own packages. This project isn't affiliated with or endorsed by
Canonical. Ubuntu is a registered trademark of Canonical Ltd.
