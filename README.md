# omarchy-super-power-saver

A 4th power mode — **Super Power Saver** — for [Omarchy](https://omarchy.org)
(Arch + Hyprland), layered on top of power-profiles-daemon's `power-saver`.
Built for and tuned on a Dell Pro Max 14 Premium (Intel Core Ultra 9 285H
"Arrow Lake-H" + RTX PRO 2000), but the layering approach applies to any
recent Intel hybrid laptop.

Maximum battery life, deliberately at the cost of performance. Everything is
**runtime-only and exactly reverted** when you switch back — the other three
modes stay bit-identical to stock, no reboot needed, ever.

## What the mode does (v4)

On top of ppd `power-saver` (EPP=power, Dell platform_profile `quiet`):

| Layer | Knob |
|---|---|
| CPU | **LP-E island consolidation**: P-cores 1-5 + E-cores 6-13 offlined; `user/system/machine.slice` pinned to the low-power SoC-tile cores (cpu14-15) via `AllowedCPUs`; all device IRQs + `default_smp_affinity` steered there (managed NVMe queue IRQs and the dGPU are left alone) |
| CPU | RAPL PL1=10W (tau 8s) / PL2=15W / **PL4=25W** in both MSR and MMIO zones; EPB=15; thermald paused (it would raise the caps) |
| Fabric | uncore frequency pinned to its floor; `pcie_aspm=powersupersave` |
| iGPU | render GT capped to its efficient frequency; **SLPC `power_saving` profile** on both GTs (kills waitboost); media GT frequency range untouched (video decode) |
| Display | PSR2 asserted via debugfs (heals the DPMS-wake PSR2→PSR1 downgrade) |
| Devices | bluetooth rfkill (prior state restored), wifi powersave, fingerprint-sensor USB autosuspend, `snd_hda` power_save 10s→1s |
| System | `nmi_watchdog=0`, writeback 60s, `laptop_mode=5`, `snapper-timeline.timer` paused |
| Defense | ~60s watcher (sysfs reads only, no D-Bus) re-pins everything if the EC / ppd / udev AC events fight back; mode persists on AC |

Measured on the reference machine: idle ~4.5W (vs 6.8W in performance mode),
sustained load capped at ~11W vs 65W — roughly **5h+ vs 1h** under load, and
the v4 consolidation targets another few tenths of a watt at idle/light use.

What it deliberately does NOT touch: Hyprland animations/UI (identical in all
modes), screen brightness, screensaver/idle-lock chain, keyboard backlight,
global USB autosuspend policy, the NVIDIA dGPU (never woken — not even by the
diagnostics).

## Install

```sh
git clone https://github.com/JackRubiralta/omarchy-super-power-saver
cd omarchy-super-power-saver
./install.sh                                          # user-side pieces
sudo ~/.local/bin/omarchy-super-power-saver-setup     # root helper (once)
```

The setup script installs, system-side:

- `/usr/local/bin/omarchy-super-power-saver-helper` — the root half (sysfs
  knobs with exact save/restore, state in `/run`)
- `/etc/sudoers.d/omarchy-super-power-saver` — NOPASSWD for exactly
  `helper on|off|reassert|diag`
- `/etc/udev/rules.d/61-igpu-dev-path.rules` — stable `/dev/dri/igpu` symlink
  (useful for `AQ_DRM_DEVICES` on hybrid-GPU machines)
- `/etc/omarchy-super-power-saver.defaults` — stock values cached for the
  worst-case restore path
- verification tooling via pacman (`intel-gpu-tools libva-utils nvme-cli linux-tools`)

Re-run the setup after BIOS updates (refreshes the cached stock values) or
after pulling a new version. If the mode is ON during an update, toggle it
off with the OLD helper first (on/off must be version-paired).

## Use

- **Menu:** Super key menu → Setup → Power Profile → Super Power Saver
  (the active mode is highlighted)
- **CLI:** `omarchy-super-power-saver on|off|toggle|status`
- **Verify:** `sudo omarchy-super-power-saver-helper diag` — PSR/DC states,
  RAPL, GT freqs, IRQ/cgroup pins, package C-states (turbostat), S0ix, LTR
- Mode changes are silent; the mode persists on AC until you switch it off.

### Optional A/B knobs

Create `/etc/omarchy-super-power-saver.conf` (must be root-owned, mode 644):

```sh
SPS_CPUIDLE_GOV=teo        # cpuidle governor while the mode is on
SPS_PL1_UW=7000000         # long-term power cap variant (default 10W)
SPS_PL2_UW=10000000        # short-term cap variant (default 15W)
SPS_ONLINE_CPUS=0,14-15    # CPUs kept online (must contain 0, 14, 15)
SPS_ALLOWED_CPUS=14-15     # slice AllowedCPUs pin (subset of online; empty = no pin)
SPS_IRQ_STEER=1            # 0 = leave IRQ affinities alone
```

Toggle the mode off→on to apply — topology keys especially: `reassert`
deliberately refuses to half-apply a changed topology (it would pin slices at
still-offline CPUs, which *un*-confines them). Malformed values fall back to
the shipped defaults and are logged to the drift log (`diag` shows it).
Measure before keeping: on the reference machine, *lower* CPU caps measured
**worse** at fixed light work (race-to-idle beats forced-slow) — the defaults
are the measured sweet spot.

## Test

```sh
./test/power-mode-ab-test.sh smoke     # ~3 min: apply/assert/revert every consolidation variant
./test/power-mode-ab-test.sh quick     # ~40 min on battery: stock vs consolidation ablations
./test/power-mode-ab-test.sh thorough  # ~3 h: full variant matrix, 3 interleaved blocks
./test/power-mode-scope-test.sh        # scope-exactness: on→off must restore ~50 knobs byte-identically
./test/power-mode-test.sh <outdir>     # battery drain protocol (idle/light/burst per mode, on battery)
```

`power-mode-ab-test.sh` is the empirical answer to "does fewer/slower cores
actually save power?": baseline-bracketed randomized visits (each variant
scored as a delta against interpolated stock-power-saver medians, canceling
battery/thermal drift), fixed-work xz energy with race-to-idle tail credit,
and a lag budget (process-spawn p95 ≤ 2× stock, timer-wakeup p99 ≤ 1.5×
stock) that turns "feels laggy" into a pass/fail line. Results land in
`test/results/` (gitignored); `analyze <outdir>` recomputes the report from
the raw CSVs.

## Design notes

`docs/design-notes.md` is the full engineering log: research, per-knob
rationale and measurements, the v1→v4 incident history (including the leaks
and races that shaped the current save/restore design), and the list of
levers that were researched and **rejected** (PCI runtime-PM sweep, NVMe APST
tuning, refresh-rate reduction, forced-slow CPU, …) so nobody re-tries them.

Highlights of the failure-hardening:

- every knob: save → apply → exact restore, tolerant of version-skewed or
  lost state (falls back to stock values cached at setup time)
- reboot-while-on, crash-while-on, double-on, off-when-off: all converge to
  stock (`boot-cleanup` runs from Hyprland autostart)
- helper verbs serialize on a `/run` flock; a reassert racing an `off` cannot
  re-pin knobs after restore
- writes are readback-verified; drift is logged and shown in `diag`

## Requirements

- Omarchy (or any Arch/Hyprland setup with power-profiles-daemon ≥ 0.30)
- systemd ≥ 250 (cgroup v2 cpuset delegation), bash, sudo
- Intel hybrid CPU for the LP-E consolidation (degrades gracefully elsewhere:
  knobs whose sysfs files don't exist are skipped)

## License

MIT
