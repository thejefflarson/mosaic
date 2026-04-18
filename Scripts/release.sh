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
BUILD_DIR="$(mktemp -d /tmp/mosaic-release.XXXXXX)"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-MosaicNotarization}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-2PR729W8E3}"
APP_NAME="Mosaic"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

trap 'rm -rf "$BUILD_DIR"' EXIT

# ── Prerequisites ─────────────────────────────────────────────────────────────

for cmd in xcodegen xcodebuild xcrun hdiutil create-dmg gh git; do
    command -v "$cmd" &>/dev/null || {
        echo "error: $cmd not found"
        [[ "$cmd" == "create-dmg" ]] && echo "  install with: brew install create-dmg"
        exit 1
    }
done

IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
if [[ "$IDENTITIES" != *"Developer ID Application"* ]]; then
    echo "error: no 'Developer ID Application' certificate found in keychain"
    exit 1
fi

if grep -q 'REPLACE_WITH_OUTPUT_OF_generate_keys' "$REPO_ROOT/project.yml"; then
    echo "error: SUPublicEDKey not set in project.yml"
    echo "  1. Build the project in Xcode to resolve Sparkle"
    echo "  2. Run: \$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*/Sparkle*/bin/*' | head -1)"
    echo "  3. Replace REPLACE_WITH_OUTPUT_OF_generate_keys in project.yml with the printed key"
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

# hdiutil preflight: fail fast if disk-image creation is blocked (sandbox or TCC),
# so we don't waste a ~2 minute archive build only to hit the error later.
HDIUTIL_TEST_DIR=$(mktemp -d /tmp/mosaic-hdiutil-test.XXXXXX)
HDIUTIL_TEST_DMG=$(mktemp -u /tmp/mosaic-hdiutil-test.XXXXXX.dmg)
trap 'rm -rf "$BUILD_DIR" "$HDIUTIL_TEST_DIR" "$HDIUTIL_TEST_DMG"' EXIT
if ! hdiutil create -volname "test" -srcfolder "$HDIUTIL_TEST_DIR" \
        -ov -format UDZO "$HDIUTIL_TEST_DMG" &>/dev/null; then
    echo "error: hdiutil cannot create disk images in this shell"
    echo "  cause: macOS TCC or a sandboxed shell (e.g. ziplock) is blocking it"
    echo "  fix:   run this script from a plain Terminal.app session, and if needed"
    echo "         grant Terminal Full Disk Access in System Settings → Privacy & Security"
    exit 1
fi
rm -rf "$HDIUTIL_TEST_DIR" "$HDIUTIL_TEST_DMG"

echo "releasing $APP_NAME $VERSION"
SHORT_VERSION="${VERSION#v}"

# ── Bump version in Info.plist and project.yml ───────────────────────────────

PLIST_PATH="$REPO_ROOT/Mosaic/Resources/Info.plist"
PROJECT_YML="$REPO_ROOT/project.yml"
echo "→ bumping CFBundleShortVersionString to $SHORT_VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$PLIST_PATH"
# project.yml is the xcodegen source; xcodegen merges its properties into Info.plist
# during the archive step, so it must match or it will overwrite the plist bump.
sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$SHORT_VERSION\"/" "$PROJECT_YML"

# Increment CFBundleVersion (build number) so Sparkle can compare builds correctly.
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH")
BUILD_NUMBER=$(( CURRENT_BUILD + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"
sed -i '' "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$BUILD_NUMBER\"/" "$PROJECT_YML"

git -C "$REPO_ROOT" add "$PLIST_PATH" "$PROJECT_YML"
git -C "$REPO_ROOT" diff --cached --quiet || git -C "$REPO_ROOT" commit -m "chore: bump version to $SHORT_VERSION"

# ── Tests ─────────────────────────────────────────────────────────────────────

echo "→ running tests"
xcodebuild test \
    -scheme MosaicTests \
    -destination 'platform=macOS' \
    -IDEPackageSupportDisableManifestSandbox=1 \
    -quiet

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
    -IDEPackageSupportDisableManifestSandbox=1 \
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
    -IDEPackageSupportDisableManifestSandbox=1 \
    -quiet

# ── DMG ───────────────────────────────────────────────────────────────────────

echo "→ creating DMG"
# create-dmg generates a polished DMG with correctly-iconed Applications alias
# and positioned icons. It writes to the current directory, so cd into BUILD_DIR.
(
    cd "$BUILD_DIR"
    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 600 340 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 160 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 160 \
        --no-internet-enable \
        "$(basename "$DMG")" \
        "$EXPORT_DIR/$APP_NAME.app" \
        > /dev/null
)

# ── Notarize & staple ─────────────────────────────────────────────────────────

echo "→ notarizing (~2 min)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

echo "→ stapling"
xcrun stapler staple "$DMG"

# ── Sign DMG for Sparkle & update appcast ─────────────────────────────────────

echo "→ signing DMG for Sparkle"
SIGN_UPDATE=$(command -v sign_update 2>/dev/null || \
    find ~/Library/Developer/Xcode/DerivedData -name sign_update \
         -path "*/Sparkle*/bin/*" 2>/dev/null | head -1)

if [[ -z "${SIGN_UPDATE:-}" ]]; then
    echo "warning: sign_update not found — skipping appcast update"
    echo "  Build the project in Xcode once so Sparkle is resolved, then retry."
else
    SIG_OUTPUT=$("$SIGN_UPDATE" "$DMG")
    ED_SIG=$(printf '%s' "$SIG_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
    DMG_LENGTH=$(stat -f%z "$DMG")
    DMG_FILENAME=$(basename "$DMG")
    DOWNLOAD_URL="https://github.com/thejefflarson/mosaic/releases/download/${VERSION}/${DMG_FILENAME}"
    PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

    python3 - "$REPO_ROOT/appcast.xml" \
              "$SHORT_VERSION" "$BUILD_NUMBER" "$DOWNLOAD_URL" \
              "$ED_SIG" "$DMG_LENGTH" "$PUB_DATE" <<'PYEOF'
import sys
from pathlib import Path

appcast, version, build, url, sig, length, pub_date = sys.argv[1:]
item = f"""
    <item>
      <title>Mosaic {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <enclosure url="{url}"
                 sparkle:edSignature="{sig}"
                 length="{length}"
                 type="application/octet-stream" />
    </item>"""

text = Path(appcast).read_text()
text = text.replace('  </channel>', item + '\n  </channel>')
Path(appcast).write_text(text)
PYEOF

    git -C "$REPO_ROOT" add appcast.xml
    git -C "$REPO_ROOT" commit -m "appcast: add $VERSION"
fi

# ── Draft release notes ───────────────────────────────────────────────────────

echo "→ drafting release notes"
PREV_TAG=$(git tag --sort=-version:refname | head -1)
if [[ -n "$PREV_TAG" ]]; then
    COMMIT_LOG=$(git log --oneline "${PREV_TAG}..HEAD")
else
    COMMIT_LOG=$(git log --oneline)
fi

RELEASE_NOTES_ARGS=(--generate-notes)
if command -v claude &>/dev/null && [[ -n "$COMMIT_LOG" ]]; then
    NOTES=$(claude -p "Write concise GitHub release notes for $APP_NAME $VERSION in markdown.
Focus on what users will notice — new features, fixes, improvements — not implementation details.
Use a short intro sentence, then bullet points (3–8 items). Do not use 'we' language. Be brief.

Commits since ${PREV_TAG:-the beginning}:
$COMMIT_LOG" 2>/dev/null) || true
    [[ -n "${NOTES:-}" ]] && RELEASE_NOTES_ARGS=(--notes "$NOTES")
fi

# ── Tag & publish ─────────────────────────────────────────────────────────────

echo "→ pushing main and tagging $VERSION"
git push origin main
git tag "$VERSION"
git push origin "$VERSION"

echo "→ creating GitHub release"
gh release create "$VERSION" "$DMG" \
    --title "$APP_NAME $VERSION" \
    "${RELEASE_NOTES_ARGS[@]}"

echo "done — $APP_NAME $VERSION released"
