# Native autoload: the 2026-09-15 incident, root cause and the rule

## What happened

At 01:39 EDT on 2026-09-15 a development session appended this block to the
operator's `~/.config/hypr/hyprland.lua` and then unloaded and reloaded the
native plugin in the live compositor:

```lua
do
  local so = os.getenv("HOME") .. "/.config/omarchy/plugins/tech.greyforge.grabbar/native/grabbar/grabbar.so"
  local loaded = false
  for _, p in ipairs(hl.get_loaded_plugins() or {}) do
    if p.name == "grabbar" then loaded = true end
  end
  if not loaded then hl.plugin.load(so) end     -- THE DEFECT
end
```

The reload hung (`Hyprland IPC didn't respond in time`). On the next login
Hyprland crashed during startup on every attempt; UWSM never received a
display, systemd killed and restarted it, and the screen stayed black. The
operator recovered by booting another OS and removing the block
(`~/.local/state/greyarch-recovery/20260915-grabbar/RECOVERY.md`).

## Root cause (Hyprland 0.56.2 source, `src/config/lua/*`, `src/plugins/PluginSystem.cpp`)

`hl.plugin.load(path)` does not load anything. It appends `path` to the
config's *declared plugin list* for this evaluation
(`LuaBindingsConfigRules.cpp: hlPluginLoad -> m_registeredPlugins`). The list
is cleared at the start of every `reload()`. After evaluation,
`postConfigReload -> handlePluginLoads -> CPluginSystem::updateConfigPlugins`
diffs the declared list against the loaded plugins:

- declared but not loaded: load it (its init runs) and schedule a reload;
- loaded with the config but no longer declared: **unload it** and schedule a
  reload (`unloadPlugin` always does);
- if anything changed, `handlePluginLoads` calls `reload()` **synchronously**.

The block above declared the plugin only while it was *not* loaded. So the
declared set alternated between `{grabbar.so}` and `{}` on every evaluation,
and each evaluation changed the set:

```
reload -> declare -> load -> reload -> (loaded, so) undeclare -> unload -> reload -> declare -> load -> ...
```

The recursion is synchronous, so it never returns to the event loop. In the
isolated reproduction (`tests/integration/startup-nested.sh repro`) the nested
compositor logged 6211 loads and 6210 unloads in four seconds and then
segfaulted from stack overflow inside Lua, before publishing its lock file.
Stack trace: `docs/evidence/startup/repro-coredump-39711.txt` (thirteen nested
`handlePluginLoads` frames visible). That is precisely the login failure.

A second, smaller contributor: `PLUGIN_INIT` also called
`HyprlandAPI::reloadConfig()` (inherited from Hyprbars). The loader already
schedules one reload after init, so this only added churn. It is removed.

## The rule

**A config-time plugin declaration must be identical on every evaluation of
the config.** Never condition `hl.plugin.load()` on whether the plugin is
already loaded; that is what the loader diffs against. Conditions that are
stable for the life of a compositor instance (file exists, an `enabled`
marker exists) are fine.

## What ships now

- `native/autoload.lua`: the shipped loader. One unconditional
  `hl.plugin.load(so)` when the `.so` and the `enabled` marker exist, plus a
  **boot guard**: it records the compositor instance signature in
  `<state>/grabbar/autoload/last-attempt` before declaring; the native plugin
  writes the same signature to `last-ok` after it has run for 15 s
  (`GRABBAR_BOOT_OK_MS`). If at startup the previous attempt never reached
  `last-ok`, nothing is declared, `skipped` is written and a notification asks
  the user to run `grabbar autoload retry`. A bad start therefore cannot
  repeat itself.
- `hyprland.lua` gets one guarded line, installed and removed by
  `grabbar autoload enable|disable` (timestamped backups, byte-exact removal):
  `pcall(dofile, HOME .. "/.config/omarchy/plugins/tech.greyforge.grabbar/native/autoload.lua")`
- `enable` never loads the plugin. The first load happens at the operator's
  own `hyprctl reload` or next login.

## Verification (isolated nested compositor on a headless output, 2026-09-15)

`HEADLESS_WS=<ws on the headless output> tests/integration/startup-nested.sh all`

| Scenario | Result |
| --- | --- |
| Cold start with the failed block | crash in 4 s, 6211 load / 6210 unload, core dump, lock never published |
| Cold start with the unconditional declaration | ready immediately, loaded once, zero churn |
| Three `hyprctl reload` | still one plugin, no load/unload lines |
| `plugin unload`, `plugin load`, `reload` | stable at each step (unload stays unloaded: the declared set did not change, so no storm) |
| Backend socket after all of the above | present and answering |
| Guard 1: armed first start | loads, `last-attempt` = instance, no `last-ok` yet |
| Guard 2: killed before 15 s, restarted | plugin **not** loaded, `skipped` written, reloads keep it skipped |
| Guard 3: `retry` + reload | loads; `last-ok` written by the plugin after 15 s; the next start loads normally |

What this does **not** prove: a real login through UWSM/systemd on the
operator's GPU with the Omarchy bootstrap config. That is the controlled host
trial in `SYSTEM-BREAKING-BUG.md`, which needs the operator's explicit go-ahead.
