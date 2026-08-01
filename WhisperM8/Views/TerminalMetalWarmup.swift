import Foundation
import Metal

/// Waermt Metals Shader-Cache vor, damit das erste Terminal sofort zeichnet.
///
/// **Das Problem:** SwiftTerm liefert seine Shader als Quelltext
/// (`Shaders.metal` im Resource-Bundle) statt als vorkompilierte
/// `default.metallib` aus — eine vorkompilierte Variante wuerde die separat zu
/// ladende Metal-Toolchain von Xcode voraussetzen und damit jeden Build-Rechner
/// belasten. Der Renderer uebersetzt die Quelle deshalb beim ersten Aufbau
/// selbst, und zwar **synchron auf dem Main Thread**, weil er im
/// `viewDidMoveToWindow` der Terminal-View entsteht.
///
/// **Gemessen (30.07.2026, M-Serie):** erste Uebersetzung 262 ms, jede weitere
/// 0,6 ms. Der Metal-Compiler-Cache liegt auf der Platte und ueberlebt
/// App-Neustarts, der Treffer faellt also nur einmal an — nach der Installation,
/// nach einem SwiftTerm-Update oder wenn der System-Cache geleert wurde. Genau
/// dann aber trifft er das Oeffnen des ersten Chats, und eine Viertelsekunde
/// Standbild beim ersten Chat ist der schlechteste Moment dafuer.
///
/// **Die Loesung:** dieselbe Quelle beim App-Start einmal im Hintergrund
/// uebersetzen und das Ergebnis wegwerfen. Der Cache ist danach warm, das erste
/// Terminal zahlt nur noch die 0,6 ms. Schlaegt irgendetwas fehl, passiert
/// nichts — der Renderer uebersetzt dann wie bisher selbst.
enum TerminalMetalWarmup {
    /// Name des SwiftPM-Resource-Bundles, in dem die Shader-Quelle liegt.
    private static let bundleName = "SwiftTerm_SwiftTerm.bundle"

    /// Startet das Vorwaermen, sofern der Metal-Renderer ueberhaupt aktiv ist.
    /// Kehrt sofort zurueck; die Arbeit laeuft auf einer Hintergrund-Queue.
    ///
    /// **Bekannte Luecke (Review 01.08.2026):** Das Vorwaermen ist
    /// fire-and-forget und gewinnt kein Rennen. Die App oeffnet ihr
    /// Agent-Chats-Fenster beim Start automatisch; wird dabei ein Chat
    /// wiederhergestellt, kann `QuietableTerminalView.viewDidMoveToWindow`
    /// die Shader-Uebersetzung anstossen, bevor das Vorwaermen fertig ist —
    /// dann wartet der Main Thread doch. Beide Uebersetzungen sind
    /// unschaedlich (Metal darf off-main), nur der Zweck verfehlt.
    ///
    /// Bewusst nicht abgesichert: Warten hiesse den Start blockieren, also
    /// genau das eintauschen, was vermieden werden soll. Der Fall trifft
    /// ausserdem nur den allerersten Start nach Installation oder
    /// Cache-Loeschung, und nur bei eingeschaltetem Metal — das ist Opt-in
    /// und derzeit aus. Sollte Metal je Default werden, gehoert das gemessen.
    static func warmUpIfNeeded() {
        guard QuietableTerminalView.metalRendererOptIn else { return }
        DispatchQueue.global(qos: .utility).async { warmUp() }
    }

    private static func warmUp() {
        guard let source = shaderSource(in: defaultSearchRoots()) else {
            Logger.agentPerformance.debug("terminal_metal_warmup_skipped reason=shader_source_missing")
            return
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.agentPerformance.debug("terminal_metal_warmup_skipped reason=no_device")
            return
        }
        let started = Date()
        do {
            // Ergebnis wird bewusst verworfen — es geht nur um den Cache-Eintrag,
            // den der Renderer spaeter auf dem Main Thread trifft.
            _ = try device.makeLibrary(source: source, options: nil)
            let ms = Date().timeIntervalSince(started) * 1000
            Logger.agentPerformance.info("terminal_metal_warmup_done ms=\(Int(ms), privacy: .public)")
        } catch {
            // Kein Fehlerfall fuer den User: der Renderer versucht es selbst
            // erneut und faellt notfalls auf die CPU-Darstellung zurueck.
            Logger.agentPerformance.debug("terminal_metal_warmup_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Dieselben Orte, an denen auch SwiftTerm sein Resource-Bundle sucht:
    /// `Contents/Resources` einer gepackten .app zuerst, dann die Bundle-Wurzel
    /// (nacktes Executable aus `.build`).
    static func defaultSearchRoots() -> [URL] {
        [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ].compactMap { $0 }
    }

    /// Liest `Shaders.metal` aus dem ersten Suchort, der es hergibt.
    /// `roots` ist ein Parameter, damit die Suche ohne echtes App-Bundle
    /// testbar bleibt.
    static func shaderSource(in roots: [URL]) -> String? {
        for root in roots {
            guard let bundle = Bundle(url: root.appendingPathComponent(bundleName)),
                  let shaderURL = bundle.url(forResource: "Shaders", withExtension: "metal"),
                  let source = try? String(contentsOf: shaderURL, encoding: .utf8)
            else { continue }
            return source
        }
        return nil
    }
}
