# aeo CLI FreeBSD cross-build: `error: libc not available` (OpenSSL link)

**Status:** open. The `aeo-freebsd-x86_64` bundle does NOT build in
`release-aeo.yml`; the FreeBSD job is `continue-on-error` and omits the asset.
Linux x86_64 + aarch64 ship fine. This tracks the work to add FreeBSD.

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

## Not blocking

The two Linux bundles are the primary targets and ship today. FreeBSD-hosted aeo
(a bhyve host running the `aeo` CLI itself) is the use case this unblocks; a
FreeBSD *guest* is served by the agent (which already has a FreeBSD asset).
