# Native release safety — 2026-09-15

**Status: 0.1.1 public preview; full-login qualification pending.** The operator
explicitly authorized immediate publication and deployment on 2026-09-15
after the remaining qualification gap was reported. That authorizes this
preview publication; it does not turn missing testing into a pass. The gate
below remains required before claiming a fully qualified stable release.

## Fix in the product

The original conditional-declaration defect is fixed in tracked
`native/autoload.lua`; the install helper uses that file. The fix does not
depend on the developer's local Hyprland configuration. A plugin declaration
is retained on every evaluation while enabled for the current instance.

Additional hardening keeps the plugin undeclared if the compositor identity
is missing or a startup-attempt marker cannot be saved. Marker replacement
checks writing, closing and renaming before permitting a new attempt.

The executable crash case is retired, including from default/all startup
tests. Its historical diagnostic evidence remains preserved. Offline CI
requires Lua loader behavior tests; the nested runner exits unsuccessfully
if an assertion fails.

## Verified in this working tree

- `tests/run.sh`: exit 0. Includes nine real-Lua loader cases with a fake
  compositor API; no native code executes in those unit tests.
- `startup-nested.sh all`: exit 0, 19 passing assertions. Corrected
  cold startup, three reloads, unload/load/reload, backend status, guarded
  cold startup, unconfirmed-start recovery, retry, health marker and next
  healthy startup. Actual native plugin tested in isolated nested Hyprland
  on a temporary headless output. The host compositor remained PID 1254.
- Hyprland 0.56.2, commit `efb50993780079460b0cbed1363e2166a2de1d9f`.
- Lua loader SHA-256: `eaa6586d69f5cc56c18924a06a1acff91462a5b7afced6889661281ac9496f39`.
- Tested local native binary SHA-256: `7e88f01760feb24a703c3d81b9e369788a9b98ed284e372f4c8a3279fdf957b6`.
- [Integration output](evidence/startup/loader-hardening-20260915.log).

## Exact 0.1.1 preview build

The operator subsequently authorized publication and deployment. The native
plugin was rebuilt from the 0.1.1 source with `make -B -C native/grabbar
CXX=g++`, and both `tests/run.sh` and `startup-nested.sh all` passed again
(exit 0, all 19 nested assertions) against that rebuilt binary.

- Release native binary SHA-256: `314f277574fb275a20a9ae183ae8c75fbb0b6fb6feafcb0fca58be800efdc749`.
- Release loader SHA-256: `eaa6586d69f5cc56c18924a06a1acff91462a5b7afced6889661281ac9496f39`.
- [Release build integration output](evidence/startup/release-0.1.1-startup.log).
- The release includes a source archive, the tested binary, and SHA256SUMS.

Full clean-install and UWSM/systemd login qualification remains pending;
this is a preview release. Historical broader UI tests are in
`QUALIFICATION.md`.

## Stable-release gate

Before a stable release, build the native plugin from the exact release source,
record source/artifact hashes, and pass the offline and applicable nested
suites against that artifact. In a disposable environment with a supported
Omarchy/Hyprland version, verify a clean installation and real UWSM/systemd
login, logout/login, guarded recovery after an unconfirmed attempt, and
removal/rollback. Validate the published install instructions there. Record
the results and limit compatibility claims to the tested versions.

No clean-install or full-login qualification of this latest loader patch
was performed in this session. The earlier controlled host trial recorded
in `SYSTEM-BREAKING-BUG.md` predates it.

## What the guard cannot guarantee

This is a native in-process compositor plugin. Its startup guard cannot
prevent the first native crash or certify all later runtime behavior. The
15-second marker only records that one startup remained alive long enough;
a crash after that marker is outside this guard's coverage. Manual native
plugin loading bypasses the Lua guard. Passing tests on this one Hyprland
build does not certify other builds or GPUs.
