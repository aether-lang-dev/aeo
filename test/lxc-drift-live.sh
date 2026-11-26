#!/bin/sh
# lxc-drift-live.sh — `aeo reconcile` on a real LXC system container: liveness
# and the syscall policy, through the FRONT DOOR (`aeo up`, `aeo reconcile
# [--converge]`, `aeo report`).
#
#   sh test/lxc-drift-live.sh
#
# test/spec_confine_lxc.ae proves confine_lxc.drift() as a pure function and
# test/spec_confine_lxc_live.ae proves the kernel refuses what a profile denies.
# This proves the runner's _reconcile_lxc reads the right facts off a real LXC:
#   1. a node up under deny_syscalls("namespace") is coherent (and the report
#      says so);
#   2. the same container restarted by hand WITHOUT the profile is drift,
#      --converge recreates it under the profile, and a second reconcile is
#      coherent;
#   3. the node's profile file edited by hand is drift;
#   4. a start log that cannot be read is UNCHECKED: exit 0, nothing recreated.
# It also prints whether reconcile could read /proc/<init>/status and the start
# log WITHOUT sudo (it reads both as its own user; only lxc-* go through sudo).
#
# Needs lxc-utils (lxc-create/-start/-info) and a passwordless `sudo -n` for
# them, ROOTFUL LXC, and network for the `download` template (alpine:3.21,
# AEO_LXC_IMAGE overrides). Without lxc or sudo it prints SKIP and exits 0 — it
# does not report a pass. Own node name, own log dir, own profile file; all
# removed at the end.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${AEO_LXC_IMAGE:-alpine:3.21}"
WORK="${TMPDIR:-/tmp}/aeo-lxcdrift-$$"
N="aeo-lxcdrift"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
has()  { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
want()   { if has "$1" "$2"; then pass "$3"; else fail "$3"; echo "  wanted: $2"; echo "  got:    $1" | head -8; fi; }
wantno() { if has "$1" "$2"; then fail "$3"; echo "  did not want: $2"; echo "  got:    $1" | head -8; else pass "$3"; fi; }

for t in lxc-create lxc-start lxc-info lxc-stop lxc-destroy; do
    [ -x "/usr/bin/$t" ] || { echo "SKIP: /usr/bin/$t is not on this host (lxc-utils) — nothing was exercised"; exit 0; }
done
sudo -n true >/dev/null 2>&1 || { echo "SKIP: passwordless sudo is needed for lxc-* (rootful LXC) — nothing was exercised"; exit 0; }
if sudo -n lxc-info -n "$N" >/dev/null 2>&1; then
    echo "SKIP: a container named $N already exists here — not touching it"; exit 0
fi

mkdir -p "$WORK" && cd "$WORK" || exit 1
export AEO_LXC_LOG_DIR="$WORK/lxclog"      # the start log is ours, and removed with $WORK
mkdir -p "$AEO_LXC_LOG_DIR"
LOG="$AEO_LXC_LOG_DIR/aeo-lxc-$N.log"
PROFILE="$HOME/.aeo/seccomp/$N.lxc"
cat > node.ae <<AE
import compose (system, lxc)
import compose (image, constrain, deny_syscalls)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("aeolxcdrift") {
        lxc("$N") {
            image("$IMG")
            constrain("$N") {
                deny_syscalls("namespace")
            }
        }
    }
}
AE

echo "### building aeo"
if ! ae build "$ROOT/bin/aeo.ae" -o "$WORK/aeo" --lib "$ROOT/lib" >"$WORK/build.log" 2>&1; then
    tail -20 "$WORK/build.log"; fail "aeo failed to build"; rm -rf "$WORK"; exit 1
fi
aeo() { AEO_HOME="$ROOT" "$WORK/aeo" "$@" 2>&1; }
cleanup() {
    chmod 644 "$LOG" 2>/dev/null
    aeo down node.ae >/dev/null
    sudo -n lxc-stop -n "$N" -k >/dev/null 2>&1
    sudo -n lxc-destroy -n "$N" >/dev/null 2>&1
    rm -f "$PROFILE"
    cd /; rm -rf "$WORK"
}
# pass/fail of a reconcile is its exit status as well as its words
reconcile() {   # reconcile [--converge] -> sets OUT and RC
    OUT="$(aeo reconcile node.ae "$@")"; RC=$?
}
init_pid() { sudo -n lxc-info -n "$N" -p -H 2>/dev/null; }
trap 'cleanup' EXIT

echo "### 1. a node up under deny_syscalls(\"namespace\") is coherent"
OUT="$(aeo up node.ae)"
if printf '%s\n' "$OUT" | grep -qFx "aeo: [$N] up"; then pass "aeo up brings the lxc node up"
else fail "aeo up brings the lxc node up"; printf '%s\n' "$OUT" | grep -F "[$N]" | head -5 | sed 's/^/  got:    /'; fi
AU="$(cat .aeo/audit.log 2>/dev/null)"
want "$AU" "\"event\":\"syscall-policy\",\"detail\":\"deny=namespace stock=" "the lxc syscall-policy audit entry is written"
PSHA="$(sha256sum "$HOME/.aeo/seccomp/$N.lxc" 2>/dev/null | cut -d' ' -f1)"
want "$AU" "sha256=$PSHA\"" "the audit entry ends with the sha256 of the profile on disk"
PID="$(init_pid)"
# what reconcile reads without sudo: the init's /proc status and aeo's start log
if [ -n "$PID" ] && grep -q '^Seccomp:' "/proc/$PID/status" 2>/dev/null; then pass "FINDING: /proc/<init>/status is readable without sudo"
else fail "FINDING: /proc/<init>/status is NOT readable without sudo"; fi
if [ -r "$LOG" ]; then pass "FINDING: the start log is readable without sudo"
else fail "FINDING: the start log is NOT readable without sudo"; ls -l "$LOG" 2>&1 | sed 's/^/  got:    /'; fi
reconcile
want "$OUT" "reconcile — COHERENT (no drift)" "reconcile: COHERENT"
wantno "$OUT" "UNCHECKED" "reconcile: the node is not left unchecked"
[ "$RC" -eq 0 ] && pass "reconcile exits 0" || fail "reconcile exits 0 (got $RC)"
J="$(aeo report --json)"
want "$J" "\"name\":\"$N\",\"system\":\"aeolxcdrift\",\"kind\":\"lxc\",\"outcome\":\"coherent\"" "run report: the node is coherent"
want "$J" "syscall policy deny=namespace verified" "run report: says the policy was verified"
IN="$(sudo -n lxc-attach -n "$N" -- sh -c 'unshare -U true 2>&1; echo rc=$?')"
want "$IN" "Operation not permitted" "inside the node, unshare is refused"

echo "### 2a. restarted by hand WITHOUT -s lxc.seccomp.profile (same start log)"
sudo -n lxc-stop -n "$N" -k >/dev/null 2>&1
sudo -n lxc-start -n "$N" -d -o "$LOG" -l INFO >/dev/null 2>&1
IN="$(sudo -n lxc-attach -n "$N" -- sh -c 'unshare -U true 2>&1 && echo UNSHARE_OK')"
want "$IN" "UNSHARE_OK" "the hand-started container runs without the policy"
reconcile
if has "$OUT" "[$N] DRIFT: seccomp:"; then pass "reconcile: DRIFT, seccomp"; else fail "reconcile: DRIFT, seccomp"; echo "  got: $OUT" | head -6; fi
if has "$OUT" "started without" || has "$OUT" "no seccomp filter"; then pass "reconcile: names the missing profile (MISSING or NOFILTER)"
else fail "reconcile: names the missing profile (MISSING or NOFILTER)"; fi
[ "$RC" -eq 1 ] && pass "reconcile exits 1" || fail "reconcile exits 1 (got $RC)"
J="$(aeo report --json)"
want "$J" '"outcome":"drifted"' "run report: the node is drifted"
IN="$(sudo -n lxc-attach -n "$N" -- sh -c 'unshare -U true 2>&1 && echo UNSHARE_OK')"
want "$IN" "UNSHARE_OK" "without --converge nothing was changed (alert, not mutate)"
OLDPID="$(init_pid)"
reconcile --converge
want "$OUT" "converge: recreating" "reconcile --converge recreates the node"
NEWPID="$(init_pid)"
if [ -n "$NEWPID" ] && [ "$NEWPID" != "$OLDPID" ]; then pass "the container really was restarted (new init)"; else fail "the container really was restarted (new init)"; fi
J="$(aeo report --json)"
want "$J" '"outcome":"converged"' "run report: the node is converged"
IN="$(sudo -n lxc-attach -n "$N" -- sh -c 'unshare -U true 2>&1; echo rc=$?')"
want "$IN" "Operation not permitted" "after converge, unshare is refused again"
reconcile
want "$OUT" "reconcile — COHERENT (no drift)" "a second reconcile is coherent"
AU="$(cat .aeo/audit.log 2>/dev/null)"
want "$AU" '"event":"drift","detail":"seccomp:' "the drift is in the audit chain"

echo "### 2b. restarted by hand, logging elsewhere (nothing in aeo's log records this init)"
sudo -n lxc-stop -n "$N" -k >/dev/null 2>&1
sudo -n lxc-start -n "$N" -d >/dev/null 2>&1
reconcile
# The usual way a container comes back by hand: lxc-start -n NAME. aeo's start
# always logs to its own file, so an init that is not in it was started by
# something else — drift (found on ae-x64: it used to be "unchecked", and
# --converge left the unconfined node alone).
want "$OUT" "is not in LXC's start log" "reconcile: DRIFT, this init is not in aeo's start log"
[ "$RC" -eq 1 ] && pass "reconcile exits 1" || fail "reconcile exits 1 (got $RC)"
OLDPID="$(init_pid)"
reconcile --converge >/dev/null
[ "$(init_pid)" != "$OLDPID" ] && pass "--converge restarted it" || fail "--converge restarted it"
reconcile
want "$OUT" "reconcile — COHERENT (no drift)" "...and then the node is coherent"
wantno "$OUT" "UNCHECKED" "...and not merely unchecked"

echo "### 3. the profile file edited by hand"
echo ' ' >> "$PROFILE"
reconcile
want "$OUT" "is not what deny=namespace renders over the host's stock profile now" "reconcile: DRIFT, the profile file is not what the policy renders"
[ "$RC" -eq 1 ] && pass "reconcile exits 1" || fail "reconcile exits 1 (got $RC)"
reconcile --converge >/dev/null
reconcile
want "$OUT" "reconcile — COHERENT (no drift)" "after --converge the profile is re-rendered and the node coherent"

echo "### 4. the start log made unreadable"
PIDBEFORE="$(init_pid)"
chmod 000 "$LOG"
if [ -r "$LOG" ]; then
    echo "SKIP: 4 — this user reads a mode-000 file (root?)"
else
    reconcile
    want "$OUT" "[$N] UNCHECKED:" "reconcile: UNCHECKED"
    wantno "$OUT" "DRIFT" "reconcile: not called drift"
    [ "$RC" -eq 0 ] && pass "reconcile exits 0" || fail "reconcile exits 0 (got $RC)"
    J="$(aeo report --json)"
    want "$J" '"outcome":"unchecked"' "run report: the node is unchecked"
    reconcile --converge
    [ "$(init_pid)" = "$PIDBEFORE" ] && pass "nothing was recreated (same init, even under --converge)" || fail "nothing was recreated (same init, even under --converge)"
fi
chmod 644 "$LOG"

echo
if [ "$fails" -eq 0 ]; then echo "lxc-drift-live: all assertions passed"; exit 0; fi
echo "lxc-drift-live: $fails assertion(s) FAILED"; exit 1
