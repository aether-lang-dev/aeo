# `aeo suite`/`smoke`/`check` can't run specs from an INSTALLED CLI — run-spec.sh not bundled

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
