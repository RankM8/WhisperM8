# Recherche-Ergebnis: macOS Menübar-App Entwicklung

# macOS Menübar-Apps mit SwiftUI entwickeln

Mit macOS 13 Ventura hat Apple `MenuBarExtra` eingeführt – eine native SwiftUI-Scene, die das komplexe AppKit-Boilerplate mit `NSStatusItem` überflüssig macht. Diese umfassende Anleitung zeigt den vollständigen Weg von der ersten Zeile Code bis zur produktionsreifen Menüleisten-App. Die wichtigsten Entscheidungen: **Menu-Style** für schnelle Aktionen, **Window-Style** für komplexe UIs, und `LSUIElement = true` für reine Menübar-Apps ohne Dock-Icon.

---

## MenuBarExtra ist der neue Standard ab macOS 13

`MenuBarExtra` ist eine SwiftUI-Scene, die sich als persistentes Icon in der Systemmenüleiste rendert. Der grundlegende Aufbau ist elegant einfach:

```swift
import SwiftUI

@main
struct MyMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("Meine App", systemImage: "star.fill") {
            ContentView()
        }
    }
}
```

Die wichtigsten Parameter des Initializers:
- **TitleKey** (String): Identifiziert das Item; wird als Text angezeigt falls kein Bild vorhanden
- **systemImage** (String): SF Symbol-Name für das Menüleisten-Icon
- **isInserted** (Binding<Bool>): Steuert die Sichtbarkeit des Menübar-Items dynamisch
- **label** (ViewBuilder): Ermöglicht komplexe Icon-Konfigurationen

### Menu-Style versus Window-Style

SwiftUI bietet zwei fundamental unterschiedliche Darstellungsarten via `.menuBarExtraStyle()`:

**Menu-Style** (Standard) erzeugt ein klassisches Dropdown-Menü:

```swift
@main
struct UtilityApp: App {
    var body: some Scene {
        MenuBarExtra("Utility", systemImage: "hammer") {
            Button("Aktion 1") { /* action */ }
            Button("Aktion 2") { /* action */ }
            Divider()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
```

Dieser Stil unterstützt **nur** Buttons, Text, Dividers und Toggles. Custom-Styles werden ignoriert, Images im Content ebenfalls. Der Runloop wird blockiert solange das Menü offen ist – Echtzeit-Updates sind nicht möglich.

**Window-Style** öffnet ein Popover-artiges Fenster mit voller SwiftUI-Kontrolle:

```swift
@main
struct RichApp: App {
    var body: some Scene {
        MenuBarExtra("Rich UI", systemImage: "gear") {
            ContentView()
                .frame(width: 300, height: 180)
        }
        .menuBarExtraStyle(.window)
    }
}
```

Hier funktioniert jede SwiftUI-View: Sliders, Pickers, Images, komplexe Layouts. Das Fenster kann dynamisch skalieren oder eine fixe Größe haben.

| Kriterium | Menu-Style | Window-Style |
|-----------|------------|--------------|
| Content-Typen | Buttons, Text, Dividers | Beliebige SwiftUI Views |
| Keyboard Shortcuts | ✅ Nativ unterstützt | Manuelle Implementation |
| Rich UI (Slider, Images) | ❌ Nicht möglich | ✅ Voll unterstützt |
| Runloop-Verhalten | Blockiert | Blockiert nicht |
| Bester Einsatz | Schnelle Aktionen | Komplexe Interfaces |

---

## Dock-Icon verstecken mit LSUIElement

Für eine reine Menübar-App ohne Dock-Icon gibt es zwei Wege:

### Statische Konfiguration in Info.plist

```xml
<key>LSUIElement</key>
<true/>
```

Oder in Xcode: Target → Info → Key "**Application is agent (UIElement)**" auf **YES** setzen.

**Was LSUIElement bewirkt:**
- Kein Dock-Icon beim App-Start
- Keine App-spezifische Menüleiste am oberen Bildschirmrand
- App erscheint nicht im Cmd+Tab Switcher
- App kann trotzdem Fenster anzeigen und den Fokus erhalten

### Programmatisches Umschalten zur Laufzeit

Für Apps, die dynamisch zwischen Dock und Menu-Bar-Only wechseln sollen:

```swift
import AppKit

// Dock-Icon verstecken (Menu-Bar-Only)
NSApp.setActivationPolicy(.accessory)

// Dock-Icon anzeigen (normale App)
NSApp.setActivationPolicy(.regular)
NSApp.activate(ignoringOtherApps: true)
```

**Vollständige Implementation mit Toggle:**

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    @AppStorage("showInMenuBar") var showInMenuBar = false
    
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        if showInMenuBar {
            NSApp.setActivationPolicy(.accessory)
            return false  // Nicht beenden, nur verstecken
        }
        return true
    }
}

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    
    var body: some Scene {
        WindowGroup { ContentView() }
        MenuBarExtra("App", systemImage: "star.fill") {
            Button("Fenster zeigen") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Beenden") { NSApp.terminate(nil) }
        }
    }
}
```

**Wichtiger Fallstrick:** Beim Wechsel zu `.accessory` können Fenster automatisch versteckt werden. Lösung: `window.canHide = false` setzen. Außerdem kann `setActivationPolicy()` in manchen macOS-Versionen fehlschlagen – hier hilft die Carbon-API als Workaround.

---

## Menübar-Icons richtig gestalten

### SF Symbols verwenden

Der einfachste Weg für professionelle Icons:

```swift
MenuBarExtra("App", systemImage: "hammer") { ContentView() }
```

**Dynamische Icons basierend auf State:**

```swift
@State var currentNumber: String = "1"

MenuBarExtra(currentNumber, systemImage: "\(currentNumber).circle") {
    Button("Eins") { currentNumber = "1" }
    Button("Zwei") { currentNumber = "2" }
}
```

### Custom Template Images

Für eigene Icons gelten klare Größenvorgaben nach Bjango-Guidelines:
- **Maximale Höhe:** 22pt (fixe Arbeitszone, unabhängig von Menüleistenhöhe)
- **Icon-Größe für optimale Optik:** 16×16pt zentriert in 22×22pt Canvas
- **Formate:** PDF (empfohlen), SVG, oder PNG-Paar (1× und 2×)

**Template Images nutzen nur den Alpha-Kanal** – macOS ignoriert Farben und töntet das Icon automatisch für Light/Dark Mode.

```swift
MenuBarExtra {
    ContentView()
} label: {
    let image: NSImage = {
        let ratio = $0.size.height / $0.size.width
        $0.size.height = 18
        $0.size.width = 18 / ratio
        $0.isTemplate = true  // Wichtig für automatische Anpassung
        return $0
    }(NSImage(named: "MenuBarIcon")!)
    Image(nsImage: image)
}
```

### Status-Anzeige im Icon

Für Aufnahme-Status oder ähnliche Indikatoren:

```swift
@State var isRecording = false

MenuBarExtra {
    ContentView()
} label: {
    HStack(spacing: 4) {
        Image(systemName: "mic")
        if isRecording {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
        }
    }
}
```

---

## Settings-Fenster implementieren

### SwiftUI Settings Scene (empfohlen)

Ab macOS 13 ist die Settings-Scene der native Weg:

```swift
@main
struct MyApp: App {
    var body: some Scene {
        MenuBarExtra("App", systemImage: "gear") {
            SettingsLink { Text("Einstellungen...") }
                .keyboardShortcut(",")
            Divider()
            Button("Beenden") { NSApp.terminate(nil) }
        }
        
        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gear") }
            AppearanceSettingsView()
                .tabItem { Label("Darstellung", systemImage: "paintbrush") }
        }
        .frame(width: 450, height: 250)
    }
}
```

### Settings programmatisch öffnen

**macOS 14+ mit Environment:**

```swift
struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        Button("Einstellungen öffnen") {
            openSettings()
        }
    }
}
```

**macOS 13 Legacy-Methode:**

```swift
NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
```

### Settings-Fenster in den Vordergrund bringen

Bei Menu-Bar-Only Apps kann das Settings-Fenster im Hintergrund bleiben. Lösung:

```swift
func showSettings() {
    // Settings öffnen...
    NSApp.setActivationPolicy(.regular)  // Temporär als normale App
    NSApp.activate(ignoringOtherApps: true)
}
```

Für macOS Sonoma+ wurde `activate(ignoringOtherApps:)` deprecated – verwende stattdessen `NSApp.activate()`.

---

## Keyboard Shortcuts definieren

```swift
MenuBarExtra("App", systemImage: "star.fill") {
    Button("Kopieren") { /* action */ }
        .keyboardShortcut("c")  // ⌘C
    
    Button("Speichern") { /* action */ }
        .keyboardShortcut("s", modifiers: [.command, .shift])  // ⇧⌘S
    
    SettingsLink { Text("Einstellungen...") }
        .keyboardShortcut(",")  // ⌘,
    
    Button("Beenden") { NSApp.terminate(nil) }
        .keyboardShortcut("q")  // ⌘Q
}
```

Für **globale, benutzerdefinierbare Shortcuts** empfiehlt sich die **KeyboardShortcuts**-Bibliothek von sindresorhus:

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleApp = Self("toggleApp")
}

// UI für Benutzer-Anpassung
KeyboardShortcuts.Recorder("Toggle App:", name: .toggleApp)

// Auf Shortcut reagieren
KeyboardShortcuts.onKeyUp(for: .toggleApp) { /* Handle */ }
```

---

## Vollständiges Beispiel einer minimalen Menübar-App

```swift
import SwiftUI

@main
struct MinimalMenuBarApp: App {
    @State private var counter = 0
    
    var body: some Scene {
        // Menübar-Item mit Window-Style für Rich UI
        MenuBarExtra("Counter: \(counter)", systemImage: "number.circle") {
            VStack(spacing: 16) {
                Text("Aktueller Wert: \(counter)")
                    .font(.title2)
                
                HStack {
                    Button("-") { counter -= 1 }
                    Button("+") { counter += 1 }
                }
                .buttonStyle(.bordered)
                
                Divider()
                
                HStack {
                    SettingsLink { Text("Einstellungen") }
                    Spacer()
                    Button("Beenden") { NSApp.terminate(nil) }
                }
                .font(.caption)
            }
            .padding()
            .frame(width: 200)
        }
        .menuBarExtraStyle(.window)
        
        // Settings Scene
        Settings {
            Form {
                Toggle("Launch at Login", isOn: .constant(false))
                Picker("Theme", selection: .constant(0)) {
                    Text("System").tag(0)
                    Text("Hell").tag(1)
                    Text("Dunkel").tag(2)
                }
            }
            .padding()
            .frame(width: 300, height: 150)
        }
    }
}
```

**Info.plist** für Dock-freie App:
```xml
<key>LSUIElement</key>
<true/>
```

---

## Empfohlene Open-Source Referenzen

| Projekt | GitHub | Beschreibung |
|---------|--------|--------------|
| **Ice** | jordanbaird/Ice | **25k⭐** Menübar-Manager mit vollem Feature-Set |
| **Hidden Bar** | dwarvesf/hidden | **13k⭐** Ultra-leichter Icon-Hider |
| **SwiftBar** | swiftbar/SwiftBar | Anpassbare Menübar mit Skript-Support |
| **Stats** | exelban/stats | System-Monitoring in SwiftUI |

### Hilfreiche Bibliotheken

| Bibliothek | Zweck |
|------------|-------|
| **MenuBarExtraAccess** (orchetect) | `isPresented` Binding, Zugriff auf NSStatusItem |
| **KeyboardShortcuts** (sindresorhus) | User-customizable globale Hotkeys |
| **Defaults** (sindresorhus) | Type-safe UserDefaults mit SwiftUI-Support |
| **LaunchAtLogin** (sindresorhus) | Einfache Launch-at-Login Implementation |
| **SettingsAccess** (orchetect) | Besserer programmatischer Settings-Zugriff |

---

## Fazit und Best Practices

Die Entwicklung von macOS Menübar-Apps mit SwiftUI ist seit macOS 13 erheblich einfacher geworden. **Für neue Projekte empfiehlt sich:**

- **macOS 14+ als Minimum-Target** für optimale MenuBarExtra-Unterstützung
- **Menu-Style** für reine Utility-Apps mit wenigen Aktionen
- **Window-Style** sobald Custom-UI, Forms oder Rich Content benötigt wird
- **`LSUIElement = true`** für reine Menübar-Apps
- **Immer einen Beenden-Button** bereitstellen (kein Dock-Icon = kein Kontextmenü)
- **Settings Scene** von Anfang an implementieren (Apple Review erwartet dies)

Die Open-Source Projekte **Ice** und **Hidden Bar** sind exzellente Code-Referenzen für produktionsreife Patterns. Die Bibliotheken von **sindresorhus** (KeyboardShortcuts, Defaults, LaunchAtLogin) und **orchetect** (MenuBarExtraAccess, SettingsAccess) lösen die häufigsten Probleme elegant.
---

## MenuBarExtra Implementierung

<!-- Nach der Recherche ausfüllen -->

## App ohne Dock-Icon

<!-- Nach der Recherche ausfüllen -->

## Icon-Design

<!-- Nach der Recherche ausfüllen -->

## Settings-Fenster

<!-- Nach der Recherche ausfüllen -->

## Code-Beispiel

<!-- Nach der Recherche ausfüllen -->
