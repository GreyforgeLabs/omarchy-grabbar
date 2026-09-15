# Changelog

## 0.1.0 — 2026-09-15 (public preview)

First public release: the complete core workflow on one qualified desktop
build (Omarchy 4.0.x, Hyprland 0.56.2 `efb50993…`, Quickshell 0.3.1).

### Native backend
- Control glyphs are cairo paths (menu, minimize, maximize, restore, close);
  crisp at 1.0/1.5/2.0 scale, no icon font.
- Strip colours and font follow the Omarchy theme pushed by the shell;
  Settings push control side, size (standard 34 px / large 46 px) and
  excluded classes. `plugin:grabbar:*` config values remain the fallback.
- Right-click on the strip opens the window menu; the menu button too.
- Press captures the window token, release re-validates and acts on that
  token (F02).
- Hover feedback only when the strip is really under the pointer.
- Dragging a maximized floating window keeps the pointer over the strip.
- Origin geometry is captured after leaving maximized mode, so a maximized
  floating window restores to its own size.
- Restore clamps floating windows into the work area (bar excluded).
- Unrecorded windows on `special:grabbar-minimized` can be restored
  (Recovered rows).
- `pause`/`resume` for the Settings switch; restore-all walks a token
  snapshot; `restored` window events after any return path.
- `plugin:grabbar:shell_grace_ms` (default 2000).
- Other tools focusing a hidden window (Hotbar, window switchers,
  `focuswindow`) or toggling `special:grabbar-minimized` no longer reveal
  the hidden workspace: the focused window is restored like a drawer
  click and the view is closed (scenarios X01/X02).
- No `reloadConfig()` in `PLUGIN_INIT`; boot-guard marker after 15 s.

### Shell
- Window menu (Minimize, Maximize/Restore size, Move freely, Close,
  Minimized windows, Hide Grabbar for this app with confirmation, Settings).
- Settings view: on/off, controls left/right, control size, excluded apps
  with "Show Grabbar again", setup check, technical details.
- Bar widget: window-stack glyph with count, left = drawer, middle =
  restore all, right = settings; keeps its space; pushes theme and the
  host's settings writer to the service.
- Fixed: title updates for minimized rows (wrong argument order); journal
  status stuck at `stale` after quarantine; `reconcile` IPC re-reads the
  journal.

### CLI and helpers
- Correct exit codes for shell answers (`restore`, `restore-all`).
- `disable`, `enable`, `uninstall` implemented; `setup`/`settings` open
  the Settings view.
- `vpointer` gains `rclick`/`mclick`.

### Tests and docs
- New nested suites: application matrix, shell-connected scenarios (F02,
  F05, F08, R05, R09, R10, R15), 500-cycle soak; harnesses work on
  Lua-config nested compositors and with a sandboxed `omarchy-shell`.
- README, ARCHITECTURE, PROTOCOL, COMPATIBILITY, QUALIFICATION rewritten;
  brand assets; GitHub Actions offline suite.

## 0.0.1-g0 — 2026-09-15 (internal)

G0 feasibility prototype: Hyprbars-derived backend with reserved strip,
token-based actions, owned hidden workspace, socket protocol, disconnect
recovery; shell service and drawer scaffold; the autoload incident, its
root cause and the boot guard (`docs/AUTOLOAD.md`).
