import Foundation

/// Merkt sich auf Disk, welche Geräte das Audio-Ducking gerade leiser gestellt
/// hat. Läuft die Session sauber zu Ende, ist der Eintrag wieder weg. Bleibt er
/// stehen, war etwas dazwischen: Absturz, `make kill`, AirPods mitten in der
/// Aufnahme abgesetzt. Dann stellt `AudioDuckingManager.recoverPendingRestores()`
/// die Lautstärke nach, sobald das Gerät wieder erreichbar ist.
///
/// Schlüssel ist die Geräte-UID: Die `AudioDeviceID` wechselt beim Wiederverbinden.
struct AudioDuckingJournal {
    struct Entry: Codable, Equatable {
        var uid: String
        var name: String
        var originalVolume: Float
        var duckedVolume: Float
        var duckedAt: Date
    }

    /// Ältere Einträge gelten als erledigt: Wer eine Woche später ein Gerät
    /// auf genau dem Duck-Wert hat, hat ihn selbst so eingestellt.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private let load: () -> Data?
    private let store: (Data?) -> Void

    init(
        load: @escaping () -> Data? = { AppPreferences.shared.audioDuckingPendingRestores },
        store: @escaping (Data?) -> Void = { AppPreferences.shared.audioDuckingPendingRestores = $0 }
    ) {
        self.load = load
        self.store = store
    }

    var entries: [Entry] {
        guard let data = load() else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    var isEmpty: Bool { entries.isEmpty }

    func entry(forUID uid: String) -> Entry? {
        entries.first { $0.uid == uid }
    }

    func record(_ entry: Entry) {
        var all = entries.filter { $0.uid != entry.uid }
        all.append(entry)
        save(all)
    }

    func remove(uid: String) {
        let all = entries
        let remaining = all.filter { $0.uid != uid }
        guard remaining.count != all.count else { return }
        save(remaining)
    }

    private func save(_ entries: [Entry]) {
        guard !entries.isEmpty else {
            store(nil)
            return
        }
        store(try? JSONEncoder().encode(entries))
    }
}
