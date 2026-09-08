# `aeo suite`/`smoke`/`check` can't run specs from an INSTALLED CLI — run-spec.sh not bundled

**Status:** RESOLVED (2026-09-08, commit pending). Fixed by running the spec
DIRECTLY (no `test/run-spec.sh` trampoline) and anchoring the composition-relative
spec path via `AEO_COMPOSE_DIR` — so nothing extra needs bundling and it works
identically from a clone and an install. Found wiring servirtium-vcr's go_aeo spike
so `aeo suite` runs its record spec.

## Resolution

`lib/aeo/runner.ae` `_run_one_spec` no longer shells `test/run-spec.sh`. It now:
1. Anchors the spec path with `_compose_rel(spec)` (the composition-relative path,
   e.g. `suite("checks/foo.spec.ae")`, resolved against the compose file's dir via
   `AEO_COMPOSE_DIR` — the same anchor the containerfile()/build_context() fix
   uses). This ALSO fixes a second latent bug: the old code resolved the spec
   against `AEO_HOME`, so only aeo's own `examples/` specs (which live under
   AEO_HOME) ever resolved — a composition's own `checks/…` spec never did.
2. Builds it directly: `ae build <specabs> -o /tmp/aeo-phasespec-<name> --lib
   <AEO_HOME>/lib && <bin>` (build-then-run fresh, so edits always take).

Why not bundle `test/run-spec.sh`: that script is aeo's INTERNAL test harness for
its own `test/spec_*.ae` — FreeBSD-only skips, capsicum C/python staging, the
AETHER_PIN floor warning, the `spec_*.ae` glob. A composition's declared spec needs
none of that; it just compiles with std.spec (+ aeo's lib) and runs. Bundling the
harness would drag `capfd.c`, `capharness.py`, etc. into every install for no
reason. `test/run-spec.sh` stays as the CLONE-side developer/CI suite runner (`sh
test/run-spec.sh`); it is simply no longer on the `aeo suite` runtime path.

Verified via the INSTALLED CLI (`make install`, no `test/` in the bundle):
- `aeo suite app.ae` with `suite("checks/web_suite.spec.ae")` → container up,
  "running spec checks/web_suite.spec.ae", the spec's assertion executes
  (`1 passing`), teardown. No "cannot open test/run-spec.sh".
- A deliberately failing spec → `aeo suite` exits 1 (CI contract intact).
- From a FOREIGN cwd (`/tmp`) with the compose path elsewhere → the
  composition-relative spec still anchors + runs (proves compose-dir anchoring,
  not cwd luck).
- aeo's own full suite still 0-fail (unaffected — it uses run-spec.sh directly).

## Original report

**Status:** OPEN (2026-09-08). Found wiring servirtium-vcr's go_aeo spike so
`aeo suite` runs its record spec.

## Symptom

`aeo suite <compose.ae>` (installed aeo v0.2.2, `make install` bundle) deploys +
tears down fine, but the spec never actually runs:
```
aeo: [sut] up
aeo: suite — running spec checks/go_record_suite.spec.ae
sh: 0: cannot open test/run-spec.sh: No such file
aeo: suite complete — tearing down
```

## Cause

`lib/aeo/runner.ae:3664` executes a named spec via:
```
list_add(av, "cd ${home} && sh test/run-spec.sh ${spec}")
```
where `${home}` is `AEO_HOME` (the installed runtime tree, `~/.local/share/aeo`).
But `test/run-spec.sh` exists only in the **clone**, not in the installed bundle:
- clone: `test/run-spec.sh` — present
- `~/.local/share/aeo/test/run-spec.sh` — **absent** (the CLI bundle ships
  `bin/aeo` + `share/aeo/{lib,examples,bin/aeo}`, no `test/`).

So the check/smoke/suite phases — a headline feature ("A composition declares its
OWN verification with first-class check()/smoke()/suite()") — silently no-op the
spec on any install that came from `get.sh` / `make install`, and only work from
a source clone where `test/run-spec.sh` happens to be alongside.

## Ask

Bundle whatever the spec runner needs into the install tree (ship `test/run-spec.sh`
under `share/aeo/`, and point runner.ae at `${home}/test/run-spec.sh` or wherever
it lands), OR run specs directly (`ae run <spec>` / the std.spec entry) without the
shell-script trampoline so there's nothing extra to package. Either way `aeo suite`
should run specs identically from an installed CLI and from a clone.

## Impact for servirtium

Non-fatal for the go_aeo spike: the composition's build→up→verified-teardown all
work from the installed CLI; only the in-suite record step is skipped. Once
run-spec.sh (or a bundle-free spec runner) ships, `aeo suite
integration/todobackend/go_aeo/todobackend_go.ae` runs the record end-to-end — the
spec invokes the canonical aeb record leaf (`integration/todobackend/go/.record.ae`).
