.PHONY: run build install install-cli kill clean clean-apps help dmg clean-install dev dev-reinstall _install_bundle

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
	@echo ""
	@echo "  make build             - Build release bundle in project directory only."
	@echo "  make install           - Build and in-place sync to /Applications."
	@echo "  make install-cli       - Symlink ~/.local/bin/whisperm8 → installed app binary."
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
#   The app must not be running during sync, otherwise rsync may fail to
#   replace the executable and codesign mismatches can surface at next launch.
#   The kill happens LATE — after the build, right before the sync: so the
#   app stays usable (and keeps flushing its stores) during the whole build,
#   and the actual downtime shrinks to the ~1-2s of kill+rsync+launch.
#
# Why `env -u CLAUDE_CONFIG_DIR -u CLAUDECODE open`?
#   `open` forwards the caller's environment to the launched app. A dev shell
#   sourcing ccs.zsh exports CLAUDE_CONFIG_DIR (active Claude account profile);
#   inherited by WhisperM8 it would shift every spawned `claude` to the wrong
#   projects/ root — resumes of main-stamped sessions then fail with
#   "No conversation found" (incident 2026-07-13). The app strips the variable
#   too (LoginShellEnvironment); this is belt-and-braces at the launch site.
# ------------------------------------------------------------------------------
dev: install
	@env -u CLAUDE_CONFIG_DIR -u CLAUDECODE open "$(INSTALLED_APP)"

# Backwards-compatible alias.
dev-reinstall: dev

# ------------------------------------------------------------------------------
# Build / install (without launching)
# ------------------------------------------------------------------------------
# Resource-Accessor-Patch (Details: scripts/patch-resource-accessors.sh):
# Der zweite `swift build` laeuft nur noch, wenn das Skript tatsaechlich etwas
# gepatcht hat (Exit 3). Im Normalfall sind die Accessors vom letzten Lauf
# noch gepatcht + schreibgeschuetzt (444) — der erste Build linkt dann bereits
# die gepatchte Variante, und der komplette zweite Build-Durchlauf entfaellt.
# WICHTIG: beide Builds mit --disable-sandbox (dieselben Flags wie der
# fruehere finale Build) — bei konsistenten Flags laesst SwiftPM die
# schreibgeschuetzten Accessors in Ruhe (verifiziert: Folge-Build 0.17s).
# Self-Healing: Wird eine 444-Accessor-Datei extern angefasst (mtime!),
# will SwiftPM sie beim Planen neu schreiben und scheitert hart mit
# "error: invalid access". Dann: entsperren, einmal regenerieren lassen —
# der Patch+Rebuild-Pfad (Exit 3) greift danach automatisch.
build:
	@echo "🔨 Building $(APP_NAME) (release)..."
	@rm -rf "$(APP_BUNDLE)"
	@swift build -c release --disable-sandbox || { \
		echo "♻️  Build fehlgeschlagen — entsperre Resource-Accessors und versuche Regeneration (Self-Healing)..."; \
		find .build -path "*/release/*/DerivedSources/resource_bundle_accessor.swift" -exec chmod u+w {} + 2>/dev/null || true; \
		swift build -c release --disable-sandbox; \
	}
	@scripts/patch-resource-accessors.sh release; status=$$?; \
	if [ $$status -eq 3 ]; then \
		echo "♻️  Resource-Accessors frisch gepatcht — Rebuild..."; \
		swift build -c release --disable-sandbox; \
	elif [ $$status -ne 0 ]; then \
		exit $$status; \
	fi
	@$(MAKE) _bundle BUILD=release
	@echo "Done: $(APP_BUNDLE)"

# Quick debug iteration: bundle stays in the project directory, gets its own
# TCC entry separate from /Applications. Useful for frontend-only changes
# where you don't want to touch the installed app's permissions at all.
run:
	@echo "Building debug..."
	@rm -rf "$(APP_BUNDLE)"
	@swift build
	@$(MAKE) _bundle BUILD=debug
	@$(MAKE) kill
	@env -u CLAUDE_CONFIG_DIR -u CLAUDECODE open "$(APP_BUNDLE)"

# Same in-place strategy as `dev`, but without launching afterwards.
# Kill erst NACH dem Build (unmittelbar vor dem Sync) — minimale Downtime.
install: build
	@$(MAKE) kill
	@$(MAKE) _install_bundle
	@echo "✅ Installed: $(INSTALLED_APP)"

# ------------------------------------------------------------------------------
# CLI-Symlink: ~/.local/bin/whisperm8 → App-Binary im Bundle.
# Die App legt diesen Symlink beim Start ohnehin automatisch an
# (CLISymlinkInstaller); dieses Target ist die manuelle Variante.
# Da der Symlink auf dasselbe signierte Binary zeigt, nutzt die CLI denselben
# Keychain-Eintrag wie die App (kein erneuter Prompt).
# ------------------------------------------------------------------------------
install-cli:
	@mkdir -p "$(HOME)/.local/bin"
	@ln -sf "$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" "$(HOME)/.local/bin/whisperm8"
	@echo "✅ CLI verlinkt: $(HOME)/.local/bin/whisperm8 → $(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)"
	@echo "   Stelle sicher, dass ~/.local/bin im PATH ist (claude findet die CLI dann automatisch)."

_install_bundle:
	@echo "📦 Syncing into $(INSTALLED_APP) (preserving TCC + settings)..."
	@mkdir -p "$(INSTALLED_APP)"
	@rsync -a --delete "$(APP_BUNDLE)/" "$(INSTALLED_APP)/"
	@rm -rf "$(APP_BUNDLE)"
	@# LaunchServices muss den Bundle neu indexieren, sonst werden Info.plist-
	@# Änderungen (z. B. neue UTExportedTypeDeclarations für Drag-Drop) bei
	@# einem in-place rsync nicht aktiv. `-f` zwingt Re-Registrierung.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALLED_APP)" 2>/dev/null || true

# Nur GUI-Instanzen beenden — und zwar graceful:
# - Match ueber argv[0] (ps args) statt Prozessname: `pkill -x $(APP_NAME)`
#   traefe auch die Agent-Supervisor (gleiches Binary via
#   Bundle.main.executablePath — SIGTERM heisst dort "laufenden Codex-Turn
#   abbrechen", siehe AgentSuperviseCommand). Supervisor werden ueber ihr
#   `agent-supervise`-Argument ausgenommen; CLI-Aufrufe laufen ueber den
#   lowercase-Symlink ~/.local/bin/whisperm8 und matchen case-sensitiv nicht.
#   argv[0]-Match faengt auch app-gestartete Instanzen, deren Prozessname
#   auf manchen Systemen nicht "$(APP_NAME)" ist (frueherer pkill-x-Blindfleck).
# - SIGTERM zuerst: der AppDelegate leitet es in einen regulaeren AppKit-Quit
#   um (inkl. Flush der debounced Stores) — sonst verlieren frisch angelegte
#   Chats/Tab-State ihre Persistenz.
# - Warten, bis der Prozess wirklich weg ist: der Single-Instance-Check der
#   frisch gestarteten App und der rsync brauchen ein totes Bundle. SIGKILL
#   nur als letzte Eskalation nach 5 s.
GUI_PIDS = ps -axww -o pid=,args= | awk '$$2 ~ /\/$(APP_NAME)$$/ && $$0 !~ /agent-supervise/ {print $$1}'

kill:
	@pids="$$($(GUI_PIDS))"; \
	if [ -n "$$pids" ]; then \
		echo "🛑 Stopping $(APP_NAME) (SIGTERM, graceful)..."; \
		kill $$pids 2>/dev/null || true; \
		i=0; \
		while [ -n "$$($(GUI_PIDS))" ] && [ $$i -lt 50 ]; do \
			sleep 0.1; i=$$((i+1)); \
		done; \
		leftover="$$($(GUI_PIDS))"; \
		if [ -n "$$leftover" ]; then \
			echo "⚠️  $(APP_NAME) reagiert nicht auf SIGTERM — SIGKILL."; \
			kill -9 $$leftover 2>/dev/null || true; \
		fi; \
	fi

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

dmg: kill
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
	@cp "WhisperM8/Resources/whisperm8-cli-skill.md" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/whisperm8-agent-skill.md" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/whisperm8-agent-skill-ref-playwright-browser-qa.md" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/whisperm8-agent-skill-ref-1password-cli.md" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/whisperm8-agent-skill-ref-claude-workflows.md" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/whisperm8-chats-skill.md" "$(APP_BUNDLE)/Contents/Resources/"
	@cp "WhisperM8/Resources/whisperm8-gpt-coworker-skill.md" "$(APP_BUNDLE)/Contents/Resources/"
	@# SwiftPM-generierte Resource-Bundles (z. B. KeyboardShortcuts_KeyboardShortcuts.bundle)
	@# in Contents/Resources/ kopieren - wo macOS-Apps Ressourcen erwarten und
	@# codesign sie als gesealte Inhalte akzeptiert. Damit `Bundle.module` sie hier
	@# auch findet, wird der generierte Accessor von scripts/patch-resource-accessors.sh
	@# auf resourceURL gepatcht (siehe dev/build). Read-only Files vom letzten
	@# Build vorab loeschen, sonst schlaegt `cp` mit Permission denied fehl.
	@for bundle in .build/$(BUILD)/*.bundle; do \
		if [ -e "$$bundle" ]; then \
			bundle_name=$$(basename "$$bundle"); \
			rm -rf "$(APP_BUNDLE)/Contents/Resources/$$bundle_name"; \
			cp -R "$$bundle" "$(APP_BUNDLE)/Contents/Resources/"; \
		fi; \
	done
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string 'AppIcon'" "$(APP_BUNDLE)/Contents/Info.plist"
	@# Codesign identity: prefer the persistent local-dev cert if it
	@# exists (created via `scripts/setup-codesign-cert.sh`), else fall
	@# back to ad-hoc. The persistent cert keeps the binary's code
	@# identity stable across rebuilds so macOS TCC grants
	@# ("Files and Folders" permissions) survive `make dev`. Ad-hoc
	@# signing re-prompts the user on every rebuild because the
	@# identity is bound to the binary hash.
	@CODESIGN_ID=$$(security find-identity -p codesigning -v 2>/dev/null | grep "WhisperM8 Local Dev" | awk -F'"' '{print $$2}' | head -1); \
	if [ -z "$$CODESIGN_ID" ]; then \
		echo "ℹ Signing ad-hoc (run scripts/setup-codesign-cert.sh for stable TCC grants)..."; \
		CODESIGN_ID="-"; \
	else \
		echo "✔ Signing with persistent identity: $$CODESIGN_ID"; \
	fi; \
	codesign --force --deep --sign "$$CODESIGN_ID" --entitlements "WhisperM8/WhisperM8.entitlements" --timestamp=none "$(APP_BUNDLE)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
