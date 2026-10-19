# WhisperM8

<p align="center">
  <img src="whisperm8-logo.png" alt="WhisperM8 Logo" width="128" height="128">
</p>

<p align="center">
  <strong>Native macOS app: AI-powered dictation + a tabbed session manager for Claude Code &amp; Codex CLI</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

---

## Features

WhisperM8 has two halves that share one app.

### 🎙️ Dictation

- **Toggle Recording** — Press a hotkey to start, press again to stop and transcribe
- **Auto-Paste** — Transcribed text is automatically pasted into the active app (optional)
- **Dual Provider Support** — Choose between OpenAI Whisper or Groq
- **Visual Context** — Optionally attach a screenshot (`screencapture -i`) as context for AI post-processing
- **Output Modes** — Rewrite, email, Slack, … with optional Codex-CLI post-processing
- **`whisperm8` CLI** — Transcribe audio/video files from the terminal (or let your AI agent do it — see [CLI](#cli-whisperm8))
- **Menu Bar App** — Runs quietly in your menu bar; API keys stored in the macOS Keychain

### 🤖 Agent Chats

A session manager for **Claude Code** and **Codex CLI**:

- **Chrome-like tabs** — Full PTY terminals in tabs with multi-select (Cmd/Shift-click), drag & drop reordering, and tear-off into a new window
- **Clickable links** — Cmd-click a path in the terminal to open it: code/Markdown → PhpStorm, other files → default app, folders → Finder; Cmd+Alt reveals in Finder
- **Background agents** — Spawn and attach `claude --bg` agents
- **Live status & organization** — Per-session working / awaiting-input / idle status, project grouping, pinning, and color tags
- **Transcript browsing** — Read closed Claude/Codex sessions inside the app

## Installation

### Homebrew

Install:

```bash
brew install --cask rankm8/tap/whisperm8
```

Update to the latest version:

```bash
brew upgrade --cask whisperm8
```

(Equivalent install: `brew tap rankm8/tap && brew install --cask whisperm8`.)

> WhisperM8 is distributed self-signed (no Apple Developer ID / notarization).
> The cask automatically removes the Gatekeeper quarantine attribute on install,
> so the app launches without a manual override.

## Setup

1. **Launch WhisperM8** — the setup wizard walks you through the rest.
2. **Choose a profile** — *Dictation only*, *Dictation + AI enrichment* or *Full (with Agent Chats)*. You can change it later under Settings → General.
3. **Grant permissions** — Microphone (recording) and Accessibility (auto-paste).
4. **Set your hotkey** — e.g. `Control + Shift + Space`.
5. **Enter an API key** — from [Groq](https://console.groq.com/keys) (free tier) or [OpenAI](https://platform.openai.com/api-keys); stored in the macOS Keychain.
6. **Connect Claude Code and Codex** (AI enrichment and Agent Chats only) — the wizard detects existing installations. If a CLI is missing, it offers to install it via Homebrew (`brew install --cask claude-code` / `codex`) after you confirm; Codex is connected right in the wizard (*Sign in with ChatGPT*); Claude Code walks you through signing in the first time you start a chat.
7. **Try it** — the last step records a short test dictation.

## Usage

1. Place your cursor in any text field
2. **Press your hotkey** to start recording
3. Speak your text
4. **Press the hotkey again** to stop and transcribe
5. Text appears automatically (or is copied to clipboard)

**Cancel Recording:** Click the X button in the overlay.

## CLI: `whisperm8`

The app installs a command-line companion at `~/.local/bin/whisperm8` (a symlink to the app binary, refreshed on every launch). It transcribes audio **and video** files using the same API key the app stores in the Keychain — no separate login.

```bash
whisperm8 transcribe recording.m4a                     # audio → text (stdout)
whisperm8 transcribe talk.mp4 -f srt -o talk.srt       # video → subtitles
whisperm8 transcribe call.mp3 --mode clean -o call.txt # + post-processing mode
whisperm8 transcribe workshop.mp4 --dry-run            # duration + cost estimate
```

Formats: `txt`, `json`, `srt`, `vtt` · providers: Groq (default) and OpenAI · long files are chunked at silence boundaries and stitched back together automatically. Run `whisperm8 --help` for all options.

**Agent skill:** Settings → *CLI & Skills* provides an agent skill (SKILL.md) that teaches Claude Code, Claude.ai, or ChatGPT how to drive the CLI — one click installs it to `~/.claude/skills/`, or copy/save it for other assistants. Source of truth: [WhisperM8/Resources/whisperm8-cli-skill.md](WhisperM8/Resources/whisperm8-cli-skill.md).

## API Providers

| Provider | Price | Speed | Link |
|----------|-------|-------|------|
| **Groq** | Free (rate-limited) | Very Fast | [Get API Key](https://console.groq.com/keys) |
| **OpenAI** | ~$0.006/min | Fast | [Get API Key](https://platform.openai.com/api-keys) |

## Troubleshooting

For detailed troubleshooting, see [docs/README.md](docs/README.md).

## Development

Building from source, `make` targets, resets and releases are for contributors only — see
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). End users install and update exclusively via Homebrew.

## Documentation

- [Technical Documentation](docs/README.md) — Architecture, troubleshooting, developer guide
- [User Guide](docs/USER_GUIDE.md) — Detailed usage instructions
- [Development](docs/DEVELOPMENT.md) — Build from source, make targets, releasing

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
