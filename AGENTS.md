# Working on Grabbar

Read `docs/AUTOLOAD.md` and `SYSTEM-BREAKING-BUG.md` before touching
anything that loads the native plugin. The 2026-09-15 incident is understood
and fixed (a conditional `hl.plugin.load()` in the Lua config), and the
shipped loader carries a boot guard; the rules that keep it fixed are:

- **Never load, reload or test the native plugin in the compositor you are
  sitting in.** Use the nested Hyprland on a headless output described in
  `docs/QUALIFICATION.md`; a sandboxed `omarchy-shell` with its own `HOME`
  gives you the bar, drawer and settings there too.
- **A config-time plugin declaration must be identical on every evaluation
  of the config.** Never condition `hl.plugin.load()` on loaded-plugin state.
- Building writes a new `grabbar.so` inode, which is safe while an old copy
  is mapped; never `cat >` over a loaded `.so`.
- The installed copy under `~/.config/omarchy/plugins/tech.greyforge.grabbar`
  is the operator's live plugin. Syncing it is the operator's call.
- Do not `pkill -f <pattern>` from an agent shell (it matches the agent's own
  command line); kill by PID.

## Release distribution

After an authorized Grabbar release, follow `docs/DISTRIBUTION.md` and the
shared `omarchy-plugin-distribution` skill when available. Submit/update
eligible directory listings and retain exact-commit receipts; distinguish
submission from acceptance. Complete repository changes before marketplace
validation so subsequent documentation commits do not stale its scan.
