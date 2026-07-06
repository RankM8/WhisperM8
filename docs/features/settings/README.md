---
description: Settings-Dokumentation — eine Referenz-Seite pro Settings-Seite (Control Center)
description_long: |
  Vollständige Dokumentation des Settings-Fensters (Control Center) von
  WhisperM8: pro Sidebar-Seite ein eigenes Referenz-Dokument mit allen
  Optionen, Persistenz, Code-Wirkung und UX-Beobachtungen. Grundlage für
  das geplante Settings-Redesign (bessere Kategorien und Auffindbarkeit).
updated: 2026-07-06 09:51
---

# Settings (Control Center)

Das Settings-Fenster von WhisperM8 („Control Center") besteht aus **15 Seiten**
in 4 Sidebar-Gruppen. Aufhängung: `ControlCenterSection` in
`WhisperM8/Views/SettingsView.swift` (Enum + Sidebar + Detail-Switch).

Pro Seite existiert hier ein Referenz-Dokument mit fester Struktur:
Zweck → UI-Aufbau → Optionen im Detail (Control, Default, Persistenz,
Code-Wirkung) → Datenfluss → Querverweise → **UX-Beobachtungen** (Rohmaterial
für das Redesign) → Offene Fragen.

## Seiten-Übersicht

| # | Seite | Gruppe | Dokument | Status |
|---|-------|--------|----------|--------|
| 1 | Transcription API | Accounts | [01-transcription-api.md](01-transcription-api.md) | ✅ |
| 2 | Codex / ChatGPT | Accounts | [02-codex-chatgpt.md](02-codex-chatgpt.md) | ✅ |
| 3 | Output Overview | Output | [03-output-overview.md](03-output-overview.md) | ✅ |
| 4 | History | Output | [04-history.md](04-history.md) | ✅ |
| 5 | Modes | Output | [05-modes.md](05-modes.md) | ✅ |
| 6 | Templates | Output | [06-templates.md](06-templates.md) | ✅ |
| 7 | Test Lab | Output | [07-test-lab.md](07-test-lab.md) | ✅ |
| 8 | Agent Chats | Agents | [08-agent-chats.md](08-agent-chats.md) | ✅ |
| 9 | Claude Code | Agents | [09-claude-code.md](09-claude-code.md) | ✅ |
| 10 | Permissions | App | [10-permissions.md](10-permissions.md) | ✅ |
| 11 | Hotkey | App | [11-hotkey.md](11-hotkey.md) | ✅ |
| 12 | Audio | App | [12-audio.md](12-audio.md) | ✅ |
| 13 | Behavior | App | [13-behavior.md](13-behavior.md) | ✅ |
| 14 | CLI & Skill | App | [14-cli-skill.md](14-cli-skill.md) | ✅ |
| 15 | About | App | [15-about.md](15-about.md) | ✅ |

Status: 🔄 = Entwurf/wird gefüllt · ✅ = von Codex gefüllt und per
Opus-Gegenprüfung validiert.

## Redesign

Die Synthese aller UX-Beobachtungen mit Neustruktur-Varianten und Empfehlung
steht in [REDESIGN-BERATUNG.md](REDESIGN-BERATUNG.md).

## Entstehung & Pflege

Erstbefüllung 2026-07-06: pro Seite ein Codex-Subagent (Analyse der Views +
Services), anschließend unabhängige Validierung durch Opus-Subagents
(Widerlegungs-Prüfung der Datei:Zeile-Belege). Bei Änderungen an einer
Settings-Seite das zugehörige Dokument mitpflegen (`updated`-Feld setzen).
