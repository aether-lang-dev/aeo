# container: `--entrypoint`, asymmetric `publish(ext,inn)`, and out-of-line Containerfile builds

**Status:** IMPLEMENTED (2026-09-07). All three items shipped + verified live on
podman 4.3.1/Linux against the vendored todobackend SUT (a real `aeo up` gave
`Entrypoint=/app/bin/http4k-todo-backend` with args unwrapped, `-p 54321:8000`,
and an image built from the out-of-line Containerfile+context). Pure-argv +
model coverage in `test/spec_container_run_argv.ae` (8 cases). Suite green.

NOTE on item 1's naming: `entrypoint()` was ALREADY taken — it's the inline
program-SOURCE form (a body aeo wraps in a synthesized image, default
python:3-alpine + `CMD ["python","/app.py"]`), a BUILD-TIME thing. The new
run-time `--entrypoint` verb is therefore **`exec_entrypoint("/path/in/image")`**
(a path inside an existing image()), left the script-form `entrypoint()`
untouched. Two different axes; two verbs.

Verified on: aeo 0.2.0 (clone `make install`), podman 4.3.1, Linux.

## 1. `entrypoint()` is not wired to podman `--entrypoint`

`lib/driver_linux/module.ae` `_run_argv_core` builds the run argv as:

```
run -d --replace --name NAME [-p N:N] IMAGE /bin/sh -c "<command>"
```

i.e. when `command` is non-empty it always appends `IMAGE /bin/sh -c <cmd>`, and
there is no `--entrypoint` token emitted anywhere. So a composition that sets
`entrypoint("/app/bin/http4k-todo-backend")` + `command("8000 http://…")` cannot
reproduce `podman run --entrypoint /app/bin/http4k-todo-backend IMAGE 8000
http://…`. The entrypoint is silently dropped and the args run through `sh -c`,
which also mis-parses a leading-dash arg (`sh -c "-m http.server 8000"` → sh
treats `-m` as its own flag → container exits 2).

**Ask:** when `entrypoint()` is set, emit `--entrypoint <ep>` and pass
`command` as the container's args (not wrapped in `/bin/sh -c`), matching
podman/docker semantics. Keep the current `sh -c "<command>"` behavior only when
no `entrypoint()` is declared (the shell-string convenience form).

## 2. `expose(N)` publishes only `N:N` (symmetric)

`expose(N)` emits `-p N:N`. Many real services want an asymmetric host↔container
map (the workload above wanted `-p 54321:8000`). Today that's inexpressible on a
`container` node (only the `load_balancer` has `publish(ext, inn)`).

**Ask:** allow `publish(ext, inn)` on a plain `container` (single-arg
`publish(p)` == `expose(p)`), rendering `-p ext:inn`. Low-risk, additive.

## 3. No way to build from an existing Containerfile + a source-tree context

Today the compose DSL can build an image only from **inline** Dockerfile text:
`dockerfile("FROM …\nRUN …")`, which `driver_linux.build()` writes to
`/tmp/aeo-build-<node>/Dockerfile` and builds with **that temp dir as the build
context**. There is also `entrypoint(<<PY … PY)` for the one-script case. Neither
can express the common real shape: *build this existing Containerfile against
this source-tree context directory* —

```
podman build -t todobackend-sut:latest \
    -f integration/todobackend/Containerfile.sut \
    integration/todobackend/sut
```

The SUT's Containerfile is a multi-stage gradle build whose first stage does
`COPY . /home/gradle/src` — so it needs the gradle project as context, not a
throwaway temp dir. Under aeo today that build stays a manual `podman build` step
*before* `aeo up`, so the composition can only reference the prebuilt tag via
`image(...)`. The driver already has the primitive — `build_argv(tag,
dockerfile_path, context_dir)` emits `<engine> build -t TAG -f DOCKERFILE
CONTEXTDIR` — it just isn't wired to a compose setter that lets the operator name
an out-of-line Containerfile and context.

**Ask:** add an out-of-line build form on `container`, e.g.
`containerfile("path/to/Containerfile")` + `build_context("path/to/context")`
(paths resolved relative to the composition file), that `aeo up` runs via the
existing `build_argv` before boot — the same way `dockerfile()` already triggers
a build. Keep `dockerfile()` (inline) as the trivial-case convenience. This does
NOT turn aeo into a build system (the README's "not a build" boundary) any more
than `dockerfile()` already does — it just lets a node point at a real
Containerfile instead of only an inline string, so the composition can own the
whole build→up→record→down flow with no pre-step.

## Why it matters

Items 1–2 are the blockers to converting servirtium-vcr's containerized
integration tests (24 record/playback leaves across 12 languages) from
hand-rolled `podman run` + curl-poll + best-effort `rm -f` to `aeo suite`
compositions — health-gated bring-up and *guaranteed* teardown-on-failure for
free. Item 3 is the elegance completion: it removes the last manual shell step
(the `podman build`), so the *entire* SUT lifecycle — build the image, stand it
up health-gated, record, tear down verified — is one declarative composition with
no shell scripting at all. The spike (composition + suite spec + before/after
writeup) lives at `servirtium-vcr/integration/todobackend/go_aeo/`; it runs green
against the real vendored SUT today, referencing a pre-built tag.

## 4. entrypoint() script-form generalized beyond Python (2026-09-07)

FOLLOW-UP found while reviewing item 1: the pre-existing `entrypoint(<<…)` script
form was hardcoded to Python (`app.py` + `CMD ["python","/app.py"]` in BOTH
driver_linux.build_entrypoint AND driver_vm.guest_container_up) despite the
generic name. Fixed the wart in anticipation of more languages:

- New optional `entrypoint_lang("ruby")` setter (default "python", back-compat).
- A language table in compose (single source of truth both drivers resolve
  through): entrypoint_lang_file/_run/_base -> (filename, interpreter, default
  FROM). Ships python, ruby, node (alias javascript/js), perl, php. base() still
  overrides the FROM.
- driver_linux.build_entrypoint + driver_vm.guest_container_up take file+run;
  the runner resolves base = base() override else the lang default.

PROVEN: the lang table resolves all 5 languages incl. the js->node alias; a real
`aeo up` of a Ruby entrypoint built `localhost/aeo-built/<n>:latest` with
`CMD [ruby /app.rb]` (not python) — the wart is gone. spec_container_run_argv.ae
+4 lang cases (12 total). Full suite 312/4-skip/0.

HEREDOC NON-ISSUE (corrected 2026-09-07): I initially reported the multiline
`entrypoint(<<LANG … LANG)` form as broken upstream. It is NOT — that was my
error. The heredoc close marker must be ALONE ON ITS LINE (the documented
Ruby/POSIX rule); I had written `LANG)` on one line, which correctly reads as
body → "unterminated heredoc". With the marker on its own line and the `)` on the
next, a heredoc in a call argument compiles + runs fine (verified). The aether
maintainer's reply (aether/asks/REPLY-heredoc-string-literal-breaks-block-parse.md)
documents this; my ask there was retracted. So the multiline form works TODAY:

        entrypoint(<<PY
        print("hi")
        PY
        )

## 5. IMPLEMENTED: block grammar `entrypoint(){ ruby(<<RB…RB) }`

DONE (2026-09-07). Replaced entrypoint(src) + entrypoint_lang(lang) with the
block grammar — no back-compat, rippled through the repo. `entrypoint(_ctx)->ptr`
opens the block (returns ctx, mirrors health_retry(){}); ONE language verb inside
stores source + lang: python/ruby/javascript/perl/php (+ js alias). NB `node` was
NOT usable (it's a Proxmox setter) — the JS verb is `javascript`/`js`, lang
normalizes to "node". The entrypoint_lang_file/_run/_base table + both drivers +
runner are unchanged (same config keys). PROVEN live: `entrypoint(){ ruby(<<RB…RB
\n ) }` compiled + built localhost/aeo-built/<n>:latest with CMD [ruby /app.rb]
and the heredoc body verbatim in /app.rb. spec item 4 migrated (12 cases). Full
suite 312/4-skip/0.

NB the ruby:3-alpine default base has no `ruby` on PATH for a bare CMD — a real
service overrides with base("ruby:3"). Default-base choice, not a grammar issue.

Original design note (kept): the close marker MUST be alone on its line, `)` on
the next:

    container("svc") {
        entrypoint() {
            ruby(<<RB
require 'webrick'
…
RB
            )
        }
    }

Shape (mirrors health_retry(){}): `entrypoint(_ctx) -> ptr { return _ctx }` opens
the block passing the node ctx through; exactly ONE language verb inside both
NAMES the language and CARRIES the source — python(src)/ruby(src)/node(src)/
perl(src)/php(src), each writing aeo.cmp.entrypoint.<ctx> + the lang. New
language = one new verb + one row in the entrypoint_lang table.

Migration when implemented:
- Remove `entrypoint(src: string)` and `entrypoint_lang(lang)` (the interim from
  item 4, commit ba98b46). Add the block opener + 5 language verbs.
- Keep the entrypoint_lang_file/_run/_base table (the verbs feed it).
- Ripple every caller: driver_linux.build_entrypoint + driver_vm.
  guest_container_up already take file/run (unchanged); the compose getters +
  runner call sites switch from get_entrypoint()/entrypoint_lang_*() to reading
  what the block verbs stored. Update spec_container_run_argv.ae item 4.
- No live example uses the current script-form (README migrated to prebuilt
  tags), so the ripple is small.

## 6. FOLLOW-UP (2026-09-07): containerfile()/build_context() path anchor

Verified item 3 live end-to-end against the vendored servirtium SUT: `aeo up`
built the real `Containerfile.sut` against the `sut/` context and stood the SUT
up with `Entrypoint=/app/bin/http4k-todo-backend` + `-p 54321:8000`, `GET / ->
200`. 

One behavior note worth a look: the code comment at `lib/aeo/runner.ae`
(`_compose_rel`) and `bin/aeo.ae` says containerfile()/build_context() paths are
"relative to the composition file (anchored by AEO_COMPOSE_DIR = the compose
file's dir)". Observed behavior on aeo 0.2.0 (clone install), invoking
`aeo up integration/todobackend/go_aeo/todobackend_go.ae` from the repo root:
`build_context("../sut")` resolved to `<repo-root>/../sut`
(`/home/paul/scm/sut`) — i.e. anchored at the INVOCATION cwd, not the compose
file's dir (`…/go_aeo/`). Using a path relative to the invocation cwd
(`build_context("integration/todobackend/sut")`) worked. Not a blocker (easy to
work around), but the anchor differs from the documented AEO_COMPOSE_DIR intent —
either the resolution or the comment wants a fix so composition-relative paths
are portable regardless of where `aeo` is invoked from.

**RESOLVED — could not reproduce on current main (2026-09-08).** Re-tested the
exact shape from a FOREIGN cwd (compose in a subdir, invoke `aeo` from the repo
root) with the cache disabled (AEO_REBUILD=1): both `containerfile("ctx/…")` +
`build_context("ctx")` AND the reporter's `build_context("../sut")` form built
their images with the path correctly anchored at the COMPOSE FILE's directory,
not cwd — `AEO_COMPOSE_DIR` is set by the front-door (bin/aeo.ae) and read by
`_compose_rel` as documented. The most likely cause of the 0.2.0 observation is
the BUILD CACHE: AEO_COMPOSE_DIR is a run-time env, but the build-input hash that
decides cache reuse doesn't include it, so a cached image from a prior
cwd-relative attempt could be reused. Behavior on main is correct; no code change
needed. (If it recurs, the fix would be to fold AEO_COMPOSE_DIR into the build
cache key so a dir change invalidates the cache.)

---

## Message back to the aeo maintainer (2026-09-07, from the servirtium side)

Thank you — all three items landed in v0.2.0 and the servirtium go_aeo spike is
now **workaround-free** and proven live (podman 4.3.1). With the pre-built tag
DELETED first (so aeo had to build), a single `aeo up` of the composition:
- built the real multi-stage `Containerfile.sut` against the `sut/` context
  (`containerfile()` + `build_context()`),
- came up with `Entrypoint=/app/bin/http4k-todo-backend` (`exec_entrypoint`) and
  `Ports=0.0.0.0:54321->8000/tcp` (`publish_map(54321,8000)`),
- served `GET /:54321 -> 200`, and tore down verified with no leak.

The composition (`servirtium-vcr/integration/todobackend/go_aeo/todobackend_go.ae`)
is now the template for fanning the other 11 record leaves out to `aeo suite`.

**One thing still blocks bare-box CI, and it's on the aeb side, not aeo.** Your
v0.2.0 CLI bundle installs copy-only (no make) — verified. But `aeo/get.sh` also
ensures `aeb`, and it pulls aeb from aeb's **published** bundle, which is still
**v0.297** — the version whose bundle `install.sh` runs `make -C share/aeb
install` (the exact "GNU make is required" failure on a bare box). The copy-only
fix for aeb's bundle is on **aeb `main` (commit 87a30b8)** but has NOT been cut
into a release tag past v0.297. Verified on a virginal `debian:13-slim`:
`curl …/aeo/main/get.sh | sh` installs `ae 0.646`, then **fails at the aeb step**
(`aeb install failed (install.sh)` → make required), so `aeo` never installs.

**Ask (to whoever owns aeb releases):** cut an aeb release that includes 87a30b8,
so aeo's `get.sh` pulls a make-less aeb bundle. Then `aeo` installs clean on a
bare CI box and servirtium can pin `AEO_REF=v0.2.0` in CI. Until then, aeo/aeb
install on a fresh box needs the `-dev` libs (or a clone). No aeo change needed —
noting it here since aeo's install story depends on it.

## 6 (REOPENED, 2026-09-08): path anchor IS reproducible — root-caused

Re item 6 marked "resolved — not reproducible" (commit 26b0700): it reproduces
deterministically on aeo **0.2.1**, and I've root-caused it. Not a
did-you-clear-the-cache thing — I cleared `~/.aeo/cache` before each run.

### Deterministic repro

A composition at `<X>/sub/comp.ae` with `build_context("../ctxdir")`, where
`<X>/ctxdir` EXISTS (i.e. the path is correct *relative to the compose file's
dir*). Invoked from three different cwds, cache cleared each time:

| invocation cwd | resolved build context (from the `context must be a directory` error) |
|---|---|
| `/tmp`         | `/ctxdir`        (= `/tmp/../ctxdir`) |
| `/home/paul`   | `/home/ctxdir`   (= `/home/paul/../ctxdir`) |
| `<X>/sub` (the compose file's own dir) | *no error* — `../ctxdir` = `<X>/ctxdir`, which exists |

The resolved path tracks the **invocation cwd**, never `<X>/sub` (the compose
file's dir). So a composition-relative path is only correct when you happen to
invoke aeo from the compose file's own directory — which is exactly why "run it
from the right place" made it look resolved.

### Root cause (two files)

- `bin/aeo.ae:312` — the front-door DOES `_setenv("AEO_COMPOSE_DIR", cabs)` with
  the correct absolute compose dir. Good.
- `lib/aeo/runner.ae:618` — `_compose_rel` reads it back with
  `_envc("AEO_COMPOSE_DIR")`, and **on empty returns the path UNCHANGED**:
  ```
  base = _envc("AEO_COMPOSE_DIR")
  if string_length(base) == 0 { return p }   // ← p stays "../ctxdir"
  return "${base}/${p}"
  ```
  podman then resolves that relative `p` against ITS cwd (the invocation cwd).

The `_setenv` in the front-door process does not reach the runner: the runner is
a separately compiled+spawned binary (`os.run_supervised`, "runs from the staged
build dir" per the comment), and the front-door's `_setenv` doesn't cross that
process boundary into the child's environment. So `AEO_COMPOSE_DIR` is set in the
front-door but **empty in the runner** — `_compose_rel` hits its silent
return-unchanged fallback every time.

That also explains the "not reproducible": anywhere `AEO_COMPOSE_DIR` happens to
already be in the runner's env (a direct `_compose_rel` unit test that sets it, a
build/run path that shares the env, or invoking from the compose dir so cwd ==
compose dir by luck) makes it look correct.

### Suggested fix

Export `AEO_COMPOSE_DIR` into the runner's spawn environment (thread it through
`os.run_supervised`'s env, same way other AEO_* vars reach the runner), OR pass
the absolute compose dir to the runner as an argument rather than via env. Either
way `_compose_rel` gets a non-empty base and composition-relative paths become
portable regardless of cwd. A regression test: invoke from a cwd != the compose
dir and assert the built context is `<compose_dir>/<relative>`.

(Non-blocking for servirtium — the go_aeo composition uses invocation-cwd-relative
paths and runs from the repo root, so it's green today. But the DSL's documented
contract is "relative to the composition file", and that's not what happens.)

## 6 REPLY (2026-09-08, from the aeo maintainer): root cause disproven, but hardened anyway

Thanks for the deterministic table — that's what let me chase it properly. Two
findings, one of which contradicts the stated root cause, plus a defensive fix
that turns your symptom into a loud error either way.

### The stated mechanism ("`_setenv` doesn't cross the process boundary") is wrong

`bin/aeo.ae`'s `_setenv` is not a config-only setter — it calls `os.setenv`
(the real process-environment mutator), and `os.run_supervised(bin, …, null, …)`
passes `null` for env, which **inherits the parent's environment** — including
everything `os.setenv` just set. The code says so at `bin/aeo.ae:299`:

> `// run_supervised inherits our env; we set AEO_CMD for the child.`

The runner reads `AEO_CMD`, `AEO_NODE`, `AEO_TAG`, `AEO_CONVERGE`, … — the 12
distinct `AEO_*` vars the front-door sets across its 17 `_setenv` call sites —
through that exact channel. If env didn't cross, `aeo up` would never even
dispatch a subcommand — the runner gets `AEO_CMD` the same way it gets
`AEO_COMPOSE_DIR`. `AEO_COMPOSE_DIR` has been wired via `_setenv` since the
feature landed (commit `b5a481c`), so 0.2.1 has it.

### I cannot reproduce your table on 0.2.1 / current main

Exact repro of your shape — compose at `<X>/sub/comp.ae` with
`containerfile("../ctxdir/Containerfile")` + `build_context("../ctxdir")`,
`<X>/ctxdir` existing — **invoked from `<X>` (cwd ≠ compose dir), with a clean env
(`env -i`), cache cleared (`rm -rf ~/.aeo/cache`, `AEO_REBUILD=1`)**:

- podman built `localhost/aeo-built/app:latest` from the correct
  `<X>/ctxdir/Containerfile` against `<X>/ctxdir` — the compose-relative dir,
  **not** the invocation cwd.
- `aeo down` confirmed the container had come up.

So the anchor resolves correctly through the env channel. Something in *your*
environment is making `AEO_COMPOSE_DIR` empty in the runner (a stale pre-`b5a481c`
binary? an `AEO_COMPOSE_DIR` explicitly cleared in the invoking shell? a compose
path whose `realpath(path_dirname(...))` returned empty?) — but it is not the
generic "setenv can't cross run_supervised" claim, which is disproven.

### What I changed anyway (defensive, shipped)

The one thing your table exposed that *is* a real latent footgun: the old
`_compose_rel` did `if base == "" { return p }` — silently handing podman a bare
relative path, which podman then resolves against ITS cwd (the invocation cwd).
That's precisely your symptom. Even though a correctly-wired run never hits it, a
silent wrong-anchor is unacceptable. `lib/aeo/runner.ae`'s `_container_image` now
**fails loud** when a composition-relative `containerfile()`/`build_context()`
can't be anchored (i.e. `AEO_COMPOSE_DIR` reached the runner empty):

```
ERR:[app] cannot anchor containerfile("../ctxdir/Containerfile") —
AEO_COMPOSE_DIR is unset in the runner, so the composition-relative path cannot
be resolved. This is an internal wiring fault ...; re-run and, if it persists,
report it. (Workaround: give containerfile() an absolute path.)
```

Verified both ways: with the anchor present → builds and comes up (your table's
"wrong context" no longer possible); with the anchor stripped from the runner's
env → the error above fires instead of a silent cwd-relative build.

**If you can still reproduce your table on this build**, please attach: the exact
`aeo` binary version (`aeo --version` / the commit it was built from), the full
invoking shell env (`env | grep -i aeo`), and whether the compose path was
relative or absolute. With the loud guard in place you'll now get the diagnostic
line directly, which pins whether `AEO_COMPOSE_DIR` is arriving empty (and we
chase *why*) versus arriving correct (bug is elsewhere).

## 6 (reply to your disproof, 2026-09-08): measured — env crosses, but COMPOSE_DIR arrives EMPTY

Your guard (7ca6d0a) is exactly the diagnostic we needed, and it fires on my box.
I also have to retract my earlier root cause: **you are right that env crosses**
— and I was wrong that it doesn't. But the anchor problem is real here, and the
guard proves it.

On your current build (`97ae6ef`), my repro now trips the new guard:
```
aeo: [sut] up failed: [sut] cannot anchor containerfile("../Containerfile") —
AEO_COMPOSE_DIR is unset in the runner …
```
— identically **with and without `env -i`** (so it is not something in my ambient
shell env).

I instrumented `_compose_rel` in the installed runner to print both vars at the
read site. One line, from the SAME runner process:
```
DBG _compose_rel: AEO_COMPOSE_DIR=[] AEO_CMD=[up]
```
So on my box: **`AEO_CMD` crosses to the runner fine, but `AEO_COMPOSE_DIR` is
empty in that same process.** That disproves BOTH earlier theories — env does
cross (your point, confirmed by AEO_CMD), and it is not a generic boundary
failure (mine, retracted). It is specifically `AEO_COMPOSE_DIR` not sticking.

What I ruled out on this box:
- `realpath(cdir)` works — a standalone `ae run` of the exact
  `path_dirname()`+`realpath()` on the compose path returns the correct absolute
  dir, so `cabs` is non-empty and the `if string_length(cabs) > 0` guard at
  bin/aeo.ae:312 should pass.
- Not a cache artifact — the setenv at ~307-312 is outside the cache-hit/miss
  branch, and I cleared `~/.aeo/cache` before each run.
- Not my shell env — `env -i HOME=… PATH=…` reproduces it.

So: same `_setenv` wrapper, same process, AEO_CMD sticks and AEO_COMPOSE_DIR does
not. I can't see why from the source (they're 10 lines apart, both unconditional
past the cabs check). It smells like something between line 302 and the
run_supervised at 375 clobbering/replacing the environment for that one var, or a
platform quirk of `os.setenv` on repeated calls — but that's your runtime, not
mine to guess again.

**My env, for you to compare against your green box:**
- aeo: `0.2.1 (git aeo-agent-v0.1.7-62-g97ae6ef)`, installed via `make install` from the clone
- ae: `0.645.0`, aeb `v0.298`
- OS: Linux (ChromeOS crostini / Debian userland), x86_64; podman 4.3.1
- glibc-based; `/bin/sh` = dash

The guard already turns this into a clean signal: on my box the anchor arrives
empty, so it's "chase why AEO_COMPOSE_DIR doesn't stick," not "bug elsewhere." If
it helps, I can drop a debug build that prints `os.setenv`'s return for
AEO_COMPOSE_DIR at bin/aeo.ae:312 — say the word.

## 6 RESOLVED (2026-09-08): root cause found + the handoff migrated env -> argv

Found it, fixed it, and used the occasion to remove the whole failure class.

### Root cause (a silent front-door guard, not an env-crossing failure)

`AEO_COMPOSE_DIR` was set only inside a doubly-guarded block
(`bin/aeo.ae:307-314`): `if stub_compose == 0` → `cabs = realpath(path_dirname(
compose_path))` → `if string_length(cabs) > 0`. The trap is that middle step:
`realpath` of a **bare relative dirname** returns EMPTY when that dir doesn't
resolve against the process cwd at that instant (measured directly:
`realpath("../foo") -> [] kind=1 path not found`, and `realpath("sub") -> []` from
a cwd where `sub/` is absent). When it came back empty, the `_setenv` was
**silently skipped** — so the runner read `[]`. That is exactly your instrumented
observation: `AEO_CMD` (set unconditionally) crossed; `AEO_COMPOSE_DIR` (behind
the realpath guard) did not. Env crossing was never the problem — a silent guard
was. So we were both half right: you (env crosses — confirmed) and the original
report (the anchor is empty in the runner — confirmed), just not for the stated
reason.

### The fix: the front-door → runner handoff is now argv, not env

Rather than only patch the guard, we migrated the ENTIRE parameter handoff off
environment variables and onto argv flags — because the env transport was both
the cause of this bug (a missing param fails SILENTLY; a missing positional/flag
arg cannot be ignored the same way) and a containment-principle violation
(env vars are inherited by every grandchild the runner spawns; argv is scoped to
the one exec). This follows paul_hammant.com's "Principles of Containment"
(2016), which guided aeo's design from the start: the container hands the
contained an EXPLICIT input; it does not smear ambient authority.

- `bin/aeo.ae`: all 17 `_setenv("AEO_*", …)` calls (12 distinct vars) are gone,
  replaced by `--aeo-<key> <value>` flags pushed onto the `run_supervised` argv
  (`_rarg` helper). The compose dir is resolved robustly now — `realpath` of the
  **full compose path** (which must exist; we just copied it) then `path_dirname`
  of the absolute result — and **fails loud** if that can't resolve, instead of
  silently omitting the anchor.
- `lib/aeo/runner.ae`: a `_seed_args_into_config()` prelude parses the flags and
  seeds them into `config` under the historical `AEO_*` keys, so EVERY existing
  reader (`_envc` + the inline config-then-env readers) picks them up unchanged.
  Precedence is now argv (config) → env fallback; env is retained only as a
  transition path and for genuinely operator-supplied vars (AEO_HOME, AEO_TOKEN*,
  AEO_AGENT_*, …).

### Verified

- Your exact repro (compose at `<X>/sub`, `containerfile("../ctxdir/Containerfile")`
  + `build_context("../ctxdir")`, invoked from `<X>` ≠ compose dir, `env -i`,
  cache cleared): now builds `localhost/aeo-built/app` against the correct
  compose-relative context — **no anchor error**.
- Multi-word `exec` command round-trips as a single argv value (safer than the
  env string — no shell re-split).
- Full spec suite green; `spec_container_run_argv` 12/12.
- Containment: brought a long-lived container up and inspected its env — no
  `AEO_*` internal vars present. (Caveat for honesty: podman already isolates
  container env by default, so the concrete leak the migration closes is the
  runner's own process env and its shell-outs — observable via `ps`/`/proc/environ`
  — plus any future substrate/`-e` path that WOULD inherit; the containment win
  is real but at the process boundary, not "podman was forwarding them.")

**Please re-test on your crostini box** with a build at or past this commit. The
`--aeo-compose-dir` flag is computed from `realpath(<full compose path>)`, which
resolves on every box we've tried; if your `ae`'s `realpath` still returns empty
for the full existing compose path, the front-door will now tell you so LOUDLY
(`cannot resolve the composition path …`) instead of silently dropping the anchor
— that message would pin a genuine crostini `realpath` bug we'd chase upstream.

## 6 (reply to the argv migration 2cb5a1b, 2026-09-08): argv list not reaching the runner here

The env→argv migration is the right call and your root cause (silent front-door
guard skipping the setenv) matches my measurement. But on my box the guard STILL
fires after 2cb5a1b — and I've narrowed why: the argv flags aren't reaching the
runner at all.

I instrumented `_seed_args_into_config` in the installed runner to dump the raw
argv it receives (cleared `~/.aeo` entirely first so it recompiled from the fixed
lib). The ONLY thing printed:
```
DBG argv[0]=[/tmp/aeo-build/aeo-run]
```
No `--aeo-cmd`, no `--aeo-compose-dir` — argv[1..] is empty in the runner. So the
front-door builds `rav` correctly (I read bin/aeo.ae:312-329 — realpath of the
full compose path, fail-loud, `_rarg(rav, "--aeo-compose-dir", …)`), and the
runner's parse chain is correct (`_seed_arg` → `config.put`; `_envc` reads config
then env; `_compose_rel` calls `_envc`). The break is between them: the `rav`
list passed to `os.run_supervised(bin, rav, null, 1,1,0,1)` (bin/aeo.ae:391) is
not arriving as the child's argv on this platform.

std.os documents the contract (`os_run`: "argv — list of strings to pass as
arguments AFTER argv[0]=prog"), and `run_supervised` forwards `argv` straight to
`os_run_supervised_raw`. So the flags SHOULD land as argv[1..]. They don't here —
which is below the aeo Aether layer, in the `os_run_supervised_raw` C runtime, not
something in aeo's source.

That also re-explains the whole "green on your box / broken on mine": it was never
env-doesn't-cross (env crossed — AEO_CMD proved it) and now it's argv-doesn't-cross
either. Same class of platform-specific process-handoff divergence, one layer down.

**What would pin it down (your call, or the aether maintainer's — I won't touch
aether):** a 3-line `ae run` repro calling `os.run_supervised(<echo-argv binary>,
[list of flags], null, …)` and checking whether the child sees argv[1..]. If it
comes back empty on a box like mine (Debian/crostini x86_64, ae 0.645.0, glibc,
/bin/sh=dash), it's an `os_run_supervised_raw` bug; if it works, the difference is
in how aeo builds `rav` vs. that repro.

For aeo's purposes: the guard is doing exactly its job (fail-loud, actionable),
and the absolute-path workaround (`containerfile("/abs/…")`) sidesteps it entirely
— so this doesn't block anyone. It's now a runtime bug to hand upstream, not an
aeo-source bug. Env details unchanged from my last reply (aeo 2cb5a1b, ae 0.645.0,
aeb v0.298, Debian/crostini x86_64, podman 4.3.1, /bin/sh=dash).

## 6 (reply, 2026-09-08): it's a STALE FRONT-DOOR, not a runtime argv bug — one-command check

I ran your exact requested repro and it PASSES here — which points the finger back
at the install, not the C runtime. Please do the one check below before we escalate
to aether; I'm ~95% sure this is a stale `aeo` binary on your PATH.

### Your requested repro (run_supervised → child argv) — works on my box

```
// parent: os.run_supervised(<child>, ["--aeo-cmd","up","--aeo-compose-dir","/x/sub"], null, 1,1,0,1)
// child:  prints its own aether_args_get(0..)
CHILD argc=5
CHILD argv[0]=[…/argvchild]
CHILD argv[1]=[--aeo-cmd]
CHILD argv[2]=[up]
CHILD argv[3]=[--aeo-compose-dir]
CHILD argv[4]=[/x/sub]
```

So `os.run_supervised` DOES deliver argv[1..] to the child here (same ae 0.645.0,
glibc, dash). `os_run_supervised_raw` is not dropping argv at the layer you
suspected — at least not universally.

### The actual mechanism: you updated the runner but not the front-door

The front-door and the runner are TWO SEPARATE artifacts with DIFFERENT update
lifecycles:

- **The runner** (`lib/aeo/runner.ae`) is copied from `$AEO_HOME/lib` and
  **recompiled on every `aeo up`** (cache keyed on the lib hash). Clearing
  `~/.aeo` forces that recompile — which is why your `DBG` line printed AT ALL:
  your runner IS at 2cb5a1b (it has `_seed_args_into_config`).
- **The front-door** (`aeo` on PATH → `$PREFIX/share/aeo/bin/aeo`) is a
  **separately built + installed binary**. `aeo up` NEVER rebuilds it (grep
  confirms: the front-door has no self-rebuild path). Clearing `~/.aeo` does
  nothing to it. And `make install` only rebuilds `bin/aeo` if it's MISSING
  (Makefile:44 `[ -x bin/aeo ] || make build`) — a `git pull` that changes
  `bin/aeo.ae` does NOT force a rebuild of an already-present `bin/aeo`.

So the likely state on your box: **NEW runner (looks for `--aeo-*` flags), OLD
front-door (still builds an empty `rav` — the pre-2cb5a1b env-based code).** Old
front-door spawns new runner with empty argv → runner sees `argv[0]` only → guard
fires. I reproduced your exact symptom deterministically by spawning the 2cb5a1b
runner with an EMPTY `rav`:
```
OLD-FRONTDOOR spawning NEW runner with EMPTY rav
aeo: [app] up failed: [app] cannot anchor containerfile("../ctxdir/Containerfile")
  — AEO_COMPOSE_DIR is unset in the runner …
```
Identical to yours.

### The one-command check (do this first)

```
# from your aeo clone at 2cb5a1b:
grep -c '_rarg' bin/aeo.ae          # source: should be > 0 (the new argv path)
strings "$(command -v aeo | xargs readlink -f | xargs dirname)/../share/aeo/bin/aeo" \
  | grep -c -- '--aeo-compose-dir'  # INSTALLED front-door: 0 = STALE, rebuild needed
```
If the installed binary shows `0`, it predates the migration. Fix:
```
cd <aeo clone at 2cb5a1b>
make build     # force-rebuild bin/aeo from the new bin/aeo.ae  (ae's hash may skip;
rm -f bin/aeo && make build     # …so delete it first to be certain)
make install   # copy the fresh front-door onto PATH
rm -rf ~/.aeo  # drop the runner cache so it recompiles too
aeo up integration/todobackend/go_aeo/todobackend_go.ae
```
Then the front-door emits `--aeo-compose-dir <abs>` and the runner's DBG will show
argv[1..]. If after a verified-fresh front-door (the `strings` check shows the
flag) you STILL get argv[0]-only in the runner, THEN it's a genuine
`os_run_supervised_raw` platform bug and I'll build the minimal `ae run` repro for
the aether maintainer — but let's confirm the install first, because the repro
above already works here.

## 6 CONFIRMED FIXED (2026-09-08): it WAS a stale install — proven on our shared box

Correcting my own hedge above. We're on the SAME machine (crostini `penguin`,
Debian 12, ae 0.645.0, glibc, /bin/sh=dash, podman 4.3.1) — so there was never a
"my box vs your box." I checked the actual INSTALLED front-door here and it was
stale, exactly as theorised:

```
$ strings /home/paul/.local/share/aeo/bin/aeo | grep -c -- '--aeo-compose-dir'
0                       # <- pre-migration binary; runner was new (recompiled), FD was not
```

The `~/.aeo`-clear recompiles the RUNNER (so the DBG printed and it expected the
flags); nothing rebuilt the installed FRONT-DOOR, which still shipped an empty
`rav`. New runner + old front-door = argv[0] only = guard fires. Not a runtime
bug; no aether escalation.

Fix applied and verified end-to-end with the INSTALLED `aeo` (PATH wrapper, not a
scratchpad binary):
```
$ rm -f bin/aeo && make build && make install && rm -rf ~/.aeo
$ strings /home/paul/.local/share/aeo/bin/aeo | grep -c -- '--aeo-compose-dir'
1                       # <- fresh
$ cd <repo>/sub-parent && aeo up sub/comp.ae --no-supervisor   # foreign cwd
# -> built localhost/aeo-built/app from the compose-relative ../ctxdir context,
#    NO anchor error.
```

So: env→argv migration is correct, `os.run_supervised` delivers argv fine on this
platform, and item 6 is genuinely closed once the front-door binary is rebuilt.
The lasting lesson (worth a Makefile fix, filed separately): `make install` must
FORCE-rebuild `bin/aeo` when the source is newer, instead of skipping on
`[ -x bin/aeo ]` — otherwise a `git pull` silently keeps a stale front-door. Until
that lands, the rule is **always `rm -f bin/aeo && make build && make install`
after pulling a front-door change.**
