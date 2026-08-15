#!/bin/sh
# run-spec.sh — run aeo's BDD spec(s).
#
# The BDD framework is `std.spec` — SHIPPED IN THE AETHER STDLIB as of ae
# 0.538.0, so there is NO sibling checkout to find and NO extra `--lib` to
# wire: only aeo's own lib/ goes on the module path. (The four HTTP-shaped
# specs additionally import std.http.client.httptest, also stdlib.)
# Data-model cases run anywhere; live-deployment cases run only when
# AEO_VERIFY=1 (against a deployed system).
#
#   sh test/run-spec.sh                         # run every test/spec_*.ae
#   sh test/run-spec.sh test/spec_running_nodes.ae   # run one spec
#   AEO_VERIFY=1 sh test/run-spec.sh            # + live checks
#
# HISTORY: aeo's specs used the standalone `aeocha` framework, which required
# a sibling clone and an `AEOCHA=` override. Aether absorbed aeocha's pure
# core into `std.spec` (0.538.0) and its process/HTTP matchers into
# `std.os.testing` / `std.http.client.httptest`; the aeocha repo is retired.
# The whole discovery-and-override block that used to live here is gone —
# that is the point of the absorption.
#
# One spec failing to build or run does NOT abort the rest — each is reported
# and the script exits non-zero at the end if any failed. (Some specs are
# FreeBSD-only — the capsicum/containment ones need a Capsicum kernel — and
# will fail to run off-BSD; that must not mask the rest of the suite.)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Toolchain floor (AETHER_PIN) ------------------------------------------
# WARN, don't fail: a too-old `ae` shows up as a wall of E0300/E0301 errors in
# EVERY spec ("Undefined variable 'spec'"), which reads as "aeo is broken"
# rather than "your toolchain predates std.spec". One line up front turns a
# confusing 78-file failure into a diagnosis. Kept non-fatal so an unreleased
# / locally-built `ae` with an odd version string can still run the suite.
PIN="$(grep -v '^#' "$ROOT/AETHER_PIN" 2>/dev/null | tr -d '[:space:]')"
HAVE="$(ae --version 2>/dev/null | head -n1 | sed -n 's/^ae \([0-9][0-9.]*\).*/\1/p')"
if [ -n "$PIN" ] && [ -n "$HAVE" ] && \
   [ "$(printf '%s\n%s\n' "$PIN" "$HAVE" | sort -V | head -n1)" != "$PIN" ]; then
    echo "WARNING: ae $HAVE is older than AETHER_PIN $PIN."
    echo "  The specs import std.spec (stdlib since 0.538.0, absorbed from aeocha)."
    echo "  Expect 'Undefined variable spec' everywhere until you upgrade:"
    echo "    (cd ~/scm/aether && ./install.sh)   # or: ae version install $PIN"
    echo
fi

failures=""
OS="$(uname -s)"

run_one() {
    echo "### $1"
    # The Capsicum/containment specs are FreeBSD-only. Two flavours:
    #  - C-helper specs (bhyve_model, breakout) use test/capfd.c, whose FreeBSD
    #    errnos (ECAPMODE/ENOTCAPABLE) won't even C-compile off FreeBSD.
    #  - SELF-REPORT specs (jail/bhyvevm) drive a python3 harness that spawns a
    #    self-confining probe inside a jail/VM (test/capharness.py + capprobe.py)
    #    — no C helper; they need python3 + sudo jail/jexec + the harness staged
    #    to /tmp. (jail self-report is RUNNABLE on this box, verified 2026-06-26.)
    # Off FreeBSD, skip all of them.
    extra=""
    case "$1" in
        *spec_capsicum_*|*spec_containment_*)
            if [ "$OS" != "FreeBSD" ]; then
                echo "  (skipped — FreeBSD-only: Capsicum kernel + BSD errnos)"
                return
            fi
            ;;
    esac
    case "$1" in
        *spec_capsicum_bhyve_model*|*spec_capsicum_breakout*)
            extra="--extra $ROOT/test/capfd.c" ;;
        *spec_capsicum_jail_selfreport*|*spec_capsicum_bhyvevm_selfreport*)
            # stage the python harness the spec shells to /tmp.
            cp "$ROOT/test/capharness.py" "$ROOT/test/capprobe.py" /tmp/ 2>/dev/null || true
            cp "$ROOT/test/capharness_freebsd.py" "$ROOT/test/capprobe_freebsd.c" /tmp/ 2>/dev/null || true
            ;;
        *spec_egress_splice_live*)
            # LIVE splice test: build the gateway binary + stage its python
            # harness where the spec shells to them. If the build fails (or
            # python3 is absent) the spec self-skips as HARNESS_UNAVAILABLE.
            cp "$ROOT/test/egress_splice_harness.py" /tmp/ 2>/dev/null || true
            ae build "$ROOT/bin/aeo-egress-gateway.ae" -o /tmp/aeo-egress-gateway-live \
                --lib "$ROOT/lib" >/dev/null 2>&1 || true
            ;;
        *spec_driver_loadbalancer_live*)
            # LIVE LB lifecycle test: the driver runs the aeo-lb CONTAINER, so it
            # needs the aeo-lb image (localhost/aeo/aeo-lb:latest). The plain suite
            # does NOT build that image, so this spec self-skips as UNAVAILABLE here;
            # the end-to-end proof is the `aeo up` step-3 run (docs §9). Left as a
            # no-op stage: to run it live, build the image first (see docs §9).
            : ;;
    esac
    # build-then-run, not `ae run`: `ae run` caches by content and can serve a
    # stale compiled dependency (e.g. an edited lib/compose) — build to a fresh
    # binary each time so edits always take.
    bin="/tmp/aeo-spec-$(basename "$1" .ae)"
    if ! ae build "$1" -o "$bin" --lib "$ROOT/lib" $extra; then
        echo "  (build failed)"
        failures="$failures $1"
        return
    fi
    if ! "$bin"; then
        failures="$failures $1"
    fi
}

if [ "$#" -gt 0 ]; then
    for spec in "$@"; do run_one "$spec"; done
else
    for spec in "$ROOT"/test/spec_*.ae; do run_one "$spec"; done
fi

if [ -n "$failures" ]; then
    echo
    echo "FAILED specs:$failures"
    exit 1
fi
