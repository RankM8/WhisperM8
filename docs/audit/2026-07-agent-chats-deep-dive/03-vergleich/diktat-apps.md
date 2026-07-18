---
status: aktiv
updated: 2026-07-18
description: Vergleich von Open-Source-Diktat-Apps für macOS (VoiceInk, Handy, WhisperKit u. a.) mit WhisperM8s Diktat-Pipeline — Audio-Lifecycle, Modelle, Hotkeys, Paste.
---

# Open-Source-Diktat-Apps im Vergleich zu WhisperM8

Research-Stand: 2026-07-18. Alle Aussagen zu Fremdprojekten basieren auf den echten GitHub-Repos (Quellcode via `raw.githubusercontent.com` gelesen, Metadaten via GitHub-API). WhisperM8-Referenzen zeigen auf `WhisperM8/Services/Dictation/AudioRecorder.swift`, `AudioFormatDecision.swift` und `PasteService.swift`.

Anlass des Vergleichs: **sporadische Crashes beim Transkriptionsstart** in WhisperM8. Der bekannte Crash-Mechanismus ist dokumentiert in `AudioFormatDecision.swift`: CoreAudio liefert direkt nach dem Geräte-Binden zeitweise 0 Hz / 0 Kanäle, und ein `installTap` mit so einem Format wirft eine **unfangbare ObjC-NSException** (Crashes 2026-07-01 und 2026-07-08). Genau diese Problemklasse hat VoiceInk im Januar 2026 zum kompletten Ausstieg aus `AVAudioEngine` bewogen (siehe unten).

---

## 1. Projektübersicht

| Projekt | Link | Sprache / Stack | Lizenz | Aktivität (Stand 2026-07-18) |
|---|---|---|---|---|
| **VoiceInk** (Beingpax / Prakash Joshi Pax) | [github.com/Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) | Swift, SwiftUI, whisper.cpp + FluidAudio (Parakeet) + 10+ Cloud-Provider | GPL-3.0 (laut README; API meldet NOASSERTION) | Sehr aktiv: ~5 600 Stars, Release v2.0 am 2026-07-16, letzter Push 2026-07-16 |
| **Handy** (cjpais) | [github.com/cjpais/Handy](https://github.com/cjpais/Handy) | Rust + Tauri (React/TypeScript-Frontend), cpal, transcribe-cpp/transcribe-rs, Silero-VAD, enigo | MIT | Sehr aktiv: ~26 800 Stars, Release v0.9.3 am 2026-07-15, Push 2026-07-18 |
| **WhisperKit** (argmaxinc, Repo heute `argmax-oss-swift`) | [github.com/argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) | Swift-Library (keine App): Whisper via CoreML auf Apple Silicon, AVAudioEngine-Capture | MIT | Aktiv: ~6 300 Stars, Push 2026-07-13; Repo wurde in `argmax-oss-swift` umbenannt (WhisperKit + TTSKit + SpeakerKit als Produkte), Release v1.0.0 2026-05 |
| **whisper.cpp** (ggml-org) | [github.com/ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) | C/C++, ggml; Inferenz-Engine, die VoiceInk & Co. einbetten | MIT | Sehr aktiv: ~51 800 Stars, Push 2026-07-11 |
| **Hex** (kitlangton) — ergänzend | [github.com/kitlangton/Hex](https://github.com/kitlangton/Hex) | Swift, Composable Architecture; WhisperKit + FluidAudio/Parakeet, Press-and-hold-Diktat | MIT | Aktiv: ~2 500 Stars, Push 2026-07-14 |
| **Whispering** (EpicenterHQ/epicenter) — ergänzend | [github.com/EpicenterHQ/epicenter](https://github.com/EpicenterHQ/epicenter) | TypeScript/Svelte + Tauri; lokal oder eigene API-Keys | k. A. (Monorepo) | Aktiv: ~4 700 Stars, Push 2026-07-17 |
| **handy-cli** (cjpais) | [github.com/cjpais/handy-cli](https://github.com/cjpais/handy-cli) | Python-Vorläufer von Handy | — | **Tot / abgelöst** durch Handy |
| **Whispera** (sapoepsilon) — ergänzend | [github.com/sapoepsilon/Whispera](https://github.com/sapoepsilon/Whispera) | Swift + WhisperKit | — | Kleines Projekt, geringe Aktivität — nur als Randnotiz |

Alle vier Hauptkandidaten leben; kein Kandidat musste als tot markiert werden (nur handy-cli ist ein abgelöster Vorläufer). MacWhisper und Superwhisper sind **nicht** Open Source und wurden deshalb nicht analysiert.

---

## 2. Wie lösen die Projekte die Kernprobleme?

### 2.1 Audio-Capture-Lifecycle (Gerätewechsel, Format-Mismatch, Tap-Verwaltung)

#### VoiceInk: kompletter Ausstieg aus AVAudioEngine → roher AUHAL-Recorder

Der wichtigste Befund des ganzen Vergleichs. VoiceInk hat am **2026-01-10** (Commit `c530367`, „Replace audio recorder with CoreAudio AUHAL") seinen Recorder durch `VoiceInk/CoreAudioRecorder.swift` (~1 300 LOC) ersetzt — ein AUHAL-AudioUnit, das direkt auf dem Zielgerät aufsetzt, ohne `AVAudioEngine` und ohne `installTap`. Die Folge-Commits benennen die Motivation explizit: *„Fix potential crashes and silent failures in audio recording"* und *„Guard check to validate device exists before AudioUnit setup"*. Kernmerkmale:

- **Geräte-Validierung vor Setup**: `validateDevice(deviceID)` bevor irgendein AudioUnit konfiguriert wird; `prepare(deviceID:)` kann das AudioUnit **vorwärmen**, ohne Capture zu starten (Recorder wird beim App-Start und bei Gerätewechsel im Leerlauf vorbereitet — reduziert die Start-Latenz und verschiebt Fehler weg vom Hotkey-Moment).
- **Formatkontrolle statt Format-Raten**: Das Geräteformat wird per `AudioUnitGetProperty(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, …)` gelesen, das Callback-Format explizit gesetzt (Float32, native Sample-Rate). Fehler sind **OSStatus-Rückgaben, keine NSExceptions** — jede Fehlkonfiguration ist fangbar. Genau der Unterschied zur `installTap`-Falle, die WhisperM8 crasht.
- **Gerätewechsel MITTEN in der Aufnahme ohne Dateiverlust**: `switchDevice(to:)` stoppt das AudioUnit (`AudioOutputUnitStop`), wartet aktiv auf laufende Render-Callbacks (`waitForRenderCallbacksToFinish`), dräniert die Processing-Queue, `AudioUnitUninitialize`, setzt das neue Gerät, liest dessen Format, konfiguriert das Callback-Format neu, re-allokiert Puffer, `AudioUnitInitialize` + `Start` — die WAV-Datei bleibt dabei durchgehend offen. Bei Fehlschlag gibt es einen expliziten **Recovery-Pfad zurück zum alten Gerät**.
- **Geräte-Ereignisse via CoreAudio-Listener, nicht via Engine-Notification**: `AudioDeviceManager` registriert `AudioObjectAddPropertyListener` auf `kAudioHardwarePropertyDevices`. Ändert sich die Geräteliste während einer Aufnahme, wird eine `audioDeviceSwitchRequired`-Notification mit der neuen Ziel-DeviceID gefeuert; im Leerlauf wird nur neu vorbereitet. Dazu kommt eine **vom Nutzer priorisierte Geräteliste** (`PrioritizedDevice`, Rebinding über Device-UID + Model-UID, Fallback `findBestAvailableDevice()` → eingebautes Mikro).
- **Realtime-Sicherheit**: Lock-freier Ringpuffer (96 Slots, `ManagedAtomic`-Indizes), vorallokierte Render-Puffer, Pegel-Metering über Atomics-Bitpattern statt Locks, Backpressure-Zähler für verworfene Puffer. Der Render-Callback macht nie Malloc, nie Locking, nie File-I/O.
- Ausgabeformat: 16 kHz mono Int16 WAV via `ExtAudioFile` (Konvertierung außerhalb des Render-Callbacks auf einer seriellen Queue).

Der ältere High-Level-Wrapper `VoiceInk/Recorder.swift` orchestriert nur noch: serielle `audioSetupQueue` für Hardware-Setup, `isReconfiguring`-Flag gegen konkurrierende Switches, Nutzer-Notification beim Auto-Switch, Media-Pause/Mute um die Aufnahme herum.

#### Handy: cpal mit „native Rate, nie erzwingen"-Politik + Retry-einmal-Strategie

Handy (Rust) benutzt `cpal` 0.16. Die relevanten Muster in `src-tauri/src/audio_toolkit/audio/recorder.rs` und `src-tauri/src/managers/audio.rs`:

- **Nie die Hardware auf 16 kHz zwingen**: `get_preferred_config()` nimmt die native Default-Sample-Rate des Geräts und lässt einen nachgelagerten `FrameResampler` (rubato) auf 16 kHz herunterrechnen. Kommentar im Code: das Erzwingen einer Nicht-nativen Rate „can cause issues on some devices (Bluetooth codecs, certain ALSA drivers)". Bei der Formatwahl wird F32 > I16 > I32 priorisiert, mit Fallback auf die Default-Config bei exotischen/virtuellen Geräten.
- **Geräte-Cache mit Invalidierung + genau ein Retry**: Der `AudioRecordingManager` cached das aufgelöste `cpal::Device` per Name. Schlägt `rec.open()` fehl (Gerät abgesteckt, Config stale), wird der Cache invalidiert, das Gerät **neu aufgelöst und genau einmal retried**, bevor der Fehler hochgereicht wird. System-Default wird bewusst nie gecached — der Recorder löst ihn bei jedem Start billig selbst auf.
- **Mikrofon-Modi „AlwaysOn" vs. „OnDemand" mit Lazy-Close**: Im AlwaysOn-Modus bleibt der Stream dauerhaft offen (keine Startlatenz, kein „erstes Wort verschluckt"); im OnDemand-Modus schließt ein `schedule_lazy_close()` den Stream erst verzögert nach Aufnahme-Ende, damit schnelle Folgeaufnahmen den warmen Stream wiederverwenden.
- **Fehlerklassifizierung über Strings**: `is_microphone_access_denied()` / `is_no_input_device_error()` mappen cpal/CoreAudio-Fehlertexte auf verständliche Zustände (Berechtigung fehlt vs. kein Gerät). Der cpal-Error-Callback im laufenden Stream loggt nur — ein mid-stream-Gerätewechsel wird nicht nahtlos überbrückt, sondern läuft über Stop/Neustart (schwächer als VoiceInk).
- Kanal-Downmix auf Mono direkt im Stream-Callback (Mittelwert über Frames), Silero-VAD (`vad-rs`) mit getrennten Offline-/Streaming-Hangover-Profilen.

#### WhisperKit: gleicher AVAudioEngine-Ansatz wie WhisperM8 — mit denselben Lücken

`Sources/WhisperKit/Core/Audio/AudioProcessor.swift` (~1 100 LOC) ist WhisperM8s Ansatz strukturell am ähnlichsten: `AVAudioEngine`, Geräteauswahl via `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` (`assignAudioInput`), `installTap` mit 0,1-s-Puffer, `AVAudioConverter` auf 16 kHz mono Float32.

Bemerkenswert zwei Details:

1. **Format-Mismatch-Workaround im `setupEngine()`**: WhisperKit baut das Tap-Format nicht direkt aus `inputFormat(forBus:)`, sondern kombiniert `hardwareSampleRate = inputNode.inputFormat(forBus: 0).sampleRate` mit dem `outputFormat(forBus: 0)` des Nodes zu einem neuen `nodeFormat`. Das umgeht die bekannte AVAudioEngine-Falle, dass Input- und Output-Format des inputNode nach Gerätewechseln auseinanderlaufen. Fehler beim Format-/Converter-Bau werfen `WhisperError` (guard-basiert) — aber ein 0-Hz-Format wird **nicht** speziell abgefangen; `installTap` mit kaputtem Format würde auch WhisperKit abschießen.
2. **Kein Configuration-Change-Handling**: `AudioProcessor` beobachtet `AVAudioEngineConfigurationChange` nicht. Gerätewechsel mid-stream sind dem Aufrufer überlassen. WhisperM8s `handleConfigurationChange()` mit Format-Retry-Schleife ist hier bereits **robuster als die Referenz-Library**.

#### whisper.cpp

Reine Inferenz-Engine; Capture ist Sache der Beispiele (SDL2 im `stream`-Beispiel) bzw. der einbettenden Apps. Für den Audio-Lifecycle-Vergleich liefert whisper.cpp selbst keine Muster, wohl aber die Erwartung: 16 kHz mono Float32 PCM — dieselbe Zielformat-Konvention, die alle Apps inkl. WhisperM8 fahren.

### 2.2 Lokale Modelle vs. Cloud-APIs

| Projekt | Lokal | Cloud | Architektur-Muster |
|---|---|---|---|
| VoiceInk | whisper.cpp (GGUF), FluidAudio/Parakeet (+ Nemotron-Streaming), lokales VAD-Modell, Modell-Warmup-Koordinator | Groq, OpenAI-kompatibel, Deepgram, ElevenLabs, Mistral, Gemini, AssemblyAI, Soniox, Speechmatics, Cartesia, xAI + Custom-Endpoints; einige davon auch als Streaming-Provider | `TranscriptionServiceRegistry` mit einheitlichem Provider-Protokoll; „Power Mode" wählt Modell/Provider pro Ziel-App |
| Handy | Ausschließlich lokal: Whisper-Familie via transcribe-cpp (ggml, Metal auf macOS), Parakeet V3 / Moonshine / SenseVoice via transcribe-rs (ONNX), Streaming-Modelle seit v0.9 | Keine (bewusst offline-only) | Modell-Manager mit Download/Capabilities-Katalog; CPU-vs-GPU-Wahl über Cargo-Features pro Plattform |
| WhisperKit | CoreML-kompilierte Whisper-Varianten (Hugging Face `argmaxinc/whisperkit-coreml`), ANE/GPU | Kein Cloud-Pfad in der OSS-Library (Pro-Produkte separat) | Library-Produkt; Apps wie Hex/Whispera bauen darauf |
| Hex | Parakeet TDT v3 (FluidAudio) + WhisperKit | Keine | — |
| **WhisperM8** | **Keine** | OpenAI Whisper API, Groq | `TranscriptionProviders.swift`, Multipart-Upload des M4A |

Muster im Feld: **Hybrid ist der Normalfall geworden** (VoiceInk), reine Cloud-Pipelines sind unter den Open-Source-Diktat-Apps die Ausnahme. Der lokale Einstiegspfad läuft 2026 fast immer über Parakeet V3 (schnell, CPU-tauglich) plus Whisper-Modelle für Sprachvielfalt.

### 2.3 Hotkey-Architektur

- **VoiceInk** (`VoiceInk/Shortcuts/ShortcutMonitor.swift`): eigener **CGEventTap** auf `keyDown/keyUp/flagsChanged`. Damit gehen (a) Modifier-only- und Fn-Hotkeys (Push-to-talk auf reinem `flagsChanged`), (b) **Event-Suppression** (der Hotkey erreicht die Ziel-App nicht) und (c) Press-and-hold-Erkennung. Wichtiges Robustheits-Detail: im Tap-Callback wird `tapDisabledByTimeout/byUserInput` behandelt und der Tap per `CGEvent.tapEnable(tap:enable:true)` **selbst reaktiviert** — sonst stirbt ein Event-Tap unter Last leise. Kostet: benötigt Accessibility/Input-Monitoring.
- **Handy** (`src-tauri/src/shortcut/`): **Dual-Backend mit automatischem Fallback**. Backend 1 ist `tauri-plugin-global-shortcut` (OS-Registrierung, konservativ), Backend 2 „HandyKeys" auf Basis des rustdesk-`rdev`-Forks (Low-Level-Listener, kann mehr Tastenkombinationen und Press/Release sauber unterscheiden). Schlägt die HandyKeys-Initialisierung fehl, wird **automatisch auf das Tauri-Backend zurückgerollt und der Fallback persistiert**, damit der nächste Start nicht wieder in den Fehler läuft. Die Event-Semantik (Push-to-talk vs. Toggle, Cancel nur während Aufnahme) liegt backend-neutral in `handler.rs`.
- **WhisperKit**: Library, kein Hotkey-Layer.
- **WhisperM8**: `KeyboardShortcuts`-Package (Carbon `RegisterEventHotKey`). Vorteile: kein Accessibility-Zwang fürs Hotkey selbst, systemkonforme Konflikterkennung. Grenzen: keine Modifier-only-/Fn-Hotkeys, kein echtes Press-and-hold-Push-to-talk.

### 2.4 Paste-Strategien

- **VoiceInk** (`VoiceInk/Paste/`): Zwei umschaltbare Methoden — Standard (CGEvent Cmd+V) und **AppleScript** (`System Events keystroke "v" using command down`) als Kompatibilitäts-Fallback für Apps, die synthetische CGEvents schlucken. Dazu das sauberste Clipboard-Handling im Feld: **Snapshot aller Pasteboard-Items mit allen Typen** (nicht nur String), Markierung des eigenen Eintrags als `transient` mit **Session-ID**, und vor der Wiederherstellung ein Ownership-Check (`pasteboardStillOwnedByPasteSession`) — hat der Nutzer inzwischen selbst etwas kopiert, wird **nicht** überschrieben. Restore-Delay ist konfigurierbar (min. 0,25 s).
- **Handy** (`src-tauri/src/input.rs`, `clipboard.rs`): `enigo` synthetisiert wahlweise Cmd/Ctrl+V, Ctrl+Shift+V (Terminals!), Shift+Insert (Linux) oder **tippt den Text direkt** (`enigo.text()`, ohne Clipboard). Paste-Delays vor/nach sind als Debug-Settings konfigurierbar; Clipboard-Inhalt wird gelesen und restauriert.
- **Hex**: Press-and-hold → Paste an der Cursor-Position, gleiche CGEvent-Klasse.
- **WhisperM8** (`PasteService.swift`): CGEvent Cmd+V nach Reaktivierung der zuvor fokussierten App (`previousApp.activate()` + `waitForActivation`), Attachments werden sequenziell mit eigenen Cmd+V-Events nachgeschoben, danach wird **nur der Text** zurück ins Clipboard gelegt (`restoreTextToClipboardAfterPaste`) — ein vorheriger Nutzer-Clipboard-Inhalt (Bild, Datei, RTF) geht verloren.

---

## 3. Direkter Vergleich zu WhisperM8

### Was WhisperM8 besser macht

1. **Configuration-Change-Handling schlägt die Referenz-Library**: WhisperM8s `handleConfigurationChange()` (Engine stoppen, 300 ms HFP-Stabilisierung, Format-Retry ×5, Converter neu, Tap neu, Engine-Restart) ist ausgereifter als WhisperKits `AudioProcessor`, der Gerätewechsel gar nicht behandelt.
2. **0-Hz-Format-Guard existiert bereits**: `AudioFormatDecision.isRecordable()` mit Retry-Schleife vor jedem `installTap` (Erststart *und* Config-Change) adressiert genau die NSException-Falle — diese Schutzschicht hat keiner der AVAudioEngine-basierten Vergleichskandidaten so explizit.
3. **Kontext-Pipeline**: Screenshot-/Selektions-/Agent-Chat-Kontext plus Codex-Nachbearbeitung mit Output-Modes ist funktional weit vor allen Kandidaten (VoiceInks „Power Mode" und AI-Enhancement kommen am nächsten).
4. **Attachment-Paste**: Mehrteilige Payloads (Text + Bilder/Dateien sequenziell) kann keiner der Kandidaten.
5. **Fokus-Management beim Paste**: explizites Reaktivieren und Abwarten der Ziel-App (`waitForActivation`) ist sauberer als VoiceInk/Handy, die einfach in die gerade fokussierte App pasten.

### Was WhisperM8 schlechter macht

1. **Verbleib in der AVAudioEngine-Crash-Klasse**: Der Format-Guard mildert, beseitigt aber nicht die Race-Fläche: zwischen Format-Validierung und `installTap` kann das Gerät erneut kippen, und `engine.inputNode` selbst kann bei kaputtem Geräte-Zustand intern werfen. VoiceInk hat dieselbe Symptomatik (sporadische Crashes/Silent Failures) im Januar 2026 durch den AUHAL-Umstieg strukturell gelöst — OSStatus statt NSException.
2. **Config-Observer nur im System-Default-Modus**: `setupConfigurationObserver()` guarded auf `isUsingSystemDefault`. Wird ein **spezifisches** Gerät während der Aufnahme abgesteckt (BT-Headset aus), gibt es keinen Wechsel-Pfad — VoiceInk switcht hier mid-recording aufs nächstbeste Gerät weiter, ohne die Datei zu verlieren.
3. **Kein Geräte-Listen-Listener**: WhisperM8 reagiert nur auf `AVAudioEngineConfigurationChange` (feuert nur bei laufender Engine). Ein CoreAudio-Listener auf `kAudioHardwarePropertyDevices` wie bei VoiceInk erlaubt Vorbereitung/Fallback schon im Leerlauf.
4. **Fehlschlag endet stumm**: In `handleConfigurationChange()` führt ein endgültig ungültiges Format zu `isRecording = false` — Aufnahme endet ohne Nutzer-Feedback und ohne Fallback auf ein anderes Gerät. VoiceInk zeigt eine Notification und hat Recovery-Pfade.
5. **Clipboard-Restore verliert Nicht-Text-Inhalte**: nur der diktierte Text wird restauriert; VoiceInks Voll-Snapshot + Ownership-Check ist nutzerfreundlicher.
6. **Kein lokaler Modell-Pfad**: offline nicht nutzbar, jede Aufnahme verlässt den Rechner, Latenz hängt an der API. Alle vier Kandidaten können lokal.
7. **Kalte Engine bei jedem Start**: `startRecording()` baut die Engine jedes Mal neu (Budget `perf.recording` Engine-Start 250 ms). VoiceInks `prepare()`-Vorwärmung und Handys warmer Stream (AlwaysOn/Lazy-Close) starten schneller und verlagern Fehler weg vom Hotkey-Moment.
8. **Kein Push-to-talk / Modifier-only-Hotkey**: Carbon-Hotkeys können kein `flagsChanged`-basiertes Halten (VoiceInk-CGEventTap, Handy-HandyKeys können es).
9. **Kein Paste-Fallback**: Wenn der CGEvent in einer App nicht ankommt (Secure Input, manche Electron-/Java-Apps), gibt es keinen zweiten Mechanismus wie VoiceInks AppleScript-Pfad oder Handys Direct-Typing.

---

## 4. Übertragbare Muster für WhisperM8 (priorisiert)

### P1 — Crash-Beseitigung beim Transkriptionsstart (direkter Bezug zum akuten Problem)

1. **Kurzfristig: `installTap`-Umgebung härten.**
   - Format-Validierung und `installTap` atomarer machen: unmittelbar vor `installTap` erneut `isRecordable` prüfen (letzte Abfrage so spät wie möglich), und den gesamten Setup-Block auf eine serielle Setup-Queue legen (VoiceInks `audioSetupQueue`-Muster), damit Start, Config-Change und Stop nie verschränkt laufen. Ein `isReconfiguring`-Äquivalent existiert mit `isRestarting` schon — aber `startRecording()` und `handleConfigurationChange()` können heute noch parallel auf demselben Engine-Objekt arbeiten (Start ist `async`, Change läuft auf MainActor-Task).
   - **Geräte-Existenz vor Engine-Bau prüfen** (VoiceInk-Commit „Guard check to validate device exists before AudioUnit setup"): wenn `selectedDeviceID` nicht mehr in `availableDevices` ist, sofort auf Default zurückfallen statt die Engine gegen ein totes Gerät zu binden.
2. **Mittelfristig: AUHAL-Recorder nach VoiceInk-Vorbild evaluieren.** VoiceInks `CoreAudioRecorder.swift` (GPL-3.0 — **nicht kopieren**, nur als Architektur-Referenz) zeigt, dass ein direkter AUHAL-Pfad (a) alle Fehler als fangbare OSStatus liefert, (b) Gerätewechsel mid-recording ohne Dateiverlust kann und (c) das 0-Hz-Fenster gar nicht erst betritt, weil das Format explizit gesetzt statt vom `inputNode` geraten wird. Aufwand ~1 300 LOC; die bestehende `AudioFormatDecision`/Converter-Logik bliebe wiederverwendbar.
3. **Config-Change auch für spezifisch gewählte Geräte behandeln** (Guard `isUsingSystemDefault` in `setupConfigurationObserver()` entfernen) und bei endgültigem Scheitern: Fallback-Kette Gerät → System-Default → eingebautes Mikro, plus sichtbares Nutzer-Feedback statt stillem `isRecording = false`.

### P2 — Robustheit & Latenz des Aufnahme-Starts

4. **CoreAudio-Geräte-Listener im Leerlauf** (`AudioObjectAddPropertyListener` auf `kAudioHardwarePropertyDevices`, VoiceInk `AudioDeviceManager`): Geräteliste aktuell halten, gewähltes Gerät bei Verlust schon *vor* dem nächsten Hotkey auf Default zurücksetzen. Beseitigt die Klasse „Hotkey trifft auf verschwundenes Gerät".
5. **Engine/AudioUnit vorwärmen**: VoiceInks `prepare()` bzw. Handys OnDemand-Lazy-Close (Stream nach Stopp noch n Sekunden offen halten für schnelle Folgediktate). Zahlt direkt aufs `perf.recording`-Budget (Start 400 ms / Engine 250 ms) ein.
6. **Handys „native Rate, nie erzwingen" beibehalten** — WhisperM8 macht das schon richtig (Tap im Hardware-Format + Converter). Nicht auf die Idee kommen, das Tap-Format auf 16 kHz zu setzen; die Kommentarlage bei Handy bestätigt die Bluetooth-Codec-Problematik.

### P3 — Paste-Qualität

7. **Voll-Snapshot + Ownership-Check fürs Clipboard-Restore** (VoiceInk `CursorPaster`): alle PasteboardItems mit allen Typen sichern, eigenen Eintrag mit Session-Marker (`org.nspasteboard.TransientType`-Konvention) schreiben, vor Restore prüfen, ob das Clipboard noch der Paste-Session gehört. Behebt Punkt 3.5 ohne UX-Änderung.
8. **Paste-Fallback-Methode**: konfigurierbarer AppleScript-Pfad (VoiceInk) für Apps, in denen der CGEvent versackt; Handys Ctrl-Shift-V-Variante ist für Terminal-Ziele interessant, da WhisperM8-Nutzer viel in Terminals (Agent Chats!) arbeiten.

### P4 — Strategisch

9. **Lokaler Transkriptions-Pfad als dritter Provider**: WhisperKit (MIT, Swift-native, CoreML/ANE) wäre die idiomatische Wahl neben OpenAI/Groq in `TranscriptionProviders.swift`; Parakeet via FluidAudio (Hex/VoiceInk-Muster) die schnellste. Bringt Offline-Fähigkeit, Datenschutz-Argument und konstante Latenz; Modell-Download/Warmup-Verwaltung nach VoiceInks `WhisperModelWarmupCoordinator`-Vorbild.
10. **VAD vor dem Upload** (Handy: Silero via `vad-rs`): Stille trimmen senkt Upload-Größe/Latenz und Groq/OpenAI-Kosten — auch im reinen Cloud-Setup sinnvoll.
11. **Push-to-talk via CGEventTap als Option**: nur falls Nutzerbedarf; erfordert Input-Monitoring-Permission und die VoiceInk-Selbstheilung (`tapDisabledByTimeout` → re-enable). Als optionaler zweiter Hotkey-Backend nach Handys Dual-Backend-Muster (Fallback auf KeyboardShortcuts persistieren, wenn der Tap scheitert).

---

## Quellen

- VoiceInk: [Repo](https://github.com/Beingpax/VoiceInk), [Releases](https://github.com/Beingpax/VoiceInk/releases), Quelldateien `CoreAudioRecorder.swift`, `Recorder.swift`, `Services/AudioDeviceManager.swift`, `Paste/CursorPaster.swift`, `Paste/PasteMethod.swift`, `Shortcuts/ShortcutMonitor.swift`; Commit `c530367` (2026-01-10, „Replace audio recorder with CoreAudio AUHAL") + Folge-Commits vom 2026-01-11; [Docs: Common Issues](https://tryvoiceink.com/docs/common-issues)
- Handy: [Repo](https://github.com/cjpais/Handy), [Releases](https://github.com/cjpais/Handy/releases) (v0.9.0 Streaming, v0.9.3), Quelldateien `src-tauri/src/audio_toolkit/audio/recorder.rs`, `src-tauri/src/managers/audio.rs`, `src-tauri/src/shortcut/{mod,handler}.rs`, `src-tauri/src/input.rs`, `src-tauri/src/clipboard.rs`, `src-tauri/Cargo.toml`
- WhisperKit / Argmax: [Repo (heute argmax-oss-swift)](https://github.com/argmaxinc/WhisperKit), `Sources/WhisperKit/Core/Audio/AudioProcessor.swift`, [Blog](https://www.argmaxinc.com/blog/whisperkit), [CoreML-Modelle](https://huggingface.co/argmaxinc/whisperkit-coreml)
- whisper.cpp: [Repo](https://github.com/ggml-org/whisper.cpp)
- Hex: [Repo](https://github.com/kitlangton/Hex); Whispering/Epicenter: [Repo](https://github.com/EpicenterHQ/epicenter), [Website](https://epicenter.so/whispering/), [Show HN](https://news.ycombinator.com/item?id=44942731); Whispera: [Repo](https://github.com/sapoepsilon/Whispera); handy-cli (Vorläufer, tot): [Repo](https://github.com/cjpais/handy-cli)
- WhisperM8-Referenzen: `WhisperM8/Services/Dictation/AudioRecorder.swift`, `AudioFormatDecision.swift`, `PasteService.swift`, `docs/ARCHITECTURE.md`
