# Runde 2: Permissions, Onboarding und App-Lifecycle (Codex)

Audit-Stand: 2026-07-18. Geprüft wurden `PermissionService`, die Diktat- und
Visual-Context-Konsumenten, `OnboardingView`, die Szenen und Delegate-Hooks in
`WhisperM8App`, `WindowRequestCenter`, `CLISymlinkInstaller`, Launch-at-Login sowie
das non-activating `RecordingPanel`. Der Bericht beruht auf statischer Codeanalyse;
TCC-Änderungen während laufender AV-/ScreenCaptureKit-Sessions wurden nicht auf einem
realen macOS-System erzwungen.

## Zusammenfassung

- kritisch: 0
- hoch: 3
- mittel: 12
- niedrig: 3

Wichtigster Punkt ist F1: Beim Beenden der App werden Terminal- und Store-Zustände
gesichert, ein laufendes Diktat beziehungsweise ein laufender Upload durchläuft aber
keinen Stop-/Recovery-Pfad. Das Audio liegt nur im temporären Verzeichnis und erhält
weder einen `FailedRecordings`-Eintrag noch eine Retry-Möglichkeit. Ebenfalls hoch sind
das dauerhaft überspringbare Rest-Onboarding nach Erteilung der TCC-Rechte (F2) und
die Desynchronisation zwischen `AudioRecorder` und sichtbarem Recording-State nach
einem Engine-Ausfall (F3).

Nicht als Finding gewertet wurden bereits vorhandene Sicherungen: Settings,
Onboarding und das Primärfenster sind Single-`Window`-Scenes; ein einzelner Request vor
Mount des `WindowRequestHandler` bleibt über `@Published latestRequest` erhalten; der
Workspace hat einen synchronen `willTerminate`-Flush und der Fenster-State wird im
Delegate explizit geflusht. Das Recording-Panel ist non-activating, auf allen Spaces
verfügbar und begrenzt gespeicherte Anker auf einen vorhandenen Bildschirm. Für diese
Pfade war ohne zusätzliche Ereigniskombination kein eigenständiger Fehler belegbar.

## F1: App-Quit umgeht die Recovery laufender Diktate

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/MenuBarView.swift:113-115`;
`WhisperM8/WhisperM8App.swift:343-361`;
`WhisperM8/Services/Dictation/AudioRecorder.swift:132-150`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:42-93`;
`WhisperM8/Services/Dictation/FailedRecordingsStore.swift:21-25`

**Szenario (Auslöser → Wirkung):** Der User beendet WhisperM8 per Menü, Cmd+Q,
SIGTERM oder System-Shutdown während einer Aufnahme, eines Screen-Clips oder eines
Transkriptions-Uploads. `applicationShouldTerminate` antwortet sofort mit
`.terminateNow`; `applicationWillTerminate` beendet nur Audio-Ducking und flusht den
Fenster-State. Der Coordinator stoppt den Recorder nicht, cancelt keinen Upload und
ruft `preserveRecording` nicht auf. Das M4A liegt deshalb nur unter `temporaryDirectory`,
hat keinen Sidecar und erscheint nicht in der Retry-Liste. Ein Screen-Clip wird zudem
nicht finalisiert.

**Beweis:**

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Fenstertracking + Terminal-Snapshots
    return .terminateNow
}

func applicationWillTerminate(_ notification: Notification) {
    AudioDuckingManager.shared.endCaptureImmediate()
    MainActor.assumeIsolated { AgentWindowStore.shared.flush() }
}
```

Demgegenüber sichert nur der reguläre Cancel-/Fehlerpfad:

```swift
func handleTranscriptionCancelled(...) {
    preserveRecording(audioURL: audioURL, ...)
}
```

**Fix-Vorschlag:** Termination mit `.terminateLater` koordinieren. Eine laufende
Aufnahme stoppen und direkt in `FailedRecordings` sichern, einen Upload canceln und
seinen Preserve-Pfad begrenzt abwarten, Screen-Clips sauber canceln/finalisieren und
erst danach `reply(toApplicationShouldTerminate:)` aufrufen. Für interaktives Quit ist
zusätzlich ein Hinweis auf das laufende Diktat sinnvoll; Shutdown muss eine feste
Deadline haben.

**Konfidenz:** hoch

## F2: Abgebrochenes Onboarding wird nach erteilten TCC-Rechten nie automatisch fortgesetzt

**Schweregrad:** hoch

**Fundort:** `WhisperM8/WhisperM8App.swift:201-208` und
`WhisperM8/WhisperM8App.swift:300-310`;
`WhisperM8/Views/OnboardingView.swift:83-95` und
`WhisperM8/Views/OnboardingView.swift:150-169`;
`WhisperM8/Views/OnboardingView.swift:510-580` und
`WhisperM8/Views/OnboardingView.swift:582-703`

**Szenario (Auslöser → Wirkung):** Beim ersten Start erteilt der User Mikrofon- und
Accessibility-Zugriff und schließt danach das normale Setup-Fenster vor Hotkey,
API-Key und „Done“. Beim nächsten Start sind beide TCC-Prüfungen positiv, also wird
das Onboarding nicht mehr geöffnet. Ein fehlender Hotkey und ein fehlender API-Key
werden von der Startbedingung nicht betrachtet; die App kann dadurch dauerhaft ohne
funktionsfähigen Diktat-Einstieg starten. Ein versionierter Completion-/Progress-State
existiert nicht.

**Beweis:**

```swift
private var needsOnboarding: Bool {
    let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let accessibilityGranted = AXIsProcessTrusted()
    return !micGranted || !accessibilityGranted
}

if needsOnboarding {
    WindowRequestCenter.shared.request(.onboarding)
}
```

Die spätere Zustandsmaschine verlangt dagegen zusätzlich Hotkey und API-Key:

```swift
return hotkeySet
    && micPermissionGranted
    && accessibilityGranted
    && (!apiKey.isEmpty || apiKeyAvailable)
```

**Fix-Vorschlag:** Einen versionierten Onboarding-State und den letzten vollständig
abgeschlossenen Schritt persistieren. Die Startbedingung muss unvollständiges Setup
unabhängig von TCC fortsetzen; TCC-Reparatur kann zusätzlich jederzeit erneut triggern.
Beim Schließen eines unvollständigen Wizards bestätigen oder eine klar sichtbare
„Setup fortsetzen“-Aktion anbieten.

**Konfidenz:** hoch

## F3: Mikrofon-/Engine-Ausfall desynchronisiert Recorder und UI und gefährdet die Aufnahme

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:219-223`;
`WhisperM8/Services/Dictation/AudioRecorder.swift:290-295` und
`WhisperM8/Services/Dictation/AudioRecorder.swift:332-346`;
`WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift:67-79`;
`WhisperM8/Services/Dictation/RecordingCoordinator.swift:304-319`

**Szenario (Auslöser → Wirkung):** Während einer Aufnahme fällt das Input-Gerät aus
oder macOS entzieht/ändert den Mikrofonzugriff so, dass die Engine neu konfiguriert
werden muss. Bei ungültigem Format oder fehlgeschlagenem Restart setzt der
`AudioRecorder` nur seinen privaten `isRecording`-Wert auf `false`. `AppState` bleibt
auf Recording, der Dauer-Timer und die rote UI laufen weiter. Erst beim nächsten Stop
liefert `AudioRecorder.stopRecording()` wegen seines Guards `nil`; der Coordinator
zeigt dann „No audio file was created“, ohne die bereits angelegte temporäre Datei in
`FailedRecordings` zu sichern. Bei explizit ausgewähltem Eingabegerät wird nicht einmal
der Configuration-Observer installiert.

**Beweis:**

```swift
guard isUsingSystemDefault, let engine = engine else { return }
// ...
guard let inputFormat = newFormat else {
    isRecording = false
    audioLevel = 0
    return
}
```

```swift
func stopRecording() -> URL? {
    guard isRecording else { return nil }
    // ...
}
```

Der UI-Timer liest nur Pegel und Zeit, nicht den Recorder-Lifecycle:

```swift
appState.recordingDuration = Date().timeIntervalSince(recordingStartTime)
appState.audioLevel = self.audioRecorder.audioLevel
```

**Fix-Vorschlag:** `AudioRecorder` muss Laufzeitfehler über einen Callback/AsyncStream
an den Coordinator melden. Dort Recording-State und Overlay sofort konsistent beenden,
eine sichtbare Permission-/Device-Meldung zeigen und eine vorhandene `recordingURL`
finalisieren beziehungsweise in `FailedRecordings` übernehmen. Das Monitoring darf
nicht nur vom „System Default“-Modus abhängen.

**Konfidenz:** hoch für die Zustands- und Datenpfade; mittel dafür, dass ein konkreter
TCC-Entzug auf jeder unterstützten macOS-Version genau diese Engine-Notification
auslöst.

## F4: ScreenCaptureKit-Laufzeitfehler erreichen den Coordinator wegen `delegate: nil` nicht

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/ManualScreenClipSession.swift:17-28`;
`WhisperM8/Services/Dictation/ManualScreenClipSession.swift:91-113` und
`WhisperM8/Services/Dictation/ManualScreenClipSession.swift:191-193`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:9-24` und
`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:47-54`

**Szenario (Auslöser → Wirkung):** Screen Recording wird während eines Clips entzogen
oder der Stream stoppt wegen Display-/Capture-Fehler. Die Session implementiert zwar
`SCStreamDelegate.didStopWithError`, der `SCStream` wird aber mit `delegate: nil`
gebaut. Es gibt auch keinen anderen Failure-Callback zum Coordinator. Damit bleibt
`appState.isScreenClipRecording` bis zum User-Stop oder Duration-Limit wahr; der
Fehlerindikator hängt und ein Teilclip kann unklar behandelt werden.

**Beweis:**

```swift
let stream = SCStream(filter: target.filter, configuration: configuration, delegate: nil)
```

```swift
func stream(_ stream: SCStream, didStopWithError error: Error) {
    streamError = error
}
```

**Fix-Vorschlag:** Einen echten Delegate/Proxy beim Erzeugen des Streams installieren
und den Fehler unverzüglich an `VisualContextCaptureService` und den Coordinator
propagieren. UI-State zurücksetzen, Timer canceln und Writer/Teilclip mit einer
expliziten Recovery-Policy behandeln.

**Konfidenz:** hoch

## F5: Accessibility-Entzug während Auto-Paste wird als Erfolg protokolliert

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/PasteService.swift:52-67`;
`WhisperM8/Services/Dictation/PasteService.swift:81-105` und
`WhisperM8/Services/Dictation/PasteService.swift:169-186`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:107-132`

**Szenario (Auslöser → Wirkung):** Accessibility ist beim Eintritt in den Paste-Pfad
vorhanden, wird aber während App-Aktivierung, Sleeps oder der Attachment-Schleife
entzogen. Der Status wird nur einmal vorab geprüft. `postPasteEvent()` gibt anschließend
`true` zurück, sobald die beiden `CGEvent`-Objekte erzeugt wurden; `CGEvent.post` hat
keinen Zustellungs-Return. macOS kann die Events blockieren, während WhisperM8
„Paste event posted successfully“ meldet und keine `pasteErrors` in den Run-Report
schreibt. Der Text bleibt immerhin als Clipboard-Fallback erhalten.

**Beweis:**

```swift
guard PermissionService.hasAccessibilityPermission else { ... }
// Aktivierung und Wartezeiten
let textPasted = postPasteEvent()
```

```swift
keyDown.post(tap: .cghidEventTap)
keyUp.post(tap: .cghidEventTap)
Logger.paste.info("Paste event posted successfully")
return true
```

**Fix-Vorschlag:** Accessibility unmittelbar vor jedem Text-/Attachment-Event erneut
prüfen, bei Verlust die Schleife abbrechen und eine sichtbare Delivery-Warnung mit
Clipboard-Fallback ausgeben. Das Resultat als „Event gesendet“ statt „Text eingefügt“
modellieren, solange keine beobachtbare Bestätigung möglich ist.

**Konfidenz:** hoch

## F6: Interaktive Screenshot-Fehler werden wie ein ESC-Abbruch verschwiegen

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:54-70` und
`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:87-101`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:119-139`

**Szenario (Auslöser → Wirkung):** `/usr/sbin/screencapture` endet ungleich null,
etwa wegen eines Capture-/TCC-Fehlers. Der Runner reduziert jeden Prozessausgang auf
ein Bool und erfasst weder Statusursache noch stderr. Der Service gibt für Nonzero,
fehlende Datei und echte ESC-Auswahl identisch `nil` zurück. Der Caller kommentiert
jedes `nil` als User-Abbruch und zeigt deshalb keine Meldung. Für den User ist der
Screenshot-Button ein stiller No-op.

**Beweis:**

```swift
process.terminationHandler = { proc in
    continuation.resume(returning: proc.terminationStatus == 0)
}
// ...
guard didCapture, fileExists, size > 0 else {
    return nil
}
```

```swift
guard let screenshot = try await captureInteractiveScreenshot(...) else {
    return  // User-Abbruch (ESC) — keine Fehlermeldung.
}
```

**Fix-Vorschlag:** Vorab Screen-Recording-Status prüfen und ein typisiertes Ergebnis
`cancelled/success/failure` verwenden. Nonzero-Status und stderr als Fehler
propagieren; fehlende Permission mit einem System-Settings-CTA anzeigen.

**Konfidenz:** hoch für die Fehlerkonflation; mittel für die konkrete Zuordnung jedes
Nonzero-Exits zu TCC.

## F7: Der Done-Button verwendet nach Verlassen des Permission-Schritts veraltete TCC-Werte

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/OnboardingView.swift:83-95`;
`WhisperM8/Views/OnboardingView.swift:150-169`;
`WhisperM8/Views/OnboardingView.swift:415-463`

**Szenario (Auslöser → Wirkung):** Beide Permissions werden im Permission-Schritt als
erteilt erkannt. Der User geht weiter; `onDisappear` stoppt das Polling. Entzieht er
Mikrofon oder Accessibility danach in System Settings, bleiben die Bindings `true`.
`canFinish` prüft ausschließlich diese gecachten Werte und „Done“ schließt den Wizard
trotz inzwischen fehlender Permission. Erst ein Neustart erkennt den Zustand wieder.

**Beweis:**

```swift
.onDisappear {
    stopPermissionPolling()
}

private var canFinish: Bool {
    hotkeySet && micPermissionGranted && accessibilityGranted && ...
}
```

**Fix-Vorschlag:** Vor `finishOnboarding()` Mic/AX synchron neu prüfen und bei
Abweichung zum Permission-Schritt zurückführen. Zusätzlich beim erneuten Aktivieren der
App refreshen; die gecachten Bools dürfen nicht die Abschlusswahrheit sein.

**Konfidenz:** hoch

## F8: Accessibility blockiert Setup und jeden Start trotz implementiertem Clipboard-only-Modus

**Schweregrad:** mittel

**Fundort:** `WhisperM8/WhisperM8App.swift:201-217`;
`WhisperM8/Views/OnboardingView.swift:150-169` und
`WhisperM8/Views/OnboardingView.swift:377-398`;
`WhisperM8/Views/OnboardingView.swift:676-692`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61-105`

**Szenario (Auslöser → Wirkung):** Ein User möchte Auto-Paste deaktivieren und nur in
die Zwischenablage transkribieren. Dieser Pfad ist implementiert und benötigt keine
Accessibility-Permission. Trotzdem blockieren Next und Done ohne AX; außerdem öffnet
`needsOnboarding` bei jedem Start erneut den Wizard und erzwingt selbst für ein
Menüleistenprofil die reguläre Dock-Policy. Auf einem Erststart liegt der Auto-Paste-
Toggle erst hinter dem blockierenden Permission-Schritt, sodass der User den
unterstützten Clipboard-only-Modus nicht wählen kann.

**Beweis:**

```swift
case .permissions:
    return micPermissionGranted && accessibilityGranted
```

```swift
pasteService.copyToClipboard(finalText)
if autoPasteRequested {
    pasteResult = await pasteService.pastePayloadToActiveApp(...)
} else {
    Logger.debug("Auto-paste disabled, text copied to clipboard only")
}
```

**Fix-Vorschlag:** Accessibility nur dann als Setup-Blocker behandeln, wenn Auto-Paste
oder Selected-Text-Capture tatsächlich aktiviert ist. Die Wahl vor der Permission-
Schranke anbieten und bei fehlendem AX kontrolliert auf Clipboard-only wechseln. Der
Launch darf AX nicht pauschal als für jede Konfiguration essenziell einstufen.

**Konfidenz:** hoch

## F9: Beim permission-bedingten Erststart öffnet Agent Chats parallel zum Onboarding

**Schweregrad:** mittel

**Fundort:** `WhisperM8/WhisperM8App.swift:30-40`;
`WhisperM8/WhisperM8App.swift:91-99`;
`WhisperM8/WhisperM8App.swift:116-155` und
`WhisperM8/WhisperM8App.swift:300-310`;
`WhisperM8/Services/Shared/WindowRequestCenter.swift:87-92`;
`WhisperM8/Models/AppUsageProfile.swift:17-18`

**Szenario (Auslöser → Wirkung):** Auf einer frischen beziehungsweise alten
Installation ohne gespeichertes Profil ist `.full` der Default. Fehlt Mic oder AX,
öffnet SwiftUI trotzdem automatisch die erste `Window`-Scene „Agent Chats“, weil deren
Gate nur das Profil betrachtet und initial `true` ist. Erst 0,5 Sekunden später öffnet
der Delegate zusätzlich das nichtmodale Onboarding. Der User landet in zwei
unabhängigen Fenstern und kann den als „funktional kaputt“ kommentierten Zustand hinter
dem Hauptfenster ignorieren.

**Beweis:**

```swift
Window("Agent Chats", id: WindowRequest.agentChats.targetWindowID) { ... }
```

```swift
@Published var allowsAgentChatsPrimaryWindow: Bool =
    AppPreferences.shared.usageProfile.wantsAgentChats
```

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    WindowRequestCenter.shared.request(.onboarding)
}
```

**Fix-Vorschlag:** Einen vor Scene-Aufbau feststehenden Launch-Gate-State verwenden.
Bei erforderlichem Onboarding das Primärfenster sperren beziehungsweise schließen und
erst nach erfolgreichem Setup profilabhängig öffnen.

**Konfidenz:** hoch

## F10: Dock-Reopen ist bei erforderlichem Onboarding im Menüleistenprofil ein No-op

**Schweregrad:** mittel

**Fundort:** `WhisperM8/WhisperM8App.swift:213-218`;
`WhisperM8/WhisperM8App.swift:307-310` und
`WhisperM8/WhisperM8App.swift:314-326`;
`WhisperM8/Models/AppUsageProfile.swift:28-38`

**Szenario (Auslöser → Wirkung):** Ein gespeichertes `dictationRaw`- oder
`dictationEnrichment`-Profil startet mit fehlender Mic-/AX-Permission. Wegen
`needsOnboarding` ist die App vorübergehend `.regular` und hat ein Dock-Icon. Schließt
der User das Setup, bleibt die App ohne Fenster am Leben. Ein Klick auf das sichtbare
Dock-Icon öffnet nichts, weil Reopen ausschließlich `wantsAgentChats` prüft, was für
beide Profile `false` ist.

**Beweis:**

```swift
let wantsDock = needsOnboarding || AppPreferences.shared.usageProfile.wantsAgentChats
NSApp.setActivationPolicy(wantsDock ? .regular : .accessory)
```

```swift
if !flag && AppPreferences.shared.usageProfile.wantsAgentChats {
    WindowRequestCenter.shared.request(.agentChats)
}
```

**Fix-Vorschlag:** Im Reopen-Pfad zuerst den aktuellen Onboarding-Bedarf prüfen und
`.onboarding` öffnen; nur andernfalls profilabhängig Agent Chats beziehungsweise
Settings öffnen.

**Konfidenz:** hoch

## F11: Onboarding akzeptiert einen API-Key trotz fehlgeschlagenem Keychain-Save

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/OnboardingView.swift:150-169` und
`WhisperM8/Views/OnboardingView.swift:611-622`;
`WhisperM8/Services/Shared/KeychainManager.swift:10-35`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:21-24`

**Szenario (Auslöser → Wirkung):** `SecItemUpdate`/`SecItemAdd` scheitert, etwa durch
Keychain-/ACL-Probleme. `KeychainManager.save` liefert keinen Status und loggt nur.
Die View setzt trotzdem `apiKeyAvailable = true`; zusätzlich reicht bereits der nicht
leere lokale Text für `canFinish`. Der Wizard schließt erfolgreich, während der
Laufzeit-Resolver keinen Key laden kann und jede Transkription mit `missingAPIKey`
abbricht.

**Beweis:**

```swift
KeychainManager.save(key: selectedProvider.keychainKey, value: newValue)
apiKeyAvailable = true
```

```swift
if status == errSecSuccess {
    setCached(value, for: key)
} else {
    Logger.permission.error("Keychain save failed ...")
}
```

**Fix-Vorschlag:** `save` als `throws` oder typisiertes Result modellieren. Erst nach
bestätigtem Save und Probe-Load freigeben; Save-Fehler inline anzeigen und „Done“
blockieren.

**Konfidenz:** hoch

## F12: CLI-Installationsfehler und Zielkonflikte haben keine verwertbare Fehlerkommunikation

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:10-39`;
`WhisperM8/WhisperM8App.swift:263-268`;
`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:20-37`;
`WhisperM8/Services/Shared/CLISkillExporter.swift:192-213`

**Szenario (Auslöser → Wirkung):** `~/.local/bin` kann nicht erstellt/beschrieben
werden oder am Ziel liegt eine reguläre fremde Datei. Der Start-Installer läuft
detached und meldet nur ins Debuglog. Auch „Create Link“ erhält kein Resultat, sondern
liest danach lediglich denselben generischen Status. Bei einer regulären Datei kehrt
der Installer absichtlich zurück, während die UI weiter eine Install-Aktion anbietet.
Der Button wirkt als wiederholter No-op; Ursache und sicherer Lösungsweg fehlen.

**Beweis:**

```swift
static func installIfNeeded() {
    // ...
    } catch {
        Logger.debug("[CLI] Symlink-Install fehlgeschlagen: ...")
    }
}
```

```swift
Button("Create Link") {
    CLISymlinkInstaller.installIfNeeded()
    installState = CLIInstallStatus.current()
}
```

**Fix-Vorschlag:** Ein typisiertes Resultat zurückgeben (`installed`,
`alreadyLinked`, `regularFileConflict`, `unwritable`, `failure`). In Settings Pfad,
Fehlerursache und nichtdestruktive Handlungsanweisung anzeigen; Auto-Install-Fehler als
persistente Warnung für die CLI-Seite aufbewahren.

**Konfidenz:** hoch

## F13: Launch-at-Login reduziert ServiceManagement auf Boolean und verschweigt Approval-/Registerfehler

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift:29-38`;
`Package.resolved:22-28`;
`.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:10-33`
und `.build/checkouts/LaunchAtLogin-Modern/Sources/LaunchAtLogin/LaunchAtLogin.swift:46-52`

**Szenario (Auslöser → Wirkung):** `SMAppService.mainApp.register()` oder
`unregister()` wirft, oder der Dienst landet in `.requiresApproval`. Die gepinnte
Library 1.1.0 definiert „enabled“ ausschließlich als `status == .enabled` und fängt
Fehler intern nur mit `os.Logger`. WhisperM8 verwendet direkt deren Toggle und besitzt
keinen eigenen Status-/Fehlerpfad. Der Switch bleibt beziehungsweise springt zurück,
ohne Approval-Hinweis oder Link zu den Login-Item-Systemeinstellungen.

**Beweis:**

```swift
LaunchAtLogin.Toggle("")
```

Aus der gepinnten Dependency:

```swift
get { SMAppService.mainApp.status == .enabled }
// ...
} catch {
    logger.error("Failed to enable/disable launch at login ...")
}
```

**Fix-Vorschlag:** Einen eigenen tri-state ViewModel über
`SMAppService.mainApp.status` verwenden. `.requiresApproval`, `.notRegistered` und
Fehler getrennt darstellen, nach Mutationen neu lesen und einen Button zu den
Login-Items in System Settings anbieten.

**Konfidenz:** hoch; die Bewertung bezieht sich auf die in `Package.resolved`
gepinnten Dependency-Quellen.

## F14: Quit-Snapshots aus a26d29f warten nicht auf bestätigten PTY-Exit

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:385-400`;
`WhisperM8/Views/AgentTerminalView.swift:822-836`;
`WhisperM8/WhisperM8App.swift:343-351`; Commit `a26d29f`

**Szenario (Auslöser → Wirkung):** Claude Code oder Codex verarbeitet Ctrl+C unter
Last langsamer als 180 ms oder interpretiert die Interrupts nur als Turn-Abbruch. Der
Quit-Pfad sendet zweimal Ctrl+C, wartet feste 80 und 180 ms und capturt dann den
aktuellen Buffer. Es gibt weder eine Exit-Bestätigung noch einen finalen
`terminal.terminate()`-/zweiten Capture-Schritt; direkt danach darf AppKit terminieren.
Späte Resume-/Fehler-Ausgabe und ein noch laufender externer JSONL-Flush können damit
nach dem Snapshot eintreffen und beim Prozessende fehlen.

**Beweis:**

```swift
for controller in running { controller.sendInterruptForAppQuit() }
usleep(80_000)
for controller in running { controller.sendInterruptForAppQuit() }
usleep(180_000)
for controller in running { controller.captureSnapshotForAppQuit() }
```

```swift
func captureSnapshotForAppQuit() {
    terminal.flushPendingOutput()
    captureTerminalSnapshot()
}
```

**Fix-Vorschlag:** `processTerminated`/Controller-Exit für alle PTYs mit einer
gemeinsamen begrenzten Deadline abwarten, danach Output flushen und capturen. Nicht
beendete Prozesse explizit terminieren und den Buffer anschließend ein letztes Mal
sichern.

**Konfidenz:** mittel-hoch

## F15: Ein Job-Abschluss direkt vor Quit verliert sein Unread-/Notification-Signal dauerhaft

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:64-104` und
`WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:181-203`;
`WhisperM8/WhisperM8App.swift:343-361`

**Szenario (Auslöser → Wirkung):** Ein detached Subagent-Job schreibt `done` oder
`failed`, während der FSEvent-Sync noch aussteht oder läuft, und der User beendet die
App. Der Termination-Pfad wartet den Sync nicht ab. Beim Relaunch ist
`lastPhaseByShortId` leer; der initiale Sync behandelt laut Code erstmals gesehene Jobs
bewusst nicht als Übergang. Der Job und Report bleiben auf Disk und sein Status wird
gemergt, aber `markSubagentUnread`, Completion-Banner und gegebenenfalls das asynchron
angestoßene Summary-Apply werden für diesen Abschluss nie ausgelöst.

**Beweis:**

```swift
guard let previous = lastPhaseByShortId[job.shortId],
      previous != job.state else { continue }
// Jobs, die dieser Prozess noch nie gesehen hat, zählen nicht als Übergang.
```

```swift
if completedShortIds.contains(job.shortId) {
    AgentWindowStore.shared.markSubagentUnread(session.id)
    AgentSessionStatusCoordinator.shared.postSubagentNotification(...)
}
```

**Fix-Vorschlag:** Die zuletzt gesehene beziehungsweise quittierte Completion
persistieren und Unread anhand eines persistenten `completedAt/acknowledgedAt` statt
nur eines prozesslokalen Phasen-Diffs ableiten. Alternativ vor Quit einen begrenzten
Sync abwarten und erst danach Workspace-/Window-State flushen.

**Konfidenz:** hoch

## F16: Selected-Text-Kontext fällt nach Accessibility-Entzug still weg

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/Dictation/SelectedContextService.swift:16-39`;
`WhisperM8/Services/Dictation/RecordingCoordinator.swift:162-178`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:47-71`

**Szenario (Auslöser → Wirkung):** Selected-Text-Capture ist aktiviert, AX fehlt oder
wird vor dem parallelen Context-Capture entzogen. Nach erfolglosem AX-Lesen führt der
fehlende Trust nur zu einer Logzeile und `.empty`. Der Aufnahme-Start hat
`appState.lastError` zuvor geleert; der leere Kontext wird ohne Warnung gemergt. Die
Transkription und gegebenenfalls die inhaltliche Nachbearbeitung laufen dadurch ohne
den vom User erwarteten markierten Text.

**Beweis:**

```swift
guard PermissionService.hasAccessibilityPermission else {
    Logger.permission.warning("Selected context capture needs Accessibility permission")
    return .empty
}
```

**Fix-Vorschlag:** Capture-Ergebnisse mit Ursache modellieren. Bei fehlender
Accessibility im Overlay klar „Ausgewählter Text konnte nicht erfasst werden“ anzeigen,
ohne die Audioaufnahme zu blockieren.

**Konfidenz:** hoch

## F17: Grüner CLI-Status prüft den externen Shell-PATH nicht

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/Shared/CLISkillExporter.swift:192-213`;
`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:45-67` und
`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:118-147`

**Szenario (Auslöser → Wirkung):** Der Symlink ist korrekt, aber die interaktive oder
Login-Shell des Users enthält `~/.local/bin` nicht. `CLIInstallStatus` prüft nur das
Symlink-Ziel und zeigt grün „whisperm8 is installed“. Direkt darunter kopiert die UI
nackte `whisperm8 ...`-Befehle; diese enden extern mit `command not found`. Der intern
von WhisperM8 ergänzte PATH hilft der Shell des Users nicht.

**Beweis:**

```swift
if resolvedDestination == executableURL.resolvingSymlinksInPath().path {
    return .linked(path: linkURL.path)
}
```

**Fix-Vorschlag:** Off-main über eine Login-Shell `command -v whisperm8` prüfen oder
den Status korrekt „Link erstellt“ nennen und einen separaten PATH-Check mit
shell-spezifischer Kopierhilfe anzeigen.

**Konfidenz:** hoch

## F18: Nach Mikrofon-Entzug scheitert ein neuer Hotkey-Start ohne unmittelbares Feedback

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:114-117` und
`WhisperM8/Services/Dictation/RecordingCoordinator.swift:147-155`;
`WhisperM8/Services/Dictation/AudioRecorder.swift:53-60`;
`WhisperM8/Views/MenuBarView.swift:46-55`

**Szenario (Auslöser → Wirkung):** Der User entzieht Mikrofonzugriff und drückt danach
den globalen Hotkey. Der Coordinator versteckt vorsorglich das Overlay; der Recorder
wirft `microphonePermissionDenied`. Der Catch setzt nur `appState.lastError` und kehrt
zurück. Diese Meldung ist ausschließlich sichtbar, wenn der User anschließend das
MenuBarExtra öffnet. Am Hotkey-Ort gibt es kein HUD, Alert, Banner oder Settings-CTA;
die Aktion wirkt zunächst wie ein stiller No-op.

**Beweis:**

```swift
overlayController.hide()
// ...
} catch {
    appState.lastError = error.localizedDescription
    AudioDuckingManager.shared.endCaptureImmediate()
    isProcessing = false
    return
}
```

**Fix-Vorschlag:** Einen nonmodalen Permission-Fehler am Recording-Overlay
beziehungsweise als kurzes HUD anzeigen und direkt „Mikrofon-Einstellungen öffnen“
anbieten. Der Menubar-Fehler kann als sekundäre Historie bestehen bleiben.

**Konfidenz:** hoch
