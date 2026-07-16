#!/bin/bash

# power-mode-ab-test.sh — comparative power/efficiency/lag measurement for
# omarchy-super-power-saver consolidation variants vs stock modes.
#
# The question under test (Jack, 2026-07-08): does confining userspace to
# fewer/slower cores actually save power, or does race-to-idle win — and can
# the mode's lag be fixed (cpu0 in the pin set) at negligible power cost?
#
# Usage:
#   power-mode-ab-test.sh smoke            # ~3 min: apply/assert/revert every
#                                          #   variant + malformed-conf fallback
#   power-mode-ab-test.sh quick  [outdir]  # ~40 min unattended ON BATTERY
#   power-mode-ab-test.sh media  [outdir]  # ~50 min ON BATTERY: hw video
#                                          #   playback + bursty-interactive
#                                          #   round over D / E / B (real-use
#                                          #   proxy: the "watching YouTube"
#                                          #   question)
#   power-mode-ab-test.sh loads  [outdir]  # ~45 min ON BATTERY: fixed-work +
#                                          #   PL1 sweep + browser hw/sw decode
#   power-mode-ab-test.sh thorough [outdir]# ~3 h ON BATTERY: the full best-
#                                          #   settings search — idle matrix
#                                          #   (6 variants x 2 blocks), real-use
#                                          #   round (browse/video/burst),
#                                          #   fixed-work + PL1 sweep, browser
#                                          #   hw/sw decode
#   power-mode-ab-test.sh analyze <outdir> # recompute stats from raw CSVs
#
# Launch from YOUR terminal (it prompts sudo once, then keeps the timestamp
# alive): conf-variant writes to /etc and the RAPL energy sampler need root;
# the mode toggles themselves don't. After the start notification, DO NOT
# touch the laptop, plug AC, or wake the screen until the done notification.
#
# Methodology (see docs/design-notes.md in the repo for the full rationale):
#  - battery power = current_now*voltage_now (BAT0 has no power_now); the EC
#    smooths readings, so within-visit samples are ~1 effective observation —
#    ALL inference is on per-visit medians.
#  - idle visits are baseline-bracketed: A(stock power-saver) -> shuffled test
#    variants -> A again; each variant is scored as delta vs the linear
#    interpolation of the bracketing A medians (cancels SoC/thermal drift).
#  - fixed-WORK loads (xz of a byte-identical tmpfs file), never fixed-time:
#    total joules over [start, back-to-idle] IS joules-per-work, which gives
#    race-to-idle fair credit for its sleep tail.
#  - responsiveness proxies run as ordinary user-session processes so they
#    inherit each variant's cgroup confinement exactly like real apps.

set -u
LC_ALL=C
LANG=C

TIER="${1:-}"
case $TIER in smoke | quick | media | loads | thorough | analyze) ;; *)
  sed -n '/^# Usage:/,/^# touch the laptop/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac

B=/sys/class/power_supply/BAT0
DGPU=/sys/bus/pci/devices/0000:01:00.0
RAPL_MSR=/sys/class/powercap/intel-rapl:0
RAPL_MMIO=/sys/class/powercap/intel-rapl-mmio:0
SPS="$HOME/.local/bin/omarchy-super-power-saver"
STATE_FILE="$HOME/.local/state/omarchy-super-power-saver/state"
RUN_STATE=/run/omarchy-super-power-saver.state
CONF=/etc/omarchy-super-power-saver.conf
RESULTS_DIR="$HOME/omarchy-super-power-saver/test/results"
OUT="${2:-$RESULTS_DIR/ab-$(date +%Y%m%d-%H%M)}"
CSV="$OUT/samples.csv"
RAPL_CSV="$OUT/rapl.csv"
BENCH_CSV="$OUT/bench.csv"
EVENTS="$OUT/events.csv"
META="$OUT/meta.txt"
LOG="$OUT/log"
WORK_FILE=/tmp/sps-ab-work.bin
VIDEO_FILE=/tmp/sps-ab-video.mp4
VIDEO_HTML=/tmp/sps-ab-video.html
BROWSE_DIR=/tmp/sps-ab-browse
# gt1 is the iGPU MEDIA engine: sustained nonzero actual frequency during
# playback = hardware decode engaged; 0 = software decode on the CPU.
# Card derived from the stable PCI path — card NUMBERS can flip across boots
# on this machine (the NVIDIA card has claimed renderD128 already).
IGPU_CARD=$(basename "$(readlink -f /dev/dri/by-path/pci-0000:00:02.0-card 2>/dev/null)" 2>/dev/null)
GT1_ACT=/sys/class/drm/${IGPU_CARD:-card0}/gt/gt1/rps_act_freq_mhz

# Timers that could fire mid-run and contaminate exactly one variant's window;
# active ones are stopped for the whole run (fairness: super pauses snapper
# anyway — stock variants must not be penalized by it) and restarted at exit.
TIMER_CANDIDATES="snapper-timeline.timer snapper-cleanup.timer plocate-updatedb.timer man-db.timer shadow.timer systemd-tmpfiles-clean.timer archlinux-keyring-wkd-sync.timer fwupd-refresh.timer pacman-filesdb-refresh.timer atop-rotate.timer logrotate.timer"

# ---------------------------------------------------------------- variants
# name|kind|conf-fragment(;-separated)   kind: stock -> fragment = ppd profile
# Expected topology per super variant is derived from the fragment with the
# same cpulist code the helper uses.
V_A="A|stock|power-saver"
V_B="B|super|" # shipped default since 2026-07-16: no consolidation (thorough-tier winner)
V_B2="B2|super|SPS_ONLINE_CPUS=0-15;SPS_ALLOWED_CPUS=14-15;SPS_IRQ_STEER=1"
V_C="C|super|SPS_ALLOWED_CPUS=14-15" # strict LP-E pin (pre-2026-07-08 default)
V_D="D|super|SPS_ONLINE_CPUS=0,14-15;SPS_ALLOWED_CPUS=0,14-15;SPS_IRQ_STEER=1" # cpu0+LP-E pin (2026-07-08..16 default)
V_E="E|super|SPS_ONLINE_CPUS=0,6-7,14-15;SPS_ALLOWED_CPUS=0,6-7,14-15;SPS_IRQ_STEER=1"
V_F="F|super|SPS_CPUIDLE_GOV=teo"
V_G8="G8|super|SPS_PL1_UW=8000000" # shipped-default topology, PL1 10W->8W (load-only)
V_G6="G6|super|SPS_PL1_UW=6000000" # shipped-default topology, PL1 6W
V_BAL="BAL|stock|balanced"
V_PERF="PERF|stock|performance"

# Defaults so every tier (incl. smoke/analyze paths) has the arrays declared
# under set -u; the case below overrides per tier.
IDLE_VARIANTS=() REALUSE_VARIANTS=() W1_VARIANTS=()
BROWSER_PHASE=0 IDLE_BLOCKS=0 SOC_FLOOR=40

# Per-tier phases:
#   IDLE_BLOCKS x [A, shuffled IDLE_VARIANTS, A]  — idle W + responsiveness
#   one [A, shuffled REALUSE_VARIANTS, A] block   — + bursty/video/browsing
#   BROWSER_PHASE                                  — hw-vs-sw decode, both browsers
#   W1_VARIANTS                                    — fixed-work joules (+ PL1 sweep)
case $TIER in
quick)
  IDLE_VARIANTS=("$V_B" "$V_C" "$V_D")
  REALUSE_VARIANTS=()
  W1_VARIANTS=("$V_B" "$V_C" "$V_D")
  BROWSER_PHASE=0
  IDLE_BLOCKS=1 SOC_FLOOR=40
  ;;
media)
  # Real-use round only: which topology is cheapest for fixed-RATE work
  # (hw-decoded video = the YouTube proxy, where mean W IS joules-per-work),
  # for bursty interactive work, and for actual Firefox browsing.
  IDLE_VARIANTS=()
  REALUSE_VARIANTS=("$V_D" "$V_E" "$V_B")
  W1_VARIANTS=()
  BROWSER_PHASE=1
  IDLE_BLOCKS=0 SOC_FLOOR=45
  ;;
loads)
  # Recovery/companion tier (~45 min): just the load phases — fixed-work
  # joules + PL1 sweep and the browser hw/sw decode A/B.
  IDLE_VARIANTS=()
  REALUSE_VARIANTS=()
  W1_VARIANTS=("$V_A" "$V_B" "$V_C" "$V_D" "$V_G8" "$V_G6")
  BROWSER_PHASE=1
  IDLE_BLOCKS=0 SOC_FLOOR=45
  ;;
thorough)
  # The full best-settings search (~3h): complete idle matrix, real-use round
  # on the topology contenders, fixed-work + PL1 sweep, browser decode A/B.
  IDLE_VARIANTS=("$V_B" "$V_B2" "$V_C" "$V_D" "$V_E" "$V_F")
  REALUSE_VARIANTS=("$V_D" "$V_E" "$V_B")
  W1_VARIANTS=("$V_A" "$V_B" "$V_C" "$V_D" "$V_G8" "$V_G6")
  BROWSER_PHASE=1
  IDLE_BLOCKS=2 SOC_FLOOR=70
  ;;
esac

# ------------------------------------------------- cpulist utils (= helper's)
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

# Derive expected topology from a super variant's conf fragment (defaults =
# the helper's shipped defaults). Sets EXP_ONLINE, EXP_PIN, EXP_MASK, EXP_STEER.
derive_expect() { # conf-fragment
  EXP_ONLINE="0-15" EXP_PIN="" EXP_STEER=0 # = helper shipped defaults (B, 2026-07-16)
  local kv k v
  local IFS=';'
  for kv in $1; do
    k=${kv%%=*} v=${kv#*=}
    case $k in
    SPS_ONLINE_CPUS) EXP_ONLINE=$(compress_cpulist "$(expand_cpulist "$v")") ;;
    SPS_ALLOWED_CPUS) [[ -z $v ]] && EXP_PIN="" || EXP_PIN=$(compress_cpulist "$(expand_cpulist "$v")") ;;
    SPS_IRQ_STEER) EXP_STEER=$v ;;
    esac
  done
  local irq_cpus=${EXP_PIN:-$EXP_ONLINE}
  EXP_MASK=$(mask_of_cpulist "$(expand_cpulist "$irq_cpus")")
}

# ------------------------------------------------------------------ plumbing
log() { echo "$(date +%T) $*" >>"$LOG"; }
note() { echo "$*" | tee -a "$LOG"; } # pre-redirect chatter

FAIL=0
chk() { # condition-result description
  if [[ $1 == 0 ]]; then
    note "  ok   $2"
  else
    note "  FAIL $2"
    FAIL=1
  fi
}

VISIT=0 # global visit counter (distinguishes the two A visits per block)

# One transient EC/ACPI status hiccup must not kill an unrepeatable 3h run:
# a plug event is only real if it persists across a 1s re-read.
discharging() {
  [[ $(<"$B/status") == Discharging ]] && return 0
  sleep 1
  [[ $(<"$B/status") == Discharging ]]
}

# A workload that died during its window means the samples are mislabeled
# idle — worse than no measurement. Checked after settle and before _end.
alive_or_fail() { # pid name
  kill -0 "$1" 2>/dev/null && return 0
  log "ABORT: $2 workload process died mid-run"
  return 1
}

sample_row() { # variant block phase -> exit 1 if AC plugged
  local v i st cap dg w
  v=$(<"$B/voltage_now") i=$(<"$B/current_now") st=$(<"$B/status") cap=$(<"$B/capacity")
  dg=$(<"$DGPU/power/runtime_status")
  w=$(awk -v v="$v" -v i="$i" 'BEGIN{printf "%.3f", (v<0?-v:v)*(i<0?-i:i)/1e12}')
  echo "$1,$2,$VISIT,$3,$(date +%s.%N),$v,$i,$w,$cap,$st,$dg" >>"$CSV"
  [[ $st == Discharging ]] || discharging
}

sample_loop() { # variant block phase count
  local n
  for ((n = 0; n < $4; n++)); do
    sample_row "$1" "$2" "$3" || {
      log "ABORT: AC plugged during $1/$3"
      return 1
    }
    sleep 2
  done
}

event() { echo "$1,$2,$3,$(date +%s.%N)" >>"$EVENTS"; } # variant block event

snapshot_meta() { # label
  {
    echo "--- $1 visit=$VISIT $(date +%T)"
    echo "profile=$(powerprofilesctl get 2>/dev/null) platform=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
    echo "epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)"
    echo "online=$(cat /sys/devices/system/cpu/online) user_cpuset='$(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null)'"
    echo "irq_default=$(cat /proc/irq/default_smp_affinity 2>/dev/null) cpuidle=$(cat /sys/devices/system/cpu/cpuidle/current_governor 2>/dev/null)"
    echo "dgpu=$(cat "$DGPU/power/runtime_status") brightness=$(cat /sys/class/backlight/intel_backlight/brightness)"
    echo "capacity=$(cat "$B/capacity")% status=$(cat "$B/status")"
  } >>"$META"
}

# --------------------------------------------------------- variant switching
write_conf() { # fragment ("" = defaults-only marker conf)
  local tmp="$OUT/conf.tmp"
  {
    echo "# TEMPORARY A/B-test conf written by power-mode-ab-test.sh — if you"
    echo "# find this outside a test run, delete it (or restore conf.orig)."
    tr ';' '\n' <<<"$1"
  } >"$tmp"
  sudo -n cp "$tmp" "$CONF" && sudo -n chown root:root "$CONF" && sudo -n chmod 644 "$CONF"
}

CUR_ONLINE_SET=""
apply_variant() { # "name|kind|conf" -> sets CUR (name); returns 1 on failure
  local name kind conf
  IFS='|' read -r name kind conf <<<"$1"
  CUR=$name
  local prev_online
  prev_online=$(cat /sys/devices/system/cpu/online)
  if [[ $kind == stock ]]; then
    [[ -f $STATE_FILE || -f $RUN_STATE ]] && "$SPS" off >/dev/null 2>&1
    powerprofilesctl set "$conf" 2>/dev/null
    # The A visits anchor every delta — a half-reverted "baseline" (off
    # failed, cores still offline, slices still pinned) would silently skew
    # the whole block, so the stock branch verifies as strictly as super.
    [[ ! -f $STATE_FILE && ! -f $RUN_STATE ]] || {
      log "ABORT: $name state files persist after off"
      return 1
    }
    [[ $(cat /sys/devices/system/cpu/online) == "0-15" ]] || {
      log "ABORT: $name online=$(cat /sys/devices/system/cpu/online) expected=0-15"
      return 1
    }
    [[ -z $(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null) ]] || {
      log "ABORT: $name user.slice still pinned after off"
      return 1
    }
    [[ $(powerprofilesctl get 2>/dev/null) == "$conf" ]] || {
      log "ABORT: $name ppd profile=$(powerprofilesctl get 2>/dev/null) expected=$conf"
      return 1
    }
  else
    [[ -f $STATE_FILE || -f $RUN_STATE ]] && "$SPS" off >/dev/null 2>&1
    write_conf "$conf" || {
      log "conf write failed for $name"
      return 1
    }
    "$SPS" on >/dev/null 2>&1
    derive_expect "$conf"
    # Topology must match the conf we just wrote — anything else means the
    # helper rejected it or a stale helper is installed; measuring a mislabeled
    # variant is worse than not measuring.
    [[ $(cat /sys/devices/system/cpu/online) == "$EXP_ONLINE" ]] || {
      log "ABORT: $name online=$(cat /sys/devices/system/cpu/online) expected=$EXP_ONLINE"
      return 1
    }
    [[ $(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null) == "$EXP_PIN" ]] || {
      log "ABORT: $name user cpuset='$(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null)' expected='$EXP_PIN'"
      return 1
    }
    grep -q '^root_applied=yes' "$STATE_FILE" || {
      log "ABORT: $name root_applied != yes"
      return 1
    }
    # PL1 must match the fragment too (the G8/G6 sweep variants share D's
    # topology — without this, a helper ignoring SPS_PL1_UW measures three
    # identical copies labeled D/G8/G6). File is world-readable.
    local exp_pl1=10000000 kv
    local IFS=';'
    for kv in $conf; do
      [[ $kv == SPS_PL1_UW=* && ${kv#*=} =~ ^[0-9]+$ ]] && exp_pl1=${kv#*=}
    done
    unset IFS
    [[ $(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) == "$exp_pl1" ]] || {
      log "ABORT: $name PL1=$(cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null) expected=$exp_pl1"
      return 1
    }
  fi
  # Settle: 60s, 90s when the online set changed (hotplug rebuilds scheduler
  # domains and migrates IRQs; the mode script also runs its own post-apply
  # observation). Then a cheap drift gate: two 5-sample means 20s apart must
  # agree within 0.4W, one 30s extension if not.
  local settle=60
  [[ $(cat /sys/devices/system/cpu/online) != "$prev_online" ]] && settle=90
  log "$name applied; settling ${settle}s"
  sleep "$settle"
  local gate
  gate=$(
    for _ in 1 2 3 4 5; do
      awk -v v="$(<"$B/voltage_now")" -v i="$(<"$B/current_now")" 'BEGIN{printf "%.3f\n", v*i/1e12}'
      sleep 2
    done
    sleep 10
    for _ in 1 2 3 4 5; do
      awk -v v="$(<"$B/voltage_now")" -v i="$(<"$B/current_now")" 'BEGIN{printf "%.3f\n", v*i/1e12}'
      sleep 2
    done
  )
  if awk 'NR<=5{a+=$1} NR>5{b+=$1} END{d=(a-b)/5; exit (d<0?-d:d)<0.4?0:1}' <<<"$gate"; then
    :
  else
    log "$name still settling (>0.4W drift in gate) — +30s"
    sleep 30
  fi
  return 0
}

# --------------------------------------------------------------- benchmarks
bench() { # variant block — ~25s, runs INSIDE the variant's confinement
  local name=$1 block=$2 i t0 t1 ms
  event "$name" "$block" bench_start
  # proof of confinement for the analysis
  echo "bench cpus_allowed=$(awk '/Cpus_allowed_list/{print $2}' /proc/self/status)" >>"$META"
  for i in $(seq 50); do
    t0=$EPOCHREALTIME
    bash -c ':'
    t1=$EPOCHREALTIME
    awk -v a="$t0" -v b="$t1" -v v="$name" -v k="$block" \
      'BEGIN{printf "%s,%s,exec_ms,%.3f\n", v, k, (b-a)*1000}' >>"$BENCH_CSV"
  done
  for i in $(seq 10); do
    t0=$EPOCHREALTIME
    python3 -c pass
    t1=$EPOCHREALTIME
    awk -v a="$t0" -v b="$t1" -v v="$name" -v k="$block" \
      'BEGIN{printf "%s,%s,pyspawn_ms,%.3f\n", v, k, (b-a)*1000}' >>"$BENCH_CSV"
  done
  # timer-wakeup overshoot: p50/p99 us over 3000 x 1ms sleeps (discriminates
  # cpuidle governors and LP-E deep-C exit latency = input-handling jitter)
  python3 - "$name" "$block" <<'PY' >>"$BENCH_CSV"
import sys, time
overs = []
for _ in range(3000):
    t0 = time.perf_counter_ns()
    time.sleep(0.001)
    overs.append(time.perf_counter_ns() - t0 - 1_000_000)
overs.sort()
v, k = sys.argv[1], sys.argv[2]
print(f"{v},{k},wake_p50_us,{overs[len(overs)//2]/1000:.1f}")
print(f"{v},{k},wake_p99_us,{overs[int(len(overs)*0.99)]/1000:.1f}")
PY
  # single-thread throughput proxy: 64MB sha256 in-process
  for i in 1 2 3; do
    python3 - "$name" "$block" <<'PY' >>"$BENCH_CSV"
import sys, time, hashlib
data = b"x" * (1 << 20)
t0 = time.perf_counter()
for _ in range(64):
    hashlib.sha256(data).digest()
print(f"{sys.argv[1]},{sys.argv[2]},st_chunk_ms,{(time.perf_counter()-t0)*1000:.1f}")
PY
  done
  # compositor round-trip (Hyprland itself lives in the confined slice)
  if command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; then
    for i in $(seq 30); do
      t0=$EPOCHREALTIME
      hyprctl version -j >/dev/null 2>&1
      t1=$EPOCHREALTIME
      awk -v a="$t0" -v b="$t1" -v v="$name" -v k="$block" \
        'BEGIN{printf "%s,%s,hypr_ms,%.3f\n", v, k, (b-a)*1000}' >>"$BENCH_CSV"
    done
  fi
  event "$name" "$block" bench_end
}

# ------------------------------------------------------------------ W1 load
w1_run() { # variant block — fixed work: xz the tmpfs file, sample through tail
  local name=$1 block=$2 spid
  (
    while sample_row "$name" "$block" w1; do sleep 2; done
  ) &
  spid=$!
  LOAD_PIDS+=("$spid") # so cleanup can stop it if we die mid-run
  event "$name" "$block" w1_start
  xz -6 -T1 <"$WORK_FILE" >/dev/null
  event "$name" "$block" w1_end
  sleep 30 # tail: race-to-idle gets credit for its sleep; analyze finds idle-return
  kill "$spid" 2>/dev/null
  wait "$spid" 2>/dev/null
  LOAD_PIDS=()
  # Only the background sampler sees an AC plug (its loop just stops) — the
  # foreground must check too, or the remaining W1 variants integrate wall
  # power into "battery joules" without complaint.
  discharging || {
    log "ABORT: AC plugged during/after $name w1"
    return 1
  }
  log "$name w1 done; cooldown 90s"
  sleep 90 # thermal hygiene before the next variant
}

# --------------------------------------------------------------- W2 bursty
# The interactive-use proxy: a fixed chunk of work every 5s for 150s. A fast
# variant races each chunk and sleeps; a slow one grinds. Total work is fixed,
# so mean W over the window compares fairly, and per-chunk latency doubles as
# a responsiveness-under-load metric.
w2_run() { # variant block
  local name=$1 block=$2 spid
  (
    while sample_row "$name" "$block" w2; do sleep 2; done
  ) &
  spid=$!
  LOAD_PIDS+=("$spid")
  event "$name" "$block" w2_start
  python3 - "$name" "$block" <<'PY' >>"$BENCH_CSV"
import sys, time, hashlib
data = b"x" * (1 << 20)
lat = []
for _ in range(30):                       # 30 cycles x 5s = 150s
    t0 = time.perf_counter()
    for _ in range(60):                   # fixed work per cycle: 60 x 1MB sha256
        hashlib.sha256(data).digest()
    dt = time.perf_counter() - t0
    lat.append(dt)
    time.sleep(max(0.0, 5.0 - dt))
lat.sort()
v, k = sys.argv[1], sys.argv[2]
print(f"{v},{k},w2_chunk_p50_ms,{lat[len(lat)//2]*1000:.1f}")
print(f"{v},{k},w2_chunk_p95_ms,{lat[int(len(lat)*0.95)]*1000:.1f}")
PY
  event "$name" "$block" w2_end
  kill "$spid" 2>/dev/null
  wait "$spid" 2>/dev/null
  LOAD_PIDS=()
  discharging || {
    log "ABORT: AC plugged during $name w2"
    return 1
  }
}

# ---------------------------------------------------------------- W3 video
# Fixed-rate work: hw-decoded 1080p30 playback (the "watching YouTube" proxy —
# same decoder/compositor/wakeup pattern, minus the browser). Mean W over the
# window IS energy-per-second-of-video; dropped frames = playback smoothness.
w3_run() { # variant block
  local name=$1 block=$2 mpid spid drops
  mpv --hwdec=auto-safe --loop=inf --mute=yes --really-quiet \
    --input-ipc-server="$OUT/mpv-ipc.sock" "$VIDEO_FILE" >/dev/null 2>&1 &
  mpid=$!
  LOAD_PIDS+=("$mpid")
  sleep 20 # decoder pipeline + renderer settle before measuring
  alive_or_fail "$mpid" "$name w3(mpv)" || { LOAD_PIDS=(); return 1; }
  (
    while sample_row "$name" "$block" w3; do sleep 2; done
  ) &
  spid=$!
  LOAD_PIDS+=("$spid")
  event "$name" "$block" w3_start
  sleep 150
  alive_or_fail "$mpid" "$name w3(mpv)" || { kill "$spid" 2>/dev/null; LOAD_PIDS=(); return 1; }
  event "$name" "$block" w3_end
  drops=$(python3 - "$OUT/mpv-ipc.sock" <<'PY' 2>/dev/null
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.settimeout(2)
f = s.makefile()
def q(prop):
    s.sendall((json.dumps({"command": ["get_property", prop]}) + "\n").encode())
    for _ in range(20):  # replies interleave with mpv events - scan for ours
        try:
            j = json.loads(f.readline())
        except Exception:
            return -1
        if "data" in j or "error" in j:
            return j.get("data", -1)
    return -1
print(f"{q('frame-drop-count')},{q('decoder-frame-drop-count')}")
PY
  )
  # empty when the IPC query failed outright (mpv dead): keep the -1 sentinel
  # q() uses, or analyze would hit float('') and lose the whole report
  drops=${drops:--1,-1}
  [[ $drops == *,* ]] || drops="$drops,-1"
  echo "$name,$block,w3_vo_drops,${drops%%,*}" >>"$BENCH_CSV"
  echo "$name,$block,w3_dec_drops,${drops##*,}" >>"$BENCH_CSV"
  kill "$spid" "$mpid" 2>/dev/null
  wait "$spid" "$mpid" 2>/dev/null
  LOAD_PIDS=()
  rm -f "$OUT/mpv-ipc.sock"
  discharging || {
    log "ABORT: AC plugged during $name w3"
    return 1
  }
}

# A fresh Firefox profile fires first-run network/telemetry/update chatter —
# different noise every launch. These prefs silence it so every run measures
# the workload, not the onboarding.
ff_quiet_profile() { # profile-dir
  cat >"$1/user.js" <<'JS'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("app.normandy.enabled", false);
user_pref("app.update.auto", false);
user_pref("network.captive-portal-service.enabled", false);
JS
}

# ---------------------------------------------------------------- W6 browse
# Real BROWSING in Firefox (Jack's request): local self-driving pages — text,
# images, JS — that smooth-scroll to the bottom, pause as if reading, then
# navigate to the next page in the chain, looping. Identical bytes for every
# variant and zero network, so power deltas are the topology's doing. Runs
# per topology visit (including the A brackets), giving browsing W the same
# baseline-bracket treatment as idle W.
w6_run() { # variant block
  local name=$1 block=$2 bpid spid
  local prof="$OUT/prof-browse-$name-$VISIT"
  mkdir -p "$prof"
  ff_quiet_profile "$prof"
  MOZ_DRM_DEVICE=/dev/dri/by-path/pci-0000:00:02.0-render \
    firefox --profile "$prof" --new-instance --no-remote \
    "file://$BROWSE_DIR/page0.html" >/dev/null 2>&1 &
  bpid=$!
  LOAD_PIDS+=("$bpid")
  sleep 25 # launch + first page settled
  alive_or_fail "$bpid" "$name w6(firefox)" || { LOAD_PIDS=(); return 1; }
  (
    while sample_row "$name" "$block" w6; do sleep 2; done
  ) &
  spid=$!
  LOAD_PIDS+=("$spid")
  event "$name" "$block" w6_start
  sleep 150
  alive_or_fail "$bpid" "$name w6(firefox)" || {
    kill "$spid" 2>/dev/null
    pkill -f "$prof" 2>/dev/null
    LOAD_PIDS=()
    return 1
  }
  event "$name" "$block" w6_end
  kill "$spid" "$bpid" 2>/dev/null
  pkill -f "$prof" 2>/dev/null
  wait "$spid" 2>/dev/null
  LOAD_PIDS=()
  sleep 8
  discharging || {
    log "ABORT: AC plugged during $name w6"
    return 1
  }
}

# ------------------------------------------------------------- W4/W5 browser
# The real "watching YouTube" measurement: a browser playing the same local
# video, hw decode ON vs forced-OFF — the delta is what the browser config
# work is worth. A background probe records the media engine's actual
# frequency: nonzero = hardware decode really engaged (not just configured).
browser_run() { # variant block browser(chromium|firefox) decode(hw|sw)
  local name=$1 block=$2 br=$3 dec=$4 bpid spid gpid
  # separate line: word expansion of a `local` list happens BEFORE any of its
  # assignments land, so ${br:0:2} on the same line is an unbound-variable
  # abort under set -u (killed the 2026-07-16 thorough run at the 2.2h mark)
  local ph="${br:0:2}${dec}"
  local prof="$OUT/prof-$br-$dec"
  mkdir -p "$prof"
  case $br in
  chromium)
    local extra=()
    [[ $dec == sw ]] && extra=(--disable-accelerated-video-decode)
    chromium --user-data-dir="$prof" --no-first-run --disable-sync \
      --autoplay-policy=no-user-gesture-required "${extra[@]}" \
      --new-window "file://$VIDEO_HTML" >/dev/null 2>&1 &
    bpid=$!
    ;;
  firefox)
    # FF >= 137 hw-decodes BY DEFAULT, so hw = quiet profile; the sw run
    # force-disables it — the delta is what hardware decode is worth.
    ff_quiet_profile "$prof"
    if [[ $dec == sw ]]; then
      {
        echo 'user_pref("media.hardware-video-decoding.enabled", false);'
        echo 'user_pref("media.hardware-video-decoding.force-enabled", false);'
      } >>"$prof/user.js"
    fi
    MOZ_DRM_DEVICE=/dev/dri/by-path/pci-0000:00:02.0-render \
      firefox --profile "$prof" --new-instance --no-remote \
      "file://$VIDEO_HTML" >/dev/null 2>&1 &
    bpid=$!
    ;;
  esac
  LOAD_PIDS+=("$bpid")
  sleep 30 # browser start + autoplay + pipeline settle
  alive_or_fail "$bpid" "$name $ph($br)" || { LOAD_PIDS=(); return 1; }
  (
    while sample_row "$name" "$block" "$ph"; do sleep 2; done
  ) &
  spid=$!
  LOAD_PIDS+=("$spid")
  (
    for _ in $(seq 30); do
      echo "$name,$block,${ph}_gt1_mhz,$(cat "$GT1_ACT" 2>/dev/null || echo -1)"
      sleep 5
    done >>"$BENCH_CSV"
  ) &
  gpid=$!
  LOAD_PIDS+=("$gpid")
  event "$name" "$block" "${ph}_start"
  sleep 150
  alive_or_fail "$bpid" "$name $ph($br)" || {
    kill "$spid" "$gpid" 2>/dev/null
    pkill -f "$prof" 2>/dev/null
    LOAD_PIDS=()
    return 1
  }
  event "$name" "$block" "${ph}_end"
  kill "$spid" "$gpid" "$bpid" 2>/dev/null
  # browsers spawn process trees a single kill misses — sweep by profile dir
  pkill -f "$prof" 2>/dev/null
  wait "$spid" "$gpid" 2>/dev/null
  LOAD_PIDS=()
  sleep 10 # let the browser exit fully before the next launch
  discharging || {
    log "ABORT: AC plugged during $name $ph"
    return 1
  }
}

# ------------------------------------------------------------------- smoke
run_smoke() {
  note "== SMOKE: apply/assert/revert every variant (no measurement)"
  local v name kind conf
  for v in "$V_B" "$V_B2" "$V_C" "$V_D" "$V_E"; do
    IFS='|' read -r name kind conf <<<"$v"
    note "-- variant $name ($conf)"
    write_conf "$conf" || {
      chk 1 "$name: conf write"
      continue
    }
    "$SPS" on >/dev/null 2>&1
    derive_expect "$conf"
    chk "$([[ $(cat /sys/devices/system/cpu/online) == "$EXP_ONLINE" ]]; echo $?)" \
      "$name online=$EXP_ONLINE (got $(cat /sys/devices/system/cpu/online))"
    chk "$([[ $(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null) == "$EXP_PIN" ]]; echo $?)" \
      "$name user.slice cpuset='$EXP_PIN' (got '$(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null)')"
    if [[ ${conf} != *SPS_IRQ_STEER=0* ]]; then
      chk "$([[ $(cat /proc/irq/default_smp_affinity) == "$EXP_MASK" ]]; echo $?)" \
        "$name irq mask=$EXP_MASK (got $(cat /proc/irq/default_smp_affinity))"
    else
      chk "$([[ $(cat /proc/irq/default_smp_affinity) == ffff ]]; echo $?)" \
        "$name irq mask untouched (got $(cat /proc/irq/default_smp_affinity))"
    fi
    chk "$(grep -q '^root_applied=yes' "$STATE_FILE"; echo $?)" "$name root_applied=yes"
    chk "$(systemctl --user is-active --quiet omarchy-super-power-saver-watch.service; echo $?)" "$name watcher active"
    # systemd's AllowedCPUs display format, for the scope test's mid asserts:
    note "  info: systemctl shows AllowedCPUs='$(systemctl show -p AllowedCPUs --value user.slice)'"
    # spawned processes actually land in the confinement:
    if [[ -n $EXP_PIN ]]; then
      chk "$([[ $(systemd-run --user --quiet --pipe -- grep Cpus_allowed_list /proc/self/status | awk '{print $2}') == "$EXP_PIN" ]]; echo $?)" \
        "$name spawned proc confined to $EXP_PIN"
    fi
    "$SPS" off >/dev/null 2>&1
    chk "$([[ ! -f $STATE_FILE && ! -f $RUN_STATE ]]; echo $?)" "$name state files gone after off"
    chk "$([[ $(cat /sys/devices/system/cpu/online) == 0-15 ]]; echo $?)" "$name all cpus back online"
    chk "$([[ -z $(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null) ]]; echo $?)" "$name user.slice unpinned"
    chk "$([[ $(cat /proc/irq/default_smp_affinity) == ffff ]]; echo $?)" "$name irq default back to ffff"
  done

  note "-- malformed conf falls back to shipped defaults"
  write_conf "SPS_ONLINE_CPUS=banana;SPS_ALLOWED_CPUS=0-99;SPS_IRQ_STEER=2"
  "$SPS" on >/dev/null 2>&1
  chk "$([[ $(cat /sys/devices/system/cpu/online) == 0-15 ]]; echo $?)" \
    "bad conf -> default online 0-15 (got $(cat /sys/devices/system/cpu/online))"
  chk "$([[ -z $(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null) ]]; echo $?)" \
    "bad conf -> default no pin (got '$(cat /sys/fs/cgroup/user.slice/cpuset.cpus 2>/dev/null)')"
  chk "$(sudo -n grep -q 'bad SPS_ONLINE_CPUS' /run/omarchy-super-power-saver.drift; echo $?)" \
    "bad conf -> drift log has rejection lines"
  "$SPS" off >/dev/null 2>&1
  chk "$([[ $(cat /sys/devices/system/cpu/online) == 0-15 ]]; echo $?)" "recovered to 0-15"
}

# ----------------------------------------------------------------- analyze
run_analyze() {
  python3 - "$OUT" <<'PY'
import csv, statistics as st, sys, os

out = sys.argv[1]
def rows(f, n):
    # skip the header and anything malformed (the root RAPL sampler is killed
    # asynchronously and can leave a partial last line)
    p = os.path.join(out, f)
    if not os.path.exists(p): return []
    with open(p) as fh:
        return [r for r in list(csv.reader(fh))[1:] if len(r) == n and all(r[:1])]

meta_p = os.path.join(out, "meta.txt")
if not os.path.exists(meta_p):
    sys.exit("analyze: no meta.txt in %s — wrong outdir?" % out)
tier = "quick"
maxr = 262143328850.0
for line in open(meta_p):
    if line.startswith("tier="): tier = line.strip().split("=", 1)[1]
    if line.startswith("rapl_max_range="):
        v = line.strip().split("=", 1)[1]
        if v: maxr = float(v)

S = [dict(zip("variant block visit phase epoch volt curr watts cap status dgpu".split(), r))
     for r in rows("samples.csv", 11)]
for s in S:
    s["epoch"], s["watts"] = float(s["epoch"]), float(s["watts"])

def med(xs): return st.median(xs) if xs else float("nan")
def mad(xs):
    if len(xs) < 2: return 0.0
    m = med(xs)
    return med([abs(x - m) for x in xs])

# ---- idle visits: per-visit median, then delta vs bracketing-A interpolation
visits = {}   # visit -> dict
for s in S:
    if s["phase"] != "idle": continue
    v = visits.setdefault(int(s["visit"]), dict(
        variant=s["variant"], block=int(s["block"]), w=[], t=[], bad=0))
    v["w"].append(s["watts"]); v["t"].append(s["epoch"])
    if s["status"] != "Discharging" or s["dgpu"] != "suspended": v["bad"] += 1

lines = ["# A/B power test — %s tier" % tier, ""]
lines += ["## Idle visits", "", "| visit | block | variant | median W | MAD | n | contaminated |", "|---|---|---|---|---|---|---|"]
for k in sorted(visits):
    v = visits[k]
    v["med"], v["mad"], v["mid"] = med(v["w"]), mad(v["w"]), med(v["t"])
    lines.append("| %d | %d | %s | %.3f | %.3f | %d | %d |" %
                 (k, v["block"], v["variant"], v["med"], v["mad"], len(v["w"]), v["bad"]))

deltas = {}   # variant -> [delta per block]
a_noise = []
MIN_VISIT_N = 20  # below this, a visit is ~noise (EC smoothing) — exclude
short = [k for k in visits if len(visits[k]["w"]) < MIN_VISIT_N]
for k in short:
    lines.append("\nWARN: visit %d (%s, block %d) has only %d samples — excluded from deltas"
                 % (k, visits[k]["variant"], visits[k]["block"], len(visits[k]["w"])))
usable = {k: v for k, v in visits.items() if k not in short}
for blk in sorted({v["block"] for v in usable.values()}):
    A = [usable[k] for k in sorted(usable) if usable[k]["block"] == blk and usable[k]["variant"] == "A"]
    T = [usable[k] for k in sorted(usable) if usable[k]["block"] == blk and usable[k]["variant"] != "A"]
    if len(A) < 2:
        lines.append("\nWARN: block %d lacks bracketing A visits — deltas skipped" % blk)
        continue
    a0, a1 = A[0], A[-1]
    a_noise.append(abs(a1["med"] - a0["med"]))
    span = a1["mid"] - a0["mid"] or 1.0
    for v in T:
        base = a0["med"] + (a1["med"] - a0["med"]) * (v["mid"] - a0["mid"]) / span
        deltas.setdefault(v["variant"], []).append(v["med"] - base)

# median, not max: one polluted block (e.g. a hot first visit) must not
# gate every other block's tight, sign-consistent evidence
thr = max(0.3 if tier == "quick" else 0.2, 2 * (st.median(a_noise) if a_noise else 0))
lines += ["", "## Idle delta vs stock power-saver (baseline-bracket corrected)", "",
          "decision threshold: |delta| >= %.3f W and same sign across blocks (A-repeat noise %s)" %
          (thr, ",".join("%.3f" % x for x in a_noise)),
          "", "| variant | delta W per block | median | verdict |", "|---|---|---|---|"]
for var in sorted(deltas):
    ds = deltas[var]
    m = med(ds)
    same_sign = all(d < 0 for d in ds) or all(d > 0 for d in ds)
    verdict = ("SAVES %.2f W" % -m if m < 0 else "COSTS %.2f W" % m) \
        if same_sign and abs(m) >= thr else "no meaningful difference"
    lines.append("| %s | %s | %+.3f | %s |" % (var, ", ".join("%+.3f" % d for d in ds), m, verdict))

# ---- W1 fixed-work energy
EV = {}
for var, blk, ev, t in rows("events.csv", 4):
    EV.setdefault((var, int(blk)), {})[ev] = float(t)
R = [(float(a), b, c) for a, b, c in rows("rapl.csv", 3) if b]

def rapl_j(t0, t1):
    seg = [(t, float(m)) for t, m, _ in R if t0 <= t <= t1]
    if len(seg) < 2: return float("nan")
    j, prev = 0.0, seg[0][1]
    for _, e in seg[1:]:
        d = e - prev
        if d < 0: d += maxr
        j += d; prev = e
    return j / 1e6

w1 = []
for (var, blk), ev in sorted(EV.items()):
    if "w1_start" not in ev or "w1_end" not in ev: continue
    t0, t1 = ev["w1_start"], ev["w1_end"]
    # PL1-sweep variants share D's topology but have no idle visits of their
    # own — without a baseline their integration window would be biased long
    # (fixed 30s tail) versus everyone else's detected idle-return.
    base_var = {"G8": "B", "G6": "B"}.get(var, var)  # PL1 variants share the shipped (B) topology
    idle = med([visits[k]["med"] for k in visits if visits[k]["variant"] == base_var]) if any(
        visits[k]["variant"] == base_var for k in visits) else float("nan")
    pts = sorted((s["epoch"], s["watts"]) for s in S
                 if s["variant"] == var and s["phase"] == "w1" and int(s["block"]) == blk
                 and s["status"] == "Discharging")
    # idle-return: first post-end 10s window whose mean is within 0.3W of idle
    tail_end = t1 + 30
    if idle == idle:
        win = []
        for t, w in pts:
            if t < t1: continue
            win.append((t, w)); win = [(a, b) for a, b in win if a > t - 10]
            if len(win) >= 4 and abs(sum(b for _, b in win) / len(win) - idle) <= 0.3:
                tail_end = t; break
    seg = [(t, w) for t, w in pts if t0 <= t <= tail_end]
    joules = sum((seg[i + 1][0] - seg[i][0]) * (seg[i][1] + seg[i + 1][1]) / 2
                 for i in range(len(seg) - 1)) if len(seg) > 1 else float("nan")
    marg = joules - idle * (tail_end - t0) if idle == idle else float("nan")
    w1.append((var, blk, t1 - t0, joules, marg, rapl_j(t0, tail_end)))
if w1:
    lines += ["", "## W1 fixed work (xz, byte-identical input): energy per job", "",
              "| variant | block | wall s | battery J | marginal J | RAPL pkg J |", "|---|---|---|---|---|---|"]
    for var, blk, wall, j, m, rj in w1:
        lines.append("| %s | %d | %.1f | %.0f | %.0f | %.0f |" % (var, blk, wall, j, m, rj))

# ---- W2/W3 per-phase power: fixed work (w2) / fixed rate (w3), so median W
# over the window compares fairly across variants; delta vs A's same phase.
for ph, label in (("w2", "W2 bursty-interactive (fixed chunk each 5s)"),
                  ("w3", "W3 mpv hw-decoded 1080p30 playback"),
                  ("w6", "W6 Firefox browsing (local pages: load, scroll, images, JS)"),
                  ("chhw", "W4 Chromium playing 1080p30, hw decode"),
                  ("chsw", "W4 Chromium playing 1080p30, SW decode (before-state)"),
                  ("fihw", "W5 Firefox playing 1080p30, hw decode (FF default)"),
                  ("fisw", "W5 Firefox playing 1080p30, forced SW decode")):
    per = {}
    for x in S:
        if x["phase"] == ph and x["status"] == "Discharging":
            per.setdefault(x["variant"], []).append(x["watts"])
    if not per: continue
    a_med = med(per.get("A", []))
    lines += ["", "## %s — median W over window" % label, "",
              "| variant | median W | MAD | n | delta vs A |", "|---|---|---|---|---|"]
    for var in sorted(per):
        m = med(per[var])
        d = ("%+.3f" % (m - a_med)) if a_med == a_med else "-"
        lines.append("| %s | %.3f | %.3f | %d | %s |" % (var, m, mad(per[var]), len(per[var]), d))

# ---- responsiveness
BR = {}
for var, blk, bench, val in rows("bench.csv", 4):
    try:
        BR.setdefault((var, bench), []).append(float(val))
    except ValueError:
        pass  # a dead-workload sentinel line must not kill the whole report
def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))]
benches = ["exec_ms", "pyspawn_ms", "st_chunk_ms", "hypr_ms", "wake_p50_us", "wake_p99_us"]
# media-tier extras (already percentiles/counts — shown as single medians)
for extra in ("w2_chunk_p50_ms", "w2_chunk_p95_ms", "w3_vo_drops", "w3_dec_drops",
              "chhw_gt1_mhz", "chsw_gt1_mhz", "fihw_gt1_mhz", "fisw_gt1_mhz"):
    if any(b == extra for _, b in BR): benches.append(extra)
variants = sorted({v for v, _ in BR})
if BR:
    lines += ["", "## Responsiveness (p50 / p95; wake rows are medians of per-run p50/p99)", "",
              "| variant | " + " | ".join(benches) + " |", "|" + "---|" * (len(benches) + 1)]
    P = {}
    for var in variants:
        cells = []
        for b in benches:
            xs = BR.get((var, b), [])
            if not xs: cells.append("-"); continue
            if b.startswith(("wake", "w2", "w3", "ch", "fi")):
                P[(var, b)] = med(xs); cells.append("%.0f" % med(xs))
            else:
                P[(var, b)] = pct(xs, 0.95)
                cells.append("%.1f / %.1f" % (med(xs), pct(xs, 0.95)))
        lines.append("| %s | %s |" % (var, " | ".join(cells)))
    # lag budget vs A
    if any(v == "A" for v in variants):
        lines += ["", "## Lag budget vs stock power-saver (pass = pyspawn p95 <= 2x A, wake p99 <= 1.5x A)", ""]
        for var in variants:
            if var == "A": continue
            checks = []
            ok, complete = True, True
            for b, lim in (("pyspawn_ms", 2.0), ("wake_p99_us", 1.5)):
                a, x = P.get(("A", b)), P.get((var, b))
                if a is not None and x is not None and a > 0:
                    r = x / a
                    checks.append("%s %.1fx" % (b, r))
                    ok &= r <= lim
                else:
                    checks.append("%s MISSING" % b)
                    complete = False
            verdict = ("PASS" if ok else "FAIL") if complete else "INCOMPLETE"
            lines.append("- %s: %s -> %s" % (var, ", ".join(checks), verdict))

# ---- recommendation
lines += ["", "## Recommendation inputs",
          "- winner rule: lowest idle-power variant that passes the lag budget.",
          "- verify sign-consistency and threshold above before shipping a default."]
report = "\n".join(lines) + "\n"
open(os.path.join(out, "summary.md"), "w").write(report)
print(report)
PY
}

if [[ $TIER == analyze ]]; then
  OUT="${2:?analyze needs an outdir}"
  run_analyze
  exit $?
fi

# ---------------------------------------------------------------- preflight
mkdir -p "$OUT"
note "== power-mode-ab-test ($TIER) -> $OUT"

[[ $("$SPS" status) == off && ! -f $STATE_FILE && ! -f $RUN_STATE ]] ||
  { note "ABORT: mode must be OFF with no state files ('$SPS' off; retry)"; exit 1; }

# Tools the selected tier will actually invoke — a missing binary must abort
# NOW, not 40 minutes into an unrepeatable battery window as a dead workload
# silently mislabeled as measurement.
NEED="python3 awk"
((${#W1_VARIANTS[@]})) && NEED+=" xz"
if ((${#REALUSE_VARIANTS[@]})) || [[ $BROWSER_PHASE == 1 ]]; then
  NEED+=" ffmpeg mpv firefox"
fi
[[ $BROWSER_PHASE == 1 ]] && NEED+=" chromium"
for tool in $NEED; do
  command -v "$tool" >/dev/null || { note "ABORT: missing tool: $tool"; exit 1; }
done

# The installed root helper must understand the topology conf keys, or every
# super "variant" would silently measure the same shipped default.
grep -q SPS_ONLINE_CPUS /usr/local/bin/omarchy-super-power-saver-helper 2>/dev/null ||
  { note "ABORT: installed helper predates SPS_ONLINE_CPUS — re-run: sudo $HOME/.local/bin/omarchy-super-power-saver-setup"; exit 1; }

if [[ $TIER != smoke ]]; then
  [[ $(cat "$B/status") == Discharging ]] || { note "ABORT: unplug AC first"; exit 1; }
  [[ $(cat "$B/capacity") -ge $SOC_FLOOR ]] ||
    { note "ABORT: battery $(cat "$B/capacity")% < ${SOC_FLOOR}% floor for $TIER tier"; exit 1; }
  # pgrep without -f matches the 15-char comm only — packaged Electron apps
  # never have comm "electron" (slack, Discord, signal-desktop...), so name
  # the common ones and add one -f pass for anything launched via electron.
  if [[ -z ${SPS_AB_FORCE:-} ]] &&
    { pgrep -ia 'firefox|chromium|chrome|brave|vivaldi|slack|discord|signal-desktop|spotify|teams' >/dev/null 2>&1 ||
      pgrep -fia 'electron' >/dev/null 2>&1; }; then
    note "ABORT: close browsers/electron apps first (tab timers ruin idle measurements);"
    note "       SPS_AB_FORCE=1 to override"
    exit 1
  fi
fi

sudo -v || { note "ABORT: sudo needed (conf writes + RAPL energy sampler)"; exit 1; }

# initial state, all restore-relevant, recorded BEFORE any change
INIT_PROFILE=$(powerprofilesctl get 2>/dev/null)
INIT_HYPRIDLE=$(pgrep -x hypridle >/dev/null && echo yes || echo no)
INIT_BRIGHTNESS=$(cat /sys/class/backlight/intel_backlight/brightness 2>/dev/null)

# The traps are armed BEFORE the first mutation (keepalive, hypridle kill,
# timer stops): an INT/TERM in the setup window must restore what was already
# changed, not leak a timestamp-refreshing sudo loop and stopped timers.
RAPL_PID="" SUDO_KEEPALIVE="" CONF_BACKED="" STOPPED_TIMERS=""
LOAD_PIDS=()
cleanup() {
  local t
  trap - EXIT INT TERM
  "$SPS" off >/dev/null 2>&1
  if [[ -n ${LOAD_PIDS[*]:-} ]]; then
    # a load may be SIGSTOPped (sensor characterization) — CONT first or the
    # TERM stays pending on a stopped process forever
    kill -CONT "${LOAD_PIDS[@]}" 2>/dev/null
    kill "${LOAD_PIDS[@]}" 2>/dev/null
  fi
  # the RAPL sampler is a ROOT process: a plain kill is EPERM. Belt: sudo
  # kill; braces: its loop self-exits within 2s of this script's pid dying.
  [[ -n $RAPL_PID ]] && sudo -n kill "$RAPL_PID" 2>/dev/null
  if [[ $CONF_BACKED == yes ]]; then
    sudo -n cp "$OUT/conf.orig" "$CONF"
    sudo -n chmod 644 "$CONF"
  else
    sudo -n rm -f "$CONF"
  fi
  [[ -n $INIT_PROFILE ]] && powerprofilesctl set "$INIT_PROFILE" 2>/dev/null
  for t in $STOPPED_TIMERS; do sudo -n systemctl start "$t" 2>/dev/null; done
  if [[ $INIT_HYPRIDLE == yes ]] && ! pgrep -x hypridle >/dev/null; then
    setsid uwsm-app -- hypridle >/dev/null 2>&1 &
  fi
  [[ -n $INIT_BRIGHTNESS ]] &&
    brightnessctl -d intel_backlight set "$INIT_BRIGHTNESS" >/dev/null 2>&1
  [[ -n $SUDO_KEEPALIVE ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null
  rm -f "$WORK_FILE" "$WORK_FILE.pool" "$VIDEO_FILE" "$VIDEO_HTML" "$OUT/mpv-ipc.sock"
  rm -rf "$BROWSE_DIR"
  notify-send -u normal "A/B power test finished" \
    "Settings restored. Results: $OUT/summary.md" 2>/dev/null
  echo "restored; results in $OUT"
}
trap cleanup EXIT
trap 'exit 129' INT TERM

(while sleep 50; do kill -0 $$ 2>/dev/null || exit; sudo -nv 2>/dev/null || exit; done) &
SUDO_KEEPALIVE=$!
# hypridle listens on Wayland idle-notify (systemd-inhibit can't stop it) and
# fires the screensaver at 150s idle — mid-run that's a massive power+redraw
# contaminant. Killed for the whole run, restarted by the trap.
pkill -x hypridle 2>/dev/null
if sudo -n test -f "$CONF"; then
  sudo -n cp "$CONF" "$OUT/conf.orig"
  CONF_BACKED=yes
fi
for t in $TIMER_CANDIDATES; do
  if systemctl is-active --quiet "$t" 2>/dev/null; then
    sudo -n systemctl stop "$t" && STOPPED_TIMERS+="$t "
  fi
done

{
  echo "tier=$TIER"
  echo "start=$(date -Is)"
  echo "init_profile=$INIT_PROFILE hypridle=$INIT_HYPRIDLE brightness=$INIT_BRIGHTNESS"
  echo "stopped_timers=$STOPPED_TIMERS"
  echo "conf_backed_up=${CONF_BACKED:-no}"
  echo "kernel=$(uname -r) capacity=$(cat "$B/capacity")%"
  echo "charge_full=$(cat "$B/charge_full" 2>/dev/null) cycle_count=$(cat "$B/cycle_count" 2>/dev/null)"
  echo "usb_snapshot=$(lsusb 2>/dev/null | sha256sum | cut -c1-16)"
  echo "wifi=$(iwctl station wlan0 show 2>/dev/null | awk '/Connected network/{print $3}')"
  echo "rapl_max_range=$(sudo -n cat $RAPL_MSR/max_energy_range_uj 2>/dev/null)"
  echo "claude_code_note=an idle Claude Code session may be running in a terminal — constant across variants"
} >>"$META"

if [[ $TIER == smoke ]]; then
  run_smoke
  if [[ $FAIL == 0 ]]; then note "== SMOKE PASS"; else
    note "== SMOKE FAIL"
    exit 1
  fi
  exit 0
fi

# ------------------------------------------------------- measurement runs
echo "variant,block,visit,phase,epoch,volt_uv,curr_ua,watts,capacity,status,dgpu" >"$CSV"
echo "variant,block,bench,value" >"$BENCH_CSV"
echo "variant,block,event,epoch" >"$EVENTS"
echo "epoch,msr_uj,mmio_uj" >"$RAPL_CSV"

# one long-lived ROOT sampler for RAPL energy (root-only files; per-sample
# sudo would write an auth journal line every 2s = periodic disk wakes).
# Self-terminating: it checks this script's pid every tick, because the
# user-side cleanup cannot signal a root process without sudo.
sudo -n bash -c "while kill -0 $$ 2>/dev/null; do echo \"\$(date +%s.%N),\$(cat $RAPL_MSR/energy_uj),\$(cat $RAPL_MMIO/energy_uj)\"; sleep 2; done" >>"$RAPL_CSV" &
RAPL_PID=$!

if ((${#REALUSE_VARIANTS[@]})) || [[ $BROWSER_PHASE == 1 ]]; then
  # 60s of encoded 1080p30 (looped by mpv). Synthetic content, but identical
  # bits for every variant — and it exercises the real hw-decode path (gt1).
  note "generating test video (one-time, ~30s)"
  if ! ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1920x1080:rate=30 \
    -t 60 -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "$VIDEO_FILE"; then
    note "ABORT: ffmpeg could not generate $VIDEO_FILE"
    exit 1
  fi
  cat >"$VIDEO_HTML" <<HTML
<!doctype html><title>sps-ab</title>
<body style="margin:0;background:#000">
<video autoplay loop muted playsinline src="file://$VIDEO_FILE"
       style="width:100vw;height:100vh;object-fit:contain"></video>
HTML
  # deterministic browse chain: 8 pages x ~150KB text + inline SVG images + JS
  note "generating browse pages"
  mkdir -p "$BROWSE_DIR"
  python3 - "$BROWSE_DIR" <<'PY'
import random, sys
out = sys.argv[1]
random.seed(7)  # SAME bytes on every generation — comparable across runs
words = ("power efficiency measurement laptop battery core island race idle "
         "scheduler browser render compositor frame decode media engine test "
         "variant baseline topology watt joule latency scroll page load").split()
def para():
    return " ".join(random.choice(words) for _ in range(random.randint(40, 90)))
def svg(i):
    r = random.Random(i)
    rects = "".join(
        f'<rect x="{r.randint(0,560)}" y="{r.randint(0,140)}" width="{r.randint(20,120)}" '
        f'height="{r.randint(20,80)}" fill="hsl({r.randint(0,359)},60%,55%)"/>'
        for _ in range(24))
    return f'<svg viewBox="0 0 640 200" style="width:100%;height:auto">{rects}</svg>'
N = 8
for i in range(N):
    nxt = (i + 1) % N
    body = "".join(
        f"<h2>Section {j}</h2>{svg(i*37+j)}<p>{para()}</p><p>{para()}</p>"
        for j in range(28))
    html = f"""<!doctype html><title>sps-ab browse {i}</title>
<meta charset="utf-8">
<body style="max-width:52rem;margin:0 auto;font:16px/1.6 sans-serif;padding:1rem">
<h1>Page {i}</h1>{body}
<script>
// self-driving reader: smooth-scroll to the bottom, pause, next page
let y = 0;
const step = () => {{
  y += 120; window.scrollTo({{top: y, behavior: "smooth"}});
  if (y < document.body.scrollHeight - innerHeight)
    setTimeout(step, 300);
  else
    setTimeout(() => location.replace("page{nxt}.html"), 8000);
}};
setTimeout(step, 3000);
</script>"""
    open(f"{out}/page{i}.html", "w").write(html)
print("browse pages ready")
PY
fi

if ((${#W1_VARIANTS[@]})); then
# EC sensor characterization (informational; analyze sanity-checks with it):
# 20s quiet + 25s of 1-core load + 20s release, 4Hz current_now sampling.
note "characterizing battery sensor (~65s)"
{
  echo "--- sensor characterization $(date +%T)"
  yes >/dev/null &
  CHAR_PID=$!
  LOAD_PIDS+=("$CHAR_PID") # cleanup CONTs+kills it if we die while it's STOPped
  kill -STOP "$CHAR_PID"
  for phase in quiet load release; do
    [[ $phase == load ]] && kill -CONT "$CHAR_PID"
    [[ $phase == release ]] && kill -STOP "$CHAR_PID"
    n=80
    [[ $phase == load ]] && n=100
    for ((s = 0; s < n; s++)); do
      echo "char,$phase,$(date +%s.%N),$(cat "$B/current_now")"
      sleep 0.25
    done
  done
  kill -CONT "$CHAR_PID" 2>/dev/null
  kill "$CHAR_PID" 2>/dev/null
  LOAD_PIDS=()
} >>"$META" 2>/dev/null

# fixed-work file + xz calibration (sized so the slowest variant ~ 2 min)
note "generating workload + calibrating xz"
head -c $((256 * 1024 * 1024)) /dev/urandom >"$WORK_FILE.pool"
T0=$EPOCHREALTIME
head -c $((8 * 1024 * 1024)) "$WORK_FILE.pool" | xz -6 -T1 >/dev/null
T1=$EPOCHREALTIME
# target ~40s at current (mode-off) speed => ~2-3x that on the slowest variant
W1_MB=$(awk -v a="$T0" -v b="$T1" 'BEGIN{t=(b-a); mb=int(8*40/t); if(mb<24)mb=24; if(mb>256)mb=256; print mb}')
head -c $((W1_MB * 1024 * 1024)) "$WORK_FILE.pool" >"$WORK_FILE"
rm -f "$WORK_FILE.pool"
echo "w1_size_mb=$W1_MB xz_8mb_s=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.1f", b-a}')" >>"$META"
fi # W1_VARIANTS non-empty

EST=$((IDLE_BLOCKS * (2 + ${#IDLE_VARIANTS[@]}) * 4 + ${#W1_VARIANTS[@]} * 5))
((${#REALUSE_VARIANTS[@]})) && EST=$((EST + (2 + ${#REALUSE_VARIANTS[@]}) * 13))
[[ $BROWSER_PHASE == 1 ]] && EST=$((EST + 16))
# -u normal, NOT critical: mako pins critical notifications until dismissed —
# a popup that vanishes at an unknown time mid-run would change what PSR sees.
notify-send -u normal -t 15000 "A/B power test started (~${EST} min)" \
  "DON'T touch the laptop, keyboard, or AC until the done notification." 2>/dev/null
note "measuring — hands off the machine (~${EST} min); tail -f '$LOG' from another machine if needed"
sleep 20 # notification gone + screen static before anything is measured

# From here on: NO terminal output (screen must stay static) — log file only.
exec >>"$LOG" 2>&1

kill_run() {
  log "ABORT: $1"
  exit 1
}

for ((blk = 1; blk <= IDLE_BLOCKS; blk++)); do
  mapfile -t shuffled < <(printf '%s\n' "${IDLE_VARIANTS[@]}" | shuf)
  log "idle block $blk order: A $(for v in "${shuffled[@]}"; do printf '%s ' "${v%%|*}"; done)A"
  for v in "$V_A" "${shuffled[@]}" "$V_A"; do
    VISIT=$((VISIT + 1))
    apply_variant "$v" || kill_run "apply failed for ${v%%|*}"
    snapshot_meta "idle-visit ${v%%|*}"
    sample_loop "$CUR" "$blk" idle 60 || kill_run "AC during idle visit"
    bench "$CUR" "$blk"
  done
done

if ((${#REALUSE_VARIANTS[@]})); then
  # Real-use bracket block: its 50-sample idle anchors feed the same idle-
  # delta analysis as the idle blocks (one more block of sign evidence).
  blk=$((IDLE_BLOCKS + 1))
  mapfile -t shuffled < <(printf '%s\n' "${REALUSE_VARIANTS[@]}" | shuf)
  log "real-use block order: A $(for v in "${shuffled[@]}"; do printf '%s ' "${v%%|*}"; done)A"
  for v in "$V_A" "${shuffled[@]}" "$V_A"; do
    VISIT=$((VISIT + 1))
    apply_variant "$v" || kill_run "apply failed for ${v%%|*}"
    snapshot_meta "realuse-visit ${v%%|*}"
    sample_loop "$CUR" "$blk" idle 50 || kill_run "AC during idle anchor"
    bench "$CUR" "$blk"
    w2_run "$CUR" "$blk" || kill_run "w2 aborted for ${v%%|*}"
    w3_run "$CUR" "$blk" || kill_run "w3 aborted for ${v%%|*}"
    w6_run "$CUR" "$blk" || kill_run "w6 aborted for ${v%%|*}"
  done
fi

if [[ $BROWSER_PHASE == 1 ]]; then
  log "browser phase (on shipped default D): hw vs sw decode, both browsers"
  apply_variant "$V_D" || kill_run "apply failed for D (browser phase)"
  snapshot_meta "browser D"
  for spec in chromium:hw chromium:sw firefox:hw firefox:sw; do
    browser_run "D" 1 "${spec%%:*}" "${spec##*:}" ||
      kill_run "browser run aborted (${spec})"
  done
fi

if ((${#W1_VARIANTS[@]})); then
  log "W1 phase"
  mapfile -t w1shuffled < <(printf '%s\n' "${W1_VARIANTS[@]}" | shuf)
  for v in "${w1shuffled[@]}"; do
    apply_variant "$v" || kill_run "apply failed for ${v%%|*} (w1)"
    snapshot_meta "w1 ${v%%|*}"
    w1_run "$CUR" 1 || kill_run "w1 aborted for ${v%%|*}"
  done
fi

"$SPS" off >/dev/null 2>&1
echo "end=$(date -Is) capacity=$(cat "$B/capacity")%" >>"$META"
run_analyze
log "DONE"
