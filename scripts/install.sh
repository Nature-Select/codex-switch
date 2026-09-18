#!/usr/bin/env bash
# Build from source and install into PREFIX/bin (default /usr/local).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"

swift build -c release
mkdir -p "$BIN_DIR"

if [[ ! -w "$BIN_DIR" ]]; then
  echo "error: $BIN_DIR is not writable." >&2
  echo "Re-run with sudo, or pick another prefix: PREFIX=\"\$HOME/.local\" bash scripts/install.sh" >&2
  exit 1
fi

install -m 0755 "$ROOT/.build/release/codex-switch" "$BIN_DIR/codex-switch"
echo "$BIN_DIR/codex-switch"
