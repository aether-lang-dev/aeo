#!/usr/bin/env bash
# aeboot.sh — install/ensure the Aether toolchain (`ae`), plus the shared shell
# primitives a repo's bootstrap.sh needs. SOURCE this, don't execute it:
#
#     . <(curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeo/main/aeboot.sh)
#     ae_ensure          # guarantees `ae >= AE_PIN` is on PATH (fetches if not)
#
# This is the SHARED half of the bootstrap story. It is deliberately curled,
# not `import`ed: at bootstrap time nothing is installed yet, so the logic that
# installs the toolchain cannot itself live inside the toolchain. It lives here,
# in ONE place, so a fix (a moved installer URL, a glibc floor, a better probe)
# is made once and every repo that curls it inherits it — instead of the same
# ~95 lines drifting across N copy-pasted bootstrap.sh files (which is exactly
# what happened to servirtium-vcr and html-sanitizer; this file is the cure).
#
# WHERE THIS LIVES. During bring-up it is pioneered in the `aeo` repo so the
# whole loop (edit -> commit -> observe raw.githubusercontent redeploy -> run)
# happens in one repo. Once stable it MOVES to the root of the `aether` repo,
# beside get.sh, and the curl URL above changes to
# .../aether-lang-dev/aether/main/aeboot.sh. The aeb half lives in aebboot.sh
# (-> aeb repo root, beside install.sh). See the completion plan.
#
# ---------------------------------------------------------------------------
# AEBOOT_REV: 1
# ^ PROPAGATION SNIFF MARKER. Bumped by hand on every change to this file.
# raw.githubusercontent.com serves a cached copy that lags a push by up to a
# few minutes, so after pushing you cannot tell from the URL alone whether you
# are looking at your new version or the stale one. Poll for THIS exact line:
#
#     want=7
#     until curl -fsSL .../aeo/main/aeboot.sh | grep -q "AEBOOT_REV: $want"; do
#         sleep 15; done
#
# When the marker matches the number you just pushed, raw has redeployed and it
# is safe to run the real curl-based bootstrap. (A commit hash can't be used —
# a file can't contain its own not-yet-existing hash — so this monotonic
# integer is the honest stamp.)
# ---------------------------------------------------------------------------

# --- Contract (what the CALLER sets before calling ae_ensure) ---------------
#   AE_PIN     FLOOR: oldest ae that can build this repo. Required.
#              An already-installed ae >= AE_PIN is accepted as-is (no fetch).
#   AE_FETCH   KNOWN-GOOD release get.sh installs when the floor is unmet.
#              MUST be >= AE_PIN. Defaults to AE_PIN if unset (floor-only repos).
#   AETHER_REF (env) explicit override of what to install (tag/branch/SHA).
#              Wins over AE_FETCH. This is the CI pin knob.
#   PREFIX     (env) install prefix. Default $HOME/.local (no sudo).
#
# aeboot.sh sets `set -euo pipefail` is the CALLER's job — sourcing must not
# silently change the caller's shell options in a way it did not ask for. The
# functions here are written to be correct under either setting.

AEBOOT_AETHER_GET_URL="${AEBOOT_AETHER_GET_URL:-https://raw.githubusercontent.com/aether-lang-dev/aether/main/get.sh}"

# --- Shared primitives (used by aeboot.sh, aebboot.sh, and the caller) ------
# Guarded so sourcing BOTH aeboot.sh and aebboot.sh doesn't redefine them or
# error under `set -u`. Define only if not already defined.
if ! declare -f say >/dev/null 2>&1; then
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fi
if ! declare -f die >/dev/null 2>&1; then
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
fi
if ! declare -f version_ge >/dev/null 2>&1; then
# version_ge A B : true if A >= B (semver-ish, via sort -V)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
fi
if ! declare -f ae_version >/dev/null 2>&1; then
# ae_version : print the bare X.Y.Z of the ae on PATH, or nothing.
ae_version() { ae --version 2>/dev/null | head -n1 | sed -E 's/^ae ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'; }
fi
if ! declare -f fetch_run >/dev/null 2>&1; then
# fetch_run URL : download an installer to a temp file and run it under sh,
# inheriting the (exported) env the caller set. Downloading first (rather than
# `curl | sh`) means a fetch failure is not masked by the pipe.
fetch_run() {
    command -v curl >/dev/null 2>&1 || die "curl is required to install the toolchain (or install ae/aeb yourself and re-run)."
    local tmp rc; tmp="$(mktemp)"
    if curl -fsSL "$1" -o "$tmp"; then sh "$tmp"; rc=$?; else rc=$?; fi
    rm -f "$tmp"; return $rc
}
fi
if ! declare -f aeboot_preflight >/dev/null 2>&1; then
# aeboot_preflight : a C compiler + make must exist. Aether compiles to C and
# hands off to cc; the source-tarball installers (get.sh/install.sh) also need
# make + cc. Check up front so a missing compiler fails clearly HERE, not
# cryptically later inside `ae build` (a --emit=lib link error) or an installer.
aeboot_preflight() {
    command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 \
        || die "a C compiler (cc/gcc/clang) is required — Aether compiles to C. Install e.g. build-essential (Debian/Ubuntu) or the Xcode Command Line Tools (macOS)."
    command -v make >/dev/null 2>&1 \
        || die "GNU make is required to build the Aether toolchain from source. Install e.g. build-essential / make."
}
fi

# --- ae_ensure : the one function this file exists to provide ---------------
# Guarantees an `ae >= AE_PIN` is on PATH, fetching AE_FETCH/AETHER_REF if the
# floor is unmet. Idempotent: a no-op when a good ae is already present.
ae_ensure() {
    [ -n "${AE_PIN:-}" ] || die "aeboot: AE_PIN is unset — the caller must set the ae floor before ae_ensure."
    local prefix fetch
    prefix="${PREFIX:-$HOME/.local}"; export PREFIX="$prefix"
    fetch="${AE_FETCH:-$AE_PIN}"   # floor-only repos: fetch == pin
    export PATH="$prefix/bin:$PATH"   # a freshly-installed ae must be found below

    aeboot_preflight

    local have
    if command -v ae >/dev/null 2>&1 && have="$(ae_version || true)" && [ -n "$have" ] && version_ge "$have" "$AE_PIN"; then
        say "ae $have already on PATH (>= $AE_PIN) — skipping"
        return 0
    fi
    say "installing ae via get.sh (AETHER_REF=${AETHER_REF:-$fetch}, PREFIX=$prefix)"
    AETHER_REF="${AETHER_REF:-$fetch}" fetch_run "$AEBOOT_AETHER_GET_URL" || die "ae install failed (get.sh)."
    command -v ae >/dev/null 2>&1 || die "ae installed but not on PATH — ensure $prefix/bin is on PATH."
    say "ae $(ae_version) ready"
}
