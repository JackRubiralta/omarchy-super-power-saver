#!/bin/bash

# Scope-exactness test for omarchy-super-power-saver (v4).
#
# Proves the mode's core guarantee: everything it changes is restored EXACTLY.
# Snapshot (~50 knobs) -> mode on -> sanity asserts -> mode off -> snapshot;
# pre and post snapshots must be byte-identical.
#
# Usage:  ./power-mode-scope-test.sh [outdir]     (default: mktemp -d)
# Needs sudo (debugfs reads + the helper's own sudo -n calls must be set up).
# Run with the mode OFF. Don't plug/unplug AC or USB devices during the run —
# power-supply state and the IRQ list must be stable between snapshots.

set -u

OUT="${1:-$(mktemp -d /tmp/sps-scope-test.XXXXXX)}"
mkdir -p "$OUT"
SPS="$HOME/.local/bin/omarchy-super-power-saver"
HELPER=/usr/local/bin/omarchy-super-power-saver-helper
STATE_FILE="$HOME/.local/state/omarchy-super-power-saver/state"
GPU=/sys/class/drm/card0
RAPL_MSR=/sys/class/powercap/intel-rapl:0
RAPL_MMIO=/sys/class/powercap/intel-rapl-mmio:0
PSR_DEBUG=/sys/kernel/debug/dri/0000:00:02.0/i915_edp_psr_debug

FAIL=0
fail() { echo "ASSERT FAIL: $*" >&2; FAIL=1; }

sudo -v || { echo "needs sudo" >&2; exit 1; }

rd() { cat "$1" 2>/dev/null; }
srd() { sudo cat "$1" 2>/dev/null; }

fp_dev() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -f $d/idVendor && $(rd "$d/idVendor") == 06cb && $(rd "$d/idProduct") == 0701 ]] &&
      { echo "$d"; return; }
  done
}

snapshot() { # <name>
  local n="$OUT/$1" fp
  fp=$(fp_dev)
  {
    echo "ppd_profile=$(powerprofilesctl get 2>/dev/null)"
    echo "platform_profile=$(rd /sys/firmware/acpi/platform_profile)"
    echo "epp_cpu0=$(rd /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
    echo "epb_cpu0=$(rd /sys/devices/system/cpu/cpu0/power/energy_perf_bias)"
    echo "no_turbo=$(rd /sys/devices/system/cpu/intel_pstate/no_turbo)"
    echo "max_perf_pct=$(rd /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
    echo "cpus_online=$(rd /sys/devices/system/cpu/online)"
    echo "cpuidle_governor=$(rd /sys/devices/system/cpu/cpuidle/current_governor)"
    local z t
    for z in "$RAPL_MSR" "$RAPL_MMIO"; do
      t=$(basename "$z")
      echo "${t}_pl1=$(rd "$z/constraint_0_power_limit_uw")"
      echo "${t}_tau=$(rd "$z/constraint_0_time_window_us")"
      echo "${t}_pl2=$(rd "$z/constraint_1_power_limit_uw")"
      echo "${t}_pl4=$(rd "$z/constraint_2_power_limit_uw")"
      echo "${t}_enabled=$(rd "$z/enabled")"
    done
    echo "aspm=$(rd /sys/module/pcie_aspm/parameters/policy)"
    echo "uncore_min=$(rd /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz)"
    echo "uncore_max=$(rd /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz)"
    echo "gt_legacy_max=$(rd "$GPU/gt_max_freq_mhz")"
    echo "gt_legacy_boost=$(rd "$GPU/gt_boost_freq_mhz")"
    local g b
    for g in "$GPU"/gt/gt*; do
      b=$(basename "$g")
      echo "${b}_max=$(rd "$g/rps_max_freq_mhz")"
      echo "${b}_boost=$(rd "$g/rps_boost_freq_mhz")"
      echo "${b}_slpc=$(rd "$g/slpc_power_profile")"
    done
    echo "psr_debug=$(srd "$PSR_DEBUG")"
    echo "fp_control=${fp:+$(rd "$fp/power/control")}"
    echo "snd_power_save=$(rd /sys/module/snd_hda_intel/parameters/power_save)"
    echo "nmi_watchdog=$(rd /proc/sys/kernel/nmi_watchdog)"
    echo "dirty_writeback=$(rd /proc/sys/vm/dirty_writeback_centisecs)"
    echo "laptop_mode=$(rd /proc/sys/vm/laptop_mode)"
    echo "irq_default_aff=$(rd /proc/irq/default_smp_affinity)"
    local i
    for i in /proc/irq/[0-9]*; do
      echo "irq_$(basename "$i")=$(rd "$i/smp_affinity_list")"
    done | sort >"$n.irqs"
    echo "irq_sha=$(sha256sum "$n.irqs" | cut -d' ' -f1)"
    local s
    for s in user system machine; do
      echo "cg_${s}_allowed=$(systemctl show -p AllowedCPUs --value $s.slice 2>/dev/null)"
      echo "cg_${s}_cpus=$(rd /sys/fs/cgroup/$s.slice/cpuset.cpus)"
    done
    # normalize 'activating' -> 'active': the helper starts these --no-block
    echo "thermald=$(systemctl is-active thermald.service 2>/dev/null | sed 's/^activating$/active/')"
    echo "snapper_timer=$(systemctl is-active snapper-timeline.timer 2>/dev/null | sed 's/^activating$/active/')"
    echo "bt_soft_blocked=$(rfkill list bluetooth 2>/dev/null | grep -c 'Soft blocked: yes')"
    local iface w=""
    for iface in /sys/class/net/*/wireless; do
      [[ -d ${iface%/wireless} ]] && w=$(iw dev "$(basename "${iface%/wireless}")" get power_save 2>/dev/null)
    done
    echo "wifi_powersave=$w"
    echo "hypr_animations=$(hyprctl getoption animations:enabled -j 2>/dev/null | grep -o '"int": *[0-9]*')"
    echo "hypr_blur=$(hyprctl getoption decoration:blur:enabled -j 2>/dev/null | grep -o '"int": *[0-9]*')"
    echo "hypr_shadow=$(hyprctl getoption decoration:shadow:enabled -j 2>/dev/null | grep -o '"int": *[0-9]*')"
    echo "legacy_hypr_toggle=$([[ -f $HOME/.local/state/omarchy/toggles/hypr/super-power-saver.conf ]] && echo present || echo absent)"
    echo "watch_unit=$(systemctl --user is-active omarchy-super-power-saver-watch.service 2>/dev/null)"
    echo "run_state=$([[ -f /run/omarchy-super-power-saver.state ]] && echo present || echo absent)"
  } | sort >"$n"
}

echo "== scope test, output in $OUT"
# 'status' says off for a STALE state file too, but do_on's stale cleanup
# would then mutate state after the pre snapshot — require a truly clean slate.
[[ $("$SPS" status) == off && ! -e $STATE_FILE && ! -e /run/omarchy-super-power-saver.state ]] ||
  { echo "mode must be OFF with no leftover state — run '$SPS off' first and retry" >&2; exit 1; }

echo "== snapshot: pre"
snapshot pre

echo "== mode ON"
"$SPS" on
sleep 8

echo "== snapshot: mid + sanity asserts"
snapshot mid

expect() { # key expected — against the mid snapshot
  local got
  got=$(grep "^$1=" "$OUT/mid" | cut -d= -f2-)
  [[ $got == "$2" ]] || fail "mid: $1 = '$got', expected '$2'"
}
watch_pl1=$(grep '^watch_pl1=' "$STATE_FILE" | cut -d= -f2)
expect cpus_online "0,14-15"
expect ppd_profile "power-saver"
expect platform_profile "quiet"
expect intel-rapl:0_pl1 "${watch_pl1:-10000000}"
expect intel-rapl:0_pl4 "25000000"
expect cg_user_allowed "14-15"
expect cg_user_cpus "14-15"
expect snd_power_save "1"
expect snapper_timer "inactive"
expect thermald "inactive"
expect irq_default_aff "c000"
grep -q '^gt0_slpc=.*\[power_saving\]' "$OUT/mid" || fail "mid: gt0 slpc not [power_saving]"
grep -q '^gt1_slpc=.*\[power_saving\]' "$OUT/mid" || fail "mid: gt1 slpc not [power_saving]"
# UI must be IDENTICAL to pre while the mode is on (v4 requirement):
for k in hypr_animations hypr_blur hypr_shadow; do
  [[ $(grep "^$k=" "$OUT/pre") == $(grep "^$k=" "$OUT/mid") ]] || fail "mid: $k changed while mode on"
done
expect legacy_hypr_toggle "absent"
expect watch_unit "active"
expect run_state "present"

echo "== mode OFF"
"$SPS" off
sleep 8

echo "== snapshot: post + diff"
snapshot post

if diff -u "$OUT/pre" "$OUT/post"; then
  echo "scope diff: CLEAN (pre == post)"
else
  fail "pre/post snapshots differ (see above)"
  diff -u "$OUT/pre.irqs" "$OUT/post.irqs" | head -30
fi

if [[ $FAIL == 0 ]]; then
  echo "== PASS"
else
  echo "== FAIL" >&2
  exit 1
fi
