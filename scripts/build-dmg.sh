#!/bin/bash
# WhisperM8 DMG Builder
# Creates a distributable DMG file

set -e

APP_NAME="WhisperM8"
VERSION="1.2.0"
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_DIR="dist"
DMG_PATH="${DMG_DIR}/${DMG_NAME}.dmg"
STAGING_DIR="${DMG_DIR}/staging"

echo "📦 Building ${APP_NAME} DMG"
echo "==========================="
echo ""

# Build release
echo "1. Building release..."
make build

# Create staging directory
echo "2. Preparing DMG contents..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# Copy app bundle
cp -R "${APP_NAME}.app" "${STAGING_DIR}/"

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

# Remove old DMG if exists
rm -f "${DMG_PATH}"
mkdir -p "${DMG_DIR}"

# Create DMG
echo "3. Creating DMG..."
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}"

# Cleanup
rm -rf "${STAGING_DIR}"

echo ""
echo "✅ DMG erstellt: ${DMG_PATH}"
echo ""
echo "Größe: $(du -h "${DMG_PATH}" | cut -f1)"
echo ""
echo "Zum Verteilen: ${DMG_PATH} an Kollegen schicken"
