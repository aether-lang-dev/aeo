#!/bin/sh
# compose-lint.sh — A5 (interim): the front-door WARNs when a composition reaches
# beyond the pure compose DSL + capability-free std (an import of a capability like
# std.os, an import of an aeo module like secrets, or a hand-declared extern). A
# composition is compiled into aeo's privileged runner, so these run with aeo's
# full authority — the lint makes that visible. Warn-only (a strict() system will
# later REFUSE; that half lands in the runner after A3).
#
#   sh test/compose-lint.sh
#
# Live harness: builds the front-door and runs `aeo dry-run <compose>` (stages +
# builds + lints, no deploy) against clean / capability / extern / aeo-module
# compositions, asserting the WARN fires (or doesn't) and that it is NON-FATAL.
# Uses `ae inspect` under the hood (no --emit-deps in this toolchain).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${TMPDIR:-/tmp}/aeo-compose-lint-$$"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

mkdir -p "$W"
AEO="$W/aeo"
if ! ae build "$ROOT/bin/aeo.ae" -o "$AEO" --lib "$ROOT/lib" >"$W/build.log" 2>&1; then
    cat "$W/build.log"; echo "FAIL: front-door build"; rm -rf "$W"; exit 1
fi

# ae inspect is the lint's engine; if this toolchain lacks it the lint is a no-op
# (by design — a missing lint must not block). Skip cleanly in that case.
if ! ae inspect "$ROOT/bin/aeo.ae" >/dev/null 2>&1; then
    echo "SKIP: this toolchain has no \`ae inspect\` — lint is a documented no-op here"
    rm -rf "$W"; exit 0
fi

cat > "$W/clean.ae" <<'AE'
import compose (system, container, image, expose)
exports ( aeo_orchestration )
aeo_orchestration() { s = system("s") { x = container("x") { image("busybox") expose(80) } } }
AE
cat > "$W/cap.ae" <<'AE'
import compose (system, container, image)
import std.os (getenv)
exports ( aeo_orchestration )
aeo_orchestration() { v = getenv("X") s = system("s") { x = container("x") { image("busybox") } } }
AE
cat > "$W/ext.ae" <<'AE'
import compose (system, container, image)
extern system(cmd: string) -> int
exports ( aeo_orchestration )
aeo_orchestration() { s = system("s") { x = container("x") { image("busybox") } } }
AE

run() { AEO_HOME="$ROOT" AEO_REBUILD=1 "$AEO" dry-run "$1" 2>&1; rm -rf "$HOME/.aeo" 2>/dev/null || true; }

echo "### clean composition -> NO lint warning, dry-run ok"
OUT="$(run "$W/clean.ae")"; RC=$?
echo "$OUT" | grep -q 'reaches beyond the compose DSL' \
    && fail "clean composition wrongly warned" \
    || pass "clean composition: no warning"

echo "### capability import (std.os) -> WARN names the capability, NON-FATAL"
OUT="$(run "$W/cap.ae")"
echo "$OUT" | grep -qE 'reaches beyond the compose DSL' \
    && echo "$OUT" | grep -qE 'capability: .*os' \
    && pass "std.os import warns, names capability os" \
    || { fail "std.os import did not warn as expected"; echo "$OUT" | grep -iE 'warning|capability' | head; }
# non-fatal: dry-run still ran to a plan (didn't exit before building)
echo "$OUT" | grep -qiE 'WARNING composition' && ! echo "$OUT" | grep -qiE 'cannot|abort' \
    && pass "capability import is NON-FATAL (warned, not refused)" \
    || fail "capability import appears to have blocked"

echo "### hand-declared extern -> WARN names the extern"
OUT="$(run "$W/ext.ae")"
echo "$OUT" | grep -qE 'extern: [0-9]+ hand-declared' \
    && pass "extern declaration warns, names it" \
    || { fail "extern declaration did not warn"; echo "$OUT" | grep -iE 'warning|extern' | head; }

echo "### aeo module import (secrets) -> WARN names the local import"
cat > "$W/sec.ae" <<'AE'
import compose (system, container, image)
import secrets
exports ( aeo_orchestration )
aeo_orchestration() { s = system("s") { x = container("x") { image("busybox") } } }
AE
OUT="$(run "$W/sec.ae")"
echo "$OUT" | grep -qE 'import: secrets .*beyond the compose DSL' \
    && pass "aeo-module import warns, names 'secrets'" \
    || { fail "secrets import did not warn"; echo "$OUT" | grep -iE 'warning|import:' | head; }

rm -rf "$W"
if [ "$fails" -ne 0 ]; then echo; echo "FAILED: $fails assertion(s)"; exit 1; fi
echo; echo "compose-lint: all assertions passed"
