# Recherche-Zusammenfassung WhisperM8

> Alle 9 Recherchen abgeschlossen. Dieses Dokument fasst die Entscheidungen zusammen.

---

## 1. API-Strategie

### Primär: OpenAI (Beste Qualität)

| Modell | Qualität | Preis | Use Case |
|--------|----------|-------|----------|
| **gpt-4o-transcribe** | ⭐ Beste WER | $0.006/min | Standard für WhisperM8 |
| whisper-1 | Gut | $0.006/min | Falls Timestamps/SRT nötig |

**Endpunkt:** `https://api.openai.com/v1/audio/transcriptions`

### Alternative: Groq (OpenAI-kompatibel)

| Modell | Qualität | Preis | Speed |
|--------|----------|-------|-------|
| **whisper-large-v3** | Sehr gut | $0.002/min | 189x Echtzeit |

**Endpunkt:** `https://api.groq.com/openai/v1/audio/transcriptions`

**Vorteil:** Drop-in Replacement - nur Base-URL und API-Key ändern.

### OpenRouter: NICHT geeignet

OpenRouter hat **keinen** `/v1/audio/transcriptions` Endpunkt. Nur Workaround über Chat-Completion mit Audio-Input möglich - nicht praktikabel.

---

## 2. Technische Implementierung

### Audio-Aufnahme

| Entscheidung | Wert |
|--------------|------|
| **API** | AVAudioEngine (nicht AVAudioRecorder) |
| **Format** | M4A (AAC) |
| **Sample Rate** | 16 kHz |
| **Kanäle** | Mono |
| **Bitrate** | 32 kbps |
| **Max. Aufnahme** | 100+ Minuten unter 25MB Limit |

**Code-Pattern:** `installTap` auf `inputNode` für Echtzeit-Buffer-Zugriff + Level-Metering.

### Globale Hotkeys

| Entscheidung | Wert |
|--------------|------|
| **Library** | KeyboardShortcuts (sindresorhus) |
| **Pattern** | Hold-to-Record (KeyDown → Start, KeyUp → Stop) |
| **Default** | Kein Default - User wählt im Onboarding |
| **Permission** | Keine nötig (nutzt Carbon API intern) |

**macOS Sequoia Bug:** Option-only Shortcuts funktionieren nicht mehr. Empfehlung: Shortcuts mit Cmd-Key.

### Floating Overlay

| Entscheidung | Wert |
|--------------|------|
| **Window-Typ** | NSPanel (nicht NSWindow) |
| **Style Mask** | `.nonactivatingPanel` |
| **Window Level** | `.floating` |
| **Größe** | 180×56pt (kompakt) |
| **Position** | Bottom-center, 40pt vom Rand |
| **Elemente** | Pulsierender roter Punkt, Timer, Audio-Level-Bars |

**Wichtig:** `canBecomeKey` und `canBecomeMain` → `false` (kein Fokus-Stealing).

### Menübar-App

| Entscheidung | Wert |
|--------------|------|
| **API** | SwiftUI `MenuBarExtra` (macOS 13+) |
| **Style** | `.menu` für Dropdown |
| **Dock-Icon** | `LSUIElement = true` (versteckt) |
| **Settings** | SwiftUI `Settings` Scene |

---

## 3. Permissions & Onboarding

### Benötigte Permissions

| Permission | Anfrage-Methode | Deep Link |
|------------|-----------------|-----------|
| **Mikrofon** | Automatischer System-Dialog | `Privacy_Microphone` |
| **Accessibility** | ❌ Nicht nötig mit KeyboardShortcuts | — |

**Überraschung:** Mit KeyboardShortcuts brauchen wir **keine Accessibility-Permission** für Hotkeys!

### Onboarding-Flow

```
1. Welcome Screen
      ↓
2. Hotkey konfigurieren (KeyboardShortcuts.Recorder)
      ↓
3. Mikrofon-Permission (System-Dialog)
      ↓
4. API-Key eingeben (OpenAI oder Groq)
      ↓
5. Test-Aufnahme
      ↓
6. Fertig!
```

---

## 4. App Distribution

| Komponente | Entscheidung | Kosten |
|------------|--------------|--------|
| **Format** | DMG (Drag-and-Drop) | Free |
| **Signing** | Developer ID Application | $99/Jahr |
| **Notarization** | Ja (eliminiert Gatekeeper-Warnungen) | Inkl. |
| **Hosting** | GitHub Releases | Free |
| **Auto-Updates** | Sparkle 2.x | Free |

**Alternative ohne Budget:** Ad-hoc Signing + Gatekeeper-Bypass-Anleitung für User.

---

## 5. Konkurrenz-Positionierung

### Marktanalyse

| App | Stärke | Schwäche | Preis |
|-----|--------|----------|-------|
| **SuperWhisper** | Feature-reich, lokale Modelle | Komplex, teuer | $249 Lifetime |
| **Wispr Flow** | Kontext-Awareness | Privacy-Skandal, Cloud-only, Abo | $12/Mo |
| **VoiceInk** | Open Source, günstig | Nur Apple Silicon | $25-49 |
| **Voice Type** | Radikal einfach | Keine AI-Features | $20 |

### WhisperM8 Positionierung

> **"Die einfachste Diktier-App mit bester Transkriptions-Qualität - kostenlos mit eigenem API-Key."**

**Differenzierung:**
1. Kostenlos (User bringt eigenen Key)
2. Beste Qualität (gpt-4o-transcribe)
3. Einfachste UI (kein Feature-Bloat)
4. Privacy-First (kein Cloud-Zwang unsererseits)

### Von Konkurrenz übernehmen

| Feature | Quelle | Umsetzung |
|---------|--------|-----------|
| Mini-Window + Full-Window Option | SuperWhisper | Später evaluieren |
| Farbcodierte Status-Dots | SuperWhisper | Gelb/Blau/Grün |
| Audio-Waveform | SuperWhisper | 5-Bar Level-Meter |
| Hold-to-Record + Toggle | SuperWhisper | Via KeyboardShortcuts |
| "It just works" Einfachheit | Voice Type | Max 3 Klicks bis Diktat |

### NICHT bauen (Scope)

- ❌ Meeting-Transkription
- ❌ Datei-Import/Batch
- ❌ Übersetzungen
- ❌ AI-Zusammenfassungen
- ❌ Team/Enterprise Features
- ❌ Windows-Support
- ❌ Screenshot-Context-Capture (Privacy!)
- ❌ Eigene History (System-Clipboard reicht)

---

## 6. Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────────┐
│  WhisperM8App                                               │
│  ├─ MenuBarExtra (Icon in Menüleiste)                      │
│  ├─ Settings Scene (API-Keys, Hotkey)                      │
│  └─ Recording Overlay (NSPanel, floating)                  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  AppState (@Observable)                                     │
│  ├─ isRecording: Bool                                      │
│  ├─ transcriptionResult: String?                           │
│  └─ selectedProvider: .openai | .groq                      │
└─────────────────────────────────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ HotkeyManager   │ │ AudioRecorder   │ │ Transcription   │
│ (Keyboard       │ │ (AVAudioEngine) │ │ Service         │
│  Shortcuts)     │ │                 │ │ (OpenAI/Groq)   │
└─────────────────┘ └─────────────────┘ └─────────────────┘
         │                 │                 │
         │                 ▼                 │
         │         ┌─────────────────┐       │
         │         │ temp.m4a        │───────┘
         │         │ (16kHz, mono)   │
         │         └─────────────────┘
         │                                   │
         │                                   ▼
         │                           ┌─────────────────┐
         └──────────────────────────▶│ NSPasteboard   │
                                     │ (System Copy)   │
                                     └─────────────────┘
```

---

## 7. Empfohlene Libraries

| Library | Zweck | GitHub |
|---------|-------|--------|
| **KeyboardShortcuts** | Globale Hotkeys | sindresorhus/KeyboardShortcuts |
| **Defaults** | Type-safe UserDefaults | sindresorhus/Defaults |
| **LaunchAtLogin** | Auto-Start | sindresorhus/LaunchAtLogin |
| **Sparkle** | Auto-Updates | sparkle-project/Sparkle |

---

## 8. Offene Entscheidungen

| Frage | Optionen | Empfehlung |
|-------|----------|------------|
| macOS Minimum | 13 vs 14 | **macOS 14** (bessere SwiftUI APIs) |
| Sprache Default | Auto vs. "de" | **"de"** voreingestellt (schneller) |
| Nach Transkription | Nur Clipboard vs. Auto-Paste | **Nur Clipboard** (sicherer) |

---

## Nächster Schritt

→ `03-implementierungsplan.md` finalisieren und mit Entwicklung starten.
