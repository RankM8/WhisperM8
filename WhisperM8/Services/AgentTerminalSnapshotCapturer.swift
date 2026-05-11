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

/// Reine, testbare Snapshot-Bau-Logik.
enum AgentTerminalSnapshotBuilder {
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

    /// Heuristik fuer "Snapshot hat sich geaendert" — nutzt einen schnellen
    /// Hash ueber den Tail.
    static func contentDigest(_ text: String) -> Int {
        let tail = AgentTerminalSnapshot.clampedFromEnd(text, maxBytes: 4 * 1024)
        return tail.hashValue
    }
}

/// Event-driven Snapshot-Worker. Schreibt den Terminal-Zustand auf Disk an
/// folgenden Triggern (statt periodischem Polling):
///
/// 1. App wechselt in den Hintergrund (`willResignActiveNotification`)
/// 2. App wird beendet (`willTerminateNotification`)
/// 3. Subprozess beendet sich (`markProcessTerminated`)
/// 4. Externer Aufrufer ruft `flush()` (z. B. Tab-Switch, Resume-Klick)
///
/// Damit eine *paranoide* Sicherheit bei Force-Quit erhalten bleibt, schreiben
/// wir ZUSAETZLICH alle 30 s einen Heartbeat-Snapshot, falls sich der Buffer
/// veraendert hat. Bei einem ruhigen Terminal: 1 Write/30s. Bei aktiver
/// Session: max 1 Write/30s — Snapshots sind State, kein Audit-Log.
@MainActor
final class AgentTerminalSnapshotCapturer {
    /// Sicherheits-Snapshot-Intervall: 30 s. Bewusst sehr langsam — die
    /// wirkliche Persistenz erfolgt event-driven. Dieser Timer ist nur fuer
    /// den seltenen Fall "App crashed ohne willResignActive zu feuern".
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

    /// Bindet den Capturer an einen Terminal-View. Registriert die
    /// AppKit-Observer und startet den 30s-Heartbeat-Timer.
    func attach(terminal: LocalProcessTerminalView) {
        self.terminalView = terminal

        // App geht in Hintergrund → synchroner Flush.
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
        // Direkt schreiben, damit der naechste Restart die richtige ID sieht.
        flush()
    }

    /// Final-Snapshot bei Prozess-Exit. Danach Heartbeat-Timer aus, weil
    /// nichts mehr zu beobachten ist.
    func markProcessTerminated(exitCode: Int32?) {
        self.processWasRunning = false
        self.exitCode = exitCode
        flush()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Synchroner Snapshot-Write — schreibt IMMER, auch wenn der Digest
    /// gleich geblieben ist. Wird von allen externen Triggern (App-
    /// Background, Tab-Switch, etc.) genutzt.
    func flush() {
        guard let terminal = terminalView else { return }
        let text = readActiveBufferText(from: terminal)
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
            lastDigest = AgentTerminalSnapshotBuilder.contentDigest(text)
        }
    }

    /// Stoppt den Heartbeat-Timer. Wird vom Controller in `terminate()`
    /// aufgerufen.
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

    /// 30s-Heartbeat: nur schreiben, wenn der Buffer-Inhalt sich seit dem
    /// letzten Snapshot veraendert hat. Bei idle-Terminal: kein Write,
    /// kein Disk-IO ausser dem Hash-Check.
    private func heartbeatTick() {
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

    private func readActiveBufferText(from terminal: LocalProcessTerminalView) -> String {
        let data = terminal.getTerminal().getBufferAsData(kind: .active, encoding: .utf8)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
