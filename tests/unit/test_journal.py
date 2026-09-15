#!/usr/bin/env python3
"""Recovery journal helper: atomic replace, refusals, quarantine, bounds."""
import json
import os
import stat
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(ROOT, "helpers", "grabbar-journal")


def run(cmd, state_dir, stdin=""):
    p = subprocess.run([sys.executable, HELPER, cmd, "--state-dir", state_dir], input=stdin, capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


def doc(entries=None, session="s1"):
    return json.dumps({"schema": 1, "session": session, "epoch": "1", "sequence": 1, "entries": entries or []})


def main():
    with tempfile.TemporaryDirectory() as tmp:
        sd = os.path.join(tmp, "grabbar")

        assert run("read", sd)["status"] == "empty"

        r = run("write", sd, doc())
        assert r["status"] == "ok", r
        st = os.lstat(os.path.join(sd, "state.json"))
        assert stat.S_IMODE(st.st_mode) == 0o600, oct(st.st_mode)
        assert stat.S_IMODE(os.lstat(sd).st_mode) == 0o700

        r = run("read", sd)
        assert r["status"] == "ok" and json.loads(r["text"])["schema"] == 1

        # refuses non-journal and non-JSON documents, keeps the previous file
        assert run("write", sd, "{nope")["status"] == "error"
        assert run("write", sd, json.dumps({"schema": 2}))["status"] == "error"
        assert json.loads(run("read", sd)["text"])["session"] == "s1"

        # oversized document refused
        big = json.dumps({"schema": 1, "session": "s1", "entries": [], "pad": "x" * 300000})
        assert run("write", sd, big)["status"] == "error"

        # symlinked state file is never followed or replaced
        path = os.path.join(sd, "state.json")
        os.unlink(path)
        victim = os.path.join(tmp, "victim.json")
        with open(victim, "w") as fh:
            fh.write("{\"schema\":1,\"session\":\"x\",\"entries\":[]}")
        os.symlink(victim, path)
        assert run("read", sd)["status"] == "symlink"
        assert run("write", sd, doc())["status"] == "error"
        with open(victim) as fh:
            assert "\"x\"" in fh.read(), "victim was modified through the symlink"
        q = run("quarantine", sd)
        assert q["status"] == "ok" and q["path"].endswith(".quarantined.json")
        assert not os.path.lexists(path)

        # quarantine keeps a diagnostic copy of a corrupt file
        with open(path, "w") as fh:
            fh.write("garbage")
        q = run("quarantine", sd, "")
        assert q["status"] == "ok"
        with open(q["path"]) as fh:
            assert fh.read() == "garbage"
        assert run("inspect", sd)["status"] == "missing"

        # state directory that is a symlink is refused
        sd2 = os.path.join(tmp, "link-dir")
        os.symlink(tmp, sd2)
        assert run("write", sd2, doc())["status"] == "error"

    print("test_journal: ok")


if __name__ == "__main__":
    main()
