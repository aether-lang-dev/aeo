#!/bin/sh
# bhyve-lab.sh — ONE command from an empty vm-bhyve datastore to "the live bhyve
# specs run": the NAT network, the golden Linux guest (aeo-base@golden, running
# at 172.16.0.50), the FreeBSD guest (aeo-fbsd at 172.16.0.52), and when pf does
# not NAT the guests, an HTTP proxy for them on 172.16.0.1:3128. Idempotent:
# each step skips what already exists. docs/operations/bsd-host-setup.md §7.
#
#   sh test/bhyve-lab.sh up       # build/start everything missing
#   sh test/bhyve-lab.sh check    # report only, change nothing
#   sh test/bhyve-lab.sh down     # stop the guests and the proxy (keeps them)
#
# Then, from this checkout:
#   AEO_HOME=$PWD sh test/run-spec.sh                  # whole suite, guests live
#   sh test/soup-to-nuts.sh                            # aeo up of the bhyve example
#
# Runs as a normal user with NOPASSWD sudo. It never edits /etc/pf.conf, reloads
# pf, or touches a physical interface (see test/setup-nat.sh). It does not
# install packages: it names what is missing and stops.
#   AEO_SSH_KEY  guest key (default ~/.ssh/id_rsa; created, no passphrase, if absent)
#   AEO_LAB_DIR  state: proxy config/pid/log, downloads (default ~/.aeo-lab)
set -eu

T="$(cd "$(dirname "$0")" && pwd)"
LAB="${AEO_LAB_DIR:-$HOME/.aeo-lab}"
export AEO_SSH_KEY="${AEO_SSH_KEY:-$HOME/.ssh/id_rsa}"
export AEO_LAB_DIR="$LAB"
GW="172.16.0.1"
NET="172.16.0.0/24"
CMD="${1:-check}"

need() {
    miss=""
    command -v vm >/dev/null 2>&1 || miss="$miss vm-bhyve"
    [ -f /usr/local/share/uefi-firmware/BHYVE_UEFI.fd ] || miss="$miss bhyve-firmware"
    command -v qemu-img >/dev/null 2>&1 || miss="$miss qemu-tools"
    command -v fuse-ext2 >/dev/null 2>&1 || miss="$miss fusefs-ext2"
    command -v python3 >/dev/null 2>&1 || miss="$miss python3"
    if [ "$(nat_ok)" = no ]; then
        [ -x /usr/local/sbin/tinyproxy ] || miss="$miss tinyproxy"
    fi
    echo "$miss"
}
uplink() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
nat_ok() {
    u=$(uplink)
    if [ -n "$u" ] && sudo -n pfctl -s nat 2>/dev/null | grep -E "^nat on $u " | grep -q "from $NET"; then
        echo yes
    else
        echo no
    fi
}
proxy_pid() {
    p=$(cat "$LAB/tinyproxy.pid" 2>/dev/null || true)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p" || true
}
proxy_up() {
    [ -n "$(proxy_pid)" ] && return 0
    mkdir -p "$LAB"
    cat > "$LAB/tinyproxy.conf" <<CONF
Port 3128
Listen $GW
Timeout 600
Allow $NET
ConnectPort 443
ConnectPort 80
PidFile "$LAB/tinyproxy.pid"
LogFile "$LAB/tinyproxy.log"
LogLevel Info
MaxClients 50
CONF
    /usr/local/sbin/tinyproxy -c "$LAB/tinyproxy.conf"
    sleep 1
    [ -n "$(proxy_pid)" ] || { echo "tinyproxy did not start; see $LAB/tinyproxy.log" >&2; return 1; }
}
answers() { nc -z -w2 "$1" 22 >/dev/null 2>&1 && echo yes || echo no; }

case "$CMD" in
check)
    sh "$T/setup-nat.sh" --check
    m=$(need); [ -n "$m" ] && echo "  TODO  missing packages:$m (sudo pkg install$m)"
    echo "=== guests"
    zfs list -H -t snapshot -o name 2>/dev/null | grep -q '/aeo-base@golden$' && echo "  ok    aeo-base@golden" || echo "  TODO  no aeo-base@golden (test/setup-base.sh)"
    echo "  Linux guest   172.16.0.50:22 answers: $(answers 172.16.0.50)"
    echo "  FreeBSD guest 172.16.0.52:22 answers: $(answers 172.16.0.52)"
    echo "  guest egress: pf NAT on uplink $(uplink): $(nat_ok); proxy pid: $(proxy_pid)"
    echo "  bhyve processes in capability mode: $(for p in $(pgrep -f '^bhyve: '); do sudo -n procstat -s $p | awk 'NR==2{print $10}'; done | tr '\n' ' ')"
    ;;
up)
    m=$(need)
    if [ -n "$m" ]; then
        echo "missing packages:$m; install them (sudo pkg install$m) and re-run" >&2; exit 1
    fi
    sudo -n kldstat -q -m vmm || sudo -n kldload vmm
    kldstat -q -m fusefs || sudo -n kldload fusefs
    sh "$T/setup-nat.sh"
    if [ ! -f "$AEO_SSH_KEY" ]; then
        mkdir -p "$(dirname "$AEO_SSH_KEY")"
        ssh-keygen -q -t ed25519 -N "" -C aeo-lab-guest -f "$AEO_SSH_KEY"
        echo "created guest key $AEO_SSH_KEY"
    fi
    if [ "$(nat_ok)" = no ]; then
        proxy_up
        export AEO_GUEST_PROXY="http://$GW:3128"
        echo "guest egress through the proxy $AEO_GUEST_PROXY (pid $(proxy_pid))"
    fi
    sh "$T/setup-base.sh"
    sh "$T/setup-base.sh" --start
    sh "$T/setup-freebsd-guest.sh"
    sh "$T/setup-freebsd-guest.sh" --start
    echo "bhyve lab up: Linux guest 172.16.0.50, FreeBSD guest 172.16.0.52."
    echo "Specs: AEO_SSH_KEY=$AEO_SSH_KEY sh test/run-spec.sh"
    ;;
down)
    for v in aeo-base aeo-fbsd; do sudo -n vm stop "$v" >/dev/null 2>&1 || true; done
    p=$(proxy_pid); [ -n "$p" ] && kill "$p" && echo "stopped proxy $p"
    echo "guests stopping (they stay defined; up starts them again)"
    ;;
*) echo "usage: sh test/bhyve-lab.sh up|check|down" >&2; exit 2 ;;
esac
