# WhisperM8

Native macOS dictation app with OpenAI Whisper / Groq transcription.

> **Additional documentation:** [USER_GUIDE.md](USER_GUIDE.md) - Detailed user guide

## Quick Start (TL;DR)

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
# Launch app → grant permissions → enter API key → done!
```

**Having issues (crashes, strange behavior)?**
```bash
make clean-install
```

---

## Features

- **Toggle Recording**: Press hotkey to start → speak → press again to stop and transcribe
- **Auto-Paste**: Transcribed text automatically pasted into active app
- **Cancel Recording**: Click X button in overlay to cancel (no transcription)
- **Dual-Provider**: OpenAI Whisper or Groq (faster, cheaper)
- **Menu Bar App**: Runs discreetly in the menu bar

---

## Installation

### Option A: DMG (recommended)

1. Get DMG file (from colleague or `make dmg`)
2. Open DMG
3. Drag `WhisperM8.app` to `Applications` folder
4. Launch app

### Option B: Build from source

**Requirements:**
- macOS 14.0+
- Xcode Command Line Tools: `xcode-select --install`

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

The app will be installed to `/Applications/WhisperM8.app`.

---

## Make Commands

| Command | Description |
|---------|-------------|
| `make build` | Create release build (app stays in repo) |
| `make install` | Build + install to `/Applications` |
| `make run` | Debug build + launch immediately |
| `make dmg` | Create DMG for distribution (`dist/WhisperM8-1.0.0.dmg`) |
| `make clean-install` | **Reset everything** + reinstall |
| `make kill` | Stop all running instances |
| `make clean` | Delete build artifacts |

---

## Clean Install (for issues)

If the app crashes, behaves strangely, or won't start after the first time:

```bash
make clean-install
```

**What the script does (`scripts/clean-install.sh`):**
1. Stops all WhisperM8 processes
2. Removes old app installations (`/Applications`, `~/Applications`, `~/Desktop`, `~/Downloads`)
3. Resets **all** TCC permissions (for all possible bundle IDs)
4. Deletes UserDefaults (for all possible bundle IDs)
5. Deletes Preferences files directly
6. Deletes Keychain entries (API keys)
7. Deletes cached data
8. Deletes Application Support
9. Deletes saved window state
10. Deletes Container data (if present)
11. Deletes temporary files
12. Reinstalls the app

**After this you need to:**
- Grant permissions again (Microphone + Accessibility)
- Re-enter API key
- Set hotkey

### Manual Reset (without reinstall)

If you only want to reset permissions:
```bash
./scripts/clean-install.sh
# Then manually: make install
```

---

## First Setup

### 1. Set up API Key

On first launch, the onboarding opens. You need an API key:

| Provider | Link | Price |
|----------|------|-------|
| OpenAI | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | ~$0.006/min |
| Groq | [console.groq.com/keys](https://console.groq.com/keys) | Free (rate-limited) |

### 2. Set Hotkey

Default: **Fn** (Globe key) or choose your own in Settings → Hotkey.

**Recommended:** `Control + Shift + Space`

**Note:** Option-only shortcuts don't work reliably on macOS 15+.

### 3. Permissions

The app requires two permissions:

#### Microphone
- Automatically requested on first recording attempt
- If denied: **System Settings → Privacy & Security → Microphone → WhisperM8** enable

#### Accessibility (for Auto-Paste)
- Required to send Cmd+V to other apps
- **System Settings → Privacy & Security → Accessibility → WhisperM8** enable

**If WhisperM8 doesn't appear in the list:**
1. Click "+"
2. Press `Cmd+Shift+G` and enter: `/Applications/WhisperM8.app`
3. Add and enable toggle

---

## Usage

1. **Place cursor** in a text field (TextEdit, Slack, browser, etc.)
2. **Press hotkey** to start recording
3. **Speak** your text
4. **Press hotkey again** to stop → transcription starts
5. **Text appears** automatically in text field (or clipboard)

### Cancel Recording

During recording you can cancel anytime:
- **X button** in overlay click

The recording is discarded, nothing is transcribed or pasted.

### Overlay Display

During recording, appears at bottom of screen:
- Red recording indicator with duration
- Audio level visualization
- X button to cancel (right side)
- "Transcribing..." during API call

### Settings

Via menu bar icon → "Settings...":

| Tab | Options |
|-----|---------|
| API | Choose provider, API key, language (de/en/auto) |
| Hotkey | Configure recording key |
| General | Auto-start, auto-paste on/off |

---

## Troubleshooting

### App crashes after first time / on every start

**Solution:** Clean Install
```bash
make clean-install
```

This is usually due to old settings or permissions from previous versions.

### Auto-paste not working

1. **Check Accessibility permission:**
   - System Settings → Privacy & Security → Accessibility
   - WhisperM8 must be enabled

2. **Restart app** after permission change

3. **Auto-paste disabled?** → Check Settings → General

4. **Check logs:**
   ```bash
   log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
   ```

### Microphone error / "Microphone usage description" crash

```bash
make clean-install
```

### API errors

- Key entered correctly? (no spaces at end)
- Groq rate limit reached? → Wait or switch to OpenAI
- Check network connection

### App not appearing in menu bar

- Already an instance running? `make kill`
- Check Console.app → WhisperM8 logs

### Completely reset permissions

```bash
# Only reset permissions (without reinstall)
tccutil reset Accessibility com.whisperm8.app
tccutil reset Microphone com.whisperm8.app
```

---

## Debug Logging

```bash
# Live logs while app runs
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug

# Categories:
# - AutoPaste: Paste sequence
# - Focus: App activation
# - Permission: Permissions
```

---

## Project Structure

```
whisperm8/
├── WhisperM8/                    # Source Code
│   ├── WhisperM8App.swift        # App entry, single-instance check
│   ├── Models/
│   │   └── AppState.swift        # Central state, recording + paste logic
│   ├── Views/
│   │   ├── MenuBarView.swift     # Menu bar UI
│   │   ├── SettingsView.swift    # Settings
│   │   └── OnboardingView.swift
│   ├── Windows/
│   │   └── RecordingPanel.swift  # Floating overlay + controller
│   ├── Services/
│   │   ├── AudioRecorder.swift   # AVAudioRecorder wrapper
│   │   ├── TranscriptionService.swift # OpenAI/Groq API
│   │   ├── KeychainManager.swift # Secure API key storage
│   │   └── Logger.swift          # Debug logging
│   ├── Resources/
│   │   └── AppIcon.icns          # App icon
│   └── Info.plist                # App configuration, permissions
├── scripts/
│   ├── build-dmg.sh              # Create DMG
│   └── clean-install.sh          # Reset + reinstall
├── docs/
│   ├── README.md                 # Technical documentation (this file)
│   └── USER_GUIDE.md             # User guide
├── Makefile                      # Build commands
└── Package.swift                 # Swift Package definition
```

---

## For Developers

### Important Code Locations

#### Auto-Paste Sequence (`AppState.swift`)
```
1. AXIsProcessTrusted() check
2. Get previousApp from OverlayController
3. Hide panel
4. Wait 50ms
5. targetApp.activate()
6. Poll until app active (max 1s)
7. Wait 100ms
8. Post CGEvent Cmd+V
```

#### Previous App Capture (`RecordingPanel.swift`)
The app that was active before the overlay is saved in `show()`:
```swift
previousApp = NSWorkspace.shared.frontmostApplication
```

#### Accessibility Permission Check (`AppState.swift`)
```swift
var hasAccessibilityPermission: Bool {
    AXIsProcessTrusted()
}

func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}
```

---

## License

MIT License — see [LICENSE](../LICENSE) for details.

Built by [360° Web Manager](https://360web-manager.com/)
