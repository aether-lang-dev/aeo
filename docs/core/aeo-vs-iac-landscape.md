# aeo across the IaC landscape

Where aeo sits among infrastructure-as-code tools, and what it does that the
category leaders don't. This is a positioning rollup — for the deep per-decision
"why", see `design-rationale.md`; for the aeb boundary, see `LLM.md`; for a
single-competitor deep dive, `research/formae_vs_aeo.md`.

The one-line placement: **aeo is a *runtime* orchestrator of a *containment tree*
— declared as code, brought up gated on health, kept coherent, and torn down with
verification — where every node can be confined, attested, and audited.** Most IaC
tools own one of those words; aeo's shape is the combination.

---

## The landscape, by category

IaC isn't one category — it's several that people lump together. aeo overlaps a
few and belongs cleanly to none of the incumbents, because it targets a seam
between them.

| category | representative tools | what it's for | how aeo relates |
|---|---|---|---|
| **Cloud provisioners** | Terraform, Pulumi, OpenTofu, AWS CDK | declare cloud resources; a plan/apply reconciler drives an API to that state | aeo is **not** this — it doesn't do cloud-provider CRUD. It orchestrates *compute nodes on hosts you already have* (jails, bhyve, containers, KVM). Complementary: provision the box with Terraform, run the tree on it with aeo. |
| **Config management (agentless push)** | Ansible | reaches hosts over **ssh** and *pushes* convergence (no resident daemon) | Structurally the opposite of aeo's model: Ansible ssh-es in and *runs commands on the host*; aeo ssh-es in **once** to plant a deputy and then never again — the node's lifecycle rides a sealed channel to that resident agent (§5). |
| **Config management (agent-pull)** | Chef, Puppet, Salt | a **resident agent** on each host *pulls* desired state from a central master/server and converges the whole host | The **closest architectural cousin** — like aeo, a resident agent, not push-over-ssh. But the differences are the point: their agent converges the *entire host* (packages/files/services) against a central server; aeo's deputy stands up a **contained node**, exposes **zero ABI to the node's other processes**, needs **no central master** (per-boot courier key, not a standing enrolment), and self-installs only the substrate a workload needs. aeo is "agent-based like Chef/Puppet, but containment-scoped and master-less." |
| **Cluster orchestrators** | Kubernetes, Nomad | schedule + keep-alive workloads across a pool, with a control plane | aeo is the **closest in spirit** (declare → run live → keep coherent) but with **no cluster/scheduler**: it's a *tree you author*, not a pool a scheduler places into. No control plane to operate; the "control plane" is one binary per node. |
| **Local composers** | Docker Compose, Podman Compose | bring up a set of containers on one host from a file | aeo's `aeo up` *feels* like this at the surface, but it's health-gated (not just start-order), verifies teardown, spans **VMs and containers in one file**, and confines/attests each node. Compose is the closest daily-driver comparison. |
| **Host init / process supervisors** | cloud-init, systemd, s6, supervisord | bring a single host or its services up at boot | aeo's `aeo-agent` is the *recursive* version of this — a resident deputy that boots the node's tree and reports health outward, one level down, at every level. |
| **Agent-containment runtimes** | AWS Strands Box (and similar hostile-code harnesses) | contain a possibly-hostile **AI agent and the tools it runs**: one trusted process holds a policy engine (Cedar-style permit/forbid + temporal rules), an egress gateway, a credential vault and a decision ledger; the workload runs in an OS sandbox *outside* it | aeo takes the **lessons, not the product**. Shared discipline: *every guarantee has an enforcement point and evidence, and a failure refuses rather than silently falls back* — which is why `aeo status` separates **declared/supported/applied/verified** per property (`reference/status-schema.md`) and why `strict()` refuses an unenforceable node. But aeo is a **host orchestrator, not an agent harness**: it does not host AI agents, so a policy engine, credential vault and per-operation decision ledger are out of scope (they're a host's job *if* it ever hosts agents — parked, not planned). The parent-owned egress gateway aeo *is* building (`research/egress-fqdn-considered.md`) is the one Box pattern that lands squarely, because enforcing a node's egress from outside the node is a containment concern aeo already owns. |

aeo's actual seam: **"declared like Terraform, runs live like Kubernetes, on one
host like Compose, across VMs *and* containers, with containment as a first-class
axis."** No single incumbent covers that rectangle.

---

## What aeo does that the leaders don't

Six things are genuinely distinctive — not "we also have X" but "the category
leaders structurally don't."

### 1. Health-gated ordering, not schedule-gated or start-order

`aeo up` brings a node up and **blocks on its health check** before starting its
dependents; teardown is a reverse walk that **verifies each node is gone**.
Terraform has no runtime health concept (apply completes when the API says the
resource exists). Compose's `depends_on` is *start order*, not *ready*. Kubernetes
has readiness probes but you operate a scheduler to get them. aeo makes
health-before-proceed the default semantics of a plain `up`. (See
`design-rationale.md` §1–2.)

### 2. VMs and containers in the *same* composition, substrate-portable

One `.ae` file can declare a FreeBSD jail, a bhyve VM, a Linux podman container,
an LXC system container, and a KVM VM — and the **confinement grammar renders to
each substrate**: one `limit{}`/`constrain{}` vocabulary → FreeBSD rctl/Capsicum/pf
*and* Linux cgroups/seccomp/netpolicy. Terraform spans clouds but not "a jail and
a container in one health-gated tree"; Compose is containers-only; Kubernetes is
containers-only (KubeVirt bolts VMs on as pods). aeo treats VM and container as
peer node kinds behind one driver model.

### 3. Containment as a first-class, portable axis

Every node can be **confined** (resource caps so it can't starve the host;
cap-drop/seccomp so it can't escalate; deny-default egress so it can't phone
home), **attested** (image digest verified before boot, *fail-closed* — a
mismatched digest is refused), and **audited** (every security decision written to
a tamper-evident hash chain). This is the project's *purpose*, not a feature:
"infrastructure as a containment hierarchy." Incumbents offer pieces (K8s
admission control, network policies) but as separate subsystems you assemble; in
aeo it's the grammar of a node.

### 4. config IS code — a program, not a parsed document

The composition is an Aether `.ae` module you *run* — full language around the
declarations, no YAML/JSON/HCL ever. Terraform's HCL and K8s/Compose YAML are
*serialized documents parsed by a tool* — the "packaging mismatch" (per
Weiher et al., *Beyond Procedure Calls as Component Glue*, Onward! '24) that forces
templating languages, string interpolation, and a second-class expression layer on
top. Pulumi and CDK share aeo's config-is-code stance (real languages) — but they
target cloud provisioning, not a live containment tree. aeo is config-is-code
*for the runtime-orchestration seam*.

### 5. The resident-deputy agent: one ssh, then a sealed channel

To bring up a node, aeo doesn't reach *through* a boundary and run commands
(the antipattern). It plants a **resident agent** inside — one ssh to courier the
binary + a per-boot secret — and thereafter the node's lifecycle is driven over an
**AEAD-encrypted channel** (`lib/secure_channel`, pure-Aether Ascon-AEAD128, keyed
by the courier PSK, single-use + anti-replay). The agent exposes **zero ABI to the
node's other processes** — the workload gets no upward channel. Ansible/ssh-based
tools reach in and run; aeo installs a deputy that acts *from* inside and reports
*outward*, containment-safe. And the agent **self-installs its substrate** (podman
via the host package manager, jail base.txz, vm-bhyve init) — one binary in, a
capable host out. (See `operations/agent-host-setup.md`.)

### 6. Recursive by construction

The same protocol works at every depth: a parent hands a node's agent its
instructions; if that node itself contains children, *its* agent hands *them* to
their agents. The runner is just the depth-0 agent whose parent is the operator.
Kubernetes is flat (a pool); Compose is one level; aeo is a tree that recurses
through the containment hierarchy with one verb set.

---

## Where aeo draws its boundaries (on purpose)

A comparison that pretends a young tool has no edges isn't useful. aeo's
boundaries are **deliberate scoping**, not gaps to apologize for — each names a job
that belongs to a *different* tool in the stack:

- **No cloud-provider CRUD.** aeo doesn't create VPCs, load balancers, or managed
  databases via a cloud API — that's the provisioner's job (Terraform/Pulumi) or
  the reconcile-centric sibling's (Formae, see `research/formae_vs_aeo.md`).
  Provision the host *with* those; run the tree *on* it with aeo.
- **No static build graph.** aeo is the runtime layer; when it needs
  artifact-DAG/build-cache work it **shells out to aeb** (its build-runner
  sibling). Reimplementing a topo-sort inside aeo would make it a second aeb — an
  explicit non-goal.
- **No scheduler / cluster placement.** aeo orchestrates a tree you *author*, not
  a pool a scheduler bin-packs. That's Kubernetes/Nomad's domain; aeo's control
  plane is one binary per node, not a cluster to operate.
- **Young, focused ecosystem.** aeo is new and single-language (Aether). It has
  the correctness disciplines (health-gating, fail-closed attestation, audited
  decisions, honest proven-vs-modeled tracking) but not the decade of
  provider-plugins, community modules, and managed offerings the incumbents carry.

The through-line: aeo owns the **live containment-tree runtime** and cedes cloud
CRUD, build graphs, and cluster scheduling to the tools built for those. That
focus *is* the positioning.

---

## Quick reference

| dimension | Terraform | Kubernetes | Docker Compose | Ansible | **aeo** |
|---|---|---|---|---|---|
| primary job | cloud provision | cluster schedule | local containers | host converge | **live containment tree** |
| declared as | HCL (parsed) | YAML (parsed) | YAML (parsed) | YAML (parsed) | **`.ae` program (run)** |
| bring-up gate | API-exists | scheduler + probes | start order | task order | **health check** |
| verifies teardown | ❌ | ✅ (controller) | ❌ | ❌ | **✅** |
| VM + container, one file | ⚠️ (via providers) | ❌ (KubeVirt bolt-on) | ❌ | ❌ | **✅** |
| confinement as grammar | ❌ | ⚠️ (assembled) | ⚠️ limited | ⚠️ (you script it) | **✅ portable** |
| attest-before-boot, fail-closed | ❌ | ⚠️ admission | ❌ | ❌ | **✅** |
| tamper-evident audit | ⚠️ event log | ⚠️ event log | ❌ | ⚠️ | **✅ hash chain** |
| control plane to operate | state backend | yes (cluster) | none | none | **none (agent per node)** |
| reaches *into* hosts | n/a | n/a | n/a | ssh, runs cmds | **plants a deputy; sealed channel** |

Read the rows aeo doesn't lead as *scoping*, not deficiency: cloud CRUD is a
provisioner's row; cluster scheduling is an orchestrator's row. aeo leads the rows
that define **"stand a contained tree up, keep it coherent, tear it down with
proof."**
