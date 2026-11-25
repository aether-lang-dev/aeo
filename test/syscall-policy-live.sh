#!/bin/sh
# syscall-policy-live.sh — the syscall policy through the FRONT DOOR, against a
# real container: `aeo up`, `aeo status`, `aeo reconcile [--converge]`.
#
#   sh test/syscall-policy-live.sh
#
# test/spec_syscall_policy_live.ae proves the kernel refuses what a rendered
# profile denies. This proves the parts around it that only exist in the
# runner:
#   - a node boots under its profile and `status` VERIFIES it from the engine;
#   - a container swapped for an unconfined one is reported (status), detected
#     (reconcile) and put back (reconcile --converge);
#   - a profile that no longer matches the declared policy is detected;
#   - a typo, and a substrate the policy is not rendered for (bwrap), are refused at
#     boot and say so in status.
#
# Needs podman and the test image present locally (AEO_SPEC_IMAGE, default
# docker.io/library/debian:trixie). Without them it prints SKIP and exits 0 —
# it does not report a pass. Nothing is pulled. Uses $HOME/.aeo/seccomp.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${AEO_SPEC_IMAGE:-docker.io/library/debian:trixie}"
WORK="${TMPDIR:-/tmp}/aeo-syspol-$$"
N="aeo-syspol-live"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
has()  { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
want()   { if has "$1" "$2"; then pass "$3"; else fail "$3"; echo "  wanted: $2"; echo "  got:    $1" | head -5; fi; }
wantno() { if has "$1" "$2"; then fail "$3"; echo "  did not want: $2"; else pass "$3"; fi; }

if ! command -v podman >/dev/null 2>&1; then
    echo "SKIP: podman is not on this host — nothing was exercised"; exit 0
fi
if ! podman image inspect "$IMG" >/dev/null 2>&1; then
    echo "SKIP: image $IMG is not present locally (pull it, or set AEO_SPEC_IMAGE) — nothing was exercised"; exit 0
fi

mkdir -p "$WORK" && cd "$WORK" || exit 1
compose() {   # compose FILE SYSTEM KINDVERB NODE IMAGE POLICY2
    cat > "$1" <<AE
import compose (system, $3)
import compose (image, command, health, constrain, deny_syscalls)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("$2") {
        $3("$4") {
            image("$5")
            command("sleep 600")
            health("true")
            constrain("$4") {
                deny_syscalls("namespace")
                deny_syscalls("$6")
            }
        }
    }
}
AE
}
compose ok.ae   aeosyspol  container "$N"      "$IMG"        debug
compose typo.ae aeosyspolt container "$N-typo" "$IMG"        debgu
compose bwrap.ae aeosyspolb bwrap    "$N-bwrap" "$IMG"        debug

echo "### building aeo"
if ! ae build "$ROOT/bin/aeo.ae" -o "$WORK/aeo" --lib "$ROOT/lib" >"$WORK/build.log" 2>&1; then
    tail -20 "$WORK/build.log"; fail "aeo failed to build"; rm -rf "$WORK"; exit 1
fi
aeo() { AEO_HOME="$ROOT" "$WORK/aeo" "$@" 2>&1; }
cleanup() {
    aeo down ok.ae >/dev/null; aeo down typo.ae >/dev/null; aeo down bwrap.ae >/dev/null
    podman rm -f "$N" "$N-typo" >/dev/null 2>&1
    rm -f "$HOME/.aeo/seccomp/$N.json" "$HOME/.aeo/seccomp/$N-typo.json"
    cd /; rm -rf "$WORK"
}
PROFILE="$HOME/.aeo/seccomp/$N.json"
podman rm -f "$N" >/dev/null 2>&1

echo "### 1. a node boots under its profile, and status verifies it"
OUT="$(aeo up ok.ae)"
want "$OUT" "[$N] up" "aeo up brings the node up"
ST="$(aeo status ok.ae)"
want "$ST" "verified=engine reports seccomp=$PROFILE" "status: the engine reports the profile aeo wrote"
wantno "$ST" "!syscalls" "status: the syscalls row is not flagged"
JS="$(AEO_STATUS_JSON=1 AEO_HOME="$ROOT" "$WORK/aeo" status ok.ae 2>/dev/null | tail -1)"
want "$JS" '"syscalls":{"declared":"namespace,debug","supported":"yes"' "status --json carries the syscalls row"
IN="$(podman exec "$N" sh -c 'unshare -U true 2>&1; echo rc=$?')"
want "$IN" "Operation not permitted" "inside the node, unshare is refused"
RC="$(aeo reconcile ok.ae)"
wantno "$RC" "DRIFT" "reconcile: a node under its profile has not drifted"

echo "### 2. the container is swapped for an unconfined one"
podman rm -f "$N" >/dev/null 2>&1
podman run -d --name "$N" "$IMG" sleep 600 >/dev/null 2>&1
ST="$(aeo status ok.ae)"
want "$ST" "!syscalls" "status: the row is flagged"
want "$ST" "applied=no (the running container reports NO seccomp profile)" "status: says the node runs without its profile"
RC="$(aeo reconcile ok.ae)"
want "$RC" "[$N] DRIFT: seccomp: declared deny=namespace,debug" "reconcile: detects the missing profile"
IN="$(podman exec "$N" sh -c 'unshare -U true 2>&1 && echo UNSHARE_OK')"
want "$IN" "UNSHARE_OK" "without --converge nothing was changed (alert, not mutate)"

echo "### 3. reconcile --converge puts the profile back"
RC="$(aeo reconcile ok.ae --converge)"
want "$RC" "converge: recreating" "reconcile --converge recreates the node"
IN="$(podman exec "$N" sh -c 'unshare -U true 2>&1; echo rc=$?')"
want "$IN" "Operation not permitted" "after converge, unshare is refused again"
RC="$(aeo reconcile ok.ae)"
wantno "$RC" "DRIFT" "after converge, no drift"
AU="$(cat .aeo/audit.log 2>/dev/null)"
want "$AU" '"event":"drift","detail":"seccomp:' "the drift is in the audit chain"

echo "### 4. the profile no longer matches the declared policy"
echo ' ' >> "$PROFILE"
RC="$(aeo reconcile ok.ae)"
want "$RC" "booted under a profile that is not what deny=namespace,debug renders now" "reconcile: detects a profile that differs from the policy"

echo "### 5. fail closed"
OUT="$(aeo up typo.ae)"
want "$OUT" "REFUSED — deny_syscalls(): unknown syscall class 'debgu'" "a typo refuses the boot"
if podman container exists "$N-typo" 2>/dev/null; then fail "a typo started nothing"; else pass "a typo started nothing"; fi
ST="$(aeo status typo.ae)"
want "$ST" "applied=no (bad entry:" "status: a typo is applied=no"
# bwrap stands for "a substrate the policy is not rendered for". When bwrap
# gains a renderer, move this to one that still has none — do not delete it.
OUT="$(aeo up bwrap.ae)"
want "$OUT" "a syscall policy is not rendered for kind 'bwrap' yet" "a bwrap node with a policy is refused"
ST="$(aeo status bwrap.ae)"
want "$ST" "supported=no applied=no (not rendered for kind 'bwrap')" "status: bwrap is supported=no"

cleanup
echo
if [ "$fails" -eq 0 ]; then echo "syscall-policy-live: all assertions passed"; exit 0; fi
echo "syscall-policy-live: $fails assertion(s) FAILED"; exit 1
