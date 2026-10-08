#!/bin/bash
# Build iRufus.app (Release) into build/iRufus.app.
#   scripts/build-app.sh               → arm64, ad-hoc signature
#   scripts/build-app.sh --universal   → arm64 + x86_64 (needs Xcode and the Rust x86_64 target)
# Environment:
#   IRUFUS_SIGN_IDENTITY  "Developer ID Application: …" to sign for distribution (default: ad-hoc "-")
#   IRUFUS_SDK            SDK path for swift build (auto-detected with Command Line Tools only)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/iRufus.app"
VERSION="$(grep -m1 '^version' "$ROOT/engine/Cargo.toml" | cut -d'"' -f2)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${IRUFUS_SIGN_IDENTITY:--}"

UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

# Command Line Tools without Xcode: the newest SDK may require SwiftUI macro
# plugins that only Xcode ships. Pick the newest SDK where State is not a macro.
if [[ -z "${IRUFUS_SDK:-}" ]] && ! xcode-select -p | grep -q Xcode.app; then
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
        iface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
        if [[ -f "$iface" ]] && ! grep -q 'public macro State()' "$iface"; then
            IRUFUS_SDK="$sdk"
            break
        fi
    done
fi
[[ -n "${IRUFUS_SDK:-}" ]] && export SDKROOT="$IRUFUS_SDK" && echo "Using SDK $SDKROOT"

echo "==> Engine"
if [[ $UNIVERSAL == 1 ]]; then "$ROOT/scripts/build-engine.sh" --universal; else "$ROOT/scripts/build-engine.sh"; fi

echo "==> Swift"
ARCH_FLAGS=()
[[ $UNIVERSAL == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build --package-path "$ROOT/app" -c release --product iRufus ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build --package-path "$ROOT/app" -c release --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})/iRufus"

echo "==> Bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/LICENSES"
cp "$BIN" "$APP_DIR/Contents/MacOS/iRufus"
cp -R "$ROOT/app/Resources/en.lproj" "$ROOT/app/Resources/it.lproj" "$APP_DIR/Contents/Resources/"
[[ -f "$ROOT/app/Resources/AppIcon.icns" ]] && cp "$ROOT/app/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSES/GPL-3.0.txt"
cp "$ROOT/THIRD_PARTY_LICENSES.md" "$APP_DIR/Contents/Resources/LICENSES/"
cp "$ROOT/engine/vendor/fatfs/LICENSE.txt" "$APP_DIR/Contents/Resources/LICENSES/fatfs-MIT.txt"
cp "$ROOT/engine/vendor/README.md" "$APP_DIR/Contents/Resources/LICENSES/fatfs-patch.md"
cat > "$APP_DIR/Contents/Resources/LICENSES/SOURCE.txt" <<EOF
iRufus $VERSION is free software released under the GNU GPL v3 or later.
The complete corresponding source code is distributed together with this
application as iRufus-$VERSION-source.tar.gz (scripts/make-source-archive.sh)
and must be provided on request for at least three years by whoever
distributes binaries, as required by section 6 of the GPL.
EOF

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
    <key>CFBundleExecutable</key><string>iRufus</string>
    <key>CFBundleIdentifier</key><string>io.github.abi0ne.iRufus</string>
    <key>CFBundleName</key><string>iRufus</string>
    <key>CFBundleDisplayName</key><string>iRufus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later. Based on Rufus © Pete Batard / Akeo Consulting.</string>
</dict>
</plist>
EOF
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

echo "==> Sign ($IDENTITY)"
SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --strict --verbose=1 "$APP_DIR"
lipo -info "$APP_DIR/Contents/MacOS/iRufus"
echo "Built $APP_DIR ($VERSION)"
