import Carbon.HIToolbox
import XCTest
@testable import WhisperM8

/// LR-DIK-025: Tastencode für Cmd+V/Cmd+C aus dem aktiven Layout.
final class KeyCodeResolverTests: XCTestCase {
    /// US-QWERTY-Ausschnitt (Code → Zeichen). QWERTZ unterscheidet sich nur bei y/z.
    private let qwerty: [UInt16: String] = [0: "a", 8: "c", 9: "v", 32: "u", 40: "k", 38: "j"]
    /// Dvorak: „v" liegt auf Code 47, „c" auf 34; Code 9 ist „k", Code 8 „j".
    private let dvorak: [UInt16: String] = [9: "k", 8: "j", 47: "v", 34: "c"]

    func testQwertyAndQwertzResolveVTo9() {
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { self.qwerty[$0] }), 9)
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "c", fallback: kVK_ANSI_C, translate: { self.qwerty[$0] }), 8)
    }

    func testDvorakResolvesVTo47() {
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { self.dvorak[$0] }), 47)
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "c", fallback: kVK_ANSI_C, translate: { self.dvorak[$0] }), 34)
    }

    func testFallsBackWhenLayoutUnreadableOrCharacterMissing() {
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { _ in nil }), 9)
        // Nicht-lateinisches Layout: kein „v" im Block.
        XCTAssertEqual(KeyCodeResolver.keyCode(for: "v", fallback: kVK_ANSI_V, translate: { _ in "ж" }), 9)
    }

    // MARK: - Layout nur auf dem Main Thread lesen (Absturz beim Diktatstart)

    private final class CountingReader: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var offMainCalls = 0
        func read() -> KeyboardLayoutCache.Snapshot? {
            lock.withLock {
                calls += 1
                if !Thread.isMainThread { offMainCalls += 1 }
            }
            return KeyboardLayoutCache.Snapshot(layout: Data([1, 2, 3]), keyboardType: 40)
        }
    }

    private func onBackground<T>(_ work: @escaping () -> T) -> T {
        var result: T?
        let done = expectation(description: "background")
        DispatchQueue.global(qos: .userInitiated).async {
            result = work()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result!
    }

    func testBackgroundThreadNeverReadsTheSystemLayout() {
        let reader = CountingReader()
        let cache = KeyboardLayoutCache(reader: reader.read)

        XCTAssertNil(onBackground { cache.current() }, "ohne Vorlesen kein Layout abseits des Main Threads")
        cache.refresh()
        let snapshot = onBackground { cache.current() }

        XCTAssertEqual(snapshot?.keyboardType, 40)
        XCTAssertEqual(reader.offMainCalls, 0, "TIS darf nie abseits des Main Threads gelesen werden")
        XCTAssertEqual(reader.calls, 1)
    }

    func testTranslatorBuiltOffMainUsesCacheAndFallsBack() {
        let cache = KeyboardLayoutCache(reader: { nil })
        let code = onBackground {
            KeyCodeResolver.keyCode(
                for: "v", fallback: kVK_ANSI_V,
                translate: KeyCodeResolver.systemTranslator(cache: cache)
            )
        }
        XCTAssertEqual(code, 9)
    }

    /// Echtes Systemlayout: auf dem Main Thread gelesen, auf einem
    /// Hintergrund-Thread übersetzt. (Den Abbruch selbst löst HIToolbox nur in
    /// der laufenden App aus, nicht im Testprozess — den Schutz prüft der
    /// Zähltest oben.)
    func testSystemLayoutWorksFromBackgroundAfterMainThreadRead() {
        let cache = KeyboardLayoutCache()
        cache.refresh()
        let code = onBackground {
            KeyCodeResolver.keyCode(
                for: "c", fallback: kVK_ANSI_C,
                translate: KeyCodeResolver.systemTranslator(cache: cache)
            )
        }
        XCTAssertLessThan(code, 51)
    }
}

