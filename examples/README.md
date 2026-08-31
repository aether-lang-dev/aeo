# aeo examples — one app, deployed every which way

Each `silly_addition_*.ae` here is the **same two-tier app** — a `db` cache (redis)
and an `app` that serves `/add/N/M` over HTTP, `app` depending on `db` — deployed
on a **different substrate** (the thing it runs on: a VM, a container, a jail, or
some combination). The demos span the orchestration matrix —
**with/without a VM (VMM)** × **with/without containers (podman)**, plus the
host-native isolation tiers (Linux LXC, FreeBSD jails, nspawn, bwrap), and
cross-platform (Linux, FreeBSD, Windows) — across the full range aeo targets.
The `confined` demo isn't a new substrate — it layers the confinement
vocabulary on top of an existing one.

They're deliberately the *same workload* so the only thing that varies is the
substrate (or the confinement) — read any one, then diff it against another to
see exactly what a different backend, or turning on `constrain{}`/`limit{}`,
changes.

## The line-up — the same app, deployed every which way

The same two-tier app, composed every which way. Each row is one substrate
(or confinement) realization of that identical workload — the table *is* the
set of alternatives, side by side. Pick any two rows and diff them:
what changes is the substrate, never the app.

| Demo | Host | VM | Container | Cell |
|---|---|---|---|---|
| [`silly_addition_bhyve_podman.ae`](silly_addition_bhyve_podman.ae) | FreeBSD | bhyve VM | podman (inside) | **+VMM +podman** |
| [`silly_addition_kvm_podman.ae`](silly_addition_kvm_podman.ae)   | Linux   | KVM VM   | podman (inside) | **+VMM +podman** |
| [`silly_addition_kvm.ae`](silly_addition_kvm.ae)          | Linux   | KVM VM   | —               | **+VMM −podman** |
| [`silly_addition_containers.ae`](silly_addition_containers.ae)   | Linux   | —        | podman (host)   | **−VMM +podman** |
| [`silly_addition_lxc.ae`](silly_addition_lxc.ae)          | Linux   | —        | LXC (system)    | host-native isolation (Linux) |
| [`silly_addition_jails.ae`](silly_addition_jails.ae)        | FreeBSD | jail     | —               | host-native isolation (FreeBSD) |
| [`silly_addition_bwrap.ae`](silly_addition_bwrap.ae)        | Linux   | —        | bwrap (sandbox) | unprivileged, zero host setup |
| [`silly_addition_nspawn.ae`](silly_addition_nspawn.ae)       | Linux   | —        | nspawn (system) | systemd-native system container |
| [`silly_addition_firecracker.ae`](silly_addition_firecracker.ae) | Linux   | microVM  | —               | minimal "smaller VM" (Firecracker) |
| [`silly_addition_windows.ae`](silly_addition_windows.ae)     | Windows | WSL2     | podman (in WSL) | Linux container on Windows (bring-your-own engine) |
| [`silly_addition_wslc.ae`](silly_addition_wslc.ae)         | Windows | WSL2     | wslc (native)   | Linux container on Windows (MSFT's native engine) |
| [`silly_addition_proxmox.ae`](silly_addition_proxmox.ae)     | _any_ (remote) | PVE VM | — | **remote host, API-driven** (up/down LIVE-PROVEN over the PVE API) |
| [`silly_addition_proxmox_ct.ae`](silly_addition_proxmox_ct.ae)  | _any_ (remote) | — | PVE LXC (native) | **remote host, API-driven** (up/down LIVE-PROVEN; created from an OS tarball) |

`−VMM −podman` is **not** a cell — a compute node has to run *somewhere*, so "no
VM, no container" is degenerate.

The **`silly_addition_confined.ae`** demo is *not* a new substrate cell —
it's the `containers` cell with the **confinement** vocabulary turned on
(`limit{}` caps + `constrain{}` + `deny_egress`), so it showcases the Linux
containment axes rather than another backend (see [Confinement](#confinement-the-impregnable-axis-live) below).

The **[`silly_addition_load_balanced.ae`](silly_addition_load_balanced.ae)** demo is
*not* a new substrate cell either — it's the `containers` cell with two identical
`app` replicas behind an aeo-native **L7 HTTP load balancer**
(`load_balancer("web"){ publish / balance_to / listens / balancer_weight }`), so it
showcases the load-balancing grammar rather than another backend. See
[docs/built_in_load_balancing.md](../docs/built_in_load_balancing.md).
**RUNNABLE** — `aeo up` provisions the balancer (weighted split, health-eject, and
backend isolation are live-proven; doc §9 step 3). The LB runs as a container on
the backends' net and aeo **bakes the aeo-lb image on demand** (no manual step);
it needs a container engine + the toolchain-built `bin/aeo-lb`. The grammar + model
checks are green (`test/spec_load_balancer.ae`, `test/spec_driver_loadbalancer.ae`)
and `aeo check` runs the model spec.

The **[`silly_addition_proxmox.ae`](silly_addition_proxmox.ae)** demo is a new
axis, not just a new backend: it is aeo's **first REMOTE substrate**. Every other
cell runs aeo *on* the box the workload lands on and shells out; here aeo addresses
a **Proxmox VE host over its HTTPS API** (`proxmox_vm("db_vm"){ host / node /
auth_token / storage / bridge / template }`) — the "remote host" the composition
names by endpoint + token. The credential is the part a **CISO signs off on for
prod**: a dedicated service user, a custom least-privilege role, a resource-pool
blast radius, and a privilege-separated, expiring API token — provisioned by
[`checks/proxmox_token_setup.sh`](checks/proxmox_token_setup.sh) and proven
allowed-vs-denied in [`checks/proxmox_token_setup.md`](checks/proxmox_token_setup.md).
**RUNNABLE** — the whole lifecycle is **live-proven**: `aeo up` clones the template
→ configures cloud-init → starts the VMs (dependency-ordered); `aeo down` stops →
destroys each (template preserved). `driver_proxmox` is a pure API client on
`std.http.client` (native Aether HTTP, no curl), and every 8006 call is **verified
against PVE's own CA** (couriered over ssh — no blind trust). Full narrative,
security model, and the provision-once/orchestrate-many design:
[docs/aeo-and-proxmox.md](../docs/aeo-and-proxmox.md).

### Runbook: a fresh orchestrator (Chromebook or other) → a running deploy

The PVE 8006 API can't do host-shell (template build, snippet placement, pool ops),
so those are **one-time host setup over ssh** (root); the deploy itself is then
pure-API with a least-privilege token. Run in order:

```sh
# --- one-time host setup (ssh root@<pve>) ---
PVE_SSH=root@<pve> sh checks/proxmox_bootstrap.sh     # template + pool member + doer snippet
PVE_SSH=root@<pve> sh checks/proxmox_token_setup.sh   # least-priv CISO token  -> prints PVE_TOKEN
PVE_SSH=root@<pve> sh checks/proxmox_pin_ca.sh        # courier PVE's CA       -> prints AEO_PVE_CACERT

# --- deploy (pure 8006 API, verified TLS, least-priv token) ---
export PVE_TOKEN="aeo@pve!deploy=<secret>"            # from proxmox_token_setup.sh
export AEO_PVE_CACERT="$(pwd)/pve-root-ca.pem"        # from proxmox_pin_ca.sh
aeo check examples/silly_addition_proxmox.ae          # model + remote-host preflight
aeo up    examples/silly_addition_proxmox.ae          # clone → cloud-init → start
aeo down  examples/silly_addition_proxmox.ae          # stop → destroy
```

Host-agent (optional): `checks/proxmox_host_agent_install.sh` installs aeo-agent ON
the PVE host as a loopback systemd listener (fetched from GH-releases, ssh-gated).
The in-guest doer (aeo-agent fetched via cloud-init, runs the workload container)
is `checks/proxmox_cloudinit.yaml` + `cloud_init()`/`agent()` in the composition.
Deferred follow-ups (see TODO): per-node identity/token seeding; a host-agent
health-multiplexer.

The naming is by SUBSTRATE (bhyve_podman / kvm / containers / jails / lxc / bwrap),
not the workload. (The original demo was `silly_addition_cache.ae`; renamed for
consistency. Its internal `system("silly_addition_cache")` IDENTIFIER stays —
specs + ipam assert against that string.)

## What each demonstrates

- **bhyve_podman** (FreeBSD apex) — two bhyve VMs, each running a container,
  with the FULL confinement story: per-VM **Capsicum** fd grants + deny-default
  **pf** port policy. db answers 6379 to app only; a compromised redis can't
  exfiltrate. The richest demo.
- **kvm_podman** (Linux apex) — the direct analog: two KVM VMs each running a
  container. Caveat: the kvm arm boots `image()` as-is (no cloud-init
  provisioning like bhyve), so the guest images need podman+sshd+key baked in.
- **kvm** — bare KVM VMs (no container) — the VMM by itself.
- **containers** — two podman containers on the host, no VM — the most common
  real Linux deploy, and the Linux peer of the jails demo.
- **lxc** — two LXC *system* containers (a full-OS userland under its own root,
  via the classic `lxc-*` tools) — the Linux analog of a FreeBSD jail, distinct
  from the podman *app* containers.
- **jails** — two FreeBSD jails with **rctl** resource caps (exhaustion-DoS
  guard) — the host-native isolation tier.
- **bwrap** — two rootless **bubblewrap** sandboxes — the lightest "contain a
  process" tier: a host process dropped into fresh namespaces, no daemon, no
  image pull, no host setup. Proves the substrate (rootless boot, a private pid
  namespace, net unshared) rather than the cache service.
- **nspawn** — two **systemd-nspawn** system containers — the systemd-native LXC
  peer: a full-OS rootfs booted under its own root, registered with machined, far
  less finicky than classic LXC (no idmap, no lxcbr0). Proves the substrate (boot
  + per-container hostname/pid namespace + ordering) rather than the cache service.
- **firecracker** — two **Firecracker** microVMs — the minimal "smaller VM" tier
  (AWS microVM, ~125ms boot, minimal device model vs full qemu). Boots a
  kernel+rootfs bundle per node; proves the microVM substrate (boot + liveness +
  ordering). No in-guest probe yet — a microVM has no host-side exec (ssh/vsock
  into the guest is a follow-up).
- **windows** — two Linux containers on a **Windows** host via **podman-in-WSL2**:
  the driver runs `wsl -d <distro> -- podman …`, so the container IS Linux, one
  substrate-hop away inside WSL. The bring-your-own-engine Windows tier (needs a
  WSL distro with podman). `wsl_distro()` selects the distro. Proves the substrate
  (run + ps + exec + teardown through WSL) rather than the cache service.
- **wslc** — two Linux containers on a **Windows** host via **Microsoft's native
  WSL Containers** (`wslc.exe`, WSL ≥ 2.9.3): no podman, no distro prefix — the
  platform's own OCI runtime. The native-engine peer of the `windows` tier. Proves
  the substrate (run + list + exec + teardown via `wslc`). Live-proven on a real
  Win11 guest; see `docs/development/aeo-agent-windows-pipeline.md`.
- **confined** — the `containers` cell with all three Linux confinement axes on:
  `limit{}` → cgroup caps, `constrain{}` → cap-drop/seccomp, `deny_egress` →
  `--network none`. The showcase for "contain malware" on Linux.

## Confinement: the impregnable axis (live)

The Linux container confinement is **built and live-proven**, from the *same*
`limit{}` + `constrain{}` grammar that renders to rctl/Capsicum/pf on FreeBSD
(substrate-portable confinement):

- **cgroup caps** (the rctl peer) — `limit_mem`/`limit_maxproc` → `--memory`/
  `--pids-limit`. Proven: a fork-bomb inside a capped node is *refused*.
- **cap-drop / seccomp** (the Capsicum peer) — a `constrain{}` node →
  `--cap-drop ALL --security-opt no-new-privileges` (+`--read-only` on
  `deny_egress`).
- **network policy** (the pf peer) — `deny_egress` → `--network none` (no
  namespace; can't phone home); peer-only egress → an `--internal` podman net
  (reaches the declared peer, *not* the internet). This *sidesteps* the FreeBSD
  pf+if_bridge inter-VM bug entirely.

Plus, orthogonal to the demos but live: **image attestation** (`attest("sha256:…")`
refuses a mismatched image at boot, fail-closed) and a **tamper-evident audit
trail** (`aeo audit` verifies the hash chain). The FreeBSD demos carry the
FreeBSD side: Capsicum + pf (bhyve_podman, pf delivery pending the if_bridge
fix), rctl + the jail boundary (jails, live).

## Each demo is a PURE COMPOSITION (declaration only)

Each `silly_addition_*.ae` is a **pure declaration** — nodes, dependencies, health
windows, and the spec files that verify it. NO `main()`, NO self-test scaffold: `aeo`
is the executor, exactly as `aeb <target>.build.ae` runs a build declaration. A demo
declares its OWN verification with first-class `check()`/`smoke()`/`suite()` verbs
that name external aeocha specs (under [`checks/`](checks/)):

```
system("silly_addition_containers") {
    container("db")  { image("…redis…"); health("redis-cli ping") }
    container("app") { image("localhost/aeo-examples/silly-add:latest"); depends("db") }
    check("examples/checks/containers_model.spec.ae")   // data-model, NO deploy
    smoke("examples/checks/containers_smoke.spec.ae")   // deploy + probe, leave up
    suite("examples/checks/containers_suite.spec.ae")   // deploy + probe, tear down
}
```

### Phases (`aeo <phase> <demo>.ae`)

| Phase | What |
|---|---|
| `aeo check` | run the demo's `check()` specs, NO deploy. Runs ANYWHERE, instant. CI-usable exit code. |
| `aeo up`    | deploy, dependency-ordered, gated on health. Leave STANDING. |
| `aeo smoke` | deploy + run `smoke()` specs, leave STANDING. |
| `aeo suite` | deploy + run `suite()` specs, then TEAR DOWN. The CI shape. |
| `aeo down`  | tear down in reverse, verifying each node is gone. |

```sh
# data-model check (anywhere, no backend needed):
aeo check examples/silly_addition_jails.ae
# a live deploy + probe + teardown (on the right host):
aeo suite examples/silly_addition_containers.ae
```

The runner runs each spec as a SEPARATE process, so aeocha stays OUT of the lean
orchestration binary. Application source (the `/add` service) lives in
[`silly_addition_app/`](silly_addition_app/) as a prebuilt image the compositions
reference by tag — NOT inline: the composition is orchestration, not an app. The
thin itest driver is [`test/examples-suite.sh`](../test/examples-suite.sh).

## Live-proven status (what's actually been run)

- **containers** — full `aeo up` → `2+2=4` over HTTP, *with the cross-container
  cache working* (a value poked into redis read back through app), live on
  Bazzite. `aeo down` verifies disappearance. The reference live deploy.
- **confined** — all three confinement axes enforced live: a fork-bomb refused by
  `--pids-limit`, a `deny_egress` node with no network namespace, cap-drop via
  `podman inspect`. The "impregnable" story, proven.
- **lxc** — `aeo up` → two alpine system containers RUNNING, `aeo exec db
  hostname` → `db` (contained), `aeo down` clean. Live on Bazzite.
- **kvm** — full `aeo up` booted two KVM VMs (rootless `-nic user`), alive +
  `aeo down`, live on Bazzite.
- **jails** — boot + jail-boundary containment + rctl caps, live on the GhostBSD
  box. The strongest FreeBSD live story.
- **bwrap** — full `aeo suite` round-trip live on Bazzite: deploy two rootless
  sandboxes, run the suite spec, then verified-gone teardown. Rootless, zero host
  setup. (Post-redesign: `aeo suite examples/silly_addition_bwrap.ae`.)
- **bhyve_podman** — confinement data-model proven; live pf inter-VM *delivery* is
  the one BROKEN axis (TODO §1, the if_bridge bug — the Linux per-flow netpolicy
  sidesteps it).
- **kvm_podman** — check green; live `aeo up` needs guest images with podman+sshd
  baked in (honest caveat in the file header).

Also live on Bazzite: **image attestation** (a mismatched digest refused at
boot), the **tamper-evident audit trail** (an edited log caught by `aeo audit`),
and the **lifecycle ops** (snapshot/rollback round-trip on a container, prune
keep-N). Every demo passes `check` standalone (data-model assertions, no backend needed).

## Other examples here

- `recipe_realize/` — proves the `image_recipe` realizer end-to-end via `aeo up`
  (the golden-image build/clone path), separate from the line-up above.
- `_parked/` — smaller single-tier demos (jail-only, vm-only, an all-Linux
  two-tier), strict subsets of the line-up demos. Revive with
  `git mv examples/_parked/<x> examples/`.
