---
name: whisperm8-transcription
description: Transcribe audio and video files to text, JSON, or SRT/VTT subtitles using the local whisperm8 CLI (installed with the WhisperM8 macOS app). Use when the user wants to transcribe a recording, meeting, voice memo, interview, podcast, lecture, call, or video file, generate subtitles, or summarize/analyze the spoken content of a media file on their Mac.
---

# WhisperM8 CLI — Audio/Video Transcription

`whisperm8` is a local command-line tool that ships with the WhisperM8 macOS app. It transcribes audio **and video** files via Groq or OpenAI Whisper APIs. The API key is read from the WhisperM8 app's Keychain entry automatically — if the app is set up, the CLI is already authenticated. No extra login is needed.

## Availability check

```bash
whisperm8 --version
```

If the command is not found: the WhisperM8 app installs a symlink at `~/.local/bin/whisperm8` on every launch. Ask the user to launch the WhisperM8 app once, or check that `~/.local/bin` is on the `PATH`.

## Quick start

```bash
# Plain text transcript to stdout
whisperm8 transcribe recording.m4a

# Video → subtitles (audio track is extracted automatically)
whisperm8 transcribe talk.mp4 -f srt -o talk.srt

# Transcript with timestamps as JSON, German language hint
whisperm8 transcribe call.mp3 -f json -l de
```

## Command reference

```
whisperm8 transcribe <file> [<file>…] [options]
whisperm8 modes          # list available post-processing modes (for --mode)
whisperm8 --help
whisperm8 --version
```

### transcribe options

| Option | Meaning |
|---|---|
| `-o, --output <path>` | Write result to a file instead of stdout. Format is inferred from the file extension if `-f` is not given. |
| `-f, --format <txt\|json\|srt\|vtt>` | Output format. Default: `txt`. `json` includes text, language, duration, and timestamped segments. |
| `-l, --language <code>` | Language hint (e.g. `de`, `en`). Optional — auto-detected otherwise. |
| `--provider <groq\|openai>` | API provider. Default: `groq`. |
| `--model <name>` | Model override: `whisper-large-v3-turbo`, `whisper-large-v3` (Groq); `gpt-4o-transcribe`, `whisper-1` (OpenAI). |
| `--mode <id>` | Post-process the transcript through a WhisperM8 output mode (cleanup, email draft, Slack message, …). List IDs with `whisperm8 modes`. Requires the Codex CLI to be installed and logged in. |
| `--api-key <key>` | Explicit API key. Normally unnecessary (see key resolution). |
| `--dry-run` | No API calls — print duration, chunk count, and an estimated cost (Groq ≈ $0.002/min, OpenAI ≈ $0.006/min). |

### What it handles automatically

- **Video files**: the audio track is extracted automatically (AVFoundation, with an ffmpeg fallback for exotic containers like `.mkv`/`.webm` if ffmpeg is installed).
- **Long files**: audio longer than ~90 minutes is split at silence boundaries and the transcripts are stitched back together with continuous timestamps. Nothing to configure.
- **Transient API errors** (429/5xx/network): retried automatically with backoff.

### Key resolution order

`--api-key` flag → environment variable (`GROQ_API_KEY` / `OPENAI_API_KEY`) → WhisperM8 app Keychain. In the normal case the Keychain entry from the app is used — do not ask the user for a key unless the CLI reports that none was found.

## Output contract (important for scripting)

- **stdout** carries *only* the transcription result — safe to pipe or capture.
- **stderr** carries progress and errors (messages are in German).
- Exit codes: `0` success · `1` at least one file failed · `64` usage error · `65` invalid option combination · `78` no API key found.

## Rules and constraints

- `srt`/`vtt` need segment timestamps, so they require a Whisper model. The OpenAI default `gpt-4o-transcribe` returns no segments — use `--provider groq` (default) or `--model whisper-1` for subtitles.
- `--mode` produces rewritten prose, so it cannot be combined with `-f srt`/`-f vtt`. Use `txt` or `json`.
- With **multiple input files**, `-o` is not allowed — each result is written next to its source file (`talk.mp4` → `talk.txt`/`talk.srt` …).
- Paths with `~` are expanded; quote paths containing spaces.

## Recipes

**Transcribe, then work with the content** (summary, action items, translation…): transcribe to a file first, then read it — long media takes a while and the transcript can be large.

```bash
whisperm8 transcribe meeting.mp4 -o meeting-transcript.txt
```

Then read `meeting-transcript.txt` and continue with the user's actual task (summarize, extract decisions, draft a follow-up email, …).

**Estimate before transcribing something huge:**

```bash
whisperm8 transcribe 3h-workshop.mp4 --dry-run
```

**Batch a folder of voice memos:**

```bash
whisperm8 transcribe ~/Memos/*.m4a
```

**Subtitles for a video, German audio:**

```bash
whisperm8 transcribe video.mp4 -f srt -l de -o video.srt
```

## Practical notes for agents

- Transcription time scales with media length (roughly: a 1-hour file takes a few minutes). Use a generous command timeout — at least 10 minutes for long recordings.
- Progress is printed live on stderr; absence of stdout output does not mean it hung.
- `whisperm8 modes` lists the user's configured post-processing modes. Prefer doing text transformation yourself unless the user explicitly wants a WhisperM8 mode — modes spawn the Codex CLI and take extra time.
- If the user asks to "transcribe" something that is a URL, download it first; the CLI only accepts local files.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `command not found: whisperm8` | Launch the WhisperM8 app once (installs the symlink), or add `~/.local/bin` to `PATH`. |
| `Kein API-Key … gefunden` (exit 78) | Open WhisperM8 → Settings → Transcription API and save a Groq or OpenAI key, or export `GROQ_API_KEY`. |
| `Format 'srt' braucht Timestamps …` | The chosen model returns no segments — drop `--model gpt-4o-transcribe` or switch to a Whisper model. |
| `Keine Audiospur … gefunden` | The file has no audio track, or the container needs ffmpeg (`brew install ffmpeg`) for the fallback extraction. |
