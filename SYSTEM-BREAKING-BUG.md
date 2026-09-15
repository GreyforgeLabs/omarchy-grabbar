# SYSTEM-BREAKING BUG — GRABBAR native plugin

Status: ROOT CAUSE FOUND AND FIXED IN SOURCE, 2026-09-15 02:30 EDT; host trial NOT yet
authorised. Native Grabbar remains disabled on the desktop. See the update at the end.
Owner: GRABBAR development and the operator.
Review: before any further native plugin testing or installation.

GRABBAR's native load/reload and autostart path is implicated in a failure
that made GreyArch's desktop unusable. After login, the screen stayed black
and flickered. Restarting did not clear it because the plugin remained in
Hyprland's startup configuration.

## Evidence and recovery

At 01:39 EDT on September 15, the development session added native autoload to
`~/.config/hypr/hyprland.lua`, then unloaded and reloaded the plugin in the live
compositor. The reload returned `Hyprland IPC didn't respond in time`.
On the next boot, Hyprland repeatedly failed to finish startup; UWSM timed
out waiting for WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE, and systemd
forcibly killed the compositor.

An offline recovery removed the GRABBAR autoload block and verified that the
configuration exactly matched its pre-change backup. Successful desktop
login after this recovery has NOT yet been confirmed. This is containment,
not a verified fix to GRABBAR.

The native initialization function calls `HyprlandAPI::reloadConfig()`;
the added Lua configuration calls `hl.plugin.load()`. Reentrant loading is
a suspected mechanism, not an established root cause.

Detailed evidence and the preserved failing configuration are in:
`~/.local/state/greyarch-recovery/20260915-grabbar/RECOVERY.md` and
`hyprland.lua.failed` beside it.

## Development precautions

The operator requested special caution and suggested a VM sandbox after this
incident. Use a disposable VM with a snapshot as the default environment for
native GRABBAR development and execution. Source inspection and edits can
remain on the host; loading the native plugin must stay inside the VM.

- Keep GRABBAR native autoload disabled on the working desktop.
- Do not run plugin load/unload/reload tests against the host Hyprland instance.
- Do not treat earlier nested-compositor G0/G1 results as proof of safe startup.
  Those tests did not establish this autoload path's safety.
- In the VM, reproduce and isolate the failure, then verify cold boot, login,
  config reload, repeated native load/unload, and backend reconnect after the
  fix. Retain failure and recovery evidence and verify rollback.
- Match the VM's Hyprland/Omarchy versions and plugin build to the affected
  desktop. Passing VM tests alone does not establish host GPU compatibility.
- Return to host installation only after the defect is understood, the VM
  regression checks pass, and the operator explicitly requests a controlled
  host trial with a recovery path.

Do not automatically restore `hyprland.lua.failed`: it contains the
startup block associated with the failure.

## Handoff

changed: documented the incident in source and installed GRABBAR directories
current state: native autoload disabled; plugin defect open; login unverified
next step: confirm desktop recovery, then investigate native behavior in a VM
read next: the recovery record above; native/grabbar/main.cpp; this warning

## Update 2026-09-15 02:30 EDT — root cause, reproduction, fix

Desktop login after the offline recovery is confirmed (this session runs in
it; `hyprctl plugins list` = none, no autoload anywhere, no core dumps from
the host compositor).

Root cause is established from the Hyprland 0.56.2 source and reproduced
with a stack trace in an isolated nested compositor, never on the host: the
Lua block declared the plugin only when it was not already loaded, and
`hl.plugin.load()` is a per-evaluation declaration that Hyprland diffs
against loaded plugins after every reload. The declared set flipped on every
evaluation, driving a synchronous load/unload/reload recursion until stack
overflow (6211 loads in 4 s). Full analysis: `docs/AUTOLOAD.md`; evidence:
`docs/evidence/startup/`. The reentrant `reloadConfig()` hypothesis was a
minor contributor only and is also removed.

Fixed in source: unconditional declaration in `native/autoload.lua`, a boot
guard that disarms autoload if the previous start never reached a health
marker (verified end to end in the nested rig), `grabbar autoload
enable|disable|retry|status`, and `tests/integration/startup-nested.sh`.

Still true: nothing native is loaded on this desktop, and nothing will be
until the operator asks for the controlled host trial described above. A VM
was requested; no VM tooling or image exists on this machine, so that remains
an operator decision (package install plus an Omarchy install in the VM).

