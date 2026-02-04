#!/bin/bash
# WhisperM8 Clean Install Script
# Entfernt ALLE alten Daten und installiert sauber neu
# Nutze dieses Script wenn die App crasht oder sich seltsam verhält

set -e

echo "🧹 WhisperM8 Clean Install"
echo "=========================="
echo ""
echo "Dieses Script entfernt ALLE WhisperM8-Daten von diesem Mac."
echo ""

# Kill all running instances
echo "1. Beende alle WhisperM8 Prozesse..."
pkill -9 -f "WhisperM8" 2>/dev/null || true
pkill -9 -f "whisperm8" 2>/dev/null || true
killall WhisperM8 2>/dev/null || true
sleep 1

# Remove old app bundles from all locations
echo "2. Entferne alte App-Installationen..."
rm -rf "/Applications/WhisperM8.app" 2>/dev/null || true
rm -rf "$HOME/Applications/WhisperM8.app" 2>/dev/null || true
rm -rf "$HOME/Desktop/WhisperM8.app" 2>/dev/null || true
rm -rf "$HOME/Downloads/WhisperM8.app" 2>/dev/null || true
# Auch im aktuellen Verzeichnis (falls vorhanden)
rm -rf "./WhisperM8.app" 2>/dev/null || true

# Reset TCC permissions for ALL possible bundle IDs (alte und neue)
echo "3. Setze Berechtigungen zurück..."
# Aktuelle Bundle-ID
tccutil reset Accessibility com.whisperm8.app 2>/dev/null || true
tccutil reset Microphone com.whisperm8.app 2>/dev/null || true
# Alte Bundle-IDs die möglicherweise verwendet wurden
tccutil reset Accessibility com.yourname.WhisperM8 2>/dev/null || true
tccutil reset Microphone com.yourname.WhisperM8 2>/dev/null || true
tccutil reset Accessibility com.rankm8.whisperm8 2>/dev/null || true
tccutil reset Microphone com.rankm8.whisperm8 2>/dev/null || true
tccutil reset Accessibility WhisperM8 2>/dev/null || true
tccutil reset Microphone WhisperM8 2>/dev/null || true

# Clear UserDefaults for all possible bundle IDs
echo "4. Lösche alte Einstellungen (UserDefaults)..."
defaults delete com.whisperm8.app 2>/dev/null || true
defaults delete com.yourname.WhisperM8 2>/dev/null || true
defaults delete com.rankm8.whisperm8 2>/dev/null || true
defaults delete WhisperM8 2>/dev/null || true

# Clear Preferences plist files directly
echo "5. Lösche Preferences-Dateien..."
rm -f "$HOME/Library/Preferences/com.whisperm8.app.plist" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/com.yourname.WhisperM8.plist" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/com.rankm8.whisperm8.plist" 2>/dev/null || true

# Clear Keychain items (API keys)
echo "6. Lösche Keychain-Einträge (API-Keys)..."
security delete-generic-password -s "com.whisperm8.app" 2>/dev/null || true
security delete-generic-password -s "com.yourname.WhisperM8" 2>/dev/null || true
security delete-generic-password -s "WhisperM8" 2>/dev/null || true

# Clear cached data
echo "7. Lösche Cache-Daten..."
rm -rf "$HOME/Library/Caches/com.whisperm8.app" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.yourname.WhisperM8" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/WhisperM8" 2>/dev/null || true

# Clear Application Support
echo "8. Lösche Application Support..."
rm -rf "$HOME/Library/Application Support/WhisperM8" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/com.whisperm8.app" 2>/dev/null || true

# Clear saved application state (Window-Positionen etc.)
echo "9. Lösche gespeicherten App-State..."
rm -rf "$HOME/Library/Saved Application State/com.whisperm8.app.savedState" 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/com.yourname.WhisperM8.savedState" 2>/dev/null || true

# Clear Container (falls App mal sandboxed war)
echo "10. Lösche Container-Daten..."
rm -rf "$HOME/Library/Containers/com.whisperm8.app" 2>/dev/null || true
rm -rf "$HOME/Library/Containers/com.yourname.WhisperM8" 2>/dev/null || true

# Clear any temporary files
echo "11. Lösche temporäre Dateien..."
rm -rf /tmp/WhisperM8* 2>/dev/null || true
rm -rf "$TMPDIR/WhisperM8"* 2>/dev/null || true

echo ""
echo "✅ Cleanup abgeschlossen!"
echo ""
echo "Alle WhisperM8-Daten wurden entfernt."
echo ""
echo "Nächste Schritte:"
echo "  1. make install"
echo "  2. App starten"
echo "  3. Accessibility-Berechtigung erteilen (Systemeinstellungen öffnet sich)"
echo "  4. API-Key neu eingeben"
echo "  5. Hotkey festlegen"
echo ""
