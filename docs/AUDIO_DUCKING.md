# Audio Ducking Feature

WhisperM8 kann automatisch die Systemlautstärke reduzieren während einer Aufnahme, sodass Hintergrundmusik, Videos und andere Audio-Quellen leiser werden. Nach der Aufnahme wird die ursprüngliche Lautstärke wiederhergestellt.

## Funktionsweise

### Grundprinzip

1. **Aufnahme startet** → Aktuelle Systemlautstärke wird gespeichert → Lautstärke wird auf Zielwert reduziert
2. **Während der Aufnahme** → Lautstärke bleibt auf dem niedrigen Zielwert
3. **Aufnahme endet** → Ursprüngliche Lautstärke wird wiederhergestellt

### Technische Details

Das Feature verwendet die [ISSoundAdditions](https://github.com/InerziaSoft/ISSoundAdditions) Library, die eine Swift-freundliche API für macOS CoreAudio Volume Control bietet.

**Wichtig:** Es wird die **gesamte Systemlautstärke** geändert, nicht nur einzelne Apps. Dies ist eine Einschränkung von macOS - es gibt keine öffentliche API um die Lautstärke einzelner Anwendungen zu steuern.

## Einstellungen

Die Audio-Ducking Einstellungen befinden sich unter **Settings → Behavior → Audio Ducking**.

### Optionen

| Einstellung | Beschreibung | Standard |
|-------------|--------------|----------|
| **Reduce system volume while recording** | Aktiviert/Deaktiviert das Feature | An |
| **Target volume** | Ziel-Lautstärke während der Aufnahme (5% - 30%) | 20% |

### Verhalten

- Wenn die aktuelle Systemlautstärke **über** dem Zielwert liegt: Lautstärke wird auf Zielwert reduziert
- Wenn die aktuelle Systemlautstärke **unter** dem Zielwert liegt: Keine Änderung (wird nicht lauter gemacht)

## AirPods / Bluetooth Unterstützung

Bei Verwendung von AirPods oder anderen Bluetooth-Kopfhörern wechselt macOS beim Aufnahmestart vom A2DP-Modus (Musik, hohe Qualität) in den HFP-Modus (Telefon, Mikrofon aktiv). Dieser Wechsel kann die Systemlautstärke kurzzeitig ändern.

### Problemlösung

WhisperM8 verwendet ein **Multi-Enforce Pattern** um mit diesem Verhalten umzugehen:

**Beim Aufnahmestart:**
- Lautstärke wird sofort auf Zielwert gesetzt
- Zusätzliche Korrekturen bei 0.3s, 0.6s, 1.0s und 1.5s nach Start
- Falls die AirPods-Umschaltung die Lautstärke erhöht, wird sie sofort wieder korrigiert

**Beim Aufnahmeende:**
- Ursprüngliche Lautstärke wird sofort wiederhergestellt
- Zusätzliche Korrekturen bei 0.3s, 0.6s, 1.0s und 1.5s nach Ende
- Falls der Wechsel zurück zu A2DP die Lautstärke ändert, wird sie korrigiert

## Architektur

### Komponenten

```
WhisperM8/
└── Services/
    └── AudioDuckingManager.swift    # Zentrale Ducking-Logik
```

### AudioDuckingManager

Singleton-Klasse die das Audio-Ducking verwaltet:

```swift
@MainActor
final class AudioDuckingManager {
    static let shared = AudioDuckingManager()

    // Einstellungen aus UserDefaults
    var isEnabled: Bool       // "audioDuckingEnabled"
    var targetVolume: Float   // "audioDuckingFactor"

    // Zustand
    private var originalVolume: Float?
    private var isDucked: Bool

    // Hauptmethoden
    func duck()      // Lautstärke reduzieren
    func restore()   // Lautstärke wiederherstellen
}
```

### Integration in AppState

Die Ducking-Aufrufe sind in `AppState.swift` integriert:

```swift
// In startRecording():
AudioDuckingManager.shared.duck()
// + Re-enforce Task für AirPods

// In stopRecording():
AudioDuckingManager.shared.restore()

// In cancelRecording():
AudioDuckingManager.shared.restore()
```

### UserDefaults Keys

| Key | Typ | Standard | Beschreibung |
|-----|-----|----------|--------------|
| `audioDuckingEnabled` | Bool | true | Feature aktiviert |
| `audioDuckingFactor` | Double | 0.2 | Ziel-Lautstärke (0.05 - 0.30) |

## Dependencies

Das Feature benötigt die **ISSoundAdditions** Library:

```swift
// Package.swift
.package(url: "https://github.com/InerziaSoft/ISSoundAdditions", from: "2.0.0")
```

## Debugging

Audio-Ducking Ereignisse werden im Debug-Log protokolliert:

```bash
# Live-Logs anzeigen
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug

# Oder Debug-Log auf Desktop
cat ~/Desktop/WhisperM8-debug.log | grep -i "ducking"
```

### Beispiel-Log

```
[AudioDucking] Ducked: 80% → 20%
[AudioDucking] Re-enforcing duck: 100% → 20%
[AudioDucking] restore() called - isDucked=true, originalVolume=Optional(0.8)
[AudioDucking] Restored to: 80% (actual: 80%)
[AudioDucking] Re-enforcing restore: 20% → 80%
```

## Bekannte Einschränkungen

1. **Nur Systemlautstärke**: Per-App Volume Control ist auf macOS nicht möglich
2. **Kurzer Audio-Spike bei AirPods**: Beim Start kann es einen kurzen (~300ms) lauten Moment geben bevor das Ducking greift
3. **App-Crash während Aufnahme**: Falls die App während einer Aufnahme abstürzt, bleibt die Lautstärke auf dem reduzierten Wert - manuelles Anpassen erforderlich
4. **Mehrere Audio-Outputs**: Das Feature arbeitet nur mit dem Standard-Output-Gerät
