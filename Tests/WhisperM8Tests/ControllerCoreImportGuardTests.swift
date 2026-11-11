import XCTest

/// Der Controller-Kern bleibt pur (Plan 3.1): keine Oberfläche, keine Hardware.
final class ControllerCoreImportGuardTests: XCTestCase {
    static let forbiddenImports = ["AppKit", "SwiftUI", "GameController", "Cocoa"]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCoreFilesImportOnlyPureFrameworks() throws {
        let core = Self.root.appendingPathComponent("WhisperM8/Services/Controller/Core")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            checked += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                for module in Self.forbiddenImports {
                    // Auch `@preconcurrency import …` und `import struct AppKit.…` erfassen.
                    let pattern = "^(@\\w+\\s+)*import\\s+((struct|class|enum|protocol|func|var|let|typealias)\\s+)?\(module)(\\.|\\s|$)"
                    XCTAssertNil(
                        trimmed.range(of: pattern, options: .regularExpression),
                        "\(url.lastPathComponent) importiert \(module)"
                    )
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "Kern-Ordner nicht gefunden")
    }
}
