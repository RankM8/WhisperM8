# Recherche-Prompt: macOS Permissions & Onboarding Flow

## Kontext

WhisperM8 muss mehrere macOS-Berechtigungen anfragen. Für unsere Mitarbeiter soll der Onboarding-Prozess so einfach wie möglich sein - die App soll sie Schritt für Schritt durch alle nötigen Permissions führen.

## Benötigte Berechtigungen

### 1. Mikrofon-Zugriff
- Für Audio-Aufnahme
- System-Dialog erscheint automatisch bei erstem Zugriff
- Einstellung in: Systemeinstellungen → Datenschutz → Mikrofon

### 2. Accessibility (Bedienungshilfen)
- Für globale Hotkeys
- Kein automatischer System-Dialog - User muss manuell aktivieren
- Einstellung in: Systemeinstellungen → Datenschutz → Bedienungshilfen

### 3. (Optional) Tastaturüberwachung / Input Monitoring
- Möglicherweise für bestimmte Hotkey-Implementierungen nötig
- Einstellung in: Systemeinstellungen → Datenschutz → Eingabeüberwachung

## Was wir wissen müssen

### 1. Permission-Check APIs

- Wie prüft man Mikrofon-Berechtigung? (`AVCaptureDevice.authorizationStatus`)
- Wie prüft man Accessibility? (`AXIsProcessTrusted()`)
- Wie fragt man Berechtigungen programmatisch an?

### 2. Onboarding UI Flow

- Wie gestaltet man einen guten Permission-Onboarding-Flow?
- Schritt-für-Schritt Wizard vs. alles auf einmal?
- Wie erklärt man dem User warum jede Berechtigung nötig ist?

### 3. Deep Links zu Systemeinstellungen

- Kann man direkt zu den richtigen Systemeinstellungen navigieren?
- URL-Schema für Systemeinstellungen (`x-apple.systempreferences:...`)
- Unterschiede zwischen macOS-Versionen?

### 4. Edge Cases

- Was passiert wenn User Berechtigung verweigert?
- Wie erkennt man wenn Berechtigung nachträglich entzogen wurde?
- Re-Prompting: Kann man erneut fragen?

### 5. Code-Beispiele

- Vollständiger Onboarding-Flow in SwiftUI
- Permission-Check und Request für alle benötigten Permissions
- Deep Links zu Systemeinstellungen

## Recherche-Quellen

- Apple Developer Documentation
- Human Interface Guidelines für Permissions
- Best Practices von anderen macOS Apps

## Erwartetes Ergebnis

1. Liste aller benötigten Permissions mit Check-APIs
2. Empfohlener Onboarding-Flow (Reihenfolge, UX)
3. Deep Links zu allen relevanten Systemeinstellungen
4. SwiftUI Code für Onboarding-Screens
5. Error-Handling wenn Permissions fehlen
