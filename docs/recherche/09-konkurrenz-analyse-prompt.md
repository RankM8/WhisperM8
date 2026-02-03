# Recherche-Prompt: Konkurrenz-Analyse (SuperWhisper & WhisperFlow)

## Kontext

Wir entwickeln WhisperM8 und wollen uns an bestehenden, erfolgreichen Apps orientieren. SuperWhisper und WhisperFlow sind die Hauptkonkurrenten im macOS Speech-to-Text Bereich.

## Fokus: Nur Diktierung

Wir wollen **nur die Diktierungsfunktion** übernehmen - keine Transkription von Dateien, keine Meeting-Aufnahmen, etc. Einfach: Hotkey drücken → Sprechen → Text erscheint.

## Was wir recherchieren müssen

### 1. SuperWhisper (superwhisper.com)

**UI/UX Analyse:**
- Wie sieht das Aufnahme-Overlay aus? (Screenshots)
- Wo erscheint es? (Mitte, Ecke, beim Cursor?)
- Welche Informationen werden angezeigt?
- Wie groß ist das Overlay?
- Welche Animationen/Feedback gibt es?
- Farbschema und Design-Sprache

**Diktierungs-Flow:**
- Wie startet/stoppt man die Aufnahme?
- Push-to-talk oder Toggle?
- Was passiert nach der Aufnahme? (direkt einfügen vs. Clipboard)
- Gibt es eine Vorschau des transkribierten Texts?
- Kann man den Text vor dem Einfügen bearbeiten?

**Features:**
- Welche Modelle werden unterstützt?
- Lokale vs. Cloud-Transkription?
- Preismodell?

### 2. WhisperFlow

**UI/UX Analyse:**
- Gleiches wie oben - Screenshots und Analyse
- Unterschiede zu SuperWhisper?

**Diktierungs-Flow:**
- Wie unterscheidet sich der Flow von SuperWhisper?

### 3. Clipboard-Verhalten

**Recherche:**
- Wie kopieren diese Apps den Text in die Zwischenablage?
- Wird der Text automatisch kopiert oder muss User bestätigen?
- Gibt es eine Vorschau bevor der Text kopiert wird?

**Für WhisperM8:**
- Text landet direkt in System-Clipboard (NSPasteboard)
- User holt es dann aus Clipboard-History (Paste, Raycast, Alfred, etc.)
- Keine eigene History nötig - System/Third-Party übernimmt das

### 4. UI-Elemente zum "Klauen"

Konkret dokumentieren:
- Overlay-Design (Größe, Form, Transparenz)
- Aufnahme-Indikator (Wellenform? Pulsierender Kreis?)
- Timer-Anzeige
- Status-Texte ("Aufnahme...", "Transkribiere...", "Fertig!")
- Abbrechen-Button Platzierung
- Erfolgs-Feedback

### 5. Differenzierung

Was machen diese Apps, das wir NICHT brauchen:
- Meeting-Transkription
- Datei-Import
- Zusammenfassungen
- AI-Nachbearbeitung
- Etc.

## Recherche-Quellen

- superwhisper.com (Website, Screenshots, Docs)
- WhisperFlow Website/App Store
- YouTube Reviews/Demos beider Apps
- Reddit/Twitter Diskussionen
- App Store Screenshots und Beschreibungen

## Erwartetes Ergebnis

1. **Screenshots** beider Apps (Overlay, Settings, History)
2. **Feature-Vergleich** Tabelle
3. **UI-Mockup Inspiration** - Welche Elemente übernehmen wir?
4. **Copy History Strategie** - Eigene vs. System/Third-Party
5. **Scope-Definition** - Was wir NICHT bauen
