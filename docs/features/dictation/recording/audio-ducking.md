# Audio Ducking Feature

WhisperM8 reduziert während einer Aufnahme automatisch die Systemlautstärke und stellt sie nach dem Stop wieder her — auch bei AirPods und anderen Bluetooth-Devices, die ihr eigenes Profile-Switching machen.

## Verhalten im Überblick

| Phase | Was passiert mit der Volume |
|---|---|
| Vor `beginCapture()` | Original-Volume des aktuellen Default-Output-Devices wird gelesen. |
| Während Aufnahme | Volume des aktuell aktiven Devices ist auf den Zielwert (Default 20 %) reduziert. |
| Routing-Wechsel während Aufnahme | Neues Default-Device wird ebenfalls gecaptured und geduckt. Altes Device behält gemerkte Original-Volume. |
| `endCapture()` (Hotkey-Release) | Alle während der Session berührten Devices werden sofort auf ihre Originals zurückgesetzt. |
| Settle-Window (2 s) | Routing-Listener bleibt aktiv. Bei verzögertem BT-Reverse-Switch (HFP → A2DP) werden alle Devices nochmal restored. |
| Transkription / Post-Processing | Volume ist bereits zurück auf Original — nichts mehr geduckt. |
| App-Quit während Recording | `endCaptureImmediate()` setzt Volume sofort zurück (Sicherheitsnetz). |

## State-Machine

```
.idle ──beginCapture()──► .capturing ──endCapture()──► .restoring ──(2 s timeout)──► .idle
                              │                            │
                              └─routing event─┐            └─routing event─► re-restore alle Captures
                                              ▼
                              capture new device + duck
```

## Designprinzipien

### 1. Pre-Switch-Capture
`AudioDuckingManager.beginCapture()` wird im `RecordingCoordinator` **vor** `audioRecorder.startRecording()` aufgerufen. Damit lesen wir die Original-Volume des Default-Output-Devices, **bevor** der `AVAudioEngine` den Bluetooth-A2DP→HFP-Profile-Switch anstößt — sonst würden wir die HFP-Volume als „Original" speichern.

### 2. Multi-Device-Capture
Jedes Device, das während der Session jemals Default-Output war, wird einzeln tracked. Bei AirPods erscheint das HFP-Profil auf vielen Macs als eigene `AudioDeviceID`. Der Routing-Listener fängt diesen Switch ab und captured/duckt das neue Device — beide werden am Ende auf ihre jeweils eigenen Originals restored.

### 3. Routing-Listener statt Time-Reinforce
Wir lauschen auf `kAudioHardwarePropertyDefaultOutputDevice`. Der frühere Multi-Enforce-Pattern (`duck()`-Calls bei +0.3 / +0.6 / +1.0 / +1.5 s) ist komplett entfernt — er ist im neuen Modell überflüssig und war Quelle von Race-Conditions.

### 4. Settle-Window (2 s)
Nach `endCapture()` bleibt der Routing-Listener noch 2 Sekunden aktiv. Jeder Routing-Wechsel in diesem Fenster triggert ein erneutes Restore auf alle bekannten Captures. Damit fangen wir verzögerte HFP→A2DP-Reverse-Switches ab, ohne in einen Retry-Loop zu verfallen.

### 5. Keine User-Eingriff-Detection (bewusster Trade-off)
Wenn der User mitten in der Aufnahme manuell die Volume ändert, wird sie am Ende trotzdem auf Original zurückgesetzt.

**Begründung:** Auf macOS gibt es kein zuverlässiges Signal „User vs System hat Volume geändert". Ein Bluetooth-Profile-Switch erzeugt einen identischen Event wie ein User-Slider-Klick. Das alte Design hat versucht das zu unterscheiden und in der Praxis dauerhaft geduckte AirPods produziert (BT-Routing-Drift wurde als User-Eingriff missinterpretiert → kein Restore → Volume blieb leise bis manueller System-Settings-Eingriff).

**Trade-off:** Wer mitten in der Aufnahme manuell lauter dreht, muss nach dem Stop nochmal nachdrehen. Selten, einklickbar, deutlich weniger schmerzhaft als der vorige Failure-Mode.

## Einstellungen

| UserDefault-Key | Typ | Standard | Bedeutung |
|---|---|---|---|
| `audioDuckingEnabled` | Bool | true | Feature aktiviert |
| `audioDuckingFactor` | Double | 0.2 | Ziel-Lautstärke (0.05 - 0.30) |

UI: **Settings → Behavior → Audio Ducking**.

## Architektur

```
WhisperM8/
└── Services/
    ├── AudioDuckingManager.swift     # State-Machine, Capture-Logik, Settle-Window
    └── RecordingCoordinator.swift    # Ruft beginCapture() vor Recorder-Start, endCapture() beim Stop
```

`AudioDuckingManager` ist `@MainActor`-isoliert. Die `AudioVolumeControlling`-Protocol-Abstraktion erlaubt deterministische Tests mit dem `AudioWorld`-Fake.

## Bekannte Einschränkungen

1. **Nur Systemlautstärke**: Per-App-Volume-Control gibt es auf macOS nicht als öffentliche API.
2. **HDMI / Aggregate Devices**: Devices ohne kontrollierbare Volume-Property werden nicht gecaptured und nicht angerührt — kein Crash, kein Restore-Versuch.
3. **Volume schon ≤ Target**: Ist die aktuelle Volume bereits leiser als der Zielwert, machen wir nichts — und merken uns auch nichts. Verhindert ein „Restore" auf einen falschen Wert.
4. **Settle-Window-Dauer**: 2 s fest verdrahtet. Bei sehr langsamen Bluetooth-Stacks könnte das knapp sein; bei Bedarf in `AudioDuckingManager.init(settleWindowDuration:)` injizierbar.

## Debugging

```bash
# Live-Logs
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug | grep -i "AudioDucking"
```

Beispiel-Log einer normalen Session mit AirPods:

```
[AudioDucking] Captured+ducked AirPods (A2DP): 80% → 20%
[AudioDucking] Captured+ducked AirPods (HFP): 50% → 20%     ← HFP-Profil als eigenes Device
[AudioDucking] Restored AirPods (A2DP) to 80%
[AudioDucking] Restored AirPods (HFP) to 50%
[AudioDucking] Restored AirPods (A2DP) to 80%                ← settle-window re-restore beim Reverse-Switch
```

## Tests

`Tests/WhisperM8Tests/AudioDuckingManagerTests.swift` enthält 18 Tests gegen einen `AudioWorld`-Fake, der die für Ducking relevanten macOS-Phänomene modelliert: Default-Output-Wechsel, BT-Profile-Switches, verschwundene Devices, doppelt feuernde Listener. Diese Tests sichern die State-Machine deterministisch ab — manuelle Real-Device-Validierung ergänzt sie.
