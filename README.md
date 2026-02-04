# WhisperM8

<p align="center">
  <img src="whisperm8-logo.png" alt="WhisperM8 Logo" width="128" height="128">
</p>

<p align="center">
  <strong>Native macOS dictation app with AI-powered transcription</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

---

## Features

- **Toggle Recording** — Press hotkey to start, press again to stop and transcribe
- **Auto-Paste** — Transcribed text automatically pasted into active app (optional)
- **Dual Provider Support** — Choose between OpenAI Whisper or Groq
- **Menu Bar App** — Runs quietly in your menu bar
- **Real-time Feedback** — Visual recording indicator with audio levels
- **Secure** — API keys stored in macOS Keychain

## Installation

### Option 1: Download DMG

Download the latest release from the [Releases](https://github.com/RankM8/whisperm8/releases) page.

### Option 2: Build from Source

```bash
git clone https://github.com/RankM8/whisperm8.git
cd whisperm8
make install
```

**Requirements:**
- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`)

## Setup

1. **Launch WhisperM8** — The setup wizard will guide you through configuration
2. **Grant Permissions** — Microphone (for recording) and Accessibility (for auto-paste)
3. **Set Your Hotkey** — Choose a key combination (e.g., `Control + Shift + Space`)
4. **Enter API Key** — Get one from [OpenAI](https://platform.openai.com/api-keys) or [Groq](https://console.groq.com/keys) (free tier available)
5. **Configure Auto-Paste** — Choose whether to auto-paste or just copy to clipboard

## Usage

1. Place your cursor in any text field
2. **Press your hotkey** to start recording
3. Speak your text
4. **Press the hotkey again** to stop and transcribe
5. Text appears automatically (or is copied to clipboard)

**Cancel Recording:** Click the X button in the overlay or press ESC.

## API Providers

| Provider | Price | Speed | Link |
|----------|-------|-------|------|
| **Groq** | Free (rate-limited) | Very Fast | [Get API Key](https://console.groq.com/keys) |
| **OpenAI** | ~$0.006/min | Fast | [Get API Key](https://platform.openai.com/api-keys) |

## Troubleshooting

Having issues? Run a clean install:

```bash
make clean-install
```

This removes all app data and reinstalls fresh. You'll need to reconfigure permissions and settings.

For detailed troubleshooting, see [docs/README.md](docs/README.md).

## Development

```bash
# Build and run (debug)
make run

# Build release
make build

# Install to /Applications
make install

# Create DMG for distribution
make dmg

# Clean install (reset everything)
make clean-install
```

## Documentation

- [Technical Documentation](docs/README.md) — Architecture, troubleshooting, developer guide
- [User Guide](docs/USER_GUIDE.md) — Detailed usage instructions

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Built and open-sourced by [360WebManager](https://360web-manager.com/) — Your partner for web development and digital solutions.

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Made with ❤️ for the macOS community
</p>
