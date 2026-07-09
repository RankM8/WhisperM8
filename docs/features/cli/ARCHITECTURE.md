---
status: aktiv
updated: 2026-07-09
---

# CLI — Architektur

Die CLI-Architektur ist ein Multiplex um dasselbe macOS-App-Binary:
`WhisperM8EntryPoint` entscheidet zuerst, ob der Prozess eine SwiftUI-App oder
ein CLI-Befehl ist. Im CLI-Fall ruft `CLIRuntime` den async Dispatch synchron
auf und beendet den Prozess mit dem jeweiligen Exit-Code.

## Entry-Point und Dispatch

`CLIModeDetector` erkennt CLI-Aufrufe über zwei Signale: `argv0` muss exakt
`whisperm8` heißen, oder das erste Argument nach dem Programmnamen muss ein
bekanntes CLI-Token sein. Diese zweite Variante ist für direkte
SwiftPM-/Bundle-Aufrufe wichtig und deckt auch den internen
`agent-supervise`-Start ab, bei dem `argv0` das App-Binary ist.

`CLICommand.run` ist der zentrale Top-Level-Dispatcher:

| Befehl | Ziel |
|--------|------|
| `help`, `--help`, `-h` | Hilfetext auf stdout |
| `--version`, `-v` | statische CLI-Version |
| `modes` | post-processing-fähige OutputModes |
| `transcribe` | `CLITranscribeCommand` |
| `agent` | `AgentCLICommand` |
| `agent-supervise` | `AgentSuperviseCommand` |

Die I/O-Regel ist strikt: Ergebnisdaten gehen nach stdout, Fortschritt,
Warnungen und Fehler nach stderr. Das macht `transcribe` pipe-fähig und hält
`agent --json` für aufrufende Tools stabil.

## Transcribe-Komponenten

`CLIArgumentParser` erzeugt `TranscribeOptions`, validiert bekannte Flags und
leitet bei `-o` ohne explizites `--format` das Ausgabeformat aus der
Dateiendung ab. Provider-Defaults werden erst nach dem Parsing aufgelöst:
Groq nutzt `whisper-large-v3-turbo`, OpenAI nutzt `gpt-4o-transcribe`.
Wenn ein explizites Modell nicht zum Provider passt, wird es verworfen und der
Provider-Default verwendet.

`CLITranscribeCommand` führt pro Datei dieselbe Pipeline aus:

1. Optionen und Kombinationen validieren.
2. API-Key aus `--api-key`, Provider-Environment oder Keychain auflösen.
3. Audio in ein temporäres `audio.m4a` normalisieren.
4. Dauer prüfen und Chunks erzeugen.
5. Chunks parallel begrenzt transkribieren.
6. Text und Segmente mit Chunk-Offsets zusammenfügen.
7. Optionalen OutputMode anwenden; nur bei Post-Processing werden Segmente verworfen.
8. Ergebnis rendern und nach stdout, `-o` oder quellnaher Datei schreiben.

Untertitel-Formate (`srt`, `vtt`) werden vor dem Lauf abgelehnt, wenn das
gewählte Modell keine Segmente liefert. `--mode` ist mit Untertitelformaten
ebenfalls unzulässig; bei post-processing-fähigen Modi entsteht Fließtext, und
die ursprünglichen Timestamps sind danach nicht mehr belastbar. Der Raw/Fast-
Modus ist selbst kein Post-Processing-Modus.

`CLIAudioExtractor` nutzt AVFoundation als Standardpfad und schreibt 16 kHz
Mono-AAC mit 32 kbit/s. Wenn AVFoundation beim Voll-Extract fehlschlägt, sucht
der Code `ffmpeg` im korrigierten Login-Shell-PATH und nutzt es als externen
Fallback; das konkrete Verhalten von `ffmpeg` ist externe Laufzeit und nicht
Teil des Swift-Vertrags. Für Chunk-Extracts wird kein `ffmpeg`-Fallback
verwendet.

`CLIAudioChunker` arbeitet auf der normalisierten Audiodatei. Dateien unter der
Ziel-Länge bleiben ein Chunk; längere Dateien werden silence-aware an
energiearmen Stellen um die Zielmarken geschnitten. Die Default-Ziellänge ist
90 Minuten, `--chunk-seconds` überschreibt sie.

`CLIOutputFormatter` rendert das zusammengefügte Ergebnis als Text, JSON, SRT
oder VTT. JSON enthält Text, Sprache, Dauer, Provider, Modell und Segmente;
SRT/VTT entstehen ausschließlich aus Segmenten.

## Agent-Komponenten

`AgentCLICommand` dispatcht den Namespace `whisperm8 agent`. Der Parser in
`AgentCLIArguments` trennt die Subcommands und erlaubt `--` als Grenze, damit
Prompts mit führendem Bindestrich als Positional erhalten bleiben.

`AgentRunCLI` prüft vor jedem Job `codex` per `CodexAgentPreflight`. Fehlt das
Binary, ist die Version zu alt oder kann der Job-State nicht angelegt werden,
endet der Befehl mit dem Agent-Environment-Code `4`. Ein erfolgreicher Start
schreibt `AgentJobState` als `spawning`, speichert den Prompt mit
WhisperM8-Report-Suffix und startet entweder inline oder detached.

`AgentSendCLI` arbeitet unter einem exklusiven Job-Lock. Der Code liest den
aktuellen State inklusive Orphan-Korrektur, sperrt aktive oder übernommene Jobs
und reserviert ruhende Jobs erst als `spawning`, bevor er den Folge-Prompt
schreibt. Dadurch können parallele `send`-Aufrufe nicht denselben ruhenden Job
gleichzeitig starten.

`AgentListCLI`, `AgentStatusCLI`, `AgentLogsCLI`, `AgentStopCLI` und
`AgentRemoveCLI` sind dünne Store-Kommandos. `status --json` serialisiert den
State und hängt nur bei `done` einen geparsten Report oder den Rohtext-Fallback
an, `logs` tailt `events.jsonl`, `stop` sendet SIGTERM an die Supervisor-PID
und `rm` löscht das WhisperM8-Job-Verzeichnis. Bei Worktree-Jobs versucht
`rm` vorher `git worktree remove` und bricht bei dirty Worktree vor dem
Job-Removal ab.

`AgentJobCLIShared` enthält die gemeinsamen Startpfade. Mit `--wait` erstellt
der aufrufende Prozess selbst einen `AgentJobSupervisor`, behandelt SIGINT als
Stop-Anforderung und gibt am Ende Status oder JSON aus. Ohne `--wait` startet
`AgentSupervisorLauncher` denselben Prozess im internen Modus
`agent-supervise <short-id>`, persistiert die PID als Liveness-Anker und gibt
die Short-ID zurück.

`AgentSuperviseCommand` ist der interne Kindprozess. Er löst sich mit
`setsid()` vom Terminal, ignoriert SIGHUP und setzt einen SIGTERM-Handler, der
`AgentJobSupervisor.requestStop()` auslöst. Der eigentliche Codex-Turn läuft
weiterhin über die Agent-Job-Schicht; Details dazu stehen in
[../agent-chats/sub-agents/ARCHITECTURE.md](../agent-chats/sub-agents/ARCHITECTURE.md).

## Subprozesse und Umgebung

Die CLI ist Consumer von `LoginShellEnvironment`; die Querschnitts-
Infrastruktur selbst gehört zur Top-Level-[Architektur](../../ARCHITECTURE.md).
Die Klasse fragt einmalig `/bin/zsh -l -c 'echo $PATH'` ab, merged das
Ergebnis mit einem konservativen Fallback und cached den Wert. Falls die
Login-Shell nicht funktioniert, bleibt der Fallback-PATH aktiv.

`processEnvironment()` erweitert die Umgebung um Terminal-Farbvariablen,
setzt bei Bedarf eine UTF-8-Locale und entfernt geerbte `CLAUDE_CODE_*`-
Variablen. Das verhindert, dass von WhisperM8 gestartete Agenten versehentlich
als Child-Session einer anderen Claude-Code-Session laufen.

Konkrete Nutzungen im CLI-Kontext:

| Ort | Verwendung |
|-----|------------|
| `CLIAudioExtractor` | `ffmpeg` wird über den korrigierten PATH gesucht und mit dieser Umgebung gestartet. |
| `AgentSupervisorLauncher` | der detachte `agent-supervise`-Prozess erhält dieselbe bereinigte Umgebung. |
| `CodexAgentPreflight` | `codex --version` läuft in der Login-Shell-Umgebung. |
| `CodexExecRunner` | `codex exec` läuft in der Login-Shell-Umgebung, aber mit `NO_COLOR=1` und `CLICOLOR=0` für saubere JSONL-Ausgaben. |
| `AgentWorktreeManager` | Git-Worktree-Operationen nutzen `/usr/bin/git` direkt und setzen keine eigene `process.environment`. |

Das Laufzeitverhalten von `codex`, `npx`, Playwright-MCP und `ffmpeg` ist
extern. WhisperM8 kontrolliert ihre Argumente, Umgebung und Exit-Code-
Auswertung, aber nicht deren Netzwerk, Installation oder Versionsdrift.

## Installation und Settings

`CLISymlinkInstaller` ist idempotent. Ein vorhandener korrekter Symlink bleibt
bestehen, ein falscher Symlink wird ersetzt, eine reguläre Datei unter
`~/.local/bin/whisperm8` wird nicht überschrieben. `CLIInstallStatus` ist die
lesende Gegenstelle für die Settings-Anzeige und unterscheidet `linked`,
`linkedElsewhere` und `missing`.

`CLISkillExporter` kapselt gebündelte Markdown-Ressourcen als
`SkillDefinition`. Die Transcription-Definition hat keine References; die
Codex-Agent-Definition installiert zusätzlich mehrere verwaltete
Reference-Dateien. `installedSkillIsCurrent` vergleicht `SKILL.md` und alle
verwalteten References bytegleich mit den Bundle-Ressourcen.

`CLISkillsSettingsPage` zeigt zuerst Skill-Karten, danach Command-Line-Status
und Quickstarts für Transkription sowie Codex-Subagents. Die Seite kann Skills
für Claude Code installieren, Markdown speichern, Markdown kopieren und eine
Vorschau öffnen.

## Invarianten und Gotchas

- Das gemeinsame Binary ist Absicht: Der CLI-Symlink nutzt denselben Prozesskontext wie die App und damit denselben Keychain-Zugriff; die Signatur des ausgelieferten Bundles ist kein Quellcode-Vertrag.
- `argv0 == whisperm8` ist case-sensitive; `WhisperM8` als App-Binary löst ohne Subcommand keinen CLI-Modus aus.
- stdout ist für Ergebnisdaten reserviert; Fortschritt und Fehler gehören auf stderr.
- `transcribe` nutzt sysexits-nahe Codes und kann bei mehreren Eingaben mit `1` enden, obwohl einzelne Dateien erfolgreich geschrieben wurden.
- Der `agent`-Namespace nutzt ausschließlich den Vertrag `0` bis `4`; dieser Vertrag ist unabhängig von den Transcribe-Codes.
- `agent-supervise` ist intern und wird nur vom Launcher benötigt, obwohl der Top-Level-Dispatcher das Token erkennen muss.
- Nur post-processing-fähige `--mode`-Werte machen aus einer segmentierten Transkription Fließtext; Raw/Fast ist kein Post-Processing-Modus.
- `ffmpeg` ist nur Fallback beim Voll-Extract, nicht beim späteren Chunk-Schneiden.
- `send` ist ein Ein-Turn-Resume, kein dauerhaft laufender Worker.
- `rm` entfernt den WhisperM8-Job, nicht die externe Codex-Historie; bei Worktree-Jobs kann dirty Git-State das Entfernen verhindern.

## Schlüsseldateien

- `WhisperM8/CLI/CLIEntryPoint.swift` enthält `WhisperM8EntryPoint`, `CLIModeDetector`, `CLIRuntime`, `CLICommand`, `CLIIO` und den Top-Level-Hilfetext.
- `WhisperM8/CLI/CLIArguments.swift` enthält `CLIOutputFormat`, `TranscribeOptions` und den Parser für Transcribe-Flags.
- `WhisperM8/CLI/CLITranscribe.swift` enthält die Transcribe-Orchestrierung, API-Key-Auflösung, Retry-Logik, Dry-Run und `modes`.
- `WhisperM8/CLI/CLIAudioExtractor.swift` enthält AVFoundation-Extraktion, `ffmpeg`-Fallback und CLI-Prozesssuche.
- `WhisperM8/CLI/CLIAudioChunker.swift` enthält Energieanalyse und silence-aware Split-Berechnung.
- `WhisperM8/CLI/CLIOutputFormatter.swift` enthält Stitching und Rendering für Text, JSON, SRT und VTT.
- `WhisperM8/CLI/AgentCLIArguments.swift` enthält `AgentCLIExit`, Run-/Send-Optionen und Parser für alle Agent-Subcommands.
- `WhisperM8/CLI/AgentCLICommand.swift` enthält den Agent-Dispatch, Start-/Send-/Status-/Log-/Stop-/Remove-Befehle und die finale Agent-Ausgabe.
- `WhisperM8/CLI/AgentSuperviseCommand.swift` enthält den internen Supervisor-Entry-Point mit Terminal-Detach und Signalbehandlung.
- `WhisperM8/Services/Shared/CLISymlinkInstaller.swift` enthält die idempotente Symlink-Installation für `~/.local/bin/whisperm8`.
- `WhisperM8/Services/Shared/CLISkillExporter.swift` enthält Skill-Definitionen, Bundle-Resource-Lesen, Claude-Code-Installation und CLI-Install-Status.
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift` enthält PATH-Auflösung, Environment-Bereinigung und Terminal-Defaults für Subprozesse.
- `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift` enthält Settings-UI für Symlink-Status, Quickstarts und Skill-Export.

## Test-Cluster

- `Tests/WhisperM8Tests/CLITranscriptionTests.swift` deckt CLI-Modus-Erkennung, Transcribe-Parsing, Modellfähigkeit, Formatter, Stitching, Chunk-Splits, Multipart-Envelope und Key-Auflösung ab.
- `Tests/WhisperM8Tests/AgentCLIArgumentsTests.swift` und `Tests/WhisperM8Tests/AgentCLIArgumentsPreviewTests.swift` decken Agent-Parser, Prompt-Grenzen und Preview-/Darstellungsfälle ab.
- `Tests/WhisperM8Tests/AgentCLICommandTests.swift` deckt Agent-Befehle, Statusausgabe und Exit-Code-Vertrag ab.
- `Tests/WhisperM8Tests/CLISkillExporterTests.swift` deckt Skill-Export, Installationsstatus und Symlink-Status ab.
- `Tests/WhisperM8Tests/LoginShellEnvironmentTests.swift` deckt PATH-Fallback, Merge-Verhalten und Prozessumgebung ab.
- `Tests/WhisperM8Tests/SupervisorJobReaderTests.swift` ergänzt den lesenden Zugriff auf Supervisor-/Job-Artefakte.
