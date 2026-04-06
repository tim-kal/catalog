#!/bin/bash
# build-release.sh — Build, sign, notarize, and package DriveCatalog.app for distribution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
VERSION=""
BUILD_NUMBER=""
SKIP_SIGN=false
SCHEME="DriveCatalog"
CONFIGURATION="Release"
BUILD_DIR="$PROJECT_DIR/build/release"
ARCHIVE_PATH="$BUILD_DIR/DriveCatalog.xcarchive"
APP_NAME="DriveCatalog"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build, sign, notarize, and package DriveCatalog.app.

Options:
  --version VERSION     Set CFBundleShortVersionString in Info.plist before building
  --build NUMBER        Set CFBundleVersion in Info.plist before building
  --skip-sign           Produce an unsigned build (for local testing without a cert)
  -h, --help            Show this help message

Environment variables (required unless --skip-sign):
  DEVELOPER_ID_APPLICATION   Code signing identity (e.g. "Developer ID Application: Name (TEAMID)")

Environment variables (required for notarization):
  APPLE_ID                   Apple ID email for notarytool
  APPLE_TEAM_ID              Apple Developer Team ID
  APP_SPECIFIC_PASSWORD      App-specific password for notarytool
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  VERSION="$2"; shift 2 ;;
        --build)    BUILD_NUMBER="$2"; shift 2 ;;
        --skip-sign) SKIP_SIGN=true; shift ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

# ---------- Pre-flight checks ----------

if [ "$SKIP_SIGN" = false ]; then
    if [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
        echo "ERROR: DEVELOPER_ID_APPLICATION is not set."
        echo "  Export it before running this script, e.g.:"
        echo "    export DEVELOPER_ID_APPLICATION=\"Developer ID Application: Your Name (TEAMID)\""
        echo "  Or use --skip-sign for an unsigned build."
        exit 1
    fi

    # Verify the identity exists in the keychain
    if ! security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID_APPLICATION"; then
        echo "ERROR: Certificate '$DEVELOPER_ID_APPLICATION' not found in keychain."
        echo "  Make sure your Developer ID Application certificate is installed."
        exit 1
    fi
    echo "==> Signing identity: $DEVELOPER_ID_APPLICATION"
fi

# ---------- Update Info.plist if requested ----------

PLIST="$PROJECT_DIR/DriveCatalog/Info.plist"

if [ -n "$VERSION" ]; then
    echo "==> Setting version to $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi

if [ -n "$BUILD_NUMBER" ]; then
    echo "==> Setting build number to $BUILD_NUMBER"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

# ---------- Bundle Python runtime ----------

echo "==> Bundling Python runtime..."
if [ -x "$SCRIPT_DIR/bundle-python.sh" ]; then
    "$SCRIPT_DIR/bundle-python.sh"
else
    echo "WARNING: bundle-python.sh not found or not executable. Skipping Python bundling."
fi

# ---------- Generate Xcode project ----------

echo "==> Generating Xcode project..."
if command -v xcodegen &>/dev/null; then
    (cd "$PROJECT_DIR" && xcodegen generate)
else
    echo "WARNING: xcodegen not found. Using existing .xcodeproj."
fi

# ---------- Clean & Build ----------

echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [ "$SKIP_SIGN" = true ]; then
    SIGN_ARGS=(
        CODE_SIGN_IDENTITY="-"
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGNING_ALLOWED=NO
    )
    echo "==> Building (unsigned)..."
else
    SIGN_ARGS=(
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
        CODE_SIGN_STYLE=Manual
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
    )
    echo "==> Building (signed)..."
fi

xcodebuild \
    -project "$PROJECT_DIR/DriveCatalog.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    "${SIGN_ARGS[@]}" \
    archive \
    2>&1 | tail -20

echo "==> Exporting archive..."

# Create export options plist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
if [ "$SKIP_SIGN" = true ]; then
    cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
PLIST
else
    cat > "$EXPORT_OPTIONS" <<PLIST
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
fi

EXPORT_DIR="$BUILD_DIR/export"

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    2>&1 | tail -10

APP_PATH="$EXPORT_DIR/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Built app not found at $APP_PATH"
    exit 1
fi

echo "==> App built at: $APP_PATH"

# ---------- Create ZIP for distribution ----------

ZIP_NAME="${APP_NAME}.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"

echo "==> Creating distribution ZIP..."
(cd "$EXPORT_DIR" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH")

# ---------- Notarize (skip if unsigned) ----------

if [ "$SKIP_SIGN" = true ]; then
    echo "==> Skipping notarization (unsigned build)"
else
    echo "==> Submitting for notarization..."

    if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APP_SPECIFIC_PASSWORD:-}" ]; then
        echo "WARNING: Notarization env vars not set (APPLE_ID, APPLE_TEAM_ID, APP_SPECIFIC_PASSWORD)."
        echo "  Skipping notarization. The signed build may be blocked by Gatekeeper."
    else
        xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APP_SPECIFIC_PASSWORD" \
            --wait

        echo "==> Stapling notarization ticket..."
        xcrun stapler staple "$APP_PATH"

        echo "==> Re-creating ZIP after stapling..."
        rm -f "$ZIP_PATH"
        (cd "$EXPORT_DIR" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH")
    fi
fi

# ---------- Output ----------

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

echo ""
echo "========================================"
echo "  Build complete!"
echo "  ZIP:    $ZIP_PATH"
echo "  SHA256: $SHA256"
if [ -n "$VERSION" ]; then
    echo "  Version: $VERSION"
fi
if [ -n "$BUILD_NUMBER" ]; then
    echo "  Build:   $BUILD_NUMBER"
fi
echo "========================================"
