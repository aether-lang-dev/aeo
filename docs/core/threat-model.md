# aeo: Threat Model and Security Assumptions

## Executive Summary

aeo is an infrastructure orchestrator designed to stand up, keep coherent, and tear down trees of compute nodes with **per-node confinement**, **image attestation**, and **tamper-evident audit trails**. This document specifies what aeo protects against and what is explicitly out-of-scope.

The core security assertion, stated to the limit this document actually supports:
**orchestrated trees of compute nodes, each confined by enforced, evidenced
boundaries — resource caps, capability drops, network policy and attested images —
within a single trust domain.** Not "impregnable": aeo's containment rests on
kernel, hypervisor and runtime primitives, and a vulnerability in any of those
bypasses it (see *Out-of-Scope Threats*). The claim aeo stands behind is narrower
and testable — every boundary it offers has an enforcement point and evidence, and
where it cannot enforce a declared property it says so (`aeo status` reports
`supported: no` / `applied: no`; see `reference/status-schema.md`) rather than
implying a protection it doesn't deliver.

---

## Threat Model

### Adversary Assumptions

aeo defends against **two** adversaries, and it is important not to conflate them
(an earlier version of this document did — it claimed an adversary with host root
who nonetheless could not read a mode-0600 key file, which is a contradiction: root
reads anything). The coherent models are:

**Adversary A — a compromised node.** A workload aeo stood up is hostile or has
been taken over. It:
- runs arbitrary code *inside its confinement* (container/jail/VM);
- tries to escape confinement, starve the host, or reach the network/peers it was
  not granted.

This is aeo's primary adversary, and the one its confinement, network policy and
attestation are built against.

**Adversary B — an unprivileged local user** on the same host, without aeo's own
UID. They can see process lists and world-readable files but cannot read aeo's
0600 key file or write its working directory.

aeo assumes neither adversary:
- has host **root/admin** — root defeats every user-level boundary here (it reads
  the 0600 key file, the audit trail and process memory; this is stated plainly at
  each boundary below, and is why host-root is out of scope, not a protected-against
  case);
- has physical access to the machine;
- controls the **hypervisor** (for VM nodes), the **kernel**, the container
  **runtime**, or the **Aether compiler / ae toolchain**.

A node that breaks *out* to host root has, by definition, defeated the containment
boundary — that is a confinement failure (Property 1), not a separately defended
layer.

### Protected Properties

#### 1. Node Confinement (Containment Boundary)

**Property:** A node cannot escalate privileges beyond its confinement rules.

**Protected against:**
- Fork bombs (memory exhaustion via `--pids-limit`)
- Capability escalation (via `--cap-drop ALL`)
- Coarse network isolation: no network (`--network none`) or intra-only
  (`--network internal` — reach named peers, not the host/internet)
- Resource starvation (via `--memory`, `--cpus`)
- Jail escape (FreeBSD rctl boundaries proven)
- pf egress filtering on FreeBSD (whitelisted flows only, others denied)

**Not protected against:**
- Kernel vulnerabilities (exploits in the kernel itself)
- Hypervisor vulnerabilities (if running in VMs)
- Vulnerabilities in the container runtime (podman/docker bugs)
- Zero-days in confinement mechanisms
- **Name-aware egress (`egress_fqdn`) — NOT YET ENFORCED.** A declared
  `egress_fqdn` is honest-but-coarse today: on FreeBSD it is not lowered to a pf
  pass, and on Linux the node is placed on an `--internal` network *stand-in* (no
  internet) rather than being filtered by destination name. `aeo status` reports
  this as `supported: no, applied: no` (see `reference/status-schema.md`); the
  parent-owned CONNECT gateway that will enforce it is designed but not wired
  (`research/egress-fqdn-considered.md`). Do not rely on `egress_fqdn` as a
  destination allowlist yet.

#### 2. Image Attestation (Supply Chain)

**Property:** when a node declares a digest (`attest("sha256:…")`), its image's
actual digest must match before the node starts, or aeo refuses it (fail-closed).

**What a digest pin does and does not prove.** A digest proves **content
identity** — the bytes you pinned are the bytes that run. It is *not* a signature:
it says nothing about **who published** the image. Publisher authenticity
(cosign/Notary) and build provenance (SLSA) are separate, complementary checks
that happen upstream of aeo (see *Recommendations*).

**Pinning is optional by default.** An unpinned node boots and is reported
`attestation: unpinned` — a finding a CI gate or audit can act on, not a block.
Strict mode (`strict()` in the composition) turns an unpinned image into a
refusal: a node in a `strict()` system does not start unless its image is pinned
(and unless every declared security property is enforceable on its backend). See
`reference/status-schema.md`.

**Protected against (for a pinned node):**
- Silent image replacement (a digest mismatch is detected and refused at boot)
- Downgrade/substitution to a *different* image (any digest not matching the pin is
  rejected)

**Not protected against:**
- An unpinned node (no `attest()`) — nothing to check; reported `unpinned`
- A backdoored image whose digest you pinned (content-identity ≠ trustworthiness)
- Registry or build-system compromise that produced the image you pinned
- A forged *publisher*: a digest is not a signature (use cosign/SLSA upstream)

#### 3. Audit Trail Integrity (Forensics)

**Property:** The audit log is tamper-evident via hash chaining.

**Protected against:**
- Silent log modification (tampering detected on verification)
- Log truncation (last entry pinned, truncation detected)
- Log reordering (sequence integrity via chaining)

**Not protected against:**
- Selective deletion (the hash chain detects tampering but doesn't recover deleted entries)
- Pre-tampering logs (if log is modified before aeo audit runs)
- Offline attacks (if an attacker can stop aeo and modify state directly)
- **A full rewrite by whoever controls both the log and its checkpoint.** The hash
  chain makes *partial* tampering evident: an entry changed in isolation breaks the
  chain. But the integrity check compares the chain against a checkpoint stored
  beside the log; an attacker who can rewrite the whole log *and* recompute/replace
  that checkpoint produces a self-consistent forgery that `aeo audit` accepts. The
  chain detects tampering, not an attacker with write access to both halves. To
  close this, anchor checkpoints **off-host** — append-only remote storage, a
  syslog/audit daemon, or another node — so the attacker cannot control the
  reference copy (see *Boundary 3* and *Recommendations*).

#### 4. Secrets Confidentiality (Encryption)

**Property:** Secret values are encrypted at rest and in transit until the moment of use.

**Protected against:**
- Reading plaintext secrets from state/logs (all ciphertext)
- Tampering with sealed values (HMAC verification detects modification)
- Using the wrong key (decryption fails, returns "")
- Timing attacks on MAC verification (constant-time comparison)

**Not protected against:**
- Memory dumps (plaintext exists in RAM at use time, by definition)
- Compromised key file (if `~/.config/aeo/secrets.key` is read)
- Keyloggers or process introspection (anything with root can read memory)
- Side-channel attacks in the hardware (cache timing, power analysis)

---

## Security Boundaries

### Boundary 1: The Composition File

**What it protects:** aeo trusts the composition file.

Implication: If an attacker modifies the compose file, aeo will execute the attacker's instructions.

**Why it's safe:** aeo runs as the user who invokes it. If an attacker can modify the composition file, they already have the same privilege level as aeo. Trust in the composition is not an additional risk.

**Recovery:** Verify the composition file before `aeo up`.

### Boundary 2: The Secrets Key File

**What it protects:** aeo trusts the key file at `~/.config/aeo/secrets.key`.

Implication: If an attacker reads this file, all sealed secrets can be decrypted.

**Why it's safe:** The key file is owned by the user and has mode 0600 (rw-------). Only the user can read it. If an attacker has read access, they have root/admin and can read anything.

**Recovery:** If the key is compromised, all sealed values must be re-sealed with a new key. The old key should be deleted immediately.

### Boundary 3: The Audit Trail

**What it protects:** aeo trusts the audit trail file location.

Implication: If an attacker modifies the audit file before aeo checks it, tampering is undetected.

**Why it's safe:** The audit file is stored in the AEO_WORK directory, which is typically /tmp/aeo-build or user-specified. Only the user running aeo can write there. If an attacker has write access to AEO_WORK, they have root/admin.

**Recovery:** Store audit trails in a tamper-evident external log (syslog, audit daemon) for production use.

---

## Out-of-Scope Threats

The following are explicitly NOT protected by aeo:

1. **Kernel vulnerabilities**
   - aeo's confinement uses kernel primitives (cgroups, seccomp, rctl, pf)
   - A kernel vulnerability bypasses all containment
   - Mitigation: Run on a patched, hardened kernel

2. **Compromised images**
   - aeo verifies the image digest matches the composition
   - aeo does NOT verify the image is non-malicious
   - Mitigation: Use image scanning tools upstream of aeo

3. **Runtime vulnerabilities**
   - aeo uses podman/docker/lxc/jail as-is
   - Runtime bugs are not aeo's responsibility
   - Mitigation: Keep container runtime updated

4. **Physical access**
   - aeo assumes the hardware is controlled
   - Someone with physical access can read RAM, modify disks, etc.
   - Mitigation: Secure the data center

5. **Network-layer attacks**
   - aeo trusts that network packets reach the intended destination
   - Man-in-the-middle attacks are not mitigated by aeo
   - Mitigation: Use encrypted network transport (TLS, WireGuard)

6. **Multi-tenant scenarios**
   - aeo is designed for single-user or single-trust-domain use
   - Multiple untrusted users on the same host can attack each other
   - Mitigation: Use separate systems for untrusted users

---

## Cryptographic Assumptions

### Key Derivation (HMAC-SHA256 Labeled)

aeo derives encryption and MAC keys using HMAC-SHA256 with labels:
```
enc_key = HMAC-SHA256(master_key, "aeo-secrets-enc-v1" || salt)
mac_key = HMAC-SHA256(master_key, "aeo-secrets-mac-v1" || salt)
```

**Assumption:** HMAC-SHA256 is a secure PRF under the assumption that SHA-256 is collision-resistant and the key is random.

**Justification:** This follows RFC 2104 and is the recommended approach in "Cryptographic Right Answers" (Colin Percival). It is not HKDF, but is equally sound and simpler to implement correctly.

### Encryption (PRF-CTR XOR)

aeo encrypts plaintext using a PRF in counter mode:
```
keystream = HMAC(enc_key, "nonce|0") || HMAC(enc_key, "nonce|1") || ...
ciphertext = plaintext XOR keystream
```

**Assumption:** HMAC in counter mode is a secure stream cipher.

**Justification:** This is a standard construction (SP 800-38A). XOR with a PRF-generated keystream is semantically secure if the PRF is a random function.

### Authentication (Encrypt-Then-MAC)

aeo computes the MAC AFTER encryption:
```
tag = HMAC(mac_key, salt || nonce || ciphertext)
verify: expected_tag = HMAC(mac_key, salt || nonce || ciphertext)
        if expected_tag != actual_tag: REJECT (constant-time)
```

**Assumption:** MAC is computed over the ciphertext, and verification is constant-time.

**Justification:** Encrypt-then-MAC is the secure composition (Bellare & Namprempre, 2000). Constant-time comparison prevents timing attacks (Kocher, 1996).

---

## Operational Security Assumptions

### Assume Operator Follows Procedures

aeo assumes:
- The key file is kept confidential
- The composition file is kept correct
- The audit trail is reviewed regularly
- Compromised keys are rotated immediately
- Unusual orchestration activity is investigated

### Assume Infrastructure is Correct

aeo assumes:
- The container runtime (podman/docker) works as documented
- The network (docker networks) is correctly configured
- The kernel confinement (cgroups, seccomp) is enabled
- System time is reasonably accurate (for audit trails)

---

## Testing and Validation

### Live-Proven Properties

The following have been proven on real hardware:

1. **Linux container confinement**
   - Fork bomb (resource limit) refused by `--pids-limit`
   - Egress-denied node has zero network connectivity
   - Cap-drop prevents privilege escalation
   - Tested: Bazzite (Fedora Atomic) + podman

2. **Image attestation**
   - Wrong digest is refused at boot time
   - Tested: Both podman and docker

3. **Audit trail integrity**
   - Tampering is detected by `aeo audit`
   - Hash chain is verified
   - Tested: Manual tampering, log truncation

4. **Secrets fail-closed**
   - Wrong key returns ("", error)
   - Tampered envelope returns ("", error)
   - Tested: spec_secrets (10 cases)

5. **FreeBSD confinement**
   - Jail boundary enforced
   - rctl resource caps enforced
   - pf network policy enforced
   - Tested: GhostBSD 21.1.1 + bhyve

### Untested Edge Cases

- Kernel vulnerability (explicitly out-of-scope)
- Runtime vulnerability (explicitly out-of-scope)
- Multi-tenant attacks (explicitly out-of-scope)
- Timing attacks on cryptography (constant-time verify implemented, not attack-tested)

---

## Recommendations for Production Deployment

1. **Key Management**
   - Store secrets key in a key management service (KMS, HashiCorp Vault)
   - Rotate keys on a regular schedule
   - Never commit secrets key to version control

2. **Audit Trail**
   - Forward audit logs to a centralized logging system (syslog, Datadog, etc.)
   - Review audit logs regularly for suspicious activity
   - Keep immutable copies of audit logs for compliance

3. **Image Supply Chain**
   - Use image signing (Notary, Cosign) before the digest reaches aeo
   - Verify images in an air-gapped registry
   - Scan images for vulnerabilities before deployment

4. **Kernel Hardening**
   - Enable AppArmor or SELinux for defense-in-depth
   - Keep the kernel patched and updated
   - Disable unnecessary kernel modules

5. **Network Isolation**
   - Use separate networks for each tier (aeo provides network policy, but assume defense-in-depth)
   - Use encrypted network transport (TLS, WireGuard)
   - Implement firewall rules at the host level

6. **Monitoring**
   - Monitor aeo status and orchestration latency
   - Alert on failed health checks
   - Alert on audit trail verification failures

---

## References

- Saltzer & Schroeder (1974): "The Protection of Information in Computer Systems"
- Kocher (1996): "Timing Attacks on Implementations of Diffie-Hellman, RSA, DSS, and Others"
- Bellare & Namprempre (2000): "Authenticated Encryption: Relations Among Notions and Instantiations"
- RFC 2104: "HMAC: Keyed-Hashing for Message Authentication"
- SP 800-38A: "Recommendation for Block Cipher Modes of Operation"
- Watson et al. (2010): "Capsicum: practical capabilities for UNIX"
- Percival (2009): "Cryptographic Right Answers" (blog)
- Principles of Containment (Paul Hammant): https://paulhammant.com/2016/12/14/principles-of-containment/

