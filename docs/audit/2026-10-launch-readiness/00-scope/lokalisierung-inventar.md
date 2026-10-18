---
status: aktiv
updated: 2026-10-17
description: Inventar der nutzersichtbaren Strings in WhisperM8 (Sprache, Bereich, Hotspots) und Umsetzungsweg für Entscheidung E1 (Englisch als Basis, Deutsch als Lokalisierung).
---

# Lokalisierungs-Inventar (E1)

Stand: Commit `a8e0f35`, Worktree `launch-readiness`. Nur gelesen, nichts gebaut.

## Methode und Grenzen

Erfasst per Python-Regex über alle 423 Swift-Dateien in `WhisperM8/` (Kommentarzeilen ausgenommen). Das ist eine **Untergrenze**, kein vollständiges Inventar.

Muster:
- `Text`, `Button`, `Label`, `Toggle`, `Picker`, `Section`, `TextField`, `SecureField`, `Menu`, `Link`, `DisclosureGroup`, `LabeledContent`, `Stepper`
- `.help`, `.navigationTitle`, `.accessibilityLabel`, `.accessibilityHint`, `.confirmationDialog`, `.alert`
- `NSAlert.messageText` und `informativeText`, `addButton(withTitle:)`, `NSMenuItem(title:)`, `toolTip`, `placeholderString`
- `UNNotificationContent.title` und `body`
- alle String-Literale in `var errorDescription` (LocalizedError)
- in `Views/`: Labels wie `title:`, `subtitle:`, `caption:`, `message:` und die Settings-Kit-Komponenten (`SettingsSection`, `SettingsRow`, `SettingsToggleRow`, `SettingsPickerRow`, `SettingsHelpText`, `SettingsStatusRow`)
- `case …: "…"`-Zuordnungen in Models und Services (Anzeigenamen)
- CLI-Ausgaben: nur `print`/`fputs`-Literale

**Was fehlt:**
- mehrzeilige Literale (`"""`), vor allem die Hilfetexte der CLI (rund 12 Blöcke)
- Texte, die erst in Variablen oder Rückgabewerten zusammengesetzt werden
- Ternär-Ketten (176 Zeilen im Code haben `cond ? "A" : "B"`, nur teilweise erfasst)
- Strings in Tests und in den Skill-Ressourcen (`Resources/*.md`)

**Spracheinordnung** (Heuristik):
- Umlaut oder ß ergibt „de".
- Sonst entscheidet ein Abgleich mit je rund 60 häufigen deutschen und englischen Funktionswörtern.
- Ohne Treffer ist die Zeile „unklar". Das sind zu 40 % Einzelwörter („Name", „Copy", „Quit", „Speichern") und Eigennamen.
- Stichprobe (25 Zeilen): „unklar" ist in Settings, Onboarding und Menüleiste überwiegend Englisch, in Agent Chats überwiegend Deutsch.
- Unsicherheit der Heuristik: etwa ±10 Prozentpunkte.

## Gesamtzahlen

| Messung | Anzahl |
|---|---|
| Treffer der UI-Muster (ohne Model-Zuordnungen) | **1 051** in 101 Dateien |
| davon in Dateien des Delta-Bereichs (siehe unten) | 319 (30 %) |
| zusätzlich `case`-Anzeigenamen in Models/Services | 60 |
| Hochrechnung mit Lücken (mehrzeilig, Ternär, Variablen) | **1 400 bis 1 800** |
| Treffer mit `\(…)`-Interpolation | 238 (23 %) |
| `LocalizedError.errorDescription`-Strings | 159 |
| bereits lokalisierte Stellen (`String(localized:)`, `NSLocalizedString`, `Bundle.module`-Katalog) | **0** |
| vorhandene `.xcstrings`, `.strings`, `.lproj` | **keine** |

Sprachverteilung der 1 051 Treffer: 329 deutsch (31 %), 255 englisch (24 %), 467 unklar (44 %). Die 60 Model-Zuordnungen sind nicht eingerechnet (32 deutsch, 4 englisch, 24 unklar).

**Befund:** Die App ist gemischtsprachig. Settings und Onboarding sind überwiegend Englisch. Agent Chats, Sheets, Popover und Fehlermeldungen sind überwiegend Deutsch. Es gibt keine Konvention, die ein Skript prüfen könnte. Die Sprachumstellung ist deshalb in beide Richtungen nötig: rund 360 deutsche Strings brauchen eine englische Quelle, und alle englischen brauchen eine deutsche Übersetzung.

Info.plist (3 Strings, alle deutsch):
- `NSMicrophoneUsageDescription`
- `NSScreenCaptureUsageDescription`
- `NSSpeechRecognitionUsageDescription`

Weder `CFBundleDevelopmentRegion` noch `CFBundleLocalizations` ist gesetzt.

## Bereiche

Zuordnung nach Dateipfad. „Diktat" umfasst `Services/Dictation`, `Services/VoiceGate`, Recording-Pill/-Overlay, Output-Modi und Transkriptions-Models. „CLI" sind nur die erfassten `print`-Literale.

| Bereich | deutsch | englisch | unklar | gesamt | Anmerkung |
|---|---:|---:|---:|---:|---|
| Agent Chats (Views, Sheets, Popover, Services) | 220 | 35 | 129 | 384 | überwiegend deutsch, hoher Delta-Anteil |
| Settings (Seiten, Kit-Labels) | 45 | 164 | 267 | 476 | überwiegend englisch; Kit-Titel und Untertitel machen den Großteil aus |
| Diktat | 26 | 35 | 26 | 87 | Fehlertexte teils deutsch, Overlay englisch |
| Onboarding | 0 | 16 | 22 | 38 | komplett englisch |
| Menüleiste | 5 | 4 | 13 | 22 | gemischt |
| CLI-Ausgaben (separat) | 12 | 0 | 4 | 16 | plus rund 12 mehrzeilige Hilfetexte, nicht erfasst |
| Sonstiges (Shared, Support, Updater) | 21 | 1 | 6 | 28 | |
| **Summe** | **329** | **255** | **467** | **1 051** | |

**CLI:** Die CLI sollte nicht Teil der App-Lokalisierung werden. Ihre Zielgruppe sind Skripte und Agents. Empfehlung: Hilfe und Fehlermeldungen einheitlich Englisch, die Chats-CLI bleibt wie sie ist (Delta-Bereich). Das ist ein separates Thema, das die Entscheidung E1 nicht blockiert.

## Delta-Bereich

Als „Delta-Bereich" markiert sind Dateien, deren Pfad auf diese Ausschlüsse passt:
- `AgentChatsView*`
- Grid-, Tab- und Sidebar-Dateien
- `Views/Workspace/`
- `AgentWindowStore`
- `AgentControl*`
- `CLI/Chats*`
- `Resources/claude-plugin/`

Sie enthalten 319 der 1 051 Treffer. Die Strings ändern sich dort selten, aber die Dateien werden durch das Merge von `main` und die laufende Chat-Brücke noch bewegt. Praktische Folge: Diese Dateien zuletzt anfassen, oder erst nach dem Merge. Das Katalog-Gerüst ist davon unabhängig.

## Die 20 Dateien mit den meisten Strings

| # | Datei | Treffer | de | en | Delta |
|--:|---|--:|--:|--:|:-:|
| 1 | `Views/AgentChatsView.swift` | 79 | 50 | 3 | ja |
| 2 | `Views/Settings/Pages/CLISkillsSettingsPage.swift` | 60 | 1 | 27 | |
| 3 | `Views/Settings/Pages/AgentChatsSettingsPage.swift` | 44 | 5 | 17 | |
| 4 | `Views/Settings/Pages/GPTBackendSettingsPage.swift` | 40 | 16 | 0 | |
| 5 | `Views/Settings/Pages/AIOutputModesTab.swift` | 39 | 0 | 15 | ja |
| 6 | `Views/OnboardingView.swift` | 38 | 0 | 16 | |
| 7 | `Views/Settings/Pages/GPTAccountsSection.swift` | 33 | 21 | 0 | |
| 8 | `Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift` | 31 | 0 | 21 | ja |
| 9 | `Views/Settings/Pages/AgentChatsVoiceAgentTab.swift` | 29 | 0 | 12 | ja |
| 10 | `Views/AgentMoveToAccountSheet.swift` | 28 | 21 | 1 | |
| 11 | `Views/AgentChatsSidebarViews.swift` | 25 | 12 | 0 | ja |
| 12 | `Views/Settings/Pages/OutputWorkspacePage.swift` | 24 | 0 | 8 | |
| 13 | `Views/Settings/Pages/RecordingSettingsPage.swift` | 24 | 0 | 10 | |
| 14 | `Views/Settings/Pages/TranscriptionSettingsPage.swift` | 23 | 2 | 7 | |
| 15 | `Views/AgentUsagePopovers.swift` | 19 | 9 | 0 | |
| 16 | `Views/Settings/Pages/AIOutputAccountTab.swift` | 19 | 0 | 8 | ja |
| 17 | `Views/Settings/Pages/PermissionsSettingsPage.swift` | 17 | 0 | 7 | |
| 18 | `Views/AgentChatsView+Workspaces.swift` | 16 | 8 | 0 | ja |
| 19 | `Views/Settings/Pages/AIOutputTemplatesTab.swift` | 16 | 0 | 3 | ja |
| 20 | `Views/SubagentJobDetailView.swift` | 15 | 9 | 0 | |

„Delta" folgt der Pfadregel oben. `AIOutput*` und `AgentChats*Tab` treffen sie über den Namensbestandteil (Tab/Agent…), obwohl sie Settings sind. Die Spalten de und en zählen nur eindeutige Treffer, der Rest ist „unklar". Die obersten 20 Dateien enthalten rund 600 der 1 051 Treffer (57 %). Weitere Hotspots sind `ChatGPTSubscriptionTranscription.swift` (15, Fehlertexte), `MenuBarView.swift` (13) und `BackgroundDispatchModal.swift` (11).

## Muster, die eine Lokalisierung erschweren

1. **String-Interpolation mit Grammatik** (238 Treffer). Beispiele:
   - `"\(sessions.count) Tabs"`
   - `"Welche \(selection.targetCapacity) Chats bleiben?"`
   - `"\(visibleCount) von \(counts.all) Chats"`

   `Text("… \(x) …")` wird als LocalizedStringKey mit `%lld`/`%@` extrahiert und ist unkritisch. Als reiner `String` (Variable, `errorDescription`, NSAlert) braucht es `String(localized:)`. Stellen, die Teile aus Funktionsaufrufen einbauen (`provider.displayName`, `selectedProject?.name ?? "…"`, `group.reason.label`), müssen vorher in vollständige Sätze mit Platzhaltern umgebaut werden.
2. **Zusammengesetzte Sätze.** Beispiele:
   - `"\(group.reason.label) (\(group.titles.count))"` im Account-Wechsel-Sheet
   - `"Nicht gewechselt — \(group.reason.label) …"`

   Ein Teilsatz kommt aus einem Enum-Label, der Rest aus dem View. Das ist in Sprachen mit anderer Wortstellung nicht übersetzbar. Lösung: pro Kombination ein Satz mit Platzhalter, oder Label und Zähler getrennt darstellen.
3. **Hart kodierte Pluralformen.** Beispiele: `\(n) Tabs`, `\(n) Chats`, `config(s)`, `(n)`. Gefunden sind nur 5 klare Fälle, die Zahl der verdeckten ist höher (Sekunden, Minuten, Dateien in Ternär-Ketten). Lösung: Plural-Variationen im String Catalog (`%lld` mit one/other).
4. **Ternär-Ketten und `if`-Zweige mit Literalen** (176 Zeilen). Jeder Zweig ist ein eigener Katalogeintrag. Die Satzteile hinter `? :` landen oft in einem `Text(…)` als `String`-Ausdruck und werden dann **nicht** automatisch lokalisiert (siehe „Falle 1" unten).
5. **Strings in Modellen und Enums.** Beispiele:
   - `displayName`/`label` in `TranscriptionProvider`, `AppUsageProfile`
   - Planner-Gründe in `AccountSwitchPlanner` und `AccountMovePlanner`
   - Zustände in `AgentSessionStateMachine` und `ClaudeGPTMixRouter`
   - `DebugControl`

   Hier gibt es keinen SwiftUI-Kontext. Es braucht `String(localized:)` oder eine `LocalizedStringResource`-Eigenschaft.
6. **LocalizedError-Texte als Fehlerkanal** (159). Sie landen in Logs, in CLI-Ausgaben, im Control-Socket und in der UI. **Regel:** Logs und Socket bleiben Englisch (nicht lokalisiert), die UI zeigt die lokalisierte Fassung. Sonst sind Logs je nach Systemsprache nicht greppbar.
7. **Strings in Logik und Vergleichen** (7 klare Stellen, ohne Anspruch auf Vollständigkeit). Es wurde nur nach Vergleichen mit deutschen Literalen gesucht. Prüfen: Stellen, die UI-Text mit `==`/`contains` auswerten (Tab-Namen, Menütitel, Stellvertreter für Zustände). Vor der Umstellung jede mit dem Enum-Fall ersetzen.
8. **Mehrsprachige Quellen außerhalb des Codes:**
   - Die Skill-Ressourcen (`Resources/*.md`) sind deutsch und gehören den Agents, nicht der UI. Sie werden nicht lokalisiert; eine Entscheidung steht aus.
   - Die Texte der Claude-Plugin-Mod (`register.tsx`) sind Delta-Bereich.
   - Tests und Snapshot-Fixtures (`UISnapshotGallery`) vergleichen teils deutsche Texte. Jede Umstellung der Quellsprache kippt diese Tests.
9. **Datum/Zahl.** 17 Dateien nutzen `DateFormatter`/`RelativeDateTimeFormatter`. Hier ist zu prüfen, ob eine feste Locale gesetzt ist (Vorbedingung: nirgends `Locale(identifier: "de_DE")` fest verdrahtet; gefunden habe ich das nicht, aber nicht abschließend geprüft).
10. **Eigennamen und Kommandos** (`Claude Code`, `Codex`, `whisperm8 chats …`, Hotkey-Namen) dürfen nie übersetzt werden. Sie sollten als Platzhalter oder mit Kommentar im Katalog stehen.

## Umsetzungsweg

### Ist-Zustand des Build-Wegs

- `Package.swift` (tools 5.9): ein `executableTarget` mit `path: "WhisperM8"`, **ohne** `defaultLocalization`. `Info.plist` ist per `exclude` ausgenommen.
- Ressourcen sind explizit gelistet (`.copy`/`.process`). Daraus entsteht `WhisperM8_WhisperM8.bundle`.
- Das Makefile (`_bundle`) macht dreierlei:
  - Es kopiert die Binary und `WhisperM8/Info.plist` von Hand.
  - Es kopiert ausgewählte Ressourcen einzeln nach `Contents/Resources` (Icons, Skill-Markdown).
  - Es kopiert alle `*.bundle` aus dem Build-Ordner nach `Contents/Resources`.
- `scripts/patch-resource-accessors.sh` biegt den generierten `Bundle.module`-Accessor auf `Bundle.main.resourceURL`. Ohne den Patch crasht die App auf fremden Macs.
- Toolchain: Swift 6.2.3 (Xcode vorhanden). SwiftPM ab 5.9 verarbeitet `.xcstrings` als Ressource. Das ist dokumentiert, im Repo aber nicht erprobt und deshalb ein Spike-Punkt.

### Zwei Fallen, die ein naiver Versuch trifft

**Falle 1: SwiftUI sucht in `Bundle.main`, nicht in `Bundle.module`.** `Text("Start")` schlägt im Hauptbundle der App nach (`Contents/Resources/<lang>.lproj/Localizable.strings`). Ein Katalog, der nur in `WhisperM8_WhisperM8.bundle` liegt, bleibt ungenutzt. Zwei Wege:
- (a) **Empfohlen:** Das Makefile legt die kompilierten `.lproj`-Ordner zusätzlich direkt nach `Contents/Resources/` (aus dem Resource-Bundle kopieren). Dann funktionieren alle `Text("…")`-Literale, `Button("…")` usw. **ohne** Code-Änderung.
- (b) Jedes Literal bekommt `bundle: .module`. Das sind rund 1 000 Code-Änderungen und ist fehleranfällig. Nicht empfohlen.

`String`-Variablen werden nie automatisch lokalisiert: `Text(someString)` zeigt den Text unverändert. Dort braucht es `String(localized: "key", comment: "…")`, das im Hauptbundle sucht (passt zu (a)).

**Falle 2: Info.plist-Texte.** Die Berechtigungstexte kommen aus `InfoPlist.strings` im Hauptbundle. Das Makefile muss `en.lproj/InfoPlist.strings` und `de.lproj/InfoPlist.strings` kopieren. Zusätzlich fehlen in `Info.plist` `CFBundleDevelopmentRegion` (`en`) und `CFBundleLocalizations` (`en`, `de`); ohne sie ignoriert macOS die Lokalisierungen.

### Katalog-Format

`.xcstrings` ist das Zielformat: eine JSON-Datei, Plural-Variationen, Status je Sprache (`translated`, `needs_review`). Beim Build erzeugt SwiftPM daraus die `.strings`/`.stringsdict` je Sprache. Fallback, falls der Spike dagegen spricht: klassische `en.lproj/Localizable.strings` und `de.lproj/Localizable.strings` plus `.stringsdict` für Plurale. Das ist größer im Diff, aber toolchain-unabhängig.

Die Extraktion neuer Schlüssel macht normalerweise Xcode beim Build. Ohne `.xcodeproj` gibt es das nicht. Das heißt: Der Katalog wird **nicht** automatisch gefüllt. Er entsteht einmalig per Skript aus dem Quelltext (Basis ist dieses Inventar) und wird danach von Hand und per Prüfskript gepflegt. Die Alternative ist `swiftc -emit-localized-strings` bzw. `genstrings`; ob sie mit SwiftPM-Aufrufen sauber laufen, klärt der Spike.

### Schlüssel-Konvention

**Englischer Text als Schlüssel** (`Text("Start recording")`). Gründe:
- Es braucht keine Code-Änderung an den rund 600 englischen Literalen.
- Die Entwicklungssprache bleibt lesbar.
- Fehlt ein Eintrag, zeigt die App Englisch statt eines Platzhalters.

Symbolische Schlüssel (`recording.start`) wären sauberer bei Umformulierungen, kosten aber den kompletten Umbau jedes Aufrufs. Die rund 360 deutschen Literale müssen so oder so ins Englische umgeschrieben werden; das ist die eigentliche Handarbeit.

### Schritte

1. **Spike (0,5 bis 1 Tag), vor allem anderen.** Minimaler `Localizable.xcstrings` mit zwei Einträgen, `defaultLocalization: "en"`, `.process("Resources/Localizable.xcstrings")`. Prüfen:
   - Was legt `swift build -c release` im Resource-Bundle ab (`en.lproj`, `de.lproj`)?
   - Greift `Text("…")` nach dem Kopieren der `.lproj`-Ordner nach `Contents/Resources`?
   - Übersteht die Signatur (`codesign --verify --deep --strict`, aktuell Pflicht)?
   - Greift `make dev` per `rsync`, und bleiben TCC-Rechte erhalten?
   - Greift der Accessor-Patch weiterhin?
   - Funktioniert `AppleLanguages` zum Testen (`-AppleLanguages "(de)"`)?

   Das Ergebnis entscheidet zwischen `.xcstrings` und `.strings`.
2. **Gerüst (1 Tag).**
   - `Package.swift`: `defaultLocalization: "en"`, Katalog als Ressource.
   - Makefile: `.lproj`-Kopie in `_bundle`, `InfoPlist.strings`, `CFBundleLocalizations` und `CFBundleDevelopmentRegion` in der `Info.plist`. Außerdem prüfen, ob `scripts/build-dmg.sh` und `release.yml` denselben Weg gehen (`build-dmg.sh` liest `Info.plist` separat).
   - Doku-Eintrag in `CLAUDE.md`: neue Ressourcen brauchen `Package.swift` **und** Makefile.
3. **Extraktions-Skript (0,5 Tag).** Liest die Treffer wie dieses Inventar und schreibt den Rohkatalog (Schlüssel, Quelltext, Fundstelle als Kommentar). Wird wegwerfbar.
4. **Strings umstellen, bereichsweise (4 bis 6 Tage mit Agent-Unterstützung).** Reihenfolge nach Zielgruppe-Wirkung:
   - (a) Onboarding, Menüleiste, Diktat, Recording-Overlay (Pfad W2/W3 aus der Launch-Definition),
   - (b) Settings (englisch, wenig Arbeit),
   - (c) Fehlertexte (`errorDescription`, NSAlert) mit `String(localized:)`,
   - (d) Agent Chats und Sheets (deutsch → englisch umschreiben) **nach** dem Merge von `main`, weil der Delta-Bereich (319 Treffer) sich noch bewegt.

   Je Bereich: Katalog füllen, Deutsch prüfen, Snapshots mit `make snapshots` in beiden Sprachen ansehen (`-AppleLanguages`).
5. **Umbauten der Problemmuster (1 bis 2 Tage).** Zusammengesetzte Sätze, Plurale, Ternär-Ketten und Enum-Labels (Muster 1 bis 5).
6. **CLI und Skills (separat, 0,5 Tag).** Entscheidung: CLI einheitlich Englisch, Skills unverändert. Nicht Teil von E1.

### Aufwand

| Posten | Schätzung |
|---|---|
| Spike und Gerüst | 1,5 bis 2 Tage |
| Katalog erzeugen, Strings umstellen (1 100 bis 1 800 Stellen) | 4 bis 6 Tage |
| Problemmuster umbauen | 1 bis 2 Tage |
| Übersetzung prüfen, Snapshots, Tests anpassen (`UISnapshotGallery`, deutsche Erwartungswerte) | 1 bis 2 Tage |
| **Summe** | **8 bis 12 Personentage** (etwa 2 Wochen), davon rund 30 % im Delta-Bereich nach dem Merge |

Die Zahl nimmt an, dass die Übersetzung selbst (rund 1 100 bis 1 800 Strings) vom Agent vorgeschlagen und vom User stichprobenartig geprüft wird. Wird jede Zeile von Hand geprüft, kommen 2 bis 3 Tage dazu. Reine Übersetzer-Arbeit ist hier nicht eingerechnet.

### Neue unlokalisierte Strings verhindern

1. **Test `LocalizationCatalogTests`** (läuft in CI mit `swift test`): lädt den Katalog und prüft, dass jeder Eintrag `en` und `de` hat, nicht `needs_review` ist und Plural-Einträge beide Formen haben. Das ist der billigste und zuverlässigste Schutz.
2. **Skript `scripts/check-l10n.sh`** (in `ci.yml` vor dem Build): findet `Text("…")`, `Button("…")`, `Label`, `.help`, `NSAlert`-Zuweisungen mit Literal, das **nicht** im Katalog steht. Zusätzlich verbietet es `Text(verbatim:)` nur in einer Allowlist. Ausnahmen (Eigennamen, Debug-Ausgaben) werden mit `// l10n:ignore` markiert.
3. **Regel für `String`-Literale in `errorDescription` und NSAlert:** nur über `String(localized:)`. Das Skript meldet rohe Literale in diesen Kontexten.
4. **Pseudo-Lokalisierung** als Sichtprüfung: ein dritter Katalog-Stand (`xx`) mit Rahmen um jeden Text zeigt in den Snapshots sofort alle Texte, die nicht durch den Katalog laufen.
5. **Konvention in `CLAUDE.md`** (ein Absatz): Quellsprache Englisch, neue UI-Texte nur über Katalog, Eigennamen nicht übersetzen, Logs und Socket-Texte bleiben Englisch.

### Offene Entscheidungen für den User

- Schlüssel: Englischer Text (empfohlen) oder symbolische Schlüssel?
- CLI-Sprache: Englisch einheitlich (empfohlen)?
- Skill-Markdown und Plugin-Mod-Texte: nicht lokalisieren (empfohlen) oder doch?
- Zeitpunkt: Gerüst und Bereiche a bis c jetzt, Agent Chats nach dem Merge von `main` und der Chat-Brücke.
