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

# --- expected consolidation topology --------------------------------------
# Mirror of the helper's conf parsing (same defaults, same validation): the
# mid-snapshot asserts must track /etc/omarchy-super-power-saver.conf instead
# of hardcoding the stock 0,14-15 island, or every A/B variant "fails".
CONF=/etc/omarchy-super-power-saver.conf
EXP_ONLINE="0,14-15" EXP_PIN="0,14-15" EXP_STEER=1 # shipped defaults (pin includes cpu0 since the 2026-07-08 A/B run)

expand_cpulist() {
  local out=() part a b i IFS=,
  for part in $1; do
    if [[ $part =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then # {1,2}: 64-bit wrap on huge numbers would bypass the <=15 bound
      a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
      ((a <= b && b <= 15)) || return 1
      for ((i = a; i <= b; i++)); do out+=("$i"); done
    elif [[ $part =~ ^[0-9]{1,2}$ ]] && ((10#$part <= 15)); then
      out+=("$((10#$part))")
    else
      return 1
    fi
  done
  ((${#out[@]})) || return 1
  printf '%s\n' "${out[@]}" | sort -nu | tr '\n' ' '
}
compress_cpulist() {
  local IFS=" " # callers may have IFS overridden (e.g. splitting conf fragments)
  local out="" start="" prev="" c
  for c in $1; do
    if [[ -n $start ]] && ((c == prev + 1)); then
      prev=$c
      continue
    fi
    [[ -n $start ]] && { ((prev > start)) && out+="${out:+,}$start-$prev" || out+="${out:+,}$start"; }
    start=$c prev=$c
  done
  [[ -n $start ]] && { ((prev > start)) && out+="${out:+,}$start-$prev" || out+="${out:+,}$start"; }
  echo "$out"
}
mask_of_cpulist() {
  local IFS=" "
  local m=0 c
  for c in $1; do ((m |= 1 << c)); done
  printf '%04x\n' "$m" # kernel prints masks padded to nr_cpu_ids width (16 cpus = 4 hex digits)
}
list_has() { [[ " $1 " == *" $2 "* ]]; }
subset_of() {
  local IFS=" "
  local c
  for c in $1; do list_has "$2" "$c" || return 1; done
}

# Replicate the helper's trust gate EXACTLY: it only sources a root-owned,
# non-group/other-writable conf. A conf that fails the gate (or that this
# unprivileged test can't read) must not shape the expectations, or the test
# asserts a topology the helper never applied.
# helper_trusts = the HELPER will source it (root-owned, no group/other write);
# the test additionally needs read access to derive matching expectations.
helper_trusts() {
  [[ -f $CONF && $(stat -c %u "$CONF" 2>/dev/null) == 0 &&
    -z $(find "$CONF" -maxdepth 0 -perm /022 2>/dev/null) ]]
}
conf_trusted() { helper_trusts && [[ -r $CONF ]]; }
if helper_trusts && [[ ! -r $CONF ]]; then
  # e.g. root:root 600: the helper APPLIES it but this unprivileged test can't
  # read it — proceeding would assert shipped defaults against a conf-shaped
  # system and blame the helper for the mismatch.
  echo "ABORT: $CONF is applied by the helper but unreadable here — chmod 644 it and retry." >&2
  exit 1
fi
if [[ -f $CONF ]] && ! helper_trusts; then
  echo "NOTE: $CONF exists but is not root-owned/non-group/other-writable — the helper ignores it;" >&2
  echo "      asserting SHIPPED DEFAULTS. Fix its ownership/perms if unintended." >&2
fi
# a stray exported SPS_* in the invoking shell must not masquerade as conf
unset SPS_ONLINE_CPUS SPS_ALLOWED_CPUS SPS_IRQ_STEER
if conf_trusted; then
  # shellcheck disable=SC1090
  . "$CONF" 2>/dev/null
  if [[ -n ${SPS_ONLINE_CPUS:-} ]] && exp=$(expand_cpulist "$SPS_ONLINE_CPUS") &&
    list_has "$exp" 0 && list_has "$exp" 14 && list_has "$exp" 15; then
    EXP_ONLINE=$(compress_cpulist "$exp")
  fi
  if [[ -n ${SPS_ALLOWED_CPUS+x} ]]; then
    if [[ -z ${SPS_ALLOWED_CPUS} ]]; then
      EXP_PIN=""
    elif exp=$(expand_cpulist "$SPS_ALLOWED_CPUS") &&
      subset_of "$exp" "$(expand_cpulist "$EXP_ONLINE")"; then
      EXP_PIN=$(compress_cpulist "$exp")
    fi
  fi
  [[ ${SPS_IRQ_STEER:-} =~ ^[01]$ ]] && EXP_STEER=$SPS_IRQ_STEER
fi
EXP_IRQ_CPUS=${EXP_PIN:-$EXP_ONLINE}
EXP_MASK=$(mask_of_cpulist "$(expand_cpulist "$EXP_IRQ_CPUS")")
# effective mode caps (conf may lower them) — the post-off leak check must
# look for THESE values, not just the shipped 10W/15W
MODE_PL1=10000000 MODE_PL2=15000000
[[ ${SPS_PL1_UW:-} =~ ^[0-9]+$ && ${SPS_PL1_UW:-0} -gt 0 ]] && MODE_PL1=$SPS_PL1_UW
[[ ${SPS_PL2_UW:-} =~ ^[0-9]+$ && ${SPS_PL2_UW:-0} -gt 0 ]] && MODE_PL2=$SPS_PL2_UW
# systemd prints AllowedCPUs as space-separated ranges ("0 14-15"), the
# kernel's cpuset files use commas ("0,14-15").
EXP_PIN_SYSTEMD=${EXP_PIN//,/ }
echo "expected topology: online=$EXP_ONLINE pin='$EXP_PIN' steer=$EXP_STEER mask=$EXP_MASK"

# Only the psr_debug read is root-only; without passwordless sudo it samples
# empty in ALL snapshots (still a consistent diff), so don't hard-require it.
sudo -n true 2>/dev/null ||
  echo "NOTE: passwordless sudo unavailable here — psr_debug not sampled"

rd() { cat "$1" 2>/dev/null; }
srd() { sudo -n cat "$1" 2>/dev/null; }

fp_dev() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [[ -f $d/idVendor && $(rd "$d/idVendor") == 06cb && $(rd "$d/idProduct") == 0701 ]] &&
      { echo "$d"; return; }
  done
}

snapshot() { # <name>
  local n="$OUT/$1" fp
  rm -f "$n.volatile"
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
    # RAPL power limits are VOLATILE when the mode is off (thermald/Dell DPTF
    # rewrites them continuously on AC) — sampled to $n.volatile, excluded
    # from the strict diff; a leak of OUR caps is asserted separately below.
    local z t
    for z in "$RAPL_MSR" "$RAPL_MMIO"; do
      t=$(basename "$z")
      {
        echo "${t}_pl1=$(rd "$z/constraint_0_power_limit_uw")"
        echo "${t}_tau=$(rd "$z/constraint_0_time_window_us")"
        echo "${t}_pl2=$(rd "$z/constraint_1_power_limit_uw")"
        echo "${t}_pl4=$(rd "$z/constraint_2_power_limit_uw")"
      } >>"$n.volatile"
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
expect_v() { # key expected — against the mid VOLATILE snapshot (RAPL)
  local got
  got=$(grep "^$1=" "$OUT/mid.volatile" | cut -d= -f2-)
  [[ $got == "$2" ]] || fail "mid: $1 = '$got', expected '$2'"
}
same_as_pre() { # key — value while mode is on must equal the pre snapshot's
  [[ $(grep "^$1=" "$OUT/pre") == $(grep "^$1=" "$OUT/mid") ]] ||
    fail "mid: $1 changed while mode on (expected untouched for this variant)"
}
watch_pl1=$(grep '^watch_pl1=' "$STATE_FILE" | cut -d= -f2)
expect cpus_online "$EXP_ONLINE"
expect ppd_profile "power-saver"
expect platform_profile "quiet"
expect_v intel-rapl:0_pl1 "${watch_pl1:-10000000}"
expect_v intel-rapl:0_pl4 "25000000"
if [[ -n $EXP_PIN ]]; then
  expect cg_user_allowed "$EXP_PIN_SYSTEMD"
  expect cg_user_cpus "$EXP_PIN"
else
  same_as_pre cg_user_allowed
  same_as_pre cg_user_cpus
fi
expect snd_power_save "1"
expect snapper_timer "inactive"
expect thermald "inactive"
if [[ $EXP_STEER == 1 ]]; then
  expect irq_default_aff "$EXP_MASK"
else
  same_as_pre irq_default_aff
fi
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

# RAPL leak check (soft — exact values are thermald-managed when off): the
# mode's own caps must NOT survive. Anything ≥20W PL1 / >15W PL2 / >25W PL4
# means thermald/DPTF is back in charge, which is stock.
k() { grep "^$1=" "$OUT/post.volatile" | cut -d= -f2; }
for z in intel-rapl:0 intel-rapl-mmio:0; do
  [[ $(k "${z}_pl1") -ge 20000000 ]] || fail "post: ${z} PL1=$(k "${z}_pl1") — mode cap leaked"
  [[ $(k "${z}_pl2") -gt 15000000 ]] || fail "post: ${z} PL2=$(k "${z}_pl2") — mode cap leaked"
  [[ $(k "${z}_pl4") -gt 25000000 ]] || fail "post: ${z} PL4=$(k "${z}_pl4") — mode clamp leaked"
  # a conf-lowered cap could sit above the stock-floor thresholds — the exact
  # mode values must never survive an off
  [[ $(k "${z}_pl1") == "$MODE_PL1" ]] && fail "post: ${z} PL1 == mode cap $MODE_PL1 — leaked"
  [[ $(k "${z}_pl2") == "$MODE_PL2" ]] && fail "post: ${z} PL2 == mode cap $MODE_PL2 — leaked"
done
echo "RAPL pre/post (thermald-managed while off, informational):"
diff --side-by-side "$OUT/pre.volatile" "$OUT/post.volatile" | sed 's/^/  /' || true

if [[ $FAIL == 0 ]]; then
  echo "== PASS"
else
  echo "== FAIL" >&2
  exit 1
fi
