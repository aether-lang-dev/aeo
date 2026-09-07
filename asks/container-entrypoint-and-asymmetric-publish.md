# container: honor `entrypoint()` as podman `--entrypoint`, and an asymmetric `publish(ext,inn)`

**Status:** OPEN (2026-09-07). Found while spiking a real workload
(servirtium-vcr's Go todobackend record standup) as an aeo composition. The
lifecycle mechanics (health-gated up, verified teardown) worked great; two
compose-DSL / linux-driver gaps stopped the composition from expressing the real
container invocation without a wrapper.

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

## Why it matters

These are the only two blockers to converting servirtium-vcr's containerized
integration tests (24 record/playback leaves across 12 languages) from
hand-rolled `podman run` + curl-poll + best-effort `rm -f` to `aeo suite`
compositions — which would give them health-gated bring-up and *guaranteed*
teardown-on-failure for free. The spike (its composition + suite spec + a
before/after writeup) lives at
`servirtium-vcr/integration/todobackend/go_aeo/`.
