import Foundation

/// Persistenz der Folgeauftrags-Warteschlange.
///
/// Single-Writer wie beim Workspace: Nur die App schreibt; die CLI liest die
/// Datei direkt von Disk (damit `chats queue` auch bei geschlossener App
/// funktioniert) und stellt Aufträge ausschließlich über den Control-Socket
/// ein. Datei-Schreiben ist atomar — ein abgebrochener Schreibvorgang darf
/// keine halbe Queue hinterlassen, sonst wären Aufträge verloren.
final class AgentPromptQueueStore: @unchecked Sendable {
    static let shared = AgentPromptQueueStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var prompts: [QueuedPrompt] = []
    private var loaded = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("agent-prompt-queue.json")
    }

    // MARK: - Lesen

    /// Alle bekannten Aufträge (inkl. abgeschlossener innerhalb der Karenzzeit).
    func all() -> [QueuedPrompt] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return prompts
    }

    func openPrompts(for sessionID: UUID) -> [QueuedPrompt] {
        AgentPromptQueueLogic.openPrompts(for: sessionID, in: all())
    }

    func openCounts() -> [UUID: Int] {
        AgentPromptQueueLogic.openCounts(in: all())
    }

    // MARK: - Mutationen

    @discardableResult
    func enqueue(sessionID: UUID, prompt: String, by actor: String, now: Date = Date()) -> QueuedPrompt {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        // Sequenz global vergeben (nicht pro Session): eine einzige monotone
        // Quelle ist einfacher zu prüfen und über Sessions hinweg vergleichbar.
        let entry = QueuedPrompt(
            sequence: (prompts.map(\.sequence).max() ?? 0) + 1,
            sessionID: sessionID, prompt: prompt, enqueuedAt: now, enqueuedBy: actor)
        prompts.append(entry)
        persist()
        return entry
    }

    /// Reserviert den nächsten Auftrag für die Zustellung — atomar unter dem
    /// Lock, damit zwei parallele Turn-Enden nicht denselben Prompt greifen.
    /// Der Zustand wird VOR dem Paste persistiert: stürzt die App dazwischen
    /// ab, steht `delivering` auf der Platte und wird beim Start zu `unknown`
    /// statt still erneut zugestellt.
    func reserveNext(for sessionID: UUID, now: Date = Date()) -> QueuedPrompt? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let next = AgentPromptQueueLogic.nextDeliverable(for: sessionID, in: prompts),
              let index = prompts.firstIndex(where: { $0.id == next.id }) else {
            return nil
        }
        prompts[index].state = .delivering
        persist()
        return prompts[index]
    }

    func markDelivered(id: UUID, now: Date = Date()) {
        mutate { prompts in
            guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
            prompts[index].state = .delivered
            prompts[index].deliveredAt = now
        }
    }

    /// Zustellung gescheitert. `retry: true` stellt den Auftrag zurück in die
    /// Warteschlange (z. B. Ziel war kurz nicht bereit); `false` schließt ihn
    /// als gescheitert ab.
    func markFailed(id: UUID, error: String, retry: Bool, now: Date = Date()) {
        mutate { prompts in
            guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
            prompts[index].state = retry ? .pending : .failed
            prompts[index].lastError = error
            if !retry { prompts[index].deliveredAt = now }
        }
    }

    /// Storniert offene Aufträge. `ids == nil` storniert alle offenen der
    /// Session. Bereits zugestellte bleiben unberührt — Historie wird nicht
    /// umgeschrieben.
    @discardableResult
    func cancel(sessionID: UUID, ids: Set<UUID>? = nil, now: Date = Date()) -> [QueuedPrompt] {
        var cancelled: [QueuedPrompt] = []
        mutate { prompts in
            for index in prompts.indices
            where prompts[index].sessionID == sessionID && prompts[index].isOpen {
                if let ids, !ids.contains(prompts[index].id) { continue }
                // Eine laufende Zustellung lässt sich nicht mehr zurückholen —
                // der Text ist bereits unterwegs in die PTY.
                guard prompts[index].state == .pending else { continue }
                prompts[index].state = .cancelled
                prompts[index].deliveredAt = now
                cancelled.append(prompts[index])
            }
        }
        return cancelled
    }

    /// Beim App-Start aufrufen: unklare Zustellungen kennzeichnen und alte
    /// abgeschlossene Einträge entfernen.
    func reconcileOnLaunch(now: Date = Date()) {
        mutate { prompts in
            prompts = AgentPromptQueueLogic.pruned(
                AgentPromptQueueLogic.reconcileAfterRestart(prompts), now: now)
        }
    }

    // MARK: - Intern

    private func mutate(_ body: (inout [QueuedPrompt]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        body(&prompts)
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        prompts = Self.read(from: fileURL)
    }

    /// Reiner Disk-Read — auch von der CLI genutzt (dort ohne jede
    /// Schreib-Nebenwirkung).
    static func read(from fileURL: URL) -> [QueuedPrompt] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([QueuedPrompt].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(prompts) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomar: ein Absturz mitten im Schreiben darf keine halbe Queue
        // hinterlassen — das wäre exakt der Auftragsverlust, den dieses
        // Feature verhindern soll.
        try? data.write(to: fileURL, options: .atomic)
    }
}
