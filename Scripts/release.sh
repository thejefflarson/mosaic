#!/usr/bin/env bash
# release.sh — build, sign, notarize, and publish a Mosaic release locally.
#
# Usage:
#   ./Scripts/release.sh v0.2.0
#
# One-time credential setup (stores credentials in your login keychain):
#   xcrun notarytool store-credentials "MosaicNotarization" \
#     --apple-id "you@example.com" \
#     --team-id "ABCDEF1234" \
#     --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com
#
# Optional environment variables:
#   NOTARYTOOL_PROFILE   keychain profile name (default: MosaicNotarization)
#   DEVELOPMENT_TEAM     10-char Apple team ID (default: 2PR729W8E3)

set -euo pipefail

VERSION="${1:?Usage: $0 <version tag>  e.g. $0 v0.2.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-MosaicNotarization}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-2PR729W8E3}"
APP_NAME="Mosaic"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

trap 'rm -rf "$BUILD_DIR"' EXIT

# ── Prerequisites ─────────────────────────────────────────────────────────────

for cmd in xcodegen xcodebuild xcrun hdiutil gh git; do
    command -v "$cmd" &>/dev/null || { echo "error: $cmd not found"; exit 1; }
done

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' certificate found in keychain"
    exit 1
fi

if git tag --list | grep -qxF "$VERSION"; then
    echo "error: tag $VERSION already exists locally"
    exit 1
fi

if git status --porcelain | grep -q .; then
    echo "error: working tree is dirty — commit or stash changes before releasing"
    exit 1
fi

echo "releasing $APP_NAME $VERSION"

# ── Generate & archive ────────────────────────────────────────────────────────

cd "$REPO_ROOT"
echo "→ generating Xcode project"
xcodegen generate --quiet

echo "→ building archive (Release)"
SIGN_ARGS=(
    CODE_SIGN_IDENTITY="Developer ID Application"
    CODE_SIGN_STYLE=Manual
    CODE_SIGNING_ALLOWED=YES
)
[[ -n "${DEVELOPMENT_TEAM:-}" ]] && SIGN_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")

xcodebuild archive \
    -scheme "$APP_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    "${SIGN_ARGS[@]}" \
    -quiet

# ── Export ────────────────────────────────────────────────────────────────────

echo "→ exporting app"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Add :teamID string $DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"
fi

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -quiet

# ── DMG ───────────────────────────────────────────────────────────────────────

echo "→ creating DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$EXPORT_DIR/$APP_NAME.app" \
    -ov -format UDZO \
    "$DMG" \
    > /dev/null

# ── Notarize & staple ─────────────────────────────────────────────────────────

echo "→ notarizing (~2 min)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

echo "→ stapling"
xcrun stapler staple "$DMG"

# ── Tag & publish ─────────────────────────────────────────────────────────────

echo "→ tagging $VERSION"
git tag "$VERSION"
git push origin "$VERSION"

echo "→ creating GitHub release"
gh release create "$VERSION" "$DMG" \
    --title "$APP_NAME $VERSION" \
    --generate-notes

echo "done — $APP_NAME $VERSION released"
