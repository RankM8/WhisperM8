# Recherche-Ergebnis: Globale Hotkeys unter macOS

# Globale Hotkeys unter macOS für Swift/SwiftUI-Apps

Für die WhisperM8-App ist **KeyboardShortcuts** von Sindre Sorhus die beste Wahl: Diese aktiv gewartete Library bietet native SwiftUI-Integration, App-Store-Kompatibilität und wird bereits von erfolgreichen Whisper-Clients wie local-whisper eingesetzt. Die Implementation benötigt nur wenige Zeilen Code und keine speziellen Berechtigungen für sandboxed Apps.

## Empfohlener Ansatz für WhisperM8

Die Recherche bestehender Whisper-Apps zeigt ein klares Bild: **KeyboardShortcuts** dominiert als Standard-Lösung. Apps wie local-whisper, Dato, Plash und Lungo setzen auf diese Library. Sie wrapped die Carbon-API `RegisterEventHotKey` und bietet gleichzeitig moderne Swift/SwiftUI-Integration mit automatischer UserDefaults-Speicherung.

**Implementierungsschritte:**
1. Library via Swift Package Manager einbinden
2. Shortcut-Namen als Extension definieren
3. SwiftUI-Recorder für die Einstellungen nutzen
4. KeyDown/KeyUp-Handler für Hold-to-Record registrieren

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
]
```

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}

// Settings-View
struct SettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Aufnahme-Shortcut:", name: .toggleRecording)
        }
    }
}

// Handler im App-State
@MainActor @Observable
final class AppState {
    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [self] in
            startRecording()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [self] in
            stopAndTranscribe()
        }
    }
}
```

## Die drei nativen Apple-APIs im Vergleich

macOS bietet drei Haupt-APIs für globale Hotkeys, jede mit spezifischen Eigenheiten bezüglich Permissions und Sandbox-Kompatibilität.

### NSEvent.addGlobalMonitorForEvents
Diese AppKit-API ist am einfachsten zu implementieren, empfängt aber nur **Kopien** der Events – konsumieren oder modifizieren ist nicht möglich. Der kritische Nachteil: Sie ist **nicht mit der App Sandbox kompatibel** und benötigt Accessibility-Permission.

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
    if event.keyCode == 49 && event.modifierFlags.contains([.option]) {
        self.toggleRecording()
    }
}
```

### CGEventTap (Core Graphics)
Apple's Developer Technical Support empfiehlt diese API explizit: *"Von den verbleibenden Optionen bevorzuge ich CGEventTap wegen der Interaktion mit TCC."* CGEventTap kann Events konsumieren und modifizieren, ist seit macOS 10.15 sandbox-kompatibel und benötigt nur Input Monitoring (nicht Accessibility).

```swift
CGPreflightListenEventAccess()  // Permission prüfen
CGRequestListenEventAccess()    // Permission anfordern
```

### Carbon RegisterEventHotKey
Trotz Deprecated-Status seit macOS 10.8 wird diese Legacy-API von allen populären Hotkey-Libraries intern verwendet. Der entscheidende Vorteil: **Keine spezielle Permission erforderlich** für sandboxed Apps. Das System filtert Events automatisch und ruft den Handler nur bei Übereinstimmung auf.

| Feature | NSEvent | CGEventTap | Carbon |
|---------|---------|------------|--------|
| Event konsumieren | ❌ | ✅ | ✅ |
| App Sandbox | ❌ | ✅ (10.15+) | ✅ |
| Permission nötig | Accessibility | Input Monitoring | ❌ Keine |
| Mac App Store | ❌ | ✅ | ✅ |

## Third-Party Libraries im Überblick

Die Landschaft der Hotkey-Libraries hat sich seit 2023 konsolidiert. **MASShortcut wurde archiviert** und sollte nicht mehr für neue Projekte verwendet werden.

### KeyboardShortcuts – der Standard für 2025+
Mit **2.500 GitHub-Stars** und aktivem Maintainer (letztes Update September 2025) ist diese Library der klare Favorit. Sie bietet native SwiftUI-Recorder-Komponenten, automatische Konflikt-Erkennung mit System-Shortcuts und funktioniert auch bei geöffnetem NSMenu – essentiell für Menu-Bar-Apps.

### HotKey – minimalistisch für feste Shortcuts
Sam Soffes' Library glänzt durch Einfachheit: Eine Zeile Code genügt für einen Hotkey. Ideal für Development-Tools mit fest programmierten Shortcuts, jedoch ohne UI-Komponente für User-Konfiguration.

```swift
let hotKey = HotKey(key: .space, modifiers: [.option])
hotKey.keyDownHandler = { print("Activated!") }
```

### ShortcutRecorder – maximale Anpassbarkeit
Mit **22 Lokalisierungen** und 19 Jahren Entwicklung bietet diese Objective-C-Library die meisten Features. Der Accessibility-basierte Monitor (`SRAXGlobalShortcutMonitor`) ermöglicht das Abfangen aller Keyboard-Events. Jedoch: Keine native SwiftUI-Komponente und letzter Release August 2022.

## Accessibility Permission und Input Monitoring

Das Permission-Handling unterscheidet sich fundamental je nach gewählter API. Für **RegisterEventHotKey** (und damit KeyboardShortcuts) ist **keine Permission erforderlich** – ein entscheidender Vorteil für die User Experience.

### Wann welche Permission benötigt wird
- **Keine Permission**: RegisterEventHotKey in sandboxed Apps
- **Input Monitoring**: CGEventTap via `CGRequestListenEventAccess()`
- **Accessibility**: NSEvent.addGlobalMonitorForEvents via `AXIsProcessTrusted()`

### Permission-Handling Code
```swift
import ApplicationServices

func checkAccessibilityPermission() -> Bool {
    return AXIsProcessTrusted()
}

func promptForAccessibilityPermission() {
    let options: NSDictionary = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ]
    _ = AXIsProcessTrustedWithOptions(options)
}

func openAccessibilitySettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
}
```

**Wichtig:** Nach Änderung der Accessibility-Permission muss die App **neu gestartet werden** – ein häufig übersehenes Detail, das zu Support-Anfragen führt.

## Kritischer macOS-Sequoia-Bug beachten

In **macOS 15 (Sequoia)** funktionieren Hotkeys mit **nur Option** oder **Option+Shift** als Modifier nicht mehr in sandboxed Apps (Bug FB15168205). Apple begründet dies als Sicherheitsmaßnahme gegen Keylogger, da diese Kombinationen Sonderzeichen in Passwörtern erzeugen können (z.B. ⌥⇧O = Ø).

**Workarounds:**
- Command-Key als zusätzlichen Modifier verwenden (empfohlen)
- App ohne Sandbox distribuieren (nicht für App Store)
- User den Shortcut selbst wählen lassen (beste UX)

## Best Practices aus bestehenden Whisper-Apps

Die Analyse von local-whisper, OpenSuperWhisper und super-voice-assistant zeigt bewährte UX-Patterns.

### Hold-to-Record als intuitivstes Pattern
- Taste **halten** = Aufnahme läuft
- Taste **loslassen** = Transkription startet
- Erfordert `onKeyDown` + `onKeyUp` Handler

### Kein Default-Shortcut setzen
Öffentliche Apps sollten **keinen Default-Shortcut** vorgeben. Stattdessen: Welcome-Screen zum Konfigurieren. Dies vermeidet Konflikte mit User-spezifischen System-Shortcuts und erhöht die Akzeptanz.

### Visuelles Feedback implementieren
- Menu-Bar-Icon ändert Farbe während Aufnahme
- Optional: Floating-Overlay im Spotlight-Stil
- Escape-Key zum Abbrechen immer unterstützen

## Vollständiges Implementierungsbeispiel

```swift
import SwiftUI
import KeyboardShortcuts
import AVFoundation

// MARK: - Shortcut Definition
extension KeyboardShortcuts.Name {
    static let startRecording = Self("startRecording")
}

// MARK: - App Entry Point
@main
struct WhisperM8App: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "mic.fill" : "mic")
        }
        
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    
    init() {
        setupHotkey()
        requestMicrophonePermission()
    }
    
    private func setupHotkey() {
        KeyboardShortcuts.onKeyDown(for: .startRecording) { [weak self] in
            self?.startRecording()
        }
        KeyboardShortcuts.onKeyUp(for: .startRecording) { [weak self] in
            self?.stopAndTranscribe()
        }
    }
    
    private func requestMicrophonePermission() {
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
        }
    }
    
    func startRecording() {
        isRecording = true
        // Audio-Recording starten
    }
    
    func stopAndTranscribe() {
        isRecording = false
        // Recording stoppen, Whisper-Transkription starten
    }
}

// MARK: - Settings View
struct SettingsView: View {
    var body: some View {
        Form {
            Section("Tastenkürzel") {
                KeyboardShortcuts.Recorder(
                    "Aufnahme starten/stoppen:",
                    name: .startRecording
                )
                Text("Halte die Taste zum Aufnehmen, lasse los zum Transkribieren")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
```

## Bekannte Fallstricke vermeiden

**Memory Leaks bei Event Monitors:** `NSEvent.removeMonitor()` immer aufrufen wenn der Monitor nicht mehr benötigt wird. Bei `deinit` des verwaltenden Objekts automatisch aufräumen.

**Thread-Safety:** KeyboardShortcuts-Handler werden auf dem Main Thread ausgeführt. Bei CGEventTap auf dem RunLoop-Thread – UI-Updates daher in `DispatchQueue.main.async` wrappen.

**Secure Keyboard Entry:** Während Passwort-Eingaben (z.B. in Keychain-Dialogen) werden globale Hotkeys teilweise blockiert. Carbon RegisterEventHotKey funktioniert hier noch am zuverlässigsten.

**App Sandbox Entitlements:** Für CGEventTap in sandboxed Apps keine zusätzlichen Entitlements nötig (seit macOS 10.15). Für Accessibility-basierte Ansätze: App erscheint nicht in System Settings wenn sandboxed.

## Fazit

Für WhisperM8 empfehle ich **KeyboardShortcuts** mit dem **Hold-to-Record-Pattern**. Diese Kombination bietet:
- Keine Permission-Anforderung für den Hotkey selbst
- Native SwiftUI-Integration für Einstellungen
- Mac App Store-Kompatibilität
- Bewährte Implementation aus produktiven Whisper-Apps
- Automatische Konflikt-Erkennung mit System-Shortcuts

Der einzige zu beachtende Punkt ist der macOS-Sequoia-Bug: Empfehlen Sie Usern, Shortcuts mit **Command-Key** zu konfigurieren statt nur Option-basierte Kombinationen.

---

## Zusammenfassung

<!-- Nach der Recherche ausfüllen -->

## Empfohlener Ansatz

<!-- Nach der Recherche ausfüllen -->

## Code-Beispiele

<!-- Nach der Recherche ausfüllen -->

## Fallstricke

<!-- Nach der Recherche ausfüllen -->

## Empfohlene Libraries

<!-- Nach der Recherche ausfüllen -->
