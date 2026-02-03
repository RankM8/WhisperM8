# WhisperM8 - Benutzerhandbuch

## Inhaltsverzeichnis

1. [Installation](#installation)
2. [Erste Schritte](#erste-schritte)
3. [Verwendung](#verwendung)
4. [Einstellungen](#einstellungen)
5. [Fehlerbehebung](#fehlerbehebung)

---

## Installation

### Voraussetzungen

- macOS 14 (Sonoma) oder neuer
- Xcode (für das Bauen aus dem Quellcode)
- OpenAI API-Key oder Groq API-Key

### Aus Quellcode bauen

1. **Repository klonen:**
   ```bash
   git clone https://github.com/yourname/whisperm8.git
   cd whisperm8
   ```

2. **Xcode-Lizenz akzeptieren (falls noch nicht geschehen):**
   ```bash
   sudo xcodebuild -license accept
   ```

3. **App bauen:**
   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
   ```

4. **App starten:**
   ```bash
   .build/debug/WhisperM8
   ```

### Als App installieren (optional)

```bash
# Release-Build erstellen
swift build -c release

# In Applications kopieren
cp -r .build/release/WhisperM8 /Applications/WhisperM8.app
```

---

## Erste Schritte

### 1. App starten

Nach dem Start erscheint ein **Mikrofon-Symbol** in der Menüleiste (oben rechts).

### 2. Einstellungen öffnen

1. Klicke auf das Mikrofon-Symbol
2. Wähle "Einstellungen..."

### 3. API-Key einrichten

1. Gehe zum Tab "API"
2. Wähle deinen Provider:
   - **OpenAI** - Beste Qualität ($0.006/min)
   - **Groq** - Günstiger ($0.002/min)
3. Gib deinen API-Key ein
4. Wähle die Sprache (Deutsch, Englisch, oder Automatisch)

**API-Keys erstellen:**
- OpenAI: https://platform.openai.com/api-keys
- Groq: https://console.groq.com/keys

### 4. Hotkey konfigurieren

1. Gehe zum Tab "Hotkey"
2. Klicke in das Recorder-Feld
3. Drücke deine gewünschte Tastenkombination

**Empfohlen:** `Ctrl + Shift + Space`

**Hinweis:** Vermeide Option-only Shortcuts auf macOS 15+

---

## Verwendung

### Diktieren

1. **Halte** deinen konfigurierten Hotkey gedrückt
2. Ein Overlay erscheint am unteren Bildschirmrand mit:
   - Mikrofon-Indicator (reaktiv auf Stimme)
   - Timer (MM:SS)
   - Audio-Level Anzeige
3. **Sprich** deinen Text
4. **Lass los** - die Transkription startet automatisch
5. Der Text wird automatisch in die **Zwischenablage** kopiert
6. Füge mit `Cmd + V` ein

### Status-Anzeige

Das Menüleisten-Icon zeigt den aktuellen Status:

| Icon | Status |
|------|--------|
| 🎤 | Bereit |
| 🎤 (gefüllt) | Aufnahme läuft |
| ⏳ | Transkription läuft |

### Letzte Transkription

Im Menüleisten-Dropdown siehst du die letzte Transkription (gekürzt auf 100 Zeichen).

---

## Einstellungen

### API Tab

| Einstellung | Beschreibung |
|-------------|--------------|
| Provider | OpenAI oder Groq |
| API-Key | Dein persönlicher API-Schlüssel |
| Sprache | de, en, oder automatisch |

### Hotkey Tab

| Einstellung | Beschreibung |
|-------------|--------------|
| Aufnahme-Taste | Tastenkombination für Hold-to-Record |

### Allgemein Tab

| Einstellung | Beschreibung |
|-------------|--------------|
| Bei Anmeldung starten | App automatisch beim Login starten |

---

## Fehlerbehebung

### "Kein API-Key konfiguriert"

1. Öffne Einstellungen
2. Gib deinen API-Key ein
3. Stelle sicher, dass der Key korrekt ist

### "Mikrofon-Berechtigung verweigert"

1. Öffne Systemeinstellungen > Datenschutz & Sicherheit > Mikrofon
2. Aktiviere WhisperM8
3. Starte die App neu

### Hotkey funktioniert nicht

1. Prüfe ob ein anderer App den gleichen Hotkey verwendet
2. Versuche eine andere Tastenkombination
3. Vermeide Option-only Shortcuts auf macOS 15+

### Einstellungen-Fenster nimmt keine Eingabe an

- Beim Öffnen der Einstellungen erscheint die App kurz im Dock
- Das ist normal und ermöglicht Tastatureingaben
- Beim Schließen verschwindet sie wieder aus dem Dock

### Transkription fehlgeschlagen

1. Prüfe deine Internetverbindung
2. Prüfe ob dein API-Key gültig ist
3. Prüfe ob du genug API-Guthaben hast
4. Schaue auf die Fehlermeldung im Menüleisten-Dropdown

### App beenden

- Klicke auf Mikrofon-Icon > "Beenden"
- Oder: `pkill WhisperM8` im Terminal

---

## Tastenkürzel

| Kürzel | Aktion |
|--------|--------|
| Cmd + , | Einstellungen öffnen |
| Cmd + Q | App beenden |
| [Dein Hotkey] | Aufnahme starten/stoppen |

---

## Datenschutz

- **API-Keys** werden sicher im macOS Keychain gespeichert
- **Audio** wird nur temporär gespeichert und nach der Transkription gelöscht
- **Keine Daten** werden lokal gespeichert außer deinen Einstellungen
- Audio wird an OpenAI/Groq zur Transkription gesendet

---

## Support

Bei Problemen:
1. Prüfe die [Fehlerbehebung](#fehlerbehebung)
2. Erstelle ein Issue auf GitHub
