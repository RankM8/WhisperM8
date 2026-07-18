# Crash-Jagd Diktat-Start — zweiter unabhängiger Durchgang (Finder: Fable)

**Auftrag:** User-Report „Beim Start der Transkribierung stürzt gelegentlich die GESAMTE App ab".
**Fokus:** `WhisperM8/Services/Dictation/` (AudioRecorder, RecordingCoordinator + Extensions, AppState, RecordingPanel).
**Methode:** reine Code-Analyse (kein Build/Test), git-Historie der letzten 30 Commits geprüft.

**Historischer Kontext aus git:** Commit `90c4fab` (2026-07-08, „fix(audio): Crash beim Aufnahmestart mit ungültigem Hardware-Format") hat bereits genau diese Crash-Klasse adressiert — 0-Hz-/0-Kanal-Formate werden seither vor `installTap` validiert (`AudioFormatDecision.isRecordable`). Der Kommentar in `AudioFormatDecision.swift:17-21` dokumentiert zwei reale Abstürze (2026-07-01 + 2026-07-08). Die Analyse unten zeigt: **die Validierung schließt nur das 0-Hz-Fenster, nicht die übrigen TOCTOU-Fenster derselben unfangbaren ObjC-Exception-Klasse.**

---

## F1: TOCTOU-Fenster zwischen Format-Query und `installTap`/`engine.start()` — unfangbare NSException bei Gerätewechsel im Startmoment

**Schweregrad:** kritisch
**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:107-120` (Format-Query), `:155` (Tap-Install), `:158-170` (Engine-Start); identisches Fenster in `handleConfigurationChange` `:278-288` → `:329` → `:333-336`.

**Szenario (Auslöser → Wirkung):**
User startet Diktat exakt in dem Moment, in dem macOS das Eingabegerät wechselt (Bluetooth A2DP→HFP-Profilswitch beim Engine-Start ist der Normalfall bei AirPods — der Aufnahmestart selbst *löst* diesen Switch aus; ebenso: Gerät ein-/ausstecken, coreaudiod unter Last). Zwischen dem Lesen des Formats und `engine.start()` ändert sich das Hardware-Format auf einen *anderen validen* Wert (z. B. 48 kHz → 24 kHz HFP). Der Tap ist dann mit dem alten Format installiert; AVFoundation wirft beim Start bzw. beim ersten Render `NSInvalidArgumentException` („required condition is false: hwFormat.sampleRate == format.sampleRate", AVAudioIONodeImpl). Das ist eine **Objective-C-Exception — Swifts `do/catch` um `try engine.start()` kann sie nicht fangen** → sofortiger Prozess-Abort, die gesamte App (inkl. aller offenen Agent-Chat-Sessions) stirbt.

**Beweis:**

Die Validierung prüft nur „überhaupt aufnahmefähig", nicht „noch aktuell":

```swift
// AudioRecorder.swift:107-120
for attempt in 1...5 {
    let format = inputNode.inputFormat(forBus: 0)
    if AudioFormatDecision.isRecordable(format) {
        validFormat = format
        ...
        break
    }
    ...
}
guard let inputFormat = validFormat else { ... throw RecordingError.invalidFormat }
```

Danach liegen Converter-Erzeugung, Datei-Anlage und Tap-Install **vor** dem Start — jedes ein Zeitfenster:

```swift
// AudioRecorder.swift:146-159
let file = try AVAudioFile(forWriting: url, settings: settings)
...
installRecordingTap(on: inputNode, inputFormat: inputFormat, label: "TAP", ...)
Logger.debug("[AudioRecorder] Starting engine...")
do {
    try engine.start()
```

Das `do/catch` fängt nur Swift-`Error`s; die Format-Assertion von AVFoundation ist eine NSException. Genau dieses Verhalten dokumentiert das Projekt selbst:

```swift
// AudioFormatDecision.swift:19-21
// ... Ein `installTap` mit so einem Format wirft eine unfangbare
// ObjC-NSException und reißt den Prozess (Crash 2026-07-01 + 2026-07-08).
```

`90c4fab` hat nur den Spezialfall „Format = 0 Hz/0 ch" abgedeckt. Der Fall „Format war valide, ist aber beim Start schon wieder ein anderes" bleibt offen — und ist bei Bluetooth-Geräten strukturell wahrscheinlich, weil der HFP-Switch *durch den Engine-Start selbst* angestoßen wird (siehe Kommentar `RecordingCoordinator.swift:142-146`: „Volume MUSS gelesen werden BEVOR der AVAudioEngine startet, sonst hat macOS … bereits den A2DP→HFP-Profile-Switch angestossen").

In `handleConfigurationChange` ist das Fenster noch größer: 300 ms Sleep (`:271`) + bis zu 5×100 ms Format-Retries (`:278-288`), dann Tap-Install (`:329`) und Start (`:335`) — ein zweiter Profilswitch in dieser Phase (BT-Reconnect-Storm ist genau das Szenario, das den Handler überhaupt auslöst) trifft wieder ein unfangbares Fenster.

**Fix-Vorschlag:**
1. Unmittelbar vor `engine.start()` das Format erneut lesen und mit dem Tap-Format vergleichen; bei Abweichung Tap entfernen und mit dem frischen Format neu installieren (Schleife mit Obergrenze).
2. Zusätzlich einen ObjC-Exception-Trampolin um `installTap`/`engine.start()` legen (kleine ObjC-Hilfsfunktion `WM8CatchException(void(^)(void))` via `@try/@catch`, in Swift als `throws` gebridged) — das ist die einzige Möglichkeit, diese AVFoundation-Assertions in einen behandelbaren Fehler (`RecordingError.invalidFormat` → Alert statt Abort) zu verwandeln. Ohne SwiftPM-ObjC-Target alternativ `NSSetUncaughtExceptionHandler` nur fürs Logging, aber der Trampolin ist der eigentliche Fix.

**Konfidenz:** hoch (Crash-Klasse zweimal real aufgetreten, Fix deckt nachweislich nur ein Teilfenster ab; Restfenster im Code direkt belegbar).

---

## F2: `handleConfigurationChange` prüft nach seinen `await`-Punkten nicht neu — Zombie-Engine-Restart und Stale-Converter-Überschreibung → Format-Mismatch-Exception im Tap-Callback

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:252-350` (Guard nur am Eintritt `:254`, Sleeps `:271`, `:287`), Converter-Überschreibung `:308-322`, Tap-Install `:329`, Restart `:333-336`; Gegenspieler `stopRecording()` `:182-215` und `startRecording()` `:33-180`.

**Szenario (Auslöser → Wirkung):**
1. Aufnahme läuft im System-Default-Modus, ein Config-Change (BT-Switch) feuert → `handleConfigurationChange` passiert den Eintritts-Guard, stoppt die Engine und schläft 300 ms (`:271`).
2. Während des Sleeps stoppt der User die Aufnahme (KeyUp) — `stopRecording()` läuft durch (`engine = nil`, `audioFile = nil`, `isRecording = false`) — und startet unmittelbar ein neues Diktat (typisch: „kurz abgebrochen, direkt neu diktiert"). `startRecording()` legt Engine B, `audioFile` B und Converter B an.
3. Der Handler wacht auf. **Nach dem Sleep gibt es keinen Re-Check von `isRecording`/Engine-Identität** — er arbeitet auf seiner lokalen Referenz der *alten* Engine A weiter: überschreibt unter dem Lock den **gemeinsamen** `converter` mit einem Converter für As Format (`:311-313`) bzw. setzt ihn auf `nil` (`:318-320`), installiert einen Tap auf Engine A (`:329`) und startet A neu (`:335`).
4. Ab jetzt schreiben **zwei** Taps (A und B) mit **unterschiedlichen Input-Formaten** über den einen geteilten `converter`/`audioFile`-Zustand. Sobald Bs Buffer (Format Y) durch einen Converter läuft, dessen Input-Format X ist — oder bei `converter == nil` ein Nicht-16-kHz-Buffer direkt in die 16-kHz-Datei geschrieben wird — wirft AVFoundation eine NSException („required condition is false: [format isEqual: _fromFormat]" in AVAudioConverter bzw. Format-Assertion in `AVAudioFile.write`). Die Exception fliegt **im Realtime-Audio-Thread** — das `try` in `writeBufferLocked` fängt sie nicht → App-Abort.

**Beweis:**

Guard nur am Eintritt, danach zwei Suspension-Points ohne Re-Validierung:

```swift
// AudioRecorder.swift:254-271
guard isRecording, !isRestarting, let engine = engine else { ... return }
isRestarting = true
...
engine.stop()
engine.inputNode.removeTap(onBus: 0)
...
try? await Task.sleep(nanoseconds: 300_000_000)
```

`stopRecording()` setzt derweil `isRestarting = false` (`:204`) — hebt also sogar die Reentranz-Sperre auf — und der Handler schreibt anschließend in den geteilten Zustand:

```swift
// AudioRecorder.swift:310-320
let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
resourceLock.withLock {
    converter = newConverter
}
...
} else {
    resourceLock.withLock {
        converter = nil
    }
```

Der Tap-Pfad vertraut darauf, dass `converter` zum übergebenen `inputFormat` passt:

```swift
// AudioRecorder.swift:452-455 / :472
let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
    outStatus.pointee = .haveData
    return buffer          // Buffer-Format ≠ Converter-Input-Format → NSException
}
...
try audioFile.write(from: buffer)   // Buffer-Format ≠ File-Processing-Format → NSException
```

Selbst ohne Neustart (nur Stop während des Sleeps) bleibt ein Defekt: Der Handler installiert den Tap auf der verwaisten Engine A und startet sie neu — niemand referenziert sie mehr (`engine`-Property ist `nil`), sie läuft mit heißem Mikrofon weiter (Orange-Dot-Leak), bis der Prozess endet; `startRecording()`s Cleanup (`:37-40`, `if engine != nil`) greift nicht, weil die Property leer ist.

**Fix-Vorschlag:** Nach **jedem** `await` in `handleConfigurationChange` re-validieren: `guard isRecording, self.engine === engine else { return }` (Engine-Identität statt nur Flag); zusätzlich in `stopRecording()` eine Generationszählung (`sessionGeneration += 1`) hochzählen und im Handler die beim Eintritt gelesene Generation vergleichen. Converter/AudioFile nie über eine gefangene lokale Engine-Referenz einer beendeten Session mutieren.

**Konfidenz:** mittel (Interleaving-Fenster ~300-800 ms, exakt belegbar, da alle Beteiligten MainActor-serialisiert nur an den `await`s verzahnen; der finale Exception-Wurf von AVAudioConverter/AVAudioFile bei Format-Mismatch ist dokumentiertes AVFoundation-Verhalten, aber hier nicht durch Repro verifiziert).

---

## F3: `AudioRecorder.startRecording()` läuft als nonisolated-async **abseits** des MainActor — Data Races auf Engine-State und `AudioDeviceManager.availableDevices`

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:5-6` (Klasse ohne Actor-Isolation), `:33` (`func startRecording() async`), Aufrufer `RecordingCoordinator.swift:25-26` (`@MainActor`) `:149`; Reads `AudioRecorder.swift:82, 94, 302` gegen Write `AudioDeviceManager.swift:173-175`.

**Szenario (Auslöser → Wirkung):**
`RecordingCoordinator` ist `@MainActor`, aber `AudioRecorder` ist eine nicht-isolierte Klasse — nach SE-0338 hüpft `try await audioRecorder.startRecording()` auf den globalen Executor: **die komplette Engine-Konstruktion, Tap-Install und die Mutationen von `engine`, `recordingURL`, `isRecording`, `audioLevel` laufen auf einem Background-Thread**, während `stopRecording()` (synchron, `:182`) und `handleConfigurationChange` (`@MainActor`, `:251`) dieselben Properties vom Main-Thread mutieren. Zusätzlich liest der Background-Pfad `AudioDeviceManager.availableDevices` (`:82`, `:94`), das per `Task { @MainActor in self.availableDevices = inputDevices }` (AudioDeviceManager.swift:173-175) auf dem Main-Thread **ersetzt** wird — unsynchronisierter Array-Read während CoW-Replacement ist Undefined Behavior und kann (selten) crashen. Gleiches Muster: der C-Callback `defaultInputDeviceChangedProc` (AudioDeviceManager.swift:14-42) läuft auf einem CoreAudio-Thread und liest `manager.currentDefaultDeviceID` (`:28, :30`), das auf Main geschrieben wird (`:33`).

**Beweis:**

```swift
// AudioRecorder.swift:5-6 — keine Actor-Annotation:
@Observable
class AudioRecorder {
```

```swift
// AudioRecorder.swift:82 — Read auf dem globalen Executor:
let currentDefaultName = deviceManager.availableDevices.first { $0.id == currentDefault }?.name ?? "Unknown"
```

```swift
// AudioDeviceManager.swift:173-175 — Write auf MainActor:
Task { @MainActor in
    self.availableDevices = inputDevices
}
```

`refreshDevices()` wird u. a. vom Hotplug-Listener genau dann getriggert, wenn Geräte wechseln (AudioDeviceManager.swift:185-188) — also exakt zeitgleich mit Aufnahme-Starts nach Gerätewechsel. Außerdem: `isRecording = true` (`AudioRecorder.swift:173`) mutiert eine `@Observable`-Property off-main, während SwiftUI/Coordinator sie auf Main beobachten.

**Fix-Vorschlag:** `AudioRecorder` `@MainActor` machen (die blockierenden Anteile — Format-Retries, Permission — sind bereits `async`) oder als `actor` modellieren; `availableDevices`-Zugriffe aus dem Recorder über eine MainActor-Hop-API führen. Minimal-invasiv: die beiden Namens-Lookups (`:82`, `:94`, `:302`) sind reine Log-Kosmetik und können auf eine thread-sichere Snapshot-Kopie umgestellt werden.

**Konfidenz:** hoch, dass die Races existieren (TSan würde alle anschlagen); mittel, dass sie der gemeldete Crash sind (CoW-Array-Race crasht selten, passt aber zeitlich exakt zum „Start nach Gerätewechsel"-Muster).

---

## F4: AVAudioConverter-Input-Block liefert immer `.haveData` mit demselben Buffer — Audio-Duplikate bei Ratenkonvertierung

**Schweregrad:** niedrig (kein Crash, aber verifizierbarer Korrektheits-Defekt im selben Hot-Path)
**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:452-455`.

**Szenario (Auslöser → Wirkung):** Bei Sample-Rate-Konvertierung (48 kHz → 16 kHz, der Standardfall) darf der Converter den Input-Block **mehrfach pro `convert`-Aufruf** rufen, bis die Output-Kapazität gefüllt ist. Der Block liefert bei jedem Aufruf denselben Buffer mit `.haveData`:

```swift
// AudioRecorder.swift:452-455
let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
    outStatus.pointee = .haveData
    return buffer
}
```

Korrekt wäre, nach der ersten Lieferung `.noDataNow` zu melden. So können einzelne Frames doppelt in die M4A einfließen (hörbare Mikro-Wiederholungen, potenziell schlechtere Transkription).

**Fix-Vorschlag:** Captured `var consumed = false`; beim zweiten Aufruf `outStatus.pointee = .noDataNow; return nil`.

**Konfidenz:** hoch (dokumentiertes AVAudioConverter-Kontrakt-Detail; Auswirkung abhängig von Kapazitätsrundung in `:437-439`).

---

## F5: Stop-Pfad kann M4A vor Finalisierung zur Transkription freigeben

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/Dictation/AudioRecorder.swift:193-214` und `RecordingCoordinator.swift:304-334`.

**Szenario (Auslöser → Wirkung):** `stopRecording()` entfernt den Tap und nullt `audioFile` unter dem Lock — ein **gerade laufender** Tap-Callback hält aber via `guard let audioFile` (`:426`) eine eigene starke Referenz und schreibt noch. Die AAC/M4A-Datei wird erst beim letzten Release des `AVAudioFile` finalisiert (moov-Atom). `stopRecording()` gibt die URL sofort zurück, der Coordinator startet direkt danach den Upload (`RecordingCoordinator.swift:329`). Im (kleinen) Fenster kann eine noch nicht finalisierte Datei hochgeladen werden → „invalid audio file"-Fehler beim Provider, kein Crash. Erklärt möglicherweise sporadische Transkriptions-Fehlschläge direkt nach dem Stop.

**Beweis:** `engine.inputNode.removeTap(onBus: 0)` / `engine.stop()` (`:195-196`) garantieren nicht synchron das Ende eines in-flight Render-Callbacks; die Datei-Lebensdauer hängt am letzten Strong-Ref im Callback (`writeBufferLocked`, `:426`).

**Fix-Vorschlag:** Nach `engine.stop()` einmal `resourceLock.lock(); audioFile = nil; resourceLock.unlock()` (bereits vorhanden) **plus** explizit auf den Lock warten reicht fast — deterministischer: `audioFile` lokal herausziehen und erst nach Lock-Freigabe fallen lassen, dann URL zurückgeben; oder vor dem Upload die Datei einmalig auf lesbaren moov prüfen.

**Konfidenz:** niedrig-mittel (Fensterbreite ein Buffer ≈ 85 ms Worst Case; Mechanismus plausibel, nicht reproduziert).

---

## Ranking der wahrscheinlichsten Ursachen für den Report

1. **F1 — TOCTOU-Format-Fenster beim Engine-Start (kritisch, Konfidenz hoch).** Dieselbe Crash-Klasse hat die App nachweislich schon zweimal getötet; der Fix `90c4fab` deckt nur 0-Hz-Formate ab. Bluetooth-User treffen das Fenster strukturell, weil der Aufnahmestart selbst den A2DP→HFP-Switch auslöst. Unfangbare NSException → „die GESAMTE App stürzt ab" passt exakt.
2. **F2 — Zombie-`handleConfigurationChange` nach Stop/Neustart (hoch, Konfidenz mittel).** Braucht das Muster „Config-Change + schneller Stop + sofortiger Neustart", endet dann aber in derselben unfangbaren Exception-Klasse (Converter-/File-Format-Mismatch im Audio-Thread) — plus Mic-Leak als harmloserer Ausgang.
3. **F3 — Off-MainActor-Races (mittel, Konfidenz für Crash mittel).** Reale Data Races (u. a. CoW-Array-Read von `availableDevices` während Main-Thread-Replacement), zeitlich korreliert mit Gerätewechsel-Starts; crasht seltener als F1/F2, ist aber derselbe Trigger-Moment.
4. **F4/F5** sind Qualitäts-/Zuverlässigkeitsdefekte im selben Pfad, keine plausiblen Ursachen für den Voll-Absturz.

**Empfohlene Sofortmaßnahme:** ObjC-Exception-Trampolin um `installTap` + `engine.start()` (F1-Fix Teil 2) — er entschärft F1 **und** die Exception-Ausgänge von F2 in einem Schritt und verwandelt jeden künftigen Vertreter dieser Klasse in einen behandelbaren Fehler mit Alert statt App-Abort.
