# Contributing

Thanks for looking at Grabbar. Two ground rules keep this project safe to
work on:

1. **Never load, reload or test the native plugin in the compositor you are
   sitting in.** Use the nested rig in `docs/QUALIFICATION.md` (a second
   Hyprland on a headless output). A native crash there ends a sandbox, not
   your session.
2. **Never condition `hl.plugin.load()` on whether the plugin is already
   loaded.** Read `docs/AUTOLOAD.md` before touching `native/autoload.lua`
   or `helpers/grabbar-autoload`.

## Layout

See the table in `README.md` and `docs/ARCHITECTURE.md`. Pure logic lives in
`GrabbarModel.js` so it can be tested with Node; the QML files are thin.

## Building

```sh
make -C native/grabbar CXX=g++       # against the installed hyprland headers
tests/run.sh                          # offline suite
```

Building writes a new `grabbar.so` inode; a compositor that has the old file
mapped keeps running. Load the new file into the nested session with
`hyprctl -i <nested sig> plugin load …`.

## Tests

- `tests/run.sh` must pass before every commit (it is what CI runs).
- Native or shell behaviour changes need the relevant nested suite
  (`g0-nested.sh`, `g1-service-nested.sh`, `apps-nested.sh`,
  `scenarios-nested.sh`); record the run in `docs/QUALIFICATION.md` with the
  exact Hyprland build.
- New protocol fields go into `docs/PROTOCOL.md` and all three codecs
  (C++, JS, Python) plus their tests.

## Style

- Match the surrounding code. C++ follows the Hyprland plugin style
  (`.clang-format` from upstream); QML/JS use two-space indent and ES5-style
  JavaScript in `GrabbarModel.js` (it runs in Quickshell's engine).
- User-facing text is plain: no dispatcher syntax, no internal workspace
  names, no success messages before the state change is observed.
- Never build shell commands from window titles or classes; never resolve
  an action against the focused window.

## Pull requests

Describe what changed and how it was tested (which nested suite, which
Hyprland build). Keep the upstream base and the patch footprint visible:
if you touch a file derived from Hyprbars, note the behavioural change in
`docs/UPSTREAM.md`.

## Release distribution

Releases include the directory submission/update stage in
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md). Preserve preview qualifications
and record each target's receipt and pending review separately.
