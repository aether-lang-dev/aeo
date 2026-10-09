#!/bin/sh
# strict-mode.sh — A2: a strict() system REFUSES a node whose declared security
# property is unsupported / failed-to-apply, or whose image is unpinned. Default
# (non-strict) behaviour is unchanged.
#
#   sh test/strict-mode.sh
#
# Live harness (like security-posture.sh): stages a composition, builds the runner
# as the front-door does (ae build run.ae --lib lib), runs `aeo up`, and greps the
# refusal lines. The gate is the FIRST thing driver_up() does, so a refusal fires
# BEFORE any podman work — the test needs no container to actually boot.
#
# Cases:
#   1. strict + egress_fqdn on Linux  -> REFUSED, message names egress_fqdn
#   2. strict + unpinned image()      -> REFUSED, message names "unpinned"
#   3. strict + fully-supported node  -> NOT refused (strict must not over-refuse)
#   4. NON-strict + egress_fqdn       -> NOT refused (negative control: the gate,
#                                        not something else, is what refuses)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# run_up <label> <compose-body> -> echoes the `aeo up` output (stderr+stdout).
run_up() {
    _w="${TMPDIR:-/tmp}/aeo-strict-$$-$1"
    rm -rf "$_w"; mkdir -p "$_w/lib/aeo_compose"
    cp -r "$ROOT/lib/." "$_w/lib/"
    printf '%s\n' "$2" > "$_w/lib/aeo_compose/module.ae"
    cp "$ROOT/lib/aeo/runner.ae" "$_w/run.ae"
    if ! ( cd "$_w" && ae build run.ae -o aeo-run --lib lib ) >"$_w/build.log" 2>&1; then
        echo "BUILD_FAILED"; cat "$_w/build.log"; rm -rf "$_w"; return 1
    fi
    ( cd "$_w" && AEO_CMD=up AEO_HOME="$ROOT" ./aeo-run 2>&1 )
    rm -rf "$_w"
}

# NOTE: a node is "pinned" only via attest() — a @sha256 in image() is not an
# attest pin (attest_state checks the attest() value). So these pinned cases carry
# attest(...) to isolate the property under test from the unpinned-image check.
STRICT_EGRESS='import compose (system, container, image, expose, attest, constrain, egress_fqdn, strict)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("s") {
        strict()
        web = container("web") {
            image("docker.io/library/busybox:latest")
            attest("sha256:aaaa")
            expose(18080)
            constrain("web") { egress_fqdn("example.com") }
        }
    }
}'

STRICT_UNPINNED='import compose (system, container, image, expose, strict)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("s") {
        strict()
        web = container("web") { image("docker.io/library/busybox:latest") expose(18080) }
    }
}'

STRICT_OK='import compose (system, container, image, expose, attest, limit, limit_mem, strict)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("s") {
        strict()
        web = container("web") {
            image("docker.io/library/busybox:latest")
            attest("sha256:aaaa")
            expose(18080)
            limit("web") { limit_mem("128m") }
        }
    }
}'

LOOSE_EGRESS='import compose (system, container, image, expose, constrain, egress_fqdn)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("s") {
        web = container("web") {
            image("docker.io/library/busybox@sha256:aaaa")
            expose(18080)
            constrain("web") { egress_fqdn("example.com") }
        }
    }
}'

echo "### case 1: strict + egress_fqdn (Linux) -> refuse naming egress_fqdn"
OUT="$(run_up c1 "$STRICT_EGRESS")" || { fail "case1 build"; OUT=""; }
echo "$OUT" | grep -qE 'STRICT REFUSED .*egress_fqdn' \
    && pass "strict refuses egress_fqdn, names the property" \
    || { fail "strict did not refuse egress_fqdn"; echo "  --- got ---"; echo "$OUT" | grep -iE 'web|strict|up failed' | head; }

echo "### case 2: strict + unpinned image -> refuse naming 'unpinned'"
OUT="$(run_up c2 "$STRICT_UNPINNED")" || { fail "case2 build"; OUT=""; }
echo "$OUT" | grep -qE 'STRICT REFUSED .*unpinned' \
    && pass "strict refuses unpinned image, names it" \
    || { fail "strict did not refuse unpinned image"; echo "  --- got ---"; echo "$OUT" | grep -iE 'web|strict|up failed' | head; }

echo "### case 3 (positive control): strict + fully-supported node -> NOT strict-refused"
OUT="$(run_up c3 "$STRICT_OK")" || { fail "case3 build"; OUT=""; }
echo "$OUT" | grep -q 'STRICT REFUSED' \
    && { fail "strict over-refused a supported node"; echo "$OUT" | grep -i strict | head; } \
    || pass "strict allows a fully-supported (pinned, limit-only) node past the gate"

echo "### case 4 (negative control): NON-strict + egress_fqdn -> NOT strict-refused"
OUT="$(run_up c4 "$LOOSE_EGRESS")" || { fail "case4 build"; OUT=""; }
echo "$OUT" | grep -q 'STRICT REFUSED' \
    && { fail "non-strict system refused — the gate is not gated on strict()!"; echo "$OUT" | grep -i strict | head; } \
    || pass "non-strict egress_fqdn boots past the gate (removing strict lets it through)"

if [ "$fails" -ne 0 ]; then
    echo; echo "FAILED: $fails assertion(s)"; exit 1
fi
echo; echo "strict-mode: all assertions passed"
