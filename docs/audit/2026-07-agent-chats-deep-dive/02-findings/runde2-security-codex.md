# Runde 2: Sicherheits- und Injection-Audit (Codex)

Stand: 2026-07-18. Statische Prüfung der Prozess-/Argument-Grenzen, Claude-Hooks,
Terminal-Links, Keychain-Nutzung und generierten Dateien. Bewertet wird eine lokale,
nicht sandboxte macOS-App; ein Prozess, der bereits beliebigen Code unter derselben UID
ausführt, ist daher nur dort ein relevanter Angreifer, wo WhisperM8 eine zusätzliche
Vertrauensgrenze öffnet (Keychain, langlebige Agent-Prozesse, persistente Zuordnung oder
bewusster Nutzerklick).

## Zusammenfassung

- kritisch: 0
- hoch: 2
- mittel: 3
- niedrig: 2

Kritischster Punkt ist die ungefilterte Weitergabe des kompletten Start-Environments an
Claude, Codex, MCP-Server und deren Tool-Prozesse (F1). Dadurch gelangen beim Start aus
einer Entwickler-Shell nicht nur `OPENAI_API_KEY`/`GROQ_API_KEY`, sondern potenziell auch
Cloud-Tokens und Capability-Sockets in Code, der absichtlich untrusted Projektinhalte
ausführt. Ebenfalls hoch ist der Keychain-Profilumzug, der das ausgelesene Claude-OAuth-
Secret erneut als sichtbares Prozessargument an `/usr/bin/security` übergibt (F2).

## F1: Vollständiges Parent-Environment wird an untrusted Agent-Prozesse vererbt

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`;
`WhisperM8/Views/AgentTerminalView.swift:749-770`;
`WhisperM8/Services/AgentChats/CodexExecRunner.swift:203-218`;
`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:241-258`;
`WhisperM8/Services/Dictation/CodexPostProcessor.swift:71-90`

**Angriffs-/Fehler-Szenario (Angreifermodell: präpariertes Projekt bzw. untrusted Tool-/MCP-Code):**
Ein Entwickler startet WhisperM8 über `make dev` oder aus einer Shell, in der etwa
`OPENAI_API_KEY`, `GROQ_API_KEY`, `AWS_*`, `GITHUB_TOKEN` oder `SSH_AUTH_SOCK` gesetzt
sind. `processEnvironment()` kopiert das gesamte Environment und entfernt ausschließlich
Claude-spezifische Variablen. Jeder danach gestartete Claude-/Codex-Prozess erhält die
übrigen Secrets. Von einem Agenten ausgeführter Projektcode, ein MCP-Server oder ein
schädliches Build-Skript kann sie aus dem Environment lesen. Bei Tokens ist das direkte
Credential-Disclosure; bei `SSH_AUTH_SOCK` wird eine Signier-Capability weitergereicht.
Die Codex-Dateisandbox verhindert das Lesen von Environment-Variablen durch gestartete
Kommandos nicht. Keychain-Werte werden zwar nicht aktiv exportiert, bereits im
Start-Environment vorhandene Keys aber sehr wohl.

**Beweis:**

```swift
func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env = base
    // ... nur CLAUDE_CODE_*, CLAUDECODE und CLAUDE_CONFIG_DIR werden entfernt ...
    env["PATH"] = path
    return env
}
```

```swift
var env = LoginShellEnvironment.shared.processEnvironment()
env["NO_COLOR"] = "1"
env["CLICOLOR"] = "0"
process.environment = env
```

**Fix-Vorschlag:** Für Agent-, Hook-, Summary-, MCP- und Postprocessing-Prozesse ein
minimales Allowlist-Environment aufbauen (`PATH`, `HOME`, `USER`, Locale, Terminalwerte
und explizite providerbezogene Overrides). Capability-Sockets und bekannte Secret-Muster
standardmäßig entfernen; notwendige Git-/SSH-Credentials pro Launch sichtbar opt-in
machen. Normale Shell-Tabs können separat eine bewusst großzügigere Policy bekommen.
Regressionstests sollten mindestens `OPENAI_API_KEY`, `GROQ_API_KEY`, `AWS_SECRET_ACCESS_KEY`,
`GITHUB_TOKEN` und `SSH_AUTH_SOCK` abdecken.

**Konfidenz:** hoch

## F2: Claude-OAuth-Secret erscheint beim Profil-Rename in der Prozessliste

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:326-342` und
`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:363-377`

**Angriffs-/Fehler-Szenario (Angreifermodell: fremder lokaler Prozess unter derselben UID):**
Beim Umbenennen eines eingeloggten Claude-Profils liest WhisperM8 das geschützte
Keychain-Secret mit `security find-generic-password -w` aus. Für das neue Item wird
dieses Secret anschließend als Wert direkt hinter `-w` in `Process.arguments` gestellt.
Ein lokaler Prozess, der die Prozessliste beziehungsweise argv regelmäßig abfragt, kann
das Claude-Credential im kurzen, aber realen Rename-Fenster auslesen. Damit wird die
Keychain-Zugriffskontrolle umgangen: Der beobachtende Prozess muss das Keychain-Item
nicht selbst öffnen können.

**Beweis:**

```swift
let (readStatus, secret) = securityRunner([
    "find-generic-password", "-s", oldService, "-w"
])
let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
// ...
let (addStatus, _) = securityRunner([
    "add-generic-password", "-a", account, "-s", newService,
    "-l", newService, "-w", trimmedSecret, "-U",
])
```

Der Default-Runner setzt dieses Array unverändert als argv:

```swift
process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
process.arguments = arguments
```

**Fix-Vorschlag:** Den Profilumzug vollständig mit Security.framework implementieren:
`SecItemCopyMatching` für den alten Wert, `SecItemAdd`/`SecItemUpdate` für das neue Item
und erst danach `SecItemDelete`. Das Secret darf weder argv noch Environment berühren.
Die Operation sollte außerdem die bisherigen Zugriffsattribute explizit erhalten und
den Secret-Puffer möglichst kurzlebig halten.

**Konfidenz:** hoch

## F3: `--api-key` exponiert Transkriptions-Keys über argv und Shell-History

**Schweregrad:** mittel

**Fundort:** `WhisperM8/CLI/CLIArguments.swift:67-125`;
`WhisperM8/CLI/CLIEntryPoint.swift:145-169`;
`WhisperM8/CLI/CLITranscribe.swift:46-55` und
`WhisperM8/CLI/CLITranscribe.swift:307-319`

**Angriffs-/Fehler-Szenario (Angreifermodell: fremder lokaler Prozess oder späterer
Zugriff auf die Shell-History):** Die dokumentierte Form
`whisperm8 transcribe ... --api-key <secret>` hält den API-Key während der potenziell
mehrminütigen Transkription im argv des WhisperM8-Prozesses. Andere Prozesse desselben
Users können ihn aus der Prozessliste lesen; bei direkter Eingabe landet er regelmäßig
zusätzlich in der History der aufrufenden Shell. Dass Keychain und Environment als
Alternativen existieren, beseitigt die Exposition des ausdrücklich angebotenen Flags
nicht.

**Beweis:**

```swift
case "--api-key":
    options.apiKey = try nextValue(for: arg)
```

```swift
--api-key <key>       API-Key explizit (sonst env bzw. Keychain).
```

**Fix-Vorschlag:** Das Klartext-Flag entfernen oder deutlich deprecaten. Für Automation
`--api-key-stdin` beziehungsweise einen benannten Keychain-Account anbieten; bei TTY
verdeckt interaktiv lesen. Environment bleibt weniger history-anfällig, sollte wegen F1
aber nicht ungefiltert an Kindprozesse weitergereicht werden.

**Konfidenz:** hoch

## F4: Chat- und Summary-Inhalte werden als langlebige Prozessargumente übergeben

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:170-225` und
`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:282-350`;
`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:356-385`;
`WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-39`

**Angriffs-/Fehler-Szenario (Angreifermodell: fremder lokaler Prozess unter derselben UID):**
Der Initial-Prompt wird bei interaktiven Claude-/Codex-Chats als einzelnes argv-Element
angehängt. Der Agent-Prozess kann stundenlang leben; sein ursprüngliches argv bleibt in
dieser Zeit inspizierbar. Background-Prompts und automatisch erzeugte Summary-Prompts
mit Transkriptauszügen werden ebenfalls per argv transportiert. So können vertrauliche
Aufgaben, Codeauszüge, Dateinamen oder Gesprächsinhalte außerhalb der App-Persistenz
ausgelesen werden. Dies ist keine Shell-Injection: Quotes, Semikolons, Backticks und
`$()` bleiben ein einzelnes Argument. Das Problem ist die Vertraulichkeit von argv.

**Beweis:**

```swift
if let initialPrompt = session.initialPrompt, !initialPrompt.isEmpty {
    arguments.append(initialPrompt)
}
```

```swift
case .claude:
    args = ["-p", prompt, "--output-format", "text"]
case .codex:
    args = ["exec", "--skip-git-repo-check", prompt]
```

**Fix-Vorschlag:** Prompts über stdin beziehungsweise die bestehende PTY-Eingabe nach
dem Launch zustellen. `CodexExecRunner` und `CodexPostProcessor` zeigen bereits das
richtige Muster (`-` als Promptquelle plus Pipe). Für CLIs ohne geeigneten stdin-Modus
eine 0600-Datei mit sofortigem Cleanup nur als letzte Option nutzen.

**Konfidenz:** hoch

## F5: Untrusted OSC-8-Links dürfen beliebige URL-Schemes und lokale Ziele öffnen

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/TerminalLinkResolver.swift:45-83` und
`WhisperM8/Views/TerminalLinkResolver.swift:88-120`;
`WhisperM8/Views/AgentTerminalView.swift:910-955`;
`WhisperM8/Services/Shared/PhpStormLauncher.swift:27-47`

**Angriffs-/Fehler-Szenario (Angreifermodell: untrusted Terminal-Output):** Ein Programm,
Build-Skript oder Remote-Output kann einen OSC-8-Hyperlink mit harmloser sichtbarer
Beschriftung, aber einem frei gewählten Ziel emittieren. Der Resolver akzeptiert jedes
syntaktische `scheme://` und leitet es nach einem Cmd-Klick ohne Scheme-Allowlist oder
Bestätigung an LaunchServices weiter. Damit sind unter anderem Netzwerk-Schemes,
registrierte Custom-Deep-Links und potenziell aktive lokale Dateitypen erreichbar.
Absolute `file:`- und nackte Pfade sind ebenfalls nicht auf Projekt/Worktree begrenzt.
Es ist kein Zero-Click: Der Nutzer muss den Link anklicken. Der Klick ist wegen der vom
Ziel unabhängigen OSC-8-Beschriftung aber keine informierte Bestätigung.

**Beweis:**

```swift
if hasAuthorityScheme(link)
    || bareSchemes.contains(where: { link.lowercased().hasPrefix($0) }) {
    if let url = URL(string: link) { return .openWeb(url) }
}
```

```swift
case .openWeb(let url), .openFile(let url), .openFolder(let url):
    NSWorkspace.shared.open(url)
```

PhpStorm selbst wird sicher ohne Shell gestartet (`process.arguments = [path]`); die
Schwachstelle liegt in der vorgelagerten Vertrauensentscheidung, nicht im
PhpStorm-Argumentbau.

**Fix-Vorschlag:** Automatisch nur `https`/`http` (optional `mailto`) erlauben. Für andere
Schemes und lokale Ziele außerhalb des aktuellen Projekts einen Dialog mit vollständigem,
nicht verkürztem Ziel und Handler-App anzeigen. Aktive lokale Typen wie `.command`,
`.app`, `.pkg`, `.dmg`, Skripte und unbekannte Custom-Schemes standardmäßig ablehnen
oder ausschließlich im Finder anzeigen.

**Konfidenz:** hoch

## F6: Subagent-Artefakte mit Prompts und Output erhalten keine restriktiven Modi

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:102-130` und
`WhisperM8/Services/AgentChats/AgentJobStore.swift:190-224`;
`WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-49`

**Angriffs-/Fehler-Szenario (Angreifermodell: anderer lokaler Account bei permissivem
Home-/ACL-Setup oder Backup-/Sync-Prozess):** Job-Verzeichnisse und -Dateien werden ohne
explizite POSIX-Modi erzeugt. Unter dem üblichen umask `022` entstehen Verzeichnisse als
0755 und Dateien als 0644. `state.json` enthält unter anderem Intent, cwd und Config-
Overrides; `pending-prompt.txt`, `events.jsonl`, `last-message.txt` und `supervisor.log`
enthalten Prompt- beziehungsweise Agent-Inhalte. Auf einem normalen modernen macOS
schützt das Home-Verzeichnis meist zusätzlich, daher nur „niedrig“; WhisperM8 selbst
garantiert die Vertraulichkeit aber nicht. Anders als bei den Hook-Dateien wird 0600
nicht gesetzt.

**Beweis:**

```swift
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try data.write(to: temp)
// ...
try prompt.write(to: pendingPromptURL(for: shortId), atomically: true, encoding: .utf8)
```

```swift
FileManager.default.createFile(atPath: logURL.path, contents: nil)
```

**Fix-Vorschlag:** `agent-jobs` und jedes Job-Verzeichnis mit 0700 anlegen; alle
Artefakte bei der Erstellung mit 0600 öffnen. Für atomare Writes Modus am Temp-File vor
`rename(2)` setzen. Existierende Installationen einmalig nachhärten und bei allen
Schreibpfaden Symlinks beziehungsweise nicht-reguläre Ziele per `lstat`/`O_NOFOLLOW`
ablehnen.

**Konfidenz:** mittel bis hoch (der effektive Zugriff hängt zusätzlich von umask und
übergeordneten ACLs ab)

## F7: Hook-Eventdatei ist semantisch nicht authentisiert

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:59-136`;
`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:202-229`;
`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:200-225` und
`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-360`

**Angriffs-/Fehler-Szenario (Angreifermodell: fremder Prozess unter derselben UID,
insbesondere aus einem untrusted Agent-Tool):** Die Eventdatei ist korrekt 0600, aber
alle Prozesse desselben Users können sie weiterhin öffnen. Jede parsebare JSON-Zeile
wird ohne Launch-Nonce, PID-/Ancestry-Bindung, erwartete cwd-Prüfung oder Validierung der
Claude-Session-ID ausgeliefert. Eine eingeschleuste `SessionStart`-Zeile kann dadurch
eine beliebige `session_id` dauerhaft an den lokalen Chat binden; `Stop` oder
`PermissionRequest` können Status, Ton und Notifications vortäuschen. Das ist wegen der
generell fehlenden Dateisystem-Isolation zwischen Prozessen derselben UID kein hoher
Privilege-Escalation-Befund, aber eine konkrete Integritätslücke an der Hook-Grenze.

**Beweis:**

```swift
let nameRaw = (object["hook_event_name"] as? String) ?? "other"
return ClaudeHookEvent(
    hookEventName: name,
    sessionID: object["session_id"] as? String,
    transcriptPath: object["transcript_path"] as? String,
    cwd: object["cwd"] as? String,
    // ...
)
```

```swift
if event.hookEventName == .sessionStart {
    bindExternalSessionID(localID: localID, event: event)
}
```

**Fix-Vorschlag:** Vor der Zustandsmaschine mindestens UUID-Format, erwartete cwd,
Transcript-Pfad unter einem bekannten Claude-Root und plausible Event-Reihenfolge
prüfen. Stärkere Bindung über einen pro Launch erzeugten Kanal beziehungsweise eine
Launch-Nonce plus Prozess-Ancestry erwägen; eine bloß neben der Eventdatei gespeicherte
Nonce schützt nicht gegen denselben User. Fremde/ungültige Zeilen mit begrenzter Rate
loggen, aber nie persistente Bindings daraus erzeugen.

**Konfidenz:** hoch

## Geprüfte Grenzen ohne Security-Finding

- Der einzige echte `zsh -l -c`-Aufruf ist
  `process.arguments = ["-l", "-c", "echo $PATH"]`; es werden keine Projektpfade,
  Dateinamen oder Prompts in diesen Shell-String interpoliert
  (`LoginShellEnvironment.swift:166-185`).
- Agent-, Git-, ffmpeg-, screencapture- und PhpStorm-Aufrufe verwenden
  `Process.arguments`-Arrays. Leerzeichen, Quotes, Semikolons, Backticks und `$()` in
  Projekt- oder Dateipfaden werden deshalb nicht von einer Shell ausgewertet. Bei
  Git-Lookups ist zusätzlich das Binary fest `/usr/bin/git`. Sonderzeichen führen hier
  weder zu Shell-Injection noch zum Aufspalten eines Arguments.
- `ClaudeHookSettingsBuilder` serialisiert JSON mit `JSONSerialization` und schützt im
  doppelt gequoteten Shell-Pfad `\`, `"`, `$` und Backticks. Damit bleiben Leerzeichen,
  Semikolons und Command Substitution inert. Der reale Eventpfad besteht zudem aus dem
  App-Support-Root und einer UUID (`ClaudeHookSettingsBuilder.swift:42-115,
  129-148`).
- `CodexExecRunner.tomlEscape` schützt Backslash und Quote, sodass Projektpfade nicht aus
  dem TOML-String ausbrechen. Ein Dateiname mit einem literalen Newline/Control-Byte kann
  die TOML-Config allerdings unparsebar machen; das ist nach aktuellem Datenfluss
  Fehlverhalten, keine belegte Code-Injection (`CodexExecRunner.swift:170-178`).
- `TerminalDropPayload` backslash-escaped Shell-Metazeichen einschließlich Quotes,
  Semikolon, Backtick, Dollar und Klammern. Ein Newline im Dateinamen wird als
  Backslash-Newline eingegeben und kann deshalb den Pfad verfälschen, erzeugt aber keine
  zweite Shell-Anweisung (`AgentTerminalView.swift:1117-1153`).
- `KeychainManager` legt Generic-Password-Items unter dem festen Service
  `com.whisperm8.app` an und loggt nur Account-Keynamen/OSStatus, nie den Wert. Es gibt
  kein explizites `kSecAttrAccessible`/`SecAccessControl`; für den vorliegenden lokalen
  Angreiferpfad ist daraus allein ohne belegten Zugriffsbypass kein Finding abzuleiten
  (`KeychainManager.swift:4-69`).
- Die Hook-Settings- und Eventdateien werden nach atomarem Schreiben auf 0600 gesetzt.
  `CLISymlinkInstaller` entfernt bei einem abweichenden vorhandenen Symlink den Link
  selbst, nicht dessen Ziel; eine reguläre Datei wird nicht überschrieben
  (`ClaudeHookSettingsBuilder.swift:70-81`, `ClaudeHookBridge.swift:79-96`,
  `CLISymlinkInstaller.swift:18-36`). Das ungefragte Ersetzen eines nutzerverwalteten
  abweichenden Symlinks ist ein Produkt-/Ownership-Problem, aber ohne zusätzliche
  Angreiferwirkung kein Security-Finding.
- Die generierten Codex-/Claude-Login-`.command`-Dateien interpolieren aufgelöste
  CLI-Pfade in Shell-Quelltext. Pfade mit `"`, `$` oder Backticks sind dort nicht robust
  escaped und können den Login-Start beschädigen. Ein lokaler Angreifer, der PATH und
  ein ausführbares CLI-Ziel bereits kontrolliert, besitzt jedoch schon Codeausführung
  unter derselben UID; deshalb wird dies hier als Quoting-Fehlverhalten und nicht als
  eigenständige Sicherheitslücke bewertet (`CodexSupport.swift:197-213`,
  `AgentChatsClaudeAccountsTab.swift:376-395`).
