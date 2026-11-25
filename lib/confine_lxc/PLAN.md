# lib/confine_lxc — PLAN (not built)

Written 2026-11-25 on the Chromebook, which has no LXC. Nothing in this folder
is code yet. This file is the hand-off: delete it when `module.ae` replaces it.

## Goal

Make `deny_syscalls()` work on an `lxc` node.

Today a `container` node (host podman/docker) gets its policy as a seccomp
profile (`lib/syscall_policy` + `lib/seccomp_baseline`, proven live). An `lxc`
node that declares one is **refused at boot** by `_syscall_gate` in
`lib/aeo/runner.ae`, and `aeo status` reports `supported=no`. That refusal is
correct and must stay until the steps below are proven on a real box.

## Why LXC is not "the podman renderer with a different flag"

1. **Different file format.** LXC takes its own line-oriented text, not the
   OCI JSON `lib/syscall_policy.render` emits.
2. **Opposite default.** The container baseline is an ALLOW-list (deny by
   default, ~370 calls allowed). LXC's stock profile is a DENY-list (allow by
   default, a handful refused). An LXC system container runs a real init
   (systemd, OpenRC) that needs `mount`, `unshare`, `setns`, `keyctl` and more.
   **Do not apply `lib/seccomp_baseline` to an LXC node** — expect it not to
   boot.
3. **One profile per container.** `lxc.seccomp.profile` names a single file;
   there is no include. So aeo cannot add a second file beside the distro's —
   it has to produce one file that is "the stock denials plus ours".

## Design

A denial-only renderer. For an LXC node the policy means: *the stock LXC
denials, plus `<name> errno 1` for every syscall the policy denies.*

```
lib/confine_lxc/module.ae      (ORIGINAL code — no header, see "Sources")
  render(stock_text, policy_csv) -> (profile_text, err)     pure
  stock_path() -> string                                    where the host keeps its stock profile
  profile_install(node, text) -> path | "ERR:why"           writes ~/.aeo/seccomp/<node>.lxc
```

- `syscall_policy.policy_error` and `syscall_policy.denied_names` are reused
  as they are. The classes and the fail-closed checks do not change per
  substrate — only the rendering does.
- `render` appends to the stock text. It must refuse (return an error) when
  the stock text is not a version-2 deny-list it recognises. Never guess.
- The driver applies it at start. `driver_lxc.start_argv_shared` already
  passes config with `-s lxc.mount.entry=…`; the profile rides the same way:
  `-s lxc.seccomp.profile=<path>`. No config-file edit, same sudo grant.
- Runner: make `_syscall_unrendered` return `""` for `k == "lxc"`, and have
  the `lxc` branch of `driver_up` call the new install + pass the path down
  (mirror `_syscall_flags`, including the audit record). Do this LAST, after
  the live proof — flipping the gate is what turns "refused" into "claimed".
- Status: `_secp_syscalls` needs an LXC read-back for its `verified` field
  (`lxc-info -n <node> -c lxc.seccomp.profile`, then compare the path).

### Where the stock profile comes from: the HOST, at run time

**Read the host's own stock profile when the node boots; do not carry a copy
in aeo.** Reasons, in order:

- LXC is **LGPL-2.1**. Its `common.seccomp` cannot be copied into this
  Apache-2.0 repo (AGENTS.md, "Licence & provenance": do not take from LGPL
  sources). Reading a file the distro installed, on the operator's own
  machine, is not copying it into aeo.
- It follows the delegate-or-port rule: the engine and its defaults are the
  distro's to ship and patch.
- The policy keyword changed between LXC versions (`blacklist` → `denylist`).
  The host's file is always spelled the way the host's LXC wants.

Usual location: `/usr/share/lxc/config/common.seccomp` (confirm per distro on
the fleet; it was absent on the Chromebook because LXC is not installed).
If the file is missing or unreadable: **refuse to start the node.** A
profile containing only aeo's lines would silently drop the stock denials.

## Sources — what may be read, what may be copied

| Source | Licence | Use |
|---|---|---|
| The host's installed LXC stock profile | LGPL-2.1 | **Read at run time only.** Never commit a copy, never paste its lines into a spec fixture. Write fixtures by hand. |
| `lxc.container.conf(5)` man page, section on seccomp | — | The format. Working from documentation does not make code derived. |
| `~/scm/incus` `internal/server/seccomp/seccomp.go` @ `641c025510c2e5692d54e112fa895f4a62df0aa8` | Apache-2.0 | **May be copied, with credit.** Holds an LXC-format profile built in code: `seccompHeader` (line 497), `defaultSeccompPolicy` (line 500, the stock deny lines), `seccompBlockNewMountAPI` (line 531), `compatBlockingPolicy` (line 575), and argument-rule syntax in the `seccompNotify*` constants (lines 512–570). |
| `~/scm/incus` `internal/server/instance/drivers/driver_lxc.go` lines 1121–1130 | Apache-2.0 | **May be copied, with credit.** How a manager points `lxc.seccomp.profile` at a generated file. |

**Preferred outcome: `module.ae` is original.** Appending `name errno 1`
lines needs nothing from Incus, and an original module stays free to move to
the MIT siblings.

**If anything IS taken from Incus** (most likely: carrying its
`defaultSeccompPolicy` as a fallback so a host with no stock file can still
boot), then:

- put it in its **own** module (`lib/lxc_seccomp_stock/`, data only, like
  `lib/seccomp_baseline`) — never mix it into `confine_lxc`;
- header: `// Derived from lxc/incus internal/server/seccomp/seccomp.go @ 641c0255…, Apache-2.0. Modified.`;
- `NOTICE`: a "Portions Copyright … (in respect of lines taken from the Incus
  project)" line. **That file has no per-file copyright line**, and Incus is a
  fork of LXD, so read `git log`/`git blame` and the repo's own credits before
  wording the holder — do not invent one;
- commit trailer: `Derived-from: lxc/incus@641c0255…`.

Only the constant names and line numbers above were looked at when this plan
was written, not the surrounding logic.

## Things not known yet — find out on the box, do not assume

- The exact second line of a version-2 profile on each fleet distro
  (`denylist` vs `blacklist`, and whether a default action follows it).
- Whether `errno 1` is accepted on every LXC version in the fleet.
- Whether `lxc-info -c lxc.seccomp.profile` reports a value set with `-s` at
  start (if not, the status read-back needs another route).
- Whether an **unprivileged** LXC container loads a custom profile the same
  way a rootful one does.
- Which classes a system container's init cannot live without. `mount`,
  `namespace` and `keyring` are the likely ones. Measure, the way `setid` was
  measured for podman, and either refuse those classes on `lxc` with a clear
  message or document them — do not ship a class that cannot boot.

## Proof required before the gate is opened

Same shape as `test/spec_syscall_policy_live.ae`:

1. **Control:** under the stock profile alone, `unshare -U true` and a
   `socket()` succeed inside the container.
2. **Denied:** under `namespace` / `sockets` they get EPERM.
3. **Still boots:** the container's init reaches running and a health command
   answers, with the widest policy the measurements above allow.
4. **Fail closed:** stock file moved aside → `aeo up` refuses, nothing starts.
5. **Status:** `aeo status` shows the profile verified on a booted node.

Skips must be honest (`spec.it_when`), never an always-true assertion.
Record box, kernel, LXC version and date in `TODO.md` ("Syscall policy").

## Where to run it

- **Ubuntu NUC** — first. Stock LXC, x86_64, same arch as the podman proof.
- **Pi 5** (`paul@192.168.0.78`, arm64) — second. LXC is already proven there
  through `driver_lxc`, and it exercises the other architecture.
- **Proxmox NUC** — third, and a separate piece of work. A `proxmox_ct` is LXC
  underneath, but aeo drives it through the PVE API, and raw `lxc.*` keys live
  in `/etc/pve/lxc/<id>.conf`, which the API does not let a token write. Expect
  to need a different delivery route; `proxmox_ct` stays refused until then.

Not applicable: GhostBSD (Capsicum is the peer there) and Windows 11.

## Also waiting on that fleet (same feature, other substrates)

From `TODO.md` "Syscall policy": re-run the podman proof on Aether 0.945.0
(the Chromebook is on 0.927.0), on docker, and on arm64; drift detection does
not notice a node that lost its profile; `aeo status`'s new row has no
automated test.
