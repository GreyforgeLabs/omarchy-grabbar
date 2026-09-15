#!/usr/bin/env bash
# Core native scenarios (the G0 gate) against an isolated nested Hyprland session.
#
# Preconditions (see docs/QUALIFICATION.md "Nested test rig"):
#   - a nested Hyprland instance is running; its instance signature is $SIG
#     and its Wayland socket is $NESTED_DISPLAY
#   - exactly one ordinary window (foot) is open in it
#   - the native backend is loaded there (hyprctl -i "$SIG" plugin load ...)
#   - tests/integration/vpointer/vpointer is built
#
# Every step records what the compositor actually reports; screenshots are
# taken from inside the nested session so the live desktop is never touched.
set -euo pipefail

SIG="${SIG:?nested Hyprland instance signature}"
NESTED_DISPLAY="${NESTED_DISPLAY:?nested Wayland display name, e.g. wayland-2}"
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
W="${NESTED_W:-1280}"
H="${NESTED_H:-800}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/helpers/grabbar_backend.py"
VP="$ROOT/tests/integration/vpointer/vpointer"
PLUGIN="${PLUGIN:-$ROOT/native/grabbar/grabbar.so}"

hc() { hyprctl -i "$SIG" "$@"; }
# Lua-config compositors reject the legacy `dispatch exec`; spawn through hl.dsp.exec_cmd.
spawn() { hc dispatch "hl.dsp.exec_cmd([[ $* ]])"; }
vp() { WAYLAND_DISPLAY="$NESTED_DISPLAY" "$VP" "$W" "$H" "$@"; }
shot() { WAYLAND_DISPLAY="$NESTED_DISPLAY" grim "$OUT/$1.png"; echo "  shot $OUT/$1.png"; }
be() { HYPRLAND_INSTANCE_SIGNATURE="$SIG" python3 "$HELPER" --timeout 3 "$@"; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; exit 1; }
say() { echo; echo "== $*"; }

# window facts from the compositor, not from Grabbar
win_json() { hc -j clients | python3 -c 'import json,sys; d=[c for c in json.load(sys.stdin) if c["mapped"]]; print(json.dumps(d[0] if d else {}))'; }
wf() { win_json | python3 -c "import json,sys; d=json.load(sys.stdin); v=d$1; print(json.dumps(v) if not isinstance(v,str) else v)"; }
token() { be windows | python3 -c 'import json,sys; [print(json.loads(l)["token"]) for l in sys.stdin if json.loads(l).get("alive")=="1"]' | head -1; }
gb() { be windows | python3 -c "import json,sys; d=[json.loads(l) for l in sys.stdin][0]; print(d.get('$1',''))"; }

# Background stand-ins are launched directly so $! is the python PID and a
# kill really closes the socket (a killed wrapper subshell would leave the
# client, and therefore the "shell", alive).
standin() { HYPRLAND_INSTANCE_SIGNATURE="$SIG" python3 "$HELPER" --timeout 3 listen --ready --auto-commit --seconds "$1" > "$2" 2>&1 & echo $!; }

say "shell stand-in (declares restore access, commits every minimize request)"
STANDIN=$(standin 300 "$OUT/shell-standin.log")
sleep 1
hc grabbar | tee "$OUT/status-active.txt" | grep -q 'decorations: active' || fail "strip not active with a ready shell"
pass "backend active after readiness handshake"

TOK=$(token)
[ -n "$TOK" ] || fail "no window token"
echo "token $TOK"
AT=$(wf '["at"]'); SZ=$(wf '["size"]')
X=$(echo "$AT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')
Y=$(echo "$AT" | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])')
WW=$(echo "$SZ" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')
STRIP_Y=$((Y - 17))            # strip is the 34 px reserved band above the client
CLOSE_X=$((X + WW - 4 - 16))   # right group: [min][max][close], 32 px each, 4 px padding
MAX_X=$((CLOSE_X - 32))
MIN_X=$((MAX_X - 32))
TITLE_X=$((X + WW / 2))
echo "client at $X,$Y size $SZ; strip y=$STRIP_Y; close x=$CLOSE_X max x=$MAX_X min x=$MIN_X"
shot 01-active

say "F03: press Close, drag away, release -> no close"
BEFORE=$(hc -j clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
vp move "$CLOSE_X" "$STRIP_Y" sleep 200
shot 02-close-hover
vp down sleep 100 move "$((CLOSE_X - 200))" "$((STRIP_Y + 200))" sleep 100 up sleep 300
AFTER=$(hc -j clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$BEFORE" = "$AFTER" ] || fail "window closed after drag-away release"
pass "F03 drag-away cancels Close ($BEFORE window(s) before and after)"

say "F04: Maximize / Restore size by button"
vp click "$MAX_X" "$STRIP_Y" sleep 400
[ "$(wf '["fullscreen"]')" = "1" ] || fail "compositor does not report maximized (fullscreen=1)"
[ "$(gb maximized)" = "1" ] || fail "backend does not report maximized"
shot 03-maximized
MAT=$(wf '["at"]'); echo "maximized client at $MAT size $(wf '["size"]')"
vp click "$MAX_X" "$STRIP_Y" sleep 400
[ "$(wf '["fullscreen"]')" = "0" ] || fail "restore size did not clear maximized"
pass "F04 maximize keeps the strip and restore size returns (strip stayed reachable at y=$STRIP_Y)"

say "double-click on the title toggles maximize"
vp dblclick "$TITLE_X" "$STRIP_Y" sleep 400
[ "$(wf '["fullscreen"]')" = "1" ] || fail "double-click did not maximize"
vp dblclick "$TITLE_X" "$STRIP_Y" sleep 400
[ "$(wf '["fullscreen"]')" = "0" ] || fail "second double-click did not restore"
pass "double-click maximize/restore"

say "F06: Minimize by button -> hidden on Grabbar's workspace, then restore"
vp click "$MIN_X" "$STRIP_Y" sleep 600
[ "$(wf '["workspace"]["name"]')" = "special:grabbar-minimized" ] || fail "window is not on special:grabbar-minimized"
[ "$(gb owned)" = "1" ] || fail "backend does not own the hidden window"
shot 04-minimized
be restore "$TOK" | tee "$OUT/restore.json" | grep -q '"status": "ok"' || fail "restore failed"
sleep 0.4
[ "$(wf '["workspace"]["name"]')" != "special:grabbar-minimized" ] || fail "window still hidden after restore"
[ "$(gb owned)" = "0" ] || fail "backend still owns the window"
[ "$(wf '["floating"]')" = "false" ] || fail "tiled window came back floating"
shot 05-restored
pass "F06 minimize -> restore returns the same window (address $(wf '["address"]')) tiled"

say "stale-target: a token from before a restore/close cycle cannot act on another window"
be restore "$TOK" | grep -q '"status": "refused"' || fail "restoring a visible window was not refused"
pass "restore of a visible window refused, not redirected"

say "F10: drag the title of a tiled window -> detaches into floating and follows the pointer"
vp drag "$TITLE_X" "$STRIP_Y" "$((TITLE_X - 300))" "$((STRIP_Y + 260))" 25 sleep 500
[ "$(wf '["floating"]')" = "true" ] || fail "tiled window did not detach into floating"
DAT=$(wf '["at"]'); echo "after drag: at $DAT size $(wf '["size"]')"
shot 06-dragged-floating
be float "$TOK" off | grep -q '"status": "ok"' || fail "return to tiling failed"
sleep 1.2   # let the layout animation finish before clicking the strip again
[ "$(wf '["floating"]')" = "false" ] || fail "window did not return to tiling"
pass "F10 tiled drag detaches; Move freely off returns it to the layout"

say "F04b: with two tiled windows, Maximize fills the work area and Restore size rejoins the layout"
spawn foot >/dev/null
sleep 1.2
N=$(hc -j clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$N" = "2" ] || fail "expected 2 windows, got $N"
TILED_W=$(wf '["size"][0]')
be maximize "$TOK" | grep -q '"status": "ok"' || fail "maximize action failed"
sleep 0.6
MAXW=$(wf '["size"][0]')
[ "$MAXW" -gt "$TILED_W" ] || fail "maximized width $MAXW not larger than tiled width $TILED_W"
shot 06b-two-windows-maximized
be restore-size "$TOK" | grep -q '"status": "ok"' || fail "restore size failed"
sleep 0.6
[ "$(wf '["size"][0]')" = "$TILED_W" ] || fail "window did not rejoin the layout at its tiled width"
TOK2=$(be windows | python3 -c 'import json,sys; [print(json.loads(l)["token"]) for l in sys.stdin if json.loads(l)["token"]!="'"$TOK"'"]' | head -1)
be close "$TOK2" | grep -q '"status": "ok"' || fail "close action failed"
sleep 0.8
N=$(hc -j clients | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$N" = "1" ] || fail "second window did not close"
be restore "$TOK2" | grep -q '"status": "stale"' || fail "closed window's token was not reported stale"
sleep 1.0
pass "F04b maximize $TILED_W -> $MAXW px wide with the strip kept; close by action; dead token is stale"

say "R02: shell service lost with a minimized window -> returned after the grace period, controls suspended"
vp click "$MIN_X" "$STRIP_Y" sleep 600
[ "$(wf '["workspace"]["name"]')" = "special:grabbar-minimized" ] || fail "second minimize failed"
kill "$STANDIN"; wait "$STANDIN" 2>/dev/null || true
sleep 0.5
hc grabbar | grep -q 'minimize: disabled' || fail "minimize still enabled right after shell loss"
sleep 2.5
[ "$(wf '["workspace"]["name"]')" != "special:grabbar-minimized" ] || fail "window still hidden after grace period"
hc grabbar | tee "$OUT/status-suspended.txt" | grep -q 'decorations: suspended' || fail "decorations not suspended"
shot 07-recovered-suspended
pass "R02 hidden window returned within the 2 s grace and the strip suspended"

say "R03: native unload with a minimized window -> window returned before unload"
STANDIN=$(standin 60 "$OUT/shell-standin2.log")
sleep 1
be minimize "$TOK" > "$OUT/minimize-for-unload.json" || true
sleep 0.6
[ "$(wf '["workspace"]["name"]')" = "special:grabbar-minimized" ] || fail "minimize before unload failed"
hc plugin unload "$PLUGIN" >/dev/null
sleep 0.5
[ "$(wf '["workspace"]["name"]')" != "special:grabbar-minimized" ] || fail "window stranded after unload"
hc plugins list | grep -q grabbar && fail "plugin still loaded"
kill "$STANDIN" 2>/dev/null || true
shot 08-after-unload
pass "R03 unload returned the hidden window"

say "reload for further manual work"
hc plugin load "$PLUGIN" >/dev/null
echo
echo "all G0 nested scenarios passed; evidence in $OUT"
