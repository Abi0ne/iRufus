#!/bin/bash
# Corresponding source for GPL distribution: build/iRufus-<version>-source.tar.gz
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(grep -m1 '^version' "$ROOT/engine/Cargo.toml" | cut -d'"' -f2)"
mkdir -p "$ROOT/build"
OUT="$ROOT/build/iRufus-$VERSION-source.tar.gz"
if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$ROOT" archive --format=tar.gz --prefix="iRufus-$VERSION/" -o "$OUT" HEAD
else
    tar -C "$ROOT/.." -czf "$OUT" --exclude='*/target' --exclude='*/.build' --exclude='*/build' "$(basename "$ROOT")"
fi
echo "$OUT"
