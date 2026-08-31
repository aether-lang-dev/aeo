# winbaz: nested-virt + Windows aeo-agent — live findings (2026-07-22)

Fresh-eyes pass over `winbaz` (the Win11 bhyve/KVM guest used to prove the
Windows aeo-agent), treating it as a first encounter. Records what actually
works, what doesn't, and why — so the boundaries aren't rediscovered.

## Box

Win11 **Home** x64, user `paul` (admin). It is itself a **system-libvirt KVM
guest** (`win11`, qemu:///system) on the bazzite host (AMD Ryzen 7 5800U).
Reached via `ssh bazzite@192.168.0.57` → `ssh -i ~/.ssh/win11_key paul@192.168.122.179`.

## The Windows agent chain WORKS — proven end-to-end

Not just "the binary runs / serves /health" (the shallow release proof). The
full control-plane chain functions on the real box:

```
aeo-agent.exe (cross-built on Linux) running, serves /health=ok
  → POST /dispatch "boot <token> <node>"   (auth-gated)
  → driver_windows → wsl -d Ubuntu -- podman run busybox
  → reply "report <token> <node> up"
  → verified: a container named for the node exists in WSL podman
```

Container lifecycle the agent depends on, all working via WSL podman:
launch ✅, exec-in ✅, filesystem write ✅, stop ✅, cleanup ✅.

## Nested virtualization — attempted, hit the AMD-KVM-Hyper-V wall

WSL2's *full* nested-virt mode does NOT engage. Windows reports
`SecondLevelAddressTranslationExtensions=False` and `wsl -d Ubuntu -- uname`
errors `Nested virtualization is not supported on this host`.

Levers tried (both correctly applied, neither moved SLAT):
1. **libvirt guest CPU**: added `<feature require svm/>` + `<feature require
   npt/>` to the `host-passthrough` `<cpu>` (verified live: the running qemu now
   shows `-cpu host,...,svm=on,npt=on`). Host is capable: `kvm_amd nested=1`,
   `npt=Y`, host CPU has `svm`. Script: `fix-winbaz-nested-virt.sh` on bazzite.
   (Watch out: the first version's regex dropped the self-closed `<topology/>`
   child and produced mismatched tags — `virsh define` rejected it, so nothing
   changed; v2 INSERTS the features and validates well-formedness before define.)
2. **Windows Hypervisor Platform**: was `Disabled`; enabled it +
   `hypervisorlaunchtype auto`, rebooted Windows. Still `SLAT=False`.

Conclusion: this is the known hard wall of **nested WSL2 (a Hyper-V VM) inside a
QEMU/KVM AMD Windows guest**. Windows' Hyper-V SLAT probe on AMD wants
nested-paging CPUID bits that qemu `-cpu host` doesn't expose to Hyper-V's
satisfaction — a KVM AMD nested-SVM emulation gap, not a config flag. (Intel
hosts, or bare-metal Windows, generally work; AMD-nested-Hyper-V-in-KVM is the
flaky corner.) Hyper-V proper isn't even available on Win11 **Home**.

## …but nested virt turned out to be MOOT

Containers run **without** WSL2's nested-virt mode — every `podman run` returned
`NESTED_OK` and the agent boot chain reported `up` throughout. WSL2 only
complains about its utility-VM *optimization*; the workload the agent drives
works on the degraded path. Enabling nested virt would not have changed the one
thing that IS broken (below) — that's podman/WSL networking, not the hypervisor.

## The real limitation: container → outbound network fails

Independent of nested virt. A container gets an interface + route
(`default via 172.18.96.1 dev eth0`) but outbound `wget`/`curl` fails, even with
`--network=host`. Backend is `netavark`, the default `podman` network exists.
Root cause: **podman-rootless networking (netavark + pasta/slirp) egress does
not work in this WSL Ubuntu** — a known podman-rootless-in-WSL friction, NOT an
aeo or nested-virt issue.

Impact: the agent's control plane + self-contained (no-network) container
workloads work; workloads that must pull images at runtime or reach the network
need the distro's podman-rootless networking fixed first (a distro-side task:
netavark/pasta config, or rootful podman, or Docker-Desktop-style networking).

## Two driver_windows hardening notes (fresh-eyes frictions)

- **WSL emits UTF-16LE** — parsing `wsl.exe` stdout over a pipe corrupts on NUL
  bytes. Read distro state from the registry (`HKCU\...\Lxss`) or strip NULs;
  don't parse raw `wsl.exe` output.
- **`wsl --status` / first `wsl -d` call can hang** — any driver_windows call
  into wsl needs a timeout guard (every probe here needed a job-timeout).

## Bottom line for the roadmap

The TODO "aeo-agent ON WINDOWS pipeline" item is **done at the control-plane
level** (agent boots/contains/reports a real container end-to-end on a real
box). Two follow-ups remain, both outside aeo: (a) podman-rootless networking in
the WSL distro for networked workloads; (b) nested-virt is not worth chasing on
this AMD-KVM box (and isn't needed).
