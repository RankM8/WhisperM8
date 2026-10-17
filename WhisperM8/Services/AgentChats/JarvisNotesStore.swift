import Combine
import Foundation

// MARK: - Jarvis-Notizen (Karte am Kachelkopf im Grid)

/// Welche Chats eine Notiz haben. Pure, damit die Regeln ohne App testbar sind:
/// - nur Einträge von **aktiven** Boards,
/// - nur, solange die Jarvis-Session des Boards lebt (ohne Jarvis keine
///   Notizen — sonst stünden über Nacht veraltete Karten im Grid),
/// - steht ein Chat auf mehreren Boards, gewinnt der zuletzt geänderte Eintrag.
enum JarvisNotesProjection {
    static func notes(file: JarvisBoardFile, aliveOwners: Set<UUID>, enabled: Bool) -> [UUID: JarvisBoardEntry] {
        guard enabled else { return [:] }
        var result: [UUID: JarvisBoardEntry] = [:]
        for board in file.boards where board.isActive && aliveOwners.contains(board.owner) {
            for entry in board.entries {
                if let existing = result[entry.sessionID], existing.updatedAt >= entry.updatedAt { continue }
                result[entry.sessionID] = entry
            }
        }
        return result
    }

    /// Ein Owner lebt, solange sein Prozess läuft (arbeitet, wartet, ruht).
    static func isAlive(_ status: AgentSessionRuntimeStatus?) -> Bool {
        switch status {
        case .working, .awaitingInput, .idle: return true
        case .errored, .stopped, .none: return false
        }
    }
}

/// Ob die Notiz-Karte einer Kachel offen ist. Pure (Entscheidungen des Users,
/// 17.10.2026): ohne Notiz zu; ein Handklick gilt, bis die Kachel den Fokus
/// gewinnt oder verliert oder der Standard umgeschaltet wird; in der Kachel,
/// in der der User arbeitet, ist die eigene Notiz zu; sonst der Standard.
enum JarvisNoteExpansion {
    static func isOpen(hasNote: Bool, override: Bool?, isFocused: Bool, defaultOpen: Bool) -> Bool {
        guard hasNote else { return false }
        if let override { return override }
        if isFocused { return false }
        return defaultOpen
    }
}

/// Hält die Notizen für die UI und die Handklick-Überschreibungen je Fenster.
///
/// Bewusst Combine mit Publishern je Session statt `@Observable` (Muster
/// `AgentSessionRuntimeStatusStore.statusPublisher(for:)`): Die Kachelköpfe
/// sind Funktionen im Body von `AgentChatsView` — eine dort gelesene
/// Observable-Property würde bei jeder Notiz-Änderung das ganze Grid neu
/// auswerten. So zeichnet nur die eigene kleine Ansicht neu.
///
/// Gefüttert beim Start (`start`) und nach jeder Board-Mutation (`reload`) —
/// die App ist einziger Schreiber des Boards, ein Datei-Beobachter ist nicht
/// nötig.
@MainActor
final class JarvisNotesStore {
    static let shared = JarvisNotesStore()

    struct OverrideKey: Hashable {
        let windowID: UUID
        let sessionID: UUID
    }

    @Published private(set) var notes: [UUID: JarvisBoardEntry] = [:]
    @Published private var overrides: [OverrideKey: Bool] = [:]

    private var boardFile = JarvisBoardFile()
    private var aliveOwners: Set<UUID> = []
    private var ownerSubscriptions: [UUID: AnyCancellable] = [:]
    private var ownerStatus: (UUID) -> AnyPublisher<AgentSessionRuntimeStatus?, Never> = { _ in
        Just(nil).eraseToAnyPublisher()
    }
    private var loadFile: () -> JarvisBoardFile = { JarvisBoardStore.load() }
    private var isEnabled: () -> Bool = { AppPreferences.shared.isJarvisNotesEnabled }
    private var started = false

    init() {}

    /// Wie `start`, aber nur beim ersten Aufruf (jedes Fenster ruft es).
    func startIfNeeded(ownerStatus: @escaping (UUID) -> AnyPublisher<AgentSessionRuntimeStatus?, Never>) {
        guard !started else { return }
        start(ownerStatus: ownerStatus)
    }

    /// Einmal beim App-Start. Abhängigkeiten injizierbar für Tests.
    func start(
        ownerStatus: @escaping (UUID) -> AnyPublisher<AgentSessionRuntimeStatus?, Never>,
        loadFile: @escaping () -> JarvisBoardFile = { JarvisBoardStore.load() },
        isEnabled: @escaping () -> Bool = { AppPreferences.shared.isJarvisNotesEnabled }
    ) {
        started = true
        ownerSubscriptions = [:]
        aliveOwners = []
        self.ownerStatus = ownerStatus
        self.loadFile = loadFile
        self.isEnabled = isEnabled
        reload()
    }

    /// Board neu lesen (nach einer Mutation). Klein und selten — ein paar
    /// Einträge, wenige Änderungen pro Stunde.
    func reload() {
        boardFile = loadFile()
        let owners = Set(boardFile.boards.map(\.owner))
        for owner in ownerSubscriptions.keys where !owners.contains(owner) {
            ownerSubscriptions[owner] = nil
            aliveOwners.remove(owner)
        }
        for owner in owners where ownerSubscriptions[owner] == nil {
            ownerSubscriptions[owner] = ownerStatus(owner).sink { [weak self] status in
                self?.ownerStatusChanged(owner, status: status)
            }
        }
        recompute()
    }

    private func ownerStatusChanged(_ owner: UUID, status: AgentSessionRuntimeStatus?) {
        let alive = JarvisNotesProjection.isAlive(status)
        guard alive != aliveOwners.contains(owner) else { return }
        if alive { aliveOwners.insert(owner) } else { aliveOwners.remove(owner) }
        recompute()
    }

    private func recompute() {
        let next = JarvisNotesProjection.notes(file: boardFile, aliveOwners: aliveOwners, enabled: isEnabled())
        if next != notes { notes = next }
    }

    // MARK: Lesen

    func notePublisher(for sessionID: UUID) -> AnyPublisher<JarvisBoardEntry?, Never> {
        $notes.map { $0[sessionID] }.removeDuplicates().eraseToAnyPublisher()
    }

    /// Chats mit Notiz — für den Schalter in der Workspace-Leiste.
    var notedSessionsPublisher: AnyPublisher<Set<UUID>, Never> {
        $notes.map { Set($0.keys) }.removeDuplicates().eraseToAnyPublisher()
    }

    // MARK: Handklick je Fenster (flüchtig, nie persistiert)

    func overridePublisher(windowID: UUID, sessionID: UUID) -> AnyPublisher<Bool?, Never> {
        let key = OverrideKey(windowID: windowID, sessionID: sessionID)
        return $overrides.map { $0[key] }.removeDuplicates().eraseToAnyPublisher()
    }

    func override(windowID: UUID, sessionID: UUID) -> Bool? {
        overrides[OverrideKey(windowID: windowID, sessionID: sessionID)]
    }

    func setOverride(_ open: Bool?, windowID: UUID, sessionID: UUID) {
        let key = OverrideKey(windowID: windowID, sessionID: sessionID)
        guard overrides[key] != open else { return }
        overrides[key] = open
    }

    /// Auswahlwechsel im Fenster: Der verlassene und der betretene Chat folgen
    /// wieder der Regel (betreten = zu, verlassen = Standard) — ein früherer
    /// Handklick gilt nicht mehr. Hängt am fensterweiten Auswahlwechsel, nicht
    /// an der Kachel: Die Einzelansicht zeigt keine Karten, wechselt aber Chats.
    func selectionChanged(from oldID: UUID?, to newID: UUID?, windowID: UUID) {
        guard oldID != newID else { return }
        if let oldID { setOverride(nil, windowID: windowID, sessionID: oldID) }
        if let newID { setOverride(nil, windowID: windowID, sessionID: newID) }
    }

    /// Standard umgeschaltet: wieder für alle Kacheln dieses Fensters.
    func clearOverrides(windowID: UUID) {
        let remaining = overrides.filter { $0.key.windowID != windowID }
        if remaining.count != overrides.count { overrides = remaining }
    }
}
