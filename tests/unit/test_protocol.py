#!/usr/bin/env python3
"""Backend protocol codec in the Python client matches the native/JS format."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "helpers"))

import grabbar_backend as gb  # noqa: E402


def main():
    nasty = "a\tb\nc%d\x07eé ✕"
    assert gb.decode(gb.encode(nasty)) == nasty
    enc = gb.encode(nasty)
    assert "\t" not in enc and "\n" not in enc
    line = gb.build("action", requestId="r1", windowToken="g1-2", action="restore", title="x\ty=z")
    assert line == "action\trequestId=r1\twindowToken=g1-2\taction=restore\ttitle=x%09y=z\n", line
    assert gb.parse(line) == {"type": "action", "requestId": "r1", "windowToken": "g1-2", "action": "restore", "title": "x\ty=z"}
    assert gb.parse("pong\t\tflag\tepoch=7\n") == {"type": "pong", "flag": "", "epoch": "7"}
    assert gb.build("x", a=None) == "x\n"
    try:
        gb.BackendClient(path=None, session="")
        c = gb.BackendClient(path=None, session="")
        assert c.path is None or c.path.endswith("backend.sock")
    except RuntimeError:
        pass
    print("test_protocol: ok")


if __name__ == "__main__":
    main()
