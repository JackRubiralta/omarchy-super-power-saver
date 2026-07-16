# Power menu: visible "active" marker + 4th mode "Super Power Saver"

**Added:** 2026-07-07 · Dell Pro Max 14 Premium (Core Ultra 9 285H + RTX PRO 2000) · Omarchy/Hyprland 0.55.2 · walker 2.16.2
**Status:** installed and working. Root setup (`sudo ~/.local/bin/omarchy-super-power-saver-setup`)
run 2026-07-07 21:51 — helper + sudoers + udev rule verified in place. NOTE: sudo
doesn't search ~/.local/bin (secure_path), always call the setup by full path.

## How to use

- Menu: Super key menu → Setup → Power Profile → pick a mode. The active mode is
  highlighted (accent color + tinted background + bold — no ✓, removed by request).
- CLI: `omarchy-super-power-saver on|off|toggle|status|boot-cleanup`
- The mode PERSISTS on AC (user preference 2026-07-08, replacing the earlier
  auto-exit): a ~30s watcher re-pins every knob, which also undoes the
  udev/ppd profile reset that AC plug/unplug events trigger. Only a manual
  off/toggle (menu or CLI) ends the mode.
- Mode changes are SILENT (user preference 2026-07-08) — the only notification
  left is the error case: root helper missing (setup not run).
- Switching between modes NEVER touches the GPU — the iGPU-only compositor change
  below is permanent/login-time, not per-mode. dGPU on demand in any mode:
  `prime-run <app>`.

## Problem 1 — active power profile not shown as selected in the menu

Omarchy's power menu already passes the active profile to walker as `-c <index>`.
Verified in walker v2.16.2 source (src/renderers/mod.rs:61-63): `-c` takes a
**1-based index** and its *only* effect is adding the CSS class `.current` to that
row — it does NOT move the cursor (the cursor always sits on row 1, which is what
made it look wrong). Omarchy's theme styles `.current` as `font-style: italic`
only — near-invisible in monospace. Upstream PR basecamp/omarchy#5165 asking for a
clearer marker was rejected ("It's using italics...").

**Fix (two layers, both update-safe):**
1. `~/.config/omarchy/extensions/menu.sh` — overrides `show_setup_power_menu`
   (sourced by omarchy-menu at the end, official extension point). Passes the
   active row as the preselect so walker tags it `.current`. (A `  ✓` suffix was
   tried first; Jack preferred highlight-only, removed 2026-07-07.)
2. `~/.config/omarchy/themes/aether/walker.css` (+ live copy in
   `~/.config/omarchy/current/theme/walker.css`) — `.current` now gets accent
   color + `alpha(@selected-text, 0.15)` background + bold. Because the theme css
   is `@import`ed at the top of the stock style.css, the stock italic rule only
   overrides `font-style`; color/background/weight survive. Re-apply after
   `omarchy theme set` of a different theme (rule lives per-theme).

## Problem 2 — 4th mode: Super Power Saver

power-profiles-daemon hardcodes exactly 3 profiles (C enum, no config for custom
ones — verified in ppd source), so the 4th mode is layered on top of power-saver:

- `~/.local/bin/omarchy-super-power-saver` (on|off|toggle|status)
- `~/.local/bin/omarchy-super-power-saver-setup` (run ONCE with sudo) installs:
  - `/usr/local/bin/omarchy-super-power-saver-helper` — root sysfs knobs
  - `/etc/sudoers.d/omarchy-super-power-saver` — NOPASSWD for exactly `helper on|off`
  - `/etc/udev/rules.d/61-igpu-dev-path.rules` — stable `/dev/dri/igpu` symlink

### What ON does (v2, 2026-07-07 — all restored on OFF)

| Layer | Action | Why |
|---|---|---|
| ppd | `powerprofilesctl set power-saver` | EPP=power on all cores; ppd 0.30 maps this to platform_profile **quiet** on this Dell (verified — quiet is Dell's real low-power mode; "cool" raises fans) |
| root | **thermald stopped** while active | in --adaptive mode thermald raises the MSR RAPL limit (defeating our cap; hardware enforces min(MSR,MMIO)). Safe at 10W: TjMax/PROCHOT protection is hardware. Restarted on OFF |
| root | RAPL PL1=10W **tau=8s** / PL2=**15W** in **both** `intel-rapl:0` and `intel-rapl-mmio:0` | min(MSR,MMIO) governs. Short tau fixes the measured slow 23→15W burst convergence (old window 28s). Watcher re-asserts every ~30s (throttled-project precedent — EC rewrites MMIO on profile changes) |
| root | EPB=15 all cpus | package-controller powersave hint, additive to EPP |
| root | **uncore freq capped to floor** (400MHz, `intel_uncore_frequency`) | ring/fabric power is a big slice at light load — biggest untapped lever per research |
| root | **P-cores 1-5 offlined** (cpu0 stays) | ~0.5-0.7W light-load saving measured on comparable hw (Framework 13); ChromeOS battery saver does the same. Idle cores in C-states cost ~0, so this only helps by consolidating work |
| root | **iGPU (gt0+gt1) max+boost capped to RP1=800MHz** | efficient frequency; never below RPn (worse perf/W). ~0 idle, 0.3-1W during scroll/animations |
| root | `pcie_aspm=`**`powersupersave`**, `nmi_watchdog=0`, `dirty_writeback=6000`, `laptop_mode=5` | L1.2 substates are a PRECONDITION for deep package C-states (PC10/S0ix — was ~0s residency!); 2025+ consensus (Framework et al.) is powersupersave is safe on Core Ultra; per-device opt-out exists at `.../link/l1_2_aspm` if something gets flaky |
| user | **bluetooth rfkill block** (previous state restored) | ~0.1-0.3W; no BT devices in use on this machine |
| user | animations/blur/shadows off via `~/.local/state/omarchy/toggles/hypr/super-power-saver.conf` + `hyprctl reload` | toggles dir is sourced LAST by hyprland.conf so it survives other reloads. hyprlang needs multi-line blocks — one-line `animations { enabled = 0 }` is silently ignored! |
| user | `omarchy-wifi-powersave on` | |
| user | transient user unit `omarchy-super-power-saver-watch`: polls AC every 15s → auto `off`; every ~30s `sudo helper reassert` (RAPL re-pin + re-stop thermald) | mirrors omarchy's udev AC behavior + protects caps from EC/thermald |

**Removed in v2 (measurement-driven):** screen brightness dim (<1W on this panel,
isolated A/B) and `no_turbo=1`/`max_perf_pct=50` (measured WORSE at fixed light
load — race-to-idle wins; TLP/ChromeOS/Windows all avoid turbo-off and use
EPP+power caps instead, which we do via RAPL).

### v3 (2026-07-08) — browsing/YouTube focus + audited mode-scoping

Changes (helper v3 + user script, installed via re-running setup):
- **Media-GT fix:** gt1 (video decode engine) is no longer capped — its fused
  RP1=RPn=100MHz meant v2's "cap to RP1" pinned the decoder 13x below its
  1300MHz operating point. Only gt0 (render) is capped, to 800 (= its floor).
- **PSR2 assert** (debugfs `i915_edp_psr_debug`=2, conditional) on apply + each
  ~30s reassert — also heals the documented DPMS-wake PSR2→PSR1 downgrade.
  Runtime-only; kernel-param PSR/DC changes (`/etc/modprobe.d/i915-powersave.conf`
  with `enable_dc=4 enable_fbc=1`) are GATED on a 2-3 day low-brightness flicker
  soak (this Dell class has documented PSR flicker reports).
- **Fingerprint sensor** (Synaptics 06cb:0701) autosuspend while mode on, by
  USB ID; global usbcore autosuspend=-1 policy untouched.
- **`diag` subcommand** (sudoers now on|off|reassert|diag): PSR/DC status, RAPL,
  GT freqs, S0ix/pmc_core substates + LTR (for chasing the S0ix=0 blocker),
  fingerprint state, turbostat if installed.
- ~~Screensaver disabled while mode on~~ and ~~hypridle 330s screen-off~~ —
  both REMOVED 2026-07-08 per Jack: the screensaver and idle-lock chain stay
  100% stock in every mode including super saver. hypridle.conf is back to its
  pre-project content. (Cost: the animated screensaver defeats PSR/RC6 when
  idle-unattended in super mode — accepted trade-off for unchanged behavior.)
- Setup now also installs intel-gpu-tools/libva-utils/nvme-cli and caches stock
  RAPL values to `/etc/omarchy-super-power-saver.defaults` (used by the
  helper's no-state fallback restore).

Mode-scoping guarantee (user requirement; adversarially audited 2026-07-08):
- Everything the mode changes is restored on off — including across reboots:
  BT rfkill / screensaver flag / hypr effects conf persist on disk, so `off`
  restores them even from a stale state file, and `boot-cleanup` (hypr
  autostart) handles reboots that happened while the mode was on.
- Audit fixes: AC-plug auto-exit no longer kills itself mid-restore (the
  watcher's `off` now runs as a detached unit + do_off skips stop_watcher for
  ac-auto); manual off restores the profile you had before on (prev_profile in
  state); RAPL `enabled` flags and per-GT freqs are saved/restored exactly;
  `off` when already off is a guarded no-op.
- Global-but-invisible (kept, identical in all modes): Chromium VAAPI flags
  (also fixed omarchy's split --enable-features lines silently dropping
  features — Chromium takes the LAST line only), mpv hwdec/dmabuf-wayland.
- Reverted after scoping review (would have changed other modes): Firefox
  user.js prefs (kept as comments), GTK caret blink, waybar intervals.
  enhanced-h264ify extension NOT installed (would cap YT at 1080p globally) —
  optional manual install if wanted.

**v2 verification targets:** `/sys/devices/system/cpu/cpuidle/low_power_idle_system_residency_us`
(S0ix; was ~0 — should start advancing at idle with ASPM L1.2), burst draw should
pin at ~10-12W quickly (short tau), light load should drop below balanced's 4.5W.
(v4 note: `low_power_idle_system_residency_us` counts SLP_S0 assertion, which
effectively needs display-off s2idle — 0 with screen on is EXPECTED, not a bug.
The correct screen-on target is package C10: `turbostat --show Pkg%pc10`.)

### v4 (2026-07-08) — LP-E island consolidation, invisible-only knobs

> Superseded detail: v4 pinned slices/IRQs to `14-15`/mask `c000`; since
> v4.2 the shipped default is `0,14-15`/mask `c001` (measured winner).

Research-driven upgrade (5-agent web research + live sysfs recon + design
review). New constraints honored: **no reboot** ever needed to toggle, **UI
identical in all modes** (the v3 animations/blur/shadows kill is REMOVED — off
still cleans a legacy toggle file), everything runtime-revertible.

New knobs (root helper v4; all saved→applied→exactly restored, reassert-idempotent):

| Knob | Action | Why / expected |
|---|---|---|
| **LP-E consolidation** | E-cores cpu6-13 offlined too (P 1-5 already were; cpu0 not hotpluggable) + `user/system/machine.slice` runtime-pinned to `AllowedCPUs=14-15` | userspace runs on the LP-E island (SoC tile); the compute tile stops lighting up for background noise. Biggest lever, est. 0.3–1W |
| **IRQ steering** | all non-managed IRQs + `default_smp_affinity` → cpu14-15 (mask c000); nvme managed IRQs EIO-skip; **dGPU 01:00.0/.1 IRQs never touched** | IRQs stop waking the compute tile; prior art: intel-lpmd, MTL measurements (PC2 0.27%→9.3%) |
| **GPU SLPC profile** | `gt0+gt1 slpc_power_profile=power_saving` | kills waitboost (which bypassed the gt0 800MHz cap); gt1 freq RANGE untouched (fused RP1=100 gotcha) |
| **RAPL PL4** | constraint_2 → 25W in MSR+MMIO (stock 205W; never write 0) | free spike clamp |
| **Audio** | `snd_hda_intel power_save` 10s→1s | ~0.1W when audio idle |
| **Snapper** | `snapper-timeline.timer` stopped while on (restarted iff was active) | hourly CPU+NVMe bursts can't wreck long idle |
| **A/B knobs (default OFF)** | `/etc/omarchy-super-power-saver.conf` (root:root 644): `SPS_CPUIDLE_GOV=teo`, `SPS_PL1_UW=7000000`, `SPS_PL2_UW=10000000` | only sourced if root-owned & not group/other-writable (feeds a root shell); toggle off→on to apply |

Engineering changes:
- **Watcher v4**: the 30s `sudo helper reassert` loop is gone. A 60s loop reads
  user-readable sysfs only (cpu0 EPP, platform_profile, **MSR** PL1 —
  authoritative, the Dell EC only rewrites MMIO — cpu6 online, AC online
  fingerprint) and escalates to sudo only on drift or AC transition.
  Expectations are the OBSERVED post-apply values (`watch_pl1`, `watch_cpu6`
  in the state file) so a version-skewed helper or a PL1 A/B variant can't
  cause a reassert storm. Runs as `omarchy-super-power-saver watch-loop`
  inside the transient unit.
- **flock serialization**: helper on/off/reassert take a lock on
  `/run/omarchy-super-power-saver.lock`; reassert re-checks the state file
  after acquiring (an in-flight reassert racing `off` would re-pin everything
  after restore).
- **Unconditional stock resets** (the no_turbo lesson, extended): on ANY off —
  even with a v3-era or lost state file — cpu1-13 re-onlined, `AllowedCPUs=`
  reset (+ drop-in removal fallback if the empty assignment didn't take), IRQs
  swept to the cached stock mask, slpc→base, snd→10, governor→menu. All stock
  values are verified constants that nothing else manages.
- **Ordering** (the hard part): ON = save-everything-first → …v3 knobs… →
  cgroup pin → IRQ steer → offline (tasks migrate while all CPUs online; IRQ
  masks already on LP-E when hotplug runs → zero churn; cgroup v2 cpuset is
  declarative so effective sets recompute cleanly). OFF = cgroup unpin FIRST
  (restore escapes the 2×2.5GHz confinement) → re-online → IRQ restore (saved
  masks referencing offline CPUs would EINVAL; kernel revives managed nvme
  queues on re-online first) → the rest. The keyless-IRQ sweep closes the one
  real leak: an IRQ allocated while on inherits the LP default mask and has no
  saved key.
- `w()` refuses empty values (v3 wrote blank lines on cross-version restore);
  `wv()` readback-verifies RAPL/online writes and logs drift to
  `/run/omarchy-super-power-saver.drift` (shown in `diag`; MMIO entries are
  expected EC behavior).
- `apply()` never re-snapshots over an existing /run baseline (double `on`
  would have captured mode values as "stock").
- `diag` extended: IRQ pin counts, slice AllowedCPUs + effective cpuset, SLPC
  profiles, PL4, snapper/thermald, cpuidle governor, drift log, `CPU%LPI` in
  the turbostat line. Setup now also installs `linux-tools` (turbostat).

Verification tooling:
- `power-mode-test-data/power-mode-scope-test.sh` — scope-exactness test:
  snapshots ~50 knobs (sysfs, systemd slices, IRQ table hash, hyprctl
  animation options), toggles on (sanity asserts: cpus_online=0,14-15,
  cpuset=14-15, slpc=[power_saving], PL4=25W, snapper inactive, animations
  UNCHANGED), toggles off, diffs pre vs post — must be byte-identical. Run
  with mode off; don't plug/unplug AC or USB mid-run.

**v4.1 hardening (2026-07-08, 38-agent adversarial review: 29 confirmed / 4
refuted, all fixed):** the big ones — (1) `off` with a lost user-side state
file was a no-op while every root knob stayed applied; `off`/the watcher now
fall back to the root `/run` state (and the watcher hands reconciliation to a
DETACHED unit — running `off` in its own process would kill itself mid-restore,
the v3 bug class). (2) No user-side locking: a double-tap toggle could apply
knobs while status read off; mutating verbs now flock `$STATE_DIR/.lock`.
(3) Snapshots are atomic + sentinel-validated; a truncated `/run` state is
never trusted (apply re-saves, restore takes the defaults branch, `on` ABORTS
if even the snapshot fails — never mutate without a baseline). (4) Every
restore key now falls back saved → cached default → hardware-derived stock;
missing keys can no longer mean "leave it applied" (incl. snapper/thermald
restart, RAPL enabled bits, fp control). (5) Watcher expectations re-observed
after each successful reassert (conf changes between on/reassert stormed);
reassert exits 3 on missing state so callers reconcile instead of retrying
forever. (6) Helper `off` failure keeps the state file + one critical
notification (silent-rule exception) so retry works. (7) Setup replaces the
helper via atomic rename (an in-place rewrite corrupts a RUNNING helper
mid-parse) and refuses to cache "stock" defaults while either half of the mode
is on. (8) `flock -w 20` + `timeout`/`--no-block` on all systemd/D-Bus calls —
one wedged call can't silently queue every later on/off. (9) prev-profile
restore now keyed on AC state unchanged since `on` (was: never restored on
AC); wifi powersave restored from snapshot, not the AC heuristic. (10) Stale
(pre-reboot) `off` no longer fires the helper's no-state sledgehammer at a
freshly-booted stock system; orphaned legacy hypr toggles get cleaned +
reloaded from every path (on/off/boot-cleanup).

Rejected after research (so nobody re-tries them): PCI runtime-PM sweep for
the remaining `control=on` devices (verified no-op — those drivers have no
runtime-suspend callbacks: nvme, ISH, proc_thermal, CNVi wifi), NVMe APST
tuning (100ms default already admits the deepest state), refresh-rate/VRR
(panel is 60Hz-only, no vrr_capable), Panel Replay force (AUX-less-ALPM gate
fails), xe driver switch (same display code, breaks AQ_DRM_DEVICES), waybar
SIGSTOP / terminal cursor-blink-off / cursor inactive_timeout (visible UX —
excluded by the all-modes-identical rule), iwlwifi power_save=Y module reload
(5-10s wifi drop per toggle), i915 enable_dc=4/enable_fbc (reboot-scoped;
DC5/DC6 already reached at defaults — 2412 DC5→DC6 transitions in diag).

State: `~/.local/state/omarchy-super-power-saver/state` (has boot_id → stale
state after reboot is auto-detected; sysfs resets at boot anyway; root helper
state in /run). Deliberately untouched: keyboard backlight (see
dell-kbd-backlight-always-on.md), USB autosuspend (disabled system-wide via
/etc/modprobe.d on purpose), audio power_save (already 10/Y).

## Problem 3 — NVIDIA dGPU and battery (side findings)

- RTD3 fine-grained **already works** (nvidia-open 610, DynamicPowerManagement=3
  default): `runtime_status=suspended`, "Video Memory: Off" even with Hyprland
  holding /dev/nvidia0. **Never check with nvidia-smi — it wakes the GPU
  (~9.9W for ~20-25s).** Safe checks:
  `cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status` and
  `cat /proc/driver/nvidia/gpus/0000:01:00.0/power`.
- `~/.config/uwsm/env-hyprland` now sets `AQ_DRM_DEVICES=/dev/dri/igpu`
  (guarded on symlink existing; effective next login) so Aquamarine never opens
  the dGPU as KMS device. As of 2026-07-07 22:00 the current session predates
  this (Hyprland from 20:36 still holds /dev/nvidia0 — harmless, GPU suspends
  anyway); takes effect on next logout/login. Safe here: ALL physical connectors
  (eDP-1, HDMI-A-1, DP-3..6) are on the Intel card (00:02.0); nvidia card1 only
  exposes disconnected DP-1/DP-2. Test each physical port once after relogin; if
  one is dead, use `AQ_DRM_DEVICES=/dev/dri/igpu:/dev/dri/card1`. Revert:
  comment the export, relogin.
- `~/.config/hypr/envs.conf` (LIBVA_DRIVER_NAME=nvidia etc.) was **never
  sourced** by hyprland.conf — the dGPU-forcing lines were inert; removed so a
  future sourcing change can't silently kill battery. dGPU on demand:
  `prime-run <app>`.
- If >200MB VRAM stays allocated by some app, GPU won't fully suspend
  (`NVreg_DynamicPowerManagementVideoMemoryThreshold`); find culprits with
  `sudo lsof +c0 /dev/nvidia*` (safe, doesn't wake it).
- Nuclear option (0W guaranteed, reboot each way): `omarchy-toggle-hybrid-gpu`
  → Integrated (supergfxd; targets Asus-style hybrids — untested on this Dell).

## Measured power draw & runtime (2026-07-07, on battery, dGPU suspended)

Battery: 72Wh label = 70.3Wh design = **67.6Wh actual** (96% health, 135 cycles;
verified vs Dell manual + sysfs). Runtime = 67.6Wh × 0.96 reserve ÷ mean W.
Protocol: per mode 60s settle → 180s idle sampling → 90s fixed-work light load
(2×74MB/s sha256, ≈ light browsing) → 20s all-core burst; hypridle paused,
machine untouched; EC refreshes battery telemetry ~1Hz, sampled at 2s.

| Mode | Idle W (mean/med) | Light load W | Burst W | Runtime idle / light |
|---|---|---|---|---|
| Performance | 6.84 / 4.97 (spiky, max 24) | 6.76 | **65** | 9.5h / 9.6h |
| Balanced | 4.80 / 4.24 | 4.51 | 27 | 13.5h / 14.4h |
| Power Saver | 4.77 / 4.32 | 4.65 | 27 | 13.6h / 13.9h |
| Super Power Saver | 4.51 / 4.21 | 5.23 | 22→15 falling | 14.4h / 12.4h |

Findings:
- **Performance mode costs ~2W at idle** (turbo racing on background noise,
  spikes to 24W) → ~4h less battery for zero benefit when not loaded.
- **Dell EC uses different power tables on battery**: balanced/quiet cap the
  package at ~27W on battery (vs 70W PL1 on paper); performance unlocks 65W
  even on battery (→ ~1h runtime under sustained load!). Super's RAPL 10W cap
  was converging (23→15W across the 20s burst; tau=28s window) → sustained
  heavy load in super ≈ 11-12W ≈ 5h+ vs 1h in performance.
- **Fixed-work light load: super is slightly WORSE than balanced** (5.2 vs
  4.5W) — race-to-idle beats forced-slow (no_turbo+max_perf_pct=50) at tiny
  loads on this silicon. Super's value is idle floor + load worst-case caps.
- **Backlight is a non-lever on this panel**: isolated A/B 400 vs 100 vs 40 raw
  showed <1W delta (within noise) — literature expected 2-3.5W. Panel is
  unusually efficient; don't count screen dim as a saving here.
- Idle floor 4.2-4.8W matches the expected 3-6.5W class band; light-use 12-14h
  matches reviewers' "+5h vs OLED" estimate for the IPS panel (OLED/Windows
  reviews: 7h21m-8h29m office).
- Known risk (untested): thermald --adaptive drives intel-rapl-mmio from Dell
  DPTF tables and may rewrite super's 10W cap under sustained load; if super's
  load draw creeps to 45W, that's thermald — re-assert or stop thermald.

Raw data + test script: ./power-mode-test-data/ (580 samples, 0 not-discharging warns).

## Incidents & fixes log

- **2026-07-08 deep bug-hunt (74-agent adversarial pass, 5 confirmed / 26 refuted),
  all fixed in v3.3:**
  1. reassert only re-pinned RAPL/PSR — ppd profile rewrites (udev fires
     omarchy-powerprofiles-set on every power_supply uevent → balanced → EPB 8,
     platform balanced) could silently degrade the mode for the whole session.
     Now reassert re-pins EVERY knob via idempotent apply_knobs() with drift
     guards (profile/platform only written when changed — each platform write
     makes the EC rewrite MMIO RAPL).
  2. Same-boot re-login killed the watcher while state said "on" → no AC
     auto-exit ever again. boot-cleanup (hypr autostart) now revives the
     watcher + reasserts when mode is on but the unit is dead.
  3. Manual off after plugging AC restored the stale battery-time profile;
     now prev_profile only restores while still on battery, else stock
     omarchy-powerprofiles-set semantics.
  4. Turning the mode on while on AC caused pointless apply→auto-revert churn;
     do_on now refuses on AC with a notification.
  5. BT was rfkill-blocked before its prior state hit disk (crash window =
     permanent soft-block, systemd-rfkill persists it) — state is written
     first now.

- **2026-07-08: no_turbo/max_perf leak into all modes.** Mode was turned on
  under helper v1 (which set no_turbo=1/max_perf_pct=50 and saved them in its
  /run state), setup was re-run (v2+ helpers no longer manage those knobs),
  then off ran → the newer restore() didn't know the old keys → 50%-capped
  no-turbo CPU in every mode until noticed. Fix: helper restore() now
  UNCONDITIONALLY resets no_turbo=0 and max_perf_pct=100 (they're stock
  defaults and nothing else manages them). Lesson: on/off must be
  version-paired — after re-running setup, always toggle the mode off with the
  same helper generation that turned it on, or rely on unconditional resets.
- **2026-07-08: hypridle (idle lock) found dead twice.** Cause: restarts
  spawned from assistant tool shells die with the shell (`setsid`/`uwsm-app &`
  insufficient). Fix: `systemd-run --user --collect --unit=hypridle-session hypridle`
  — survives; omarchy's own autostart takes over at next login.

## Gotchas learned

- walker `-c` needs a 1-based index; 0 disables; it never moves the cursor.
- ppd re-applies EPP on every AC transition and profile change — layer on top of
  power-saver, never fight it. `no_turbo=1` makes ppd report
  "performance-degraded: high-operating-temperature"; harmless.
- Omarchy udev rule (99-power-profile.rules) resets the profile on every AC
  plug/unplug — super-saver's AC watcher makes that coherent (auto-exit).
- hyprctl reload reverts keyword-set options but NOT `keyword env` vars.
- `hyprctl getoption misc:vfr` doesn't exist on 0.55.2 — it's `debug:vfr`,
  default on; leave it.

## v4.2 (2026-07-08) — conf-driven consolidation topology + empirical A/B harness

Jack's challenge: "sometimes using less cores does not make it more
efficient" — the LP-E consolidation was research-driven, never measured on
this machine; and the mode felt laggy (all userspace on 2× 2.5GHz LP-E cores
while cpu0, a 5.4GHz P-core that cannot be offlined, idled outside every
slice's AllowedCPUs — paying its idle cost, using none of its speed).

### Topology became configuration

Three new `/etc/omarchy-super-power-saver.conf` keys (same guarded sourcing:
root-owned, not group/other-writable, validated before use):

- `SPS_ONLINE_CPUS` (default `0,14-15`) — offline set derived as complement
- `SPS_ALLOWED_CPUS` (default `0,14-15` since the quick-tier A/B shipped D; was `14-15`) — empty means "no cgroup pin"
- `SPS_IRQ_STEER` (default `1`) — IRQ mask derived from pin set (else online set)

Validation invariants (this feeds a NOPASSWD root shell): cpulist parts
limited to 1–2 digits **before** arithmetic (bash silently wraps 64-bit —
`9223372036854775808` would pass `<= 15` after wrap and either offline the
LP-E island or spin the fill loop ~2^63 times), online must contain 0/14/15,
allowed ⊆ online, everything canonicalized (expand→compress) so guarded
writers can string-compare against kernel cpulist prints. Bad values → shipped
defaults + deduplicated drift-log line that survives a clean `off`.

Restore stays conf-INDEPENDENT: it re-onlines all of cpu1-15 unconditionally
and restores IRQs/cgroups from the saved snapshot — a conf edited (or
deleted) between on and off cannot strand a core. `reassert` re-reads the
conf but refuses to half-apply topology: pinning slices at still-offline CPUs
makes cgroup v2 fall back to the parent's effective set, silently
*un*-confining userspace, so `cgroup_apply` skips (and logs) when no pin-set
CPU is online. Watcher expectations were already observed-post-apply, so
variants flow through with zero watcher changes.

### The A/B harness (test/power-mode-ab-test.sh)

Methodology (why it looks the way it does):

- BAT0 has no `power_now`; power = current×voltage. The Dell EC smooths
  readings, so a visit's 60 samples are ~1 effective observation — inference
  is on **per-visit medians across visits**, never per-sample stats.
- **Baseline-bracketed randomized blocks**: A(stock power-saver) → shuffled
  test variants → A; each variant scored as Δ vs the linear interpolation of
  the bracketing A medians. Cancels SoC/voltage/thermal drift better than
  fixed ABAB. Decision rule: same sign across blocks AND |Δ| ≥ max(0.3 W
  quick / 0.2 W thorough, 2× A-repeat noise).
- **Fixed-work loads, never fixed-time**: xz -6 of a byte-identical tmpfs
  file; energy window runs to "back within 0.3 W of that variant's own idle
  median" so race-to-idle gets credit for its sleep tail. Battery J primary,
  RAPL package J (wrap-corrected) as attribution only — package ≠ platform.
- **Lag budget** converts "kinda laggy": python-spawn p95 ≤ 2× stock,
  timer-wakeup p99 ≤ 1.5× stock (also discriminates teo/menu and LP-E
  C-state exit). Benches run as ordinary user-session processes so they
  inherit the variant's confinement exactly like real apps; `/proc/self/status
  Cpus_allowed_list` is logged as proof.
- Confound control: hypridle killed (Wayland idle-notify — systemd-inhibit
  can't stop it; 150s screensaver otherwise fires mid-run), system timers
  paused for the WHOLE run (fairness — super pauses snapper, stock must not
  be penalized), zero terminal output during measurement (PSR2), browser
  preflight refusal, one long-lived root RAPL sampler (per-sample sudo =
  auth-journal disk wakes every 2s) that self-terminates by watching the
  harness pid (user-side cleanup can't signal a root process), dGPU
  runtime_status asserted per sample, AC-plug aborts in idle AND W1 phases.
- Every mutation happens after the EXIT/INT/TERM traps are armed and is
  restored data-driven from recorded initial state.

Variant matrix: A=stock power-saver, B=super minus consolidation (all knobs,
16 CPUs, no pin/steer), B2=pin without offlining, C=shipped default,
D=pin 0,14-15 (the lag-fix candidate), E=E-core pair (0,6-7,14-15),
F=teo governor, PL1 sweep load-only. Quick tier = A/B/C/D (the core
hypothesis quartet), 1 block, ~40 min; thorough = all, 3 blocks, ~3 h.

Pre-registered predictions (written before the run): C ≈ D at idle (an idle
online cpu0 in deep C-state should cost ≈0 W → D is a free lag fix); B loses
≤0.3 W idle but wins joules-per-work under load.

### Review findings worth remembering

Two adversarial review agents over the new code confirmed/added: the 64-bit
cpulist wrap (critical), unkillable root sampler (critical), IFS=';' leaking
from `derive_expect` into the space-splitting cpulist utils (caught by direct
unit test first — every list-consuming function now sets `local IFS=' '`),
stock-baseline visits must be verified as strictly as super variants (a
half-reverted A visit skews every delta in its block), kernel prints
`default_smp_affinity` zero-padded to nr_cpu_ids width (`%04x`, not `%x` —
masks < 0x1000 would false-fail), the scope test must replicate the helper's
conf trust gate or a mis-permissioned conf makes test and helper disagree,
and stray exported `SPS_*` env vars must be unset before sourcing the conf in
tests (sudo's env_reset makes the helper immune; tests aren't).

### Quick-tier results (2026-07-08, ab-20260708-1926) — D shipped as default

Idle (vs stock power-saver 4.06 W, A-repeat noise 0.031 W): C −0.52 W,
D −0.39 W, B −0.23 W (below the 0.3 W quick gate). So the consolidation
itself earns ~0.3 W beyond the non-topology knobs — Jack's "fewer cores might
not help" is refuted at idle, and cpu0-in-pin costs only 0.13 W (an idle
online P-core in deep C-states is nearly free, as pre-registered).

Fixed work (byte-identical xz job, battery J over [start → back-to-idle]):
D 73 s / 526 J beat B 79 s / 565 J beat C 93 s / 589 J. Race-to-idle
confirmed under load: the strict LP-E pin costs ~11% more energy per job.
RAPL package J agreed on ordering (239 / 266 / 305).

Responsiveness: C's lag mechanism is single-thread starvation (st_chunk 88 ms
vs stock 44 ms, 2×) plus doubled timer-wakeup jitter. D restores burst speed
to better-than-stock (32 ms — cpu0 at full boost under the 10 W PL1) and
improves wake p99 (458 µs vs C's 561 µs). D technically failed the
pre-registered spawn-p95 line (137 ms, 3.4× stock) — n=10 with one outlier;
p50 beat C — while no variant that saves meaningful power passed it. Winner
by Jack's stated rule ("least-power variant that feels smooth, ~0.2–0.5 W
cost acceptable"): **D**, shipped as PIN_CPUS="0,14-15" (IRQ mask c001).
C remains one conf line away; E (E-core pair) and the teo/PL1 sweeps remain
unmeasured — run the thorough tier if D still feels laggy.

### Browser battery config (2026-07-08, source-verified for Chromium 148 + Firefox 151)

Research verdict: **both browsers already hardware-decode video by default on
this stack** — the classic advice is stale in both directions. Firefox
removed `media.ffmpeg.vaapi.enabled` in 137 (master switch is
`media.hardware-video-decoding.enabled`, default true, Intel not
blocklisted); Chromium's `AcceleratedVideoDecodeLinuxGL` + `ZeroCopyGL` are
default-on since M143. Battery Saver does not function on desktop Linux
(no battery-level provider in base/power_monitor) — Memory Saver does.

What we ship instead (config/ + installers):
- `chromium-flags.conf`: cleaned to the two features still off-by-default
  and useful — `WebRtcPipeWireCamera` (camera portal) and
  `AcceleratedVideoEncoder` (hw encode for calls; remove if colors break —
  intel-media-driver encode bugs exist on adjacent platforms).
- `chromium-policy.json` → /etc/chromium/policies/managed/ (own file,
  composes): Memory Saver on, max savings.
- `electron-flags.conf`: decode features listed EXPLICITLY — Electron majors
  bundle older Chromium where zero-copy is still off.
- `firefox-policies.json` → /etc/firefox/policies (non-clobbering):
  sessionstore 15s→60s, captive-portal probes off, telemetry off; default
  branch, so user about:config wins.
- `51-browser-igpu.conf` → environment.d: `MOZ_DRM_DEVICE` pinned to the
  Intel iGPU BY PATH. **This machine's render nodes are inverted (NVIDIA =
  renderD128, Intel = renderD129)** and numbering may flip across boots — a
  numeric device pick can wake the dGPU (~9.9W).
- Media tier W6: real Firefox browsing per topology variant — deterministic
  local page chain (text/SVG/JS, auto-scroll, navigate; zero network),
  baseline-bracketed like idle; W4/W5 measure hw-vs-forced-sw decode in both
  browsers with a gt1 media-engine frequency probe proving engagement.

Verify decode engagement: Firefox `MOZ_LOG=PlatformDecoderModule:5` (look
for InitVAAPIDecoder / "VA-API frame"); Chromium DevTools Media domain
(`kIsPlatformVideoDecoder=true`) or `--vmodule=*vaapi*=2`; both cross-checked
by gt1 rc6/act-freq during playback. Expected magnitude (published analogs):
2-5W during 1080p video, larger under the 10W PL1 where software VP9 would
eat the whole CPU budget.

### v4.2.1 (2026-07-08) — 54-agent adversarial review, 22 confirmed findings fixed

Six dimension-focused finders + two independent refuters per finding over the
harness/helper/installers. Deduplicated fixes:

1. Smoke's malformed-conf assert expected the pre-2026-07-08 pin (14-15) —
   every smoke run would have FAILed deterministically against a correct
   install (found 4x independently).
2. mpv-death during w3 wrote empty bench values -> analyze crashed at
   float(''), killing the report for the entire unattended run (and every
   later analyze of that outdir). Sentinel -1,-1 + try/except.
3. No workload liveness checks: a browser/mpv that died after launch recorded
   150s of idle mislabeled as the workload. Now: per-tier command -v preflight
   + kill -0 after settle AND before the _end event in w3/w6/browser runs.
4. apply_variant never verified PL1, so a helper ignoring SPS_PL1_UW would
   have measured the G8/G6 sweep as three identical copies of D. PL1 readback
   asserted from the fragment.
5. G8/G6 have no idle visits: their W1 integration window was biased long vs
   variants with a detected idle-return. They now borrow D's idle baseline
   (same topology).
6. sudo keepalive didn't die with the script on SIGKILL — kill -0 $$ added
   (RAPL sampler already had it).
7. One transient EC "Unknown" status read aborted a 3h run — plug events now
   debounced (1s re-read).
8. GT1_ACT hardcoded card0; card numbers can flip (NVIDIA already claimed
   renderD128) — derived from the by-path PCI symlink.
9. Lag budget PASSed on missing/zero bench data — now INCOMPLETE.
10. Aborted (short) idle visits anchored deltas at full confidence — visits
    under 20 samples excluded with a WARN.
11. Helper's ONLINE_CPUS-unparseable fallback pinned the STALE default 14-15.
12. Scope test: root-owned-600 conf is applied by the helper but unreadable
    by the test — now aborts with a chmod hint instead of asserting shipped
    defaults against a conf-shaped system; RAPL leak check additionally hunts
    the exact conf-driven cap values, not just the stock floors.
13. set -u runtime crash in the new preflight (${#arr[@]:-0} is a bad
    substitution; smoke tier hit it) — arrays now default-declared per tier.

Also: chromium policy skip now visible, menu-extension staleness noted by
install.sh. Two findings refuted (exec-redirect/cleanup interaction and
SUDO_USER-unset derivation were fine as written).

### v4.2.2 (2026-07-08) — mode-core audit (40 agents), 17 findings fixed

Focused pass on the daily-use mode core (previous round leaned harness-ward).
The three majors were state-machine holes in the "state lost / half-applied"
corners:

1. `off` with the helper installed but sudoers missing (and nothing root-side
   applied) failed forever — state file kept, menu stuck "on" until reboot.
   Helper-off now gated on the root half being live (root_applied=yes or /run
   state present).
2. `on` while the root half was still applied but the user state lost
   snapshotted the MODE's own values as the "prior" state (profile
   power-saver, BT blocked) — the eventual off restored those. `on` now
   reconciles to stock first (helper off + stock profile), refusing to enable
   if that fails.
3. The lost-user-state `off` branch ignored the helper's exit status — a lock
   -timeout failure read as success with the watcher already stopped: root
   knobs stayed applied with nothing left to reconcile. Now mirrors the
   normal path (critical notify, /run state kept for retry).

Also fixed: boot-cleanup gets the missing lost-state-with-live-root branch
(menu could previously stack profiles on top of applied root knobs); a
queued watcher reconcile that loses the flock race to a manual `on` no
longer tears the fresh mode down (distinct `off reconcile` reason,
re-validated); watcher gains a cgroup-pin canary (a dropped AllowedCPUs was
invisible to all four existing canaries) and persists re-observed
expectations to the state file (revived watchers inherited stale ones);
caller timeouts raised above the helper's worst-case internal budget
(90/120s could SIGTERM a legitimately slow helper mid-restore; now 180/300s);
exact-restore RAPL fallbacks end hardware-derived like the no-state branch
(v3-state + missing defaults cache could leave the 10W cap); reassert
removes a truncated /run state instead of looping the watcher on exit 3;
SPS_CPUIDLE_GOV validated (was the only conf value reaching sysfs unchecked);
diag documented as deliberately lock-free; stale topology text in the user
script header, design notes v4.2 section, README, and install.sh manifest
brought in line with the 0,14-15 default. One finding refuted (platform_
profile snapshot is restored via ppd, not directly — correct as written).

### v4.3 (2026-07-16) — thorough-tier verdict: consolidation OFF by default

The full matrix (2 bracketed idle blocks x 6 variants + real-use round with
actual Firefox browsing) reversed the consolidation story. Numbers (median
delta vs stock power-saver; blocks sign-consistent):

- idle: C -0.46W, B2 -0.35W, B -0.32W, D -0.27W, E -0.15W, F ~0
- Firefox browsing: D -0.82W, E -0.73W, B -0.69W (stock 7.19W)
- bursty: D -0.54W, E -0.47W, B -0.39W
- mpv video: all within 0.11W of stock (decode is on the media engine;
  topology irrelevant); zero dropped frames everywhere
- lag budget: B 1.1x (stock feel), E 1.3x pass; D 2.1x fail, F/B2/C fail

Weighted for a realistic day (idle-dominant), B and D tie at ~-0.36W average
— but B is unconfined and cannot lag. The pinning machinery just moves
savings from load to idle while charging latency for it. Shipped default is
now **B: SPS_ONLINE_CPUS=0-15, SPS_ALLOWED_CPUS='', SPS_IRQ_STEER=0** — the
mode is the RAPL caps + quiet profile + fabric/GPU/device knobs, with the
whole consolidation stack intact as conf variants (C for max idle savings
when responsiveness doesn't matter, e.g. unplugged overnight).

Run post-mortem: the browser hw/sw-decode phase crashed at the 2.2h mark on
`local ... ph="${br:0:2}..."` — word expansion of a `local` list happens
BEFORE its assignments land, so ${br} was unbound under set -u (that phase
had never executed live; smoke/quick don't reach it). Fixed by splitting the
line; a `loads` tier (~45 min: W1 + PL1 sweep + browser decode A/B) recovers
the two lost phases without a 3h re-run. Threshold logic also improved: one
polluted first visit (block-1 A-noise 0.53W) had inflated the max-noise gate
past every real effect — now median per-block noise.

F (teo governor): no idle benefit, worse latency — rejected, do not re-try.
B2 (pin without offlining): strictly dominated by C — rejected.
