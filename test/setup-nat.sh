#!/bin/sh
# setup-nat.sh — the bhyve guest network: a private NAT switch (aeonat,
# 172.16.0.0/24, host = 172.16.0.1) plus the vm-bhyve templates that put guests
# on it. SAFE on a host with its own firewall: it never writes /etc/pf.conf,
# never reloads pf and never touches a physical interface. pf's NAT rule is
# CHECKED, and when it is missing the exact line to add is printed for the
# operator to add by hand.
#
#   sh test/setup-nat.sh            # create what is missing, then report
#   sh test/setup-nat.sh --check    # report only, change nothing
#
# Runs as a normal user; privileged steps use `sudo -n`.
#
# What it may change (each only when missing): the vm-bhyve switch `aeonat`
# with address 172.16.0.1/24 (a bridge with NO physical member); the templates
# linux-nat.conf and freebsd-nat.conf in the datastore; net.inet.ip.forwarding=1
# and gateway_enable=YES.
#
# History: the first version (2026-06) wrote a three-line /etc/pf.conf naming
# the AMD box's re0, restarted pf and installed dnsmasq. On a host with any
# other ruleset that would have dropped its rules (and its ssh rail), so it is
# gone. dnsmasq is gone too: guests take static addresses (vm-bhyve's
# `vm create -n ip=...` for a fresh guest, test/patch-static-ip.sh for a
# clone), because DHCP broadcasts on the bridge never reached dnsmasq.
set -eu

SW="aeonat"
NET="172.16.0.0/24"
GW="172.16.0.1"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

VMDIR=$(sysrc -n vm_dir 2>/dev/null | sed 's/^zfs://')
case "$VMDIR" in
    /*) DS="$VMDIR" ;;
    "") DS="" ;;
    *)  DS=$(zfs get -H -o value mountpoint "$VMDIR" 2>/dev/null || echo "/$VMDIR") ;;
esac

# The uplink is whatever carries the default route (re0, em0, ue0, ...), never a
# name baked into this script.
UPLINK=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')

ok() { echo "  ok    $1"; }
todo() { echo "  TODO  $1"; }
did() { echo "  done  $1"; }
problems=0

echo "=== bhyve NAT network (switch $SW, $NET via $GW; uplink ${UPLINK:-unknown})"

# 1. The switch: a vm-bhyve bridge with the gateway address and no physical port.
if sudo -n vm switch list 2>/dev/null | awk '{print $1}' | grep -qx "$SW"; then
    ok "switch $SW exists"
elif [ "$CHECK" = 1 ]; then
    todo "switch $SW missing"; problems=1
else
    sudo -n vm switch create "$SW"
    sudo -n vm switch address "$SW" "$GW/24"
    did "created switch $SW with $GW/24"
fi
ports=$(sudo -n vm switch info "$SW" 2>/dev/null | awk '/physical-ports:/{print $2}')
if [ -n "$ports" ] && [ "$ports" != "-" ]; then
    echo "  WARN  switch $SW has physical port(s) '$ports': guests are bridged onto a real network"
    problems=1
fi
if ifconfig "vm-$SW" 2>/dev/null | grep -q "inet $GW "; then
    ok "vm-$SW carries $GW"
else
    todo "vm-$SW has no $GW (sudo vm switch address $SW $GW/24)"; problems=1
fi

# 2. Templates: Linux and FreeBSD guests on the NAT switch, UEFI.
if [ -z "$DS" ] || [ ! -d "$DS/.templates" ]; then
    todo "no vm-bhyve datastore (vm_dir unset or not initialised: sysrc vm_dir=zfs:zroot/vm; vm init)"; problems=1
else
    for t in linux-nat freebsd-nat; do
        f="$DS/.templates/$t.conf"
        if [ -f "$f" ]; then
            ok "template $t"
        elif [ "$CHECK" = 1 ]; then
            todo "template $t missing"; problems=1
        else
            printf 'loader="uefi"\ncpu="1"\nmemory="1G"\nnetwork0_type="virtio-net"\nnetwork0_switch="%s"\ndisk0_type="virtio-blk"\ndisk0_name="disk0.img"\n' "$SW" \
                | sudo -n tee "$f" >/dev/null
            did "wrote template $t"
        fi
    done
fi

# 3. Forwarding, so the host routes for the guests.
if [ "$(sysctl -n net.inet.ip.forwarding)" = 1 ]; then
    ok "net.inet.ip.forwarding=1"
elif [ "$CHECK" = 1 ]; then
    todo "net.inet.ip.forwarding is 0"; problems=1
else
    sudo -n sysctl net.inet.ip.forwarding=1 >/dev/null
    sudo -n sysrc gateway_enable=YES >/dev/null
    did "net.inet.ip.forwarding=1, gateway_enable=YES"
fi

# 4. pf NAT out of the uplink: CHECKED, never written.
if ! sudo -n pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
    todo "pf is not enabled, so guests have no NAT; enabling pf is the operator's call"
    problems=1
elif [ -z "$UPLINK" ]; then
    todo "no default route, so no uplink to NAT out of"; problems=1
elif sudo -n pfctl -s nat 2>/dev/null | grep -E "^nat on $UPLINK " | grep -q "from $NET"; then
    ok "pf NATs $NET out of $UPLINK"
else
    echo "  TODO  pf has no NAT for $NET on the uplink $UPLINK, so guests cannot reach"
    echo "        the internet (the host still reaches them). Add this to /etc/pf.conf,"
    echo "        beside the other nat rules, then reload pf yourself:"
    echo "          nat on $UPLINK inet from $NET to any -> ($UPLINK)"
    echo "        Until then test/bhyve-lab.sh gives guests an HTTP proxy on $GW:3128."
    problems=1
fi

if [ "$problems" = 0 ]; then
    echo "NAT network ready."
else
    echo "NAT network: see TODO above."
fi
# Exit 0 either way: a missing NAT rule leaves guests reachable from the host,
# which is all the specs need; the caller decides what a TODO means for it.
exit 0
