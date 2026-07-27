import Foundation

// ==============================================================================
// Bestaetigung, dass Codex den Tastendruck tatsaechlich ausgefuehrt hat.
//
// Beobachtung aus dem Spike (26.07.2026): jede erfolgreiche Ausfuehrung eines
// Codex-Kommandos hinterlaesst binnen ~0,5 s ein Paar
// `response_routed … conversationId=null` im Desktop-Log. Das Grundrauschen
// dieser Zeile war in den umliegenden Minuten exakt null; bei den zwei
// Fokus-Druecken erschien sie, bei den zwei fokusfreien nicht.
//
// WICHTIG: Das ist eine undokumentierte Interna, kein Vertrag. Sie darf die
// Zuversicht erhoehen, aber nie Voraussetzung sein — faellt sie mit einem
// Codex-Update weg, muss das Voice Gate weiter funktionieren. Deshalb ist eine
// AUSBLEIBENDE Signatur kein Fehlschlag, sondern nur eine Notiz im Log.
// Mechanisches Scheitern (Fokus nicht erhalten) erkennt der Toggler selbst.
// ==============================================================================

struct CodexCommandExecutionProbe {
    private let logRoot: URL
    private let now: () -> Date

    init(
        logRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(CodexVoiceSessionProbe.codexBundleIdentifier)", isDirectory: true),
        now: @escaping () -> Date = Date.init
    ) {
        self.logRoot = logRoot
        self.now = now
    }

    /// Signatur einer ausgefuehrten Kommando-Aktion.
    static func containsExecutionSignature(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.contains("response_routed") && line.contains("conversationId=null")
        }
    }

    /// Byte-Stand der aktuellsten Logdatei — vor dem Tastendruck aufnehmen.
    func snapshot() -> (url: URL, offset: UInt64)? {
        guard let url = newestLogFile() else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        return (url, size ?? 0)
    }

    /// Wartet, bis die Signatur nach dem Schnappschuss auftaucht.
    /// - Returns: `true` = bestaetigt, `false` = binnen `timeout` nichts gesehen.
    func awaitExecutionSignature(
        after snapshot: (url: URL, offset: UInt64)?,
        timeout: TimeInterval = 1.5,
        pollInterval: TimeInterval = 0.2
    ) async -> Bool {
        guard let snapshot else { return false }
        let deadline = now().addingTimeInterval(timeout)

        while now() < deadline {
            if let fresh = Self.readFrom(url: snapshot.url, offset: snapshot.offset),
               Self.containsExecutionSignature(fresh) {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    // MARK: - Datei

    private func newestLogFile() -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let directory = logRoot.appendingPathComponent(
            String(format: "%04d/%02d/%02d", year, month, day),
            isDirectory: true
        )
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return files
            .filter { $0.pathExtension == "log" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
    }

    static func readFrom(url: URL, offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return nil }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
