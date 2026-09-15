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

## Other window tools (tested together in the sandboxed shell)

Grabbar's hidden workspace is storage, never a view. Hyprland shows a
special workspace whenever a window on it is focused, so any tool that
focuses a hidden window would otherwise pop the whole hidden set onto the
monitor. The backend listens for that (`window.active`,
`workspace.specialActive`) and answers by restoring the focused window as if
its drawer row had been clicked, then closing the workspace view
(scenarios X01/X02).

| Tool | Interaction | Result |
| --- | --- | --- |
| **Hotbar** (`greyforge.hotbar`) | Lists hidden windows in their app group; clicking/cycling to one calls `hl.dsp.focus` | The window is restored to the current workspace and focused; the drawer row clears; `special:grabbar-minimized` is not shown |
| **Reprieve** (`tech.greyforge.reprieve`) | `Super+W` / `parkWindow` on a window with a Grabbar strip | Parked on `special:reprieve` and returned by Reprieve's undo; Grabbar does not interfere |
| Reprieve | `parkWindow` aimed at a Grabbar-minimized window | Reprieve refuses windows on special workspaces (`passthrough`); nothing moves |
| Any tool | Moves a Grabbar-minimized window somewhere else | Grabbar releases ownership (`released`) and drops the row; it never drags the window back |
| Omarchy scratchpad (`Super+S`, `Super+Alt+S`) | `special:scratchpad` | Separate workspace; no interaction |
| Keybind or tool toggling `special:grabbar-minimized` itself | `toggle_special` | Closed again at once; the window Hyprland focused meanwhile is restored |
| Window switchers / overviews | Focus a hidden window | Same as Hotbar: restored, not revealed |
| Hyprbars, `omarchy-window-controls` | Another decorator on the same windows | Not handled automatically; `grabbar doctor` reports them so you can disable one |

A brief flash of the hidden workspace is possible on slow frames: Hyprland
opens it inside the focus call and Grabbar closes it on the next event-loop
turn.

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
