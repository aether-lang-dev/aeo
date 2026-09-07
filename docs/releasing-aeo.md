# Releasing aeo

**ONE release, ONE version, LOCKSTEP.** A single `v*` tag (e.g. `v0.2.0`) cuts
one GitHub Release carrying BOTH halves of aeo:

| half | assets | who consumes it |
|---|---|---|
| **aeo CLI** | `aeo-<os>-<arch>.tar.gz` bundles (binary + runtime tree) + `.sha256` | a host operator, via `curl … get.sh \| sh` |
| **aeo-agent** | `aeo-agent-<os>-<arch>` self-contained binaries + `.sha256` | a guest, fetched via cloud-init / ssh push |

The CLI and the agent **share one version counter and release together**. The
single source of truth for the number is the repo-root `VERSION` file. Tag = `v`
+ that number.

Authoritative source: `.github/workflows/release.yml` (+
`.github/scripts/assemble-aeo-bundle.sh` for the CLI bundles). This doc explains
it; the workflow wins on any disagreement — fix the doc to match.

> **History:** the two halves used to be separate release lines (`aeo-agent-v*`
> via `release-aeo-agent.yml`, `aeo-v*` via `release-aeo.yml`). They were unified
> into one `v*` workflow at v0.2.0; the old `aeo-agent-v0.1.x` releases remain on
> the page for historical pins but that tag line is retired.

## What gets released

One tag → one Release → **14 assets**: the 3 CLI bundles + 3 `.sha256`, and the
4 agent binaries + 4 `.sha256` — each immutable and retained forever (so a
pinned SHA in a cloud-init snippet or a CI step never breaks, and you can roll
back / bisect).

- **aeo CLI** — the operator-facing orchestrator. NOT self-contained: it reads
  `AEO_HOME` for its `lib/` tree and shells `ae` at runtime, so it ships as a
  per-platform BUNDLE (see the CLI section below), installed by `get.sh`.
- **aeo-agent** — the lean, in-guest agent a guest FETCHES to complete its node
  and run its workload. Self-contained single binaries.

### Assets (as of this writing)

| asset | guest it serves | linkage |
|---|---|---|
| `aeo-agent-linux-x86_64-static` | any Linux — full OS, debian-slim, Alpine/musl, busybox | **STATIC** (no runtime `.so` deps) |
| `aeo-agent-windows-x86_64.exe` | Windows (Win11 bhyve guests; workload via WSL2+podman) | dynamic vs Windows system DLLs (always present) |
| `aeo-agent-freebsd-x86_64` | FreeBSD (bhyve guests) | dynamic vs the base `libc.so.7` + `libthr.so.3` (always present in a FreeBSD userland) |

Each asset ships a companion `<asset>.sha256`. The run summary prints a table of
all asset SHA256s to pin.

> Historical note: pre-`v0.1.2` the linux asset was named
> `aeo-agent-linux-x86_64-glibc` (dynamic). It is now `…-static`. Some older
> docs/scripts may still reference the glibc name — treat `…-static` as current.

## How to cut a release

Set the shared number in `VERSION`, then push a matching **`v*`** tag:

```
# 1. bump VERSION (the single source of truth), commit it
echo 0.2.0 > VERSION && git add VERSION && git commit -m "release: 0.2.0"
# 2. tag v<that number> and push
git tag v0.2.0
git push origin main --tags
```

The `v*` tag runs `release.yml` and — because it's a real tag — **publishes**
one GitHub Release with all 14 assets (both CLI bundles and agent binaries).
Keep the tag number identical to `VERSION` so the bundle's self-reported version
matches the release.

### Dry run first (no publish)

`workflow_dispatch` builds + assembles + checksums every asset but does **NOT**
tag or publish — use it to test the pipeline before committing to a version:

```
gh workflow run release.yml                 # latest aether toolchain
gh workflow run release.yml -f ref=<sha>    # pin a specific aether ref
```

or the "Run workflow" button on the Actions tab. Only a pushed `v*` tag creates
an actual Release — there is never a rolling/overwritten asset.

## How the CI builds it (mechanics)

Seven build jobs feed one `release` job that publishes whatever artifacts they
produced:
- **agent** (self-contained binaries): `agent-build-linux`, `agent-build-linux-arm64`,
  `agent-build-freebsd`, `agent-build-windows`.
- **CLI** (bundles via `assemble-aeo-bundle.sh`): `cli-build-linux`,
  `cli-build-linux-arm64`, `cli-build-freebsd`.

Gated jobs (freebsd/arm64) skip cleanly on an older `ae` and simply omit their
asset (`fail_on_unmatched_files: false`), so a release ships what built.

### The runner has no prebuilt `ae` — it builds the toolchain from source

There is no downloaded `ae` binary. The "Install the Aether toolchain" step runs
`get.sh`, which fetches a pinned Aether **source tarball** and `make install`s
it. This has no chicken-and-egg because **Aether compiles to C** — the only
prerequisites are a C compiler + GNU make (hence the `build-essential` apt line).
Chain: `get.sh` → Aether source → C → `make` → `ae` on `PATH`.

The `ref` input (or the latest Aether tag by default) pins **which** Aether
version is built. That is the same version the FreeBSD gate checks (below).

### `agent-build-linux` — native, static

Native x86_64 build with `AE_CC="gcc -static"`. The job **asserts** the result
is an x86_64 ELF *and* statically linked — if not, it fails the build, because
the asset name would be a lie and a dynamic binary hits the exit-127 trap in
slim/busybox guests. This is the load-bearing asset.

### `agent-build-freebsd` — cross-compiled, self-gating

Cross-compiles on the Linux runner via `ae build --target=x86_64-freebsd` (zig
under the hood). It fetches a FreeBSD base sysroot + third-party deps from
[aether-crossbuild](https://github.com/aether-lang-org/aether-crossbuild)
(`fetch-freebsd-base.sh` + `provision.sh`; nghttp2 is intentionally omitted —
the plaintext agent doesn't need HTTP/2 and it doesn't cross-build for FreeBSD).

**The gate:** this job only produces its asset when the built `ae` is
`>= AEO_FREEBSD_MIN_AE` (currently `0.428.0`) — the first Aether version carrying
the FreeBSD-cross **pthread fix** (link `libthr.so.3` by path; `-lpthread`
doesn't resolve under zig-lld + `-nostdlib` against the split base). Below that
version the job **skips cleanly**: a tag still ships the linux asset, and the
FreeBSD asset appears on a later tag once that `ae` is released.

> If you cut a tag and the FreeBSD asset is missing, check the `agent-build-freebsd`
> "Gate" step — the toolchain is probably older than `AEO_FREEBSD_MIN_AE`. To
> test FreeBSD before that release, do a `workflow_dispatch` dry run with
> `-f ref=<aether-branch-or-sha carrying the fix>`.

## Consuming a release (guest side)

A guest fetches the asset for its OS/arch, **verifies the pinned SHA256**
(fail-closed), then runs it. Linux example:

```
curl -fsSL https://github.com/aether-lang-dev/aeo/releases/download/v0.2.0/aeo-agent-linux-x86_64-static -o /usr/local/bin/aeo-agent
echo "<SHA256-from-the-release>  /usr/local/bin/aeo-agent" | sha256sum -c -
chmod +x /usr/local/bin/aeo-agent
```

Real consumers of this pattern:
- `examples/checks/proxmox_cloudinit.yaml` — the cicustom snippet that curls +
  SHA-verifies the agent into a proxmox_vm guest.
- `examples/checks/proxmox_host_agent_install.sh` — host-side installer.
- `docs/aeo-and-proxmox.md` — the proxmox delivery narrative.

When you bump the release, update the pinned `v*` version **and** the SHA256 in
those consumers (the run summary prints the SHA to copy).

## Adding a new asset permutation (arch/OS)

The agent's targets are dictated by **where guests actually land**, not by what
`ae` can cross-compile. Add an asset only for a (guest OS, arch) that aeo
provisions *and* that the agent can function on, and keep the name honest with a
`file`-based assert (as every build job does).

- **aarch64-linux** — wanted (ARM VMs / Pi / Graviton), but `ae --target` has no
  musl triple, so a static aarch64 asset isn't reachable by cross-compile today.
  Tracked in `asks/aarch64-agent-runproof-and-static.md` (native ARM build +
  run-proof needed before wiring a job).
- **x86_64-macos** — the agent cross-builds and even runs + serves /health on
  macOS, but aeo has NO macOS-guest substrate (no mac driver; nothing provisions
  a macOS VM as a workload target). A fetchable agent for a guest type that
  doesn't exist would be dead weight. Revisit only if a macOS substrate appears.
- **windows-x86_64** — SHIPPED. The agent imports `driver_windows` and
  platform()-dispatches the workload to WSL2+podman. Note the workload path
  needs WSL2+podman IN the guest; the agent CORE (boot/contain/protocol/health)
  runs regardless, which is the same bar the FreeBSD asset ships at.

---

# The CLI half in detail (bundle + install + consume)

The cut/dry-run/tag mechanics are shared with the agent (above) — one `v*` tag,
`release.yml`, `workflow_dispatch` for a dry run. This section is only what's
specific to the CLI bundles.

## Why the CLI ships a BUNDLE, not a bare binary

The `aeo` CLI is **not self-contained** the way `aeo-agent` is. At runtime it
reads `AEO_HOME` to find `lib/` and `cp`s `$AEO_HOME/lib` into every composition
build (`bin/aeo.ae`, exits if unset), and shells `ae` to compile (the cache key
even includes `ae --version`). So a lone `aeo` binary is useless — it needs its
`lib/` tree beside it and an `ae` on PATH. Each `cli-build-*` job therefore ships
a **bundle** (via `assemble-aeo-bundle.sh`):

```
aeo-<os>-<arch>/
  bin/aeo                            the target-native CLI
  share/aeo/{bin/aeo,lib,examples,VERSION}   the runtime tree AEO_HOME points at
  install.sh                         COPY-ONLY (no make) — see below
```

`install.sh` stages `share/aeo` to `$PREFIX/share/aeo` and writes a
`$PREFIX/bin/aeo` **wrapper** that `export AEO_HOME=…; exec …` — so the installed
`aeo` needs no env var. (Same shape as how `aeb` ships `share/aeb/`.)

**The installer is COPY-ONLY — deliberately no `make`.** The bundle is already
target-native and needs no compile; running `make` would (a) require GNU make on
the target — a virginal debian-slim / bare VM has none, the exact "GNU make is
required" failure a prebuilt install exists to avoid — and (b) rebuild bin/aeo
via `ae`, clobbering the cross-built binary. So `install.sh` reproduces the copy
phase directly. (Byte-for-byte the aeb fix, aeb commit 87a30b8. Verified on a
real debian:13-slim with no make: sha256 OK, install clean, `aeo doctor` runs.)

CLI targets: `linux-x86_64`, `linux-aarch64` (gated `AEO_ARM64_MIN_AE`),
`freebsd-x86_64` (zig-cross, gated `AEO_FREEBSD_MIN_AE=0.646.0` — needs the
aether 0.646.0 FreeBSD cross-link fix). Windows/macos deferred.

## Test the bundle locally (no CI)

```sh
ae build bin/aeo.ae -o bin/aeo --lib lib
sh .github/scripts/assemble-aeo-bundle.sh linux x86_64
tar -xzf dist/aeo-linux-x86_64.tar.gz -C /tmp
sh /tmp/aeo-linux-x86_64/install.sh /tmp/aeo-prefix   # copy-only; runs make-less
env -u AEO_HOME /tmp/aeo-prefix/bin/aeo doctor        # works: the wrapper sets AEO_HOME
```

## Consuming the CLI

End users don't touch these tarballs directly — `get.sh` (repo root) does:
`curl -fsSL …/aeo/main/get.sh | sh` ensures `ae` + `aeb`, then downloads and
**sha256-verifies** the `aeo-<os>-<arch>.tar.gz` for the platform and runs its
copy-only `install.sh`. `AEO_REF=v0.2.0` (or positional `sh -s -- v0.2.0`) pins
the release. See the repo README's "Quickly trying it".
