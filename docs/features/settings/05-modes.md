---
description: Settings-Seite „Modes" — vollständige Referenz der Output Modes
description_long: |
  Vollständige Referenz der Settings-Seite „Modes" im Settings-Fenster von WhisperM8.
  Dokumentiert werden UI-Aufbau, jede Option und jedes Control, Persistenzorte,
  Laufzeitwirkung in Overlay, Diktat-Pipeline, Test Lab und Codex-Post-Processing
  sowie UX-Beobachtungen für ein späteres Settings-Redesign.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 2 Zeilenverweise korrigiert)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `AIOutputSettingsPage.swift` / `AIOutputModesTab.swift` + Doku-Verweis [ARCHITEKTUR: Pages](ARCHITEKTUR.md#pages).

# Settings: Modes

> **Sidebar-Gruppe:** Output · **View:** `WhisperM8/Views/OutputModesView.swift` · **Enum-Case:** `ControlCenterSection.modes` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `OutputModesView.swift`, `OutputModeRow.swift`, `Models/OutputMode.swift`, `Services/Dictation/OutputModeStore.swift`

## 1. Zweck & Überblick

Die Seite „Modes" ist die Detailverwaltung für WhisperM8-Output-Modes im Settings-Fenster; sie wird über `ControlCenterSection.modes` mit Label „Modes" und SF-Symbol `slider.horizontal.3` in der Sidebar-Gruppe „Output" geführt und rendert `OutputModesView()` als Detailansicht (`WhisperM8/Views/SettingsView.swift:8`, `WhisperM8/Views/SettingsView.swift:71`, `WhisperM8/Views/SettingsView.swift:100`, `WhisperM8/Views/SettingsView.swift:217`). Sie dient dazu, eingebaute und eigene Modi sichtbar/unsichtbar zu schalten, den Default-Mode zu setzen, Mode-spezifische Codex-Overrides, Kontextverhalten, Template-Zuordnung und Screenshot-Auslieferung zu konfigurieren (`WhisperM8/Views/OutputModesView.swift:67`, `WhisperM8/Views/OutputModesView.swift:143`, `WhisperM8/Views/OutputModesView.swift:149`, `WhisperM8/Views/OutputModesView.swift:160`, `WhisperM8/Views/OutputModesView.swift:166`).

Fachlich entscheidet ein Mode, ob das rohe Transkript direkt ausgegeben wird oder über Codex/Post-Processing läuft; `OutputMode.usesPostProcessing` ist nur bei `kind == .raw` false, und alle anderen Modi gelten als Codex-abhängig (`WhisperM8/Models/OutputMode.swift:29`, `WhisperM8/Models/OutputMode.swift:35`). Die Seite ist relevant für Nutzer, die das Recording-Overlay, das Test Lab oder Codex-gestützte Ausgaben wie Clean, Prompt, Chat, Task, Email, Slack, WhatsApp und Notes anpassen wollen (`WhisperM8/Models/OutputMode.swift:137`, `WhisperM8/Views/RecordingPillView.swift:371`, `WhisperM8/Views/OutputTestLabView.swift:14`).

## 2. UI-Aufbau

Oben liegt ein zweispaltiges Layout: links eine 280-Punkt-Modes-Liste mit Überschrift „Modes" und Icon-only-Button „New", rechts der Editor für den aktuell selektierten Mode oder ein `ContentUnavailableView("No Mode Selected")` (`WhisperM8/Views/OutputModesView.swift:48`, `WhisperM8/Views/OutputModesView.swift:51`, `WhisperM8/Views/OutputModesView.swift:54`, `WhisperM8/Views/OutputModesView.swift:86`, `WhisperM8/Views/OutputModesView.swift:91`). Wenn das aktuelle Nutzungsprofil kein Codex-Enrichment will, zeigt die Seite ein Banner „AI enrichment is off"; dieses Profil kommt aus `AppPreferences.shared.usageProfile.wantsCodexEnrichment` (`WhisperM8/Views/OutputModesView.swift:21`, `WhisperM8/Views/OutputModesView.swift:23`, `WhisperM8/Views/OutputModesView.swift:27`, `WhisperM8/Models/AppUsageProfile.swift:20`).

Jede Listenzeile ist ein `OutputModeRow`: Klick selektiert den Mode, ein Punkt zeigt aktiv/inaktiv/locked, ein Switch schaltet Sichtbarkeit, ein Schloss ersetzt den Switch bei gesperrten Codex-Modi, und ein grünes Checkmark markiert den Default (`WhisperM8/Views/OutputModesView.swift:68`, `WhisperM8/Views/OutputModeRow.swift:24`, `WhisperM8/Views/OutputModeRow.swift:28`, `WhisperM8/Views/OutputModeRow.swift:43`, `WhisperM8/Views/OutputModeRow.swift:49`, `WhisperM8/Views/OutputModeRow.swift:57`). Der Editor zeigt Name, Built-in/Custom-Status, Default-Button, Textfelder, Sichtbarkeits- und Screenshot-Toggles, bei Post-Processing-Modi zusätzlich Codex-Modell/Thinking/Speed, Kontext-Policy und Template-Picker; bei Raw/Fast erscheint stattdessen ein Hinweis, dass Codex übersprungen wird (`WhisperM8/Views/OutputModesView.swift:130`, `WhisperM8/Views/OutputModesView.swift:143`, `WhisperM8/Views/OutputModesView.swift:149`, `WhisperM8/Views/OutputModesView.swift:166`, `WhisperM8/Views/OutputModesView.swift:231`, `WhisperM8/Views/OutputModesView.swift:241`, `WhisperM8/Views/OutputModesView.swift:252`).

Unterhalb des Editorbereichs folgt die Section „Behavior" mit den zwei globalen Toggles „Fallback to Fast on processing errors" und „Show mode chip in Mini overlay"; beide sind `@AppStorage`-Werte und speichern sofort in UserDefaults (`WhisperM8/Views/OutputModesView.swift:96`, `WhisperM8/Views/OutputModesView.swift:101`, `WhisperM8/Views/OutputModesView.swift:104`, `WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Views/OutputModesView.swift:12`).

## 3. Optionen im Detail

### Mode-Liste: Zeile auswählen

| Aspekt | Wert |
|---|---|
| Control | Button-Zeile pro Mode in `OutputModeRow`; Klick ruft `onSelect()` auf (`WhisperM8/Views/OutputModeRow.swift:24`, `WhisperM8/Views/OutputModesView.swift:79`). |
| Default | Beim Öffnen ist `selectedModeID` initial `OutputMode.rawID`; wenn dieser Mode nach `reload()` nicht existiert, wird auf `defaultOutputModeID` gewechselt (`WhisperM8/Views/OutputModesView.swift:8`, `WhisperM8/Views/OutputModesView.swift:351`, `WhisperM8/Views/OutputModesView.swift:355`). |
| Persistenz | Keine direkte Persistenz der Settings-Selektion; persistiert werden nur die Mode-Daten in `~/Library/Application Support/WhisperM8/OutputModes.json` über `saveModes(_:)` (`WhisperM8/Services/Dictation/OutputModeStore.swift:194`, `WhisperM8/Services/Dictation/OutputModeStore.swift:200`, `WhisperM8/Services/Dictation/OutputModeStore.swift:81`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:17`, `WhisperM8/Views/OutputModesView.swift:88`, `WhisperM8/Views/OutputModesView.swift:130` |
| Wirkung | Die Auswahl bestimmt, welcher Mode rechts editiert wird; die Laufzeit-Auswahl im Recording-Overlay wird davon nicht direkt geändert (`WhisperM8/Views/OutputModesView.swift:88`, `WhisperM8/Views/OutputModesView.swift:89`, `WhisperM8/Models/AppState.swift:88`). |
| Abhängigkeiten | Die Zeile zeigt Summary, Toggle-Status, Default-Status und Lock-Status aus Parent-Berechnungen (`WhisperM8/Views/OutputModesView.swift:69`, `WhisperM8/Views/OutputModesView.swift:72`, `WhisperM8/Views/OutputModesView.swift:73`, `WhisperM8/Views/OutputModesView.swift:78`). |

### New

| Aspekt | Wert |
|---|---|
| Control | Icon-only Button mit `Label("New", systemImage: "plus")` und Help „Create custom mode" (`WhisperM8/Views/OutputModesView.swift:54`, `WhisperM8/Views/OutputModesView.swift:57`, `WhisperM8/Views/OutputModesView.swift:59`, `WhisperM8/Views/OutputModesView.swift:60`). |
| Default | Neue Custom Modes heißen „Custom Mode", haben Short Label „Custom", verwenden `template.clean`, sind aktiviert und nicht Default (`WhisperM8/Services/Dictation/OutputModeStore.swift:100`, `WhisperM8/Services/Dictation/OutputModeStore.swift:103`, `WhisperM8/Services/Dictation/OutputModeStore.swift:104`, `WhisperM8/Services/Dictation/OutputModeStore.swift:106`, `WhisperM8/Services/Dictation/OutputModeStore.swift:107`, `WhisperM8/Services/Dictation/OutputModeStore.swift:108`). |
| Persistenz | `OutputModes.json` unter `~/Library/Application Support/WhisperM8/OutputModes.json`, weil `addMode()` den Mode anhängt und `saveModes()` schreibt (`WhisperM8/Views/OutputModesView.swift:384`, `WhisperM8/Views/OutputModesView.swift:386`, `WhisperM8/Views/OutputModesView.swift:388`, `WhisperM8/Services/Dictation/OutputModeStore.swift:194`, `WhisperM8/Services/Dictation/OutputModeStore.swift:200`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:55`, `WhisperM8/Services/Dictation/OutputModeStore.swift:100` |
| Wirkung | Erstellt einen Custom Mode mit UUID als ID und selektiert ihn sofort (`WhisperM8/Services/Dictation/OutputModeStore.swift:102`, `WhisperM8/Views/OutputModesView.swift:385`, `WhisperM8/Views/OutputModesView.swift:387`). |
| Abhängigkeiten | Der neue Mode nutzt standardmäßig das Clean-Template aus der Templates-Seite (`WhisperM8/Services/Dictation/OutputModeStore.swift:106`, `WhisperM8/Models/PostProcessingTemplate.swift:74`). |

### Mode Enabled Switch

| Aspekt | Wert |
|---|---|
| Control | Switch in der Mode-Zeile mit verborgenem Label „Enabled"; im Editor zusätzlich Toggle „Show in recording overlay and Test Lab" (`WhisperM8/Views/OutputModeRow.swift:49`, `WhisperM8/Views/OutputModeRow.swift:50`, `WhisperM8/Views/OutputModesView.swift:153`). |
| Default | Alle eingebauten Modi sind im Modell initial aktiviert; Raw/Fast ist zusätzlich immer aktiviert (`WhisperM8/Models/OutputMode.swift:144`, `WhisperM8/Models/OutputMode.swift:153`, `WhisperM8/Models/OutputMode.swift:162`, `WhisperM8/Models/OutputMode.swift:173`, `WhisperM8/Models/OutputMode.swift:184`, `WhisperM8/Models/OutputMode.swift:195`, `WhisperM8/Models/OutputMode.swift:206`, `WhisperM8/Models/OutputMode.swift:217`, `WhisperM8/Models/OutputMode.swift:228`, `WhisperM8/Services/Dictation/OutputModeStore.swift:163`). |
| Persistenz | Feld `isEnabled` im Mode-JSON `~/Library/Application Support/WhisperM8/OutputModes.json`; Coding-Key `isEnabled` wird serialisiert (`WhisperM8/Models/OutputMode.swift:15`, `WhisperM8/Models/OutputMode.swift:75`, `WhisperM8/Services/Dictation/OutputModeStore.swift:89`, `WhisperM8/Services/Dictation/OutputModeStore.swift:90`). |
| Gelesen von | `WhisperM8/Services/Dictation/OutputModeStore.swift:72`, `WhisperM8/Models/OutputMode.swift:248`, `WhisperM8/Views/OutputTestLabView.swift:15`, `WhisperM8/Views/RecordingPillView.swift:379` |
| Wirkung | Nur aktivierte Modi erscheinen in `enabledModes`, im Test Lab und im Overlay-Menü; deaktivierte Menüeinträge wären im Chip disabled, werden aber normalerweise bereits aus `availableBuiltInModes()` herausgefiltert (`WhisperM8/Services/Dictation/OutputModeStore.swift:72`, `WhisperM8/Models/OutputMode.swift:255`, `WhisperM8/Views/OutputTestLabView.swift:15`, `WhisperM8/Views/RecordingPillView.swift:389`). |
| Abhängigkeiten | Raw/Fast und der aktuelle Default können nicht deaktiviert werden; `modeEnabledBinding` setzt nur, wenn `newValue` true ist oder `canDisable` true liefert (`WhisperM8/Views/OutputModesView.swift:340`, `WhisperM8/Views/OutputModesView.swift:344`, `WhisperM8/Views/OutputModesView.swift:422`). |

### Locked State bei ausgeschaltetem AI Enrichment

| Aspekt | Wert |
|---|---|
| Control | Kein editierendes Control, sondern Banner plus gesperrte Zeilendarstellung mit Schloss statt Switch (`WhisperM8/Views/OutputModesView.swift:27`, `WhisperM8/Views/OutputModesView.swift:63`, `WhisperM8/Views/OutputModeRow.swift:43`). |
| Default | Default-Profil ist `.full`, also ist Enrichment für Bestandsnutzer standardmäßig verfügbar (`WhisperM8/Models/AppUsageProfile.swift:17`, `WhisperM8/Models/AppUsageProfile.swift:18`, `WhisperM8/Models/AppUsageProfile.swift:23`, `WhisperM8/Models/AppUsageProfile.swift:24`). |
| Persistenz | UserDefaults-Key `usageProfile`; `wantsCodexEnrichment` wird daraus berechnet (`WhisperM8/Support/AppPreferences.swift:23`, `WhisperM8/Support/AppPreferences.swift:25`, `WhisperM8/Support/AppPreferences.swift:28`, `WhisperM8/Support/AppPreferences.swift:358`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:23`, `WhisperM8/Models/OutputMode.swift:237`, `WhisperM8/Models/OutputMode.swift:255` |
| Wirkung | Ohne Enrichment werden Codex-abhängige Modi visuell gesperrt und für Overlay/Default effektiv auf Raw/Fast gefiltert (`WhisperM8/Views/OutputModesView.swift:78`, `WhisperM8/Models/OutputMode.swift:242`, `WhisperM8/Models/OutputMode.swift:258`). |
| Abhängigkeiten | Betrifft alle Modi außer Raw/Fast, weil `isCodexDependent` auf `usesPostProcessing` basiert und `usesPostProcessing` nur bei `kind == .raw` false ist (`WhisperM8/Models/OutputMode.swift:29`, `WhisperM8/Models/OutputMode.swift:35`). |

### Make Default / Default

| Aspekt | Wert |
|---|---|
| Control | Button im Editor; Text ist „Default", wenn der Mode bereits Default ist, sonst „Make Default"; der Button ist im Default-Zustand disabled (`WhisperM8/Views/OutputModesView.swift:143`, `WhisperM8/Views/OutputModesView.swift:146`). |
| Default | In `OutputModesView` ist der `@AppStorage`-Fallback `OutputMode.rawID`; `AppPreferences.defaultOutputModeID` fällt dagegen auf `OutputMode.cleanID` zurück (`WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Support/AppPreferences.swift:84`, `WhisperM8/Support/AppPreferences.swift:85`). |
| Persistenz | UserDefaults-Key `defaultOutputModeID`; im Mode-JSON wird zusätzlich das abgeleitete Feld `isDefault` normalisiert gespeichert (`WhisperM8/Support/AppPreferences.swift:368`, `WhisperM8/Services/Dictation/OutputModeStore.swift:152`, `WhisperM8/Services/Dictation/OutputModeStore.swift:156`, `WhisperM8/Services/Dictation/OutputModeStore.swift:184`). |
| Gelesen von | `WhisperM8/Models/OutputMode.swift:237`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:167`, `WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Services/Dictation/OutputModeStore.swift:77` |
| Wirkung | Neue Recordings starten mit `OutputMode.defaultMode()`; wenn das Profil kein Enrichment erlaubt und der gespeicherte Default Codex-abhängig ist, fällt die effektive Auswahl auf Raw/Fast zurück (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:167`, `WhisperM8/Models/OutputMode.swift:237`, `WhisperM8/Models/OutputMode.swift:242`, `WhisperM8/Models/OutputMode.swift:243`). |
| Abhängigkeiten | Default Modes werden durch `applyDefaultFlags()` immer aktiviert; beim Löschen eines Custom-Defaults wird der Key auf Raw/Fast gesetzt (`WhisperM8/Views/OutputModesView.swift:368`, `WhisperM8/Views/OutputModesView.swift:372`, `WhisperM8/Views/OutputModesView.swift:395`, `WhisperM8/Views/OutputModesView.swift:396`). |

### Mode name

| Aspekt | Wert |
|---|---|
| Control | `TextField("Mode name", text: mode.name)` im Editor (`WhisperM8/Views/OutputModesView.swift:150`). |
| Default | Built-ins heißen Fast, Clean, Prompt, Chat, Task, Email, Slack, WhatsApp und Notes; Custom Modes starten als „Custom Mode" (`WhisperM8/Models/OutputMode.swift:140`, `WhisperM8/Models/OutputMode.swift:149`, `WhisperM8/Models/OutputMode.swift:159`, `WhisperM8/Models/OutputMode.swift:169`, `WhisperM8/Models/OutputMode.swift:180`, `WhisperM8/Models/OutputMode.swift:191`, `WhisperM8/Models/OutputMode.swift:202`, `WhisperM8/Models/OutputMode.swift:213`, `WhisperM8/Models/OutputMode.swift:224`, `WhisperM8/Services/Dictation/OutputModeStore.swift:103`). |
| Persistenz | Feld `name` im Mode-JSON; Coding-Key `name` wird serialisiert (`WhisperM8/Models/OutputMode.swift:11`, `WhisperM8/Models/OutputMode.swift:70`, `WhisperM8/Services/Dictation/OutputModeStore.swift:89`). |
| Gelesen von | `WhisperM8/Views/OutputModeRow.swift:33`, `WhisperM8/Views/OutputModesView.swift:134`, `WhisperM8/Views/RecordingPillView.swift:384`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:319` |
| Wirkung | Ändert die Listenanzeige, den Editor-Titel, den Overlay-Menüeintrag und den im Prompt-Paket genannten Output-Mode-Namen (`WhisperM8/Views/OutputModeRow.swift:33`, `WhisperM8/Views/OutputModesView.swift:134`, `WhisperM8/Views/RecordingPillView.swift:384`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:319`). |
| Abhängigkeiten | Raw/Fast wird bei Normalisierung von altem Namen „Raw" auf „Fast" migriert, eigene Umbenennungen bleiben laut Kommentar ausgenommen (`WhisperM8/Services/Dictation/OutputModeStore.swift:157`, `WhisperM8/Services/Dictation/OutputModeStore.swift:161`). |

### Overlay label

| Aspekt | Wert |
|---|---|
| Control | `TextField("Overlay label", text: mode.shortLabel)` (`WhisperM8/Views/OutputModesView.swift:151`). |
| Default | Built-in-Short-Labels sind Fast, Clean, Prompt, Chat, Task, Mail, Slack, WA und Notes; Custom Modes starten als „Custom" (`WhisperM8/Models/OutputMode.swift:141`, `WhisperM8/Models/OutputMode.swift:150`, `WhisperM8/Models/OutputMode.swift:159`, `WhisperM8/Models/OutputMode.swift:170`, `WhisperM8/Models/OutputMode.swift:181`, `WhisperM8/Models/OutputMode.swift:192`, `WhisperM8/Models/OutputMode.swift:203`, `WhisperM8/Models/OutputMode.swift:214`, `WhisperM8/Models/OutputMode.swift:225`, `WhisperM8/Services/Dictation/OutputModeStore.swift:104`). |
| Persistenz | Feld `shortLabel` im Mode-JSON; Coding-Key `shortLabel` wird serialisiert (`WhisperM8/Models/OutputMode.swift:12`, `WhisperM8/Models/OutputMode.swift:71`, `WhisperM8/Services/Dictation/OutputModeStore.swift:89`). |
| Gelesen von | `WhisperM8/Views/RecordingPillView.swift:393`, `WhisperM8/Views/OutputModesView.swift:419` |
| Wirkung | Bestimmt den kompakten Text im Mode-Chip der Recording-Pill und fließt in die Summary-Zeile der Modes-Liste ein (`WhisperM8/Views/RecordingPillView.swift:393`, `WhisperM8/Views/OutputModesView.swift:419`). |
| Abhängigkeiten | Raw/Fast-Short-Label wird bei alter Persistenz von „Raw" auf „Fast" migriert (`WhisperM8/Services/Dictation/OutputModeStore.swift:162`). |

### Paste screenshots into target app

| Aspekt | Wert |
|---|---|
| Control | Toggle „Paste screenshots into target app" (`WhisperM8/Views/OutputModesView.swift:160`). |
| Default | Für Prompt, Chat, Task, Email, Slack und WhatsApp ist der Default true; für andere Built-ins false; Custom Modes sind default true, wenn ihre Kontext-Policy nicht `.off` ist (`WhisperM8/Models/OutputMode.swift:164`, `WhisperM8/Models/OutputMode.swift:165`, `WhisperM8/Models/OutputMode.swift:175`, `WhisperM8/Models/OutputMode.swift:176`, `WhisperM8/Models/OutputMode.swift:186`, `WhisperM8/Models/OutputMode.swift:187`, `WhisperM8/Models/OutputMode.swift:197`, `WhisperM8/Models/OutputMode.swift:198`, `WhisperM8/Models/OutputMode.swift:208`, `WhisperM8/Models/OutputMode.swift:209`, `WhisperM8/Models/OutputMode.swift:219`, `WhisperM8/Models/OutputMode.swift:220`, `WhisperM8/Models/OutputMode.swift:277`). |
| Persistenz | Feld `pasteVisualAttachments` im Mode-JSON; fehlende alte Werte werden beim Decode auf Default berechnet (`WhisperM8/Models/OutputMode.swift:18`, `WhisperM8/Models/OutputMode.swift:77`, `WhisperM8/Models/OutputMode.swift:94`, `WhisperM8/Models/OutputMode.swift:95`). |
| Gelesen von | `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:16`, `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:22`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:65` |
| Wirkung | Wenn Auto-paste aktiv ist, kopiert WhisperM8 visuelle Anhänge in ein temporäres Delivery-Verzeichnis und fügt sie nach dem Text in die Ziel-App ein; bei false wird eine leere Attachment-Liste geliefert (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:67`, `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:22`, `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:27`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:87`). |
| Abhängigkeiten | Hängt zusätzlich an globalem Auto-paste, das in Behavior als `autoPasteEnabled` gespeichert wird (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:5`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:56`). |

### Use global Codex model

| Aspekt | Wert |
|---|---|
| Control | Toggle „Use global Codex model", nur für `usesPostProcessing`-Modes sichtbar (`WhisperM8/Views/OutputModesView.swift:166`, `WhisperM8/Views/OutputModesView.swift:174`). |
| Default | `nil` Override bedeutet globaler Wert; Built-ins und neue Custom Modes starten ohne Override (`WhisperM8/Models/OutputMode.swift:19`, `WhisperM8/Models/OutputMode.swift:49`, `WhisperM8/Services/Dictation/OutputModeStore.swift:100`). |
| Persistenz | Feld `codexModelRawOverride` im Mode-JSON; globaler Wert liegt separat in UserDefaults-Key `codexPostProcessingModel` (`WhisperM8/Models/OutputMode.swift:21`, `WhisperM8/Models/OutputMode.swift:78`, `WhisperM8/Support/AppPreferences.swift:145`, `WhisperM8/Support/AppPreferences.swift:379`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:286`, `WhisperM8/Models/OutputMode.swift:101`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:70` |
| Wirkung | Bei aktivem Toggle bleibt das Override `nil` und der globale Codex/ChatGPT-Default wird verwendet; beim Ausschalten wird der aktuell aufgelöste Wert als Mode-Override gespeichert (`WhisperM8/Views/OutputModesView.swift:288`, `WhisperM8/Views/OutputModesView.swift:290`, `WhisperM8/Views/OutputModesView.swift:292`). |
| Abhängigkeiten | Der globale Wert wird auf der Seite „Codex / ChatGPT" über denselben UserDefaults-Key gepflegt (`WhisperM8/Views/CodexSettingsView.swift:4`, `WhisperM8/Views/CodexSettingsView.swift:57`). |

### Mode model

| Aspekt | Wert |
|---|---|
| Control | Picker „Mode model", sichtbar wenn `codexModelRawOverride != nil` (`WhisperM8/Views/OutputModesView.swift:176`, `WhisperM8/Views/OutputModesView.swift:181`). |
| Default | Globaler Default ist `GPT-5.5` mit Raw Value `gpt-5.5`; weitere Optionen sind `GPT-5.4` und `GPT-5.2` (`WhisperM8/Models/CodexPostProcessingModel.swift:4`, `WhisperM8/Models/CodexPostProcessingModel.swift:5`, `WhisperM8/Models/CodexPostProcessingModel.swift:6`, `WhisperM8/Models/CodexPostProcessingModel.swift:32`). |
| Persistenz | Feld `codexModelRawOverride` im Mode-JSON; der Picker schreibt den Raw Value (`WhisperM8/Views/OutputModesView.swift:297`, `WhisperM8/Views/OutputModesView.swift:300`, `WhisperM8/Models/OutputMode.swift:78`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:182`, `WhisperM8/Models/OutputMode.swift:101`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:70`, `WhisperM8/Services/Dictation/CodexSupport.swift:62` |
| Wirkung | Der aufgelöste Modellwert wird als `-m <model>` an `codex exec` übergeben (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:67`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:70`, `WhisperM8/Services/Dictation/CodexSupport.swift:63`, `WhisperM8/Services/Dictation/CodexSupport.swift:64`). |
| Abhängigkeiten | Ungültige Raw Values fallen über `CodexPostProcessingModel.resolve` auf `GPT-5.5` zurück (`WhisperM8/Models/CodexPostProcessingModel.swift:34`, `WhisperM8/Models/CodexPostProcessingModel.swift:35`). |

### Use global Thinking level

| Aspekt | Wert |
|---|---|
| Control | Toggle „Use global Thinking level", nur für Post-Processing-Modes sichtbar (`WhisperM8/Views/OutputModesView.swift:192`). |
| Default | `nil` Override bedeutet globaler Wert; globaler Default ist `medium` (`WhisperM8/Models/OutputMode.swift:22`, `WhisperM8/Models/CodexReasoningEffort.swift:37`). |
| Persistenz | Feld `codexReasoningEffortRawOverride` im Mode-JSON; globaler Wert liegt in UserDefaults-Key `codexReasoningEffort` (`WhisperM8/Models/OutputMode.swift:24`, `WhisperM8/Models/OutputMode.swift:79`, `WhisperM8/Support/AppPreferences.swift:150`, `WhisperM8/Support/AppPreferences.swift:380`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:304`, `WhisperM8/Models/OutputMode.swift:109`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:71` |
| Wirkung | Bei aktivem Toggle bleibt das Override `nil`; beim Ausschalten wird der aktuell aufgelöste Thinking-Wert Mode-spezifisch gespeichert (`WhisperM8/Views/OutputModesView.swift:306`, `WhisperM8/Views/OutputModesView.swift:308`, `WhisperM8/Views/OutputModesView.swift:310`). |
| Abhängigkeiten | Der globale Wert wird auf „Codex / ChatGPT" über denselben Key editiert (`WhisperM8/Views/CodexSettingsView.swift:5`, `WhisperM8/Views/CodexSettingsView.swift:67`). |

### Thinking level

| Aspekt | Wert |
|---|---|
| Control | Picker „Thinking level", sichtbar wenn `codexReasoningEffortRawOverride != nil` (`WhisperM8/Views/OutputModesView.swift:194`, `WhisperM8/Views/OutputModesView.swift:199`). |
| Default | Optionen sind Low, Medium, High und Extra High; Default ist Medium (`WhisperM8/Models/CodexReasoningEffort.swift:4`, `WhisperM8/Models/CodexReasoningEffort.swift:5`, `WhisperM8/Models/CodexReasoningEffort.swift:6`, `WhisperM8/Models/CodexReasoningEffort.swift:7`, `WhisperM8/Models/CodexReasoningEffort.swift:37`). |
| Persistenz | Feld `codexReasoningEffortRawOverride` im Mode-JSON (`WhisperM8/Views/OutputModesView.swift:315`, `WhisperM8/Views/OutputModesView.swift:318`, `WhisperM8/Models/OutputMode.swift:79`). |
| Gelesen von | `WhisperM8/Models/OutputMode.swift:109`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:71`, `WhisperM8/Services/Dictation/CodexSupport.swift:65` |
| Wirkung | Der aufgelöste Wert wird als Codex-Konfiguration `model_reasoning_effort=<value>` an `codex exec` übergeben (`WhisperM8/Services/Dictation/CodexSupport.swift:62`, `WhisperM8/Services/Dictation/CodexSupport.swift:65`). |
| Abhängigkeiten | Ungültige Raw Values fallen über `CodexReasoningEffort.resolve` auf Medium zurück (`WhisperM8/Models/CodexReasoningEffort.swift:39`, `WhisperM8/Models/CodexReasoningEffort.swift:40`). |

### Use global Fast mode

| Aspekt | Wert |
|---|---|
| Control | Toggle „Use global Fast mode", nur für Post-Processing-Modes sichtbar (`WhisperM8/Views/OutputModesView.swift:210`). |
| Default | `nil` Override bedeutet globaler Wert; globaler Default ist Service-Tier `fast` (`WhisperM8/Models/OutputMode.swift:25`, `WhisperM8/Models/CodexServiceTier.swift:39`). |
| Persistenz | Feld `codexServiceTierRawOverride` im Mode-JSON; globaler Wert liegt in UserDefaults-Key `codexServiceTier` (`WhisperM8/Models/OutputMode.swift:27`, `WhisperM8/Models/OutputMode.swift:80`, `WhisperM8/Support/AppPreferences.swift:155`, `WhisperM8/Support/AppPreferences.swift:381`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:322`, `WhisperM8/Models/OutputMode.swift:117`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:72` |
| Wirkung | Bei aktivem Toggle bleibt das Override `nil`; beim Ausschalten wird der aktuell aufgelöste Speed/Service-Tier-Wert Mode-spezifisch gespeichert (`WhisperM8/Views/OutputModesView.swift:324`, `WhisperM8/Views/OutputModesView.swift:326`, `WhisperM8/Views/OutputModesView.swift:328`). |
| Abhängigkeiten | Der globale Wert wird auf „Codex / ChatGPT" über denselben Key editiert (`WhisperM8/Views/CodexSettingsView.swift:6`, `WhisperM8/Views/CodexSettingsView.swift:77`). |

### Speed

| Aspekt | Wert |
|---|---|
| Control | Picker „Speed", sichtbar wenn `codexServiceTierRawOverride != nil` (`WhisperM8/Views/OutputModesView.swift:212`, `WhisperM8/Views/OutputModesView.swift:217`). |
| Default | Optionen sind Fast und Standard; Default ist Fast (`WhisperM8/Models/CodexServiceTier.swift:4`, `WhisperM8/Models/CodexServiceTier.swift:5`, `WhisperM8/Models/CodexServiceTier.swift:39`). |
| Persistenz | Feld `codexServiceTierRawOverride` im Mode-JSON (`WhisperM8/Views/OutputModesView.swift:333`, `WhisperM8/Views/OutputModesView.swift:336`, `WhisperM8/Models/OutputMode.swift:80`). |
| Gelesen von | `WhisperM8/Models/OutputMode.swift:117`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:72`, `WhisperM8/Services/Dictation/CodexSupport.swift:67` |
| Wirkung | Fast setzt `features.fast_mode=true` und `service_tier=fast`; Standard setzt `service_tier=default` (`WhisperM8/Models/CodexServiceTier.swift:27`, `WhisperM8/Models/CodexServiceTier.swift:30`, `WhisperM8/Models/CodexServiceTier.swift:31`, `WhisperM8/Models/CodexServiceTier.swift:32`, `WhisperM8/Models/CodexServiceTier.swift:35`). |
| Abhängigkeiten | Ungültige Raw Values fallen über `CodexServiceTier.resolve` auf Fast zurück (`WhisperM8/Models/CodexServiceTier.swift:41`, `WhisperM8/Models/CodexServiceTier.swift:42`). |

### Selected context

| Aspekt | Wert |
|---|---|
| Control | Picker „Selected context" mit `ContextCapturePolicy.allCases` (`WhisperM8/Views/OutputModesView.swift:231`, `WhisperM8/Views/OutputModesView.swift:232`). |
| Default | Policies sind Off, Auto when selected und Required; Prompt, Chat, Task, Email, Slack und WhatsApp starten mit `.auto`, andere Modi mit `.off` (`WhisperM8/Models/SelectedContext.swift:3`, `WhisperM8/Models/SelectedContext.swift:13`, `WhisperM8/Models/SelectedContext.swift:15`, `WhisperM8/Models/SelectedContext.swift:17`, `WhisperM8/Models/OutputMode.swift:263`, `WhisperM8/Models/OutputMode.swift:265`, `WhisperM8/Models/OutputMode.swift:268`). |
| Persistenz | Feld `contextPolicy` im Mode-JSON; fehlende alte Werte werden per `defaultContextPolicy(for:)` ergänzt (`WhisperM8/Models/OutputMode.swift:17`, `WhisperM8/Models/OutputMode.swift:76`, `WhisperM8/Models/OutputMode.swift:92`, `WhisperM8/Models/OutputMode.swift:93`). |
| Gelesen von | `WhisperM8/Services/Dictation/PostProcessingService.swift:26`, `WhisperM8/Services/Dictation/PostProcessingService.swift:27`, `WhisperM8/Services/Dictation/PostProcessingService.swift:39` |
| Wirkung | `.off` entfernt Kontext aus dem Post-Processing, `.auto` und `.required` erlauben ihn; `.required` wirft einen Fehler, wenn kein Kontext erfasst wurde (`WhisperM8/Services/Dictation/PostProcessingService.swift:40`, `WhisperM8/Services/Dictation/PostProcessingService.swift:42`, `WhisperM8/Services/Dictation/PostProcessingService.swift:43`, `WhisperM8/Services/Dictation/PostProcessingService.swift:27`, `WhisperM8/Services/Dictation/PostProcessingService.swift:28`). |
| Abhängigkeiten | Die Erfassung von markiertem Text und visuellem Kontext hängt global an Behavior-Settings wie `selectedContextCaptureEnabled` und `visualContextCaptureEnabled` (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:11`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:12`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:65`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:73`). |

### Template

| Aspekt | Wert |
|---|---|
| Control | Picker „Template" über alle `templates`; darunter wird die Template-Beschreibung angezeigt, wenn die ID gefunden wird (`WhisperM8/Views/OutputModesView.swift:241`, `WhisperM8/Views/OutputModesView.swift:242`, `WhisperM8/Views/OutputModesView.swift:247`, `WhisperM8/Views/OutputModesView.swift:248`). |
| Default | Built-in-Modes referenzieren passende Template-IDs; Custom Modes starten mit `PostProcessingTemplate.cleanID` (`WhisperM8/Models/OutputMode.swift:152`, `WhisperM8/Models/OutputMode.swift:161`, `WhisperM8/Models/OutputMode.swift:172`, `WhisperM8/Models/OutputMode.swift:183`, `WhisperM8/Models/OutputMode.swift:194`, `WhisperM8/Models/OutputMode.swift:205`, `WhisperM8/Models/OutputMode.swift:216`, `WhisperM8/Models/OutputMode.swift:227`, `WhisperM8/Services/Dictation/OutputModeStore.swift:106`). |
| Persistenz | Feld `templateID` im Mode-JSON; Custom Templates liegen separat in `~/Library/Application Support/WhisperM8/PostProcessingTemplates.json` (`WhisperM8/Models/OutputMode.swift:14`, `WhisperM8/Models/OutputMode.swift:73`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:58`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:64`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:65`). |
| Gelesen von | `WhisperM8/Services/Dictation/CodexPostProcessor.swift:21`, `WhisperM8/Services/Dictation/PostProcessingService.swift:54`, `WhisperM8/Services/Dictation/PostProcessingService.swift:73` |
| Wirkung | Das Template rendert den Mode-Prompt mit Transkript, Sprache und Kontext-Platzhaltern; bei fehlendem Template wirft der Codex-Postprocessor `missingTemplate` (`WhisperM8/Models/PostProcessingTemplate.swift:12`, `WhisperM8/Models/PostProcessingTemplate.swift:20`, `WhisperM8/Models/PostProcessingTemplate.swift:21`, `WhisperM8/Models/PostProcessingTemplate.swift:36`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:21`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:22`). |
| Abhängigkeiten | Überschneidet sich direkt mit der Settings-Seite „Templates", die Templates erstellt, dupliziert und speichert (`WhisperM8/Views/OutputTemplatesView.swift:27`, `WhisperM8/Views/OutputTemplatesView.swift:40`, `WhisperM8/Views/OutputTemplatesView.swift:114`, `WhisperM8/Views/OutputTemplatesView.swift:118`, `WhisperM8/Views/OutputTemplatesView.swift:230`). |

### Delete Custom Mode

| Aspekt | Wert |
|---|---|
| Control | Destruktiver Button „Delete Custom Mode", nur wenn `kind == .custom` (`WhisperM8/Views/OutputModesView.swift:260`, `WhisperM8/Views/OutputModesView.swift:261`, `WhisperM8/Views/OutputModesView.swift:262`). |
| Default | Eingebaute Modes haben `kind` `.raw` oder `.builtIn`; nur neu erzeugte oder unbekannte nicht-built-in IDs werden Custom (`WhisperM8/Models/OutputMode.swift:4`, `WhisperM8/Models/OutputMode.swift:142`, `WhisperM8/Models/OutputMode.swift:151`, `WhisperM8/Services/Dictation/OutputModeStore.swift:183`). |
| Persistenz | Entfernt den Mode aus `OutputModes.json`; wenn der gelöschte Mode Default war, wird UserDefaults-Key `defaultOutputModeID` auf `raw` gesetzt (`WhisperM8/Views/OutputModesView.swift:391`, `WhisperM8/Views/OutputModesView.swift:394`, `WhisperM8/Views/OutputModesView.swift:395`, `WhisperM8/Views/OutputModesView.swift:396`, `WhisperM8/Views/OutputModesView.swift:399`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:391`, `WhisperM8/Services/Dictation/OutputModeStore.swift:145` |
| Wirkung | Löscht nur Custom Modes; Built-ins werden beim Normalisieren wieder ergänzt, wenn sie in der Datei fehlen (`WhisperM8/Views/OutputModesView.swift:392`, `WhisperM8/Services/Dictation/OutputModeStore.swift:148`, `WhisperM8/Services/Dictation/OutputModeStore.swift:149`). |
| Abhängigkeiten | Nach dem Löschen wird die erste vorhandene Mode-ID oder Raw/Fast selektiert (`WhisperM8/Views/OutputModesView.swift:398`). |

### Reload

| Aspekt | Wert |
|---|---|
| Control | Button „Reload" unten rechts im Editor (`WhisperM8/Views/OutputModesView.swift:269`, `WhisperM8/Views/OutputModesView.swift:270`). |
| Default | Keine Persistenzwirkung; liest aktuellen Store-Zustand erneut (`WhisperM8/Views/OutputModesView.swift:351`, `WhisperM8/Views/OutputModesView.swift:352`, `WhisperM8/Views/OutputModesView.swift:353`). |
| Persistenz | Liest `OutputModes.json` und `PostProcessingTemplates.json`; schreibt nicht selbst (`WhisperM8/Views/OutputModesView.swift:351`, `WhisperM8/Services/Dictation/OutputModeStore.swift:118`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:23`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:269`, `WhisperM8/Views/OutputModesView.swift:351` |
| Wirkung | Aktualisiert lokale `templates` und `modes`; falls die bisherige Selektion fehlt, wird der Default selektiert (`WhisperM8/Views/OutputModesView.swift:352`, `WhisperM8/Views/OutputModesView.swift:353`, `WhisperM8/Views/OutputModesView.swift:354`, `WhisperM8/Views/OutputModesView.swift:355`). |
| Abhängigkeiten | Der Store nutzt einen mtime/size-Disk-Cache für Mode-Dateien, daher kann Reload aus Cache oder Datei kommen (`WhisperM8/Services/Dictation/OutputModeStore.swift:3`, `WhisperM8/Services/Dictation/OutputModeStore.swift:22`, `WhisperM8/Services/Dictation/OutputModeStore.swift:121`, `WhisperM8/Services/Dictation/OutputModeStore.swift:122`). |

### Drag-Reorder

| Aspekt | Wert |
|---|---|
| Control | Im aktuellen Working Tree gibt es kein Drag-Reorder-Control in `OutputModesView`; die Liste ist ein `ForEach($modes)` ohne `.onMove`, Drop-Delegate oder Drag-Modifier (`WhisperM8/Views/OutputModesView.swift:67`, `WhisperM8/Views/OutputModesView.swift:68`, `WhisperM8/Views/OutputModeRow.swift:23`). |
| Default | Built-ins werden in der Reihenfolge von `OutputMode.builtInModes` normalisiert; Custom Modes werden alphabetisch nach Name sortiert (`WhisperM8/Models/OutputMode.swift:137`, `WhisperM8/Services/Dictation/OutputModeStore.swift:152`, `WhisperM8/Services/Dictation/OutputModeStore.swift:178`, `WhisperM8/Services/Dictation/OutputModeStore.swift:180`, `WhisperM8/Services/Dictation/OutputModeStore.swift:191`). |
| Persistenz | Keine separate Reihenfolge-Persistenz; gespeicherte Reihenfolge wird beim Laden durch `normalized(_:)` überschrieben (`WhisperM8/Services/Dictation/OutputModeStore.swift:145`, `WhisperM8/Services/Dictation/OutputModeStore.swift:191`). |
| Gelesen von | `WhisperM8/Views/OutputModesView.swift:67`, `WhisperM8/Services/Dictation/OutputModeStore.swift:145` |
| Wirkung | Nutzer können die Reihenfolge im UI nicht manuell ändern; Custom-Reihenfolge folgt Name-Sortierung (`WhisperM8/Services/Dictation/OutputModeStore.swift:180`). |
| Abhängigkeiten | Eine künftige Drag-Reorder-Funktion müsste `normalized(_:)` und das JSON-Schema ändern, weil aktuell keine Order-Felder existieren (`WhisperM8/Models/OutputMode.swift:68`, `WhisperM8/Models/OutputMode.swift:80`, `WhisperM8/Services/Dictation/OutputModeStore.swift:178`). |

### Fallback to Fast on processing errors

| Aspekt | Wert |
|---|---|
| Control | Toggle „Fallback to Fast on processing errors" in der Section „Behavior" (`WhisperM8/Views/OutputModesView.swift:96`, `WhisperM8/Views/OutputModesView.swift:101`). |
| Default | true (`WhisperM8/Views/OutputModesView.swift:12`, `WhisperM8/Support/AppPreferences.swift:94`, `WhisperM8/Support/AppPreferences.swift:95`). |
| Persistenz | UserDefaults-Key `fallbackToRawOnProcessingError` (`WhisperM8/Views/OutputModesView.swift:12`, `WhisperM8/Support/AppPreferences.swift:370`). |
| Gelesen von | `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:236`, `WhisperM8/Views/OutputTestLabView.swift:5`, `WhisperM8/Views/OutputTestLabView.swift:77` |
| Wirkung | Bei Codex/Post-Processing-Fehlern gibt die Diktat-Pipeline je nach Intent Raw oder einen vorsichtigen Fallback-Text aus; im Test Lab wird bei Fehlern der normalisierte Raw-Text angezeigt (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:236`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:240`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:245`, `WhisperM8/Views/OutputTestLabView.swift:77`, `WhisperM8/Views/OutputTestLabView.swift:78`). |
| Abhängigkeiten | Der sichtbare Name sagt „Fast", Code und Key sagen weiterhin `Raw`; die Fallback-Funktion nutzt je nach Reply-Intent vorsichtige Texte für Slack/WhatsApp/Email (`WhisperM8/Views/OutputModesView.swift:101`, `WhisperM8/Support/AppPreferences.swift:370`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:281`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:290`). |

### Show mode chip in Mini overlay

| Aspekt | Wert |
|---|---|
| Control | Toggle „Show mode chip in Mini overlay" in der Section „Behavior" (`WhisperM8/Views/OutputModesView.swift:104`). |
| Default | true (`WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Support/AppPreferences.swift:99`, `WhisperM8/Support/AppPreferences.swift:100`). |
| Persistenz | UserDefaults-Key `showModePickerInMiniOverlay` (`WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Support/AppPreferences.swift:371`). |
| Gelesen von | `WhisperM8/Windows/RecordingPanel.swift:465`, `WhisperM8/Windows/RecordingPanel.swift:688`, `WhisperM8/Views/RecordingPillView.swift:161`, `WhisperM8/Views/RecordingPillView.swift:163` |
| Wirkung | In der Mini-Pill ist der Mode-Chip permanent sichtbar, wenn der Toggle true ist; wenn false, erscheint er nur im Hover-expandierten Zustand (`WhisperM8/Views/RecordingPillView.swift:161`, `WhisperM8/Views/RecordingPillView.swift:163`, `WhisperM8/Views/RecordingPillView.swift:164`). |
| Abhängigkeiten | Dieselbe Option existiert auch in Behavior unter „Recording Overlay", wo sie denselben UserDefaults-Key verwendet (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:10`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`). |

## 4. Datenfluss & Persistenz

`OutputModesView` initialisiert lokale Stores und Arrays direkt beim View-Aufbau, lädt auf `onAppear` erneut und speichert jede Änderung an `modes` sofort über `saveModes()` (`WhisperM8/Views/OutputModesView.swift:4`, `WhisperM8/Views/OutputModesView.swift:5`, `WhisperM8/Views/OutputModesView.swift:6`, `WhisperM8/Views/OutputModesView.swift:7`, `WhisperM8/Views/OutputModesView.swift:120`, `WhisperM8/Views/OutputModesView.swift:121`, `WhisperM8/Views/OutputModesView.swift:122`). `OutputModeStore.saveModes(_:)` legt das Application-Support-Verzeichnis an, normalisiert die Liste, schreibt pretty-printed JSON atomar und postet `OutputModeStore.modesDidChange` (`WhisperM8/Services/Dictation/OutputModeStore.swift:81`, `WhisperM8/Services/Dictation/OutputModeStore.swift:82`, `WhisperM8/Services/Dictation/OutputModeStore.swift:88`, `WhisperM8/Services/Dictation/OutputModeStore.swift:89`, `WhisperM8/Services/Dictation/OutputModeStore.swift:90`, `WhisperM8/Services/Dictation/OutputModeStore.swift:97`).

Der exakte Dateiort für Modes ist `~/Library/Application Support/WhisperM8/OutputModes.json`; die Store-URL wird aus `.applicationSupportDirectory`, Unterordner `WhisperM8` und Dateiname `OutputModes.json` aufgebaut (`WhisperM8/Services/Dictation/OutputModeStore.swift:194`, `WhisperM8/Services/Dictation/OutputModeStore.swift:195`, `WhisperM8/Services/Dictation/OutputModeStore.swift:200`, `WhisperM8/Services/Dictation/OutputModeStore.swift:201`). Custom Templates liegen getrennt in `~/Library/Application Support/WhisperM8/PostProcessingTemplates.json`, werden aber im Modes-Editor für den Template-Picker gelesen (`WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:58`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:64`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:65`, `WhisperM8/Views/OutputModesView.swift:241`).

Die globalen Behavior- und Codex-Werte werden nicht in JSON gespeichert, sondern in UserDefaults über `@AppStorage` beziehungsweise `AppPreferences`: `defaultOutputModeID`, `fallbackToRawOnProcessingError`, `showModePickerInMiniOverlay`, `codexPostProcessingModel`, `codexReasoningEffort` und `codexServiceTier` (`WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Views/OutputModesView.swift:12`, `WhisperM8/Views/OutputModesView.swift:13`, `WhisperM8/Views/OutputModesView.swift:14`, `WhisperM8/Views/OutputModesView.swift:15`, `WhisperM8/Support/AppPreferences.swift:368`, `WhisperM8/Support/AppPreferences.swift:370`, `WhisperM8/Support/AppPreferences.swift:371`, `WhisperM8/Support/AppPreferences.swift:379`, `WhisperM8/Support/AppPreferences.swift:380`, `WhisperM8/Support/AppPreferences.swift:381`).

Zur Laufzeit werden neue Recordings mit `OutputMode.defaultMode()` gestartet und der beim Stoppen ausgewählte Mode wird eingefroren, bevor Transkription und Post-Processing laufen (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:167`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:287`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:288`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:330`). Das Overlay liest `OutputMode.availableBuiltInModes()` beim Anzeigen und bei Updates; zusätzlich lauscht es auf `modesDidChangeNotification`, damit Settings-Änderungen ohne Neustart in die Mode-Liste des Overlays fließen (`WhisperM8/Windows/RecordingPanel.swift:464`, `WhisperM8/Windows/RecordingPanel.swift:538`, `WhisperM8/Windows/RecordingPanel.swift:545`, `WhisperM8/Windows/RecordingPanel.swift:687`).

Post-Processing nimmt den ausgewählten Mode, filtert Kontext nach `contextPolicy`, rendert mit dem gewählten Template ein Prompt-Paket und übergibt Modell, Thinking und Speed an `codex exec` (`WhisperM8/Services/Dictation/PostProcessingService.swift:26`, `WhisperM8/Services/Dictation/PostProcessingService.swift:31`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:244`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:257`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:67`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:70`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:71`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:72`). Raw/Fast überspringt Codex und gibt den Text über `NoOpPostProcessor` unverändert zurück (`WhisperM8/Services/Dictation/PostProcessingService.swift:17`, `WhisperM8/Services/Dictation/PostProcessingService.swift:18`).

## 5. Querverweise

- „Output Overview" hat einen eigenen Picker „Default Mode" und schreibt denselben UserDefaults-Key `defaultOutputModeID` (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Views/OutputOverviewView.swift:14`, `WhisperM8/Views/OutputOverviewView.swift:15`).
- „Templates" verwaltet die Template-Inhalte, die in „Modes" nur ausgewählt werden; Custom Templates werden in `PostProcessingTemplates.json` gespeichert (`WhisperM8/Views/OutputTemplatesView.swift:27`, `WhisperM8/Views/OutputTemplatesView.swift:124`, `WhisperM8/Views/OutputTemplatesView.swift:136`, `WhisperM8/Views/OutputTemplatesView.swift:230`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:65`).
- „Codex / ChatGPT" verwaltet globale Modell-, Thinking-, Speed- und Visual-Input-Werte, von denen die Mode-spezifischen Overrides abhängen (`WhisperM8/Views/CodexSettingsView.swift:4`, `WhisperM8/Views/CodexSettingsView.swift:5`, `WhisperM8/Views/CodexSettingsView.swift:6`, `WhisperM8/Views/CodexSettingsView.swift:7`).
- „Behavior" enthält denselben Toggle `showModePickerInMiniOverlay` und außerdem globale Kontext-/Auto-paste-Einstellungen, die die Wirkung einzelner Mode-Optionen beeinflussen (`WhisperM8/Views/Settings/BehaviorSettingsView.swift:10`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:56`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:66`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:74`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`).
- Das Recording-Overlay zeigt den Mode-Chip als Menü und deaktiviert die Mode-Auswahl während Busy-Phasen (`WhisperM8/Views/RecordingPillView.swift:103`, `WhisperM8/Views/RecordingPillView.swift:107`, `WhisperM8/Views/RecordingPillView.swift:371`, `WhisperM8/Views/RecordingPillView.swift:413`).
- Das Test Lab nutzt aktivierte Modes und denselben Fallback-Key, um Post-Processing gegen Freitext zu testen (`WhisperM8/Views/OutputTestLabView.swift:5`, `WhisperM8/Views/OutputTestLabView.swift:14`, `WhisperM8/Views/OutputTestLabView.swift:70`, `WhisperM8/Views/OutputTestLabView.swift:77`).
- Onboarding/Usage-Profil wirkt indirekt auf Modes, weil `usageProfile.wantsCodexEnrichment` Codex-abhängige Modi sperrt beziehungsweise filtert (`WhisperM8/Models/AppUsageProfile.swift:20`, `WhisperM8/Models/AppUsageProfile.swift:23`, `WhisperM8/Models/AppUsageProfile.swift:24`, `WhisperM8/Views/OutputModesView.swift:23`, `WhisperM8/Models/OutputMode.swift:255`).

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

1. Die Seite überschneidet sich stark mit „Templates" und „Codex / ChatGPT": Im Modes-Editor wählt man Templates und setzt Codex-Overrides, während die eigentlichen Template-Texte auf „Templates" und die globalen Modell-/Thinking-/Speed-Defaults auf „Codex / ChatGPT" liegen (`WhisperM8/Views/OutputModesView.swift:174`, `WhisperM8/Views/OutputModesView.swift:181`, `WhisperM8/Views/OutputModesView.swift:199`, `WhisperM8/Views/OutputModesView.swift:217`, `WhisperM8/Views/OutputModesView.swift:241`, `WhisperM8/Views/OutputTemplatesView.swift:27`, `WhisperM8/Views/CodexSettingsView.swift:56`).
2. Der Editor ist für einen einzelnen Mode sehr dicht: Name, Overlay-Label, Sichtbarkeit, Screenshot-Paste, drei globale Override-Toggles, drei bedingte Picker, Kontext-Policy, Template, Delete und Reload liegen in einer Fläche (`WhisperM8/Views/OutputModesView.swift:149`, `WhisperM8/Views/OutputModesView.swift:153`, `WhisperM8/Views/OutputModesView.swift:160`, `WhisperM8/Views/OutputModesView.swift:174`, `WhisperM8/Views/OutputModesView.swift:192`, `WhisperM8/Views/OutputModesView.swift:210`, `WhisperM8/Views/OutputModesView.swift:231`, `WhisperM8/Views/OutputModesView.swift:241`, `WhisperM8/Views/OutputModesView.swift:262`, `WhisperM8/Views/OutputModesView.swift:269`).
3. Die Benennung ist uneinheitlich: UI spricht von „Fast", Code/Keys weiterhin von `raw` und `fallbackToRawOnProcessingError`, und der sichtbare Toggle heißt „Fallback to Fast on processing errors" (`WhisperM8/Models/OutputMode.swift:127`, `WhisperM8/Models/OutputMode.swift:140`, `WhisperM8/Views/OutputModesView.swift:101`, `WhisperM8/Support/AppPreferences.swift:370`).
4. Es gibt einen Default-Widerspruch im Working Tree: `OutputModesView` nutzt als `@AppStorage`-Fallback `OutputMode.rawID`, während `AppPreferences.defaultOutputModeID` und `OutputOverviewView` auf `OutputMode.cleanID` fallen (`WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Support/AppPreferences.swift:85`, `WhisperM8/Views/OutputOverviewView.swift:6`).
5. Die Sprache ist gemischt: Die App-UI ist weitgehend Englisch („Modes", „Behavior", „Use global Thinking level"), einzelne Hilfetexte im Overlay sind Deutsch („Ziehen zum Verschieben · Doppelklick: Standardposition", „Aufnahme beenden & transkribieren"), und die Settings-Seite „Behavior" mischt deutsche Section-Titel mit englischen Controls (`WhisperM8/Views/OutputModesView.swift:51`, `WhisperM8/Views/OutputModesView.swift:97`, `WhisperM8/Views/OutputModesView.swift:192`, `WhisperM8/Views/RecordingPillView.swift:199`, `WhisperM8/Views/RecordingPillView.swift:617`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:37`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:56`).
6. Der Toggle „Show mode chip in Mini overlay" ist redundant in „Modes" und „Behavior"; beide schreiben denselben Key, aber die Begründung steht nur in Behavior ausführlicher (`WhisperM8/Views/OutputModesView.swift:104`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:131`).
7. „Drag-Reorder" ist als erwartbares Listenmuster nicht vorhanden; Custom Modes werden alphabetisch normalisiert, wodurch Nutzer keine explizite Reihenfolge für Overlay/Test Lab definieren können (`WhisperM8/Views/OutputModesView.swift:67`, `WhisperM8/Services/Dictation/OutputModeStore.swift:178`, `WhisperM8/Services/Dictation/OutputModeStore.swift:180`).

## 7. Offene Fragen

- Soll der Default-Fallback für `defaultOutputModeID` fachlich Fast/Raw oder Clean sein? Im aktuellen Working Tree widersprechen sich `OutputModesView`, `OutputOverviewView` und `AppPreferences` (`WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Support/AppPreferences.swift:85`).
- Soll es künftig eine manuelle Mode-Reihenfolge geben? Der aktuelle Code hat kein Reorder-Control und normalisiert Custom Modes alphabetisch (`WhisperM8/Views/OutputModesView.swift:67`, `WhisperM8/Services/Dictation/OutputModeStore.swift:178`, `WhisperM8/Services/Dictation/OutputModeStore.swift:180`).
- Soll die Option „Show mode chip in Mini overlay" auf „Behavior" bleiben, auf „Modes" bleiben oder nur einmal sichtbar sein? Beide Seiten schreiben denselben Key (`WhisperM8/Views/OutputModesView.swift:11`, `WhisperM8/Views/OutputModesView.swift:104`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:10`, `WhisperM8/Views/Settings/BehaviorSettingsView.swift:129`).
- Soll die sichtbare Terminologie konsequent „Fast" heißen oder sollen Code-/Doku-Namen weiterhin „Raw" erklären? Der Built-in heißt Fast, die technische ID und Preference heißen weiter Raw (`WhisperM8/Models/OutputMode.swift:127`, `WhisperM8/Models/OutputMode.swift:140`, `WhisperM8/Support/AppPreferences.swift:370`).
