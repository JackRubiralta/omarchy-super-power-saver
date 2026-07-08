#!/bin/bash

# Installer for omarchy-super-power-saver.
#
# Run WITHOUT sudo:  ./install.sh
# It installs the user-side pieces, then tells you the one sudo command that
# installs the root helper (sudoers whitelist + udev rule + defaults cache).
#
# What it does:
#   ~/.local/bin/omarchy-super-power-saver           mode script (on|off|toggle|status)
#   ~/.local/bin/omarchy-super-power-saver-setup     root setup (you run it with sudo once)
#   ~/.config/omarchy/extensions/menu.sh             power menu: 4th mode + active marker
#   ~/.config/hypr/autostart.conf                    adds the boot-cleanup line (idempotent)
#
# Nothing here needs a reboot; the mode is runtime-only by design.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run without sudo — the script asks for the one root step at the end." >&2
  exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
EXT="$HOME/.config/omarchy/extensions"
AUTOSTART="$HOME/.config/hypr/autostart.conf"
BOOT_LINE='exec-once = ~/.local/bin/omarchy-super-power-saver boot-cleanup'

echo "== omarchy-super-power-saver installer"

# sanity: this targets Omarchy (Hyprland + power-profiles-daemon)
command -v powerprofilesctl >/dev/null ||
  echo "WARN: powerprofilesctl not found — this is built for Omarchy/power-profiles-daemon."
command -v hyprctl >/dev/null ||
  echo "WARN: hyprctl not found — boot-cleanup autostart assumes Hyprland."

mkdir -p "$BIN" "$EXT"

install -m 755 "$HERE/bin/omarchy-super-power-saver" "$BIN/"
install -m 755 "$HERE/bin/omarchy-super-power-saver-setup" "$BIN/"
echo "installed $BIN/omarchy-super-power-saver{,-setup}"

# Power menu extension: only install fresh; never clobber user customizations.
if [[ -f $EXT/menu.sh ]]; then
  if grep -q 'Super Power Saver' "$EXT/menu.sh"; then
    echo "menu extension already present — left untouched ($EXT/menu.sh)"
  else
    install -m 644 "$HERE/config/menu.sh" "$EXT/menu.sh.super-power-saver"
    echo "NOTE: $EXT/menu.sh exists with your own overrides."
    echo "      Wrote ours next to it as menu.sh.super-power-saver — merge the"
    echo "      show_setup_power_menu function into your menu.sh by hand."
  fi
else
  install -m 644 "$HERE/config/menu.sh" "$EXT/menu.sh"
  echo "installed $EXT/menu.sh (power menu override)"
fi

# Hypr autostart: boot-cleanup handles reboot-while-on leftovers + watcher revival.
if [[ -f $AUTOSTART ]] && grep -qF "$BOOT_LINE" "$AUTOSTART"; then
  echo "autostart line already present"
else
  mkdir -p "$(dirname "$AUTOSTART")"
  printf '\n# super-power-saver: clean up reboot-while-on leftovers, revive watcher\n%s\n' \
    "$BOOT_LINE" >>"$AUTOSTART"
  echo "added boot-cleanup line to $AUTOSTART"
fi

echo
echo "== done. ONE root step left (installs the root helper + sudoers + udev rule):"
echo
echo "   sudo $BIN/omarchy-super-power-saver-setup"
echo
echo "   (full path required — sudo does not search ~/.local/bin)"
echo
echo "Then toggle from the menu (Super > Setup > Power Profile) or:"
echo "   omarchy-super-power-saver on|off|toggle|status"
echo
echo "Verify while on:   sudo omarchy-super-power-saver-helper diag"
echo "Scope test:        ./test/power-mode-scope-test.sh   (mode off, on battery ideally)"
