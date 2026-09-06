#!/usr/bin/env bash
# bootstrap.sh — one-command casual-dev bootstrap for the aeo repo.
#
# Ensures the Aether toolchain (`ae`) and the aeb build runner are present and
# recent enough, builds aeo's binary, and runs its spec suite. (aeo builds via
# `ae build`, not aeb — aeb is a runtime seam, see AEB_PIN — but a box that will
# exercise that seam wants aeb ready, and this repo pioneers the shared helper.)
#
# THE SHARED LOGIC LIVES ELSEWHERE. Everything about *installing* the toolchain
# (binary-first download + checksum, source fallback, floor checks, the shared
# say/die helpers) is in ONE file, aebboot.sh, curled below. This file carries
# only what is genuinely aeo-specific: its pins and its build/verify commands.
# That is the whole point — see aebboot.sh's header for why the install logic is
# curled once rather than copy-pasted into every repo's bootstrap.sh.
#
# Env overrides (consumed by the sourced helper):
#   PREFIX      install prefix                 (default: $HOME/.local; no sudo)
#   AETHER_REF  ae tag/branch/SHA to install   (default: the ae floor)
#   AEB_REF     aeb tag/branch/SHA to install  (default: latest)
#   MIN_AE      override the ae floor          (default: AETHER_PIN)
#   AEBBOOT_NO_BINARY=1  force source builds (skip gh-release binaries)
#   AEBBOOT_URL override where the helper is curled from (default: this repo's
#               raw URL on main). Point it at the relocated aeb repo after
#               Phase 4, or at a branch to test an unmerged helper change.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# --- aeo's pins: read from the machine-readable pin files (not hardcoded) ----
# Exercises AETHER_PIN / AEB_PIN as the single source of truth AND stays honest
# when those files move forward.
readpin() { grep -v '^#' "$1" 2>/dev/null | tr -d '[:space:]'; }
# The floor: MIN_AE env override wins over the pin file wins over a hard default.
# (Order matters — AE_FETCH is derived from the FINAL floor, so a MIN_AE that
# raises the floor also raises what we fetch, not just what we check.)
AE_PIN="${MIN_AE:-$(readpin "$HERE/AETHER_PIN")}"; AE_PIN="${AE_PIN:-0.645.0}"
AEB_MIN="$(readpin "$HERE/AEB_PIN")";              AEB_MIN="${AEB_MIN:-0.297.0}"
# aeo floors ae; there is no separate known-good "fetch" number (AETHER_PIN is
# floor-only), so fetch == the floor unless AETHER_REF overrides. The helper
# handles v-prefixing and binary-vs-source selection.
AE_FETCH="${AE_FETCH:-$AE_PIN}"
export AE_PIN AE_FETCH AEB_MIN

# --- source the shared installer helper (curled from raw, prod-shape) --------
# The helper is aebboot.sh, whose canonical home is the aeb repo root (it was
# pioneered here in aeo, then relocated). Override AEBBOOT_URL to point at a
# branch to test an unmerged helper change.
AEBBOOT_URL="${AEBBOOT_URL:-https://raw.githubusercontent.com/aether-lang-dev/aeb/main/aebboot.sh}"

_source_url() {   # source a script from a URL (or a file:// / local path)
    local url="$1" tmp rc
    case "$url" in
        file://*) . "${url#file://}"; return $? ;;
        /*|./*)   . "$url"; return $? ;;
    esac
    command -v curl >/dev/null 2>&1 || { printf 'error: curl is required to fetch %s\n' "$url" >&2; exit 1; }
    tmp="$(mktemp)"
    if curl -fsSL "$url" -o "$tmp"; then . "$tmp"; rc=$?; else
        rc=$?; printf 'error: could not fetch %s (curl exit %s)\n' "$url" "$rc" >&2; rm -f "$tmp"; exit 1
    fi
    rm -f "$tmp"; return $rc
}

_source_url "$AEBBOOT_URL"

# --- do the work -------------------------------------------------------------
aeb_bootstrap      # from aebboot.sh: ensure ae (>= AE_PIN) THEN aeb, binary-first

say "building aeo (ae build bin/aeo.ae)"
ae build "$HERE/bin/aeo.ae" -o /tmp/aeo-bootstrap-check --lib "$HERE/lib" \
    || die "aeo build failed — see the ae errors above."
say "aeo builds clean."

say "running the spec suite (sh test/run-spec.sh)"
if sh "$HERE/test/run-spec.sh"; then
    say "done — aeo builds and the suite is green."
else
    die "the spec suite reported failures above."
fi
