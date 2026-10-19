---
description: End-User-Anleitung für WhisperM8 (Installation per Homebrew, Einrichtung, Diktat, Agent Chats, Einstellungen, Fehlerbehebung, Datenschutz)
description_long: |
  Ausführlicher Nutzer-Leitfaden: Installation und Updates nur über den Homebrew-Cask,
  Einrichtungsassistent mit Nutzungsprofilen, Diktat-Workflow (Hotkey, Ausgabemodi,
  Auto-Paste), Agent Chats (Projekte, Chats, Status, Schließen/Stoppen/Archivieren,
  Fortsetzen nach Neustart), Einstellungsseiten mit den Namen aus der App,
  nicht-destruktive Fehlerbehebung und lokale Datenablage. Zielgruppe sind Endnutzer;
  Entwicklerthemen stehen in DEVELOPMENT.md.
updated: 2026-10-19
---

# WhisperM8 - User Guide

## Quick Start

```bash
brew install --cask rankm8/tap/whisperm8
```

Launch WhisperM8 from Applications — the setup wizard does the rest. Updates:
`brew upgrade --cask whisperm8`.

---

## Table of Contents

1. [Installation](#installation)
2. [First Steps](#first-steps)
3. [Dictation](#dictation)
4. [Agent Chats](#agent-chats)
5. [Settings](#settings)
6. [Troubleshooting](#troubleshooting)
7. [Privacy and local data](#privacy-and-local-data)
8. [Keyboard Shortcuts](#keyboard-shortcuts)

---

## Installation

### Requirements

- macOS 14 (Sonoma) or newer
- [Homebrew](https://brew.sh)
- A Groq or OpenAI API key for transcription
- Optional: a ChatGPT account (AI enrichment via Codex) and a Claude account (Agent Chats)

### Install and update

```bash
brew install --cask rankm8/tap/whisperm8     # install
brew upgrade --cask whisperm8                # update
```

Homebrew is the only supported way to install and update WhisperM8. The app is self-signed; the cask
removes the Gatekeeper quarantine flag for you, so no manual override is needed. A self-built copy
from the source code is not updated by Homebrew — remove it before installing the cask.

---

## First Steps

The setup wizard opens on first launch. You can leave it at any step and come back later through
Settings.

1. **Profile** — choose what you want to use. You can switch any time under Settings → General.

   | Profile | What you get |
   |---|---|
   | Dictation only | Menu-bar app, speech to text |
   | Dictation + AI enrichment | Plus output modes like Clean, Email or Slack (uses Codex) |
   | Full (with Agent Chats) | Plus the Agent Chats window for Claude Code and Codex (Dock app) |

2. **Permissions** — Microphone (recording) and Accessibility (auto-paste, selected text). The wizard
   opens the right page in System Settings. If WhisperM8 is missing in the Accessibility list, click
   "+", press `Cmd+Shift+G`, enter `/Applications/WhisperM8.app` and enable it.
3. **Hotkey** — click the recorder field and press a key combination, e.g. `Control + Shift + Space`.
   Avoid shortcuts made only of Option keys.
4. **API key** — choose Groq (free tier, rate-limited) or OpenAI and paste your key from
   [console.groq.com/keys](https://console.groq.com/keys) or
   [platform.openai.com/api-keys](https://platform.openai.com/api-keys). It is stored in the macOS
   Keychain.
5. **Language** — the language you usually speak, or auto-detect.
6. **Claude Code and Codex** (AI enrichment and Agent Chats only) — the wizard detects existing
   installations (native installer, Homebrew, npm and common version managers). If one is missing,
   it offers to install it with Homebrew (`brew install --cask claude-code` / `codex`) after you
   confirm. Codex is connected right in the wizard (*Sign in with ChatGPT*); Claude Code walks you
   through signing in the first time you start a chat.
7. **Test** — record a short sentence to check that everything works.

---

## Dictation

1. Place the cursor in any text field (TextEdit, Slack, browser …).
2. Press your hotkey to start recording, speak, press it again to stop.
   With *Hold to talk* you keep the hotkey pressed while speaking instead.
3. The text is pasted into the app that was in front (with auto-paste) and is always also on the
   clipboard.

**Cancel:** click the X in the overlay. Nothing is transcribed.

**Overlay:** shows level, timer and buttons at the bottom of the screen. Drag it anywhere; double-click
resets the position. Full or Mini layout under Settings → Recording.

**Output modes:** with AI enrichment you pick a mode (e.g. Clean, Email, Slack) in the overlay or the
menu bar. The transcript is then rewritten by Codex using your ChatGPT login. Modes, templates and a
test lab live under Settings → AI Output.

**Context:** optionally the selected text and screenshots or a short screen clip are passed to the
mode, so that e.g. *Reply* knows what you are answering (Settings → Context & Privacy).

**Menu bar:** start/stop recording, switch modes, open Agent Chats and Settings.

---

## Agent Chats

Agent Chats (profile *Full*) host the real Claude Code and Codex command-line tools in tabs — the same
tools you would run in Terminal, with their own sign-in, models and commands.

### Projects and chats

- **Add a project:** *Add Project…* in the sidebar and choose a folder. Chats always start in their
  project's folder.
- **New chat:** the + button next to the tabs or the project's context menu — *New Claude Chat* or
  *New Codex Chat*. Advanced options (background agents, agent views, sub-agent library) appear once
  you turn on *Advanced agent features* in Settings → Agent Chats.
- **Workspaces:** place several chats of a project side by side in a grid and switch between them with
  `Ctrl+Tab`.

### Status

The dot in the sidebar, on the tab and in the chat header shows the same status everywhere:

| Status | Meaning |
|---|---|
| Green | Working |
| Amber | Waiting for you — a question, a permission or a plan to approve |
| Grey | Ready — the turn is finished, waiting for your next prompt |
| Red ring | Error |

VoiceOver reads the status out loud. You can get a notification and a sound when an agent finishes
(Settings → Agent Chats → Notifications & Sounds).

### Close, stop, archive

| Action | What happens |
|---|---|
| **Close Tab** | Only hides the tab. The chat keeps running and stays in the sidebar. |
| **Stop** | Ends the chat's process. The conversation is kept and can be resumed later. |
| **Archive** | Moves a chat out of the sidebar into the archive; *Restore* brings it back. |

WhisperM8 asks before an action interrupts a chat that is still working.

### Quit and resume

- **Cmd+Q** with a chat that is working or waiting asks first: *Quit and Reopen Later* reopens those
  chats the next time WhisperM8 starts, so you can pick up where they stopped. The running turn itself
  ends when the app quits.
- **Log out, restart or shut down** never asks, but marks all running chats to reopen.
- **After a crash** WhisperM8 reopens the chats that were running.

Resumed chats continue the same conversation (`--resume`); nothing is lost except the turn that was
in progress.

### Accounts

Several Claude accounts can be set up under Settings → Accounts; each chat runs in one of them and can
be moved to another via its context menu. A chat that is working is moved after its turn.

---

## Settings

Open from the menu bar → *Settings…* or with `Cmd + ,`.

| Page | What you find there |
|---|---|
| **Recording** | Hotkey (hold or toggle), input device, audio ducking, overlay layout and position, auto-paste |
| **Transcription** | Provider (Groq/OpenAI), API key, model and price, spoken language |
| **AI Output** | ChatGPT connection for Codex, output modes, templates, test lab |
| **Context & Privacy** | Selected text and visual context (screenshots, screen clips), deleting context files |
| **Agent Chats** | Default chat type and project folder, automatic titles, tab swipe, summaries, notifications, terminal |
| **Accounts** | Claude accounts, MCP servers across accounts |
| **Hooks** | How chats report their state to WhisperM8 (advanced) |
| **CLI & Skills** | The `whisperm8` command-line tool and agent skills |
| **General** | Usage profile, start at login, appearance, automatic update check |
| **Permissions** | Status of microphone, accessibility and screen recording, with links to System Settings |
| **About** | Version and update |

Experimental features (GPT backend, ChatGPT-subscription transcription, Codex Voice Agent, Jarvis board)
are grouped separately and are off by default.

**Bluetooth microphones (AirPods etc.):** macOS switches the headset to its phone profile while the
microphone is in use; the sound gets thinner, that is normal. WhisperM8 adapts to the format change.
If an explicitly chosen Bluetooth device disappears, recording falls back to *System Default*.

---

## Troubleshooting

### App crashes, won't start or behaves strangely

1. Update: `brew upgrade --cask whisperm8`.
2. Quit WhisperM8 and launch it again. Make sure only one copy exists (Spotlight, Activity Monitor) —
   remove any self-built copy.
3. Check the permissions under Settings → Permissions.
4. Still broken? Reinstall the app without touching your data: `brew reinstall --cask whisperm8`.
5. Report the problem with the crash report (Console → Crash Reports) and recent logs:
   `log show --last 10m --predicate 'subsystem == "com.whisperm8.app"'`.

A **full reset** deletes your chats, projects, custom modes, reports and API keys. It is a last
resort for developers and described in [DEVELOPMENT.md](DEVELOPMENT.md#full-reset-destructive) —
back up `~/Library/Application Support/WhisperM8` before using it.

### Auto-paste not working

1. Settings → Permissions: Accessibility must be granted. Restart WhisperM8 after changing it.
2. Settings → Recording → *Auto-paste after transcription* must be on.
3. The text is always on the clipboard — paste it with `Cmd+V` as a fallback.

### Microphone permission denied

System Settings → Privacy & Security → Microphone → enable WhisperM8, then restart the app.

### Hotkey not working

Another app may use the same combination — choose a different one under Settings → Recording.

### Audio device not appearing

Check System Settings → Sound → Input, reconnect the device, wait a few seconds and pick it again under
Settings → Recording.

### API errors

Check the key (no trailing spaces), the Groq rate limit (wait or switch to OpenAI) and the network.

### A chat does not start

If Claude Code or Codex is missing, WhisperM8 shows a sheet with *Check Again* and an install option.
Sign-in problems are shown inside the chat itself — follow the CLI's instructions there.

---

## Privacy and local data

- **API keys** are stored in the macOS Keychain.
- **Audio** of a successful dictation is sent to your transcription provider (Groq or OpenAI) and the
  temporary file is deleted afterwards.
- **Failed or cancelled transcriptions:** the audio is kept as a rescue copy under
  `~/Library/Application Support/WhisperM8/FailedRecordings`, so you can transcribe it again. At most
  10 recordings are kept; older than 7 days are removed the next time a recording is saved there. You
  can delete the folder's contents at any time.
- **Reports:** every dictation leaves a local report (transcript, chosen mode, timings and — if enabled
  — context images) under `~/Library/Application Support/WhisperM8/Reports`. At most 500 reports,
  180 days and 2 GB are kept; the oldest are removed when a new report is saved. Settings → Context &
  Privacy can delete visual context files right after processing. You can delete the folder at any time.
- **Context** (selected text, screenshots, screen clips) is only sent to Codex when an output mode
  requests it.
- **Agent Chats** run the Claude Code and Codex tools on your Mac; what they send is governed by those
  tools and your accounts. Automatic chat summaries are off by default.
- **Settings** are stored in macOS user defaults (`com.whisperm8.app`).

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| [Your hotkey] | Start/stop recording |
| `Cmd + ,` | Open Settings |
| `Ctrl + Tab` | Switch between chats |
| `Cmd + Q` | Quit (asks first if a chat is working) |

---

## License

MIT License — see [LICENSE](../LICENSE) for details.

Built by [360° Web Manager](https://360web-manager.com/)
