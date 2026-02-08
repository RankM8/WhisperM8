.PHONY: run build install kill clean clean-apps help dmg clean-install dev

APP_NAME = WhisperM8
APP_BUNDLE = $(APP_NAME).app

# Use Xcode toolchain for SwiftUI Preview macro support
export DEVELOPER_DIR = /Applications/Xcode.app/Contents/Developer

help:
	@echo "WhisperM8 Development Commands:"
	@echo ""
	@echo "  make dev           - [RECOMMENDED] Clean build, install, and launch"
	@echo "  make build         - Build release app bundle only"
	@echo "  make install       - Build and install to /Applications"
	@echo "  make run           - Quick debug build (creates local .app)"
	@echo ""
	@echo "  make kill          - Kill all running instances"
	@echo "  make clean         - Clean build artifacts"
	@echo "  make clean-apps    - Remove ALL app bundles (fixes Spotlight duplicates)"
	@echo "  make clean-install - Full reset (removes all app data + reinstall)"
	@echo "  make dmg           - Build distributable DMG"
	@echo ""
	@echo "Note: Use 'make dev' for development to avoid duplicate app versions."

# Development workflow: clean build, install to /Applications, launch
# This ensures only ONE app version exists (in /Applications)
dev: kill
	@echo "🔄 Development build..."
	@rm -rf "$(APP_BUNDLE)"
	@swift build -c release
	@$(MAKE) _bundle BUILD=release
	@rm -rf "/Applications/$(APP_BUNDLE)"
	@cp -R "$(APP_BUNDLE)" "/Applications/"
	@rm -rf "$(APP_BUNDLE)"
	@echo "✅ Installed to /Applications/$(APP_BUNDLE)"
	@open "/Applications/$(APP_BUNDLE)"

# Build release app bundle (leaves .app in project directory)
build:
	@echo "Building release..."
	@swift build -c release
	@$(MAKE) _bundle BUILD=release
	@echo "Done: $(APP_BUNDLE)"

# Quick debug build and run (for rapid iteration, creates local .app)
run: kill
	@echo "Building debug..."
	@swift build
	@$(MAKE) _bundle BUILD=debug
	@open "$(APP_BUNDLE)"

# Install to /Applications
install: build
	@echo "Installing to /Applications..."
	@rm -rf "/Applications/$(APP_BUNDLE)"
	@cp -R "$(APP_BUNDLE)" "/Applications/"
	@rm -rf "$(APP_BUNDLE)"
	@echo "Installed: /Applications/$(APP_BUNDLE)"

# Kill running instances
kill:
	@pkill -x $(APP_NAME) 2>/dev/null || true

# Clean build artifacts and local app bundle
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf .build $(APP_BUNDLE)
	@echo "Done"

# Remove ALL app versions from everywhere (use if Spotlight shows duplicates)
clean-apps: kill
	@echo "Removing all WhisperM8 app bundles..."
	@rm -rf "$(APP_BUNDLE)"
	@rm -rf "/Applications/$(APP_BUNDLE)"
	@rm -rf "$(HOME)/Applications/$(APP_BUNDLE)"
	@rm -rf "$(HOME)/Desktop/$(APP_BUNDLE)"
	@rm -rf "$(HOME)/Downloads/$(APP_BUNDLE)"
	@echo "✅ All app bundles removed."
	@echo ""
	@echo "If Spotlight still shows duplicates, wait a few minutes or run:"
	@echo "  sudo mdutil -E /"
	@echo ""
	@echo "Then run 'make dev' to reinstall."

# Build distributable DMG
dmg:
	@./scripts/build-dmg.sh

# Clean install (reset all data)
clean-install:
	@./scripts/clean-install.sh
	@$(MAKE) install

# Internal: Create app bundle
_bundle:
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp ".build/$(BUILD)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/"
	@cp "WhisperM8/Info.plist" "$(APP_BUNDLE)/Contents/"
	@cp "WhisperM8/Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/MenuBarIcon.png" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/MenuBarIcon@2x.png" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/AppLogo.png" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/AppLogo@2x.png" "$(APP_BUNDLE)/Contents/Resources/"
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string 'AppIcon'" "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - --entitlements "WhisperM8/WhisperM8.entitlements" --timestamp=none "$(APP_BUNDLE)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
