#!/usr/bin/env python3
"""helpers/grabbar-autoload: hook install/remove is idempotent, backed up, and
byte-exact on removal; the guard state machine reports the right states."""
import importlib.machinery, importlib.util, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(ROOT, "helpers", "grabbar-autoload")
spec = importlib.util.spec_from_loader("al", importlib.machinery.SourceFileLoader("al", HELPER))
al = importlib.util.module_from_spec(spec); spec.loader.exec_module(al)

with tempfile.TemporaryDirectory() as td:
    cfg = os.path.join(td, "hyprland.lua"); state = os.path.join(td, "state")
    original = "-- user config\nrequire(\"hypr.monitors\")\n"
    open(cfg, "w").write(original)
    # enable: appends the hook once, backs up, arms
    r = al.enable(state, cfg); assert r.startswith("installed"), r
    text = open(cfg).read(); assert text.count(al.BEGIN) == 1 and "pcall(dofile" in text and text.startswith(original), text
    assert os.path.exists(os.path.join(state, "autoload", "enabled"))
    assert any(f.startswith("hyprland.lua.bak.") for f in os.listdir(td))
    # the installed line must not depend on plugin state (the 2026-09-15 defect)
    assert "get_loaded_plugins" not in text and "if not loaded" not in text
    assert al.enable(state, cfg) == "already-installed" and open(cfg).read().count(al.BEGIN) == 1
    # status states
    assert al.status(state, cfg)["state"] == "armed"
    os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "sigB"
    d = os.path.join(state, "autoload")
    open(os.path.join(d, "last-attempt"), "w").write("sigA\n")
    assert al.status(state, cfg)["state"] == "skipped-after-failed-start"
    open(os.path.join(d, "last-ok"), "w").write("sigA\n")
    assert al.status(state, cfg)["state"] == "armed"
    open(os.path.join(d, "last-attempt"), "w").write("sigB\n")
    assert al.status(state, cfg)["state"] == "active-this-session-unconfirmed"
    open(os.path.join(d, "last-ok"), "w").write("sigB\n")
    assert al.status(state, cfg)["state"] == "active-this-session"
    open(os.path.join(d, "last-attempt"), "w").write("sigA\n"); open(os.path.join(d, "last-ok"), "w").write("sigZ\n")
    al.retry(state); assert al.status(state, cfg)["state"] == "armed"
    al.disarm(state); assert al.status(state, cfg)["state"] == "disarmed"
    # disable: byte-exact restore of the original text
    r = al.disable(state, cfg); assert r.startswith("removed"), r
    assert open(cfg).read() == original, repr(open(cfg).read())
    assert al.status(state, cfg)["state"] == "not-installed"
    assert al.disable(state, cfg) == "not-installed"
    # the shipped Lua must parse and must not reference loaded-plugin state
    lua = open(os.path.join(ROOT, "native", "autoload.lua")).read()
    assert "get_loaded_plugins" not in lua
    v = subprocess.run(["Hyprland", "--verify-config", "-c", os.path.join(ROOT, "native", "autoload.lua")],
                       capture_output=True, text=True, env={**os.environ, "GRABBAR_SO": "/dev/null", "GRABBAR_STATE_DIR": td})
    assert "config ok" in (v.stdout + v.stderr).lower(), v.stdout + v.stderr
print("test_autoload: ok")
