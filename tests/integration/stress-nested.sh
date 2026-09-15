#!/usr/bin/env bash
# §11 soak: N minimize/restore cycles through the shell service, watching that
# tracked entries, file descriptors and memory settle instead of growing.
#   SIG=… NESTED_DISPLAY=… CYCLES=500 tests/integration/stress-nested.sh
set -u
SIG="${SIG:?}"; NESTED_DISPLAY="${NESTED_DISPLAY:?}"; CYCLES="${CYCLES:-500}"
SHELL_CONFIG="${SHELL_CONFIG:-/usr/share/omarchy/shell}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/helpers/grabbar_backend.py"
hc() { hyprctl -i "$SIG" "$@"; }
be() { HYPRLAND_INSTANCE_SIGNATURE="$SIG" python3 "$HELPER" --timeout 4 "$@"; }
sipc() { WAYLAND_DISPLAY="$NESTED_DISPLAY" qs ipc -p "$SHELL_CONFIG" call tech.greyforge.grabbar "$@"; }
HPID=$(head -1 "$XDG_RUNTIME_DIR/hypr/$SIG/hyprland.lock")
QPID=$(for p in $(pgrep -f "qs -p $SHELL_CONFIG"); do tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -qx "WAYLAND_DISPLAY=$NESTED_DISPLAY" && echo $p; done | head -1)
mem() { awk '/^Pss:/{print $2}' /proc/$1/smaps_rollup; }
fds() { ls /proc/$1/fd | wc -l; }
sample() { echo "$1 compositor pss=$(mem $HPID)kB fds=$(fds $HPID) | shell pss=$(mem $QPID)kB fds=$(fds $QPID) | backend $(be status | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tracked=%s owned=%s" % (d["tracked"], d["owned"]))')"; }
A=$(hc -j clients | python3 -c 'import json,sys; d=[c for c in json.load(sys.stdin) if c["mapped"]]; print(d[0]["address"] if d else "")')
[[ -n "$A" ]] || { hc dispatch "hl.dsp.exec_cmd([[ foot ]])" >/dev/null; sleep 2; A=$(hc -j clients | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["address"])'); }
T=$(be windows | python3 -c 'import json,sys; a=sys.argv[1]; [print(json.loads(l)["token"]) for l in sys.stdin if json.loads(l).get("address")==a]' "$A" | head -1)
ws() { hc -j clients | python3 -c 'import json,sys; a=sys.argv[1]; [print(c["workspace"]["name"]) for c in json.load(sys.stdin) if c["address"]==a]' "$A"; }
wait_ws() { for _ in $(seq 1 40); do [[ "$(ws)" == "$1" ]] && return 0; sleep 0.05; done; return 1; }
sample "before"
T0=$(date +%s); FAILS=0; LAT=()
for i in $(seq 1 "$CYCLES"); do
  s=$(date +%s%N); sipc minimize "$T" >/dev/null; wait_ws special:grabbar-minimized || { FAILS=$((FAILS+1)); continue; }
  sipc restore "$T" current >/dev/null; wait_ws 1 || { FAILS=$((FAILS+1)); continue; }
  LAT+=( $(( ($(date +%s%N) - s) / 1000000 )) )
  (( i % 100 == 0 )) && sample "cycle $i"
done
sample "after"
printf '%s\n' "${LAT[@]}" | sort -n | awk '{a[NR]=$1} END {printf "cycles=%d ok=%d p50=%dms p95=%dms max=%dms\n", NR, NR, a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'
echo "failed cycles: $FAILS; elapsed $(( $(date +%s) - T0 )) s"
