#!/bin/bash
# Build the files of a GitHub release into build/release/:
#   iRufus-<version>.zip       the app, installed by iRufus' automatic updates
#   iRufus-<version>.zip.sig   Ed25519 signature of the zip (checked before installing)
#   iRufus-<version>.dmg       drag-to-install disk image for manual downloads
#   iRufus-<version>-source.tar.gz   corresponding source (GPL section 6)
# Arguments are passed to build-app.sh (e.g. --universal).
# Environment:
#   IRUFUS_UPDATE_KEY  private signing key (default ~/.config/irufus/update-ed25519.key)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(grep -m1 '^version' "$ROOT/engine/Cargo.toml" | cut -d'"' -f2)"
KEY="${IRUFUS_UPDATE_KEY:-$HOME/.config/irufus/update-ed25519.key}"
OUT="$ROOT/build/release"
SIGNING="$ROOT/scripts/update-signing.swift"

[[ -f "$KEY" ]] || { echo "Signing key not found: $KEY (see docs/BUILD.md)" >&2; exit 1; }
EMBEDDED="$(grep -m1 'static let publicKey' "$ROOT/app/Sources/IrufusCore/Updates.swift" | cut -d'"' -f2)"
[[ "$(swift "$SIGNING" public "$KEY")" == "$EMBEDDED" ]] \
    || { echo "The key does not match the public key embedded in Updates.swift" >&2; exit 1; }

"$ROOT/scripts/build-app.sh" "$@"

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/iRufus-$VERSION.zip"
ditto -c -k --keepParent "$ROOT/build/iRufus.app" "$ZIP"
swift "$SIGNING" sign "$KEY" "$ZIP" > "$ZIP.sig"
swift "$SIGNING" verify "$EMBEDDED" "$ZIP" "$(cat "$ZIP.sig")"
"$ROOT/scripts/make-dmg.sh" > /dev/null
mv "$("$ROOT/scripts/make-source-archive.sh")" "$OUT/"

echo
ls -l "$OUT"
echo
echo "Publish with:"
echo "  gh release create v$VERSION --repo Abi0ne/iRufus --title \"iRufus $VERSION\" --notes-file <notes> $OUT/*"
