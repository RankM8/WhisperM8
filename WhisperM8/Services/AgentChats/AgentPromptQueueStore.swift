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
        AppInstance.applicationSupport
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

    /// Wirft, wenn der Auftrag nicht dauerhaft gesichert werden konnte
    /// (LR-AK-018) — der Aufrufer darf dann keinen Erfolg melden; der Eintrag
    /// wird wieder zurückgenommen.
    @discardableResult
    func enqueue(sessionID: UUID, prompt: String, by actor: String, verified: Bool = false, now: Date = Date()) throws -> QueuedPrompt {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        // Sequenz global vergeben (nicht pro Session): eine einzige monotone
        // Quelle ist einfacher zu prüfen und über Sessions hinweg vergleichbar.
        let entry = QueuedPrompt(
            sequence: (prompts.map(\.sequence).max() ?? 0) + 1,
            sessionID: sessionID, prompt: prompt, enqueuedAt: now, enqueuedBy: actor, enqueuedVerified: verified)
        prompts.append(entry)
        do {
            try persist()
        } catch {
            prompts.removeAll { $0.id == entry.id }
            throw error
        }
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
        do {
            try persist()
        } catch {
            // Ohne durables `delivering` darf nicht gesendet werden: ein Absturz
            // danach ließe auf Disk `pending` stehen und der Auftrag liefe doppelt.
            prompts[index].state = .pending
            Logger.agentStore.error("queue_reserve_persist_failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
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
        let before = prompts
        body(&prompts)
        // Unveränderter Bestand schreibt nichts — insbesondere darf eine wegen
        // Decode-Fehler leer geladene Queue nie die Originaldatei ersetzen.
        guard prompts != before else { return }
        do {
            try persist()
        } catch {
            Logger.agentStore.error("queue_persist_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty,
           Self.decode(data) == nil {
            // Nicht dekodierbar: Original sichern, bevor irgendein Write die
            // Datei durch eine leere/neue Queue ersetzt (LR-AK-018).
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970 * 1000))")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            Logger.agentStore.error("queue_file_undecodable backup=\(backup.lastPathComponent, privacy: .public)")
        }
        prompts = Self.read(from: fileURL)
    }

    private static func decode(_ data: Data) -> [QueuedPrompt]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([QueuedPrompt].self, from: data)
    }

    /// Reiner Disk-Read — auch von der CLI genutzt (dort ohne jede
    /// Schreib-Nebenwirkung).
    static func read(from fileURL: URL) -> [QueuedPrompt] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return decode(data) ?? []
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(prompts)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomar: ein Absturz mitten im Schreiben darf keine halbe Queue
        // hinterlassen — das wäre exakt der Auftragsverlust, den dieses
        // Feature verhindern soll.
        try data.write(to: fileURL, options: .atomic)
        // Volle Prompts nur für den eigenen Benutzer (LR-CLI-012).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
