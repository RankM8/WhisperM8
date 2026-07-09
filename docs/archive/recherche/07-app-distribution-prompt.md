# Recherche-Prompt: macOS App Distribution (ohne App Store)

## Kontext

WhisperM8 soll einfach an Mitarbeiter verteilt werden können, ohne den App Store zu nutzen. Die Installation soll schnell und unkompliziert sein.

## Was wir wissen müssen

### 1. Distribution-Optionen

- **DMG-Datei**: Klassische Mac-Installation (App in Applications ziehen)
- **PKG-Installer**: Automatische Installation
- **Direkter .app Download**: Einfachste Option
- **Homebrew Cask**: Für technisch versierte User

### 2. Code Signing

- Ist Code Signing nötig für interne Distribution?
- Was passiert ohne Signing? (Gatekeeper-Warnung)
- Apple Developer ID für Signing
- Ad-hoc Signing vs. Developer ID
- Notarization: Was ist das und brauchen wir es?

### 3. Gatekeeper & Sicherheitswarnungen

- "App kann nicht geöffnet werden, da sie von einem unbekannten Entwickler stammt"
- Wie umgeht man das? (Rechtsklick → Öffnen)
- Wie erklärt man das den Usern?

### 4. Einfachste Lösung

- Was ist die einfachste Distribution für ein Team von ~10-50 Leuten?
- Muss die App signiert sein wenn sie nur intern genutzt wird?
- GitHub Releases als Distribution-Kanal?

### 5. Auto-Updates

- Wie implementiert man Auto-Updates ohne App Store?
- Sparkle Framework?
- Manueller Update-Check?

## Recherche-Quellen

- Apple Developer Documentation (Distribution)
- Sparkle Framework Dokumentation
- Best Practices für interne macOS App Distribution

## Erwartetes Ergebnis

1. Empfohlene Distribution-Methode für unser Team
2. Mindestanforderungen (Signing, Notarization)
3. Anleitung für User bei Gatekeeper-Warnung
4. Optional: Auto-Update Strategie
