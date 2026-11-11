import Foundation

/// Farbe der Lichtleiste aus dem Zustand der App. Dieselbe Bedeutung wie die
/// Status-Punkte der App: Grün heißt nur „arbeitet“.
enum ControllerLightPolicy {
    static let recording = ControllerLightTone.red
    static let working = ControllerLightTone.green
    static let awaiting = ControllerLightTone.amber
    static let idle = ControllerLightTone.dimWhite

    /// `nil`: nichts schreiben (Pause — die Farbe gehört dann jemand anderem).
    static func tone(
        isPaused: Bool,
        recordingPhase: ControllerRecordingPhase?,
        targetStatus: ControllerChatState.Status?
    ) -> ControllerLightTone? {
        if isPaused { return nil }
        if recordingPhase == .recording { return recording }
        switch targetStatus {
        case .working: return working
        case .awaitingInput: return awaiting
        default: return idle
        }
    }
}

enum ControllerLightTone: String, CaseIterable, Sendable {
    case red, green, amber, dimWhite

    /// RGB-Anteile 0…1 für die Lichtleiste.
    var components: (red: Float, green: Float, blue: Float) {
        switch self {
        case .red: return (0.90, 0.10, 0.08)
        case .green: return (0.10, 0.75, 0.35)
        case .amber: return (0.95, 0.55, 0.05)
        case .dimWhite: return (0.18, 0.18, 0.20)
        }
    }
}

/// Erkennt, wann ein Chat NEU auf eine Entscheidung wartet, und begrenzt die
/// Rückmeldung: höchstens ein Signal alle fünf Sekunden, keins während einer
/// Aufnahme und keins für den Chat, den man ohnehin vor sich hat.
struct ControllerWaitingTracker: Equatable, Sendable {
    static let minimumInterval: TimeInterval = 5

    private var awaiting: Set<UUID> = []
    private var lastSignalAt: TimeInterval?

    /// Ausgangslage festhalten, ohne zu melden (Start, Neuverbinden).
    mutating func prime(awaiting current: Set<UUID>) {
        awaiting = current
    }

    /// - Returns: `true`, wenn jetzt ein Signal fällig ist.
    mutating func update(
        awaiting current: Set<UUID>,
        visibleTarget: UUID?,
        isRecording: Bool,
        at time: TimeInterval
    ) -> Bool {
        var fresh = current.subtracting(awaiting)
        awaiting = current
        if let visibleTarget { fresh.remove(visibleTarget) }
        guard !fresh.isEmpty, !isRecording else { return false }
        if let lastSignalAt, time - lastSignalAt < Self.minimumInterval { return false }
        lastSignalAt = time
        return true
    }
}

/// Erkennt Spiele im Vordergrund, damit der Controller dort nicht dazwischen
/// funkt. Nur ein Zusatz: Der eigentliche Schutz ist, dass der Empfang im
/// Hintergrund ab Werk aus ist. Spiele über Wine (Whisky, CrossOver) und
/// Cloud-Gaming im Browser erkennt das nicht zuverlässig — dafür gibt es die
/// Pause mit L1 + R1.
enum ControllerGameDetector {
    /// Programme, die Spiele starten oder selbst welche sind, ohne sich so
    /// auszuweisen.
    static let knownBundleIDs: Set<String> = [
        "com.valvesoftware.steam",
        "com.codeweavers.CrossOver",
        "com.isaacmarovitz.Whisky",
        "com.nvidia.gfnpc.mall",
        "org.openemu.OpenEmu",
        "com.libretro.RetroArch",
        "org.dolphin-emu.dolphin",
        "net.pcsx2.pcsx2",
        "net.rpcs3.rpcs3",
        "com.apple.Games",
    ]

    static func isGame(bundleID: String?, category: String?, supportsGameMode: Bool) -> Bool {
        if supportsGameMode { return true }
        if let category, category.hasPrefix("public.app-category.") && category.hasSuffix("-games") { return true }
        if category == "public.app-category.games" { return true }
        if let bundleID, knownBundleIDs.contains(bundleID) { return true }
        return false
    }
}
