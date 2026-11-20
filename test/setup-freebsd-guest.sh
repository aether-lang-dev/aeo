#!/bin/sh
# setup-freebsd-guest.sh — the FreeBSD bhyve guest that
# spec_capsicum_bhyvevm_selfreport probes: a process INSIDE the VM cap_enter()s
# and reports its own confinement (a Linux guest has no Capsicum).
#
# Builds `aeo-fbsd` from the official FreeBSD BASIC-CLOUDINIT (ufs) VM image at
# 172.16.0.52 on the aeonat switch (.50 is the Linux guest), with the key
# installed for the image's `freebsd` user. nuageinit (FreeBSD's cloud-init)
# applies the network-config; the image ships cc, which the probe needs.
#
#   sh test/setup-freebsd-guest.sh            # create + start unless present
#   sh test/setup-freebsd-guest.sh --start    # start it
#   sh test/setup-freebsd-guest.sh --destroy
#
#   AEO_SSH_KEY       private key whose .pub is installed (default ~/.ssh/id_rsa)
#   AEO_FREEBSD_REL   release (default: this host's, e.g. 15.1-RELEASE)
#   AEO_LAB_DIR       where the download lands before it moves to the datastore
set -eu

VM="aeo-fbsd"
IP="172.16.0.52"
GW="172.16.0.1"
KEY="${AEO_SSH_KEY:-$HOME/.ssh/id_rsa}"
REL="${AEO_FREEBSD_REL:-$(freebsd-version -k | sed 's/-p[0-9]*$//')}"
F="FreeBSD-$REL-amd64-BASIC-CLOUDINIT-ufs.raw"
SITE="https://download.freebsd.org/releases/VM-IMAGES/$REL/amd64/Latest"
LAB="${AEO_LAB_DIR:-$HOME/.aeo-lab}"

VMDIR=$(sysrc -n vm_dir | sed 's/^zfs://')
case "$VMDIR" in /*) DS="$VMDIR" ;; *) DS=$(zfs get -H -o value mountpoint "$VMDIR") ;; esac

wait_ssh() {
    i=0
    while [ $i -lt 60 ]; do
        nc -z -w2 "$IP" 22 >/dev/null 2>&1 && return 0
        i=$((i + 1)); sleep 5
    done
    echo "$VM never answered ssh at $IP:22" >&2; return 1
}

case "${1:-}" in
--destroy)
    sudo -n vm poweroff -f "$VM" >/dev/null 2>&1 || true; sleep 2
    sudo -n vm destroy -f "$VM"; echo "destroyed $VM"; exit 0 ;;
--start)
    sudo -n vm start "$VM" >/dev/null 2>&1 || true
    wait_ssh && echo "$VM answers at $IP"; exit $? ;;
esac

if sudo -n vm list | awk '{print $1}' | grep -qx "$VM"; then
    echo "$VM exists (--start to boot it, --destroy to rebuild)"; exit 0
fi
[ -f "$KEY.pub" ] || { echo "no $KEY.pub (set AEO_SSH_KEY)" >&2; exit 1; }

if [ ! -f "$DS/.img/$F" ]; then
    mkdir -p "$LAB"
    ( cd "$LAB"
      fetch -q "$SITE/$F.xz"
      want=$(fetch -qo - "$SITE/CHECKSUM.SHA256" | awk -v f="($F.xz)" '$2==f {print $4}')
      got=$(sha256 -q "$F.xz")
      [ -n "$want" ] && [ "$want" = "$got" ] || { echo "sha256 mismatch for $F.xz: want '$want' got '$got'" >&2; rm -f "$F.xz"; exit 1; }
      xz -d "$F.xz" )
    sudo -n mv "$LAB/$F" "$DS/.img/$F"
fi

UD=$(mktemp "${TMPDIR:-/tmp}/aeo-fbsd-ud.XXXXXX")
printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat "$KEY.pub")" > "$UD"
sudo -n vm create -t freebsd-nat -i "$F" -C -u "$UD" "$VM"
rm -f "$UD"
# vm-bhyve's own network-config renames the NIC and uses `routes`, which
# nuageinit does not read; replace it with the form nuageinit understands
# (vm-bhyve rebuilds seed.iso from .cloud-init at every start).
printf 'version: 2\nethernets:\n  vtnet0:\n    addresses: [%s/24]\n    gateway4: %s\n    nameservers:\n      addresses: [%s]\n' "$IP" "$GW" "$GW" \
    | sudo -n tee "$DS/$VM/.cloud-init/network-config" >/dev/null
sudo -n vm start "$VM" >/dev/null
wait_ssh
echo "$VM answers at $IP"
