# Orca: wie es gebaut ist und was es kann

**Stand:** 10.11.2026 · **Quelle:** <https://github.com/stablyai/orca>, Stand vom selben Tag (v1.4.255, rund 121.000 Sterne, MIT)
**Methode:** Quelltext und Doku gelesen, nichts installiert oder gestartet. Aussagen über Tempo, Stabilität oder Speicherverbrauch sind deshalb keine Messwerte.
**Gehört zu:** [README.md](README.md) · [orca-video.md](orca-video.md) (Oberfläche Bild für Bild) · [vergleich.md](vergleich.md) · [architektur.md](architektur.md)

## In einem Satz

Orca ist eine Electron-App, die wie WhisperM8 die echte CLI im Terminal hostet, aber jede Aufgabe in eine eigene Arbeitskopie legt, die Terminals in einem eigenen Hintergrunddienst hält und darum herum eine komplette Arbeitsumgebung baut: Dateien, Diff, PR, Browser, Aufgaben, Automatisierungen, andere Rechner, Handy.

## Größe

Rund 4,3 Millionen Zeilen TypeScript, davon etwa 1,3 Millionen Tests. Hauptprozess 1,8 Mio., Oberfläche 1,5 Mio., geteilter Code 0,4 Mio., Handy-App 0,35 Mio., Cloud-Dienste 0,09 Mio. 75 CI-Abläufe, mehrere Veröffentlichungen pro Tag. Das ist gut dreißigmal so viel Code wie WhisperM8.

## Wie die Agents laufen

### Terminal-Modus (Standard)

Die echte CLI im PTY (`node-pty`), gezeichnet mit xterm.js. Das ist derselbe Ansatz wie bei uns, mit einem entscheidenden Unterschied:

**Die Terminals gehören nicht der App, sondern einem eigenen Dienst** (`src/main/daemon/`, rund 40.000 Zeilen). Er startet die Prozesse, hält ihren Verlauf und führt nebenher einen unsichtbaren Terminal-Emulator mit, aus dem er den Bildschirm beim Wiederanhängen neu aufbaut, auch für Vollbild-Oberflächen wie Claude Code.

Folge laut Orcas Doku (`docs/site/content/docs/model/session-restore.mdx`):

- App beenden, Auto-Update, Absturz: die Agents laufen weiter, die App hängt sich wieder an, die Ausgabe aus der Zwischenzeit ist da.
- Erst ein Neustart des Rechners beendet sie. Danach stellt Orca Anordnung und Verlauf wieder her.
- „Vollständig beenden“ stoppt alles bewusst.

Der Preis: Die Entwicklernotiz im selben Ordner (`src/main/daemon/AGENTS.md`) beschreibt das Protokoll, mit dem App und Dienst den Besitz am Socket aushandeln, und nennt sieben Review-Runden und 23 Fehler allein an dieser Stelle.

Bei WhisperM8 bekommen alle Vordergrund-Chats ein SIGHUP, wenn die App endet. Die Wiederaufnahme nach Absturz startet sie neu und setzt die Sitzung fort; der laufende Arbeitsschritt ist verloren.

### Chat-Modus (wählbar)

Keine eigene Agent-Laufzeit. Claude läuft über das Claude Agent SDK, das die installierte `claude`-CLI startet; Codex über `codex app-server`; Grok, OpenCode und andere über ACP. Die Chat-Darstellung allein umfasst rund 87.000 Zeilen (`native-chat`), dazu kommen die Anbindungen (`acp` rund 16.000, Teile von `claude` mit rund 26.000).

Zwischen Chat und Terminal wird per Kopie in eine neue Sitzung gewechselt (`claude-conversation-copy.ts`), nicht nahtlos. Nahtlos ist nur eine Leseansicht des Verlaufs über einem laufenden Terminal (⌘⇧J).

### Status

Zwei Kanäle (`src/main/agent-hooks/README.md`):

1. **Verwaltete Hooks.** Orca trägt sie in die Einstellungen des jeweiligen Agents ein, bei Claude in `~/.claude/settings.json` (`src/main/claude/hook-settings.ts`), dazu eine eigene Statuszeile. Die Hooks melden an einen lokalen Server: Zustand, Prompt, Werkzeug, Antwort, Sitzungs-ID, Modell, Subagents. Entfernt werden die Einträge, wenn man die Funktion in Orca ausschaltet.
2. **OSC 7501** („Program Status Protocol“). Der Agent schreibt seinen Zustand selbst in den Terminalstrom. Claude Code kann das seit 2.1.295 (fünf Zustände, Grund der Blockade: Freigabe, Frage oder Anmeldung, eine Textzeile, Subagents), Codex seit 0.163 (nur Zustand), dazu Grok und Pi. Der Kanal springt ein, wenn Hooks fehlen oder seit zwei Minuten schweigen, etwa auf einem frischen SSH-Rechner.

Der zweite Kanal ist für uns interessant, siehe [kernfeatures.md](kernfeatures.md). In der hier installierten Claude-Code-Version 2.1.322 ist er vorhanden (im Programm nachgesehen); WhisperM8 wertet ihn nicht aus.

### Freigaben

Orca startet Agents ab Werk mit Vollzugriff (`src/shared/default-global-settings.ts`: `agentPermissionDefault: 'full-access'`), bei Claude also mit `--dangerously-skip-permissions`. Umstellen lässt es sich unter Einstellungen → Agenten → Berechtigungen.

## Andere Rechner

Im Dialog „Worktree erstellen“ wählt man unter „Ausführen auf“ den Rechner. Dahinter stehen drei Wege (`docs/site/content/docs/ways-to-run.mdx`, `ssh.mdx`, `remote-servers.mdx`):

| Weg | Was auf dem Zielrechner läuft | Was bleibt lokal |
|---|---|---|
| **SSH-Host** | Beim ersten Verbinden installiert Orca dort einen eigenen Dienst (Node, `orcad`, `node-pty`). Worktree, Terminals und Agents laufen dort und überleben einen zugeklappten Laptop. | Oberfläche, Editor, Diff. Dazu Port-Weiterleitung und Dateiübertragung. |
| **Remote Orca Server** | Ein ganzes Orca (Desktop oder `orca serve`) mit eigenen Projekten, Konten und Sitzungen | Nur die Oberfläche. Kopplung per Link mit widerrufbarer Berechtigung, empfohlen über Tailscale. |
| **Cloud-VM je Worktree** (experimentell) | Eine VM, die ein Rezept in `orca.yaml` anlegt, pausiert und wieder löscht (Vercel, Fly, Modal, Docker) | Den Cloud-Anbieter bringt der Nutzer mit. |

Für die Handy-App betreibt Orca ein eigenes Relay und einen Push-Dienst in der Cloud (`cloud/`).

Der SSH-Teil allein umfasst rund 26.000 Zeilen, die Laufzeit dahinter (`src/main/runtime/`) rund 287.000.

## Was Orca kann

### Agents

- rund 40 Agent-CLIs, je mit eigenem Ordner im Code
- Status aus Hooks, OSC 7501 und Fenstertitel, Subagents als Kindzeilen
- Agenten-Dashboard als Kanban (experimentell), Benachrichtigungen
- Übergabe an einen anderen Agent mit gezieltem oder vollem Kontext; bei erreichtem Limit schlägt der Dialog Agents mit anderem Limit vor
- Sitzung abzweigen, Verlauf mit Fortsetzen
- Ruhezustand (experimentell, ab Werk aus): fertige, unsichtbare Agents werden nach 30 Minuten beendet und beim Öffnen des Tabs mit denselben Einstellungen fortgesetzt; nicht bei offenen Aufträgen oder lebenden Subagents

### Git und Arbeitskopien

- Worktree je Aufgabe aus „Intelligent“, PR, Issue, Branch oder Name, mit Eltern- und Kind-Worktrees
- `orca.yaml` im Projekt: Skripte für Einrichtung und Aufräumen, Liste der Dateien, die in neue Worktrees mitkommen
- Diff mit Anmerkungen an einzelnen Zeilen, die an den Agent gehen
- Commit- und PR-Text aus dem Diff, fehlgeschlagene Checks und PR-Kommentare zurück an den Agent
- Konfliktansicht, Git-Graph, Checkpoints
- Aufgaben aus GitHub, GitLab, Linear, Jira, Azure DevOps, Bitbucket, Gitea

### Oberfläche

- neun Tab-Arten (`src/shared/tab-types.ts`): Terminal, Editor, Diff, Konflikt-Review, Check-Details, Git-Graph, Chat, Browser, Simulator. Unter „Editor“ laufen auch Markdown, Bilder, PDF, HTML-Vorschau und Notebooks.
- Plus-Menü mit Suchfeld, festen Einträgen und Agent-Liste je Rechner; Plugins können Einträge beisteuern
- Splits per Drag oder Tastenkürzel, verschachtelbar, je Worktree gemerkt
- Sprung zu jedem Workspace oder Tab über alle Projekte und Rechner
- rechte Leiste: Dateien, Änderungen, PR, Checks, Verlauf, Ports
- Plugins (Themes, Editoren, Sprachen, Panels), elf Sprachen

### Browser

- eingebettetes Chromium mit Profilen, Cookie-Import, Erweiterungen, Passwörtern
- Design-Modus: Element greifen, anmerken, hineinzeichnen, an einen wählbaren Agent senden (`src/main/browser/element-grab/`, `src/renderer/src/components/browser-pane/annotate/`)
- Steuerung durch Agents über `orca goto`, `orca snapshot`, `orca click` und weitere; dahinter das Werkzeug `agent-browser`, das per CDP an die sichtbare Seite gekoppelt ist (`src/main/browser/agent-browser/`)
- iOS-Simulator und Android-Emulator neben dem Agent, Steuerung von Desktop-Apps („Computer Use“)

Einzelheiten und der Weg für uns: [browser.md](browser.md).

### Orchestrierung und CLI

Ein Skill plus die `orca`-CLI (`skill-guides/orchestration.md`, `src/main/runtime/orchestration/`):

- Modell: Lauf mit Postfach → Aufgaben mit Abhängigkeiten → Versuch auf einem Terminal → Nachrichten → Entscheidungspunkte
- `worker-start` mit Worktree (aktueller, neuer Kind- oder neuer Haupt-Worktree), Agent, Modell, Aufwand und Zielrechner
- Abschlussmeldung genau einmal, Rückfragen als eigene Nachricht statt im Terminal
- Orca weckt den Koordinator; Nachfragen in Schleife verbietet der Skill
- Gruppenadressen wie `@idle` oder `@codex`
- übrige CLI: Worktrees, Terminals lesen und beschreiben, Dateien und Diffs öffnen, Browser, Emulator, Automatisierungen

### Konten und Verbrauch

- Claude: eigener Konfigurationsordner je Konto, wie bei uns. Dazu eine Shell-Funktion `claude`, damit auch ein von Hand getipptes `claude` das aktive Konto nimmt. Nach einem Wechsel fragt ein Dialog „N Sitzungen neu starten oder so lassen“.
- Codex: eigenes `CODEX_HOME` je Konto.
- Limits für über zehn Anbieter, Fenster für fünf Stunden, Tag und Woche, Warnung ab 80 %.
- Codex-Reset-Guthaben per Knopf einlösen (`src/main/rate-limits/providers/codex/codex-reset-credit-client.ts`).
- Kein Gegenstück zu unserem GPT-Backend: Es gibt keinen eingebauten Proxy, `ANTHROPIC_BASE_URL` wird nur durchgereicht.

### Ressourcen

- Messung über `ps` und auf dem Mac über einen 23-Zeilen-Helfer für `phys_footprint` (`native/process-footprint-macos/main.swift`)
- Baum Orca selbst → Projekt → Worktree → Terminal mit CPU, Speicher und Verlaufslinie; entfernte Rechner als eigener Zweig
- Aktionen: Sitzung beenden, alle lokalen beenden, Dienst neu starten, Worktree schlafen legen oder löschen, Aufräumen mit Blick auf den Plattenplatz
- Reiter „PTYs“: jedes Terminal mit Sitzung, Ordner, zugehörigem Tab, Prozess. Verwaiste Terminals werden erkannt und lassen sich beenden, nach einer Prüfung, ob inzwischen wieder jemand daran hängt.

### Sonstiges

- Automatisierungen mit Zeitplan, Nachholfrist und Vorabprüfung
- Diktat nur innerhalb der App, mit Offline-Modellen oder OpenAI
- Wachhalten in drei Stufen über `caffeinate`
- Artefakte als öffentliche Links
- Telemetrie ab Werk an
- macOS, Windows mit WSL, Linux

## Was wir uns abschauen können

1. **Terminals in einem eigenen Dienst.** Der größte Vorsprung.
2. **Arbeitskopie je Aufgabe**, gewählt beim Start, mit einer Liste der Änderungen daneben.
3. **Der Status aus dem Terminalstrom** als zweiter Kanal.
4. **Übergabe-Dialog** an einen anderen Agent.
5. **Ruhezustand** für fertige Chats.
6. **Plus-Menü als Suche und Startfläche.**
7. **Abschlussvertrag in der Orchestrierung:** genau eine Fertig-Meldung, Rückfragen als eigene Nachricht.
8. **Verwaiste Terminals erkennen.**

## Was wir nicht übernehmen sollten

- Vollzugriff als Voreinstellung
- Einträge in den Claude-Einstellungen des Nutzers für den Status
- den Chat-Modus über SDK und ACP
- den Katalog von 40 Agents
- Editor, Notebooks, Plugin-Katalog, Emulator, Steuerung von Desktop-Apps
- eigenes Relay und eigene Cloud-Dienste
