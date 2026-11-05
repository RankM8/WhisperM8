import Foundation

/// Räumt Daten weg, die durch einen Umbau ihren Zweck verloren haben.
///
/// Ein abgeschalteter Schreibpfad lässt seine Altdaten sonst für immer liegen
/// — der Nutzer sieht nur, dass Plattenplatz belegt bleibt, und niemand weiß
/// später noch, wofür.
enum LegacyDataCleanup {
    /// Terminal-Snapshots (`TerminalSnapshots/`). Sie versorgten den
    /// Terminal-Modus der Transcript-Ansicht mit dem eingefrorenen
    /// Terminal-Stand einer beendeten Session. Seit die Verlaufsansicht
    /// (01.08.2026) den Verlauf direkt aus dem JSONL rendert, liest sie
    /// niemand mehr; das Schreiben ist mit demselben Umbau entfallen.
    ///
    /// Läuft genau EINMAL (Flag in den Defaults) und off-main. Fehler werden
    /// bewusst geschluckt: Ein nicht gelöschter Ordner ist kein Grund, den
    /// Start zu stören.
    static func removeObsoleteTerminalSnapshots(
        defaults: UserDefaults = .standard,
        directory: URL? = nil
    ) {
        removeOnce(
            flag: "terminalSnapshotsPurged",
            directory: directory ?? appSupportDirectory("TerminalSnapshots"),
            logName: "terminal_snapshots",
            defaults: defaults)
    }

    /// Zustell-Tokens des Send-Guards (`send-tokens/`, nur Hash + Zeit, 0600).
    /// Der Guard ist seit 05.11.2026 ausgebaut, niemand liest oder räumt den
    /// Ordner mehr. Mit ihm fällt der Schalter `chatsPromptGuardEnabled` weg.
    /// Gleiche Regeln wie oben: genau einmal, off-main, Fehler geschluckt.
    ///
    /// - Parameter completion: Testnaht, läuft nach dem Löschversuch.
    static func removeObsoleteSendTokens(
        defaults: UserDefaults = .standard,
        directory: URL? = nil,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard !defaults.bool(forKey: "sendTokensPurged") else { return }
        defaults.removeObject(forKey: "chatsPromptGuardEnabled")
        removeOnce(
            flag: "sendTokensPurged",
            directory: directory ?? appSupportDirectory("send-tokens"),
            logName: "send_tokens",
            defaults: defaults,
            completion: completion)
    }

    private static func appSupportDirectory(_ name: String) -> URL {
        AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static func removeOnce(
        flag: String,
        directory target: URL,
        logName: String,
        defaults: UserDefaults,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        DispatchQueue.global(qos: .utility).async {
            defer { completion?() }
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: target.path) else { return }
            let count = (try? fileManager.contentsOfDirectory(atPath: target.path).count) ?? 0
            do {
                try fileManager.removeItem(at: target)
                Logger.agentStore.info(
                    "\(logName, privacy: .public)_purged files=\(count, privacy: .public) — Verzeichnis wird nicht mehr genutzt"
                )
            } catch {
                Logger.agentStore.warning(
                    "\(logName, privacy: .public)_purge_failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
