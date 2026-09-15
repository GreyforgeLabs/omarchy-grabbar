#!/usr/bin/env bash
# Shell service against the native backend in the nested session, using a
# standalone Quickshell process (tests/integration/service-host.qml) instead
# of the live omarchy-shell. Covers: handshake + readiness, two-phase
# minimize with the journal written before commit, restore through the
# service, journal permissions, and recovery when the service process dies.
set -euo pipefail

SIG="${SIG:?nested Hyprland instance signature}"
NESTED_DISPLAY="${NESTED_DISPLAY:?nested Wayland display name}"
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/helpers/grabbar_backend.py"
STATE="$OUT/state"
HOST="$OUT/host"
HOST_QML="$HOST/shell.qml"
mkdir -p "$STATE" "$HOST/helpers"
# Quickshell only loads QML from inside its config folder: stage a copy.
cp "$ROOT/Service.qml" "$ROOT/GrabbarModel.js" "$HOST/"
cp "$ROOT/helpers/grabbar-journal" "$HOST/helpers/"
cp "$ROOT/tests/integration/service-host.qml" "$HOST_QML"

hc() { hyprctl -i "$SIG" "$@"; }
be() { HYPRLAND_INSTANCE_SIGNATURE="$SIG" python3 "$HELPER" --timeout 3 "$@"; }
ipc() { WAYLAND_DISPLAY="$NESTED_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$SIG" qs ipc -p "$HOST_QML" call tech.greyforge.grabbar "$@"; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; cleanup; exit 1; }
say() { echo; echo "== $*"; }
wsname() { hc -j clients | python3 -c 'import json,sys; d=[c for c in json.load(sys.stdin) if c["mapped"]]; print(d[0]["workspace"]["name"] if d else "")'; }
token() { be windows | python3 -c 'import json,sys; [print(json.loads(l)["token"]) for l in sys.stdin if json.loads(l).get("alive")=="1"]' | head -1; }

QSPID=""
cleanup() { if [[ -n "$QSPID" ]] && kill -0 "$QSPID" 2>/dev/null; then kill "$QSPID"; wait "$QSPID" 2>/dev/null || true; fi; }
trap cleanup EXIT

say "start the standalone service host on the nested display"
WAYLAND_DISPLAY="$NESTED_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$SIG" XDG_STATE_HOME="$STATE" \
  qs -p "$HOST_QML" > "$OUT/service-host.log" 2>&1 &
QSPID=$!
sleep 2.5
kill -0 "$QSPID" || { cat "$OUT/service-host.log"; fail "service host exited"; }
STATUS=$(ipc status)
echo "$STATUS" | tee "$OUT/status-1.json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["backend"]["connected"] and d["backend"]["ready"], d; assert d["restoreHost"], d' || fail "service did not connect as the shell"
hc grabbar | grep -q 'minimize: enabled' || fail "backend did not enable minimize after the service handshake"
pass "handshake: service welcomed as shell, restore host declared, minimize enabled"

say "two-phase minimize through the service (journal written before commit)"
TOK=$(token); [[ -n "$TOK" ]] || fail "no token"
be minimize "$TOK" | grep -q '"status": "ok"' || fail "minimizePrepare refused"
sleep 1.2
[ "$(wsname)" = "special:grabbar-minimized" ] || fail "window not hidden after service commit"
ipc status | python3 -c 'import json,sys; d=json.load(sys.stdin); e=[x for x in d["entries"] if x["status"]=="minimized"]; assert len(e)==1, d' || fail "service model has no minimized entry"
J="$STATE/grabbar/state.json"
[ -f "$J" ] || fail "journal not written"
[ "$(stat -c %a "$J")" = "600" ] || fail "journal mode is $(stat -c %a "$J")"
[ "$(stat -c %a "$STATE/grabbar")" = "700" ] || fail "state dir mode is $(stat -c %a "$STATE/grabbar")"
python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); assert j["schema"]==1 and j["entries"][0]["status"]=="minimized" and "title" not in j["entries"][0], j' "$J" || fail "journal content"
pass "minimize committed; journal at $J holds one minimized entry without a title"

say "restore through the service IPC"
ipc restore "$TOK" current | grep -q restoring || fail "service restore did not start"
sleep 1.0
[ "$(wsname)" != "special:grabbar-minimized" ] || fail "window still hidden"
ipc status | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["minimized"]==0 and not d["entries"], d' || fail "entry not cleared after confirmed restore"
python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); assert j["entries"]==[], j' "$J" || fail "journal not cleared"
pass "restore confirmed by the compositor, row and journal cleared"

say "service process killed with a minimized window -> backend grace recovery"
be minimize "$TOK" >/dev/null; sleep 1.2
[ "$(wsname)" = "special:grabbar-minimized" ] || fail "second minimize failed"
kill "$QSPID"; wait "$QSPID" 2>/dev/null || true; QSPID=""
sleep 3
[ "$(wsname)" != "special:grabbar-minimized" ] || fail "window stranded after service death"
hc grabbar | grep -q 'decorations: suspended' || fail "strip not suspended"
pass "backend returned the window and suspended after the service died"

say "service restarts with a stale journal entry -> reconciliation clears it without moving the window"
python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); assert j["entries"] and j["entries"][0]["status"]=="minimized"' "$J" || fail "journal should still hold the entry from before the kill"
WAYLAND_DISPLAY="$NESTED_DISPLAY" HYPRLAND_INSTANCE_SIGNATURE="$SIG" XDG_STATE_HOME="$STATE" \
  qs -p "$HOST_QML" > "$OUT/service-host-2.log" 2>&1 &
QSPID=$!
sleep 2.5
ipc status | tee "$OUT/status-after-restart.json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["backend"]["ready"] and d["minimized"]==0 and not d["entries"], d' || fail "stale entry survived reconciliation"
[ "$(wsname)" != "special:grabbar-minimized" ] || fail "window moved during reconciliation"
grep -q '"cleared":\["' "$OUT/service-host-2.log" || grep -q 'reconcile' "$OUT/service-host-2.log" || fail "no reconcile log"
pass "reconciliation: journal entry for a visible window cleared, window untouched"

echo
echo "all service scenarios passed; evidence in $OUT"
