import Foundation
import XCTest
@testable import WhisperM8

final class OutputModeCompatTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OutputModeStore._resetCacheForTesting()
    }

    func testDefaultOutputModeIDFallbackKeepsStoredValuesUntouched() throws {
        try withIsolatedOutputModePreferences { preferences in
            let fileURL = temporaryJSONURL(prefix: "WhisperM8OutputModes")
            let store = OutputModeStore(fileURL: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.cleanID)

            preferences.defaultOutputModeID = OutputMode.rawID
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.rawID)
            XCTAssertEqual(store.mode(for: preferences.defaultOutputModeID).id, OutputMode.rawID)
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.rawID)

            preferences.defaultOutputModeID = "deleted-custom-mode"

            // Ist-Zustand: unbekannte/gelöschte IDs bleiben persistiert; effektiv
            // resolved der Store auf den ersten Raw/Fast-Modus.
            XCTAssertEqual(store.mode(for: preferences.defaultOutputModeID).id, OutputMode.rawID)
            XCTAssertEqual(preferences.defaultOutputModeID, "deleted-custom-mode")
        }
    }

    func testLegacyOutputModesJSONDecodesMissingContextVisualAndCodexFields() throws {
        let json = """
        [
          {
            "id": "raw",
            "name": "Raw",
            "shortLabel": "Raw",
            "kind": "raw",
            "templateID": null,
            "isEnabled": true,
            "isDefault": true
          },
          {
            "id": "slack",
            "name": "Slack",
            "shortLabel": "Slack",
            "kind": "builtIn",
            "templateID": "template.slack",
            "isEnabled": true,
            "isDefault": false
          },
          {
            "id": "custom-legacy",
            "name": "Custom Legacy",
            "shortLabel": "Custom",
            "kind": "custom",
            "templateID": "template.clean",
            "isEnabled": true,
            "isDefault": false
          }
        ]
        """

        let modes = try JSONDecoder().decode([OutputMode].self, from: Data(json.utf8))
        let raw = try XCTUnwrap(modes.first { $0.id == OutputMode.rawID })
        let slack = try XCTUnwrap(modes.first { $0.id == OutputMode.slackID })
        let custom = try XCTUnwrap(modes.first { $0.id == "custom-legacy" })

        XCTAssertEqual(raw.contextPolicy, .off)
        XCTAssertFalse(raw.pasteVisualAttachments)
        XCTAssertNil(raw.codexModelRawOverride)
        XCTAssertEqual(slack.contextPolicy, .auto)
        XCTAssertTrue(slack.pasteVisualAttachments)
        XCTAssertNil(slack.codexReasoningEffortRawOverride)
        XCTAssertNil(slack.codexServiceTierRawOverride)
        XCTAssertEqual(custom.contextPolicy, .off)
        XCTAssertFalse(custom.pasteVisualAttachments)
    }

    func testOutputModeStoreNormalizationPinsBuiltInsRawFastMigrationAndCustomSort() throws {
        try withIsolatedOutputModePreferences { preferences in
            preferences.defaultOutputModeID = "custom-beta"
            let fileURL = temporaryJSONURL(prefix: "WhisperM8OutputModes")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let json = """
            [
              {
                "id": "raw",
                "name": "Raw",
                "shortLabel": "Raw",
                "kind": "builtIn",
                "templateID": "template.clean",
                "isEnabled": false,
                "isDefault": false,
                "contextPolicy": "auto",
                "pasteVisualAttachments": true,
                "codexModelRawOverride": "gpt-5.2",
                "codexReasoningEffortRawOverride": "high",
                "codexServiceTierRawOverride": "standard"
              },
              {
                "id": "custom-zeta",
                "name": "Zulu",
                "shortLabel": "Zulu",
                "kind": "builtIn",
                "templateID": "template.clean",
                "isEnabled": true,
                "isDefault": false,
                "contextPolicy": "off",
                "pasteVisualAttachments": false
              },
              {
                "id": "custom-beta",
                "name": "Alpha",
                "shortLabel": "Alpha",
                "kind": "raw",
                "templateID": "template.clean",
                "isEnabled": false,
                "isDefault": false,
                "contextPolicy": "auto",
                "pasteVisualAttachments": true
              }
            ]
            """
            try Data(json.utf8).write(to: fileURL)

            let modes = OutputModeStore(fileURL: fileURL).modes
            let raw = try XCTUnwrap(modes.first { $0.id == OutputMode.rawID })
            let customModes = modes.filter { !OutputMode.builtInModes.map(\.id).contains($0.id) }

            XCTAssertEqual(modes.count, OutputMode.builtInModes.count + 2)
            XCTAssertEqual(modes.prefix(OutputMode.builtInModes.count).map(\.id), OutputMode.builtInModes.map(\.id))
            XCTAssertEqual(raw.name, "Fast")
            XCTAssertEqual(raw.shortLabel, "Fast")
            XCTAssertEqual(raw.kind, .raw)
            XCTAssertNil(raw.templateID)
            XCTAssertTrue(raw.isEnabled)
            XCTAssertEqual(raw.contextPolicy, .off)
            XCTAssertFalse(raw.pasteVisualAttachments)
            XCTAssertNil(raw.codexModelRawOverride)
            XCTAssertNil(raw.codexReasoningEffortRawOverride)
            XCTAssertNil(raw.codexServiceTierRawOverride)
            XCTAssertEqual(customModes.map(\.name), ["Alpha", "Zulu"])
            XCTAssertTrue(customModes.allSatisfy { $0.kind == .custom })
            XCTAssertTrue(customModes.first { $0.id == "custom-beta" }?.isDefault == true)
            XCTAssertTrue(customModes.first { $0.id == "custom-beta" }?.isEnabled == true)
        }
    }
}

private func withIsolatedOutputModePreferences(_ body: (AppPreferences) throws -> Void) rethrows {
    let suiteName = "WhisperM8OutputModeCompatTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let original = AppPreferences.shared
    let preferences = AppPreferences(defaults: defaults)
    AppPreferences.shared = preferences
    defer {
        AppPreferences.shared = original
        defaults.removePersistentDomain(forName: suiteName)
    }

    try body(preferences)
}

private func temporaryJSONURL(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .appendingPathExtension("json")
}
