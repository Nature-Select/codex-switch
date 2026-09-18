#!/usr/bin/env bash
# Build a universal binary and package it the way releases ship it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-dev}"
TARBALL="${TARBALL:-codex-switch-${VERSION}-macos-universal.tar.gz}"
STAGE="$ROOT/.build/package"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

if command -v codesign >/dev/null 2>&1; then
  /usr/bin/codesign --force --sign - "$BIN_DIR/codex-switch" >/dev/null
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$BIN_DIR/codex-switch" "$STAGE/codex-switch"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/README.md" "$STAGE/README.md"

/usr/bin/tar -czf "$ROOT/.build/$TARBALL" -C "$STAGE" codex-switch LICENSE README.md
shasum -a 256 "$ROOT/.build/$TARBALL" | awk '{print $1}' > "$ROOT/.build/$TARBALL.sha256"

echo "$ROOT/.build/$TARBALL"
