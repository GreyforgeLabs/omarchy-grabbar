# Grabbar

Familiar window controls for Omarchy.

Grabbar adds a title strip with Minimize, Maximize/Restore size and Close to
ordinary application windows, lets you move a window by dragging that strip,
and keeps a drawer in the bar that always brings a minimized window back.

**Status: G0 feasibility prototype.** The native backend, its shell socket
protocol, and disconnect recovery are implemented and exercised in an
isolated nested Hyprland session (see `docs/QUALIFICATION.md`). The Omarchy
shell side (service, bar widget, drawer) is an early scaffold. There is no
installer, no published release, and no support claim for any desktop other
than the one build listed in `docs/COMPATIBILITY.md`.

## Layout

| Path | Purpose |
| --- | --- |
| `manifest.json` | Omarchy plugin identity and entry points |
| `Service.qml` | Shell service: backend connection, minimize journal, restore model |
| `BarWidget.qml` | Stable restore entry point in the bar |
| `Panel.qml` | Minimized windows drawer |
| `GrabbarModel.js` | Pure state, protocol codec, journal, reconciliation |
| `native/grabbar/` | Native backend (Hyprbars-derived, C++) |
| `native/autoload.lua` | Guarded config-time loader for the native backend; read `docs/AUTOLOAD.md` and `SYSTEM-BREAKING-BUG.md` before enabling it |
| `native/upstream/` | Pinned Hyprbars reference checkout (not packaged) |
| `helpers/` | Journal helper and backend socket client (Python, stdlib) |
| `bin/grabbar` | CLI: status, windows, restore, restore-all, doctor |
| `tests/unit/` | Model, journal, protocol tests |
| `tests/integration/` | Nested-compositor scenarios and the virtual pointer tool |
| `docs/` | Upstream identity, compatibility, qualification evidence |

## Building the native backend

```sh
make -C native/grabbar CXX=g++
```

The result is only valid for the Hyprland build whose headers were used.
Load it into an **isolated** test session first:

```sh
hyprctl -i "$NESTED_SIG" plugin load "$PWD/native/grabbar/grabbar.so"
hyprctl -i "$NESTED_SIG" grabbar
```

`docs/QUALIFICATION.md` describes the nested test rig.

## Tests

```sh
tests/run.sh                       # offline: model, journal, protocol, syntax, manifest
tests/integration/g0-nested.sh     # against the nested session (see the script header)
```

## License

MIT for Greyforge code. The native backend is derived from Hyprbars
(BSD-3-Clause); see `THIRD_PARTY_NOTICES` and `docs/UPSTREAM.md`.
