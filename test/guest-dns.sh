# guest-dns.sh — sourced by the bhyve guest setup scripts (setup-base.sh,
# setup-freebsd-guest.sh, patch-static-ip.sh); not run on its own.
#
# The resolver a guest should use: the HOST's own, read from /etc/resolv.conf
# when the guest is set up, so nothing here hard-codes one. The guests sit
# behind pf's NAT (172.16.0.0/24 out of the uplink), so a resolver the host
# can reach, they can reach. Nothing serves DNS on the switch address
# (172.16.0.1), which is what the guests were pointed at before.
#
#   AEO_GUEST_DNS   override: space or comma separated addresses
#
# guest_dns prints up to two addresses, comma separated ("a,b"). Loopback
# resolvers (127.x, ::1: a local cache the guests cannot reach) and IPv6
# ones are skipped. With none left it prints the switch address and warns on
# stderr, which is the old behaviour (a guest that then resolves only through
# an HTTP proxy, AEO_GUEST_PROXY).
guest_dns() {
    _gd_list=$(printf '%s' "${AEO_GUEST_DNS:-}" | tr ' ' ',')
    if [ -z "$_gd_list" ]; then
        _gd_list=$(awk '$1=="nameserver" && $2 !~ /^127\./ && $2 !~ /:/ { print $2 }' /etc/resolv.conf 2>/dev/null \
            | head -n 2 | paste -sd, -)
    fi
    if [ -z "$_gd_list" ]; then
        echo "guest-dns: no usable nameserver in /etc/resolv.conf (set AEO_GUEST_DNS); using ${GW:-172.16.0.1}, which serves no DNS" >&2
        _gd_list="${GW:-172.16.0.1}"
    fi
    printf '%s\n' "$_gd_list"
}
# "a,b" as a YAML flow list body: "a, b".
guest_dns_yaml() { guest_dns | sed 's/,/, /g'; }

# EXISTING GUESTS (the scripts above only set a guest up; none is rewritten
# behind your back):
#   aeo-base (Linux, running): on the guest, replace the nameserver address in
#     /etc/netplan/99-aeo-static.yaml with the output of guest_dns_yaml and run
#     `sudo netplan apply`. Clones of aeo-base@golden get the host's resolver
#     from patch-static-ip.sh each time aeo clones one.
#   aeo-fbsd (FreeBSD): its address comes from the seed vm-bhyve rebuilds at
#     every start, so write the same `nameservers: addresses: [...]` into
#     <vm_dir>/aeo-fbsd/.cloud-init/network-config (as root) and `vm stop` then
#     `vm start` it. The `freebsd` user has no sudo or doas in the guest, so
#     /etc/resolv.conf cannot be fixed from inside without root.
