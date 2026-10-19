import AppKit
import XCTest
@testable import WhisperM8

/// LR-DIK-007: Scheitert die Aktivierung der Ziel-App, wird NICHT gepastet.
@MainActor
final class PasteServiceTests: XCTestCase {
    private func makeEnvironment(
        frontmost: Bool,
        pasteboard: NSPasteboard,
        posts: @escaping () -> Void
    ) -> PasteServiceEnvironment {
        PasteServiceEnvironment(
            hasAccessibilityPermission: { true },
            requestAccessibilityPermission: {},
            isFrontmost: { _ in frontmost },
            activate: { _ in },
            postPasteKeyEvent: { posts(); return true },
            pasteboard: pasteboard,
            activationTimeout: 0.1
        )
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("wm8-paste-test-\(UUID().uuidString)"))
    }

    func testActivationTimeoutDoesNotPasteAndKeepsTextOnClipboard() async {
        let pasteboard = privatePasteboard()
        var postCount = 0
        var missingTarget = 0
        let service = PasteService(environment: makeEnvironment(frontmost: false, pasteboard: pasteboard) { postCount += 1 })

        let result = await service.pastePayloadToActiveApp(
            .textOnly("Hallo Welt"),
            previousApp: NSRunningApplication.current,
            onMissingPermission: {},
            onMissingTarget: { missingTarget += 1 }
        )

        XCTAssertEqual(postCount, 0, "Ohne aktivierte Ziel-App darf kein Cmd+V gesendet werden")
        XCTAssertEqual(missingTarget, 1)
        XCTAssertFalse(result.textPasted)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hallo Welt")
    }

    func testActivatedTargetStillPastes() async {
        let pasteboard = privatePasteboard()
        var postCount = 0
        let service = PasteService(environment: makeEnvironment(frontmost: true, pasteboard: pasteboard) { postCount += 1 })

        let result = await service.pastePayloadToActiveApp(
            .textOnly("Hallo"),
            previousApp: NSRunningApplication.current,
            onMissingPermission: {},
            onMissingTarget: {}
        )

        XCTAssertEqual(postCount, 1)
        XCTAssertTrue(result.textPasted)
    }
}
