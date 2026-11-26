#!/bin/sh
# agent-confine-live.sh — prove ONE BINARY is enough for grant-list confinement
# of a host-exec node: the agent is its own launcher (`aeo-agent confine`) and
# carries Aether's sandbox preload library (lib/sandbox_preload).
#
#   sh test/agent-confine-live.sh
#
# Every launch here runs under `env -i` with a scratch HOME and NO AETHER_HOME /
# AETHER_SANDBOX_PRELOAD, from a scratch directory, i.e. as on a fleet host that
# has never seen an Aether toolchain. Part 2 goes through a REAL agent over the
# HTTP transport (boot -> probe -> halt), the route that had only been compiled.
# Part 3: the confinement decision, launched or refused, is in the agent
# host's own audit trail ($HOME/.aeo/agent-audit.log; `aeo-agent audit`).
#
# SKIPs (exit 0, saying why) where it cannot run: not Linux, no Landlock, no
# toolchain library to embed. Not run by run-spec.sh (it builds two agents).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(uname -s)" = "Linux" ] || { echo "SKIP: Linux only (Landlock)"; exit 0; }
command -v ae >/dev/null 2>&1 || { echo "SKIP: no ae toolchain"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: no curl"; exit 0; }

T="$(mktemp -d)"
NODE="aeoconf$$"
PIDF="/tmp/aeo-macexec-$NODE.pid"     # driver_mac_exec.pidfile_for
APID=""
cleanup() {
    [ -n "$APID" ] && kill "$APID" 2>/dev/null
    for f in "$T"/*.pid "$PIDF"; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
    rm -f "$PIDF"; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/full" "$T/plain" "$T/home" "$T/data/w"
echo allowed > "$T/data/allow.txt"; echo secret > "$T/data/deny.txt"

sh "$ROOT/tools/build-agent.sh" -o "$T/full/aeo-agent" >"$T/build.log" 2>&1 \
    || { echo "SKIP: cannot build an agent that carries the library:"; tail -3 "$T/build.log"; exit 0; }
( cd "$ROOT" && ae build bin/aeo-agent.ae -o "$T/plain/aeo-agent" --lib lib ) >"$T/build2.log" 2>&1 \
    || { echo "BUILD FAILED (plain agent)"; tail -5 "$T/build2.log"; exit 2; }

CAT="$(readlink -f "$(command -v cat)")"; SLP="$(readlink -f "$(command -v sleep)")"
CLEAN="env -i PATH=/usr/bin:/bin HOME=$T/home"
GR="shell,fork,fs:/dev/null,exec:$CAT,exec:$SLP,fs_read:$T/data/allow.txt,fs_write:$T/data/w/*"
WORK="cat $T/data/allow.txt > $T/data/w/o.txt; cat $T/data/deny.txt >> $T/data/w/o.txt 2>&1; echo x > $T/data/escape.txt 2>> $T/data/w/o.txt; sleep 60"

# Gate: can this kernel contain a child at all?
gate="$($CLEAN "$T/full/aeo-agent" confine --grants "exec:$SLP" -- "$SLP" 0 2>&1)" \
    || { echo "SKIP: this box cannot contain a child: $gate"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
check() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }
mapped() { grep -q 'libaether_sandbox' "/proc/$1/maps" 2>/dev/null; }

# NB the direct launches below put `exec </dev/null >/dev/null 2>&1;` in front
# of the workload exactly as driver_mac_exec does: without it the workload holds
# the launcher's stdio and does not outlive it (measured here).
echo "== 1. the agent as its own launcher, no toolchain in sight"
SHA="$("$T/full/aeo-agent" preload | sed -n 's/.*sha256:\([0-9a-f]*\).*/\1/p')"
[ ${#SHA} -eq 64 ]; check $? "the built agent reports the library it carries"
LIB="$T/home/.aeo/lib/libaether_sandbox-$(echo "$SHA" | cut -c1-16).so"
[ -f "$LIB" ] && [ "$(sha256sum "$LIB" | cut -d' ' -f1)" = "$SHA" ]
check $? "the gate launch put the library at \$HOME/.aeo/lib, byte for byte"
# By its mode bits, not `-w`: root may write any file whatever its mode, so
# `[ ! -w ]` fails for root even on a 0555 file (seen in a root container).
case "$(stat -c %A "$LIB" 2>/dev/null)" in -r-?r-?r-?) ok "the extracted library is not writable" ;; *) bad "the extracted library is not writable ($(stat -c %A "$LIB" 2>/dev/null))" ;; esac

out="$($CLEAN "$T/full/aeo-agent" confine --pidfile "$T/a.pid" --grants "$GR" -- /bin/sh -c "exec </dev/null >/dev/null 2>&1; $WORK" 2>&1)"
check $? "a granted workload starts ($out)"
sleep 1
P="$(cat "$T/a.pid" 2>/dev/null)"
kill -0 "$P" 2>/dev/null; check $? "the pidfile names a live process"
mapped "$P"; check $? "the workload has the preload library mapped"
grep -q allowed "$T/data/w/o.txt"; check $? "it read and wrote what it was granted"
! grep -q secret "$T/data/w/o.txt" && grep -q 'deny.txt: Permission denied' "$T/data/w/o.txt"
check $? "the kernel refused the file it was not granted"
[ ! -e "$T/data/escape.txt" ]; check $? "the kernel refused a write outside its grant"
kill "$P" 2>/dev/null

chmod u+w "$LIB"; echo tampered > "$LIB"
$CLEAN "$T/full/aeo-agent" confine --grants "exec:$SLP" -- "$SLP" 0 >/dev/null 2>&1
[ "$(sha256sum "$LIB" | cut -d' ' -f1)" = "$SHA" ]
check $? "a library changed on disk is replaced before the next launch"

out="$(env -i PATH=/usr/bin:/bin "$T/full/aeo-agent" confine --pidfile "$T/b.pid" --grants "exec:$SLP" -- "$SLP" 30 2>&1)"
[ $? -ne 0 ] && [ ! -f "$T/b.pid" ]; check $? "no HOME: nothing starts ($out)"

out="$($CLEAN "$T/plain/aeo-agent" confine --pidfile "$T/c.pid" --grants "exec:$SLP" -- "$SLP" 30 2>&1)"
[ $? -ne 0 ] && [ ! -f "$T/c.pid" ]; check $? "an agent built WITHOUT the library starts nothing here"

out="$($CLEAN "$T/full/aeo-agent" confine --pidfile "$T/d.pid" --grants "exec:$SLP,bogus:x" -- "$SLP" 30 2>&1)"
[ $? -ne 0 ] && [ ! -f "$T/d.pid" ] && echo "$out" | grep -q "unknown grant 'bogus:x'"
check $? "a grant it does not know starts nothing"

echo "== 2. dispatched through a real agent (HTTP transport)"
# A port of this run's own: a fixed one fails every second back-to-back run
# (the previous agent's listener is not yet released; measured).
PORT="${AEO_PORT:-$((20000 + $$ % 20000))}"; TOK="courier-$$"; BASE="http://127.0.0.1:$PORT"
rm -f "$T/data/w/o.txt"
env -i PATH=/usr/bin:/bin HOME="$T/home" AEO_TRANSPORT=http AEO_BIND=127.0.0.1 AEO_PORT="$PORT" \
    AEO_NODE="$NODE" AEO_TOKEN="$TOK" AEO_BOOT_KIND=exec AEO_BOOT_CMD="$WORK" AEO_EXEC_GRANTS="${GR#shell,fork,fs:/dev/null,}" \
    "$T/full/aeo-agent" >"$T/agent.log" 2>&1 &
APID=$!
i=0
while ! curl -fsS "$BASE/health" >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -gt 50 ] && { echo "FAIL: agent never came up"; cat "$T/agent.log"; exit 1; }
    sleep 0.1
done
rep="$(curl -sS --max-time 20 -X POST --data "boot $TOK $NODE" "$BASE/dispatch" 2>/dev/null)"
[ "$rep" = "report $TOK $NODE up" ]; check $? "boot reports up ('$rep')"
sleep 1
P="$(cat "$PIDF" 2>/dev/null)"
kill -0 "$P" 2>/dev/null; check $? "the dispatched workload is running"
mapped "$P"; check $? "it has the preload library mapped"
! grep -q secret "$T/data/w/o.txt" 2>/dev/null && grep -q 'deny.txt: Permission denied' "$T/data/w/o.txt" 2>/dev/null
check $? "the kernel refused the file it was not granted"
rep="$(curl -sS --max-time 20 -X POST --data "halt $TOK $NODE" "$BASE/dispatch" 2>/dev/null)"
sleep 1
! kill -0 "$P" 2>/dev/null; check $? "halt stops it ('$rep')"

echo "== 3. the confinement decision is in this host's audit trail"
AUDF="$T/home/.aeo/agent-audit.log"
grep -q "\"node\":\"$NODE\",\"kind\":\"exec\",\"event\":\"confine\",\"detail\":\"landlock grants=" "$AUDF" 2>/dev/null
check $? "the confined launch is recorded"
grep -q "fs_read:$T/data/allow.txt" "$AUDF" 2>/dev/null && grep -q "launcher=aeo-agent confine" "$AUDF" 2>/dev/null
check $? "the entry names the grants and the launcher"
! grep -q "deny.txt" "$AUDF" 2>/dev/null; check $? "the workload's command is not in the trail"
[ "$(stat -c %a "$AUDF" 2>/dev/null)" = "600" ]; check $? "the trail is readable by its owner only"
out="$($CLEAN "$T/full/aeo-agent" audit 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "chain:   INTACT"; check $? "aeo-agent audit: the chain verifies"

kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
PORT2=$((PORT + 1)); BASE2="http://127.0.0.1:$PORT2"; NODE2="${NODE}r"
env -i PATH=/usr/bin:/bin HOME="$T/home" AEO_TRANSPORT=http AEO_BIND=127.0.0.1 AEO_PORT="$PORT2" \
    AEO_NODE="$NODE2" AEO_TOKEN="$TOK" AEO_BOOT_KIND=exec AEO_BOOT_CMD="$SLP 60" AEO_EXEC_GRANTS="exec:$SLP,bogus:x" \
    "$T/full/aeo-agent" >"$T/agent2.log" 2>&1 &
APID=$!
i=0
while ! curl -fsS "$BASE2/health" >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -gt 50 ] && { echo "FAIL: second agent never came up"; cat "$T/agent2.log"; exit 1; }
    sleep 0.1
done
rep="$(curl -sS --max-time 20 -X POST --data "boot $TOK $NODE2" "$BASE2/dispatch" 2>/dev/null)"
[ "$rep" != "report $TOK $NODE2 up" ]; check $? "a boot with a grant the launcher does not know is not reported up ('$rep')"
[ ! -f "/tmp/aeo-macexec-$NODE2.pid" ] || ! kill -0 "$(cat "/tmp/aeo-macexec-$NODE2.pid")" 2>/dev/null
check $? "and nothing was started"
grep -q "\"node\":\"$NODE2\",\"kind\":\"exec\",\"event\":\"confine-refuse\"" "$AUDF" 2>/dev/null
check $? "the refusal is recorded"
grep "confine-refuse" "$AUDF" 2>/dev/null | grep -q "bogus:x"; check $? "the entry says which grants were refused"
out="$($CLEAN "$T/full/aeo-agent" audit 2>&1)"; rc=$?
[ $rc -eq 0 ]; check $? "the chain still verifies with both entries"
sed -i '1s/landlock grants=/landlock grants=fs:\/,/' "$AUDF"
out="$($CLEAN "$T/full/aeo-agent" audit 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "CHAIN BROKEN"; check $? "an edited trail is caught, and aeo-agent audit exits non-zero"
kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null

echo
echo "$pass passed, $fail failed  (kernel $(uname -r), $(uname -m), $(ae version | head -1))"
[ "$fail" -eq 0 ] || { echo "--- agent log ---"; cat "$T/agent.log" 2>/dev/null; exit 1; }
exit 0
