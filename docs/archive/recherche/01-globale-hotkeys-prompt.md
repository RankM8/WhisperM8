# Recherche-Prompt: Globale Hotkeys unter macOS

## Kontext

Wir entwickeln eine macOS-App (Swift/SwiftUI) namens WhisperM8, die per globalem Hotkey (z.B. Option+Space) eine Sprachaufnahme starten/stoppen soll. Der Hotkey muss funktionieren, auch wenn die App nicht im Vordergrund ist.

## Was wir wissen müssen

### 1. Technische Implementierung

- Wie implementiert man globale Hotkeys in Swift/SwiftUI?
- Welche APIs gibt es? (`CGEvent`, `NSEvent.addGlobalMonitorForEvents`, `MASShortcut`, etc.)
- Was sind die Vor-/Nachteile der verschiedenen Ansätze?
- Gibt es empfohlene Third-Party Libraries?

### 2. Accessibility Permissions

- Welche Berechtigungen braucht die App für globale Hotkeys?
- Wie prüft man programmatisch, ob die Berechtigung erteilt wurde?
- Wie leitet man den User zu den Systemeinstellungen, um die Berechtigung zu erteilen?
- Was ist `AXIsProcessTrusted()`?

### 3. Best Practices

- Wie vermeidet man Konflikte mit System-Hotkeys?
- Soll der User den Hotkey selbst konfigurieren können?
- Wie speichert man benutzerdefinierte Hotkeys?

### 4. Code-Beispiele

- Vollständiges Beispiel für globalen Hotkey in Swift
- Beispiel für Accessibility-Check und -Anfrage

## Recherche-Quellen

- Apple Developer Documentation
- Aktuelle GitHub-Projekte mit ähnlicher Funktionalität
- Stack Overflow / Swift Forums
- Bestehende Open-Source Whisper-Clients für macOS

## Erwartetes Ergebnis

Ein zusammenfassender Bericht mit:
1. Empfohlener Ansatz für unsere App
2. Code-Snippets für die Implementierung
3. Bekannte Fallstricke und wie man sie vermeidet
4. Liste empfohlener Libraries (falls sinnvoll)
