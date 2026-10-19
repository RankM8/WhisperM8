import AppKit
import XCTest
@testable import WhisperM8

/// W2b-Blocker: Datenschutz im Diktat-Kontext.
final class DictationPrivacyTests: XCTestCase {
    /// LR-DIK-008: Entfernter Chat-Kontext darf seinen Verlauf nicht im Prompt lassen.
    func testRemovedChatContextDropsTailFromPrompt() {
        let template = PostProcessingTemplate(
            id: "t", name: "T", description: "T", instruction: "A {agentChatTail} B",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), isBuiltIn: false)
        var bundle = TranscriptContextBundle(agentChatTail: "SECRET-TAIL")
        bundle.agentChat = nil
        XCTAssertFalse(template.render(rawTranscript: "x", language: "de", contextBundle: bundle).contains("SECRET-TAIL"))
    }

    /// LR-DIK-023: Passwort-Manager-Markierungen werden erkannt.
    func testConfidentialPasteboardTypesAreRecognized() {
        XCTAssertTrue(PasteboardPrivacy.isConfidential(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(PasteboardPrivacy.isConfidential(["org.nspasteboard.TransientType"]))
        XCTAssertFalse(PasteboardPrivacy.isConfidential(["public.utf8-plain-text"]))
    }

    func testConfidentialSnapshotIsMarked() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("pw", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        XCTAssertTrue(PasteboardSnapshot.capture(from: pasteboard).isConfidential)
    }
}
