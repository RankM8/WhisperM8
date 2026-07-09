---
status: aktiv
updated: 2026-07-10
---

# CLI — das whisperm8-Binary

WhisperM8 liefert kein zweites CLI-Programm aus. Das Kommando `whisperm8`
zeigt per Symlink auf dasselbe Executable wie die macOS-App und aktiviert im
Prozess nur einen anderen Entry-Point-Pfad. Dadurch teilen sich GUI und CLI
denselben Keychain-Zugriff, dieselben Output-Modes und dieselbe
Agent-Job-Persistenz. Die Quelle belegt das gemeinsame Executable und den
Symlink auf `Bundle.main.executableURL`; die tatsächliche Code-Signatur eines
ausgelieferten Bundles ist Laufzeit-/Build-Artefakt und nicht aus dem
Quellcode ableitbar.

Das Binary hat drei CLI-Facetten:

| Facette | Zweck |
|---------|-------|
| `whisperm8 transcribe` | Speech-to-Text für Audio- oder Videodateien mit Groq oder OpenAI, optionalem Chunking, Ausgabeformaten und WhisperM8-OutputMode-Nachbearbeitung. |
| `whisperm8 agent` | Maschinenfreundliche Steuerung von Codex-Subagent-Jobs: starten, fortsetzen, listen, Status lesen, Logs ansehen, stoppen und entfernen. |
| `whisperm8 agent-supervise` | Interner Detach-Supervisor, der von WhisperM8 selbst gestartet wird und genau einen Codex-Turn fährt. |

Die fachliche Subagent-Dokumentation liegt unter
[../agent-chats/sub-agents/](../agent-chats/sub-agents/). Diese CLI-Doku
beschreibt nur das Binary, den Dispatch und die öffentlichen Befehle.

## Aufruf-Erkennung

`CLIModeDetector` entscheidet vor dem SwiftUI-Start, ob das gemeinsame Binary
als CLI oder als App läuft. Der normale CLI-Pfad ist der case-sensitive
Symlink-Name `whisperm8`; ein GUI-Launch über `WhisperM8` wird dadurch nicht
versehentlich als CLI behandelt. Zusätzlich erkennt der Detector bekannte
Subcommands als erstes Argument nach dem Programmnamen, damit Tests und
SwiftPM-Builds das App-Binary direkt mit `transcribe`, `modes`, `agent` oder
`agent-supervise` aufrufen können.

Der Dispatch liegt danach bei `CLICommand`: Hilfe, Version und `modes` sind
kleine Top-Level-Befehle, `transcribe` geht an `CLITranscribeCommand`, `agent`
an `AgentCLICommand`, und `agent-supervise` an `AgentSuperviseCommand`.

## Installation

Der CLI-Zugang ist ein Symlink unter `~/.local/bin/whisperm8`, der auf das
laufende App-Binary zeigt. Beim App-Launch startet WhisperM8 die Installation
im Hintergrund; dieselbe Logik kann in der Settings-Seite "CLI & Skills" über
"Create Link" manuell angestoßen werden. `CLISymlinkInstaller` legt den
Ordner an, ersetzt einen falschen Symlink, lässt eine reguläre Datei am
Zielpfad aber unangetastet und schreibt nur Debug-Logs bei Fehlern. Die
Settings-Seite zeigt den Status mit `CLIInstallStatus`, wenn der Link fehlt
oder auf eine andere App-Kopie zeigt.

Die gleiche Settings-Seite exportiert zwei Skills aus dem App-Bundle:
`whisperm8-transcription` für `transcribe` und `codex-subagent` für
`agent`. Für Claude Code installiert `CLISkillExporter` sie nach
`~/.claude/skills/<name>/SKILL.md`; beim Codex-Subagent-Skill werden zusätzlich
verwaltete Dateien unter `references/` geschrieben. Fremde Dateien in diesem
`references/`-Ordner bleiben erhalten. Für andere Tools kann die Settings-UI
den Markdown-Inhalt speichern, kopieren oder anzeigen.

## Transcribe

`whisperm8 transcribe <datei...>` extrahiert zuerst eine normalisierte
Audiospur, zerlegt lange Dateien bei Bedarf in Chunks, transkribiert diese mit
bounded concurrency und fügt Text sowie Segment-Timestamps wieder zusammen.
Audio und Video laufen durch denselben Pfad; Videos liefern ihre Audiospur.
Bei mehreren Eingaben ist `-o` verboten, und jedes Ergebnis wird neben die
jeweilige Quelldatei mit der gewählten Format-Endung geschrieben.

Die CLI ist hier Adapter und Batch-Hülle. Die fachlichen STT- und
Nachbearbeitungs-Schichten sind unter
[../dictation/transcription/](../dictation/transcription/) und
[../dictation/ai-output/](../dictation/ai-output/) dokumentiert.

Wichtige Optionen:

| Option | Bedeutung |
|--------|-----------|
| `-o`, `--output` | Schreibt in eine Datei; ohne explizites `--format` bestimmt die Dateiendung das Format. |
| `-f`, `--format` | `txt`, `json`, `srt` oder `vtt`; Untertitel brauchen Segment-Timestamps. |
| `--provider` | `groq` oder `openai`, Default ist Groq. |
| `--model` | Modell-Override; unpassende Provider-Modell-Kombinationen fallen auf den Provider-Default zurück. |
| `--mode` | Wählt einen WhisperM8-OutputMode; nur post-processing-fähige Modi laufen über Codex und verwerfen danach Segmente. |
| `--api-key` | Hat Vorrang vor Umgebungsvariable und Keychain. |
| `--chunk-seconds` | Überschreibt die Ziel-Chunk-Länge. |
| `--dry-run` | Prüft Datei, Dauer, Chunk-Schätzung und Kosten ohne API-Calls. |

Der API-Key wird in dieser Reihenfolge gesucht: explizites `--api-key`,
Provider-Umgebungsvariable (`GROQ_API_KEY` oder `OPENAI_API_KEY`) und danach
WhisperM8-Keychain. Das externe Laufzeitverhalten von Groq, OpenAI und
Codex-Post-Processing liegt außerhalb des CLI-Codes; WhisperM8 validiert nur
seine eigenen Optionen und behandelt transiente API-/Netzwerkfehler mit Retry.

## Modes

`whisperm8 modes` listet die post-processing-fähigen OutputModes für
`transcribe --mode`. Raw/Fast ist kein Post-Processing-Modus und erscheint
deshalb nicht in dieser Liste. Der Befehl weist darauf hin, dass
Nachbearbeitung die externe Codex-CLI voraussetzt; ob Codex installiert,
eingeloggt und lauffähig ist, ist externes Laufzeitverhalten.

## Agent

`whisperm8 agent` ist der öffentliche CLI-Namespace für Codex-Subagent-Jobs.
Die Befehle `run`, `send`, `wait`, `list`, `status`, `logs`, `stop` und `rm`
arbeiten gegen denselben Job-Store, den die App in Agent Chats darstellt.
`run` startet standardmäßig detached und gibt die Short-ID aus; mit `--wait`
startet der Job ebenfalls detacht, und der Aufrufer hängt sich nur als
Zuschauer an (Follow bis Turn-Ende). Stirbt der Zuschauer — Bash-Timeout,
Ctrl-C —, läuft der Job ungestört weiter; `agent wait <id>` hängt sich wieder
an und liefert bei ruhenden Jobs sofort das letzte Ergebnis. Den Turn beendet
ausschließlich `agent stop <id>`.
Mit `--json` schreibt der Befehl maschinenlesbare Objekte nach stdout.

Wichtige Optionen für `agent run`:

| Option | Bedeutung |
|--------|-----------|
| `--wait` | Startet detacht und folgt als Zuschauer bis zum Turn-Ende; Ctrl-C stoppt nur das Zuschauen, nicht den Turn. |
| `--json` | Gibt maschinenlesbare Statusobjekte auf stdout aus. |
| `--cd <dir>` | Setzt das Arbeitsverzeichnis; Default ist das aktuelle Verzeichnis. |
| `--sandbox <mode>` | `read-only` oder `workspace-write`, Default ist `workspace-write`. |
| `--model <name>` | Reicht einen Codex-Modell-Override an den Turn weiter. |
| `--effort <level>` | Reicht `model_reasoning_effort` als Codex-Config weiter. |
| `--allow-network` | Aktiviert Netzwerkzugriff in der workspace-write-Sandbox. |
| `--config <key=value>` | Reicht wiederholbare Codex-Config-Overrides als letzte `-c`-Werte weiter. |
| `--playwright-storage-state <path>` | Validiert und persistiert eine Storage-State-Datei für einen isolierten Playwright-MCP. |
| `--worktree` | Legt den Job in einem neuen Git-Worktree unter dem Job-Verzeichnis an. |
| `--parent <session-id>` | Speichert die externe Parent-Session-ID für die spätere App-Zuordnung. |

`send` reserviert ruhende Jobs atomar, schreibt den Folge-Prompt und startet
einen weiteren `codex exec resume`-Turn. Aktive Jobs, übernommene Jobs und Jobs
ohne Codex-Thread-ID werden als Zustandskonflikt behandelt. `logs` akzeptiert
`--tail N`.

`rm` entfernt das WhisperM8-Job-Verzeichnis, lässt die externe Codex-Session
unter `~/.codex/sessions/` aber bestehen. Bei Jobs mit `--worktree` versucht
der Befehl vorher, den Git-Worktree zu entfernen; bei uncommitteten Änderungen
bricht er mit Umgebungsfehler ab und lässt das Job-Verzeichnis stehen.

Details zu Job-Zuständen, Persistenz, Parent-Zuordnung und UI-Projektion
stehen in [../agent-chats/sub-agents/](../agent-chats/sub-agents/).

## Agent-Supervise

`agent-supervise <short-id>` ist kein Benutzerkommando. `AgentSupervisorLauncher`
startet es als Kindprozess desselben Binaries, leitet stdout und stderr in
`supervisor.log` um und setzt die Login-Shell-Umgebung. Der interne Befehl
löst sich per `setsid()` vom Terminal, ignoriert SIGHUP und behandelt SIGTERM
als Stop-Anforderung an `AgentJobSupervisor`.

## Exit-Codes

Die CLI hat zwei Exit-Code-Welten.

`transcribe`, `modes`, Hilfe und unbekannte Top-Level-Befehle verwenden die
klassische CLI-/sysexits-Logik: `0` für Erfolg, `64` für Usage-Fehler, `65`
für valide, aber nicht ausführbare Daten-/Optionskombinationen, `78` für
fehlende Konfiguration wie API-Keys und `1` für mindestens einen
dateibezogenen Laufzeitfehler in einer Batch-Transkription.

`agent` verwendet dagegen einen eigenen Maschinenvertrag mit kleinen Zahlen:

| Code | Bedeutung |
|------|-----------|
| `0` | ok, Job angelegt oder abgeschlossen |
| `1` | Usage-Fehler |
| `2` | Job fehlgeschlagen oder Report-Status `failure` |
| `3` | Zustandskonflikt wie aktiver, übernommener oder nicht fortsetzbarer Job |
| `4` | Umgebungsproblem wie fehlendes `codex`, zu alte Codex-Version oder unbekannter Job |

Dieser getrennte Vertrag ist wichtig, weil Claude Code und andere Tools beim
`agent`-Namespace nicht Text parsen müssen.

## Schlüsseldateien

- `WhisperM8/CLI/CLIEntryPoint.swift` entscheidet zwischen GUI-Start und CLI-Pfad, blockiert async CLI-Kommandos synchron und dispatcht Top-Level-Befehle.
- `WhisperM8/CLI/CLIArguments.swift` definiert Transcribe-Optionen, Ausgabeformate und den Parser für `whisperm8 transcribe`.
- `WhisperM8/CLI/CLITranscribe.swift` implementiert Key-Auflösung, Validierung, Datei-Pipeline, Chunk-Transkription, Retry, Dry-Run und `modes`.
- `WhisperM8/CLI/CLIAudioExtractor.swift` normalisiert Audio per AVFoundation und nutzt `ffmpeg` nur als externen Fallback für den Voll-Extract.
- `WhisperM8/CLI/CLIAudioChunker.swift` schneidet normalisierte Audiodateien silence-aware in API-taugliche Chunks.
- `WhisperM8/CLI/CLIOutputFormatter.swift` fügt Chunk-Ergebnisse zusammen und rendert `txt`, `json`, `srt` und `vtt`.
- `WhisperM8/CLI/AgentCLIArguments.swift` definiert Parser und Exit-Code-Vertrag des `agent`-Namespaces.
- `WhisperM8/CLI/AgentCLICommand.swift` implementiert `agent run`, `send`, `wait`, `list`, `status`, `logs`, `stop` und `rm`.
- `WhisperM8/CLI/AgentSuperviseCommand.swift` implementiert den internen detachten Supervisor-Modus `agent-supervise <short-id>`.
- `WhisperM8/Services/Shared/CLISymlinkInstaller.swift` verwaltet den Symlink `~/.local/bin/whisperm8` auf das aktuelle App-Binary.
- `WhisperM8/Services/Shared/CLISkillExporter.swift` exportiert die gebündelten CLI-Skills und ihren Installationsstatus für Claude Code.
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift` liefert einen korrigierten Login-Shell-PATH und bereinigte Prozessumgebungen für CLI-Subprozesse.
- `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift` ordnet Symlink-Status, Quickstarts und Skill-Export in die Settings-UI ein.

## Keywords

CLI, Kommandozeile, whisperm8-Binary, ein Binary, Symlink, App-Binary,
Speech-to-Text, Transkription, Audio transkribieren, Video transkribieren,
Untertitel, SRT, VTT, JSON-Ausgabe, Groq, OpenAI, Whisper, OutputMode,
Post-Processing, API-Key, Keychain, Dry-Run, Chunking, ffmpeg-Fallback,
Codex-Subagent, Subagent-Job, detached Supervisor, interner Supervisor,
Exit-Code, sysexits, Maschinenvertrag, `whisperm8`, `transcribe`, `modes`,
`--language`, `--provider`, `--model`, `--mode`, `--api-key`,
`--chunk-seconds`, `--dry-run`, `agent`, `agent run`, `agent send`,
`agent wait`, `agent list`, `agent status`, `agent logs`, `agent stop`, `agent rm`,
`agent-supervise`, `--worktree`, `--allow-network`, `--config`,
`--playwright-storage-state`, `--sandbox`, `--cd`, `--wait`, `--json`,
`--tail`, `--parent`, `--effort`,
`CLIModeDetector`, `CLICommand`, `CLIRuntime`, `CLIArgumentParser`,
`CLITranscribeCommand`, `CLIAudioExtractor`, `CLIAudioChunker`,
`CLIOutputFormatter`, `CLIKeyResolver`, `AgentCLICommand`,
`AgentCLIParser`, `AgentCLIExit`, `AgentRunCLI`, `AgentSendCLI`,
`AgentJobCLIShared`, `AgentSuperviseCommand`, `AgentSupervisorLauncher`,
`CLISymlinkInstaller`, `CLIInstallStatus`, `CLISkillExporter`,
`CLISkillsSettingsPage`, `LoginShellEnvironment`.
