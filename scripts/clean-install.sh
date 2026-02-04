#!/bin/bash
# WhisperM8 Clean Install Script
# Removes ALL old data and installs fresh
# Use this script if the app crashes or behaves strangely

set -e

echo "🧹 WhisperM8 Clean Install"
echo "=========================="
echo ""
echo "This script removes ALL WhisperM8 data from this Mac."
echo ""

# Kill all running instances
echo "1. Stopping all WhisperM8 processes..."
pkill -9 -f "WhisperM8" 2>/dev/null || true
pkill -9 -f "whisperm8" 2>/dev/null || true
killall WhisperM8 2>/dev/null || true
sleep 1

# Remove old app bundles from all locations
echo "2. Removing old app installations..."
rm -rf "/Applications/WhisperM8.app" 2>/dev/null || true
rm -rf "$HOME/Applications/WhisperM8.app" 2>/dev/null || true
rm -rf "$HOME/Desktop/WhisperM8.app" 2>/dev/null || true
rm -rf "$HOME/Downloads/WhisperM8.app" 2>/dev/null || true
# Also in current directory (if present)
rm -rf "./WhisperM8.app" 2>/dev/null || true

# Reset TCC permissions for ALL possible bundle IDs (old and new)
echo "3. Resetting permissions..."
# Current bundle ID
tccutil reset Accessibility com.whisperm8.app 2>/dev/null || true
tccutil reset Microphone com.whisperm8.app 2>/dev/null || true
# Old bundle IDs that may have been used
tccutil reset Accessibility com.yourname.WhisperM8 2>/dev/null || true
tccutil reset Microphone com.yourname.WhisperM8 2>/dev/null || true
tccutil reset Accessibility com.rankm8.whisperm8 2>/dev/null || true
tccutil reset Microphone com.rankm8.whisperm8 2>/dev/null || true
tccutil reset Accessibility WhisperM8 2>/dev/null || true
tccutil reset Microphone WhisperM8 2>/dev/null || true

# Clear UserDefaults for all possible bundle IDs
echo "4. Deleting old settings (UserDefaults)..."
defaults delete com.whisperm8.app 2>/dev/null || true
defaults delete com.yourname.WhisperM8 2>/dev/null || true
defaults delete com.rankm8.whisperm8 2>/dev/null || true
defaults delete WhisperM8 2>/dev/null || true

# Clear Preferences plist files directly
echo "5. Deleting Preferences files..."
rm -f "$HOME/Library/Preferences/com.whisperm8.app.plist" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/com.yourname.WhisperM8.plist" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/com.rankm8.whisperm8.plist" 2>/dev/null || true

# Clear Keychain items (API keys)
echo "6. Deleting Keychain entries (API keys)..."
security delete-generic-password -s "com.whisperm8.app" 2>/dev/null || true
security delete-generic-password -s "com.yourname.WhisperM8" 2>/dev/null || true
security delete-generic-password -s "WhisperM8" 2>/dev/null || true

# Clear cached data
echo "7. Deleting cached data..."
rm -rf "$HOME/Library/Caches/com.whisperm8.app" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/com.yourname.WhisperM8" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/WhisperM8" 2>/dev/null || true

# Clear Application Support
echo "8. Deleting Application Support..."
rm -rf "$HOME/Library/Application Support/WhisperM8" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/com.whisperm8.app" 2>/dev/null || true

# Clear saved application state (window positions etc.)
echo "9. Deleting saved app state..."
rm -rf "$HOME/Library/Saved Application State/com.whisperm8.app.savedState" 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/com.yourname.WhisperM8.savedState" 2>/dev/null || true

# Clear Container (if app was ever sandboxed)
echo "10. Deleting Container data..."
rm -rf "$HOME/Library/Containers/com.whisperm8.app" 2>/dev/null || true
rm -rf "$HOME/Library/Containers/com.yourname.WhisperM8" 2>/dev/null || true

# Clear any temporary files
echo "11. Deleting temporary files..."
rm -rf /tmp/WhisperM8* 2>/dev/null || true
rm -rf "$TMPDIR/WhisperM8"* 2>/dev/null || true

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "All WhisperM8 data has been removed."
echo ""
echo "Next steps:"
echo "  1. make install"
echo "  2. Launch app"
echo "  3. Grant Accessibility permission (System Settings will open)"
echo "  4. Re-enter API key"
echo "  5. Set hotkey"
echo ""
