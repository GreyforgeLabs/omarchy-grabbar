#!/usr/bin/env python3
"""Client for the Grabbar native backend socket (protocol 1).

Used by the CLI, the integration tests, and as a stand-in shell service during
the G0 feasibility work. Standard library only; short-lived.

Wire format: one message per line, fields separated by tabs, the first field is
the message type, the rest are key=value with control characters, '%', tab and
newline percent-encoded.
"""

import argparse
import json
import os
import select
import socket
import sys
import time

PROTOCOL = 1
MAX_LINE = 4096


_HEX = "0123456789ABCDEFabcdef"


def encode(value):
    out = []
    for ch in str(value):
        code = ord(ch)
        if code < 0x20 or code == 0x7F or ch in "%\t\n":
            out.append("%%%02X" % code)
        else:
            out.append(ch)
    return "".join(out)


def decode(value):
    s = str(value)
    out = []
    i = 0
    while i < len(s):
        if s[i] == "%" and i + 2 < len(s) and s[i + 1] in _HEX and s[i + 2] in _HEX:
            out.append(chr(int(s[i + 1:i + 3], 16)))
            i += 3
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def build(msg_type, **fields):
    parts = [msg_type]
    for k, v in fields.items():
        if v is None:
            continue
        parts.append("%s=%s" % (k, encode(v)))
    return "\t".join(parts) + "\n"


def parse(line):
    parts = line.rstrip("\n").split("\t")
    msg = {"type": parts[0]}
    for part in parts[1:]:
        if not part:
            continue
        k, _, v = part.partition("=")
        msg[k] = decode(v)
    return msg


def socket_path(session=None):
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    session = session or os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if not runtime or not session:
        return None
    return os.path.join(runtime, "grabbar", session, "backend.sock")


class BackendClient:
    def __init__(self, path=None, session=None, timeout=2.0):
        self.path = path or socket_path(session)
        self.session = session or os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        self.timeout = timeout
        self.sock = None
        self.buf = b""
        self.welcome = None
        self._seq = 0

    # ---------------------------------------------------------- transport
    def connect(self, role="observer"):
        if not self.path:
            raise RuntimeError("no socket path (XDG_RUNTIME_DIR / HYPRLAND_INSTANCE_SIGNATURE unset)")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.path)
        self.sock = s
        self.send("hello", protocol=PROTOCOL, client=role, sessionId=self.session)
        self.welcome = self.wait("welcome", alt=("error",))
        if self.welcome["type"] == "error":
            raise RuntimeError("backend refused hello: %s" % self.welcome)
        return self.welcome

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def send(self, msg_type, **fields):
        line = build(msg_type, **fields)
        if len(line) > MAX_LINE:
            raise ValueError("message too long")
        self.sock.sendall(line.encode("utf-8"))

    def read(self, timeout=None):
        """Return the next message or None on timeout."""
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line = self.buf[:nl].decode("utf-8", "replace")
                self.buf = self.buf[nl + 1:]
                return parse(line)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            r, _, _ = select.select([self.sock], [], [], remaining)
            if not r:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("backend closed the connection")
            self.buf += chunk

    def wait(self, msg_type, alt=(), timeout=None, predicate=None):
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("no %s from backend" % msg_type)
            msg = self.read(remaining)
            if msg is None:
                raise TimeoutError("no %s from backend" % msg_type)
            if msg["type"] == msg_type or msg["type"] in alt:
                if predicate is None or predicate(msg):
                    return msg

    # ------------------------------------------------------------- calls
    def next_request(self):
        self._seq += 1
        return "c%d-%d" % (os.getpid(), self._seq)

    def ready(self, restore_access=True):
        self.send("ready", restoreAccess="1" if restore_access else "0")
        return self.wait("state")

    def snapshot(self):
        self.send("snapshot")
        windows = []
        while True:
            msg = self.wait("window", alt=("snapshotEnd",))
            if msg["type"] == "snapshotEnd":
                return windows
            windows.append(msg)

    def status(self):
        self.send("status")
        msg = self.wait("status")
        return json.loads(msg.get("json", "{}"))

    def action(self, action, token="", request_id=None, **extra):
        rid = request_id or self.next_request()
        self.send("action", requestId=rid, windowToken=token, action=action, **extra)
        return self.wait("result", predicate=lambda m: m.get("requestId") == rid)

    def minimize(self, token):
        """Full two-phase minimize as the shell would do it."""
        self.action("minimizePrepare", token)
        req = self.wait("minimizeRequest", alt=("notice",), predicate=lambda m: m.get("token") == token or m["type"] == "notice")
        if req["type"] == "notice":
            return {"status": "refused", "error": req.get("text", ""), "type": "result"}
        # A real shell writes its `prepared` journal record here.
        return self.action("minimizeCommit", token, request_id=req["requestId"])


def _print(msg):
    sys.stdout.write(json.dumps(msg, sort_keys=True) + "\n")
    sys.stdout.flush()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Grabbar backend socket client")
    ap.add_argument("--session", help="Hyprland instance signature (default: $HYPRLAND_INSTANCE_SIGNATURE)")
    ap.add_argument("--role", default="observer", choices=("observer", "shell"))
    ap.add_argument("--timeout", type=float, default=2.0)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("windows")
    p = sub.add_parser("ready")
    p.add_argument("--no-restore-access", action="store_true")
    p = sub.add_parser("minimize")
    p.add_argument("token")
    p = sub.add_parser("restore")
    p.add_argument("token")
    p.add_argument("--original", action="store_true")
    p.add_argument("--monitor", default="")
    p.add_argument("--no-focus", action="store_true")
    sub.add_parser("restore-all")
    for name in ("maximize", "restore-size", "toggle-maximize", "close"):
        p = sub.add_parser(name)
        p.add_argument("token")
    p = sub.add_parser("float")
    p.add_argument("token")
    p.add_argument("value", choices=("on", "off"))
    p = sub.add_parser("listen")
    p.add_argument("--seconds", type=float, default=10.0)
    p.add_argument("--ready", action="store_true", help="declare restore access so minimize works")
    p.add_argument("--auto-commit", action="store_true", help="commit every minimizeRequest (shell stand-in)")
    args = ap.parse_args(argv)

    c = BackendClient(session=args.session, timeout=args.timeout)
    role = "shell" if args.cmd in ("ready", "listen") or args.role == "shell" else "observer"
    c.connect(role)
    try:
        if args.cmd == "status":
            _print(c.status())
        elif args.cmd == "windows":
            for w in c.snapshot():
                _print(w)
        elif args.cmd == "ready":
            _print(c.ready(not args.no_restore_access))
        elif args.cmd == "minimize":
            if role == "shell":
                # Stand-alone: this process is the shell and commits itself.
                c.ready(True)
                _print(c.minimize(args.token))
            else:
                # A shell is connected: ask it to run the prepare/commit flow.
                _print(c.action("minimizePrepare", args.token))
        elif args.cmd == "restore":
            _print(c.action("restore", args.token, destination="original" if args.original else "current", monitor=args.monitor, focus="0" if args.no_focus else "1"))
        elif args.cmd == "restore-all":
            _print(c.action("restoreAll"))
        elif args.cmd == "maximize":
            _print(c.action("maximize", args.token))
        elif args.cmd == "restore-size":
            _print(c.action("restoreSize", args.token))
        elif args.cmd == "toggle-maximize":
            _print(c.action("toggleMaximize", args.token))
        elif args.cmd == "close":
            _print(c.action("close", args.token))
        elif args.cmd == "float":
            _print(c.action("setFloating", args.token, value="1" if args.value == "on" else "0"))
        elif args.cmd == "listen":
            if args.ready:
                _print(c.ready(True))
            end = time.monotonic() + args.seconds
            while time.monotonic() < end:
                msg = c.read(min(0.5, max(0.01, end - time.monotonic())))
                if msg is None:
                    continue
                _print(msg)
                if args.auto_commit and msg["type"] == "minimizeRequest":
                    _print(c.action("minimizeCommit", msg["token"], request_id=msg["requestId"]))
    finally:
        c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
