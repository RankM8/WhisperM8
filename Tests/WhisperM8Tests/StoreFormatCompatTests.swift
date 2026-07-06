import Foundation
import XCTest
@testable import WhisperM8

final class StoreFormatCompatTests: XCTestCase {
    func testPostProcessingTemplateStoreWritesOnlyCustomTemplatesWithISO8601Dates() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8TemplateCompat-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let store = PostProcessingTemplateStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let custom = PostProcessingTemplate(
            id: "custom-template",
            name: "Custom Template",
            description: "Persisted custom template",
            instruction: "{rawTranscript}",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            isBuiltIn: false
        )

        try store.saveCustomTemplates([PostProcessingTemplate.builtInTemplates[0], custom])

        let data = try Data(contentsOf: fileURL)
        let fileText = String(decoding: data, as: UTF8.self)
        let decoded = store.loadCustomTemplates()

        XCTAssertEqual(decoded.map(\.id), ["custom-template"])
        XCTAssertFalse(decoded.contains { $0.isBuiltIn })
        XCTAssertFalse(fileText.contains(PostProcessingTemplate.cleanID))
        XCTAssertTrue(fileText.contains("1970-01-01T00:00:00Z"))
    }

    func testTranscriptRunReportLegacyDecodeWithoutVisualFields() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "createdAt": "2026-01-02T03:04:05Z",
          "sourceAppName": "Notes",
          "sourceBundleIdentifier": "com.apple.Notes",
          "status": "succeeded",
          "errorMessage": null,
          "mode": {
            "id": "clean",
            "name": "Clean",
            "shortLabel": "Clean",
            "templateID": "template.clean",
            "contextPolicy": "off"
          },
          "transcription": {
            "provider": "OpenAI",
            "model": "Whisper",
            "language": "de",
            "audioDuration": 4.5
          },
          "codex": {
            "model": "gpt-5.2",
            "reasoningEffort": "medium",
            "commandPreview": ["codex", "exec", "-"]
          },
          "attachments": [],
          "renderedPrompt": "Prompt",
          "rawTranscript": "Raw",
          "finalTranscript": "Final",
          "copiedToClipboard": true,
          "autoPasteRequested": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report = try decoder.decode(TranscriptRunReport.self, from: Data(json.utf8))

        XCTAssertEqual(report.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(report.sourceAppName, "Notes")
        XCTAssertNil(report.visualContextSummary)
        XCTAssertNil(report.visualManifest)
        XCTAssertEqual(report.attachments, [])
        XCTAssertEqual(report.codex?.visualInputMode, CodexVisualInputMode.defaultMode.rawValue)
        XCTAssertEqual(report.codex?.imageInputPaths, [])
        XCTAssertEqual(report.codex?.videoInputPaths, [])
        XCTAssertEqual(report.codex?.usesFrameFallbackForVideo, false)
    }

    func testTranscriptRunReportWithHistoricAgentChatIntentStillDecodes() throws {
        // Chat-Modus 2026-07-07 ausgebaut — Bestands-Reports tragen den
        // Intent "agentChat" aber weiterhin; der Enum-Case muss decodierbar bleiben.
        let json = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "createdAt": "2026-01-02T03:04:05Z",
          "status": "succeeded",
          "mode": {
            "id": "chat",
            "name": "Chat",
            "shortLabel": "Chat",
            "templateID": "template.chat",
            "contextPolicy": "auto"
          },
          "transcription": {
            "provider": "OpenAI",
            "model": "Whisper",
            "language": "de",
            "audioDuration": 4.5
          },
          "attachments": [],
          "replyIntent": "agentChat",
          "rawTranscript": "Raw",
          "finalTranscript": "Opened Codex chat: Demo",
          "copiedToClipboard": true,
          "autoPasteRequested": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report = try decoder.decode(TranscriptRunReport.self, from: Data(json.utf8))

        XCTAssertEqual(report.replyIntent, .agentChat)
        XCTAssertEqual(report.replyIntent?.displayName, "Agent Chat")
        XCTAssertEqual(report.mode.id, OutputMode.retiredChatID)
    }

    func testTranscriptRunReportStoreDefaultPathAndCleanupConstantsAreStable() throws {
        let store = TranscriptRunReportStore()
        let expectedDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
        let reportsDirectory = try XCTUnwrap(privateURL(named: "reportsDirectory", in: store))
        let policy = TranscriptRunReportStore.CleanupPolicy.productionDefault

        XCTAssertEqual(reportsDirectory, expectedDirectory)
        XCTAssertEqual(policy.maxAge, Optional(TimeInterval(180 * 24 * 60 * 60)))
        XCTAssertEqual(policy.maxCount, Optional(500))
        XCTAssertEqual(policy.maxBytes, Optional(Int64(2 * 1024 * 1024 * 1024)))
    }
}

private func privateURL(named label: String, in value: Any) -> URL? {
    Mirror(reflecting: value).children.first { $0.label == label }?.value as? URL
}
