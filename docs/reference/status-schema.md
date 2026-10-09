# `aeo status` schema — the per-node report and its `--json` shape

`aeo status <compose.ae>` reports every declared node's live state plus the facts
aeo already knows about it (address, resource caps, confinement, attestation, and
— since the Strands honesty track — a per-property **security posture**). The same
data renders two ways: a human view, and `--json` for tooling and CI gates. Both
are produced from one model, so they never disagree: the JSON a gate reads is the
truth a human sees.

This document is the contract. The producers are `_status` (human) and
`_status_json` (JSON) in `lib/aeo/runner.ae`.

## Invocation

```sh
aeo status compose.ae            # human
aeo status compose.ae --json     # machine-readable (one JSON array on the last line)
```

`--json` sets `AEO_STATUS_JSON=1` for the runner. The JSON array is the last line
of output; earlier lines may carry build/diagnostic text, so tooling should take
the final line (`… | tail -1 | jq …`).

## JSON: a flat array of node objects

One object per declared node, in declaration order. Fields with no value are
present as `""` (stable shape — consumers get the same keys every time rather than
having to handle missing ones).

```json
[
  {
    "name": "web",
    "kind": "container",
    "system": "secposture",
    "host": "",
    "depends": "",
    "state": "down",
    "ip": "",
    "caps": "memoryuse=128m",
    "netpolicy": "egress_fqdn:example.com",
    "grants": "",
    "attestation": "attested",
    "attest_digest": "sha256:deadbeef",
    "security": {
      "egress_fqdn": {
        "declared": "example.com",
        "supported": "no",
        "applied": "no (on --internal net standin; NOT name-aware)",
        "verified": "not probed"
      }
    }
  }
]
```

### Top-level node fields

| field | meaning |
|---|---|
| `name` | the node's declared name |
| `kind` | `container`, `jail`, `kvm_vm`, `bhyve_vm`, `proxmox_vm`, `lxc`, … |
| `system` | the enclosing `system("…")` name |
| `host` | the containing node, for a nested node (VM→container); `""` at top level |
| `depends` | the node this one `depends()` on; `""` if none |
| `state` | `up` or `down` — liveness, batched one `ps` per engine |
| `ip` | resolved address, when known |
| `caps` | resource limits from `limit{}` (e.g. `memoryuse=128m, maxproc=32`) |
| `netpolicy` | the raw declared network policy string |
| `grants` | Capsicum fd grants from `constrain{}` |
| `attestation` | `attested` \| `unpinned` \| `unattestable` (see below) |
| `attest_digest` | the pinned digest, or `""` |
| `security` | the per-property posture object (below) |

`attestation` is the supply-chain posture a CI gate greps for:
- **`attested`** — the node declared `attest("sha256:…")`; aeo verifies the actual
  digest before boot and refuses on mismatch.
- **`unpinned`** — a pulled `image()` with no `attest()`. A finding, not an error.
- **`unattestable`** — built locally (`entrypoint`/`dockerfile`), so there is no
  upstream digest to pin.

## `security`: declared / supported / applied / verified

`security` is an object keyed by security **property**. Only properties the node
*declared* appear (an unconfined node has an empty or small `security` object).
Each property reports four fields — the Strands-lesson distinction between asking
for a guarantee, being able to enforce it, having installed it, and having proved
it:

| field | question it answers |
|---|---|
| `declared` | what did the composition ask for? (the accessor value) |
| `supported` | can **this** node's backend (kind × host OS) enforce it? `yes`/`no` |
| `applied` | what was actually installed? a concrete token, or `no (…)` |
| `verified` | did a probe confirm it? a probe tag, or `not probed` |

`verified` is `not probed` for most properties today: `status` reads declared
state and liveness; it does **not** re-probe live rules. A live probe is the job
of `aeo check` and the A3 netpolicy-before-reachability work. The one exception is
attestation, whose `verified` is `at boot` (the digest is verified fail-closed at
bring-up).

### Properties

| key | `supported` depends on | notable honest `no` |
|---|---|---|
| `netpolicy` | FreeBSD (pf) yes; Linux **container** yes (container net mode); Linux non-container **no** (only pf/container enforce) | a non-container kind on Linux |
| `egress_fqdn` | **no on every backend today** — name-aware egress is not enforced anywhere until the CONNECT gateway lands (see `research/egress-fqdn-considered.md`) | always; on Linux the node is placed on an `--internal` net *standin*, **not** name-aware filtered |
| `attestation` | yes (the boot-time digest gate) | `applied: no (unpinned)` for a pulled-but-unpinned image |
| `limits` | yes (FreeBSD rctl / Linux cgroups) | — |
| `cap_drop` | yes; declared is derived as `constraints OR netpolicy` (no single accessor) | — |

The `egress_fqdn` row is the reason this posture exists. Before it, aeo mapped
`egress_fqdn` on Linux to an `--internal` network and said nothing — a silent gap
(the WARN the design docs mention lives in `lib/netpolicy_linux`, a module imported
nowhere). The posture makes the gap legible: `supported: no, applied: no`.

### Human view

The same model renders as indented lines under each node; a line whose `supported`
or `applied` is `no` is flagged with a leading `!` so a gap stands out:

```
  web [container] {secposture} state=down
      attest: attested (sha256:deadbeef)
      netpolicy   declared=egress_fqdn:example.com supported=yes applied=container net (internal) verified=not probed
     !egress_fqdn declared=example.com supported=no applied=no (on --internal net standin; NOT name-aware) verified=not probed
      limits      declared=memoryuse=128m supported=yes applied=cgroups (--memory/--pids-limit) verified=not probed
      cap-drop    declared=(from netpolicy) supported=yes applied=--cap-drop ALL --security-opt no-new-privileges verified=not probed
```

## CI gates

The posture is built for gating. Examples:

```sh
# Fail if any node isn't up.
aeo status compose.ae --json | jq -e '[.[] | select(.state != "up")] | length == 0'

# Fail if any declared security property could not be applied (the honest gate:
# catches egress_fqdn on Linux, an unpinned image, a non-container netpolicy …).
aeo status compose.ae --json \
  | jq -e '[.[] | .name as $n | (.security // {}) | to_entries[]
             | select(.value.applied | startswith("no"))
             | "\($n).\(.key)"] | length == 0'

# Supply-chain gate: every container must be attested.
aeo status compose.ae --json | jq -e 'all(.[]; .kind != "container" or .attestation == "attested")'
```

Pair this with `strict()` in the composition: a status gate reports *after* the
fact; `strict()` refuses to *start* a node in the first place.

## `strict()` — refuse instead of report

A status gate is advisory — it runs after `aeo up` and tells you what degraded. For
a system that must not run degraded at all, declare `strict()` at system scope:

```
system("prod") {
    strict()                         // refuse unsupported / failed / unpinned nodes
    container("db") { image("…") attest("sha256:…") }
}
```

In a `strict()` system a node does **not** start if:
- a declared security property is `supported: no` or `applied: no` on its backend
  (the same posture fields above — e.g. `egress_fqdn` on Linux), or
- its image is **unpinned** (a pulled `image()` with no `attest()`; `attestation`
  is `unpinned`).

The refusal is loud and names the property (`aeo: [db] STRICT REFUSED — …`), is
recorded in the audit trail (`strict-refuse`), and fails the node before any boot
work. It is config-is-code: the policy lives in the composition, reviewable in git,
not an operator flag. Default (no `strict()`) is unchanged — degraded nodes still
boot and status marks them. A locally-built image (`unattestable` — no upstream
digest to pin) is a distinct class and is not gated by the unpinned check.


## Stability

The top-level field set is stable; new optional fields may be added (present as
`""` when unset) without removing existing ones. Inside `security`, property keys
are added as aeo gains properties; the four sub-fields
(`declared`/`supported`/`applied`/`verified`) are the fixed contract. The
free-text `applied`/`verified` strings are human-oriented — gate on `supported`
and on `applied` *starting with* `no`, not on exact wording.
