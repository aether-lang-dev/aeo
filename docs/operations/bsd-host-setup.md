# GhostBSD/FreeBSD host setup for aeo (bhyve substrate)

Everything needed to turn a fresh GhostBSD/FreeBSD box into an aeo bhyve
host. This is the authoritative env-setup record — keep it current as the
setup evolves.

> ### Re-imaging to a new box / GhostBSD version? Re-check these (NIC + version drift)
> This doc was written for the .57 box (FreeBSD 15, NIC `re0`). Other boxes have
> since been used, and the specifics DRIFT per install — before following the steps
> below, confirm the current values and substitute them:
> - **Uplink NIC name** — `re0` on .57, but `em0` on the .204 NUC. Find
>   it with `netstat -rn -f inet | awk '/^default/{print $NF}'` (or `route -n get default`);
>   every pf ssh-rail rule and `nat on <NIC>` must use the REAL name.
> - **FreeBSD version** — `freebsd-version`; the AMD Ryzen guest-boot fix (§5) and pf
>   path (`/sbin/pfctl`) were version-specific once; re-verify on a new base. The
>   base-dev-files and jail-binary footguns below FLIP between 14 and 15 — read §0.
> - **base dev files (14 vs 15 — they FLIP)** — GhostBSD/FreeBSD **14.3** ships
>   WITHOUT `/usr/include` + `crt1.o` (must extract from base.txz); GhostBSD 26 /
>   FreeBSD **15.0** ships WITH them but WITHOUT the `jail`/`jexec`/`jls` base
>   binaries. Different missing pieces, same fix (extract from base.txz). See §0.
> - **ipfw** — GhostBSD enables it by default. On the guest BRIDGE path it must be
>   off (see the ⚠️ box in the pf-anchor section — the pf-redemption fix). On the
>   JAIL path (shared host stack) the stock GhostBSD kernel is compiled
>   `IPFIREWALL_DEFAULT_TO_ACCEPT`, so it's default-allow and does NOT block jail
>   traffic or lock you out — verify with `sudo ipfw list 65535`.
> - **rctl** — `kern.racct.enable=1` needs `/boot/loader.conf` + a reboot (§ rctl).
> - **ssh access on a fresh GhostBSD** — desktop installs often offer only
>   `keyboard-interactive` (not `password`) auth and may firewall inbound; enable sshd
>   + install your pubkey early (see memory `ghostbsd-freebsd14-box`). A fresh
>   GhostBSD 26 desktop reboot is SLOW to bring sshd up (graphical stack first) —
>   "Connection refused" for a few minutes post-reboot is normal, not a hang.

Reference boxes:
- `paul@192.168.0.57` — GhostBSD on **FreeBSD 15.0-RELEASE-p2**, **AMD Ryzen 7 5800U**
  (Zen 3), ZFS root (`zroot`), NIC `re0`. The doc's original bhyve host.
- `paul@192.168.0.204` — reimaged to **GhostBSD 26 / FreeBSD 15.0-RELEASE-p2**
  (2026-07-07; was FreeBSD 14.3 before), NIC `em0`. Where pf was redeemed (on 14.3)
  and where the **jails example is live-proven on 15** (`aeo check`/`up`/`suite` all
  green: two rctl-capped jails boot, the jail boundary contains, teardown is clean).

Versions in use (on .57): bhyve from base (15.0), `vm-bhyve 1.7.3`,
`edk2-bhyve-g202508` (UEFI firmware), `dnsmasq 2.92`, `qemu 11.0.0`
(qemu-img), `fuse-ext2 0.0.11`.

---

## 0. Building the ae toolchain + aeo on GhostBSD

GhostBSD is a desktop distro that ships a STRIPPED base — but *which* pieces are
missing **flips between FreeBSD 14 and 15**, so check both before you build:

| piece | GhostBSD/FreeBSD **14.3** | GhostBSD 26 / FreeBSD **15.0** |
|---|---|---|
| base dev files (`/usr/include`, `crt1.o`, `libgcc_s`) | **MISSING** — extract from base.txz | **present** ✓ |
| jail binaries (`jail`/`jexec`/`jls`, `libjail`) | present | **MISSING** — extract from base.txz |

Both gaps have the **same fix** (pull the missing paths out of the matching
`base.txz`); you just extract different members. Verify each on the box first:
```sh
ls /usr/include/stdio.h /usr/lib/crt1.o   # dev files (14.3: absent; 15.0: present)
ls /usr/sbin/jail                         # jail bin  (14.3: present; 15.0: absent)
```

```sh
# git needs a matching pcre2 (version skew on a fresh box):
sudo pkg install -y git pcre2 gmake
git clone https://github.com/aether-lang-org/aether.git   # https, not git@ (no key)
git clone https://github.com/aether-lang-org/aeo.git
git clone https://github.com/aether-lang-org/aeb.git      # optional: the build tool
git clone https://github.com/aether-lang-org/aeocha.git   # REQUIRED for `aeo check/suite`
                                                          #   (expected as aeo's sibling)

# Extract whatever base.txz members THIS version is missing (see the table above):
fetch https://download.freebsd.org/releases/amd64/$(freebsd-version | sed 's/-p[0-9]*//')/base.txz
# 14.3 (dev files absent):
sudo tar -xf base.txz -C / ./usr/include './usr/lib/*' './lib/*'   # a few .so unlink-fails are harmless
# 15.0 (jail bins absent — needed to run the jails example):
sudo tar -xf base.txz -C / ./usr/sbin/jail ./usr/sbin/jexec ./usr/sbin/jls \
                          './lib/libjail*' './usr/lib/libjail*'

# build: GNU make + clang-as-cc (no gcc on FreeBSD)
cd aether && gmake CC=cc
# stage the install layout + AETHER_HOME (like the Linux box)
mkdir -p ~/.local/bin ~/.local/share/aether ~/.local/lib/aether
cp build/ae build/aetherc ~/.local/bin/; cp -r std runtime ~/.local/share/aether/
cp build/libaether.a ~/.local/lib/aether/
export PATH=$HOME/.local/bin:$PATH AETHER_HOME=$HOME/.local AE_CC=cc CC=cc  # AE_CC=cc: ae links via gcc by default

cd ../aeo && ae build bin/aeo.ae -o ~/.local/bin/aeo --lib lib   # AE_CC=cc must be set
# (aeb, if you cloned it, installs its own way:)
cd ../aeb && gmake install PREFIX=$HOME/.local
```

Two env vars are load-bearing at RUN time, not just build time:
- **`AE_CC=cc`** — ae shells out to `gcc` for the final link otherwise, which fails
  silently as "Build failed". Needed for every `ae build` / `aeo` invocation.
- **`AEO_HOME=$HOME/aeo`** — `aeo check`/`up`/`suite` need it pointed at the aeo tree
  holding `lib/`, else `aeo: AEO_HOME is not set`. (Distinct from `AETHER_HOME`.)

Verified end-to-end on GhostBSD 26 / FreeBSD 15.0 (2026-07-07): **aether 0.361.0**,
**aeb git v0.226**, and **aeo** all build clean with `gmake CC=cc` / `ae build`;
`freebsd-version` = `15.0-RELEASE-p2`; base clang is 19.1.7.

---

## 1. Packages

```sh
pkg install -y vm-bhyve bhyve-firmware qemu-tools dnsmasq fusefs-ext2
```
- **vm-bhyve** — VM manager. **bhyve-firmware** — UEFI ROM (BHYVE_UEFI.fd).
- **qemu-tools** — `qemu-img` (vm-bhyve converts qcow2 cloud images → raw;
  also used to convert the AMD-patched image, §5).
- **dnsmasq** — local DHCP/DNS for the NAT network (§4).
- **fusefs-ext2** — mount the Linux cloud image's ext4 offline to patch
  GRUB (§5).

## 2. Kernel module + vm-bhyve init

```sh
kldload vmm
sysrc -f /boot/loader.conf vmm_load="YES"          # persist vmm
sysrc vm_enable="YES" vm_dir="zfs:zroot/vm"
zfs create zroot/vm 2>/dev/null || true
zfs set mountpoint=/zroot/vm zroot/vm
vm init
cp /usr/local/share/examples/vm-bhyve/* /zroot/vm/.templates/
```

## 3. sudo (passwordless for the aeo automation user)

`/usr/local/etc/sudoers.d/aeo` — the agent drives the box over ssh with
NOPASSWD sudo, scoped to the tools it needs:

```
paul ALL=(ALL) NOPASSWD: /usr/local/sbin/vm, /usr/sbin/jail, /usr/sbin/jexec, /usr/sbin/jls, /sbin/ifconfig, /sbin/zfs, /sbin/zpool
paul ALL=(ALL) NOPASSWD: /usr/bin/cu, /usr/sbin/kldload
paul ALL=(ALL) NOPASSWD: /sbin/pfctl, /usr/sbin/tcpdump, /usr/sbin/service, /usr/sbin/sysctl, /sbin/sysctl, /usr/bin/rctl
paul ALL=(ALL) NOPASSWD: /usr/bin/tee, /bin/mkdir
paul ALL=(ALL) NOPASSWD: /usr/bin/sed
paul ALL=(ALL) NOPASSWD: /sbin/mdconfig, /sbin/mount, /sbin/umount, /usr/local/bin/fuse-ext2, /sbin/gpart, /usr/local/bin/qemu-img
```
(tcpdump/pfctl/sysctl = NAT + diagnosis; sed/mdconfig/mount/fuse-ext2/
qemu-img/gpart = offline image patching §5. **pfctl is `/sbin/pfctl`** on
FreeBSD 15 — NOT `/usr/sbin/pfctl`; a path mismatch makes `sudo -n pfctl` fail.
tee + mkdir let `aeo up` write + load each VM's `/etc/pf.anchors/aeo-<vm>` —
the netpolicy enforcement seam. **VERIFIED on the box 2026-06-25: write→load→
read-back of a resolved deny-default ruleset round-trips through real pfctl.**)

## 4. Networking — NAT mode (REQUIRED on this box)

Bridged-to-LAN networking is unreliable here: bridged guests send DHCP but
get **no reply back to the tap** (`netstat -I tap0 -b` → in=6000+, out=0) —
the upstream LAN switch appears to limit MACs per port. NAT sidesteps L2 to
the LAN entirely (guest on a private net behind the host, host NATs out).

Run the one-time setup:
```sh
sudo sh test/setup-nat.sh
```
which does: install dnsmasq; `sysctl net.inet.ip.forwarding=1` +
`sysrc gateway_enable=YES`; `/etc/pf.conf` source-NAT
`nat on re0 from 172.16.0.0/24 -> (re0)` + `sysrc pf_enable=YES` +
`service pf restart`; `/usr/local/etc/dnsmasq.conf`
(`interface=vm-aeonat`, `dhcp-range=172.16.0.10,172.16.0.250`) +
`service dnsmasq restart`; `vm switch create aeonat` +
`vm switch address aeonat 172.16.0.1/24` + a `linux-nat` template on that
switch. Guests then get a `172.16.0.x` lease from LOCAL dnsmasq (never
touches the LAN switch). `sudo sh test/setup-nat.sh --check` shows state.

Note: vm-bhyve's *internal* NAT is disabled on FreeBSD — it warns and
expects pf + dnsmasq done manually, which setup-nat.sh does.

### Per-VM pf anchor (the netpolicy enforcement seam — REQUIRED for confinement)

> ### ⚠️ FIRST, disable ipfw on the guest bridge path (the load-bearing fix, 2026-07-05)
>
> **GhostBSD ships `ipfw` ENABLED by default** (`net.inet.ip.fw.enable=1`) with a
> stock ruleset. It hooks the same pfil framework pf uses. The moment
> `net.link.bridge.pfil_member=1` routes bridged guest-to-guest L3 packets through
> pfil, **ipfw — which knows nothing about the guest subnet — silently drops them**,
> even though pf *passes* them. This masqueraded for a long time as an "if_bridge+pf
> bug" (see `if_bridge-pf-delivery-bug.md`); it is not. **pf's per-member inter-VM
> confinement works fine once ipfw is off the bridge path** — proven on FreeBSD 14.3
> with the full acceptance suite (whitelisted flow completes, non-whitelisted blocked).
>
> Do ONE of these before expecting inter-VM confinement to bite:
> ```sh
> # simplest: turn ipfw off entirely if aeo owns this host's networking
> sudo sysctl net.inet.ip.fw.enable=0
> sudo sysrc firewall_enable=NO        # persist across reboot
> # OR, if you must keep ipfw: add a pass for the guest subnet BEFORE its denies
> #   sudo ipfw add 100 allow ip from 172.16.0.0/24 to 172.16.0.0/24
> ```
> **aeo does this for you now:** when a BSD node with a `constrain{}` netpolicy comes
> up, aeo detects an enabled ipfw and WARNS (naming the conflict + this fix); run with
> **`AEO_IPFW_OFF=1`** and it disables ipfw automatically (needs the `/sbin/sysctl`
> NOPASSWD grant below). It warns rather than mutating by default — a containment tool
> must not silently disable a host firewall.
> Diagnostic when a whitelisted flow still won't complete: `sysctl net.inet.ip.fw.enable`
> and `kldstat | grep -i fw`. A packet "passed by pf but lost" = a SECOND pfil
> consumer (ipfw/ipf) is eating it — check that before ever blaming if_bridge again.

`aeo up` LOADS each VM's deny-default netpolicy (from `constrain{ egress /
ingress_from / deny_egress }`) into a per-VM pf anchor `aeo/<vm>` (lib/pf —
`pfctl -a aeo/<vm> -f /etc/pf.anchors/aeo-<vm>`) **before the node is created**
(A3): the jail's `exec.start` / the guest's first packet already meet the rules,
so there is no window where the node is reachable but unfiltered (live-probed by
`test/a3-bringup-probe.sh`; the old post-promotion load left a ~2 s window of
open ingress + egress on a deny-default jail). A jail's anchor names its declared
`ip()` (the address it boots at); a bhyve guest's names its ipam address. Before
loading, aeo checks pf will actually **evaluate** the anchor — pf enabled and
`anchor "aeo/*"` in the main ruleset — and reads the anchor back after the load;
any failure is "policy NOT enforced": a loud warning + `status applied: no`, or
**fatal in a `strict()` system** (the node is not started / is torn down). The write→load→read-back chain
is VERIFIED against real pfctl. The deny-default + whitelist acceptance suite PASSES
on FreeBSD 14.3 (once ipfw is off the bridge, per the box above). Three things are
REQUIRED for the loaded rules to actually govern traffic:

0. **ipfw off the guest bridge path** — the box above. Without it everything else is
   necessary-but-not-sufficient; ipfw silently eats the bridged packet.

1. **Reference the anchor** — add `anchor "aeo/*"` to `/etc/pf.conf`.
2. **Don't let a blanket pass override it.** The default `setup-nat.sh` pf.conf
   ships `pass quick on vm-aeonat all` + `pass all`. The `quick` inter-VM pass
   short-circuits — it passes ALL VM↔VM traffic BEFORE the anchor is consulted,
   so confinement never engages. And the trailing non-quick `pass all` re-allows
   whatever an anchor `block`ed (pf is last-match-wins). **Remove the blanket
   `pass quick on vm-aeonat all`** and keep only the host-control-plane passes
   (DHCP/DNS to 172.16.0.1, host→guest ssh), so un-whitelisted inter-VM flows
   fall through to each VM's anchor deny.

⚠️ Editing live pf.conf can interrupt running guests' connectivity — parse-check
first (`sudo pfctl -nf /etc/pf.conf.new`), apply when no deploy is mid-flight,
and the host's own LAN reachability (192.168.0.57 on re0) is unaffected since the
changes are scoped to the vm-aeonat switch.

aeo now DETECTS (1) — and pf being disabled/absent — and reports it as not
enforced. It cannot detect (0) beyond the ipfw warning, nor (2): a blanket `pass
quick` ahead of the anchor still leaves the policy silently inert, so keep the
main ruleset to the shape above.

> **Known gap (found by A3, 2026-10-10): off-box egress through a host `nat`
> rule is NOT blocked by the anchor.** pf translates before it filters, so on the
> NAT interface an outbound packet already carries the host's address and the
> anchor's `block out … from <node>` never matches. Proven live on GhostBSD
> (FreeBSD 15): a `deny_egress` jail behind `nat on em0 from 10.77.3.0/24 -> (em0)`
> reached a LAN host with the anchor loaded. A first try at exempting it — `no nat
> proto tcp from <node>` in a `nat-anchor "aeo/*"` evaluated before the host's
> `nat` — did not take (the rule was evaluated but never matched; not yet
> understood). On-box/inter-node flows and ingress ARE filtered. Tracked in
> TODO.md (Strands track, after A3). With them, a
compromised node can only reach the peers/ports its `constrain{}` block
whitelisted; everything else (incl. egress for a `deny_egress` node) is blocked.
`aeo down` flushes the anchor (`pfctl -a aeo/<vm> -F rules`) so a torn-down VM
leaves no stale deny rules on its (now-reused) address.

The `pfctl` calls go through `sudo -n` (the NOPASSWD pfctl in the sudoers above).

### Resource caps (rctl — the exhaustion-DoS defense, the `limit{}` block)

`aeo up` applies each node's `limit{ limit_mem/limit_cpu/limit_maxproc/... }`
caps via FreeBSD `rctl` (lib/rctl), so a malicious or runaway node can't STARVE
the host (fork bomb, memory balloon, fd gluttony) — rctl DENIES the offending op
rather than leaving it to OOM roulette. Two host prerequisites:

1. **Enable RACCT/RCTL** — it's a boot tunable (not runtime-settable), but RACCT
   IS compiled into GENERIC. Add to `/boot/loader.conf` and REBOOT:
   ```
   kern.racct.enable=1
   ```
   (Verify after reboot: `sysctl kern.racct.enable` → `1`.)
2. **Grant rctl** in the sudoers drop-in: add `/usr/bin/rctl` to a NOPASSWD line
   (rctl is `/usr/bin/rctl` on FreeBSD 15).

⚠️ Enabling RACCT needs a REBOOT — do it during a maintenance window, not with
guests mid-deploy. Until both are done, `aeo up` records + logs the caps but
they aren't enforced (an `rctl: RACCT disabled` error, surfaced as a non-fatal
"caps NOT enforced" line — the node still comes up).

v0 caps **jail** nodes (`jail:<name>` subject); bhyve-VM nodes (a hypervisor
process) are a later thickening (PID targeting) — aeo says so loudly rather than
silently skipping. `aeo down` removes the node's rules (`rctl -r jail:<name>`).

## 4c. The jails example — the live-provable BSD path (`silly_addition_jails.ae`)

The jails demo is the **unblocked** BSD containment path: jails share the host
network stack, so none of the bhyve bridge/NAT/ipfw grief (§4/§5) applies. It's the
one to reach for to prove a fresh box. Two jails (`db` ← `app`, a dependency edge),
each with an rctl `limit{}` cap. **Live-proven on GhostBSD 26 / FreeBSD 15.0
(2026-07-07):**

```sh
export AEO_HOME=$HOME/aeo AE_CC=cc CC=cc
# 1) provision the two jail roots (aeo orchestrates a userland it doesn't ship):
sudo sh test/setup-jail-root.sh db
sudo sh test/setup-jail-root.sh app
# 2) the three verbs:
aeo check examples/silly_addition_jails.ae            # 3 passing (data model, no deploy)
sudo -E aeo up    examples/silly_addition_jails.ae    # boots 2 jails + applies rctl
sudo -E aeo suite examples/silly_addition_jails.ae    # deploy + 2 passing + teardown
sudo -E aeo down  examples/silly_addition_jails.ae    # (if you used `up`)
```
Proven at `up`: `jls` lists JID 1 `db` (172.16.0.10) + JID 2 `app` (172.16.0.11);
`rctl` shows `jail:db:memoryuse:deny=512M`/`maxproc:deny=32` +
`jail:app:memoryuse:deny=1G`/`maxproc:deny=128` (kernel-enforced); and the boundary
holds — `jexec db /rescue/ls /` shows only the jail's `bin dev etc rescue tmp`, NOT
the host's `boot home usr var zroot …`. `suite` tears down cleanly (empty `jls`, zero
`jail:` rctl rules after).

> ### ⚠️ A persistent jail workload MUST detach its stdio (or `aeo up` busy-spins)
> aeo boots a jail with `jail -c … persist exec.start=<cmd>`, shelled through
> `run_capture` (which reads the command's stdout via a pipe). If `exec.start` is a
> **long-lived** process that keeps fd 1 open (e.g. a bare `while :; do sleep; done`),
> that inherited descriptor keeps the capture pipe open, so `aeo up` **blocks reading
> it forever** — and the Aether actor runtime then hot-loops on `sched_yield()`,
> pegging every core (observed load 15+ on a 4-core box; `procstat -k` shows one thread
> in `pipe_read`, the rest spinning). PROVEN + fixed on FreeBSD 15 (2026-07-07).
>
> **Fix (in the composition):** background the payload and redirect its stdio, so the
> create call inherits nothing:
> ```
> command("/rescue/sh -c '(while :; do /rescue/sleep 60; done) >/dev/null 2>&1 &'")
> ```
> `silly_addition_jails.ae` now does this. Any persistent jail payload wants the same
> — detach descriptors from the `jail -c` capture.
>
> (Separately, FreeBSD 15's `/rescue` **dropped `/rescue/true`** — `true` is a shell
> builtin now — so the old `while /rescue/true; …` form also prints a benign
> `/rescue/true: not found`. Use `while :;` (builtin), as above. Harmless on 14.x.)

Prereqs recap for this path (all covered above): jail binaries present (§0 — extract
from base.txz on FreeBSD 15), `kern.racct.enable=1` + reboot for the rctl caps (§4b),
pool named `zroot` (the example's `dataset("zroot/jails/…")`), and `aeocha` cloned as
aeo's sibling for the check/suite specs (§0). ipfw needs no attention here — the
shared-stack jail path isn't governed by the guest-bridge pfil concern, and this
kernel's ipfw is default-allow anyway.

## 5. AMD Ryzen guest-boot fix (REQUIRED — patched image)

Ubuntu Linux guests hang very early in boot under bhyve on this AMD Ryzen
box, intermittently — the guest barely transmits (~20 packets in minutes)
and never reaches networking. Root cause: AMD **TSC/clocksource** handling
in virtualization + bhyve not persisting UEFI vars. Fix = AMD-safe kernel
cmdline, baked into the image's GRUB **offline** (it must be on the cmdline
from the FIRST boot; cloud-init can only fix the NEXT boot — chicken/egg).

Build the patched image once (host-side, no guest boot needed):
```sh
sudo sh test/patch-amd-image.sh      # qcow2 -> raw, md-attach, fuse-ext2
                                     # mount, inject GRUB params, repackage
```
which injects `clocksource=hpet tsc=unstable processor.max_cstate=5
idle=halt console=ttyS0` into BOTH `/etc/default/grub` and the live
`/boot/grub/grub.cfg` kernel lines, producing `jammy-amd.img`. The driver
provisions from `jammy-amd.img` (the AMD-safe image) instead of the stock
cloud image.

Manual steps it runs (for reference / debugging):
```sh
qemu-img convert -f qcow2 -O raw jammy-server-cloudimg-amd64.img jammy-patched.raw
MD=$(mdconfig -a -t vnode -f jammy-patched.raw)     # -> md0
gpart show $MD                                       # p1 = linux-data (ext4 root)
fuse-ext2 /dev/${MD}p1 /tmp/jammy -o rw+
sed -i '' 's/console=tty1 console=ttyS0/& clocksource=hpet tsc=unstable processor.max_cstate=5 idle=halt/g' /tmp/jammy/boot/grub/grub.cfg
# (+ /etc/default/grub for future update-grub)
sync; umount /tmp/jammy; mdconfig -d -u $MD
qemu-img convert -f raw -O qcow2 jammy-patched.raw jammy-amd.img
```

## 5b. Static guest IP (bypass DHCP-broadcast issue)

Even with the AMD-patched image (guest boots, sends DHCP), dnsmasq on the
NAT bridge does NOT receive the guest's DHCP broadcasts — they're visible
on `vm-aeonat` via tcpdump but never reach dnsmasq's socket (a FreeBSD
if_bridge broadcast-to-host-stack quirk; tried `bind-interfaces` off,
`bind-dynamic`, `dhcp-authoritative` — none worked). So the guest never
gets a lease.

Workaround: give the guest a **static IP** via cloud-init network-config,
skipping DHCP entirely. vm-bhyve's `vm create -n <netconfig>` is supposed to
take it but writes its own DHCP block instead — so set it on the seed AFTER
create:
```sh
NC=/zroot/vm/<name>/.cloud-init/network-config
sudo sed -i '' -e 's|dhcp4: true|addresses: [172.16.0.50/24]\n    gateway4: 172.16.0.1\n    nameservers: {addresses: [172.16.0.1]}|' \
               -e '/dhcp6: true/d' -e '/accept-ra: true/d' "$NC"
# rebuild the cloud-init seed (vm-bhyve uses makefs cd9660 label=CIDATA):
sudo makefs -t cd9660 -o rockridge -o label=CIDATA /zroot/vm/<name>/seed.iso /zroot/vm/<name>/.cloud-init
sudo vm start <name>
# guest comes up at 172.16.0.50; host reaches it directly (ssh/curl).
```
Each guest gets a distinct static IP (.50, .51, …). The host NATs them out
via the pf rule.

## 6. Verify

```sh
sudo sh test/setup-nat.sh --check                    # NAT up
# provision a guest from jammy-amd.img on the aeonat switch, watch:
#   netstat -I <tap> -b   -> Ipkts climbs into the thousands (booting)
#   cat /var/db/dnsmasq.leases  -> a 172.16.0.x lease appears
#   ssh ubuntu@<lease> 'cat /proc/cmdline'  -> shows clocksource=hpet ...
```

See also `docs/bhyve-networking-journey.md` (the full journey — every
approach tried, why each helped/failed, and which workarounds become
removable once the AMD boot hang is fixed), memory `bhyve-guest-networking`
(the running diagnosis trail), and `docs/aeo-agent.md`.
