# aeo

**Infrastructure orchestrator** — stand up and tear down a deliberate tree of
VMs and containers (FreeBSD jails + bhyve, Linux containers/LXC + KVM) from a
single Aether composition, with dependency-ordered bring-up gated on health,
reverse-order teardown that *verifies* disappearance, per-node **confinement**
(cgroups / cap-drop / network policy on Linux; rctl / jail boundary on FreeBSD),
**image attestation** (verify-before-boot, fail-closed), and a **tamper-evident
audit trail**.

## Why aeo?

**The problem**: Modern infrastructure needs to be both **declared** (reproducible,
version-controlled, diff'able) and **live** (responsive to health, capable of
rolling updates, safe to tear down). Terraform declares; Kubernetes runs live.
aeo does both from the same file.

**The promise**: A single `.ae` composition declares a tree of nodes, their
dependencies, health checks, containment policy, and attestation requirements.
`aeo up` brings it all up in parallel (respecting dependencies), health-gated.
`aeo watch` keeps it coherent. `aeo down` tears it down in reverse, verifying
each node is gone. No drift, no config creep, auditable at every step.

**The security story**: Every node runs confined (cap-drop, network-deny-default,
resource caps). Images are attested (SHA-256 verified before boot, wrong digests
refused). The audit log is tamper-evident (hash-chained). Secrets stay ciphertext
in state/logs and decrypt only at use (fail-closed on tampering or wrong key).

**Portable**: Works on Linux (podman/docker, LXC, KVM), macOS (Docker Desktop),
and FreeBSD (jails, bhyve). Same composition, different drivers — no rewrites.

```
aeo up       compose.ae      # bring the tree up, dependency-ordered, gated on health
aeo status   compose.ae      # per-node state + confinement/attestation posture (--json too)
aeo down     compose.ae      # tear down in reverse order, verifying each node is gone
aeo dry-run  compose.ae      # validate + print the plan, touch nothing
aeo check    compose.ae      # run the composition's declared check() specs, NO deploy (CI/anywhere)
aeo smoke    compose.ae      # deploy + run smoke() specs, leave the tree STANDING
aeo suite    compose.ae      # deploy + run suite() specs, then TEAR DOWN (the CI shape)
aeo audit    compose.ae      # verify the hash-chained audit trail
aeo cutover  compose.ae node  # zero-downtime blue-green: green up + confined + health-gated, alias-swap, retire blue
aeo reconcile compose.ae      # one-shot drift check: live probes vs the composition (exit 1 on drift); --converge to fix
aeo watch    compose.ae       # reconcile on a loop (default 30s) — aeo's life between up and down; --converge to act
aeo apply-node compose.ae node # small blast radius: re-render ONE node, apply only its delta, touch nothing else
aeo extract                   # reality->code: walk live containers, print a composition (attest() pre-filled); > file.ae
aeo inventory [compose.ae]    # the live walk as a table; with a composition, a "declared? yes/no" column
aeo pasta    compose.ae on   # rootless source-IP fidelity: switch the port forwarder to pasta (see docs/linux-host-setup.md)
# aeo up hands the tree to a resident aeo-supervisord BY DEFAULT (down/status ask it); --no-supervisor = today's fire-and-exit
# also: snapshot | rollback | backup | prune | exec | restart  (per-node lifecycle ops)
```

The composition file is a **pure declaration** (no `main`, no self-test scaffold) —
`aeo` is the executor, exactly as `aeb <target>.build.ae` runs a build declaration.
A composition declares its OWN verification with first-class `check()`/`smoke()`/
`suite()` verbs that name external `std.spec` specs; `aeo <phase> compose.ae` runs them.

aeo is **not** a build system and **not** an aeb SDK. It is a third sibling to
[`aether`](https://github.com/aether-lang-org/aether) (the language) and
[`aeb`](https://github.com/aether-lang-org/aeb) (the build runner). aeo is
*built by* aeb and can shell *to* aeb at runtime, across a plain artifact + CLI
seam. Its DSL philosophy is inherited from the ecosystem — **config IS code**,
closure-with-setters, no YAML — applied to live infrastructure. Its containment
thinking traces back to [The Principles of
Containment](https://paulhammant.com/2016/12/14/principles-of-containment/) (see
[below](#principles-of-containment)).

> Status: **working v0, with a live-proven containment story.** Host probe,
> drivers for Linux (podman/docker, LXC, KVM) and FreeBSD (jail, bhyve), an
> actor-based runtime, the compose DSL, host-gating fast-fail, and the `aeo`
> front-door are implemented and verified end-to-end on real infrastructure. All
> **six containment axes are now live-proven** — Linux container confinement (a
> fork-bomb refused by `--pids-limit`, a `deny_egress` node with no network),
> image attestation (a mismatched digest refused at boot), a tamper-evident audit
> trail (an edited log caught), the FreeBSD jail boundary, rctl resource caps, and
> **FreeBSD pf inter-VM delivery** — the last was long the one red axis (blamed on
> an `if_bridge` bug) but was root-caused to GhostBSD's default-enabled `ipfw`
> eating bridged packets, not pf; with ipfw off the guest bridge path, pf's
> deny-default + whitelist bites (whitelisted flow completes, non-whitelisted
> blocked), and aeo now detects + handles the ipfw conflict on `up`
> (`docs/if_bridge-pf-delivery-bug.md`). Beyond containment, aeo has grown a life
> *between* `up` and `down` — reconcile/watch, apply-node, extract/inventory, a
> `policy{}` block, and a resident **aeo-supervisor** that holds this-boot's trees
> (`docs/aeo-supervisor.md`). See [`aeo-design.md`](./aeo-design.md) for the full
> design, [`TODO.md`](./TODO.md) for the honest what's-proven-vs-modeled scorecard,
> and [`LLM.md`](./LLM.md) for the Aether constraints navigated.

## Try it in 60 seconds

All you need is the [`ae` toolchain](https://github.com/aether-lang-org/aether)
and **any container engine — podman or Docker, on Linux or macOS** (container
kinds are engine-gated, not OS-gated):

```sh
export AEO_HOME=/path/to/aeo
ae build $AEO_HOME/bin/aeo.ae -o ~/.local/bin/aeo --lib $AEO_HOME/lib

aeo doctor                                    # what can THIS host run?
docker build -t localhost/aeo-examples/silly-add:latest \
    $AEO_HOME/examples/silly_addition_app/    # the demo app image (podman works too)
aeo up examples/silly_addition_containers.ae  # redis ◄ app, dependency-ordered,
                                              # health-gated, level-parallel
curl http://localhost:8080/add/40/2           # -> 42 (the app, live)
aeo status examples/silly_addition_containers.ae   # states + attestation posture
aeo exec  examples/silly_addition_containers.ae db "redis-cli ping"
aeo down  examples/silly_addition_containers.ae    # reverse levels, disappearance VERIFIED
```

Repeat invocations are fast — the front door content-hashes its inputs (compose
+ lib/ + toolchain) and skips the rebuild when nothing changed (`AEO_REBUILD=1`
forces). `aeo doctor` reports which kinds this host can execute and what's
missing for the rest; `aeo secrets` seals values (tokens, creds) so they stay
ciphertext everywhere aeo holds state and decrypt only at use, fail-closed.

## Features at a glance

| Feature | aeo | Kubernetes | Docker Compose | Terraform |
|---------|-----|------------|-----------------|-----------|
| **Declare infrastructure** | ✅ | ✅ | ✅ | ✅ |
| **Health-gated bring-up** | ✅ | ✅ | ⚠️ basic | ❌ |
| **Verify teardown** (nodes actually gone) | ✅ | ✅ | ❌ | ❌ |
| **Per-node confinement** (cap-drop, rctl, netpolicy) | ✅ | ✅ | ⚠️ limited | ❌ |
| **Image attestation** (verify before boot, fail-closed) | ✅ | ⚠️ admission control | ❌ | ❌ |
| **Tamper-evident audit trail** | ✅ | ⚠️ event log | ❌ | ❌ |
| **Runtime reconcile/watch** | ✅ | ✅ | ❌ | ❌ |
| **Zero-downtime cutover** (blue-green) | ✅ (aeo cutover) | ✅ | ❌ | ❌ |
| **No YAML** (config IS code) | ✅ | ❌ | ❌ | ✅ |
| **VM + container substrate** (same file) | ✅ | ❌ | ❌ | ✅ |
| **Multi-OS** (Linux, macOS, FreeBSD) | ✅ | ⚠️ Linux-first | ✅ | ✅ |
| **Portable driver model** (docker/podman/lxc/bhyve/jail) | ✅ | ❌ | ⚠️ engine only | ✅ |

> Full landscape comparison — how aeo relates to cloud provisioners, config
> management, cluster orchestrators, and where it draws its boundaries on purpose:
> **[`docs/core/aeo-vs-iac-landscape.md`](docs/core/aeo-vs-iac-landscape.md)**.

> **Also see [pulumi-dart](https://github.com/kingwill101/pulumi-dart)** — a Pulumi
> SDK and language host for Dart, for similarly declarative infrastructure. It shares
> aeo's **config-is-code** stance: infrastructure declared in a real general-purpose
> language you *run*, not a YAML/HCL document a tool parses. The targets differ —
> Pulumi provisions cloud resources through provider APIs, while aeo stands up a live
> containment tree on hosts you already have — which makes them complementary rather
> than competing: provision the box with one, run the tree on it with the other.

> **Also see [TerraDart](https://terradart.dev/)** ([repo](https://github.com/nozomi-koborinai/terradart))
> — type-safe IaC for Dart, another take on declarative infrastructure. You author
> typed cloud resources in Dart and it **emits standard `*.tf.json`** for the
> `terraform apply` pipeline you already run. That is a deliberately different bet
> from aeo's: TerraDart puts a real language at the *authoring* layer and still hands
> a serialized document to Terraform, which keeps the whole existing toolchain (state,
> plan, providers); aeo keeps the language all the way to *execution* — the `.ae` IS
> the program that stands the tree up, so there is no generated artifact and no
> parse step. Same complaint about hand-written HCL/YAML, two answers to it.

## The one-line distinction

| | does | invocation |
|---|---|---|
| **aeb** | build the tree (static DAG of artifacts) | `aeb target:name` |
| **aeo** | stand the tree up and keep it coherent (live lifecycle) | `aeo up compose.ae` |

aeb is *declare-then-schedule* — its DAG is static text, `build.dep()` is a
runtime no-op. aeo is *imperative-runtime* — `vm(a).wait_for_it_to_be_up()` is
a live handle that blocks on liveness; ordering is by **health**, not by
artifact existence. aeo is the runtime-lifecycle layer aeb deliberately refuses
to have. If aeo ever needs build-graph work, it shells out to aeb.

## Design principles

**Config IS code.** The composition is pure Aether — control flow, env lookups,
conditionals — not YAML. Derive a database password from a secret key, select
container kinds based on host capabilities, loop over a fleet of nodes. This is
feature, not a bug.

**Declare, then execute.** The composition is data (a pure declaration of the
resource tree). The runner is the executor. They're separate concerns. Same
composition can be checked (dry-run), smoke-tested (deploy + test + keep), or
fully tested (deploy + test + tear down).

**Health-gated, not schedule-gated.** Bring-up waits for **health**, not just
"container started". A node is ready when *you* say it's ready (via the health
check). Teardown verifies disappearance, not just "stop signal sent".

**Portable.** Same composition runs on Linux (podman/docker/LXC/KVM) and FreeBSD
(jail/bhyve) without rewrites. Drivers are isolated; the DSL is substrate-agnostic.

**Confined by default.** Every node runs with a cap-drop floor and network-deny
default. Confinement is *declared* (you set the high-water mark), not
bolted-on post-hoc.

**Auditable.** Every step — build, bring-up, health, teardown — is logged. The
audit trail is tamper-evident (hash-chained). Secrets stay ciphertext and
decrypt only at use.

## Common patterns

**Microservices architecture** (the 60-second demo). Database tier (Redis/Postgres)
← application tier (Node/Python) ← reverse proxy. Health checks at each layer.
Confinement: app has network access to DB only; reverse proxy allows only port 80/443.

**Distributed system testing.** Spin up N nodes (broker, replicas, clients),
declare confinement (this replica can reach only these others), run your chaos
tests, tear down. Composition is the test harness. `aeo check` validates the
topology; `aeo smoke` deploys + tests + leaves it running; `aeo suite` deploys
+ tests + tears down. Same file, different phases.

**Live infrastructure (permanent)** with `aeo watch --converge`. Declare your
nodes once. aeo watches for drift (a crashed container, a failed health check),
reconciles automatically, and logs every action. Manual fixes and drift creep
become impossible.

**Blue-green deployments.** Declare version A (blue). Run `aeo up blue.ae`.
Later, declare version B (green) with `aeo cutover blue.ae app-tier`. aeo brings
up green in parallel, health-gates it, swaps the alias, retires blue. Zero
downtime, atomic.

**Compliance + audit.** Every node confined by default. Image digests attested.
Audit trail tamper-evident. `aeo audit` verifies the chain end-to-end. Meets
regulatory requirements without extra tooling.

## A composition

A composition is an ordinary Aether module that declares a resource tree by
calling the compose DSL. It exposes `aeo_orchestration()`, which the front-door
runs before bring-up. **config IS code**: the file is real Aether — control
flow, env lookups, conditionals — around the declarations.

```aether
import compose (system, container)
import compose (image, health, depends, within, every)

exports ( aeo_orchestration )

aeo_orchestration() {
    system("web") {
        health_retry() {                // health-timing knobs for the tree (see below)
            every(500ms)                // interval between probes
            up_within(30s)              // bring-up: retry health this long
            down_within(10s)            // teardown: wait this long for "gone"
        }

        // Tier 1: database
        db = container("db") {
            image("docker.io/library/postgres:16")
            health("pg_isready")
        }

        // Tier 2: app — depends on db, so db comes up (and is healthy) first
        app = container("app") {
            image("docker.io/library/myapp:latest")
            health("curl -fsS http://localhost:8080/healthz")
            depends(db)
        }
    }
}
```

The **kind is the verb** — `container(name) { ... }`, `jail(name) { ... }` — and
the opener returns a **handle** you can bind (`db = container("db") { ... }`) and
pass to `depends(db)`, so a typo'd dependency is a compile error rather than a
silent bad string. The bare-name setters inside configure that resource (its
name flows in as the block's context, so you don't repeat it). This is Aether's
trailing-block builder DSL: the call site reads like config, but the body is
full Aether (control flow, env lookups, conditionals). See
[`docs/closures-and-builder-dsl.md`](https://github.com/aether-lang-org/aether/blob/main/docs/closures-and-builder-dsl.md)
in the language repo for the mechanism.

Two import lines, the standard ecosystem idiom (cf. aeb's `import bash (script,
jobs, env)`): the openers (`container`, `jail`, …) and the block setters
(`image`, `health`, …).

`aeo up` brings `db` up and blocks until its health check passes before
starting `app`; `aeo down` stops `app` before the `db` it depends on. The
operator writes the tree once; direction is aeo's job.

Kind verbs: `container` / `lxc` / `kvm_vm` / `bwrap` / `nspawn` / `firecracker` /
`kata` (Linux), `jail` / `bhyve_vm` / `freebsd_vm` (FreeBSD). `container` is the one OCI
app-container kind; which **engine** realizes it is the `engine()` property, not a
separate kind — `engine("podman"|"docker"|"wslc"|"wsl_podman")`, system-scope
float + per-node override, auto-resolving per host (Linux → podman → docker;
Windows → wslc / podman-in-WSL). So a Linux container and a Windows-hosted one are
the *same* declaration, differing by one engine string. `bwrap` is the lightest
tier — an unprivileged bubblewrap sandbox (no root, no host setup); `nspawn` is a
systemd-nspawn system container (the systemd-native LXC peer); `firecracker` is a
minimal-device-model microVM (the "smaller VM" peer of full KVM, live-proven boot
+ persist + teardown); `kata` boots an OCI container image *inside* a lightweight
microVM (its own guest kernel — VM-grade isolation with the container API, via
containerd's Kata shim-v2; live-proven, guest kernel ≠ host). Block setters (one arg
per call — Aether is fixed-arity),
grouped by what they declare:

- **identity / lifecycle:** `image`, `command`, `entrypoint`, `dockerfile`,
  `health`, `depends`, `dataset`, `ip`, `env`, `expose`, `engine` (which OCI
  engine realizes a `container`; floats system-scope, auto per host)
- **health timing** (FluentSelenium-style duration literals), grouped in a
  `health_retry() { … }` block: `up_within(30s)` = retry-until-up window,
  `every(500ms)` = probe interval, `down_within(10s)` = retry-until-*gone* on
  teardown. (The loose form `within(30s) every(500ms) without(10s)` still works;
  `health_interval`/`health_budget` int forms remain.)
- **confinement** — `limit{}` caps (`limit_mem`, `limit_maxproc`, `limit_cpu`,
  `limit_openfiles`) and `constrain{}` (`grant_fd`, `egress`, `ingress`,
  `ingress_from`, `deny_egress`, `deny_ingress`). The *same* grammar renders to
  rctl/Capsicum/pf on FreeBSD and cgroups/seccomp/network on Linux —
  substrate-portable confinement.
- **supply chain:** `attest("sha256:…")` — pin a node's expected image digest;
  aeo verifies it before boot and refuses on mismatch.
- **device claims:** `gpu("shared"|"exclusive")` (+ optional `gpu_device(pin)`) —
  names the *contract* (container/lxc SHARE a GPU; a VM takes it EXCLUSIVELY via
  VFIO), and `aeo check` enforces the allocation (exclusive ∩ anything on one
  device fails; kind-mismatches fail). At `up` aeo probes `/etc/cdi` and prefers
  the structured CDI selector (`--device intel.com/gpu=all` — the full
  card+render+by-path bundle), falling back to the raw DRI device-map
  (`--device /dev/dri`) when no spec is present. Both proven live on a podman-6
  Intel N100. (See [`examples/cdi/`](./examples/cdi/) for a ready CDI spec.)
- **VM sizing:** `cpus`, `memory`, `nic`; **image recipes:** `from`, `install`,
  `systemd_unit`, `realize_as`, …
- **reconcile policy:** `policy(node){ reprobe_every(15s) on_drift("converge")
  reattest_every(24h) }` — per-node data that `aeo watch`/`reconcile` reads;
  `on_drift` defaults to `"alert"` (never silently mutate).

`depends` accepts either a handle (`depends(db)`) or a name string
(`depends("db")`) — handles are typo-checked, the string form is there for
references you don't have a binding for. (`resource(name, kind) { ... }` remains
as a general escape hatch.) See [`examples/`](./examples/) for twelve
compositions with the same `db ◄ app` shape across every substrate — the
substrate grid (read one, diff against another). Each example is a **pure
declaration** that names its own `check()`/`smoke()`/`suite()` verification specs;
`aeo <phase> <example>.ae` executes it.

## Performance

aeo is fast because it **parallelizes aggressively** and **caches wisely**.

**Bring-up**: Level-parallel orchestration (topological sort respecting both
`depends()` and containment edges). All nodes at the same level boot in parallel.
Health polls are batched (one OS `ps` per engine for all host containers, not per
node). A 2-node demo brings up in ~2-3s; a 9-node DAG in ~15s.

**Build cache**: The front door content-hashes the entire closure (compose + all
lib files + toolchain version) and caches the compiled binary. Repeated `aeo
status` on an unchanged composition: 3.2s (first run, compile) → 0.26s (cache
hit, 12.5× speedup).

**Teardown**: Reverse-topology, level-parallel. Nodes at the same level halt
concurrently. Tear-down of a 15-node cluster with uncooperative containers
(ignore SIGTERM) dropped from 15.6s (serial) to 6.3s (parallel) by batching stops
per engine and giving one grace period per level, not per node.

**Status probing**: A single `ps` per distinct engine (docker/podman/lxc/etc)
reports all host-visible containers, not one probe per node. On a 9-node tree:
~0.3s (batched) vs ~2.7s (one per node).

**Secrets**: O(n) encryption/decryption (HMAC-SHA256 labeled derivation + PRF-CTR
keystream on `std.strbuilder`) instead of O(n²) string concat. Native keygen
(no subprocess).

See [`TODO.md`](./TODO.md) for detailed measurements and [`aeo-design.md`](./aeo-design.md)
for the architecture.

## Running it

aeo compiles your composition into a supervised runner and executes it. Point
`AEO_HOME` at the aeo tree, then:

```
export AEO_HOME=/path/to/aeo
ae build $AEO_HOME/bin/aeo.ae -o ~/.local/bin/aeo --lib $AEO_HOME/lib
aeo up examples/silly_addition_containers.ae
```

The front-door (Decision 1B — native Aether, no bash trampoline) assembles a
build dir, `ae build`s the composition, and runs it under `os.run_supervised`
(own process group + signal forwarding + group reap). Resources are modeled as
Aether actors (Decision 2A) with a `down → booting → up` state machine and a
self-driven, `up_within`-bounded health-poll loop.

On an immutable host (e.g. a Fedora-atomic box) where `ae` isn't on the runtime
PATH, aeo builds the composition inside a toolchain container via an `ae`
container-shim — see [`docs/build-in-container.md`](./docs/build-in-container.md).
The Linux substrates (containers, KVM, LXC) are all live-proven this way.

## Host adaptation & fast-fail

aeo adapts to whether the host is BSD or Linux and **fast-fails before touching
any resource** when a composition can't run here:

- A `kind` the host can't execute (a `jail` on Linux, a `container` on BSD) is
  a loud error at composition-evaluation time, not a silent no-op three nodes
  deep.
- A `depends()` on an undeclared resource (or itself) is caught the same way.
- Capsicum/Casper enforcement consumes Aether's `std.capsicum` /
  `std.casper` `available()` contract (merged from `feat/freebsd-sandbox-parity`)
  rather than reinventing host detection — the host probe reports
  `family=bsd, capsicum=yes` on FreeBSD and `family=linux, capsicum=no` on
  Linux.

`aeo dry-run` runs all of this validation and prints the resolved bring-up plan
without starting anything — the operator's pre-flight.

## Principles of containment

aeo is, at heart, an exercise in
[The Principles of Containment](https://paulhammant.com/2016/12/14/principles-of-containment/):
the container sees and drives the contained; the contained only suspects it is
contained and cannot casually reach back unless the container configured it to;
and this should nest, restricting further at each boundary without the contained
knowing its depth. An honest scorecard of how aeo measures up today:

| Principle | aeo fit |
|---|---|
| Container sees the contained, drives it | **Strong** — aeo holds live handles and runs `up` / health-gated wait / `down` (teardown *verifies* the node is gone, not just flips a flag). |
| Contained can't casually reach the container | **Strong, control *and* data plane.** Control: a resource has no handle back to aeo. Data: `constrain{}` renders to a real deny-default — on Linux, `deny_egress` puts a node on `--network none` (no namespace — proven: it can't phone home); peer-only egress lands it on an `--internal` network (reaches its declared peer, not the internet); on FreeBSD the same grammar targets pf. |
| Reach out only where configured | **Strong** — the `image`/`command`/`env`/`expose`/`egress`/`ingress` setters _are_ the explicit, declared I/O surface; anything not declared is denied. |
| Don't starve the host | **Strong (live)** — `limit{}` renders to cgroup caps on Linux (`--memory`, `--pids-limit`: a fork-bomb is *refused*, proven) and rctl on FreeBSD (live on a jail). |
| Trust only what you pinned | **Strong (live)** — `attest("sha256:…")` verifies a node's image digest before boot, **fail-closed**: a mismatched/poisoned image is refused (proven), and the verdict is recorded in the audit trail. |
| Observe, tamper-evidently | **Strong (live)** — every confinement/attestation decision is written to a hash-chained audit log; `aeo audit` verifies the chain (an edited entry is caught, proven). |
| Authority injected, not constructed (DI) | **Strong** — the composition receives its authority to spawn from the front-door, it does not build it. Constructor injection (the [PicoContainer](https://picocontainer.com/) principle) applied to live infrastructure. |
| **Nestable; restrict at each boundary, depth-agnostic** | **Partial** — the grammar nests (`bhyve_vm("x") { container("app") { … } }`), `get_host` records the containment, the preflight gates a nested resource against its guest substrate, and the nest **executes** (a container inside a bhyve/KVM VM is built+run in the guest — see the `*_podman` demos). What's not yet built is *recursive depth-agnostic* nesting — see below. |

So aeo is a faithful realization of the post's **directionality and injection**
principles — arguably more so than some of the post's own exhibits, because
Aether's native capability model closes the "subvert IoC from within" hole the
post laments in the DOM. The **isolation** principles — don't-reach-out,
don't-starve, trust-what-you-pinned, observe — are now *enforced and live-proven*
on Linux (cgroups / cap-drop / `--internal` networks / digest attestation /
audit), from one substrate-portable grammar that also targets FreeBSD's
rctl/Capsicum/pf. Its **nesting** — the principle the post treats as defining —
executes one level (container-in-VM), but the *recursive, depth-agnostic* form is
still ahead. Closing that is **aeo-agent** (`docs/aeo-agent.md`): rather than aeo
reaching _through_ a boundary (ssh-ing in — the directionality the post calls a
disaster), the container hands its contained an agent, and that agent carries
orchestration deeper — receiving the instructions for its node and everything
below it, and in turn handing instructions to _its_ children's agents. Same
actor protocol at every level, so no node knows its depth — exactly the post's
"further restricted without knowledge of its nesting depth." That build takes aeo
from "the principles, live on one level" to "the post, recursively implemented."

## Layout

```
bin/aeo.ae            the front-door CLI (codegen + supervised run + subcommands)
lib/aeo/runner.ae     the fixed runner: the resource actor + bring-up/teardown engine
lib/compose/          the operator-facing compose DSL (config IS code)
lib/driver_linux/     podman/docker backend (build/run/probe + the confinement flags)
lib/driver_lxc/       real LXC system-container backend (lxc-create/start/attach)
lib/driver_bwrap/     unprivileged bubblewrap sandbox backend (rootless; pidfile-tracked)
lib/driver_nspawn/    systemd-nspawn system-container backend (machined-managed; self-sudo)
lib/driver_firecracker/  Firecracker microVM backend (config-file boot; pidfile-tracked)
lib/driver_kata/      Kata Containers backend — an OCI image in a microVM (nerdctl + containerd kata shim-v2)
lib/driver_vm/        KVM/qemu (Linux) + bhyve (FreeBSD) VM backend
lib/driver_bsd/       FreeBSD jail backend (jail/jexec/jls over a ZFS dataset)
lib/driver_stub/      fail-loud arm for unsupported host/kind
lib/confine_linux/    Linux confinement renderer: limit{}/constrain{} → cgroup/seccomp/net flags
lib/rctl/  lib/pf/     FreeBSD confinement: rctl resource caps + pf network policy
lib/attest/           image attestation (verify-before-boot, fail-closed; 3 greppable states)
lib/audit/            tamper-evident hash-chained audit trail (`aeo audit`)
lib/secrets/          sealed values (`aeo secrets`): ciphertext-throughout, decrypt-at-boundary
lib/snapshot/  lib/snapshot_linux/   lifecycle ops: ZFS (jail/bhyve) + podman/qemu-img/lxc
lib/host/             host-profile probe + capsicum/casper gating
lib/ipam/  lib/images/  IP allocation + the golden-image recipe/realizer
lib/resource/         the actor↔main state bridge
lib/driver_windows/  lib/driver_wslc/   Windows OCI engines (podman-in-WSL2 / MSFT's native wslc.exe)
examples/             the substrate grid — twelve `db ◄ app` compositions (see examples/README.md)
examples/checks/      the per-example check()/smoke()/suite() std.spec specs
lib/reconcile/        desired-vs-actual property diff (drift detection under `aeo watch`/`reconcile`)
lib/extract/          reality->code emitter (`aeo extract`/`inventory` — live containers to a composition)
lib/supervisor/       the in-memory tree registry the aeo-supervisord daemon holds (this-boot's trees)
bin/aeo-supervisord   resident holder of this-boot's trees; `aeo up` adopts by default (`--no-supervisor` opts out)
bin/aeo-supervisor-install.sh  install aeo-supervisord as a boot service per init (systemd/OpenRC/rc.d, Restart=no)
test/                 ~48 specs (fluent std.spec style): driver/confinement/attest/audit/lifecycle/gpu/pasta/reconcile/policy/extract/conformance/ipfw/supervisor/kata + real-jail
test/conformance-behavioral.sh  the live driver-conformance lifecycle (create->probe->confine->stop->verify-gone) per substrate
```

## What aeo is NOT

Not a build (it `pkg install`s / pulls images, it doesn't compile — shell out to
aeb for that). Not multi-host by default (every node is local unless a future
`host(...)` control-plane form is used). Not YAML — the composition *is* the
config, full Aether underneath. Don't add a config-file parser; expose setters.
