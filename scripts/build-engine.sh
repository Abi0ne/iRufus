#!/bin/bash
# Build the Rust engine as a static library for the Swift app.
#   scripts/build-engine.sh             → host architecture (arm64 on Apple Silicon)
#   scripts/build-engine.sh --universal → arm64 + x86_64 (needs: rustup target add x86_64-apple-darwin)
# Output: engine/target/irufus/libirufus_engine.a
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine"
OUT="$ENGINE/target/irufus"
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0

UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

mkdir -p "$OUT"
cd "$ENGINE"
if [[ $UNIVERSAL == 1 ]]; then
    cargo build --release --locked --target aarch64-apple-darwin
    cargo build --release --locked --target x86_64-apple-darwin
    lipo -create \
        target/aarch64-apple-darwin/release/libirufus_engine.a \
        target/x86_64-apple-darwin/release/libirufus_engine.a \
        -output "$OUT/libirufus_engine.a"
else
    cargo build --release --locked
    cp target/release/libirufus_engine.a "$OUT/libirufus_engine.a"
fi
lipo -info "$OUT/libirufus_engine.a"
