import Foundation

struct GitProjectStatus {
    var branch: String?
    var changedFiles: Int
    var added: Int
    var deleted: Int

    var summary: String {
        changedFiles == 0 ? "Clean" : "\(changedFiles) Dateien geändert"
    }

    /// Test-Seam: fuehrt ein Git-Kommando aus und liefert getrimmtes stdout
    /// (nil bei Fehler). Default spawnt /usr/bin/git.
    typealias Runner = @Sendable (_ arguments: [String]) -> String?

    /// Synchron und blockierend — nie direkt aus dem UI-Pfad aufrufen,
    /// dafuer gibt es `load(path:)`.
    init?(path: String, runner: Runner = Self.git) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        branch = runner(["-C", path, "branch", "--show-current"])?.nilIfEmpty
        let porcelain = runner(["-C", path, "status", "--porcelain"]) ?? ""
        changedFiles = porcelain
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count

        let diff = runner(["-C", path, "diff", "--numstat"]) ?? ""
        var addedTotal = 0
        var deletedTotal = 0
        for line in diff.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            addedTotal += Int(parts[0]) ?? 0
            deletedTotal += Int(parts[1]) ?? 0
        }
        added = addedTotal
        deleted = deletedTotal
    }

    /// Laedt den Status off-main (drei Git-Spawns koennen bei kalten/grossen
    /// Repos Sekunden dauern). Aufrufer prueft nach dem await selbst, ob das
    /// Ergebnis noch zum aktuellen Projekt gehoert.
    static func load(path: String, runner: @escaping Runner = Self.git) async -> GitProjectStatus? {
        await Task.detached(priority: .utility) {
            GitProjectStatus(path: path, runner: runner)
        }.value
    }

    @Sendable private static func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // stderr wird nie gelesen — nullDevice statt Pipe, sonst kann ein
        // voller stderr-Puffer den Prozess verklemmen.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Deadline: ein haengendes Git (Netz-Mounts, fsmonitor) darf den
        // Aufrufer nicht unbegrenzt blockieren.
        let kill = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: kill)
        // Erst stdout bis EOF drainen, DANN auf Exit warten — umgekehrt
        // deadlockt ein voller Pipe-Puffer (grosse Repos) beide Seiten.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        kill.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
