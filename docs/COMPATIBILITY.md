# Compatibility

Grabbar's native backend is only valid for the exact compositor build it was
compiled against; `PLUGIN_INIT` compares the API hash and refuses anything
else with "Grabbar needs an update for this desktop version". Nothing below
is a promise for other versions (spec §10.2).

## Qualified for 0.1.0 (2026-09-15)

| Item | Value | Status |
| --- | --- | --- |
| Omarchy | 4.0.x (`omarchy` 4.0.0.alpha shell, Lua configuration mode) | host and sandboxed shell |
| Hyprland | 0.56.2, commit `efb50993780079460b0cbed1363e2166a2de1d9f`, API hash `efb5099…_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6` | all nested suites pass; loaded on the development host |
| Hyprland headers / toolchain | `hyprland 0.56.2-2` package, g++ 16.2.1, `-std=c++2b`, cairo from the same package set | build input |
| Hyprbars base | hyprland-plugins `7644cecdb947060682891a0db2a0cdc5c0b9e704` (hyprpm pin for 0.56.2) | `docs/UPSTREAM.md` |
| Quickshell | 0.3.1 | `omarchy-shell` sandboxed on the nested display: widget, drawer, menu, settings |
| Output scale | 1.0, 1.5, 2.0 (nested outputs) | G0 suite passes at each; glyphs are vector paths |
| Outputs | one; second headless output added and removed while a window was minimized (R09) | restore clamps into the remaining output's work area |
| Layout | dwindle (Omarchy default) with 1–20 tiled windows | scrolling and other layouts unqualified |
| Input | mouse via `zwlr_virtual_pointer_v1`; keyboard in the drawer/menu | touch on the strip unqualified (dropped from the prototype) |

### Applications (tests/integration/apps-nested.sh, all pass)

Each: strip reserved above the client (no overlap), Maximize/Restore size by
button, Minimize by button through the two-phase shell path and restore of
the same window, title drag detaching a tiled window, Close by button.

| Application | Toolkit / path | Notes |
| --- | --- | --- |
| foot | Wayland, no CSD | reference client |
| Chromium | Wayland (Ozone) | draws its own close button in the tab strip; coexists with the Grabbar strip; excludable per app |
| Chromium | **XWayland** (`--ozone-platform=x11`) | class `Chromium` |
| Firefox | Wayland | |
| Konsole | Qt 6 | |
| Dolphin | Qt 6 | |
| Kate | Qt 6, menu bar + toolbar | |
| Nautilus (Files) | GTK 4, client-side decoration | its own header bar stays fully visible under the strip |
| mpv | Wayland, `--force-window` | media app; Grabbar performs no audio/pause operation (F07 by construction) |

## Known exclusions and open questions

- **Modal families** are refused, not moved together: a window with an
  open modal dialog cannot be minimized ("This window cannot be minimized
  while its dialog is open"); a modal cannot be minimized on its own.
- **Native resize** relies on `general:resize_on_border`; Omarchy's default
  is `false`. Enabling it is the user's configuration decision. The nested
  rig runs with it on.
- **Pointer warp on restore-with-focus**: `Config::Actions::focus`
  honours `cursor:no_warps`; Omarchy sets `no_warps = true` and so does the
  rig. Behaviour with warps enabled is not measured.
- **Detached drag** keeps the compositor's native move and does not clamp
  during the drag (Hyprland allows moving windows partly off-screen); the
  strip stays reachable because the drag starts from it.
- **Tooltips** on the strip are not drawn natively; the window menu is the
  text path for every action.
- **Recovery handle** for a bar that cannot host the widget is not built;
  without the widget Minimize stays disabled by design.
- **Spec-inspected upstream `722f15a7…` does not build** on 0.56.2 (header
  layout changed); the hyprpm pin is the base.
- **Cold login through UWSM/systemd** on a real GPU with the Omarchy
  bootstrap config was exercised once on the development host (controlled
  trial, 2026-09-15); the boot guard is the safety net for other machines.
