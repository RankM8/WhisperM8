import Foundation
import XCTest
@testable import WhisperM8

final class OutputHistoryFilterTests: XCTestCase {
    private func makeReport(
        modeID: String = OutputMode.cleanID,
        status: TranscriptRunStatus = .succeeded,
        replyIntent: ReplyIntentKind? = nil,
        sourceApp: String? = "Chrome",
        raw: String? = "raw text",
        final: String? = "final text"
    ) -> TranscriptRunReport {
        let mode = OutputMode.mode(for: modeID)
        return TranscriptRunReport(
            id: UUID(),
            createdAt: Date(),
            sourceAppName: sourceApp,
            sourceBundleIdentifier: nil,
            status: status,
            errorMessage: nil,
            mode: TranscriptRunReport.ModeSnapshot(
                id: mode.id,
                name: mode.name,
                shortLabel: mode.shortLabel,
                templateID: mode.templateID,
                contextPolicy: mode.contextPolicy
            ),
            transcription: TranscriptRunReport.TranscriptionSnapshot(
                provider: "OpenAI",
                model: "gpt-4o",
                language: "de",
                audioDuration: 1
            ),
            codex: nil,
            selectedText: nil,
            visualContextSummary: nil,
            replyIntent: replyIntent,
            visualManifest: nil,
            attachments: [],
            renderedPrompt: nil,
            rawTranscript: raw,
            finalTranscript: final,
            copiedToClipboard: false,
            autoPasteRequested: false,
            autoPasteTextRequested: nil,
            autoPasteAttachmentsRequested: nil,
            pastedAttachmentCount: nil,
            pasteErrors: nil,
            deliveryAttachmentLabels: nil,
            agentProvider: nil,
            agentSessionID: nil,
            agentProjectPath: nil
        )
    }

    func testAllScopeKeepsEveryReport() {
        let reports = [makeReport(), makeReport(modeID: OutputMode.taskID)]
        let filter = OutputHistoryFilter(scope: .all)

        XCTAssertEqual(filter.apply(to: reports).count, 2)
    }

    func testTasksScopeMatchesTaskModeAndAgenticReplies() {
        let taskMode = makeReport(modeID: OutputMode.taskID)
        let agenticReply = makeReport(modeID: OutputMode.slackID, replyIntent: .agenticReply)
        let plain = makeReport(modeID: OutputMode.cleanID)
        let filter = OutputHistoryFilter(scope: .tasks)

        let result = filter.apply(to: [taskMode, agenticReply, plain])

        XCTAssertEqual(Set(result.map(\.id)), Set([taskMode.id, agenticReply.id]))
    }

    func testStatusFilterKeepsMatchingStatusOnly() {
        let ok = makeReport(status: .succeeded)
        let failed = makeReport(status: .failed)
        let filter = OutputHistoryFilter(status: .failed)

        let result = filter.apply(to: [ok, failed])

        XCTAssertEqual(result.map(\.id), [failed.id])
    }

    func testSearchMatchesRawFinalAndAppCaseInsensitively() {
        let match = makeReport(sourceApp: "Slack", raw: "Hallo WELT", final: "nichts")
        let miss = makeReport(sourceApp: "Notes", raw: "abc", final: "def")

        XCTAssertEqual(OutputHistoryFilter(searchText: "welt").apply(to: [match, miss]).map(\.id), [match.id])
        XCTAssertEqual(OutputHistoryFilter(searchText: "slack").apply(to: [match, miss]).map(\.id), [match.id])
        XCTAssertEqual(OutputHistoryFilter(searchText: "  ").apply(to: [match, miss]).count, 2)
    }

    func testCombinedScopeStatusAndSearch() {
        let target = makeReport(modeID: OutputMode.taskID, status: .succeeded, sourceApp: "Xcode", raw: "build passed")
        let wrongStatus = makeReport(modeID: OutputMode.taskID, status: .failed, sourceApp: "Xcode", raw: "build passed")
        let wrongScope = makeReport(modeID: OutputMode.cleanID, status: .succeeded, sourceApp: "Xcode", raw: "build passed")
        let filter = OutputHistoryFilter(scope: .tasks, status: .succeeded, searchText: "build")

        let result = filter.apply(to: [target, wrongStatus, wrongScope])

        XCTAssertEqual(result.map(\.id), [target.id])
    }
}
