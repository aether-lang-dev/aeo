#!/bin/sh
# agent-sealed-live.sh — a Landlock-confined exec node dispatched over the
# SEALED channel (lib/secure_channel, Ascon-AEAD128 keyed by the courier PSK):
# boot -> probe -> halt as AE1: frames to a real agent built by
# tools/build-agent.sh, with AEO_EXEC_GRANTS set. Also: a frame under the wrong
# key and a replayed frame are not obeyed. test/agent-confine-live.sh covers the
# same route in plaintext.
#
#   sh test/agent-sealed-live.sh
#
# The PSK is generated per run (a test value, never a real key). test/sealer.ae
# seals and opens frames, as the parent orchestrator does in code. SKIPs (exit
# 0, saying why) off Linux or without a toolchain library to embed. Not run by
# run-spec.sh (it builds an agent).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(uname -s)" = "Linux" ] || { echo "SKIP: Linux only (Landlock)"; exit 0; }
command -v ae >/dev/null 2>&1 || { echo "SKIP: no ae toolchain"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }
cd "$ROOT" || exit 2
T="$(mktemp -d)"; NODE="aeoseal$$"; PIDF="/tmp/aeo-macexec-$NODE.pid"; APID=""
cleanup() { [ -n "$APID" ] && kill "$APID" 2>/dev/null; [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; chmod -R u+w "$T"; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/home" "$T/data/w"; echo allowed > "$T/data/allow.txt"; echo secret > "$T/data/deny.txt"
sh tools/build-agent.sh -o "$T/bin/aeo-agent" > "$T/b1.log" 2>&1 || { echo "SKIP: cannot build an agent that carries the library:"; tail -3 "$T/b1.log"; exit 0; }
ae build test/sealer.ae -o "$T/bin/sealer" --lib lib > "$T/b2.log" 2>&1 || { echo "sealer build failed"; tail "$T/b2.log"; exit 2; }
"$T/bin/aeo-agent" preload
CAT="$(readlink -f "$(command -v cat)")"; SLP="$(readlink -f "$(command -v sleep)")"
GR="exec:$CAT,exec:$SLP,fs_read:$T/data/allow.txt,fs_write:$T/data/w/*"
WORK="cat $T/data/allow.txt > $T/data/w/o.txt; cat $T/data/deny.txt >> $T/data/w/o.txt 2>&1; sleep 60"
PSK="test-psk-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PORT=$((20000 + $$ % 20000)); BASE="http://127.0.0.1:$PORT"
env -i PATH=/usr/bin:/bin HOME="$T/home" AEO_TRANSPORT=http AEO_BIND=127.0.0.1 AEO_PORT="$PORT" \
  AEO_NODE="$NODE" AEO_TOKEN="$PSK" AEO_BOOT_KIND=exec AEO_BOOT_CMD="$WORK" AEO_EXEC_GRANTS="$GR" \
  "$T/bin/aeo-agent" > "$T/agent.log" 2>&1 &
APID=$!
i=0; while ! curl -fsS "$BASE/health" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 50 ] && { echo "agent never up"; cat "$T/agent.log"; exit 1; }; sleep 0.1; done
pass=0; fail=0; ck() { if [ "$1" -eq 0 ]; then pass=$((pass+1)); echo "PASS $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }
send() { F="$("$T/bin/sealer" seal "$PSK" "$1")"; curl -sS --max-time 20 -X POST --data "$F" "$BASE/dispatch"; }
R="$(send "boot $PSK $NODE")"
case "$R" in AE1:*) ck 0 "the boot reply is sealed";; *) ck 1 "the boot reply is sealed ($R)";; esac
O="$("$T/bin/sealer" open "$PSK" "$R")"
case "$O" in *"report $PSK $NODE up"*) ck 0 "sealed boot reports up";; *) ck 1 "sealed boot reports up ($O)";; esac
sleep 1; P="$(cat "$PIDF" 2>/dev/null)"
kill -0 "$P" 2>/dev/null; ck $? "the dispatched workload is running (pid $P)"
grep -q libaether_sandbox "/proc/$P/maps" 2>/dev/null; ck $? "it has the preload library mapped"
grep -q '^Seccomp:[[:space:]]*2' "/proc/$P/status"; ck $? "it holds a seccomp filter"
grep -q allowed "$T/data/w/o.txt" && ! grep -q secret "$T/data/w/o.txt" && grep -q 'Permission denied' "$T/data/w/o.txt"; ck $? "granted file read, ungranted file refused by the kernel"
# wrong key and a replay
F="$("$T/bin/sealer" seal "wrong-$PSK" "probe $PSK $NODE")"; R2="$(curl -sS --max-time 10 -X POST --data "$F" "$BASE/dispatch")"
O2="$("$T/bin/sealer" open "$PSK" "$R2" 2>&1)"; case "$O2" in *"report $PSK $NODE up"*) ck 1 "a frame under the wrong key is not obeyed ($O2)";; *) ck 0 "a frame under the wrong key is not obeyed (${R2%%:*}...)";; esac
F="$("$T/bin/sealer" seal "$PSK" "probe $PSK $NODE")"; R3="$(curl -sS --max-time 10 -X POST --data "$F" "$BASE/dispatch")"; R4="$(curl -sS --max-time 10 -X POST --data "$F" "$BASE/dispatch")"
O3="$("$T/bin/sealer" open "$PSK" "$R3")"; O4="$("$T/bin/sealer" open "$PSK" "$R4" 2>&1)"
case "$O3" in *"up"*) ck 0 "a sealed probe answers up";; *) ck 1 "a sealed probe answers up ($O3)";; esac
case "$O4" in *"report $PSK $NODE up"*) ck 1 "a replayed frame is refused ($O4)";; *) ck 0 "a replayed frame is refused";; esac
R="$(send "halt $PSK $NODE")"; O="$("$T/bin/sealer" open "$PSK" "$R")"; sleep 1
case "$O" in *"down"*) ck 0 "sealed halt reports down";; *) ck 1 "sealed halt reports down ($O)";; esac
! kill -0 "$P" 2>/dev/null; ck $? "halt stopped the workload"
echo "$pass passed, $fail failed (kernel $(uname -r), $(uname -m), $(ae --version | head -1))"
[ $fail -eq 0 ] || { echo '--- agent log'; tail -30 "$T/agent.log"; exit 1; }
