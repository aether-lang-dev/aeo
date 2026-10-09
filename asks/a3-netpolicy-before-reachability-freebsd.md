# A3 — load pf netpolicy BEFORE a FreeBSD node is reachable (needs the FreeBSD box)

**Status:** RESOLVED (2026-10-10) in **`ce6b68e`** — live-probed on the GhostBSD
box (FreeBSD 15.0-RELEASE-p10). Original hand-off text below the resolution.

## Resolution

**Design as built** (line numbers at `ce6b68e`):
- `lib/aeo/runner.ae:783` — `driver_up` calls `_preload_netpolicy(nm, k)` right
  after `_strict_gate` and before ANY driver work (jail `-c` / `vm start`).
- `lib/aeo/runner.ae:1494` `_preload_netpolicy` — ipfw preflight (kept, same
  warn / `AEO_IPFW_OFF=1` behaviour) → `pf.apply_pinned` → on success record
  `applied = pf anchor aeo/<n> (loaded before start)` + audit `netpolicy-loaded`;
  on failure in a `strict()` system: audit `strict-refuse`, best-effort
  `driver_down` + anchor flush (covers an idempotent re-up of a running node),
  return `STRICT REFUSED — declared netpolicy could not be enforced (…)`; outside
  strict: the loud `WARNING pf policy NOT enforced` + `applied = no (…)`, boot.
- `lib/aeo/runner.ae:1460` `_enforce_netpolicy` (still called at promotion) is
  now Linux reporting only — nothing loads post-hoc on FreeBSD.
- **No create-isolated-then-attach step was needed (decision):** both FreeBSD
  kinds aeo drives know their address before creation — a jail boots at its
  declared `ip()` (now pinned into the anchor, `_pf_pins`, runner.ae:1543), a bhyve
  guest at its ipam address (written as a static netplan before first boot). A
  jail with no `ip()` is created with ip4/ip6 *disabled* (FreeBSD's default,
  checked on the box) — already isolated.
- `lib/pf/module.ae:99` `apply_pinned` (`ready()` :139) — `ready()` first (pf loaded, `Status:
  Enabled`, main ruleset references `anchor "aeo/*"`; pure verdict
  `_ready_verdict`), resolve with pins winning over ipam, load, then READ BACK
  (`loaded_count`) — an empty anchor is a failure. An anchor pf will not evaluate
  is the same load-but-not-bite class as the ipfw confound, so it counts as "not
  enforced" (and is fatal under strict).
- A1 status: `_secp_netpolicy_status` (runner.ae:2305) reads `applied` LIVE from
  pf on FreeBSD (`pf anchor aeo/<n> (N rules loaded, pf enabled)` or `no (…)`);
  the strict gate keeps the pre-boot `_secp_netpolicy`.
- Two pre-existing bugs the live probe exposed, fixed here: (1) a jail's `$name`
  resolved through **ipam**, not its `ip()` — the anchor named an address the
  jail did not have, so it never filtered the jail; (2) A2's strict gate refused
  **every jail** as an "unpinned image" (now container kinds only, matching
  `_secp_attest`), so no strict() FreeBSD system could boot at all.

**Live evidence** — `test/a3-bringup-probe.sh` (re-runnable; instructions in its
header; `A3_PF_TEMP=1` brings up and restores a temporary pf on a box without
one). A deny-default jail (`deny_egress`, no ingress whitelist, `ip 10.77.3.10`)
whose workload opens a listener and loops connecting out, started by `jail -c`'s
`exec.start`; a host loop connects in every ~50 ms from before `aeo up`; an
independent 20 ms poller records when the anchor first holds rules; the workload
takes 2 s to report healthy (a service warming up). ipam is steered so even the
OLD code's anchor names the jail's address — the difference is ordering alone.
- **OLD (`2a0140d`)**: workload START `…117.869`, anchor first holds rules
  `…119.965` (after promotion UP) → **36 ingress + 39 egress connections
  succeeded** in the ~2.1 s window; 0 after the anchor. (With a 0 s health delay:
  1 + 1 in ~48 ms.)
- **NEW (`ce6b68e`)**: anchor holds rules `…831.889` **before** workload START
  `…831.933`; **0 of 90 ingress + 95 egress attempts** succeeded from creation
  through ready and after; `aeo status` → `applied=pf anchor aeo/aeo_a3_probe (2
  rules loaded, pf enabled)`.
- **Forced pf failure** (pf disabled for the bring-up): strict → `STRICT REFUSED —
  declared netpolicy could not be enforced (aeo: pf is loaded but DISABLED …)`,
  the jail never runs; strict re-`up` over an already-running jail → it is torn
  down. Negative control, same failure without strict(): the jail boots, `WARNING
  pf policy NOT enforced`, status `!netpolicy … applied=no (anchor … empty —
  policy not loaded)`. The OLD code in the same situation printed "pf
  deny-default policy loaded" and status claimed `applied=pf anchor …` while pf
  was disabled — and its strict() refused the jail only as an "unpinned image".

**Tests** — Mac (ae 0.791.0): `run-spec.sh` 322 ✓ vs 313 at `2a0140d` (+9 in
spec_pf_enforce), the only failing spec `spec_driver_loadbalancer_live` fails
identically before/after (no aeo-lb image); strict-mode.sh, security-posture.sh,
compose-lint.sh green. GhostBSD (ae 0.791.0 source build under ~/aether-lab/a3):
`run-spec.sh` 340 ✓ vs 331, the same two pre-existing failures before/after
(`spec_capsicum_bhyvevm_selfreport`, `spec_containment_linux_vm`); strict-mode.sh
cases 1-2 fail identically before/after on FreeBSD (container kinds are refused by
the host preflight there — a Linux-shaped harness); security-posture.sh green.

**Left open** (in `TODO.md`, Strands track): off-box egress behind a host `nat`
rule is NOT filtered by the anchor (pf translates before filtering — proven live);
a bhyve live probe (the ordering covers it, but no guest image on the box; DHCP
double-address unverified); driver_bsd mounts no devfs in jails.

## Original hand-off

Part of the Strands-inspired honesty track (A1, A2, A4 are done on `main`; see
`TODO.md` → "Strands-inspired honesty track" and
`docs/reference/status-schema.md`).

## The problem (verified at aeo `214430e`)

On FreeBSD, aeo loads a node's pf deny-default anchor **after** the node is already
up and running its workload, and a failure to load is **non-fatal**:

- `lib/aeo/runner.ae:160-163` — the engine promotes a node: `set_state(bn,
  STATE_UP())` → `println("aeo: [bn] up")` → **then** `_enforce_netpolicy(bn)`.
- `_enforce_netpolicy` (`runner.ae:1443-1482`) on FreeBSD runs `pf.apply(...)` and,
  on error, only prints `WARNING pf policy NOT enforced` and returns — the node
  stays up. The function's own header says so: *"Non-fatal by design: a pfctl
  failure logs loudly but doesn't tear the (already-up) node down."*

So there is a **window of unfiltered reachability**: for a jail or bhyve guest, the
workload is running before its egress/ingress policy exists. For a deny-default
posture that is exactly backwards — the node can phone out (or be reached) in the
gap, and if pf never loads at all, it runs unfiltered indefinitely with only a log
line.

(Linux is not affected the same way: a container gets its network *mode* at
creation — `confine_linux` places it on none/internal/shared at `up` — so there's
no post-hoc window. A3 is a FreeBSD-path task.)

## Do

1. **Order: load the anchor before the workload runs.** On FreeBSD, apply the pf
   anchor *before* the jail/bhyve guest starts executing its workload, not after
   promotion. Where the node's address is only known after creation (bhyve guest
   IP via ipam/agent), create the node **isolated** (no reachable path) and attach
   it to the network only after the rules are loaded — so there is never a moment
   it is both reachable and unfiltered.
2. **Strict → fatal.** In a `strict()` system (A2 — `compose.get_strict(sys)`; see
   `_strict_gate` at the top of `driver_up`), a failure to load the pf anchor is
   **fatal**: tear the node down rather than leave it up unfiltered. Outside strict,
   keep today's loud `WARNING … NOT enforced` line **plus** A1's `applied: no` in
   status (don't regress the non-strict ergonomics).
3. **Keep the ipfw preflight** already in `_enforce_netpolicy` (`runner.ae:1459-
   1474`): ipfw shares pfil with pf and silently eats bridged packets, so the
   anchor can load-but-not-bite. That check must run in the new (earlier) ordering
   too. See memory/`docs/research` on "pf redeemed (ipfw confound)".

## Done when (the plan's acceptance, with a LIVE probe — not a green rule-gen spec)

- A forced `pf.apply` failure in a **strict** system leaves the node **down** (torn
  down), not up-with-a-warning. Negative control: the same forced failure in a
  non-strict system still boots with the warning + `status applied: no`.
- A probe **during bring-up** shows **no window** of unfiltered reach: e.g. a jail
  whose policy is `deny_egress` cannot reach off-box at any point between create and
  ready. A rule-generation unit spec is **not** sufficient evidence here — drive a
  real jail/bhyve guest on the FreeBSD box and observe the actual reachability
  (this is aeo's "live claims need a live probe" rule; see the BDD + `AEO_VERIFY=1`
  live-check convention in `test/run-spec.sh` and the existing
  `spec_pf_enforce.ae` / `spec_pf_rulegen.ae` for the model-side).

## Pointers

- Bring-up promotion + the post-hoc call site: `lib/aeo/runner.ae:155-166`.
- `_enforce_netpolicy` (the FreeBSD pf path + ipfw preflight): `runner.ae:1440-1482`.
- Strict gate to hook the fatal-on-failure behaviour into: `_strict_gate` /
  `driver_up` top (search `_strict_gate` in `runner.ae`); `compose.get_strict(sys)`.
- pf rule generation + anchor naming: `lib/pf/`, `compose.pf_rules_for(nm)`,
  `pf.anchor_name(nm)`, `pf.ipfw_conflict()` / `pf.ipfw_disable()`.
- Jail/bhyve up: `driver_bsd.up(...)` (`runner.ae:944`), `driver_vm.bhyve_up(...)`
  (`runner.ae:958`) — the workload-start points A3 must order the anchor ahead of.
- Status already reports netpolicy posture per node (A1): `_secp_netpolicy` in
  `runner.ae`; keep `applied` honest after the reorder.
- Conventions: `LLM.md`, `TODO.md`, `AETHER_PIN`/`AEB_PIN`; aeo pushes to `main`
  (no PRs). Every change ships with a test shown to fail without it.

## Coordination

The aeo Strands track is tracked in aeo's own `TODO.md` (authoritative). If A3
surfaces an Aether need, file it in `aether/asks/` as a concrete spec rather than
patching Aether. Mark this done in `TODO.md`'s Strands-track section when it lands.
