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
RC_OUT="$(aeo reconcile leak.ae --converge)"
want "$RC_OUT" "converge FAILED" "reconcile --converge: the same build fails again"
want "$RC_OUT" "TOKEN=$SECRET" "reconcile: the terminal shows the build output, secret included"
want "$(cat .aeo/audit.log)" '"event":"converge-fail"' "audit: the failed converge is recorded"
wantno "$(grep "$N-leak" .aeo/audit.log)" '"event":"converge","detail":"restarted' "audit: a converge that failed is not recorded as a restart"
if grep -q "$SECRET" .aeo/audit.log; then fail "the secret is in the audit log after a failed converge"; else pass "audit: the converge-fail entry does not hold the secret"; fi
aeo down leak.ae --no-supervisor >/dev/null
podman rmi -f "localhost/aeo-built/$N-leak:latest" >/dev/null 2>&1

echo "### 6. the audit chain"
AUD="$(aeo audit good.ae)"
want "$AUD" "chain:   INTACT" "audit: the chain still verifies with the run-report entries in it"
N_REP="$(ls .aeo/reports/*.json | grep -vc last.json)"
N_AUD="$(grep -c 'run-report' .aeo/audit.log)"
[ "$N_REP" -gt 0 ] && [ "$N_REP" -eq "$N_AUD" ] && pass "audit: one entry per report written ($N_REP)" || fail "audit: $N_AUD entries for $N_REP reports"

echo "### 7. a report edited afterwards no longer matches the chain"
LASTUP="$(ls .aeo/reports/*-up.json | tail -1)"
sed -i 's/"outcome":"failed"/"outcome":"ok"/' "$LASTUP"
EDITED="$(sha256sum "$LASTUP" | cut -d' ' -f1)"
wantno "$(cat .aeo/audit.log)" "sha256:$EDITED" "an edited report's hash is not the one the chain recorded"

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASSED  ($(uname -m), kernel $(uname -r), $(podman --version), $(ae version | head -1))"
    exit 0
fi
echo "$fails FAILED"
exit 1
