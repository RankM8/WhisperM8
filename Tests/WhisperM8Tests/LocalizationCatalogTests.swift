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

    // MARK: - Helfer

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
