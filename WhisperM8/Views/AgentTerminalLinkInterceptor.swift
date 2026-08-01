import AppKit
import SwiftTerm

/// Fängt SwiftTerms Link-Klicks ab, ohne den Rest des Terminals zu stören —
/// und verweigert TUIs das LESEN der Zwischenablage.
///
/// **Warum nötig:** `LocalProcessTerminalView` macht sich in `setup()` selbst
/// zum `terminalDelegate` und reicht nur Prozess-relevante Callbacks
/// (`sizeChanged`/`setTerminalTitle`/`hostCurrentDirectoryUpdate`/
/// `processTerminated`) an den `processDelegate` weiter — **`requestOpenLink`
/// gehört nicht dazu**. Ein Override auf dem `processDelegate` wird deshalb nie
/// aufgerufen, und der Protocol-Extension-Default macht `URL(string:) +
/// NSWorkspace.open`, was bei schemelosen Dateipfaden mit `-50` scheitert.
///
/// **Lösung (von SwiftTerm dokumentiert):** den `terminalDelegate` ersetzen und
/// „proxy the values" — alles unverändert an die Basis weiterreichen, nur
/// `requestOpenLink` selbst behandeln. Die Basis-Methoden werden per dynamischer
/// Dispatch aufgerufen, sodass die Overrides der `QuietableTerminalView`
/// (z. B. der Scroll-Lock in `scrolled(source:position:)`) erhalten bleiben.
///
/// **Warum der Proxy trotz SwiftTerm 1.15 bleibt:** Upstream-PR #599 hat
/// `requestOpenLink` inzwischen als `open` auf `LocalProcessTerminalView`
/// nachgereicht — der ursprüngliche Grund ist damit weg, ein Override in
/// `QuietableTerminalView` täte es. Der zweite Grund bleibt und wiegt schwerer:
/// `clipboardRead` (`MacLocalTerminalView.swift`) gibt jeder TUI den Klartext
/// der Zwischenablage und ist `public`, nicht `open` — per Subclass also NICHT
/// überschreibbar. Nur als eigenständiger Delegate lässt sich der Zugriff
/// abweisen. Wer den Proxy „vereinfacht", öffnet damit still das Auslesen von
/// Passwörtern aus der Zwischenablage.
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
    //
    // `clipboardRead` (neu in SwiftTerm 1.14, OSC-52-LESEN) wird bewusst
    // NICHT an die Basis weitergereicht: deren Implementierung gäbe jeder
    // TUI den Klartext-Inhalt der Zwischenablage (Passwörter!). Der
    // Extension-Default verweigert mit `nil` — gewollte Sicherheits-
    // Entscheidung, kein Versehen. Clipboard-SCHREIBEN (`clipboardCopy`,
    // OSC 52 copy) bleibt erlaubt, siehe oben.
}
