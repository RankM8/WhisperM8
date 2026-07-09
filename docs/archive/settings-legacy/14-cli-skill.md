---
description: Settings-Seite „CLI & Skill" — Referenz für CLI-Symlink, Schnellstart-Befehle und installierbare Agent-Skills
description_long: |
  Vollständige Referenz der Settings-Seite „CLI & Skill": Zweck, UI-Aufbau,
  alle Controls mit Persistenz bzw. Installationsorten, Statusprüfung, Datenfluss,
  Querverweise sowie UX-Beobachtungen für das Settings-Redesign.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 1 Lücke im Quellen-Header korrigiert)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `CLISkillsSettingsPage.swift` + Doku-Verweis [ARCHITEKTUR: Pages](../../features/settings/ARCHITECTURE.md#pages).

# Settings: CLI & Skill

> **Sidebar-Gruppe:** App · **View:** `WhisperM8/Views/Settings/CLISettingsView.swift` · **Enum-Case:** `ControlCenterSection.cli` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `CLISettingsView.swift`, `Services/Shared/CLISymlinkInstaller.swift`, `Services/Shared/CLISkillExporter.swift` (CLIInstallStatus + Skill-Export/-Install)

## 1. Zweck & Überblick

Die Settings-Seite „CLI & Skill" ist der App-Bereich für die Kommandozeilen-Anbindung von WhisperM8 und wird im Settings-Detail für `ControlCenterSection.cli` gerendert. (WhisperM8/Views/SettingsView.swift:17, WhisperM8/Views/SettingsView.swift:241-243) Sie zeigt den Installationsstatus des Symlinks `~/.local/bin/whisperm8`, bietet eine manuelle Reparaturaktion an und erklärt, dass die CLI denselben Keychain-API-Key wie die App nutzt. (WhisperM8/Views/Settings/CLISettingsView.swift:37-61, WhisperM8/Services/Shared/CLISymlinkInstaller.swift:3-6) Zusätzlich stellt die Seite kopierbare Schnellstart-Befehle für Transkription und Codex-Subagents sowie zwei installierbare Skills für Claude Code, ChatGPT oder Claude.ai bereit. (WhisperM8/Views/Settings/CLISettingsView.swift:107-143, WhisperM8/Views/Settings/CLISettingsView.swift:16-29)

## 2. UI-Aufbau

Die Seite ist ein gruppiertes SwiftUI-`Form` mit vier Bereichen in dieser Reihenfolge: „Kommandozeile", „Schnellstart: Transkription", „Schnellstart: Codex-Subagents" und „Agent-Skills für Claude & ChatGPT". (WhisperM8/Views/Settings/CLISettingsView.swift:11-31) Beim Erscheinen liest sie den aktuellen CLI-Installationsstatus erneut ein. (WhisperM8/Views/Settings/CLISettingsView.swift:32)

„Kommandozeile" zeigt Statusicon, Titel, Detailpfad und bei Bedarf den Button „Link anlegen". (WhisperM8/Views/Settings/CLISettingsView.swift:37-61) Der Button ist nur sichtbar, wenn der Status nicht `.linked` ist. (WhisperM8/Views/Settings/CLISettingsView.swift:50-55, WhisperM8/Views/Settings/CLISettingsView.swift:100-103)

„Schnellstart: Transkription" enthält vier `CommandExampleRow`-Zeilen für `whisperm8 transcribe ...`; jede Zeile zeigt Befehl, Caption und einen Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:107-120, WhisperM8/Views/Settings/CLISettingsView.swift:148-180)

„Schnellstart: Codex-Subagents" erklärt WhisperM8 als Supervisor für headless Codex-Agenten und zeigt vier `whisperm8 agent ...`-Beispiele mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:125-143, WhisperM8/Views/Settings/CLISettingsView.swift:148-180)

„Agent-Skills für Claude & ChatGPT" rendert zwei `SkillCardView`s: den Transkriptions-Skill `.transcription` und den Codex-Agent-Skill `.codexAgent`. (WhisperM8/Views/Settings/CLISettingsView.swift:16-29) Jede Skill-Karte lädt ihren Installationsstatus und den gebündelten Markdown-Inhalt beim Erscheinen. (WhisperM8/Views/Settings/CLISettingsView.swift:258, WhisperM8/Views/Settings/CLISettingsView.swift:271-277)

## 3. Optionen im Detail

### CLI-Statusanzeige

| Aspekt | Wert |
|---|---|
| Control | Read-only-Statuszeile mit Systemicon, Titel und selektierbarem Detailpfad. (WhisperM8/Views/Settings/CLISettingsView.swift:37-61) |
| Default | Initial `.missing(expectedPath: "~/.local/bin/whisperm8")`, danach `CLIInstallStatus.current()` auf `onAppear`. (WhisperM8/Views/Settings/CLISettingsView.swift:9, WhisperM8/Views/Settings/CLISettingsView.swift:32) |
| Persistenz | Keine UserDefaults-Persistenz; der Status wird aus dem Dateisystempfad `~/.local/bin/whisperm8` abgeleitet. (WhisperM8/Services/Shared/CLISkillExporter.swift:119-132) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:32, WhisperM8/Services/Shared/CLISkillExporter.swift:119-141 |
| Wirkung | Zeigt „whisperm8 ist installiert", „Link zeigt auf eine andere App-Kopie" oder „CLI-Link noch nicht angelegt" und den jeweiligen Pfad bzw. Zielpfad. (WhisperM8/Views/Settings/CLISettingsView.swift:81-98) |
| Abhängigkeiten | Hängt vom Symlink-Ziel und vom aktuellen `Bundle.main.executableURL` ab. (WhisperM8/Services/Shared/CLISkillExporter.swift:119-141) |

### Link anlegen

| Aspekt | Wert |
|---|---|
| Control | Button „Link anlegen", nur bei fehlendem oder fremdem CLI-Link sichtbar. (WhisperM8/Views/Settings/CLISettingsView.swift:50-55, WhisperM8/Views/Settings/CLISettingsView.swift:100-103) |
| Default | Nicht sichtbar, wenn `installState == .linked`; sichtbar bei `.missing` oder `.linkedElsewhere`. (WhisperM8/Views/Settings/CLISettingsView.swift:50-55, WhisperM8/Views/Settings/CLISettingsView.swift:100-103) |
| Persistenz | Legt bzw. repariert den Symlink `~/.local/bin/whisperm8` auf das laufende App-Binary `.../Contents/MacOS/WhisperM8`. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:13-16, WhisperM8/Services/Shared/CLISymlinkInstaller.swift:35-36, WhisperM8/Services/Shared/CLISymlinkInstaller.swift:42-51) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:52-53, WhisperM8/Services/Shared/CLISymlinkInstaller.swift:10-40 |
| Wirkung | Erstellt `~/.local/bin`, ersetzt einen vorhandenen Symlink auf eine andere App-Kopie und überschreibt keine reguläre Datei am Zielpfad. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:18-35) |
| Abhängigkeiten | Nutzt das aktuelle Executable aus `Bundle.main.executableURL` oder `CommandLine.arguments.first`; danach wird der Status neu gelesen. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:42-51, WhisperM8/Views/Settings/CLISettingsView.swift:52-53) |

### Transkription: Audio zu Text kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 transcribe aufnahme.m4a` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:110, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:110, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:110, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert den Befehl für Audio-zu-Text-Ausgabe auf stdout. (WhisperM8/Views/Settings/CLISettingsView.swift:110, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Benötigt den installierten oder per PATH erreichbaren Befehl `whisperm8`. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:3-6, WhisperM8/WhisperM8App.swift:244-249) |

### Transkription: Video zu Untertiteln kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 transcribe video.mp4 -f srt -o video.srt` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:111, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:111, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:111, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert den Beispielbefehl für SRT-Ausgabe in eine Datei `video.srt`. (WhisperM8/Views/Settings/CLISettingsView.swift:111, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Nutzt dieselbe CLI-Verfügbarkeit über `~/.local/bin/whisperm8`. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:3-6, WhisperM8/WhisperM8App.swift:244-249) |

### Transkription: Clean-Mode kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 transcribe meeting.mp3 --mode clean -o meeting.txt` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:112, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:112, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:112, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert den Beispielbefehl für Transkript plus Nachbearbeitung über den Output-Mode `clean`. (WhisperM8/Views/Settings/CLISettingsView.swift:112, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Hängt von CLI-Verfügbarkeit und den in der CLI vorhandenen Output-Modes ab; die Seite verweist nur per Beispiel auf `--mode clean`. (WhisperM8/Views/Settings/CLISettingsView.swift:112, WhisperM8/Services/Shared/CLISymlinkInstaller.swift:3-6) |

### Transkription: Dry-Run kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 transcribe workshop.mp4 --dry-run` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:113, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:113, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:113, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert den Beispielbefehl für Dauer-, Chunk- und Kostenschätzung ohne API-Calls. (WhisperM8/Views/Settings/CLISettingsView.swift:113, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Nutzt dieselbe CLI-Verfügbarkeit über den Symlink oder PATH. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:3-6, WhisperM8/WhisperM8App.swift:244-249) |

### Codex-Subagent: Run mit Wait und JSON kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 agent run --wait --json "Reviewe den Diff von HEAD~3 auf Regressionen."` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:132, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:132, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:132, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert ein Beispiel für einen synchronen Agent-Job, der bis zum JSON-Report blockiert. (WhisperM8/Views/Settings/CLISettingsView.swift:132, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Der erklärende Text koppelt diese Befehle an Agent Chats, weil Jobs dort live erscheinen und als interaktiver Chat übernommen werden können. (WhisperM8/Views/Settings/CLISettingsView.swift:127-135) |

### Codex-Subagent: Worktree-Run kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 agent run --worktree "Implementiere X, teste, committe bei grün."` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:133, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:133, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:133, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert ein Beispiel für einen detachten Job in einem isolierten Git-Worktree mit Branch `subagent/<id>`. (WhisperM8/Views/Settings/CLISettingsView.swift:133, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Gehört zur Agent-Chat-Funktion, weil die Seite Agent-Jobs als live sichtbare, fortsetzbare Sessions beschreibt. (WhisperM8/Views/Settings/CLISettingsView.swift:127-135) |

### Codex-Subagent: Folge-Turn kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 agent send <id> --wait "Bitte auch die Edge-Cases abdecken."` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:134, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:134, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:134, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert ein Beispiel für einen Folge-Turn, bei dem die Session ihren Kontext über `codex exec resume` behält. (WhisperM8/Views/Settings/CLISettingsView.swift:134, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Hängt fachlich von bestehenden Agent-Job-IDs ab, weil der Befehl `<id>` als Platzhalter verwendet. (WhisperM8/Views/Settings/CLISettingsView.swift:134) |

### Codex-Subagent: Job-Liste kopieren

| Aspekt | Wert |
|---|---|
| Control | `CommandExampleRow` für `whisperm8 agent list` mit Kopierbutton. (WhisperM8/Views/Settings/CLISettingsView.swift:135, WhisperM8/Views/Settings/CLISettingsView.swift:161-173) |
| Default | Der Befehl ist statischer UI-Text; `copied` startet pro Zeile mit `false`. (WhisperM8/Views/Settings/CLISettingsView.swift:135, WhisperM8/Views/Settings/CLISettingsView.swift:151) |
| Persistenz | Keine App-Persistenz; Klick schreibt den Befehl in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:135, WhisperM8/Views/Settings/CLISettingsView.swift:156-164 |
| Wirkung | Kopiert ein Beispiel für Job-Übersicht und Verwaltung über `status`, `logs`, `stop` und `rm`. (WhisperM8/Views/Settings/CLISettingsView.swift:135, WhisperM8/Views/Settings/CLISettingsView.swift:162-165) |
| Abhängigkeiten | Gehört zu den Agent-Chat-/Subagent-Workflows der Seite. (WhisperM8/Views/Settings/CLISettingsView.swift:125-143) |

### Transkriptions-Skill: In Claude Code installieren

| Aspekt | Wert |
|---|---|
| Control | Prominenter Button in der Skill-Karte „Skill `whisperm8-transcription`"; Label wechselt zwischen „In Claude Code installieren", „Skill aktualisieren" und „In Claude Code installiert". (WhisperM8/Views/Settings/CLISettingsView.swift:202-220, WhisperM8/Services/Shared/CLISkillExporter.swift:15-19) |
| Default | `installed` und `isCurrent` starten mit `false` und werden auf `onAppear` über den Exporter aktualisiert. (WhisperM8/Views/Settings/CLISettingsView.swift:188-189, WhisperM8/Views/Settings/CLISettingsView.swift:258, WhisperM8/Views/Settings/CLISettingsView.swift:271-277) |
| Persistenz | Schreibt `~/.claude/skills/whisperm8-transcription/SKILL.md` aus der Bundle-Ressource `whisperm8-cli-skill.md`. (WhisperM8/Services/Shared/CLISkillExporter.swift:15-19, WhisperM8/Services/Shared/CLISkillExporter.swift:58-74, WhisperM8/Services/Shared/CLISkillExporter.swift:90-101) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:18-20, WhisperM8/Views/Settings/CLISettingsView.swift:279-287, WhisperM8/Services/Shared/CLISkillExporter.swift:76-88 |
| Wirkung | Installiert oder aktualisiert den Claude-Code-Skill; danach werden Installations- und Aktualitätsstatus neu gelesen. (WhisperM8/Views/Settings/CLISettingsView.swift:279-287, WhisperM8/Services/Shared/CLISkillExporter.swift:90-101) |
| Abhängigkeiten | Claude Code lädt Skills automatisch aus `~/.claude/skills`; für manuelles Ablegen muss der Ordnername dem Skill-Namen entsprechen und die Datei `SKILL.md` heißen. (WhisperM8/Views/Settings/CLISettingsView.swift:26, WhisperM8/Services/Shared/CLISkillExporter.swift:3-10) |

### Transkriptions-Skill: Skill-Datei sichern

| Aspekt | Wert |
|---|---|
| Control | Button „Skill-Datei sichern…" in der Skill-Karte `whisperm8-transcription`. (WhisperM8/Views/Settings/CLISettingsView.swift:222-226, WhisperM8/Services/Shared/CLISkillExporter.swift:15-19) |
| Default | Das Save-Panel schlägt den Dateinamen `SKILL.md` vor und erlaubt Markdown über `UTType(filenameExtension: "md")`. (WhisperM8/Views/Settings/CLISettingsView.swift:294-299) |
| Persistenz | Schreibt den geladenen Skill-Markdown an einen vom Nutzer gewählten Pfad; kein fester App-Speicherort außer dem vorgeschlagenen Dateinamen `SKILL.md`. (WhisperM8/Views/Settings/CLISettingsView.swift:294-302) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:222-226, WhisperM8/Views/Settings/CLISettingsView.swift:289-305 |
| Wirkung | Exportiert denselben Skill-Inhalt, den `CLISkillExporter.skillMarkdown()` aus dem App-Bundle lädt. (WhisperM8/Views/Settings/CLISettingsView.swift:271-276, WhisperM8/Services/Shared/CLISkillExporter.swift:58-65) |
| Abhängigkeiten | Wenn der Markdown nicht geladen ist, zeigt die Aktion eine Fehlermeldung für die fehlende Bundle-Ressource. (WhisperM8/Views/Settings/CLISettingsView.swift:289-292, WhisperM8/Services/Shared/CLISkillExporter.swift:47-55) |

### Transkriptions-Skill: Inhalt kopieren

| Aspekt | Wert |
|---|---|
| Control | Button „Inhalt kopieren" in der Skill-Karte `whisperm8-transcription`; der Button ist deaktiviert, solange `markdown` leer ist. (WhisperM8/Views/Settings/CLISettingsView.swift:228-233, WhisperM8/Services/Shared/CLISkillExporter.swift:15-19) |
| Default | `markdown` startet leer und wird beim Erscheinen einmal aus dem Bundle geladen. (WhisperM8/Views/Settings/CLISettingsView.swift:190, WhisperM8/Views/Settings/CLISettingsView.swift:271-276) |
| Persistenz | Keine App-Persistenz; Klick schreibt den gesamten Skill-Markdown in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:308-313) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:228-233, WhisperM8/Views/Settings/CLISettingsView.swift:308-313 |
| Wirkung | Macht den Skill-Inhalt für ChatGPT oder Claude.ai als Projekt-Anweisung bzw. Custom Instruction kopierbar. (WhisperM8/Views/Settings/CLISettingsView.swift:26, WhisperM8/Views/Settings/CLISettingsView.swift:308-313) |
| Abhängigkeiten | Hängt vom erfolgreichen Laden der Bundle-Ressource `whisperm8-cli-skill.md` ab. (WhisperM8/Services/Shared/CLISkillExporter.swift:15-19, WhisperM8/Services/Shared/CLISkillExporter.swift:58-65) |

### Transkriptions-Skill: Skill-Inhalt ansehen

| Aspekt | Wert |
|---|---|
| Control | `DisclosureGroup` „Skill-Inhalt ansehen" mit scrollbarer, selektierbarer Markdown-Vorschau. (WhisperM8/Views/Settings/CLISettingsView.swift:243-255) |
| Default | `isPreviewExpanded` startet mit `false`; bei fehlendem Markdown steht „Skill-Ressource nicht gefunden.". (WhisperM8/Views/Settings/CLISettingsView.swift:193, WhisperM8/Views/Settings/CLISettingsView.swift:243-246) |
| Persistenz | Keine App-Persistenz; der Expanded-State liegt nur in `@State`. (WhisperM8/Views/Settings/CLISettingsView.swift:193, WhisperM8/Views/Settings/CLISettingsView.swift:243) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:243-255, WhisperM8/Views/Settings/CLISettingsView.swift:271-276 |
| Wirkung | Erlaubt Prüfung des geladenen Skill-Markdowns innerhalb der Settings-Seite. (WhisperM8/Views/Settings/CLISettingsView.swift:243-255) |
| Abhängigkeiten | Zeigt den Inhalt, den `CLISkillExporter.skillMarkdown()` aus der Skill-Ressource lädt. (WhisperM8/Views/Settings/CLISettingsView.swift:271-276, WhisperM8/Services/Shared/CLISkillExporter.swift:58-65) |

### Codex-Subagent-Skill: In Claude Code installieren

| Aspekt | Wert |
|---|---|
| Control | Prominenter Button in der Skill-Karte „Skill `codex-subagent`"; Label wechselt zwischen „In Claude Code installieren", „Skill aktualisieren" und „In Claude Code installiert". (WhisperM8/Views/Settings/CLISettingsView.swift:202-220, WhisperM8/Services/Shared/CLISkillExporter.swift:20-24) |
| Default | `installed` und `isCurrent` starten mit `false` und werden auf `onAppear` über den Exporter aktualisiert. (WhisperM8/Views/Settings/CLISettingsView.swift:188-189, WhisperM8/Views/Settings/CLISettingsView.swift:258, WhisperM8/Views/Settings/CLISettingsView.swift:271-277) |
| Persistenz | Schreibt `~/.claude/skills/codex-subagent/SKILL.md` aus der Bundle-Ressource `whisperm8-agent-skill.md`. (WhisperM8/Services/Shared/CLISkillExporter.swift:20-24, WhisperM8/Services/Shared/CLISkillExporter.swift:58-74, WhisperM8/Services/Shared/CLISkillExporter.swift:90-101) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:22-25, WhisperM8/Views/Settings/CLISettingsView.swift:279-287, WhisperM8/Services/Shared/CLISkillExporter.swift:76-88 |
| Wirkung | Installiert oder aktualisiert den Skill, der Claude Code das WhisperM8-Codex-Subagent-System mit Befehlen, Flags, Exit-Codes, JSON-Formaten und Workflows beschreibt. (WhisperM8/Views/Settings/CLISettingsView.swift:23-25, WhisperM8/Views/Settings/CLISettingsView.swift:279-287) |
| Abhängigkeiten | Baut fachlich auf dem Agent-CLI-Bereich der Seite auf, der Jobs live in Agent Chats sichtbar und über Turns fortsetzbar beschreibt. (WhisperM8/Views/Settings/CLISettingsView.swift:125-143) |

### Codex-Subagent-Skill: Skill-Datei sichern

| Aspekt | Wert |
|---|---|
| Control | Button „Skill-Datei sichern…" in der Skill-Karte `codex-subagent`. (WhisperM8/Views/Settings/CLISettingsView.swift:222-226, WhisperM8/Services/Shared/CLISkillExporter.swift:20-24) |
| Default | Das Save-Panel schlägt den Dateinamen `SKILL.md` vor und erlaubt Markdown über `UTType(filenameExtension: "md")`. (WhisperM8/Views/Settings/CLISettingsView.swift:294-299) |
| Persistenz | Schreibt den geladenen Skill-Markdown an einen vom Nutzer gewählten Pfad; kein fester App-Speicherort außer dem vorgeschlagenen Dateinamen `SKILL.md`. (WhisperM8/Views/Settings/CLISettingsView.swift:294-302) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:222-226, WhisperM8/Views/Settings/CLISettingsView.swift:289-305 |
| Wirkung | Exportiert denselben Codex-Subagent-Skill, den `CLISkillExporter.skillMarkdown()` aus dem App-Bundle lädt. (WhisperM8/Views/Settings/CLISettingsView.swift:271-276, WhisperM8/Services/Shared/CLISkillExporter.swift:58-65) |
| Abhängigkeiten | Wenn der Markdown nicht geladen ist, zeigt die Aktion eine Fehlermeldung für die fehlende Bundle-Ressource. (WhisperM8/Views/Settings/CLISettingsView.swift:289-292, WhisperM8/Services/Shared/CLISkillExporter.swift:47-55) |

### Codex-Subagent-Skill: Inhalt kopieren

| Aspekt | Wert |
|---|---|
| Control | Button „Inhalt kopieren" in der Skill-Karte `codex-subagent`; der Button ist deaktiviert, solange `markdown` leer ist. (WhisperM8/Views/Settings/CLISettingsView.swift:228-233, WhisperM8/Services/Shared/CLISkillExporter.swift:20-24) |
| Default | `markdown` startet leer und wird beim Erscheinen einmal aus dem Bundle geladen. (WhisperM8/Views/Settings/CLISettingsView.swift:190, WhisperM8/Views/Settings/CLISettingsView.swift:271-276) |
| Persistenz | Keine App-Persistenz; Klick schreibt den gesamten Skill-Markdown in `NSPasteboard.general`. (WhisperM8/Views/Settings/CLISettingsView.swift:308-313) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:228-233, WhisperM8/Views/Settings/CLISettingsView.swift:308-313 |
| Wirkung | Macht den Codex-Subagent-Skill für ChatGPT oder Claude.ai als Projekt-Anweisung bzw. Custom Instruction kopierbar. (WhisperM8/Views/Settings/CLISettingsView.swift:26, WhisperM8/Views/Settings/CLISettingsView.swift:308-313) |
| Abhängigkeiten | Hängt vom erfolgreichen Laden der Bundle-Ressource `whisperm8-agent-skill.md` ab. (WhisperM8/Services/Shared/CLISkillExporter.swift:20-24, WhisperM8/Services/Shared/CLISkillExporter.swift:58-65) |

### Codex-Subagent-Skill: Skill-Inhalt ansehen

| Aspekt | Wert |
|---|---|
| Control | `DisclosureGroup` „Skill-Inhalt ansehen" mit scrollbarer, selektierbarer Markdown-Vorschau. (WhisperM8/Views/Settings/CLISettingsView.swift:243-255) |
| Default | `isPreviewExpanded` startet mit `false`; bei fehlendem Markdown steht „Skill-Ressource nicht gefunden.". (WhisperM8/Views/Settings/CLISettingsView.swift:193, WhisperM8/Views/Settings/CLISettingsView.swift:243-246) |
| Persistenz | Keine App-Persistenz; der Expanded-State liegt nur in `@State`. (WhisperM8/Views/Settings/CLISettingsView.swift:193, WhisperM8/Views/Settings/CLISettingsView.swift:243) |
| Gelesen von | WhisperM8/Views/Settings/CLISettingsView.swift:243-255, WhisperM8/Views/Settings/CLISettingsView.swift:271-276 |
| Wirkung | Erlaubt Prüfung des geladenen Codex-Subagent-Skill-Markdowns innerhalb der Settings-Seite. (WhisperM8/Views/Settings/CLISettingsView.swift:243-255) |
| Abhängigkeiten | Zeigt den Inhalt, den `CLISkillExporter.skillMarkdown()` aus der Skill-Ressource lädt. (WhisperM8/Views/Settings/CLISettingsView.swift:271-276, WhisperM8/Services/Shared/CLISkillExporter.swift:58-65) |

## 4. Datenfluss & Persistenz

Der CLI-Symlink wird beim App-Start in einem Hintergrund-Task idempotent angelegt. (WhisperM8/WhisperM8App.swift:244-249) Die Settings-Seite liest den Status zusätzlich bei jedem Erscheinen mit `CLIInstallStatus.current()`. (WhisperM8/Views/Settings/CLISettingsView.swift:32)

`CLISymlinkInstaller.installIfNeeded()` ermittelt das aktuelle Executable, erstellt `~/.local/bin`, entfernt nur vorhandene Symlinks auf andere Ziele und legt `~/.local/bin/whisperm8` auf das aktuelle Binary. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:10-36) Eine reguläre Datei am Zielpfad wird nicht überschrieben und nur geloggt. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:28-32)

`CLIInstallStatus.current()` ist rein lesend und unterscheidet drei Zustände: korrekter Symlink, fremder Link bzw. reguläre Datei und fehlender Link. (WhisperM8/Services/Shared/CLISkillExporter.swift:107-141) Nach einem Klick auf „Link anlegen" installiert die Seite und liest sofort erneut. (WhisperM8/Views/Settings/CLISettingsView.swift:51-54)

Skill-Inhalte kommen aus Bundle-Ressourcen, werden in `markdown` zwischengespeichert und bei leerem `markdown` während `refresh()` geladen. (WhisperM8/Views/Settings/CLISettingsView.swift:190, WhisperM8/Views/Settings/CLISettingsView.swift:271-276, WhisperM8/Services/Shared/CLISkillExporter.swift:58-65) Die Claude-Code-Installation schreibt nach `~/.claude/skills/<name>/SKILL.md`; der Status `isInstalledForClaudeCode` prüft nur Datei-Existenz, `installedSkillIsCurrent` vergleicht den installierten Inhalt bytegenau mit der Bundle-Version. (WhisperM8/Services/Shared/CLISkillExporter.swift:68-88, WhisperM8/Services/Shared/CLISkillExporter.swift:90-101)

Kopieraktionen nutzen ausschließlich `NSPasteboard.general` und schreiben keine WhisperM8-Konfiguration. (WhisperM8/Views/Settings/CLISettingsView.swift:161-165, WhisperM8/Views/Settings/CLISettingsView.swift:308-313) Die Save-Aktion schreibt nur an den im `NSSavePanel` gewählten Ort. (WhisperM8/Views/Settings/CLISettingsView.swift:294-302)

## 5. Querverweise

Die Seite hängt an der Sidebar-Gruppe „App", weil `ControlCenterSection.cli` zusammen mit Permissions, Hotkey, Audio, Behavior und About gruppiert wird. (WhisperM8/Views/SettingsView.swift:96-106, WhisperM8/Views/SettingsView.swift:127-130) Die Detail-View wird über `CLISettingsView()` gerendert und nutzt den Navigationstitel „CLI & Skill". (WhisperM8/Views/SettingsView.swift:241-243, WhisperM8/Views/SettingsView.swift:17)

Der Symlink ist auch für Claude-Code-/Agent-Aufrufe relevant, weil `AgentCommandBuilder` `~/.local/bin` explizit als Fallback-Pfad für user-installierte CLIs durchsucht. (WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:298-315) Die App-Start-Installation stellt `whisperm8 transcribe ...` für Claude Code und Terminal bereit und nutzt denselben Keychain-Eintrag wie die App. (WhisperM8/WhisperM8App.swift:244-249)

Die Seite verweist fachlich auf Agent Chats, weil die Codex-Subagent-Erklärung sagt, dass Jobs live in den Agent Chats erscheinen, fortsetzbar sind und als interaktiver Chat übernommen werden können. (WhisperM8/Views/Settings/CLISettingsView.swift:125-135) Der separate Settings-Bereich „Agent Chats" existiert in der Sidebar-Gruppe „Agents". (WhisperM8/Views/SettingsView.swift:11-12, WhisperM8/Views/SettingsView.swift:127-130, WhisperM8/Views/SettingsView.swift:223-228)

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

- Für Nicht-Entwickler ist die Seite funktional, aber begrifflich dicht: „CLI", „Symlink", „stdout", „SRT", „dry-run", „Sandbox" und „Exit-Codes" werden direkt gezeigt, während nur ein kurzer Hilfetext erklärt, dass keine separate Anmeldung nötig ist. (WhisperM8/Views/Settings/CLISettingsView.swift:58-60, WhisperM8/Views/Settings/CLISettingsView.swift:117-139)
- Der Name „CLI & Skill" beschreibt die zwei Hauptartefakte technisch korrekt, sagt aber nicht, dass die Seite auch die Brücke zu Agent Chats und Codex-Subagents erklärt. (WhisperM8/Views/SettingsView.swift:17, WhisperM8/Views/Settings/CLISettingsView.swift:125-143)
- Die Seite liegt in der Gruppe „App", obwohl der Codex-Subagent-Teil stark mit der Gruppe „Agents" und den Agent Chats zusammenhängt. (WhisperM8/Views/SettingsView.swift:96-106, WhisperM8/Views/SettingsView.swift:127-130, WhisperM8/Views/Settings/CLISettingsView.swift:125-135)
- Positiv für Nicht-Entwickler ist, dass die Seite konkrete Beispiele anbietet und jeden Befehl per Iconbutton kopierbar macht, statt nur abstrakte Syntax zu zeigen. (WhisperM8/Views/Settings/CLISettingsView.swift:107-143, WhisperM8/Views/Settings/CLISettingsView.swift:148-180)
- Die Skill-Karten erklären den Unterschied zwischen Claude Code und ChatGPT/Claude.ai direkt im UI: Claude Code liest aus `~/.claude/skills`, andere Tools brauchen Kopieren oder manuelles Ablegen. (WhisperM8/Views/Settings/CLISettingsView.swift:26, WhisperM8/Services/Shared/CLISkillExporter.swift:3-7)
- Der Zusammenhang zwischen `codex-subagent`-Skill und Agent Chats ist vorhanden, aber über zwei Abschnitte verteilt: erst Schnellstart, dann Skill-Karte. (WhisperM8/Views/Settings/CLISettingsView.swift:125-143, WhisperM8/Views/Settings/CLISettingsView.swift:16-29)
- Der Installationsstatus unterscheidet technisch sauber zwischen korrekt verlinkt, fremder App-Kopie und fehlend; die UI zeigt diese Zustände mit Titel und Pfad, aber ohne erklärenden nächsten Schritt außer dem Button. (WhisperM8/Views/Settings/CLISettingsView.swift:64-98, WhisperM8/Views/Settings/CLISettingsView.swift:50-55)

## 7. Offene Fragen

- Es ist aus den gelesenen Dateien nicht ersichtlich, ob die UI Nutzer explizit darauf hinweist, dass `~/.local/bin` im Terminal-PATH liegen muss; der Installer legt nur den Symlink an. (WhisperM8/Services/Shared/CLISymlinkInstaller.swift:13-16, WhisperM8/Services/Shared/CLISymlinkInstaller.swift:35-36)
- Die Settings-Seite dokumentiert Beispiele für Formate, Provider, Sandbox und Exit-Codes, aber die hier geprüften Quellen validieren nicht die vollständige CLI-Argumentsemantik hinter allen Beispielen. (WhisperM8/Views/Settings/CLISettingsView.swift:107-143)
- Es bleibt offen, ob „CLI & Skill" als Navigationstitel für Nicht-Entwickler verständlich genug ist oder ob eine produktnähere Benennung wie „Terminal & Assistenten-Skills" getestet werden sollte. (WhisperM8/Views/SettingsView.swift:17, WhisperM8/Views/Settings/CLISettingsView.swift:16-29)
