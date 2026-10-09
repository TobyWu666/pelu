#!/bin/bash
# Pelu Mac release: build → notarize → staple → DMG → sign for Sparkle
#
# Usage:
#   ./scripts/release.sh <marketing-version> <build-number>
# Example:
#   ./scripts/release.sh 1.0.0 1
#   ./scripts/release.sh 1.0.1 2
#
# Requirements (one-time):
#   - Developer ID Application certificate in Keychain
#   - Developer ID provisioning profile installed (plan §八)
#   - Notarytool keychain-profile: pelu-notary
#   - Sparkle Ed25519 keypair generated (./scripts/generate-sparkle-keys.sh)
#   - brew install create-dmg

set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  cat >&2 <<EOF
Usage: $0 <marketing-version> <build-number>
Example: $0 1.0.0 1

  marketing-version → CFBundleShortVersionString (e.g. 1.0.0)
  build-number      → CFBundleVersion (MUST increment every release,
                       Sparkle compares this for "is there a new version")
EOF
  exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Outside iCloud Drive: synced files pick up com.apple.FinderInfo and codesign
# rejects the bundle ("resource fork, Finder information, or similar detritus").
BUILD_DIR="${PELU_BUILD_DIR:-${TMPDIR:-/tmp}/pelu-build-release}"
PRODUCTS_DIR="$BUILD_DIR/Build/Products/Release"
DIST_DIR="$PROJECT_ROOT/dist"
DMG_BG="$SCRIPT_DIR/dmg-background.tiff"

APP_NAME="PeluMac"
APP_BUNDLE="$PRODUCTS_DIR/$APP_NAME.app"
# Stable filename so https://.../releases/latest/download/PeluMac.dmg
# always resolves to the newest release's asset.
DMG_NAME="PeluMac.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
NOTARIZE_ZIP="$DIST_DIR/.tmp/PeluMac-notarize.zip"

# Public release repo (DMG hosting only; main code stays in private pelu).
RELEASES_REPO="TobyWu666/pelu-releases"

# ── Constants ─────────────────────────────────────────────────────────────────
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
TEAM_ID="N6Z3T6D6NF"
CODE_SIGN_IDENTITY="Developer ID Application: Kuan Ting Wu ($TEAM_ID)"
PROVISIONING_PROFILE="Pelu Mac Developer ID"
NOTARY_PROFILE="pelu-notary"

mkdir -p "$DIST_DIR/.tmp"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo "==> Pre-flight"

command -v create-dmg >/dev/null 2>&1 || {
  echo "✗ create-dmg not installed. Run: brew install create-dmg" >&2
  exit 1
}

SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path "*/Sparkle*/bin/sign_update" -perm +111 2>/dev/null | head -1)"
[[ -n "$SIGN_UPDATE" ]] || {
  echo "✗ Sparkle sign_update not found. Build PeluMac in Xcode first." >&2
  exit 1
}

security find-identity -v -p codesigning | grep -q "Developer ID Application" || {
  echo "✗ Developer ID Application certificate not in Keychain (see plan §八)" >&2
  exit 1
}

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
  echo "✗ notarytool keychain-profile '$NOTARY_PROFILE' missing. Run:" >&2
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <ID> --team-id $TEAM_ID" >&2
  exit 1
}

# Guard against publishing a placeholder Ed25519 key.
PBXPROJ="$PROJECT_ROOT/Pelu.xcodeproj/project.pbxproj"
if grep -q "REPLACE_WITH_ED25519_PUBLIC_KEY" "$PBXPROJ"; then
  echo "✗ SUPublicEDKey is still the placeholder." >&2
  echo "  Run ./scripts/generate-sparkle-keys.sh and paste the public key into" >&2
  echo "  PeluMac target Build Settings → SUPublicEDKey." >&2
  exit 1
fi

echo "✓ Pre-flight ok"

# ── Build ────────────────────────────────────────────────────────────────────
echo "==> Build PeluMac $VERSION ($BUILD) — Release / Developer ID / hardened runtime"

DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
  -project "$PROJECT_ROOT/Pelu.xcodeproj" \
  -scheme PeluMac \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  clean build

[[ -d "$APP_BUNDLE" ]] || { echo "✗ Build produced no .app" >&2; exit 1; }

# ── Re-sign Sparkle nested binaries ──────────────────────────────────────────
# Sparkle.framework ships pre-signed by the Sparkle project. Xcode re-signs
# the framework itself but does NOT re-sign the nested Updater.app, Autoupdate,
# and XPC helpers. notarytool rejects them ("not signed with valid Developer ID
# / signature does not include a secure timestamp") unless we sign them
# ourselves with our Developer ID + hardened runtime + timestamp.
echo "==> Re-sign Sparkle nested binaries"
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

for BIN in \
  "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
  "$SPARKLE_FW/Versions/B/Autoupdate" \
  "$SPARKLE_FW/Versions/B/Updater.app" \
  "$SPARKLE_FW"
do
  [[ -e "$BIN" ]] || continue
  codesign --force --options runtime --timestamp \
    --sign "$CODE_SIGN_IDENTITY" \
    --preserve-metadata=identifier,entitlements,flags \
    "$BIN"
done

# Re-sign the main app last so its signature reflects the new framework hash.
# preserve-metadata=entitlements 是關鍵：Xcode 簽 .app 時用的 .xcent 比 source
# 檔的 PeluMac.entitlements 多了 provisioning profile 帶來的關鍵 entitlements
# （com.apple.application-identifier / team-identifier / keychain-access-groups）。
# 若用 --entitlements 指向 source 檔重簽，這些會被丟掉，secd 會 ignore
# entitlement，CloudKit / Keychain / App Group 全部失效 → onboarding 一呼叫
# CKContainer.accountStatus 直接掛。
codesign --force --options runtime --timestamp \
  --sign "$CODE_SIGN_IDENTITY" \
  --preserve-metadata=identifier,entitlements,flags \
  "$APP_BUNDLE"

# ── Notarize .app ────────────────────────────────────────────────────────────
echo "==> Notarize $APP_NAME.app"
rm -f "$NOTARIZE_ZIP"
( cd "$PRODUCTS_DIR" && ditto -c -k --keepParent "$APP_NAME.app" "$NOTARIZE_ZIP" )

NOTARY_OUT="$(xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait)"
echo "$NOTARY_OUT"
SUB_ID="$(echo "$NOTARY_OUT" | awk '/id:/ {id=$2} END {print id}')"
STATUS="$(echo "$NOTARY_OUT" | awk '/status:/ {s=$2} END {print s}')"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "✗ Notarization failed (status: $STATUS). Apple log:" >&2
  xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" >&2
  exit 1
fi

# ── Staple .app ──────────────────────────────────────────────────────────────
echo "==> Staple"
xcrun stapler staple "$APP_BUNDLE"

# ── Gatekeeper assess ────────────────────────────────────────────────────────
echo "==> Verify .app"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

# ── Build DMG ────────────────────────────────────────────────────────────────
echo "==> Build DMG"
rm -f "$DMG_PATH"

create-dmg \
  --volname "Pelu $VERSION" \
  --background "$DMG_BG" \
  --window-pos 200 120 \
  --window-size 750 500 \
  --icon-size 120 \
  --icon "$APP_NAME.app" 180 250 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 560 250 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_BUNDLE"

# ── Sign + notarize the DMG itself ───────────────────────────────────────────
echo "==> Codesign DMG"
codesign --sign "$CODE_SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Notarize DMG"
DMG_NOTARY_OUT="$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait)"
echo "$DMG_NOTARY_OUT"
DMG_SUB_ID="$(echo "$DMG_NOTARY_OUT" | awk '/id:/ {id=$2} END {print id}')"
DMG_STATUS="$(echo "$DMG_NOTARY_OUT" | awk '/status:/ {s=$2} END {print s}')"
if [[ "$DMG_STATUS" != "Accepted" ]]; then
  echo "✗ DMG notarization failed (status: $DMG_STATUS). Apple log:" >&2
  xcrun notarytool log "$DMG_SUB_ID" --keychain-profile "$NOTARY_PROFILE" >&2
  exit 1
fi

echo "==> Staple DMG"
xcrun stapler staple "$DMG_PATH"

echo "==> Verify DMG"
spctl --assess --type install --verbose=4 "$DMG_PATH"

# ── Sparkle Ed25519 signature ────────────────────────────────────────────────
echo "==> Sparkle sign"
SPARKLE_SIG_LINE="$("$SIGN_UPDATE" "$DMG_PATH")"  # e.g. sparkle:edSignature="…" length="…"
DMG_LENGTH="$(stat -f%z "$DMG_PATH")"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

# ── Summary + appcast snippet ────────────────────────────────────────────────
PUB_DATE="$(LC_ALL=en_US.UTF-8 date -u +"%a, %d %b %Y %H:%M:%S +0000")"
RELEASE_URL="https://github.com/${RELEASES_REPO}/releases/download/v${VERSION}/${DMG_NAME}"

cat <<EOF

═════════════════════════════════════════════════════════════════════════
  ✓ Release ready

  DMG       : $DMG_PATH
  Size      : $DMG_LENGTH bytes
  SHA-256   : $SHA256
  Version   : $VERSION (build $BUILD)

  Next:
    1. gh release create v${VERSION} "$DMG_PATH" \\
         --repo $RELEASES_REPO \\
         --title "Pelu $VERSION" --notes "…"

    2. Append this <item> to appcast.xml and upload to pelu.wutoby.com:

  <item>
    <title>Pelu $VERSION</title>
    <pubDate>$PUB_DATE</pubDate>
    <sparkle:version>$BUILD</sparkle:version>
    <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure
      url="$RELEASE_URL"
      type="application/octet-stream"
      $SPARKLE_SIG_LINE />
  </item>

═════════════════════════════════════════════════════════════════════════
EOF
