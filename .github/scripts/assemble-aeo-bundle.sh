#!/usr/bin/env sh
# assemble-aeo-bundle.sh OS ARCH — build the aeo CLI release bundle for a target.
#
# Produces dist/aeo-<os>-<arch>.tar.gz from an ALREADY-BUILT bin/aeo (the caller,
# release-aeo.yml, cross-builds bin/aeo first). Bundle layout:
#
#   aeo-<os>-<arch>/
#     bin/aeo                       the target-native CLI
#     Makefile                      the install target
#     install.sh                    runs `make -C share/aeo install PREFIX=…`
#     share/aeo/bin/aeo             (the CLI again — the wrapper execs this)
#     share/aeo/lib/                the runtime module tree
#     share/aeo/examples/           the substrate-grid examples
#
# Factored out of the workflow so it's testable locally:
#   ae build bin/aeo.ae -o bin/aeo --lib lib
#   sh .github/scripts/assemble-aeo-bundle.sh linux x86_64
#   tar tzf dist/aeo-linux-x86_64.tar.gz | head
set -eu

OS="${1:?usage: assemble-aeo-bundle.sh OS ARCH}"
ARCH="${2:?usage: assemble-aeo-bundle.sh OS ARCH}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

[ -x bin/aeo ] || { echo "assemble: bin/aeo not built — run 'ae build bin/aeo.ae -o bin/aeo --lib lib' first" >&2; exit 1; }

BASE="aeo-$OS-$ARCH"
STAGE="dist/$BASE"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share/aeo/bin"

# The CLI, at the bundle root (for direct use) and under share/ (what the
# installed wrapper execs).
cp -f bin/aeo "$STAGE/bin/aeo"
cp -f bin/aeo "$STAGE/share/aeo/bin/aeo"
chmod +x "$STAGE/bin/aeo" "$STAGE/share/aeo/bin/aeo"

# The runtime tree the CLI needs at AEO_HOME: lib/ (staged into every build) and
# examples/ (the substrate grid). NOT test/ — a release ships no test harness.
cp -R lib "$STAGE/share/aeo/lib"
[ -d examples ] && cp -R examples "$STAGE/share/aeo/examples" || true

# The Makefile the bundled install.sh drives (its `install` copies share/aeo ->
# $PREFIX/share/aeo and writes the $PREFIX/bin/aeo wrapper). Shipped at the
# bundle root AND under share/aeo (install.sh runs `make -C share/aeo`).
cp -f Makefile "$STAGE/Makefile"
cp -f Makefile "$STAGE/share/aeo/Makefile"

# The bundled installer: no compiler needed (bin/aeo is already target-native),
# but `make install` still runs — so GNU make is required (checked by get.sh).
cat > "$STAGE/install.sh" <<'EOF'
#!/bin/sh
# Install this prebuilt aeo bundle. bin/aeo is already target-native; this copies
# the runtime tree to PREFIX/share/aeo and writes a PREFIX/bin/aeo wrapper that
# pins AEO_HOME. Usage: ./install.sh [PREFIX]   (default: ~/.local)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:-$HOME/.local}"
# The bundle already carries the built bin/aeo under share/aeo/bin — the
# Makefile's install sees it and skips the (compiler-needing) build.
make -C "$here/share/aeo" install PREFIX="$PREFIX"
echo "aeo installed to $PREFIX/bin/aeo"
echo "NOTE: aeo shells 'ae' at runtime — ensure the Aether toolchain is on PATH."
EOF
chmod +x "$STAGE/install.sh"

# Archive: tar.gz (+ .sha256 is done by the caller's Checksum step). zip too, so
# a minimal box with only tar OR unzip can extract (matches aeb's dual-format).
( cd dist && tar -czf "$BASE.tar.gz" "$BASE" )
if command -v zip >/dev/null 2>&1; then
    ( cd dist && zip -qr "$BASE.zip" "$BASE" )
fi

echo "assembled: dist/$BASE.tar.gz"
tar -tzf "dist/$BASE.tar.gz" | sed 's/^/  /' | head -20
