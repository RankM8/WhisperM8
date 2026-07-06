---
description: Settings-Seite „Hotkey" — Referenz zur globalen Aufnahme-Tastenkombination
description_long: |
  Vollständige Referenz der Settings-Seite „Hotkey" im WhisperM8-Settings-Fenster.
  Die Seite konfiguriert genau den globalen Recording-Shortcut `.toggleRecording`,
  dessen Speicherung das KeyboardShortcuts-Package in `UserDefaults` übernimmt.
updated: 2026-07-06 10:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 0 Mängel)
---

# Settings: Hotkey

> **Sidebar-Gruppe:** App · **View:** `WhisperM8/Views/Settings/HotkeySettingsView.swift` · **Enum-Case:** `ControlCenterSection.hotkey` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `HotkeySettingsView.swift` (KeyboardShortcuts-Package), Hotkey-Registrierung im Code suchen

## 1. Zweck & Überblick

Die Seite konfiguriert die globale Tastenkombination, mit der WhisperM8 eine Aufnahme startet und später stoppt; die View besteht aus einem `KeyboardShortcuts.Recorder` für `.toggleRecording` und einem erklärenden Caption-Text. (`WhisperM8/Views/Settings/HotkeySettingsView.swift:6`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:8`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:11`)

Der konfigurierte Shortcut wird nicht in `AppPreferences` verwaltet, sondern vom eingebundenen SwiftPM-Package `KeyboardShortcuts` gespeichert; WhisperM8 pinnt dieses Package auf Version `1.16.1`. (`Package.swift:13`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:21`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:28`)

Der einzige statisch definierte `KeyboardShortcuts.Name` in WhisperM8 ist `.toggleRecording` mit dem Raw Value `toggleRecording`; daraus entsteht der UserDefaults-Key `KeyboardShortcuts_toggleRecording`. (`WhisperM8/WhisperM8App.swift:402`, `WhisperM8/WhisperM8App.swift:403`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:410`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:412`)

## 2. UI-Aufbau

Die Seite ist ein gruppierter SwiftUI-`Form` mit genau einer `Section`; darin stehen zuerst der Recorder mit Label `Recording Hotkey:` und danach ein sekundärer Caption-Text. (`WhisperM8/Views/Settings/HotkeySettingsView.swift:5`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:6`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:7`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:8`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:11`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:12`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:13`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:16`)

Die Sidebar führt `ControlCenterSection.hotkey` als App-Sektion mit Titel `Hotkey`, Route `hotkey` und SF Symbol `keyboard`; die Detailansicht rendert dafür `HotkeySettingsView()` und setzt den Navigationstitel auf den Raw Value. (`WhisperM8/Views/SettingsView.swift:14`, `WhisperM8/Views/SettingsView.swift:44`, `WhisperM8/Views/SettingsView.swift:45`, `WhisperM8/Views/SettingsView.swift:83`, `WhisperM8/Views/SettingsView.swift:104`, `WhisperM8/Views/SettingsView.swift:130`, `WhisperM8/Views/SettingsView.swift:232`, `WhisperM8/Views/SettingsView.swift:233`, `WhisperM8/Views/SettingsView.swift:234`)

Es gibt keine bedingte Sichtbarkeit auf dieser Seite: `HotkeySettingsView` enthält keinen lokalen State, kein Environment und keine `if`-Verzweigung. (`WhisperM8/Views/Settings/HotkeySettingsView.swift:4`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:5`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:18`)

## 3. Optionen im Detail

### Recording Hotkey

| Aspekt | Wert |
|---|---|
| Control | `KeyboardShortcuts.Recorder("Recording Hotkey:", name: .toggleRecording)` als SwiftUI-Recorder-Control des `KeyboardShortcuts`-Packages. (`WhisperM8/Views/Settings/HotkeySettingsView.swift:8`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:21`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:28`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:116`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:118`) |
| Default | Kein App-Default: `.toggleRecording` wird als `Self("toggleRecording")` ohne `default:`-Argument definiert, und `KeyboardShortcuts.Name` hat `default initialShortcut: Shortcut? = nil`. (`WhisperM8/WhisperM8App.swift:402`, `WhisperM8/WhisperM8App.swift:403`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Name.swift:38`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Name.swift:40`) |
| Persistenz | `UserDefaults.standard` über das KeyboardShortcuts-Package; exakter Key: `KeyboardShortcuts_toggleRecording`. Der Key entsteht aus Prefix `KeyboardShortcuts_` plus Raw Value `toggleRecording`, und der gespeicherte Wert ist ein JSON-codierter `KeyboardShortcuts.Shortcut`-String. (`WhisperM8/WhisperM8App.swift:403`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:410`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:412`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:420`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:421`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:430`) |
| Gelesen von | Runtime-Handler: `WhisperM8App.setupHotkeys()` registriert `onKeyDown` und `onKeyUp` für `.toggleRecording`. Menüleiste: `MenuBarView` liest und zeigt den Shortcut. Onboarding: `HotkeyStep` und Abschlussbildschirm lesen denselben Shortcut. (`WhisperM8/WhisperM8App.swift:101`, `WhisperM8/WhisperM8App.swift:102`, `WhisperM8/WhisperM8App.swift:108`, `WhisperM8/Views/MenuBarView.swift:59`, `WhisperM8/Views/MenuBarView.swift:60`, `WhisperM8/Views/OnboardingView.swift:522`, `WhisperM8/Views/OnboardingView.swift:550`, `WhisperM8/Views/OnboardingView.swift:743`, `WhisperM8/Views/OnboardingView.swift:744`) |
| Wirkung | `KeyDown` startet `AppState.shared.startRecording()`, `KeyUp` ruft `AppState.shared.stopRecording()` auf; ein Stop innerhalb von 0,3 Sekunden wird im Coordinator ignoriert, damit ein kurzer Tap die Aufnahme startet statt sie sofort wieder zu stoppen. (`WhisperM8/WhisperM8App.swift:102`, `WhisperM8/WhisperM8App.swift:104`, `WhisperM8/WhisperM8App.swift:108`, `WhisperM8/WhisperM8App.swift:110`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:257`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:259`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:260`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:267`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:269`) |
| Abhängigkeiten | Das Package pausiert die globale Auslösung während der Recorder-Fokussierung und behandelt Konflikte mit System- oder App-Menü-Shortcuts; WhisperM8 selbst koppelt keine weitere Setting-Option direkt an den Recorder. (`.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:26`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:28`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/RecorderCocoa.swift:210`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/RecorderCocoa.swift:213`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:4`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:18`) |

## 4. Datenfluss & Persistenz

Beim App-Start ruft `WhisperM8App.init()` einmal `setupHotkeys()` auf; dort werden `onKeyDown` und `onKeyUp` für `.toggleRecording` registriert. (`WhisperM8/WhisperM8App.swift:15`, `WhisperM8/WhisperM8App.swift:27`, `WhisperM8/WhisperM8App.swift:101`, `WhisperM8/WhisperM8App.swift:102`, `WhisperM8/WhisperM8App.swift:108`)

Die Registrierung ist auch dann erlaubt, wenn der User noch keinen Shortcut gesetzt hat; das Package hängt Handler an und registriert den Carbon-Shortcut nur, wenn `getShortcut(for:)` einen Wert liefert. (`.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:379`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:380`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:381`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:389`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:405`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:406`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:407`)

Speichern passiert sofort im Recorder, weil `KeyboardShortcuts.setShortcut(_:for:)` auf `userDefaultsSet` oder Entfernen/Deaktivieren routet; Lesen passiert über `UserDefaults.standard.string(forKey:)` und JSON-Decoding. (`.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:280`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:282`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:287`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:295`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:297`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:298`)

Nach einer Änderung postet das Package `.shortcutByNameDidChange`; die Cocoa-Recorder-View beobachtet diese Notification und aktualisiert die angezeigte Zeichenfolge. (`.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:415`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:417`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:431`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/RecorderCocoa.swift:121`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/RecorderCocoa.swift:122`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/RecorderCocoa.swift:131`)

Ein Neustart ist für die Anzeige nicht nötig, weil `MenuBarView` den aktuellen Shortcut mit `KeyboardShortcuts.getShortcut(for: .toggleRecording)` liest und die Recorder-View per Notification aktualisiert wird. (`WhisperM8/Views/MenuBarView.swift:59`, `WhisperM8/Views/MenuBarView.swift:60`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/RecorderCocoa.swift:121`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/RecorderCocoa.swift:131`)

## 5. Querverweise

Onboarding nutzt denselben Recorder-Namen `.toggleRecording`, zeigt aber das Label `Recording key:` und empfiehlt `Control + Shift + Space`, obwohl die Settings-Seite keinen Default setzt. (`WhisperM8/Views/OnboardingView.swift:518`, `WhisperM8/Views/OnboardingView.swift:522`, `WhisperM8/Views/OnboardingView.swift:533`, `WhisperM8/WhisperM8App.swift:403`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Name.swift:38`)

Die Menüleiste zeigt entweder `Hotkey: <Shortcut>` oder `No hotkey configured`; sie schreibt den Shortcut nicht, sondern liest denselben Package-Wert. (`WhisperM8/Views/MenuBarView.swift:59`, `WhisperM8/Views/MenuBarView.swift:60`, `WhisperM8/Views/MenuBarView.swift:63`, `WhisperM8/Views/MenuBarView.swift:64`)

Die Behavior-Seite enthält die wichtigste hotkey-nahe Option: `Show Confirm Button (✓)` in der Recording-Overlay-Sektion, deren Hilfetext ausdrücklich sagt, dass der Button Aufnahme stoppt und Transkription startet wie der Hotkey. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:115`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:123`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:125`)

Der Confirm-Button landet technisch im gleichen Stop-Pfad, weil `presentOverlay` seinen `onStopAndTranscribe`-Callback auf `stopRecording()` routet. (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:194`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:207`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:208`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:211`)

Audio Ducking liegt ebenfalls auf der Behavior-Seite und wirkt während einer laufenden Aufnahme, also in der Praxis auch nach Hotkey-Start; das Control reduziert die Systemlautstärke während `recording`. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:102`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:103`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:109`)

Die Permissions-Seite ist für Hotkey-Nutzung relevant, weil ohne Mikrofonzugriff keine Aufnahme starten kann; Accessibility ist für Auto-Paste und Selected-Text-Capture nötig, nicht für reines Transkribieren. (`WhisperM8/Views/Settings/PermissionsSettingsView.swift:82`, `WhisperM8/Views/Settings/PermissionsSettingsView.swift:83`)

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

Die Seite ist so klein, weil das externe Recorder-Control Aufnahme, Anzeige, Konfliktwarnung und UserDefaults-Persistenz kapselt; WhisperM8 stellt auf der Seite nur den Recorder und einen erklärenden Text bereit. (`WhisperM8/Views/Settings/HotkeySettingsView.swift:6`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:8`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:11`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:21`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:26`, `.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:28`)

Die fachliche Komplexität liegt nicht in der Settings-Seite, sondern in der App-Initialisierung und im Recording-Coordinator: `KeyDown` startet, `KeyUp` stoppt, und der Coordinator schützt kurze Taps mit der 0,3-Sekunden-Regel. (`WhisperM8/WhisperM8App.swift:101`, `WhisperM8/WhisperM8App.swift:102`, `WhisperM8/WhisperM8App.swift:108`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:257`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:260`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:267`)

Hotkey-nahe Optionen sind verstreut: Der alternative Stop-Mechanismus `Show Confirm Button (✓)` liegt unter `Behavior` statt auf der Hotkey-Seite, und Audio Ducking liegt ebenfalls dort, obwohl es unmittelbar mit dem Start einer Aufnahme zusammenhängt. (`WhisperM8/Views/SettingsView.swift:16`, `WhisperM8/Views/SettingsView.swift:238`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:97`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:98`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:115`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:123`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:125`)

Onboarding und Settings verwenden unterschiedliche Labels für denselben Wert: Onboarding sagt `Recording key:`, die Settings-Seite sagt `Recording Hotkey:`; beide schreiben `.toggleRecording`. (`WhisperM8/Views/OnboardingView.swift:522`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:8`, `WhisperM8/WhisperM8App.swift:403`)

Es gibt sichtbaren Sprachmix in der Oberfläche: Sidebar-Gruppe und Seitentitel sind Englisch (`App`, `Hotkey`), der Recorder- und Hilfetext sind Englisch, und die Onboarding-Empfehlung ist ebenfalls Englisch. (`WhisperM8/Views/SettingsView.swift:14`, `WhisperM8/Views/SettingsView.swift:104`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:8`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:11`, `WhisperM8/Views/OnboardingView.swift:533`)

Die Settings-Seite erklärt die Tap-to-toggle-Semantik knapp, aber sie zeigt weder die interne KeyDown/KeyUp-Logik noch den Schutz gegen Sofort-Stopp; diese Details sind nur im Coordinator-Kommentar sichtbar. (`WhisperM8/Views/Settings/HotkeySettingsView.swift:11`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:260`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:261`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:267`)

## 7. Offene Fragen

- Ob ein echter Push-to-Talk-Modus geplant ist, lässt sich aus dem aktuellen Code nicht ableiten; statisch definiert ist nur `.toggleRecording`. (`WhisperM8/WhisperM8App.swift:402`, `WhisperM8/WhisperM8App.swift:403`)
- Ob die Onboarding-Empfehlung `Control + Shift + Space` auch in den Settings erscheinen soll, ist offen, weil Onboarding diese Empfehlung zeigt und Settings keinen Default- oder Empfehlungstext enthalten. (`WhisperM8/Views/OnboardingView.swift:533`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:8`, `WhisperM8/Views/Settings/HotkeySettingsView.swift:11`)
- Ob `Show Confirm Button (✓)` als hotkey-nahe Option auf die Hotkey-Seite gehört, ist eine Redesign-Frage, weil Behavior den Button beschreibt und der Coordinator ihn auf denselben Stop-Pfad wie den Hotkey routet. (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:123`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:125`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:207`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:211`)
