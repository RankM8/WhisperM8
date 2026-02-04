#!/bin/bash
# WhisperM8 Clean Install Script
# Entfernt alle alten Daten und installiert sauber neu

set -e

echo "🧹 WhisperM8 Clean Install"
echo "=========================="
echo ""

# Kill all running instances
echo "1. Beende alle WhisperM8 Prozesse..."
pkill -9 -f "WhisperM8" 2>/dev/null || true
pkill -9 -f "whisperm8" 2>/dev/null || true
sleep 1

# Remove old app bundles
echo "2. Entferne alte App-Installationen..."
rm -rf "/Applications/WhisperM8.app" 2>/dev/null || true
rm -rf "$HOME/Applications/WhisperM8.app" 2>/dev/null || true

# Reset TCC permissions for all possible bundle IDs
echo "3. Setze Berechtigungen zurück..."
tccutil reset Accessibility com.whisperm8.app 2>/dev/null || true
tccutil reset Accessibility com.yourname.WhisperM8 2>/dev/null || true
tccutil reset Microphone com.whisperm8.app 2>/dev/null || true
tccutil reset Microphone com.yourname.WhisperM8 2>/dev/null || true

# Clear UserDefaults
echo "4. Lösche alte Einstellungen..."
defaults delete com.whisperm8.app 2>/dev/null || true
defaults delete com.yourname.WhisperM8 2>/dev/null || true

# Clear Keychain items (API keys) - optional, commented out
# echo "5. Lösche gespeicherte API-Keys..."
# security delete-generic-password -s "com.whisperm8.app" 2>/dev/null || true

# Clear any cached data
echo "5. Lösche Cache-Daten..."
rm -rf "$HOME/Library/Caches/com.whisperm8.app" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.yourname.WhisperM8" 2>/dev/null || true

# Clear saved application state
echo "6. Lösche gespeicherten App-State..."
rm -rf "$HOME/Library/Saved Application State/com.whisperm8.app.savedState" 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/com.yourname.WhisperM8.savedState" 2>/dev/null || true

echo ""
echo "✅ Cleanup abgeschlossen!"
echo ""
echo "Nächste Schritte:"
echo "  1. make install    (oder WhisperM8.app nach /Applications ziehen)"
echo "  2. App starten"
echo "  3. Accessibility-Berechtigung erteilen wenn gefragt"
echo "  4. API-Key eingeben"
echo ""
