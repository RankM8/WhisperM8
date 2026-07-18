# Runde 2: Settings-, Preferences- und Migrations-Sicherheit

Audit-Stand: 2026-07-18. Geprüft wurden die Settings-Pages samt Models/Kit,
`AppPreferences`, alle direkten `UserDefaults`-/`@AppStorage`-Zugriffe,
Onboarding und Update-Check sowie die Persistenzpfade für Agent-Workspace,
UI-/Grid-State, Session-Index-Cache, Output-Modes, Custom-Templates und
Transcript-Run-Reports.

## Kurzfazit

Es wurden **9 Findings** bestätigt: **0 kritisch, 4 hoch, 2 mittel, 3 niedrig**.
Das größte irreversible Datenverlust-Risiko liegt in den unversionierten Dateien
`OutputModes.json` und `PostProcessingTemplates.json`: Ein einziges inkompatibles
Element lässt den gesamten Custom-Bestand als leer erscheinen; die nächste normale
Settings-Aktion überschreibt ihn ohne Backup.

## Format- und Roundtrip-Matrix

| Persistenz | Version | Future-Version-Gate | Fehlergranularität | Backup/Recovery | Roundtrip mit älterer App |
|---|---:|---|---|---|---|
| `AgentSessions.json` | `schemaVersion`, aktuell 1 | nein | ein defektes Projekt/eine Session verwirft den ganzen Decode | Decode-Failure-Kopie + 3 Generationen | unbekannte Felder gehen beim Re-Encode verloren; Schema wird auf 1 zurückgesetzt |
| `agent-ui-state.json` inkl. Grid-Workspaces | `schemaVersion`, aktuell 4; Grid ohne eigene Version | nein | eine defekte Teilstruktur setzt den gesamten UI-State zurück | keine | unbekannte Felder werden beim automatischen Repair-Save entfernt |
| `agent-session-index-cache.json` (im Auftrag verkürzt als `agent-index-cache.json`) | keine | nein | Gesamtcache fällt auf leer | keine, aber vollständig ableitbar | nächster Scan baut ihn neu; kein Primärdatenverlust |
| `OutputModes.json` | keine, nacktes Array | nein | ein defekter Eintrag verwirft alle Einträge | keine | unbekannte Felder werden beim nächsten Save entfernt |
| `PostProcessingTemplates.json` | keine, nacktes Array | nein | ein defekter Eintrag verwirft alle Custom-Templates | keine | unbekannte Felder werden beim nächsten Save entfernt |
| `Reports/<UUID>/report.json` | keine | nein | Fehler betrifft den Einzelreport | keine, Report wird aber nicht zurückgeschrieben | inkompatibler Report wird aus UI/Index ausgelassen, Quelldatei bleibt bis zum regulären Cleanup |
| `Reports/reports-index.json` | `version`, aktuell 1 | exakt `== 1` | Gesamtindex wird verworfen | aus Reports ableitbar | wird mit Version 1 neu aufgebaut; kein Verlust der Report-Quelldateien |

Konkreter Codable-Nachweis: Ein isolierter Swift-/Foundation-Lauf mit
`struct Old: Codable { let known: Int }` dekodierte
`{"known":1,"future":{"important":"…"}}` erfolgreich und encodierte danach nur
`{"known":1}`. Ein Array, dessen zweitem Element der erforderliche Key `known`
fehlte, warf dagegen `DecodingError.keyNotFound` für `Index 1` und lieferte kein
Teilergebnis. Genau diese beiden Standardverhalten wirken in den unten genannten
keyed Containern beziehungsweise Array-Decodes.

## F1: Downgrade überschreibt neuere `AgentSessions.json` mit Schema 1

- **Schweregrad:** hoch
- **Fundort:** `WhisperM8/Models/AgentChat.swift:405-441`, `WhisperM8/Models/AgentChat.swift:577-603`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1170-1184`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:33-47`
- **Szenario:** Eine neuere App schreibt `schemaVersion: 2` und zusätzliche Workspace-, Projekt- oder Session-Felder. Danach startet eine ältere App. `JSONDecoder` ignoriert unbekannte Keys; ein unbekannter `kind` wird sogar ausdrücklich zu `nil`/effektiv `.chat`. Die Normalisierung setzt jede geladene Version bedingungslos auf 1. Weil sich der Workspace dadurch unterscheidet, erstellt der Loader zwar eine `pre-migration`-Kopie, schreibt aber anschließend die von allen unbekannten Feldern bereinigte Datei als Hauptdatei zurück. Beim erneuten Start der neueren App sind die neuen Daten aus der aktiven Datei verschwunden und nur noch manuell aus der Backup-Datei rekonstruierbar.
- **Beweis:**

  ```swift
  kind = AgentSessionKind.lenientDecode(
      try container.decodeIfPresent(String.self, forKey: .kind)
  )
  // ...
  migrated.schemaVersion = AgentWorkspace.currentSchemaVersion
  // ...
  if migrated != workspace {
      try backup(reason: "pre-migration")
      try save(migrated)
  }
  ```

  `AgentWorkspace.currentSchemaVersion` ist fest `1`; es gibt weder in `load` noch in `migratedWorkspace` eine Abweisung für `workspace.schemaVersion > currentSchemaVersion`.
- **Fix-Vorschlag:** Vor jeder Migration strikt zwischen älterem, aktuellem und neuerem Schema unterscheiden. Bei `version > current` die Datei ausschließlich read-only beziehungsweise in einem expliziten „neuere App erforderlich“-Zustand öffnen und jeden Write blockieren. Für echte Roundtrip-Kompatibilität unbekannte JSON-Felder als Raw-Payload erhalten; mindestens darf ein älterer Build die Hauptdatei nicht neu encodieren.
- **Konfidenz:** hoch

## F2: Ein defektes Workspace-Element kann den gesamten aktiven Agent-Bestand durch einen Teil-Rebuild ersetzen

- **Schweregrad:** hoch
- **Fundort:** `WhisperM8/Models/AgentChat.swift:598-603`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:33-65`, `WhisperM8/WhisperM8App.swift:281-293`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:131-143`
- **Szenario:** Nur eine Session enthält beispielsweise einen unbekannten `provider`-/`status`-Enumwert oder einen falsch typisierten Pflichtwert. Weil `projects` und `sessions` als vollständige Arrays dekodiert werden, scheitert die gesamte Datei. Sind auch die drei Generationen nicht dekodierbar oder noch nicht vorhanden, liefert der Repository-Load `.empty`. Der beim Start automatisch laufende Transcript-Scan merged anschließend nur extern rekonstruierbare Sessions und persistiert diesen Teilbestand. Projektnamen, manuelle Sessions, Gruppen, Sortierung, Initial-Prompts und andere ausschließlich in `AgentSessions.json` vorhandene Metadaten fehlen dann in der Hauptdatei. Die `decode-failed`-Kopie verhindert einen endgültigen physischen Verlust, aber es gibt keinen automatischen Merge oder einen schreibgeschützten Recovery-Modus.
- **Beweis:**

  ```swift
  projects = try container.decode([AgentProject].self, forKey: .projects)
  sessions = try container.decode([AgentChatSession].self, forKey: .sessions)
  // ...
  if let recovered = loadNewestDecodableGenerationBackup() {
      return migrate(recovered)
  }
  return .empty
  ```

  Direkt beim Launch wird danach `requestScan(reason: .launch)` ausgelöst; der Scan ruft `mergeIndexedSessions` auf.
- **Fix-Vorschlag:** Einzelne Array-Elemente verlustarm dekodieren und fehlerhafte Records mit JSON-Pfad/Raw-Daten separat quarantänisieren. Wenn eine vorhandene Hauptdatei weder selbst noch aus Generationen geladen werden kann, den Store in einen schreibgeschützten Recovery-Zustand versetzen statt `.empty` als normalen kanonischen Stand freizugeben. Erst nach bestätigter Wiederherstellung oder explizitem Reset wieder Writes erlauben.
- **Konfidenz:** hoch

## F3: `agent-ui-state.json` wird bei Future-Schema oder Teilkorruption ohne Backup destruktiv repariert

- **Schweregrad:** hoch
- **Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:45-60`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:70-108`, `WhisperM8/Models/AgentUIState.swift:223-255`, `WhisperM8/Models/AgentUIState.swift:267-284`, `WhisperM8/Models/AgentGridWorkspace.swift:94-110`, `WhisperM8/Models/AgentGridWorkspace.swift:143-156`
- **Szenario:** Zwei Varianten führen zum gleichen Verlustpfad. (1) Eine neuere App ergänzt in Schema 5 Felder oder erweitert Grid-Kapazitäten über 9; die ältere App akzeptiert `schemaVersion > 4`, normalisiert bekannte Strukturen mit ihrer alten Semantik und encodiert nur ihre `CodingKeys`. Der kanonische Bytevergleich erkennt eine Abweichung und schreibt automatisch zurück. (2) Ein einziges Fenster oder Grid enthält einen falsch typisierten Wert; der Gesamtdecode scheitert, `initialMigration` ersetzt Tabs, Fenster, Pins, Unread-Markierungen und Grids, und `needsPersist = true` überschreibt die defekte Datei sofort. Für den Sidecar existiert weder eine Vorabkopie noch eine Last-known-good-Generation.
- **Beweis:**

  ```swift
  } catch {
      state = AgentUIState.initialMigration(from: workspace)
      needsPersist = true
  }
  // ...
  if needsPersist || diskData == nil || canonical == nil || diskData != canonical {
      try saveUIState(state)
  }
  ```

  Für neuere Schemas lautet der Guard lediglich `guard schemaVersion < currentSchemaVersion else { ... normalize ...; return }`; er blockiert weder Normalisierung noch den späteren Repair-Save. `AgentGridWorkspace.normalize()` kappt zudem Slots deterministisch auf die aktuell größte Kapazität 9.
- **Fix-Vorschlag:** Future-Schemas strikt erkennen und niemals mit älterem Code zurückschreiben. UI-State-Load/Save in ein Repository mit `pre-migration`-/`decode-failed`-Kopie und rotierenden Generationen verlagern. Bei Teilfehlern nach Möglichkeit nur das betroffene Fenster/Grid quarantänisieren; bis zur erfolgreichen Recovery keinen automatischen Repair-Save ausführen.
- **Konfidenz:** hoch

## F4: Ein inkompatibler Output-Mode oder ein Custom-Template kann den gesamten Custom-Bestand löschen

- **Schweregrad:** hoch
- **Fundort:** `WhisperM8/Services/Dictation/OutputModeStore.swift:64-69`, `WhisperM8/Services/Dictation/OutputModeStore.swift:118-134`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:23-47`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:53-57`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:204-215`, `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift:56-84`
- **Szenario:** `OutputModes.json` und `PostProcessingTemplates.json` sind unversionierte Arrays. Ein einziges Element mit neuem Enumwert, fehlendem Pflichtfeld oder falschem Typ lässt jeweils den kompletten Array-Decode scheitern. Der Mode-Store ersetzt das Ergebnis im Speicher durch Built-ins; der Template-Store liefert nur seine separat eingebetteten Built-ins. Klickt der Nutzer danach auf „New“ oder ändert einen Mode, speichert das ViewModel diesen unvollständigen In-Memory-Bestand atomar über die Originaldatei. Alle zuvor vorhandenen Custom-Modes beziehungsweise Custom-Templates sind ohne Backup verloren. Auch bei erfolgreichem Downgrade-Decode werden unbekannte additive Felder beim nächsten Save still entfernt.
- **Beweis:**

  ```swift
  let modes = try JSONDecoder().decode([OutputMode].self, from: data)
  // catch:
  return []
  // ...
  if loadedModes.isEmpty {
      loadedModes = OutputMode.builtInModes
  }
  ```

  Der Template-Store hat denselben Gesamtarray-Fallback `catch { return [] }`; `createTemplate()` ruft anschließend `saveCustomTemplates(templates + [template])` auf.
- **Fix-Vorschlag:** Beide Dateien in ein versioniertes Envelope (`schemaVersion`, `entries`) überführen, Future-Versionen schreibgeschützt behandeln und vor jedem Rewrite eine Generation sichern. Dekodierbare Einträge einzeln erhalten, fehlerhafte Einträge quarantänisieren und im ViewModel einen „degraded load“-Status führen, der Saves blockiert, bis der Nutzer Recovery oder Reset bestätigt.
- **Konfidenz:** hoch

## F5: Die Provider/Model-Defaults-Migration ist für Downgrade-Teilzustände nicht idempotent

- **Schweregrad:** mittel
- **Fundort:** `WhisperM8/Models/TranscriptionProvider.swift:123-170`, `WhisperM8/Models/TranscriptionProvider.swift:173-203`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:79-87`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:17-30`
- **Szenario:** Das alte Format speicherte kombinierte Werte wie `openai_whisper` in `selectedProvider`; das neue Format trennt Provider und Modell. Nach einem Downgrade kann eine alte App `selectedProvider = openai_whisper` schreiben, während der ihr unbekannte neue Key `selectedModel` weiter existiert. Beim erneuten Upgrade beendet `migrateIfNeeded()` die Migration allein wegen des vorhandenen Modell-Keys. `loadProvider()` kann den Legacy-Wert nicht als neuen Enumwert lesen und fällt auf Groq zurück, während `loadModel()` etwa `whisper-1`/OpenAI liefert. Der Recording-Pfad lädt folglich den Groq-Key und baut einen Groq-Service mit einem logisch fremden OpenAI-Modell; die Auswahl des Nutzers ist effektiv verstellt und Aufnahmen können wegen des falschen Keys scheitern.
- **Beweis:**

  ```swift
  if preferences.selectedModelRaw != nil {
      return  // Already migrated
  }
  // ...
  return TranscriptionProvider(rawValue: raw) ?? .groq
  return TranscriptionModel(rawValue: raw) ?? .groq_whisper_v3
  ```

  Der Runtime-Pfad löst beide Werte getrennt auf und lädt den API-Key anhand des resultierenden Providers.
- **Fix-Vorschlag:** Nicht die Existenz eines Einzelkeys als Migrationsmarker verwenden. Das Paar `(provider, model)` gemeinsam validieren und Legacy-Providerwerte auch bei vorhandenem Modell migrieren. Eine explizite Preferences-Schemaversion einführen und das konsistente Paar in einem Schritt schreiben; bei Widerspruch den Provider aus dem validen Modell ableiten oder eine klare Reparaturauswahl anzeigen.
- **Konfidenz:** hoch

## F6: API-Key-Eingaben überschreiben gültige Keys zeichenweise und melden fehlgeschlagene Saves als Erfolg

- **Schweregrad:** mittel
- **Fundort:** `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:38-49`, `WhisperM8/Views/OnboardingView.swift:611-622`, `WhisperM8/Views/OnboardingView.swift:150-169`, `WhisperM8/Services/Shared/KeychainManager.swift:10-34`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:17-30`
- **Szenario:** Sobald ein Nutzer einen bestehenden Key ersetzen will, schreibt jeder Tastendruck den Zwischenstand in die Keychain; bereits das erste Zeichen ersetzt den zuvor funktionierenden Key. Schließt der Nutzer das Fenster oder wechselt den Provider während der Eingabe, bleibt der Teil-Key gespeichert. Reine Leerzeichen gelten ebenfalls als nicht leer. Zusätzlich liefert `KeychainManager.save` kein Ergebnis: Auch bei `SecItemUpdate`-/`SecItemAdd`-Fehler setzt die UI `apiKeyAvailable = true`, und das Onboarding erlaubt „Next/Done“. Der Recording-Pfad akzeptiert whitespace-only ebenfalls als nicht leer und läuft erst in einen Provider-Authentifizierungsfehler.
- **Beweis:**

  ```swift
  .onChange(of: apiKey) { _, newValue in
      guard !newValue.isEmpty else { return }
      KeychainManager.save(key: provider.keychainKey, value: newValue)
      apiKeyAvailable = true
  }
  ```

  `KeychainManager.save` loggt einen Fehlerstatus lediglich, gibt ihn aber nicht zurück; `canProceed`/`canFinish` prüfen nur `!apiKey.isEmpty || apiKeyAvailable`.
- **Fix-Vorschlag:** Eingabe als lokalen Draft halten und erst über einen expliziten „Save“-/„Verify“-Schritt committen. Whitespace trimmen und leere Werte ablehnen. `KeychainManager.save` als `throws` oder `Result` ausführen, Verfügbarkeit erst nach bestätigtem Erfolg aktualisieren und den alten Key bis dahin unangetastet lassen.
- **Konfidenz:** hoch

## F7: Ein fehlgeschlagener Re-Check löscht eine bereits bekannte Update-Meldung

- **Schweregrad:** niedrig
- **Fundort:** `WhisperM8/Services/Shared/AppUpdateChecker.swift:129-153`, `WhisperM8/Views/AppUpdateViews.swift:9-31`
- **Szenario:** Ein erfolgreicher Check findet ein Update und zeigt das Sidebar-Badge. Beim nächsten automatischen oder manuellen Check ist GitHub kurz nicht erreichbar. Während `.checking` bleibt `.available` zwar absichtlich sichtbar, im `catch` wird der Zustand aber auf `.failed` gesetzt. Das Badge verschwindet damit trotz weiterhin gültiger letzter Erfolgsinformation. Da kein letzter erfolgreicher Release separat gehalten wird, bleibt der Update-Hinweis bis zu einem späteren erfolgreichen Check weg.
- **Beweis:**

  ```swift
  if case .available = state {
      // Zustand behalten
  } else {
      state = .checking
  }
  // ...
  } catch {
      state = .failed("Update-Prüfung fehlgeschlagen ...")
      return
  }
  ```

  `SidebarUpdateBadge` rendert ausschließlich bei `.available`.
- **Fix-Vorschlag:** Letzten erfolgreichen Versionsstand getrennt vom Status des letzten Versuchs speichern. Bei transientem Fehler ein nicht-destruktives `available(info, lastError:)` beziehungsweise weiterhin `.available` anzeigen und den Fehler nur in About ergänzen. Der Checker löst selbst kein Update aus; laufende Aufnahmen/Sessions werden durch ihn nicht beendet. Die UI bietet nur einen kopierbaren Homebrew-Befehl und warnt vor dem späteren Neustart, daher wurde hierfür kein zusätzliches Finding erhoben.
- **Konfidenz:** hoch

## F8: Die einmalige Screenshot-Default-Migration ist nicht downgrade-sicher

- **Schweregrad:** niedrig
- **Fundort:** `WhisperM8/Support/AppPreferences.swift:131-139`, `WhisperM8/Support/AppPreferences.swift:359-370`
- **Szenario:** Der neue Build migriert den früheren Defaultwert 3 einmalig auf 20 und setzt dauerhaft `didMigrateMaxScreenshotsPerRecordingTo20`. Ein anschließender Downgrade kann den alten Default 3 erneut schreiben; beim nächsten Upgrade verhindert der Marker jede erneute Migration, sodass der Nutzer unerwartet dauerhaft bei 3 bleibt. Umgekehrt kann der erste Upgrade-Lauf einen bewusst vom Nutzer gewählten Wert 3 nicht vom alten Default unterscheiden und überschreibt ihn ebenfalls auf 20.
- **Beweis:**

  ```swift
  guard defaults.bool(forKey: Keys.didMigrateMaxScreenshotsPerRecordingTo20) == false else {
      return
  }
  if value <= 0 || value == 3 {
      defaults.set(Self.defaultMaxScreenshotsPerRecording, forKey: ...)
  }
  defaults.set(true, forKey: Keys.didMigrateMaxScreenshotsPerRecordingTo20)
  ```
- **Fix-Vorschlag:** Preferences insgesamt versionieren und Migrationen pro erkanntem Quellformat statt über einen permanenten Bool-Sentinel ausführen. Defaultwechsel bevorzugt über registrierte Defaults statt gespeicherter Werte modellieren; wenn ein gespeicherter Alt-Default migriert werden muss, Herkunft/App-Version separat festhalten, damit ein expliziter Nutzerwert nicht überschrieben wird.
- **Konfidenz:** hoch

## F9: Mode-Namen und Overlay-Labels werden ungeprüft als leere Werte persistiert

- **Schweregrad:** niedrig
- **Fundort:** `WhisperM8/Views/Settings/Pages/AIOutputModesTab.swift:163-173`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:88-94`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:204-215`
- **Szenario:** Ein Nutzer löscht den Namen oder das Kurzlabel eines Modes vollständig. Das TextField schreibt jede Zwischenstufe direkt über `setName`/`setShortLabel` in den Store; es gibt weder Trim-/Nonempty-Validierung noch einen Save-Commit. Dadurch entstehen dauerhaft leere Einträge in Mode-Liste und Recording-Overlay, die dort kaum identifizierbar sind. Der Template-Editor schützt Name und Instruction dagegen ausdrücklich vor Leerwerten; der Mode-Editor nicht.
- **Beweis:**

  ```swift
  func setName(_ name: String, for modeID: String) {
      updateMode(modeID) { $0.name = name }
  }
  func setShortLabel(_ label: String, for modeID: String) {
      updateMode(modeID) { $0.shortLabel = label }
  }
  // updateMode(...) ruft unmittelbar saveModes() auf.
  ```
- **Fix-Vorschlag:** Mode-Identität als Draft bearbeiten, beim Commit trimmen und leere Namen/Labels ablehnen; optional sinnvolle Längenlimits für das Overlay-Label setzen. Bis zu einem erfolgreichen Save den letzten gültigen Wert beibehalten.
- **Konfidenz:** hoch

## Geprüfte Pfade ohne zusätzliches Finding

- Onboarding besitzt bewusst keinen Completion-Flag mehr. Der automatische Start ist ausschließlich an fehlende Mikrofon- oder Accessibility-Rechte gebunden (`WhisperM8/WhisperM8App.swift:201-207`, `WhisperM8/WhisperM8App.swift:300-311`); ein normales App-Update wiederholt den Wizard daher nicht.
- Der Default-Projektordner wird über einen Directory-only-Open-Panel gewählt und vor dem Schreiben erneut mit `fileExists(..., isDirectory:)` validiert (`WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:151-181`).
- Der Custom-Template-Editor verhindert leere Namen und leere Instructions (`WhisperM8/Views/Settings/Models/TemplateEditorModel.swift:100-127`). Inhaltliche Placeholder-Kombinationen sind frei gestaltbare Produktfunktion; das Fehlen eines bestimmten Placeholders allein wurde deshalb nicht als Defekt gewertet.
- Der Session-Index-Cache fällt bei Decode-Fehler auf leer und wird beim nächsten vollständigen Scan atomar ersetzt (`WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:71-103`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:131-136`). Da er ausschließlich aus externen JSONL-Dateien abgeleitet wird, entsteht kein Primärdatenverlust.
- Transcript-Reports werden nach dem Schreiben nicht als Ganzes neu encodiert. Ein beschädigter oder inkompatibler Einzelreport wird beim Index-Rebuild ausgelassen, andere Reports bleiben sichtbar; der Index selbst ist aus den Report-Verzeichnissen rekonstruierbar (`WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:274-299`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:439-485`).
- Die alten Grid-Split-Defaults werden für die v3→v4-Migration noch gelesen, aber nicht mehr aktiv geschrieben (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:73-83`). Der verbliebene Alt-Key-Bestand hat im aktuellen v4-State keine belegbare unmittelbare Wirkung und wurde daher nicht als Finding hochgestuft.
