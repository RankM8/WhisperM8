import Foundation
import Observation

/// Was die Seitenspalte „Board-Chat“ je Projekt behält (WM8-113): Breite,
/// zugeklappt, und welcher Chat dort steht, wenn nicht der automatische.
/// Alle Felder optional: `nil` heißt Vorgabe, und ältere Dateien lesen sich
/// ohne Umweg.
struct BoardChatProjectPreferences: Codable, Equatable {
    var width: Double?
    var isCollapsed: Bool?
    /// Von Hand gewählter Board-Chat (Teil c). `nil` = automatisch der Jarvis.
    var chosenSessionID: UUID?
    /// Zuletzt automatisch gefundener Jarvis. So findet die Spalte ihn auch
    /// gestoppt und ohne Tab, ohne alle Chats zu durchsuchen.
    var lastJarvisSessionID: UUID?

    var isEmpty: Bool { width == nil && isCollapsed == nil && chosenSessionID == nil && lastJarvisSessionID == nil }
}

/// Inhalt von `ticket-board-chat.json`.
struct BoardChatPreferencesFile: Codable, Equatable {
    static let currentSchema = "wm8.board-chat/1"
    var schema = BoardChatPreferencesFile.currentSchema
    /// Schlüssel: Projekt-ID (Haupt-Projekt, nicht Arbeitsordner).
    var projects: [String: BoardChatProjectPreferences] = [:]

    init(projects: [String: BoardChatProjectPreferences] = [:]) {
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? Self.currentSchema
        projects = try container.decodeIfPresent([String: BoardChatProjectPreferences].self, forKey: .projects) ?? [:]
    }
}

/// Hält die Einstellungen der Spalte im Speicher und schreibt sie in eine
/// eigene Datei in Application Support. Eigene Datei statt `agent-ui-state.json`:
/// Jede Änderung dort ließe alle Fenster samt Seitenleiste neu auswerten,
/// weil sie den ganzen Fensterzustand beobachten.
///
/// Gelesen wird einmal abseits des Main Threads (`preload`), sobald der
/// Ticket-Knopf erscheint, also lange vor dem ersten Klick. Bis dahin gelten
/// die Vorgaben. Geschrieben wird gebündelt, ebenfalls abseits des Main Threads.
@MainActor
@Observable
final class BoardChatPreferencesStore {
    static let shared = BoardChatPreferencesStore()

    private(set) var projects: [UUID: BoardChatProjectPreferences] = [:]
    private(set) var isLoaded = false

    @ObservationIgnored private let read: @Sendable () -> BoardChatPreferencesFile?
    @ObservationIgnored private let write: @Sendable (BoardChatPreferencesFile) -> Void
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Änderungen vor dem Ende des Ladens: Sie gewinnen gegen die Datei.
    @ObservationIgnored private var changedBeforeLoad: Set<UUID> = []

    init(
        read: @escaping @Sendable () -> BoardChatPreferencesFile? = { BoardChatPreferencesStore.readFile(at: BoardChatPreferencesStore.defaultFileURL()) },
        write: @escaping @Sendable (BoardChatPreferencesFile) -> Void = { BoardChatPreferencesStore.writeFile($0, to: BoardChatPreferencesStore.defaultFileURL()) },
        saveDelay: Duration = .milliseconds(500)
    ) {
        self.read = read
        self.write = write
        self.saveDelay = saveDelay
    }

    nonisolated static func defaultFileURL() -> URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("ticket-board-chat.json")
    }

    // MARK: Lesen

    func preferences(for projectID: UUID) -> BoardChatProjectPreferences {
        projects[projectID] ?? BoardChatProjectPreferences()
    }

    /// Liest die Datei einmal, abseits des Main Threads. Mehrfache Aufrufe
    /// sind billig.
    func preload() {
        guard !isLoaded, loadTask == nil else { return }
        let read = read
        loadTask = Task { [weak self] in
            let file = await Task.detached(priority: .utility) { read() }.value
            self?.finishLoading(file)
        }
    }

    /// Wartet auf das Laden (Tests).
    func waitUntilLoaded() async {
        preload()
        await loadTask?.value
    }

    private func finishLoading(_ file: BoardChatPreferencesFile?) {
        var loaded: [UUID: BoardChatProjectPreferences] = [:]
        for (key, value) in file?.projects ?? [:] {
            guard let id = UUID(uuidString: key), !value.isEmpty else { continue }
            loaded[id] = value
        }
        for id in changedBeforeLoad { loaded[id] = projects[id] }
        changedBeforeLoad = []
        let merged = loaded.filter { !$0.value.isEmpty }
        if merged != projects { projects = merged }
        isLoaded = true
        loadTask = nil
    }

    // MARK: Ändern

    func setWidth(_ width: Double?, for projectID: UUID) {
        update(projectID) { $0.width = width.flatMap(BoardChatRules.clamped) }
    }

    func setCollapsed(_ collapsed: Bool, for projectID: UUID) {
        update(projectID) { $0.isCollapsed = collapsed ? true : nil }
    }

    func setChosenSession(_ sessionID: UUID?, for projectID: UUID) {
        update(projectID) { $0.chosenSessionID = sessionID }
    }

    func setLastJarvis(_ sessionID: UUID, for projectID: UUID) {
        update(projectID) { $0.lastJarvisSessionID = sessionID }
    }

    private func update(_ projectID: UUID, _ change: (inout BoardChatProjectPreferences) -> Void) {
        var value = preferences(for: projectID)
        change(&value)
        guard value != preferences(for: projectID) else { return }
        projects[projectID] = value.isEmpty ? nil : value
        if !isLoaded { changedBeforeLoad.insert(projectID) }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Nie vor dem Laden schreiben: Sonst ersetzte ein früher Klick die
            // ganze Datei durch diesen einen Eintrag.
            await self.loadTask?.value
            self.saveNow()
        }
    }

    /// Schreibt sofort, abseits des Main Threads. Eine serielle Schlange hält
    /// die Reihenfolge: Ein älterer Stand überholt nie einen neueren.
    func saveNow() {
        saveTask = nil
        let file = BoardChatPreferencesFile(projects: Dictionary(
            uniqueKeysWithValues: projects.map { ($0.key.uuidString, $0.value) }))
        let write = write
        Self.ioQueue.async { write(file) }
    }

    nonisolated private static let ioQueue = DispatchQueue(label: "com.whisperm8.app.board-chat-prefs", qos: .utility)

    /// Wartet, bis alle angestoßenen Schreibvorgänge durch sind (Tests).
    nonisolated static func waitForWrites() { ioQueue.sync {} }

    // MARK: Datei

    nonisolated static func readFile(at url: URL) -> BoardChatPreferencesFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BoardChatPreferencesFile.self, from: data)
    }

    nonisolated static func writeFile(_ file: BoardChatPreferencesFile, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
