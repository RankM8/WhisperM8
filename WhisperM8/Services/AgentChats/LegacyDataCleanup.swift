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
        let flag = "terminalSnapshotsPurged"
        guard !defaults.bool(forKey: flag) else { return }

        let target = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("TerminalSnapshots", isDirectory: true)

        defaults.set(true, forKey: flag)
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: target.path) else { return }
            let count = (try? fileManager.contentsOfDirectory(atPath: target.path).count) ?? 0
            do {
                try fileManager.removeItem(at: target)
                Logger.agentStore.info(
                    "terminal_snapshots_purged files=\(count, privacy: .public) — Verzeichnis wird nicht mehr genutzt"
                )
            } catch {
                Logger.agentStore.warning(
                    "terminal_snapshots_purge_failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
