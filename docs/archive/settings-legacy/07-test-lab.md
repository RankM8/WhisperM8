---
description: Settings-Seite „Test Lab" — Referenz zum manuellen Testen von Output-Modi und Post-Processing
description_long: |
  Vollständige Referenz der Settings-Seite „Test Lab": Zweck, UI-Aufbau,
  alle sichtbaren Controls mit Default, Persistenz und Code-Wirkung, Datenfluss,
  Querverweise sowie UX-Beobachtungen als Grundlage für das Settings-Redesign.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, Formulierung präzisiert)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `AIOutputSettingsPage.swift` / `AIOutputTestLabTab.swift` + Doku-Verweis [ARCHITEKTUR: Pages](../../features/settings/ARCHITECTURE.md#pages).

# Settings: Test Lab

> **Sidebar-Gruppe:** Output · **View:** `WhisperM8/Views/OutputTestLabView.swift` · **Enum-Case:** `ControlCenterSection.testLab` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `OutputTestLabView.swift`

## 1. Zweck & Überblick

Das Test Lab ist eine manuelle Probeoberfläche für Output-Modi: Nutzer geben Rohtext ein, wählen einen aktivierten Output-Modus und lassen daraus eine Vorschau berechnen (`WhisperM8/Views/OutputTestLabView.swift:14`, `WhisperM8/Views/OutputTestLabView.swift:21`, `WhisperM8/Views/OutputTestLabView.swift:27`, `WhisperM8/Views/OutputTestLabView.swift:54`). Die Seite transkribiert nicht selbst, sondern übergibt den eingegebenen Text nach Normalisierung an `PostProcessingService` (`WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:71`). Für jeden Modus entscheidet `mode.usesPostProcessing` (false nur bei `kind == .raw`, also „Fast"), ob der No-Op-Pfad ohne Codex oder der Codex-Post-Processor läuft (`WhisperM8/Models/OutputMode.swift:29`, `WhisperM8/Services/Dictation/PostProcessingService.swift:17`, `WhisperM8/Services/Dictation/PostProcessingService.swift:31`). Ergebnisse bleiben im View-State und werden nur per Copy-Button in die macOS-Zwischenablage geschrieben (`WhisperM8/Views/OutputTestLabView.swift:8`, `WhisperM8/Views/OutputTestLabView.swift:34`, `WhisperM8/Views/OutputTestLabView.swift:36`).

## 2. UI-Aufbau

Oben steht ein segmentierter Picker mit dem Label „Mode"; er rendert alle aktivierten Output-Modi über `OutputMode.enabledBuiltInModes` und zeigt deren `mode.name` an (`WhisperM8/Views/OutputTestLabView.swift:14`, `WhisperM8/Views/OutputTestLabView.swift:15`, `WhisperM8/Views/OutputTestLabView.swift:16`, `WhisperM8/Views/OutputTestLabView.swift:19`). Darunter liegt ein unbeschrifteter `TextEditor` für den Rohtext mit Mindesthöhe 160 pt (`WhisperM8/Views/OutputTestLabView.swift:21`, `WhisperM8/Views/OutputTestLabView.swift:24`). Danach folgt eine horizontale Button-Zeile mit „Preview", „Copy", optionalem `ProgressView` während der Verarbeitung und einem Spacer (`WhisperM8/Views/OutputTestLabView.swift:26`, `WhisperM8/Views/OutputTestLabView.swift:27`, `WhisperM8/Views/OutputTestLabView.swift:34`, `WhisperM8/Views/OutputTestLabView.swift:40`, `WhisperM8/Views/OutputTestLabView.swift:45`). Fehler erscheinen unter der Button-Zeile als orange Caption, sobald `errorMessage` gesetzt ist (`WhisperM8/Views/OutputTestLabView.swift:48`, `WhisperM8/Views/OutputTestLabView.swift:50`, `WhisperM8/Views/OutputTestLabView.swift:51`). Unten steht ein zweiter unbeschrifteter `TextEditor` für die Vorschau mit Mindesthöhe 180 pt (`WhisperM8/Views/OutputTestLabView.swift:54`, `WhisperM8/Views/OutputTestLabView.swift:57`). Die Seite setzt den Navigationstitel auf „Test Lab" und wird im Settings-Detail für `.testLab` gerendert (`WhisperM8/Views/OutputTestLabView.swift:60`, `WhisperM8/Views/SettingsView.swift:221`, `WhisperM8/Views/SettingsView.swift:222`).

## 3. Optionen im Detail

### Mode

| Aspekt | Wert |
|---|---|
| Control | Segmentierter `Picker("Mode", selection: $selectedModeID)` (`WhisperM8/Views/OutputTestLabView.swift:14`, `WhisperM8/Views/OutputTestLabView.swift:19`). |
| Default | `selectedModeID` startet mit `OutputMode.rawID`; `rawID` ist `"raw"` und der Built-in-Modus dazu heißt „Fast" (`WhisperM8/Views/OutputTestLabView.swift:7`, `WhisperM8/Models/OutputMode.swift:127`, `WhisperM8/Models/OutputMode.swift:139`, `WhisperM8/Models/OutputMode.swift:140`). |
| Persistenz | Keine Persistenz für die Auswahl im Test Lab, weil `selectedModeID` ein lokaler `@State`-Wert ist (`WhisperM8/Views/OutputTestLabView.swift:7`). Die auswählbaren Modi selbst kommen aus `OutputModeStore().enabledModes`; der Store liest `~/Library/Application Support/WhisperM8/OutputModes.json` und fällt bei leerem Load auf Built-ins zurück (`WhisperM8/Models/OutputMode.swift:248`, `WhisperM8/Models/OutputMode.swift:249`, `WhisperM8/Services/Dictation/OutputModeStore.swift:64`, `WhisperM8/Services/Dictation/OutputModeStore.swift:67`, `WhisperM8/Services/Dictation/OutputModeStore.swift:194`, `WhisperM8/Services/Dictation/OutputModeStore.swift:201`). |
| Gelesen von | `OutputTestLabView` rendert die Optionen über `OutputMode.enabledBuiltInModes` und löst die Auswahl vor dem Preview über `OutputMode.mode(for:)` auf (`WhisperM8/Views/OutputTestLabView.swift:15`, `WhisperM8/Views/OutputTestLabView.swift:68`). |
| Wirkung | Der ausgewählte Modus bestimmt, ob `PostProcessingService` direkt `NoOpPostProcessor` nutzt oder an den konfigurierten Processor weitergibt (`WhisperM8/Services/Dictation/PostProcessingService.swift:17`, `WhisperM8/Services/Dictation/PostProcessingService.swift:18`, `WhisperM8/Services/Dictation/PostProcessingService.swift:31`). |
| Abhängigkeiten | Sichtbarkeit hängt von `mode.isEnabled` ab, weil `enabledModes` die Modi filtert (`WhisperM8/Services/Dictation/OutputModeStore.swift:72`, `WhisperM8/Services/Dictation/OutputModeStore.swift:73`). Änderungen an Modi werden in der Modes-Seite gespeichert, die bei `modes`-Änderungen `saveModes()` ausführt (`WhisperM8/Views/OutputModesView.swift:121`, `WhisperM8/Views/OutputModesView.swift:122`, `WhisperM8/Views/OutputModesView.swift:359`, `WhisperM8/Views/OutputModesView.swift:361`). |

### Rohtext-Eingabe

| Aspekt | Wert |
|---|---|
| Control | Unbeschrifteter `TextEditor(text: $rawText)` mit `.font(.body)`, Border und Mindesthöhe 160 pt (`WhisperM8/Views/OutputTestLabView.swift:21`, `WhisperM8/Views/OutputTestLabView.swift:22`, `WhisperM8/Views/OutputTestLabView.swift:23`, `WhisperM8/Views/OutputTestLabView.swift:24`). |
| Default | Leerstring, weil `rawText` als `@State private var rawText = ""` initialisiert wird (`WhisperM8/Views/OutputTestLabView.swift:6`). |
| Persistenz | Keine Persistenz; der eingegebene Rohtext ist lokaler `@State` (`WhisperM8/Views/OutputTestLabView.swift:6`). |
| Gelesen von | Der Preview-Button deaktiviert sich bei leerem getrimmtem `rawText`, und `runPreview()` normalisiert denselben Wert vor der Übergabe an `PostProcessingService` (`WhisperM8/Views/OutputTestLabView.swift:32`, `WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:71`). |
| Wirkung | Vor dem Processing entfernt `TextNormalizer.normalizeTranscriptionText` Whitespace, Newlines, Control-Characters und mehrere unsichtbare Unicode-Trenner an den Rändern (`WhisperM8/Support/TextNormalizer.swift:4`, `WhisperM8/Support/TextNormalizer.swift:5`, `WhisperM8/Support/TextNormalizer.swift:7`, `WhisperM8/Support/TextNormalizer.swift:9`). |
| Abhängigkeiten | Das Feld hat keine direkte Abhängigkeit zu Transkriptionsprovider oder Audioaufnahme, weil `runPreview()` den Text direkt aus `rawText` liest und an Post-Processing übergibt (`WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:71`). |

### Preview

| Aspekt | Wert |
|---|---|
| Control | `Button("Preview")`, der in einem `Task` asynchron `runPreview()` startet (`WhisperM8/Views/OutputTestLabView.swift:27`, `WhisperM8/Views/OutputTestLabView.swift:28`, `WhisperM8/Views/OutputTestLabView.swift:29`). |
| Default | Aktiv, sobald `rawText.trimmingCharacters(in: .whitespacesAndNewlines)` nicht leer ist und `isProcessing` false ist; beim Start ist `isProcessing` false (`WhisperM8/Views/OutputTestLabView.swift:10`, `WhisperM8/Views/OutputTestLabView.swift:32`). |
| Persistenz | Keine Persistenz für den Button-Zustand; `isProcessing` und `errorMessage` sind lokale `@State`-Werte (`WhisperM8/Views/OutputTestLabView.swift:9`, `WhisperM8/Views/OutputTestLabView.swift:10`). |
| Gelesen von | Der Button liest `rawText` und `isProcessing` für `.disabled(...)`; der Handler ruft `runPreview()` auf (`WhisperM8/Views/OutputTestLabView.swift:27`, `WhisperM8/Views/OutputTestLabView.swift:29`, `WhisperM8/Views/OutputTestLabView.swift:32`). |
| Wirkung | `runPreview()` setzt `isProcessing = true`, leert `errorMessage`, löst den Modus auf, ruft `PostProcessingService().process(...)` auf und schreibt das Ergebnis in `previewText` (`WhisperM8/Views/OutputTestLabView.swift:65`, `WhisperM8/Views/OutputTestLabView.swift:66`, `WhisperM8/Views/OutputTestLabView.swift:68`, `WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:75`). |
| Abhängigkeiten | Der Lauf verwendet `AppPreferences.shared.language`; diese Preference liest `UserDefaults`-Key `language` mit Default `"de"` (`WhisperM8/Views/OutputTestLabView.swift:73`, `WhisperM8/Support/AppPreferences.swift:36`, `WhisperM8/Support/AppPreferences.swift:37`, `WhisperM8/Support/AppPreferences.swift:359`). |

### Copy

| Aspekt | Wert |
|---|---|
| Control | `Button("Copy")`, der die allgemeine `NSPasteboard` leert und `previewText` als `.string` setzt (`WhisperM8/Views/OutputTestLabView.swift:34`, `WhisperM8/Views/OutputTestLabView.swift:35`, `WhisperM8/Views/OutputTestLabView.swift:36`). |
| Default | Deaktiviert, solange `previewText.isEmpty` true ist; `previewText` startet als Leerstring (`WhisperM8/Views/OutputTestLabView.swift:8`, `WhisperM8/Views/OutputTestLabView.swift:38`). |
| Persistenz | Keine App-Persistenz; der Button schreibt nur in die macOS-Zwischenablage (`WhisperM8/Views/OutputTestLabView.swift:35`, `WhisperM8/Views/OutputTestLabView.swift:36`). |
| Gelesen von | Der Button liest `previewText` für Pasteboard-Inhalt und Disabled-State (`WhisperM8/Views/OutputTestLabView.swift:36`, `WhisperM8/Views/OutputTestLabView.swift:38`). |
| Wirkung | Der aktuelle Vorschautext wird systemweit kopierbar, ohne `OutputHistory` oder andere App-Dateien zu schreiben (`WhisperM8/Views/OutputTestLabView.swift:35`, `WhisperM8/Views/OutputTestLabView.swift:36`). |
| Abhängigkeiten | Der Button hängt nur davon ab, ob `previewText` leer ist; `previewText` wird bei Erfolg, Fallback oder Fehlerpfad durch `runPreview()` gesetzt oder geleert (`WhisperM8/Views/OutputTestLabView.swift:75`, `WhisperM8/Views/OutputTestLabView.swift:78`, `WhisperM8/Views/OutputTestLabView.swift:81`). |

### Verarbeitungsindikator

| Aspekt | Wert |
|---|---|
| Control | Optionaler `ProgressView` mit `.controlSize(.small)`, sichtbar innerhalb der Button-Zeile (`WhisperM8/Views/OutputTestLabView.swift:40`, `WhisperM8/Views/OutputTestLabView.swift:41`, `WhisperM8/Views/OutputTestLabView.swift:42`). |
| Default | Unsichtbar, weil `isProcessing` als `false` startet (`WhisperM8/Views/OutputTestLabView.swift:10`, `WhisperM8/Views/OutputTestLabView.swift:40`). |
| Persistenz | Keine Persistenz; `isProcessing` ist lokaler `@State` (`WhisperM8/Views/OutputTestLabView.swift:10`). |
| Gelesen von | Der `if isProcessing`-Block liest denselben State wie der Preview-Button-Disabled-State (`WhisperM8/Views/OutputTestLabView.swift:32`, `WhisperM8/Views/OutputTestLabView.swift:40`). |
| Wirkung | Der Indikator signalisiert den laufenden async Preview-Aufruf; `runPreview()` setzt `isProcessing` am Anfang auf true und am Ende auf false (`WhisperM8/Views/OutputTestLabView.swift:65`, `WhisperM8/Views/OutputTestLabView.swift:86`). |
| Abhängigkeiten | Sichtbarkeit hängt ausschließlich vom lokalen Processing-State ab (`WhisperM8/Views/OutputTestLabView.swift:10`, `WhisperM8/Views/OutputTestLabView.swift:40`). |

### Fehlermeldung

| Aspekt | Wert |
|---|---|
| Control | Bedingter `Text(errorMessage)` als Caption in Orange (`WhisperM8/Views/OutputTestLabView.swift:48`, `WhisperM8/Views/OutputTestLabView.swift:49`, `WhisperM8/Views/OutputTestLabView.swift:50`, `WhisperM8/Views/OutputTestLabView.swift:51`). |
| Default | Unsichtbar, weil `errorMessage` als optionaler `@State` mit `nil` startet (`WhisperM8/Views/OutputTestLabView.swift:9`, `WhisperM8/Views/OutputTestLabView.swift:48`). |
| Persistenz | Keine Persistenz; `errorMessage` ist lokaler `@State` (`WhisperM8/Views/OutputTestLabView.swift:9`). |
| Gelesen von | Der Fehlertext wird nur vom bedingten `if let errorMessage`-Block gelesen (`WhisperM8/Views/OutputTestLabView.swift:48`, `WhisperM8/Views/OutputTestLabView.swift:49`). |
| Wirkung | Bei Preview-Start wird die Meldung geleert; bei Fehler zeigt sie entweder die Fehlerbeschreibung plus „Showing Raw fallback." oder nur die Fehlerbeschreibung (`WhisperM8/Views/OutputTestLabView.swift:66`, `WhisperM8/Views/OutputTestLabView.swift:79`, `WhisperM8/Views/OutputTestLabView.swift:82`). |
| Abhängigkeiten | Der Fallback-Pfad hängt vom UserDefaults-Key `fallbackToRawOnProcessingError` ab, den die View per `@AppStorage` liest und der in `AppPreferences` mit Default true definiert ist (`WhisperM8/Views/OutputTestLabView.swift:5`, `WhisperM8/Support/AppPreferences.swift:94`, `WhisperM8/Support/AppPreferences.swift:95`, `WhisperM8/Support/AppPreferences.swift:370`). |

### Vorschau-Ausgabe

| Aspekt | Wert |
|---|---|
| Control | Unbeschrifteter `TextEditor(text: $previewText)` mit `.font(.body)`, Border und Mindesthöhe 180 pt (`WhisperM8/Views/OutputTestLabView.swift:54`, `WhisperM8/Views/OutputTestLabView.swift:55`, `WhisperM8/Views/OutputTestLabView.swift:56`, `WhisperM8/Views/OutputTestLabView.swift:57`). |
| Default | Leerstring, weil `previewText` als `@State private var previewText = ""` initialisiert wird (`WhisperM8/Views/OutputTestLabView.swift:8`). |
| Persistenz | Keine Persistenz; die Vorschau ist lokaler `@State` und wird nicht über einen Store geschrieben (`WhisperM8/Views/OutputTestLabView.swift:8`, `WhisperM8/Views/OutputTestLabView.swift:75`, `WhisperM8/Views/OutputTestLabView.swift:78`, `WhisperM8/Views/OutputTestLabView.swift:81`). |
| Gelesen von | Das Textfeld bindet direkt an `previewText`; der Copy-Button liest denselben State (`WhisperM8/Views/OutputTestLabView.swift:54`, `WhisperM8/Views/OutputTestLabView.swift:36`). |
| Wirkung | Bei erfolgreichem Post-Processing enthält das Feld den Output von `PostProcessingService`; bei aktiviertem Fehler-Fallback enthält es den normalisierten Rohtext; bei deaktiviertem Fehler-Fallback wird es geleert (`WhisperM8/Views/OutputTestLabView.swift:75`, `WhisperM8/Views/OutputTestLabView.swift:78`, `WhisperM8/Views/OutputTestLabView.swift:81`). |
| Abhängigkeiten | Inhalt und Qualität hängen vom gewählten Modus, der Sprache und den zugeordneten Templates ab; `CodexPostProcessor` lädt das Template über `templateStore.template(for: mode.templateID)` und baut daraus mit Sprache und Kontext das Prompt-Package (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:21`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:33`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:37`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:38`). |

## 4. Datenfluss & Persistenz

Beim Öffnen initialisiert SwiftUI die lokalen States `rawText`, `selectedModeID`, `previewText`, `errorMessage` und `isProcessing`; nur `fallbackToRawOnProcessingError` kommt direkt aus `@AppStorage` (`WhisperM8/Views/OutputTestLabView.swift:5`, `WhisperM8/Views/OutputTestLabView.swift:6`, `WhisperM8/Views/OutputTestLabView.swift:7`, `WhisperM8/Views/OutputTestLabView.swift:8`, `WhisperM8/Views/OutputTestLabView.swift:9`, `WhisperM8/Views/OutputTestLabView.swift:10`). Der Mode-Picker liest aktivierte Modi live aus `OutputMode.enabledBuiltInModes`, das auf `OutputModeStore().enabledModes` zeigt (`WhisperM8/Views/OutputTestLabView.swift:15`, `WhisperM8/Models/OutputMode.swift:248`, `WhisperM8/Models/OutputMode.swift:249`). `OutputModeStore` lädt Modi aus `OutputModes.json`, ergänzt fehlende Built-ins und normalisiert den Raw/Fast-Modus (`WhisperM8/Services/Dictation/OutputModeStore.swift:64`, `WhisperM8/Services/Dictation/OutputModeStore.swift:67`, `WhisperM8/Services/Dictation/OutputModeStore.swift:69`, `WhisperM8/Services/Dictation/OutputModeStore.swift:157`, `WhisperM8/Services/Dictation/OutputModeStore.swift:161`). Beim Klick auf „Preview" wird der Rohtext normalisiert, der aktuelle Modus aufgelöst und die gespeicherte Sprache gelesen (`WhisperM8/Views/OutputTestLabView.swift:68`, `WhisperM8/Views/OutputTestLabView.swift:71`, `WhisperM8/Views/OutputTestLabView.swift:73`). `PostProcessingService` nutzt bei `mode.usesPostProcessing == false` den `NoOpPostProcessor`; sonst ruft er den injizierten Processor auf, dessen Default `CodexPostProcessor()` ist (`WhisperM8/Services/Dictation/PostProcessingService.swift:7`, `WhisperM8/Services/Dictation/PostProcessingService.swift:17`, `WhisperM8/Services/Dictation/PostProcessingService.swift:18`, `WhisperM8/Services/Dictation/PostProcessingService.swift:31`). Das Test Lab übergibt keinen ausgewählten Kontext, weil der `contextBundle`-Parameter mit `.empty` defaultet und der View-Aufruf ihn nicht setzt (`WhisperM8/Services/Dictation/PostProcessingService.swift:15`, `WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:74`). Persistiert werden durch die Test-Lab-Seite keine Ergebnisse; sichtbare Ausgaben landen in `previewText`, und nur der Copy-Button schreibt in die System-Zwischenablage (`WhisperM8/Views/OutputTestLabView.swift:75`, `WhisperM8/Views/OutputTestLabView.swift:78`, `WhisperM8/Views/OutputTestLabView.swift:81`, `WhisperM8/Views/OutputTestLabView.swift:35`, `WhisperM8/Views/OutputTestLabView.swift:36`).

## 5. Querverweise

Die Seite ist in der Settings-Sidebar der Gruppe „Output" zugeordnet; dieselbe Gruppe enthält Output Overview, History, Modes und Templates (`WhisperM8/Views/SettingsView.swift:100`, `WhisperM8/Views/SettingsView.swift:128`). Die Mode-Liste und Sichtbarkeit werden auf der Modes-Seite gepflegt; dort existieren `modes`, `templates`, `selectedModeID`, `defaultOutputModeID`, `showModePickerInMiniOverlay` und `fallbackToRawOnProcessingError` als States/AppStorage-Werte (`WhisperM8/Views/OutputModesView.swift:4`, `WhisperM8/Views/OutputModesView.swift:5`, `WhisperM8/Views/OutputModesView.swift:6`, `WhisperM8/Views/OutputModesView.swift:8`, `WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Views/OutputModesView.swift:12`). Die Templates-Seite teilt sich den `PostProcessingTemplateStore`, der Built-in-Templates plus `PostProcessingTemplates.json` lädt (`WhisperM8/Views/OutputTemplatesView.swift:4`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:14`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:15`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:58`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:65`). Die Sprache kommt von der API-Settings-Seite über `@AppStorage("language")`; dort bietet der Picker „German", „English" und „Auto-detect" an (`WhisperM8/Views/Settings/APISettingsView.swift:6`, `WhisperM8/Views/Settings/APISettingsView.swift:68`, `WhisperM8/Views/Settings/APISettingsView.swift:69`, `WhisperM8/Views/Settings/APISettingsView.swift:70`, `WhisperM8/Views/Settings/APISettingsView.swift:71`). Die echte Diktat-Hot-Path-Verarbeitung nutzt denselben Fallback-Key über `AppPreferences.shared.fallbackToRawOnProcessingError`, aber sie läuft in `RecordingCoordinator+Transcription` statt in der Test-Lab-View (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:236`, `WhisperM8/Views/OutputTestLabView.swift:77`).

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

Der Zweck „Test Lab" ist für technisch geprägte Nutzer erkennbar, weil die Seite nur Mode, Rohtext, Preview und Output anbietet; für normale Settings-Nutzer fehlen jedoch sichtbare Labels für beide Textfelder und ein kurzer Hinweis, dass keine Aufnahme/Transkription gestartet wird (`WhisperM8/Views/OutputTestLabView.swift:14`, `WhisperM8/Views/OutputTestLabView.swift:21`, `WhisperM8/Views/OutputTestLabView.swift:27`, `WhisperM8/Views/OutputTestLabView.swift:54`). Die Verortung in der Output-Gruppe ist fachlich plausibel, weil das Test Lab Output-Modi, Templates, Sprache und Post-Processing testet und neben Output Overview, History, Modes und Templates einsortiert ist (`WhisperM8/Views/SettingsView.swift:100`, `WhisperM8/Views/SettingsView.swift:128`, `WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:73`). Die Seite mischt englische UI-Begriffe und deutsche Systemmeldungen aus angrenzenden Services: „Test Lab", „Mode", „Preview", „Copy" und „Showing Raw fallback." stehen englisch in der View, während `PostProcessingError.userCancelled` deutsch „Codex wurde abgebrochen." liefert (`WhisperM8/Views/OutputTestLabView.swift:27`, `WhisperM8/Views/OutputTestLabView.swift:34`, `WhisperM8/Views/OutputTestLabView.swift:60`, `WhisperM8/Views/OutputTestLabView.swift:79`, `WhisperM8/Services/Dictation/PostProcessing.swift:17`). Die Fehler-Fallback-Option beeinflusst das Test Lab, ist aber auf der Modes-Seite platziert; dadurch kann das Fehlerverhalten im Test Lab nicht direkt dort verstanden oder geändert werden (`WhisperM8/Views/OutputTestLabView.swift:5`, `WhisperM8/Views/OutputTestLabView.swift:77`, `WhisperM8/Views/OutputModesView.swift:96`, `WhisperM8/Views/OutputModesView.swift:101`). Der Preview-Lauf nutzt keinen ausgewählten Text- oder visuellen Kontext, obwohl mehrere Built-in-Modi `contextPolicy: .auto` und visuelle Anhänge aktiviert haben; dadurch testet die Seite nur den textbasierten Teil dieser Modi (`WhisperM8/Models/OutputMode.swift:164`, `WhisperM8/Models/OutputMode.swift:165`, `WhisperM8/Models/OutputMode.swift:175`, `WhisperM8/Models/OutputMode.swift:176`, `WhisperM8/Services/Dictation/PostProcessingService.swift:15`, `WhisperM8/Views/OutputTestLabView.swift:70`).

## 7. Offene Fragen

- Soll das Test Lab im Redesign weiterhin als eigenständige Settings-Seite sichtbar bleiben oder als Testbereich in „Modes" oder „Templates" integriert werden? Die aktuelle Navigation führt es als eigenen `ControlCenterSection.testLab`-Case und rendert dafür `OutputTestLabView()` (`WhisperM8/Views/SettingsView.swift:10`, `WhisperM8/Views/SettingsView.swift:221`, `WhisperM8/Views/SettingsView.swift:222`).
- Soll die Seite Kontextquellen simulieren können, damit Modi mit `contextPolicy: .auto` realitätsnäher geprüft werden? Aktuell defaultet `contextBundle` auf `.empty`, und `OutputTestLabView` setzt keinen Kontextparameter (`WhisperM8/Services/Dictation/PostProcessingService.swift:15`, `WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:74`).
- Soll der Fehler-Fallback im Test Lab sichtbar steuerbar sein oder bewusst nur über „Modes" konfiguriert werden? Die View liest den Key `fallbackToRawOnProcessingError`, zeigt dafür aber kein eigenes Toggle (`WhisperM8/Views/OutputTestLabView.swift:5`, `WhisperM8/Views/OutputTestLabView.swift:77`, `WhisperM8/Views/OutputModesView.swift:101`).
