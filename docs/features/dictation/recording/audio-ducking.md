---
status: aktiv
updated: 2026-10-25
---

# Audio Ducking Feature

WhisperM8 reduziert während einer Aufnahme automatisch die Systemlautstärke und stellt sie nach dem Stop wieder her — auch bei AirPods und anderen Bluetooth-Devices, die ihr eigenes Profile-Switching machen.

## Verhalten im Überblick

| Phase | Was passiert mit der Volume |
|---|---|
| Vor `beginCapture()` | Original-Volume des aktuellen Default-Output-Devices wird gelesen. |
| Start mit Bluetooth-Mikrofon | Das Ducken wartet, bis der Ausgang im Headset-Profil ist (Abtastrate < 32 kHz); `recorderDidStart()` und der Enforce-Loop ziehen es nach, spätestens nach 3 s. Das Musik-Profil wird nie geduckt. |
| Während Aufnahme | Volume des aktuell aktiven Devices ist auf den Zielwert (Default 20 %) reduziert; ein 0,2-s-Enforce-Loop duckt idempotent nach, falls Bluetooth-Profile ohne Routing-Event die Volume zurücksetzen. |
| Routing-Wechsel während Aufnahme | Neues Default-Device wird ebenfalls gecaptured und geduckt. Altes Device behält gemerkte Original-Volume. |
| `endCapture()` (Stop, Abbruch, Startfehler) | Alle geduckten Devices werden sofort auf ihre Originals zurückgesetzt. |
| Settle-Window (8 s) | Steht ein Device wieder auf **unserem** Duck-Wert (± 5 %), wird erneut zurückgestellt — das ist das Profil-Gedächtnis des Bluetooth-Stacks. Einen Wert, den der Nutzer selbst gedreht hat, lässt das Fenster stehen. |
| Zweites Diktat im Settle-Window | Die gemerkten Originale werden mitgenommen statt neu gelesen. |
| Transkription / Post-Processing | Volume ist bereits zurück auf Original — nichts mehr geduckt. |
| App-Quit während Recording | `endCaptureImmediate()` setzt Volume sofort zurück (Sicherheitsnetz). |
| Absturz, `make kill`, Gerät weg | Das `AudioDuckingJournal` hält die offene Rückstellung; nachgeholt beim App-Start und beim Wiederverbinden des Geräts. |

## State-Machine

```
.idle ──beginCapture()──► .capturing ──endCapture()──► .restoring ──(8 s)──► .idle
  ▲                           │     │                      │      │
  │                           │     └─0,2 s loop           │      └─0,2 s loop: Device auf
  │                           │       re-duck current,     │        Duck-Wert → restore
  │                           │       BT: duck sobald HFP  │
  │                           └─routing event──────────────┘
  │                              capture new device + duck / restore
  └── beginCapture() im Settle-Window: Captures mitnehmen ──┘
```

## Designprinzipien

### 1. Pre-Switch-Capture
`AudioDuckingManager.beginCapture()` wird im `RecordingCoordinator` **vor** `audioRecorder.startRecording()` aufgerufen. Damit lesen wir die Original-Volume des Default-Output-Devices, **bevor** der `AVAudioEngine` den Bluetooth-A2DP→HFP-Profile-Switch anstößt — sonst würden wir die HFP-Volume als „Original" speichern.

### 2. Bluetooth erst im Headset-Profil ducken
AirPods merken sich für das Musik-Profil (A2DP) und das Headset-Profil (HFP) je eine eigene Lautstärke. Was im Musik-Profil gesetzt wird, kommt beim Rückwechsel nach der Aufnahme wieder — auch wenn längst zurückgestellt wurde, denn das Zurückstellen trifft das Headset-Profil. Nimmt die Aufnahme über ein Bluetooth-Mikrofon auf (`recordingInputDeviceID`), wird der Original-Wert vorher gelesen, geduckt wird aber erst im Headset-Profil. Erkennung über die Abtastrate des Ausgangs: an AirPods Pro gemessen 48 kHz → 24 kHz beim Mikrofon-Start. Kommt der Wechsel nicht, duckt der Manager nach 3 s trotzdem. Bei Bluetooth-Ausgang mit eingebautem Mikrofon wird sofort geduckt.

**Vorfall 25.10.2026:** coreaudiod hielt das Headset-Profil nach dem Stop 2,0 s offen („Delayed Transport Disconnect"), der Rückwechsel kam 2,1 s nach dem Stop mit 10 % im Musik-Profil. Das alte 2-s-Settle-Window war 0,1 s vorher zu. Beim Abbrechen per X trat das fast immer auf, weil `endCapture()` dort im selben Moment wie der Engine-Stop läuft; beim normalen Stop lag oft der Kontext-Capture (bis 1 s) dazwischen.

### 3. Multi-Device-Capture
Jedes Device, das während der Session jemals Default-Output war, wird einzeln tracked. Bei AirPods erscheint das HFP-Profil auf vielen Macs als eigene `AudioDeviceID`. Der Routing-Listener fängt diesen Switch ab und captured/duckt das neue Device — beide werden am Ende auf ihre jeweils eigenen Originals restored.

### 4. Routing-Listener plus idempotenter Enforce-Loop
Wir lauschen auf `kAudioHardwarePropertyDefaultOutputDevice`, damit echte Default-Output-Wechsel sofort verarbeitet werden. Zusätzlich läuft während `.capturing` alle 0,2 Sekunden ein idempotentes Re-Duck des aktuellen Devices, weil Bluetooth-Profile auf demselben Device die Volume-Property ändern können, ohne ein Default-Output-Routing-Event auszulösen.

Der frühere Multi-Enforce-Pattern mit festen Einzel-Calls bei +0.3 / +0.6 / +1.0 / +1.5 s ist ersetzt durch diesen gleichmäßigen Loop und wird beim Wechsel aus `.capturing` beendet.

### 5. Settle-Window (8 s) mit Duck-Wert-Erkennung
Nach `endCapture()` wird alles sofort zurückgestellt; danach prüft der Manager 8 Sekunden lang alle 0,2 Sekunden und bei jedem Routing-Wechsel, ob ein Device wieder auf dem eigenen Duck-Wert steht (± 5 %, weil das Headset-Profil auf 1/16-Stufen rundet). Nur dann wird erneut zurückgestellt. Damit kann das Fenster großzügig sein, ohne gegen den Nutzer zu arbeiten: Wer nach dem Stop selbst dreht, behält seinen Wert.

Startet währenddessen das nächste Diktat, nimmt `beginCapture()` die gemerkten Originale mit. Steht ein Device gerade auf dem Duck-Wert, bleibt das alte Original; sonst gilt der aktuelle Wert, weil der Nutzer zwischen den Diktaten gedreht hat.

Auch Abbruch während „Mikrofon verbindet …" und ein fehlgeschlagener Start laufen über `endCapture()`. `endCaptureImmediate()` ohne Fenster bleibt dem App-Quit vorbehalten.

### 6. Journal für Absturz und getrennte Geräte
Jede geduckte Lautstärke steht bis zur bestätigten Rückstellung im `AudioDuckingJournal` (UserDefaults `audioDuckingPendingRestores`, Schlüssel ist die Geräte-UID, weil sich die `AudioDeviceID` beim Wiederverbinden ändert). Am Session-Ende werden bestätigte Einträge gelöscht; ein unerreichbares oder noch geduckt stehendes Gerät bleibt eingetragen.

`recoverPendingRestores()` läuft beim App-Start und, solange etwas offen ist, bei jedem Default-Output-Wechsel (wiederverbundene AirPods werden Default). Nachgeholt wird nur, wenn das Gerät noch auf dem Duck-Wert steht; sonst hat der Nutzer schon gedreht und der Eintrag verfällt. Einträge älter als sieben Tage werden verworfen. Beginnt ein Diktat, während ein Gerät noch auf einem Duck-Wert aus dem Journal steht, gilt das gemerkte Original.

### 7. Keine User-Eingriff-Detection während der Aufnahme (bewusster Trade-off)
Wenn der User mitten in der Aufnahme manuell die Volume ändert, wird sie am Ende trotzdem auf Original zurückgesetzt.

**Begründung:** Auf macOS gibt es kein zuverlässiges Signal „User vs System hat Volume geändert". Ein Bluetooth-Profile-Switch erzeugt einen identischen Event wie ein User-Slider-Klick. Das alte Design hat versucht das zu unterscheiden und in der Praxis dauerhaft geduckte AirPods produziert (BT-Routing-Drift wurde als User-Eingriff missinterpretiert → kein Restore → Volume blieb leise bis manueller System-Settings-Eingriff).

**Trade-off:** Wer mitten in der Aufnahme manuell lauter dreht, muss nach dem Stop nochmal nachdrehen. Selten, einklickbar, deutlich weniger schmerzhaft als der vorige Failure-Mode.

## Einstellungen

| UserDefault-Key | Typ | Standard | Bedeutung |
|---|---|---|---|
| `audioDuckingEnabled` | Bool | true | Feature aktiviert |
| `audioDuckingFactor` | Double | 0.2 | Ziel-Lautstärke (0.05 - 0.30) |

UI: **Settings → Recording → Audio Ducking**.

## Architektur

```
WhisperM8/
└── Services/
    └── Dictation/
        ├── AudioDuckingManager.swift        # State-Machine, Capture-Logik, Enforce-Loop, Settle-Window, Nachholen
        ├── AudioDuckingJournal.swift        # Offene Rückstellungen auf Disk (Absturz, getrenntes Gerät)
        ├── CoreAudioVolumeController.swift  # CoreAudio-Adapter: Volume, UID, Bluetooth/Headset-Profil, Default-Output-Listener
        └── RecordingCoordinator.swift       # beginCapture() vor Recorder-Start, recorderDidStart(), endCapture() bei Stop/Abbruch/Fehler
```

`AudioDuckingManager` ist `@MainActor`-isoliert. Die `AudioVolumeControlling`-Protocol-Abstraktion erlaubt deterministische Tests mit dem `AudioWorld`-Fake.

## Bekannte Einschränkungen

1. **Nur Systemlautstärke**: Per-App-Volume-Control gibt es auf macOS nicht als öffentliche API.
2. **HDMI / Aggregate Devices**: Devices ohne kontrollierbare Volume-Property werden nicht gecaptured und nicht angerührt — kein Crash, kein Restore-Versuch.
3. **Volume schon ≤ Target**: Ist die aktuelle Volume bereits leiser als der Zielwert, machen wir nichts — und merken uns auch nichts. Verhindert ein „Restore" auf einen falschen Wert.
4. **Settle-Window-Dauer**: 8 s Default, macOS braucht nach dem Stop rund 2 s. Kommt ein Rückwechsel noch später, fängt ihn das Journal beim nächsten Diktat oder Start auf.
5. **Absturz im Headset-Profil**: Stirbt die App mit geducktem Headset-Profil, sieht das Journal beim Start nur das Musik-Profil (unverändert) und verwirft den Eintrag. Das Headset-Profil korrigiert sich beim nächsten Diktat, weil das Zurückstellen dort den vorher gelesenen Musik-Wert schreibt.

## Debugging

```bash
# Live-Logs
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug | grep -i "AudioDucking"
```

Beispiel-Log einer normalen Session mit AirPods:

```
[AudioDucking] Captured AirPods Pro at 75%; duck waits for headset profile
[AudioDucking] Captured+ducked AirPods Pro (headset profile): 63% → 10% original=75%
[AudioDucking] endCapture entered: phase=capturing capturedDevices=1
[AudioDucking] Restored AirPods Pro: 10% → 75%               ← Headset-Profil zurück
                                                             ← Musik-Profil kommt unberührt mit 75 % zurück
```

## Tests

`Tests/WhisperM8Tests/AudioDuckingManagerTests.swift` enthält Tests gegen einen `AudioWorld`-Fake, der die für Ducking relevanten macOS-Phänomene modelliert: Default-Output-Wechsel, BT-Profile-Switches, eine eigene Lautstärke pro Bluetooth-Profil, verschwundene und wiederverbundene Devices, doppelt feuernde Listener. Dazu Regressionstests für den spät zurückgespielten Duck-Wert, das zweite Diktat im Settle-Window, Absturz und getrenntes Gerät. Diese Tests sichern die State-Machine deterministisch ab; Real-Device-Aussagen zu AirPods/Bluetooth sind als empirisch validiertes Laufzeitverhalten zu verstehen, nicht als Garantie für jedes CoreAudio-Gerät.
