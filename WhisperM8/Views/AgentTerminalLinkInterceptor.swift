import AppKit
import SwiftTerm

/// Fängt SwiftTerms Link-Klicks ab, ohne den Rest des Terminals zu stören.
///
/// **Warum nötig:** `LocalProcessTerminalView` macht sich in `setup()` selbst
/// zum `terminalDelegate` und reicht nur Prozess-relevante Callbacks
/// (`sizeChanged`/`setTerminalTitle`/`hostCurrentDirectoryUpdate`/
/// `processTerminated`) an den `processDelegate` weiter — **`requestOpenLink`
/// gehört nicht dazu** und ist auch nicht als `open`-Klassenmethode
/// überschreibbar (nur Protocol-Extension-Default, der `URL(string:) +
/// NSWorkspace.open` macht und bei schemelosen Dateipfaden mit `-50` scheitert).
/// Ein Override auf dem `processDelegate` wird deshalb nie aufgerufen.
///
/// **Lösung (von SwiftTerm dokumentiert):** den `terminalDelegate` ersetzen und
/// „proxy the values" — alles unverändert an die Basis weiterreichen, nur
/// `requestOpenLink` selbst behandeln. Die Basis-Methoden werden per dynamischer
/// Dispatch aufgerufen, sodass die Overrides der `QuietableTerminalView`
/// (z. B. der Scroll-Lock in `scrolled(source:position:)`) erhalten bleiben.
@MainActor
final class AgentTerminalLinkInterceptor: @preconcurrency TerminalViewDelegate {
    private weak var base: LocalProcessTerminalView?
    private let onOpenLink: (String, [String: String]) -> Void

    init(base: LocalProcessTerminalView, onOpenLink: @escaping (String, [String: String]) -> Void) {
        self.base = base
        self.onOpenLink = onOpenLink
    }

    /// Der eigentliche Fix — statt SwiftTerms `URL(string:)`-Default.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        onOpenLink(link, params)
    }

    // MARK: - Alles Übrige unverändert an die Basis
    // (sonst bricht Tippen, Resize, Clipboard-Copy oder der Scroll-Lock).

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        base?.send(source: source, data: data)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        base?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {
        base?.setTerminalTitle(source: source, title: title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        base?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }
    func scrolled(source: TerminalView, position: Double) {
        base?.scrolled(source: source, position: position)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        base?.clipboardCopy(source: source, content: content)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        base?.rangeChanged(source: source, startY: startY, endY: endY)
    }

    // `bell` + `iTermContent` bewusst NICHT überschrieben → SwiftTerm-Extension-
    // Defaults greifen (identisch zur Basis; der hörbare Bell wird ohnehin auf
    // Terminal-Delegate-Ebene in QuietableTerminalView abgefangen).
}
