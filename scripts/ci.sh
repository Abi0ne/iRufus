#!/bin/bash
# Static checks and automated tests, as run in CI. Never touches physical disks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
cd "$ROOT/engine"
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
"$ROOT/scripts/build-app.sh"
cd "$ROOT/app"
if [[ -z "${IRUFUS_SDK:-}" ]] && ! xcode-select -p | grep -q Xcode.app; then
    export SDKROOT="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk | sort -V | tail -1)"
fi
swift run IrufusCoreChecks
python3 "$ROOT/scripts/localization.py" check
echo "CI OK"
