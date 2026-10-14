#!/usr/bin/env python3
"""bin/grabbar against a fake backend socket and a stub omarchy-shell.

No compositor, no real shell: the backend is a tiny in-process server that
speaks protocol 1, and omarchy-shell is a script answering from env vars.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "helpers"))
import grabbar_backend as gb  # noqa: E402

STATUS = {"version": "test", "protocol": 1, "epoch": 77, "sessionId": "sig", "socket": "", "shellConnected": False,
          "minimizeEnabled": True, "suspended": False, "paused": False, "tracked": 3, "owned": 2, "ownedWorkspace": True, "apiHash": "x"}


def serve(listener, stop):
    listener.settimeout(0.2)
    while not stop.is_set():
        try:
            conn, _ = listener.accept()
        except socket.timeout:
            continue
        with conn:
            buf = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    msg = gb.parse(line.decode())
                    if msg["type"] == "hello":
                        conn.sendall(gb.build("welcome", protocol=1, backendEpoch=77, sessionId="sig", role="observer").encode())
                    elif msg["type"] == "status":
                        conn.sendall(gb.build("status", json=json.dumps(STATUS)).encode())
                    elif msg["type"] == "action":
                        status = "ok" if msg.get("windowToken") == "g77-1" else "stale"
                        conn.sendall(gb.build("result", requestId=msg["requestId"], action=msg["action"], status=status, error="").encode())


def main():
    with tempfile.TemporaryDirectory() as td:
        runtime = os.path.join(td, "run")
        os.makedirs(os.path.join(runtime, "grabbar", "sig"))
        stub = os.path.join(td, "bin")
        os.mkdir(stub)
        with open(os.path.join(stub, "omarchy-shell"), "w") as f:
            f.write('#!/bin/sh\ncase "$2" in\n  status) printf "%s" "$TEST_SHELL_STATUS";;\n'
                    '  ping) printf "%s" "$TEST_SHELL_PING";;\n  restore) printf "%s" "$TEST_SHELL_RESTORE";;\nesac\n')
        os.chmod(os.path.join(stub, "omarchy-shell"), 0o755)
        env = {**os.environ, "PATH": stub + os.pathsep + os.environ["PATH"], "XDG_RUNTIME_DIR": runtime,
               "HYPRLAND_INSTANCE_SIGNATURE": "sig", "TEST_SHELL_STATUS": "", "TEST_SHELL_PING": "", "TEST_SHELL_RESTORE": ""}

        def cli(*args, **extra):
            return subprocess.run([os.path.join(ROOT, "bin", "grabbar"), *args], env={**env, **extra},
                                  capture_output=True, text=True, timeout=20)

        # Nothing running at all.
        r = cli("status", "--json")
        d = json.loads(r.stdout)
        assert r.returncode == 0 and d["backend"] is None and d["shell"] is None and not d["summary"]["backendLoaded"], r.stdout
        assert cli("restore", "not-a-token").returncode == 2
        assert cli("restore", "g77-1").returncode == 3  # neither shell nor backend

        path = os.path.join(runtime, "grabbar", "sig", "backend.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(4)
        stop = threading.Event()
        thread = threading.Thread(target=serve, args=(listener, stop), daemon=True)
        thread.start()
        try:
            r = cli("status", "--json", TEST_SHELL_STATUS='{"schema":1,"paused":false}')
            d = json.loads(r.stdout)
            assert d["backend"]["epoch"] == 77 and d["shell"] == {"schema": 1, "paused": False}, d
            assert d["summary"] == {"backendLoaded": True, "shellRunning": True, "minimizeEnabled": True,
                                    "decorations": "active", "minimized": 2}, d["summary"]
            r = cli("status")
            assert r.returncode == 0 and "loaded (epoch 77)" in r.stdout and "minimized       2" in r.stdout, r.stdout
            # Shell answers take precedence; "offline" means the backend is unavailable.
            assert cli("restore", "g77-1", TEST_SHELL_RESTORE="restoring").returncode == 0
            assert cli("restore", "g77-1", TEST_SHELL_RESTORE="unknown").returncode == 4
            assert cli("restore", "g77-1", TEST_SHELL_RESTORE="offline").returncode == 3
            # No shell: the backend answers directly.
            r = cli("restore", "g77-1")
            assert r.returncode == 0 and '"status": "ok"' in r.stdout, r.stdout + r.stderr
            assert cli("restore", "g77-9").returncode == 4
        finally:
            stop.set()
            thread.join(2)
            listener.close()
    print("test_cli: ok")


if __name__ == "__main__":
    main()
