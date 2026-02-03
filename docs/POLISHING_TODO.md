# WhisperM8 - Polishing & Robustness TODO

## Priorität: HOCH (Kritisch für Funktionalität)

### 1. Audio Recording Robustheit
- [ ] **Sample Rate Conversion fixen** - AudioRecorder.writeBuffer() hat unvollständige Resampling-Logik
- [ ] **Fehlerbehandlung bei Audio-Engine Start** - Try-Catch erweitern
- [ ] **Mikrofon-Wechsel während Aufnahme** - Graceful handling wenn User Mikrofon wechselt
- [ ] **Maximale Aufnahmedauer** - Limit setzen (z.B. 5 Minuten) um API-Limits nicht zu überschreiten
- [ ] **Audio-Format Validierung** - Prüfen ob M4A korrekt erstellt wurde vor Upload

### 2. API Error Handling
- [ ] **Retry-Logik** - Bei temporären Fehlern (429, 500, 503) automatisch wiederholen
- [ ] **Timeout konfigurierbar** - Aktuell hardcoded 60s
- [ ] **Bessere Fehlermeldungen** - JSON-Fehler von API parsen und anzeigen
- [ ] **API-Key Validierung** - Test-Request beim Speichern des Keys
- [ ] **Rate Limiting Feedback** - User informieren wenn Limit erreicht

### 3. Overlay & UI
- [ ] **Overlay Position** - Multi-Monitor Support (aktuell nur NSScreen.main)
- [ ] **Overlay Animation** - Smooth fade-in/fade-out
- [ ] **Pulsing Animation fixen** - isPulsing State wird nicht korrekt zurückgesetzt
- [ ] **Dark/Light Mode** - Overlay-Farben testen in beiden Modi

### 4. Settings Focus Problem
- [ ] **Robustere Lösung** - setActivationPolicy Wechsel kann flackern
- [ ] **Alternative: Eigenes NSWindow** - Statt SwiftUI Window Scene
- [ ] **TextField Focus Ring** - Visuelles Feedback wenn fokussiert

---

## Priorität: MITTEL (User Experience)

### 5. Onboarding
- [ ] **Onboarding automatisch öffnen** - Beim ersten Start nicht nur im Hintergrund
- [ ] **API-Key Test im Onboarding** - Validieren bevor "Fertig"
- [ ] **Hotkey Konflikt-Erkennung** - Warnen wenn Hotkey bereits belegt
- [ ] **Skip-Option** - Onboarding überspringen erlauben

### 6. Feedback & Notifications
- [ ] **Sound bei erfolgreicher Transkription** - Optional
- [ ] **macOS Notification** - "Text kopiert" Benachrichtigung
- [ ] **Haptic Feedback** - Falls Trackpad unterstützt
- [ ] **Visual Feedback** - Kurzes Aufblitzen des Menübar-Icons

### 7. Transkriptions-Features
- [ ] **Sprache auto-detect** - Wenn "auto" gewählt, Sprache aus Response anzeigen
- [ ] **Prompt/System-Instruction** - Optional für bessere Formatierung
- [ ] **Timestamps** - Optional Zeitstempel in Transkription
- [ ] **Punctuation Enhancement** - Nachbearbeitung der Interpunktion

### 8. History & Clipboard
- [ ] **Transkriptions-History** - Letzte 10-20 Transkriptionen speichern
- [ ] **History View** - Fenster zum Durchsuchen alter Transkriptionen
- [ ] **Auto-Paste Option** - Direkt in aktive App einfügen (optional)

---

## Priorität: NIEDRIG (Nice-to-have)

### 9. Performance
- [ ] **Memory Management** - Audio-Buffer nach Verwendung freigeben
- [ ] **Temp-File Cleanup** - Regelmäßig alte Temp-Files löschen
- [ ] **Launch Time** - App-Start optimieren

### 10. Accessibility
- [ ] **VoiceOver Support** - Alle UI-Elemente labeln
- [ ] **Keyboard Navigation** - Tab-Navigation in Settings
- [ ] **Reduced Motion** - Animation respektieren

### 11. Distribution
- [ ] **App Icon** - Eigenes Icon erstellen (alle Größen)
- [ ] **Code Signing** - Developer ID Zertifikat
- [ ] **Notarization** - Apple Notarization für Gatekeeper
- [ ] **DMG Installer** - Drag-and-Drop Installation
- [ ] **Sparkle Updates** - Auto-Update Mechanismus
- [ ] **GitHub Releases** - Automatische Release-Builds

### 12. Zusätzliche Features
- [ ] **Lokales Whisper** - Offline-Modus mit whisper.cpp
- [ ] **Shortcuts Integration** - Apple Shortcuts Actions
- [ ] **AppleScript Support** - Scripting-Unterstützung
- [ ] **Mehrere Profile** - Verschiedene Hotkeys/Sprachen

---

## Code Quality

### 13. Testing
- [ ] **Unit Tests** - AudioRecorder, TranscriptionService, KeychainManager
- [ ] **UI Tests** - Settings-Flow, Onboarding
- [ ] **Integration Tests** - Vollständiger Recording-Flow (Mock API)

### 14. Code Cleanup
- [ ] **Sendable Conformance** - AppState Thread-safe machen
- [ ] **Error Types** - Einheitliche Error-Hierarchie
- [ ] **Logging** - OSLog für Debugging
- [ ] **Comments** - Code dokumentieren

### 15. CI/CD
- [ ] **GitHub Actions** - Automatische Builds
- [ ] **SwiftLint** - Code Style Enforcement
- [ ] **Dependabot** - Dependency Updates

---

## Bekannte Bugs

1. **Settings TextField** - Erfordert temporäre Dock-Anzeige (Workaround aktiv)
2. **Overlay Pulsing** - Animation stoppt nicht immer korrekt
3. **KeyboardShortcuts #Preview** - Muss in Dependency gepatcht werden für SPM-Build
4. **Audio Resampling** - writeBuffer() Konvertierung unvollständig

---

## Geschätzter Aufwand

| Kategorie | Items | Aufwand |
|-----------|-------|---------|
| Hoch (Kritisch) | 13 | 2-3 Tage |
| Mittel (UX) | 12 | 2-3 Tage |
| Niedrig (Nice-to-have) | 16 | 3-5 Tage |
| Code Quality | 8 | 2-3 Tage |

**Gesamt: ~10-14 Tage für komplettes Polishing**

---

## Empfohlene Reihenfolge

1. Audio Recording Robustheit (#1)
2. API Error Handling (#2)
3. Settings Focus Problem (#4)
4. Onboarding (#5)
5. Feedback & Notifications (#6)
6. Distribution (#11)
7. Rest nach Bedarf
