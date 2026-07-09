---
status: geplant
erstellt: 2026-07-09
---

# Agent Chats — Sessions verwalten, beobachten, spawnen

> ⏳ **Platzhalter** — die Säulen-Übersicht entsteht im `docs-rebuild`-Workflow als Synthese, nachdem die fünf Unterordner geschrieben sind. Sie soll die **UI-Landkarte** liefern: Was sieht man im Agent-Chats-Fenster, und welches Teilsystem treibt welchen Teil (Sidebar ← `sessions/` + `ui/`, Tabs ← `ui/multiwindow.md`, eingerückte Subagent-Zeilen ← `sub-agents/`, Status-Ampeln ← `sessions/` + `background-agents/`).

## Teilsysteme

| Ordner | Thema |
|---|---|
| [`ui/`](ui/) | SwiftUI-Schicht: Fenster, Sidebar, Tabs, Terminal, Timeline — inkl. migrierter Multiwindow-Doku |
| [`sessions/`](sessions/) | Daten-Kern: Store, Indexer, Runtime-Status, Transcript-Reader |
| [`sub-agents/`](sub-agents/) | Codex-Jobs via `whisperm8 agent` (JobStore, Supervisor, Discovery) |
| [`background-agents/`](background-agents/) | Claude `--bg`, attach, Hook-Bridge |
| [`codex-exec/`](codex-exec/) | codex-exec-Integrationsschicht (auch von `dictation/ai-output/` genutzt) |
