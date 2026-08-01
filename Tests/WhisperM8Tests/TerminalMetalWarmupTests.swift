import XCTest
@testable import WhisperM8

/// Sichert die Bundle-Suche des Shader-Vorwaermens ab.
///
/// Die Suchorte sind an SwiftTerms eigene Logik gekoppelt: eine gepackte .app
/// legt SwiftPM-Resource-Bundles in `Contents/Resources`, ein nacktes Executable
/// aus `.build` daneben. Faellt einer der beiden Faelle weg, waermt die App still
/// nichts mehr vor und der 262-ms-Treffer landet wieder beim ersten Chat —
/// ohne dass irgendetwas kaputtgeht. Genau solche stillen Regressionen fangen
/// diese Tests.
final class TerminalMetalWarmupTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metal-warmup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Legt ein flaches Resource-Bundle an — genau die Form, die SwiftPM baut:
    /// ein `.bundle`-Verzeichnis mit der Ressource direkt darin, ohne
    /// `Contents/`-Struktur und ohne Info.plist.
    @discardableResult
    private func makeShaderBundle(in root: URL, source: String = "vertex void terminal_text_vertex() {}") throws -> URL {
        let bundleURL = root.appendingPathComponent("SwiftTerm_SwiftTerm.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try source.write(to: bundleURL.appendingPathComponent("Shaders.metal"), atomically: true, encoding: .utf8)
        return bundleURL
    }

    func testFindsShaderInFlatResourceBundle() throws {
        try makeShaderBundle(in: tempDir, source: "// shader marker 42")
        let source = TerminalMetalWarmup.shaderSource(in: [tempDir])
        XCTAssertEqual(source, "// shader marker 42")
    }

    /// Der Regelfall in der gepackten .app: der erste Suchort (Contents/Resources)
    /// traegt das Bundle, der zweite (Bundle-Wurzel) nicht.
    func testPrefersFirstSearchRoot() throws {
        let first = tempDir.appendingPathComponent("Resources")
        let second = tempDir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try makeShaderBundle(in: first, source: "// aus Contents/Resources")
        try makeShaderBundle(in: second, source: "// aus der Bundle-Wurzel")

        XCTAssertEqual(TerminalMetalWarmup.shaderSource(in: [first, second]), "// aus Contents/Resources")
    }

    /// Liegt am ersten Ort nichts, wird der zweite genommen statt aufzugeben.
    func testFallsBackToSecondSearchRoot() throws {
        let empty = tempDir.appendingPathComponent("leer")
        let populated = tempDir.appendingPathComponent("voll")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: populated, withIntermediateDirectories: true)
        try makeShaderBundle(in: populated, source: "// zweiter Ort")

        XCTAssertEqual(TerminalMetalWarmup.shaderSource(in: [empty, populated]), "// zweiter Ort")
    }

    /// Kein Bundle irgendwo: nil statt Absturz — der Renderer uebersetzt dann
    /// wie bisher selbst.
    func testReturnsNilWhenBundleMissing() {
        XCTAssertNil(TerminalMetalWarmup.shaderSource(in: [tempDir]))
        XCTAssertNil(TerminalMetalWarmup.shaderSource(in: []))
    }

    /// Ein Bundle-Verzeichnis ohne die Shader-Datei darf nicht als Treffer
    /// zaehlen — sonst kaeme leerer Quelltext beim Metal-Compiler an.
    func testReturnsNilWhenShaderFileMissingFromBundle() throws {
        let bundleURL = tempDir.appendingPathComponent("SwiftTerm_SwiftTerm.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        XCTAssertNil(TerminalMetalWarmup.shaderSource(in: [tempDir]))
    }

    /// Die Suchorte muessen die beiden real vorkommenden Layouts abdecken.
    func testDefaultSearchRootsCoverBundleAndResources() {
        let roots = TerminalMetalWarmup.defaultSearchRoots()
        XCTAssertFalse(roots.isEmpty)
        XCTAssertTrue(roots.contains(Bundle.main.bundleURL))
    }
}
