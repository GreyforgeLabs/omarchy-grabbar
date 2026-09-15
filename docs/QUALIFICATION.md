# Qualification record

Evidence for the release gates in spec §15. Everything here was measured on
the host below; nothing is a claim for other machines or versions.

## 0.1.0 preview — 2026-09-15 (G1 + G2 + G3 evidence)

### Host and rig

| Item | Value |
| --- | --- |
| Machine | greyarch (Omarchy 4.0.x, Lua config), Hyprland 0.56.2 `efb50993…`, Quickshell 0.3.1 |
| Native build | `make -C native/grabbar CXX=g++`, g++ 16.2.1, 584 KB `grabbar.so` |
| Rig | nested Hyprland (`tests/integration/nested/lab.lua`, 1600×1000, `resize_on_border`, `no_warps`) on a headless output created with `hyprctl output create headless GRABBAR-LAB`, launched with `[workspace <ws> silent]`; the operator's desktop was never used |
| Shell | a second **real** `omarchy-shell` (`qs -p /usr/share/omarchy/shell`) on the nested display with an isolated `HOME` (its own `shell.json`, plugin copy and state dir) — see "Sandboxed shell" below |
| Input | `tests/integration/vpointer` (`zwlr_virtual_pointer_v1`), now with `rclick`/`mclick` |

### Suites and results (all PASS)

| Suite | Result | Evidence |
| --- | --- | --- |
| `tests/run.sh` (offline) | model 23, journal, autoload, protocol, syntax | CI-equivalent |
| `g0-nested.sh` at scale 1.0 | 10/10: F03, F04, F04b, double-click, F06, stale target, F10, R02, R03 | `docs/evidence/0.1.0/g0-scale100.log` |
| `g0-nested.sh` at scale 1.5 and 2.0 | 10/10 each; glyphs and hover boxes align at both scales | `g0-scale150.log`, `g0-scale200.log`, `scale150-strip.png`, `scale200-close-hover.png` |
| `g1-service-nested.sh` (standalone service host) | 5/5: handshake, two-phase minimize with journal before commit (0600/0700, no title), restore via IPC, service death → grace recovery, stale journal reconciled without moving | `g1-service.log` |
| `apps-nested.sh` | 9/9 applications × 5 checks (see COMPATIBILITY.md) | `apps.log`, `apps/*.png` |
| `scenarios-nested.sh` with the sandboxed shell | F02, F05, F08 (20 windows: 20 rows, 20 journal entries, Restore all in 110–169 ms), R05, R09, R10, R15, X01 (another tool focuses a hidden window → restored, no reveal), X02 (`toggle_special` on Grabbar's workspace → closed) — all PASS, also with **Hotbar and Reprieve enabled in the same sandboxed shell** | `scenarios.log`, `scenarios/*.png` |
| Hotbar / Reprieve interplay (manual, sandboxed shell) | Reprieve parks and undoes a Grabbar-decorated window; Reprieve refuses (`passthrough`) a Grabbar-minimized window; `hl.dsp.focus` on a hidden window (Hotbar's activation call) restores it and closes the special workspace | `docs/COMPATIBILITY.md` "Other window tools" |
| `stress-nested.sh` | 500/500 minimize+restore cycles through the shell IPC; p50 164ms, p95 170ms, max 186ms per round trip (two `qs ipc` process spawns included); compositor PSS 99826 → 99827 kB, fds 85 → 83; shell PSS 194281 → 190177 kB, fds 73 → 72; tracked entries constant | `stress.log` |
| `startup-nested.sh all` | repro of the 2026-09-15 failure (6213 loads, core dump), fixed cold start, 3 reloads, unload/load/reload, socket after reload, boot guard 1–3 | `startup.log`, `docs/evidence/startup/` |
| Sandboxed `omarchy-shell` walk-through | bar widget mounts and declares restore access; Minimize button → count in the bar → drawer → Restore by click; menu button and right-click open the window menu; Move freely toggles and shows its check; Hide Grabbar for foot → confirmation → strip gone, exclusion persisted through the host's `updateEntryInline` into `shell.json` and mirrored; Settings: Show Grabbar again, Large, Left, Off (windows returned, strips off, `decorations: paused`), On | `docs/screenshots/*.png`, `sandbox-shell.log` |

### Measured against §11 budgets

| Metric | Budget | Measured |
| --- | --- | --- |
| Idle background work | zero polling | no timers except the one-shot grace and the one-shot boot marker; no subprocesses; rendering only in the decoration pass |
| Incremental idle CPU (10 windows, 2×30 s, pointer still) | ≤ 0.2 % of one CPU | compositor 5 and 0 ticks/30 s with Grabbar vs 1 and 0 without (100 ticks/s) → < 0.02 %; shell 0 ticks |
| Incremental PSS, compositor (10 windows) | ≤ 25 MiB | 99898 kB loaded vs 99624 kB unloaded → **≈ 0.27 MiB** (glyph textures + decorations) |
| Larger working set | no unbounded growth | 20 windows minimized/restored (F08) and 500 cycles: PSS flat |
| Completed simple transition | p95 ≤ 250 ms | 170ms (full round trip minimize + restore through two CLI IPC calls) |
| Button acknowledgment | p95 ≤ 100 ms | not instrumented; hover/press redraw is synchronous in the decoration pass |
| Drawer open | p95 ≤ 150 ms | not instrumented |

### Sandboxed shell (how to reproduce)

```sh
# 1. headless output + nested compositor (never the live one)
hyprctl output create headless GRABBAR-LAB
WS=$(hyprctl -j monitors | jq '.[] | select(.name=="GRABBAR-LAB") | .activeWorkspace.id')
hyprctl dispatch "hl.dsp.exec_cmd([[ [workspace $WS silent] env HYPRLAND_INSTANCE_SIGNATURE= Hyprland -c $PWD/tests/integration/nested/lab.lua ]])"
SIG=<new dir under $XDG_RUNTIME_DIR/hypr>; NESTED_DISPLAY=<wayland-N from its hyprland.log>
hyprctl -i $SIG plugin load $PWD/native/grabbar/grabbar.so
# 2. an isolated HOME with a minimal shell.json (grabbar in the right section) and this checkout
#    copied to $H/.config/omarchy/plugins/tech.greyforge.grabbar, themes copied, state dir empty
env -i HOME=$H PATH=$PATH XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$NESTED_DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=$SIG OMARCHY_PATH=/usr/share/omarchy QT_QPA_PLATFORM=wayland \
  qs -p /usr/share/omarchy/shell
# 3. drive it: WAYLAND_DISPLAY=$NESTED_DISPLAY qs ipc -p /usr/share/omarchy/shell call tech.greyforge.grabbar status
```

Screenshots come from inside the nested session (`WAYLAND_DISPLAY=$NESTED_DISPLAY grim`).

### Not covered by 0.1.0

Modal families, touch, native tooltips, other layouts, three outputs,
portrait/mixed-refresh outputs, the usability study (§14.5), a cold
UWSM/systemd login on hardware other than the development host.

## G0 — native feasibility (2026-09-15)

**Verdict: passed for the narrow matrix in `COMPATIBILITY.md`.** A small
Hyprbars-derived extension provides every G0 requirement without a compositor
fork or function hooks. The patch footprint is visible in `docs/UPSTREAM.md`
and in the source (about 2,270 lines including the new backend, against
1,207 upstream lines). Remaining hypotheses are listed at the end.

### Host

| Item | Value |
| --- | --- |
| Machine | greyarch (Omarchy 4.0.3-1, Lua config) |
| Hyprland | 0.56.2 `efb50993…` (2026-08-05 build) |
| Headers / toolchain | `hyprland 0.56.2-2` package headers, g++ 16.2.1 |
| Upstream base | hyprland-plugins `7644cecd…` (hyprpm pin for 0.56.2) |
| Native build | 16.8 s, `grabbar.so` 550,000 bytes (upstream hyprbars 396,864 bytes) |

### Test rig: nested Hyprland on a headless output

The operator's live desktop was never used for compositor tests. A second
Hyprland instance runs as a Wayland client of the live session, placed on an
existing headless output (`HD-1`, workspace 7) with `[workspace 7 silent]`
so nothing appears on the operator's monitor. It has its own instance
signature and Wayland socket, its own `hyprctl -i`, and its own screencopy,
so `grim` inside it produces the evidence without touching the host output.
Pointer input is injected with `tests/integration/vpointer` through
`zwlr_virtual_pointer_v1` on the nested display only.

```
hyprctl dispatch "hl.dsp.exec_cmd([[ [workspace 7 silent] env HYPRLAND_INSTANCE_SIGNATURE= Hyprland -c test.conf ]])"
# then: hyprctl -i <nested sig> plugin load .../grabbar.so
SIG=<nested sig> NESTED_DISPLAY=wayland-2 tests/integration/g0-nested.sh
```

Config for the nested session: legacy `.conf` (parsed fine by 0.56.2),
1280×800, `resize_on_border = true`, `no_warps = true`, default animations.
A crash of the nested compositor would only end that nested session.

### G0 exit conditions and evidence

| Requirement (spec §15 G0) | Result | Evidence |
| --- | --- | --- |
| Reserved decorations | The strip occupies a 34 px reserved top band; the client is placed below it, no overlap with app content. Unmodified upstream hyprbars shows the same reservation. | `docs/evidence/g0/01-strip-active.png` (client at y=56 with strip; y=22 without) |
| Identity-safe actions | Every action resolves a token to a live window and re-checks `m_stableID`; press captures the token, release re-validates; a closed window's token answers `stale`; restoring a visible window is `refused`, never redirected to the active window. | `g0-nested.sh` "stale-target" and F04b steps; `shell-standin.log` |
| Press Close, drag away, release does not close | F03 passes: the window count is unchanged. | `02-close-hover.png` (hover treatment on Close) |
| Native mouse move | Dragging the title beyond `binds:drag_threshold` (6 px fallback) starts the compositor's own move mode; a tiled window is detached to floating at 60 % size with the strip under the pointer. | F10 passes; `06-tiled-drag-detached.png` |
| Native resize | Not exercised in G0 (see hypotheses). | — |
| Maximize with strip retained | `fullscreenWindow(FSMODE_MAXIMIZED, FSMODE_MAXIMIZED, false, w)` fills the work area (611 → 1236 px with two tiled windows), the strip stays reachable, restore size rejoins the layout at the tiled width. Double-click on the title toggles it. | F04, F04b, `07-two-windows-maximized.png` |
| Minimize / restore of the same window | The window moves to `special:grabbar-minimized` only after the shell acknowledged the prepared record (two-phase, request-id bound), and returns tiled to the drawer's current workspace with the same address. | F06; `04-minimized.png`, `05-restored.png` |
| Per-action pointer stability | Not measured with `no_warps = false` (see hypotheses). | — |
| Safe shell/native disconnect recovery | Shell socket closed with a minimized window: minimize disabled within 0.6 s, the window returned within the 2 s grace, controls suspended (reserved height 0). Native unload with a minimized window returns it before native references are dropped. | R02, R03; `08-shell-lost-recovered.png`, `09-after-unload.png`, `status-suspended.txt` |
| Backend starts suspended | Without a shell handshake the strip is not drawn and no space is reserved. | `00-suspended-no-shell.png`, `status-active.txt` vs `status-suspended.txt` |

Full scenario output of the passing run (run 3): all of F03, F04, F04b,
double-click, F06, stale-target, F10, R02, R03 `PASS`.

### Measured footprint and latencies

Not yet measured against the §11 budgets. The prototype has no timers
except the one-shot 2 s grace timer and no polling; rendering is driven by
the decoration pass. Idle CPU, PSS and p95 latencies remain to be recorded
with the shell service in place.

### Defects found and fixed during G0

- The backend reported a window as "released" (moved by another tool)
  during its own restore move, because the workspace-change event fires
  before ownership is cleared. Fixed with an explicit `transitioning` flag.
- Detaching a full-size tiled window kept its layout size, pushing it off
  screen; it now gets a 60 % floating size and the pointer stays over the
  same proportional strip point.
- A test stand-in launched through a bash wrapper survived `kill` of the
  wrapper, so the "shell" never disconnected; the harness now launches the
  python client directly.

### Remaining G0 hypotheses (not demonstrated)

1. **Mouse resize** through `general:resize_on_border` (edges/corners,
   floating and tiled) — not exercised; whether `extend_border_grab_area`
   overlaps client controls must be checked before the feasibility gate is
   fully closed (spec §4.5).
2. **Pointer warp on restore/focus** with `cursor:no_warps = false`.
3. **Modal families** (spec §4.6): currently refused, not moved together.
4. **Scales other than 1.0**, multiple outputs, XWayland and CSD clients.
5. **Touch** input (dropped from the prototype).
6. **Reserved work area** clamping (currently monitor logical box).
7. **Live Omarchy shell integration** of `Service.qml` / `BarWidget.qml` /
   `Panel.qml`: written against the host contract used by Reprieve but not
   yet loaded into a running shell.

## G1 — shell service against the backend (2026-09-15, partial)

`Service.qml` was run in a standalone Quickshell process on the nested
display (`tests/integration/g1-service-nested.sh`, host staged from
`service-host.qml`), never inside the operator's live `omarchy-shell`.
The bar widget was simulated by registering a restore host at startup.

| Scenario | Result | Evidence |
| --- | --- | --- |
| Handshake and readiness | Service welcomed as the shell, restore host declared, backend reports `minimize: enabled` | `docs/evidence/g1/status-1.json` |
| Two-phase minimize | The `prepared` journal record is written (0600 in a 0700 dir, no title) before the service sends `minimizeCommit`; the window is on `special:grabbar-minimized` afterwards | `state.json` checks in the script |
| Restore via service IPC | Row and journal entry removed only after the compositor reported the window visible | script step 3 |
| Service process killed with a minimized window | Backend returned the window within the grace period and suspended the strip (R02 with the real service) | script step 4 |
| Restart with a stale journal entry | Reconciliation cleared the entry for the now-visible window without moving it (§7.4 row "entry but window visible") | `docs/evidence/g1/service-host-2.log` |

Not yet done for G1: `BarWidget.qml` and `Panel.qml` inside the live
Omarchy shell, the window menu, settings, setup card, desktop entry,
recovery handle, per-app exclusion, and the §11 measurements.

## Startup / autoload regression (2026-09-15, after the desktop incident)

Run in the isolated nested compositor (`tests/integration/startup-nested.sh
all`, `HEADLESS_WS` on the headless output). Never on the host. Details and
the root cause are in `docs/AUTOLOAD.md`; the incident record is
`SYSTEM-BREAKING-BUG.md`.

| Check | Result | Evidence |
| --- | --- | --- |
| Reproduce the failed conditional block on cold start | crash after 4 s: 6211 loads, 6210 unloads, SIGSEGV from stack overflow, lock never published | `docs/evidence/startup/repro-coredump-39711.txt`, `repro-counts.txt`, `repro-hyprland.log` |
| Fixed unconditional declaration, cold start | ready at once, loaded once, no churn | `fixed-counts.txt`, `fixed-hyprland.log` |
| 3 reloads; unload; load; reload | one plugin, compositor alive at every step | script output |
| Backend socket + status after the above | present, answering | `fixed-grabbar-status.txt` |
| Boot guard: killed before health marker then restarted | plugin not loaded, `skipped` recorded, reloads stable | `guard-status-skipped.txt`, `guard-state-final/` |
| Boot guard: `retry`, health marker, healthy restart | loads after retry; `last-ok` written after 15 s; next start loads normally | script output |

Not covered here: a real UWSM/systemd login on the operator's GPU with the
Omarchy bootstrap config. That is the controlled host trial and needs the
operator's explicit go-ahead.

