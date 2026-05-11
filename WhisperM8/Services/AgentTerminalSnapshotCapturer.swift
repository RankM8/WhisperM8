import Foundation
import SwiftTerm

/// Konfigurations-Bundle fuer einen Snapshot-Capturer. Trennt die "wer bin
/// ich"-Metadaten vom Terminal-Lifecycle, damit `AgentTerminalController`
/// hiermit nicht angereichert werden muss.
struct AgentTerminalSnapshotContext: Equatable {
    var localSessionID: UUID
    var provider: AgentProvider
    var externalSessionID: String?
    var cwd: String
}

/// Reine, testbare Snapshot-Bau-Logik: aus rohem PTY-Buffer-Text werden
/// `visibleText` (letzte ~ 8 KiB) und `scrollbackText` (letzte ~ 64 KiB)
/// extrahiert und in ein `AgentTerminalSnapshot` gepackt.
enum AgentTerminalSnapshotBuilder {
    /// Baut ein Snapshot. `rawText` ist das, was SwiftTerms
    /// `Terminal.getBufferAsData(kind: .active)` liefert (UTF-8 decodiert).
    static func makeSnapshot(
        context: AgentTerminalSnapshotContext,
        rawText: String,
        terminalColumns: Int?,
        terminalRows: Int?,
        processWasRunning: Bool,
        exitCode: Int32?,
        capturedAt: Date = Date()
    ) -> AgentTerminalSnapshot {
        let clamped = AgentTerminalSnapshot.clamp(visible: rawText, scrollback: rawText)
        return AgentTerminalSnapshot(
            localSessionID: context.localSessionID,
            provider: context.provider,
            externalSessionID: context.externalSessionID,
            cwd: context.cwd,
            capturedAt: capturedAt,
            terminalColumns: terminalColumns,
            terminalRows: terminalRows,
            processWasRunning: processWasRunning,
            exitCode: exitCode,
            visibleText: clamped.visible,
            scrollbackText: clamped.scrollback,
            ansiReplayDataPath: nil
        )
    }

    /// Heuristik fuer "Snapshot hat sich aendern" — nutzt einen schnellen
    /// Hash ueber Visible-Slice. Wird vom Capturer benutzt, um Writes zu
    /// sparen wenn das Terminal idle ist.
    static func contentDigest(_ text: String) -> Int {
        // Wir hashen nur die letzten 4 KiB — reicht aus um Aenderungen zu
        // erkennen, ist deutlich schneller als ueber 64 KiB zu hashen.
        let tail = AgentTerminalSnapshot.clampedFromEnd(text, maxBytes: 4 * 1024)
        return tail.hashValue
    }
}

/// Periodischer Snapshot-Worker fuer einen `LocalProcessTerminalView`.
/// Verantwortlich fuer:
/// 1. Polling-Timer (Default 1.5s)
/// 2. Aenderungs-Detektion (Hash ueber Visible-Tail)
/// 3. Final-Flush bei Prozess-Ende / App-Background / Terminate
///
/// Hat absichtlich **keinen** direkten Bezug zum `AgentTerminalController` —
/// der Controller besitzt eine Instanz und ruft `attach(terminal:)` /
/// `flush()` / `stop()` auf.
@MainActor
final class AgentTerminalSnapshotCapturer {
    private let context: AgentTerminalSnapshotContext
    private let store: AgentTerminalSnapshotStore
    private let pollInterval: TimeInterval

    private weak var terminalView: LocalProcessTerminalView?
    private var timer: Timer?
    private var lastDigest: Int = 0
    /// Status des Subprozesses zum Zeitpunkt der letzten Capture-Runde. Wird
    /// im Snapshot gespeichert, damit der Recovery-Pfad weiss, ob's ein
    /// Final-Snapshot ist.
    private var processWasRunning = true
    private var exitCode: Int32?

    init(
        context: AgentTerminalSnapshotContext,
        store: AgentTerminalSnapshotStore = AgentTerminalSnapshotStore(),
        pollInterval: TimeInterval = 1.5
    ) {
        self.context = context
        self.store = store
        self.pollInterval = pollInterval
    }

    /// Bindet den Capturer an einen konkreten Terminal-View und startet den
    /// Polling-Timer. Idempotent: doppeltes Attach ueberschreibt das Target.
    func attach(terminal: LocalProcessTerminalView) {
        self.terminalView = terminal
        startTimer()
    }

    /// Setzt die externe Session-ID. Wird vom Caller aufgerufen wenn die
    /// Indexer-Retry-Schleife oder der Hook eine ID gebunden hat — damit
    /// der naechste Snapshot die korrekte externe ID festhaelt.
    func updateExternalSessionID(_ id: String?) {
        var newContext = context
        newContext.externalSessionID = id
        // Wir koennen `context` nicht direkt mutieren (let), aber wir
        // schreiben den naechsten Snapshot mit dieser ID. Trick: in einer
        // Closure-Capture umwandeln. Hier reicht's, wenn wir den letzten
        // Snapshot dirty markieren, der naechste Flush schreibt eh neu mit
        // der frischen ID — wir muessten dafuer aber `context` zu var
        // machen. Vereinfacht: speichere als separate Property.
        self.overriddenExternalSessionID = id
        self.lastDigest = 0 // erzwingt naechste Capture
    }

    private var overriddenExternalSessionID: String?

    /// Markiert den Subprozess als beendet. Triggert sofort einen
    /// Final-Snapshot, danach wird der Timer gestoppt.
    func markProcessTerminated(exitCode: Int32?) {
        self.processWasRunning = false
        self.exitCode = exitCode
        flush()
        stopTimer()
    }

    /// Synchroner Snapshot-Write — bricht das Polling nicht ab, sondern
    /// erzwingt einen Write jetzt. Nutzbar fuer App-Background / Terminate.
    func flush() {
        guard let terminal = terminalView else { return }
        let text = readActiveBufferText(from: terminal)
        let digest = AgentTerminalSnapshotBuilder.contentDigest(text)
        // Bei flush() schreiben wir IMMER, auch wenn digest unveraendert
        // ist — wir wollen den letzten State persistieren.
        var effectiveContext = context
        if let override = overriddenExternalSessionID {
            effectiveContext.externalSessionID = override
        }
        let cols = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows
        let snapshot = AgentTerminalSnapshotBuilder.makeSnapshot(
            context: effectiveContext,
            rawText: text,
            terminalColumns: cols,
            terminalRows: rows,
            processWasRunning: processWasRunning,
            exitCode: exitCode
        )
        if store.save(snapshot) {
            lastDigest = digest
        }
    }

    /// Stoppt das Polling. Idempotent. Wird vom Controller in `deinit` und
    /// `markProcessTerminated` aufgerufen.
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        stopTimer()
        let interval = pollInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        // `.common` damit der Timer auch waehrend Window-Drag / Menu-Open weiter feuert.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Pruefe alle `pollInterval` Sekunden, ob der Buffer sich geaendert
    /// hat. Falls ja → Snapshot schreiben.
    private func tick() {
        guard let terminal = terminalView else { return }
        let text = readActiveBufferText(from: terminal)
        let digest = AgentTerminalSnapshotBuilder.contentDigest(text)
        guard digest != lastDigest else { return }
        var effectiveContext = context
        if let override = overriddenExternalSessionID {
            effectiveContext.externalSessionID = override
        }
        let cols = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows
        let snapshot = AgentTerminalSnapshotBuilder.makeSnapshot(
            context: effectiveContext,
            rawText: text,
            terminalColumns: cols,
            terminalRows: rows,
            processWasRunning: processWasRunning,
            exitCode: exitCode
        )
        if store.save(snapshot) {
            lastDigest = digest
        }
    }

    /// Holt den aktiven Buffer (Scrollback + sichtbar) als UTF-8-decodierten
    /// String. Trailing-Whitespace pro Zeile ist schon entfernt
    /// (SwiftTerm trimt mit `trimRight: true`).
    private func readActiveBufferText(from terminal: LocalProcessTerminalView) -> String {
        let data = terminal.getTerminal().getBufferAsData(kind: .active, encoding: .utf8)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
