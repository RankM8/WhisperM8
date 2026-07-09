---
status: geplant
erstellt: 2026-07-09
---

# Dictation — Diktieren von Hotkey bis Einfügen

> ⏳ **Platzhalter** — die Säulen-Übersicht entsteht im `docs-rebuild`-Workflow als Synthese, nachdem die vier Unterordner geschrieben sind.

**Scope:** Big Picture der Diktat-Pipeline: Hotkey (KeyboardShortcuts) → `RecordingCoordinator` → `AudioRecorder` → Kontext-Erfassung → `TranscriptionService` → optionales Codex-Post-Processing → Clipboard/Auto-Paste oder Routing in einen Agent Chat.

## Teilsysteme

| Ordner | Thema |
|---|---|
| [`recording/`](recording/) | Aufnahme-Flow, Overlay/Pill, MenuBar, Paste — inkl. [`audio-ducking.md`](recording/audio-ducking.md) |
| [`transcription/`](transcription/) | STT-Engine (OpenAI/Groq, Multipart, Chunking) |
| [`ai-output/`](ai-output/) | Post-Processing, Output-Modes, Templates, Test-Lab, Reports |
| [`visual-context/`](visual-context/) | Screenshot-/Selektions-Kontext |
