#!/bin/bash
# Fair power-draw test across the 4 power modes (protocol per powerstat guidance:
# generous settle, minutes of 2s sampling matched to the EC's ~1Hz refresh).
# Phases per mode, identical for every mode:
#   settle 60s -> idle: 90 samples @2s (180s)
#   light load (2 workers, FIXED work/second ~= 20% of a balanced core) settle 8s -> 45 samples @2s (90s)
#   burst: all-core load 4s warmup -> 10 samples @2s (20s) -> cooldown 20s
# Battery must be discharging throughout. hypridle paused (screensaver at 150s).

set -u
OUT_DIR="${1:?usage: power-mode-test.sh <outdir>}"
mkdir -p "$OUT_DIR"
B=/sys/class/power_supply/BAT0
CSV="$OUT_DIR/samples.csv"
META="$OUT_DIR/meta.txt"
SPS="$HOME/.local/bin/omarchy-super-power-saver"

echo "mode,phase,epoch,volt_uv,curr_ua,watts,capacity,status" >"$CSV"

sample() { # mode phase
  local v i w st cap
  v=$(cat $B/voltage_now); i=$(cat $B/current_now)
  st=$(cat $B/status); cap=$(cat $B/capacity)
  w=$(awk -v v="$v" -v i="$i" 'BEGIN{printf "%.3f", v*i/1e12}')
  echo "$1,$2,$(date +%s),$v,$i,$w,$cap,$st" >>"$CSV"
  [[ $st == "Discharging" ]] || echo "WARN: not discharging during $1/$2 at $(date +%T)" >>"$META"
}

sample_loop() { # mode phase count interval
  for ((n = 0; n < $3; n++)); do sample "$1" "$2"; sleep "$4"; done
}

LOAD_PIDS=()
light_load_start() {
  # Fixed WORK rate (not duty): 74 x 1MB sha256 per second per worker
  # (~20% of one balanced-mode core). Slower modes take longer per second =
  # honest "same user activity" comparison.
  for _ in 1 2; do
    python3 -c '
import hashlib, time
data = b"x" * (1 << 20)
while True:
    t0 = time.monotonic()
    for _ in range(74):
        hashlib.sha256(data).digest()
    time.sleep(max(0.0, 1.0 - (time.monotonic() - t0)))' &
    LOAD_PIDS+=($!)
  done
}
burst_load_start() {
  for _ in $(seq 16); do yes >/dev/null & LOAD_PIDS+=($!); done
}
load_stop() { kill "${LOAD_PIDS[@]}" 2>/dev/null; wait "${LOAD_PIDS[@]}" 2>/dev/null; LOAD_PIDS=(); }

snapshot_meta() { # mode
  {
    echo "--- $1 $(date +%T)"
    echo "profile=$(powerprofilesctl get) platform=$(cat /sys/firmware/acpi/platform_profile)"
    echo "no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo) max_perf_pct=$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
    echo "epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
    echo "brightness=$(cat /sys/class/backlight/intel_backlight/brightness)/400"
    echo "aspm=$(grep -o '\[.*\]' /sys/module/pcie_aspm/parameters/policy)"
    echo "rapl_mmio_pl1=$(cat /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw) rapl_msr_pl1=$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw)"
    echo "dgpu=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
    echo "charge_now=$(cat $B/charge_now) capacity=$(cat $B/capacity)%"
  } >>"$META"
}

set_mode() { # mode
  case $1 in
  super) "$SPS" on ;;
  *)
    [[ $("$SPS" status) == on ]] && "$SPS" off
    powerprofilesctl set "$1"
    ;;
  esac
}

trap 'load_stop; "$SPS" off >/dev/null 2>&1; powerprofilesctl set balanced; pgrep -x hypridle >/dev/null || setsid uwsm-app -- hypridle >/dev/null 2>&1 &' EXIT

[[ $(cat $B/status) == "Discharging" ]] || { echo "ABORT: on AC" | tee "$META"; exit 1; }

pkill -x hypridle
notify-send -u critical -t 30000 "Power mode test started" "Measuring all 4 modes (~25 min). Please DON'T touch the laptop until the done notification. Screen will dim in the last phase — that's the Super Power Saver mode." 2>/dev/null

{
  echo "start=$(date -Is)"
  echo "charge_full=$(cat $B/charge_full) charge_full_design=$(cat $B/charge_full_design)"
  echo "voltage_min_design=$(cat $B/voltage_min_design) cycle_count=$(cat $B/cycle_count)"
  echo "charge_type=$(cat $B/charge_types 2>/dev/null) end_threshold=$(cat $B/charge_control_end_threshold 2>/dev/null)"
} >>"$META"

for mode in performance balanced power-saver super; do
  set_mode "$mode"
  sleep 60
  snapshot_meta "$mode"
  sample_loop "$mode" idle 90 2

  light_load_start
  sleep 8
  sample_loop "$mode" load 45 2
  load_stop
  sleep 4

  burst_load_start
  sleep 4
  sample_loop "$mode" burst 10 2
  load_stop
  sleep 20
done

"$SPS" off >/dev/null 2>&1
powerprofilesctl set balanced
setsid uwsm-app -- hypridle >/dev/null 2>&1 &
echo "end=$(date -Is)" >>"$META"
notify-send -u normal "Power mode test done" "All modes measured, settings restored. You can use the laptop again." 2>/dev/null
echo DONE
