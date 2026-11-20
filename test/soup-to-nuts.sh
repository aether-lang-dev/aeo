#!/bin/sh
# soup-to-nuts.sh — THE end-to-end experience, driven by the aeo DSL.
#
# Runs `aeo up examples/silly_addition_bhyve_podman.ae`, which brings up the
# whole nested system declared in the DSL:
#
#   system("silly_addition_cache")
#     ├─ db_vm     (bhyve VM, Linux guest) ─ db  (redis)
#     └─ python_vm (bhyve VM, Linux guest) ─ app (python /add) ──► db_vm:6379
#
# then curls the app FROM the FreeBSD host and asserts the two-tier behaviour
# across the two VMs (compute on a miss, serve redis's value on a hit), then
# tears it down with `aeo down` (pass --keep to leave it standing).
#
#   sh test/soup-to-nuts.sh [--keep]
#
# Prerequisites: `sh test/bhyve-lab.sh up` (the NAT switch and aeo-base@golden,
# which both VMs are cloned from, with the app image already in it). The guest
# image is ubuntu-22.04+podman, whose recipe realizes as clone:aeo-base@golden.
#   AEO       aeo binary (default: built into $AEO_LAB_DIR from this checkout)
#   AEO_SSH_KEY / AEO_LAB_DIR as for bhyve-lab.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAB="${AEO_LAB_DIR:-$HOME/.aeo-lab}"
export AEO_SSH_KEY="${AEO_SSH_KEY:-$HOME/.ssh/id_rsa}"
export AEO_HOME="$ROOT" AEO_GUEST_IMAGE="${AEO_GUEST_IMAGE:-ubuntu-22.04+podman}"
DSL="$ROOT/examples/silly_addition_bhyve_podman.ae"
WORK="$LAB/soup-to-nuts"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
mkdir -p "$WORK"

g() {
    ssh -i "$AEO_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=8 "ubuntu@$1" "$2"
}

echo "=== prerequisite check ==="
miss=0
zfs list -H -t snapshot -o name 2>/dev/null | grep -q '/aeo-base@golden$' || { echo "  MISSING: aeo-base@golden -> sh test/bhyve-lab.sh up"; miss=1; }
sudo -n vm switch list 2>/dev/null | awk '{print $1}' | grep -qx aeonat || { echo "  MISSING: aeonat switch -> sh test/bhyve-lab.sh up"; miss=1; }
AEO="${AEO:-$LAB/aeo}"
if [ ! -x "$AEO" ]; then
    ( cd "$ROOT" && ae build bin/aeo.ae -o "$AEO" --lib lib >/dev/null 2>&1 ) || { echo "  MISSING: could not build $AEO"; miss=1; }
fi
[ "$miss" = 0 ] && echo "  all present" || { echo "fix the above, then re-run"; exit 1; }

echo "=== aeo up (the DSL drives everything) ==="
( cd "$WORK" && "$AEO" up "$DSL" --no-supervisor ) 2>&1 | grep '^aeo:' | sed 's/^/  /'

# aeo's ipam binding (sticky, in the cwd it ran from) says where each VM lives.
ips="$WORK/.aeo/silly_addition_cache.ips"
APP=$(awk '$1=="python_vm"{print $2}' "$ips" 2>/dev/null)
DB=$(awk '$1=="db_vm"{print $2}' "$ips" 2>/dev/null)
echo "  python_vm=$APP db_vm=$DB"

echo "=== host -> app (python_vm) -> db (redis in db_vm) ==="
a=$(curl -fsS -m 8 "http://$APP:8080/add/2/3" 2>/dev/null)
b=$(curl -fsS -m 8 "http://$APP:8080/add/40/2" 2>/dev/null)
echo "  /add/2/3  = $a   (expect 5)"
echo "  /add/40/2 = $b   (expect 42)"

echo "=== prove the cache: overwrite in db_vm's redis, expect the CACHED value ==="
g "$DB" 'podman exec db redis-cli SET add:2:3 CACHED99 >/dev/null 2>&1'
c=$(curl -fsS -m 8 "http://$APP:8080/add/2/3" 2>/dev/null)
echo "  /add/2/3 after cache poke = $c   (expect CACHED99: the app read db across VMs)"

rc=1
if [ "$a" = "5" ] && [ "$b" = "42" ] && [ "$c" = "CACHED99" ]; then
    echo "=== PASS: two-tier nested system across two bhyve VMs, DSL-driven, curl-proven ==="
    rc=0
else
    echo "=== FAIL ==="
fi
if [ "$KEEP" = 0 ]; then
    echo "=== aeo down ==="
    ( cd "$WORK" && "$AEO" down "$DSL" --no-supervisor ) 2>&1 | grep '^aeo:' | sed 's/^/  /'
fi
exit $rc
