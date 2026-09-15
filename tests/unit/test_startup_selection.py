#!/usr/bin/env python3
"""Exercise startup mode selection with a fake compositor client, never Hyprland."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "tests/integration/startup-nested.sh"

with tempfile.TemporaryDirectory() as td:
    sandbox = Path(td)
    runtime = sandbox / "runtime"
    host = runtime / "hypr/host"
    host.mkdir(parents=True)
    (host / "hyprland.lock").write_text(f"{os.getpid()}\n")
    calls = sandbox / "calls.jsonl"
    client = sandbox / "hyprctl"
    client.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['-j', 'monitors']:
    print('[]')
    sys.exit(0)
sys.exit(1)  # Stop at launch; no compositor is ever started.
""")
    client.chmod(0o755)
    env = {**os.environ, "PATH": f"{sandbox}:{os.environ['PATH']}",
           "TEST_CALLS": str(calls), "XDG_RUNTIME_DIR": str(runtime),
           "HYPRLAND_INSTANCE_SIGNATURE": "host", "HEADLESS_WS": "999",
           "GUARD_STATE": str(sandbox / "guard"), "OUT": str(sandbox / "out")}

    # Invalid/retired modes must fail before even requiring a desktop session.
    offline = {k: v for k, v in env.items() if k not in
               ("HEADLESS_WS", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR")}
    for mode in ("repro", "typo"):
        result = subprocess.run(["bash", str(RUNNER), mode], env=offline,
                                capture_output=True, text=True, timeout=5)
        assert result.returncode == 2, result.stderr
        assert not calls.exists(), "rejected mode contacted the compositor"
        assert not (sandbox / "out").exists(), "rejected mode created output"

    for args, fixture in (([], "fixed"), (["all"], "fixed"),
                          (["fixed"], "fixed"), (["guard"], "guarded")):
        calls.unlink(missing_ok=True)
        result = subprocess.run(["bash", str(RUNNER), *args], env=env,
                                capture_output=True, text=True, timeout=5)
        assert result.returncode == 1, result.stdout + result.stderr
        commands = [json.loads(line) for line in calls.read_text().splitlines()]
        launches = [c for c in commands if c[0] == "dispatch"]
        assert len(launches) == 1, commands
        assert f"/autoload-{fixture}.lua" in launches[0][1], launches
        assert "autoload-failed" not in str(commands), commands

    # Old direct invocations stop before touching any plugin or base config.
    if shutil.which("lua"):
        result = subprocess.run(
            ["lua", str(ROOT / "tests/integration/nested/autoload-failed.lua")],
            env=offline, capture_output=True, text=True, timeout=5)
        assert result.returncode != 0 and "Retired crash fixture" in result.stderr, result
    else:
        print("test_startup_selection: Lua not installed, skipping retired entry point")

print("test_startup_selection: ok")
