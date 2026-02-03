# Recherche-Prompt: Floating UI/Overlay unter macOS

## Kontext

WhisperM8 braucht eine kleine, nicht-störende UI die erscheint wenn die Aufnahme läuft. Diese soll über allen anderen Fenstern schweben und visuelles Feedback geben.

## Was wir wissen müssen

### 1. Technische Umsetzung

- Wie erstellt man ein Floating Window in SwiftUI/AppKit?
- `NSPanel` vs normales `NSWindow`?
- Window Level: `.floating`, `.statusBar`, `.screenSaver`?
- Wie macht man das Fenster nicht-fokussierbar (damit man weiter tippen kann)?

### 2. UI-Design

- Wie groß sollte das Overlay sein?
- Wo sollte es positioniert werden? (Bildschirmmitte, Ecke, bei Cursor?)
- Animation beim Ein-/Ausblenden?
- Welche Informationen anzeigen?
  - Aufnahme-Indikator (pulsierender roter Punkt?)
  - Timer (wie lange läuft Aufnahme?)
  - Audio-Pegel Visualisierung?
  - Abbrechen-Button?

### 3. Best Practices

- Wie vermeidet man, dass das Overlay stört?
- Soll es draggable sein?
- Transparenz/Blur-Effekt?
- Dark Mode Support?

### 4. Referenz-Apps

- Wie macht es die originale Whisper App?
- Wie machen es andere Voice-Apps (Diktieren, CleanShot, etc.)?

## Recherche-Quellen

- Apple Human Interface Guidelines
- SwiftUI Window Management
- Beispiel-Apps und deren Implementierung

## Erwartetes Ergebnis

1. Technische Implementierung für Floating Window
2. Design-Empfehlung für das Overlay
3. Code-Beispiel
4. Screenshots von Referenz-Apps
