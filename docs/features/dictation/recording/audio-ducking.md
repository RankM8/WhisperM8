---
status: aktiv
updated: 2026-07-09
---

# Audio Ducking Feature

WhisperM8 reduziert während einer Aufnahme automatisch die Systemlautstärke und stellt sie nach dem Stop wieder her — auch bei AirPods und anderen Bluetooth-Devices, die ihr eigenes Profile-Switching machen.

## Verhalten im Überblick

| Phase | Was passiert mit der Volume |
|---|---|
| Vor `beginCapture()` | Original-Volume des aktuellen Default-Output-Devices wird gelesen. |
| Während Aufnahme | Volume des aktuell aktiven Devices ist auf den Zielwert (Default 20 %) reduziert; ein 0,2-s-Enforce-Loop duckt idempotent nach, falls Bluetooth-Profile ohne Routing-Event die Volume zurücksetzen. |
| Routing-Wechsel während Aufnahme | Neues Default-Device wird ebenfalls gecaptured und geduckt. Altes Device behält gemerkte Original-Volume. |
| `endCapture()` (Hotkey-Release) | Alle während der Session berührten Devices werden sofort auf ihre Originals zurückgesetzt. |
| Settle-Window (2 s) | Routing-Listener bleibt aktiv und ein periodischer Re-Restore setzt alle Captures wiederholt auf Original, um verzögerte BT-Reverse-Switches (HFP → A2DP) abzufangen. |
| Transkription / Post-Processing | Volume ist bereits zurück auf Original — nichts mehr geduckt. |
| App-Quit während Recording | `endCaptureImmediate()` setzt Volume sofort zurück (Sicherheitsnetz). |

## State-Machine

```
.idle ──beginCapture()──► .capturing ──endCapture()──► .restoring ──(2 s timeout)──► .idle
                              │     │                      │      │
                              │     └─0,2 s loop──────────►│      └─0,2 s loop──► re-restore alle Captures
                              │        re-duck current     │
                              └─routing event──────────────┘
                                 capture new device + duck / restore
```

## Designprinzipien

### 1. Pre-Switch-Capture
`AudioDuckingManager.beginCapture()` wird im `RecordingCoordinator` **vor** `audioRecorder.startRecording()` aufgerufen. Damit lesen wir die Original-Volume des Default-Output-Devices, **bevor** der `AVAudioEngine` den Bluetooth-A2DP→HFP-Profile-Switch anstößt — sonst würden wir die HFP-Volume als „Original" speichern.

### 2. Multi-Device-Capture
Jedes Device, das während der Session jemals Default-Output war, wird einzeln tracked. Bei AirPods erscheint das HFP-Profil auf vielen Macs als eigene `AudioDeviceID`. Der Routing-Listener fängt diesen Switch ab und captured/duckt das neue Device — beide werden am Ende auf ihre jeweils eigenen Originals restored.

### 3. Routing-Listener plus idempotenter Enforce-Loop
Wir lauschen auf `kAudioHardwarePropertyDefaultOutputDevice`, damit echte Default-Output-Wechsel sofort verarbeitet werden. Zusätzlich läuft während `.capturing` alle 0,2 Sekunden ein idempotentes Re-Duck des aktuellen Devices, weil Bluetooth-Profile auf demselben Device die Volume-Property ändern können, ohne ein Default-Output-Routing-Event auszulösen.

Der frühere Multi-Enforce-Pattern mit festen Einzel-Calls bei +0.3 / +0.6 / +1.0 / +1.5 s ist ersetzt durch diesen gleichmäßigen Loop und wird beim Wechsel aus `.capturing` beendet.

### 4. Settle-Window (2 s)
Nach `endCapture()` bleibt der Routing-Listener noch 2 Sekunden aktiv. Jeder Routing-Wechsel in diesem Fenster triggert ein erneutes Restore auf alle bekannten Captures; zusätzlich setzt der periodische Re-Restore alle 0,2 Sekunden idempotent auf Original, weil ein HFP→A2DP-Reverse-Switch auch ohne DeviceID-Wechsel die Volume ändern kann.

### 5. Keine User-Eingriff-Detection (bewusster Trade-off)
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
        ├── AudioDuckingManager.swift        # State-Machine, Capture-Logik, Enforce-Loop, Settle-Window
        ├── CoreAudioVolumeController.swift  # CoreAudio-Adapter für Volume und Default-Output-Listener
        └── RecordingCoordinator.swift       # Ruft beginCapture() vor Recorder-Start, endCapture() beim Stop
```

`AudioDuckingManager` ist `@MainActor`-isoliert. Die `AudioVolumeControlling`-Protocol-Abstraktion erlaubt deterministische Tests mit dem `AudioWorld`-Fake.

## Bekannte Einschränkungen

1. **Nur Systemlautstärke**: Per-App-Volume-Control gibt es auf macOS nicht als öffentliche API.
2. **HDMI / Aggregate Devices**: Devices ohne kontrollierbare Volume-Property werden nicht gecaptured und nicht angerührt — kein Crash, kein Restore-Versuch.
3. **Volume schon ≤ Target**: Ist die aktuelle Volume bereits leiser als der Zielwert, machen wir nichts — und merken uns auch nichts. Verhindert ein „Restore" auf einen falschen Wert.
4. **Settle-Window-Dauer**: 2 s Default. Bei sehr langsamen Bluetooth-Stacks könnte das knapp sein; `AudioDuckingManager.init(settleWindowDuration:enforceInterval:)` macht Dauer und Enforce-Intervall injizierbar.

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

`Tests/WhisperM8Tests/AudioDuckingManagerTests.swift` enthält Tests gegen einen `AudioWorld`-Fake, der die für Ducking relevanten macOS-Phänomene modelliert: Default-Output-Wechsel, BT-Profile-Switches, verschwundene Devices, doppelt feuernde Listener. Diese Tests sichern die State-Machine deterministisch ab; Real-Device-Aussagen zu AirPods/Bluetooth sind als empirisch validiertes Laufzeitverhalten zu verstehen, nicht als Garantie für jedes CoreAudio-Gerät.
