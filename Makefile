.PHONY: run build install kill clean clean-apps help dmg clean-install dev dev-reinstall dev-skip-onboarding mark-onboarded

APP_NAME = WhisperM8
APP_BUNDLE = $(APP_NAME).app
INSTALLED_APP = /Applications/$(APP_BUNDLE)

# Use Xcode toolchain for SwiftUI Preview macro support
export DEVELOPER_DIR = /Applications/Xcode.app/Contents/Developer

help:
	@echo "WhisperM8 Development Commands:"
	@echo ""
	@echo "  make dev               - [DEFAULT] In-place update of /Applications/$(APP_BUNDLE)."
	@echo "                            Preserves: TCC permissions (mic/accessibility/screen),"
	@echo "                            UserDefaults, Keychain (API keys), Application Support."
	@echo "  make dev-reinstall     - Alias for 'make dev' (kept for backwards compatibility)."
	@echo "  make dev-skip-onboarding - Run 'make dev' and force onboardingCompleted=true."
	@echo ""
	@echo "  make build             - Build release bundle in project directory only."
	@echo "  make install           - Build and in-place sync to /Applications."
	@echo "  make run               - Quick debug build, run from project directory (TCC isolated)."
	@echo ""
	@echo "  make kill              - Kill running instances."
	@echo "  make clean             - Clean build artifacts."
	@echo "  make clean-apps        - Remove ALL app bundles (fixes Spotlight duplicates)."
	@echo "  make clean-install     - Full reset: removes app, UserDefaults, Keychain,"
	@echo "                            Application Support, and TCC permissions. Use this"
	@echo "                            when testing onboarding/migrations or simulating a new user."
	@echo "  make dmg               - Build distributable DMG."
	@echo ""
	@echo "Workflow guidance:"
	@echo "  - 95%% of the time: 'make dev'."
	@echo "  - When testing onboarding flow / fresh-install behavior: 'make clean-install'."

# ------------------------------------------------------------------------------
# Development: in-place sync into /Applications/WhisperM8.app
# ------------------------------------------------------------------------------
# Why rsync instead of `rm -rf + cp -R`?
#   macOS TCC (Transparency, Consent, Control) tracks granted permissions per
#   bundle, keyed off the bundle's code-signing Designated Requirement *and*
#   filesystem identity. Deleting and recopying the bundle creates a new inode
#   tree, which TCC may treat as a fresh app and revoke permissions
#   (Microphone, Accessibility, Screen Recording).
#
#   `rsync -a --delete` updates the existing bundle in place: only changed
#   files are written, the bundle root inode and its xattrs are preserved,
#   and TCC continues to recognize the app as the same one.
#
#   Trailing slashes matter: `src/` (with slash) means "contents of src",
#   so the resulting destination is dst/* — a true in-place update.
#
#   The app must not be running during sync (we kill it first), otherwise
#   rsync may fail to replace the executable and codesign mismatches can
#   surface at next launch.
# ------------------------------------------------------------------------------
dev: kill
	@echo "🔄 Building $(APP_NAME) (release)..."
	@rm -rf "$(APP_BUNDLE)"
	@swift build -c release
	@$(MAKE) _bundle BUILD=release
	@echo "📦 Syncing into $(INSTALLED_APP) (preserving TCC + settings)..."
	@mkdir -p "$(INSTALLED_APP)"
	@rsync -a --delete "$(APP_BUNDLE)/" "$(INSTALLED_APP)/"
	@rm -rf "$(APP_BUNDLE)"
	@echo "✅ Updated $(INSTALLED_APP)"
	@open "$(INSTALLED_APP)"

# Backwards-compatible alias.
dev-reinstall: dev

# Force onboardingCompleted=true (useful right after a clean-install).
mark-onboarded:
	@echo "✅ Marking onboarding as completed for com.whisperm8.app"
	@defaults write com.whisperm8.app onboardingCompleted -bool true

dev-skip-onboarding: kill mark-onboarded
	@$(MAKE) dev

# ------------------------------------------------------------------------------
# Build / install (without launching)
# ------------------------------------------------------------------------------
build:
	@echo "Building release..."
	@swift build -c release
	@$(MAKE) _bundle BUILD=release
	@echo "Done: $(APP_BUNDLE)"

# Quick debug iteration: bundle stays in the project directory, gets its own
# TCC entry separate from /Applications. Useful for frontend-only changes
# where you don't want to touch the installed app's permissions at all.
run: kill
	@echo "Building debug..."
	@swift build
	@$(MAKE) _bundle BUILD=debug
	@open "$(APP_BUNDLE)"

# Same in-place strategy as `dev`, but without launching afterwards.
install: kill build
	@echo "Syncing into $(INSTALLED_APP)..."
	@mkdir -p "$(INSTALLED_APP)"
	@rsync -a --delete "$(APP_BUNDLE)/" "$(INSTALLED_APP)/"
	@rm -rf "$(APP_BUNDLE)"
	@echo "Installed: $(INSTALLED_APP)"

kill:
	@pkill -x $(APP_NAME) 2>/dev/null || true

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf .build $(APP_BUNDLE)
	@echo "Done"

# Remove every WhisperM8.app bundle on disk. Use when Spotlight shows
# duplicate icons or when a previous install ended up in an unexpected
# location.
clean-apps: kill
	@echo "Removing all WhisperM8 app bundles..."
	@rm -rf "$(APP_BUNDLE)"
	@rm -rf "$(INSTALLED_APP)"
	@rm -rf "$(HOME)/Applications/$(APP_BUNDLE)"
	@rm -rf "$(HOME)/Desktop/$(APP_BUNDLE)"
	@rm -rf "$(HOME)/Downloads/$(APP_BUNDLE)"
	@echo "✅ All app bundles removed."
	@echo ""
	@echo "If Spotlight still shows duplicates, wait a few minutes or run:"
	@echo "  sudo mdutil -E /"
	@echo ""
	@echo "Then run 'make dev' to reinstall."

dmg:
	@./scripts/build-dmg.sh

# ------------------------------------------------------------------------------
# Clean install: bewusster Reset.
# Entfernt App-Bundle, UserDefaults, Keychain, Application Support und TCC-
# Permissions. Genau das richtige Werkzeug, wenn du Onboarding-Flow oder
# Migrations-Verhalten testen willst — oder simulieren, was ein neuer User sieht.
# ------------------------------------------------------------------------------
clean-install:
	@./scripts/clean-install.sh
	@$(MAKE) install

# Internal: assemble the .app bundle from the most recent swift build output.
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
	@cp "WhisperM8/Resources/ProviderClaude.png" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/ProviderClaude@2x.png" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/ProviderCodex.png" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/ProviderCodex@2x.png" "$(APP_BUNDLE)/Contents/Resources/"
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string 'AppIcon'" "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - --entitlements "WhisperM8/WhisperM8.entitlements" --timestamp=none "$(APP_BUNDLE)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
