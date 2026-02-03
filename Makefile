.PHONY: run build install kill clean help

APP_NAME = WhisperM8
APP_BUNDLE = $(APP_NAME).app

# Use Xcode toolchain for SwiftUI Preview macro support
export DEVELOPER_DIR = /Applications/Xcode.app/Contents/Developer

help:
	@echo "WhisperM8 Commands:"
	@echo "  make build   - Build release app bundle"
	@echo "  make run     - Build debug and run"
	@echo "  make install - Build and install to /Applications"
	@echo "  make kill    - Kill running instances"
	@echo "  make clean   - Clean build artifacts"

# Build release app bundle
build:
	@echo "Building release..."
	@swift build -c release
	@$(MAKE) _bundle BUILD=release
	@echo "Done: $(APP_BUNDLE)"

# Build debug and run
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
	@echo "Installed: /Applications/$(APP_BUNDLE)"

# Kill running instances
kill:
	@pkill -x $(APP_NAME) 2>/dev/null || true

# Clean
clean:
	@echo "Cleaning..."
	@rm -rf .build $(APP_BUNDLE)
	@echo "Done"

# Internal: Create app bundle
_bundle:
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp ".build/$(BUILD)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/"
	@cp "WhisperM8/Info.plist" "$(APP_BUNDLE)/Contents/"
	@cp "WhisperM8/Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/"
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string 'AppIcon'" "$(APP_BUNDLE)/Contents/Info.plist"
