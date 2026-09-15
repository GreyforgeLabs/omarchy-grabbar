# Upstream source identity and maintained changes

Grabbar's native backend starts from Hyprbars. This file records exactly
which upstream revision it is based on and what Grabbar changes, so the
patch footprint stays visible (spec §6.1, §16).

## Base revision

| Item | Value |
| --- | --- |
| Repository | https://github.com/hyprwm/hyprland-plugins |
| Base revision | `7644cecdb947060682891a0db2a0cdc5c0b9e704` (2026-07-15, "borders/bars/focus: chase hyprland") |
| Why this one | It is the `hyprpm.toml` commit pin for Hyprland `v0.56.2` (`efb50993…`), the build installed on the qualification host. The specification inspected `722f15a7…` (2026-09-05); that revision includes `<hyprland/src/desktop/view/window/Window.hpp>` and does not compile against the 0.56.2 headers. |
| License | BSD-3-Clause, Copyright (c) 2023 Hypr Development (see THIRD_PARTY_NOTICES) |
| Reference checkout | `native/upstream/` — not committed (`.gitignore`); recreate with `git clone https://github.com/hyprwm/hyprland-plugins native/upstream && git -C native/upstream checkout 7644cecdb947060682891a0db2a0cdc5c0b9e704` |
| Unmodified build check | `make -C native/upstream/hyprbars` builds cleanly on the host (16.8 s, 396,864-byte `.so`) and loads into the nested test session |

## Files derived from Hyprbars

| Grabbar file | Upstream file | Relationship |
| --- | --- | --- |
| `native/grabbar/bar.hpp` / `bar.cpp` | `barDeco.hpp` / `barDeco.cpp` | Decoration positioning, reserved-area geometry, hit validation (`inputIsValid`), stencil-rounded bar rendering, `assignedBoxGlobal`, rule handling retained. Input and button model rewritten (below). |
| `native/grabbar/pass.hpp` / `pass.cpp` | `BarPassElement.hpp` / `.cpp` | Same structure; blur support removed. |
| `native/grabbar/main.cpp` | `main.cpp` | Same plugin skeleton (version-hash check, decoration attach, config values, exit). Lua/legacy `add_button` keyword removed; backend and hyprctl command added. |
| `native/grabbar/globals.hpp` | `globals.hpp` | Config-value holder retained; button list replaced by a fixed control set. |
| `native/grabbar/backend.hpp` / `backend.cpp` | — | New: identities, typed actions, owned workspace, socket, recovery. |

## Maintained changes (behavioural)

1. **Buttons act on release inside the same target.** Upstream fires `exec` on press. Grabbar records the pressed button and the window token at press and acts only if release lands on the same button of the same live window (spec §3.3, test F03).
2. **No shell commands.** Upstream buttons run user-configured command strings through the `exec` dispatcher and target `activewindow`. Grabbar calls typed actions (`Config::Actions::closeWindow`, `fullscreenWindow`, `floatWindow`, `pinWindow`, `moveToWorkspace`, `move`, `resize`, `focus`) with an explicit `PHLWINDOW` resolved from a token.
3. **Fixed control set.** Window-menu target, Minimize, Maximize/Restore size, Close; left or right placement; narrow-window fallback keeps only the menu target.
4. **Drag threshold and tiled detach.** Upstream starts a native move on the first motion event. Grabbar waits for `binds:drag_threshold` (6 px fallback), gives a layout-filling window a 60 % floating size, keeps the pointer over the same proportional strip point, then starts the compositor's native move (`changeMouseBindMode(MBIND_MOVE)`).
5. **Double-click on the title region only** toggles Maximize/Restore size; buttons never double-click.
6. **Suspended until a shell service completes the readiness handshake**; suspended again when the shell disappears for longer than the grace period. Reserved height becomes 0 so clients get their space back.
7. **Touch input dropped** for the G0 prototype (upstream supports it); to be re-qualified.
8. **Glyphs are cairo paths** (menu, minimize, maximize, restore, close) rendered into textures through `createTexture(cairo_surface_t*)`, cached per glyph/size/colour. Upstream renders text glyphs with the text renderer. No icon font.
10. **Appearance pushed by the shell.** Colours, font, control side and size, and per-class exclusions arrive over the socket (`theme`/`settings` messages) and take precedence over `plugin:grabbar:*` while set, so the strip follows the Omarchy theme without config edits.
11. **Right-click opens the window menu** (a `menuRequest` to the shell); upstream has no menu.
12. **`decorate()` window rule** disables the reservation too (upstream reserves the band even for `nodecoration` windows).

## Not changed

Decoration positioning policy (`DECORATION_POSITION_STICKY`, top edge, `reserved = true`), `DECORATION_ALLOWS_MOUSE_INPUT | DECORATION_PART_OF_MAIN_WINDOW`, layer `DECORATION_LAYER_UNDER`, the stencil-based rounded rendering, the hit test that yields to top/overlay layer surfaces and seat grabs.

## Compatibility rule

The backend refuses to load unless `__hyprland_api_get_hash()` equals the running compositor's hash. A new Hyprland release requires re-basing on that release's hyprpm pin and re-running `tests/integration/g0-nested.sh`.

9. **No `HyprlandAPI::reloadConfig()` in `PLUGIN_INIT`** (Hyprbars calls it
   at the end of init). `CPluginSystem::loadPluginInternal` already schedules
   a config reload after init returns; the extra call only adds reload churn,
   which matters when the plugin is declared from the config (see
   `docs/AUTOLOAD.md`). A 15 s one-shot `CEventLoopTimer` writes the boot
   health marker instead.

