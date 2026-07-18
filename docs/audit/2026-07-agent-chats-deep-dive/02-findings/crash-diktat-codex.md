# Crash-Audit: Diktat-Pipeline

Untersucht wurden Aufnahmestart, Stop/Abbruch, Gerätewechsel, Transkription und Overlay-Lifecycle. Die vorgesehene Subsystem-Karte `01-subsysteme/diktat.md` war im Workspace nicht vorhanden. Die Analyse basiert daher auf dem aktuellen Quellcode und der Git-Historie der betroffenen Dateien.

Die vorhandenen Guards verhindern einen gewöhnlichen Hotkey-Doppeldruck weitgehend: `RecordingCoordinator` ist `@MainActor`, setzt vor dem ersten `await` `isProcessing = true` und blockiert Start/Stop während Transkription. Mikrofon-Permission, M4A-Anlage, HTTP-/Dateifehler und Swift-Fehler von `engine.start()` werden kontrolliert behandelt. Die folgenden Findings betreffen dagegen Prozess-Aborts bzw. echte Data Races, die von diesen Fehlerpfaden nicht aufgefangen werden.

## F1: Valides, aber veraltetes Tap-Format kann beim Gerätewechsel eine unfangbare AVFoundation-Exception auslösen

**Schweregrad:** kritisch

**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:107-120`, `WhisperM8/Services/Dictation/AudioRecorder.swift:146-159`, `WhisperM8/Services/Dictation/AudioRecorder.swift:278-335`; ergänzend `WhisperM8/Services/Dictation/AudioFormatDecision.swift:17-27`

**Crash-Szenario:** Der User startet die Aufnahme, während macOS das Default-Eingabegerät oder das Bluetooth-Profil wechselt. `inputFormat(forBus:)` liefert zunächst ein gültiges Format, etwa 48 kHz/1 Kanal. Vor `installTap` oder `engine.start()` wechselt das Gerät auf ein anderes Format. Der Code installiert den Tap trotzdem mit dem zuvor gespeicherten Format. AVFoundation kann den Format-Mismatch mit einer Objective-C-Exception quittieren; Swifts `do/catch` um `engine.start()` fängt diese Exception nicht ab. Wirkung: sofortiger Prozess-Abort der gesamten App. Dasselbe TOCTOU-Fenster besteht beim Restart nach einer Engine-Konfigurationsänderung.

**Beweis:** Die Retry-Prüfung akzeptiert jedes Format mit Sample-Rate und Kanalzahl größer null und speichert genau dieses Objekt für die spätere Installation:

```swift
for attempt in 1...5 {
    let format = inputNode.inputFormat(forBus: 0)
    if AudioFormatDecision.isRecordable(format) {
        validFormat = format
        break
    }
}
guard let inputFormat = validFormat else {
    throw RecordingError.invalidFormat
}
```

Zwischen Query und Tap-Installation werden Converter und M4A-Datei angelegt; unmittelbar vor der Installation findet keine erneute Format-/Geräteprüfung statt:

```swift
let file = try AVAudioFile(forWriting: url, settings: settings)
// ...
installRecordingTap(on: inputNode, inputFormat: inputFormat, label: "TAP", logHundredthCallback: true)

do {
    try engine.start()
```

Die lokale Schutzfunktion prüft nur `> 0`, nicht, ob das Format noch dem aktuellen Node-/Hardware-Format entspricht:

```swift
static func isRecordable(sampleRate: Double, channelCount: UInt32) -> Bool {
    sampleRate > 0 && channelCount > 0
}
```

Der Repository-Kommentar in `AudioFormatDecision.swift:17-21` dokumentiert bereits reale Prozess-Aborts durch `installTap` mit 0-Hz-/0-Kanal-Formaten. Commit `90c4fab` schließt diesen Spezialfall, nicht aber den belegbaren Zeitraum zwischen erfolgreicher Validierung und Tap/Start. Der Coordinator bestätigt zudem in `RecordingCoordinator.swift:142-146`, dass gerade der Engine-Start bei Bluetooth-Geräten den A2DP→HFP-Wechsel anstößt.

**Fix-Vorschlag:** Tap-Aufbau und Start als generationengebundene Retry-Operation ausführen: direkt vor der Installation und nochmals vor dem Start das aktuelle Node-Format sowie die Geräteidentität vergleichen; bei Änderung Tap entfernen, Converter neu erzeugen und mit begrenzter Retry-Zahl neu aufbauen. Der Tap sollte nicht mit einem früheren Format arbeiten; bei Installation mit `format: nil` muss der Callback stattdessen konsequent `buffer.format` verwenden und den passenden Converter atomar zuordnen. Da `installTap`/AVFoundation-Assertions keine Swift-`Error`s sind, zusätzlich die kritischen Objective-C-Aufrufe über einen kleinen `@try/@catch`-Wrapper in einem separaten Clang-Target in behandelbare Fehler übersetzen.

**Konfidenz:** hoch

## F2: Konfigurations-Task läuft nach Stop/Abbruch auf einer alten Engine weiter und kann den Zustand einer neuen Aufnahme überschreiben

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:251-350`, `WhisperM8/Services/Dictation/AudioRecorder.swift:182-215`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:448-480`

**Crash-Szenario:** Während einer laufenden Aufnahme löst ein Bluetooth-/Default-Device-Wechsel `handleConfigurationChange()` aus. Der Handler stoppt Engine A, entfernt den Tap und suspendiert für 300 ms. In diesem Fenster bricht der User die Aufnahme per ESC/Overlay ab; `stopRecording()` leert `engine`, `audioFile` und `converter`. Weil `cancelRecording()` keinen Transkriptionszustand setzt, kann der User unmittelbar eine neue Aufnahme mit Engine B starten. Nach dem Sleep prüft der alte Handler weder Session noch Engine-Identität erneut: Er schreibt einen Converter für Engine A in den gemeinsamen Slot, installiert As Tap und startet A. Damit können die Taps von A und B über dieselbe `audioFile`-/`converter`-Ablage laufen. Ein Buffer von Format B gegen einen Converter von Format A bzw. gegen das 16-kHz-Dateiformat kann eine AVFoundation-Format-Assertion im Audio-Thread auslösen; Swift-`catch` fängt eine solche Objective-C-Exception nicht. Ohne unmittelbaren Neustart wird zumindest eine bereits gestoppte, nicht mehr in `self.engine` referenzierte Engine erneut gestartet.

**Beweis:** Der einzige Lifecycle-Guard liegt vor dem ersten Suspension-Point:

```swift
guard isRecording, !isRestarting, let engine = engine else { return }
isRestarting = true
removeConfigurationObserver()
engine.stop()
engine.inputNode.removeTap(onBus: 0)
try? await Task.sleep(nanoseconds: 300_000_000)
```

`stopRecording()` invalidiert währenddessen den gemeinsamen Zustand und setzt sogar `isRestarting` zurück:

```swift
engine = nil
resourceLock.withLock {
    converter = nil
    audioFile = nil
}
isRecording = false
isRestarting = false
```

Nach dem Sleep fehlt ein `guard self.engine === engine && isRecording`. Der alte Handler überschreibt stattdessen wieder den globalen Converter und startet seine gefangene Engine:

```swift
resourceLock.withLock {
    converter = newConverter
}
// ...
installRecordingTap(on: inputNode, inputFormat: inputFormat, label: "NEW TAP", logHundredthCallback: false)
engine.prepare()
try engine.start()
```

Der Tap verwendet zwar den beim Installieren gefangenen `inputFormat`, liest aber `converter` und `audioFile` später aus den gemeinsamen Instanz-Slots:

```swift
self.writeBuffer(buffer, inputFormat: inputFormat, targetFormat: capturedTargetFormat)
```

Damit ist die Zuordnung „Engine/Tap ↔ Converter/Datei" nicht sessionsicher.

**Fix-Vorschlag:** Jede Aufnahme mit einer monotonen Session-Generation versehen. `handleConfigurationChange()` muss Generation und `self.engine === engine` nach jedem `await` sowie unmittelbar vor Converter-Tausch, Tap-Installation und Start prüfen. Stop und Cancel erhöhen die Generation und canceln einen explizit gespeicherten Configuration-Task. Converter und Datei sollten pro Session/Tap gekapselt statt über globale Slots geteilt werden.

**Konfidenz:** mittel

## F3: Der nonisolated-async Recorder liest ein gleichzeitig auf Main mutiertes Swift-Array

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:5-6`, `WhisperM8/Services/Dictation/AudioRecorder.swift:33-95`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:44-49`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:173-194`

**Crash-Szenario:** Ein Geräte-Hotplug oder Default-Device-Wechsel fällt mit einem Hotkey-Start zusammen. `AudioRecorder.startRecording()` gehört zu keiner Actor-Isolation und läuft als nonisolated `async`-Funktion nicht auf dem MainActor. Dort durchsucht sie `AudioDeviceManager.shared.availableDevices`. Der Device-Listener ersetzt dasselbe Array auf dem MainActor. Ein gleichzeitiger Swift-Array-Read und CoW-Write ist ein Data Race mit undefiniertem Verhalten; mögliche Wirkung ist ein Speicherzugriffs-Crash genau beim Aufnahmestart. Zusätzlich werden die nicht isolierten Recorder-Properties auf verschiedenen Executoren benutzt, was F2 bei einem Reentranzfenster verschärft.

**Beweis:** Der Recorder hat keine Actor-Annotation:

```swift
@Observable
class AudioRecorder {
    // ...
    func startRecording() async throws {
```

Der Startpfad liest das gemeinsam veränderliche Array mehrfach:

```swift
let currentDefaultName = deviceManager.availableDevices.first { $0.id == currentDefault }?.name ?? "Unknown"
// ...
let deviceName = deviceManager.availableDevices.first { $0.id == currentDeviceID }?.name ?? "Unknown"
```

Der Hotplug-Listener wird auf der Main-Queue registriert und ersetzt den Array-Wert dort:

```swift
listenerBlock = { [weak self] _, _ in
    self?.refreshDevices()
}
AudioObjectAddPropertyListenerBlock(
    // ...
    DispatchQueue.main,
    listenerBlock!
)
```

```swift
Task { @MainActor in
    self.availableDevices = inputDevices
}
```

Der Trigger ist nicht abstrakt: Gerade ein Hotplug bzw. Profil-/Default-Wechsel ruft `refreshDevices()` auf und ist zugleich der Zustand, in dem der User die Aufnahme typischerweise erneut startet.

**Fix-Vorschlag:** `AudioRecorder` konsequent `@MainActor` isolieren oder seinen kompletten Lifecycle in einen eigenen Actor legen. `AudioDeviceManager` ebenfalls actor-isolieren oder einen unter Lock/Actor erzeugten unveränderlichen Device-Snapshot liefern; die reinen Namen-Lookups im Recorder können alternativ entfallen. Alle CoreAudio-Callbacks müssen nur Events auf diese Isolation zustellen und dürfen den gemeinsam veränderlichen Zustand nicht direkt lesen.

**Konfidenz:** mittel

## Ranking der wahrscheinlichsten Ursachen für den User-Report

1. **F1 – veraltetes Tap-Format beim Geräte-/Bluetooth-Wechsel.** Das Timing passt exakt zu „manchmal beim Start", die gleiche `installTap`-Crash-Klasse ist im Repository bereits für zwei reale Vorfälle dokumentiert, und der bestehende Fix deckt nur 0 Hz/0 Kanäle ab. Dies ist die wahrscheinlichste Ursache.
2. **F2 – fortgesetzter Configuration-Handler nach Stop/Abbruch.** Besonders plausibel bei AirPods und schnellem Abbruch/Neustart; benötigt ein engeres, aber im Code klar vorhandenes `await`-Interleaving.
3. **F3 – Array-/Lifecycle-Data-Race beim Hotplug.** Der Race ist real und zeitlich passend, der konkrete Crash-Ausgang aber weniger deterministisch als die AVFoundation-Exception aus F1.

Nicht als Crash-Ursachen gewertet wurden die konstanten Force-Unwraps für feste 16-kHz-/HTTPS-Werte, das unmittelbar zuvor gesetzte `listenerBlock!`, die kontrolliert werfenden M4A-/Multipart-Dateipfade sowie `MainActor.assumeIsolated` in `RecordingPanel`: Die betreffenden Notification-Observer werden explizit mit `queue: .main` registriert. Für diese Stellen ist im untersuchten Hot-Path keine auslösbare harte Crash-Kette belegt.
