# T3 Code: wie es gebaut ist und was es kann

**Stand:** 10.11.2026 · **Quelle:** <https://github.com/pingdotgg/t3code>, Stand vom selben Tag (v0.1.8, rund 55.000 Sterne, MIT)
**Methode:** Quelltext und Doku gelesen, nichts installiert oder gestartet. Aussagen über Tempo, Stabilität oder Speicherverbrauch sind deshalb keine Messwerte.
**Gehört zu:** [README.md](README.md) · [vergleich.md](vergleich.md) · [architektur.md](architektur.md)

## In einem Satz

T3 Code ist ein Server, der auf dem Rechner mit dem Projekt läuft und dort die Agents ausführt, plus drei Bedienoberflächen dafür (Desktop, Web, Handy). Die Chat-Oberfläche baut T3 selbst; Claudes eigene Terminal-Oberfläche kommt im normalen Chat nicht vor.

## Größe

| Teil | Zeilen (TypeScript, grob) |
|---|---|
| Server (`apps/server`) | 590.000 |
| Web-Oberfläche (`apps/web`) | 405.000 |
| Handy-App (`apps/mobile`) | 227.000 |
| Desktop-Hülle (`apps/desktop`, Electron) | 76.000 |
| Gemeinsame Pakete (`packages/*`) | rund 400.000 |

Zusammen etwa 1,6 Millionen Zeilen, gut zwölfmal so viel wie WhisperM8.

## Wie die Agents laufen

Das ist der wichtigste Unterschied zu uns. T3 startet die originalen Programme, aber nicht deren Oberfläche. Es spricht mit ihnen über eine Programmierschnittstelle und zeichnet den Chat selbst.

| Anbieter | Weg | Fundstelle |
|---|---|---|
| Claude Code | Claude Agent SDK, das originale `claude` läuft als Kindprozess ohne Terminal-Oberfläche | `apps/server/src/provider/ClaudeProvider.ts`, `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts` |
| Codex | `codex app-server`, strukturierte Ereignisse statt Terminal | `packages/effect-codex-app-server` |
| Cursor | Cursor Agent SDK | `packages/provider-cursor` |
| OpenCode | eigener OpenCode-Server je Chat oder je Instanz | `packages/provider-opencode` |
| Grok, fx, Kiro, Antigravity, weitere | ACP (gemeinsames Agent-Protokoll) | `packages/provider-acp`, `packages/provider-grok`, `packages/provider-fx`, `packages/provider-kiro` |
| Pi | `pi --mode rpc` | `packages/provider-pi` |
| Muse Code | Muse SDK | `packages/provider-muse` |

Daneben gibt es echte Shell-Terminals (`apps/server/src/terminal/`, gezeichnet mit libghostty). Darin könnte man `claude` von Hand starten, das wäre dann aber ein loses Terminal ohne Anbindung an Chat, Freigaben und Orchestrierung. Einen Schalter „diesen Chat als echte Claude-Oberfläche zeigen“ gibt es nicht.

### Was das für Claude-Funktionen heißt

„Echter Agent“ und „echte Oberfläche“ sind zwei verschiedene Dinge. T3 hat das erste, wir haben beides.

- **Funktioniert in T3:** Skills (auch aus Plugins, `ClaudeSkills.ts`), viele Slash-Befehle (T3 entdeckt die des Anbieters und ergänzt eigene), MCP-Server, Hooks grundsätzlich.
- **Fehlt in T3, weil es nur in Claudes Oberfläche lebt:** die Statuszeile, Bänder und Panes von Mods (so etwas wie unser Jarvis-Board), Claudes eigene Dialoge wie `/model`, Tastenbelegungen der TUI, jede neue interaktive Funktion, bis T3 sie nachgebaut hat.
- **Dafür gewinnt T3:** Fragen, Freigaben, Werkzeugausgaben und Diffs sind bei ihnen Daten, keine Bildschirminhalte. Das macht Handy-Antworten, Warteschlangen und Wiederverbinden einfach.

## Grundidee der Architektur

Aus `docs/internals/overview.md` und `docs/internals/remote.md`:

1. **Die Ausführung gehört dem Rechner mit dem Projekt** („Environment“). Dateien, Logins, Git, Terminals und Agent-Prozesse liegen dort. Jede Oberfläche, auch die Desktop-App auf demselben Rechner, ist nur Fernbedienung über eine angemeldete Verbindung.
2. **Absicht wird zuerst gespeichert, dann ausgeführt.** Ein Befehl wird mit Quittung in die Datenbank geschrieben, erst danach erledigt ein Arbeiter die Wirkung. Geht die Antwort verloren, startet dieselbe Aufgabe beim Wiederholen nicht doppelt (`apps/server/src/orchestration-v2/`).
3. **Jeder Anbieter sitzt hinter einem Adapter mit erklärten Fähigkeiten.** Kann ein Anbieter kein Zurückspulen, wird es dort nicht angeboten.
4. **Die Logik für Verbindung und Zustand ist geteilt** (`packages/client-runtime`), damit Web und Handy sich gleich verhalten.

## Andere Rechner

Ein Chat läuft dort, wo sein Environment läuft. Vier Wege führen zum selben Server:

| Weg | Was passiert | Voraussetzung |
|---|---|---|
| LAN oder direkt | Kopplung per Link oder QR-Code, danach widerrufbare Sitzung | Rechner erreichbar |
| Tailscale | dieselbe Verbindung über das private Netz | Tailscale auf beiden Seiten |
| SSH (nur Desktop) | die App startet den T3-Server auf dem Zielrechner und leitet einen Port weiter | SSH-Zugang, Linux oder Apple-Silicon-Mac |
| T3 Connect | Anmeldung in der Cloud, Tunnel ohne Router-Einstellung | Konto, Tunnel-Dienst eines Dritten im Datenweg |

Beim neuen Chat wählt man Projekt und Rechner. Eine Lastverteilung kann neue Chats nach freier CPU und freiem Speicher verteilen (`docs/user/remote-access.md`, Abschnitt „Balance new threads across machines“). Laufende Chats ziehen nicht um, Dateien werden nicht zwischen Rechnern abgeglichen. Über „Peer Links“ kann ein Agent Aufgaben auf einem anderen Rechner ausführen lassen.

Einschränkung: Bei der Desktop-App beendet das Schließen des letzten Fensters laut Doku den mitgelieferten Server. Dauerhaft läuft nur der eigens eingerichtete Hintergrunddienst.

## Was T3 Code kann

### Projekte und Chats

- Projekte mit und ohne Git, Klonen, neue Projekte, projektlose „Scratch“-Chats
- eigener Worktree oder Branch je Chat, wählbar vor dem Start
- derselbe Auftrag parallel an mehrere Modelle, je in eigenem Worktree
- Eingang mit Zuständen (arbeitet, aktiv, zurückgestellt, erledigt, Archiv), Zurückstellen mit Wiedervorlage, automatisches Erledigen nach gemergtem PR
- Suche über Titel, Branch, PR und Nachrichtentext
- Import vorhandener Claude-, Codex- und Pi-Verläufe, mit dokumentierten Grenzen
- Nebenchats für Zwischenfragen, Abzweigen und Zurückführen
- Warteschlange für Nachrichten und Eingreifen in laufende Arbeit
- Vorschau für Code, Markdown, HTML, PDF, Bilder und weitere Formate

### Geräte

- iOS- und Android-App mit Chats, Freigaben, Terminals, Dateien, PRs
- Push-Meldungen, Live-Aktivitäten und Widgets, auch für verbleibende Kontingente
- Entwürfe bleiben offline erhalten

### Git und Review

- Commit, Push, Branch und Worktree aus der App, vorgeschlagene Commit- und PR-Texte
- sieben Plattformen: GitHub, GitLab, Forgejo/Gitea, Bitbucket, Azure DevOps, GitCafe, Cursor Origin
- Review in der App: Beschreibung, Commits, Dateien, Kommentare, Reviewer, Merge, gestapelte PRs
- PR-Beobachtung: der Server weckt den Agent bei CI-Fehlern, Kommentaren oder Konflikten
- Checkpoints über versteckte Git-Refs, Zurückspulen von Gespräch und Dateien gemeinsam

### Orchestrierung

- Werkzeuge für Agents (`docs/orchestration-v2/orchestrator-mcp-server.md`): Aufgaben abgeben (`delegate_task`), Status, Abbruch, Chats auflisten, lesen, starten, anschreiben, unterbrechen
- auch Agents, die T3 nicht gestartet hat, können darüber steuern
- Zeitpläne (einmalig, Intervall, wiederkehrend) und Webhooks mit Signaturprüfung (`apps/server/src/scheduledTasks/`)
- Chats, die am Limit hängen, warten bis zum Reset und laufen dann weiter

### Konten und Verbrauch

- mehrere Konten je Anbieter über getrennte Instanzen (`docs/user/providers-claude.md`, `providers-codex.md`)
- fremde Modelle in Claude über OpenRouter oder einen eigenen Router, von Hand als Adresse und Schlüssel eingetragen
- Verbrauch über Anbieter, Konten und Rechner hinweg, mit Modellpreisen und Gegenwert

### Sprache, Browser, Sonstiges

- Diktat in das Eingabefeld, in Review-Kommentare und in Browser-Anmerkungen; lokal oder über OpenAI, Grok, OpenRouter; Wörterbücher und Glättung (`docs/user/voice-input.md`)
- eingebauter Browser, den Agent und Mensch gemeinsam benutzen, mit Elementauswahl und Anmerkungen
- Antworten als HTML-Seite (Diagramm, Tabelle, Entwurf) im Chat, MCP-Apps im Chat
- Simulatoren und Emulatoren ansehen und steuern
- Bildschirmfoto per globalem Tastenkürzel als Chat-Kontext
- Geheimnisse über 1Password-Verweise statt Klartext
- Gastlinks auf einen Chat, Diagnose-Chat für Fehler in T3 selbst

### Ressourcen

Ein eigener kleiner Rust-Prozess (`native/resource-monitor`) misst CPU, Speicher und Plattenzugriffe aller Prozesse. Gemessen wird nur, solange die Ansicht offen ist, im Sekundentakt, mit einer Stunde Verlauf im Speicher. Die Ansicht ist ein Prozessbaum mit Prozessnummern und Befehlen, nicht nach Chats benannt. Prozesse lassen sich gezielt beenden, vorher wird geprüft, ob die Nummer noch zum selben Prozess gehört (Nummer plus Startzeit).

Beim Terminal ist die Grenze des Verlaufs doppelt, 5.000 Zeilen und 8 MiB je Terminal, damit eine einzelne riesige Zeile die Grenze nicht umgeht.

## Was wir uns abschauen können

1. **Arbeit beginnt in einer eigenen Arbeitskopie.** Branch und Ordner stehen fest, bevor der Agent startet.
2. **„Angenommen“ und „ausgeführt“ trennen.** Unsere Sende-Strecke ist schon gegen Doppelsenden geschützt; das Prinzip mit Quittung gehört auch an Start- und Übergabe-Befehle.
3. **PR-Beobachtung, die den Chat weckt.** Passt direkt zu Jarvis.
4. **Messen nur bei offener Ansicht, Prozessnummer plus Startzeit.** Für unsere Ressourcenansicht.
5. **Doppelte Grenze für den Terminal-Verlauf.**

6. **Diagnose-Chat mit den Quellen der installierten Version.** T3 startet für Fehler in T3 selbst einen eigenen Chat, der Logs und die zur Version passenden Quellen lädt (`apps/server/src/triage/TriageService.ts`). Für Nutzer, die nicht entwickeln, ein kleiner, nützlicher Baustein.

## Fundstellen

Pfade relativ zum Repository, Stand 10.11.2026.

| Thema | Datei |
|---|---|
| Registrierte Anbieter | `apps/server/src/provider/builtInDrivers.ts` |
| Claude über SDK, Kindprozess ohne Terminal | `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts` |
| Codex über App-Server | `apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts`, `apps/server/src/provider/CodexProvider.ts` |
| Skills aus Claude-Plugins | `apps/server/src/provider/Drivers/ClaudeSkills.ts` |
| Echte Shell-Terminals, Verlaufsgrenzen | `apps/server/src/terminal/NodePtyAdapter.ts`, `apps/server/src/terminal/Manager.ts`, `docs/internals/terminal-runtime.md` |
| Konten je Anbieter | `apps/server/src/provider/Drivers/ClaudeDriver.ts`, `apps/server/src/provider/Drivers/CodexDriver.ts`, `docs/user/providers-claude.md`, `docs/user/providers-codex.md` |
| Verbrauch und Reset-Guthaben | `apps/server/src/usage/UsageService.ts`, `apps/server/src/provider/claudeResetCredits.ts`, `docs/user/usage.md` |
| Rechner, Wege, Kopplung | `docs/internals/remote.md`, `docs/user/remote-access.md`, `packages/client-runtime/src/connection/driver.ts`, `packages/ssh/src/tunnel.ts` |
| Lastverteilung | `packages/client-runtime/src/load-balancing.ts` |
| Werkzeuge für Agents | `apps/server/src/mcp/toolkits/orchestrator/tools.ts`, `docs/orchestration-v2/orchestrator-mcp-server.md` |
| Absicht, Quittung, Wirkung | `apps/server/src/orchestration-v2/EventSink.ts`, `apps/server/src/orchestration-v2/Orchestrator.ts`, `docs/internals/overview.md` |
| Zeitpläne und Webhooks | `apps/server/src/scheduledTasks/ScheduledTaskService.ts` |
| Übergabe zwischen Anbietern | `apps/server/src/orchestration-v2/ContextHandoffService.ts`, `packages/provider-core/src/server/handoffBudget.ts` |
| PR-Beobachtung | `apps/server/src/orchestration-v2/PullRequestWatchReactor.ts`, `docs/user/source-control.md` |
| Checkpoints und Zurückspulen | `apps/server/src/checkpointing/CheckpointStore.ts`, `apps/server/src/orchestration-v2/CheckpointRollbackService.ts` |
| Ressourcenmessung | `native/resource-monitor/src/main.rs`, `apps/server/src/resourceTelemetry/Model.ts`, `apps/server/src/diagnostics/ProcessDiagnostics.ts` |
| Browser | `apps/server/src/preview/ServerBrowser.ts`, `docs/user/browser-import.md` |
| Diktat | `apps/server/src/speech/SpeechService.ts`, `docs/user/voice-input.md` |

Zwei Fallen beim Nachlesen:

- `docs/internals/context-handoffs.md` ist überholt. Dort stehen nur kurze Zusammenfassungen; der aktuelle Code übergibt ganze Nachrichten bis zu einem Budget plus Verweise zum Nachladen.
- Das README nennt weniger Anbieter, als im Code registriert sind.

## Was wir nicht übernehmen sollten

- die eigene Chat-Oberfläche als Ersatz für das Terminal
- einen eigenen Cloud-Tunnel-Dienst
- elf Anbieter und sieben Git-Plattformen
- das vollständige Ereignis-Modell mit Datenbank-Quittungen für alles
