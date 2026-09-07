# container: `--entrypoint`, asymmetric `publish(ext,inn)`, and out-of-line Containerfile builds

**Status:** OPEN (2026-09-07). Found while spiking a real workload
(servirtium-vcr's Go todobackend record standup) as an aeo composition. The
lifecycle mechanics (health-gated up, verified teardown) worked great; three
compose-DSL / linux-driver gaps stopped the composition from owning the full
build→up→record→down flow declaratively — two block the run invocation, one keeps
the image `podman build` a manual pre-step.

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
