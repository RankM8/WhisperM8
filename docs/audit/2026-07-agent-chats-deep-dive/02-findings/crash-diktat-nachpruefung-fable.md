# Nachprüfung Crash-Diktat (C01/C02) — Verifikations-Durchgang (Prüfer: Fable)

**Auftrag:** Die Kern-These beider Crash-Audits (`crash-diktat-codex.md` F1, `crash-diktat-fable.md` F1) gegen den echten Code prüfen: (a) existiert das TOCTOU-Fenster zwischen Format-Validierung und `engine.start()`, (b) deckt `90c4fab` wirklich nur 0-Hz-Formate ab, (c) ist der vorgeschlagene ObjC-Exception-Trampolin technisch korrekt und regressionsarm?
**Methode:** Zeilengenauer Abgleich mit `WhisperM8/Services/Dictation/AudioRecorder.swift` (Stand main, a26d29f), `AudioFormatDecision.swift`, `RecordingCoordinator.swift`, `Package.swift` sowie dem vollständigen Diff von Commit `90c4fab`. Kein Code geändert.

---

## (a) TOCTOU-Fenster: BESTÄTIGT

Der behauptete Ablauf steht exakt so im Code:

1. **Format-Query mit Validierung** — `AudioRecorder.swift:107-120`: Retry-Schleife, bricht beim **ersten** validen Format ab (`break`) und friert genau dieses `AVAudioFormat`-Objekt ein. Danach wird es nie wieder gegen den Node verglichen.
2. **Zwischenschritte** — `:123-150`: Converter-Erzeugung, Temp-URL, `AVAudioFile(forWriting:)` (Disk-I/O) — alles echte Wanduhrzeit zwischen Query und Tap.
3. **Tap-Install mit dem eingefrorenen Format** — `:155` → `installRecordingTap(…, inputFormat: inputFormat, …)`, darin `installTap(onBus:0, bufferSize:4096, format: inputFormat)` (`:372`).
4. **`engine.start()`** — `:159` in `do/catch`. Das `catch` fängt ausschließlich Swift-`Error`s; die AVFoundation-Format-Assertion (`NSInvalidArgumentException`, „required condition is false: format.sampleRate == hwFormat.sampleRate", AVAudioIONodeImpl) ist eine ObjC-NSException → SIGABRT der gesamten App. Das Projekt dokumentiert diese Exception-Klasse selbst als unfangbar (`AudioFormatDecision.swift:17-21`, zwei reale Crashes 2026-07-01 + 2026-07-08).

**Struktureller Trigger bestätigt:** Der Kommentar in `RecordingCoordinator.swift` (Pre-Switch-Capture, „Volume MUSS gelesen werden BEVOR der AVAudioEngine startet, sonst hat macOS bei Bluetooth-Devices bereits den A2DP→HFP-Profile-Switch angestossen") belegt, dass der Aufnahmestart den Profilwechsel **selbst auslöst**. Ablauf beim BT-Headset: `engine.inputNode` (`:88`) bindet das Gerät und stößt den HFP-Switch an → die Format-Query wenige Zeilen später kann noch das alte A2DP-Format (z. B. 48 kHz) liefern → beim `engine.start()` ist die Hardware schon auf HFP (16/24 kHz) → Format-Mismatch-Exception. Das TOCTOU-Fenster ist also nicht nur theoretisch, sondern wird vom eigenen Startpfad systematisch provoziert.

**Zweites, größeres Fenster ebenfalls bestätigt:** `handleConfigurationChange()` (`:252-350`) hat zwischen Format-Query (`:278-288`, inkl. 300 ms Sleep `:271` + bis zu 5×100 ms Retries) und Tap-Install/Restart (`:329`, `:335`) dieselbe Lücke — und wird genau in BT-Reconnect-Situationen betreten, in denen ein zweiter Profilswitch wahrscheinlich ist.

Alle in den beiden Findings zitierten Zeilennummern stimmen mit dem aktuellen Stand überein; keine der Beweis-Zitate ist veraltet oder verfälscht.

## (b) `90c4fab` deckt nur 0-Hz/0-Kanal ab: BESTÄTIGT

Der vollständige Commit-Diff zeigt: `90c4fab` fügt ausschließlich `AudioFormatDecision.isRecordable` (`sampleRate > 0 && channelCount > 0`), die Retry-Schleife in `startRecording()` und das defensive `removeTap` vor `installTap` hinzu. Geprüft wird nur „überhaupt aufnahmefähig", nie „noch aktuell". Der Fall *valides, aber inzwischen verändertes* Format bleibt vollständig offen — sowohl im Startpfad als auch im Config-Change-Pfad. Die Formulierung beider Audits ist korrekt.

Randnotiz: Die Retry-Schleife enthält im Fehlerfall sogar `Task.sleep`-Suspension-Points (`:115`), die das Fenster zusätzlich verlängern können, sollte der erste Versuch invalid und ein späterer valide-aber-flüchtig sein.

## (c) Bewertung des ObjC-Exception-Trampolins

### Technisch korrekt: JA

- Swift kann NSExceptions prinzipiell nicht fangen; ein ObjC-`@try/@catch`-Wrapper (`WM8CatchException(NS_NOESCAPE void(^)(void))`, gebridged als `throws`) ist der etablierte und einzige saubere Mechanismus (identisches Muster wie das verbreitete `sindresorhus/ExceptionCatcher`-Paket — das wäre alternativ eine fertige Dependency).
- **SwiftPM-Machbarkeit bestätigt:** `Package.swift` ist ein reines SwiftPM-Setup; ein zusätzliches ObjC-Target (SwiftPM erlaubt keine gemischten Swift/ObjC-Targets, wohl aber ein separates C/ObjC-Target als Dependency des Executable-Targets) ist unterstützt und build-neutral. Kein Makefile-/Bundle-Ressourcen-Problem (die „zwei Orte"-Falle betrifft nur Ressourcen, nicht Link-Targets).
- Happy-Path-Kosten: null — ObjC-Exceptions sind auf arm64/x86_64 zero-cost, solange nicht geworfen wird.

### Regressionsarm: JA, mit vier Auflagen

1. **Cleanup nach Catch:** Nach gefangener Exception ist der Engine-/AudioUnit-Zustand undefiniert. Der Catch-Pfad muss die komplette Session verwerfen (removeTap, `engine.stop()`, Engine-Objekt fallen lassen, Slots nullen) — der bestehende `catch`-Block um `engine.start()` (`:161-169`) macht das bereits und muss nur auf den Trampolin-Fehler ausgeweitet werden. Nie mit derselben Engine weitermachen.
2. **ARC + Unwinding:** Code im Block minimal halten (nur der `installTap`-/`start`-Aufruf). Beim Unwinden durch Swift-Frames laufen keine Cleanups — im seltenen Fehlerpfad sind kleine Leaks akzeptabel, aber es darf kein zustandsbehafteter Swift-Code zwischen Wurf und Catch liegen. Shim ggf. mit `-fobjc-arc-exceptions` kompilieren oder ohne ARC schreiben.
3. **Nicht stumm schlucken:** Exception-Name/-Reason loggen und als spezifischen `RecordingError` weiterreichen, sonst maskiert der Trampolin echte Programmierfehler (z. B. „tap already installed").
4. **Auch den Config-Change-Pfad wrappen** (`:329`, `:333-336`), nicht nur den Erststart — dort ist das Fenster am größten.

### Einschränkungen der Schutzwirkung (wichtig für die Erwartungshaltung)

- **Der Trampolin fängt nur Exceptions auf dem Aufrufer-Thread** (synchron in `installTap`/`engine.start()`). Die in `crash-diktat-fable.md` F2 beschriebenen Exception-Ausgänge (`AVAudioConverter.convert` / `AVAudioFile.write` bei Format-Mismatch) fliegen **im Tap-Callback auf dem Audio-Thread** — ein Trampolin um `engine.start()` hilft dort nicht. Die Aussage in der „Empfohlenen Sofortmaßnahme" (F1+F2 „in einem Schritt" entschärft) ist insoweit **zu optimistisch**: F2s Exception-Pfad wird nur abgedeckt, wenn zusätzlich der Body von `writeBuffer`/`writeBufferLocked` (`:419-483`) durch den Trampolin läuft. Das ist machbar und billig (zero-cost bis zum Wurf) und sollte Teil des Fixes sein. Die eigentliche Ursache von F2 (fehlende Re-Validierung nach `await`s, Session-Generation) bleibt davon unabhängig fixwürdig.
- **AVFoundation-interne Threads:** Format-Assertions können in seltenen Fällen auch auf AVFoundation-eigenen Threads (Media-Services-Reconfig) geworfen werden — dorthin reicht kein Trampolin. Der Fix reduziert die Abort-Wahrscheinlichkeit massiv, garantiert aber keine 100 %-Abdeckung dieser Exception-Klasse.
- **Fix-Teil 1 (Re-Check vor Start) allein reicht nicht:** Zwischen erneutem Check und `start()` bleibt immer Restzeit. Der Re-Check senkt die Trefferwahrscheinlichkeit, der Trampolin ist das tragende Sicherheitsnetz. Beide Teile zusammen sind die richtige Kombination — so steht es auch (korrekt) im Fable-Finding.

### Nebenbefund (bestätigt, nicht Teil des Auftrags)

F3 beider Audits (Recorder nonisolated-async → `startRecording()` läuft off-MainActor, liest `AudioDeviceManager.availableDevices`, das auf Main ersetzt wird) ist im Code nachvollziehbar (`AudioRecorder.swift:5-6`, `:82`, `:94`; `AudioDeviceManager` Main-Writes). Der Trampolin adressiert diese Race-Klasse nicht; eine `@MainActor`-Isolation des Recorders wäre der passende, separate Fix und würde zugleich F2s Interleaving deterministischer machen.

---

## Fazit

| Frage | Ergebnis |
|---|---|
| TOCTOU-Fenster Format-Query → `installTap`/`engine.start()` existiert? | **Ja, bestätigt** (zwei Fenster: Startpfad + Config-Change; vom eigenen BT-Startablauf strukturell provoziert) |
| `90c4fab` deckt nur 0-Hz/0-Kanal-Formate ab? | **Ja, bestätigt** (Diff geprüft; keinerlei Staleness-Prüfung) |
| ObjC-Trampolin technisch korrekt? | **Ja** (Standard-Muster, SwiftPM-tauglich als separates ObjC-Target oder via ExceptionCatcher-Dependency) |
| Regressionsarm? | **Ja** — zero-cost im Happy Path, additiv; Auflagen: vollständiges Cleanup nach Catch, minimaler Block-Inhalt, Logging statt Stummschlucken, beide Pfade wrappen |
| Deckt der Trampolin auch F2 ab? | **Nur teilweise** — die Audio-Thread-Exceptions in `writeBuffer` erfordern zusätzliches Wrapping dort; die Root-Cause (fehlende Re-Validierung nach `await`, Session-Generation) braucht ohnehin den eigenen Fix |

**Gesamturteil: Crash-Diagnose hält — JA. Fix-Idee hält — JA, mit Einschränkung** (Trampolin zusätzlich um den Tap-Write-Pfad legen, F2-Generation-Fix nicht durch den Trampolin ersetzt sehen, und keine 100 %-Garantie gegen AVFoundation-interne Thread-Exceptions versprechen).
