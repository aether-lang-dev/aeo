#!/bin/sh
# setup-base.sh — build the GOLDEN Linux guest ONCE, so every bhyve VM aeo
# brings up is a ZFS clone (seconds) instead of a cloud-image provision
# (minutes), and so the live specs have a Linux guest to probe.
#
# Builds `aeo-base`, an Ubuntu 22.04 cloud image guest at 172.16.0.50 on the
# aeonat switch, with podman, python:3-alpine and redis:alpine pulled, and the
# example app image localhost/aeo-examples/silly-add:latest built (from
# examples/silly_addition_app/); then snapshots it as aeo-base@golden. Clones
# are warm copies: cloud-init is disabled in the golden and the address lives in
# /etc/netplan/99-aeo-static.yaml, which test/patch-static-ip.sh rewrites per
# clone before its first boot.
#
#   sh test/setup-base.sh            # build aeo-base@golden unless it exists
#   sh test/setup-base.sh --start    # (re)start aeo-base itself at .50
#   sh test/setup-base.sh --destroy  # remove aeo-base and its snapshot
#
# Runs as a normal user; privileged steps use `sudo -n`. Needs: vm-bhyve with
# the linux-nat template (test/setup-nat.sh), qemu-img (pkg qemu-tools).
#   AEO_SSH_KEY      private key whose .pub is installed (default ~/.ssh/id_rsa)
#   AEO_GUEST_PROXY  http proxy the guest uses for apt and image pulls, e.g.
#                    http://172.16.0.1:3128 when pf does not NAT the guests
#                    (test/bhyve-lab.sh sets it); unset = direct
#
# The stock image boots on Intel (ghostbsd, i3-8109U). The June 2026 AMD
# Ryzen box needed test/patch-amd-image.sh; this script does not apply it.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="aeo-base"
IP="172.16.0.50"
GW="172.16.0.1"
IMG="jammy-server-cloudimg-amd64.img"
URL="https://cloud-images.ubuntu.com/jammy/current/$IMG"
KEY="${AEO_SSH_KEY:-$HOME/.ssh/id_rsa}"
PROXY="${AEO_GUEST_PROXY:-}"

g() {
    ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=8 "ubuntu@$IP" "$@"
}
wait_ssh() {
    i=0
    while [ $i -lt 60 ]; do
        nc -z -w2 "$IP" 22 >/dev/null 2>&1 && return 0
        i=$((i + 1)); sleep 5
    done
    echo "$BASE never answered ssh at $IP:22" >&2; return 1
}
stopped() {
    i=0
    while [ $i -lt 40 ]; do
        sudo -n vm list | awk -v n="$BASE" '$1==n' | grep -q Stopped && return 0
        i=$((i + 1)); sleep 3
    done
    return 1
}
has_golden() { zfs list -H -t snapshot -o name 2>/dev/null | grep -q "/$BASE@golden\$"; }

case "${1:-}" in
--destroy)
    sudo -n vm stop "$BASE" >/dev/null 2>&1 || true; stopped || sudo -n vm poweroff -f "$BASE" >/dev/null 2>&1 || true
    sudo -n vm destroy -f "$BASE"
    echo "destroyed $BASE (and $BASE@golden)"; exit 0 ;;
--start)
    sudo -n vm start "$BASE" >/dev/null 2>&1 || true
    wait_ssh && echo "$BASE answers at $IP"; exit $? ;;
esac

if has_golden; then
    echo "$BASE@golden exists (sh test/setup-base.sh --destroy to rebuild)"; exit 0
fi
[ -f "$KEY.pub" ] || { echo "no $KEY.pub (set AEO_SSH_KEY)" >&2; exit 1; }

sudo -n vm img 2>/dev/null | grep -q "$IMG" || sudo -n vm img "$URL"

if ! sudo -n vm list | awk '{print $1}' | grep -qx "$BASE"; then
    UD=$(mktemp "${TMPDIR:-/tmp}/aeo-base-ud.XXXXXX")
    printf '#cloud-config\ndatasource_list: [ NoCloud, None ]\nssh_pwauth: false\nssh_authorized_keys:\n  - %s\n' "$(cat "$KEY.pub")" > "$UD"
    # vm-bhyve 1.7.5 renders -n into a valid netplan network-config (1.7.3 did
    # not, which is why patch-static-ip.sh exists for clones).
    sudo -n vm create -t linux-nat -i "$IMG" -c 1 -m 2G -s 10G -C -u "$UD" \
        -n "ip=$IP/24;gateway4=$GW;nameservers=$GW" "$BASE"
    rm -f "$UD"
fi
sudo -n vm start "$BASE" >/dev/null 2>&1 || true
wait_ssh

echo "provisioning $BASE (podman, images, app image)..."
if [ -n "$PROXY" ]; then
    g "printf 'Acquire::http::Proxy \"%s\";\nAcquire::https::Proxy \"%s\";\n' $PROXY $PROXY | sudo tee /etc/apt/apt.conf.d/95aeo-proxy >/dev/null
       grep -q aeo-proxy /etc/environment || printf '# aeo-proxy\nhttp_proxy=%s\nhttps_proxy=%s\nHTTP_PROXY=%s\nHTTPS_PROXY=%s\nno_proxy=localhost,127.0.0.1,172.16.0.0/24\nNO_PROXY=localhost,127.0.0.1,172.16.0.0/24\n' $PROXY $PROXY $PROXY $PROXY | sudo tee -a /etc/environment >/dev/null"
fi
g "set -e
export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get update -qq
sudo -E apt-get install -y -qq podman >/dev/null
# podman copies the host's proxy variables into containers by default; a
# container's own localhost calls then went to the proxy (busybox wget ignores
# no_proxy).
printf '[containers]\nhttp_proxy = false\n' | sudo tee /etc/containers/containers.conf >/dev/null
echo overlay | sudo tee /etc/modules-load.d/aeo.conf >/dev/null
grep -q '$BASE' /etc/hosts || echo '127.0.1.1 $BASE' | sudo tee -a /etc/hosts >/dev/null
podman pull -q docker.io/library/python:3-alpine >/dev/null
podman pull -q docker.io/library/redis:alpine >/dev/null"
tar -C "$ROOT/examples/silly_addition_app" -cf - Dockerfile app.py | \
    g "rm -rf ~/silly-add && mkdir ~/silly-add && tar -C ~/silly-add -xf - && podman build -q -t localhost/aeo-examples/silly-add:latest ~/silly-add >/dev/null"

# Warm-copy golden: the address in a name-matched netplan (patch-static-ip.sh
# rewrites it per clone), cloud-init off so a clone re-initialises nothing.
g "set -e
sudo tee /etc/netplan/99-aeo-static.yaml >/dev/null <<NP
network:
  version: 2
  ethernets:
    aeonic:
      match:
        name: \"e*\"
      dhcp4: false
      addresses: [$IP/24]
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$GW]
NP
sudo chmod 600 /etc/netplan/99-aeo-static.yaml
sudo rm -f /etc/netplan/50-cloud-init.yaml
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network.cfg >/dev/null
sudo touch /etc/cloud/cloud-init.disabled
sudo netplan generate
podman images --format '{{.Repository}}:{{.Tag}}'
sudo sync"

# Snapshot only a cleanly stopped guest (an unclean one left an aborted ext4
# journal in an earlier golden).
sudo -n vm stop "$BASE" >/dev/null
stopped || { echo "$BASE did not stop" >&2; exit 1; }
sudo -n vm snapshot "$BASE@golden"
echo "built $BASE@golden; start the Linux guest with: sh test/setup-base.sh --start"
