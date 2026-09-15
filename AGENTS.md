# GRABBAR development warning

Read [SYSTEM-BREAKING-BUG.md](SYSTEM-BREAKING-BUG.md) before working on this
project. A native plugin load/reload and autostart failure made the GreyArch
desktop unusable and persisted across restarts.

Keep native GRABBAR disabled on the operator's desktop. Use a disposable VM
with a snapshot for native execution and regression testing. Do not load,
reload, or autostart the native plugin in the host compositor as part of
routine development. Earlier qualification notes predate this incident and
do not establish startup safety. The warning records evidence, recovery
state, and the conditions for a later controlled host trial.

