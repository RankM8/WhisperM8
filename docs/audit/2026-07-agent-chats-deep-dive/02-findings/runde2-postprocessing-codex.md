# Runde 2: Diktat-Postprocessing und Output-Modes

Geprüft wurden die GUI- und CLI-Pfade von der erfolgreichen Transkription über Prompt-Bau und `codex exec` bis Clipboard/Auto-Paste und Run-Report. Die Findings beziehen sich auf den Codezustand vom 18.07.2026. Zusammenfassung: **0 kritisch, 4 hoch, 6 mittel, 0 niedrig**.

## F1: Codex-Prozesse haben keine Deadline und lassen sich nicht zuverlässig beenden

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/Dictation/CodexPostProcessor.swift:55-58, 102-128`; `WhisperM8/Services/Dictation/CodexSupport.swift:30-39, 239-259`

**Szenario (Auslöser → Wirkung für den User):** `codex login status` oder der eigentliche `codex exec` hängt wegen eines defekten/veralteten Wrappers, einer Netzwerkstörung oder eines nicht terminierenden Tool-Subprozesses. Beide Pfade warten unbegrenzt mit `waitUntilExit()`. Die Statusprobe ist überhaupt nicht im Prozessregister registriert; beim eigentlichen Lauf sendet Cancel nur einmal `SIGTERM` an den direkten `Process`, ohne Frist, `SIGKILL`-Eskalation oder Prozessgruppen-Cleanup. Ignoriert Codex das Signal oder hält ein Kindprozess die Handles offen, bleibt WhisperM8 dauerhaft in „Improving…“ und der Run blockiert weitere Aufnahmen. Auch der CLI-Aufruf kann unbegrenzt hängen.

**Beweis:**

```swift
// CodexSupport.swift:252-255 — Statusprobe ohne Timeout/Cancel-Registrierung
try process.run()
process.waitUntilExit()
let data = output.fileHandleForReading.readDataToEndOfFile()

// CodexPostProcessor.swift:116-128 — eigentlicher Lauf ebenfalls ohne Deadline
process.waitUntilExit()
// ...
let wasCancelledByUser = CodexProcessRegistry.shared.didCancel
CodexProcessRegistry.shared.unregister(process)

// CodexSupport.swift:37-39 — nur einfacher SIGTERM an den direkten Prozess
guard let process, process.isRunning else { return false }
process.terminate()
return true
```

**Fix-Vorschlag:** Statusprobe und Exec über einen gemeinsamen asynchronen Process-Runner mit harter Deadline ausführen. Bei Task-Cancel/Timeout zunächst die gesamte Prozessgruppe terminieren, nach kurzer Grace-Period mit `SIGKILL` eskalieren, Pipes schließen/drainen und in einem `defer` immer deregistrieren. Die Statusprobe ebenfalls cancelbar machen; ein Probe-Timeout muss als sichtbarer, retrybarer Codex-Fehler auf Raw zurückfallen.

**Konfidenz:** hoch — beide synchronen, unbegrenzten Waits und die fehlende Kill-Eskalation sind direkt im Spawn-Pfad sichtbar.

## F2: Cancel vor der Prozessregistrierung wird still verworfen

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:174-180`; `WhisperM8/Services/Dictation/CodexPostProcessor.swift:25-30, 102-110`; `WhisperM8/Services/Dictation/CodexSupport.swift:15-19, 32-39, 47-49`

**Szenario (Auslöser → Wirkung für den User):** Sobald das Overlay „Improving…“ zeigt, drückt der User Cancel, während noch `codex login status` läuft oder zwischen `process.run()` und `register()`. Das Register hat noch keinen Prozess, setzt aber `cancelledByUser = true` und liefert `false`. Der spätere `resetCancelFlag()` beziehungsweise `register()` setzt dasselbe Flag wieder auf `false`; der Codex-Lauf startet und läuft trotz sichtbarem Abbruch weiter.

**Beweis:**

```swift
// RecordingCoordinator+Transcription.swift:174-180
appState.isPostProcessing = true
// ...
let processedText = try await postProcessingService.process(...)

// CodexPostProcessor.swift:102-106
CodexProcessRegistry.shared.resetCancelFlag()
try process.run()
CodexProcessRegistry.shared.register(process)

// CodexSupport.swift:32-38
let process = current
cancelledByUser = true
// ...
guard let process, process.isRunning else { return false }
process.terminate()

// CodexSupport.swift:15-19
current = process
cancelledByUser = false
```

**Fix-Vorschlag:** Pro Run eine eindeutige Run-ID und einen persistenten Cancellation-State anlegen, bevor die UI in Post-Processing wechselt. Registrierung darf einen bereits gesetzten Cancel-Wunsch nicht löschen; nach `process.run()` muss vor Prompt-Write und Wait erneut geprüft und ein bereits abgebrochener Prozess sofort beendet werden. Die globale Singleton-Flag-Kombination durch einen run-lokalen Actor ersetzen.

**Konfidenz:** hoch — die Reihenfolge setzt den Cancel-Wunsch nachweislich zweimal zurück; nur das Timing des User-Klicks ist variabel.

## F3: Der Task-Mode verspricht Ausführung, startet Codex aber immer in einer Read-only-Sandbox

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Models/PostProcessingTemplate.swift:268-286`; `WhisperM8/Models/OutputMode.swift:208-218`; `WhisperM8/Services/Dictation/CodexSupport.swift:65-75`

**Szenario (Auslöser → Wirkung für den User):** Der User wählt „Task“ und diktiert eine Implementierungs- oder Fix-Aufgabe. Template und Mode-Beschreibung verlangen, dass Codex die Aufgabe direkt erledigt und das fertige Ergebnis liefert. Der Spawn hardcodiert jedoch für jeden Output-Mode `--sandbox read-only`. Codex kann damit keine Projektdatei ändern; der vermeintliche Task-Mode kann schreibende Tasks prinzipbedingt nur mit einem Blocker oder Textvorschlag beantworten.

**Beweis:**

```swift
// PostProcessingTemplate.swift:270-285
description: "Führt den gesprochenen Task mit Codex aus und liefert das fertige Ergebnis.",
instruction: """
Execute this task and return the finished result.
// ...
- Do the task yourself as far as the current non-interactive Codex session allows.
// ...
- Output only the final answer or deliverable.

// CodexSupport.swift:71-75
arguments.append(contentsOf: [
    "--sandbox", "read-only",
    "--skip-git-repo-check",
    "--output-last-message", outputURL.path,
])
```

**Fix-Vorschlag:** Produktentscheidung explizit machen: Entweder Task-Mode als reinen „Task-Entwurf/Analyse“-Mode umbenennen und Template/Help entsprechend korrigieren, oder für genau diesen Mode einen bewusst bestätigten Workspace-Write-Pfad mit enger Projektwurzel und Approval-Policy implementieren. Ein stilles Abweichen zwischen Leistungsversprechen und unveränderlicher Sandbox vermeiden.

**Konfidenz:** hoch — der Widerspruch zwischen Built-in-Template und festem Spawn-Argument gilt für jeden Task-Run.

## F4: Agent-Chat-Auto-Paste adressiert nur den Prozess, nicht das eingefrorene Fenster oder die Session

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:120-133, 169-191`; `WhisperM8/Windows/RecordingPanel.swift:429-446, 612-614`; `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:78-101`; `WhisperM8/Services/Dictation/PasteService.swift:69-92`

**Szenario (Auslöser → Wirkung für den User):** Die Aufnahme startet in Agent-Chat A; während Transkription/Codex wechselt der User zu Chat B, öffnet Settings oder schließt das ursprüngliche Fenster. Das Context-Bundle friert zwar die Session-ID von A ein, die Delivery ignoriert sie aber. Gespeichert wird nur `NSRunningApplication` für WhisperM8; später wird lediglich die App aktiviert und blind Cmd+V an das dann fokussierte Control gesendet. Das Ergebnis kann dadurch in Chat B, ein anderes WhisperM8-Fenster oder gar kein Textfeld gelangen. Das ist besonders riskant bei vertraulichem Diktat. Der bereits dokumentierte Retry-Pfad verschärft dies zusätzlich, weil `show()` die Ziel-App nach dem Fehlerdialog neu erfasst.

**Beweis:**

```swift
// RecordingCoordinator.swift:125-130 — Session wird nur als Kontext eingefroren
let activeAgentChat: AgentChatContextRef?
// ...
activeAgentChat = keyAgentWindow != nil ? appState.activeAgentChat : nil

// RecordingPanel.swift:442-444 — Delivery-Ziel kennt nur die App
previousApp = NSWorkspace.shared.frontmostApplication

// PasteService.swift:81-92 — keine Fenster-/Sessionprüfung vor Cmd+V
targetApp.activate()
await waitForActivation(of: targetApp)
// ...
copyToClipboard(payload.text)
let textPasted = postPasteEvent()
```

**Fix-Vorschlag:** Ein unveränderliches Delivery-Target pro Run speichern: App-PID plus bei Agent Chats `windowID` und `sessionID`. Vor Paste prüfen, ob genau diese Session noch offen und fokussierbar ist; gezielt Fenster und Tab aktivieren. Ist das Ziel geschlossen oder nicht eindeutig, nicht blind pasten, sondern nur ins Clipboard kopieren und eine klare Meldung mit „Ziel erneut wählen“ anzeigen. Retry muss dasselbe ursprüngliche Target behalten.

**Konfidenz:** hoch — im Delivery-Pfad wird die vorhandene Session-ID nirgends konsumiert; `activate()` kann nur die App, nicht den ursprünglichen Chat adressieren.

## F5: Postprocessing-Fehler ohne Raw-Fallback werden als Transkriptionsfehler behandelt und nicht reportet

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:33-59, 112-139, 199-235`; `WhisperM8/Services/Dictation/RecordingCoordinator.swift:396-415`; `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:11-39`; `WhisperM8/Models/TranscriptRunReport.swift:3-8`

**Szenario (Auslöser → Wirkung für den User):** Whisper/Groq liefert erfolgreich Text, danach scheitert Codex und „Fall back to Fast on processing errors“ ist deaktiviert. Der bereits vorhandene Raw-Text wird nur flüchtig in `AppState.lastRawTranscription` gehalten; er wird weder in Clipboard noch in einen `.failed`-Run-Report geschrieben. Der Fehler fällt in den generischen Transkriptionsfehler-Pfad, zeigt „Transcription Failed“, sichert nur die Audioaufnahme und bietet eine vollständige erneute Transkription an. Nach App-Neustart ist der erfolgreiche Raw-Text weg und der User muss Audio erneut hochladen, obwohl nur Postprocessing fehlgeschlagen war. Der vorhandene Report-Status `.failed` wird in diesem Lauf nie erzeugt.

**Beweis:**

```swift
// RecordingCoordinator+Transcription.swift:52-59
appState.lastRawTranscription = normalizedRawText
let postProcessingResult = try await processTranscriptIfNeeded(...)

// RecordingCoordinator+Transcription.swift:215-235
if AppPreferences.shared.fallbackToRawOnProcessingError {
    // Raw-/cautious-Fallback
    return PostProcessingRunResult(...)
}
throw error

// RecordingCoordinator.swift:413-414 — Postprocessing landet als UNKNOWN ERROR
case .failure(let error):
    handleTranscriptionFailure(..., message: error.localizedDescription, ...)

// Der einzige saveRunReport-Aufruf liegt im erfolgreichen Delivery-Pfad
saveRunReport(...)
```

**Fix-Vorschlag:** Transkription und Postprocessing als getrennte persistente Phasen modellieren. Sobald Raw-Text vorliegt, einen Draft/Report atomar mit Raw-Text speichern. Bei Codex-Fehler ohne Delivery Status `.failed` plus Postprocessing-Fehler aktualisieren, dem User „Postprocessing fehlgeschlagen“ anzeigen und Aktionen „Raw kopieren“, „nur Codex erneut versuchen“ sowie optional „Audio neu transkribieren“ anbieten.

**Konfidenz:** hoch — der Throw umgeht den einzigen Report-/Clipboard-Pfad; die Audioerhaltung verhindert zwar Totalverlust, nicht aber den Verlust des bereits bezahlten Raw-Ergebnisses.

## F6: Die CLI verwirft bei `--mode`-Fehlern das erfolgreiche Raw-Transkript

**Schweregrad:** mittel

**Fundort:** `WhisperM8/CLI/CLITranscribe.swift:57-79, 91-99, 119-150, 254-265`

**Szenario (Auslöser → Wirkung für den User):** Eine lange Datei wird vollständig und gegebenenfalls in vielen Chunks transkribiert; anschließend ist Codex nicht installiert, ausgeloggt, veraltet oder liefert einen Fehler. `PostProcessingService.process` wirft, `emit` wird nie erreicht und das temporäre Arbeitsverzeichnis wird per `defer` gelöscht. Die Quelldatei bleibt erhalten, aber das erfolgreiche Raw-Transkript wird nirgends ausgegeben oder gespeichert; der User muss den kosten- und zeitintensiven Provider-Lauf wiederholen.

**Beweis:**

```swift
// CLITranscribe.swift:129-141
var text = stitched.text
// ...
if let mode, mode.usesPostProcessing {
    text = try await PostProcessingService().process(...)
    segments = []
}

// CLITranscribe.swift:72-76 — emit nur nach komplett erfolgreichem transcribeFile
let rendered = CLIOutputFormatter.render(result, as: options.format)
try emit(rendered, for: sourceURL, options: options)
} catch {
    CLIIO.err("✗ \(sourceURL.lastPathComponent): \(error.localizedDescription)")
}
```

**Fix-Vorschlag:** Raw-Ergebnis vor Codex in einer atomaren Zwischen-/Sidecar-Datei sichern. Bei Postprocessing-Fehler entweder standardmäßig Raw ausgeben und mit Warnung/Exit-Code kennzeichnen oder mindestens den Pfad zum erhaltenen Raw-Transkript melden. Optional einen reinen Postprocessing-Retry auf dieser Datei anbieten; Temp-Cleanup erst nach erfolgreicher finaler Ausgabe.

**Konfidenz:** hoch — der Throw liegt vor dem einzigen Output-Aufruf und das Temp-Verzeichnis wird anschließend sicher entfernt.

## F7: Doppelte Output-Mode-IDs crashen den Prozess beim Laden

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/Dictation/OutputModeStore.swift:118-134, 145-165`

**Szenario (Auslöser → Wirkung für den User):** Durch manuelle Bearbeitung, Sync-/Merge-Konflikt, Downgrade oder einen früheren Schreibfehler enthält `OutputModes.json` dieselbe ID zweimal. JSON-Decoding gelingt, danach ruft `normalized` `Dictionary(uniqueKeysWithValues:)` auf. Swift löst bei einem doppelten Key einen Fatal Error aus; schon der nächste Zugriff auf Modes kann die App beziehungsweise `whisperm8 modes/transcribe --mode` hart beenden. Der vorhandene Decode-Fallback greift nicht, weil das JSON syntaktisch und typseitig gültig ist.

**Beweis:**

```swift
// OutputModeStore.swift:126-130
let data = try loader(fileURL)
let modes = try JSONDecoder().decode([OutputMode].self, from: data)
// ...

// OutputModeStore.swift:162
var byID = Dictionary(uniqueKeysWithValues: migratedModes.map { ($0.id, $0) })
```

**Fix-Vorschlag:** IDs vor der Dictionary-Erzeugung validieren und Duplikate deterministisch behandeln (beispielsweise ersten Eintrag behalten, Konflikt quarantänisieren). Den Konflikt in Settings sichtbar machen und die Originaldatei nicht automatisch überschreiben. Einen Unit-Test mit doppelter Built-in- sowie doppelter Custom-ID ergänzen.

**Konfidenz:** hoch — `Dictionary(uniqueKeysWithValues:)` hat für doppelte Keys dokumentiertes Trap-Verhalten; dieser Pfad besitzt keinen vorgelagerten Eindeutigkeits-Guard.

## F8: Sequentielle Platzhalter-Ersetzung interpretiert Nutzinhalt erneut als Template

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Models/PostProcessingTemplate.swift:12-38`

**Szenario (Auslöser → Wirkung für den User):** Das Diktat oder eingefangener Text enthält wörtlich einen später ersetzten Platzhalter, etwa „Schreibe exakt `{selectedContext}`“ oder Quellcode/Dokumentation mit `{agentChatTail}`. Zuerst wird `{rawTranscript}` durch das Diktat ersetzt; danach laufen weitere `replacingOccurrences` über den bereits eingesetzten Text und expandieren dessen Token mit Kontextdaten. Der User-Inhalt wird dadurch verändert, Kontext kann an einer unbeabsichtigten Stelle dupliziert werden, und bei sensiblen Captures kann ein als Literal gedachtes Token unerwartet Daten in den Prompt ziehen. Das ist keine Shell-Injection — der Prompt geht sicher über stdin — aber eine belegbare Template-/Prompt-Injection auf Inhaltsebene.

**Beweis:**

```swift
return instruction
    .replacingOccurrences(of: "{rawTranscript}", with: rawTranscript)
    .replacingOccurrences(of: "{selectedContext}", with: contextBundle.selectedText.text)
    // ... spätere Ersetzungen laufen auch über den gerade eingesetzten Raw-Text
    .replacingOccurrences(of: "{agentChatTail}", with: contextBundle.agentChatTail ?? "")
    .replacingOccurrences(of: "{language}", with: language.isEmpty ? "auto" : language)
```

**Fix-Vorschlag:** Template einmalig tokenisieren und ausschließlich Token aus der ursprünglichen Template-Struktur ersetzen; eingesetzte Werte dürfen nicht erneut geparst werden. Alternativ alle Werte zunächst durch eindeutige, nicht kollidierende Sentinels ersetzen und erst in einem finalen Pass einsetzen. Tests für jedes Platzhalter-Literal in Raw-Text, Selected Context und Chat-Tail ergänzen.

**Konfidenz:** hoch — die Reihenfolge erzeugt die beschriebene Expansion deterministisch mit einem einfachen Literal im Diktat.

## F9: Selected-/Clipboard-Kontext ist unbeschränkt und wird im Prompt mehrfach eingebettet

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/SelectedContextService.swift:14-36, 64-73`; `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:164-203`; `WhisperM8/Models/PostProcessingTemplate.swift:20-35`; `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:257-270, 329-345`

**Szenario (Auslöser → Wirkung für den User):** Der User markiert ein sehr großes Dokument oder kopiert während Recording/Transcribing mehrfach große Textblöcke. Für AX-/Clipboard-Text gibt es weder Zeichen-, Byte- noch Tokenbudget; weitere Captures werden angehängt. `PromptPackageBuilder` schreibt Selected Text bereits in `## Captured Context`, danach enthält `modeInstruction` denselben Text erneut über `{selectedContext}`; Chat-Tail und Visual Summary werden analog doppelt geführt. Das erhöht Speicher, Tokenkosten und Latenz und kann Codex' Kontextgrenze überschreiten. In der GUI endet das in Raw-Fallback/Fehlermeldung, in der CLI in F6; der vollständige gerenderte Prompt wird zusätzlich im Report archiviert.

**Beweis:**

```swift
// RecordingCoordinator+Clipboard.swift:186-191 — unbegrenztes Anhängen
if bundle.selectedText.isEmpty {
    bundle.selectedText = SelectedContext(text: normalized, ...)
} else {
    if bundle.selectedText.text.contains(normalized) { return false }
    bundle.selectedText.text += "\n\n" + normalized
}

// PromptPackageBuilder.swift:263-267
let prompt = [
    globalContract(...),
    agentChatContextBlock(contextBundle: contextBundle),
    visualContextBlock(contextBundle: contextBundle, visualManifest: visualManifest),
    "## Mode Instruction\n\(modeInstruction)"
]

// PostProcessingTemplate.swift:21-23 — dieselben Werte nochmals im Mode-Template
.replacingOccurrences(of: "{rawTranscript}", with: rawTranscript)
.replacingOccurrences(of: "{selectedContext}", with: contextBundle.selectedText.text)
.replacingOccurrences(of: "{visualContextSummary}", with: contextBundle.visualContextSummary)
```

**Fix-Vorschlag:** Ein zentrales, deterministisches Prompt-Budget in Bytes/Tokens einführen. Quellen einzeln begrenzen, Deduplizierung nicht per `contains` auf dem wachsenden Gesamtstring durchführen und bei Kürzung Quelle/Umfang kennzeichnen. Kontext genau einmal in klar abgegrenzten Datenblöcken einbetten; Templates sollen darauf referenzieren statt Inhalte zu wiederholen. Vor Spawn die finale Prompt- und Bildgröße validieren und dem User eine verständliche Kürzungs-/Overflow-Meldung zeigen.

**Konfidenz:** hoch — fehlende Textlimits und doppelte Einbettung sind direkt sichtbar; die exakte Modellgrenze hängt vom gewählten Codex-Modell ab.

## F10: Visual Manifest und Run-Report behaupten fälschlich, Screen-Clips seien an Codex gesendet worden

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/CodexSupport.swift:94-121`; `WhisperM8/Services/Dictation/CodexPostProcessor.swift:32-50`; `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:134-150, 177-184`; `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:86-105, 132-135`

**Szenario (Auslöser → Wirkung für den User):** Ein Run enthält einen Screen-Clip. `CodexVisualInputSelection.includes` liefert für den Clip `true`, weil dessen URL in `videoURLs` liegt. Manifest und archivierter Attachment-Report markieren ihn deshalb als `sent to Codex`/`includedInCodexInput`, und der Report füllt `videoInputPaths`. Der tatsächliche Spawn übergibt aber ausschließlich `imageURLs` als `--image`; `videoURLs` erreichen `runCodex` und `CodexInvocation` nie. Der User und spätere Auditoren glauben daher, Codex habe das vollständige Video gesehen, obwohl nur extrahierte Frames gesendet wurden.

**Beweis:**

```swift
// CodexSupport.swift:115-121
func includes(_ attachment: ContextAttachment) -> Bool {
    switch attachment.kind {
    case .screenshot, .annotation, .visualFrame:
        return imageURLs.contains { $0.path == attachment.fileURL.path }
    case .screenClip:
        return videoURLs.contains { $0.path == attachment.fileURL.path }
    }
}

// CodexPostProcessor.swift:32-50 — Videos werden nicht weitergereicht
let visualInput = CodexVisualInputSelection(contextBundle: contextBundle)
// ...
return try await runCodex(
    prompt: package.prompt,
    imageURLs: visualInput.imageURLs,
    mode: mode,
    projectPath: projectPath
)

// PromptPackageBuilder.swift:147
parts.append(entry.includedInCodexInput ? "sent to Codex" : "stored locally")
```

**Fix-Vorschlag:** `includedInCodexInput` aus den tatsächlich erzeugten CLI-Argumenten ableiten. Solange Codex CLI nur Bilder erhält, Screen-Clips konsequent als „nicht gesendet; Frames als Fallback gesendet“ markieren und `videoInputPaths` in „capturedVideoPaths“ umbenennen beziehungsweise mit einem separaten Delivery-Status versehen. Falls echte Video-Inputs später unterstützt werden, sie erst nach erfolgreichem Argument-/Capability-Check als gesendet reporten.

**Konfidenz:** hoch — der einzige reale Spawn-Parameter ist `[URL] imageURLs`; für `videoURLs` existiert kein Übergang in `CodexInvocation`.
