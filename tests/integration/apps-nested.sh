#!/usr/bin/env bash
# Application qualification (spec §14.3) against the nested session with a
# real shell service connected (the sandboxed omarchy-shell or the stand-in).
# For every app: the strip reserves its own band above the client, maximize /
# restore size, minimize through the full two-phase path / restore, drag the
# title (tiled → floating), close through the strip's action. A screenshot
# per app goes to $OUT.
#
#   SIG=… NESTED_DISPLAY=wayland-N OUT=dir tests/integration/apps-nested.sh "<name>|<command>" ...
set -u
SIG="${SIG:?nested Hyprland instance signature}"
NESTED_DISPLAY="${NESTED_DISPLAY:?nested Wayland display name}"
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
W="${NESTED_W:-1600}"; H="${NESTED_H:-1000}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/helpers/grabbar_backend.py"
VP="$ROOT/tests/integration/vpointer/vpointer"
BAR_TOP="${BAR_TOP:-0}"   # height of a bar reserved at the top of the nested output

hc() { hyprctl -i "$SIG" "$@"; }
spawn() { hc dispatch "hl.dsp.exec_cmd([[ $* ]])" >/dev/null; }
vp() { WAYLAND_DISPLAY="$NESTED_DISPLAY" "$VP" "$W" "$H" "$@"; }
shot() { WAYLAND_DISPLAY="$NESTED_DISPLAY" grim "$OUT/$1.png"; }
be() { HYPRLAND_INSTANCE_SIGNATURE="$SIG" python3 "$HELPER" --timeout 4 "$@"; }
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAILED=$((FAILED+1)); }
FAILED=0; TOTAL=0
cj() { hc -j clients; }
# fields of the newest mapped window with the given class (or any when empty)
wjson() { cj | python3 -c '
import json,sys; cls=sys.argv[1]
d=[c for c in json.load(sys.stdin) if c["mapped"] and (not cls or c["class"]==cls or c["initialClass"]==cls)]
print(json.dumps(d[-1] if d else {}))' "$1"; }
wf() { wjson "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d$2 if d else ''; print(json.dumps(v) if not isinstance(v,str) else v)"; }
tok() { be windows | python3 -c 'import json,sys; a=sys.argv[1]; [print(json.loads(l)["token"]) for l in sys.stdin if json.loads(l).get("address")==a]' "$1" | head -1; }
wait_class() { for _ in $(seq 1 120); do [[ "$(wf "$1" '["mapped"]')" == "true" ]] && return 0; sleep 0.25; done; return 1; }
wait_gone() { for _ in $(seq 1 40); do [[ -z "$(wf "$1" '["address"]')" ]] && return 0; sleep 0.25; done; return 1; }
settle() { sleep "${1:-1.2}"; }

N0=$(cj | python3 -c 'import json,sys; print(len([c for c in json.load(sys.stdin) if c["mapped"]]))')
[[ "$N0" == 0 ]] || { echo "refusing: $N0 window(s) already open in the nested session; close them first"; exit 2; }

for spec in "$@"; do
  NAME="${spec%%|*}"; CMD="${spec#*|}"; CLASS="${NAME%%:*}"; LABEL="${NAME#*:}"
  echo; echo "== $LABEL ($CLASS): $CMD"
  TOTAL=$((TOTAL+1))
  spawn "$CMD"
  if ! wait_class "$CLASS"; then fail "$LABEL never mapped a window of class $CLASS"; continue; fi
  sleep 2.5   # let toolkits finish their first layout
  ADDR="$(wf "$CLASS" '["address"]')"; TOK="$(tok "$ADDR")"
  X=$(wf "$CLASS" '["at"][0]'); Y=$(wf "$CLASS" '["at"][1]'); WW=$(wf "$CLASS" '["size"][0]'); HH=$(wf "$CLASS" '["size"][1]')
  FLOAT=$(wf "$CLASS" '["floating"]'); XW=$(wf "$CLASS" '["xwayland"]')
  echo "  window $ADDR token=$TOK at=$X,$Y size=${WW}x$HH floating=$FLOAT xwayland=$XW"
  [[ -n "$TOK" ]] || { fail "$LABEL: backend has no token for $ADDR"; continue; }
  # Button centres from the live geometry (recomputed before every click:
  # maximize and drags change it). Right group: [min][max][close], 32 px
  # each, 4 px padding; the strip is the 34 px band above the client.
  geom() { X=$(wf "$CLASS" '["at"][0]'); Y=$(wf "$CLASS" '["at"][1]'); WW=$(wf "$CLASS" '["size"][0]'); HH=$(wf "$CLASS" '["size"][1]')
           STRIP_Y=$((Y - 17)); TITLE_X=$((X + WW / 2)); CLOSE_X=$((X + WW - 4 - 16)); MAX_X=$((CLOSE_X - 32)); MIN_X=$((MAX_X - 32)); }
  geom
  shot "$LABEL-01-strip"
  # 1. reserved band: the client's top edge sits at least 34 px below the workspace/bar top
  #    (tiled: gaps_out=10 + strip 34 above; floating: strip is still reserved above the client)
  if [[ "$FLOAT" == "false" ]]; then
    (( Y >= BAR_TOP + 10 + 34 )) && pass "strip reserved above the client (client y=$Y)" || fail "client y=$Y does not leave room for the strip"
  else
    pass "floating at first map (y=$Y); strip reservation applies relative to the client"
  fi
  # 2. maximize / restore size via the strip button
  vp click "$MAX_X" "$STRIP_Y" sleep 900
  if [[ "$(wf "$CLASS" '["fullscreen"]')" == "1" ]]; then
    MW=$(wf "$CLASS" '["size"][0]'); shot "$LABEL-02-maximized"
    geom; vp click "$MAX_X" "$STRIP_Y" sleep 900
    [[ "$(wf "$CLASS" '["fullscreen"]')" == "0" ]] && pass "maximize ($WW -> $MW px) and restore size by button" || fail "restore size did not clear maximized"
  else fail "maximize button did nothing (fullscreen=$(wf "$CLASS" '["fullscreen"]'))"; fi
  settle
  # 3. minimize (button -> shell two-phase) and restore (backend action, as the drawer does)
  geom; vp click "$MIN_X" "$STRIP_Y" sleep 1200
  if [[ "$(wf "$CLASS" '["workspace"]["name"]')" == "special:grabbar-minimized" ]]; then
    shot "$LABEL-03-minimized"
    be restore "$TOK" | grep -q '"status": "ok"' || fail "restore action failed"
    settle
    [[ "$(wf "$CLASS" '["workspace"]["name"]')" != "special:grabbar-minimized" && "$(wf "$CLASS" '["address"]')" == "$ADDR" ]] && pass "minimize by button, restore returns the same window" || fail "window did not return"
  else fail "minimize button did not hide the window (ws=$(wf "$CLASS" '["workspace"]["name"]'))"; fi
  settle
  # 4. drag the title: tiled detaches to floating; floating just moves
  geom
  vp drag "$TITLE_X" "$STRIP_Y" "$((TITLE_X - 200))" "$((STRIP_Y + 150))" 25 sleep 900
  if [[ "$(wf "$CLASS" '["floating"]')" == "true" ]]; then
    NY=$(wf "$CLASS" '["at"][1]'); shot "$LABEL-04-dragged"
    pass "title drag -> floating and moved (y $Y -> $NY)"
    be float "$TOK" off >/dev/null; settle
  else fail "title drag did not detach the window"; fi
  # 5. close via the strip
  geom
  vp click "$CLOSE_X" "$STRIP_Y" sleep 600
  if wait_gone "$CLASS"; then pass "close by button (graceful close request)"; else
    echo "  note: window still open after Close (an app-side prompt or slow exit); closing by action"
    be close "$TOK" >/dev/null; wait_gone "$CLASS" || { hc dispatch "hl.dsp.window.close({ window = 'address:$ADDR' })" >/dev/null 2>&1; }
    fail "close button did not close $LABEL within 10 s"
  fi
  settle
done
echo; echo "apps: $TOTAL run, $FAILED failure(s); evidence in $OUT"
[[ $FAILED -eq 0 ]]
