import Foundation
import SwiftUI

/// Beobachtet `~/.claude/jobs/*/state.json` und meldet die Background-
/// Session, in deren JSONL zuletzt geschrieben wurde — also wo der User
/// gerade aktiv tippt oder Claude gerade antwortet.
///
/// Wird vom `AgentChatsView` benutzt, wenn der aktive Tab ein
/// `.agentView`-TUI-Tab ist: WhisperM8 kann nicht erkennen, welche Row
/// in der TUI selektiert ist, aber wir koennen erkennen, in welcher
/// Session der JSONL-Stream gerade waechst. Das ist semantisch genau
/// "wo passiert gerade was" — eine sinnvolle Annaeherung an "in welchem
/// Sub-Chat bin ich".
///
/// Implementation: Polling-Timer alle `pollInterval` Sekunden. Lokal
/// stat()-Aufrufe sind extrem billig (Cached vom OS), wir polling deshalb
/// bewusst statt eines komplizierten DispatchSource-Setups ueber Dutzende
/// JSONL-Files. CPU-Last vernachlaessigbar.
@MainActor
final class ActiveBackgroundSessionTracker: ObservableObject {
    /// Was die UI rendert. Stabile Identitaet (Short-ID), damit SwiftUI
    /// nicht bei jedem Refresh den ganzen Header rebuilded.
    struct ActiveSession: Equatable {
        let shortID: String
        let displayName: String
        let cwd: String
        let projectDisplayName: String
        let state: String?
        /// Zeitpunkt der mtime der JSONL — fuer "vor X Sekunden aktiv"-Anzeige.
        let lastActivityAt: Date
    }

    @Published private(set) var currentSession: ActiveSession?
    /// Wann der letzte Refresh-Lauf passierte — fuer die UI, damit sie
    /// erkennen kann "der Tracker hat aktuell nichts Neues gesehen".
    @Published private(set) var lastRefreshAt: Date?

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private let pollInterval: TimeInterval
    private let recencyWindow: TimeInterval
    private let jobsDirectoryProvider: () -> URL
    /// Rate-Limit fuer `nudge()` — verhindert dass schnelle Tastendrucke
    /// einen Refresh-Sturm ausloesen.
    private let nudgeMinInterval: TimeInterval
    private var lastNudgeAt: Date?

    /// Aktiv-Flag: nur wenn `start()` aufgerufen wurde, faengt der Tracker
    /// an zu pollen. Verhindert versehentliche Doppelstarts.
    private(set) var isRunning: Bool = false

    init(
        pollInterval: TimeInterval = 5.0,
        recencyWindow: TimeInterval = 60,
        nudgeMinInterval: TimeInterval = 0.3,
        jobsDirectoryProvider: @escaping () -> URL = { SupervisorJobReader.defaultJobsDirectory }
    ) {
        self.pollInterval = pollInterval
        self.recencyWindow = recencyWindow
        self.nudgeMinInterval = nudgeMinInterval
        self.jobsDirectoryProvider = jobsDirectoryProvider
    }

    /// Startet den Polling-Loop. Idempotent: zweite Aufrufe sind no-ops.
    /// Macht direkt einen ersten Refresh, damit die UI nicht erst nach
    /// `pollInterval` Sekunden auf gefuellten State umschaltet.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh()
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                try? await Task.sleep(for: .seconds(self.pollInterval))
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    /// Stoppt den Loop und nullt den aktuellen State — die UI zeigt dann
    /// nichts mehr an. Idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        lastNudgeAt = nil
        if currentSession != nil {
            currentSession = nil
        }
    }

    /// Bittet den Tracker um einen Sofort-Refresh — typisch bei User-
    /// Aktivitaet in der TUI (Tastendruck). Rate-limited damit ein
    /// schneller Tipper keinen Refresh-Sturm ausloest. No-op wenn der
    /// Tracker gerade nicht laeuft.
    func nudge() {
        guard isRunning else { return }
        let now = Date()
        if let last = lastNudgeAt, now.timeIntervalSince(last) < nudgeMinInterval {
            return
        }
        lastNudgeAt = now
        requestRefresh()
    }

    /// Synchroner Refresh — wird vom Loop wie von `start()` direkt
    /// aufgerufen. Liest alle state.jsons, sucht das juengste, mapped
    /// den cwd auf einen lesbaren Projekt-Namen.
    private func refresh() {
        requestRefresh()
    }

    private func requestRefresh() {
        guard refreshTask == nil else { return }
        let jobsDirectory = jobsDirectoryProvider()
        let recencyWindow = recencyWindow
        refreshTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.buildSnapshot(
                    jobsDirectory: jobsDirectory,
                    recencyWindow: recencyWindow,
                    now: Date()
                )
            }.value

            guard let self, !Task.isCancelled, self.isRunning else {
                self?.refreshTask = nil
                return
            }
            if result.currentSession != self.currentSession {
                self.currentSession = result.currentSession
            }
            self.lastRefreshAt = result.lastRefreshAt
            self.refreshTask = nil
        }
    }

    nonisolated private static func buildSnapshot(
        jobsDirectory: URL,
        recencyWindow: TimeInterval,
        now: Date
    ) -> (currentSession: ActiveSession?, lastRefreshAt: Date) {
        let jobs = SupervisorJobReader.readAll(from: jobsDirectory)
        let active = SupervisorJobReader.mostRecentlyActive(
            among: jobs,
            within: recencyWindow,
            now: now
        )
        let mapped = active.map { job -> ActiveSession in
            let mtime: Date = {
                if let path = job.linkScanPath,
                   let d = SupervisorJobReader.modificationDate(at: URL(fileURLWithPath: path)) {
                    return d
                }
                return job.updatedAt ?? now
            }()
            return ActiveSession(
                shortID: job.shortID,
                displayName: Self.displayName(for: job),
                cwd: job.cwd,
                projectDisplayName: Self.projectDisplayName(forCwd: job.cwd),
                state: job.state,
                lastActivityAt: mtime
            )
        }
        return (mapped, now)
    }

    /// Title-Fallback-Kette: `name` aus state.json, sonst gekuerzter
    /// `intent`, sonst die Short-ID.
    nonisolated static func displayName(for job: SupervisorJobState) -> String {
        if let name = job.name { return name }
        if let intent = job.intent {
            let trimmed = intent.replacingOccurrences(of: "\n", with: " ")
            return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
        }
        return "Hintergrund-Agent · \(job.shortID)"
    }

    /// Macht aus einem Worktree- oder Repo-Pfad einen kurzen Anzeigenamen.
    /// `/Users/x/repos/whisperm8/.claude/worktrees/feat-a` →  `whisperm8`,
    /// `/Users/x/repos/heartbeat`                          →  `heartbeat`.
    /// Faellt auf den Last-Path-Component zurueck, wenn keiner der bekannten
    /// Marker matched.
    nonisolated static func projectDisplayName(forCwd cwd: String) -> String {
        let standardized = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let worktreeMarker = "/.claude/worktrees/"
        if let range = standardized.range(of: worktreeMarker) {
            let repoPath = String(standardized[..<range.lowerBound])
            return URL(fileURLWithPath: repoPath).lastPathComponent
        }
        return URL(fileURLWithPath: standardized).lastPathComponent
    }
}
