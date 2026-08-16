# aeo — primer & purpose guide

Two audiences, one file. **For an LLM (me or a cousin) picking up work on aeo:**
this is the orient-fast primer — what aeo is, how it's shaped, the invariants
that keep it coherent, the footguns. Re-read at the start of every session. **For
an observer wanting to *use* aeo for its purpose:** the "What aeo is for" and "A
composition, end to end" sections are your entry; the rest is the engine room.

Not a CLAUDE.md. Short, opinionated, current as of ae 0.545.0 (2026-08-16).
`AETHER_PIN` floor is 0.545.0 — the specs call std.spec's skip verbs.

---

## What aeo is for

aeo is an **infrastructure orchestrator**: from a single Aether composition it
stands up, keeps coherent, and tears down a deliberate *tree* of compute nodes —
FreeBSD jails + bhyve VMs, Linux podman/docker containers + LXC system containers
+ KVM VMs. Dependency-ordered bring-up gated on **health**, reverse-order teardown
that **verifies** each node is gone.

Its *purpose* — the thing it's actually for, not just what it does — is
**orchestrated trees of compute nodes that contain malware and are impregnable to
attack.** Every node can be **confined** (resource caps so it can't starve the
host; cap-drop/seccomp so it can't escalate; a deny-default network so it can't
phone home), **attested** (its image digest verified before boot, fail-closed),
and **audited** (every security decision written to a tamper-evident hash chain).
The confinement grammar is *substrate-portable*: one `limit{}` + `constrain{}`
vocabulary renders to FreeBSD rctl/Capsicum/pf **and** Linux cgroups/seccomp/
network. This is "infrastructure as a containment hierarchy," tracing to
[The Principles of Containment](https://paulhammant.com/2016/12/14/principles-of-containment/).

aeo is the third sibling to `aether` (the language) and `aeb` (the build runner),
born spun-out. **config IS code** — the composition is a `.ae` you *run*, full
Aether around the declarations; no YAML, ever.

## Status (honest, ae 0.545.0)

Working, with a **live-proven containment story** AND a **live-proven resident-agent
story** (see the aeo-agent note below). Of six containment axes, **all six are
live-proven on real hardware** (a rootless Fedora-atomic "Bazzite" box for Linux, a
GhostBSD box for FreeBSD, plus macOS via Docker Desktop):

| Axis | State |
|---|---|
| Linux container confinement (cgroups / cap-drop / netpolicy) | ✅ live — fork-bomb refused by `--pids-limit`; `deny_egress` node has no network |
| Image attestation (verify-before-boot, fail-closed) | ✅ live — a mismatched digest is refused at boot |
| Audit trail (tamper-evident hash chain) | ✅ live — an edited log is caught by `aeo audit` |
| FreeBSD jail boundary | ✅ live on GhostBSD |
| rctl resource caps | ✅ live on GhostBSD |
| pf inter-VM network delivery | ✅ live on FreeBSD 14.3 — deny-default + whitelist bites (whitelisted flow completes, non-whitelisted blocked). The old "red axis / if_bridge bug" was a MIS-ATTRIBUTION: GhostBSD's default-enabled `ipfw` was dropping the bridged packet, not pf. Fix = keep ipfw off the guest bridge path (`docs/research/bhyve-networking-journey.md`). |

Drivers all exist and the Linux ones (`containers`/`lxc`/`kvm`) are live-proven
end-to-end via `aeo up` on Bazzite. The front-door, the actor runtime, the compose
DSL, host-gating, lifecycle ops (snapshot/rollback/backup/prune/exec/restart), and
the audit trail are all built. See `TODO.md` for the per-item proven-vs-modeled
scorecard, `docs/core/design-rationale.md` for the design, `README.md` for the
user-facing tour.

**aeo-agent (resident deputy) — SHIPPED, not drafted.** The recursive-orchestration
story is now live, not design-intent: the agent runs the node's lifecycle
(`boot/probe/halt`) over **HTTP** with an **AEAD-encrypted channel** (`lib/secure_channel`,
Ascon-AEAD128, courier-PSK-keyed, single-use + anti-replay + attack-meta), and each
substrate **self-installs its engine** when absent (`host.pkg_install` across
apt/dnf/apk/pkg/brew; jail base.txz; vm-bhyve init). One ssh plants the agent; then
everything — install, deploy, tear down — flows through the sealed channel. Proven
end-to-end on a Pi 5 (podman + lxc), a Pi Zero 2 W (host-exec on ~415MB), and
GhostBSD .204 (jails; vm-bhyve setup). Released binaries per OS/arch,
SHA-pinned. **The full host lifecycle is documented in
`operations/agent-host-setup.md`** (ssh-plant → self-install → sealed dispatch; what
mutates on the host; why nothing but the one binary is shipped).

## The one thing to never get wrong: aeo is NOT aeb

The load-bearing distinction. Burn it in:

- **aeb is declare-then-schedule.** Its DAG is static text, grep-extracted before
  any `.ae` runs; `build.dep()` is a runtime no-op; nodes are isolated subprocesses
  coordinating via on-disk markers.
- **aeo is imperative-runtime.** A resource handle is a *live reference in one
  running process*; a node comes up and aeo **blocks on its health** before the
  next; ordering is by health, not by artifact existence; teardown is a reverse
  walk that verifies disappearance.

**If you ever want to give aeo a static DAG / topo-sort / build cache — STOP. That
is aeb's job; aeo shells out to aeb for it.** The moment aeo reimplements a static
DAG it has become a second aeb and the factoring rots. aeo's value is *only* the
runtime layer.

| | aeb | aeo |
|---|---|---|
| grain | static DAG of artifacts | imperative orchestration of live nodes |
| dep | data (runtime no-op) | runtime reference (live) |
| time | build-time | run-time lifecycle (up / healthy / confined / down) |
| invoke | `aeb target:name` | `aeo up compose.ae` |
| one-liner | "build the tree" | "stand the tree up, keep it coherent, contain it" |

## A composition, end to end

A composition is an ordinary Aether module exporting `aeo_orchestration()` (no
args — the front-door calls it). The kind is the verb; the block configures it.

```aether
import compose (system, container)
import compose (image, health, depends, health_retry, every, up_within, down_within, limit, limit_maxproc, constrain, deny_egress, attest)
exports ( aeo_orchestration )

aeo_orchestration() {
    system("web") {
        health_retry() {                       // health-timing knobs, one block
            every(500ms)                       // interval between probes
            up_within(30s)                     // bring-up: retry health this long
            down_within(10s)                   // teardown: wait this long for "gone"
        }

        db = container("db") {
            image("docker.io/library/redis:alpine")
            attest("sha256:cd5f3ac…")      // refuse to boot a mismatched image
            health("redis-cli ping")
            limit("db") { limit_maxproc(32) }      // cgroup fork-bomb ceiling
            constrain("db") { deny_egress() }       // -> --network none, can't phone home
        }
        app = container("app") {
            image("docker.io/library/myapp:latest")
            health("curl -fsS localhost:8080/healthz")
            depends(db)                    // db up + healthy before app starts
        }
    }
}
```

`aeo up` brings `db` up, blocks on its health, then `app`; `aeo down` stops `app`
before `db` and verifies each is gone. Two import lines (openers + setters) is the
ecosystem idiom. **Kind verbs:** `container`/`docker`/`lxc`/`kvm_vm` (Linux),
`jail`/`bhyve_vm`/`freebsd_vm` (FreeBSD). Setters are **single-arg** (Aether is
fixed-arity — repeat the call for more). `depends` takes a handle (typo-checked)
or a name string.

The `examples/silly_addition_*.ae` are the canonical surface — the same `db ◄ app`
app across every substrate (the "substrate grid"). Read one, diff another. They are
**PURE COMPOSITIONS** — declaration only, no `main()`, no self-test scaffold (like
aeb's `.build.ae`). Each declares its nodes AND its own verification via first-class
`check()`/`smoke()`/`suite()` verbs that NAME external `std.spec` specs:

```
system("silly_addition_containers") {
    container("db")  { image("…redis…"); health("redis-cli ping") }
    container("app") { image("localhost/aeo-examples/silly-add:latest"); depends("db") }
    check("examples/checks/containers_model.spec.ae")   // data-model, NO deploy
    smoke("examples/checks/containers_smoke.spec.ae")   // deploy + probe, leave up
    suite("examples/checks/containers_suite.spec.ae")   // deploy + probe, tear down
}
```

`aeo` is the executor (never `ae run <example>`; the file is not a program):
`aeo up|down|check|smoke|suite <compose.ae>`. `check` runs the spec(s) with NO
deploy (anywhere); `smoke` deploys then runs the spec(s), leaves standing; `suite`
deploys, runs, then tears down (CI shape). The runner runs each spec as a SUBPROCESS
(`ae run <spec>`), so the test framework stays OUT of the lean orchestration binary. Application
source lives in `examples/silly_addition_app/` (a prebuilt image the compositions
reference by tag) — NOT inline: the composition is orchestration, not an app.

## How it's built — the shape that matters

```
bin/aeo.ae         front-door CLI: stages a build dir, `ae build`s the composition,
                   runs it under os.run_supervised. Subcommands: up|down|status|
                   dry-run|snapshot|rollback|exec|restart|backup|prune|audit.
lib/aeo/runner.ae  the fixed runner: the resource ACTOR + bring-up/teardown engine.
lib/compose/       the operator DSL (config IS code). All grammar + getters.
lib/driver_linux/  podman/docker: build/run/probe + the confinement flags.
lib/driver_lxc/    real LXC (lxc-create/start/attach) — system containers.
lib/driver_vm/     KVM/qemu (Linux) + bhyve (FreeBSD).
lib/driver_bsd/    FreeBSD jail (jail/jexec/jls over a ZFS dataset).
lib/confine_linux/ limit{}/constrain{} -> cgroup/seccomp/network flags (the Linux peer).
lib/rctl/ lib/pf/  FreeBSD confinement: rctl caps + pf network policy.
lib/attest/        image attestation (verify-before-boot, 3 greppable states).
lib/audit/         tamper-evident hash-chained audit trail.
lib/secrets/       SEALED values (aeo1 envelope): ciphertext in state/env/logs,
                   plaintext only at the use boundary via resolve(), fail-closed.
                   `aeo secrets keygen|seal|unseal`. NB `seal` is RESERVED —
                   hence seal_value/unseal_value.
lib/snapshot/ lib/snapshot_linux/   lifecycle ops (ZFS ; podman/qemu-img/lxc).
lib/host/          host-profile probe + capsicum/casper gating.
lib/ipam/ lib/images/   IP allocation + golden-image recipe/realizer.
lib/resource/      the actor↔main STATE BRIDGE.
```

### The front-door codegen (a real Aether constraint, load-bearing)

**Aether actors are single-compilation-unit only.** `actor`/`message` defs and
their `spawn`/`!` sites must live in the file with `main`; they do NOT cross
`import`. So the resource actor can't be a plain importable lib. The front-door
(`bin/aeo.ae`) therefore **stages a build dir**: it copies `lib/` in, installs the
operator's compose file as the `aeo_compose` module, copies `lib/aeo/runner.ae`
(which contains the inlined actor + `main`) as the top-level entry, and `ae build`s
that single unit. `examples/` files are the hand-written shape of what gets staged.
On an immutable host where `ae` isn't on PATH, an `ae` container-shim builds it
inside a toolchain container (`docs/operations/build-in-container.md`).

### State, never in a module `var`

ALL ambient / cross-module state goes through **`std.config`** (the C-extern
process-global KV) — never an Aether module-level `var`. `cursystem`/`curhost`,
the within/without float snapshots, node state, audit inputs: all `config.*`. This
is load-bearing: Aether's module `var` had a string of cross-import soundness bugs
(#929/#937) that aeo dodged *only* because it routes ambient state through config.
**Rule: ambient/cross-module/"current context" state = config, never a `var`.**

## Footguns (Aether constraints that will bite)

- **Reserved words** trip the parser: `state`, `match`, `message`, `receive`,
  `after`, **`spawn`** (the actor keyword — `spawn = "…"` parses as `spawn(` and
  errors "Expected LEFT_PAREN, got ASSIGN"; this bit driver_bwrap, a *non-actor*
  file, where a local was named `spawn`). Rename locals (`st`, `msg`, `spwn`).
- **`list_get` returns a ptr; `"${a}"` on it yields the ADDRESS, not the string.**
  To shell argv, pass the list DIRECTLY to `run_capture(prog, list)` (like
  driver_vm/driver_lxc), or `list_get_raw` + `list_add_raw` to copy element ptrs.
  Interpolating a list element into a command string silently mangles it. (Bit
  driver_lxc; driver_bsd's `_sudo_run` had it too — fixed, all self-sudo paths
  are argv-direct now. Passing a raw element ptr as a string-typed FUNCTION ARG
  is fine — only direct interpolation mangles.)
- **Nested string literals inside `${}` don't parse** — `"${f("x")}"` errors
  (sometimes as a bogus type error, e.g. "Undefined variable 'docker'"). Assign
  to a var first: `r = f("x"); "${r}"`.
- **Backslash escapes differ between INTERPOLATED and plain strings**: in a
  string containing `${}`, `\\n` collapses to a REAL newline; in a plain string
  it stays a literal backslash-n (driver_vm's cloud-init printf lines depend on
  the plain behaviour). A `tr '\\n' ...` inside an interpolated command string
  handed the shell an unbalanced quote. Rule: keep interpolated command strings
  BACKSLASH-FREE (`\"` is fine; verified).
- **Heredocs `<<TAG` are RAW** — no `${}` interpolation inside.
- **`getenv` for an unset var returns an empty string that `== ""` reports as
  FALSE** — `string_length(v) == 0` is true, yet `v == ""` is *false* (so a
  `== ""` default-guard silently never fires). Always guard with
  `string_length(v) == 0`, never `== ""`. (This bit `bin/aeo.ae`: the AEO_WORK
  default never applied → `aeo up` died with `cp: cannot create directory ''`.)
  **`os_which` has the same trap, worse**: a missing binary returns NULL (not
  ""), NULL passes `!= ""`, and interpolating it prints `(null)`. This bit
  driver_linux.engine_resolve — every docker-only host (no podman) ran
  `(null) run ...` exit-127, which ALSO made the two real-container specs
  silently skip-as-pass. Guard `== null` (or string_length), the way
  driver_bwrap/driver_firecracker's available() do.
- **Multi-return is one-call destructure only** — `a, b = f()`. Don't chain.
- **Duration literals** (`30s`, `500ms`) are i64 ns; `/ 1000000` → ms (`as int` is
  rejected, `/` works). Used by within/every/without.
- **Selective imports + compiler-emitted qualified calls (FIXED in ae 0.364).**
  On ae ≤ 0.338 a selective-only `import std.string`/`import std.os` could leave
  COMPILER-EMITTED qualified calls unresolved (`string.copy` for some
  string-return shapes; `os_platform` via a transitively-imported `platform()`;
  aeocha's `os.now_monotonic_ns`), and the fix was a bare `import std.string` /
  `import std.os` beside the selective one. **ae 0.364 resolves this** — every
  such bare-import crutch has been removed from the tree, and `bin/aeo.ae` uses
  qualified `os.*` calls (cleaner than the workaround). If you're on an older
  toolchain and hit a phantom `string.copy`/`os_platform`, upgrade
  (`~/scm/aether && ./install.sh`) rather than re-adding the bare import.
- **`seal` is a reserved word** (the compiler says so; `unseal` is NOT —
  verified). lib/secrets uses `seal_value`/`unseal_value`.
- **Aether's std.http.client SIGABRTs intermittently on macOS** (mid-request).
  Specs that only need transport shell out to curl.
- **Name http handlers with a TRAILING underscore (`h_health_`), not a
  leading one** — and keep it that way. On ae ≤ 0.542 a leading-underscore
  top-level function *passed as a value* (a function pointer) did not
  compile: the DEFINITION was renamed `_h_health` → `ae_h_health` (C's
  reserved namespace) but only CALL sites were rewritten, so the pointer
  reference dangled — `'_h_health' undeclared … did you mean 'ae_h_health'?`,
  an error naming a symbol you never wrote. It blocked `bin/aeo-agent.ae` +
  `bin/aeo-supervisord.ae` on the 0.541 upgrade. **aether#1598 — FIXED in
  0.543.0** (aeo reported it; the fix also caught a nastier twin, where an
  extern-collision rename bound to the real libc symbol, linked clean and
  SEGFAULTED at runtime). aeo does **not** revert to the leading form:
  aether's own `docs/c-interop.md` names the trailing convention (#279) as
  idiomatic, and reverting would raise our pin floor to 0.543.0 for no gain.
- **A selective import of `std.http.client.httptest` does NOT work** —
  `import std.http.client.httptest (expect_http_get_body_eq, within, …)`
  leaves the module's own retry-state vars (`httptest_retry_poll_ns`,
  `httptest_retry_budget_ns`, `httptest_retry_without`) unresolved at
  E0300. Use the BARE `import std.http.client.httptest`. (Bit the four
  HTTP-shaped example checks during the aeocha→std.spec migration.)

### Testing: `std.spec`, not aeocha (changed 2026-08-15)

**aeocha is GONE — absorbed into the Aether stdlib; the repo is retired.**
There is no sibling checkout, no `AEOCHA=` env var, no extra `--lib`:

| was | now |
|---|---|
| `import aeocha` | `import std.spec` (then `spec.init`, `spec.describe`, `spec.it`, …) |
| `aeocha.expect_http_*` | bare `import std.http.client.httptest` → `httptest.expect_http_*` |
| process matchers | `std.os.testing` |
| `--lib ~/aeocha` | nothing — it's stdlib |

`sh test/run-spec.sh` needs only aeo's own `lib/`. **`AETHER_PIN` (0.541.0)
is the floor** — std.spec landed in 0.538.0, so an older `ae` cannot compile
the suite at all; run-spec.sh warns up front rather than letting you read 48
files of `Undefined variable 'spec'`.

**Fluent matchers take an optional "why" message (aether#1576 — LANDED in
0.542.0).** aeo asked for this: `expected 'x', got 'y'` states the values but
not the rule, which is what a failing-CI triager needs.

```aether
spec.expect_str(egress_fqdn_csv("python_vm")).to_equal_str(want,
    "a node's egress FQDN set is exactly its declared whitelist")
```

It is **optional** (Aether default args resolve through UFCS chaining), so
aeo's ~810 existing message-less sites compile and pass untouched — verified,
48 files / 304 assertions / 0 failures on 0.542.0. **No sweep is needed or
wanted**: add a message where it carries a rule the values can't, at whatever
pace. `to_equal_str` also now prints the caret-aligned diff once either string
hits 24 chars, so **78 of aeo's 477 `to_equal_str` sites got better failure
output with no edit at all**.

The why-message did **not** move the pin (it is backward compatible). The SKIP
VERBS did — see below. Write a why-message freely; it needs 0.542.0 and the
floor is already past that.

### Honest skips, never a fake pass (std.spec skip verbs, 0.545.0)

**A spec whose dependency is absent must report `⊘ skipped`, NOT a pass.**

```aether
spec.it_when(avail, "the LB answers on its publish() port", "aeo-lb image absent") callback { … }
spec.skip_it("every breakout class is denied by the kernel", "needs a FreeBSD kernel") callback { … }
```

A skipped body does not run, counts in neither passed nor failed, prints its
reason, and leaves the exit code 0 — so an environment gap stays green in CI
without pretending anything was verified.

**The anti-pattern this replaced, which is banned:** gating on an always-true
assertion (`expect_int(1).to_be_truthy()`, `expect_int(1).to_equal(1)`) or a
helper that returns "pass" when its harness is missing (the old `_ok()` in
`spec_egress_splice_live`). Four specs did this; a box lacking the dependency
reported *"3 passing"* having exercised **nothing**, and was indistinguishable
from a box that genuinely passed. That is a direct breach of **"don't
overclaim live"**, and it was sitting inside the containment specs — the ones
whose entire purpose is to substantiate a security claim. If you catch
yourself writing an assertion that cannot fail, you want `it_when`.

Converted: `spec_egress_splice_live`, `spec_driver_loadbalancer_live`,
`spec_capsicum_breakout`, `spec_capsicum_bhyve_model`. **This is why
`AETHER_PIN` is 0.545.0** — an older `ae` has no `it_when`/`skip_it` at all.

### Agent / deployment footguns (operational, cost real session time)

- **`pkill -x aeo-agent`, NEVER `pkill -f /tmp/aeo-agent`.** `-f` matches the whole
  command line — including your *own ssh command* that contains the path — so it
  leaves the real agent alive holding the port; the next agent then fails
  `server_create` and exits, looking like a mystery crash. (Burned ~an hour on a Pi
  5 chasing this phantom.)
- **The sealed channel's ±30 s freshness window needs synced clocks.** A host an
  hour off (a BST-vs-UTC mix-up on .204) rejects *every* sealed frame as `stale` —
  indistinguishable from an auth failure at a glance. Sync first
  (`sudo date -r <epoch>` / ntpdate) before dispatching. Meta says `stale=N`.
- **Detach properly or the agent dies with the login session.** Linux:
  `systemd-run --user` (+ `loginctl enable-linger`); FreeBSD: `daemon(8)`. A bare
  `setsid … &` can be reaped. On a flaky link, fire long ops **detached +
  poll-a-logfile** rather than holding an interactive ssh.
- **A firewall may block inbound on `AEO_PORT`** (a FreeBSD ipfw box did). Bind
  loopback + reach it through an ssh tunnel (`ssh -L …`) — the AEAD is still
  end-to-end. Don't punch firewall holes on a console-less box (pf-lockout risk).
- **vm-bhyve NAT needs pf; on an ipfw host the switch is created but NAT can't
  enable** — a networked bhyve guest can't boot there. Jails have no such issue.

## DSL conventions (don't fight them)

- **config IS code.** Composition is a `.ae` you run. NEVER add a YAML/JSON/HCL
  parser. External formats only via shell-out.
- **closure-with-setters**, single-arg, pure accumulation into the compose KV.
- **`os.run_capture(prog, argv, env)`** is the canonical spawn primitive every
  driver shells through (argv-based, no shell, binary-safe).
- **Drivers self-sudo where they need privilege**: `sudo -n <prog> …` so the aeo
  binary needn't be root (the operator pre-grants specific binaries NOPASSWD).

> **Academic precedent (cite, don't depend on):** Weiher/Taeumel/Hirschfeld,
> *Beyond Procedure Calls as Component Glue* (Onward! '24,
> doi:10.1145/3689492.3690052) is the canonical academic backing for
> config-IS-code-for-infra. Listings 41/42 are directory-sync-as-program where the
> *only* difference between the local and remote case is an `SSHConnection` store
> handle — aeo's substrate-portability pitch (one composition, local/remote differ
> by a handle), two years early. §8.7 (Plan 9 / "packaging mismatch") is the sharp
> argument for routing through a `.ae` rather than YAML-over-a-CLI: an OS-mediated
> abstraction "requires serialized representations, which have to be parsed,
> generated and accessed via the POSIX APIs … a form of packaging mismatch."
> **Where aeo diverges — the part that's genuinely ours:** Objective-S gets this
> via a polymorphic connection operator `→` backed by a metaobject protocol; its
> remote story (L42) is plain `SSHConnection` remote *filesystem* sync over SFTP
> (no containment boundary — just remote directory sync, holding the credentials).
> aeo's contribution is **not** a directionality flip (containment *always*
> allowed the container to orchestrate the contained; what it forbids is the
> *contained's workload* chatting back up — "I'll have four more deps please").
> aeo's contribution is the **resident-deputy** shape: `lib/protocol/` +
> `aeo-agent` (`bin/aeo-agent.ae`) keep the paper's best idea — *a stable verb set
> with a replaceable transport beneath it* (`boot/halt/probe/announce/report` over
> `transport_file` or `transport_http` on `std.http.server` — NOT ssh; ssh is
> bootstrap-only): a metaobject protocol in miniature — and put it inside the node
> as the **container's deputy**. The agent enacts the container's will + reports
> health, but exposes **zero ABI surface to the node's other processes** (the
> workload gets no upward channel through it) and the parent channel is
> **AEAD-encrypted** (`lib/secure_channel`, pure-Aether Ascon-AEAD128 + HKDF) keyed
> by an **ssh-couriered one-time symmetric secret — the 1970s bank-courier model,
> no CA, no keypair** (ssh is the motorbike: bootstrap hand-delivers the key). This
> is **shipped, not designed** — HTTP transport, the sealed channel (single-use +
> freshness window + attack-meta piggyback), and per-dispatch substrate kinds are
> all live-proven; see the status table above and `operations/agent-host-setup.md`.
> The agent IS the standing live connection the paper describes via `→`, made
> concrete *and* containment-safe (workload can't speak on it, can't forge onto
> it). The runner is just the depth-0 agent. The front door still has **no `→`
> operator** and shells to aeb for static structure.
> (See `development/aeo-agent.md` for the design, `operations/agent-host-setup.md`
> for the ssh-plant → self-install → sealed-dispatch host lifecycle.)

> Historical note: early design docs (and old versions of this file) describe a
> `cap` threaded through every handle — `jail(cap, "db")`, `aeo(cap)` DI. That
> was the intended capability-injection shape; it is **not built** — today's
> openers are `kind(name){…}` and `aeo_orchestration()` takes no cap. Treat the
> `cap`/`require_capsicum()`/`prefer_capsicum()` grammar in older docs as
> aspirational, not current.

## The seam to aeb

Boring on purpose: **artifacts on disk + a CLI invocation.** aeb produces an
image/disk in `target/<module>/`; aeo boots a node around it. Mid-composition, aeo
can `run_capture("aeb", ["app:image"], env)` to build something it then deploys.
Don't over-engineer this into an in-process binding.

## Repo topology & invariants

```
~/scm/aether   the language; produces `ae`, `aetherc`, libaether.a
~/scm/aeb      build runner; built from Aether
~/scm/aeo      THIS repo; its own binary; built BY aeb (or `ae build`); calls aeb at runtime
(no aeocha checkout — the test framework is `std.spec`, IN the Aether stdlib)
```

- aeo's binary is emitted from THIS repo, never aeb's (keeps infra backends out of
  aeb's core). Edges: build-time + run-time aeo→aeb. **No cycle.**
- Link line is always `$(ae cflags)` — never hand-crafted `-I`/`-L`/`-laether`.
- aeo is substrate-agnostic at the core — never hardcode one backend as "the" one.

## What NOT to do

- Don't give aeo a static DAG / topo-sort / build cache → that's aeb. Shell out.
- Don't add a config-file parser → composition is `.ae`.
- Don't put aeo's binary/build in the aeb repo.
- Don't hold ambient state in a module `var` → use `std.config`.
- Don't interpolate a `list_get` ptr into a command string → pass the list to
  `run_capture`, or use `list_*_raw`.
- Don't hand-craft Aether link flags → `$(ae cflags)`.
- Don't reinvent host detection → consume `std.capsicum.available()` etc.
- Don't put `main()`/`AEO_MODE`/self-test scaffold in a compose example → examples
  are PURE declarations; `aeo <phase> <file>` executes them, and verification is
  declared via `check()`/`smoke()`/`suite()` naming external specs (like aeb's
  `.build.ae`). (This replaced the old all-in-one AEO_MODE scaffold.)
- Don't overclaim "live" → keep the proven-vs-modeled discipline; say which box,
  which date, what was actually run.

## Git

`main` with two remotes: `origin` (SSH, git@github.com:aether-lang-org/aeo.git)
and `origin2` (HTTPS, same repo). **When port 22 is blocked** (some networks),
push via `origin2` — `gh auth setup-git` wires the credential helper. End commit
messages with:
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
