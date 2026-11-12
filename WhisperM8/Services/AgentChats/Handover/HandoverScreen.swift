import Darwin
import Foundation
import SwiftTerm

// MARK: - Bild sichern (Schnittstelle zu Paket 1)

/// Sichert den Stand eines Terminals als ANSI-Strom: Zeilen samt Farben und
/// Stilen, Alt-Screen samt Hauptpuffer, Cursor und die Schalter, die TUIs nur
/// beim Start setzen (Kitty-Tastaturprotokoll, Maus mit SGR, Bracketed Paste,
/// Fokus-Meldungen, Cursor sichtbar, Application Cursor/Keypad).
///
/// **Einspielen** heißt immer: frisches Terminal mit denselben Spalten, Zeilen
/// und Scrollback anlegen und den Strom per `feed(byteArray:)` füttern.
/// Mehr nicht — das Bild ist damit unabhängig von der Protokollversion.
///
/// Die echte Umsetzung baut Paket 1 im SwiftTerm-Fork. Bis dahin gilt
/// `HandoverPlainTextSerializer`.
protocol HandoverScreenSerializing {
    func serialize(_ terminal: Terminal) -> [UInt8]
}

/// Platzhalter bis zum Serialisierer aus dem Fork: nur Text und Cursor, ohne
/// Farben, Stile und Schalter. Für den Aufbewahrer reicht das zum Testen; für
/// echte TUIs nicht (ohne Schalter kommen Shift+Enter und Mausklicks nach der
/// Übernahme falsch an, siehe Plan „Bild und Schalter“).
struct HandoverPlainTextSerializer: HandoverScreenSerializing {
    func serialize(_ terminal: Terminal) -> [UInt8] {
        let text = String(decoding: terminal.getBufferAsData(kind: .active), as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        // getBufferAsData schließt jede Zeile mit \n ab; das letzte Element ist leer.
        if lines.last == "" { lines.removeLast() }
        var out = [UInt8]()
        out.append(contentsOf: Array(lines.joined(separator: "\r\n").utf8))
        let cursor = terminal.getCursorLocation()
        out.append(contentsOf: Array("\u{1B}[\(cursor.y + 1);\(cursor.x + 1)H".utf8))
        return out
    }
}

// MARK: - Terminal ohne Fenster

/// Terminal des Aufbewahrers je Chat. Wird erst mit dem Bild gefüttert, dann
/// mit allem, was der Chat in der Lücke schreibt, und beantwortet dabei die
/// Rückfragen der TUIs (Cursorposition, Farben, Fähigkeiten) wie die App —
/// die Antworten schreibt `Terminal` über `send(source:data:)` in die Leitung.
///
/// **Zwischenablage-Lesen per OSC 52 wird verweigert**, dieselbe Regel wie im
/// `AgentTerminalLinkInterceptor`: sonst bekäme jede TUI den Klartext der
/// Zwischenablage. Schreiben (OSC 52 setzen) wird in der Lücke verworfen.
///
/// Nicht thread-sicher; alle Aufrufe auf der Queue des Aufbewahrers.
final class HandoverHeadlessTerminal: TerminalDelegate {
    private(set) var terminal: Terminal!
    /// Schreibt Antworten an die TUI (PTY-Master). Ersetzbar für Tests.
    private let writeToPTY: ([UInt8]) -> Void
    private let colors: (foreground: Color, background: Color)?
    private(set) var deniedClipboardReads = 0

    init(
        cols: Int,
        rows: Int,
        scrollback: Int?,
        colors: HandoverTerminalColors?,
        writeToPTY: @escaping ([UInt8]) -> Void
    ) {
        self.writeToPTY = writeToPTY
        self.colors = colors.flatMap(Self.parse)
        var options = TerminalOptions(cols: max(cols, 2), rows: max(rows, 1))
        if let scrollback { options.scrollback = scrollback }
        terminal = Terminal(delegate: self, options: options)
    }

    func feed(_ bytes: [UInt8]) {
        terminal.feed(byteArray: bytes)
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(buffer: bytes)
    }

    // MARK: TerminalDelegate

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        writeToPTY(Array(data))
    }

    func clipboardRead(source: Terminal) -> Data? {
        deniedClipboardReads += 1
        return nil
    }

    func clipboardCopy(source: Terminal, content: Data) {}

    func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        colors ?? (source.foregroundColor, source.backgroundColor)
    }

    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        nil
    }

    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}

    // MARK: Farben

    /// `#rrggbb` → SwiftTerm-Farbe (16 Bit je Kanal).
    static func parse(_ colors: HandoverTerminalColors) -> (foreground: Color, background: Color)? {
        guard let fg = parseHex(colors.foreground), let bg = parseHex(colors.background) else { return nil }
        return (fg, bg)
    }

    static func parseHex(_ text: String) -> Color? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = UInt16((value >> 16) & 0xFF) * 257
        let g = UInt16((value >> 8) & 0xFF) * 257
        let b = UInt16(value & 0xFF) * 257
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Prozessende per kqueue

/// Meldet das Ende eines fremden Prozesses samt Exit-Status. `waitpid` geht
/// nicht (kein eigenes Kind, ECHILD); `kqueue` mit `NOTE_EXIT |
/// NOTE_EXITSTATUS` liefert Ende und Status (Vorversuch: Status 7 gemessen).
final class HandoverExitWatcher {
    private let kq: Int32
    private var source: DispatchSourceRead?
    private let onExit: (pid_t, Int32?) -> Void

    init?(queue: DispatchQueue, onExit: @escaping (pid_t, Int32?) -> Void) {
        let kq = kqueue()
        guard kq >= 0 else { return nil }
        HandoverSocket.setCloseOnExec(kq)
        self.kq = kq
        self.onExit = onExit
        let source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(kq) }
        source.resume()
        self.source = source
    }

    /// `false`, wenn der Prozess schon weg ist (ESRCH) — der Aufrufer
    /// vermerkt das Ende dann selbst.
    func watch(pid: pid_t) -> Bool {
        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS),
            data: 0,
            udata: nil
        )
        return kevent(kq, &change, 1, nil, 0, nil) == 0
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        var events = Array<kevent>(repeating: kevent(), count: 16)
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(kq, nil, 0, &events, Int32(events.count), &zero)
        guard count > 0 else { return }
        for event in events.prefix(Int(count)) where event.filter == Int16(EVFILT_PROC) {
            let hasStatus = event.fflags & UInt32(NOTE_EXITSTATUS) != 0
            onExit(pid_t(event.ident), hasStatus ? Int32(truncatingIfNeeded: event.data) : nil)
        }
    }
}
