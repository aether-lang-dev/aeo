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
