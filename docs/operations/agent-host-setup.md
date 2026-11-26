# Setting up a host with aeo-agent over ssh

What happens to a host when it becomes an aeo node: the **parent orchestrator**
(at depth 0 the operator/runner via `aeo`; deeper, a parent agent) **ssh-es once** to plant
the agent and hand it a per-boot secret (PSK), then everything after — installing the
substrate engine, deploying workloads, tearing them down — flows **through the
agent over an encrypted channel**, never ssh again.

This is the operational counterpart to `development/aeo-agent.md` (the design/why)
and the `*-host-setup.md` docs (the manual prerequisites a substrate needs). Read
those for theory and per-substrate detail; read this for the end-to-end lifecycle
and what actually mutates on the host.

> Proven live this way on: a Raspberry Pi 5 (arm64, podman + lxc), a Pi Zero 2 W
> (arm64, ~415MB, host-exec — no container), and a GhostBSD/FreeBSD box (jails +
> the vm-bhyve substrate). The examples below are grounded in those runs.

---

## The one ssh: plant + courier

ssh has exactly one job here — the **bank courier on a motorbike** (not a CA, not
a standing channel, the 1970s-1980s key distribution mechanism in banks in the USA). 
It carries two things onto the host and leaves:

1. **The agent binary** — a single self-contained executable. Fetch the release
   asset matching the host's OS + arch (see `releasing-aeo.md` for the matrix:
   `aeo-agent-linux-x86_64-static`, `-linux-aarch64-static`, `-freebsd-x86_64`,
   `-windows-x86_64.exe`). The Linux assets are **static** so they run in a full
   OS, debian-slim, musl Alpine, or bare busybox with no runtime `.so` deps.
2. **A per-agent, per-boot secret** — the "courier key" / PSK. Minted fresh (CSPRNG)
   and delivered as `AEO_TOKEN` when the agent starts. It authenticates every later
   command and (see below) keys the encrypted channel. It dies with the agent — a
   host reboot means re-couriering a **new** key; captured traffic can't be
   replayed against the new agent.

Minimal plant (loopback bind, dev/local case):

```
scp aeo-agent-linux-x86_64-static  host:/tmp/aeo-agent
ssh host 'chmod +x /tmp/aeo-agent; \
  AEO_NODE=myhost AEO_TOKEN=<mint-a-secret> AEO_PORT=9700 \
  AEO_TRANSPORT=http AEO_BIND=127.0.0.1 \
  setsid /tmp/aeo-agent >/tmp/agent.log 2>&1 &'
```

Then ssh's job is done. The `probe_health` after the launching ssh closes is the
proof the agent is *resident* (living on its own, not tied to your session).

### Making the agent survive the session (per-OS)

A bare `setsid … &` can be reaped when the launching login session is torn down.
Use the OS's proper detach, and match the process by **exact name** when
restarting (`pkill -x aeo-agent`, never `pkill -f /tmp/aeo-agent` — the latter
also matches your own ssh command line and leaves a stale agent holding the port):

- **Linux (systemd)**: `systemd-run --user --unit=aeo-agent …` (a lingering user
  scope) survives; you may need `loginctl enable-linger <user>` first.
- **FreeBSD**: `daemon -f -o /tmp/agent.log env … /tmp/aeo-agent` — `daemon(8)` is
  the reliable detach.

---

## What the host gets

After the plant, the host has:

- **A resident agent process** serving HTTP on `AEO_PORT` (default 9450; 9700 in
  the examples), bound per `AEO_BIND` — `127.0.0.1` for a same-host/tunnelled
  setup, `0.0.0.0` when a remote orchestrator must reach it across the network.
- **`/health`** — an open, unauthenticated liveness endpoint (`ok`).
- **`/dispatch`** — the authenticated command endpoint. Every command is gated by
  the courier key; a bad/absent token is a fail-closed `401`.
- **No standing ssh credential** and **no interior ssh path** the workload shares.
  ssh was bootstrap-only.

The agent itself is tiny (~1–2 MB, negligible RAM) — it runs comfortably even on a
415 MB Pi Zero 2 W.

### Confining an `exec` node on Linux (`AEO_EXEC_GRANTS`)

An `exec` node is a host process, so by default nothing stands between it and the
host. Set `AEO_EXEC_GRANTS` on the agent and the kernel holds the process to that
list (Landlock + seccomp, applied in the child before it execs; no root, no user
namespace):

```
AEO_BOOT_KIND=exec
AEO_BOOT_CMD='/usr/bin/redis-server /etc/redis/redis.conf'
AEO_EXEC_GRANTS='exec:/usr/bin/redis-server,fs_read:/etc/redis/*,fs:/var/lib/redis/*,tcp_listen'
```

Nothing else has to be on the host. The agent is its own launcher
(`aeo-agent confine …`) and a release agent carries Aether's
`libaether_sandbox.so` inside it; the first confined launch writes it to
`$HOME/.aeo/lib/libaether_sandbox-<hash>.so` and re-checks that hash before
every later one. `aeo-agent preload` prints whether a given binary carries the
library (exit 0) or not (exit 1) — an agent built with a bare `ae build`, not
`tools/build-agent.sh`, does not. `AEO_CONFINE_BIN` names a standalone
`aeo-confine` instead, and `AETHER_SANDBOX_PRELOAD` a library of your own.
The agent needs `HOME` set; it will not fall back to `/tmp`.

The token grammar is in `lib/confine_landlock/module.ae`. Three things to know:

- **It fails closed.** No Landlock in the kernel, no library (not embedded and
  not found), no `HOME` to put it in, or a token the grammar does not know: nothing starts and
  the boot reports why. There is no fallback to the unconfined launch.
- **`shell`, `fork` and `/dev/null` are implied**, because the command is a string
  run through `sh -c`. There is no fork ceiling on this substrate.
- **It is not a network boundary.** TCP connects are kernel-held only from Linux
  6.7, and Landlock has no UDP rule at all. A node that must not phone home needs
  a container kind with `deny_egress()`.
- **The decision is audited on the agent's host.** Every confined launch, and
  every refused one, is one entry in `$HOME/.aeo/agent-audit.log` (or
  `$AEO_AUDIT`): the node, the grants, the launcher, and for a refusal the
  reason. The workload's command is not written. It is the same hash chain as
  the operator's audit trail; `aeo-agent audit` verifies it and exits 1 if it
  was edited. The entry stays on that host — it is not yet sent to the parent.

**Status (2026-11-20): proven locally, not through an agent.** `aeo-confine` and
`driver_mac_exec.up_confined` are live-tested on one box (Crostini, kernel 6.6,
x86_64: reads, writes and execs outside the grants refused). The agent's
`AEO_EXEC_GRANTS` route compiles but has not been dispatched to over the sealed
channel, and **it breaks the one-binary rule below**: the host needs `aeo-confine`
and `libaether_sandbox.so` as well as the agent. How those two reach a fleet host
is undecided.

### How the *rest* of aeo gets to the host: it doesn't

Only the single `aeo-agent` executable is delivered. **Everything aeo will run on
the host is already inside that one binary.** aeo is Aether compiled to a native
executable, so all the logic the agent needs is statically compiled in at build
time — every substrate driver (`driver_linux`, `driver_bsd`, `driver_vm`,
`driver_lxc`, `driver_nspawn`, `driver_bwrap`, `driver_mac_exec`,
`driver_windows`/`driver_wslc`, `driver_proxmox`), the protocol, the courier auth,
the `secure_channel` (AEAD), and both transports. There is no interpreter to
install, no `lib/` directory to copy, no runtime aeo package on the host — `scp`ing
the agent *is* delivering all of aeo's host-side logic.

**No toolchain on the host, either — no `ae` / `aetherc`, no `cc`/`gcc`.** The
agent is *already compiled*; nothing in its runtime path invokes a compiler.
Aether being the source language is a **build-time** fact (the agent binary is
cross-built *off* the host — see "Where the agent binary comes from" below) — the
host never sees Aether source or the Aether toolchain. And self-provisioning is **fetch / package
/ extract, never compile**: `host.pkg_install` runs the OS package manager, the
jail path does `fetch base.txz` + `tar`, bhyve does `pkg install` — no source is
built on the node. (The one thing that *builds* — `driver_linux.build_entrypoint`,
which bakes a container image from an `entrypoint()` — runs that build **inside a
container via podman/buildah**, using the engine's own build machinery, not a host
`cc`.) So the host toolchain requirement is: **none**.

#### Where the agent binary comes from — two provenances

"Cross-built on the CI/dev host" is two distinct paths, and it matters which one a
deployment uses:

1. **A published GitHub Release asset (the intended path).** The
   `release-aeo-agent.yml` workflow, triggered by an `aeo-agent-v*` tag, builds
   each OS/arch asset and publishes an **immutable, versioned** Release: one tag →
   one set of assets → their **SHA256s, retained forever** (see
   `releasing-aeo.md`). Every asset ships a companion `<asset>.sha256`, and the
   run summary prints the table to pin. The recommended plant **fetches the asset
   and verifies its pinned SHA256 *before* running it** — fail-closed, so a
   tampered or wrong binary never executes. This is `attest()`-style integrity:
   the operator (or a cloud-init seed) hard-codes the expected SHA, and delivery
   is only trusted if the hash matches. The parent orchestrator here is the
   **GitHub Releases infrastructure of a prior release cut** — reproducible,
   auditable, retained.

   ```
   ASSET=aeo-agent-linux-aarch64-static
   SHA=<the pinned sha256 from the release>          # hard-coded, from a prior cut
   curl -fsSL .../releases/download/aeo-agent-vX.Y.Z/$ASSET -o /tmp/aeo-agent
   echo "$SHA  /tmp/aeo-agent" | sha256sum -c -       # fail-closed: refuse on mismatch
   chmod +x /tmp/aeo-agent
   ```

2. **A locally-built binary (dev / iteration path).** A developer's workstation
   cross-compiles the agent (`ae build bin/aeo-agent.ae --target=<triple> --lib
   lib`) and `scp`s the *fresh* binary directly — no Release, no pinned SHA. Fast
   for iterating on driver changes (this doc's proofs were done this way), but the
   integrity guarantee is only "I built it and I trust my box." **For anything
   beyond dev, cut a release and use path 1** so the deployed bits are pinned and
   auditable.

Either way the *host's shape* is the same — one self-contained binary, no
toolchain. But the paths are **not** equivalent: the release path gives you a
**correct-and-verified** binary (its bits provably match a retained, SHA-pinned,
auditable artifact), while a hand-built one is only **correct if you trust the box
that built it** — no independent attestation. Same footprint on the host; a
strictly weaker integrity guarantee. The difference is **who vouches for the
bits**, and only path 1 lets the *host itself* refuse a binary that isn't the one
expected.

**What the larger `aeo/` tree contains that is deliberately NOT on the host:**

| in the repo | why it stays off the host |
|---|---|
| `bin/aeo` — the **runner / front-door** (`aeo up <compose.ae>`) | Runs on the **parent orchestrator**, not the node. It evaluates the compose model and *sends* work; the agent *receives* it. |
| the **compose file** (your `*.ae` topology) + `lib/compose` model | Config-as-code lives and is **evaluated on the parent**. The agent never reads a `.ae` file — the parent turns the model into wire lines (`boot <token> <node> <kind>`) and stamps any per-node config as `aeo.cmp.*` keys it couriers. The agent links `compose` only for those shared config-key types, not to load files. |
| `bin/aeo-lb` / `aeo-l4lb` / `aeo-egress-gateway` / `aeo-supervisord` | Separate helper binaries. A driver that needs one (e.g. the load balancer image) builds/ships **it** on demand — they are not part of the agent. |
| `tools/`, `test/`, `spec/`, `examples/`, `docs/` | Build/dev/CI/docs — never shipped anywhere. |

So the division is clean: the **parent** holds the topology (compose), the runner,
and the courier key mint; the **host** holds exactly one self-contained agent
binary, which self-provisions its substrate on demand. Adding aeo logic to what a
host can do means shipping a **newer agent binary** — there's nothing else to sync.

---

## The encrypted channel (courier-keyed AEAD)

The `/dispatch` wire is an **authenticated-encrypted envelope** — a "safe custom
HTTPS" for a closed fleet where both ends already share the courier key, so no
PKI/handshake/cert is needed (and no OpenSSL — it's pure-Aether **Ascon-AEAD128**,
so it works even on a cross-built agent with TLS stubbed out).

- **Confidentiality + integrity**: the dispatch line and reply travel as
  `AE1:<nonce>:<ciphertext+tag>` — a sniffer sees ciphertext; any tampering fails
  the tag (fail-closed).
- **Key**: `HKDF(courier_key)` → the AEAD key, derived identically on both ends.
- **Single-use + freshness**: each frame carries a sealed timestamp; the agent
  rejects frames outside a ±30 s window **and** replays of an already-seen nonce.
- **Attack telemetry**: rejected attempts (bad-key / replay / stale / malformed)
  are counted and **piggybacked on the orchestrator's next authenticated reply**
  (`… | sec: bad_key=1 replay=0 …`) — the attacker gets only a bare `401`, no
  oracle; the legitimate operator learns of probes on their next touch.

Plaintext dispatch still works (an `AE1:`-less line is handled as before), so
existing recursion/tests are unaffected; sealing is opt-in on the client side.

> **Two operational gotchas this bit, both real:**
> - **Clock skew**: the ±30 s window means the host's clock must be roughly
>   NTP-synced. A box an hour off (e.g. a BST/UTC mix-up) rejects *every* sealed
>   frame as stale. Sync it (`ntpdate`, or `sudo date -r <epoch>`) before
>   dispatching.
> - **Firewall**: if the host firewall blocks inbound on `AEO_PORT` (a FreeBSD
>   ipfw box did), bind loopback and reach the agent through an **SSH tunnel**
>   (`ssh -L 9710:127.0.0.1:9700 host`) — the AEAD is still end-to-end; ssh is just
>   the pipe. Don't punch firewall holes remotely on a console-less box.

---

## Self-provisioning: the substrate makes itself ready

The point of the agent model: the parent orchestrator doesn't hand-prepare the
host's container/VM engine, then deploy. It **deploys a workload**, and the agent
silently installs whatever that workload's substrate needs — one ssh in,
everything else through the agent.

A dispatched `boot <token> <node> <kind>` routes to a driver; if the driver's
engine is absent, it self-installs it (best-effort, retried, silent), then runs
the workload. Package installs go through the **host's own package manager**,
detected automatically — `apt`, `dnf`, `yum`, `zypper`, `pacman`, `apk` (Linux),
`pkg` (FreeBSD), `brew` (macOS). Opt out of all auto-install with
`AEO_LINUX_AUTOINSTALL=0`.

**Windows is deliberately absent from that list — aeo installs nothing *on*
Windows** (no choco / winget / nuget / scoop, and no MinGW runtime dep on the
host; MinGW is only a build-time concern for cross-compiling the `.exe`). The
Windows container path (`driver_windows`) runs the workload as a **Linux**
container *inside WSL2* (`wsl -d <distro> -- podman …`), so the engine self-install
happens **inside the WSL distro** using *that distro's* Linux package manager
(the same apt/dnf/apk/pacman/zypper logic, run through `wsl`). The one
Windows-*host* prerequisite is **WSL2 itself** — a Windows *feature* the operator
enables once (`wsl --install`), not a package aeo can fetch. (The native
`driver_wslc` path likewise depends on the `wslc` runtime shipping with WSL.)

`AEO_BOOT_KIND` (the agent's default) or the optional 4th word of the wire line
(`boot <token> <node> <kind>`) selects the kind. Every value the agent routes:

| `kind` | substrate | what the agent silently sets up |
|---|---|---|
| `exec` | a bare tracked host **process** (no vm, no container) | nothing — just runs it (the RAM-tight / minimal-footprint path). Unconfined unless `AEO_EXEC_GRANTS` is set — see below |
| `bwrap` | an unprivileged **bubblewrap** sandbox | nothing beyond bubblewrap (usually present) |
| `lxc` | an **LXC** system container | installs `lxc` (+ `lxc-templates`, `debootstrap` on apt); `lxc-create` downloads the rootfs |
| `nspawn` | a **systemd-nspawn** system container | installs `systemd-container` |
| `vm` | a **KVM/qemu** hardware-virt VM | (arch-aware; needs `/dev/kvm` + qemu) |
| `jail` | a **FreeBSD jail** | fetches + extracts `base.txz` into an empty jail root (opt-out `AEO_JAIL_AUTOBASE=0`) |
| `bhyve` | a **FreeBSD bhyve** VM | `kldload vmm`; installs `vm-bhyve` + `bhyve-firmware`; `vm init` + datastore + a NAT switch |
| `proxmox_vm` | a **VM** on a **remote Proxmox** via its API | — (targets a remote PVE, not the local host) |
| `proxmox_ct` | an **LXC container** on a **remote Proxmox** via its API | — (remote PVE) |

**The default (no `kind`) — a container — resolves per host OS**, not by a `kind`
string:

| host OS | default backend | what the agent silently sets up |
|---|---|---|
| Linux | **podman/docker** app container | installs `podman` if absent, then `podman run` |
| Windows | **`wslc`** (native WSL Containers, `wslc.exe`) if present, else **`windows`** (podman-in-WSL) | wslc: needs only WSL. windows: installs podman *inside the WSL distro* (see the Windows note above) |

`wslc` and `windows` are auto-selected by `_win_backend()` — wslc is preferred
when available (observed on winbaz to get working container networking that
podman-rootless-in-WSL often lacks); `AEO_WIN_BACKEND` forces one.

> **macOS has no container/VM default.** The default path assumes Linux podman; on
> macOS use the explicit **`exec`** kind (a native tracked host process, optionally
> Seatbelt-confined — proven on macvm), since macOS has no container primitive. See
> `research/mac-exec-considered.md`.

Installs retry through transient failures (a held dpkg lock on first boot, a
network blip, the post-install `podman run` 125 race) — `AEO_LINUX_RUN_RETRIES`
tunes the run-retry count. So a cold host self-heals without the orchestrator
re-dispatching.

**Example — deploy a container on a cold host, all through the sealed channel.**

There is **no `aeo boot` CLI**; the control plane is the HTTP `/dispatch`
endpoint. A command is a one-line **wire payload** — the space-separated protocol
line `<verb> <token> <node> [kind]` (from `lib/protocol`) — which the client
**seals** (AEAD, keyed by the PSK) and **POSTs**. The protocol lines here are:

```
boot  <PSK> web1           # -> agent: podman absent? install it -> podman run -> report up
probe <PSK> web1           # -> report web1 up
halt  <PSK> web1           # -> report web1 down
```

To actually send one, seal the line and POST it (the parent orchestrator does
this in code; shown here with a `seal` helper + `curl` for illustration):

```
FRAME=$(seal "$PSK" "boot $PSK web1")            # -> AE1:<nonce>:<ciphertext+tag>
curl -s -X POST http://<host>:9700/dispatch --data "$FRAME"   # -> a sealed reply
# open the reply with the same PSK -> "report web1 up"
```

(`seal`/`open` are `lib/secure_channel.seal_line`/`open_line`; the parent
orchestrator calls them directly. There is no shipped standalone `seal` binary —
it's a library the dispatching side links, or a small helper you build.)

One running agent can boot **mixed** substrates without a restart — the `kind` is
the optional **4th word** of the wire line (`boot <token> <node> lxc`), overriding
the agent's `AEO_BOOT_KIND` default.

---

## What actually mutates on the host

Setting a host up this way changes it in these concrete ways — know them before
pointing the agent at a box you care about:

- **Packages get installed** (via the host package manager) the first time a
  workload of that kind is booted — podman/lxc/systemd-container on Linux,
  vm-bhyve/bhyve-firmware on FreeBSD, etc. Nothing is *removed*.
- **NOPASSWD sudo is required** for the host-mutating bits. The agent runs
  privileged ops non-interactively (`sudo -n`, never prompting), so the automation
  user needs NOPASSWD grants for the relevant tools — the same contract the
  manual `linux-host-setup.md` / `bsd-host-setup.md` describe (podman networking,
  `jail`/`jexec`, `vm`, `lxc-*`, `pkg`/`apt`, `zfs`, `kldload`, `sysrc`). Without
  them the self-install silently no-ops and the boot fails loudly.
- **A network switch / bridge may be created** — e.g. bhyve's `vm switch create`
  makes a host-local NAT bridge (`172.16.0.1/24`). (Caveat: vm-bhyve NAT needs
  **pf**; on an **ipfw** host the switch is created but NAT can't enable, so a
  *networked* guest can't boot there without a manual NAT — see
  `research/bhyve-networking-journey.md`.)
- **A jail base system is extracted** (`base.txz`, ~400 MB) into the jail root the
  first time a jail is booted on a FreeBSD host.
- **`/dev/kvm` / `vmm.ko`** must be available for the VM tiers (the agent loads
  `vmm` on FreeBSD; on Linux the user needs the `kvm` group — and on a systemd box
  the `--user` manager must be restarted to pick the group up).

### What persists vs. dies

- **Dies with the agent** (host reboot / `pkill`): the resident process, its
  in-memory seen-nonce cache and attack-meta, the courier key. Re-plant to restore
  — with a **fresh** key. Yes, the parent orchestrator over SSH 
- **Persists**: installed packages, created switches/bridges, extracted jail
  bases, running workloads that were launched to outlive the agent (VMs under a
  lingering scope, `daemon`-launched jails). Re-planting an agent finds and
  re-drives them idempotently (`boot` of an already-up node is a no-op).

---

## Security posture, in one paragraph

You ssh **once** to deliver the agent and a per-boot secret; after that the
control plane is HTTP-served (never ssh), authenticated by the courier key, and
its payloads AEAD-encrypted end-to-end (`AE1:` frames) with anti-replay. There is
no standing ssh credential and no interior ssh path the workload shares. The model
is **not** forward-secret (a static key derived from the PSK) and replay *within
the freshness window* is bounded but not zero — acceptable for a closed,
key-shared fleet on a synced-clock network; wrap it in an ssh tunnel or overlay if
the transport network is untrusted. See `core/threat-model.md`.
