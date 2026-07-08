# Overwrite parts of the omarchy-menu with user-specific submenus.
# See $OMARCHY_PATH/bin/omarchy-menu for functions that can be overwritten.
#
# WARNING: Overwritten functions will obviously not be updated when Omarchy changes.
#
# Example of minimal system menu:
#
# show_system_menu() {
#   case $(menu "System" "  Lock\n󰐥  Shutdown") in
#   *Lock*) omarchy-lock-screen ;;
#   *Shutdown*) omarchy-system-shutdown ;;
#   *) back_to show_main_menu ;;
#   esac
# }
#
# Example of overriding just the about menu action: (Using zsh instead of bash (default))
#
# show_about() {
#   exec omarchy-launch-or-focus-tui "zsh -c 'fastfetch; read -k 1'"
# }

# Power Profile menu override:
#  - highlights the ACTIVE mode via walker's -c preselect + .current styling in
#    the theme's walker.css (stock italics-only marker is too subtle)
#  - adds a 4th mode: Super Power Saver (~/.local/bin/omarchy-super-power-saver)
show_setup_power_menu() {
  local current
  if [[ $(omarchy-super-power-saver status 2>/dev/null) == on ]]; then
    current="super"
  else
    current=$(powerprofilesctl get)
  fi

  local perf="󰓅  Performance" bal="󰾅  Balanced" saver="󰾆  Power Saver" super="󰂃  Super Power Saver"
  local active_line=""
  case $current in
  performance) active_line="$perf" ;;
  balanced) active_line="$bal" ;;
  power-saver) active_line="$saver" ;;
  super) active_line="$super" ;;
  esac

  local choice
  choice=$(menu "Power Profile" "$perf\n$bal\n$saver\n$super" "" "$active_line")

  if [[ $choice == "CNCLD" || -z $choice ]]; then
    back_to show_setup_menu
    return
  fi

  case $choice in
  *Super*)
    [[ $current == super ]] || omarchy-super-power-saver on
    ;;
  *Performance*)
    [[ $current == super ]] && omarchy-super-power-saver off
    powerprofilesctl set performance
    ;;
  *Balanced*)
    [[ $current == super ]] && omarchy-super-power-saver off
    powerprofilesctl set balanced
    ;;
  *Saver*)
    [[ $current == super ]] && omarchy-super-power-saver off
    powerprofilesctl set power-saver
    ;;
  *) back_to show_setup_menu ;;
  esac
}
