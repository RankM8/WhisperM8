# Robustheits-Audit: Fehlerbehandlung und Datenintegrität

Stand: 2026-07-18. Geprüft wurden `WhisperM8/Services/`,
`WhisperM8/Models/` und `WhisperM8/CLI/`. Im vorgesehenen Kartenordner
`01-subsysteme/` lagen zum Prüfzeitpunkt keine Dateien. Der Report enthält nur
aus konkreten Codepfaden ableitbare Fehlerbilder; reine Stilfragen sind
ausgenommen.

## F1: Eine neuere `AgentSessions.json` wird entweder geleert oder verlustbehaftet heruntergestuft

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Models/AgentChat.swift:405-433, 577-603`;
`WhisperM8/Services/AgentChats/AgentSessionStore.swift:1168-1184`;
`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:33-65`

**Szenario (Auslöser → Wirkung für den User):** Der User öffnet nach einem
Downgrade eine `AgentSessions.json`, die von einer neueren WhisperM8-Version
geschrieben wurde. Enthält das neue Schema nur zusätzliche Felder, dekodiert
der alte Build sie zwar, setzt die höhere Versionsnummer aber bedingungslos auf
seine eigene Version zurück. Weil diese Änderung bereits als Migration gilt,
schreibt der Load-Pfad sofort eine alte Re-Encodierung zurück und entfernt alle
unbekannten Felder. Enthält das neue Schema dagegen einen unbekannten `provider`- oder
`status`-Enumwert, scheitert der Decode der gesamten Datei. Sind auch die drei
Generations-Backups mit dem neueren Schema geschrieben, startet die App mit
einem leeren Workspace. In beiden Fällen sieht der User fehlende Projekte oder
Sessions; im ersten Fall wird die Information beim nächsten Save dauerhaft aus
der Hauptdatei entfernt.

**Beweis:**

```swift
// AgentChat.swift:405-416
provider = try container.decode(AgentProvider.self, forKey: .provider)
// ...
status = try container.decodeIfPresent(AgentChatStatus.self, forKey: .status) ?? .pending

// AgentSessionStore.swift:1170-1174
static func migratedWorkspace(_ workspace: AgentWorkspace) -> AgentWorkspace {
    var migrated = workspace
    // ...
    migrated.schemaVersion = AgentWorkspace.currentSchemaVersion

// AgentWorkspaceRepository.swift:60-65
if let recovered = loadNewestDecodableGenerationBackup() {
    return migrate(recovered)
}
return .empty
```

Nur `kind` besitzt explizit einen lenienten Decoder
(`AgentChat.swift:431-433`); `provider` und `status` bleiben strikt. Außerdem
prüft `migratedWorkspace` nicht, ob `workspace.schemaVersion` größer als
`currentSchemaVersion` ist. `AgentWorkspaceRepository.loadBody` speichert jeden
vom geladenen Stand abweichenden Migrationsstand sofort (`:37-45`).

**Fix-Vorschlag:** Vor dem typisierten Decode zunächst nur den Envelope samt
`schemaVersion` lesen. Bei `version > current` die Datei weder migrieren noch
speichern, sondern den Workspace read-only öffnen oder eine klare Meldung
„mit neuerer WhisperM8-Version erstellt“ anzeigen. Für erweiterbare Enums eine
explizite Unknown-Strategie pro Datensatz definieren; keinesfalls wegen eines
einzigen unbekannten Session-Felds den gesamten Workspace verwerfen. Ein
Downgrade darf unbekannte Felder nicht durch Re-Encode entfernen.

**Konfidenz:** hoch — beide Verzweigungen folgen direkt aus den Decodern, der
bedingungslosen Versionszuweisung und dem `.empty`-Fallback.

## F2: Ein defektes `agent-ui-state.json` wird ohne Quarantäne oder Backup überschrieben

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:45-64, 94-125`

**Szenario (Auslöser → Wirkung für den User):** Die Sidecar-Datei ist nach
Dateisystemfehler, manueller Bearbeitung oder inkompatibler Schemaänderung
nicht dekodierbar. `loadUIState()` ersetzt sie durch eine First-Load-Migration
aus `AgentSessions.json` und schreibt diesen Ersatz sofort über denselben Pfad.
Offene Fenster und Tabs, Pins, Sidebar-Zustand und insbesondere die nur im
Sidecar gespeicherten Grid-Workspaces sind damit verloren. Anders als der
Workspace-Store legt dieser Pfad weder Generation-Backups an noch verschiebt er
die unlesbare Datei in Quarantäne.

**Beweis:**

```swift
// AgentSessionStore.swift:52-60
if FileManager.default.fileExists(atPath: uiStateFileURL.path) {
    do {
        let data = try Data(contentsOf: uiStateFileURL)
        state = try JSONDecoder().decode(AgentUIState.self, from: data)
    } catch {
        Logger.debug("AgentUIState load failed: \(error.localizedDescription) — falling back to first-load migration")
        state = AgentUIState.initialMigration(from: workspace)
        needsPersist = true
    }
}

// AgentSessionStore.swift:100-103
if needsPersist || diskData == nil || canonical == nil || diskData != canonical {
    do {
        try saveUIState(state)
```

`saveUIState` schreibt anschließend atomar direkt auf `uiStateFileURL`
(`:115-125`); ein Recovery-Lauf über ältere Generationen existiert hier nicht.

**Fix-Vorschlag:** Dieselbe Recovery-Policy wie für `AgentSessions.json`
verwenden: rotierende Last-known-good-Generationen, unlesbare Hauptdatei vor
jedem Ersatz als `decode-failed` sichern und zuerst das jüngste dekodierbare
Backup laden. Ohne Backup den rekonstruierten Zustand nur nach sichtbarer
User-Bestätigung über die defekte Datei schreiben.

**Konfidenz:** hoch — der Catch-Pfad setzt `needsPersist` und überschreibt die
Quelle im selben Aufruf deterministisch.

## F3: Fehlgeschlagene Workspace-Saves bleiben unsichtbar und werden nicht selbstständig erneut versucht

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:21-29, 226-241, 254-274`

**Szenario (Auslöser → Wirkung für den User):** Bei voller Platte, verlorenen
Schreibrechten oder einem transienten I/O-Fehler erstellt, löscht oder ändert
der User einen Chat. Die Produktions-Policy bestätigt die Mutation bereits im
Speicher und persistiert erst asynchron. Schlägt der Write fehl, gibt es nur
einen Logeintrag; die UI zeigt die Änderung weiter als erfolgreich. Der
Catch-Pfad setzt zwar `dirty = true`, plant aber keinen neuen Flush. Ohne eine
weitere Mutation, einen Fokuswechsel oder einen erfolgreichen Terminate-Flush
bleibt der Stand ausschließlich im RAM. Crash, Force-Quit oder ein ebenfalls
fehlschlagender einmaliger Terminate-Flush verlieren diese Änderungen.

**Beweis:**

```swift
// AgentWorkspaceStore.swift:226-241
do {
    try persist(workspace)
    // ...
} catch {
    Logger.agentStore.error("agent_store_flush_failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    lock.lock()
    dirty = true
    if firstDirtyAt == nil { firstDirtyAt = Date() }
    lock.unlock()
}
```

Der einzige Timer wird beim ursprünglichen `persistLocked` erzeugt
(`:254-274`). Der Catch-Pfad ruft weder `flushQueue.asyncAfter` noch `flush()`
auf und publiziert keinen Fehlerzustand an die UI.

**Fix-Vorschlag:** Nach Save-Fehlern einen begrenzten Retry mit exponentiellem
Backoff und Jitter planen, solange `dirty` ist. Zusätzlich einen beobachtbaren
Persistenzstatus bereitstellen und in der UI „Änderungen nicht gespeichert“
anzeigen. Vor App-Ende muss ein fehlgeschlagener finaler Flush sichtbar
behandelt werden; mindestens sollten die letzten Bytes in eine separate
Recovery-Datei geschrieben werden, statt still zu terminieren.

**Konfidenz:** hoch — fehlende Reschedule- und UI-Pfade sind im vollständigen
Catch-Block eindeutig.

## F4: Die Keychain-Migration löscht den einzigen API-Key auch dann, wenn das Speichern fehlschlägt

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/Shared/KeychainManager.swift:10-35, 37-69`

**Szenario (Auslöser → Wirkung für den User):** Ein Altbestand hält den
OpenAI-/Groq-Key noch in `UserDefaults`. Beim ersten Laden ist die Keychain
gesperrt, nicht beschreibbar oder `SecItemAdd`/`SecItemUpdate` schlägt aus einem
anderen Grund fehl. `save` meldet das nur im Log und kann dem Aufrufer keinen
Fehler liefern. `load` löscht den `UserDefaults`-Wert trotzdem und gibt den Key
für die aktuelle App-Laufzeit zurück. Nach dem nächsten Start ist der einzige
persistente Key weg; Diktat bricht mit „No API key configured“ ab.

**Beweis:**

```swift
// KeychainManager.swift:30-34
if status == errSecSuccess {
    setCached(value, for: key)
} else {
    Logger.permission.error("Keychain save failed for \(key): \(status)")
}

// KeychainManager.swift:61-66
if let oldValue = UserDefaults.standard.string(forKey: key), !oldValue.isEmpty {
    Logger.permission.info("Migrating API key from UserDefaults to Keychain")
    save(key: key, value: oldValue)
    UserDefaults.standard.removeObject(forKey: key)
    return oldValue
}
```

**Fix-Vorschlag:** `save` muss `throws` oder `Result<Void, KeychainError>`
liefern. Den Legacy-Wert erst nach `errSecSuccess` entfernen und den neuen Wert
zur Sicherheit erneut aus der Keychain lesen. Onboarding und Settings müssen
einen Save-Fehler anzeigen und dürfen keinen erfolgreichen Zustand vortäuschen.

**Konfidenz:** hoch — der Legacy-Wert wird unabhängig vom Security-Status
gelöscht.

## F5: Der GUI-Diktatpfad behandelt transiente 429/5xx- und Netzfehler ohne automatische Retry-Policy

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:184-210`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:30-37`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:11-39, 97-110`;
Vergleichspfad `WhisperM8/CLI/CLITranscribe.swift:200-238`

**Szenario (Auslöser → Wirkung für den User):** Ein langer Upload trifft einen
kurzen 429, Provider-5xx, `networkConnectionLost` oder
`cannotConnectToHost`. Der GUI-Pfad macht genau einen Request und wechselt
sofort in einen modalen Fehler-/manuellen Retry-Flow. Die Aufnahme bleibt
erfreulicherweise erhalten, aber der laufende Diktat-Flow ist unterbrochen; bei
429 kann der angebotene sofortige Button vor Ablauf des serverseitigen Limits
denselben Fehler wiederholen, weil `Retry-After` nicht ausgewertet wird. Der
CLI-Pfad besitzt für dieselben Klassen bereits bis zu vier Versuche mit
Backoff, die App jedoch nicht.

**Beweis:**

```swift
// MultipartTranscriptionClient.swift:194, 206-210
let (data, response) = try await session.upload(for: request, fromFile: bodyFileURL)
// ...
guard httpResponse.statusCode == 200 else {
    let errorBody = sanitizedErrorBody(data)
    throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
}

// RecordingCoordinator+Transcription.swift:33-37
let rawText = try await service.transcribe(
    audioURL: audioURL,
    language: language.isEmpty ? nil : language,
    audioDuration: audioDuration
)
```

Demgegenüber klassifiziert `CLITranscribe.isRetryable` 429, 5xx und ausgewählte
`URLError`s und wartet 2/4/8 Sekunden (`CLITranscribe.swift:200-238`).

**Fix-Vorschlag:** Die bereits im CLI vorhandene Klassifikation in einen
gemeinsamen Retry-Executor ziehen und auch im App-Pfad verwenden. Nur
idempotent wiederholbare Fehlerklassen retryen, `Retry-After` respektieren,
Jitter hinzufügen und Abbruch via `Task.checkCancellation()` erhalten. Im
Overlay Versuch und verbleibende Wartezeit anzeigen; nach Ausschöpfen bleibt
der vorhandene Preserve-/manuelle-Retry-Pfad bestehen.

**Konfidenz:** hoch — App und CLI verwenden nachweislich unterschiedliche
Policies für denselben Client.

## F6: Der Live-Statusparser versteht das im selben Repository dokumentierte Codex-JSONL-Schema nicht

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:112-153, 246-293`;
`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:10-29, 112-145`;
`WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:421-436`

**Szenario (Auslöser → Wirkung für den User):** Eine aktuelle Codex-Session
schreibt die im Reader dokumentierten Zeilen `event_msg` und `response_item`,
am Turn-Ende etwa `event_msg/payload.type = task_complete`. Der
Runtime-Watcher reicht genau diese Tail-Zeile an `AgentTranscriptParser`. Dessen
Codex-Zweig erkennt jedoch nur das ältere Paar `type = event`, `subtype =
turn.completed` beziehungsweise `type = item`. Aktuelle Zeilen fallen auf
`.other`: Nach 30 Sekunden wird die Session zwar heuristisch idle, aber
`turnFinished` bleibt `false`. Dadurch fehlen Turn-End-Bookkeeping,
Auto-Naming und Fertig-Notification oder sie kommen nicht zuverlässig.

**Beweis:**

```swift
// CodexTranscriptReader.swift:116-142 — das aktuelle Persistenzformat
switch outerType {
case "event_msg":
    guard let payload = obj["payload"] as? [String: Any] else { return nil }
    // user_message / agent_message / task_*
case "response_item":
    // ...

// AgentSessionTranscript.swift:117-140 — Statusparser
switch (type, subtype) {
case ("event", "turn.completed"),
     ("event", "agent_turn.completed"),
     ("event", "agent.message.completed"):
    return .assistantMessageStopped(timestamp: timestamp, stopReason: subtype)
// ...
case ("item", "user_message"):
    return .userMessage(timestamp: timestamp)
```

Der Default-Zweig liefert für die aktuellen Root-Typen `.other`
(`AgentSessionTranscript.swift:140-152`); der Decider setzt dafür niemals
`turnFinished = true` (`:285-292`).

**Fix-Vorschlag:** Den Statusparser auf dieselben `event_msg`-/`response_item`-
Subtypen wie den TranscriptReader ausrichten und Fixture-Tests mit echten
Rollout-Zeilen für `task_started`, `agent_message`, Tool-Events und
`task_complete` ergänzen. Unbekannte neue Typen weiterhin statusneutral
überspringen, nicht als Abschluss interpretieren.

**Konfidenz:** hoch — die beiden Parser im selben Code erwarten widersprüchliche
Root-Schemata.

## F7: Ein UTF-8-Zeichen am 1-MiB-Leselimit kann eine Claude-Session über Neustarts aus dem Index entfernen

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/BoundedJSONLReader.swift:19-34`;
`WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:90-108`;
`WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:44-51`

**Szenario (Auslöser → Wirkung für den User):** Bei einem Claude-Transcript
größer als 1 MiB schneidet der Prefix-Read exakt innerhalb eines mehrbyteigen
UTF-8-Zeichens ab. Obwohl alle vollständigen JSONL-Zeilen davor gültig sind,
fordert `lines` eine strikte UTF-8-Dekodierung des gesamten, am Ende
angeschnittenen Puffers. Das liefert `nil`; der Indexer markiert die komplette
Datei als nicht parsebar und speichert einen negativen Cache-Eintrag. Bleiben
mtime und Größe danach unverändert, wird die Session auch nach App-Neustarts
weiter als Cache-Hit mit `nil` übersprungen und verschwindet kommentarlos aus
der importierten Sessionliste.

**Beweis:**

```swift
// BoundedJSONLReader.swift:19-28
guard let data = readPrefix(from: fileURL, maxBytes: maxBytes),
      let text = String(data: data, encoding: .utf8) else {
    return nil
}
let lines = text
    .split(separator: "\n", omittingEmptySubsequences: true)
    .prefix(maxLines)

// ClaudeSessionIndexer.swift:91-98
if let parsed = parseSessionFile(fileURL, metadata: metadata, stats: &stats) {
    cache[.claude, fileURL, metadata] = parsed
    sessions.append(parsed)
} else {
    stats.skippedFiles += 1
    cache[.claude, fileURL, metadata] = nil
}
```

Der Cache-Key gilt weiter, solange Dateigröße und mtime gleich sind
(`AgentSessionIndexer.swift:44-51`).

**Fix-Vorschlag:** Nach dem bounded Read nur bis zum letzten vollständigen
Newline dekodieren oder mit `String(decoding:as:)` arbeiten und die letzte
angeschnittene Zeile grundsätzlich verwerfen. Negative Cache-Einträge sollten
bei Parser-/I/O-Fehlern nicht dauerhaft gespeichert werden; nur semantisch
sicher irrelevante Dateien dürfen negativ gecacht werden.

**Konfidenz:** hoch für den Mechanismus; mittel für die Auftretenshäufigkeit,
weil der Byte-Cutoff genau einen Mehrbyte-Codepoint treffen muss.

## F8: Nicht schreibbare Hook-Dateien deaktivieren Claude-Binding und Status stillschweigend

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:65-101`

**Szenario (Auslöser → Wirkung für den User):** Application Support ist voll,
nicht schreibbar oder enthält einen kollidierenden Pfad. Das Anlegen von Event-
oder Settings-Datei schlägt fehl. `prepareLaunch` wandelt den Fehler in eine
leere Argumentliste um, sodass Claude ohne `--settings` normal startet. Der
User erhält keine Warnung. Damit fehlen SessionStart-Binding und die
ereignisbasierten Arbeits-/Warte-/Endsignale; der spätere Indexer kann manches
heuristisch reparieren, aber eine ungebundene Session oder falsche
Statusanzeige bleibt möglich und der User weiß nicht, dass die robuste
Tracking-Schicht deaktiviert ist.

**Beweis:**

```swift
// ClaudeHookBridge.swift:67-71
func prepareLaunch(localSessionID: UUID) -> [String] {
    guard let path = prepareSettingsFile(localSessionID: localSessionID) else {
        return []
    }
    return ["--settings", path]
}

// ClaudeHookBridge.swift:98-100
} catch {
    Logger.claudeBinding.warning("hook_prepare_failed localID=\(localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    return nil
}
```

**Fix-Vorschlag:** `prepareLaunch` als `throws`/`Result` modellieren. Der Caller
soll sichtbar zwischen „Launch abbrechen“, „ohne Live-Tracking starten“ und
„erneut versuchen“ wählen können. Falls bewusst degradiert gestartet wird,
einen persistenten Warnstatus am Tab anzeigen und den Indexer-Fallback sofort
statt erst beim nächsten regulären Scan anstoßen.

**Konfidenz:** hoch — der Fehler wird ausschließlich geloggt und explizit in
einen Launch ohne Hook-Argumente übersetzt.

## F9: Korrupte Modus- oder Template-Dateien werden als leer behandelt und beim nächsten Edit überschrieben

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/OutputModeStore.swift:64-69, 118-134`;
`WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:23-55`

**Szenario (Auslöser → Wirkung für den User):** `OutputModes.json` oder
`PostProcessingTemplates.json` ist unvollständig, korrupt oder enthält nach
Schema-Drift ein nicht dekodierbares Feld. Der Load-Pfad liefert jeweils ein
leeres Array. Bei Output Modes zeigt die App daraufhin nur Built-ins; beim
nächsten Settings-Save werden die Custom Modes aus der korrupten Quelle nicht
mehr mitgeschrieben. Bei Templates reicht bereits „Duplizieren“: Die Funktion
lädt wegen des Fehlers `[]`, hängt genau das neue Duplikat an und überschreibt
damit alle bisherigen Custom Templates. Es gibt weder Backup noch Quarantäne
oder UI-Fehler.

**Beweis:**

```swift
// OutputModeStore.swift:64-69, 126-134
var loadedModes = loadModes()
if loadedModes.isEmpty {
    loadedModes = OutputMode.builtInModes
}
// ...
} catch {
    Logger.debug("Failed to load output modes: \(error.localizedDescription)")
    return []
}

// PostProcessingTemplateStore.swift:50-54
let duplicated = template.duplicated()
var customTemplates = loadCustomTemplates() // Decode-Fehler -> []
customTemplates.append(duplicated)
try saveCustomTemplates(customTemplates)
```

**Fix-Vorschlag:** Load-Ergebnis als `Result` statt „leer bedeutet fehlt oder
defekt“ modellieren. Nach Decode-Fehler alle mutierenden Aktionen sperren und
einen Recovery-Dialog anbieten. Atomare Writes um rotierende Backups und
`decode-failed`-Quarantäne ergänzen; neue optionale Felder lenient dekodieren.

**Konfidenz:** hoch — der nächste Mutationspfad baut seinen vollständigen
Snapshot nachweislich aus dem leeren Fehler-Fallback.

## F10: Eine defekte oder neuere Subagent-`state.json` erscheint als „Job nicht gefunden“

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:111-114, 229-246, 287-294`;
`WhisperM8/CLI/AgentCLICommand.swift:298-312`

**Szenario (Auslöser → Wirkung für den User):** Ein Job-Verzeichnis existiert
und sein Supervisor kann sogar noch laufen, aber `state.json` ist durch
Dateisystemfehler nicht dekodierbar oder stammt von einer neueren
WhisperM8-Version. `readState` liefert in beiden Fällen undiagnostiziert `nil`;
`agent list` überspringt das Verzeichnis, `agent status <id>` meldet „Job nicht
gefunden“. Es gibt kein Backup, keine Quarantäne, keine Unterscheidung zwischen
„fehlt“, „korrupt“ und „neueres Schema“. Der User kann den Job dadurch weder
verlässlich überwachen noch stoppen oder fortsetzen, obwohl `events.jsonl`,
Log und Codex-Session noch vorhanden sein können.

**Beweis:**

```swift
// AgentJobStore.swift:111-114
func readState(shortId: String) -> AgentJobState? {
    guard let data = try? Data(contentsOf: stateURL(for: shortId)) else { return nil }
    return Self.decode(data)
}

// AgentJobStore.swift:287-294
guard let state = try? decoder.decode(AgentJobState.self, from: data) else { return nil }
guard state.version <= AgentJobState.currentVersion else { return nil }
return state

// AgentCLICommand.swift:308-311
guard let state = store.readCorrected(shortId: shortId) else {
    CLIIO.err("Job \(shortId) nicht gefunden.")
    return AgentCLIExit.environment
}
```

**Fix-Vorschlag:** Einen typisierten Read-Fehler (`missing`, `io`, `corrupt`,
`newerSchema`) zurückgeben und ihn in CLI sowie App sichtbar ausgeben.
`state.json` mit mindestens einer Last-known-good-Generation sichern; bei
korruptem Hauptfile den Supervisor über PID/Log/Events als „Recovery nötig“
anzeigen statt den Job zu verstecken. Ein neueres Schema strikt read-only
lassen und die erforderliche App-Version nennen.

**Konfidenz:** hoch — alle Fehlerklassen kollabieren im aktuellen API auf
denselben `nil`-Wert.

## F11: Ein fehlgeschlagener Write der Codex-Thread-ID wird vollständig verschluckt und macht Folge-Turns unmöglich

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:188-217`;
`WhisperM8/CLI/AgentCLICommand.swift:212-239`

**Szenario (Auslöser → Wirkung für den User):** Beim ersten
`thread.started`-Event ist die Platte kurz voll oder der atomare
`state.json`-Rename schlägt fehl. Der Sink schluckt den Fehler ohne Log und der
Codex-Turn kann trotzdem erfolgreich bis `done` laufen. Der spätere
Done-Übergang schreibt einen gültigen Zustand, aber weiterhin ohne
`codexThreadID`. `agent send` verweigert danach jeden Folge-Turn mit „Resume
unmöglich“; der User soll den Job löschen und neu starten, obwohl Codex die
Thread-ID geliefert hatte und die zugrunde liegende Session existiert.

**Beweis:**

```swift
// AgentJobSupervisor.swift:211-216
func threadStarted(threadID: String) {
    _ = try? store.mutateState(shortId: shortId) { job in
        if job.codexThreadID == nil {
            job.codexThreadID = threadID
        }
    }
}

// AgentCLICommand.swift:224-226
guard state.codexThreadID != nil else {
    return .failure(.init(message: "Job \(options.shortId) hat keine Codex-Thread-ID (erster Turn kam nie bis thread.started) — Resume unmöglich. `agent rm` und neu starten.", exit: AgentCLIExit.stateConflict))
}
```

**Fix-Vorschlag:** Thread-ID-Persistenz darf kein `try?` sein. Den Event-Sink
fehlerfähig machen, den Write mit Backoff wiederholen und den Turn erst dann als
dauerhaft resumebar/done markieren, wenn die ID gesichert ist. Als zusätzliche
Recovery kann die ID aus `events.jsonl` beziehungsweise dem Codex-Rollout
rekonstruiert werden. Mindestens müssen Persistenzfehler im Jobstatus und Log
sichtbar sein.

**Konfidenz:** hoch — der Fehler wird explizit verworfen, während der
Folge-Turn dieselbe persistierte ID zwingend voraussetzt.
