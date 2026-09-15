# Compatibility

Grabbar's native backend is only valid for the exact compositor build it was
compiled against. Nothing below is a promise for other versions (spec §10.2).

## Qualified so far

| Item | Value | Status |
| --- | --- | --- |
| Omarchy | 4.0.3-1 (Lua configuration mode) | host used for G0 |
| Hyprland | 0.56.2, commit `efb50993780079460b0cbed1363e2166a2de1d9f`, ABI `efb5099…_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6` | G0 prototype loads and passes the nested scenarios |
| Hyprland headers | `/usr/include/hyprland` from the `hyprland 0.56.2-2` package | build input |
| Toolchain | g++ 16.2.1, `-std=c++2b` | build input |
| Hyprbars base | hyprland-plugins `7644cecdb947060682891a0db2a0cdc5c0b9e704` (hyprpm pin for 0.56.2) | see docs/UPSTREAM.md |
| Quickshell | 0.3.1 | shell side not yet exercised in the live shell |
| Output scale | 1.0 only (nested WAYLAND-1 at 1280×800) | 125/150/200 % unqualified |
| Layout | default (dwindle) with one and two tiled windows | scrolling and other layouts unqualified |
| Applications | foot (Wayland, no CSD) | browsers, GTK CSD, Qt, XWayland unqualified |
| Input | mouse via `zwlr_virtual_pointer_v1` | touch dropped in the prototype |

## Known exclusions and open questions

- **Spec-inspected upstream `722f15a7…` does not build** on 0.56.2 (header layout changed). The pin table in `hyprpm.toml` is authoritative for the base revision.
- **Pointer warp on restore-with-focus** uses `Config::Actions::focus`; the nested config sets `cursor:no_warps = true`, and the operator's Omarchy config does too. Behaviour with `no_warps = false` is not yet measured (G0 question, spec §5.3).
- **Work area vs. logical box.** Floating restore clamps into the monitor's logical box, not the reserved work area. Correct clamping against the panel's reserved area is pending.
- **Modal families** are refused, not moved together: a window with an open modal dialog cannot be minimized, and a modal cannot be minimized on its own. Family minimize/restore (spec §4.6) is not implemented.
- **Native resize** relies on the compositor's `general:resize_on_border` feature; Omarchy's default sets it to `false`. Enabling it is a configuration decision for setup, not something the backend does silently. Edge/corner resize has not been exercised yet.
- **Detached drag** keeps the compositor's native move; it does not clamp the window to the output during the drag (Hyprland allows moving windows partly off-screen). The strip stays reachable because the drag starts from it.
- **Glyphs** are text characters, not bundled icons.
- **Unsupported native combination**: the backend throws at `PLUGIN_INIT` when the API hash differs; Hyprland reports the load failure and nothing is decorated.
