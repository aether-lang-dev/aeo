# A3 — load pf netpolicy BEFORE a FreeBSD node is reachable (needs the FreeBSD box)

**Status:** OPEN, ready to pick up. **Needs a FreeBSD box** (the GhostBSD box,
paul@192.168.0.204, or any FreeBSD host with pf + a bhyve/jail substrate) for the
live probe — this is why it's handed to a sibling with that hardware rather than
done on the crostini dev box. Part of the Strands-inspired honesty track (A1, A2,
A4 are done on `main`; see `TODO.md` → "Strands-inspired honesty track" and
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
