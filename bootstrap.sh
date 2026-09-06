#!/usr/bin/env bash
# bootstrap.sh — one-command casual-dev bootstrap for the aeo repo.
#
# Ensures the Aether toolchain (`ae`) is present and recent enough, builds aeo's
# binary, and runs its spec suite. aeb is ALSO ensured — not because aeo builds
# WITH aeb (it builds via `ae build`; aeb is a runtime seam, see AEB_PIN) but so
# a box that will exercise that seam has aeb ready, and so this repo dogfoods
# aebboot.sh during its bring-up as the pioneer of the shared bootstrap helpers.
#
# THE SHARED LOGIC LIVES ELSEWHERE. Everything about *installing* a toolchain
# (floor checks, fetch, the C-compiler preflight, the shared say/die helpers) is
# in aeboot.sh (ae) and aebboot.sh (aeb), curled below. This file carries only
# what is genuinely aeo-specific: its pins and its build/verify commands. That
# split is the whole point — see aeboot.sh's header for why the installer logic
# is curled rather than copy-pasted into every repo's bootstrap.sh.
#
# Env overrides (consumed by the sourced helpers):
#   PREFIX      install prefix                 (default: $HOME/.local; no sudo)
#   AETHER_REF  ae tag/branch/SHA to install   (default: AE_FETCH below)
#   AEB_REF     aeb tag/branch/SHA to install  (default: install.sh latest)
#   MIN_AE      override the ae floor          (default: AETHER_PIN)
#   AEBOOT_URL / AEBBOOT_URL  override where the helpers are curled from
#               (default: this repo's raw URL on main). Point these at the
#               relocated aether/aeb repos after Phase 4, or at a branch to
#               test an unmerged helper change.
# Extra args are ignored (aeo has no aeb DAG to target).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# --- aeo's pins: read from the machine-readable pin files (not hardcoded) ----
# This exercises AETHER_PIN / AEB_PIN as the single source of truth AND keeps
# bootstrap.sh honest when those files move forward.
readpin() { grep -v '^#' "$1" 2>/dev/null | tr -d '[:space:]'; }
AE_PIN="$(readpin "$HERE/AETHER_PIN")"; AE_PIN="${AE_PIN:-0.645.0}"
AEB_MIN="$(readpin "$HERE/AEB_PIN")";  AEB_MIN="${AEB_MIN:-0.297.0}"
# aeo assumes an `ae` on PATH and floors it; there is no separate known-good
# "fetch" number (AETHER_PIN is floor-only, see its rationale), so fetch == pin
# unless the caller overrides AETHER_REF.
AE_FETCH="${AE_FETCH:-v$AE_PIN}"
MIN_AE="${MIN_AE:-$AE_PIN}"; AE_PIN="$MIN_AE"
export AE_PIN AE_FETCH AEB_MIN

# --- source the shared installer helpers (curled from raw, prod-shape) -------
# During bring-up these live at this repo's root; after Phase 4 they relocate to
# the aether / aeb repos and only these two URLs change.
AEBOOT_URL="${AEBOOT_URL:-https://raw.githubusercontent.com/aether-lang-dev/aeo/main/aeboot.sh}"
AEBBOOT_URL="${AEBBOOT_URL:-https://raw.githubusercontent.com/aether-lang-dev/aeo/main/aebboot.sh}"

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

_source_url "$AEBOOT_URL"
_source_url "$AEBBOOT_URL"

# --- do the work -------------------------------------------------------------
ae_ensure          # from aeboot.sh:  ae >= AE_PIN on PATH (fetch if needed)
aeb_ensure         # from aebboot.sh: aeb on PATH (warn if < AEB_MIN)

case ":$PATH:" in *":${PREFIX:-$HOME/.local}/bin:"*) : ;;
    *) say "tip: add '${PREFIX:-$HOME/.local}/bin' to your shell PATH permanently";; esac

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
