import AppKit
import Foundation
import os

/// Claude- und GPT-Kontoprofile im Arbeitsspeicher, für Seitenleiste,
/// Kontextmenüs, Controller und Limits (WM8-101).
///
/// **Warum:** Vorher lud ein Menü-Cache (`AccountMenuData`) die Profile mit 2 s Ablaufzeit
/// direkt beim Auswerten der Seitenleiste und der Menüs nach, also Platten-I/O
/// im Body, auf dem Main Thread. Jetzt lesen Body und Menüs nur diesen
/// Speicher; neu gelesen wird abseits des Main Threads.
///
/// **Wann neu gelesen wird:**
/// - bei den App-eigenen Ereignissen (Umzug, Rückgängig, Kontowechsel, Login,
///   Logout, neues oder gelöschtes Profil): die Aufrufer stoßen `refresh()` an,
///   damit das Menü sofort stimmt;
/// - beim Aktivieren der App (Login im Terminal, dann zurück in die App);
/// - alle `pollInterval` Sekunden als Netz, für Änderungen von außen.
/// Bewusst ohne Dateiwächter: Die Profilordner enthalten die Verläufe
/// (`projects/`) und würden bei jedem Schreiben feuern, die `.claude.json`
/// des Hauptkontos liegt direkt im Home-Ordner.
///
/// **Was er nicht tut:** Er schreibt nichts, weder unter `~/.claude*` noch in
/// den Schlüsselbund, und er stößt keinen Angleich an (Symlinks, MCP). Das
/// Lesen (`profiles()`) listet Ordner und liest `.claude.json` bzw.
/// `auth.json` mit Cache über Änderungszeit und Größe; den Schlüsselbund fasst
/// es nicht an.
@MainActor
@Observable
final class AccountProfileStore {
    static let shared = AccountProfileStore()

    struct Snapshot: Equatable, Sendable {
        var claude: [ClaudeAccountProfile]
        var gpt: [GPTAccountProfile]
        var hasUndoableAccountMove: Bool

        static let empty = Snapshot(claude: [], gpt: [], hasUndoableAccountMove: false)
    }

    /// Wie gelesen wird. `.live` liest die echten Profile; Tests und
    /// Snapshots geben feste Werte.
    struct Loader: Sendable {
        var load: @Sendable () -> Snapshot

        static let live = Loader {
            Snapshot(
                claude: ClaudeAccountProfiles().profiles(),
                gpt: GPTAccountProfiles().profiles(),
                hasUndoableAccountMove: AccountMoveJournal().hasUndoableBatch()
            )
        }

        static func fixed(_ snapshot: Snapshot) -> Loader { Loader { snapshot } }
    }

    static let pollInterval: TimeInterval = 30

    private(set) var snapshot: Snapshot
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Zählt abgeschlossene Lesevorgänge (Tests).
    @ObservationIgnored private(set) var loadCount = 0

    /// Der erste Stand wird synchron gelesen, einmal beim ersten Zugriff,
    /// so wie bisher der erste Zugriff auf den Menü-Cache. Ohne ihn sähe
    /// der erste Durchlauf von Menü und Limits eine leere Liste.
    init(loader: Loader = .live, initial: Snapshot? = nil) {
        self.loader = loader
        self.snapshot = initial ?? loader.load()
    }

    var claudeProfiles: [ClaudeAccountProfile] { snapshot.claude }
    var gptProfiles: [GPTAccountProfile] { snapshot.gpt }
    var hasUndoableAccountMove: Bool { snapshot.hasUndoableAccountMove }

    /// Neu lesen, abseits des Main Threads. Kommt ein Aufruf, während schon
    /// gelesen wird, folgt genau ein weiterer Lauf danach (Salven werden zu
    /// höchstens zwei Läufen). Gesetzt wird nur bei echter Änderung, damit
    /// die Seitenleiste nicht ohne Grund neu rechnet.
    func refresh() {
        guard !isLoading else {
            needsReload = true
            return
        }
        isLoading = true
        let loader = self.loader
        Task { @MainActor [weak self] in
            let fresh = await Task.detached(priority: .utility) { loader.load() }.value
            guard let self else { return }
            self.loadCount += 1
            if fresh != self.snapshot { self.snapshot = fresh }
            self.isLoading = false
            if self.needsReload {
                self.needsReload = false
                self.refresh()
            }
        }
    }

    /// Netz für Änderungen von außen: alle `pollInterval` Sekunden und beim
    /// Aktivieren der App. Einmal beim Start der App.
    func start(pollInterval: TimeInterval = AccountProfileStore.pollInterval) {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                self?.refresh()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
}
