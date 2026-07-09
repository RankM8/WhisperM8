---
status: geplant
erstellt: 2026-07-09
---

# Sessions — Store, Indexer, Runtime-Status, Transcripts

> ⏳ **Platzhalter** — diese Doku entsteht im `docs-rebuild`-Workflow (Codex-Writer + 2 Verifier). Struktur: README.md (fachlich) + ARCHITECTURE.md (Komponenten, Datenflüsse, Invarianten) + Keywords-Sektion.

**Scope:** Der Daten-Kern: Persistenz, Discovery/Indexing externer Sessions, ereignisgetriebenes Status-Tracking, Transcript-Reader.

**Code:** `Services/AgentChats/AgentSessionStore`, `AgentSessionIndexer`, `AgentSessionRuntimeWatcher`, `*TranscriptReader`
