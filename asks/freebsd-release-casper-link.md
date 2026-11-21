# The FreeBSD release tarball's `ae` does not link std.casper on GhostBSD

**RESOLVED** in Aether 0.932.0 (PR #3795). Checked 2026-11-21 on ghostbsd (FreeBSD 15.1) with the released
0.934.0 and no environment variable: all seven `bin/` entry points build; on the released 0.931.0, in
the same shell, `bin/aeo` still fails to link. The text below is the original report.

Found 2026-11-20 verifying aeo on ghostbsd (FreeBSD 15.1-RELEASE-p6 amd64) with
the release tarball `aether-0.927.0-freebsd-x86_64.tar.gz` (sha256 1f68ab79...),
unpacked under its own AETHER_HOME, `AE_CC=cc`.

Repro: `ae build bin/aeo.ae -o bin/aeo --lib lib` in aeo. bin/aeo imports
std.casper through lib/host. The link fails with undefined symbols cap_init,
cap_close, cap_service_open, cap_getaddrinfo, cap_getpwnam, cap_sysctlbyname
(from aether_casper.o in libaether.a). The other six aeo entry points build.

Cause: `tools/ae.c` takes its Casper link libraries from `AETHER_CASPER_LIBS`,
a compile-time define, and the release `ae` carries none; the source Makefile
globs `/lib/libcasper.so.*` because GhostBSD has no `.so` linker symlinks.

Workaround, no Aether change: `AETHER_LDFLAGS_EXTRA="/lib/libcasper.so.1
/lib/libcap_pwd.so.1 /lib/libcap_sysctl.so.2 /lib/libcap_grp.so.1
/lib/libcap_dns.so.2"` builds it and the suite passes.

Wanted: the release `ae` on FreeBSD resolves the Casper libraries at link time
the way the Makefile's CASPER_LDFLAGS does, so a std.casper importer builds
without the env var. Not checked: whether a stock FreeBSD (with the `.so`
symlinks) links without it.
