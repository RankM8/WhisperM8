import Foundation

struct GitProjectStatus {
    var branch: String?
    var changedFiles: Int
    var added: Int
    var deleted: Int

    var summary: String {
        changedFiles == 0 ? "Clean" : "\(changedFiles) Dateien geändert"
    }

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        branch = Self.git(["-C", path, "branch", "--show-current"])?.nilIfEmpty
        let porcelain = Self.git(["-C", path, "status", "--porcelain"]) ?? ""
        changedFiles = porcelain
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count

        let diff = Self.git(["-C", path, "diff", "--numstat"]) ?? ""
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

    private static func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
