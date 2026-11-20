#!/bin/sh
# breakout-harness.sh — adversarial confinement tests for the bhyve-Ubuntu
# guest. Each test gets a PRISTINE clone of the golden snapshot (so a breakout
# can't poison the next test), attempts to bust out of a confinement, asserts
# the attempt was DENIED, and destroys the clone.
#
# Iteration cost (measured): clone = ~8KB + 0s; destroy = instant full reclaim;
# disk is effectively free — the cost is boot time. See memory
# aeo-breakout-test-economics.
#
#   sudo env AEO_SSH_KEY=$AEO_SSH_KEY sh test/breakout-harness.sh       # all probes
#   sudo env AEO_SSH_KEY=$AEO_SSH_KEY sh test/breakout-harness.sh fd    # one (net|fd|vm)
#   sudo env N=20 AEO_SSH_KEY=$AEO_SSH_KEY sh test/breakout-harness.sh net
# (sudo resets the environment, so the key must be passed through env.)
#
# Run ON the GhostBSD host (needs vm clone/start/destroy + ssh into the guest),
# after `sh test/bhyve-lab.sh up` (aeo-base@golden). Each clone gets its own
# static address, 172.16.0.60 upward (patch-static-ip.sh before first boot), so
# it never collides with the running Linux guest at .50.
#
# CONFINEMENT READINESS (honest):
#   vm  — the bhyve VM boundary (guest cannot touch host). Always on. DENY now.
#   fd  — Capsicum on the clone's bhyve process: it must be in capability mode
#         (procstat -s FLAGS has C) with its disk descriptor narrowed. bhyve
#         confines itself; DENIED means the kernel holds it there.
#   net — pf egress/ingress whitelist. Not wired for bhyve guests, so egress
#         is RED until enforcement lands (TDD). On a host whose pf does not NAT
#         the guest subnet out of its uplink (ghostbsd 2026-11-20) egress fails
#         for that reason alone, so the probe SKIPs there.
set -u

GOLDEN="${GOLDEN:-aeo-base@golden}"
KEY="${KEY:-${AEO_SSH_KEY:-$HOME/.ssh/id_rsa}}"
T="$(cd "$(dirname "$0")" && pwd)"
seq_ip=60
N="${N:-1}"
CAT="${1:-all}"

pass=0; fail=0; xfail=0

# --- pristine clone lifecycle ------------------------------------------------

# Clone the golden into a uniquely-named VM with its own static address, boot
# it, print the address once it answers ssh (or "").
clone_boot() {
    name="$1"; ip="$2"
    vm destroy -f "$name" 2>/dev/null
    vm clone "$GOLDEN" "$name" >/dev/null 2>&1 || { echo ""; return; }
    sh "$T/patch-static-ip.sh" "$name" "$ip" >/dev/null 2>&1 || { echo ""; return; }
    vm start "$name" >/dev/null 2>&1
    i=0
    while [ $i -lt 40 ]; do
        i=$((i+1)); sleep 3
        nc -z -w2 "$ip" 22 >/dev/null 2>&1 && { echo "$ip"; return; }
    done
    echo ""
}

# Destroy is bulletproof: a running/locked clone needs poweroff first.
destroy() {
    vm stop "$1" >/dev/null 2>&1
    # -f: without it vm-bhyve asks "are you sure" on stdin and the harness hangs
    vm poweroff -f "$1" >/dev/null 2>&1 </dev/null
    sleep 1
    vm destroy -f "$1" >/dev/null 2>&1
}

gssh() { ip="$1"; shift; ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 "ubuntu@$ip" "$@" 2>/dev/null; }

# A probe result: it ran the attack and reports "DENIED" or "ESCAPED".
# verdict <label> <category> <DENIED|ESCAPED>  -- enforced=pass, escaped=xfail/fail
verdict() {
    label="$1"; cat="$2"; got="$3"
    if [ "$got" = "DENIED" ]; then
        echo "  PASS [$cat] $label — confinement held (DENIED)"; pass=$((pass+1))
    elif [ "$cat" = "net" ]; then
        echo "  XFAIL [$cat] $label — ESCAPED (pf enforcement for bhyve guests not wired yet)"; xfail=$((xfail+1))
    else
        echo "  FAIL [$cat] $label — ESCAPED (the VM boundary and bhyve's Capsicum should always hold!)"; fail=$((fail+1))
    fi
}

# --- the breakout probes -----------------------------------------------------
# Each runs INSIDE a fresh confined clone and tries to bust out.

probe_vm() {                       # guest must not reach the host filesystem
    ip="$1"
    # Try to read a host-only path through the guest. A VM can't see the host
    # FS; success here would mean the VM boundary failed.
    r=$(gssh "$ip" 'cat /host-secret 2>/dev/null || echo NOREACH')
    [ "$r" = "NOREACH" ] && verdict "guest cannot read host /host-secret" vm DENIED \
                         || verdict "guest cannot read host /host-secret" vm ESCAPED
    # Try to reach the host's ssh from inside the guest as a different escape.
    r=$(gssh "$ip" 'timeout 3 nc -z 172.16.0.1 22 2>/dev/null && echo OPEN || echo CLOSED')
    # (Reaching the gateway:22 is allowed for a normal guest; this is a
    #  placeholder for a host-service the guest shouldnt touch once pf lands.)
}

probe_fd() {                       # Capsicum: the clone's bhyve is confined
    name="$2"
    pid=$(pgrep -f "^bhyve: $name( |\$)" | head -1)
    if [ -z "$pid" ]; then
        verdict "bhyve for $name found" fd ESCAPED; return
    fi
    flags=$(procstat -s "$pid" | awk 'NR==2{print $10}')
    case "$flags" in
        *C*) verdict "bhyve $pid ($name) is in Capsicum capability mode" fd DENIED ;;
        *)   verdict "bhyve $pid ($name) is in Capsicum capability mode" fd ESCAPED ;;
    esac
    rights=$(procstat -C -f "$pid" | awk '$NF ~ /disk0\.img$/ {print $6; exit}')
    case ",$rights," in
        ,,|*,cr,*|*,fe,*|*,mmx,*) verdict "disk descriptor narrowed ($rights)" fd ESCAPED ;;
        *) verdict "disk descriptor narrowed ($rights)" fd DENIED ;;
    esac
}

probe_net() {                      # pf: workload-mode egress whitelist (deny rest)
    ip="$1"
    # The python_vm policy: egress only to db_vm:6379, nothing else out.
    # Attempt egress to a FORBIDDEN destination (a public host:443). Under the
    # pf whitelist this must be DENIED; with no pf wired it succeeds (ESCAPED).
    # A host whose pf does not NAT the guest subnet out of its uplink blocks
    # this egress for that reason alone, which proves nothing about aeo: skip.
    up=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    if ! pfctl -s nat 2>/dev/null | grep -E "^nat on $up " | grep -q '172.16.0.0/24'; then
        echo "  SKIP [net] the host does not NAT 172.16.0.0/24 out of its uplink ${up:-?}, so egress fails regardless of policy"
        return
    fi
    r=$(gssh "$ip" 'timeout 4 nc -z -w3 1.1.1.1 443 2>/dev/null && echo OUT || echo BLOCKED')
    [ "$r" = "BLOCKED" ] && verdict "egress to forbidden 1.1.1.1:443 blocked" net DENIED \
                         || verdict "egress to forbidden 1.1.1.1:443 blocked" net ESCAPED
}

run_one() {
    cat="$1"; n="$2"
    name="bust-${cat}-${n}"
    echo "=== clone+boot $name (pristine) ==="
    want="172.16.0.$seq_ip"; seq_ip=$((seq_ip + 1))
    ip=$(clone_boot "$name" "$want")
    if [ -z "$ip" ]; then
        echo "  FAIL [$cat] $name — clone never answered ssh at $want"; fail=$((fail+1))
        destroy "$name"; return
    fi
    case "$cat" in
        vm)  probe_vm  "$ip" ;;
        fd)  probe_fd  "$ip" "$name" ;;
        net) probe_net "$ip" ;;
    esac
    destroy "$name"
}

cats="vm fd net"
[ "$CAT" != "all" ] && cats="$CAT"

echo "=== breakout harness: cats=[$cats] x$N (pristine clone per test) ==="
for c in $cats; do
    i=0
    while [ $i -lt "$N" ]; do
        i=$((i+1))
        run_one "$c" "$i"
    done
done

echo "=== RESULT: $pass confinement-held, $xfail expected-escape (not-yet-enforced), $fail REAL-FAIL ==="
[ "$fail" -eq 0 ]   # exit 0 unless a VM-boundary escape happened (a real failure)
