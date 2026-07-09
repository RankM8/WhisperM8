---
status: geplant
erstellt: 2026-07-09
---

# Transcription — Speech-to-Text-Engine

> ⏳ **Platzhalter** — diese Doku entsteht im `docs-rebuild`-Workflow (Codex-Writer + 2 Verifier). Struktur: README.md (fachlich) + ARCHITECTURE.md (Komponenten, Datenflüsse, Invarianten) + Keywords-Sektion.

**Scope:** Provider-Abstraktion (OpenAI/Groq), Multipart-Upload, Chunking; geteilt von GUI-Diktat und CLI.

**Code:** `Services/Dictation/TranscriptionService`, `TranscriptionProviders`, `MultipartTranscriptionClient`
