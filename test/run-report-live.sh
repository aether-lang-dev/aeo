#!/bin/sh
# run-report-live.sh — run reports through the FRONT DOOR, against real
# containers: every `aeo up` / `aeo down` leaves a report of what it did to
# each node, `aeo report [--json]` prints the newest, and its hash is in the
# audit chain.
#
#   sh test/run-report-live.sh
#
# test/spec_run_report.ae proves the report's shape and its outcome rules as
# pure functions. This proves what only exists in the runner: that the outcomes
# recorded are the ones that happened —
#   - a healthy two-node up: both "started", timed, overall ok;
#   - a node REFUSED at boot is "failed" with the refusal as its reason, the
#     node that depends on it is "not-attempted", overall failed;
#   - the teardown after it, and a plain down, report "stopped" (verified gone);
#   - a build that prints a node's env() value and fails: the value is in what
#     the run printed and NOT in the report; the reason is cut to size; the
#     reports are readable by their owner only;
#   - a node that boots and never becomes healthy is "timeout", its dependent
#     "not-attempted"; a bwrap tree (not a container) is "started", then
#     "halted" on the way down (signalled, no gone-check for that kind);
#   - a SUPERVISED down (the default path, through a real aeo-supervisord)
#     writes a report from what the runner itself verified gone;
#   - the audit chain carries each report's sha256, and still verifies.
#
# Needs podman and the test image present locally (AEO_SPEC_IMAGE, default
# docker.io/library/debian:trixie). Without them it prints SKIP and exits 0 —
# it does not report a pass. Nothing is pulled.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${AEO_SPEC_IMAGE:-docker.io/library/debian:trixie}"
WORK="${TMPDIR:-/tmp}/aeo-runrep-$$"
N="aeo-runrep"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
has()  { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
want()   { if has "$1" "$2"; then pass "$3"; else fail "$3"; echo "  wanted: $2"; echo "  got:    $1" | head -8; fi; }
wantno() { if has "$1" "$2"; then fail "$3"; echo "  did not want: $2"; else pass "$3"; fi; }

command -v podman >/dev/null 2>&1 || { echo "SKIP: podman is not on this host — nothing was exercised"; exit 0; }
podman image inspect "$IMG" >/dev/null 2>&1 || { echo "SKIP: image $IMG is not present locally (pull it, or set AEO_SPEC_IMAGE) — nothing was exercised"; exit 0; }

mkdir -p "$WORK" && cd "$WORK" || exit 1
compose() {   # compose FILE SYSTEM DB-POLICY
    cat > "$1" <<AE
import compose (system, container)
import compose (image, command, health, depends, constrain, deny_syscalls)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("$2") {
        container("$N-db") {
            image("$IMG")
            command("sleep 600")
            health("true")
            constrain("$N-db") { deny_syscalls("$3") }
        }
        container("$N-app") {
            image("$IMG")
            command("sleep 600")
            health("true")
            depends("$N-db")
        }
    }
}
AE
}
SECRET="s3cr3t-live-$$-do-not-keep"
cat > leak.ae <<AE
import compose (system, container)
import compose (dockerfile, command, health, env)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("aeorunrepl") {
        container("$N-leak") {
            dockerfile(<<DOCKER
FROM $IMG
RUN echo TOKEN=$SECRET; seq 1 400; echo again $SECRET; exit 7
DOCKER
            )
            env("API_TOKEN", "$SECRET")
            command("sleep 600")
            health("true")
        }
    }
}
AE
cat > bw.ae <<AE
import compose (system, bwrap)
import compose (command, health, depends)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("aeorunrepw") {
        bwrap("$N-bw-db") {
            command("sleep 613")
            health("true")
        }
        bwrap("$N-bw-app") {
            command("sleep 613")
            health("true")
            depends("$N-bw-db")
        }
    }
}
AE
cat > slow.ae <<AE
import compose (system, container)
import compose (image, command, health, depends, health_retry, every, up_within, down_within)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("aeorunreps") {
        health_retry() {
            every(250ms)
            up_within(3s)
            down_within(5s)
        }
        container("$N-slow") {
            image("$IMG")
            command("sleep 600")
            health("false")
        }
        container("$N-after") {
            image("$IMG")
            command("sleep 600")
            health("true")
            depends("$N-slow")
        }
    }
}
AE
compose good.ae aeorunrep  debug
compose bad.ae  aeorunrepb debgu       # a typo: the node is refused at boot

echo "### building aeo"
if ! ae build "$ROOT/bin/aeo.ae" -o "$WORK/aeo" --lib "$ROOT/lib" >"$WORK/build.log" 2>&1; then
    tail -20 "$WORK/build.log"; fail "aeo failed to build"; rm -rf "$WORK"; exit 1
fi
aeo() { AEO_HOME="$ROOT" "$WORK/aeo" "$@" 2>&1; }
cleanup() {
    aeo down good.ae --no-supervisor >/dev/null
    podman rm -f "$N-db" "$N-app" >/dev/null 2>&1
    rm -f "$HOME/.aeo/seccomp/$N-db.json"
    cd /; rm -rf "$WORK"
}
trap cleanup EXIT
podman rm -f "$N-db" "$N-app" >/dev/null 2>&1

echo "### 1. nothing has run yet"
OUT="$(aeo report)"; RC=$?
want "$OUT" "no run report at" "aeo report: says there is none"
[ "$RC" -eq 1 ] && pass "aeo report: exits 1 when there is none" || fail "aeo report: exit $RC, wanted 1"

echo "### 2. a healthy up"
OUT="$(aeo up good.ae --no-supervisor)"
want "$OUT" "run report: up ok -> .aeo/reports/" "up: names the report it wrote"
R="$(aeo report)"
want "$R" "aeo run report: up ok in" "report: overall ok"
want "$R" "2 started" "report: both nodes started"
J="$(aeo report --json)"
want "$J" '"schema":1,"command":"up","outcome":"ok"' "report --json: header"
want "$J" "\"name\":\"$N-db\",\"system\":\"aeorunrep\",\"kind\":\"container\",\"outcome\":\"started\"" "report --json: db started"
want "$J" "\"name\":\"$N-app\",\"system\":\"aeorunrep\",\"kind\":\"container\",\"outcome\":\"started\"" "report --json: app started"
wantno "$J" '"call_ms":null' "report --json: every started node has a call time"
wantno "$J" '"done_ms":null' "report --json: every started node has a time to healthy"
if command -v python3 >/dev/null 2>&1; then
    echo "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["nodes"])==2 and d["counts"]=={"started":2}' 2>/dev/null \
        && pass "report --json: parses as JSON, counts agree with nodes" || fail "report --json: does not parse or counts disagree"
fi
[ "$(podman ps -q --filter "name=^$N-db\$" | wc -l)" -eq 1 ] && pass "the report matches the host: db is running" || fail "db is not running"
SHA="$(sha256sum .aeo/reports/last.json | cut -d' ' -f1)"
AUD="$(cat .aeo/audit.log 2>/dev/null)"
want "$AUD" "sha256:$SHA" "audit: the chain carries this report's sha256"

echo "### 3. a plain down"
OUT="$(aeo down good.ae --no-supervisor)"
want "$OUT" "run report: down ok" "down: writes a report"
J="$(aeo report --json)"
want "$J" '"command":"down","outcome":"ok"' "report --json: the newest report is the down"
want "$J" "\"name\":\"$N-db\",\"system\":\"aeorunrep\",\"kind\":\"container\",\"outcome\":\"stopped\"" "report --json: db verified gone"
[ "$(podman ps -aq --filter "name=^$N-" | wc -l)" -eq 0 ] && pass "the report matches the host: nothing is left" || fail "containers are left behind"

echo "### 4. a node refused at boot"
OUT="$(aeo up bad.ae --no-supervisor)"; RC=$?
[ "$RC" -ne 0 ] && pass "up: a refused node fails the run (exit $RC)" || fail "up exited 0 with a refused node"
UPR="$(ls .aeo/reports/*-up.json | tail -1)"
J="$(cat "$UPR")"
want "$J" '"command":"up","outcome":"failed"' "report: overall failed"
want "$J" "\"name\":\"$N-db\",\"system\":\"aeorunrepb\",\"kind\":\"container\",\"outcome\":\"failed\"" "report: the refused node is failed"
want "$J" "debgu" "report: its reason names the bad policy token"
want "$J" '"detail":"aeo: ' "report: the reason is the driver's whole message, from its first character"
want "$J" "\"name\":\"$N-app\",\"system\":\"aeorunrepb\",\"kind\":\"container\",\"outcome\":\"not-attempted\",\"call_ms\":null,\"done_ms\":null" "report: the dependent was never attempted, and has no times"
want "$J" '"counts":{"failed":1,"not-attempted":1}' "report: counts"
want "$(cat "${UPR%.json}.txt")" "up failed in" "report: the text form says failed"
want "$(aeo report --json)" '"command":"down"' "the teardown of the partial tree wrote its own report, and it is the newest"
[ "$(podman ps -aq --filter "name=^$N-" | wc -l)" -eq 0 ] && pass "the report matches the host: nothing was started" || fail "a refused run left a container"

echo "### 5. a failed build that prints a secret"
OUT="$(aeo up leak.ae --no-supervisor)"; RC=$?
[ "$RC" -ne 0 ] && pass "up: the failed build fails the run" || fail "up exited 0 with a failed build"
want "$OUT" "TOKEN=$SECRET" "the build really printed the secret (the terminal shows it)"
UPR="$(ls .aeo/reports/*-up.json | tail -1)"
J="$(cat "$UPR")"
want "$J" "\"name\":\"$N-leak\",\"system\":\"aeorunrepl\",\"kind\":\"container\",\"outcome\":\"failed\"" "report: the node is failed"
want "$J" "image build failed" "report: the reason is the build failure"
want "$J" "[withheld]" "report: the secret's place is marked"
want "$J" "characters cut; the run printed the full text" "report: the long build output is cut"
if grep -rq "$SECRET" .aeo/reports .aeo/audit.log; then fail "the secret is in a report or the audit log"; grep -rl "$SECRET" .aeo; else pass "the secret is in no report file and not in the audit log"; fi
[ "$(stat -c %a .aeo/reports)" = "700" ] && pass "the reports directory is 0700" || fail "reports directory is $(stat -c %a .aeo/reports)"
OPEN="$(find .aeo/reports -type f ! -perm 600 | wc -l)"
[ "$OPEN" -eq 0 ] && pass "every report file is 0600" || fail "$OPEN report file(s) are not 0600"
[ "$(stat -c %a .aeo/audit.log)" = "600" ] && pass "the audit log is 0600" || fail "audit log is $(stat -c %a .aeo/audit.log)"
RC_OUT="$(aeo reconcile leak.ae --converge)"; RRC=$?
[ "$RRC" -ne 0 ] && pass "reconcile: a failed converge exits non-zero ($RRC)" || fail "reconcile exited 0 with a failed converge"
want "$RC_OUT" "converge FAILED" "reconcile --converge: the same build fails again"
want "$RC_OUT" "TOKEN=$SECRET" "reconcile: the terminal shows the build output, secret included"
want "$(cat .aeo/audit.log)" '"event":"converge-fail"' "audit: the failed converge is recorded"
J="$(aeo report --json)"
want "$J" '"command":"reconcile","outcome":"failed"' "run report: the reconcile wrote one, and it is failed"
want "$J" "\"name\":\"$N-leak\",\"system\":\"aeorunrepl\",\"kind\":\"container\",\"outcome\":\"failed\"" "run report: the node's converge failed"
want "$J" "was not running; the restart failed" "run report: says what was tried"
if grep -rq "$SECRET" .aeo/reports; then fail "the secret is in the reconcile report"; else pass "run report: the reconcile report does not hold the secret"; fi
wantno "$(grep "$N-leak" .aeo/audit.log)" '"event":"converge","detail":"restarted' "audit: a converge that failed is not recorded as a restart"
if grep -q "$SECRET" .aeo/audit.log; then fail "the secret is in the audit log after a failed converge"; else pass "audit: the converge-fail entry does not hold the secret"; fi
aeo down leak.ae --no-supervisor >/dev/null
podman rmi -f "localhost/aeo-built/$N-leak:latest" >/dev/null 2>&1

echo "### 6. the audit chain"
AUD="$(aeo audit good.ae)"; ARC=$?
want "$AUD" "chain:   INTACT" "audit: the chain still verifies with the run-report entries in it"
[ "$ARC" -eq 0 ] && pass "audit: exits 0 when everything verifies" || fail "audit exited $ARC on an intact chain"
N_REP="$(ls .aeo/reports/*.json | grep -vc last.json)"
N_AUD="$(grep -c 'run-report' .aeo/audit.log)"
want "$AUD" "reports: $N_REP match their entry, 0 no longer on disk" "audit: every report file still hashes to what its entry recorded"
[ "$N_REP" -gt 0 ] && [ "$N_REP" -eq "$N_AUD" ] && pass "audit: one entry per report written ($N_REP)" || fail "audit: $N_AUD entries for $N_REP reports"

echo "### 7. a report edited afterwards no longer matches the chain"
LASTUP="$(ls .aeo/reports/*-up.json | tail -1)"
sed -i 's/"outcome":"failed"/"outcome":"ok"/' "$LASTUP"
EDITED="$(sha256sum "$LASTUP" | cut -d' ' -f1)"
wantno "$(cat .aeo/audit.log)" "sha256:$EDITED" "an edited report's hash is not the one the chain recorded"
AUD="$(aeo audit good.ae)"; ARC=$?
want "$AUD" "reports: CHANGED since they were recorded:" "audit: says a report was changed"
want "$AUD" "$LASTUP" "audit: names the changed report"
[ "$ARC" -ne 0 ] && pass "audit: exits non-zero for a changed report ($ARC)" || fail "audit exited 0 with a changed report"

echo "### 8. a supervised down (the default path)"
if ae build "$ROOT/bin/aeo-supervisord.ae" -o "$WORK/aeo-supervisord" --lib "$ROOT/lib" >"$WORK/sup-build.log" 2>&1; then
    SPORT=$((20000 + $$ % 20000))
    export AEO_SUP_TOKEN="runrep-$$" AEO_SUP_URL="http://127.0.0.1:$SPORT"
    AEO_SUP_PORT=$SPORT AEO_SUP_WATCH=0 "$WORK/aeo-supervisord" >"$WORK/sup.log" 2>&1 &
    SUP=$!
    i=0; while [ $i -lt 40 ]; do curl -fsS --max-time 2 "$AEO_SUP_URL/health" >/dev/null 2>&1 && break; sleep 0.25; i=$((i + 1)); done
    OUT="$(aeo up good.ae)"
    want "$OUT" "run report: up ok" "supervised up: writes a report"
    [ "$(podman ps -q --filter "name=^$N-" | wc -l)" -eq 2 ] && pass "supervised up: both nodes are running" || fail "supervised up did not start both nodes"
    OUT="$(aeo down good.ae)"
    want "$OUT" "torn down (via supervisor)" "the down went through the supervisor"
    want "$OUT" "run report: down ok" "supervised down: writes a report"
    J="$(aeo report --json)"
    want "$J" '"command":"down","outcome":"ok"' "supervised down: the newest report is this down"
    want "$J" "\"name\":\"$N-db\",\"system\":\"aeorunrep\",\"kind\":\"container\",\"outcome\":\"stopped\"" "supervised down: db was verified gone by the runner"
    want "$J" '"counts":{"stopped":2}' "supervised down: both nodes stopped"
    [ "$(podman ps -aq --filter "name=^$N-" | wc -l)" -eq 0 ] && pass "the report matches the host: nothing is left" || fail "containers are left after a supervised down"
    kill "$SUP" 2>/dev/null; wait "$SUP" 2>/dev/null
    unset AEO_SUP_TOKEN AEO_SUP_URL
else
    tail -5 "$WORK/sup-build.log"; fail "aeo-supervisord failed to build"
fi

echo "### 9. a node that boots and never becomes healthy"
OUT="$(aeo up slow.ae --no-supervisor)"; RC=$?
[ "$RC" -ne 0 ] && pass "up: fails the run" || fail "up exited 0 with an unhealthy node"
UPR="$(ls .aeo/reports/*-up.json | tail -1)"
J="$(cat "$UPR")"
want "$J" "\"name\":\"$N-slow\",\"system\":\"aeorunreps\",\"kind\":\"container\",\"outcome\":\"timeout\"" "report: the node is timeout, not failed (its boot call worked)"
wantno "$J" "\"outcome\":\"timeout\",\"call_ms\":null" "report: a timed-out node has a call time"
want "$J" "not healthy inside its window" "report: says why"
want "$J" "\"name\":\"$N-after\",\"system\":\"aeorunreps\",\"kind\":\"container\",\"outcome\":\"not-attempted\"" "report: its dependent was never attempted"
[ "$(podman ps -aq --filter "name=^$N-" | wc -l)" -eq 0 ] && pass "the partial tree was torn down" || fail "containers left after a timed-out up"

echo "### 10. a kind that is not a container (bwrap)"
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true 2>/dev/null; then
    OUT="$(aeo up bw.ae --no-supervisor)"
    want "$OUT" "run report: up ok" "bwrap up: writes a report"
    J="$(aeo report --json)"
    want "$J" "\"name\":\"$N-bw-db\",\"system\":\"aeorunrepw\",\"kind\":\"bwrap\",\"outcome\":\"started\"" "report: a bwrap node is started"
    want "$J" '"counts":{"started":2}' "report: both bwrap nodes started"
    OUT="$(aeo reconcile bw.ae)"; RRC=$?
    want "$OUT" "no drift FOUND, but 2 node(s) could NOT be checked" "reconcile: nodes of a kind it does not cover are not called coherent"
    wantno "$OUT" "COHERENT" "reconcile: the summary does not say COHERENT for them"
    [ "$RRC" -eq 0 ] && pass "reconcile: unchecked nodes do not fail the run" || fail "reconcile exited $RRC for unchecked nodes"
    want "$(aeo report --json)" '"counts":{"unchecked":2}' "report: both are unchecked"
    OUT="$(aeo down bw.ae --no-supervisor)"
    J="$(aeo report --json)"
    want "$J" '"command":"down","outcome":"ok"' "bwrap down: writes a report, ok"
    wantno "$J" '"outcome":"lingering"' "report: no bwrap node lingers"
    want "$J" '"counts":{"halted":2}' "report: bwrap nodes are halted (signalled; this kind has no gone-check), not claimed stopped"
    # "halted" promises a signal, not absence — so give the signal a moment.
    # Matched on the process NAME (comm), not the whole command line: a shell
    # that merely mentions these words must not count as a sandbox.
    i=0; while [ $i -lt 20 ] && pgrep -x bwrap -a | grep -q "sleep 613"; do sleep 0.25; i=$((i + 1)); done
    if pgrep -x bwrap -a | grep -q "sleep 613"; then fail "a bwrap sandbox is still running 5s after down"; else pass "the host agrees: no sandbox is left"; fi
else
    echo "SKIP: bwrap is not usable on this host — the bwrap section was not exercised"
fi

echo "### 11. pruning, and a tampered chain"
OUT="$(AEO_REPORT_KEEP=2 AEO_HOME="$ROOT" "$WORK/aeo" down good.ae --no-supervisor 2>&1)"
LEFT="$(ls .aeo/reports/*.json | grep -vc last.json)"
[ "$LEFT" -eq 2 ] && pass "AEO_REPORT_KEEP=2 leaves the two newest runs" || fail "$LEFT reports left, wanted 2"
[ -f .aeo/reports/last.json ] && pass "pruning leaves last.json" || fail "last.json was pruned"
[ "$(ls .aeo/reports/*.txt | grep -vc last.txt)" -eq 2 ] && pass "each pruned report's text form went with it" || fail "text reports left behind"
AUD="$(aeo audit good.ae)"; ARC=$?
want "$AUD" "2 match their entry" "audit: the reports that remain still match"
wantno "$AUD" "CHANGED" "audit: a pruned report is not called changed (the edited one was among those pruned)"
want "$AUD" "no longer on disk" "audit: pruned reports are counted, not hidden"
[ "$ARC" -eq 0 ] && pass "audit: pruned reports do not fail verification" || fail "audit exited $ARC after pruning"
sed -i '1s/"event":"syscall-policy"/"event":"syscall-polic1"/' .aeo/audit.log
AUD="$(aeo audit good.ae)"; ARC=$?
want "$AUD" "CHAIN BROKEN" "audit: an edited log is caught"
[ "$ARC" -ne 0 ] && pass "audit: exits non-zero for a broken chain ($ARC)" || fail "audit exited 0 with a broken chain"

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASSED  ($(uname -m), kernel $(uname -r), $(podman --version), $(ae version | head -1))"
    exit 0
fi
echo "$fails FAILED"
exit 1
