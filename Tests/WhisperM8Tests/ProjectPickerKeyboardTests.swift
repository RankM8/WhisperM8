import Foundation
import XCTest
@testable import WhisperM8

/// Tastatur-Navigation der „Neuer Chat"-Ordnersuche: geklemmte Pfeiltasten
/// (kein Wrap) + Highlight-Normalisierung nach Filterwechsel. Reine Logik.
final class ProjectPickerKeyboardTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private var order: [UUID] { [a, b, c] }

    // MARK: move

    func testMoveDownAdvancesByOne() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: a, in: order, direction: 1), b)
    }

    func testMoveUpGoesBackByOne() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: b, in: order, direction: -1), a)
    }

    func testMoveDownClampsAtBottom() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: c, in: order, direction: 1), c)
    }

    func testMoveUpClampsAtTop() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: a, in: order, direction: -1), a)
    }

    func testMoveFromNilDownReturnsFirst() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: nil, in: order, direction: 1), a)
    }

    func testMoveFromNilUpReturnsLast() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: nil, in: order, direction: -1), c)
    }

    func testMoveOnEmptyReturnsNil() {
        XCTAssertNil(ProjectPickerKeyboard.move(from: a, in: [], direction: 1))
    }

    func testMoveWithUnknownCurrentDownReturnsFirst() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: UUID(), in: order, direction: 1), a)
    }

    func testMoveWithUnknownCurrentUpReturnsLast() {
        XCTAssertEqual(ProjectPickerKeyboard.move(from: UUID(), in: order, direction: -1), c)
    }

    // MARK: normalize

    func testNormalizeKeepsValidSelection() {
        XCTAssertEqual(ProjectPickerKeyboard.normalize(b, in: order), b)
    }

    func testNormalizeResetsToFirstWhenSelectionRemoved() {
        XCTAssertEqual(ProjectPickerKeyboard.normalize(UUID(), in: order), a)
    }

    func testNormalizeResetsToFirstWhenNil() {
        XCTAssertEqual(ProjectPickerKeyboard.normalize(nil, in: order), a)
    }

    func testNormalizeOnEmptyReturnsNil() {
        XCTAssertNil(ProjectPickerKeyboard.normalize(a, in: []))
    }
}
