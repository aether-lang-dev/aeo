# Built-in load balancing in aeo — considered (design, BUILT + live-proven)

**STATUS: BUILT + LIVE-PROVEN (steps 1–3).** `aeo up` provisions a working L7
load balancer end to end on real podman: **weighted split** (3:1 observed
exactly), **health-eject** (a stopped backend drops from rotation), and **backend
isolation** (backends are NXDOMAIN + IP-unreachable from the host; only the LB's
`publish()` port is the pinhole). See §9 for the proof and the two architecture
findings it forced.

§9 steps 1, 2 AND 3 have landed:
- **Step 1** — the compose grammar (`load_balancer`, `publish`/`listens`,
  `balance_to { algorithm / lb_health }`, `balancer_weight`), model accessors
  (`lb_backends`, `lb_algorithm`, `lb_weight_ignored`), and model-check rules
  (`lb_model_errors` — the three §3/§4 checks) in `lib/compose`
  (`test/spec_load_balancer.ae`, 12 passing).
- **Step 2** — `aeo up` now PROVISIONS a `load_balancer` node: `lib/driver_loadbalancer`
  renders the pool from the model and backgrounds the `bin/aeo-lb` front-door (an
  `std.http.proxy` reverse proxy), wired into the runner's driver_up/down/probe.
  Renderers unit-tested (`test/spec_driver_loadbalancer.ae`, 4 passing) and the
  up→answers→down lifecycle live-proven through the real binary
  (`test/spec_driver_loadbalancer_live.ae`, 3 passing). The datapath itself
  (weighted split + health-eject) was proven live via `bin/aeo-lb` directly.

Remaining: a full deploy-and-route example proof on CachyOS/Bazzite (step 3 — two
real backends, weighted split observed, health-eject observed, backend not
directly reachable). This note captures the design of an aeo-native HTTP load
balancer: a `load_balancer` node that *contains* its backends, derives its pool
from the containment tree, and lowers onto Aether's already-shipped
`std.http.proxy` (nginx-class reverse proxy — weighted RR, active health checks,
drain/undrain, circuit breaker, LRU cache). Written 2026-07-10.

The guiding discipline is the same one that governs `egress_fqdn`
([egress-fqdn-considered.md](research/egress-fqdn-considered.md)): **the model may
record intent, but it must never let you *say* something it will silently not
*do*.** Several decisions below fall directly out of that rule.

---

## 1. The shape: a balancer *contains* its backends

The balancer is not a config block that lists upstreams by string (nginx's
`upstream {}`, an ELB target group). It is a **node with children**, and the pool
membership *is* the set of children:

```
aeo_orchestration() {
    system("silly_addition_containers") {
        health_retry() {
            every(500ms)
            up_within(30s)
            down_within(10s)
        }

        load_balancer("web", :container) {
            publish(9000)
            balance_to(8080) {
                algorithm(weighted_rr)     // optional; inferred (see §5)
                health("/healthz", expect: 200)
            }
            container("app-1") { listens(8080); balancer_weight(3) }
            container("app-2") { listens(8080); balancer_weight(1) }
        }

        check("checks/containers_model.spec.ae")
        smoke("checks/containers_smoke.spec.ae")
        suite("checks/containers_suite.spec.ae")
    }
}
```

This is the aeo grain: a balancer that fans requests to its children **is**
acts-inside/reports-outward. It is strictly better than a dead upstream string,
because the upstream list can no longer drift from reality — the backends *are*
the children, and aeo reads their declared ports directly. If `app-1` says
`listens(8080)` and `app-2` says `listens(9090)`, that is a **model-check error**
("balancer 'web' forwards to 8080 but backend 'app-2' listens on 9090"), not a
runtime 502.

### `load_balancer` is a node with its own identity

The block above defines *what is balanced*; the `("web", :container)` head defines
*the balancer node itself*. This matters: the children are backends, but the
balancer is a **different node** that aeo must provision, that gets an IP, that
binds a port, and that peers resolve to. `egress("web", 9000)` from elsewhere in
the system must have something to resolve to — that something is the `web` node.

So `load_balancer` is a new shape in the tree: **a node with children** (every
other aeo node today is a leaf). That is the real structural decision here.

---

## 2. Two faces, two directions: `publish` vs `listens`

Docker's `-p 8080:80` conflates two unrelated facts — *the port the process binds*
(a workload fact) and *the port the outside reaches it on* (a boundary/placement
fact). Docker can fuse them because a container is a flat box with one NAT hop.
**aeo is a tree, and those two facts live on different nodes.** So the grammar
names the *direction* rather than borrowing the fused flag:

| verb | who declares it | means | Docker analogue |
|---|---|---|---|
| `listens(p)` | a backend / any leaf | the process binds `p`; peers reach it **by name** on the internal net | the container side of `-p` |
| `publish(ext[, inner])` | a boundary node (the LB) | `ext` crosses the boundary **outward** to whatever contains the node | the host side of `-p` + `EXPOSE` |

Key consequences:

- **No port collision from `listens`.** Every backend can `listens(8080)` — each
  is its own network namespace, and the LB reaches them by name (`app-1:8080`,
  `app-2:8080`) on the `--internal` peer network. This is the thing Docker's `-p`
  cannot express and a tree can: N backends on the same port, zero mapping
  arithmetic.
- **`publish` is the *only* place a boundary crossing exists**, and it exists once,
  on the node meant to be reachable. The backends are, by construction, **not
  publishable** (see §3).

### What we keep from `docker run -p`, and what we reject

`-p 8080:80` is really five facts — bind on the host, bind `0.0.0.0`, host port
`8080`, container port `80`, proto tcp — with three hidden as defaults, two of
them dangerous.

**Adopt** (muscle memory is real; fighting it is arrogance):
- **`external:internal` read order.** `publish(9000, 8080)` reads outside→inside,
  the same direction as `-p`. A reader traces "the port I hit → the port it's on."
- **The single-arg collapse.** `publish(9000)` == `publish(9000, 9000)`, like
  `-p 9000`. The two-arg form is only needed when the outside port must differ from
  the LB's own listener (`publish(443, 9000)`) — keep it available, don't require
  it.

**Reject** (these are precisely what a containment tree exists to fix):
- **`0.0.0.0` by default.** `-p 8080:80` binds the world unless you remember
  `127.0.0.1:...`. For a system whose thesis is containment, bind-all-by-default is
  heresy. `publish` defaults to **the parent boundary only**; reaching the actual
  outside is a separate, louder act. Docker makes exposure the default and safety
  the opt-in; aeo inverts that.
- **The colon-string.** `-p` takes `"8080:80"` — a stringly-typed, proto-suffixed
  micro-DSL you parse by splitting on `:`. In aeo it is two integers:
  `publish(9000, 8080)`. Same order as Docker, no string-splitting.
- **Universal legality.** `-p` is legal on *any* `docker run` — the footgun that
  leaks databases onto the internet daily. `publish` is legal **only on
  boundary-role nodes** (see §3).

### Realistic ports

Rootless podman cannot bind `<1024` (no `CAP_NET_BIND_SERVICE`), so `80`/`443`
are off the table *inside* containers regardless. Every port in a realistic aeo
example is high (Tomcat is `8080`). Examples must stop pretending `80`/`443` exist
inside a rootless container.

---

## 3. Role-relative verbs, and a compile-time guarantee Docker cannot offer

Two verbs above are only meaningful **because of the parent's role**:

- `publish` is legal only on a boundary node (the LB, or a node explicitly marked
  ingress). **A backend physically cannot be published** — "backend is unreachable
  from outside" becomes a *model error to violate*, not a discipline you maintain.
- `balancer_weight` (§4) is legal only on a node whose parent is a `load_balancer`.

This is a second verb class alongside the intrinsic ones:

- **intrinsic** (`listens`, `image`, `limit_cpu`) — true about the node in
  isolation.
- **role-relative** (`publish`, `balancer_weight`) — valid only given the parent's
  role.

Model-check gains a rule class: *a role-relative verb on a node whose parent lacks
the enabling role is an error.* This is a **pattern**, not a one-off — aeo will
accrue more of these (a `replica` set would want `replica_priority`, etc.). Naming
it now keeps the checks uniform.

In Docker every container is one flag away from being published to the internet; in
aeo the grammar makes that a type error. That is the kind of guarantee that
justifies a bespoke DSL over compose-on-Docker.

---

## 4. `balance_to` — the explicit forward fact

The LB→backend forward port is a **fourth fact** that must not be left implicit.
`publish`'s outside port, `publish`'s inner listener, and each backend's `listens`
are three independent numbers that may *coincide* (all `8080`) without being
*wired*. `balance_to(8080)` names the wire:

```
publish(9000)              // world:9000 -> the LB
balance_to(8080)           // LB forwards to each backend's 8080   <- the wire
container("app-1") { listens(8080) }
```

We considered **inferring** the target from the children (the parent reads the
child's declared port) and rejected it, for two reasons:

1. **It reads as a data-flow story.** `publish(9000)` → `balance_to(8080)` → the
   backends. A reader traces the request path down the block without knowing any
   inference rule. A balancer's whole job is "where does the request go"; that
   should not be invisible.
2. **It makes the consistency check a real assertion.** Under inference,
   `listens(8080)` *defines* the target, so backends cannot be checked against it —
   whatever they say is true by construction. With `balance_to(8080)` declared
   independently, it is the **spec** and `listens` is the **claim**, and aeo can
   reject the mismatch. That is the `egress_fqdn` discipline exactly: intent
   stated, reality checked against it.

`balance_to` is the natural home for pool policy (this is the `someOptions` from
the earliest sketch, correctly placed): `algorithm`, `health`, stickiness — the
"how it forwards" facts. Per-backend `balancer_weight` rides on the child, because
it is a fact about that backend. This mirrors the line `std.http.proxy` already
draws between pool-level config and per-upstream `upstream_add(url, weight)`.

---

## 5. Weight/algorithm coupling — infer, then surface the mismatch at `aeo up`

`algorithm` and `balancer_weight` are coupled: `round_robin` ignores weights,
`weighted_rr` honors them. So `balancer_weight(3)` under a `round_robin` pool is
**silently ignored** — the "model says something it won't do" failure the whole
discipline forbids.

Two decisions:

1. **Infer the algorithm from the data.** The presence of any `balancer_weight`
   *is* the intent to weight, so the algorithm defaults to `weighted_rr` when
   weights are present. `algorithm(...)` is reserved for **overriding** that
   inference — you write it only when you deliberately want to drop the weights.

2. **When you *do* override into an ignoring algorithm, surface it at `aeo up`
   — not at model-check, and not at request time.** There are two distinct
   moments both loosely called "runtime":
   - **`aeo up` (provisioning):** aeo builds the pool, sees `round_robin` +
     weights, and reports the mismatch. This is the chosen point.
   - **request-serving (production):** the pool silently picks unweighted forever;
     nobody ever finds out. Rejected — this *is* the silent failure.

   **Caveat that makes the choice honest:** "surface at `aeo up`" only counts if
   the signal survives an *unattended* deploy. A bare `println` scrolling past in a
   green CI log is effectively the production-silent case. So the mismatch must
   land in the **`up` result summary / audit trail** — the same audit trail
   `egress_fqdn` routes allow/deny decisions to — not just stdout.

We deliberately do **not** hard-fail this at `aeo check`. A weight-vs-algorithm
mismatch is advisory (the LB still works, just unweighted); model-check hard
errors are reserved for things that are *wrong*, like a backend-port mismatch
(§4).

---

## 6. Health: one clock, two enforcers

The original sketch had health in two places, and they are **two genuinely
different contracts** — the trap is treating them as one knob:

| | `health_retry` (system scope) | `health("/healthz")` (balancer scope) |
|---|---|---|
| asks | "did this node *come up*?" | "is this backend *fit to serve right now*?" |
| acted on by | aeo `up`/reconcile — retry, declare deploy success/fail | `std.http.proxy` pool — eject/readmit a backend |
| when | once, at deploy | continuously, forever, in the datapath |
| failure means | "provisioning didn't converge" | "route around this one; deploy is still fine" |
| runs in | aeo (host side) | the LB process (C datapath) |

They must not be collapsed: a backend can be **up** (systemd started, port bound →
`health_retry` satisfied) yet **unfit** (`/healthz` returns 503 because its DB is
cold → pool ejects it).

**But they share values, and drift between them is incoherent.** The cadence
(`every(500ms)`) and the pool's health interval want to be one number; and
`down_within(10s)` (aeo declares it down) versus the pool's `unhealthy_threshold`
(eject after N fails) describe the *same physical event* twice. If aeo says "down
in 10s" but 3×500ms ejects in 1.5s, which is true?

**Decision — one clock, inherited:**

- `health_retry` at **system scope** is the single source of truth for cadence and
  timing (`every`, `up_within`, `down_within`).
- The balancer's `health(...)` contributes **only** the two genuinely
  balancer-specific facts: the **probe path** and the **expected status**.
  Intervals and thresholds are *inherited*, never restated.
- aeo lowers the **one** health contract onto **two** enforcement points — its own
  `up`/reconcile loop, and the pool's health checker.

```
health_retry() {                 // the ONE clock
    every(500ms)
    up_within(30s)
    down_within(10s)
}
load_balancer("web", :container) {
    balance_to(8080) {
        health("/healthz", expect: 200)   // ONLY path + expected status
    }                                       // interval, thresholds inherited
}
```

We rejected letting the balancer carry its own independent timing
(`health { every(1s); eject_after(3) }`). More flexible, but it is **two clocks on
the same backend** — the way you get "aeo thinks it's up, the LB thinks it's out,
nobody is lying" incidents. The convenience is not worth two clocks that can
disagree about one node.

This is the same one-intent → two-enforcers lowering aeo already does elsewhere
(one `egress_fqdn` intent → L3 floor + L7 gateway; one netpolicy → pf + iptables).

---

## 7. Where the balancer runs: container-first; host and multi-host are later epics

The DSL is intended to *read* uniform across substrates — `load_balancer("web",
:container | :vm | :host | ...)`. But the substrates are **not** interchangeable,
and the build order matters:

- **`:container`** — the balancer is just another node aeo provisions;
  `std.http.proxy` runs inside it. **Real today. This is the first slice.**
- **`:vm`** — same, one tier up. Straightforward.
- **`:host`** — the balancer *is* the aeo host itself. Not a node aeo deploys — the
  thing running aeo. Provisioning means aeo configuring its own host's networking;
  different lifecycle, and killing the LB kills aeo. A distinct, later concern.
- **other host / multi-host** — this is **not a load-balancer feature at all.** It
  is the multi-host substrate direction (inevitable, and the DSL should reach it
  through the *same* grammar). But it drags in cross-host health, cross-host splice,
  and cross-host identity/trust — the aeo-agent parent-relay story from the egress
  work. **Do not let `load_balancer` be the trojan horse that forces multi-host
  early.** Build container → vm → host → multi-host in that order; keep the DSL
  uniform, keep the *build* staged.

---

## 8. L7-only — and why L4 is explicitly out of scope (for now)

This design is an **L7 HTTP** balancer. That is deliberate and load-bearing:

- L7 lowers onto `std.http.proxy`, which does its own C-level I/O — **buildable
  today, no upstream blocker.**
- An **L4 TCP** balancer (for the non-HTTP tiers — redis/db replicas) is the
  *same engine* as the CONNECT egress gateway: accept a conn, pick a backend, splice
  bytes both ways. That splice is **blocked on aether#1092** (std.tcp cannot express
  a full-duplex relay — no readiness primitive, and a read timeout is
  indistinguishable from EOF and fatal; see
  [egress-fqdn-considered.md §8d](research/egress-fqdn-considered.md)).

Defining `load_balancer` as protocol-agnostic would let you *write* "balance my
redis" and then not honor it until an upstream fix lands — the exact
say-what-you-can't-do failure the discipline forbids. So: **`load_balancer` is an
L7 HTTP node.** When aether#1092 lands, an L4 balancer falls out almost for free by
generalizing the egress-gateway splice from one-upstream to pick-from-pool — as a
*separate, explicitly-marked* capability, not a silent extension of this one.

---

## 9. How it lowers onto `std.http.proxy` (the buildable slice)

The datapath already exists. `aeo up` for a `load_balancer` node builds a pool and
mounts it — roughly:

```
pool = proxy.upstream_pool_new(algorithm, request_timeout_sec, dial_timeout_ms, max_inflight)
proxy.upstream_add(pool, "http://app-1:8080", 3)     // url from child + balancer_weight
proxy.upstream_add(pool, "http://app-2:8080", 1)
// health_checks_enable(pool, path, expect_status, interval_ms, timeout_ms,
//                      healthy_threshold, unhealthy_threshold)
//   path, expect_status  <- balancer health("/healthz", expect: 200)
//   interval_ms          <- system health_retry every(500ms)
//   thresholds           <- derived from system down_within / up_within
proxy.health_checks_enable(pool, "/healthz", 200, 500, timeout_ms, healthy, unhealthy)
proxy.mount(server, "/", pool, opts)                 // server binds publish() port
```

The mapping is pure glue: children + `balancer_weight` → `upstream_add`; one health
contract → `health_checks_enable`; `publish` → the server's bind port. `drain`/
`undrain` give zero-downtime rollout for free; `breaker_configure` and `cache_new`
are later thickening.

### First buildable slice, in dependency order

1. **Model + grammar, no provisioning. — DONE.** `load_balancer`, `publish`,
   `listens`, `balance_to`, `balancer_weight`, and the role-relative model-check
   rules (§3): `publish`-only-on-boundary, `balancer_weight`-only-under-a-balancer,
   backend-port-agreement (§4). Landed in `lib/compose`, covered by
   `test/spec_load_balancer.ae`. Mirrors how `egress_fqdn` landed (model surface
   first, enforcement later). *Grammar note:* the health verb is spelled
   `lb_health("/healthz", 200)` (not `health("/healthz", expect: 200)`) — `health`
   was already a container-scope verb, and named args aren't used elsewhere in the
   grammar; the doc's `health(..., expect:)` sketch reads better but collides.
2. **`aeo up` lowering onto `std.http.proxy` — DONE.** `bin/aeo-lb.ae` is the
   front-door (an `std.http.proxy` reverse proxy reading its pool from `AEO_LB_*`
   env); `lib/driver_loadbalancer` renders the pool from the model (children +
   `listens` + `balancer_weight` → `http://name:port|weight`, the inferred/declared
   algorithm, the health contract) and runs aeo-lb; wired into the runner's
   `driver_up`/`driver_down`/`driver_probe` for kind `load_balancer`, plus the
   host-gate (`_kind_runnable`) and the backend-nesting fix (a backend's `host` is
   the LB — a container, not a VM — so it takes the host-container path, not the
   ssh/agent nested path). Renderers unit-tested (`test/spec_driver_loadbalancer.ae`);
   lifecycle live-proven (`test/spec_driver_loadbalancer_live.ae`).
3. **Live deploy-and-route proof — DONE.** Proven via real `aeo up` on podman:
   two self-identifying backends behind `web`, **weighted split 3:1 observed
   exactly**, **health-eject** (stopped backend drops out, all traffic to the
   survivor), **isolation** (backends NXDOMAIN + IP-unreachable from host; only
   `web:19000` published), and clean `aeo down`.

   **Two architecture findings this forced (both fixed):**
   - **The LB must run as a CONTAINER on the backends' net, not a host process.**
     A host-side aeo-lb cannot resolve backend names (container DNS is net-internal)
     nor reach rootless-podman backend IPs (not host-routable). So the driver runs
     aeo-lb as a container (image `localhost/aeo/aeo-lb:latest`) on `aeo-<system>`,
     publishing `publish()` to the host — which is *also* what makes backend
     isolation real. The image is **baked on demand** by the driver
     (`ensure_image`): a slim base + the binary's runtime libs (libssl/libnghttp2)
     + the toolchain-built `AEO_HOME/bin/aeo-lb` — no manual image step. (This
     replaced the earlier host-process `os_system` launcher; the container path is
     `driver_linux.up_net`.) The backends list uses `;` not `,` because
     driver_linux's `-e` env splitter is comma-delimited.
   - **The LB must boot AFTER its backends.** A pool built before a backend is
     healthy admits it only once health checks converge — correct eventually, but
     early traffic skews. `_deps_ready` now makes a `load_balancer` implicitly
     depend on all its children being UP, so it's the last node in its subtree to
     boot; the 3:1 split is then exact from the first request.
   The weight/algorithm mismatch surfacing (§5) is **DONE**: the runner's
   `_surface_lb_weight_ignored` hook fires when an LB comes UP with weights an
   explicit non-`weighted_rr` algorithm ignores — a loud `WARNING` line AND a
   hash-chained `weight-ignored` entry in the audit trail (so an unattended `up`
   still carries the signal), never a hard error. Live-proven: the warning fires,
   the audit entry is recorded, and the split is genuinely round-robin (10:10, the
   3:1 weights truly dropped — the warning is truthful).

   The health interval/threshold lowering (§6 "one clock, two enforcers") is
   **DONE**: `lb_health_timing` lowers the SYSTEM `health_retry` window (inherited
   by the LB via the float) onto the pool checker — `interval_ms = every()`,
   `timeout_ms = every()` (a probe can't outlast its cadence),
   `unhealthy_threshold = down_within / every()` (so ejection lands within
   down_within), `healthy_threshold = 2` (readmit hysteresis, kept distinct from
   aeo's `up_within` bring-up retry). Unset window → `get_interval`'s 1000ms
   default + unhealthy 3. Unit-tested (`500ms`/`10s` → `500;500;20;2`); live-proven
   — the lowered `AEO_LB_HEALTH_*` env reached the container and a stopped backend
   ejected within the 10s `down_within` window.
4. **Later thickening:**
   - **Circuit breaker + response cache — DONE.** Grammar `breaker(failures,
     open_ms, half_open)` and `cache(entries, max_body, ttl_sec, key_strategy)` in
     `balance_to{}`, rendered to `AEO_LB_BREAKER`/`AEO_LB_CACHE` (`;`-joined,
     comma-safe) and consumed by aeo-lb via `breaker_configure` /
     `cache_new`+`opts_bind_cache`. Live-proven: both reach the container and
     configure; routing intact.
   - **drain/undrain — DONE.** aeo-lb exposes an admin **middleware** (`POST
     /_aeo/drain` | `/_aeo/undrain`, backend URL in the body) that drains an
     upstream from the LIVE pool; `driver_loadbalancer.drain/undrain` POST to it.
     It had to be a middleware registered BEFORE the reverse-proxy middleware —
     the proxy's `/` prefix matches everything and runs before the route table, so
     a route is shadowed. Live-proven: draining a backend shifts ALL traffic off it
     (zero-downtime), undrain restores the split. (Wiring it into an automated
     rolling-cutover in the runner is the remaining reconcile step.)
   - **L4 TCP balancer — DONE.** `bin/aeo-l4lb.ae` balances OPAQUE TCP streams for
     non-HTTP tiers (redis, postgres, …): it `listen`s on `publish()`, and per
     accepted connection picks a weighted-RR backend and full-duplex splices bytes
     both ways via `egress_relay.splice` (poll2, aether#1092). Grammar: `l4()`
     inside `balance_to{}` marks the balancer L4; the driver then bakes/runs the
     aeo-l4lb image with `AEO_L4_*` env and `host:port|weight` backends (no
     `http://`). **The feared fan-out gate does NOT exist:** an actor per
     connection gives thread-per-connection concurrency (fire-and-forget `!`
     returns immediately; the splice runs on the actor's own OS thread), so no
     N-fd poll / `std.tcp` enhancement is needed — verified: 5 parallel
     connections greeted within 0.02s. Live-proven via `aeo up`: two redis
     backends behind an L4 balancer, real RESP relayed (PING→PONG, SET→OK), and
     the 1:1 spread routes independent connections to different backends.
   - **`:vm` substrate — gated with a loud error (not silently broken).** A
     balancer in a VM sits on a DIFFERENT network (tap/bridge) from its container
     backends, so it cannot reach them by name — that's the cross-network
     multi-host problem §7 defers, not a quick driver branch. Rather than ship a
     `:vm` balancer that can't route, `lb_model_errors` now rejects any substrate
     but `:container` with a message pointing at the multi-host epic, and (this
     also retroactively wires ALL the §3/§4 LB model checks, which existed but
     never fired in production) `lb_model_errors` is now run at `aeo check` AND in
     the up/down/dry-run `_preflight` — so a bad balancer fails loud before any
     deploy. Live: `aeo check` on a `:vm` balancer exits 1 with the substrate
     error; a `:container` balancer is clean.
   - **Still ahead:** the real `:vm`/`:host`/multi-host epics (§7 — cross-network
     routing, cross-host health/identity); and wiring drain/undrain into an
     automated rolling-cutover in the runner. (The balancer image build is already
     folded in — the driver bakes it on demand.)

---

See also [egress-fqdn-considered.md](research/egress-fqdn-considered.md) (the same
one-intent → many-enforcers lowering, and the aether#1092 splice gap that gates
L4), `lib/compose/module.ae` (`dns_hosts()` at ~L1305 already flags a health-aware
split-horizon responder — a DNS-tier balancer that pairs with this one), and
`std/http/proxy/module.ae` in the aether repo (the datapath this lowers onto).
