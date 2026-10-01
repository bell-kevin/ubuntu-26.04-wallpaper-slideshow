# Ubuntu 26.04 Wallpaper Slideshow

Cycle your desktop background through every wallpaper that ships with
Ubuntu 26.04 LTS, changing every 5 minutes with a 5-second crossfade. Want a
particular picture? Pick it in **Settings → Appearance** as usual, and the
slideshow carries on from there. Pause it whenever you want to keep a favorite
on screen until you choose to resume.

It uses GNOME's built-in slideshow support. Your slideshow or paused picture
is remembered after every login.

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
- Shows each one for 5 minutes, including a 5-second fade into the next.
- Lets you choose a different duration for individual pictures.
- Lets you pause on a picture for as long as you like, then resume rotation.
- Sets it for both light and dark style, since GNOME keeps a separate
  background for each. The lock screen shows it too, blurred.
- Keeps going when you pick a picture in **Settings → Appearance** (or with
  **Set as Background** in another app): your picture shows right away, and
  the slideshow moves on after that picture's chosen duration (normally
  5 minutes), unless you've paused it.

GNOME saves your background as a setting, so the slideshow or paused picture
survives every login and reboot. A small helper starts with your session to
notice when you pick a picture. It sleeps the rest of the time.

## Everyday use

Run the `./cycle-desktop-pictures.sh` commands from the folder containing the
script. From another folder, use its full path; see
[Troubleshooting](#troubleshooting) for an example.

| To | Do this |
| --- | --- |
| Jump to a picture | Pick it in Settings → Appearance; rotation continues unless paused |
| Keep the current picture until you choose | `./cycle-desktop-pictures.sh --pause` |
| Resume rotation | `./cycle-desktop-pictures.sh --resume` (or `--unpause`) |
| Give a picture more time on every rotation | `./cycle-desktop-pictures.sh --set-duration 30` (minutes) |
| Restore its normal duration | `./cycle-desktop-pictures.sh --reset-duration` |
| Change the normal interval | `./cycle-desktop-pictures.sh 20` (minutes per picture; keeps custom durations) |
| Reshuffle the order | Run the script again while rotating |
| Stop and uninstall | `./cycle-desktop-pictures.sh --stop` (the current picture stays) |
| Start again after uninstalling | Run the script again |

The setting is per account: each person who wants the slideshow runs the
script once while logged in as themselves.

To keep one of Ubuntu's pictures on screen, pick it in **Settings → Appearance**,
then run `./cycle-desktop-pictures.sh --pause`. It stays until you run
`./cycle-desktop-pictures.sh --resume`, even after logging out or restarting.
Picking another picture while paused changes the picture and keeps rotation
paused. Resuming starts a fresh interval from the currently selected picture.

Pause keeps your interval, custom durations, and helper installed. Rerunning
the script or changing the interval or custom durations won't unpause it;
duration changes are saved for when you resume. You can also pause on a
picture by its local file path:

```bash
./cycle-desktop-pictures.sh --pause /usr/share/backgrounds/warty-final-ubuntu.png
```

For a longer timed stay on every rotation, pick a picture and run
`./cycle-desktop-pictures.sh --set-duration 30`. While rotating, this starts a
fresh 30 minutes for that picture right away; other pictures keep their usual
interval. While paused, it saves the duration for later. Its custom duration
applies each time it appears, including after picking it again, logging in,
or rerunning the script.

Both `--set-duration MINUTES [PICTURE]` and `--reset-duration [PICTURE]`
use the currently visible picture if you leave out `PICTURE`. To choose a
picture by its local file path instead:

```bash
./cycle-desktop-pictures.sh --set-duration 30 /usr/share/backgrounds/warty-final-ubuntu.png
```

Quote paths that contain spaces. Durations must be positive whole minutes
and include the 5-second crossfade. `--reset-duration` restores the normal
interval for just that picture; you can pass the same file path to reset it
while another picture is showing.

`--stop` also uninstalls: it removes the helper and every file the script
created, including the pause state and saved custom durations. If you've
deleted the script, run the copy the helper uses:

```bash
~/.local/share/wallpaper-slideshow/cycle-desktop-pictures.sh --stop
```

## Only want Ubuntu's own slideshow?

To switch to Ubuntu's built-in slideshow (21 pictures, 30 minutes each) for
your account, first run `./cycle-desktop-pictures.sh --stop` if you've been
using this script. Otherwise it takes over again the next time you pick a
picture. Then:

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
3. Points `org.gnome.desktop.background` `picture-uri` and `picture-uri-dark`
   at it.
4. Starts a helper: a systemd user service, `wallpaper-slideshow.service`,
   that runs a copy of the script with `--watch`. It waits for the background
   setting to change. Unless paused, picking a picture makes it write a new
   slideshow that starts with that picture and switches to it about a second
   later.

A few details:

- GNOME Shell caches a slideshow by file name, so each new slideshow gets a
  new file and the old one is deleted. Otherwise a new interval or order
  wouldn't show until the next login.
- A picture of your own, added with **Add Picture…** in Settings, works too.
  It's shown first and stays in the rotation until you pick another picture.
- If you pick a different slideshow, the helper leaves it alone.
- Earlier versions added a slideshow tile to Settings → Appearance, to switch
  back after picking a picture. Picking a picture no longer stops the
  slideshow, so running the script now removes that tile.
- Terminals inside snap apps point `gsettings` at an outdated copy of GNOME's
  settings list that has no `picture-uri-dark`. The script clears those
  variables before calling `gsettings`, so it works from any terminal.

## Troubleshooting

**`No such file or directory` when running the script.** The `./` prefix looks
in your terminal's current folder. If you saved the script inside
`~/cycle desktop pictures`, you can pause it from any folder with:

```bash
"$HOME/cycle desktop pictures/cycle-desktop-pictures.sh" --pause
```

To resume:

```bash
"$HOME/cycle desktop pictures/cycle-desktop-pictures.sh" --resume
```

Replace the folder path if you saved it elsewhere. Keep the quotes around
paths containing spaces. `cycle desktop pictures` is the folder;
`cycle-desktop-pictures.sh` is the script inside it.

**Only a few pictures are included.** The 21 community wallpapers come from
the `ubuntu-wallpapers-resolute` package, which a standard install includes.
If it's missing, install it with `sudo apt install ubuntu-wallpapers`, then
run the script again.

**Some pictures stopped showing after upgrading Ubuntu.** A new release
replaces the wallpaper packages. Run the script again to rebuild the list.

**The slideshow stays on one picture.** If you paused it, run
`./cycle-desktop-pictures.sh --resume`. If picking pictures still stops rotation,
check the helper with `systemctl --user status wallpaper-slideshow`, then run
the script again to reinstall and restart it.

Tested on Ubuntu 26.04.1 LTS with GNOME Shell 50.1.

## License

GNU Affero General Public License, version 3. See [LICENSE](LICENSE).

The wallpapers aren't included here; they come from Ubuntu's own packages.
This project isn't affiliated with or endorsed by Canonical. Ubuntu is a
registered trademark of Canonical Ltd.
