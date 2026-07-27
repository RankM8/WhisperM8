---
status: aktiv
stand: 2026-07-09
---

# Feature-Dokumentation

Die Doku ist in **fünf Bereiche** organisiert — die vier Produkt-Säulen der App plus die App-Hülle. Jeder Unterordner ist ein abgeschlossenes Teilsystem mit `README.md` (fachlich: was, wie, warum) und `ARCHITECTURE.md` (Komponenten, Datenflüsse, Invarianten) plus Keywords-Sektion zum Wiederfinden.

## Säulen

| Säule | Inhalt | Unterordner |
|---|---|---|
| [`dictation/`](dictation/) | Diktieren: Hotkey → Aufnahme → STT → AI-Nachbearbeitung → Einfügen | `recording/`, `transcription/`, `ai-output/`, `visual-context/` |
| [`agent-chats/`](agent-chats/) | Das Agent-Chats-Fenster: Sessions verwalten, beobachten, spawnen | `ui/`, `sessions/`, `sub-agents/`, `background-agents/`, `codex-exec/` |
| [`cli/`](cli/) | Das `whisperm8`-Binary: transcribe / agent / agent-supervise | — |
| [`settings/`](settings/) | Einstellungen: 10-Seiten-Struktur, Settings-Kit, Routing | — |
| [`app-shell/`](app-shell/) | App-Hülle: Profile (Dock/MenuBar), Onboarding, Menüleiste, Updates, Fenster-Routing | — |

## Einzeldokumente

Features, die quer zu den Säulen liegen und (noch) keinen eigenen Unterordner haben:

| Dokument | Inhalt |
|---|---|
| [`agent-chats-cli.md`](agent-chats-cli.md) | `whisperm8 chats` — Agent-Sessions aus einem Chat heraus sehen und steuern |
| [`voice-gate.md`](voice-gate.md) | Codewort-Steuerung der Codex-Sprachsitzung („Codex Voice Agent") |

## Konventionen

- **Fachlich vor codezeilengetrieben:** Schlüsseldateien werden als *Pfad + Rolle* genannt, ohne Zeilennummern.
- **Keywords-Sektion** in jeder README: deutsche Begriffe + Code-Bezeichner, damit Suche (`/DOC:search`, grep) trifft.
- **Ist-Zustand only:** Offene Vorhaben liegen in [`../plans/`](../plans/), Historisches in [`../archive/`](../archive/).
- Querschnitts-Infrastruktur (LoginShellEnvironment, Permissions, Keychain, Signposts) dokumentiert die Top-Level-[`../ARCHITECTURE.md`](../ARCHITECTURE.md).
