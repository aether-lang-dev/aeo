#!/bin/sh
# security-posture.sh — A1: `aeo status` reports declared/supported/applied/
# verified per security property, in both human and JSON, and a CI-style gate
# can fail on any `applied: no`.
#
#   sh test/security-posture.sh
#
# This is a LIVE harness (not a std.spec data test): it builds the runner with a
# known composition staged — exactly as the front-door does (ae build run.ae
# --lib lib) — and runs `status` against it, so it exercises the real _secp_*
# model + the human and JSON renderers, not a mock.
#
# The load-bearing assertion is the claim-4 honesty case: egress_fqdn on Linux
# must report supported=no / applied=no. Before A1 there was NO such signal (the
# WARN the docs mention lives in a dead, unwired module), so `aeo status` was
# silent about the gap. If someone removes the _secp_egress_fqdn supported=no
# logic, the JSON assertion below flips to "yes" and this test FAILS — the
# negative control the plan requires.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/aeo-secposture-$$"
fails=0
note() { echo "  $1"; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

mkdir -p "$WORK/lib"
cp -r "$ROOT/lib/." "$WORK/lib/"
mkdir -p "$WORK/lib/aeo_compose"
cat > "$WORK/lib/aeo_compose/module.ae" <<'AE'
import compose (system, container)
import compose (image, expose, limit, limit_mem, constrain, egress_fqdn, attest)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("secposture") {
        web = container("web") {
            image("docker.io/library/busybox:latest")
            attest("sha256:deadbeef")
            expose(18080)
            limit("web") { limit_mem("128m") }
            constrain("web") { egress_fqdn("example.com") }
        }
    }
}
AE
cp "$ROOT/lib/aeo/runner.ae" "$WORK/run.ae"

echo "### building the runner with the posture composition staged"
if ! ( cd "$WORK" && ae build run.ae -o aeo-run --lib lib >/tmp/aeo-secposture-build.$$ 2>&1 ); then
    cat /tmp/aeo-secposture-build.$$
    fail "runner failed to build"
    rm -rf "$WORK" /tmp/aeo-secposture-build.$$
    exit 1
fi
rm -f /tmp/aeo-secposture-build.$$

HUMAN="$( cd "$WORK" && AEO_CMD=status AEO_HOME="$ROOT" ./aeo-run 2>/dev/null )"
JSON="$(  cd "$WORK" && AEO_CMD=status AEO_STATUS_JSON=1 AEO_HOME="$ROOT" ./aeo-run 2>/dev/null | tail -1 )"

echo "### human status posture"
echo "$HUMAN" | grep -qE 'egress_fqdn .*supported=no' \
    && pass "human: egress_fqdn supported=no" \
    || { fail "human: egress_fqdn not reported supported=no"; note "$(echo "$HUMAN" | grep egress_fqdn || echo '(no egress_fqdn line)')"; }
echo "$HUMAN" | grep -qE 'egress_fqdn .*applied=no' \
    && pass "human: egress_fqdn applied=no" \
    || fail "human: egress_fqdn not reported applied=no"

echo "### JSON status posture (the CI-gate surface)"
# .security.egress_fqdn.supported must be "no" — the claim-4 honesty case.
if command -v python3 >/dev/null 2>&1; then
    got="$(printf '%s' "$JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("PARSE_ERROR:%s" % e); sys.exit(0)
web = next((n for n in d if n["name"] == "web"), None)
if not web: print("NO_WEB_NODE"); sys.exit(0)
sec = web.get("security", {})
ef = sec.get("egress_fqdn", {})
print("supported=%s applied=%s" % (ef.get("supported"), (ef.get("applied") or "")[:2]))
# A CI gate: fail on any applied:no across all properties/nodes.
bad = [(n["name"], k) for n in d for k, v in n.get("security", {}).items() if str(v.get("applied","")).startswith("no")]
print("APPLIED_NO=%s" % ";".join("%s.%s" % b for b in bad))
')"
    echo "  parsed: $got"
    echo "$got" | grep -q 'supported=no applied=no' \
        && pass "JSON: .security.egress_fqdn supported=no applied=no (valid JSON)" \
        || fail "JSON: egress_fqdn posture wrong or JSON invalid"
    # the CI gate must SEE at least the egress_fqdn applied:no (proves gate works).
    echo "$got" | grep -q 'APPLIED_NO=.*web.egress_fqdn' \
        && pass "JSON: a CI gate can fail on applied:no (web.egress_fqdn flagged)" \
        || fail "JSON: CI gate found no applied:no to flag"
else
    note "python3 absent — JSON structural check skipped (grep fallback)"
    printf '%s' "$JSON" | grep -q '"egress_fqdn":{"declared":"example.com","supported":"no"' \
        && pass "JSON: egress_fqdn supported=no (grep)" \
        || fail "JSON: egress_fqdn supported=no not found (grep)"
fi

echo "### positive control: a supported property reports supported=yes"
echo "$HUMAN" | grep -qE 'limits .*supported=yes' \
    && pass "human: limits supported=yes (not everything is 'no')" \
    || fail "human: limits should be supported=yes"

rm -rf "$WORK"
if [ "$fails" -ne 0 ]; then
    echo
    echo "FAILED: $fails assertion(s)"
    exit 1
fi
echo
echo "security-posture: all assertions passed"
