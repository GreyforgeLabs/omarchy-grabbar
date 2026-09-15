#!/usr/bin/env bash
# Cold-start, reload and load/unload regression for the native autoload path,
# run in a NESTED Hyprland on a headless output. The host compositor is never
# touched: nothing here calls hyprctl without -i <nested signature> except the
# initial exec that spawns the nested compositor as a Wayland client.
#
#   HEADLESS_WS=<workspace id on the headless output> tests/integration/startup-nested.sh [fixed|guard|all]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-all}"
case "$MODE" in
  fixed|guard|all) ;;
  repro)
    echo "The crash reproducer is retired. See docs/AUTOLOAD.md for preserved evidence; use fixed, guard, or all." >&2
    exit 2 ;;
  *) echo "Usage: $0 [fixed|guard|all]" >&2; exit 2 ;;
esac
export GRABBAR_SO="${GRABBAR_SO:-$ROOT/native/grabbar/grabbar.so}"
export GRABBAR_NESTED_BASE="$ROOT/tests/integration/nested/base.lua"
HEADLESS_WS="${HEADLESS_WS:?workspace id that lives on the headless output}"
OUT="${OUT:-$ROOT/docs/evidence/startup}"
mkdir -p "$OUT"
GUARD_STATE="${GUARD_STATE:-$(mktemp -d)}"   # state dir for the boot-guard scenario (never the real one)
HOST_SIG="$HYPRLAND_INSTANCE_SIGNATURE"
HYPRDIR="$XDG_RUNTIME_DIR/hypr"
HOST_HYPR_PID="$(head -1 "$HYPRDIR/$HOST_SIG/hyprland.lock")"

pass() { echo "PASS $*"; }
FAILURES=0
fail() { echo "FAIL $*"; FAILURES=$((FAILURES + 1)); }
say()  { echo; echo "== $*"; }

# Guard: the headless workspace must not be on the operator's focused monitor.
hyprctl -j monitors | python3 -c '
import json,sys; ws=int(sys.argv[1])
for m in json.load(sys.stdin):
    if m["activeWorkspace"]["id"]==ws and m["focused"]: sys.exit("refusing: workspace %d is on the focused monitor %s" % (ws, m["name"]))
' "$HEADLESS_WS" || exit 2

NESTED_SIG=""; NESTED_PID=""
launch() { # $1 = lua config
  local before; before="$(ls "$HYPRDIR")"
  hyprctl dispatch "hl.dsp.exec_cmd([[ [workspace $HEADLESS_WS silent] env HYPRLAND_INSTANCE_SIGNATURE= GRABBAR_SO=$GRABBAR_SO GRABBAR_NESTED_BASE=$GRABBAR_NESTED_BASE GRABBAR_AUTOLOAD_LUA=$ROOT/native/autoload.lua GRABBAR_STATE_DIR=$GUARD_STATE Hyprland -c $1 ]])" >/dev/null || return 1
  for _ in $(seq 1 60); do
    sleep 0.25
    for d in $(ls "$HYPRDIR"); do
      if ! grep -qx "$d" <<<"$before"; then NESTED_SIG="$d"; break 2; fi
    done
  done
  [[ -n "$NESTED_SIG" ]] || { fail "nested compositor never created a runtime dir"; return 1; }
  # The pid is published in hyprland.lock only once startup gets far enough;
  # until then find it by command line (the host compositor has no -c <ours>).
  for _ in $(seq 1 40); do
    NESTED_PID="$(pgrep -x Hyprland | while read -r p; do [[ "$p" != "$HOST_HYPR_PID" ]] && tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- "-c $1" && echo "$p"; done | head -1)"
    [[ -n "$NESTED_PID" ]] && break
    sleep 0.25
  done
  echo "nested sig=$NESTED_SIG pid=${NESTED_PID:-<already gone>}"
  return 0
}
nc() { timeout 3 hyprctl -i "$NESTED_SIG" "$@" 2>&1; }
alive() { [[ -n "$NESTED_PID" ]] && kill -0 "$NESTED_PID" 2>/dev/null; }
stop_nested() {
  [[ -n "$NESTED_PID" && "$NESTED_PID" != "$HOST_HYPR_PID" ]] || return 0
  if alive; then nc dispatch exit >/dev/null; for _ in $(seq 1 20); do alive || break; sleep 0.25; done; fi
  if alive; then kill "$NESTED_PID"; sleep 1; fi
  if alive; then kill -9 "$NESTED_PID"; fi
  NESTED_PID=""
}
trap stop_nested EXIT
ready_within() { # $1 seconds; ready = hyprctl answers version
  local n=$(( $1 * 4 )); for _ in $(seq 1 $n); do nc version 2>/dev/null | grep -q '^Hyprland' && return 0; alive || return 1; sleep 0.25; done; return 1
}
plugin_count() { nc plugins list | grep -c 'Plugin grabbar'; }
logcounts() { local L="$HYPRDIR/$NESTED_SIG/hyprland.log"; printf 'loaded=%s unloaded=%s twice=%s reloads=%s\n' "$(grep -c 'Plugin grabbar loaded' "$L")" "$(grep -c 'Plugin grabbar unloaded' "$L")" "$(grep -c 'Cannot load a plugin twice' "$L")" "$(grep -c 'Reloading the config' "$L")"; }

if [[ "$MODE" == fixed || "$MODE" == all ]]; then
  say "FIXED: cold start with the unconditional declaration"
  launch "$ROOT/tests/integration/nested/autoload-fixed.lua" || exit 1
  START=$(date +%s)
  if [[ -n "$NESTED_PID" ]] && ready_within 20; then pass "fixed: ready in $(( $(date +%s) - START ))s"; else fail "fixed: not ready in 20s; $(logcounts)"; cp "$HYPRDIR/$NESTED_SIG/hyprland.log" "$OUT/fixed-hyprland.log"; exit 1; fi
  sleep 3
  [[ "$(plugin_count)" == 1 ]] && pass "fixed: plugin loaded exactly once from config" || fail "fixed: plugin count $(plugin_count)"
  C1="$(logcounts)"; sleep 4; C2="$(logcounts)"
  [[ "$C1" == "$C2" ]] && pass "fixed: no load/unload churn after start ($C2)" || fail "fixed: churn ($C1 -> $C2)"
  say "FIXED: three config reloads"
  for i in 1 2 3; do nc reload >/dev/null; sleep 1.5; done
  [[ "$(plugin_count)" == 1 ]] && alive && pass "fixed: still one plugin after 3 reloads; $(logcounts)" || fail "fixed: reloads broke it; $(logcounts)"
  say "FIXED: hyprctl plugin unload / load / reload"
  nc plugin unload "$GRABBAR_SO" >/dev/null; sleep 2
  [[ "$(plugin_count)" == 0 ]] && alive && pass "fixed: unload leaves it unloaded (config still declares it, set unchanged -> no reload storm)" || fail "fixed: after unload count=$(plugin_count) alive=$(alive && echo y || echo n)"
  nc plugin load "$GRABBAR_SO" >/dev/null; sleep 2
  [[ "$(plugin_count)" == 1 ]] && alive && pass "fixed: manual load after unload works" || fail "fixed: manual load count=$(plugin_count)"
  nc reload >/dev/null; sleep 2
  [[ "$(plugin_count)" == 1 ]] && alive && pass "fixed: reload after manual load is stable; $(logcounts)" || fail "fixed: reload after manual load; $(logcounts)"
  say "FIXED: backend socket and shell reconnect across a reload"
  SOCK="$XDG_RUNTIME_DIR/grabbar/$NESTED_SIG/backend.sock"
  [[ -S "$SOCK" ]] && pass "fixed: backend socket present" || fail "fixed: no backend socket at $SOCK"
  HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" python3 "$ROOT/helpers/grabbar_backend.py" --timeout 3 status | grep -q '"epoch"' && pass "fixed: backend answers status" || fail "fixed: backend status"
  nc grabbar | tee "$OUT/fixed-grabbar-status.txt" | head -3
  cp "$HYPRDIR/$NESTED_SIG/hyprland.log" "$OUT/fixed-hyprland.log"
  logcounts | tee "$OUT/fixed-counts.txt"
  stop_nested
fi
if [[ "$MODE" == guard || "$MODE" == all ]]; then
  AL="python3 $ROOT/helpers/grabbar-autoload"
  G="$GUARD_STATE/autoload"
  say "GUARD 1: armed, first start loads, health marker appears after ${GRABBAR_BOOT_OK_S:-15}s"
  rm -rf "$G"; $AL arm --state-dir "$GUARD_STATE" >/dev/null
  launch "$ROOT/tests/integration/nested/autoload-guarded.lua" || exit 1
  [[ -n "$NESTED_PID" ]] && ready_within 20 || { fail "guard1: not ready"; exit 1; }
  sleep 2
  [[ "$(plugin_count)" == 1 ]] && pass "guard1: plugin loaded via the shipped hook" || fail "guard1: count $(plugin_count)"
  [[ "$(head -1 "$G/last-attempt" 2>/dev/null)" == "$NESTED_SIG" ]] && pass "guard1: last-attempt records this instance" || fail "guard1: last-attempt='$(head -1 "$G/last-attempt" 2>/dev/null)' expected $NESTED_SIG"
  [[ ! -e "$G/last-ok" || "$(head -1 "$G/last-ok")" != "$NESTED_SIG" ]] && pass "guard1: no health marker yet" || fail "guard1: health marker too early"
  say "GUARD 2: kill the compositor before the health marker -> next start must skip the plugin"
  stop_nested; sleep 1
  [[ ! -e "$G/last-ok" || "$(head -1 "$G/last-ok")" != "$NESTED_SIG" ]] || fail "guard2: marker appeared before kill (timing)"
  launch "$ROOT/tests/integration/nested/autoload-guarded.lua" || exit 1
  [[ -n "$NESTED_PID" ]] && ready_within 20 || { fail "guard2: not ready"; exit 1; }
  sleep 2
  [[ "$(plugin_count)" == 0 ]] && pass "guard2: plugin NOT loaded after an unconfirmed previous start" || fail "guard2: plugin loaded despite failed previous start"
  [[ -e "$G/skipped" ]] && pass "guard2: skip recorded ($(head -1 "$G/skipped" | cut -c1-24)...)" || fail "guard2: no skipped marker"
  HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" $AL status --state-dir "$GUARD_STATE" --hypr-config /dev/null | tee "$OUT/guard-status-skipped.txt" | head -2
  nc reload >/dev/null; sleep 1.5; nc reload >/dev/null; sleep 1.5
  [[ "$(plugin_count)" == 0 ]] && alive && pass "guard2: reloads keep it skipped, compositor alive" || fail "guard2: reload changed state"
  say "GUARD 3: retry re-arms; reload loads it; health marker confirms; a fresh start loads normally"
  $AL retry --state-dir "$GUARD_STATE" >/dev/null
  nc reload >/dev/null; sleep 2
  [[ "$(plugin_count)" == 1 ]] && pass "guard3: loaded after retry + reload" || fail "guard3: count $(plugin_count) after retry"
  [[ "$(head -1 "$G/last-attempt" 2>/dev/null)" == "$NESTED_SIG" ]] && pass "guard3: attempt re-recorded" || fail "guard3: last-attempt not updated"
  echo "waiting $(( ${GRABBAR_BOOT_OK_S:-15} + 3 ))s for the health marker"; sleep $(( ${GRABBAR_BOOT_OK_S:-15} + 3 ))
  [[ "$(head -1 "$G/last-ok" 2>/dev/null)" == "$NESTED_SIG" ]] && pass "guard3: health marker written by the native plugin" || fail "guard3: last-ok='$(head -1 "$G/last-ok" 2>/dev/null)'"
  stop_nested; sleep 1
  launch "$ROOT/tests/integration/nested/autoload-guarded.lua" || exit 1
  [[ -n "$NESTED_PID" ]] && ready_within 20 || { fail "guard3b: not ready"; exit 1; }
  sleep 2
  [[ "$(plugin_count)" == 1 ]] && pass "guard3: next start after a healthy session loads normally" || fail "guard3: count $(plugin_count) on healthy restart"
  stop_nested
  cp -r "$G" "$OUT/guard-state-final" 2>/dev/null
fi

echo; echo "host Hyprland pid $HOST_HYPR_PID still alive: $(kill -0 "$HOST_HYPR_PID" && echo yes)"; echo "host plugins: $(hyprctl plugins list | head -1)"
(( FAILURES == 0 ))
