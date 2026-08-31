# aeo TODO

Open work, honest about what's built vs. proven-live. The containment roadmap is
the live focus (GhostBSD box `paul@192.168.0.57`); see also
`docs/pf-enforcement-next-steps.md` and `docs/bsd-host-setup.md`.

## Merged from the macOS work-line (2026-07-06/07)

A parallel line developed + validated on the macOS dev box (Docker Desktop),
re-derived onto this architecture (engine() model, supervisor) after the two
lines diverged. Everything below is suite-green (193 passing) AND E2E-proven on
macOS+docker (up 1.8s warm -> curl 42 -> exec -> level-parallel down 6s, zero
leftovers). Live-prove on a Linux box for full confidence:

- [x] **lib/secrets — sealed values, encrypted-throughout** (the TODO's secrets
      engine, first cut). `aeo1:<salt>:<nonce>:<ct>:<tag>` envelope; stock-stdlib
      composition (HMAC-SHA256 labeled derivation, PRF-CTR keystream,
      encrypt-then-MAC, constant-time verify); FAIL-CLOSED everywhere; key file
      0600 (AEO_SECRETS_KEY / ~/.config/aeo/secrets.key), key material never on
      an argv. `aeo secrets keygen|seal|unseal`. The agent-token boundary is
      wired: runner._agent_token + driver_vm._agent_token_drv resolve() sealed
      AEO_TOKEN[_<node>] at the courier/seed boundary — ciphertext in
      env/state/logs, plaintext only at use. spec_secrets 10. NEXT CUTS: encrypt
      the token INTO the cloud-init seed (agent-side decrypt via ssh-couriered
      key); pluggable KMS/age/gpg backend; redact() sweep over status/logs.
- [x] **Front-door BUILD CACHE** — content hash over the full input closure
      (compose + every lib/ file + `ae --version`) recorded beside the staged
      binary; match -> skip restage+recompile (measured 3.2s -> 0.26s, 12.5×).
      NOT a build-graph cache (aeb's line): one artifact, whole closure, can't
      serve a stale mix. AEO_REBUILD=1 forces; no sha tool -> always rebuild;
      hash written only after a completed build. Stub compositions
      (extract/inventory) hash /dev/null.
- [x] **LEVEL-PARALLEL teardown** — run_down mirrors the bring-up engine:
      reverse topological levels over BOTH edges (depends() + containment host —
      a nested node tears down before its guest); engine containers halt in ONE
      down_many sweep per distinct engine() (stop grace paid once per level —
      measured 15.6s -> 6.3s at width 3 vs SIGTERM-ignoring containers);
      dedicated-driver kinds keep per-node actor Halts; wait_for_idle() is the
      level barrier (state can't be: Configure sets STATE_DOWN before Halt runs
      — the old per-node _await_down was silently a no-op); ONE poller verifies
      the level's disappearance (without() windows concurrent = max not sum;
      engine nodes get a 2s floor so a failed rm surfaces). spec_teardown_batch.
- [x] **container kinds ENGINE-gated, not family-gated** — runnable wherever
      podman/docker resolves (macOS via Docker Desktop unlocked; Linux-without-
      engine now fast-fails at eval time). WSL engines still gate via their
      driver. FOUND EN ROUTE: engine_resolve returned NULL (os_which null
      footgun) — every docker-only host ran `(null) run …` AND
      spec_running_nodes + spec_integration_app silently skip-as-passed for
      their whole life (now genuinely run against docker); podman-only
      `--replace` -> docker pre-clears with rm -f; podman-only `network exists`
      -> engine-portable `network inspect`; spec_integration_app's
      std.http.client -> curl (client SIGABRTs intermittently on macOS).
- [x] **`aeo doctor`** — per-kind host capability report (engine paths,
      /dev/kvm, family, secrets-key posture) + fix hints; compose-less. The
      interactive twin of the eval-time fast-fail gate.
- [x] **limit_cpu/pcpu -> podman --cpus** (integer math; 150 -> "1.5"; bogus ->
      no flag). The CPU axis now enforces on Linux; spec_confine_linux 15.
- [x] **README "Try it in 60 seconds"** — build front door, doctor, build the
      demo app image, up, curl, status/exec, verified down. Works on a stock
      Mac or Linux box with docker/podman.
- [x] **ae-0.338 selective-import quirk RESOLVED on ae 0.364** — the phantom
      `string.copy`/`os_platform`/`os.now_monotonic_ns` from selective-only
      std.string/std.os imports is gone on 0.364 (upgraded via the canonical
      installer; 0.338 stays version-managed for rollback). EVERY bare-import
      workaround deleted (6 mine + 9 legacy aeocha ones across the specs);
      bin/aeo.ae moved to qualified `os.*` calls (designs the trigger out, not
      a workaround). Suite 193 green on 0.364, no bare-import crutches.
- [x] **Perf pass, all serial/quadratic paths closed** (ae 0.364):
      - `aeo status` (both text + `--json`) now does ONE `ps` per distinct
        engine for all host-visible container nodes instead of one probe per
        node (the _status_alive_set batch, same shape as the bring-up/teardown
        pollers). VMs/jails/sandboxes/nested keep their per-node probe.
      - run_down computes teardown depths ONCE into a std.intarr (indexed by
        declaration order) instead of re-walking each node's parent chains per
        level — O(N) depths, not O(N·levels) chain walks.
      - lib/secrets hex plumbing (_hex_of/_unhex/_xor_hex/_keystream) rebuilt on
        std.strbuilder — O(n) append, not O(n²) string-concat; keygen is now
        fully native (cryptography.random_hex + fs.write_atomic + fs.chmod 0600,
        no shell/od/tr subprocess); load_key is a direct fs.read (no shell).
      - inspect_state uses os.run_full (separate stderr capture) so an absent
        container's "No such object" no longer leaks onto aeo's stderr during
        `aeo dry-run`/reconcile.

## Containment / impregnability roadmap

The question driving this: *orchestrated trees of compute nodes that contain
malware and are impregnable to attack.* Two axes — stop a node REACHING things
(constrain) and stop it STARVING the host (limit) — plus supply-chain + forensics.

| Axis | Built | Live-proven | Notes |
|---|---|---|---|
| **jail nodes (driver_bsd)** | ✅ | ✅ **real jail boots+probes+contains, live** | the UNBLOCKED path — no bridge/NAT |
| pf network policy | ✅ rulegen | ❌ inter-VM delivery BROKEN (if_bridge) | needs design rethink — see below |
| rctl resource caps | ✅ | ✅ live + orchestrator-guarded | real-node deny proof pending |
| Capsicum device grants | n/a | n/a | bhyve self-confines — no seam |
| **Linux container confinement** | ✅ | ✅ **cgroups+cap-drop+netpolicy, fork-bomb refused live** | lib/confine_linux; reuses limit{}+constrain{} grammar (§5) |
| Image attestation | ✅ | ✅ **verify-before-boot, fail-closed; wrong digest refused live** | attest("sha256:..."); 3 greppable states (attested/unpinned/unattestable) |
| Audit trail | ✅ | ✅ **tamper-evident hash chain; tamper + attest-refuse caught live** | lib/audit; `aeo audit` verifies the chain (§4) |

### 0. jail nodes — LIVE-PROVEN (the unblocked containment path)
Jails share the host network stack, so the bhyve bridge/NAT bug DOESN'T apply —
this is where aeo's containment is both strongest and now demonstrated live.
Validated 2026-06-25 on the box:
- [x] Populated a jail root (`/zroot/jails/aeo-rj` + `/rescue/{sh,test,ls}`).
- [x] Booted a REAL jail via the exact `driver_bsd` command sequence:
      `jail -c name=aeo-rj path=... host.hostname=aeo-rj persist` → jail CREATED.
- [x] Probed: `jls` shows JID + hostname (driver_bsd.probe path).
- [x] In-jail exec: `jexec aeo-rj /rescue/test -d /` passed; `ls /` shows ONLY
      the jail's own root (dev, rescue) — NOT the host's — i.e. contained.
- [x] Closed the loop: aeo's `jail_create_argv` emits EXACTLY the command that
      worked live (byte-for-byte), and `smoke_bsd` (driver pure-logic) passes.
- [x] **driver_bsd self-sudo** — jail/jls/jexec/zfs now run via `sh -c "sudo -n
      <prog> <squoted-args>"` (a `_sudo_run` helper, like driver_vm), so the aeo
      binary no longer needs to be root. Paths match the box sudoers exactly
      (/usr/sbin/jail family + /sbin/zfs). smoke_bsd green; argv builders
      unchanged (the tested pure surface).
- [x] **Un-parked `test/real_jail.ae`** into `test/` — now a normal spec (runs
      unprivileged; the sudo is inside the driver). Builds + fails gracefully off
      FreeBSD; runs for real on the box (needs a populated jail root via
      setup-jail-root.sh). Box-validate when it's back.
- [x] Apply rctl caps to a live jail node end-to-end: booted db+app jails on the
      box, applied the demo's exact rules (jail:db:memoryuse:deny=512M, maxproc
      32; jail:app:maxproc 128), kernel accepted, read back, cleaned up. The
      jail-boundary + rctl axes BOTH live on real nodes.
- [x] **A jail-based apex example** — `examples/silly_addition_jails.ae`, the
      sibling of silly_addition_bhyve_podman.ae: two rctl-capped jails (db <- app),
      all-in-one (check/up/suite). check 3/3 standalone; both build doors green;
      live suite assertions (jls running + `jexec ls /` shows only the jail root,
      not /home) validated on the box.
- [ ] Capsicum-in-jail on the live node (spec_capsicum_jail_selfreport proves the
      mechanism; combine with the demo for the full three-axis showcase).
- [ ] Run the jail demo's `up`/`suite` via real `aeo up` once driver_bsd can run
      privileged (self-sudo or a root grant) — same blocker as real_jail.ae.

### 1. pf network policy — inter-VM delivery BROKEN, needs design rethink (HIGH)
Rulegen (lib/pf, lib/compose) is correct + unit-tested. The bite-step pf.conf was
applied and host mgmt preserved. BUT the live two-guest behavioral test
(2026-06-25) proved the inter-VM *enforcement path* does not work on the shared
bridge — full writeup in `docs/pf-enforcement-next-steps.md`:
- [x] Behavioral acceptance test RUN — and it FAILED honestly. Found: (a) pf
      doesn't filter bridge traffic by default (`pfil_member=0` → anchor never
      sees inter-VM packets); (b) with `pfil_member=1`, deny-default works but the
      whitelist PASS can't complete a handshake (if_bridge per-member dual
      evaluation drops the stateful return path). Reverted to known-good.
- [ ] **DECIDE the delivery architecture** (this is the fork): per-VM epair +
      routed L3 (pf filters normally, no bridge), vs `pfil_bridge=1` (filter once
      on the bridge), vs guest-side firewall via the resident agent. See doc.
- [ ] Re-run the 4 assertions once a working delivery is chosen (the test harness
      + two guests aeo-base/.50 + testpeer/.51 are proven and reusable).
- [x] Lockout-safety: Paul has console (kbd/display); pf/rctl missteps recoverable.

### 2. rctl resource caps — LIVE (MEDIUM)
`limit{}` grammar + lib/rctl + runner wiring built; `spec_rctl_rulegen` green
(8, incl. the orchestrator-guard). Host prereqs DONE + live-validated 2026-06-25.
- [x] Host prereq: `kern.racct.enable=1` in `/boot/loader.conf` + reboot — done.
- [x] Host prereq: `/usr/bin/rctl` granted in the `aeo-pf` sudoers drop-in.
- [x] Live: `jail:testjail:maxproc:deny=10` added/read-back/removed cleanly on
      the box (RACCT on); orchestrator session untouched.
- [x] **Never-cap-the-orchestrator guard** (lib/rctl `_subject_ok`): refuse
      user/loginclass subjects; only jail/process (node-scoped). Found the hard
      way — a `user:paul` vmem cap locked sshd out and needed a reboot.
- [ ] Behavioral deny on a REAL node: stand a jail with a maxproc cap, prove a
      fork-bomb inside it is refused (the live "it actually contains" proof).
- [ ] Thicken: cap **bhyve-VM** nodes too (v0 caps jails only — needs the
      hypervisor PID → `process:<pid>` targeting). Runner logs "NOT enforced
      (kind=bhyve)" loudly rather than skipping silently.

### 3. Image attestation — DONE + LIVE (lib/attest, 2026-06-27) — supply-chain
- [x] **Grammar**: `attest("sha256:...")` pins a node's expected image digest.
- [x] **Verify-at-boot, FAIL-CLOSED**: the runner resolves the image's ACTUAL
      digest, refuses on mismatch (loud), runs image@<digest> so podman enforces
      the pin too. LIVE: correct pin boots by-digest; WRONG pin -> "DIGEST
      MISMATCH ... refusing to boot", container refused.
- [x] **3 greppable states** (Paul's audit idea): attest_state -> "attested" |
      "unpinned" (pulled, no pin — a finding) | "unattestable" (built from
      entrypoint/dockerfile — no upstream digest). In `aeo status` + `--json`
      (attestation/attest_digest fields) so a CI gate can fail on
      attestation!="attested". spec_attest 5.
- [ ] Follow-up: trust root beyond operator-pinned hashes (cosign/skopeo are on
      Bazzite — a signature path). Also: attest a qcow2 / jail-dataset hash
      (same shape, swap the digest probe) so attestation spans substrates.

### 4. Audit trail — DONE + LIVE (lib/audit, 2026-06-27) — forensics
Containment BLOCKS; the audit trail OBSERVES. Append-only, HASH-CHAINED log of
every security DECISION aeo makes per node.
- [x] **record + hash chain**: each entry hash = sha256(prev + payload); editing/
      deleting any past line breaks the chain. Events: attest-pass/attest-refuse
      (supply-chain verdict) + confine (the posture). LIVE: confined demo recorded
      both nodes' exact posture, chained.
- [x] **`aeo audit` verify**: walks the chain, reports INTACT or "CHAIN BROKEN at
      N". LIVE: edited the log to hide db's --network none -> CAUGHT. A bad-digest
      boot recorded as attest-refuse. spec_audit 5.
- [x] NB: distinct from std.audit (Aether's in-process SANDBOX permission ring) —
      this is aeo's INFRASTRUCTURE audit.
- [ ] Follow-up: arrival timestamps (Date.now is unavailable in scripts — the
      sink/caller stamps); pf-logged blocks / rctl denials as events (FreeBSD
      side); per-node connection logging on the deny-default.

### 5. Linux container confinement — DONE + LIVE (lib/confine_linux, 2026-06-27)
The rootless Linux peer of the FreeBSD Capsicum/rctl/pf axes — and it REUSES the
same grammar (limit{} + constrain{}), so confinement is substrate-portable (the
driver picks rctl/Capsicum/pf on FreeBSD vs cgroups/seccomp/network on Linux).
- [x] **cgroup caps** (rctl peer): limit{} -> --memory / --pids-limit / --ulimit.
      LIVE: fork-bomb in db REFUSED by --pids-limit 32 ("can't fork: Resource
      temporarily unavailable").
- [x] **seccomp / cap-drop** (Capsicum peer): a constrain{} node -> --cap-drop
      ALL + --security-opt no-new-privileges (+--read-only on deny_egress). LIVE:
      podman inspect shows db CapDrop=ALL.
- [x] **netpolicy** (pf peer): deny_egress() -> --network none. LIVE: db has no
      network namespace — can't phone home. (Per-flow egress/ingress whitelist
      beyond on/off is a follow-up — podman has no per-flow filter without extra
      tooling; --network none vs shared is the v0 deny-default. NB: podman nets
      are routed/NAT'd not bridged, so the richer policy MAY sidestep the FreeBSD
      pf+if_bridge bug — worth revisiting for that.)
- [x] **grammar reuse achieved**: limit{}+constrain{} render to BOTH substrates.
      lib/confine_linux (spec_confine_linux 10); driver_linux up_confined;
      runner._confine_flags. Demo: examples/silly_addition_confined.ae.
- [x] **per-flow container netpolicy** — DONE + LIVE 2026-06-27. 3 tiers via
      podman per-network isolation: deny_egress->none, peer egress->--internal net
      (reach peers by name, NOT the internet), ingress/none->shared. net_kind
      classifies; egress targets pulled onto the internal net. LIVE: app
      (egress->db) reaches db but CANNOT reach the internet. SIDESTEPS the pf+
      if_bridge bug (§1) — podman routed nets, no bridge filter. spec 12.
- [ ] Follow-up: --cpus from pcpu (limit_cpu); finer ingress_from peer-scoping
      (v0 internal-net is per-system, not per-pair); SELinux-aware podman
      handling on Bazzite/Fedora hosts (bind-mount relabel policy such as `:Z`,
      refuse/avoid unsafe `$HOME` relabels, document/profile-test the host
      traps currently only noted in `docs/build-in-container.md`).
- [ ] **Layer-7 egress: `egress_fqdn(...)` allowlist** — PARTIAL BUILD:
      compose/model surface + CONNECT parser/decision core + length-aware relay
      helpers landed (`lib/egress_relay`, `test/spec_egress_relay.ae`), and the
      std.http CONNECT gateway landed (`lib/egress_gateway`,
      `bin/aeo-egress-gateway.ae`, `test/spec_egress_gateway.ae`). Aether's
      length-aware TCP prerequisite is merged to `origin/main` (aether#1079 from
      aether#1078), and Aether #1086 added std.http server tunnel handoff via
      `http.response_accept_tunnel`; the standalone gateway now takes ownership
      after an allowed CONNECT and pumps opaque bytes with length-aware TCP I/O.
      Design captured in
      `docs/research/egress-fqdn-considered.md` (2026-07-08, prompted by Formae's
      FQDN-allowlist agent setup). The layer-3/4 netpolicy above filters by
      IP/net; the exfil-hardening threat (a prompt-injected agent holding live
      creds) wants a DESTINATION-NAME allowlist. A packet filter structurally
      can't (name is gone by SYN-time; CDN IPs are huge/rotating), so it lowers
      to a parent-owned CONNECT allowlist gateway the node's routed through (no
      MITM), default-drop+log. Decisions on record: **build** the FQDN allowlist;
      **reject** HTTP-method limiting (forces MITM *and* GET isn't read-only —
      body + query-string exfil; can't enforce data-flow with a metadata filter);
      the child never owns its own gateway; hierarchy = each level enforced by
      the level above; any `X-Aeo-Path` containment context is **parent-stamped,
      never child-asserted** (narrow-only, identity bound by the authenticated
      channel). Next: audit + namespace/routing enforcement that makes the
      gateway unbypassable, plus committing the live loopback tunnel smoke into
      the normal test suite.
      Residual hole (exfil THROUGH an allowed host) is answered by credential
      scoping, not more network filtering.

## Lifecycle & state ops (snapshot / rollback / backup / prune / exec / restart)
Day-2 operability for a STANDING deployment: capture point-in-time state, restore
it, retain it, and reach into / restart individual nodes — without becoming a
platform (no web UI, no daemon, no HA — those cross the "aeo is not a platform"
line). Config-is-code intact. Proxmox is the comparison, not the goal: these are
aeo's own verbs; the inline "Proxmox-X" notes just point at the familiar analog.
- [x] **snapshot/rollback** — `aeo snapshot|rollback <compose.ae> [tag]` over each
      node's ZFS dataset (lib/snapshot; jail=declared dataset, bhyve=zroot/vm/<n>).
      Pure logic spec'd (spec_snapshot, 6); live zfs box-validated later.
- [x] **enriched `aeo status`** — per node now shows ip / rctl caps / pf netpolicy
      / Capsicum grants / snapshots, only where set. Live state still driver-probed.
- [ ] Live-validate snapshot/rollback on the box (zfs snapshot a jail, roll it
      back) once it's back from the storm. [the FreeBSD/ZFS side — still pending;
      box is on Bazzite. The LINUX side is now done + live, see below.]
- [x] **Linux-side operability** (lib/snapshot_linux) — snapshot/rollback/backup/
      prune for container/kvm/lxc (the verbs were ZFS-only). container = podman
      commit -> image; kvm = qemu-img snapshot; lxc = lxc-snapshot. Runner
      dispatches on kind. LIVE on Bazzite 2026-06-27: container round-trip proven
      (snapshot -> change /marker.txt -> rollback -> restored), backup -> real
      .tar artifacts. spec_snapshot_linux 3.
      - [x] kvm validated 2026-06-27: offline snapshot (v1/v2 on a qcow2) + PRUNE
            keep-N (seeded a/b/c, keep=2 -> {b,c}, dropped oldest). FOUND: kvm
            snapshot is OFFLINE-ONLY — qemu write-locks a running VM's qcow2
            ("Failed to get shared write lock"), unlike ZFS/podman (live). The
            driver now returns an actionable "aeo down first" message (_qemu_offline).
      - [x] lxc validated 2026-06-27 (lxc-snapshot/lxc-copy sudoers grant added):
            snapshot @v1 -> snap0 (both containers, offline stop->snap->start, both
            RUNNING after); rollback snap0 -> /marker.txt restored. FOUND: lxc-
            snapshot is OFFLINE + AUTO-NAMES (snap0, not operator tags) — the driver
            now does stop->snap->start and restores by snapN. ALL THREE Linux
            substrates (container/kvm/lxc) now live for lifecycle ops.
- [x] **`aeo status --json`** — machine-readable status (flat array of node
      objects: name/kind/system/host/depends/state/ip/caps/netpolicy/grants).
      Validated through a real JSON parser on both demos (paths/<-/= chars
      escape cleanly). The Proxmox-API value without the web server: pipe to jq/
      a dashboard/a CI gate.
- [x] **per-node lifecycle** — `aeo exec <compose.ae> <node> <cmd>` runs a command
      IN one node (jail=jexec, bhyve=ssh, container=podman-exec, nested=ssh-to-host
      +podman); `aeo restart <compose.ae> <node>` down+ups a SINGLE node without
      touching the tree (Proxmox per-VM stop/start). Per-kind driver_exec()
      dispatch + driver_{bsd,vm}.exec_capture(); clean error handling (unknown/
      missing node/cmd). Built + dispatch-tested here; live on box.
- [x] **backup + prune** — `aeo backup <compose.ae> <tag> [dir]` zfs-sends each
      node's @tag snapshot to a portable `<dir>/<node>-<tag>.zfs` stream
      (restore = `zfs receive`); `aeo prune <compose.ae> [keep]` keeps the N
      newest-by-CREATION snapshots per node, destroys older. Composable verbs
      (operator snapshots, then backups/prunes). Backup surfaces failures + cleans
      up partial artifacts (no false success). backup_file path unit-tested
      (spec_snapshot, 8); live zfs send/destroy box-validated later.
- [ ] NOT doing (against the grain, design-doc line): web UI, clustering/multi-
      host default, live migration, HA. A `driver_proxmox` (orchestrate a Proxmox
      host as a substrate) is the aeo-shaped alternative if that itch returns.

## Resource-kind coverage (which `kind`s are real vs demo'd)

aeo's grammar exposes 6 kinds + a flavor. Demo'd: container/jail/bhyve/kvm/lxc.
Gaps:
- [x] **`proxmox` — REMOTE substrate (first API-driven kind). LIVE-PROVEN
      2026-07-11 (up + down against a real PVE box, 192.168.0.204).** aeo's first
      substrate driven over an HTTPS API (PVE :8006) rather than local shell-out.
      `proxmox_vm(){ host/node/auth_token/storage/bridge/template }`; flat leaf VM
      (mirrors kvm_vm). Grammar (`071cba9`): compose 6 setters/getters,
      `proxmox_model_errors()` gate wired into runner `_preflight` + `check`,
      `proxmox` host-family-agnostic in `_kind_runnable`, reset_nodes clears pve*.
      DRIVER `lib/driver_proxmox`: a pure API client on **std.http.client** (native
      Aether HTTP — NOT curl; the same stack std.http.proxy backs the LB with).
      up: resolve template VMID → clone into pool → poll → PUT cloud-init → start →
      poll running. down: resolve → stop → destroy(--purge) → poll gone. probe:
      status/current == running. LIVE: `aeo up examples/silly_addition_proxmox.ae`
      → db_vm+app_vm RUNNING on the box; `aeo down` → both destroyed, template
      preserved; clean up→down cycle repeatable. Specs green (proxmox_model 7,
      proxmox_suite 2, LB 16, reconcile 11, confine_linux 16).
      THREE live findings baked into the driver + docs: (1) a least-priv token can
      only clone a template that is a MEMBER of its pool (else invisible); (2)
      PVE `sshkeys` is DOUBLE-url-encoded; (3) PVE VM names must be DNS labels — an
      aeo node `db_vm` is sanitized to `db-vm`. Also fixed a RUNNER bug that bit the
      new kind: `_kind_has_driver` didn't list `proxmox`, so `_engine_downable`
      routed it to the podman/docker down-sweep, which no-op'd — `aeo down`
      falsely reported "gone" while the VMs kept running. Any future dedicated-
      driver kind must be added to `_kind_has_driver` too. TOKEN: least-priv CISO
      setup (`examples/checks/proxmox_token_setup.sh`+`.md`) — dedicated user,
      custom minimal role, resource-pool blast radius, privsep+expiring token,
      PROVEN allowed-vs-denied. HOST CHECKS (2026-07-11, live-proven): (1) remote
      PREFLIGHT wired into `aeo check` — driver_proxmox.preflight() reaches the box
      with the token and verifies deploy-readiness (template is a pool member,
      storage + bridge exist); reachable-but-misconfigured -> LOUD fail, unreachable
      -> warn + still validate the model (the gpu-preflight discipline); driver
      also gained reachable(). (2) test/spec_pve_host_live.ae — executable proof the
      host is deploy-ready AND the token is least-priv (create-user / self-ACL /
      node-reboot all DENIED 403); self-skips as PASS with no PVE_TOKEN. FRONTIER
      follow-ups: (3) POST-PROVISION / in-guest completion — see the dedicated item
      below; (4) TLS CA PIN — DONE + LIVE-PROVEN 2026-07-11 (commit 00e537e). The
      driver couriers PVE's own private CA over the initial ssh
      (examples/checks/proxmox_pin_ca.sh -> AEO_PVE_CACERT) and PINS it: _pve() does
      set_cafile(ca)+set_insecure(0) when AEO_PVE_CACERT is set (verify against THAT
      cert, fail-closed), else set_insecure(1) fallback. Unblocked by aether
      set_cafile (#1107 + trust-store fix #1110, v0.384.0 — both were filed as
      ../aether/asks/ and landed). PROVEN: right CA -> preflight VERIFIES + passes;
      wrong CA -> 8006 verify fails (rejected, not blind-trusted); full up/down over
      pinned TLS. Remaining nit: the couriered CA is one file for the whole box
      (fine); a per-node cert or a fingerprint-only pin could follow if ever needed.
- [~] **PVE post-provision: complete the node IN-GUEST via cloud-init (RUNG 1 LIVE-
      PROVEN 2026-07-11); aeo-agent seeding is the next layer.** BUILT + proven:
      compose grammar `cloud_init(snippet)` + `agent(on)` (+ getters, reset, exports,
      model spec 9); driver_proxmox up() sets `cicustom` from cloud_init() with the
      LEAST-PRIV token (proven: referencing a snippet needs only VM-write, not
      storage-write — operator places the file, token references it); probe()
      upgraded so `agent(1)` waits for the qemu-guest-agent to RESPOND (guest OS
      alive) before UP, not just "hypervisor running". LIVE: `aeo up` on a
      cloud_init+agent node -> clone -> driver-set cicustom -> guest installs
      qemu-guest-agent -> agent-probe 200 -> promoted UP; `AEO_PROVISIONED` marker
      confirmed in-guest; `aeo down` clean. examples/checks/proxmox_cloudinit.yaml is
      the operator snippet (installs guest-agent + marker; has the aeo-agent-seeding
      hook stubbed). TOKEN: added VM.GuestAgent.Audit (READ-ONLY ping only; Exec/
      Unrestricted/FileRead/Write still excluded — did NOT weaken any denial, host
      spec still 4/4). NEXT LAYER (the aeo-agent DOER): extend the snippet's runcmd
      to fetch+launch bin/aeo-agent with AEO_NODE/AEO_TOKEN/AEO_RENDEZVOUS seeded
      (token via lib/secrets), so the agent completes the node + runs its workload
      CONTAINER (driver_linux) and reports outward; probe() then checks the workload,
      not just guest liveness. The design/layering below stands as the plan for it.
- [~] **aeo-agent DOER layer — LIVE-PROVEN end-to-end 2026-07-11.** The recursion
      closes: proxmox VM (driver_proxmox) -> guest aeo-agent -> workload CONTAINER
      (driver_linux) -> report outward. DELIVERY (Paul's call): aeo-agent is fetched
      from GITHUB RELEASES + SHA256-verified in-guest (NOT baked / NOT ssh'd — PVE
      snippets are text-only w/ no write API, so the guest fetches; Releases is the
      durable checksummed host). BUILT: `.github/workflows/release-aeo-agent.yml`
      (builds ae via aether get.sh -> glibc linux-amd64 -> sha256 -> Release asset;
      triggers on `aeo-agent-v*` tags; dev asset `aeo-agent-dev` published now).
      `examples/checks/proxmox_cloudinit.yaml` rewritten: installs qemu-guest-agent,
      curls the agent + `sha256sum -c` (fail-closed, attest()-style), starts it
      (http :9450, 0.0.0.0), backgrounds podman. LIVE PROOF: `aeo up` -> cloud-init
      "agent fetched + verified" + "agent started" -> agent /health=200 reachable
      from the orchestrator over the LAN -> POST /dispatch "boot" -> "report ... up"
      -> busybox workload CONTAINER confirmed `podman ps` Up in the guest -> `aeo
      down` clean. RE-PROVEN against the IMMUTABLE versioned release aeo-agent-v0.1.1
      (asset aeo-agent-linux-x86_64-glibc, SHA a6713fc0) 2026-07-11: fetch+verify ->
      /health 200 -> dispatch boot -> "report ... up" -> busybox container Up. The
      GitHub-Releases delivery is CI-published + versioned-only (see the CI item).
      TWO PRODUCTION-SEEDING GAPS (mechanism proven; these are polish):
      (1) IDENTITY — a generic image boots hostname "localhost" so AEO_NODE=localhost.
      LIVE-INVESTIGATED 2026-07-11, BOTH clean paths are BLOCKED for the least-priv
      token: (a) SMBIOS serial — guest CAN read /sys/class/dmi/id/product_serial (no
      root), but setting `smbios1` needs VM.Config.HWType -> 403 (token widening); (b)
      PVE NoCloud meta-data doesn't carry local-hostname, and our cicustom user-data
      overrides the name-derived default, so the guest never sees the VM name through
      a token-writable channel. So the real options are: DRIVER GENERATES a per-node
      cicustom (writes hostname/AEO_NODE) + places it via ssh-to-PVE-host (token stays
      least-priv; driver gains host ssh — but it's config text, not a 5MB binary), OR
      widen the role with VM.Config.HWType + set smbios1=serial=<node> (token-only, +1
      config priv, guest reads product_serial). DECISION DEFERRED (Paul: revisit
      later) — AEO_NODE=localhost only matters once multi-node identity/recursion is
      exercised, which the demo doesn't yet.
      (2) TOKEN — dev token in the snippet; prod seals a per-node token via
      lib/secrets and seeds it (same per-node-cicustom seam as identity option (a)).
      Neither changes the doer mechanics. NEXT (when picked up): seed identity+token
      per-node from the driver; then probe() checks the WORKLOAD (agent reports its
      container healthy), not just guest-agent liveness.
      ORIGINAL DECISION (2026-07-11, debated + spiked live): the template
      stays a GENERIC cloud image; the node's identity is completed at runtime from
      inside, by aeo-agent (aeo's native "act inside, report outward" recursion — a
      PVE VM is just another boundary; the agent one level down completes it). Baking
      a workload into the template is the anti-pattern (makes the template node-
      specific, bypasses the agent boundary). The substrate is a VM RUNNING A
      CONTAINER (driver_proxmox VM -> guest aeo-agent -> workload container via
      driver_linux; the kvm_podman cell, one substrate over) — NOT a PVE LXC (PVE CTs
      exist at /nodes/*/lxc but we deploy /qemu VMs).
      LAYERING (irreducible order, spiked live):
        1. cloud-init is the TRUE first rung (only thing that runs with zero guest
           cooperation): installs qemu-guest-agent, drops+starts aeo-agent, seeds
           AEO_NODE/AEO_TOKEN/AEO_RENDEZVOUS (token via lib/secrets). cicustom=
           user=local:snippets/<f>.yaml needs snippets enabled on a storage +
           admin to set (operator prereq, not the least-priv token).
        2. IGNITION options to launch/drive the agent:
           (B) exec-in over 8006: /qemu/<id>/agent/{exec,file-write} (virtio-serial,
               no guest net). LIVE-PROVEN COST: least-priv token gets 403
               (VM.GuestAgent.Audit|Unrestricted) — REQUIRES widening the role.
               Best used as one-shot IGNITION only (open GuestAgent for one call,
               then the agent's own report-out is the control plane).
           (A) report-out: agent dials a rendezvous outbound; parent never connects
               in; token stays pristine. Needs a rendezvous both sides see.
        3. aeo-agent = the DOER: runs the workload container, reports outward; probe()
           upgrades from "hypervisor says running" to "agent announced".
      BOX-SPECIFIC FINDING: this PVE's vmbr0 is 192.168.0.204/24 = the home LAN, so
      guests get LAN IPs and are DIRECTLY reachable from the orchestrator (agent
      transport_http works with NEITHER the 8006 hole NOR a host agent). On a
      hardened prod PVE (isolated/NAT'd guest bridge, hypervisor firewalled to 8006)
      the wall is real and the above matters; here the direct-LAN happy path is the
      place to build+prove first. (efs2 /home/paul/scm/efs2 is the prior reach-in
      RUN/PUT-over-ssh model — correctly demoted to IGNITION-only, not the operating
      model, because ssh-at-distance has no socket through 8006.)
- [ ] **PVE host-resident aeo-agent = health MULTIPLEXER + depth-1 sub-runner.**
      Paul's idea (2026-07-11): put an aeo-agent ON the PVE host (unusual for PVE).
      Because the host sits ON the guest net (vmbr0 = the LAN here), it reaches every
      guest DIRECTLY and reports ONE aggregated health signal outward — no per-guest
      8006 hole, NO GuestAgent token-widening (health goes host->guest over the
      bridge, not the API). It's aeo's depth-1 sub-runner landing on a remote host
      (the PVE box BECOMES an aeo node that contains VMs). COMPLEMENTARY to the
      post-provision item (health layer, not provisioning). COST: an agent on the
      hypervisor (operator imposition). RECONCILE with [[aeo-supervisor-design]] —
      a host-side PVE agent is arguably that supervisor specialized to a hypervisor;
      don't build twice.
- [ ] **PVE token hardening (deferred — not now).** The current least-priv token
      is CISO-grade for the demo, but a larger-org prod bar could add: (a) TOKEN
      IP-ALLOWLIST so a leaked secret is useless off-network; (b) prove EXPIRY
      actually 401s after the timestamp (we set expire= but haven't watched it
      lapse); (c) a read-only `aeo-auditor` role split from the deployer (status/
      audit needn't carry VM.Clone/PowerMgmt); (d) an ACL-DRIFT detector (aeo
      re-reads /access/acl at check and flags scope creep vs the declared grant).
      None block the driver; all are defense-in-depth polish.
- [ ] **PVE DRIFT CHECKER (`proxmox_token_setup.sh --verify`).** A non-destructive
      ops-side check that the CISO setup is STILL clean: re-run the allowed/denied
      probes and report drift vs the declared intent — role privs == the declared
      ~15 (no widening), token still `privsep=1` and scoped to `/pool` (+storage/sdn)
      only (not `/`), token not expired (and how many days left), template still a
      pool member, no extra ACL entries crept in. Exit non-zero on any drift so CI/
      cron can gate on it. This is the STANDING-STATE partner to the check-time
      preflight (which asks "ready to deploy?"); --verify asks "is the credential
      still as locked-down as we declared?". Overlaps token-hardening item (d)
      (ACL-drift) — fold them together.
- [x] **`lxc` is now REAL** — was a misnomer (routed to podman). driver_lxc built
      + wired (runner up/down/probe/exec) + silly_addition_lxc.ae; LIVE on Bazzite
      2026-06-27 (rootful via the lxc-* NOPASSWD sudoers grant + `systemctl enable
      --now lxc-net` for lxcbr0). `aeo up`->two alpine system containers RUNNING,
      `aeo exec db hostname`->"db" (contained), `aeo down` clean. (busybox template
      fails — no busybox binary on the host; the download/alpine template works.
      Rootless LXC stays blocked on this atomic host — rootful is the path.)
- [ ] **PORT the self-sudo argv fix to driver_bsd** — driver_bsd._sudo_run has
      the SAME latent bug driver_lxc hit: it interpolates argv with "${a}" into an
      `sh -c` string, yielding the element ADDRESS not the string. Its argv
      builders are unit-tested but the live self-sudo path apparently never ran for
      real. Fix: pass argv DIRECTLY to run_capture("sudo", [...]) with list_add_raw
      ptr-copy (as driver_lxc now does, like driver_vm's qemu exec). Until then,
      jail/jls/jexec via driver_bsd self-sudo would mangle their args live.
- [~] **`engine()` property — CORE BUILT + LIVE-PROVEN 2026-07-04; examples pending
      (Paul migrating). See docs/research/grammar-design-proposals.md §D.** DONE: compose `engine()` verb
      (system-float + node override, snapshotted at decl like within/every) +
      `get_engine()`; deleted docker/windows/wslc KIND-verbs; rerouted all runner
      dispatch (up/exec/down/probe + batch-liveness `_level_has_engine`) to key on
      `container` + resolved engine; deleted dead `_engine_of`/`_level_has_batch_kind`.
      Both Windows DRIVERS kept (engine value = driver selector: wslc→driver_wslc,
      wsl_podman→driver_windows). LIVE on bazzite (podman 5.8.2 + docker 29.5.3):
      `engine()` float+override verified (system engine("docker") floats, node
      engine("podman") overrides); the DOCKER-SECOND-CLASS BUG FIXED — an
      engine-pinned container now gets `--memory 128m --pids-limit 16` + the shared
      `aeo-<system>` network (podman inspect confirmed mem=134217728 pids=16
      nets=aeo-engine_demo), which the old plain-up() docker path dropped. 22 spec
      files pass, no regression. STILL TODO: (a) DONE 2026-07-04 (5d9ecb1):
      windows/wslc examples + their 4 specs migrated to container(){engine(...)} via
      a system-scope float; all 12 examples aeo-check green (windows/wslc 3 passing
      each w/ a new get_engine float assertion); (b) host-family gate
      `_kind_runnable` still linux-blocks `container` — a WSL-engined container
      needs the node's engine to skip the linux gate (driver available() is the real
      check); (c) the mixed-engine-per-system network-plane WARNING (podman vs docker
      nets can't resolve peers by name) not yet emitted; (d) describe_tree engine=
      surfacing (snapshots are engine-agnostic — get_engine() asserts cover it).
      --- original design note ---
      `container()` stays the one OCI kind; new `engine("podman"|"docker"|"wslc")`
      node property with SYSTEM-SCOPE FLOAT + node override (same FluentSelenium
      float machinery as within/every). Auto default per host family: Linux →
      podman → docker; Windows → wslc → podman-through-WSL. `engine()` does NOT
      admit lxc (fails the swap test: image namespace, expose, env, init-vs-command
      — a kind, not an engine). DELETE `docker()`/`wslc()`/`windows()` kind-verbs
      outright — no aliases (pre-1.0, no back-compat; Paul 2026-07-04). Container-
      on-Windows = host-family engine resolution; the windows/wslc examples
      collapse into "containers.ae on a Windows host". Kinds staying OUTSIDE
      container(): lxc, nspawn (which also don't merge with each other), bwrap,
      jail, kvm_vm/bhyve_vm/freebsd_vm/firecracker. FIXES A REAL BUG en route: the `docker` kind's dispatch is
      second-class today — plain `up()`, silently losing the shared aeo-<system>
      net, env() pairs, and ALL limit{}/constrain{} rendering that `container`
      gets via up_confined(). Also: warn loudly when ONE system mixes engines —
      podman and docker networks are separate planes; cross-engine peers can't
      resolve by name (motivating scenario: one Debian host, three systems on
      docker/podman/lxc respectively).
- [ ] **`freebsd_vm`** — a bhyve VM with a FreeBSD GUEST (flavor "freebsd"); the
      bhyve demos run Linux guests. A real cell (FreeBSD-native VM / jails-in-VM),
      trivially close to the bhyve demo. No demo yet.
- [ ] **GENERAL container nesting — the Proxmox docker-in-LXC pattern (see
      docs/research/grammar-design-proposals.md §E)**. Homelab ground truth (XDA Jul-2025 + many
      others): OCI-engine-inside-LXC is mainstream — cheap on weak hardware, and
      LXCs can SHARE a GPU/PCIe device across consumers where VM passthrough is
      exclusive. aeo already has the seam: every host-capable kind exposes
      exec_capture (ssh / lxc-attach / systemd-run --machine / jexec) — nested
      bring-up IS "the child engine's commands through the host's exec seam"; the
      VM-only guest_container_up is just one instance. Work: (1) make `lxc()`/
      `nspawn()` block-host openers (set curhost) so
      `lxc("dockerbox"){ container("web"){ engine("docker") } }` declares the
      pattern; (2) route nested bring-up by the HOST's kind, generalizing
      guest_container_up over driver_exec; (3) resident aeo-agent-in-LXC (the
      containment-correct delegate path, same as agent-in-VM); (4) record per-host
      prereqs honestly (lxc nesting=1; privileged for NFS/CIFS volumes; engine
      installed in the guest userland — the "seed installs podman" story);
      (5) compose-time nesting-matrix validation: host-kind × child-kind cells
      gated on "exec seam + child runtime can run there", loud at `aeo check`.
- [ ] **Nesting depth** — the demo grid is flat (1-level: container-in-VM). aeo's
      design is RECURSIVE (the tree-of-nodes / aeo-agent recursion). No demo of
      jail-in-VM, VM-in-VM, or 3+ tier. (Subsumes into the general-nesting item
      above once that lands: depth is just repeated application of the exec seam.)
- [x] **`gpu(mode)` — device claims with CHECKED allocation semantics (see
      docs/research/grammar-design-proposals.md §G)** — BUILT + live-proven 2026-07-04 (Intel iGPU,
      podman 6, CachyOS). `gpu("shared"|"exclusive")` + optional `gpu_device(pin)`
      as a claim; gpu_flags renders SHARED container/lxc to `--device /dev/dri`;
      gpu_alloc_error() is the check-time gate (kind-gating + exclusive-conflict
      per device within a system, with the tier-choice reasoning as the error);
      up-path splices the flag into confine + audit-records it; `aeo check` runs
      the gate + a host DRI-preflight; describe_tree shows gpu=. test/spec_gpu.ae
      (13). LIVE: container sees /dev/dri/renderD128 @ 226,128 (host iGPU exactly),
      plain container does not, inspect .CreateCommand confirms the flag.
      GROUND TRUTH: `--gpus`/CDI is VENDOR-gated (nvidia/AMD toolchain) — FAILS on
      Intel ("no known GPU vendor found in CDI specs"); the DRI device-map is the
      portable path, so aeo renders `--device`, not `--gpus`. Corrected §G.
      CDI arm ALSO BUILT + proven (2026-07-04): gpu_flags takes a cdi_dev the runner
      resolves — _gpu_cdi_device probes /etc/cdi at up-time, prefers the `all` device,
      renders `--device <vendor>.com/gpu=all` (full card+render+by-path bundle,
      portable across intel/nvidia/amd), falls back to raw DRI when absent. Both arms
      live-proven on the N100. CDI spec is a plain YAML (examples/cdi/intel-gpu.yaml),
      NOT toolchain-locked. (Escaping footgun found+fixed: `[.]` not `\\.` in the
      probe's embedded grep — Aether-string→sh mangles backslash-escapes.)
      NOT yet built (follow-ups): VM exclusive/VFIO render (refused-at-check today);
      `"slice"` (MIG/SR-IOV); repeat gpu() for multi-device.
- [ ] **`nested_virt()` — deny-by-default, attenuate-down-the-tree (see
      docs/research/grammar-design-proposals.md §H)**. Principles of containment: capability must
      attenuate down the tree, never flow down implicitly — a node with nested
      virt can spawn sub-VMs aeo can't see (breaks tree-is-truth; the
      deny_egress twin for compute capability). Explicit per-node grant, NO
      float-down (each level re-declares). Deny = ACTIVE masking even when the
      substrate leaks it: `-cpu host,-vmx,-svm` for child VMs; no /dev/kvm map +
      cgroup device-deny for containers/lxc; `[wsl2] nestedVirtualization=false`
      for the WSL tier. Check-time CHAIN validation (host nested=1 → VM vmx →
      container /dev/kvm; break anywhere = loud fail — the ladder we hand-debugged
      on bazzite for the Win11→WSL2→podman 3-deep proof). Refused on
      firecracker/jail (ungrantable, by construction). Grants audited. Doctrinal
      point: a node needing children should DECLARE them (agent delegate path),
      not freelance with raw /dev/kvm — deny-default forces sprawl into the tree.

### Lighter-tier substrates (smaller VMs + sandboxes) — future kinds
Surveyed both boxes 2026-06-27. Below what aeo drives today (full-qemu kvm,
podman, LXC) sits a lighter tier — smaller VMs and unprivileged sandboxes. None
wired yet; mapped here as candidate kinds. Ordered by how cleanly they'd land:
- [x] **bwrap (bubblewrap)** — the STANDOUT. Unprivileged sandbox (the Flatpak
      engine); installed on both boxes and proven to run ROOTLESS with zero host
      setup — no sudoers, no systemctl, no idmap/bridge dance (unlike jails/kvm-
      tap/LXC, which all needed grants + console). A driver_bwrap = aeo's
      no-privilege "contain this process" tier, runnable anywhere. Directly serves
      the containment thread without the host-config friction that's blocked us.
      DONE (2026-06-29): lib/driver_bwrap (kind `bwrap`) wired through the runner
      (up/down/probe/exec + linux host-gating) and the compose DSL verb. bwrap has
      no daemon/named-container registry, so the driver tracks each sandbox by a
      PIDFILE like driver_vm/kvm: up backgrounds `bwrap --unshare-all --new-session
      <binds> -- /bin/sh -c CMD` (host userland ro-bound, or image() rootfs as /);
      net unshared = deny_egress for free. command() is required (a sandbox has no
      image init). exec/probe-health run a FRESH identically-confined bwrap (no
      unprivileged re-attach exists). PURE half (sandbox_argv + the sh-quoting)
      unit-tested off-box: test/spec_bwrap.ae + 9/9 on the macOS dev box. Example:
      examples/silly_addition_bwrap.ae (PID-1 containment proof). LIVE up/probe/
      exec still need a Linux box: run test/smoke_bwrap.ae where `bubblewrap` is
      installed (it SKIPs cleanly off-Linux). Headline win realized: the only host
      prereq is `apt/dnf install bubblewrap` — no sudoers, no bridge.
- [x] **systemd-nspawn** — a systemd-native system container (LXC's tier) but far
      less finicky: a rootfs + nspawn, no idmap/lxcbr0. Installed on both boxes;
      needs root. Possibly the LESS painful system-container path than driver_lxc.
      DONE (2026-06-30): lib/driver_nspawn (kind `nspawn`) wired through runner +
      compose DSL. machined-managed (no pidfile): up runs `systemd-run
      --unit=aeo-nspawn-NAME systemd-nspawn --machine=NAME --directory=ROOTFS`
      with `--boot` (full system container) by default, or the node's command()
      as the payload via `--as-pid2`. probe = `systemctl is-active`; exec =
      `systemd-run --machine=NAME --pipe`; down = `machinectl terminate` + stop
      the unit. Self-sudo (systemd-run/systemctl/machinectl NOPASSWD), mirroring
      driver_lxc. image() is the (required) rootfs dir. PURE half (the argv
      builders) unit-tested off-box: test/spec_nspawn.ae + a standalone harness on
      macOS. LIVE up/probe/exec needs a real SYSTEMD host: run test/smoke_nspawn.ae
      on Bazzite (nspawn refuses Docker's /run layout, so no Docker proof — it
      SKIPs cleanly off a systemd host). Example: examples/silly_addition_nspawn.ae
      (hostname-containment proof). Follow-up: rootfs provisioning (today image()
      must point at an already-populated /var/lib/machines/<name>; lxc gets its
      from the download template — nspawn could grow a machinectl pull-tar path).
- [x] **Firecracker** — the canonical "smaller VM": AWS microVM, ~125ms boot,
      minimal device model vs full qemu. A genuinely distinct VM substrate (the
      `kvm` kind is full-qemu). Cloud-hypervisor / crosvm are the same rust-vmm
      niche (crosvm IS ChromeOS's VMM, not exposed to Crostini).
      DONE (2026-06-30): lib/driver_firecracker (kind `firecracker`) wired through
      runner + compose DSL. No daemon/named-VM registry, so it's pidfile-tracked
      like the kvm arm of driver_vm: up writes a config.json (boot-source=vmlinux,
      drive=rootfs.ext4, machine-config=vcpus/mem from cpus()/memory()) and
      backgrounds `firecracker --api-sock SOCK --config-file CONFIG`; down SIGTERMs
      the pid + drops socket/config; probe = pid alive. image() names a BUNDLE DIR
      holding `vmlinux` + `rootfs.ext4` (one field, both artifacts). The pure
      builders (config_json/mem_mib) are unit-tested (test/spec_firecracker.ae) AND
      the generated config is SCHEMA-PROVEN against the real firecracker v1.10.1
      binary in Docker — it accepts the config, machine-config, and both drives,
      advancing to kernel-load (only a dummy-kernel magic-number error stops it; a
      real vmlinux + /dev/kvm boots). Example: examples/silly_addition_firecracker.ae.
      LIVE boot needs a KVM host: run test/smoke_firecracker.ae where /dev/kvm +
      firecracker + a bundle exist (it SKIPs otherwise; Docker-on-macOS has no
      /dev/kvm). LIVE-CONFIRMED 2026-07-04 on bazzite (Paul installed firecracker
      v1.16.1 to ~/.local/bin; kernel vmlinux-6.1.102 + ubuntu-22.04.ext4 rootfs from
      the firecracker-ci S3 bucket staged at ~/fc-bundles/{db,app}, pointed via
      AEO_FC_BUNDLEDIR): `aeo suite examples/silly_addition_firecracker.ae` completed
      the full phase (up→spec 1 passing→teardown), and the db microVM's log shows a
      REAL Linux boot (systemd 'Reached target Local File Systems', udev, etc.). So
      firecracker is a proven live substrate now. KNOWN GAPS / follow-ups: (1)
      exec_capture is a no-op — a microVM has no host-side exec; reaching the guest
      needs ssh/vsock over a tap (the driver_vm ssh shape). (2) No networking yet
      (bare boot; a tap/CNI for guest egress is next). (3) Artifact provisioning —
      image() must point at a prebuilt vmlinux+rootfs bundle today. (4) FIXED 2026-07-04 — the live run's two bugs turned out to be ONE root cause
      each, both now resolved + re-proven live: (a) NOT ephemeral-rootfs — the
      microVMs died because a bare bg-child of the short-lived aeo front-door is
      SIGHUP-reaped (the exact KVM bug; setsid+bg ALSO dies on a systemd box, live-
      confirmed). Fix: driver_firecracker now launches via `systemd-run --user
      --unit=aeo-fc-NAME --collect` (Type=simple; the lingering --user scope
      survives aeo's exit), with a setsid-bg fallback off a non-systemd host. (b) The
      HANG (app never dispatched) was because firecracker was still on the batch-
      liveness PIDFILE path, but systemd-run writes NO pidfile → the batch sweep never
      saw db "up" → app (depends db) never dispatched → poller hung. Fix: removed
      firecracker from _pidfile_of so it's NOT batchable; its per-node probe() now
      checks `systemctl --user is-active` (unit) OR the fallback pidfile. Also
      silenced the cosmetic `cat: No such file` noise (_read_pid now guards with
      `[ -f ]`). LIVE-PROVEN on bazzite: `aeo up` → BOTH microVMs active + persist
      (pgrep=2 after aeo exits); `aeo suite` → up → spec 1 passing → teardown →
      both units inactive, 0 leftover procs. firecracker spec 3/3, full suite green.
      (The suite spec still re-asserts data model only — no in-guest probe, gap #1 —
      but the LIFECYCLE now genuinely boots+persists+tears-down real microVMs.)
- [ ] **microsandbox (`msb`) — fast local microVMs for UNTRUSTED workloads**
      (github.com/superradcompany/microsandbox, Apache-2.0, libkrun+smoltcp).
      An almost-tailor-made fit for aeo's *purpose* ("orchestrated trees that
      contain malware and are impregnable"): microVM hardware isolation, but with
      **OCI images** (Docker Hub/GHCR) and Docker-like workflows, ~**<100ms boot**,
      **cross-platform** (Linux KVM / macOS Apple-Silicon / Windows WHP), and
      **embeddable** (no daemon, no server — `Sandbox::builder(...).create()`
      spawns a microVM as a child process).
        - **New driver tier `driver_microsandbox` (kind `microsandbox`)**: the CLI
          maps cleanly onto aeo's driver shape — `msb create --name N <image>` /
          `msb start|stop|rm N` (lifecycle), `msb exec N -- <cmd>` (exec_capture),
          `msb ps N` / `msb inspect N` (probe), `msb pull` (image). cpus()/memory()
          → the builder's `.cpus()/.memory()`. It's the microVM tier that ISN'T
          artifact-bound like firecracker (which needs a prebuilt vmlinux+rootfs) —
          microsandbox takes a stock OCI image, so no bundle provisioning. Likely
          the LEAST-friction strong-isolation tier after bwrap.
        - **Where it beats the existing tiers**: firecracker gives microVM
          isolation but needs hand-built artifacts + has no networking/exec yet;
          microsandbox gives the same isolation class WITH OCI images, built-in
          networking (smoltcp), exec, and detached long-running mode — i.e. it's
          firecracker's isolation with podman's ergonomics. And it's the one tier
          that spans all three OSes uniformly (relevant to the Windows arm + wslc
          items above).
        - **Cross-cutting wins to fold in**: "secrets that can't leak" (keys never
          enter the VM) is an attestation/forensics property worth a self-attest
          axis (§5.4); detached long-running sandboxes suit the aeo-agent resident
          model; and its MCP server / Agent-Skills are orthogonal but note-worthy
          (an agent could drive aeo which drives microsandbox).
        - Requirements to gate on: Linux KVM / macOS Apple-Silicon / Windows WHP;
          BETA (expect breaking changes — pin a version). Spike: does the SDK/CLI
          expose per-sandbox resource caps + network-deny that render the
          `limit{}`/`constrain{}` grammar (substrate-portable confinement)?
- [ ] **Raw primitives** — unshare (namespaces), chroot (the oldest container).
      Too low-level to be node kinds on their own; bwrap is the usable wrapper.

## share() — filesystem overlay INTO a node (slice 1 DONE 2026-07-19)

A share is a CAPABILITY GRANT (a filesystem pinhole through the boundary — the
publish()/gpu() class): explicit per node, READ-ONLY by default (`share_rw` is
the writable opt-in), repeatable, and every grant hash-chained onto the audit
trail (event=share, mode included). Stored `src|dst|mode` per line; shares ride
their OWN argv parameter (paths may contain spaces — they must NOT ride the
space-split confine flag channel).
- [x] **Slice 1 — grammar + local arms, LIVE-PROVEN (2026-07-19)**: compose
      `share(src,dst)`/`share_rw` + get_shares + reset_nodes clearing (no
      capability bleed across compositions); renderers: podman/docker
      `-v src:dst[:ro]` (NO auto-:Z — the SELinux relabel stays the operator's
      call, the documented Fedora trap), bwrap `--ro-bind/--bind` (placed after
      the base rootfs binds, before the fresh /proc//dev//tmp), nspawn
      `--bind-ro=/--bind=`; runner threads shares into the three up dispatches
      + audit-records. spec_share (6). LIVE PROOF (one run, all four nodes,
      with the death forensics as the instrument): ro nodes read the shared
      file then TRIED to write -> "kernel verdict: exited with code 7/9" (the
      refusal IS the proof; no blocked-file appeared on the host); share_rw
      nodes wrote THROUGH to the host (out-*.txt appeared with content) and
      promoted UP; all four grants hash-chained; clean teardown.
- [ ] **Slice 2 — proxmox_vm virtiofs (the box is ready)**: PVE 9.2 has
      first-class virtiofs (`virtiofs0: <dirid>` + /cluster/mapping/dir —
      probed live on .204, mappings list is empty). The operator-places/
      token-references split fits exactly: admin creates the directory mapping
      once (like snippets/templates), the composition references it, the token
      needs `Mapping.Use` (add to token_setup like §4b). Guest mounts
      `mount -t virtiofs <tag> <dst>` — the in-guest half belongs to the agent
      (cloud-init or a mount verb). proxmox_ct: storage-backed `mp[n]` volumes
      are token-grantable; RAW host-path binds are root@pam-only by PVE policy
      — refuse loudly under a least-priv token with the widen-or-volume
      reasoning, never silently degrade.
- [x] **kvm 9p + lxc arms — pulled forward + LIVE-PROVEN on .160
      (2026-07-19), plus the container/bwrap re-proof there.** All four
      CachyOS permutations green:
      - container + bwrap: the local demo re-ran identically (ro verdicts
        exit 7/9, rw write-through, audit-chained).
      - **lxc**: shares render as `-s lxc.mount.entry=<src> <dst-rel> none
        bind[,ro],create=dir 0 0` AT START (no config-file write — rides the
        existing lxc-start invocation; dst is RELATIVE to the rootfs, LXC
        convention). LIVE (unprivileged lxc): ro read OK, ro write ->
        "Read-only file system" (LXC's internal ro-remount on bind entries
        works), rw wrote through to the host. EN ROUTE: `_sudo_lxc` gained
        the sudo-or-plain LIFECYCLE fallback (the death read's _lxc_query
        pattern promoted to all ops) — driver_lxc now works end-to-end on
        unprivileged-lxc hosts with no sudoers grant. GOTCHAS: unprivileged
        rw shares need the mapped uid granted on the host dir (setfacl
        u:100000:rwx); alpine lxc-attach needs /bin/busybox FULL PATHS (the
        dltest spike trap again).
      - **kvm 9p**: `-virtfs local,path=<src>,mount_tag=aeoshN,
        security_model=none[,readonly=on]` per share (9p is UNPRIVILEGED,
        unlike virtiofs's sidecar; readonly=on enforces ro AT THE DEVICE;
        security_model=none maps guest writes to the qemu uid — rootless-
        correct). Guest mounts `mount -t 9p -o trans=virtio,version=9p2000.L
        aeoshN <dst>`. LIVE with a REAL debian guest via the driver: NoCloud
        seed as a VFAT cidata volume on the deterministic
        /tmp/aeo-seed-<n>.iso path (mkfs.vfat+mcopy — no ISO tooling
        needed), cloud-init mounted both tags, copied a file OUT of the ro
        share INTO the rw share (write-through observed on the host), and
        the ro-violation attempt left NO marker (readonly=on held). FINDING
        that cost a cycle: debian's `genericcloud` image ships the CLOUD
        KERNEL which OMITS the 9p modules — the mount silently fails; use
        `generic` (full kernel). Down clean both runs.
- [ ] **Slice 3 remainder — bhyve virtio-9p** (`-s N,virtio-9p,share=/path` +
      guest mount_virtfs; FreeBSD box needed); firecracker is
      REFUSED-by-construction (no share device — the nested_virt() pattern:
      ungrantable, loud at check).
- [ ] **Slice 4 — the agent-courier `put` verb** (push files over the
      authenticated agent conduit — substrate-agnostic, reaches nested
      containers, no PVE privilege at all; the small-payload complement to
      mappings).
- [ ] Follow-ups: lxc `lxc.mount.entry` arm; wslc/wsl_podman Windows-path
      translation; up_green share parity (cutover green currently gets NO
      shares — parity needed before cutover of share-bearing nodes);
      [DONE 2026-07-19: share_model_errors() — the loud kind×share gate,
      wired into _preflight + check like the proxmox gate: firecracker
      REFUSED-by-construction, proxmox_vm/ct + bhyve + jail + wsl engines
      not-rendered-yet errors, nested-in-VM-guest containers refused
      (delegate path carries no shares); spec-locked incl. the curhost-float
      trap (a container declared AFTER a VM opener reads as nested).
      A declared share can no longer silently vanish on any kind.]
      absolute-path validation (still open);
      bwrap probe/exec fresh sandboxes do NOT carry data shares (documented
      limitation); attest() over a share manifest (verify-before-mount for
      data — the fail-closed story extended to content).

## Cross-cutting / smaller

- [ ] **Podman 6.0 readiness (released ~2026-06-25) — preflight + follow-throughs.**
      aeo's engine() work is version-agnostic (it selects the binary), so nothing
      breaks on podman 5; but podman 6 changes ground aeo stands on:
        - **cgroups v1 REMOVED** — aeo's limit{}→cgroup confinement now REQUIRES a
          cgroups-v2 host under podman 6. Add a preflight probe (a v1 host + podman 6
          = confinement silently unavailable — must fail loud at `aeo check`, like the
          RACCT/kern.racct preflight on FreeBSD).
        - **Windows 10 support REMOVED** — the `wsl_podman` engine (podman-in-WSL) is
          Win11-only now; wslc (MSFT's, WSL 2.9.3) is separate and unaffected. Note in
          any Windows host-gating.
        - **iptables→nftables required, CNI gone (Netavark only)** — aeo's
          network_ensure/--internal netpolicy goes through podman's net layer so it's
          insulated, but the per-flow confinement (§5) now runs on nftables/Netavark;
          live-re-verify the deny_egress/internal-net tiers on a podman-6 box.
        - **Version lockstep** — podman 6 demands Buildah 1.44 / Skopeo 1.23 /
          Netavark+Aardvark 2.0. aeo doesn't bundle these, but the attest follow-up
          (cosign/skopeo signature path) must use the matching versions.
        - **--gpus is VENDOR-gated, NOT universal** (CORRECTED 2026-07-04 by live
          probe): podman 6's `--gpus` is a CDI front-end; CDI specs come from the
          nvidia/AMD vendor toolchains, so `--gpus all` FAILS on Intel iGPUs ("no
          known GPU vendor found in CDI specs"). The portable path is the DRI
          device-map (`--device /dev/dri`), which is what gpu("shared") renders.
          `--gpus`/CDI stays a future per-engine specialization for nvidia/AMD
          hosts (gate on a CDI-present probe). (gpu() item above: BUILT + proven.)
        - Box status: bazzite host 5.8.2, WSL2 guest 5.7.0. PODMAN-6 BOX NOW LIVE:
          CachyOS @192.168.0.160 (Arch, gcc 16.1.1, podman 6.0.0, cgroups v2, Intel
          iGPU) — throwaway, reimaging to FreeBSD after. LIVE-PROVEN there 2026-07-04:
          `aeo up` on podman 6 (engine auto->podman) deployed a limit{} container,
          `podman inspect` confirmed mem=134217728 pids=16 (limit{} -> real cgroups-v2
          caps), and a fork-bomb inside it was REFUSED ("sh: can't fork: Resource
          temporarily unavailable") — the behavioral containment proof on the
          podman-6/v2 substrate; clean `aeo down`. So the confinement path is
          podman-6-safe. NETPOLICY RE-VERIFIED on podman 6 / netavark (2026-07-04):
          deny_egress -> db-netmode=none (db->internet DENIED behaviorally),
          egress->db -> app on the --internal net (app->internet DENIED). So the
          per-flow netpolicy (§5) SURVIVES podman 6's iptables->nftables/netavark
          transition — the container-confinement axis holds on the new stack. (Test
          artifact: the `nslookup db` check fell through to ISP DNS = NXDOMAIN, not a
          confinement failure — app IS on the internal net; the internet-deny asserts
          are the load-bearing ones and passed.) STILL TO DO on this box while it
          lasts: cgroups-v2 PREFLIGHT probe (fail loud on v1+podman6); the --gpus/DRI
          gpu() path (Intel iGPU, /dev/dri/renderD128 present, needs gpu() built
          first); pasta forwarder (passt pulled in; needs the containers.conf drop-in
          wired). Toolchain
          getting-started failures captured in docs/getting-started-cachyos-hardening.md
          (gcc-16 -Werror const-strstr, make-install-wipes-build, fish-shell).
        - COSMETIC BUG seen on podman 6 (and bazzite): a Linux container with limit{}
          logs "limit{} declared but rctl is FreeBSD-only — NOT enforced on this host"
          even though the cgroup caps ARE applied (inspect proves it). The message is
          about the FreeBSD rctl path and misfires on Linux — fix the runner to only
          emit it for the FreeBSD/rctl case.
- [ ] **`aeo-supervisor` — host-resident holder of this-boot's trees (DESIGN, see
      `docs/aeo-supervisor.md`).** Decided shape (2026-07-05): boot-scoped +
      non-restoring (empty on OS boot, never restores last-boot's trees, no disk
      state); NEVER crashes (if it does, ops reboots the box — no auto-restart,
      Restart=no, which removes the re-adopt problem); supervisor-NOT-datastore (holds
      the tree because it's the PARENT of every node, live handles not records);
      `aeo up` hands to it BY DEFAULT, `--no-supervisor` = today's fire-and-exit,
      default-up with no supervisor present = ERROR (not a silent downgrade). Kills the
      pidfile fallback (§ driver_bwrap/firecracker) — the supervisor owns the pid — and
      closes the orphan gap (`down` releases exactly what it holds, no composition
      re-hand). Cross-init: install per host (systemd/OpenRC/runit/s6/sysvinit/rc.d,
      Alpine musl) via the agent's TSR renderer; nodes held uniformly as the
      supervisor's children. Hosts `watch`/reconcile. Composes with the aeo-agent
      (per-guest deputy) — supervisor is per-HOST. Supersedes the `lib/persist`
      adhere-to-native node-hold if built. Sequencing in the doc §8. NOT YET DECIDED
      to build — this is captured design.
- [ ] **`lib/persist` — one seam, adhere to each substrate's native supervisor for
      HOLD-ALIVE.** NOTE (2026-07-05): `docs/aeo-supervisor.md` proposes a DIFFERENT,
      possibly-superseding answer to the same "what holds the tree between aeo runs"
      question — a boot-scoped, never-crash, non-restoring aeo-OWNED resident
      supervisor that becomes the PARENT of every node (so the pidfile fallback is
      DELETED, not ported, and `aeo down` latches onto it instead of re-deriving from
      the composition). If that design is built, this `lib/persist` "adhere to native
      init for node-hold" work collapses — the supervisor holds nodes as its own
      children; only INSTALLING the supervisor stays per-init. Decide between them
      before building either. Original design below (adhere-to-native, no aeo daemon):
      Motivated by the firecracker fix (§ Firecracker gap #4): a bare
      bg-child of the short-lived aeo front-door is SIGHUP-reaped when aeo's session
      scope tears down. driver_vm (kvm) and driver_firecracker BOTH independently
      solved this with `systemd-run --user`; that logic is now duplicated and
      Linux-only. Factor it into ONE seam:
        - **Contract**: `persist_launch(unit_name, argv, opts) -> err` = "start this
          so it SURVIVES my exit"; `persist_stop(unit_name)`, `persist_active(unit_name)
          -> int`. Drivers call the seam; they don't hand-roll systemd-run/setsid.
        - **Per-substrate backends** (adhere to the native supervisor, NOT a bespoke
          resident):
            - Linux/systemd → `systemd-run --user --unit=… --collect` (Type=simple),
              `systemctl --user is-active/stop`. (What kvm + firecracker do today.)
            - Linux/podman containers → optionally QUADLET (.container units) so
              systemd itself supervises + restarts + boot-survives (podman 6 improved
              Quadlet); the systemd-native container answer. A `aeo-<system>.target` 
              Wants= each node's unit = the whole tree as one systemctl handle.
            - **FreeBSD → rc.d (boot-survive) + `daemon(8) -r -P pidfile` (keep-alive/
              restart)**; jails via jail.conf / `service jail` / BastilleBSD (the
              jail-tree supervisor). NB the ASYMMETRY that motivates keeping
              reconciliation in aeo (below): rc.d does NOT restart-on-crash and
              daemon(8) restarts a PROCESS not a node-to-declared-state.
            - Windows → a Windows service / Task Scheduler entry (the wsl_podman /
              future windows-agent hold-alive).
            - non-systemd Linux → setsid+nohup+pidfile fallback (today's firecracker
              fallback path).
        - **CRITICAL split — delegate hold-alive, KEEP reconciliation in aeo.** The
          native supervisors are uneven at reconcile-to-declared-state (systemd
          Restart= is crude; FreeBSD rc.d can't restart-on-crash at all). So the seam
          owns ONLY "keep the process alive across my exit"; re-attest / re-confine /
          re-join-network / restart-to-declared-state stays aeo's, uniform across
          substrates (the resident/agent or a future reconcile pass). This is why the
          answer is NOT a bespoke root daemon (aeo-host) reimplementing systemd, and
          NOT "adhere to systemd" alone (leaves FreeBSD's weaker init a gap) — it's
          "adhere to each OS's supervisor for HOLD, own RECONCILE portably." See the
          "what holds the tree between aeo runs" discussion (2026-07-04).
        - Scope guard: hold-alive + is-active + stop only — NOT a process babysitter
          with its own policy engine. The drivers already know their lifecycle; this
          just makes "survive the launcher" a single, per-OS-correct primitive.
      Sequencing: de-dups driver_vm + driver_firecracker NOW (both use systemd-run
      --user); the Quadlet/target and FreeBSD daemon(8) backends land as those tiers
      need persistence. Related: aeo-agent's init-aware TSR item (systemd/OpenRC/
      sysvinit — memory `aeo-agent-tsr-init-systems`) is the AGENT's version of the
      same "adhere to the native init" idea; keep them consistent.
- [ ] **A secrets engine — encrypted-throughout, never plaintext in state/logs**
      (transfer from Pulumi's model; the one idea from their talk that's a real
      aeo gap). Today aeo has attestation + a tamper-evident audit trail but NO
      secrets story — and the bank-courier agent token is currently plaintext in
      env + baked into the cloud-init seed (readable on the seed ISO). The Pulumi
      shape is right for aeo:
        - A secret is a TYPED value that stays CIPHERTEXT in aeo's own state
          (std.config / the audit inputs) and is decrypted ONLY at the boundary
          where it's used (the agent dial, the driver spawn) — never logged, never
          in a snapshot/backup artifact in the clear.
        - PLUGGABLE key backend (Pulumi does its own KMS by default, swap in
          AWS/GCP KMS or Vault). aeo's peer: a default local key + an operator hook
          to a real KMS/age/gpg — mirroring how drivers self-sudo to operator-
          granted binaries rather than owning the trust root.
        - Concrete first cut: courier the agent token as a secret — mint it,
          encrypt it into the seed (agent decrypts at boot with a key delivered by
          the ssh courier, not the seed), so a captured seed ISO doesn't leak the
          token. Ties into the bank-courier auth (lib/agent_auth) + audit.
        - Guard: this is aeo's OWN secret handling, NOT a general secrets manager —
          scope it to what the orchestrator itself must hold (tokens, image-pull
          creds), not user-workload secrets (those are the workload's problem).
- [ ] **Component compositions as versioned, testable API objects** (lighter
      Pulumi transfer). aeo's compose DSL is already closure-with-setters, but the
      pattern worth borrowing is *operator packages a component (e.g. a confined
      db-tier or a whole subtree), devs consume it by name/version, refactor +
      test it like real code* — an ops/dev separation where the confinement +
      attestation live IN the packaged component so a consumer can't accidentally
      deploy it unconfined. aeo's `.ae`-you-run already allows this (import a
      module that returns a configured subtree); make it a blessed pattern +
      example, not a new mechanism. NOT Pulumi's SaaS-state/component-registry —
      just the "confinement travels with the component" ergonomic.
      (Explicitly NOT doing from the Pulumi talk: cloud-provider CRUD, SaaS state
      backend, terraform import, IAM-JSON helpers, general IaC language — that's
      Pulumi's grain, not aeo's. aeo is config-IS-code for a CONTAINMENT tree, not
      a cloud-resource graph. Keep the seam sharp, same as aeo-is-NOT-aeb.)

- [~] **pasta port-forwarder for rootless containers — preserve true source IP**
      MECHANISM BUILT + lifecycle live-proven + ROOT-CAUSED 2026-07-05. Built:
      driver_linux pasta_dropin_path/content (pure, unit-tested — spec_pasta.ae, 3) +
      pasta_forwarder_ensure/active/clear (sudo -n NOPASSWD writes, matching the
      pf/nspawn/lxc contract); `aeo pasta <compose> on|off|status` subcommand
      (front-door + runner run_pasta, audit-recorded). LIVE-PROVEN: full
      status(off)->on->status(active)->off->status(off) cycle on the N100 box.
      CORRECTION (an earlier note wrongly said "upstream-blocked / waiting for
      #28478"): podman 6.0.0 SHIPS pesto and it RUNS. Root-caused why the source
      looked masked: (1) my first test used a bare `-p` container (no --network) =>
      pasta-as-network-stack, always 169.254.x; (2) on a BRIDGE net (what aeo's up
      path uses) the pesto path fully engages — VERIFIED the shared `pasta -c
      .../pasta.sock` control socket is present (the #28478 mechanism). The ONLY
      unproven arm: a genuine EXTERNAL LAN client's source surviving — pasta's
      `--map-guest-addr 169.254.1.2` maps HOST-originated traffic to a published port
      by design (loopback/splice), so host-local curls always show 169.254.x; only a
      real remote host over the LAN interface takes the TAP path. We had no third LAN
      host, so external-client preservation is pasta's documented behavior but
      UNVERIFIED here (test-harness limit, NOT an aeo gap or upstream wait). Findings:
      docs/linux-host-setup.md.
        - **[ ] PROVE THE EXTERNAL ARM — the one thing left unverified.** Everything
          up to the TAP path is confirmed; the last mile is: does a genuine remote
          client's real source IP reach the container? It CANNOT be tested from the
          host itself — host-originated traffic to a published port takes pasta's
          loopback/splice path and is mapped to `--map-guest-addr 169.254.1.2` by
          design, so a host-local curl ALWAYS shows 169.254.x even when pesto is fully
          active (this is the trap that produced the false "upstream-blocked"
          conclusion — see memory pasta-source-ip-test-trap). Only a SECOND PHYSICAL
          HOST on the box's LAN, hitting the box's LAN IP, traverses the TAP path
          where the source survives.
          Recipe when a 2nd host is available (both on 192.168.0.0/24):
            1. On the pasta host (the box): `aeo pasta compose.ae on`, then bring up a
               container on a BRIDGE net publishing a port, running the source-echo
               server (test/srv-srcip.py logs `PEER=<client_address[0]>`; the same server
               used in the root-cause probes).
            2. Confirm pesto engaged: `pasta.sock` present under
               `/run/user/<uid>/containers/networks/rootless-netns/`.
            3. From the SECOND host: `curl http://<box-LAN-IP>:<port>/`.
            4. PASS = the server logs `PEER=<second-host's LAN IP>` (e.g.
               192.168.0.x). FAIL/regression = `PEER=169.254.x` (still mapped).
            5. Control: repeat with `aeo pasta compose.ae off` (rootlessport) — expect
               the masked address, proving the drop-in is what flips the behavior.
          Candidate 2nd hosts on this LAN: the bazzite box (192.168.0.x) or the
          GhostBSD box (192.168.0.57) as a plain curl client. Once green, promote the
          pasta item from [~] to [x] and record the external-arm proof in
          docs/linux-host-setup.md (replacing the "unverified here" caveat).
        - **[ ] Teardown stale-rule guard (podman #29032).** pesto/pasta forward rules
          aren't always torn down cleanly on container shutdown -> port conflicts on
          restart. Wire an explicit clear into aeo's restart/teardown path
          (lib/snapshot_linux / the restart op) so a pasta-host node reliably comes
          back up. Test in the container-restart path.
      (podman 6, `rootless_port_forwarder = "pasta"`). Directly serves aeo's
      rootless-containment thesis: without it, a rootless container behind a
      reverse-proxy node sees the PROXY's internal IP, not the real client — which
      breaks any IP-based defense (brute-force lockout, IP banning) and pollutes
      the audit trail with useless source addresses. With pasta, the true source IP
      survives into the container.
        - **Config, not code**: a drop-in `/etc/containers/containers.conf.d/*.conf`
          with `[network]\nrootless_port_forwarder = "pasta"`. driver_linux could
          write/verify this drop-in as part of an "ingress" or `expose()` posture,
          OR aeo just documents it as a host prereq (like the sudoers grants).
        - **Confinement/forensics angle**: source-IP fidelity is an AUDIT property —
          a `constrain{}`/ingress node whose logs show the real client is
          meaningfully more defensible. Worth a self-attest axis later (§5.4): "is
          the true source IP reaching this node, or a proxy's?".
        - **KNOWN BUG to guard**: forward rules aren't torn down cleanly on
          container shutdown → conflicts on restart (podman-container-tools/podman
          #29032). aeo's teardown VERIFIES disappearance — so aeo's reverse-order
          teardown should explicitly clear stale pasta forward rules before a
          restart, or the node fails to come back up. Test this in the
          container-restart path (lib/snapshot_linux / lifecycle ops).
        - PODMAN 6.0 UPDATE (released ~2026-06-25): the premise firmed up. slirp4netns
          is REMOVED — pasta IS the rootless networking stack now. BUT the source-IP-
          preserving path (`rootless_port_forwarder = "pasta"`, kernel-level forwarding
          via "Pesto") is NOT the default yet — default stays `rootlessport` (5.x
          behavior); the pasta forwarder is opt-in until stability firms. So aeo still
          writes the `containers.conf.d` drop-in explicitly; "experimental" softens to
          "opt-in-default." Box versions: bazzite host 5.8.2, WSL2 guest 5.7.0 — NOT 6
          yet, so this waits on a podman-6 box (or upgrade one).
      Sequencing: small + high-value for any real ingress/reverse-proxy topology
      (which the blue-green cutover below will also want).

- [x] **Blue-green upgrades (zero-downtime node/tree cutover) — `aeo cutover` BUILT + LIVE-PROVEN 2026-07-04 (d316e02): forward zero-downtime (0 drops) + rollback, on podman 6. Details below; NEXT is subtree cutover + the wslc/wsl_podman + VM arms.** — orchestration,
      not just lifecycle ops. Upgrade a node (or subtree) by standing the NEW
      version up ALONGSIDE the old (green beside blue), health-gating it to
      readiness, cutting traffic/dependents over, verifying, THEN tearing down the
      old — with rollback to blue if green fails its health window. Where it lands:
        - Leans on machinery aeo already has: health-gated bring-up (the
          within/every window), the reverse-order verified teardown, and
          snapshot/rollback (lib/snapshot*) for the fallback.
        - The agent path makes the nested case honest: to blue-green a container
          nested in a VM, the resident agent stands up green inside the guest and
          swaps — the orchestrator never reaches through the boundary. `delegate`
          + `status` + a new `retire`/`cutover` verb is the natural protocol shape.
        - Confinement invariant: green must come up ATTESTED + CONFINED before any
          cutover (self-attest, §5.4) — a blue-green swap must not be a hole where
          an unconfined node briefly serves.
        - Open design: cutover mechanism per substrate (DNS/port-forward re-point,
          dependents' env re-resolve, or an in-guest reverse-proxy the agent owns);
          and whether "green beside blue" needs distinct IPAM/ports (it does — the
          addressing convention already assigns per-node ports).
      Sequencing: after the agent path is the blessed default and a real workload
      runs in the child (both currently opt-in / NOOP). This is the marquee
      operational feature the agent architecture unlocks.
      CUTOVER MECHANISM PROVEN LIVE on podman 6 (CachyOS box, 2026-07-04): the
      network-alias-swap approach WORKS end-to-end — blue holds a shared
      --network-alias 'svc', green is staged + health-gated on its own name, then
      the alias moves to green and blue's is dropped; a client resolving http://svc
      switches BLUE->GREEN, blue retired, service intact. So the "cutover mechanism
      per substrate" open question is answered for containers: podman network alias
      swap (no router/cranker needed for the first cut). TWO podman-6 GOTCHAS the
      `aeo cutover` driver must handle: (1) both blue+green must be on a BRIDGE net
      from the start — a container defaulting to podman-6's `pasta` net can't be
      `network connect`'d ('"pasta" is not supported: invalid network mode'); (2)
      re-aliasing = `network disconnect` then `network connect --alias` (podman
      refuses re-connecting an already-connected container). NEXT (buildable now,
      no box): an `aeo cutover <node>` verb = stand green up beside blue on a
      distinct name + the shared net (no alias), health-gate + attest+confine-gate
      it (green must be CONFINED before the swap — the invariant above), then
      disconnect/reconnect-with-alias to cut, retire blue, rollback-to-blue on
      failure. The alias-swap commands are pure argv builders (unit-testable like
      every driver op); the live zero-downtime measurement (curl-loop across the
      cut) is the box-gated proof.

- [x] **PARALLEL bring-up — the detached single-poller engine** (2026-07-01) —
      run_up() used to boot serially: spawn a node, block until it is up, THEN
      start the next — O(N) even for N INDEPENDENT nodes. Rewritten to boot a
      whole topological LEVEL at once. Two-step finding (test/bench_bringup.ae,
      real /bin/sleep boots, N independent nodes):
        - Naive fix (fan out Boot to an actor per node, then await) is NO better
          than serial — the Aether actor runtime SERIALIZES blocking ops inside
          actors, so a per-actor health poll can't overlap. Structural
          parallelism alone is useless here. (Worth reporting upstream.)
        - Real fix: the DETACHED single-poller. Every driver already backgrounds
          its boot (bwrap/podman/firecracker/systemd-run); the actor's Boot now
          does ONLY driver_up (no blocking poll), and a SINGLE engine poller
          (_await_level) probes the whole level, promoting each node to UP as its
          health passes. Boots overlap at the OS level → wall-clock ~= slowest
          boot. Measured ~4.6× at width 32 (macOS, 8 cores), scaling with width.
      depends() ordering preserved (a node dispatches only once its dep is UP);
      per-node health windows honoured (level budget = max node window; tick =
      fastest node interval). Removed the per-actor _poll_to_up / _await.
      VALIDATION: compiles; principle proven by the benchmark. The change is to
      the CORE bring-up path — LIVE-PROVE on Bazzite (a multi-node `aeo up`, e.g.
      silly_addition_containers) before trusting it.
      - [x] BATCHED liveness (2026-07-01): the per-level poller now checks all
            pidfile-kind, health-less nodes (bwrap/firecracker/kvm — readiness ==
            "process alive") in ONE shell sweep per tick instead of N×(cat+kill).
            Uses `read`/`kill -0` builtins → zero child spawns; collapses 2N Aether
            run_captures into 1. Measured 14.6× cheaper per tick at width 32
            (macOS); the sweep's correctness (live/dead/missing pids) validated
            directly. Health-checked / non-pidfile nodes keep the identical
            per-node probe (zero behaviour change). In _await_level /
            _batch_pidfile_alive.
      - [x] VM levels parallelize (2026-07-01): `_up_kvm` already returns fast
            (qemu launches detached) and probe() gates kvm readiness on the guest
            agent's /health — so KVM VMs ALREADY boot concurrently under the new
            engine (no change needed). `bhyve_up` used to block on _wait_guest_ready;
            it now RETURNS after `vm start` when the agent path is on (readiness
            gated by the poller's agent /health probe, which is IP-independent),
            so sibling bhyve VMs boot concurrently. Legacy (no-agent) bhyve still
            blocks — probe can't confirm ssh-reachability without the guest IP.
      - [x] container/docker liveness batched too (2026-07-01): health-less
            container/docker nodes are checked with one rootless `podman/docker ps`
            per tick (driver_linux.running_names), same reliable-source rule as the
            pidfile sweep. nspawn/lxc are DELIBERATELY left per-node: their liveness
            is sudo-gated (machinectl/lxc-ls), and a false "down" from a denied sudo
            in a batch would HANG bring-up — the per-node probe is the safe path.
            All batching is a fast-path gated by _batchable(); health-checked and
            non-batchable nodes are byte-for-byte unchanged.

- [x] **Aether DURATION LITERALS woven into the aeo DSL** (Paul 2026-06-27) —
      DONE. The FluentSelenium within()/secs() idiom: `within(30s) every(500ms)`
      expresses a health retry as WALL-CLOCK time, not a hand-computed attempt
      count; get_budget DERIVES attempts = window/interval. _dur_ms(d) = d/1000000
      (Duration is i64 ns; `as int` rejected, `/` works). Back-compat: explicit
      health_budget wins; int setters untouched. LIVE on Bazzite. spec_duration 4.
      (Aether has no fn overloading — so `within`/`every` are NEW names, not
      Duration overloads of health_interval.)
      - [ ] Follow-up: an egress(target, port, timeout: Duration) connect-window,
            and any other ms-int site that wants a duration form.

- [x] **NOT A BUG: "single-container doesn't boot" was a test-harness artifact.**
      Investigated 2026-06-27 and traced to the END: a 1-node compose DOES boot
      fine (`aeo up justdb.ae` -> [db] up -> container RUNNING). The earlier
      "quirk" was MY fault — test demos written via SSH heredocs with `\"` inside
      double-quoted commands landed on the box with BACKSLASH-ESCAPED quotes
      (`system(\"justdb\")`), so `system()`/`container()` got mangled names,
      resources registered under bad keys, and `compose.count()` came back 0 ->
      run_up's loop did nothing -> vacuous "stack up". Clean-quoted files (all the
      real demos, and any scp'd file) register + boot correctly. LESSON: write
      .ae test files locally + scp them, or use a quoted heredoc delimiter
      (`<<'EOF'`) — never an unquoted SSH heredoc with `\"`.
- [ ] **Behavioral end-to-end on the box**: one session that does the pf
      bite-step + RACCT reboot, then runs the apex and validates BOTH pf deny
      and rctl deny live (the two pending acceptance tests together).
- [ ] aeo-agent: slices 2–4 (rewrite onto transport_http; container-build the
      Linux agent binary; driver push + init-aware TSR — systemd/OpenRC/sysvinit,
      see memory `aeo-agent-tsr-init-systems`). Slice 1 (lib/transport_http) done.
        - **[ ] HTTPS agent conduit (when it goes TLS).** transport_http is plain
          `http://<ip>:<port>` today (send_command/probe_health), though agent_auth's
          design says the wire should run "under TLS." When the conduit moves to
          `https://` with SELF-SIGNED guest certs (the natural choice for ephemeral
          in-guest agents that can't get a CA-signed cert), the ready knob is
          `client.set_insecure(req, 1)` — landed in aether 0.354 (#1012), documented
          in 0.357. Wire it behind an explicit gate (e.g. `AEO_AGENT_INSECURE_TLS=1`,
          code-visible grant) into send_command/send_command_status/probe_health.
          NOT needed yet (no HTTPS-agent workflow exists) — noted so the migration
          doesn't rediscover the blocker. (#1012's forward-proxy half is irrelevant to
          aeo — the agent talks direct to a known peer.)
- [x] **aeo-agent ON WINDOWS — control plane DONE** (proven live on `winbaz`,
      the Win11 KVM guest, 2026-07-22). The listed blockers are all cleared: the
      cross-build ships (zig, not mingw — see .github/release-aeo-agent.yml), the
      agent is on the conduit, and driver_windows exists. Proven END TO END, not
      just "the binary serves /health":
      `aeo-agent.exe → POST /dispatch "boot <token> <node>" (auth-gated) →
      driver_windows → wsl -d Ubuntu -- podman run → report "up"`, with a
      container named for the node verified present in WSL podman. Container
      lifecycle all working: launch / exec-in / fs-write / stop / cleanup.
      Full write-up: `docs/development/winbaz-nested-virt-and-agent-findings.md`.
- [ ] Follow-ups from the winbaz pass — both OUTSIDE aeo, neither blocking:
      (a) **container → outbound network fails** in that WSL distro (interface +
      route present, but `wget`/`curl` dies even with `--network=host`). Root
      cause is podman-ROOTLESS networking (netavark + pasta/slirp) in WSL, a
      known distro-side friction — not an aeo bug and not nested-virt. Impact:
      the control plane and self-contained workloads work; anything that must
      pull an image or reach the network needs the distro fixed first.
      (b) **nested virt is a dead end on this box and is NOT needed** — WSL2's
      full nested-virt mode never engages (`SLAT=False`) on AMD-KVM-inside-QEMU;
      both levers were correctly applied and neither moved it (Hyper-V isn't even
      available on Win11 *Home*). Moot anyway: every `podman run` worked on the
      degraded path. Don't re-chase it.
- [ ] **driver_windows has NO timeout guard on its wsl calls.** `wsl --status`
      and a cold first `wsl -d <distro>` can HANG while the utility VM boots —
      every probe on the live box needed a job-timeout. `os.run_capture` takes no
      timeout argument, so a wedged WSL blocks the runner's health loop instead
      of failing it. Options: an upstream `run_capture` timeout (an ask for
      aether), or wrap the inner command with a `timeout`-style guard. The driver
      header records the constraint so a hang reads as known, not mysterious.
- [x] **`driver_wslc` — a Windows Linux-container tier via WSL Containers** — DONE
      (2026-07-03, commit `2615bbb`). `lib/driver_wslc` shells Microsoft's native
      `wslc.exe` directly (no podman, no distro prefix). Wired into compose (`wslc`
      kind) + runner (up/exec/down/probe); unit spec 6/6; example present. Got wslc
      onto the guest by upgrading WSL 2.7.10 → 2.9.3 (`wsl --update --pre-release` —
      NO Store needed, so the unlicensed-guest block didn't bite; nested virt NOT
      required despite the old warning). LIVE-PROVEN vs real `wslc.exe` 2.9.3.0: the
      driver's exact argv ran the full round-trip (run -d -p → list json Name-match
      + port bound → exec hostname → container stop → container remove → list []).
      Handled wslc's deltas from podman: `container remove` not `rm`, no `--replace`
      (manual idempotency), `list --format json` not Go templates (probe matches the
      "Name" field). STILL OPEN (follow-ups, not the driver itself): render
      limit{}/constrain{} onto wslc's governance knobs (caps/network-deny/registry
      allowlist ↔ attest); and the headless WSL container API (NuGet
      `Microsoft.WSL.Containers`) as an alternative to shelling the CLI.
      --- original rationale (kept for the follow-ups) ---
      Native OCI Linux
      containers on Win11 with NO Docker Desktop, via a dedicated optimized Hyper-V
      VM. Directly relevant because:
        - **New driver tier**: `wslc` syntax mirrors Docker (`wslc run -p 8080:80
          nginx`, `wslc build -t app .`, `wslc container ps`), so a `driver_wslc`
          is close to `driver_linux` with the engine swapped — the run/build/probe/
          down argv shape carries over. It's the WINDOWS analog of the podman
          container tier (a real Linux-container backend that isn't Linux-hosted).
        - **Developer API for headless launch** — native Windows apps can start +
          manage containers with no terminal (MS demoed a .exe silently running a
          Linux container). That's the seam a Windows-resident aeo-agent would use
          to run nested children WITHOUT bundling podman — the aeo-agent-on-Windows
          blocker above (agent Linux-bound) is partly answered: the *agent* still
          needs a Windows arm, but the *child-run* mechanism exists natively.
        - **Enterprise governance maps onto aeo's grammar** — registry allow/block
          lists, resource audit, host file/net/clipboard governance are exactly
          aeo's `attest()` (registry pin) + `limit{}`/`constrain{}` (resource/net)
          + audit-trail axes. A `driver_wslc` should render the SAME limit/constrain
          vocabulary onto wslc's governance knobs (substrate-portable, like the
          FreeBSD↔Linux confinement peers).
      Blockers/unknowns: it's PREVIEW (single-container only, no Compose — fine,
      aeo owns orchestration; sparse docs; rough edges). Spike: does `wslc` expose
      per-container resource caps + network-deny that map to constrain{}? Confirm
      the headless API is scriptable from an Aether-built binary. Sequencing: after
      the Windows agent arm exists (the two are complementary — agent = control
      plane, wslc = the container runtime it drives).

      GROUND-TRUTH from the real Win11 guest on the box (winbaz, build 26200,
      "Windows 10 Home" name-string, 2026-07-02): the container primitives are
      present-but-OFF — `Microsoft-Windows-Subsystem-Linux` DISABLED,
      `VirtualMachinePlatform` DISABLED, `HypervisorPlatform` (WHP — the
      microsandbox/microVM base) DISABLED, `wsl.exe` launcher exists but WSL "is
      not installed", `wslc.exe` NOT FOUND. So:
        - **A `driver_wslc` (and any WSL/WHP tier) must ENABLE the feature first** —
          `dism`/`Enable-WindowsOptionalFeature -Online -FeatureName ...` (+ likely
          a reboot) is a prerequisite step, the Windows analog of "the seed installs
          podman." The TODO's "does wslc expose caps" spike is downstream of that.
        - **`wslc` isn't on this build yet** (26200) — the launchers ship before the
          feature. So Paul's instinct ("watch Windows updates for new container
          possibilities") is the right cadence: these are nascent, toggle-able
          isolation primitives that arrive incrementally. Re-probe after WSL is
          enabled + Windows updates land; when `wslc` appears, THEN spike the
          caps↔constrain mapping on a real container.
        - **Home-edition caveat**: WSL works on Home; the newer WSL Containers'
          Home-vs-Pro gating is the open question — verify on THIS Home guest before
          assuming consumer-Windows reach.
      ENABLE ATTEMPT (2026-07-02, over SSH — no walking to the box):
        - Enabled `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`
          via `Enable-WindowsOptionalFeature` (admin-over-SSH worked, no elevation
          block) → both `Enabled`, `RestartNeeded=True`; rebooted the guest (came
          back on :22, key-auth survived). Guest has internet egress (virbr0 NAT).
        - BUT `wsl --install` (and `--web-download`) DON'T WORK: the inbox
          `wsl.exe` in System32 is an OLD STUB that doesn't implement the modern
          `--install`/`--web-download` flags — it just prints "WSL is not installed,
          run wsl --install" regardless of args. The real WSL is a STORE-delivered
          appx, and **this guest is UNLICENSED (skip-license test install) so the
          Microsoft Store doesn't function** → the app never delivers.
        - So a `driver_wslc`/WSL provisioning path on an unlicensed or Store-less
          Windows must **sideload the WSL `.msixbundle` from GitHub**
          (`github.com/microsoft/WSL/releases`) + `Add-AppxPackage` — the
          Store-free install. (In progress on the guest.) This is a REAL extra step
          the driver must own beyond "enable the feature."
        - **And nested-virt**: WSL2 boots a lightweight VM, but win11 is itself a
          KVM guest — WSL2 needs the Bazzite host's KVM to expose nested virt to the
          win11 domain (`kvm_amd nested=1` + host-passthrough CPU in the libvirt
          XML). If a distro fails to boot post-install with a hypervisor error,
          that's why. WSL1 needs no nested-virt (a fallback).
      NET: on Windows, the container-tier prerequisites are a real chain —
      enable-feature + reboot → (Store OR sideload-MSIX) the WSL app → nested-virt
      for WSL2 → THEN a distro + a container runtime. A `driver_windows` child-run
      arm has to automate this chain; it's meatier than the Linux "seed installs
      podman" step. Documented from the real guest, not a news article.
      RESULT (2026-07-02): **WSL2 INSTALLED** on the unlicensed guest via GitHub
      MSIX sideload — `Add-AppxPackage Microsoft.WSL_2.7.10.0_x64_ARM64.msixbundle`
      (~518MB; the crux was a clean single-writer re-download — the first tries
      were truncated → 0x80073CF0). `wsl --version` → 2.7.10.0, Linux kernel
      6.18.33.2, WSLg 1.0.73.2. So the Store-free WSL install path WORKS on an
      unlicensed Windows — a real, reusable finding for a `driver_windows` provisioner.
      **NESTED VIRT PROVEN + WSL2 DISTRO BOOTED (2026-07-02):** the Bazzite host
      already had `kvm_amd nested=1` and the win11 libvirt domain already had
      `<cpu mode='host-passthrough'>` — no changes needed. `wsl --install -d Ubuntu`
      pulled Ubuntu 26.04 cleanly (WSL 2.7.10 fetches distros from its own source —
      NO Store-sideload needed for the distro, unlike the WSL app itself), VERSION 2.
      `wsl -d Ubuntu -- uname -a` → `Linux winbaz 6.18.33.2-microsoft-standard-WSL2
      ... x86_64` (RC=0). A REAL Linux kernel runs in a WSL2 VM, inside the win11
      KVM guest, inside the Bazzite host — a 3-deep virt stack, all over SSH.
      SO: a Windows guest now has a live Linux container-capable environment. The
      remaining piece for blocker #1 (the Windows child-run mechanism) is podman
      INSIDE this WSL2 Ubuntu (apt install podman → run OCI containers), which the
      driver_windows arm would drive via `wsl -d Ubuntu -- podman ...`. That's the
      concrete, now-testable path to a functional Windows aeo-agent.
      **PODMAN-IN-WSL2 PROVEN (2026-07-02):** `apt install podman` in the WSL2
      Ubuntu (podman 5.7.0), then `wsl -d Ubuntu -u root -- podman run --rm
      debian:stable-slim echo ...` PULLED debian from Docker Hub and RAN the
      container (no cgroup/systemd errors — podman 5.7 handles WSL2 cleanly).
      WSL2 egress works (deep NAT: WSL2→Windows→virbr0→internet; apt Hits all
      Ubuntu repos). So the FULL Windows child-run substrate is proven end-to-end:
        Bazzite(KVM host) → win11 KVM guest → WSL2 Ubuntu → podman container.
      Blocker #1's mechanism is SOLVED — a driver_windows arm runs children via
      `wsl -d Ubuntu -- podman run ...`, mirroring the Linux agent's
      _ensure_child_container. What's left for a functional Windows agent is the
      AGENT-SIDE wiring: build the agent .exe for Windows (mingw, libaether.a-for-
      mingw pending) + a driver_windows body that shells `wsl ... podman` instead
      of native podman. The hard substrate gates are all cleared.
- [ ] aether#870/#878 are CLOSED (fixed in ae 0.326). BUT investigated
      2026-06-27: they do NOT let the aeocha specs drop their bare `import
      std.string`. #878 fixes the QUALIFIED surface (`string.copy()` with the dot)
      on any import; #870 fixes a selective ENTRY-FILE import suppressing merged
      qualified calls. The aeocha workaround is for aeocha's inlined code calling
      `copy` BARE/UNQUALIFIED — which needs a bare `import std.string` to provide
      the bare-name binding, and that's aeocha's design, NOT what #870/#878 fixed.
      So the ~14 bare-import sites STAY unless aeocha switches to qualified
      `string.copy()` internally (an aeocha change), or ae adds bare-name
      re-export. Couldn't even test on this box: installed ae is 0.325 (the 0.326
      source has the sib's uncommitted WIP + a version-stamp quirk; didn't force a
      build). Revisit when ae 0.326+ is cleanly installed.
- [ ] aether#929/#586/#744 CLOSED (narrowing/Duration/module-global soundness).
      aeo not exposed today (no module-scope `var` 64-bit cells; durations convert
      ns->ms-int immediately). Commented on #929 with the corroborating near-miss.
- [ ] **aether#937 (module `var` not persisted across import) FIXED in ae 0.328**
      — verified read-back=7 (was 0). aeo was immune anyway (zero module vars; all
      ambient state via std.config — kept as a design rule + memory). With #934
      (0.327) + #937 (0.328) BOTH fixed, the full fluent-facade shape now builds +
      runs end-to-end: verified `matchers.expect_int(5).to_equal(5).to_be_gt(0)`
      across the import boundary with an ambient cur_fw cell ([myspec] ok lines).
- [ ] **NOW UNBLOCKED: fluent aeocha facade + aeo spec sweep.** #934+#937 fixed,
      so aeocha can ship `expect_int(x).to_equal(5).to_be_gt(0)` (chainable matchers
      + an ambient fw cell). That's an AEOCHA change; THEN a mechanical aeo sweep
      of ~18 specs from `aeocha.assert_str_eq(fw, got, want, msg)` to the fluent
      form. Real readability win, now actionable.
- [ ] **aether#934 (cross-module UFCS) FIXED in ae 0.327** — verified end-to-end:
      `b.bump()` AND `b.bump().bump()` resolve + run across the import boundary
      (was the exact failure we commented on). Unblocks a FLUENT aeocha facade
      (`expect_int(x).to_equal(5).to_be_gt(0)`) — which would replace aeo's verbose
      `aeocha.assert_str_eq(fw, got, want, msg)` across ~18 specs. That's an AEOCHA
      change (add the chainable facade), then a mechanical aeo spec sweep. aeo's
      OWN DSL is block-setter (container("db"){within(30s)}), not method-chain, so
      not directly blocked — but the readability win on the specs is real.
      (Compiler bump to 0.327: full aeo suite + demos re-checked, no regression.)

## Re-create from clawk (survey 2026-07-17)

clawk (~/scm/clawk, github.com/clawkwork/clawk) is a per-project disposable-
microVM sandbox for coding agents (Go, macOS Virtualization.framework +
firecracker-on-Linux). Different problem than aeo (one VM, no graph — no
dependencies, health gating, attestation, audit, or reconcile), but it
independently validates the containment thesis (isolation as STRUCTURE — a
separate machine, an owned network layer — not policy on a shared host) and
several of its mechanisms are worth re-creating in aeo's shape. Ranked by
payoff; consciously NOT copying: the ticket/worktree/PR workflow and
Claude-attach UX (their product, not an orchestrator's), the snapshot-at-create
config-template semantics (aeo's reconcile model is deliberately the opposite —
the composition stays authoritative), and macOS Virtualization.framework
support (no consumer).

- [ ] **1. Owned-userspace-stack egress enforcement — the `egress_fqdn` tier
      without a CONNECT proxy.** clawk's gvproxy insight: the guest's ENTIRE L3
      (gateway, DHCP, DNS, NAT) is a userspace TCP/IP stack inside their daemon,
      so every outbound SYN and every DNS ANSWER consults the allow-list at a
      point root-in-the-guest cannot reconfigure — hostname allow-listing falls
      out for free (allow `example.com`, keeps working as its IPs rotate,
      because the filter sees the name the guest just resolved). No host
      iptables, no sudo, rootless by construction. aeo already ships pasta
      (same userspace-stack family as gvproxy/slirp) for source-IP fidelity —
      extending that ownership from FORWARDING to FILTERING lands
      `asks/linux-per-flow-netpolicy-for-ci.md` priority 2 (and plausibly
      priority 1's per-flow tuples) without the netavark/nftables rootless-
      reachability spike. Should be weighed AGAINST the CONNECT-gateway embryo
      (§5 egress_fqdn item, lib/egress_gateway) before more gateway work: the
      gateway remains right for the hierarchical parent-owned story, but the
      DNS-aware-stack tier may be the better first enforcement for the
      registry/warmer case. Lands in: confine_linux / the pasta path.
- [ ] **2. A DENIALS LEDGER — record attempted-and-blocked flows.** clawk logs
      every denial keyed by the HOSTNAME the guest resolved (`clawk network
      denials` reads as "what did the agent try to reach"). aeo blocks silently
      today — and a silent block is indistinguishable from a broken app.
      Record per-node denied flows (resolved name where known, else addr:port),
      surface via `aeo status`/a `denials` verb, and append to the hash-chained
      audit trail (§4's "per-node connection logging on the deny-default"
      follow-up — this is that, with a design to copy). Also subsumes the ask's
      priority 3 (dry-run prints the rendered tier + flow whitelist). Lands in:
      runner + lib/audit.
- [ ] **3. Daemonless OCI-image-as-VM-rootfs.** clawk pulls any OCI image (no
      Docker daemon), flattens layers resolving whiteouts, writes ext4 with NO
      root/loop-devices/e2fsprogs (vendored hcsshim-derived writer), caches the
      master, then CoW-clones per sandbox (APFS clonefile / FICLONE) — so
      per-node disk cost is what the guest writes. For aeo this would free
      kvm/proxmox_vm from the "operator pre-places a cloud-image template"
      prerequisite: `image("golang:1.25")` on a VM kind, same vocabulary as
      containers, one image namespace across substrates. Biggest build of the
      list; strategic. Lands in: driver_vm first (local qcow2/raw), then
      driver_proxmox (upload/import path). Also answers driver_firecracker
      gap #3 (prebuilt vmlinux+rootfs bundles).
- [ ] **4. vsock as an aeo-agent transport.** clawk's only control path into
      the guest is a vsock agent (no sshd, no cloud-init network dependency) —
      each attach is container-exec-style (fresh process, torn down on
      disconnect). For aeo: `AEO_TRANSPORT=vsock` as the LOCAL-hypervisor
      transport (kvm/firecracker/bhyve) — works before DHCP (would have erased
      the `_wait_guest_ip` + retry-delegate dance from the proxmox_podman
      debugging), unreachable from anything but the host, no 0.0.0.0-bind
      exposure. HTTP stays for REMOTE guests (proxmox — vsock doesn't cross the
      wire). Small, immediate boot-path-robustness payoff. Lands in: aeo-agent
      + driver_vm.
- [ ] **5. Suspend-to-disk as a lifecycle verb.** clawk's `snapshot`/`resume`
      is RAM+device-state hibernation: dev servers survive, next boot restores
      the guest exactly where it was, an idle sandbox costs only storage. aeo's
      snapshot/rollback verbs are DISK-state (zfs/qemu-img/podman-commit); the
      missing sibling is `aeo suspend|resume <compose> [node]` for VM kinds.
      PVE has native suspend (nearly free for proxmox_vm); qemu has
      savevm/migrate-to-file for kvm. Pairs with item 6. Lands in: driver_vm /
      driver_proxmox verbs + runner dispatch.
- [ ] **6. Idle management under the supervisor.** clawk balloons idle VMs
      down (~1 GiB), auto-stops after 30 idle minutes, and (roadmap) suspends
      the least-recently-used sandbox instead of refusing a new one when RAM is
      over-committed (admission control). This is exactly a resident-supervisor
      job — slots into `docs/aeo-supervisor.md` as its resource-steward role
      (see also memory `aeo-supervisor-design`); don't build it standalone.
      Depends on item 5 for the suspend primitive.
- [ ] **7. Credential FORWARDING instead of credential injection.** clawk
      forwards the host's ssh-agent over a dedicated vsock port — signing
      happens ON THE HOST, keys never enter the guest, yet in-guest `git push`
      works. aeo's secrets story (lib/secrets) is ciphertext-at-rest,
      decrypt-at-use; the stronger tier for KEY-shaped secrets is
      never-materialize-at-all: broker the OPERATION at the boundary. A
      `forward_agent()`-style grammar item, agent-brokered (the aeo-agent
      relays the agent protocol hop-by-hop down the recursion, same
      parent-owns-the-boundary shape as the egress gateway). Lands in: compose
      + aeo-agent.

Sequencing: 1+2 are the same work area as the aeci ask
(`asks/linux-per-flow-netpolicy-for-ci.md`) and should ride it; 4 is small and
pays for itself in boot-path robustness; 3 is the strategic one; 5–7 queue
behind the supervisor decision.

## Re-create from aurae (survey 2026-07-17)

aurae (~/scm/aurae, github.com/aurae-runtime/aurae, Kris Nóva's project) is a
"distributed systems runtime": ONE memory-safe Rust daemon (`auraed`) that is
simultaneously PID-1 init, process manager, and gRPC API server on a node —
managing executables, cells (cgroups + namespace unsharing), CRI pods, VMs,
and SPAWNED NESTED aurae instances, with SPIFFE/mTLS identity down to the
socket and eBPF observability. It's a NODE runtime, not an orchestrator — it
sits below aeo the way auraed sits below Kubernetes. It independently
validates two aeo design calls: recursion as first-class (aurae `Spawn` writes
its OWN binary into a child rootfs and runs a nested instance — exactly
aeo-agent's mount-own-binary-into-container trick) and config-is-code
(auraescript/Deno exists because they refuse YAML — Aether already covers
that). Ranked by payoff; consciously NOT copying: the CRI/pods/Kubernetes-
complement layer (aeo is not a kubelet), auraescript (Aether IS aeo's answer),
gRPC/protobuf as the API substance (aeo's HTTP+Aether seam is fine — it's the
VERB DISCIPLINE that transfers), and the Rust-rewrite instinct.

- [ ] **1. aeo-agent as PID-1 guest init (context-aware single binary).**
      auraed detects PID==1 and runs as the init system — four context-aware
      "system runtimes" in one binary (pid1 / cell / container / daemon,
      auraed/src/init/system_runtimes). clawk converged on the same call
      (clawk-init: "no systemd, no cloud-init"). For aeo this collapses the
      proxmox/kvm bring-up ladder — today's cloud-init -> install
      qemu-guest-agent -> fetch agent from GitHub Releases -> sha256-verify ->
      start chain becomes "the guest image boots straight into aeo-agent" —
      and makes the agent un-killable-by-accident (it IS init). Copy the
      context-aware pattern wholesale: ONE agent binary auto-detecting "am I
      init in a VM / inside a container / a daemon on a host?" and selecting
      transport+behavior accordingly. Depends on owning the guest image
      (clawk item 3, OCI-as-rootfs, is the natural delivery vehicle).
      Cloud-init stays as the fallback rung for operator-supplied images.
- [ ] **2. Allocate/Free split from Start/Stop — an `aeo stage` phase.**
      aurae's verb discipline separates RESERVE (allocate resources +
      prerequisites) from RUN (start). aeo's `up` conflates them: image
      pulls, attest resolution, network creation, cgroup setup all happen
      inside the node's health window. `aeo stage <compose>` = pull + attest
      images, create networks, allocate — touch nothing that serves traffic;
      `up` after a stage shrinks to actual boot time. Exactly what `aeo
      cutover` wants (stage green FULLY before the swap — the confinement
      invariant gets cheaper to hold). Also the honest fix for cold-chain
      up_within(15m) windows (the proxmox_podman example): most of that
      window is fetch/pull work a stage phase would front-load.
- [ ] **3. Full cgroup-v2 controller vocabulary in `limit{}`.** aurae types
      the whole controller surface: `cpu.weight`/`cpu.max`,
      `cpuset.cpus`/`cpuset.mems` (core PINNING), `memory.min/low/high/max`
      (soft-guarantee tiers vs the kill-line). aeo's limit{} today is
      memory/pids/cpus — it can't express "guarantee this node 1G
      (memory.low)" vs "kill it at 2G (memory.max)", nor pin a node to cores.
      Proven consumer: the LB benchmark hand-pinned cores with taskset
      (aether#1123 perf note). Render onto podman's --cpuset-cpus /
      --memory-reservation etc.; FreeBSD peer = rctl where an analog exists,
      loud NOT-enforced where not (the §5 discipline).
- [x] **4. Kernel-level "why did it die" forensics — BUILT + LIVE-PROVEN
      2026-07-18 (both arms).** aurae's observe API streams POSIX signals via
      eBPF; aeo's first cut needed no eBPF: driver_linux gained
      `death_argv`/`death_state` (engine post-mortem inspect:
      status|OOMKilled|ExitCode — podman AND docker expose all three) +
      `death_cause` (pure classifier: OOM beats exit code; >128 -> named
      signal; else exit code; clean-exit-before-ready is still a verdict;
      running/absent -> ""). `_diag_level_not_up` now appends the verdict to
      the timeout line AND audit-records it (`event: death` — forensics,
      like attest-refuse). spec_death.ae (10) locks the pure core; full
      suite green. LIVE: (a) SIGNAL arm on the Chromebook — a segfaulting
      entrypoint under a never-passing health -> "kernel verdict: killed by
      SIGSEGV (exit 139)", death event hash-chained; (b) OOM arm on CachyOS
      .160 (podman 6, cgroups v2) — a 32m-capped memory hog ->
      "kernel verdict: OOM-killed (cgroup memory limit)", chained.
      TWO findings en route: (1) the LEVEL-BUDGET FLOOR swallowed explicit
      windows — `_await_level`'s min_secs=120 was a floor, so within(10s)
      waited 2 MINUTES to report a dead-on-arrival node. Fixed:
      `_level_budget_ms` honours the declared max as-is when EVERY node in
      the level states its own within()/up_within(); the 120s floor now
      protects only default-window nodes. (2) PID-1 SIGNAL TRAP for tests: a
      container entrypoint CANNOT kill itself with os.kill (the kernel
      ignores kill()-sent signals to a namespace's init — it exits 0 and can
      even get promoted UP off the ps sweep) — a HARDWARE FAULT (segfault)
      IS delivered; and Crostini is cgroups-v1 rootless, where podman
      IGNORES --memory (the OOM arm needs a v2 box; also re-motivates the
      podman-6 cgroups-v2 preflight item).
      SUBSTRATE EXPANSION 2026-07-18 (the "cheap wins" round): classifier
      PROMOTED to lib/death (one death_cause for every substrate) + a shared
      `unit_death_line` systemd mapper (Result/ExecMainCode/ExecMainStatus ->
      canonical status|oom|exit; killed/dumped -> 128+signal). New arms:
      - **nspawn**: driver_nspawn.death_state via UNPRIVILEGED `systemctl
        show` (reads need no sudo — proven as plain user on .160; mutations
        keep self-sudo). Mapper live-proven via the fc arm (identical code).
      - **firecracker**: driver_firecracker.death_state (--user scope).
        LIVE-PROVEN on .160 through the REAL driver path, all three ways a
        unit dies: MemoryMax OOM -> "OOM-killed (cgroup memory limit)";
        external kill -9 of MainPID -> "killed by SIGKILL (exit 137)";
        exit 3 -> "exited with code 3".
      - **wsl_podman**: driver_windows.death_state (driver_linux.death_argv
        through the proven wsl_argv wrapper). LIVE-PROVEN 2026-07-18 on the
        winbaz guest (WSL2 Ubuntu, podman 5.7.0) at the driver_windows house
        bar — the driver's EXACT `wsl -d Ubuntu -- podman inspect <n>
        --format <death-format>` against real containers, all THREE modes:
        /bin/false -> status=exited|oom=false|exit=1; podman kill ->
        exit=137; a --memory 16m tail-/dev/zero hog -> **oom=true|exit=137**
        (WSL2 here is cgroups v2 WITH the memory controller — a real cgroup
        OOM, and unlike wslc the OOMKilled flag survives). The earlier
        "needs the pipeline resumed" deferral was WRONG — death_state needs
        none of the agent-.exe recursion work, just the wsl exec seam, which
        was already live.
      KEY MECHANICAL CHANGE: dropped `--collect` from the nspawn +
      firecracker systemd-run launches — systemd's default keeps a FAILED
      transient unit loaded until reset-failed, which IS the post-mortem
      window; --collect was garbage-collecting the corpse before the diag
      could ask why it died. down() (and fc relaunch) now reset-fail the
      corpse away. FOUND EN ROUTE: a process that SIGKILLs *itself* via the
      shell lands Result=success and the unit unloads (observed on systemd
      258/.160; no corpse, no verdict) — the external-kill case (host OOM
      killer, stray pkill: the real threats) is the one that fails-and-
      lingers, and it's captured. spec_death now 20 (classifier + mapper +
      the pure argvs); spec_nspawn updated for the --collect removal.
      KVM + NESTED-IN-VM ARMS 2026-07-18 (second round, on .160):
      - **kvm (process half)**: driver_vm.death_state reads the VM's
        Type=forking --user unit (aeo-<nm>) — EMPIRICALLY confirmed first
        that forking+PIDFile units populate Result/ExecMainCode/Status on an
        external SIGKILL of the daemonized pid (systemd 258, user manager
        reaps the orphan). LIVE-PROVEN via `aeo up`: a REAL qemu VM (blank
        qcow2, real /dev/kvm boot) killed mid-window -> "kernel verdict:
        killed by SIGKILL (exit 137)" at the declared within(25s), death
        event hash-chained. down() + relaunch now reset-fail the unit corpse
        (aeo's own teardown kill must not read as a death / block --unit
        reuse). Guest-OS-level death (panic inside a live qemu) stays the
        agent's future layer.
      - **nested container in a local VM**: driver_vm.guest_death_state —
        the engine inspect through the SAME ssh exec seam as `aeo exec`
        (resolved guest IP + guest key), classified by lib/death. MECHANISM
        LIVE-PROVEN on .160 with the box standing in as the guest
        (AEO_GUEST_USER/AEO_SSH_KEY -> 127.0.0.1): exit-3 container ->
        "exited with code 3", REAL cgroup-OOM'd container -> "OOM-killed
        (cgroup memory limit)", absent -> no verdict; the sh->ssh->sh
        quoting of the piped format is the production path. Full in-cell
        proof (real VM guest) when the kvm_podman cell next runs — .160 has
        no sudo for tap networking.
      TWO driver fixes en route: (1) `ubuntu@` was HARDCODED in all three
      ssh-seam sites — now `_guest_user()` (AEO_GUEST_USER, default ubuntu,
      mirroring AEO_SSH_KEY; debian/fedora cloud images need it); (2)
      `_guest_ip`'s `nc -z` pre-check: a box WITHOUT nc (minimal Arch) took
      the exit-127 else-branch into the bhyve MAC-lookup and silently
      BLANKED the whole exec seam (aeo exec on VM nodes included) — now a
      missing nc trusts the resolved IP and lets ssh's ConnectTimeout
      surface unreachability.
      WSLC ARM 2026-07-18 (third round, spiked LIVE on winbaz): `wslc
      inspect NAME` returns Docker-shaped JSON with State.Status +
      State.ExitCode — proven against real wslc 2.9.3.0 on the guest:
      /bin/false -> ExitCode 1; `wslc kill` -> ExitCode 137 (the >128 signal
      convention HOLDS); a stopped container LINGERS in `list --all` until
      removed (corpse readable at diag time). State has NO OOMKilled field —
      oom reports false, so a wslc OOM kill classifies as "killed by SIGKILL
      (exit 137)" (a verdict, just less specific). BUILT:
      driver_wslc.inspect_death_argv / death_line (needle parse LOCKED
      against the real captured fixture — ExitCode BEFORE Status inside
      State, Config.Cmd present so a false match would be caught) /
      death_state; runner diag dispatches engine wslc to it. Proof bar = the
      driver_wslc house discipline (exact argv run live against real
      wslc.exe + parser fixture-locked to real output); in-driver execution
      on a Windows host rides the aeo-agent.exe pipeline when that thread
      resumes. spec_death 26.
      LXC ARM 2026-07-18 (fourth round, spiked + LIVE-PROVEN on .160 via
      UNPRIVILEGED lxc — the box has subuid maps + user-slice memory/pids
      delegation; ~/.config/lxc idmap config + a setfacl u:100000:x on
      /home/paul were the only setup, no sudo). TWO verdict sources, both
      empirically mapped on real LXC 6.x:
      - **RUNNING but sick**: the payload cgroup's memory.events oom_kill
        counter (resolved via lxc-info PID -> /proc/<pid>/cgroup, so rootful
        AND unprivileged placements both work; unprivileged read). NEW
        verdict class in lib/death: status=running|oom=true -> "OOM kills
        inside (cgroup memory limit; container still running)" — the kernel
        killed WORKLOAD processes while init survives. GOTCHAS proven live:
        swap absorbs the pressure (memory.swap.max=0 needed alongside
        memory.max for a deterministic OOM — CachyOS zswap soaked 64MB);
        busybox tail gets a failed malloc, not an OOM kill (fill /dev/shm
        tmpfs instead — unreclaimable pages force the killer).
      - **STOPPED**: the cgroup VANISHES on stop; the ONLY post-mortem
        carrier is the lxc log — so start_argv now passes `-o
        <AEO_LXC_LOG_DIR|/tmp>/aeo-lxc-<n>.log -l INFO`, where LXC records
        "Child <pid> ended on signal <Name>(<N>)" (-> 128+N) or "ended on
        error (<N>)" (-> N); a CLEAN exit logs no ended-line (LXC only logs
        error ends). lxc-info exposes state+pid but NO exit code. Rootful
        caveat recorded in the driver: the root-written 0640 log needs an
        operator default-ACL'd log dir for the unprivileged read, else the
        stopped verdict degrades to honest "".
      BUILT: driver_lxc.death_log_path/death_from_log/death_state +
      `_lxc_query` (sudo-grant first, PLAIN fallback for unprivileged-lxc
      hosts, both stderr-swallowed); runner diag dispatches kind lxc.
      LIVE-PROVEN through the real driver on .160: running+capped+shm-fill
      -> "OOM kills inside (cgroup memory limit; container still running)";
      lxc-stop -k -> "killed by SIGKILL (exit 137)" parsed from the driver's
      own log. spec_death 32 (log wordings locked from real captures).
      PROXMOX ARMS 2026-07-18 (fifth round, LIVE-PROVEN on the FRESH .204 —
      reformatted PVE 9.2.2, already bootstrapped: template 9000 + pool +
      snippet + aeo@pve; root key auth survived the reformat; token minted
      fresh via the idempotent token_setup): driver_proxmox.death_state —
      TASK-HISTORY CORRELATION over the token seam. PVE exposes no exit code
      for a dead guest, but every operator/API stop is a task
      (qmstop/qmshutdown/vzstop/...), so STOPPED with no stop-shaped task
      newer than the last start-shaped task = DIED (qemu crashed, host
      OOM-killed it, or in-guest poweroff). One death_state serves BOTH
      kinds (_ep-shared, like the rest of the driver); the pre-classified
      verdict rides a new `cause=` pass-through field in lib/death's
      canonical line (no lossy exit-code encoding). LIVE PROOFS:
      - proxmox_vm, FULL aeo-up diag: cloned VM w/ cloud_init+agent(1)
        (running-but-not-UP window), kvm process kill -9'd ON THE PVE HOST ->
        "kernel verdict: stopped with no stop task (hypervisor process died,
        host-killed, or powered off from inside the guest)" at the declared
        within(3m); death event hash-chained (kind=proxmox_vm); teardown
        destroyed the corpse.
      - proxmox_ct, driver-level probe: host-side kill of the CT's init (no
        task) -> the died verdict; CONTROL: a deliberate `pct stop` -> NO
        verdict.
      THE CONTROL CAUGHT A REAL HOLE: PVE shows a non-root user only its OWN
      tasks — root@pam's pct stop was INVISIBLE to the token, so an operator
      stop read as a death. Fix: `Sys.Audit` (read-only, same class as the
      VM.Audit/Pool.Audit already granted) in a separate `aeo-taskviewer`
      role on /nodes, granted to BOTH user and token (the privsep
      intersection rule) — baked into proxmox_token_setup.sh (§4b) and
      re-proven from a clean re-run with a rotated token. spec_death 33
      (cause= pass-through locked).
      NESTED-IN-REMOTE-PROXMOX ARM 2026-07-18 (sixth round — the AGENT-VERB
      arm, LIVE-PROVEN on .204 through the full recursive chain): the
      aeo-agent protocol gained a `death` verb — the guest's RESIDENT agent
      runs the engine inspect INSIDE the boundary (tries the delegate path's
      `aeo-<node>` name, then bare) and replies the canonical
      status|oom|exit line as the report state (spaceless by construction,
      rides the space-separated wire intact; "none" when nothing to report).
      The PARENT classifies — the agent only reads. driver_vm gained
      agent_death_at (mirrors agent_status_at: dial <guest-ip>:9450 direct)
      + the pure agent_death_line reply parser (spec-locked, incl. not
      mistaking a `status`-verb "up" reply for a death line); the runner
      diag routes container-nested-in-proxmox_vm through it via
      driver_proxmox.guest_ip. LIVE (dev delivery: locally-built agent
      served from the PVE host + a dev snippet with the local SHA — the
      versioned-release path needs a new aeo-agent-v* tag when this merges):
      full chain up (clone -> cloud-init -> agent fetch+verify+start ->
      delegate -> child container) and the diag surfaced "kernel verdict:
      exited with code 127" for the child inside the remote guest — a REAL,
      UNSTAGED failure the new arm diagnosed on its first flight (see next
      item), hash-chained (node=dead kind=container event=death). The
      verdict can ONLY have come through the agent verb — no host engine or
      ssh can see that container.
      **RELEASE-BLOCKING CHAIN FINDING — FIXED 2026-07-18 (static link):**
      the agent binary had grown a libnghttp2.so.14 dep (std.http's LB-era
      growth) + libssl3/libcrypto3 — `debian:stable-slim` (the
      agent-in-container base, _fire_child_async default) does NOT ship
      nghttp2, so a fresh DYNAMIC agent build exited 127 in the child
      container (the exact verdict the forensics returned; the v0.1.1 asset
      predates the dep, which is why the 2026-07-11 chain worked). FIX:
      STATIC LINK — `AE_CC="gcc -static" ae build bin/aeo-agent.ae` (after
      `ae cache clear`; AE_CC alone doesn't invalidate ae's content cache —
      a toolchain gotcha). Removes the ENTIRE runtime-deps axis: the same
      binary serves /health in debian-slim, musl Alpine AND bare busybox
      (all proven in local podman) — the glibc-vs-musl asset axis is
      designed out, not labeled. The static-glibc NSS/getaddrinfo caveat
      doesn't apply (the agent binds IP literals + shells to curl).
      `.github/workflows/release-aeo-agent.yml` REWRITTEN: asset renamed
      `aeo-agent-linux-x86_64-static`, AE_CC static build, libssl-dev +
      libnghttp2-dev runner prereqs, asserts now require "statically
      linked" (the name can't lie). Next `aeo-agent-v*` tag ships it; the
      snippet template bumps URL+SHA then. LIVE RE-PROOF on .204 with the
      static agent (dev-served): the recursive chain came up HEALTHY
      ([db_vm] up -> [dead] up -> stack up — the chain is UNBROKEN again),
      and the staged-kill re-proof completed against the standing tree via
      the agent death verb: alive -> "status=running|oom=false|exit=0" (no
      verdict — correct), `podman kill` in-guest ->
      "status=exited|oom=false|exit=137" -> "killed by SIGKILL (exit 137)".
      Clean aeo down.
      BWRAP + BHYVE ARMS 2026-07-18 (seventh round) — the "supervisor-gated"
      pair turned out to need NO supervisor:
      - **bwrap — BUILT + LIVE-PROVEN (Crostini)**: the launch now PREFERS a
        transient --user unit with bwrap as the unit's MAIN process (plain
        setsid stays as the non-systemd fallback, honestly verdict-less).
        KEY EMPIRICAL FINDING that picked the shape: the first attempt
        (Type=forking + PIDFile over the info-fd child-pid, the kvm shape)
        tracks a pid that is NOT systemd's child — "we'll most likely not
        notice when it exits" — and indeed the unit stayed active/success
        after the kill. bwrap-as-main works because bubblewrap PROPAGATES
        the sandboxed child's death as its own exit (128+signal): kill -9
        of the INNER process -> unit Result=exit-code ExecMainStatus=137 ->
        the shared unit_death_line. Side benefits: the unit scope fixes the
        latent SIGHUP-reap fragility (the kvm/firecracker bug, previously
        unfixed here), down() now `systemctl stop`s the WHOLE cgroup (outer
        + reaper + child — a pid-kill of outer could orphan the sandbox),
        and the pidfile carries MainPID so the batch-sweep contract is
        unchanged. LIVE on TWO boxes: kill of the inner process mid-window
        -> "kernel verdict: killed by SIGKILL (exit 137)", death event
        hash-chained (kind=bwrap) — proven on Crostini (Debian 12) AND
        CachyOS .160 (Arch, systemd 258), clean teardown both (no failed
        units, no leftover processes).
      - **bhyve — BUILT, source-derived (live pending a FreeBSD box)**:
        vm-bhyve IS already the supervisor — its run loop interprets
        bhyve's guest-meaningful exit codes (0=reset, 1=poweroff, 2=halt,
        3=triple fault) for restart-vs-stop and logs "bhyve exited with
        status N" / "fatal; loader returned error N" to the guest's
        vm-bhyve.log. driver_vm.bhyve_death_state reads that log when the
        VM is down; bhyve_death_from_log maps codes to cause= verdicts
        ("guest TRIPLE FAULT (bhyve exit 3 — crashed)" etc.). Wordings
        taken from churchers/vm-bhyve lib/vm-run (2026-07-18) and
        fixture-locked in spec_death; MODELED until a FreeBSD box is back
        on the bench.
      The supervisor design remains relevant as the general
      parent-of-every-node answer (and the non-systemd-host fallback is
      still verdict-less) — but no death-forensics row is gated on it now.
      spec_death 43.
      Remaining follow-ups: memory.events oom_kill as ground truth where the
      engine under-reports rootless OOMs (podman arm; the lxc arm now reads
      it directly); live-prove the bhyve log arm on a FreeBSD box (fixtures
      are source-derived); jail rctl denies are EVENT-shaped (the
      denials-ledger mechanism, not post-mortem state); guest-OS-level death
      via the in-guest agent (kvm panic; proxmox distinguishing crash vs
      in-guest poweroff — the task correlation can't); RELEASED 2026-07-18:
      aeo-agent-v0.1.2 (asset aeo-agent-linux-x86_64-static, SHA 35c87fb2…)
      cut + published by CI, snippet template pinned to it, and the FULL
      recursive chain re-proven on .204 via the REAL release delivery
      (GitHub fetch -> CI-SHA verify -> [db_vm] up -> [dead] up -> stack up
      -> clean down); EARLY-EXIT the level poller when every
      not-up node already has
      a death verdict; swallow the cosmetic engine stderr from
      probing/inspecting an exited or absent container (podman "exec
      sessions" + "no such object" leaks); eBPF signal streams as the later
      tier.
- [ ] **5. Mutual TLS with per-node identity on the agent conduit.** aurae
      does SPIFFE-style x509 mTLS down to the Unix socket — every client has
      a minted identity (docs/certs.md, certgen per client). aeo's agent auth
      is a bearer token (the live-debug default was literally
      "aeo-dev-token"). The existing HTTPS-conduit follow-up (§ aeo-agent
      slices) is server-TLS + token; the aurae-shaped upgrade is MUTUAL auth
      with per-node certs minted at seed time via lib/secrets — parent
      verifies child AND vice versa down the delegate chain (depth 0 -> 1 ->
      2). Also feeds the multi-host/WireGuard design: per-node crypto
      identity was the flagged caveat of host-level WG (the host's pf/routing
      is trusted; node certs give the independent identity back).
- [ ] **6. `aeo logs <node> [--follow]` — streaming workload output.** aurae
      streams daemon logs + subprocess stdout/stderr as first-class API
      (observe.proto GetSubProcessStream). aeo has `exec` but no log verb — a
      day-2 ops gap; the agent chain is already the transport (delegate a
      STREAM instead of a command; for host-visible containers it's just
      `podman logs -f` behind the verb).
- [ ] **7. (Minor) Discovery.** aurae's `Discover()` RPC returns
      node/instance identity + version. aeo's multi-host epic wants the agent
      to answer "who are you, what do you hold" for cross-host inventory
      (the 5-proxmox-host + chromebook-control-plane design). FOLD INTO the
      multi-host design doc rather than building standalone — it's one verb
      on the agent protocol.

Sequencing: 3+4 are self-contained and buildable now (grammar + diag work, no
new architecture); 2 is a runner phase with immediate cutover payoff; 1 is
the strategic one and rides clawk item 3 (OCI-as-rootfs); 5 rides the
existing HTTPS-conduit item + lib/secrets; 6 is small once the agent protocol
grows a stream shape; 7 folds into the multi-host design doc.

## One to watch: uvm (surveyed 2026-07-17 — future substrate, not yet)

uvm (~/scm/uvm, github.com/maximecb/uvm — Maxime Chevalier-Boisvert's
minimalist APPLICATION VM) is a different category from clawk/aurae: a stack-
bytecode interpreter with ~40 frozen syscalls, NO FFI, self-contained app
images, and an anti-code-rot mission (APIs freeze at 1.0). Pre-1.0,
interpreter-only, programs ship as `.asm` TEXT files today. Little to copy
now; the value is as a FUTURE SUBSTRATE — and it would be aeo's purest
containment tier, stronger than bwrap STRUCTURALLY: no FFI and no syscall
escape means a program's entire reachable universe is the ~40 calls.
Containment isn't a filter that could be misconfigured; the capability
DOESN'T EXIST in the machine. Bonus alignment: frozen APIs + self-contained
images compose with aeo's reproducibility story — an attested uvm image in a
composition deploys bit-identically decades later, which no container image
can promise.

Spec findings (from spec/syscalls.json, 2026-07-17):
- NO outbound TCP at all — net surface is net_listen/accept/read/write/close,
  server-side only, no net_connect. So a uvm workload can SERVE but not DIAL:
  deny_egress() is free-by-construction, but a non-leaf workload (app -> db)
  is impossible until outbound lands.
- Permission system HALF-SKETCHED: every syscall carries a `permission` tag
  (net_server, net_io, …) but spec/permissions.json is literally 0 bytes —
  the grant mechanism is planned, unbuilt. When it lands it's exactly the
  shape constrain{} renders onto: per-node grants over a small enumerable
  capability set.
- Roadmap items that map straight onto aeo verbs: single-file binary app
  image with metadata (-> image() + the easiest attest() ever — one file,
  one sha256); headless/no-SDL build (a server node can't require SDL2);
  "suspend a running program to a new app image file" (-> the snapshot/
  suspend verbs as a PORTABLE FILE — cleaner than clawk's RAM+disk pair).

READINESS GATE for a driver_uvm (re-check the repo against this list before
building anything): (1) headless/no-SDL build; (2) the binary image format
(can't meaningfully attest a .asm text file — no metadata/entry contract);
(3) outbound net_connect for non-leaf workloads; (4) the permission system
for constrain{} rendering. Driver shape when it's time: the bwrap/
firecracker tier — pidfile/systemd-run-tracked process, command() = the app
image, probe = process-alive + TCP health, deny_egress recorded as
STRUCTURAL rather than rendered.

Copyable NOW (small, independent of the substrate):
- [ ] **"Containment by absence" as a recorded posture class.** A boundary
      can be ABSENT-BY-CONSTRUCTION (bwrap --unshare-all, --network none, a
      uvm with no net_connect syscall) vs FILTERED-BY-POLICY (pf rules,
      internal nets, allow-lists). aeo's audit/status records what was
      RENDERED but not which class it is — record it ("egress: impossible"
      vs "egress: filtered") for a more truthful audit trail and a stronger
      attestation-of-posture story. Lands in: lib/audit + status.
- [ ] **Declarative spec -> generated docs/bindings.** uvm's
      spec/syscalls.json generates the markdown docs, Rust constants, AND C
      headers from one source. aeo analog: spec the agent protocol verbs
      (dispatch/delegate/status/report, soon streams) once and generate
      docs/ + the LLM.md tables, so protocol and docs can't drift. Small.
- [ ] **Attest follow-up note**: §3's "attest a qcow2 / jail-dataset hash"
      cross-substrate item should name the single-file app image as the
      degenerate ideal case (one file, one hash) when a uvm/appimage-like
      substrate arrives.
