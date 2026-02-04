# WhisperM8 - Benutzerhandbuch

## Schnellstart

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

**Bei Problemen (Crashes, alte Installation):**
```bash
make clean-install
```

---

## Inhaltsverzeichnis

1. [Installation](#installation)
2. [Erste Schritte](#erste-schritte)
3. [Verwendung](#verwendung)
4. [Einstellungen](#einstellungen)
5. [Fehlerbehebung](#fehlerbehebung)
6. [Make-Befehle](#make-befehle)

---

## Installation

### Voraussetzungen

- macOS 14 (Sonoma) oder neuer
- Xcode Command Line Tools: `xcode-select --install`
- OpenAI API-Key oder Groq API-Key

### Option A: DMG (empfohlen für Endnutzer)

1. DMG-Datei erhalten (oder selbst bauen: `make dmg`)
2. DMG öffnen
3. `WhisperM8.app` in den `Applications`-Ordner ziehen
4. App starten

### Option B: Aus Source bauen

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

Die App wird nach `/Applications/WhisperM8.app` installiert.

### Erstinstallation bei Kollegen / Neuer Mac

**WICHTIG:** Falls vorher eine andere Version installiert war:

```bash
make clean-install
```

Das entfernt alle alten Daten (Permissions, Cache, Settings) und installiert sauber neu.

---

## Erste Schritte

### 1. App starten

Nach dem Start erscheint ein **Mikrofon-Symbol** in der Menüleiste (oben rechts).

### 2. Berechtigungen erteilen

Beim ersten Start werden zwei Berechtigungen benötigt:

#### Mikrofon
- Dialog erscheint automatisch beim ersten Aufnahmeversuch
- "Erlauben" klicken

#### Accessibility (für Auto-Paste)
- Systemeinstellungen öffnet sich automatisch
- WhisperM8 in der Liste finden und aktivieren
- **Falls nicht in Liste:** "+" klicken → `/Applications/WhisperM8.app` auswählen

### 3. API-Key einrichten

1. Klicke auf Mikrofon-Symbol → "Einstellungen..."
2. Tab "API" wählen
3. Provider auswählen:
   - **OpenAI** - Beste Qualität (~$0.006/min)
   - **Groq** - Kostenlos (Rate-Limited)
4. API-Key eingeben

**API-Keys erstellen:**
- OpenAI: https://platform.openai.com/api-keys
- Groq: https://console.groq.com/keys

### 4. Hotkey konfigurieren

1. Tab "Hotkey" wählen
2. In das Recorder-Feld klicken
3. Gewünschte Tastenkombination drücken

**Empfohlen:** `Control + Shift + Space`

**Hinweis:** Option-only Shortcuts funktionieren auf macOS 15+ nicht zuverlässig.

---

## Verwendung

### Diktieren (Push-to-Talk)

1. **Cursor platzieren** in einem Textfeld (TextEdit, Slack, Browser, etc.)
2. **Hotkey gedrückt halten** und sprechen
3. **Loslassen** → Transkription startet
4. **Text erscheint** automatisch im Textfeld (Auto-Paste)

### Aufnahme abbrechen

Während der Aufnahme kannst du jederzeit abbrechen:
- **X-Button** im Overlay klicken

Die Aufnahme wird verworfen, nichts wird transkribiert.

### Overlay-Anzeige

Während der Aufnahme erscheint unten am Bildschirm:
- Mikrofon-Indicator (reagiert auf Stimme)
- Timer (MM:SS)
- Audio-Level Balken
- X-Button zum Abbrechen

### Status in der Menüleiste

| Icon | Status |
|------|--------|
| 🎤 | Bereit |
| 🎤 (gefüllt) | Aufnahme läuft |
| ⏳ | Transkription läuft |

---

## Einstellungen

Öffnen: Mikrofon-Symbol → "Einstellungen..." (oder `Cmd + ,`)

### API Tab

| Einstellung | Beschreibung |
|-------------|--------------|
| Provider | OpenAI oder Groq |
| API-Key | Dein persönlicher API-Schlüssel (sicher im Keychain gespeichert) |
| Sprache | Deutsch, Englisch, oder Automatisch |

### Hotkey Tab

| Einstellung | Beschreibung |
|-------------|--------------|
| Aufnahme-Taste | Tastenkombination für Push-to-Talk |

### Allgemein Tab

| Einstellung | Beschreibung |
|-------------|--------------|
| Bei Anmeldung starten | App automatisch beim Login starten |
| Auto-Paste | Text automatisch einfügen (oder nur Clipboard) |

---

## Fehlerbehebung

### App crasht / startet nicht / verhält sich seltsam

**Lösung:** Clean Install
```bash
make clean-install
```

Das entfernt alle alten Daten und installiert neu. Danach:
1. Accessibility-Berechtigung erteilen
2. API-Key neu eingeben
3. Hotkey festlegen

### Auto-Paste funktioniert nicht

1. **Accessibility-Berechtigung prüfen:**
   - Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen
   - WhisperM8 muss aktiviert sein

2. **App neu starten** nach Berechtigungsänderung

3. **Auto-Paste aktiviert?** → Einstellungen → Allgemein prüfen

### Mikrofon-Berechtigung verweigert

1. Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon
2. WhisperM8 aktivieren
3. App neu starten

### Hotkey funktioniert nicht

1. Prüfe ob andere App den gleichen Hotkey verwendet
2. Versuche andere Tastenkombination
3. Vermeide Option-only Shortcuts auf macOS 15+

### API-Fehler

- Key korrekt eingegeben? (keine Leerzeichen am Ende)
- Groq Rate-Limit erreicht? → Warten oder zu OpenAI wechseln
- Internetverbindung prüfen

### Debug Logging

```bash
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
```

---

## Make-Befehle

| Befehl | Beschreibung |
|--------|--------------|
| `make install` | Build + Installation nach `/Applications` |
| `make run` | Debug-Build + sofort starten |
| `make build` | Release-Build (App bleibt im Repo) |
| `make dmg` | DMG für Verteilung erstellen |
| `make clean-install` | **Alles zurücksetzen** + neu installieren |
| `make kill` | Laufende Instanzen beenden |
| `make clean` | Build-Artefakte löschen |

### Wann welchen Befehl?

- **Normale Updates:** `git pull && make install`
- **Bei Problemen:** `make clean-install`
- **Für Kollegen:** `make dmg` → DMG verschicken

---

## Datenschutz

- **API-Keys** werden sicher im macOS Keychain gespeichert
- **Audio** wird nur temporär gespeichert und nach der Transkription gelöscht
- **Einstellungen** werden in UserDefaults gespeichert
- Audio wird an OpenAI/Groq zur Transkription gesendet

---

## Tastenkürzel

| Kürzel | Aktion |
|--------|--------|
| `Cmd + ,` | Einstellungen öffnen |
| `Cmd + Q` | App beenden |
| [Dein Hotkey] | Aufnahme starten (halten) / stoppen (loslassen) |
| X-Button | Aufnahme abbrechen |
