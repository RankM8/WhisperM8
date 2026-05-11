import AppKit
import Foundation
import SwiftTerm

/// Konfigurations-Bundle fuer einen Snapshot-Capturer.
struct AgentTerminalSnapshotContext: Equatable {
    var localSessionID: UUID
    var provider: AgentProvider
    var externalSessionID: String?
    var cwd: String
}

/// Pure Snapshot-Bau-Logik. Walkt den SwiftTerm-Buffer und gruppiert
/// aufeinanderfolgende Cells mit identischen Attributen in `AgentTerminalRun`s.
enum AgentTerminalSnapshotBuilder {
    /// Maximale Anzahl Zeilen pro Snapshot. Inkludiert Scrollback. Bei
    /// typischer Claude-Session mit ~30 sichtbaren Zeilen + Scrollback
    /// reichen 2000 Zeilen weit aus — ein voller Snapshot ist dann
    /// ~300-800 KB als JSON.
    static let maxLines = 2000

    static func makeSnapshot(
        context: AgentTerminalSnapshotContext,
        lines: [AgentTerminalLine],
        terminalColumns: Int?,
        terminalRows: Int?,
        processWasRunning: Bool,
        exitCode: Int32?,
        capturedAt: Date = Date()
    ) -> AgentTerminalSnapshot {
        AgentTerminalSnapshot(
            localSessionID: context.localSessionID,
            provider: context.provider,
            externalSessionID: context.externalSessionID,
            cwd: context.cwd,
            capturedAt: capturedAt,
            terminalColumns: terminalColumns,
            terminalRows: terminalRows,
            processWasRunning: processWasRunning,
            exitCode: exitCode,
            lines: lines
        )
    }

    /// Extrahiert die sichtbaren Buffer-Zeilen (`0..<terminal.rows`). Wir
    /// koennen ueber das public API keinen Scrollback einlesen
    /// (`buffer.lines` ist intern in SwiftTerm). Fuer den Use-Case
    /// "Zustand beim Schliessen wiederherstellen" reicht der Viewport.
    static func extractLines(from terminal: SwiftTerm.Terminal) -> [AgentTerminalLine] {
        let rows = terminal.rows
        guard rows > 0 else { return [] }
        var result: [AgentTerminalLine] = []
        result.reserveCapacity(rows)
        for row in 0..<rows {
            guard let bufferLine = terminal.getLine(row: row) else {
                result.append(AgentTerminalLine(runs: []))
                continue
            }
            result.append(extractLine(bufferLine))
        }
        // Hintere Leerzeilen abschneiden, aber eine Leerzeile als optischen
        // Boden erhalten.
        while result.count > 1,
              let last = result.last,
              last.runs.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            result.removeLast()
        }
        return result
    }

    /// Buffer-Line → AgentTerminalLine mit gruppierten Runs.
    /// Wide-Char-Continuation-Cells (folgende Zelle nach einer width-2-Zelle)
    /// werden uebersprungen — ihre Character-Daten sind `"\0"` und wuerden
    /// sonst doppelt erscheinen.
    static func extractLine(_ line: BufferLine) -> AgentTerminalLine {
        let cellCount = line.count
        guard cellCount > 0 else {
            return AgentTerminalLine(runs: [])
        }

        var runs: [AgentTerminalRun] = []
        var current: AgentTerminalRun?

        var i = 0
        while i < cellCount {
            let cell = line[i]
            let ch = cell.getCharacter()
            // Wide-char continuation: NULL-Char direkt nach width=2 Zelle.
            if i > 0, ch == "\0", line[i - 1].width == 2 {
                i += 1
                continue
            }

            let attr = cell.attribute
            let fg = convertColor(attr.fg, isBackground: false)
            let bg = convertColor(attr.bg, isBackground: true)
            let style = attr.style
            let bold = style.contains(.bold)
            let italic = style.contains(.italic)
            let underline = style.contains(.underline)
            let inverse = style.contains(.inverse)
            let dim = style.contains(.dim)

            // NULL-Character als sichtbares Padding-Space behandeln (kommt
            // bei leeren Buffer-Cells vor).
            let effectiveChar: Character = (ch == "\0") ? " " : ch

            if var run = current,
               run.fg == fg,
               run.bg == bg,
               run.bold == bold,
               run.italic == italic,
               run.underline == underline,
               run.inverse == inverse,
               run.dim == dim {
                run.text.append(effectiveChar)
                current = run
            } else {
                if let finished = current {
                    runs.append(finished)
                }
                current = AgentTerminalRun(
                    text: String(effectiveChar),
                    fg: fg,
                    bg: bg,
                    bold: bold,
                    italic: italic,
                    underline: underline,
                    inverse: inverse,
                    dim: dim
                )
            }
            i += 1
        }

        if let finished = current {
            runs.append(finished)
        }
        return AgentTerminalLine(runs: runs)
    }

    /// SwiftTerm.Attribute.Color → AgentTerminalCellColor. Default-Werte
    /// werden role-spezifisch gemappt, damit der Renderer ohne weiteren
    /// Kontext weiss "das ist eine Default-FG vs. Default-BG".
    static func convertColor(_ color: SwiftTerm.Attribute.Color, isBackground: Bool) -> AgentTerminalCellColor {
        switch color {
        case .defaultColor:
            return isBackground ? .defaultBg : .defaultFg
        case .defaultInvertedColor:
            return isBackground ? .defaultFg : .defaultBg
        case .ansi256(let code):
            return .ansi(code)
        case .trueColor(let r, let g, let b):
            return .rgb(r: r, g: g, b: b)
        }
    }
}

/// Event-driven Snapshot-Worker. Snapshotted bei:
/// 1. App geht in Hintergrund (`willResignActiveNotification`)
/// 2. App wird beendet (`willTerminateNotification`)
/// 3. Subprozess beendet sich (`markProcessTerminated`)
/// 4. Externer Aufrufer ruft `flush()` (z. B. Tab-Switch, Resume-Klick)
///
/// Plus alle 30s ein opportunistischer Heartbeat — schreibt nur, wenn der
/// Buffer-Inhalt sich seit dem letzten Snapshot veraendert hat.
@MainActor
final class AgentTerminalSnapshotCapturer {
    private static let heartbeatInterval: TimeInterval = 30.0

    private let context: AgentTerminalSnapshotContext
    private let store: AgentTerminalSnapshotStore

    private weak var terminalView: LocalProcessTerminalView?
    private var heartbeatTimer: Timer?
    private var lastDigest: Int = 0
    private var processWasRunning = true
    private var exitCode: Int32?
    private var overriddenExternalSessionID: String?
    private var willResignActiveObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?

    init(
        context: AgentTerminalSnapshotContext,
        store: AgentTerminalSnapshotStore = AgentTerminalSnapshotStore()
    ) {
        self.context = context
        self.store = store
    }

    deinit {
        heartbeatTimer?.invalidate()
        if let willResignActiveObserver {
            NotificationCenter.default.removeObserver(willResignActiveObserver)
        }
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
    }

    func attach(terminal: LocalProcessTerminalView) {
        self.terminalView = terminal

        willResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }

        startHeartbeat()
    }

    func updateExternalSessionID(_ id: String?) {
        self.overriddenExternalSessionID = id
        self.lastDigest = 0
        flush()
    }

    func markProcessTerminated(exitCode: Int32?) {
        self.processWasRunning = false
        self.exitCode = exitCode
        flush()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Synchroner Snapshot-Write — schreibt IMMER.
    func flush() {
        guard let terminal = terminalView else { return }
        let lines = AgentTerminalSnapshotBuilder.extractLines(from: terminal.getTerminal())
        let digest = Self.computeDigest(for: lines)
        var effectiveContext = context
        if let override = overriddenExternalSessionID {
            effectiveContext.externalSessionID = override
        }
        let cols = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows
        let snapshot = AgentTerminalSnapshotBuilder.makeSnapshot(
            context: effectiveContext,
            lines: lines,
            terminalColumns: cols,
            terminalRows: rows,
            processWasRunning: processWasRunning,
            exitCode: exitCode
        )
        if store.save(snapshot) {
            lastDigest = digest
        }
    }

    func stopTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Internals

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.heartbeatTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.heartbeatTimer = timer
    }

    /// 30s-Heartbeat: nur schreiben wenn Content sich seit letztem Snapshot
    /// veraendert hat. Wir hashen ueber die letzten N Linien als
    /// Aenderungs-Proxy.
    private func heartbeatTick() {
        guard let terminal = terminalView else { return }
        let lines = AgentTerminalSnapshotBuilder.extractLines(from: terminal.getTerminal())
        let digest = Self.computeDigest(for: lines)
        guard digest != lastDigest else { return }
        var effectiveContext = context
        if let override = overriddenExternalSessionID {
            effectiveContext.externalSessionID = override
        }
        let cols = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows
        let snapshot = AgentTerminalSnapshotBuilder.makeSnapshot(
            context: effectiveContext,
            lines: lines,
            terminalColumns: cols,
            terminalRows: rows,
            processWasRunning: processWasRunning,
            exitCode: exitCode
        )
        if store.save(snapshot) {
            lastDigest = digest
        }
    }

    /// Hash ueber die letzten ~50 Zeilen — billig zu berechnen,
    /// erkennt Aenderungen am Visible-Bereich zuverlaessig.
    nonisolated static func computeDigest(for lines: [AgentTerminalLine]) -> Int {
        var hasher = Hasher()
        let tail = lines.suffix(50)
        for line in tail {
            for run in line.runs {
                hasher.combine(run.text)
            }
        }
        return hasher.finalize()
    }
}
