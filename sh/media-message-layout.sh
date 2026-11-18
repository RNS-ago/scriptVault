#!/usr/bin/env bash
# Launch a group of apps and arrange them on COSMIC (Wayland).
#
# Setup (once):
#   sudo apt install pipx && pipx ensurepath
#   pipx install cosmic-ext-window-helper
#   Turn tiling ON for the workspace you run this from.
#
# Find an app's ID: open it, then run  cosmic-ext-window-helper state
# Find monitor names:                  cosmic-randr list

set -u
H=cosmic-ext-window-helper

# wait_for APP_ID: wait (max ~30 s) until a window with that ID exists, then focus it.
wait_for() {
  for _ in $(seq 1 100); do
    $H activate "app_id='$1'" >/dev/null 2>&1 && return 0
    sleep 0.3
  done
  echo "Timed out waiting for $1" >&2
  return 1
}

# launch APP_ID COMMAND...: start the app detached and wait for its window.
launch() {
  local id=$1; shift
  setsid "$@" >/dev/null 2>&1 &
  wait_for "$id"
}

# ---------------- your layout ----------------
# With tiling on, each new window splits the FOCUSED window along its
# longer side. On a 16:9 or 16:10 screen that gives a 2x2 grid:
#   1st app             -> whole screen
#   2nd app             -> 1st | 2nd   (side by side)
#   focus 1st, 3rd app  -> 1st splits top/bottom   (left column)
#   focus 2nd, 4th app  -> 2nd splits top/bottom   (right column)
#
#   +----------+-----------+
#   | signal   | spotifast |
#   +----------+-----------+
#   | telegram | discord   |
#   +----------+-----------+
#
# The first word on each line is the window's app ID. These are best guesses:
# confirm each with `cosmic-ext-window-helper state` while the app is open.

launch signal    signal-desktop                                  # top-left
launch spotifast "$HOME/AppImages/spotifast.appimage"            # top-right
wait_for signal                                                  # focus top-left...
launch org.telegram.desktop flatpak run org.telegram.desktop     # ...bottom-left
wait_for spotifast                                               # focus top-right...
launch discord   flatpak run com.discordapp.Discord              # ...bottom-right (last: see note below)
# Discord goes last because it shows an updater window first, which could
# otherwise push the next app into the wrong spot.

# AppImages: use the file's full path as the command. Check the app ID with
# `cosmic-ext-window-helper state` while it's running, since it often isn't
# the file name. Example:
# launch obsidian "$HOME/Applications/Obsidian.AppImage"

# Flatpaks: the command is `flatpak run FLATPAK_ID` (list IDs with
# `flatpak list --app --columns=application,name`). The window's app ID is
# often the same as the Flatpak ID, but not always (Electron apps differ),
# so check it with `cosmic-ext-window-helper state`. Examples:
# launch org.gnome.Calculator flatpak run org.gnome.Calculator
# launch discord              flatpak run com.discordapp.Discord

# Optional: put an app on another workspace / monitor, and maximize it.
# $H move_to "app_id='APP_ID'" 2 HDMI-A-1
# $H maximize true "app_id='APP_ID'"