---
description: Settings-Seite „Permissions" — Referenz der macOS-Systemberechtigungen
description_long: |
  Vollständige Referenz der Settings-Seite „Permissions": Mikrofon,
  Bedienungshilfen und Bildschirmaufnahme, inklusive Statusquellen,
  Request-Flows, Refresh-Verhalten, Onboarding-Bezügen und UX-Befunden
  als Grundlage für das Settings-Redesign.
updated: 2026-07-06 09:54
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 0 Mängel)
---

# Settings: Permissions

> **Sidebar-Gruppe:** App · **View:** `WhisperM8/Views/Settings/PermissionsSettingsView.swift` · **Enum-Case:** `ControlCenterSection.permissions` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `PermissionsSettingsView.swift`, `Services/Shared/PermissionService.swift`

## 1. Zweck & Überblick

Die Seite „Permissions" ist die Reparatur- und Kontrollansicht für macOS-Systemberechtigungen im Settings-Fenster: Sie hängt am Sidebar-Case `ControlCenterSection.permissions`, gehört zur Gruppe „App" und rendert `PermissionsSettingsView()` als Detailansicht (WhisperM8/Views/SettingsView.swift:13, WhisperM8/Views/SettingsView.swift:104, WhisperM8/Views/SettingsView.swift:229-231). Sie zeigt die benötigten TCC-Status für Mikrofon und Bedienungshilfen sowie die optionale Bildschirmaufnahme an, liest diese Status direkt aus `PermissionService` und speichert keine eigenen Berechtigungsflags (WhisperM8/Views/Settings/PermissionsSettingsView.swift:4-6, WhisperM8/Services/Shared/PermissionService.swift:7-21). Die Seite ist vor allem für Nutzer gedacht, die Berechtigungen nach dem Onboarding erneut prüfen oder reparieren müssen; der Header benennt diesen Zweck ausdrücklich als „re-check or repair permissions here without running onboarding again" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:25-36).

## 2. UI-Aufbau

Die View ist ein gruppiertes SwiftUI-`Form` mit vier Sections und startet beim Erscheinen sofort ein Refresh plus Polling, das beim Verschwinden wieder gestoppt wird (WhisperM8/Views/Settings/PermissionsSettingsView.swift:17-18, WhisperM8/Views/Settings/PermissionsSettingsView.swift:87-95). Die erste Section ist ein Header mit Schild-Icon, Statusheadline, erklärender Caption und Button „Refresh"; die Headline lautet „All system permissions are active" nur, wenn `allGranted` wahr ist, sonst „WhisperM8 needs system access" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:19-38). `allGranted` umfasst aktuell nur Mikrofon und Bedienungshilfen, nicht die optionale Bildschirmaufnahme (WhisperM8/Views/Settings/PermissionsSettingsView.swift:13-15).

Die Section „Required" enthält zwei `SystemPermissionRow`s für „Microphone" und „Accessibility" mit Icon, Beschreibung, Status, primärem Aktionsbutton und sekundärem „Open Settings"-Button (WhisperM8/Views/Settings/PermissionsSettingsView.swift:42-65). Die Section „Optional Visual Context" enthält die Zeile „Screen Recording" mit derselben Row-Komponente und kennzeichnet sie textlich als nur für Screenshots oder Screen-Clips nötig (WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-79). Die letzte Section „What happens without permissions" ist ein reiner Erklärungstext zu den Folgen fehlender Berechtigungen (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-86).

Jede Berechtigungszeile nutzt `SystemPermissionRow`: links Symbol und Text, rechts Status, primärer Button und sekundärer Button; erteilte Berechtigungen verwenden einen grünen Status und einen randlosen Primärbutton, fehlende Berechtigungen einen orangefarbenen Status und einen prominenten Primärbutton (WhisperM8/Views/Settings/PermissionsSettingsView.swift:181-231). Die View hat keine bedingten Sichtbarkeiten außer den Button-Styles innerhalb der Row; alle drei Berechtigungszeilen werden immer angezeigt (WhisperM8/Views/Settings/PermissionsSettingsView.swift:42-79, WhisperM8/Views/Settings/PermissionsSettingsView.swift:214-224).

## 3. Optionen im Detail

### Globaler Status & Refresh

| Aspekt | Wert |
|---|---|
| Control | Header-Section mit Status-Icon, Headline, Caption und Button „Refresh" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:19-38). |
| Default | Beim Initialisieren der View werden `microphoneStatus`, `accessibilityGranted` und `screenRecordingGranted` aus `PermissionService` gelesen; es gibt keinen App-Defaultwert (WhisperM8/Views/Settings/PermissionsSettingsView.swift:4-6). |
| Persistenz | Keine eigene Persistenz; die Statuswerte kommen direkt aus macOS-TCC-APIs: `AVCaptureDevice.authorizationStatus(for: .audio)`, `AXIsProcessTrusted()` und `CGPreflightScreenCaptureAccess()` (WhisperM8/Services/Shared/PermissionService.swift:7-21). |
| Gelesen von | `PermissionsSettingsView` liest alle drei Statuswerte bei State-Initialisierung und in `refreshPermissions()` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:4-6, WhisperM8/Views/Settings/PermissionsSettingsView.swift:162-166). |
| Wirkung | „Refresh" ruft `refreshPermissions()` auf und synchronisiert alle drei angezeigten Status neu mit `PermissionService` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:35-37, WhisperM8/Views/Settings/PermissionsSettingsView.swift:162-166). |
| Abhängigkeiten | Die globale Erfolgsanzeige hängt nur von Mikrofon und Accessibility ab, weil `allGranted` ausschließlich `microphoneGranted && accessibilityGranted` berechnet (WhisperM8/Views/Settings/PermissionsSettingsView.swift:13-15). |

Refresh-Verhalten: Beim Öffnen der Seite laufen `refreshPermissions()` und `startPermissionPolling()`; der Timer aktualisiert jede Sekunde alle drei Statuswerte und wird in `onDisappear` invalidiert (WhisperM8/Views/Settings/PermissionsSettingsView.swift:89-95, WhisperM8/Views/Settings/PermissionsSettingsView.swift:168-178).

### Microphone

| Aspekt | Wert |
|---|---|
| Control | `SystemPermissionRow` mit Icon `mic.fill`, Titel „Microphone", Beschreibung „Required to record your voice for transcription.", Statuslabel, primärem Button und sekundärem Button „Open Settings" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:42-53). |
| Default | Kein App-Default; die Zeile startet mit `PermissionService.microphoneAuthorizationStatus`, und `microphoneGranted` ist nur bei `.authorized` wahr (WhisperM8/Views/Settings/PermissionsSettingsView.swift:4, WhisperM8/Views/Settings/PermissionsSettingsView.swift:9-11). |
| Persistenz | macOS-TCC für Audio; Statusquelle ist `AVCaptureDevice.authorizationStatus(for: .audio)`, Request ist `AVCaptureDevice.requestAccess(for: .audio)`, kein UserDefaults-Key (WhisperM8/Services/Shared/PermissionService.swift:7-9, WhisperM8/Services/Shared/PermissionService.swift:28-30). |
| Gelesen von | `PermissionsSettingsView` liest den Status in `refreshPermissions()`; `AudioRecorder` fordert beim Aufnahmestart ebenfalls Mikrofonzugriff an und bricht bei Ablehnung mit `RecordingError.microphonePermissionDenied` ab (WhisperM8/Views/Settings/PermissionsSettingsView.swift:162-166, WhisperM8/Services/Dictation/AudioRecorder.swift:53-60). |
| Wirkung | Ohne Mikrofon kann die Aufnahme nicht starten; die Fehlerbeschreibung lautet „Microphone permission denied. Please allow access in System Settings." (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-84, WhisperM8/Services/Dictation/AudioRecorder.swift:486-495). |
| Abhängigkeiten | Mikrofon ist eine der zwei essenziellen Permissions für Onboarding-Weitergehen und App-Launch-Routing; Onboarding blockiert den Schritt ohne Mikrofon und Accessibility, und die App öffnet Onboarding beim Launch, wenn eine der beiden fehlt (WhisperM8/Views/OnboardingView.swift:150-169, WhisperM8/WhisperM8App.swift:197-204, WhisperM8/WhisperM8App.swift:270-280). |

Statusanzeigen: `microphoneStatusText` zeigt „Granted", „Denied", „Restricted", „Not requested" oder „Unknown" abhängig von `AVAuthorizationStatus` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:98-110). Der Primärbutton heißt bei `.authorized` „Check Again", bei `.denied` oder `.restricted` „Open Settings", bei `.notDetermined` „Grant" und im unbekannten Fall „Open Settings" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:113-124). Die primäre Aktion refresht bei `.authorized`, ruft bei `.notDetermined` asynchron `PermissionService.requestMicrophonePermission()` auf und refresht danach, und öffnet bei `.denied`, `.restricted` oder unbekannt den Mikrofon-Privacy-Pane (WhisperM8/Views/Settings/PermissionsSettingsView.swift:126-141). Der sekundäre „Open Settings"-Button öffnet immer `Privacy_Microphone` über `PermissionService.openMicrophonePrivacySettings()` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:51-52, WhisperM8/Services/Shared/PermissionService.swift:36-38).

### Accessibility

| Aspekt | Wert |
|---|---|
| Control | `SystemPermissionRow` mit Icon `accessibility`, Titel „Accessibility", Beschreibung „Required for auto-paste and selected text capture.", Statuslabel, primärem Button und sekundärem Button „Open Settings" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:55-65). |
| Default | Kein App-Default; die Zeile startet mit `PermissionService.hasAccessibilityPermission` und bildet daraus `accessibilityGranted` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:5). |
| Persistenz | macOS-TCC für Bedienungshilfen; Statusquelle ist `AXIsProcessTrusted()`, Request nutzt `AXIsProcessTrustedWithOptions` mit Prompt-Option, kein UserDefaults-Key (WhisperM8/Services/Shared/PermissionService.swift:15-17, WhisperM8/Services/Shared/PermissionService.swift:23-26). |
| Gelesen von | `PermissionsSettingsView` liest Accessibility in `refreshPermissions()`; `PasteService` und `SelectedContextService` prüfen dieselbe Permission vor Auto-Paste bzw. Kontext-Erfassung (WhisperM8/Views/Settings/PermissionsSettingsView.swift:162-166, WhisperM8/Services/Dictation/PasteService.swift:58-66, WhisperM8/Services/Dictation/SelectedContextService.swift:25-28). |
| Wirkung | Ohne Accessibility kann WhisperM8 laut Settings-Text weiter transkribieren und in die Zwischenablage kopieren, aber Auto-Paste und Selected-Text-Capture werden von macOS blockiert (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-84). |
| Abhängigkeiten | Accessibility ist neben Mikrofon für Onboarding-Fortschritt, Onboarding-Abschluss und Launch-Onboarding erforderlich (WhisperM8/Views/OnboardingView.swift:150-169, WhisperM8/WhisperM8App.swift:197-204, WhisperM8/WhisperM8App.swift:270-280). |

Statusanzeigen: Die Zeile zeigt „Granted" oder „Not granted" aus `accessibilityGranted` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:55-60). Der Primärbutton heißt bei erteilter Berechtigung „Check Again" und sonst „Grant" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:61-62). Die primäre Aktion refresht bei erteilter Berechtigung; ohne Berechtigung ruft sie `PermissionService.requestAccessibilityPermission()` auf und öffnet zusätzlich den Accessibility-Privacy-Pane (WhisperM8/Views/Settings/PermissionsSettingsView.swift:144-150). Der sekundäre „Open Settings"-Button öffnet immer `Privacy_Accessibility` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:63-64, WhisperM8/Services/Shared/PermissionService.swift:40-42).

### Screen Recording

| Aspekt | Wert |
|---|---|
| Control | `SystemPermissionRow` in der Section „Optional Visual Context" mit Icon `rectangle.dashed.badge.record`, Titel „Screen Recording", Beschreibung „Required only when you add screenshots or screen clips as context.", Statuslabel, primärem Button und sekundärem Button „Open Settings" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-79). |
| Default | Kein App-Default; die Zeile startet mit `PermissionService.hasScreenRecordingPermission` und bildet daraus `screenRecordingGranted` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:6). |
| Persistenz | macOS-TCC für Bildschirmaufnahme; Statusquelle ist `CGPreflightScreenCaptureAccess()`, Request ist `CGRequestScreenCaptureAccess()`, kein UserDefaults-Key (WhisperM8/Services/Shared/PermissionService.swift:19-21, WhisperM8/Services/Shared/PermissionService.swift:32-34). |
| Gelesen von | `PermissionsSettingsView` liest Screen Recording in `refreshPermissions()`; `VisualContextCaptureService` prüft dieselbe Permission vor Screen-Clip-Aufnahmen (WhisperM8/Views/Settings/PermissionsSettingsView.swift:162-166, WhisperM8/Services/Dictation/VisualContextCaptureService.swift:130-136). |
| Wirkung | Bildschirmaufnahme ist optional und nur für Screenshot- oder Screen-Clip-Kontext nötig; ohne diese Permission wirft Screen-Clip-Start `VisualContextCaptureError.missingPermission` mit der Meldung „Screen Recording permission is required for visual context." (WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-79, WhisperM8/Services/Dictation/VisualContextCaptureService.swift:7-21, WhisperM8/Services/Dictation/VisualContextCaptureService.swift:130-136). |
| Abhängigkeiten | Visual Context muss zusätzlich in den Behavior-Settings aktiviert sein, denn Screen Clips bleiben laut Behavior-Text weiterhin von Screen Recording abhängig (WhisperM8/Views/Settings/BehaviorSettingsView.swift:90-92). |

Statusanzeigen: Die Zeile zeigt „Granted" oder „Not granted" aus `screenRecordingGranted` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-75). Der Primärbutton heißt bei erteilter Berechtigung „Check Again" und sonst „Grant" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:75-76). Die primäre Aktion refresht bei erteilter Berechtigung; ohne Berechtigung ruft sie `PermissionService.requestScreenRecordingPermission()` auf und öffnet zusätzlich den Screen-Capture-Privacy-Pane (WhisperM8/Views/Settings/PermissionsSettingsView.swift:153-159). Der sekundäre „Open Settings"-Button öffnet immer `Privacy_ScreenCapture` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:77-78, WhisperM8/Services/Shared/PermissionService.swift:44-46).

### Hinweistext „What happens without permissions"

| Aspekt | Wert |
|---|---|
| Control | Statischer `Text` in der Section „What happens without permissions" (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-86). |
| Default | Immer sichtbar; es gibt keine State-Bedingung für diesen Hinweis (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-86). |
| Persistenz | Keine Persistenz; der Text ist hart in der View definiert (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-84). |
| Gelesen von | Nur die Settings-View rendert diesen Text; Laufzeitlogik liest stattdessen die TCC-Status über `PermissionService` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-86, WhisperM8/Services/Shared/PermissionService.swift:6-21). |
| Wirkung | Der Hinweis erklärt die Degradierung: Mikrofon fehlt -> Aufnahme startet nicht; Accessibility fehlt -> Transkription und Clipboard bleiben möglich, Auto-Paste und Selected Text Capture nicht; Screen Recording fehlt -> nur Screenshot-/Screen-Clip-Kontext betroffen (WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-84). |
| Abhängigkeiten | Die genannten Folgen passen zu den Laufzeitprüfungen in `AudioRecorder`, `PasteService`, `SelectedContextService` und `VisualContextCaptureService` (WhisperM8/Services/Dictation/AudioRecorder.swift:53-60, WhisperM8/Services/Dictation/PasteService.swift:58-66, WhisperM8/Services/Dictation/SelectedContextService.swift:25-28, WhisperM8/Services/Dictation/VisualContextCaptureService.swift:130-136). |

## 4. Datenfluss & Persistenz

Die Settings-Seite persistiert nichts selbst: Alle drei Statuswerte werden live aus macOS-TCC gelesen und in lokalen `@State`-Variablen gespiegelt (WhisperM8/Views/Settings/PermissionsSettingsView.swift:4-7, WhisperM8/Services/Shared/PermissionService.swift:7-21). Beim Erscheinen ruft die View `refreshPermissions()` auf und startet einen Timer; der Timer ruft jede Sekunde erneut `refreshPermissions()` auf, damit Änderungen in System Settings ohne Neustart sichtbar werden (WhisperM8/Views/Settings/PermissionsSettingsView.swift:89-95, WhisperM8/Views/Settings/PermissionsSettingsView.swift:168-172). Beim Verlassen der Seite wird der Timer invalidiert und auf `nil` gesetzt (WhisperM8/Views/Settings/PermissionsSettingsView.swift:93-95, WhisperM8/Views/Settings/PermissionsSettingsView.swift:175-178).

Request-Aktionen schreiben nicht in WhisperM8-Konfiguration, sondern lösen macOS-Prompts oder Privacy-Panes aus: Mikrofon nutzt `AVCaptureDevice.requestAccess`, Accessibility nutzt `AXIsProcessTrustedWithOptions`, Screen Recording nutzt `CGRequestScreenCaptureAccess`, und alle „Open Settings"-Buttons öffnen `x-apple.systempreferences:com.apple.preference.security?...` über `NSWorkspace.shared.open` (WhisperM8/Services/Shared/PermissionService.swift:23-34, WhisperM8/Services/Shared/PermissionService.swift:36-53). Die View aktualisiert den Mikrofonstatus nach einem `.notDetermined`-Request aktiv auf dem MainActor; Accessibility und Screen Recording verlassen sich nach Request und Settings-Öffnung auf Refresh/Polling (WhisperM8/Views/Settings/PermissionsSettingsView.swift:126-159, WhisperM8/Views/Settings/PermissionsSettingsView.swift:168-172).

## 5. Querverweise

Onboarding dupliziert die Pflicht-Permissions Mikrofon und Accessibility als eigenen Schritt: Es zeigt „App Permissions", erklärt „WhisperM8 needs two permissions to work properly.", rendert `PermissionRow`s für „Microphone" und „Accessibility" und pollt alle 0,5 Sekunden (WhisperM8/Views/OnboardingView.swift:350-389, WhisperM8/Views/OnboardingView.swift:406-449). Der Onboarding-Schritt blockiert „Next" und „Done", solange Mikrofon oder Accessibility fehlen (WhisperM8/Views/OnboardingView.swift:150-169). Beim App-Launch entscheidet `needsOnboarding` ebenfalls direkt anhand von `AVCaptureDevice.authorizationStatus(for: .audio)` und `AXIsProcessTrusted()`, ob das Onboarding-Fenster geöffnet wird (WhisperM8/WhisperM8App.swift:197-204, WhisperM8/WhisperM8App.swift:270-280).

Die Mikrofonberechtigung wird zur Laufzeit im `AudioRecorder` erneut angefordert; bei Ablehnung wird `RecordingError.microphonePermissionDenied` geworfen (WhisperM8/Services/Dictation/AudioRecorder.swift:53-60, WhisperM8/Services/Dictation/AudioRecorder.swift:486-495). Accessibility wird von `PasteService` für Auto-Paste geprüft und bei fehlender Berechtigung erneut angefragt; außerdem bricht `SelectedContextService` die Selected-Context-Erfassung ohne Accessibility leer ab (WhisperM8/Services/Dictation/PasteService.swift:58-66, WhisperM8/Services/Dictation/SelectedContextService.swift:25-28). Screen Recording ist mit Visual Context verknüpft: Overlay-Menüs zeigen je nach TCC-Status entweder Screen-Clip-Controls oder „Grant Screen Recording", und die Pill-Schaltfläche fordert die Permission an oder toggelt den Clip (WhisperM8/Views/RecordingOverlayView.swift:67-80, WhisperM8/Views/RecordingPillView.swift:539-570). Die Behavior-Settings erklären zusätzlich, dass Clipboard-Screenshots automatisch erfasst werden können, Screen Clips aber weiterhin Screen Recording brauchen (WhisperM8/Views/Settings/BehaviorSettingsView.swift:90-92).

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

1. Die Seite ist als Repair-Ansicht sinnvoll auffindbar, weil sie in der Settings-Gruppe „App" steht und im Header ausdrücklich sagt, dass Berechtigungen ohne erneutes Onboarding geprüft oder repariert werden können (WhisperM8/Views/SettingsView.swift:104, WhisperM8/Views/SettingsView.swift:130, WhisperM8/Views/Settings/PermissionsSettingsView.swift:25-36).

2. Es gibt deutliche Redundanz mit Onboarding: Beide Flows erklären und beantragen Mikrofon und Accessibility, aber Onboarding implementiert die Statusprüfung direkt mit `AVCaptureDevice` und `AXIsProcessTrusted`, während Settings über `PermissionService` geht (WhisperM8/Views/OnboardingView.swift:419-442, WhisperM8/Views/Settings/PermissionsSettingsView.swift:162-166, WhisperM8/Services/Shared/PermissionService.swift:7-30). Diese Redundanz ist fachlich sichtbar, weil beide Views eigene Polling-Timer besitzen, Onboarding mit 0,5 Sekunden und Settings mit 1,0 Sekunde (WhisperM8/Views/OnboardingView.swift:444-449, WhisperM8/Views/Settings/PermissionsSettingsView.swift:168-172).

3. Die Erklärtexte sind grundsätzlich verständlich, weil jede Zeile knapp den Zweck nennt und die Abschluss-Section die Folgen fehlender Berechtigungen zusammenfasst (WhisperM8/Views/Settings/PermissionsSettingsView.swift:45-46, WhisperM8/Views/Settings/PermissionsSettingsView.swift:57-58, WhisperM8/Views/Settings/PermissionsSettingsView.swift:71-72, WhisperM8/Views/Settings/PermissionsSettingsView.swift:82-84). Der Header kann aber missverständlich sein: „All system permissions are active" wird angezeigt, wenn nur Mikrofon und Accessibility erteilt sind, obwohl Screen Recording als dritte Systemberechtigung sichtbar darunter steht (WhisperM8/Views/Settings/PermissionsSettingsView.swift:13-15, WhisperM8/Views/Settings/PermissionsSettingsView.swift:25-28, WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-79).

4. Bei fehlender Permission ist das Verhalten überwiegend reparaturorientiert: nicht erteilte Rows zeigen einen prominenten Primärbutton, während erteilte Rows nur „Check Again" randlos anbieten (WhisperM8/Views/Settings/PermissionsSettingsView.swift:214-224). Mikrofon mit `.denied` oder `.restricted` öffnet direkt System Settings, Accessibility und Screen Recording fordern erst an und öffnen dann zusätzlich System Settings (WhisperM8/Views/Settings/PermissionsSettingsView.swift:126-159).

5. Screen Recording ist korrekt als optional gruppiert, aber der Produktzusammenhang liegt teils auf einer anderen Seite: Die Permission-Seite beschreibt Screenshot- und Screen-Clip-Kontext, während die Behavior-Settings die eigentliche Visual-Context-Option und die Screen-Clip-Abhängigkeit erklären (WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-79, WhisperM8/Views/Settings/BehaviorSettingsView.swift:90-92).

## 7. Offene Fragen

1. Soll die Header-Erfolgsanzeige „All system permissions are active" Screen Recording bewusst ignorieren, weil es optional ist, oder sollte der Text präziser „All required permissions are active" heißen? Der Code ignoriert Screen Recording in `allGranted`, zeigt Screen Recording aber als eigene Systemberechtigung auf derselben Seite (WhisperM8/Views/Settings/PermissionsSettingsView.swift:13-15, WhisperM8/Views/Settings/PermissionsSettingsView.swift:25-28, WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-79).

2. Soll Onboarding künftig `PermissionService` wiederverwenden, damit Statusquelle, Request-Flow und Polling nicht doppelt gepflegt werden? Onboarding nutzt aktuell direkte TCC-Calls, Settings nutzt `PermissionService` (WhisperM8/Views/OnboardingView.swift:419-442, WhisperM8/Views/Settings/PermissionsSettingsView.swift:162-166, WhisperM8/Services/Shared/PermissionService.swift:7-34).

3. Soll Screen Recording aus der Permissions-Seite heraus direkt auf die Visual-Context-Einstellungen verlinken? Der Code zeigt die Permission hier, die aktivierende Produktoption und Erklärung liegen aber in `BehaviorSettingsView` (WhisperM8/Views/Settings/PermissionsSettingsView.swift:68-79, WhisperM8/Views/Settings/BehaviorSettingsView.swift:90-92).
