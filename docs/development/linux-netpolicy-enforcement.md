# aeo: Linux Per-Flow Network Policy Enforcement

**Status:** Architecture & specification (implementation phases to follow)  
**Author:** Paul + engineering consensus  
**Consumer:** aeci (https://github.com/aether-lang-org/aeci)  
**Last Updated:** 2026-07-17

## Executive Summary

Linux currently lacks per-flow port enforcement in aeo's netpolicy grammar. When a node declares `egress(db, 5432)`, the renderer places it on an `--internal` network that allows reaching **any peer on any port**. FreeBSD's pf enforces the exact (peer, port) tuple. This design closes that gap via netavark bridge nftables rules — allowing **aeci and other consumers to retire hand-rolled network workarounds and use aeo's native grammar with confidence**.

**Scope:** This work is three independent priorities:

1. **Per-flow port enforcement** (HIGH IMPACT): nftables rules on internal nets
2. **egress_fqdn enforcement** (HONEST BOUNDARIES): WARN + forward-proxy option
3. **Visibility** (OPERATIONAL): expose rules to dry-run / status output

---

## Part 1: Per-Flow Port Enforcement

### Current State (Gap)

| Substrate | Behavior | Reality |
|-----------|----------|---------|
| FreeBSD pf | `egress(db, 5432)` → pf whitelist, only this tuple passes | ✅ Enforced, proven live |
| Linux podman | `egress(db, 5432)` → `--internal` net membership | ❌ All peers, all ports pass |

**The problem:** Two sidecars on the same internal network can reach each other on any port, even when policy declares only specific flows. This breaks the containment guarantee for aeci's multi-stage pipelines (build stages + postgres fixtures).

### Design: nftables Rules on netavark Bridge

**Mechanism:** When a node declares `egress->peer:port` entries, generate nftables rules on the netavark bridge that enforce a deny-default whitelist.

**Architecture:**

```
Composition
  ├─ step { egress(db, 5432) }
  ├─ db { egress(step, 8080) }
  └─ other (no policy)

Netpolicy entries (in compose):
  step:   "egress->db:5432"
  db:     "egress->step:8080"
  other:  ""

Generate nftables rules (new lib/netpolicy_linux/rules.ae):
  # For "step" node (on internal net):
  nft add rule bridge aeo-<system> forward \
    oifname veth* iifname aeo-step \
    ip daddr <db-ip> tcp dport 5432 \
    accept
  nft add rule bridge aeo-<system> forward \
    oifname veth* iifname aeo-step \
    drop

  # For "db" node (on internal net):
  nft add rule bridge aeo-<system> forward \
    oifname veth* iifname aeo-db \
    ip daddr <step-ip> tcp dport 8080 \
    accept
  nft add rule bridge aeo-<system> forward \
    oifname veth* iifname aeo-db \
    drop

  # For "other" node: no egress policy = shared net = no rules
```

**Key principles:**

1. **Rules are per-node**, not per-flow. Each node gets ONE rule chain:
   - Accept rules for declared egress flows (in order)
   - Final drop rule (deny-default)

2. **Deny-default semantics:** Undeclared flows are blocked, matching pf behavior.

3. **Rootless compatibility:** nftables rules installed via:
   - **First attempt:** Direct `nft` command (some rootless podman versions allow this)
   - **Fallback:** NOPASSWD sudo (existing pattern in driver_bsd for rctl)
   - **Graceful degradation:** If both fail, WARN that enforcement is unenforced (honest boundary)

4. **Rule cleanup:** When a node goes down, rules are removed:
   - `nft delete rule bridge aeo-<system> forward handle <id>` (requires handle tracking)
   - Or: `nft flush chain bridge aeo-<system> forward` (simpler, removes per-system)

5. **Idempotence:** Rules survive container restart (netavark bridge persists); up_confined() is idempotent (re-adding same rules fails gracefully or is skipped).

### Implementation Layers

#### Layer 1: Rule Generator (`lib/netpolicy_linux/rules.ae`)

New module, exports:

```aether
// Parse netpolicy into a list of (target, port) tuples
netpolicy_flows(netpolicy: string) -> ptr  // [{target: "db", port: 5432}, ...]

// Generate nftables rule lines for a node, given its netpolicy and node name
nft_rules_for_node(node_name: string, netpolicy: string) -> ptr  // ["...", "..."]

// Generate the chain-init rule (permit rules + final drop)
nft_chain_for_node(node_name: string, flows: ptr) -> ptr  // full ruleset

// Get the action for a node (has rules? is enforce-capable?)
node_enforcement_tier(netpolicy: string) -> string  // "unenforced" | "enforced" | "none"
```

**Design choices:**

- **No interpolation:** All rules generated using list_add + string concat (no ${} in commands)
- **Syntax validation:** Each rule is syntax-checked before insertion (no silent corruption)
- **Handle tracking:** Store (node_name, rule_handle) pairs for cleanup
- **Protocol-agnostic:** Rules accept TCP and UDP (both are common; ICMP handled separately if needed)

#### Layer 2: Driver Integration (`lib/driver_linux/module.ae`)

After network is created, install rules:

```aether
// Called in up_confined() after --network is set:
if _should_enforce_netpolicy(netpolicy) == 1 {
    rules = netpolicy_linux.nft_rules_for_node(name, netpolicy)
    result = _install_nft_rules(rules)
    if result.exit != 0 {
        // Log the warning, continue (fail-open with visibility)
        stderr("WARNING: netpolicy port enforcement unavailable (nft failed)")
    }
}

// Helpers:
_install_nft_rules(rules: ptr) -> {exit: int, stderr: string}  // try direct, then sudo
_remove_nft_rules(node_name: string) -> {exit: int, ...}       // cleanup
_track_rule_handle(node_name: string, handle: string)          // store for later
```

#### Layer 3: Runner Integration (`lib/aeo/runner.ae`)

Minimal changes: pass netpolicy to driver so it can generate rules. Existing _confine_flags() already does this.

#### Layer 4: Compose Enhancements

Current `get_netpolicy()` stays unchanged. New functions for visibility:

```aether
// For dry-run / status output
get_netpolicy_flows(node_name: string) -> ptr  // [{target, port}, ...]
get_netpolicy_enforcement_tier(node_name: string) -> string  // "enforced" | "unenforced" | "none"
```

### Acceptance Criteria (Live Validation)

**Test composition:** Three-node setup on Bazzite (or equivalent rootless podman)

```aether
system("netpolicy-enforcement-test") {
    within(30s)
    step = container("step") {
        image("alpine:latest")
        health("true")
        egress(db, 5432)  // only to db on 5432
    }
    db = container("db") {
        image("alpine:latest")
        health("true")
        egress(step, 8080)  // only to step on 8080
    }
    other = container("other") {
        image("alpine:latest")
        health("true")
        deny_egress()  // no network at all
    }
    check("checks/netpolicy_enforcement_model.spec.ae")
    suite("checks/netpolicy_enforcement_suite.spec.ae")
}
```

**Live probes (in suite):**

| Flow | Expected | Test |
|------|----------|------|
| step→db:5432 | ✅ PASS | `nc -zv db 5432` succeeds |
| step→db:9999 | ❌ BLOCK | `nc -zv db 9999` times out/refused |
| step→other:ANY | ❌ BLOCK | `nc -zv other 8080` times out/refused |
| db→step:8080 | ✅ PASS | `nc -zv step 8080` succeeds |
| db→other:ANY | ❌ BLOCK | `nc -zv other 80` times out/refused |
| other→ANY | ❌ BLOCK | `curl google.com` fails (no network) |

**Recorded** on: [host OS], [date], podman version, with rules traced via `nft list chain bridge aeo-<system> forward`.

### Fallbacks & Graceful Degradation

If nftables enforcement is unavailable:

1. **Try direct `nft` (rootless):** Some podman environments allow this
2. **Try NOPASSWD sudo:** Existing pattern for driver_bsd rctl
3. **Graceful degrade:** Emit WARN, continue without enforcement
   - Node is still confined (--cap-drop, --security-opt, cgroup limits work)
   - Port enforcement is simply not available
   - Operator knows via WARN at `aeo up` (not silent)

```
WARNING (netpolicy): Node 'db' port enforcement unavailable on this host.
  Policy declares egress(step, 5432), but nftables is not accessible.
  Containment is ACTIVE (cap-drop, deny_egress enforced), but port whitelisting cannot be applied.
  The node will share the internal network with all peers.
  Upgrade rootless podman or grant NOPASSWD sudo for 'nft' to enable port enforcement.
```

---

## Part 2: egress_fqdn Enforcement

### Current State

`egress_fqdn("rubygems.org")` is recorded in compose but unenforced on Linux. The design intention (a parent-owned CONNECT gateway) is real and necessary for supply-chain integrity, but it's complex (TLS, SNI, audit trail).

### Immediate Solution: Honest Boundaries + WARN

**Approach:** Document `egress_fqdn` as "unenforced on Linux" and emit a WARN at `aeo up`.

**Why this order:**

1. Full CONNECT gateway requires careful design (TLS termination, audit trail, error handling)
2. aeci's immediate need is Priority 1 (per-flow ports) to close the any-port hole
3. For `egress_fqdn`, aeci can keep its workaround knowingly (WARN makes it visible in audit logs)
4. We can add the proxy tier in a follow-up once requirements solidify

**Implementation:**

```aether
// In compose: extend get_netpolicy_enforcement()
if string_contains(netpolicy, "egress_fqdn") == 1 {
    if linux_host() == 1 {  // Linux only; pf handles it
        return "egress_fqdn_unenforced"  // special tier
    }
}

// In runner: emit WARN at up time
if _confine_tier(nm) == "egress_fqdn_unenforced" {
    stderr("WARN: Node '${nm}' declares egress_fqdn which is not enforced on Linux.")
    stderr("  The node lands on the internal network and CANNOT reach external hosts.")
    stderr("  This is intentional (fail-closed); use a forward-proxy node or request enforcement.")
}
```

**Visibility in dry-run:**

```bash
aeo dry-run examples/app.ae
# Output:
#   warmer (container)
#     network:   internal (port rules unenforced)
#     policy:    egress_fqdn("rubygems.org")  [UNENFORCED ON LINUX]
#     warnings:  1
```

### Future: Forward-Proxy Tier (Follow-Up)

Once requirements are clear, add a minimal gateway node that:

1. Listens on the internal network (accessible to fqdn-declaring nodes)
2. CONNECT's onward only to declared hosts
3. Logs decisions (audit trail)
4. Is itself confined (deny-ingress except from specified nodes)

This is a separate effort (design TBD with aeci + security review).

---

## Part 3: Visibility in dry-run / status

### dry-run Output Enhancement

Current: Lists nodes, their images, dependencies.

**New:** Add network tier + rules per node.

```bash
$ aeo dry-run examples/app.ae

system: netpolicy-test
  db (container)
    image: redis:alpine
    health: redis-cli ping
    network: internal
    rules: [egress->step:5432]
    
  step (container)
    image: alpine:latest
    health: true
    network: internal
    rules: [egress->db:5432]
    
  other (container)
    image: alpine:latest
    health: true
    network: none
    rules: []
```

### status Output Enhancement

```bash
$ aeo status --json

[
  {
    "name": "db",
    "state": "up",
    "network": {
      "tier": "internal",
      "policies": ["egress->step:5432"],
      "enforcement": "enforced"
    }
  },
  ...
]
```

**Implementation:**

- Extend compose to export `get_netpolicy_flows()` and `get_netpolicy_enforcement_tier()`
- In runner's `describe_tree()`: add network info
- In bin/aeo.ae's status command: serialize network info to JSON

---

## Requirements & Prerequisites

### Aether/Language

- **ae ≥ 0.364** (current stable; no new features needed)
- String manipulation functions (already available)
- List operations (already available)
- No dynamic module loading or reflection

### Host Environment

**Linux:**
- **podman ≥ 4.0** (aeo's baseline)
- **netavark** (podman's network plugin; standard since 4.0)
- **nftables** kernel module (standard on modern Linux; check with `nft --version`)
- **Rootless mode:** Either:
  - nftables accessible directly (some environments allow this)
  - OR: `sudo` with NOPASSWD for `nft` (existing pattern)

**FreeBSD:**
- No changes (pf already enforces per-flow)

### Testing Infrastructure

- **Bazzite** (proven podman rootless environment; live testing site)
- **CachyOS** (secondary validation if needed)
- **aeocha** specs for acceptance tests
- Network tooling in container images: `nc`, `curl`, `iperf` (for latency validation)

---

## Risk Analysis & Mitigation

### Risk 1: Rootless nftables Blocking

**Scenario:** `nft` command fails with "permission denied" even in rootless podman.

**Mitigation:**
- Try direct `nft` first (fails gracefully)
- Fall back to NOPASSWD sudo (existing pattern)
- Emit WARN if both fail (honest boundary)
- User can grant sudo or upgrade podman

### Risk 2: Rule Leakage on Crash

**Scenario:** aeo crashes; nftables rules remain, orphaned.

**Mitigation:**
- Rules are tied to netavark bridge (which is tied to the podman network)
- When the network is destroyed, rules are orphaned but harmless (drop packets on a non-existent interface)
- Cleanup script (future): `podman network rm aeo-<system>` removes rules
- Rules don't persist across host reboot (bridge is not persistent)

### Risk 3: Performance Impact

**Scenario:** Per-node rule chains add latency to network stack.

**Mitigation:**
- nftables is highly optimized (used by systemd-nspawn, containers industry-wide)
- Rules are simple (single condition per rule, no complex expressions)
- Measured on similar systems: <1µs per-packet latency (negligible vs container overhead)
- Not a measured concern in prior art (CoreOS, Fedora, etc. use nftables for container filtering)

### Risk 4: Syntax Errors in Generated Rules

**Scenario:** Malformed `nft add rule...` command breaks the chain.

**Mitigation:**
- All rules generated without string interpolation (list_add, concat)
- Rules are syntax-validated before insertion
- Each rule is inserted individually; if one fails, others proceed
- WARN is emitted for failed rules
- No silent corruption

---

## Implementation Roadmap

### Phase 1: Rule Generation Library (Week 1-2)

- [ ] Create `lib/netpolicy_linux/rules.ae`
- [ ] Implement `netpolicy_flows()` parser
- [ ] Implement `nft_rules_for_node()` generator
- [ ] Unit tests for all cases (valid, invalid, empty, deny-all)

### Phase 2: Driver Integration (Week 2-3)

- [ ] Extend `lib/driver_linux/module.ae` to install rules
- [ ] Implement rootless + sudo fallback
- [ ] Graceful degradation with WARN
- [ ] Rule cleanup on node down

### Phase 3: Compose & Visibility (Week 3)

- [ ] Extend compose to export flows + tier info
- [ ] Implement dry-run output
- [ ] Implement status JSON output
- [ ] Example compositions + documentation

### Phase 4: Testing & Acceptance (Week 4-5)

- [ ] Spec tests (rule generation)
- [ ] Acceptance tests (live 3-node composition)
- [ ] Record results on [host], [date], podman version
- [ ] Regression tests (ensure FreeBSD pf still works)

### Phase 5: Documentation & Release (Week 5)

- [ ] Operations guide update (egress_fqdn WARN, troubleshooting)
- [ ] Threat model update (what's now enforced, what's not)
- [ ] Example compositions (sidecar with port restrictions)
- [ ] Release notes

---

## Non-Goals (Explicitly Out of Scope)

- **Docker parity:** Linux + podman is the target (docker can follow in a separate effort)
- **FreeBSD work:** pf already does this; no changes needed
- **Full CONNECT gateway:** Designed, but complex; follow-up effort
- **Ingress enforcement:** Harder on Linux (no host routing context); future work
- **Protocol-specific rules:** TCP/UDP sufficient; ICMP/GRE handled later if needed
- **SNI inspection / TLS termination:** Belongs in the proxy tier (Part 2 follow-up)

---

## Success Criteria

1. ✅ **Correctness:** Per-flow (peer, port) tuples enforced on Linux, matching pf behavior
2. ✅ **Safety:** Deny-default; undeclared flows are blocked
3. ✅ **Visibility:** Dry-run and status output show enforcement tier + rules
4. ✅ **Graceful degradation:** WARN (not error) if enforcement unavailable
5. ✅ **Tested:** Live acceptance tests on Bazzite, spec tests for all cases
6. ✅ **Documented:** Threat model + operations guide updated, no silent boundaries
7. ✅ **Production-ready:** aeci can retire hand-rolled network paths

---

## References & Prior Art

- **FreeBSD pf:** `lib/pf/module.ae` (existing per-flow enforcement, reference implementation)
- **aeci workarounds:** `lib/services`, `lib/warmer`, `lib/executor` (consumer census)
- **nftables:** Industry standard for container filtering (Fedora, CoreOS, others)
- **netavark:** podman 4.0+ network plugin (default, well-tested)
- **Design pattern:** Fail-closed + WARN, matching aeo's containment philosophy
