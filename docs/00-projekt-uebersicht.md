# WhisperM8 - Projekt-Übersicht

> **Status:** Recherche abgeschlossen, bereit zur Implementierung

## Was wir bauen

Eine native macOS-App für **Diktierung** (Speech-to-Text) mit folgenden Features:

| Feature | Beschreibung |
|---------|--------------|
| **Globaler Hotkey** | Hold-to-Record (Taste gedrückt halten = Aufnahme) |
| **Floating Overlay** | Zeigt Aufnahme-Status, Timer und Audio-Level |
| **Beste Transkription** | OpenAI gpt-4o-transcribe (niedrigste Word Error Rate) |
| **Alternative API** | Groq whisper-large-v3 (OpenAI-kompatibel, günstiger) |
| **BYOK** | User bringt eigenen API-Key mit |
| **System Clipboard** | Text landet in macOS Zwischenablage |

## API-Strategie

### Primär: OpenAI (Beste Qualität)

| Modell | Qualität | Preis |
|--------|----------|-------|
| **gpt-4o-transcribe** | ⭐ Niedrigste WER | $0.006/min |

### Alternative: Groq (OpenAI-kompatibel)

| Modell | Qualität | Preis | Speed |
|--------|----------|-------|-------|
| **whisper-large-v3** | Sehr gut | $0.002/min | 189x Echtzeit |

**Vorteil:** Drop-in Replacement - nur Base-URL und API-Key ändern.

### OpenRouter: NICHT geeignet

OpenRouter hat **keinen** `/v1/audio/transcriptions` Endpunkt. Nur LLM-Routing, kein STT.

---

## Scope: Nur Diktierung

### Was wir bauen:
- ✅ Echtzeit-Diktierung per Hotkey (Hold-to-Record)
- ✅ Minimale, nicht-störende Overlay-UI
- ✅ Text in System-Zwischenablage (⌘V zum Einfügen)
- ✅ Einfaches Onboarding (nur 1 Permission!)
- ✅ Menübar-App ohne Dock-Icon

### Was wir NICHT bauen:
- ❌ Meeting-Transkription
- ❌ Datei-Import (Audio/Video)
- ❌ AI-Zusammenfassungen
- ❌ Übersetzung
- ❌ Speaker Detection
- ❌ Eigene History (System-Clipboard reicht)
- ❌ Screenshot-Context-Capture
- ❌ Windows/Linux Support

---

## Benötigte Permission

| Permission | Status | Anfrage |
|------------|--------|---------|
| **Mikrofon** | ✅ Erforderlich | Automatischer System-Dialog |
| **Accessibility** | ❌ **NICHT nötig!** | — |

**Überraschung aus der Recherche:** Mit der KeyboardShortcuts-Library brauchen wir **keine Accessibility-Permission** für globale Hotkeys! Die Library nutzt intern die Carbon API.

---

## Kernfunktionalität

```
[User hält Hotkey gedrückt]
        ↓
[Overlay erscheint - "Aufnahme läuft..."]
[Audio wird aufgenommen]
        ↓
[User lässt Hotkey los]
        ↓
[Overlay zeigt "Transkribiere..."]
[Audio → API]
        ↓
[Text → System-Zwischenablage]
[Overlay verschwindet]
        ↓
[User kann ⌘V drücken oder aus Clipboard-History holen]
```

---

## Zielplattform

- **macOS 14+** (Sonoma) - Für bessere SwiftUI APIs
- Native Swift/SwiftUI App
- Menübar-App mit `LSUIElement = true`

---

## Positionierung

> **"Die einfachste Diktier-App mit bester Transkriptions-Qualität - kostenlos mit eigenem API-Key."**

| vs. | WhisperM8 Vorteil |
|-----|-------------------|
| SuperWhisper ($249) | Kostenlos (BYOK), einfacher |
| Wispr Flow ($12/Mo) | Keine Privacy-Bedenken, keine Subscription |
| VoiceInk | Beste Qualität (gpt-4o-transcribe) |

---

## Nächster Schritt

→ Siehe `03-implementierungsplan.md` für die Entwicklungs-Phasen.
