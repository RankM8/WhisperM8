import XCTest

/// Lokalisierungs-Guard (E1: Englisch Basis, Deutsch vollständig; W3.0).
///
/// Der Katalog `WhisperM8/Localization/Localizable.xcstrings` wird vom
/// Makefile in das App-Bundle kompiliert. Geprüft wird:
/// 1. jeder Schlüssel hat eine fertige deutsche Übersetzung mit denselben
///    Platzhaltern;
/// 2. in den bereits lokalisierten Dateien (`localizedFiles`, wächst mit jeder
///    Welle) steht jeder UI-Text als Schlüssel im Katalog — ein neuer Text ohne
///    Katalogeintrag fällt sofort auf.
final class LocalizationCatalogTests: XCTestCase {
    /// Dateien, deren sichtbare Texte vollständig über den Katalog laufen.
    /// Neue oder umgestellte Ansichten hier eintragen.
    static let localizedFiles: [String] = [
        "WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift",
        "WhisperM8/Views/OnboardingView.swift",
        "WhisperM8/Views/AgentCLIInstallPanel.swift",
        "WhisperM8/Models/OnboardingLogic.swift",
        "WhisperM8/Models/DictationLanguage.swift",
        "WhisperM8/Services/Shared/AgentCLIInstaller.swift",
    ] + settingsFiles

    /// Alle Einstellungsdateien (W6 · LR-ONB-011/LR-AU-030) außer der Entwickler-Vorschau
    /// `SettingsKitPreview` (nur Platzhalter-Text für die Kit-Galerie).
    static let settingsFiles: [String] = [
        "WhisperM8/Views/Settings/Kit/ClipboardClient.swift",
        "WhisperM8/Views/Settings/Kit/SettingsButtonRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsCodeBlock.swift",
        "WhisperM8/Views/Settings/Kit/SettingsCopyCommandRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsFeedbackState.swift",
        "WhisperM8/Views/Settings/Kit/SettingsHelpText.swift",
        "WhisperM8/Views/Settings/Kit/SettingsKeyRecorderRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsLabsNotice.swift",
        "WhisperM8/Views/Settings/Kit/SettingsListPanel.swift",
        "WhisperM8/Views/Settings/Kit/SettingsPageContainer.swift",
        "WhisperM8/Views/Settings/Kit/SettingsPickerRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsSection.swift",
        "WhisperM8/Views/Settings/Kit/SettingsSliderRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsStatusRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsStatusTone.swift",
        "WhisperM8/Views/Settings/Kit/SettingsStepperRow.swift",
        "WhisperM8/Views/Settings/Kit/SettingsTabs.swift",
        "WhisperM8/Views/Settings/Kit/SettingsTextArea.swift",
        "WhisperM8/Views/Settings/Kit/SettingsToggleRow.swift",
        "WhisperM8/Views/Settings/Models/AgentCLIArgumentsPreview.swift",
        "WhisperM8/Views/Settings/Models/CodexConnectionModel.swift",
        "WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift",
        "WhisperM8/Views/Settings/Models/OutputModesViewModel.swift",
        "WhisperM8/Views/Settings/Models/PermissionSettingsModel.swift",
        "WhisperM8/Views/Settings/Models/PreferenceBedienweg.swift",
        "WhisperM8/Views/Settings/Models/SettingsNavigation.swift",
        "WhisperM8/Views/Settings/Models/SettingsRouteTarget.swift",
        "WhisperM8/Views/Settings/Models/TemplateEditorModel.swift",
        "WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift",
        "WhisperM8/Views/Settings/Pages/AIOutputModesTab.swift",
        "WhisperM8/Views/Settings/Pages/AIOutputSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift",
        "WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift",
        "WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift",
        "WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/AgentChatsVoiceAgentTab.swift",
        "WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/ClaudeAccountsSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/ClaudeMCPSyncSection.swift",
        "WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/GPTAccountsSection.swift",
        "WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/GPTBackendSetupRunner.swift",
        "WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/JarvisCalloutsSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift",
        "WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift",
        "WhisperM8/Views/Settings/Pages/VoiceGateSettingsPage.swift",
        "WhisperM8/Views/SettingsView.swift",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("WhisperM8/Localization/Localizable.xcstrings"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func strings() throws -> [String: [String: Any]] {
        try XCTUnwrap(try loadCatalog()["strings"] as? [String: [String: Any]])
    }

    func testCatalogIsEnglishBased() throws {
        XCTAssertEqual(try loadCatalog()["sourceLanguage"] as? String, "en")
    }

    func testEveryKeyHasFinishedGermanTranslationWithSamePlaceholders() throws {
        for (key, entry) in try strings() {
            if entry["shouldTranslate"] as? Bool == false { continue }
            let de = (entry["localizations"] as? [String: Any])?["de"] as? [String: Any]
            let unit = de?["stringUnit"] as? [String: Any]
            let variations = de?["variations"]
            XCTAssertTrue(unit != nil || variations != nil, "„\(key)“: deutsche Übersetzung fehlt")
            guard let unit else { continue }
            XCTAssertEqual(unit["state"] as? String, "translated", "„\(key)“: Übersetzung nicht fertig")
            let value = unit["value"] as? String ?? ""
            XCTAssertFalse(value.isEmpty, "„\(key)“: deutscher Text leer")
            XCTAssertEqual(Self.placeholders(in: key), Self.placeholders(in: value),
                           "„\(key)“: Platzhalter weichen ab (\(value))")
        }
    }

    func testLocalizedFilesUseOnlyCatalogKeys() throws {
        let keys = Set(try strings().keys)
        for file in Self.localizedFiles {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            let isSettings = file.hasPrefix("WhisperM8/Views/Settings/") || file == "WhisperM8/Views/SettingsView.swift"
            let literals = Self.uiLiterals(in: source) + (isSettings ? Self.settingsKitLiterals(in: source) : [])
            for literal in literals where !keys.contains(literal) {
                XCTFail("\(file): „\(literal)“ fehlt im String-Katalog")
            }
        }
    }

    func testCatalogCompilesWithXcstringstool() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        process.arguments = ["xcstringstool", "compile",
                             Self.root.appendingPathComponent("WhisperM8/Localization/Localizable.xcstrings").path,
                             "--output-directory", out.path]
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("de.lproj/Localizable.strings").path))
    }

    /// Dateien, in denen Ternär-Literale direkt in Text/Button verboten sind
    /// (LR-ONB/Lokalisierung): `Text(a ? "x" : "y")` wird zu `String` und bleibt
    /// unübersetzt. Neben den vollständig lokalisierten Dateien die Stellen,
    /// an denen es schon einmal auftrat.
    static let ternaryGuardedFiles: [String] = localizedFiles + [
        "WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift",
        "WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift",
    ]

    func testNoTernaryLiteralsInTextAndButtons() throws {
        for file in Self.ternaryGuardedFiles {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            for hit in Self.ternaryLiteralCalls(in: source) {
                XCTFail("\(file): Ternär-Literal „\(hit)“ in Text/Button — `cond ? Text(\"A\") : Text(\"B\")` verwenden")
            }
        }
    }

    func testTernaryDetectorFindsTheKnownPatterns() {
        XCTAssertEqual(Self.ternaryLiteralCalls(in: #"Button(status == .signedIn ? "Reconnect" : "Sign In") {"#).count, 1)
        XCTAssertEqual(Self.ternaryLiteralCalls(in: #"Text(isOn ? "A" : "B")"#).count, 1)
        XCTAssertTrue(Self.ternaryLiteralCalls(in: #"x ? Text("A") : Text("B")"#).isEmpty)
        XCTAssertTrue(Self.ternaryLiteralCalls(in: #"Text("Plain")"#).isEmpty)
    }

    // MARK: - Agent-Chats-UI (W6, LR-ONB-011 / LR-AU-030)

    /// Chat-Oberfläche: keine deutschen Literale im Code (Englisch im Code,
    /// Deutsch im Katalog). Zusätzlich muss jedes Literal der UI-Aufrufe ein
    /// Katalogschlüssel sein.
    static let chatsLocalizedFiles: [String] = [
        "WhisperM8/Views/AgentChatChromeViews.swift",
        "WhisperM8/Views/AgentChatsSidebarViews.swift",
        "WhisperM8/Views/AgentChatsView.swift",
        "WhisperM8/Views/AgentChatsView+AccountMove.swift",
        "WhisperM8/Views/AgentChatsView+Archive.swift",
        "WhisperM8/Views/AgentChatsView+BackgroundAgents.swift",
        "WhisperM8/Views/AgentChatsView+BulkActions.swift",
        "WhisperM8/Views/AgentChatsView+DragDrop.swift",
        "WhisperM8/Views/AgentChatsView+GPTAccount.swift",
        "WhisperM8/Views/AgentChatsView+Grid.swift",
        "WhisperM8/Views/AgentChatsView+ProjectManagement.swift",
        "WhisperM8/Views/AgentChatsView+RuntimeServices.swift",
        "WhisperM8/Views/AgentChatsView+SessionLifecycle.swift",
        "WhisperM8/Views/AgentChatsView+SessionMenus.swift",
        "WhisperM8/Views/AgentChatsView+Shortcuts.swift",
        "WhisperM8/Views/AgentChatsView+SubagentChildren.swift",
        "WhisperM8/Views/AgentChatsView+Subagents.swift",
        "WhisperM8/Views/AgentChatsView+Tabs.swift",
        "WhisperM8/Views/AgentChatsView+Workspaces.swift",
        "WhisperM8/Views/AgentChatsViewModel.swift",
        "WhisperM8/Views/AgentChatsWindowAccessor.swift",
        "WhisperM8/Views/AgentGridSplitContainer.swift",
        "WhisperM8/Views/AgentMoveToAccountSheet.swift",
        "WhisperM8/Views/AgentResourceSummaryButton.swift",
        "WhisperM8/Views/AgentSessionAmbiguousRebindPicker.swift",
        "WhisperM8/Views/AgentSessionDetailView.swift",
        "WhisperM8/Views/AgentStatusIndicator.swift",
        "WhisperM8/Views/AgentTabSwitcherMiniMap.swift",
        "WhisperM8/Views/AgentTabSwitcherOverlay.swift",
        "WhisperM8/Views/AgentUsagePopovers.swift",
        "WhisperM8/Views/BackgroundDispatchModal.swift",
        "WhisperM8/Views/GridDropViews.swift",
        "WhisperM8/Views/GridShrinkSelection.swift",
        "WhisperM8/Views/GridShrinkSelectionViews.swift",
        "WhisperM8/Views/JarvisNoteViews.swift",
        "WhisperM8/Views/ProjectDetailPanel.swift",
        "WhisperM8/Views/SessionDragPreview.swift",
        "WhisperM8/Views/SessionMenuPolicy.swift",
        "WhisperM8/Views/SidebarAlertLevelButton.swift",
        "WhisperM8/Views/SubagentJobDetailView.swift",
        "WhisperM8/Views/TabSwitcherGridMarking.swift",
        "WhisperM8/Views/TabSwitcherGridPaneMarking.swift",
        "WhisperM8/Views/TabSwitcherMiniMapGeometry.swift",
        "WhisperM8/Views/TabSwitcherModel.swift",
        "WhisperM8/Views/TabSwitcherScope.swift",
        "WhisperM8/Views/TabSwitcherShortcut.swift",
        "WhisperM8/Views/TabSwitcherTile.swift",
        "WhisperM8/Views/TabSwitcherTileModel.swift",
        "WhisperM8/Views/Workspace/WorkspaceLayoutView.swift",
        "WhisperM8/Views/WorkspacePersistenceBanner.swift",
        "WhisperM8/Views/VoiceGateMenuSection.swift",
        "WhisperM8/Views/AgentChatsView+AdvancedMenu.swift",
        "WhisperM8/Views/AgentTerminalView.swift",
        "WhisperM8/Views/AgentChatsView+Confirmations.swift",
        "WhisperM8/Services/AgentChats/ChatsUIStrings.swift",
        "WhisperM8/Services/AgentChats/AccountMovePlanner.swift",
        "WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift",
        "WhisperM8/Services/AgentChats/AgentAdvancedFeatures.swift",
        "WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift",
        "WhisperM8/Services/AgentChats/SidebarCloseAction.swift",
        "WhisperM8/Services/AgentChats/AgentSessionNotifier.swift",
        "WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift",
        "WhisperM8/Services/AgentChats/AgentTranscriptActivityExtractor.swift",
        "WhisperM8/Views/AgentChatsView+ProjectManagement.swift",
    ]

    func testChatsFilesContainNoGermanLiterals() throws {
        for file in Self.chatsLocalizedFiles {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            for literal in Self.germanLiterals(in: source) {
                XCTFail("\(file): deutsches Literal „\(literal)“ — Englisch in den Code, Deutsch in den Katalog")
            }
        }
    }

    func testChatsFilesUseOnlyCatalogKeys() throws {
        let keys = Set(try strings().keys)
        for file in Self.chatsLocalizedFiles {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            for literal in Self.uiLiterals(in: Self.withoutComments(source))
            where !keys.contains(literal) && Self.needsCatalogEntry(literal) {
                XCTFail("\(file): „\(literal)“ fehlt im String-Katalog")
            }
            for hit in Self.ternaryLiteralCalls(in: source) {
                XCTFail("\(file): Ternär-Literal „\(hit)“ in Text/Button")
            }
        }
    }

    /// Ternäre mit nackten String-Literalen (auch verschachtelt, auch in
    /// `.help(`/`help:`/`title:`) werden nie lokalisiert — jeder Zweig braucht
    /// `Text("…")` bzw. `String(localized:)`.
    func testChatsFilesHaveNoBareStringTernaries() throws {
        for file in Self.chatsLocalizedFiles {
            let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
            for hit in Self.bareStringTernaries(in: Self.withoutComments(source)) {
                XCTFail("\(file): Ternär mit nacktem Literal „\(hit)“ — Zweige als Text(\"…\") oder String(localized:)")
            }
        }
    }

    func testBareTernaryDetectorFindsKnownPatterns() {
        XCTAssertEqual(Self.bareStringTernaries(in: #".help(a ? "Einblenden" : "Ausblenden")"#).count, 2)
        XCTAssertEqual(Self.bareStringTernaries(in: #"Text(r ? "Restart" : (x == nil ? "Start" : "Resume"))"#).count, 3)
        XCTAssertEqual(Self.bareStringTernaries(in: #"help: s ? "Hide sidebar" : "Show sidebar""#).count, 2)
        XCTAssertTrue(Self.bareStringTernaries(in: #"x ? Text("A") : Text("B")"#).isEmpty)
        XCTAssertTrue(Self.bareStringTernaries(in: #"x ? String(localized: "A") : String(localized: "B")"#).isEmpty)
        XCTAssertTrue(Self.bareStringTernaries(in: #"icon: a ? "archivebox.fill" : "archivebox""#).isEmpty)
    }

    func testGermanDetectorFindsKnownPatterns() {
        XCTAssertEqual(Self.germanLiterals(in: #"Text("Projekt löschen?")"#).count, 1)
        XCTAssertEqual(Self.germanLiterals(in: #"let a = "Der Chat läuft noch""#).count, 1)
        XCTAssertEqual(Self.germanLiterals(in: #"Button("Archivieren und beenden") {}"#).count, 1)
        XCTAssertTrue(Self.germanLiterals(in: #"// Löschen: „Wert“ ist deutsch"#).isEmpty)
        XCTAssertTrue(Self.germanLiterals(in: #"Text("Delete project?")"#).isEmpty)
        XCTAssertTrue(Self.germanLiterals(in: #"logger.info("Chat läuft noch")"#).isEmpty)
    }

    // MARK: - Helfer

    /// Reine Symbole/Zeichen (`·`, `⌘N`) und SF-Symbol-Namen brauchen keinen Eintrag.
    static func needsCatalogEntry(_ literal: String) -> Bool {
        guard literal.range(of: #"\p{L}"#, options: .regularExpression) != nil else { return false }
        return literal.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) == nil
    }

    /// Bezeichner statt Text: Farb-Hex, Kleinbuchstaben-Token (`claude`, `pin`, `s`), Werkzeugnamen.
    static func isIdentifierLike(_ literal: String) -> Bool {
        literal.hasPrefix("#") || literal.hasPrefix("/") || literal == "Bash"
            || literal.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil
    }

    /// Literale direkt hinter `?` oder `:` eines Ternärs, die Text enthalten
    /// (SF-Symbol-Namen und reine Zeichen zählen nicht).
    static func bareStringTernaries(in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?: \? | : )\(?"((?:[^"\\]|\\.)*)"(?=\s*:\s|\s*[)\n,]|\s*$)"#) else { return [] }
        var hits: [String] = []
        for line in source.split(separator: "\n") {
            let text = String(line)
            guard text.contains(" ? ") else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[r])
                // Nur Zweige eines `? … :`-Ternärs: der Text davor enthält ein ` ? `.
                let before = String(text[..<r.lowerBound])
                if before.contains(" ? "), needsCatalogEntry(literal), !isIdentifierLike(literal) { hits.append(literal) }
            }
        }
        return hits
    }

    /// Entfernt `//`-Kommentare zeilenweise (außerhalb von Literalen).
    static func withoutComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var inString = false
            var previous: Character = " "
            var result = ""
            let chars = Array(line)
            var index = 0
            while index < chars.count {
                let ch = chars[index]
                if ch == "\"" && previous != "\\" { inString.toggle() }
                if !inString, ch == "/", index + 1 < chars.count, chars[index + 1] == "/" { break }
                result.append(ch)
                previous = (previous == "\\" && ch == "\\") ? " " : ch
                index += 1
            }
            return result
        }.joined(separator: "\n")
    }

    /// Deutsche Literale außerhalb von Kommentaren und Log-Zeilen: Umlaut/ß
    /// oder ein typisches deutsches Funktionswort.
    static func germanLiterals(in source: String) -> [String] {
        let words = #"\b(der|die|das|den|dem|und|oder|nicht|wird|werden|ein|eine|einen|für|mit|von|zu|zum|zur|im|auf|noch|kein|keine|alle|ohne|nach|bei|über|aus|ist|sind|hier|neuer|neue|neues|sich|wurde|beim|gelöscht|neu|laden|starten|stoppen|beenden|anzeigen|entfernen|archivieren|abbrechen|fertig|speichern|umbenennen|wiederherstellen|einstellungen|hilfe|ablegen|zeigen|projekt|projekte|farbe|fehler|aufklappen|einklappen|zuklappen|weniger|ältere|übrig|arbeitet|bereit|wartet|leer|leerer|keine|kein|archiv|einblenden|ausblenden|verlassen|durchsuchen|gepinnte|gepinnt|schließen|lösen|anpinnen|lade|kopieren|wählen|hinzufügen|entfernen|zurück|weiter|gerade|noch|alle|zeigen|anzeigen|öffnen)\b"#
        guard let literal = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#),
              let german = try? NSRegularExpression(pattern: "[äöüÄÖÜß]|" + words, options: [.caseInsensitive]) else { return [] }
        var hits: [String] = []
        for line in withoutComments(source).split(separator: "\n") {
            let text = String(line)
            if text.contains("ogger.") || text.contains("log.") || text.contains("fatalError(") || text.contains("assert") { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in literal.matches(in: text, range: range) {
                guard let inner = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else { continue }
                let innerRange = NSRange(inner.startIndex..., in: inner)
                if german.firstMatch(in: inner, range: innerRange) != nil { hits.append(inner) }
            }
        }
        return hits
    }

    static func ternaryLiteralCalls(in source: String) -> [String] {
        let pattern = #"(?:Text|Button|Label|Toggle|Section|Picker|Menu|ContentUnavailableView)\(\s*(?!settingsLocalized:)[^"()\n]*\?\s*"(?:[^"\\]|\\.)*"\s*:\s*"(?:[^"\\]|\\.)*""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { Range($0.range, in: source).map { String(source[$0]) } }
    }

    /// Swift-Literal → eigentlicher Schlüssel (`\"` und `\\` aufgelöst).
    static func unescape(_ literal: String) -> String {
        literal.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// `%@`, `%lld`, `%1$@` … in Reihenfolge, Positionsangaben ignoriert.
    static func placeholders(in text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaA]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        // `%%` ist ein wörtliches Prozentzeichen, kein Platzhalter.
        let text = text.replacingOccurrences(of: "%%", with: "")
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
        }.sorted()
    }

    /// Literale, die an die Kit-Komponenten der Einstellungen gehen
    /// (`SettingsRow(title:subtitle:)`, `SettingsHelpText("…")`, `SettingsSection("…")` …).
    /// Sie rendern ihre `String`-Parameter zur Laufzeit über den Katalog.
    static func settingsKitLiterals(in source: String) -> [String] {
        let pattern = #"(?:\b(?:title|subtitle|detail|caption|placeholder|message|label|prompt|hint):|Settings(?:Section|HelpText|LabsNotice)\()\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { Self.unescape(String(source[$0])) }
        }.filter { !$0.contains("\\(") && !$0.isEmpty }
    }

    /// Einfache Literale in typischen UI-Aufrufen. Interpolationen (`\(`)
    /// prüft der Guard nicht — dafür `String(localized:)` mit Platzhalter nutzen.
    static func uiLiterals(in source: String) -> [String] {
        // `String(localized: "…")` hat kein zweites `(` — eigene Alternative.
        let calls = #"(?:(?:Text|Button|Label|Toggle|Section|Picker|Menu|ContentUnavailableView|\.help|\.navigationTitle|LocalizedStringKey)\(|String\(localized:)\s*"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: calls) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { Self.unescape(String(source[$0])) }
        }.filter { !$0.contains("\\(") && !$0.isEmpty }
    }
}
