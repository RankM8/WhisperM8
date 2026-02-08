# WhisperM8 - User Guide

## Quick Start

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

**Having issues (crashes, old installation)?**
```bash
make clean-install
```

---

## Table of Contents

1. [Installation](#installation)
2. [First Steps](#first-steps)
3. [Usage](#usage)
4. [Settings](#settings)
5. [Troubleshooting](#troubleshooting)
6. [Make Commands](#make-commands)

---

## Installation

### Requirements

- macOS 14 (Sonoma) or newer
- Xcode Command Line Tools: `xcode-select --install`
- OpenAI API key or Groq API key

### Build from source (current supported path)

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

The app will be installed to `/Applications/WhisperM8.app`.

### First install on colleague's Mac / new Mac

**IMPORTANT:** If a different version was installed before:

```bash
make clean-install
```

This removes all old data (permissions, cache, settings) and installs fresh.

---

## First Steps

### 1. Launch App

After launch, a **microphone icon** appears in the menu bar (top right).

### 2. Grant Permissions

On first launch, two permissions are required:

#### Microphone
- Dialog appears automatically on first recording attempt
- Click "Allow"

#### Accessibility (for Auto-Paste)
- System Settings opens automatically
- Find WhisperM8 in the list and enable
- **If not in list:** Click "+" → select `/Applications/WhisperM8.app`

### 3. Set up API Key

1. Click microphone icon → "Settings..."
2. Select "API" tab
3. Choose provider:
   - **OpenAI** - Best quality (~$0.006/min)
   - **Groq** - Free (rate-limited)
4. Enter API key

**Get API keys:**
- OpenAI: https://platform.openai.com/api-keys
- Groq: https://console.groq.com/keys

### 4. Configure Hotkey

1. Select "Hotkey" tab
2. Click in the recorder field
3. Press desired key combination

**Recommended:** `Control + Shift + Space`

**Note:** Option-only shortcuts don't work reliably on macOS 15+.

---

## Usage

### Dictation (Push-to-Talk)

1. **Place cursor** in a text field (TextEdit, Slack, browser, etc.)
2. **Press hotkey** to start recording
3. **Speak** your text
4. **Press hotkey again** to stop → transcription starts
5. **Text appears** automatically in text field (or clipboard)

### Cancel Recording

During recording you can cancel anytime:
- **X button** in overlay click

The recording is discarded, nothing is transcribed.

### Overlay Display

During recording, appears at bottom of screen:
- Microphone indicator (responds to voice)
- Timer (MM:SS)
- Audio level bars
- X button to cancel
- Default position is bottom-center (40pt), but you can drag it freely on-screen
- Overlay position is saved and restored on the next recording
- You can switch between `Full` and `Mini` overlay UI in Settings → Behavior

### Menu Bar Status

| Icon | Status |
|------|--------|
| 🎤 | Ready |
| 🎤 (filled) | Recording |
| ⏳ | Transcribing |

---

## Settings

Open: Microphone icon → "Settings..." (or `Cmd + ,`)

### API Tab

| Setting | Description |
|---------|-------------|
| Provider | OpenAI or Groq |
| API Key | Your personal API key (stored securely in Keychain) |
| Language | German, English, or Auto-detect |

### Hotkey Tab

| Setting | Description |
|---------|-------------|
| Recording key | Key combination for push-to-talk |

### Behavior Tab

| Setting | Description |
|---------|-------------|
| Launch at login | Start app automatically at login |
| Auto-paste | Paste text automatically (or clipboard only) |
| Overlay UI | Choose `Full` or `Mini` overlay, and reset saved position |

### Audio Tab

| Setting | Description |
|---------|-------------|
| Input Device | Select microphone or audio input device. "System Default" uses whatever macOS has configured as default input. |

**Bluetooth-Mikrofone (AirPods, etc.):** WhisperM8 unterstützt Bluetooth-Mikrofone vollständig. Bei AirPods wechselt macOS automatisch vom Musik-Profil (A2DP) zum Telefon-Profil (HFP) - dies ist normal und wird automatisch gehandhabt. Empfehlung: "System Default" verwenden.

---

## Troubleshooting

### App crashes / won't start / behaves strangely

**Solution:** Clean Install
```bash
make clean-install
```

This removes all old data and reinstalls. After that:
1. Grant Accessibility permission
2. Re-enter API key
3. Set hotkey

### Auto-paste not working

1. **Check Accessibility permission:**
   - System Settings → Privacy & Security → Accessibility
   - WhisperM8 must be enabled

2. **Restart app** after permission change

3. **Auto-paste enabled?** → Check Settings → Behavior

### Microphone permission denied

1. System Settings → Privacy & Security → Microphone
2. Enable WhisperM8
3. Restart app

### Hotkey not working

1. Check if another app uses the same hotkey
2. Try different key combination
3. Avoid Option-only shortcuts on macOS 15+

### Audio device not appearing

1. Check if device is recognized in System Settings → Sound → Input
2. Reconnect USB device and wait 2-3 seconds
3. Restart WhisperM8
4. For Bluetooth: Ensure device is connected and in input mode

### Bluetooth-Mikrofon (AirPods) produziert keine Aufnahme

**Das Problem ist gelöst in Version 1.1.** Falls du eine ältere Version nutzt:

```bash
git pull && make install
```

**Hintergrund:** Bluetooth-Geräte wechseln beim Mikrofonzugriff vom A2DP-Profil (48kHz, Musik) zum HFP-Profil (16kHz, Telefon). WhisperM8 erkennt diesen Wechsel automatisch und passt das Audio-Format an.

### API errors

- Key entered correctly? (no spaces at end)
- Groq rate limit reached? → Wait or switch to OpenAI
- Check internet connection

### Debug Logging

```bash
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
```

---

## Make Commands

| Command | Description |
|---------|-------------|
| `make install` | Build + install to `/Applications` |
| `make run` | Debug build + launch immediately |
| `make build` | Release build (app stays in repo) |
| `make clean-install` | **Reset everything** + reinstall |
| `make kill` | Stop running instances |
| `make clean` | Delete build artifacts |

### When to use which command?

- **Normal updates:** `git pull && make install`
- **Having issues:** `make clean-install`
- **For colleagues (current path):** clone repo and run `make install`

---

## Privacy

- **API keys** are stored securely in macOS Keychain
- **Audio** is stored temporarily and deleted after transcription
- **Settings** are stored in UserDefaults
- Audio is sent to OpenAI/Groq for transcription

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd + ,` | Open settings |
| `Cmd + Q` | Quit app |
| [Your hotkey] | Toggle recording (start/stop) |
| X button | Cancel recording |

---

## License

MIT License — see [LICENSE](../LICENSE) for details.

Built by [360° Web Manager](https://360web-manager.com/)
