#!/usr/bin/env bash
# aebboot.sh — install/ensure the aeb build runner (`aeb`). SOURCE this after
# aeboot.sh (which provides the shared primitives AND guarantees `ae` exists,
# since aeb's installer needs an `ae` to point at):
#
#     . <(curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeo/main/aeboot.sh)
#     . <(curl -fsSL https://raw.githubusercontent.com/aether-lang-dev/aeo/main/aebboot.sh)
#     ae_ensure          # from aeboot.sh — ae first
#     aeb_ensure         # then aeb
#
# This is the aeb half of the shared bootstrap. It is separate from aeboot.sh
# on purpose: the two tools version independently and, once stable, this file
# MOVES to the root of the `aeb` repo (beside install.sh) while aeboot.sh moves
# to the `aether` repo (beside get.sh) — each helper ending up next to the tool
# it installs. During bring-up both are pioneered in `aeo`. See the plan.
#
# ---------------------------------------------------------------------------
# AEBBOOT_REV: 3
# ^ PROPAGATION SNIFF MARKER — same scheme as aeboot.sh. Bumped by hand on
# every change; poll the raw URL for `AEBBOOT_REV: <n>` to know when
# raw.githubusercontent has redeployed your push. (Distinct name from
# aeboot.sh's AEBOOT_REV so the two files' markers can't be confused.)
# ---------------------------------------------------------------------------

# --- Contract (what the CALLER sets before calling aeb_ensure) --------------
#   AEB_MIN   FLOOR: oldest aeb this repo's build files need. Optional but
#             recommended — an aeb below it fails loudly on `import bldr` /
#             the b-free Shape A grammar rather than silently. If set AND an
#             aeb is already present, aeb_ensure only WARNS on a too-old aeb
#             (it does not force a reinstall — an aeb already on PATH is the
#             user's, and aeb has no cheap in-place upgrade).
#   AEB_REF   (env) explicit aeb tag/branch/SHA to install. The CI pin knob.
#             Default: install.sh's own default (latest tag).
#   PREFIX    (env) install prefix. Default $HOME/.local. (Shared with aeboot.)
#
# REQUIRES aeboot.sh to have been sourced (for say/die/version_ge/fetch_run and
# for ae_ensure having put an `ae` on PATH). Guarded fallbacks below let this
# file be sourced standalone in a pinch, but the intended order is ae first.

AEBBOOT_AEB_INSTALL_URL="${AEBBOOT_AEB_INSTALL_URL:-https://raw.githubusercontent.com/aether-lang-dev/aeb/main/install.sh}"

# --- Defensive fallbacks (no-ops if aeboot.sh already defined these) --------
if ! declare -f say >/dev/null 2>&1; then
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fi
if ! declare -f die >/dev/null 2>&1; then
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
fi
if ! declare -f version_ge >/dev/null 2>&1; then
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
fi
if ! declare -f fetch_run >/dev/null 2>&1; then
fetch_run() {
    command -v curl >/dev/null 2>&1 || die "curl is required to install aeb (or install it yourself and re-run)."
    local tmp rc; tmp="$(mktemp)"
    if curl -fsSL "$1" -o "$tmp"; then sh "$tmp"; rc=$?; else rc=$?; fi
    rm -f "$tmp"; return $rc
}
fi

# aeb_version : print aeb's version NORMALIZED to X.Y.Z, or nothing. aeb prints
# "aeb v0.297  (git ..., installed ...)" — a TWO-component tag (no patch). We
# normalize a bare X.Y to X.Y.0 so it compares cleanly against a three-component
# AEB_MIN like 0.297.0. Without this, `sort -V` orders 0.297 BEFORE 0.297.0 and
# a correctly-pinned aeb reports as "too old" — a spurious upgrade nag. (Caught
# by dogfooding this in aeo, where AEB_PIN is 0.297.0 and aeb is tagged v0.297.)
aeb_version() {
    local v
    v="$(aeb --version 2>/dev/null | head -n1 | sed -E 's/^aeb v?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
    [ -n "$v" ] || return 0
    case "$v" in *.*.*) : ;; *.*) v="$v.0" ;; esac
    printf '%s' "$v"
}

# --- aeb_ensure : guarantee `aeb` is on PATH -------------------------------
aeb_ensure() {
    local prefix
    prefix="${PREFIX:-$HOME/.local}"; export PREFIX="$prefix"
    export PATH="$prefix/bin:$PATH"

    if command -v aeb >/dev/null 2>&1; then
        local have; have="$(aeb_version || true)"
        # A source-built aeb reports "aeb 0.0.0-dev+<sha>" (no release tag), which
        # aeb_version renders as 0.0.0. That is NOT an old release — it is an
        # untagged build straight from HEAD, and it is almost certainly NEWER than
        # any AEB_MIN. Warning "your aeb is older than 0.297.0" about a
        # just-compiled-from-main aeb is nonsense (and would fire on the very aeb
        # this helper just fetched via install.sh from source). Treat 0.0.0 as
        # "unversioned — trust it" and skip the floor check. (Caught on a bare-box
        # fetch, where install.sh builds aeb from source -> 0.0.0-dev.)
        if [ "$have" = "0.0.0" ]; then
            say "aeb (source build, unversioned) already on PATH — skipping floor check"
        elif [ -n "${AEB_MIN:-}" ] && [ -n "$have" ] && ! version_ge "$have" "$AEB_MIN"; then
            say "WARNING: aeb $have is older than this repo's floor $AEB_MIN."
            say "  Its build files use the b-free Shape A grammar (bldr.build{}) that"
            say "  needs aeb >= $AEB_MIN; an older aeb fails on 'import bldr'. To upgrade:"
            say "    AEB_REF=v$AEB_MIN $0     # or install a newer aeb yourself"
        else
            say "aeb ${have:-(version unknown)} already on PATH — skipping"
        fi
        say "using aeb: $(command -v aeb)"
        return 0
    fi

    command -v ae >/dev/null 2>&1 || die "aeb_ensure: no \`ae\` on PATH — source aeboot.sh and call ae_ensure first (aeb's installer needs an ae to target)."
    say "installing aeb via install.sh (AEB_REF=${AEB_REF:-latest}, PREFIX=$prefix)"
    AEB_REF="${AEB_REF:-}" AETHER="$(command -v ae)" fetch_run "$AEBBOOT_AEB_INSTALL_URL" || die "aeb install failed (install.sh)."
    command -v aeb >/dev/null 2>&1 || die "aeb installed but not on PATH — ensure $prefix/bin is on PATH."
    say "using aeb: $(command -v aeb) ($(aeb_version || echo version-unknown))"
}
