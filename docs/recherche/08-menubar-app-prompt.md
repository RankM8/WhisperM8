# Recherche-Prompt: macOS Menübar-App Entwicklung

## Kontext

WhisperM8 soll als Menübar-App laufen - d.h. kein Dock-Icon, nur ein Icon in der Menüleiste oben rechts. Von dort aus kann man die Einstellungen öffnen und den Status sehen.

## Was wir wissen müssen

### 1. SwiftUI MenuBarExtra (macOS 13+)

- Wie nutzt man `MenuBarExtra` in SwiftUI?
- Unterschied zwischen `MenuBarExtra` mit Menu vs. Window
- Wie zeigt man ein Custom-Fenster vom Menübar-Icon?

### 2. App ohne Dock-Icon

- `LSUIElement = true` in Info.plist
- Oder `Application is agent (UIElement)` in Xcode
- Wie wechselt man zwischen Dock/Menübar-only?

### 3. Menübar-Icon Design

- SF Symbols verwenden?
- Eigenes Icon-Template (16x16, 32x32)?
- Status-Anzeige im Icon (z.B. Punkt bei Aufnahme)?

### 4. Popup-Fenster

- Wie öffnet man ein Settings-Fenster von der Menübar?
- Positionierung relativ zum Menübar-Icon?
- WindowGroup vs separates NSWindow?

### 5. Best Practices

- Wie verhalten sich andere Menübar-Apps?
- Wann Menu, wann Fenster?
- Keyboard-Shortcuts im Menü?

## Recherche-Quellen

- Apple SwiftUI Documentation (MenuBarExtra)
- WWDC Sessions zu Menübar-Apps
- Open-Source Menübar-Apps als Referenz

## Erwartetes Ergebnis

1. Code-Struktur für Menübar-App
2. Icon-Design Guidelines
3. Settings-Fenster Implementierung
4. Beispiel-Code
