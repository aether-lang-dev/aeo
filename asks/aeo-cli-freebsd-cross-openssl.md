# aeo CLI FreeBSD cross-build: `error: libc not available`

**Status:** FIXED UPSTREAM (aether 0.646.0), pending a green-run confirmation +
flipping this repo's job load-bearing. Linux x86_64 + aarch64 ship regardless.

## Resolution (2026-09-07)

Fixed in **aether 0.646.0** via **PR #1930** ("FreeBSD tier-2 cross-link under
Zig 0.16 — link staged libs by path, only when used"), plus a **Zig 0.13 -> 0.16**
bump across aether-crossbuild (`deps.lock`) and this repo's release workflows
(commit `4d8572a`).

**Root cause was NOT OpenSSL-specific** — the correction to the diagnosis below.
The sibling reproduced on the real crossbuild kit that *a program importing only
`std.io` fails identically*. The trigger was a **Zig version mismatch**:
`tools/ae_cross.c`'s FreeBSD/tier-2 wiring is written for Zig 0.16, but the kit
pinned Zig 0.13, which can't resolve the base libc/CRT from `--sysroot` for a
FreeBSD target -> `libc not available`. The 0.16 bump then exposed two tier-2
link bugs 0.13 had masked, also fixed in #1930: (1) over-linking staged-but-
unused libs (0.16 hard-errors on a dangling `-l`), now gated on the program's
import closure; (2) `-L$SYSROOT/lib` mangled under `--sysroot`, now linked by
absolute archive path.

The crypto correlation I first saw (agent green, CLI red) was real but
MISLEADING — the CLI just happened to be the first freebsd-cross target built
after the kit landed. My original ask flagged exactly this risk ("if the minimal
repro passes, the trigger is more specific than 'imports crypto'"); it went the
other way (an even simpler program also failed), which is what let the sibling
locate the Zig mismatch fast. Lesson kept: the hedge earned its place.

**Remaining aeo-side step:** once v0.646.0 is a published release and a
`release-aeo.yml` dry run produces a green `aeo-freebsd-x86_64` bundle, drop
`continue-on-error` on build-freebsd (gate already raised to 0.646.0) to make it
load-bearing.

---

Original diagnosis (kept for the record — the correlation was right, the
mechanism was corrected above):

## Symptom

`build-freebsd` in `.github/workflows/release-aeo.yml`, at the
`ae build bin/aeo.ae … --target=x86_64-freebsd` step:

```
ld.lld: warning: cannot find entry symbol _start; not setting start address
error: libc not available
    note: run 'zig libc -h' to learn about libc installations
Error: cross-linking for x86_64-freebsd.15.0 failed.
```

Type-checking + codegen succeed; only the **link** fails.

## Root cause (diagnosed, not guessed)

It is NOT a heavier dep closure (the AGENT imports far more — all drivers,
std.http, std.net — and its FreeBSD job builds green). The single relevant delta:

- `bin/aeo.ae` → `import secrets` → `lib/secrets/module.ae:48`
  `import std.cryptography (hmac_sha256_hex, random_hex)`.
- `std.cryptography` links **OpenSSL** (its module notes it returns
  `"openssl unavailable"` when libcrypto is absent; the `cryptography_*_raw`
  externs are libcrypto/libssl).
- `bin/aeo-agent.ae` does **not** import `secrets` or `std.cryptography` — so the
  agent's FreeBSD cross-link never pulls libcrypto, and succeeds.

So the aeo CLI is the first FreeBSD-cross target that needs OpenSSL, and the
crypto link doesn't resolve against the split FreeBSD base sysroot under
zig-lld — surfacing as the generic `libc not available` (zig fell back to its own
libc resolution, which has no FreeBSD static libc, instead of using the provided
base).

## Where the work is

1. **aether-crossbuild sysroot / provision** — the FreeBSD job runs
   `CB_LIBS="zlib pcre2 openssl" ./provision.sh x86_64-freebsd15` (from
   `github.com/aether-lang-dev/aether-crossbuild`). openssl IS in CB_LIBS, so the
   libs are built — the question is whether `std.cryptography`'s link flags find
   them AND the base libc/CRT in the same link. Likely fixes, in order of
   likelihood:
   - the `AETHER_SYSROOT` (base: libc.so.7 + libthr.so.3 + CRT) and
     `CROSSBUILD_SYSROOT` (third-party: openssl) must BOTH reach the crypto link;
     confirm ae's `--target` link threads `CROSSBUILD_SYSROOT` for `-lcrypto`
     the way it threads the base for libc. The `libc not available` suggests the
     base sysroot wiring is dropped when the crypto libs enter the link.
   - a `std.cryptography` FreeBSD-cross link fix in the **aether** toolchain
     (analogous to the libthr-by-path fix the agent's job gates on at
     `AEO_FREEBSD_MIN_AE=0.428.0`): link libcrypto/libssl BY PATH from
     `$CROSSBUILD_SYSROOT` rather than `-lcrypto` under `-nostdlib`.

2. **release-aeo.yml build-freebsd** — once the toolchain/sysroot builds it:
   - bump the gate `AEO_FREEBSD_MIN_AE` to the ae version carrying the fix;
   - drop `continue-on-error: true` and the `built=true`-gating on assemble/
     upload (make FreeBSD load-bearing again — see the TODO comment there).

## How to reproduce / verify a fix

Locally on a Linux box with the crossbuild kit (mirrors the CI job):

```sh
git clone --depth 1 https://github.com/aether-lang-dev/aether-crossbuild ~/aether-crossbuild
cd ~/aether-crossbuild && ./scripts/get-zig.sh && ./scripts/fetch-freebsd-base.sh x86_64 15
CB_LIBS="zlib pcre2 openssl" ./provision.sh x86_64-freebsd15
export AETHER_SYSROOT=~/aether-crossbuild/bases/x86_64-freebsd15
export CROSSBUILD_SYSROOT=~/aether-crossbuild/sysroots/x86_64-freebsd15
export PATH=~/aether-crossbuild/toolchain/zig-linux-x86_64-0.13.0:$PATH
cd ~/scm/aeo && ae build bin/aeo.ae -o /tmp/aeo-fbsd --lib lib --target=x86_64-freebsd
file /tmp/aeo-fbsd   # want: ELF 64-bit x86-64, FreeBSD
```

A minimal repro that isolates the OpenSSL link (no aeo needed): any `.ae` that
`import std.cryptography` and calls `hmac_sha256_hex`, cross-built to
`x86_64-freebsd`. If THAT fails identically, the fix belongs in aether/crossbuild,
not aeo.

## Upstream ask

The actual fix is in the aether toolchain / crossbuild, tracked there:
`aether/asks/freebsd-cross-openssl-libc-not-available.md`. That ask carries the
confirmed source sites (`compiler/codegen/codegen.c:4235` maps std.cryptography
-> `-lssl -lcrypto`; `tools/ae_cross.c:~835-895` is the crossbuild openssl
probe/link path) and the minimal no-aeo repro. This aeo-side file is just the
consumer view + the two-line follow-up once it lands.

## Not blocking

The two Linux bundles are the primary targets and ship today. FreeBSD-hosted aeo
(a bhyve host running the `aeo` CLI itself) is the use case this unblocks; a
FreeBSD *guest* is served by the agent (which already has a FreeBSD asset).
