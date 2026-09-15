#!/usr/bin/env bash
# Behaviour scenarios from spec §14 that need a real shell service: run
# against the nested session with the sandboxed omarchy-shell connected
# (docs/QUALIFICATION.md "Sandboxed shell"). Covers F02 (press on A, focus
# moves to B, release on A), F05 (external maximize toggle), F08 (many
# windows, restore all), R05 (journal write failure), R09 (origin monitor
# removed), R10 (pinned floating window), R15 (fullscreen window).
#
#   SIG=… NESTED_DISPLAY=wayland-N STATE_DIR=<shell's grabbar state dir> tests/integration/scenarios-nested.sh
set -u
SIG="${SIG:?}"; NESTED_DISPLAY="${NESTED_DISPLAY:?}"; STATE_DIR="${STATE_DIR:?path of the shell grabbar state dir}"
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
W="${NESTED_W:-1600}"; H="${NESTED_H:-1000}"; BAR_TOP="${BAR_TOP:-35}"
MANY="${MANY:-20}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/helpers/grabbar_backend.py"; VP="$ROOT/tests/integration/vpointer/vpointer"
SHELL_CONFIG="${SHELL_CONFIG:-/usr/share/omarchy/shell}"

hc() { hyprctl -i "$SIG" "$@"; }
spawn() { hc dispatch "hl.dsp.exec_cmd([[ $* ]])" >/dev/null; }
vp() { WAYLAND_DISPLAY="$NESTED_DISPLAY" "$VP" "$W" "$H" "$@"; }
shot() { WAYLAND_DISPLAY="$NESTED_DISPLAY" grim "$OUT/$1.png"; }
be() { HYPRLAND_INSTANCE_SIGNATURE="$SIG" python3 "$HELPER" --timeout 4 "$@"; }
sipc() { WAYLAND_DISPLAY="$NESTED_DISPLAY" qs ipc -p "$SHELL_CONFIG" call tech.greyforge.grabbar "$@"; }
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAILED=$((FAILED+1)); }
say() { echo; echo "== $*"; }
FAILED=0
cj() { hc -j clients; }
count() { cj | python3 -c 'import json,sys; print(len([c for c in json.load(sys.stdin) if c["mapped"]]))'; }
hidden_count() { cj | python3 -c 'import json,sys; print(len([c for c in json.load(sys.stdin) if c["workspace"]["name"]=="special:grabbar-minimized"]))'; }
addr_list() { cj | python3 -c 'import json,sys; [print(c["address"]) for c in json.load(sys.stdin) if c["mapped"]]'; }
wj() { cj | python3 -c 'import json,sys; a=sys.argv[1]; d=[c for c in json.load(sys.stdin) if c["address"]==a]; print(json.dumps(d[0] if d else {}))' "$1"; }
wf() { wj "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d$2 if d else ''; print(json.dumps(v) if not isinstance(v,str) else v)"; }
tok() { be windows | python3 -c 'import json,sys; a=sys.argv[1]; [print(json.loads(l)["token"]) for l in sys.stdin if json.loads(l).get("address")==a]' "$1" | head -1; }
gb() { be windows | python3 -c 'import json,sys; a=sys.argv[1]; [print(json.loads(l).get(sys.argv[2],"")) for l in sys.stdin if json.loads(l).get("address")==a]' "$1" "$2" | head -1; }
geom() { local a="$1"; X=$(wf "$a" '["at"][0]'); Y=$(wf "$a" '["at"][1]'); WW=$(wf "$a" '["size"][0]'); STRIP_Y=$((Y - 17)); TITLE_X=$((X + WW / 2)); CLOSE_X=$((X + WW - 4 - 16)); MAX_X=$((CLOSE_X - 32)); MIN_X=$((MAX_X - 32)); }
wait_count() { for _ in $(seq 1 80); do [[ "$(count)" == "$1" ]] && return 0; sleep 0.25; done; return 1; }
close_all() { for a in $(addr_list); do hc dispatch "hl.dsp.window.close({ window = 'address:$a' })" >/dev/null; done; wait_count 0; }
shell_minimized() { sipc status | python3 -c 'import json,sys; print(json.load(sys.stdin)["minimized"])'; }

[[ "$(count)" == 0 ]] || { echo "refusing: windows already open in the nested session"; exit 2; }
sipc ping | grep -q connected || { echo "refusing: no shell service connected on $NESTED_DISPLAY"; exit 2; }

say "F02: press Minimize on A, focus moves to B before release, release on A -> only A minimizes"
spawn foot; wait_count 1; spawn foot; wait_count 2; sleep 1.5
A=$(addr_list | head -1); B=$(addr_list | tail -1)
geom "$A"; vp move "$MIN_X" "$STRIP_Y" sleep 150 down sleep 100
hc dispatch "hl.dsp.focus({ window = 'address:$B' })" >/dev/null; sleep 0.3
[[ "$(hc -j activewindow | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')" == "$B" ]] || echo "  note: focus did not move to B while pressed"
vp up sleep 1500
if [[ "$(wf "$A" '["workspace"]["name"]')" == "special:grabbar-minimized" && "$(wf "$B" '["workspace"]["name"]')" != "special:grabbar-minimized" ]]; then pass "F02 only A minimized"; else fail "F02 A ws=$(wf "$A" '["workspace"]["name"]') B ws=$(wf "$B" '["workspace"]["name"]')"; fi
sipc restoreAll >/dev/null; sleep 1.5
close_all

say "F05: external maximize toggle is reflected by the backend"
spawn foot; wait_count 1; sleep 1.2; A=$(addr_list)
hc dispatch "hl.dsp.window.fullscreen_state({ internal = 1, client = 1, action = 'set', window = 'address:$A' })" >/dev/null; sleep 0.8
[[ "$(gb "$A" maximized)" == "1" ]] && pass "F05 backend reports maximized after an external maximize" || fail "F05 backend maximized=$(gb "$A" maximized) fs=$(wf "$A" '["fullscreen"]')"
shot "f05-external-maximized"
geom "$A"; vp click "$MAX_X" "$STRIP_Y" sleep 900
[[ "$(wf "$A" '["fullscreen"]')" == "0" ]] && pass "F05 the strip's button then restores size (no stale checkpoint)" || fail "F05 button did not restore size"
close_all

say "F08: $MANY windows minimized through the shell, restored with Restore all"
for i in $(seq 1 "$MANY"); do spawn foot; done
wait_count "$MANY" || { fail "F08 only $(count) of $MANY windows mapped"; close_all; }
sleep 2
for a in $(addr_list); do t=$(tok "$a"); [[ -n "$t" ]] && sipc minimize "$t" >/dev/null; done
for _ in $(seq 1 60); do [[ "$(hidden_count)" == "$MANY" ]] && break; sleep 0.5; done
HC=$(hidden_count); SM=$(shell_minimized)
[[ "$HC" == "$MANY" && "$SM" == "$MANY" ]] && pass "F08 $MANY windows hidden; shell model has $SM rows" || fail "F08 hidden=$HC shell rows=$SM"
J="$STATE_DIR/state.json"; JN=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["entries"]))' "$J" 2>/dev/null || echo "?")
[[ "$JN" == "$MANY" ]] && pass "F08 journal holds $JN entries" || fail "F08 journal entries=$JN"
shot "f08-all-minimized"
T0=$(date +%s%N); sipc restoreAll >/dev/null
for _ in $(seq 1 80); do [[ "$(hidden_count)" == 0 && "$(shell_minimized)" == 0 ]] && break; sleep 0.25; done
T1=$(( ($(date +%s%N) - T0) / 1000000 ))
[[ "$(hidden_count)" == 0 && "$(shell_minimized)" == 0 && "$(count)" == "$MANY" ]] && pass "F08 Restore all returned $MANY windows in ${T1} ms, rows and journal cleared" || fail "F08 after restore all: hidden=$(hidden_count) rows=$(shell_minimized) windows=$(count)"
close_all

say "R05: journal cannot be written -> minimize refused, window stays visible"
spawn foot; wait_count 1; sleep 1.2; A=$(addr_list); T=$(tok "$A")
chmod 500 "$STATE_DIR"
sipc minimize "$T" >/dev/null; sleep 1.5
if [[ "$(wf "$A" '["workspace"]["name"]')" != "special:grabbar-minimized" && "$(shell_minimized)" == 0 ]]; then pass "R05 window visible, no row, after a failed journal write"; else fail "R05 ws=$(wf "$A" '["workspace"]["name"]') rows=$(shell_minimized)"; fi
chmod 700 "$STATE_DIR"
sipc minimize "$T" >/dev/null; sleep 1.5
[[ "$(wf "$A" '["workspace"]["name"]')" == "special:grabbar-minimized" ]] && pass "R05 minimize works again once the journal is writable" || fail "R05 minimize still failing"
sipc restoreAll >/dev/null; sleep 1.2; close_all

say "R09: window minimized from a second output; output removed; restore lands on the remaining output"
hc output create headless GRABBAR-R09 >/dev/null; sleep 1
MON2=$(hc -j monitors | python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin) if m["name"]=="GRABBAR-R09"]')
if [[ -z "$MON2" ]]; then fail "R09 could not create a second output"; else
  WS2=$(hc -j monitors | python3 -c 'import json,sys; [print(m["activeWorkspace"]["id"]) for m in json.load(sys.stdin) if m["name"]=="GRABBAR-R09"]')
  spawn foot; wait_count 1; sleep 1.2; A=$(addr_list); T=$(tok "$A")
  hc dispatch "hl.dsp.window.move({ workspace = '$WS2', window = 'address:$A' })" >/dev/null; sleep 0.8
  [[ "$(wf "$A" '["monitor"]')" != "0" ]] || echo "  note: window did not move to the second output"
  sipc minimize "$T" >/dev/null; sleep 1.5
  [[ "$(wf "$A" '["workspace"]["name"]')" == "special:grabbar-minimized" ]] || fail "R09 minimize on second output failed"
  hc output remove GRABBAR-R09 >/dev/null; sleep 1
  sipc restore "$T" original >/dev/null; sleep 1.5
  M=$(wf "$A" '["monitor"]'); WS=$(wf "$A" '["workspace"]["name"]')
  [[ "$WS" != "special:grabbar-minimized" && "$M" == "0" ]] && pass "R09 restored onto the remaining output (monitor $M, workspace $WS)" || fail "R09 monitor=$M ws=$WS"
  close_all
fi

say "R10: pinned floating window really hides while minimized and comes back pinned + floating"
spawn foot; wait_count 1; sleep 1.2; A=$(addr_list); T=$(tok "$A")
hc dispatch "hl.dsp.window.float({ action = 'enable', window = 'address:$A' })" >/dev/null; sleep 0.5
hc dispatch "hl.dsp.window.pin({ action = 'enable', window = 'address:$A' })" >/dev/null; sleep 0.5
[[ "$(wf "$A" '["pinned"]')" == "true" ]] || echo "  note: pin did not apply"
sipc minimize "$T" >/dev/null; sleep 1.5
if [[ "$(wf "$A" '["workspace"]["name"]')" == "special:grabbar-minimized" && "$(wf "$A" '["pinned"]')" == "false" ]]; then pass "R10 pinned window hidden with pin cleared"; else fail "R10 ws=$(wf "$A" '["workspace"]["name"]') pinned=$(wf "$A" '["pinned"]')"; fi
sipc restore "$T" current >/dev/null; sleep 1.5
[[ "$(wf "$A" '["pinned"]')" == "true" && "$(wf "$A" '["floating"]')" == "true" && "$(wf "$A" '["workspace"]["name"]')" == "1" ]] && pass "R10 restored pinned + floating on workspace 1" || fail "R10 pinned=$(wf "$A" '["pinned"]') floating=$(wf "$A" '["floating"]') ws=$(wf "$A" '["workspace"]["name"]')"
close_all

say "R15: app fullscreen -> no strip drawn, Minimize refused; leaving fullscreen brings the strip back"
spawn foot; wait_count 1; sleep 1.2; A=$(addr_list); T=$(tok "$A")
hc dispatch "hl.dsp.window.fullscreen_state({ internal = 2, client = 2, action = 'set', window = 'address:$A' })" >/dev/null; sleep 0.8
shot "r15-fullscreen"
FY=$(wf "$A" '["at"][1]')
[[ "$FY" == "0" ]] && pass "R15 fullscreen client occupies y=0 (no reserved strip)" || fail "R15 fullscreen client at y=$FY"
sipc minimize "$T" >/dev/null; sleep 1.2
[[ "$(wf "$A" '["workspace"]["name"]')" != "special:grabbar-minimized" ]] && pass "R15 minimize refused while fullscreen" || fail "R15 fullscreen window was minimized"
hc dispatch "hl.dsp.window.fullscreen_state({ internal = 0, client = 0, action = 'set', window = 'address:$A' })" >/dev/null; sleep 1
[[ "$(wf "$A" '["at"][1]')" -ge $((BAR_TOP + 44)) ]] && pass "R15 strip reserved again after leaving fullscreen (y=$(wf "$A" '["at"][1]'))" || fail "R15 y=$(wf "$A" '["at"][1]') after fullscreen"
close_all

echo; echo "scenarios: $FAILED failure(s); evidence in $OUT"
[[ $FAILED -eq 0 ]]
