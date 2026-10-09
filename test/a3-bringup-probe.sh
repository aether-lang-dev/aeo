#!/bin/sh
# a3-bringup-probe.sh — LIVE acceptance for A3 (netpolicy before reachability) on a
# FreeBSD host. A rule-generation spec cannot show a TIME window; this drives a
# real jail through a real `aeo up` and watches its reachability the whole way.
#
#   sh test/a3-bringup-probe.sh window    # bring-up probe: any unfiltered reach?
#   sh test/a3-bringup-probe.sh strict    # forced pf failure: strict tears down,
#                                         #   non-strict boots + warns + applied=no
#   sh test/a3-bringup-probe.sh all       # both (default)
#
#   AEO_TREE=/path/to/aeo   the aeo tree whose lib/ + runner to build (default:
#                           this checkout). Point it at an OLD checkout to see the
#                           window the old code had (2a0140d: it shows; A3: it doesn't).
#   A3_PF_TEMP=1            pf not loaded/enabled here? Load a TEMPORARY pf
#                           (`pass all` + `anchor "aeo/*"`), and restore the prior
#                           state on exit (disable; unload pf.ko if we loaded it).
#                           Without it the probe requires pf already enabled with
#                           `anchor "aeo/*"` in the main ruleset.
#   A3_ALLOW_PF_DISABLE=1   the strict case forces a pf-load failure by DISABLING pf
#                           for a moment (pfctl -d). Done automatically when A3_PF_TEMP
#                           loaded pf (it is ours); on a host whose pf is the
#                           operator's, the strict case is SKIPPED unless this is set.
#   A3_READY_DELAY=2        seconds the workload takes to report healthy after its
#                           sockets are open (the old window spans this).
#
# Needs: FreeBSD, `sudo -n` (jail/jexec/jls/zfs/pfctl/ifconfig), `ae` on PATH, a
# ZFS pool with zroot/jails. Everything it creates is aeo-test-named and removed on
# exit: loopback clone `aeoa3lo0` (10.77.3.1 host side, 10.77.3.10 the jail), ZFS
# dataset zroot/jails/aeo_a3_probe (a /rescue root — no download), jail
# aeo_a3_probe, pf anchor aeo/aeo_a3_probe. Existing jails/rules/interfaces are not
# touched (the temp pf.conf is only loaded when pf was NOT running).
#
# THE PROBE (window): before `aeo up` starts, a host-side loop connects to the
# jail's workload port (10.77.3.10:7777) every ~50 ms; the jail's workload itself
# (started by jail -c's exec.start — the earliest instant it can run) opens its
# listener and loops connecting OUT to a host listener (10.77.3.1:7778), logging
# each attempt. The composition's netpolicy is deny-default (deny_egress, no
# ingress whitelist), so EVERY successful connection — either direction, at any
# time from creation through ready — is unfiltered reach. PASS = zero successes
# with the probes demonstrably running while the jail existed. The old ordering
# (anchor loaded after promotion to UP) shows successes between the workload's
# START and the "policy loaded" line; after the anchor, none (the anchor bites).
#
# ipam is steered (AEO_IP_RANGE_*) so even the OLD code's anchor resolves the jail
# to 10.77.3.10 — the before/after difference is then the ORDERING alone, not the
# jail-ip pin A3 also fixed (spec_pf_enforce covers that).
set -u

MODE="${1:-all}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TREE="${AEO_TREE:-$HERE}"
NAME=aeo_a3_probe
DS=zroot/jails/$NAME
ROOT=/zroot/jails/$NAME
IF=aeoa3lo0
HOSTIP=10.77.3.1
JIP=10.77.3.10
W="${TMPDIR:-/tmp}/aeo-a3-probe-$$"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ts() { date +%s.%N; }

[ "$(uname -s)" = FreeBSD ] || { echo "SKIP: a3-bringup-probe needs FreeBSD (pf + jails)"; exit 0; }
sudo -n true 2>/dev/null || { echo "a3-bringup-probe: needs passwordless sudo"; exit 2; }
command -v ae >/dev/null 2>&1 || { echo "a3-bringup-probe: needs ae on PATH"; exit 2; }
mkdir -p "$W"

# ---- pf: require ready, or bring up a temporary one (A3_PF_TEMP=1) ----------
PF_LOADED_BY_US=0; PF_ENABLED_BY_US=0
ANCHOR_DIR_EXISTED=0; [ -d /etc/pf.anchors ] && ANCHOR_DIR_EXISTED=1   # aeo mkdirs it
pf_ready() {
    sudo -n pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' &&
    sudo -n pfctl -s rules 2>/dev/null | grep -q 'anchor "aeo/\*"'
}
if ! pf_ready; then
    if [ "${A3_PF_TEMP:-0}" != 1 ]; then
        echo "a3-bringup-probe: pf is not enabled with anchor \"aeo/*\" — set A3_PF_TEMP=1 for a temporary pf, or see docs/operations/bsd-host-setup.md"
        exit 2
    fi
    if sudo -n pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
        echo "a3-bringup-probe: pf is ENABLED with an operator ruleset lacking anchor \"aeo/*\" — refusing to replace it"; exit 2
    fi
    if ! kldstat -q -m pf; then sudo -n kldload pf && PF_LOADED_BY_US=1; fi
    printf 'pass all\nanchor "aeo/*"\n' > "$W/pf-temp.conf"
    sudo -n pfctl -q -f "$W/pf-temp.conf" && sudo -n pfctl -q -e && PF_ENABLED_BY_US=1
    pf_ready || { echo "a3-bringup-probe: temporary pf did not come up"; exit 2; }
    echo "(temporary pf loaded: pass all + anchor \"aeo/*\")"
fi

cleanup() {
    touch "$W/stop" 2>/dev/null
    [ -d "$ROOT/tmp" ] && sudo -n touch "$ROOT/tmp/a3-stop" 2>/dev/null
    sleep 1
    sudo -n jail -r "$NAME" >/dev/null 2>&1
    sudo -n pfctl -a "aeo/$NAME" -F all >/dev/null 2>&1
    sudo -n rm -f "/etc/pf.anchors/aeo-$NAME"
    [ "$ANCHOR_DIR_EXISTED" = 0 ] && sudo -n rmdir /etc/pf.anchors 2>/dev/null
    [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null
    mount -p | awk -v d="$ROOT/dev" '$2==d{f=1}END{exit !f}' && sudo -n umount "$ROOT/dev"
    sudo -n zfs destroy -r "$DS" >/dev/null 2>&1
    ifconfig "$IF" >/dev/null 2>&1 && sudo -n ifconfig "$IF" destroy
    if [ "$PF_ENABLED_BY_US" = 1 ]; then
        sudo -n pfctl -q -F all >/dev/null 2>&1; sudo -n pfctl -q -d >/dev/null 2>&1
    fi
    [ "$PF_LOADED_BY_US" = 1 ] && sudo -n kldunload pf
    rm -rf "$W"
}
trap cleanup EXIT INT TERM

# ---- fixtures: addresses, jail root, workload, host listener ---------------
if ! ifconfig "$IF" >/dev/null 2>&1; then
    c=$(sudo -n ifconfig lo create) && sudo -n ifconfig "$c" name "$IF" >/dev/null
fi
sudo -n ifconfig "$IF" inet "$HOSTIP/32" up
sudo -n ifconfig "$IF" inet "$JIP/32" alias
zfs list "$DS" >/dev/null 2>&1 || sudo -n zfs create -p "$DS"
sudo -n zfs set mountpoint="$ROOT" "$DS"; sudo -n zfs mount "$DS" 2>/dev/null
sudo -n mkdir -p "$ROOT/rescue" "$ROOT/dev" "$ROOT/tmp" "$ROOT/bin" "$ROOT/etc"
[ -x "$ROOT/rescue/sh" ] || sudo -n cp -a /rescue/. "$ROOT/rescue/"
sudo -n ln -sf /rescue/sh "$ROOT/bin/sh"
# devfs (jail ruleset 4): sh opens /dev/null for a backgrounded exec.start even
# when the command redirects — the operator-provision step a real jail root has.
if ! mount -p | awk -v d="$ROOT/dev" '$2==d{f=1}END{exit !f}'; then
    sudo -n mount -t devfs devfs "$ROOT/dev" && sudo -n devfs -m "$ROOT/dev" rule -s 4 applyset
fi
# The workload: listener + an egress loop that logs every attempt (inside the jail's
# own /tmp, read from the host). It starts at jail -c's exec.start.
sudo -n tee "$ROOT/a3-workload.sh" >/dev/null <<'WL'
#!/bin/sh
PATH=/rescue
echo "$(date +%s.%N) START" >> /tmp/a3-egress.log
nc -lk 10.77.3.10 7777 >/tmp/a3-listener.out 2>&1 </a3-workload.sh &
( sleep "$(cat /a3-ready-delay)"; : > /tmp/a3-workload-started ) &   # (no touch(1) in /rescue)
while [ ! -f /tmp/a3-stop ]; do
    t=$(date +%s.%N)
    if nc -z -w1 10.77.3.1 7778 >/tmp/a3-nc.out 2>&1; then echo "$t OK" >> /tmp/a3-egress.log
    else echo "$t FAIL" >> /tmp/a3-egress.log; fi
    sleep 0.05
done
WL
# How long the workload takes to report ready AFTER its sockets are open (a real
# service warming up). The old ordering's window spans exactly this; default 2 s.
echo "${A3_READY_DELAY:-2}" | sudo -n tee "$ROOT/a3-ready-delay" >/dev/null
nc -lk "$HOSTIP" 7778 >/dev/null 2>&1 </dev/null &
LPID=$!

# ---- build the runner for a composition (as the front-door does) -----------
build_runner() {   # $1 label, $2 strict-line ("" or "strict()")
    b="$W/build-$1"; mkdir -p "$b/lib/aeo_compose"
    cp -r "$TREE/lib/." "$b/lib/"
    cat > "$b/lib/aeo_compose/module.ae" <<EOF
import compose (system, jail, dataset, ip, command, health, constrain, deny_egress, strict)
exports ( aeo_orchestration )
aeo_orchestration() {
    system("a3probe") {
        $2
        j = jail("$NAME") {
            dataset("$DS")
            ip("$JIP")
            command("/bin/sh /a3-workload.sh >/tmp/a3-workload.out 2>&1 </a3-workload.sh &")
            health("test -f /tmp/a3-workload-started")
            constrain("$NAME") { deny_egress() }
        }
    }
}
EOF
    cp "$TREE/lib/aeo/runner.ae" "$b/run.ae"
    ( cd "$b" && ae build run.ae -o aeo-run --lib lib ) >"$b/build.log" 2>&1 || { echo "BUILD FAILED ($1):" >&2; tail -30 "$b/build.log" >&2; return 1; }
    echo "$b/aeo-run"
}
aeo_env() {
    env AEO_HOME="$TREE" AEO_NO_SUPERVISOR=1 AEO_JAIL_AUTOBASE=0 \
        AEO_IP_RANGE_BASE=10.77.3. AEO_IP_RANGE_LO=10 AEO_IP_RANGE_HI=10 "$@"
}
run_cmd() {   # $1 runner, $2 cmd, $3 log — timestamps every output line
    ( cd "$W" && aeo_env AEO_CMD="$2" "$1" 2>&1 ) | while IFS= read -r l; do echo "$(ts) $l"; done >> "$3"
}
reset_jail_logs() {
    sudo -n rm -f "$ROOT/tmp/a3-egress.log" "$ROOT/tmp/a3-workload-started" "$ROOT/tmp/a3-stop"
    rm -f "$W/stop" "$W/ingress.log"
}

# ---- case: the bring-up window ----------------------------------------------
probe_window() {
    echo "### window: deny-default jail, probed from before creation through ready"
    R=$(build_runner win "") || { fail "window build"; return; }
    reset_jail_logs
    : > "$W/ingress.log"
    ( while [ ! -f "$W/stop" ]; do t=$(ts)
        if nc -z -w1 "$JIP" 7777 >/dev/null 2>&1; then echo "$t OK"; else echo "$t FAIL"; fi
        sleep 0.05; done >> "$W/ingress.log" ) &
    # An INDEPENDENT observer of when the anchor holds rules (aeo's own output is
    # block-buffered through the pipe, so its line timestamps are flush times).
    : > "$W/anchor.log"
    ( last=-1; while [ ! -f "$W/stop" ]; do t=$(ts)
        c=$(sudo -n pfctl -a "aeo/$NAME" -s rules 2>/dev/null | grep -c .)
        [ "$c" != "$last" ] && echo "$t $c" && last=$c
        sleep 0.02; done >> "$W/anchor.log" ) &
    sleep 1                                        # the probers are running BEFORE up
    echo "$(ts) PROBE aeo up begins" > "$W/up.log"
    run_cmd "$R" up "$W/up.log"
    run_cmd "$R" status "$W/status.log"            # A1 posture, read live from pf
    sleep 3                                        # keep probing a while after ready
    touch "$W/stop"; sudo -n touch "$ROOT/tmp/a3-stop"; sleep 2
    run_cmd "$R" down "$W/up.log"
    sudo -n cat "$ROOT/tmp/a3-egress.log" > "$W/egress.log" 2>/dev/null
    echo "--- aeo up/down (timestamped) ---"; grep -v 'warning\|^ *$' "$W/up.log" | grep 'aeo\|PROBE' | sed 's/^/  /'
    T_ANCHOR=$(awk '$2>0{print $1; exit}' "$W/anchor.log")
    T_START=$(grep -m1 START "$W/egress.log" | cut -d' ' -f1)
    T_UP=$(grep -m1 '\] up$' "$W/up.log" | cut -d' ' -f1)
    echo "  workload START (jail exec.start) : ${T_START:-never}"
    echo "  pf anchor first holds rules      : ${T_ANCHOR:-never}   (observed: pfctl -a aeo/$NAME -s rules, polled 20 ms)"
    echo "  node promoted UP                 : ${T_UP:-never}"
    awk -v a="${T_ANCHOR:-0}" -v s="${T_START:-0}" '
        FNR==1 { f++ }
        $2=="OK"   { if (a==0 || $1 < a) pre[f]++; else post[f]++ }
        $2=="OK" || $2=="FAIL" { n[f]++; if (s>0 && $1>=s) live[f]++ }
        END {
            printf "  ingress (host -> jail:7777): %d attempts, %d while the workload ran, %d OK before anchor, %d OK after\n", n[1], live[1], pre[1], post[1]
            printf "  egress  (jail -> host:7778): %d attempts, %d OK before anchor, %d OK after\n", n[2], pre[2], post[2]
        }' "$W/ingress.log" "$W/egress.log" | tee "$W/summary"
    grep 'netpolicy ' "$W/status.log" | sed 's/^[0-9.]* /  status:/'
    grep -q 'netpolicy .*applied=pf anchor aeo/[a-z_0-9]* ([1-9][0-9]* rules loaded, pf enabled)' "$W/status.log" \
        && pass "status: netpolicy applied reads the live anchor (rules loaded, pf enabled)" \
        || fail "status: netpolicy applied does not reflect the loaded anchor"
    ok_in=$(grep -c ' OK$' "$W/ingress.log"); ok_eg=$(grep -c ' OK$' "$W/egress.log")
    att_eg=$(grep -cE ' (OK|FAIL)$' "$W/egress.log")
    live_in=$(awk -v s="${T_START:-0}" 's>0 && $1>=s' "$W/ingress.log" | wc -l | tr -d ' ')
    if [ -z "$T_START" ] || [ "$att_eg" -lt 1 ] || [ "$live_in" -lt 1 ]; then
        fail "the probe never observed the running workload (START=${T_START:-none}, egress attempts=$att_eg, ingress during workload=$live_in) — inconclusive"
    elif [ "$ok_in" -eq 0 ] && [ "$ok_eg" -eq 0 ]; then
        pass "NO unfiltered window: 0 connections in either direction from creation through ready ($att_eg egress + $live_in ingress attempts while the workload ran)"
        if [ -n "$T_ANCHOR" ] && awk -v a="$T_ANCHOR" -v s="$T_START" 'BEGIN{exit !(a < s)}'; then
            pass "anchor observed loaded BEFORE the workload started ($T_ANCHOR < $T_START)"
        else
            fail "anchor not observed loaded before the workload started (anchor=${T_ANCHOR:-never}, start=$T_START)"
        fi
    else
        fail "UNFILTERED WINDOW: $ok_in ingress + $ok_eg egress connections succeeded on a deny-default node"
        grep ' OK$' "$W/ingress.log" | head -3 | sed 's/^/    ingress /'
        grep ' OK$' "$W/egress.log" | head -3 | sed 's/^/    egress  /'
    fi
}

# ---- case: forced pf-load failure, strict vs non-strict ---------------------
probe_strict() {
    echo "### strict: forced pf-load failure (pf disabled for the bring-up)"
    if [ "$PF_ENABLED_BY_US" != 1 ] && [ "${A3_ALLOW_PF_DISABLE:-0}" != 1 ]; then
        echo "SKIP: forcing the failure means disabling pf, which is the operator's here (set A3_ALLOW_PF_DISABLE=1)"; return
    fi
    RS=$(build_runner strict "strict()") || { fail "strict build"; return; }
    RL=$(build_runner loose "") || { fail "loose build"; return; }

    # (a) strict, node not yet running: refused, never left up.
    reset_jail_logs; : > "$W/s.log"
    sudo -n pfctl -q -d
    run_cmd "$RS" up "$W/s.log"
    sudo -n pfctl -q -e
    sed 's/^/  /' "$W/s.log" | grep 'aeo' | grep -v warning
    grep -q "STRICT REFUSED .*netpolicy could not be enforced" "$W/s.log" \
        && pass "strict: pf-load failure refuses the node, naming netpolicy" \
        || fail "strict: no netpolicy refusal"
    jls -j "$NAME" >/dev/null 2>&1 && fail "strict: jail is UP after a refused bring-up" \
        || pass "strict: jail is not running after the refused bring-up"

    # (b) strict, node ALREADY running (an idempotent re-up): torn down.
    reset_jail_logs; : > "$W/s2.log"
    run_cmd "$RL" up "$W/s2.log"
    jls -j "$NAME" >/dev/null 2>&1 && pass "strict re-up precondition: jail running (filtered) from a good non-strict up" \
        || fail "strict re-up precondition: the non-strict up did not leave the jail running"
    sudo -n pfctl -q -d
    run_cmd "$RS" up "$W/s2.log"
    sudo -n pfctl -q -e
    grep 'STRICT REFUSED\|tearing down\|torn down' "$W/s2.log" | sed 's/^/  /'
    jls -j "$NAME" >/dev/null 2>&1 && fail "strict re-up: a running node was LEFT UP unfiltered" \
        || pass "strict re-up: the already-running node was torn down"
    run_cmd "$RL" down "$W/s2.log"

    # (c) negative control: the SAME failure without strict() boots, warns, applied=no.
    reset_jail_logs; : > "$W/l.log"
    sudo -n pfctl -q -d
    run_cmd "$RL" up "$W/l.log"
    run_cmd "$RL" status "$W/l.log"
    sudo -n pfctl -q -e
    grep 'NOT enforced\|netpolicy ' "$W/l.log" | sed 's/^/  /'
    jls -j "$NAME" >/dev/null 2>&1 && pass "non-strict: node boots despite the failure (default ergonomics kept)" \
        || fail "non-strict: node did not boot"
    grep -q 'WARNING pf policy NOT enforced' "$W/l.log" && pass "non-strict: loud WARNING line" || fail "non-strict: no WARNING"
    grep -q 'netpolicy .*applied=no' "$W/l.log" && pass "non-strict: status reports netpolicy applied=no" || fail "non-strict: status does not say applied=no"
    run_cmd "$RL" down "$W/l.log"
}

case "$MODE" in
    window) probe_window ;;
    strict) probe_strict ;;
    all) probe_window; probe_strict ;;
    *) echo "usage: $0 [window|strict|all]"; exit 2 ;;
esac
if [ "$fails" -ne 0 ]; then echo; echo "a3-bringup-probe: $fails FAILED"; exit 1; fi
echo; echo "a3-bringup-probe: all assertions passed"
