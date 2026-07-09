---
description: Settings-Seite „About" — Referenz von Branding, Version, Update-Prüfung und Links.
description_long: |
  Vollständige Referenz der Settings-Seite „About": UI-Aufbau, reine Anzeigen,
  Update-Statuszustände, Buttons, Links, Datenquellen und Persistenz. Grundlage
  für das Settings-Redesign mit belegten UX-Beobachtungen zu Update-Auffindbarkeit
  und Sprachmix.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 1 Zeilenverweis korrigiert)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `AboutSettingsPage.swift` + Doku-Verweis [ARCHITEKTUR: Pages](../../features/settings/ARCHITECTURE.md#pages).

# Settings: About

> **Sidebar-Gruppe:** App · **View:** `WhisperM8/Views/Settings/AboutView.swift` · **Enum-Case:** `ControlCenterSection.about` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `AboutView.swift`, `Views/AppUpdateViews.swift`

## 1. Zweck & Überblick

Die Seite „About" ist der App-Info-Bereich im Settings-Fenster: `ControlCenterSection.about` trägt den sichtbaren Namen `About`, gehört zur Sidebar-Gruppe `App` und nutzt das Symbol `info.circle` (`WhisperM8/Views/SettingsView.swift:18`, `WhisperM8/Views/SettingsView.swift:92`, `WhisperM8/Views/SettingsView.swift:104`). Beim Öffnen des Detailbereichs rendert die Settings-Navigation `AboutView()` und setzt den Navigationstitel auf den Raw-Value der Sektion (`WhisperM8/Views/SettingsView.swift:244`, `WhisperM8/Views/SettingsView.swift:246`). Inhaltlich zeigt die Seite App-Icon, App-Name, Version/Build, Produktbeschreibung, Update-Status und Hersteller-Link (`WhisperM8/Views/Settings/AboutView.swift:27`, `WhisperM8/Views/Settings/AboutView.swift:29`, `WhisperM8/Views/Settings/AboutView.swift:34`, `WhisperM8/Views/Settings/AboutView.swift:37`, `WhisperM8/Views/Settings/AboutView.swift:41`, `WhisperM8/Views/Settings/AboutView.swift:50`, `WhisperM8/Views/Settings/AboutView.swift:57`).

## 2. UI-Aufbau

Die Seite ist als `Form` mit `.formStyle(.grouped)` aufgebaut; der Kommentar im Code begründet das mit einem früheren Layout-Überlauf bei knapper Fensterhöhe, den die Form durch Scrollen vermeidet (`WhisperM8/Views/Settings/AboutView.swift:19`, `WhisperM8/Views/Settings/AboutView.swift:25`, `WhisperM8/Views/Settings/AboutView.swift:62`, `WhisperM8/Views/Settings/AboutView.swift:63`). Die erste Section enthält einen zentrierten `VStack` mit 64x64-App-Icon, Titel „WhisperM8", Versionszeile und Produktbeschreibung (`WhisperM8/Views/Settings/AboutView.swift:27`, `WhisperM8/Views/Settings/AboutView.swift:28`, `WhisperM8/Views/Settings/AboutView.swift:29`, `WhisperM8/Views/Settings/AboutView.swift:32`, `WhisperM8/Views/Settings/AboutView.swift:34`, `WhisperM8/Views/Settings/AboutView.swift:37`, `WhisperM8/Views/Settings/AboutView.swift:41`). Die zweite Section heißt „Updates" und bettet `AboutUpdateSection()` ein (`WhisperM8/Views/Settings/AboutView.swift:50`, `WhisperM8/Views/Settings/AboutView.swift:51`). Die letzte Section enthält einen horizontal zentrierten Link „Built by 360WebManager" auf `https://360web-manager.com/` (`WhisperM8/Views/Settings/AboutView.swift:54`, `WhisperM8/Views/Settings/AboutView.swift:55`, `WhisperM8/Views/Settings/AboutView.swift:57`).

## 3. Optionen im Detail

### Navigationstitel „About"

| Aspekt | Wert |
|---|---|
| Control | Navigationstitel des Settings-Detailbereichs; `AboutView()` wird für `ControlCenterSection.about` gerendert und erhält `.navigationTitle(section.rawValue)` (`WhisperM8/Views/SettingsView.swift:244`, `WhisperM8/Views/SettingsView.swift:246`). |
| Default | Der Raw-Value des Enum-Cases ist `About` (`WhisperM8/Views/SettingsView.swift:18`). |
| Persistenz | Keine eigene Persistenz; der Detailtitel wird aus dem Enum-Raw-Value gelesen (`WhisperM8/Views/SettingsView.swift:18`, `WhisperM8/Views/SettingsView.swift:246`). |
| Gelesen von | `WhisperM8/Views/SettingsView.swift:244`, `WhisperM8/Views/SettingsView.swift:246`. |
| Wirkung | Zeigt im Settings-Detailbereich den Titel „About" und lädt die About-Seite (`WhisperM8/Views/SettingsView.swift:244`, `WhisperM8/Views/SettingsView.swift:246`). |
| Abhängigkeiten | Gehört zur Sidebar-Gruppe `App`; die Gruppe umfasst `.permissions`, `.hotkey`, `.audio`, `.behavior`, `.cli` und `.about` (`WhisperM8/Views/SettingsView.swift:104`). |

### App-Icon

| Aspekt | Wert |
|---|---|
| Control | Reine Anzeige über `Image(nsImage: NSApp.applicationIconImage)` mit `resizable()`, `.aspectRatio(contentMode: .fit)` und 64x64-Frame (`WhisperM8/Views/Settings/AboutView.swift:29`, `WhisperM8/Views/Settings/AboutView.swift:30`, `WhisperM8/Views/Settings/AboutView.swift:31`, `WhisperM8/Views/Settings/AboutView.swift:32`). |
| Default | Das Icon kommt zur Laufzeit aus `NSApp.applicationIconImage` (`WhisperM8/Views/Settings/AboutView.swift:29`). |
| Persistenz | Keine eigene Settings-Persistenz; die Anzeige liest den AppKit-App-Icon-Wert (`WhisperM8/Views/Settings/AboutView.swift:29`). |
| Gelesen von | `WhisperM8/Views/Settings/AboutView.swift:29`. |
| Wirkung | Visuelle Identifikation der App innerhalb der About-Seite (`WhisperM8/Views/Settings/AboutView.swift:29`, `WhisperM8/Views/Settings/AboutView.swift:32`). |
| Abhängigkeiten | Das Icon steht in der oberen, zentrierten `VStack` der ersten Section (`WhisperM8/Views/Settings/AboutView.swift:27`, `WhisperM8/Views/Settings/AboutView.swift:28`). |

### App-Name „WhisperM8"

| Aspekt | Wert |
|---|---|
| Control | Reine Textanzeige `Text("WhisperM8")` mit `.font(.title2.bold())` (`WhisperM8/Views/Settings/AboutView.swift:34`, `WhisperM8/Views/Settings/AboutView.swift:35`). |
| Default | Statischer String `WhisperM8` im View-Code (`WhisperM8/Views/Settings/AboutView.swift:34`). |
| Persistenz | Keine Persistenz; der Text ist hart codiert (`WhisperM8/Views/Settings/AboutView.swift:34`). |
| Gelesen von | `WhisperM8/Views/Settings/AboutView.swift:34`. |
| Wirkung | Zeigt den App-Namen prominent unter dem Icon (`WhisperM8/Views/Settings/AboutView.swift:28`, `WhisperM8/Views/Settings/AboutView.swift:34`, `WhisperM8/Views/Settings/AboutView.swift:35`). |
| Abhängigkeiten | Keine sichtbare Abhängigkeit von `CFBundleName`; `Info.plist` enthält zwar `CFBundleName = WhisperM8`, die About-Anzeige liest diesen Key aber nicht (`WhisperM8/Info.plist:7`, `WhisperM8/Info.plist:8`, `WhisperM8/Views/Settings/AboutView.swift:34`). |

### Versions-/Build-Anzeige

| Aspekt | Wert |
|---|---|
| Control | Reine Textanzeige `Text(versionText)` mit Caption-Font und sekundärer Farbe (`WhisperM8/Views/Settings/AboutView.swift:37`, `WhisperM8/Views/Settings/AboutView.swift:38`, `WhisperM8/Views/Settings/AboutView.swift:39`). |
| Default | `versionText` liest `CFBundleShortVersionString` und `CFBundleVersion`; im aktuellen `Info.plist` stehen beide auf `2.7.0`, daher ergibt die Logik „Version 2.7.0" statt „Version 2.7.0 (2.7.0)" (`WhisperM8/Views/Settings/AboutView.swift:5`, `WhisperM8/Views/Settings/AboutView.swift:6`, `WhisperM8/Views/Settings/AboutView.swift:8`, `WhisperM8/Views/Settings/AboutView.swift:10`, `WhisperM8/Info.plist:9`, `WhisperM8/Info.plist:10`, `WhisperM8/Info.plist:11`, `WhisperM8/Info.plist:12`). |
| Persistenz | Keine Settings-Persistenz; Datenquelle ist das Bundle-Info-Dictionary (`WhisperM8/Views/Settings/AboutView.swift:5`, `WhisperM8/Views/Settings/AboutView.swift:6`). |
| Gelesen von | `WhisperM8/Views/Settings/AboutView.swift:4`, `WhisperM8/Views/Settings/AboutView.swift:37`. |
| Wirkung | Zeigt Version und optional Build an: unterschiedliche Werte werden als `Version <version> (<build>)` formatiert, nur Version als `Version <version>`, nur Build als `Build <build>`, fehlende Werte als `Version unknown` (`WhisperM8/Views/Settings/AboutView.swift:7`, `WhisperM8/Views/Settings/AboutView.swift:8`, `WhisperM8/Views/Settings/AboutView.swift:9`, `WhisperM8/Views/Settings/AboutView.swift:10`, `WhisperM8/Views/Settings/AboutView.swift:11`, `WhisperM8/Views/Settings/AboutView.swift:12`, `WhisperM8/Views/Settings/AboutView.swift:13`, `WhisperM8/Views/Settings/AboutView.swift:14`, `WhisperM8/Views/Settings/AboutView.swift:15`). |
| Abhängigkeiten | Der Update-Checker liest für Vergleiche ebenfalls `CFBundleShortVersionString`, aber nicht `CFBundleVersion` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:62`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:63`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:64`). |

### Produktbeschreibung

| Aspekt | Wert |
|---|---|
| Control | Reine Textanzeige `Text("Native macOS dictation with AI transcription")` mit Caption-Font, sekundärer Farbe und zentrierter Mehrzeilen-Ausrichtung (`WhisperM8/Views/Settings/AboutView.swift:41`, `WhisperM8/Views/Settings/AboutView.swift:42`, `WhisperM8/Views/Settings/AboutView.swift:43`, `WhisperM8/Views/Settings/AboutView.swift:44`). |
| Default | Statischer englischer String im View-Code (`WhisperM8/Views/Settings/AboutView.swift:41`). |
| Persistenz | Keine Persistenz; der Text ist hart codiert (`WhisperM8/Views/Settings/AboutView.swift:41`). |
| Gelesen von | `WhisperM8/Views/Settings/AboutView.swift:41`. |
| Wirkung | Erklärt die App als native macOS-Diktier-App mit KI-Transkription (`WhisperM8/Views/Settings/AboutView.swift:41`). |
| Abhängigkeiten | Keine technische Abhängigkeit; die Anzeige liegt in derselben Branding-Section wie App-Name und Versionszeile (`WhisperM8/Views/Settings/AboutView.swift:27`, `WhisperM8/Views/Settings/AboutView.swift:28`, `WhisperM8/Views/Settings/AboutView.swift:34`, `WhisperM8/Views/Settings/AboutView.swift:37`, `WhisperM8/Views/Settings/AboutView.swift:41`). |

### Section-Titel „Updates"

| Aspekt | Wert |
|---|---|
| Control | Section-Header `Section("Updates")` (`WhisperM8/Views/Settings/AboutView.swift:50`). |
| Default | Statischer String `Updates` (`WhisperM8/Views/Settings/AboutView.swift:50`). |
| Persistenz | Keine Persistenz; der Section-Titel ist hart codiert (`WhisperM8/Views/Settings/AboutView.swift:50`). |
| Gelesen von | `WhisperM8/Views/Settings/AboutView.swift:50`. |
| Wirkung | Gruppiert den eingebetteten `AboutUpdateSection()` visuell unter „Updates" (`WhisperM8/Views/Settings/AboutView.swift:50`, `WhisperM8/Views/Settings/AboutView.swift:51`). |
| Abhängigkeiten | Der Inhalt der Section hängt vom Zustand `AppUpdateChecker.shared.state` ab (`WhisperM8/Views/AppUpdateViews.swift:125`, `WhisperM8/Views/AppUpdateViews.swift:129`). |

### Button „Nach Updates suchen"

| Aspekt | Wert |
|---|---|
| Control | Button aus `checkButton("Nach Updates suchen")` im Zustand `.unknown` (`WhisperM8/Views/AppUpdateViews.swift:129`, `WhisperM8/Views/AppUpdateViews.swift:130`, `WhisperM8/Views/AppUpdateViews.swift:131`). |
| Default | Sichtbar, solange `AppUpdateChecker.state` auf `.unknown` steht; der Checker initialisiert `state` mit `.unknown` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:42`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:50`, `WhisperM8/Views/AppUpdateViews.swift:130`, `WhisperM8/Views/AppUpdateViews.swift:131`). |
| Persistenz | Kein Button-Wert wird gespeichert; der Klick ruft `Task { await checker.checkNow() }` auf (`WhisperM8/Views/AppUpdateViews.swift:161`, `WhisperM8/Views/AppUpdateViews.swift:162`, `WhisperM8/Views/AppUpdateViews.swift:163`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:125`, `WhisperM8/Views/AppUpdateViews.swift:131`, `WhisperM8/Views/AppUpdateViews.swift:163`. |
| Wirkung | Startet manuell eine Update-Prüfung gegen den geteilten `AppUpdateChecker` (`WhisperM8/Views/AppUpdateViews.swift:125`, `WhisperM8/Views/AppUpdateViews.swift:163`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:116`). |
| Abhängigkeiten | Der manuelle Check funktioniert unabhängig vom automatischen Kill-Switch; der Code-Kommentar nennt „manueller Check in About geht immer", während der Kill-Switch nur `scheduleAutomaticChecks()` betrifft (`WhisperM8/Services/Shared/AppUpdateChecker.swift:27`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:94`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:95`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:96`). |

### Status „Suche nach Updates …"

| Aspekt | Wert |
|---|---|
| Control | `HStack` mit `ProgressView().controlSize(.small)` und Text `Suche nach Updates …` im Zustand `.checking` (`WhisperM8/Views/AppUpdateViews.swift:132`, `WhisperM8/Views/AppUpdateViews.swift:133`, `WhisperM8/Views/AppUpdateViews.swift:134`, `WhisperM8/Views/AppUpdateViews.swift:135`). |
| Default | Nicht initial sichtbar; der Checker setzt `state = .checking`, sofern kein `.available`-Zustand erhalten bleiben soll (`WhisperM8/Services/Shared/AppUpdateChecker.swift:129`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:135`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:137`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:138`). |
| Persistenz | Keine Persistenz; `state` ist `@Published private(set)` im Speicher (`WhisperM8/Services/Shared/AppUpdateChecker.swift:50`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:129`, `WhisperM8/Views/AppUpdateViews.swift:132`, `WhisperM8/Views/AppUpdateViews.swift:135`. |
| Wirkung | Informiert während der laufenden Netzwerkprüfung über den temporären Suchzustand (`WhisperM8/Views/AppUpdateViews.swift:132`, `WhisperM8/Views/AppUpdateViews.swift:135`). |
| Abhängigkeiten | `checkNow()` ist idempotent und wartet auf einen bereits laufenden Check statt doppelt zu starten (`WhisperM8/Services/Shared/AppUpdateChecker.swift:114`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:116`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:117`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:118`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:119`). |

### Status „WhisperM8 <Version> ist aktuell"

| Aspekt | Wert |
|---|---|
| Control | `Label("WhisperM8 \(current.description) ist aktuell", systemImage: "checkmark.circle")` im Zustand `.upToDate` (`WhisperM8/Views/AppUpdateViews.swift:139`, `WhisperM8/Views/AppUpdateViews.swift:141`). |
| Default | Sichtbar, wenn die remote Version nicht größer als die lokale Version ist; dann setzt der Checker `.upToDate(current: current)` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:162`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:171`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:172`). |
| Persistenz | Keine Persistenz; der aktuelle Zustand liegt in `AppUpdateChecker.state` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:42`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:45`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:50`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:139`, `WhisperM8/Views/AppUpdateViews.swift:141`. |
| Wirkung | Bestätigt, dass kein neueres Release angeboten wird (`WhisperM8/Services/Shared/AppUpdateChecker.swift:162`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:171`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:172`). |
| Abhängigkeiten | Der Versionsvergleich nutzt `SemanticVersion` und dessen numerischen Vergleich über Major, Minor und Patch (`WhisperM8/Services/Shared/SemanticVersion.swift:41`, `WhisperM8/Services/Shared/SemanticVersion.swift:42`, `WhisperM8/Services/Shared/SemanticVersion.swift:43`, `WhisperM8/Services/Shared/SemanticVersion.swift:44`). |

### Button „Erneut suchen"

| Aspekt | Wert |
|---|---|
| Control | Button aus `checkButton("Erneut suchen")` im Zustand `.upToDate` (`WhisperM8/Views/AppUpdateViews.swift:139`, `WhisperM8/Views/AppUpdateViews.swift:144`). |
| Default | Sichtbar zusammen mit dem Up-to-date-Label (`WhisperM8/Views/AppUpdateViews.swift:139`, `WhisperM8/Views/AppUpdateViews.swift:140`, `WhisperM8/Views/AppUpdateViews.swift:141`, `WhisperM8/Views/AppUpdateViews.swift:144`). |
| Persistenz | Kein Button-Wert wird gespeichert; der Klick ruft erneut `checker.checkNow()` auf (`WhisperM8/Views/AppUpdateViews.swift:161`, `WhisperM8/Views/AppUpdateViews.swift:162`, `WhisperM8/Views/AppUpdateViews.swift:163`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:144`, `WhisperM8/Views/AppUpdateViews.swift:163`. |
| Wirkung | Ermöglicht eine manuelle Wiederholung der Update-Prüfung nach einem Up-to-date-Ergebnis (`WhisperM8/Views/AppUpdateViews.swift:144`, `WhisperM8/Views/AppUpdateViews.swift:163`). |
| Abhängigkeiten | Nutzt dieselbe `checkButton`-Hilfsfunktion wie „Nach Updates suchen" und „Erneut versuchen" (`WhisperM8/Views/AppUpdateViews.swift:131`, `WhisperM8/Views/AppUpdateViews.swift:144`, `WhisperM8/Views/AppUpdateViews.swift:155`, `WhisperM8/Views/AppUpdateViews.swift:161`). |

### Update verfügbar: Headline

| Aspekt | Wert |
|---|---|
| Control | Text `Version \(info.latestVersion.description) verfügbar` in `AppUpdateDetailsView` (`WhisperM8/Views/AppUpdateViews.swift:38`, `WhisperM8/Views/AppUpdateViews.swift:39`, `WhisperM8/Views/AppUpdateViews.swift:44`). |
| Default | Sichtbar, wenn `AppUpdateChecker.state` `.available(let info)` ist (`WhisperM8/Views/AppUpdateViews.swift:146`, `WhisperM8/Views/AppUpdateViews.swift:147`). |
| Persistenz | Keine Persistenz; `UpdateInfo.latestVersion` ist Teil des im Speicher gehaltenen Checker-Zustands (`WhisperM8/Services/Shared/AppUpdateChecker.swift:32`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:34`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:46`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:50`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:44`, `WhisperM8/Views/AppUpdateViews.swift:147`. |
| Wirkung | Zeigt die neuere Release-Version an (`WhisperM8/Views/AppUpdateViews.swift:44`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:162`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:164`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:166`). |
| Abhängigkeiten | Die neuere Version stammt aus dem GitHub-Release-Feld `tag_name`, das als `LatestRelease.tagName` decodiert und als `SemanticVersion` geparst wird (`WhisperM8/Services/Shared/AppUpdateChecker.swift:156`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:157`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:176`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:181`). |

### Update verfügbar: Installierte Version

| Aspekt | Wert |
|---|---|
| Control | Text `Installiert: \(info.currentVersion.description)` mit Caption-Font und sekundärer Farbe (`WhisperM8/Views/AppUpdateViews.swift:46`, `WhisperM8/Views/AppUpdateViews.swift:47`, `WhisperM8/Views/AppUpdateViews.swift:48`). |
| Default | Sichtbar im verfügbaren Update-Detail (`WhisperM8/Views/AppUpdateViews.swift:42`, `WhisperM8/Views/AppUpdateViews.swift:46`). |
| Persistenz | Keine Persistenz; `UpdateInfo.currentVersion` wird aus dem aktuellen Bundle-Short-Version-String erzeugt (`WhisperM8/Services/Shared/AppUpdateChecker.swift:32`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:33`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:142`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:143`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:46`. |
| Wirkung | Zeigt die lokal verglichene Version neben der verfügbaren Release-Version an (`WhisperM8/Views/AppUpdateViews.swift:44`, `WhisperM8/Views/AppUpdateViews.swift:46`). |
| Abhängigkeiten | Wenn die lokale Version fehlt oder nicht als `SemanticVersion` parsebar ist, wird statt dieser Anzeige der Fehler „Installierte Version unbekannt (Info.plist)." gesetzt (`WhisperM8/Services/Shared/AppUpdateChecker.swift:142`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:143`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:144`). |

### Kopierfeld „brew upgrade --cask whisperm8"

| Aspekt | Wert |
|---|---|
| Control | `CopyableCommandBox(command: AppUpdateChecker.brewUpgradeCommand)` im Update-Detail (`WhisperM8/Views/AppUpdateViews.swift:56`). |
| Default | Befehl ist statisch `brew upgrade --cask whisperm8` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:19`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:20`). |
| Persistenz | Kein Settings-Wert; beim Klick schreibt die Box den Befehl in `NSPasteboard.general` (`WhisperM8/Views/AppUpdateViews.swift:100`, `WhisperM8/Views/AppUpdateViews.swift:101`, `WhisperM8/Views/AppUpdateViews.swift:102`, `WhisperM8/Views/AppUpdateViews.swift:103`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:56`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:20`. |
| Wirkung | Stellt den empfohlenen Homebrew-Upgrade-Befehl als auswählbare, kopierbare Zeile bereit (`WhisperM8/Views/AppUpdateViews.swift:94`, `WhisperM8/Views/AppUpdateViews.swift:96`, `WhisperM8/Views/AppUpdateViews.swift:100`, `WhisperM8/Views/AppUpdateViews.swift:103`). |
| Abhängigkeiten | Der Kommentar erklärt, dass Updates bewusst über Homebrew laufen, weil DMG bei self-signed Builds einen manuellen Quarantäne-Befehl bräuchte (`WhisperM8/Views/AppUpdateViews.swift:51`, `WhisperM8/Views/AppUpdateViews.swift:52`, `WhisperM8/Views/AppUpdateViews.swift:53`, `WhisperM8/Views/AppUpdateViews.swift:54`, `WhisperM8/Views/AppUpdateViews.swift:55`). |

### Hinweis zu Terminal, Neustart und Berechtigungen

| Aspekt | Wert |
|---|---|
| Control | Reine Textanzeige mit Hinweis „Im Terminal ausführen. Beim anschließenden Neustart werden laufende Agent-Chats beendet; macOS fragt Berechtigungen danach erneut ab." (`WhisperM8/Views/AppUpdateViews.swift:58`). |
| Default | Sichtbar im Update-Detail unter dem Upgrade-Befehl (`WhisperM8/Views/AppUpdateViews.swift:56`, `WhisperM8/Views/AppUpdateViews.swift:58`). |
| Persistenz | Keine Persistenz; der Hinweis ist hart codiert (`WhisperM8/Views/AppUpdateViews.swift:58`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:58`. |
| Wirkung | Warnt vor Terminal-Ausführung, Beenden laufender Agent-Chats und erneuten macOS-Berechtigungsabfragen nach dem Neustart (`WhisperM8/Views/AppUpdateViews.swift:58`). |
| Abhängigkeiten | Bezieht sich auf das Homebrew-Upgrade aus derselben Detailansicht (`WhisperM8/Views/AppUpdateViews.swift:56`, `WhisperM8/Views/AppUpdateViews.swift:58`). |

### Hinweis „Noch nicht über Homebrew installiert?"

| Aspekt | Wert |
|---|---|
| Control | Bedingte Textanzeige `Noch nicht über Homebrew installiert? Einmalig:` (`WhisperM8/Views/AppUpdateViews.swift:63`, `WhisperM8/Views/AppUpdateViews.swift:66`). |
| Default | Nur sichtbar, wenn `info.isBrewInstall` `false` ist (`WhisperM8/Views/AppUpdateViews.swift:63`). |
| Persistenz | Kein Settings-Wert; `isBrewInstall` wird im `UpdateInfo` gespeichert, nachdem `brewReceiptExists()` geprüft wurde (`WhisperM8/Services/Shared/AppUpdateChecker.swift:36`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:39`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:168`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:63`, `WhisperM8/Views/AppUpdateViews.swift:66`. |
| Wirkung | Erklärt, dass Nicht-Cask-Installationen den Cask einmalig übernehmen sollen (`WhisperM8/Views/AppUpdateViews.swift:63`, `WhisperM8/Views/AppUpdateViews.swift:64`, `WhisperM8/Views/AppUpdateViews.swift:65`, `WhisperM8/Views/AppUpdateViews.swift:66`). |
| Abhängigkeiten | Die Cask-Erkennung prüft die Pfade `/opt/homebrew/Caskroom/whisperm8` und `/usr/local/Caskroom/whisperm8` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:84`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:86`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:87`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:88`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:89`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:91`). |

### Kopierfeld „brew install --cask rankm8/tap/whisperm8 --force"

| Aspekt | Wert |
|---|---|
| Control | Bedingte `CopyableCommandBox(command: AppUpdateChecker.brewAdoptCommand)` für Nicht-Cask-Installationen (`WhisperM8/Views/AppUpdateViews.swift:63`, `WhisperM8/Views/AppUpdateViews.swift:69`). |
| Default | Befehl ist statisch `brew install --cask rankm8/tap/whisperm8 --force` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:21`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:26`). |
| Persistenz | Kein Settings-Wert; die Box schreibt beim Klick den Befehl in die macOS-Zwischenablage (`WhisperM8/Views/AppUpdateViews.swift:100`, `WhisperM8/Views/AppUpdateViews.swift:101`, `WhisperM8/Views/AppUpdateViews.swift:102`, `WhisperM8/Views/AppUpdateViews.swift:103`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:69`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:26`. |
| Wirkung | Gibt Nicht-Cask-Installationen einen einmaligen Übernahmebefehl an die Hand (`WhisperM8/Views/AppUpdateViews.swift:64`, `WhisperM8/Views/AppUpdateViews.swift:65`, `WhisperM8/Views/AppUpdateViews.swift:66`, `WhisperM8/Views/AppUpdateViews.swift:69`). |
| Abhängigkeiten | Die Anzeige hängt von `!info.isBrewInstall` ab (`WhisperM8/Views/AppUpdateViews.swift:63`). |

### Link „Release-Notes ansehen"

| Aspekt | Wert |
|---|---|
| Control | `Link("Release-Notes ansehen", destination: info.releaseURL)` im Update-Detail (`WhisperM8/Views/AppUpdateViews.swift:72`). |
| Default | Ziel ist die `html_url` des GitHub-Release; wenn daraus keine URL entsteht, wird die Releases-Seite als Fallback verwendet (`WhisperM8/Services/Shared/AppUpdateChecker.swift:163`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:18`). |
| Persistenz | Keine Persistenz; `releaseURL` ist Teil von `UpdateInfo` im Checker-Zustand (`WhisperM8/Services/Shared/AppUpdateChecker.swift:32`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:35`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:167`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:72`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:163`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:167`. |
| Wirkung | Öffnet die Release-Notes des gefundenen Updates (`WhisperM8/Views/AppUpdateViews.swift:72`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:163`). |
| Abhängigkeiten | Die Release-Daten werden von `https://api.github.com/repos/RankM8/WhisperM8/releases/latest` geladen; der Repo-Slug ist `RankM8/WhisperM8` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:15`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:16`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:17`). |

### Fehlermeldung der Update-Prüfung

| Aspekt | Wert |
|---|---|
| Control | Textanzeige `Text(message)` im Zustand `.failed(let message)` mit Caption-Font, sekundärer Farbe und zentrierter Mehrzeilen-Ausrichtung (`WhisperM8/Views/AppUpdateViews.swift:149`, `WhisperM8/Views/AppUpdateViews.swift:151`, `WhisperM8/Views/AppUpdateViews.swift:152`, `WhisperM8/Views/AppUpdateViews.swift:153`, `WhisperM8/Views/AppUpdateViews.swift:154`). |
| Default | Nicht initial sichtbar; Fehler entstehen bei unbekannter lokaler Version, fehlgeschlagenem Fetch oder unerwarteter Release-API-Antwort (`WhisperM8/Services/Shared/AppUpdateChecker.swift:142`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:144`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:148`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:151`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:152`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:156`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:158`). |
| Persistenz | Keine Persistenz; der Fehlertext ist Teil von `.failed(String)` in `state` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:42`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:47`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:50`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:149`, `WhisperM8/Views/AppUpdateViews.swift:151`. |
| Wirkung | Zeigt den aktuellen Grund an, warum die Update-Prüfung nicht erfolgreich abgeschlossen wurde (`WhisperM8/Views/AppUpdateViews.swift:151`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:144`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:152`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:158`). |
| Abhängigkeiten | Netzwerkfehler werden als „Update-Prüfung fehlgeschlagen — offline? (...)" formatiert (`WhisperM8/Services/Shared/AppUpdateChecker.swift:148`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:151`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:152`). |

### Button „Erneut versuchen"

| Aspekt | Wert |
|---|---|
| Control | Button aus `checkButton("Erneut versuchen")` im Zustand `.failed` (`WhisperM8/Views/AppUpdateViews.swift:149`, `WhisperM8/Views/AppUpdateViews.swift:155`). |
| Default | Sichtbar zusammen mit der Fehlermeldung (`WhisperM8/Views/AppUpdateViews.swift:149`, `WhisperM8/Views/AppUpdateViews.swift:150`, `WhisperM8/Views/AppUpdateViews.swift:151`, `WhisperM8/Views/AppUpdateViews.swift:155`). |
| Persistenz | Kein Button-Wert wird gespeichert; der Klick ruft `checker.checkNow()` auf (`WhisperM8/Views/AppUpdateViews.swift:161`, `WhisperM8/Views/AppUpdateViews.swift:162`, `WhisperM8/Views/AppUpdateViews.swift:163`). |
| Gelesen von | `WhisperM8/Views/AppUpdateViews.swift:155`, `WhisperM8/Views/AppUpdateViews.swift:163`. |
| Wirkung | Wiederholt die Update-Prüfung nach einem Fehler (`WhisperM8/Views/AppUpdateViews.swift:155`, `WhisperM8/Views/AppUpdateViews.swift:163`). |
| Abhängigkeiten | Nutzt denselben Checker und dieselbe idempotente `checkNow()`-Methode wie die anderen Update-Buttons (`WhisperM8/Views/AppUpdateViews.swift:125`, `WhisperM8/Views/AppUpdateViews.swift:163`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:116`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:117`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:118`). |

### Footer-Link „Built by 360WebManager"

| Aspekt | Wert |
|---|---|
| Control | Zentrierter SwiftUI-`Link("Built by 360WebManager", destination: URL(string: "https://360web-manager.com/")!)` mit Caption-Font (`WhisperM8/Views/Settings/AboutView.swift:55`, `WhisperM8/Views/Settings/AboutView.swift:56`, `WhisperM8/Views/Settings/AboutView.swift:57`, `WhisperM8/Views/Settings/AboutView.swift:58`, `WhisperM8/Views/Settings/AboutView.swift:59`). |
| Default | Ziel-URL ist statisch `https://360web-manager.com/` (`WhisperM8/Views/Settings/AboutView.swift:57`). |
| Persistenz | Keine Persistenz; Linktext und URL sind hart codiert (`WhisperM8/Views/Settings/AboutView.swift:57`). |
| Gelesen von | `WhisperM8/Views/Settings/AboutView.swift:57`. |
| Wirkung | Öffnet die Website von 360WebManager (`WhisperM8/Views/Settings/AboutView.swift:57`). |
| Abhängigkeiten | Keine funktionale Abhängigkeit; die Section nutzt zwei `Spacer()`, um den Link horizontal zu zentrieren (`WhisperM8/Views/Settings/AboutView.swift:55`, `WhisperM8/Views/Settings/AboutView.swift:56`, `WhisperM8/Views/Settings/AboutView.swift:57`, `WhisperM8/Views/Settings/AboutView.swift:59`). |

## 4. Datenfluss & Persistenz

Die sichtbare About-Version liest `CFBundleShortVersionString` und `CFBundleVersion` direkt aus `Bundle.main.object(forInfoDictionaryKey:)`; diese Anzeige speichert nichts in UserDefaults oder Dateien (`WhisperM8/Views/Settings/AboutView.swift:5`, `WhisperM8/Views/Settings/AboutView.swift:6`, `WhisperM8/Views/Settings/AboutView.swift:37`). Die aktuelle Bundle-Version im Working Tree ist `2.7.0` für `CFBundleShortVersionString` und `2.7.0` für `CFBundleVersion` (`WhisperM8/Info.plist:9`, `WhisperM8/Info.plist:10`, `WhisperM8/Info.plist:11`, `WhisperM8/Info.plist:12`).

Die Update-Sektion beobachtet `AppUpdateChecker.shared` über `@ObservedObject` und rendert ausschließlich aus `checker.state` (`WhisperM8/Views/AppUpdateViews.swift:123`, `WhisperM8/Views/AppUpdateViews.swift:124`, `WhisperM8/Views/AppUpdateViews.swift:125`, `WhisperM8/Views/AppUpdateViews.swift:129`). Der Checker hält `state` und `lastCheckedAt` als `@Published private(set)` im Speicher; `lastCheckedAt` wird nach jedem abgeschlossenen Check per `defer { lastCheckedAt = Date() }` gesetzt, wird in `AboutUpdateSection` aber nicht angezeigt (`WhisperM8/Services/Shared/AppUpdateChecker.swift:50`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:51`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:52`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:140`, `WhisperM8/Views/AppUpdateViews.swift:127`, `WhisperM8/Views/AppUpdateViews.swift:157`). Manuelle Klicks starten `checker.checkNow()` sofort über eine Swift-Concurrency-`Task` (`WhisperM8/Views/AppUpdateViews.swift:161`, `WhisperM8/Views/AppUpdateViews.swift:162`, `WhisperM8/Views/AppUpdateViews.swift:163`).

Der eigentliche Check liest die lokale Version aus `CFBundleShortVersionString`, lädt `https://api.github.com/repos/RankM8/WhisperM8/releases/latest` mit Accept-Header `application/vnd.github+json`, decodiert `tag_name` und `html_url`, vergleicht `latest > current` und setzt danach `.available`, `.upToDate` oder `.failed` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:16`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:17`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:63`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:64`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:67`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:68`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:69`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:156`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:157`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:162`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:164`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:172`). Automatische Checks werden beim App-Start geplant, starten nach 10 Sekunden und laufen danach alle 24 Stunden mit 10 Minuten Timer-Toleranz (`WhisperM8/WhisperM8App.swift:223`, `WhisperM8/WhisperM8App.swift:224`, `WhisperM8/WhisperM8App.swift:225`, `WhisperM8/WhisperM8App.swift:226`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:27`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:28`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:29`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:30`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:94`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:97`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:100`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:104`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:110`).

Die einzige persistierte Einstellung im Update-Kontext ist der automatische Kill-Switch `updateCheckEnabled`; `AppPreferences.isUpdateCheckEnabled` liest ihn mit Default `true`, schreibt ihn in UserDefaults und wird als `isAutomaticCheckEnabled` nur für automatische Checks genutzt (`WhisperM8/Support/AppPreferences.swift:303`, `WhisperM8/Support/AppPreferences.swift:305`, `WhisperM8/Support/AppPreferences.swift:306`, `WhisperM8/Support/AppPreferences.swift:307`, `WhisperM8/Support/AppPreferences.swift:308`, `WhisperM8/Support/AppPreferences.swift:399`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:76`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:101`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:106`). Die About-Seite bietet keinen Toggle für diesen UserDefaults-Key; sie bietet nur manuelle Check-Buttons (`WhisperM8/Views/AppUpdateViews.swift:131`, `WhisperM8/Views/AppUpdateViews.swift:144`, `WhisperM8/Views/AppUpdateViews.swift:155`, `WhisperM8/Views/AppUpdateViews.swift:161`, `WhisperM8/Views/AppUpdateViews.swift:163`).

## 5. Querverweise

`AppUpdateDetailsView` wird laut Kommentar sowohl im Sidebar-Footer-Popover als auch inline in Settings → About verwendet (`WhisperM8/Views/AppUpdateViews.swift:35`, `WhisperM8/Views/AppUpdateViews.swift:36`, `WhisperM8/Views/AppUpdateViews.swift:37`). Der Sidebar-Footer nutzt `SidebarUpdateBadge`, zeigt ihn nur bei `.available(let info)` und öffnet dann ein Popover mit `AppUpdateDetailsView(info: info)` (`WhisperM8/Views/AppUpdateViews.swift:9`, `WhisperM8/Views/AppUpdateViews.swift:14`, `WhisperM8/Views/AppUpdateViews.swift:26`, `WhisperM8/Views/AppUpdateViews.swift:27`); eingebunden ist dieser Badge im Footer der Agent-Chats-Sidebar (`WhisperM8/Views/AgentChatsView.swift:1235`). Das heißt: Der manuelle Check sitzt auf der About-Seite, die passive Update-Aufforderung sitzt zusätzlich im Agent-Chats-Footer (`WhisperM8/Views/AppUpdateViews.swift:123`, `WhisperM8/Views/AppUpdateViews.swift:131`, `WhisperM8/Views/AgentChatsView.swift:1235`).

Der automatische Update-Check ist App-Start-Infrastruktur und nicht Teil einer Settings-Unterseite: `WhisperM8App.applicationDidFinishLaunching` ruft `AppUpdateChecker.shared.scheduleAutomaticChecks()` auf (`WhisperM8/WhisperM8App.swift:216`, `WhisperM8/WhisperM8App.swift:223`, `WhisperM8/WhisperM8App.swift:226`). Die Update-Links führen auf GitHub-Releases für `RankM8/WhisperM8` und auf die Herstellerseite `360web-manager.com` (`WhisperM8/Services/Shared/AppUpdateChecker.swift:16`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:17`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:18`, `WhisperM8/Views/Settings/AboutView.swift:57`, `WhisperM8/Views/AppUpdateViews.swift:72`).

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

- Ein Update-Check fehlt auf der About-Seite nicht: Der `.unknown`-Zustand zeigt „Nach Updates suchen", `.upToDate` zeigt „Erneut suchen" und `.failed` zeigt „Erneut versuchen" (`WhisperM8/Views/AppUpdateViews.swift:130`, `WhisperM8/Views/AppUpdateViews.swift:131`, `WhisperM8/Views/AppUpdateViews.swift:139`, `WhisperM8/Views/AppUpdateViews.swift:144`, `WhisperM8/Views/AppUpdateViews.swift:149`, `WhisperM8/Views/AppUpdateViews.swift:155`). Der automatische Check liegt stattdessen im App-Start-Pfad und die passive Update-Aufforderung liegt zusätzlich im Agent-Chats-Footer-Badge (`WhisperM8/WhisperM8App.swift:223`, `WhisperM8/WhisperM8App.swift:226`, `WhisperM8/Views/AgentChatsView.swift:1235`, `WhisperM8/Views/AppUpdateViews.swift:14`, `WhisperM8/Views/AppUpdateViews.swift:27`).
- Die Seite mischt Deutsch und Englisch: Sidebar-Name und Navigationstitel sind `About`, die Section heißt `Updates`, die Produktbeschreibung lautet englisch „Native macOS dictation with AI transcription", der Hersteller-Link lautet englisch „Built by 360WebManager", während Update-Buttons und Status-/Hinweistexte deutsch sind (`WhisperM8/Views/SettingsView.swift:18`, `WhisperM8/Views/SettingsView.swift:246`, `WhisperM8/Views/Settings/AboutView.swift:41`, `WhisperM8/Views/Settings/AboutView.swift:50`, `WhisperM8/Views/Settings/AboutView.swift:57`, `WhisperM8/Views/AppUpdateViews.swift:131`, `WhisperM8/Views/AppUpdateViews.swift:135`, `WhisperM8/Views/AppUpdateViews.swift:141`, `WhisperM8/Views/AppUpdateViews.swift:155`).
- Die About-Seite zeigt keinen Zeitpunkt der letzten Prüfung, obwohl der Checker `lastCheckedAt` publiziert und bei Abschluss setzt (`WhisperM8/Services/Shared/AppUpdateChecker.swift:51`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:52`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:140`, `WhisperM8/Views/AppUpdateViews.swift:127`, `WhisperM8/Views/AppUpdateViews.swift:157`). Dadurch ist nach einer automatischen Prüfung nicht sichtbar, wann der Status entstanden ist (`WhisperM8/WhisperM8App.swift:223`, `WhisperM8/WhisperM8App.swift:226`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:140`).
- Der automatische Kill-Switch `updateCheckEnabled` ist nur per `defaults write com.whisperm8.app updateCheckEnabled -bool NO` dokumentiert und besitzt keinen sichtbaren Toggle auf der About-Seite (`WhisperM8/Services/Shared/AppUpdateChecker.swift:94`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:95`, `WhisperM8/Support/AppPreferences.swift:303`, `WhisperM8/Support/AppPreferences.swift:305`, `WhisperM8/Views/AppUpdateViews.swift:127`, `WhisperM8/Views/AppUpdateViews.swift:157`). Für ein Settings-Redesign ist das eine Inkonsistenz: eine persistierte App-Einstellung existiert, ist aber nicht im Settings-Fenster bedienbar (`WhisperM8/Support/AppPreferences.swift:306`, `WhisperM8/Support/AppPreferences.swift:307`, `WhisperM8/Support/AppPreferences.swift:308`, `WhisperM8/Support/AppPreferences.swift:399`).

## 7. Offene Fragen

- Soll die About-Seite deutsch lokalisiert werden, obwohl der aktuelle Code `About`, `Updates`, „Native macOS dictation with AI transcription" und „Built by 360WebManager" hart codiert englisch anzeigt (`WhisperM8/Views/SettingsView.swift:18`, `WhisperM8/Views/Settings/AboutView.swift:41`, `WhisperM8/Views/Settings/AboutView.swift:50`, `WhisperM8/Views/Settings/AboutView.swift:57`)?
- Soll `lastCheckedAt` in der About-Seite sichtbar werden, da der Checker den Wert publiziert und aktualisiert, die `AboutUpdateSection` ihn aber nicht rendert (`WhisperM8/Services/Shared/AppUpdateChecker.swift:51`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:52`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:140`, `WhisperM8/Views/AppUpdateViews.swift:127`, `WhisperM8/Views/AppUpdateViews.swift:157`)?
- Soll `updateCheckEnabled` als sichtbarer Settings-Toggle angeboten werden, obwohl der Key aktuell nur als UserDefaults-Kill-Switch existiert und automatische Checks steuert (`WhisperM8/Support/AppPreferences.swift:303`, `WhisperM8/Support/AppPreferences.swift:306`, `WhisperM8/Support/AppPreferences.swift:307`, `WhisperM8/Support/AppPreferences.swift:308`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:76`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:101`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:106`)?
