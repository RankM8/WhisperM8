# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WhisperM8 is a native macOS menu bar application for speech-to-text transcription using AI providers (OpenAI Whisper, Groq). Built with Swift 5.9 and SwiftUI, targeting macOS 14+ (Sonoma).

## Build Commands

```bash
make dev          # Recommended: clean build, install to /Applications, launch
make build        # Release build only (creates local .app)
make run          # Quick debug build for rapid iteration
make install      # Build + install to /Applications
make dmg          # Create distributable DMG
make clean        # Clean build artifacts
make clean-apps   # Remove all app bundles (fixes Spotlight duplicates)
make clean-install # Full reset (removes all app data + reinstall)
make kill         # Kill running instances
```

For development, always use `make dev` to avoid duplicate app versions in Spotlight.

## Debugging

View live logs:
```bash
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
```

## Architecture

The app follows a unidirectional data flow pattern:

```
Hotkey Event → AppState → AudioRecorder/TranscriptionService → UI Update
```

### Key Components

- **WhisperM8App.swift** - Entry point, sets up MenuBarExtra, Settings/Onboarding windows, and global hotkey listeners
- **Models/AppState.swift** - Central `@Observable` state managing recording lifecycle, transcription coordination, and clipboard operations
- **Models/TranscriptionProvider.swift** - Provider/model enums with settings migration logic
- **Services/AudioRecorder.swift** - AVAudioEngine-based recording with real-time audio levels, outputs M4A (16kHz mono AAC)
- **Services/TranscriptionService.swift** - Protocol-based API clients for OpenAI and Groq transcription endpoints
- **Services/AudioDuckingManager.swift** - Reduces system volume during recording (see [docs/AUDIO_DUCKING.md](docs/AUDIO_DUCKING.md))
- **Windows/RecordingPanel.swift** - Non-activating NSPanel overlay with OverlayController managing lifecycle
- **Services/KeychainManager.swift** - Secure API key storage using macOS Keychain

### Recording Flow

1. Hotkey press → `AppState.startRecording()` → AudioRecorder starts, overlay panel appears
2. Audio captured via AVAudioEngine tap with RMS level calculation
3. Hotkey release → `AppState.stopRecording()` → Recording stops, audio sent to transcription API
4. Result copied to clipboard, optionally auto-pasted via CGEvent to previously active app

### LSUIElement Considerations

The app runs as a menu bar-only application (LSUIElement=true). This causes focus issues with text fields in windows. The workaround is temporarily switching to `.regular` activation policy when Settings/Onboarding windows appear.

## Dependencies

Managed via Swift Package Manager (Package.swift):
- **KeyboardShortcuts** (1.16.1) - Global hotkey detection
- **Defaults** (8.2.0) - Type-safe UserDefaults
- **LaunchAtLogin-Modern** (1.1.0) - Launch at startup
- **ISSoundAdditions** (2.0.0) - System volume control for audio ducking

## Build Environment

Requires Xcode toolchain for SwiftUI Preview macro support:
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The Makefile sets this automatically.
