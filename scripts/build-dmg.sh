#!/bin/bash
# WhisperM8 DMG Builder
# Creates a distributable DMG file and optionally signs/notarizes it.

set -euo pipefail

APP_NAME="WhisperM8"
APP_BUNDLE="${APP_NAME}.app"
INFO_PLIST="WhisperM8/Info.plist"
ENTITLEMENTS="WhisperM8/WhisperM8.entitlements"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}")
DMG_DIR="dist"
DMG_VERSIONED_PATH="${DMG_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_LATEST_PATH="${DMG_DIR}/${APP_NAME}.dmg"
STAGING_DIR="${DMG_DIR}/staging"

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"

echo "📦 Building ${APP_NAME} DMG (${VERSION})"
echo "======================================="
echo ""

# Build release
echo "1. Building release app bundle..."
make build

# Re-sign with Developer ID when configured. Otherwise keep the ad-hoc signature.
if [[ -n "${DEVELOPER_ID_APPLICATION}" ]]; then
    echo "2. Signing app with Developer ID..."
    codesign --force --deep --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${DEVELOPER_ID_APPLICATION}" \
        "${APP_BUNDLE}"
else
    echo "2. Developer ID not configured; keeping ad-hoc signature."
    echo "   WARNING: Unsigned/ad-hoc builds are blocked by Gatekeeper on other Macs."
fi

echo "3. Verifying app signature..."
codesign --verify --deep --strict --verbose=4 "${APP_BUNDLE}"

# Create staging directory
echo "4. Preparing DMG contents..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
mkdir -p "${DMG_DIR}"

# Copy app bundle
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"

# Create Applications symlink
ln -s /Applications "${STAGING_DIR}/Applications"

# Create README
cat > "${STAGING_DIR}/LIES MICH.txt" << 'EOF'
WhisperM8 Installation
======================

1. Ziehe WhisperM8.app in den Applications-Ordner
2. Starte WhisperM8 aus dem Applications-Ordner
3. Erteile die Berechtigungen (Mikrofon + Bedienungshilfen)
4. Gib deinen API-Key ein (OpenAI oder Groq)
5. Fertig! Nutze deinen Hotkey zum Diktieren.

Bei Problemen: ./scripts/clean-install.sh ausführen

Docs: https://github.com/RankM8/whisperm8
EOF

# Remove old DMGs if they exist
rm -f "${DMG_VERSIONED_PATH}" "${DMG_LATEST_PATH}"

# Create DMG
echo "5. Creating DMG..."
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDZO \
    "${DMG_VERSIONED_PATH}"

# Sign DMG for distribution if we have Developer ID
if [[ -n "${DEVELOPER_ID_APPLICATION}" ]]; then
    echo "6. Signing DMG..."
    codesign --force --timestamp \
        --sign "${DEVELOPER_ID_APPLICATION}" \
        "${DMG_VERSIONED_PATH}"

    # Optional notarization
    if [[ -n "${NOTARYTOOL_PROFILE}" ]]; then
        echo "7. Notarizing DMG with keychain profile '${NOTARYTOOL_PROFILE}'..."
        xcrun notarytool submit "${DMG_VERSIONED_PATH}" \
            --keychain-profile "${NOTARYTOOL_PROFILE}" \
            --wait
        xcrun stapler staple "${DMG_VERSIONED_PATH}"
    elif [[ -n "${APPLE_ID}" && -n "${APPLE_TEAM_ID}" && -n "${APPLE_APP_SPECIFIC_PASSWORD}" ]]; then
        echo "7. Notarizing DMG with Apple ID credentials..."
        xcrun notarytool submit "${DMG_VERSIONED_PATH}" \
            --apple-id "${APPLE_ID}" \
            --team-id "${APPLE_TEAM_ID}" \
            --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
            --wait
        xcrun stapler staple "${DMG_VERSIONED_PATH}"
    else
        echo "7. Notarization credentials not configured; skipping notarization."
    fi
fi

# Create stable filename for GitHub latest-download links
cp "${DMG_VERSIONED_PATH}" "${DMG_LATEST_PATH}"

# Cleanup
rm -rf "${STAGING_DIR}"

echo ""
echo "✅ DMG erstellt:"
echo "   - ${DMG_VERSIONED_PATH}"
echo "   - ${DMG_LATEST_PATH}"
echo ""
echo "Größe: $(du -h "${DMG_VERSIONED_PATH}" | cut -f1)"
