#!/bin/bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
APP_NAME="Fantastty"
SCHEME="Fantastty"
BUNDLE_ID="com.blainecook.fantastty"
NOTARIZE_PROFILE="fantastty-notarize"

# ── Paths ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build/release"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

# ── Parse args ─────────────────────────────────────────────────
SKIP_NOTARIZE=false
for arg in "$@"; do
    case $arg in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ── Clean ──────────────────────────────────────────────────────
echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Build ──────────────────────────────────────────────────────
echo "==> Building $APP_NAME (Release)..."
xcodebuild \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    SYMROOT="$BUILD_DIR/Products" \
    clean build 2>&1 | tail -5

# Copy app bundle out of Xcode's nested structure
APP_BUILT="$BUILD_DIR/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_BUILT" ]; then
    echo "ERROR: Build product not found at $APP_BUILT"
    exit 1
fi
cp -R "$APP_BUILT" "$APP_PATH"

# ── Verify signature ──────────────────────────────────────────
echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature OK"

SIGN_INFO=$(codesign -dvv "$APP_PATH" 2>&1)
echo "$SIGN_INFO" | grep -E "^(Authority|TeamIdentifier|Identifier|Runtime)"

# ── Notarize ───────────────────────────────────────────────────
if [ "$SKIP_NOTARIZE" = true ]; then
    echo "==> Skipping notarization (--skip-notarize)"
else
    echo "==> Creating ZIP for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "==> Submitting to Apple notary service..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    rm -f "$ZIP_PATH"
fi

# ── Create DMG ─────────────────────────────────────────────────
echo "==> Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

# Notarize the DMG too
if [ "$SKIP_NOTARIZE" = false ]; then
    echo "==> Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "==> Stapling DMG..."
    xcrun stapler staple "$DMG_PATH"
fi

# ── Done ───────────────────────────────────────────────────────
echo ""
echo "==> Build complete!"
echo "    App: $APP_PATH"
echo "    DMG: $DMG_PATH"
echo ""
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "    DMG size: $DMG_SIZE"
