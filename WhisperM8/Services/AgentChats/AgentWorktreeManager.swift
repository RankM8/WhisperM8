import Darwin
import Foundation

/// Legt Git-Worktrees für Subagent-Jobs an und räumt sie wieder ab.
/// Opt-in (beschlossen): nur bei `--worktree`; Default ist In-place im Repo.
/// Branch-Konvention: `subagent/<short-id>`, Worktree-Pfad im Job-Verzeichnis.
struct AgentWorktreeManager {
    enum WorktreeError: LocalizedError, Equatable {
        case notARepo(String)
        case gitFailed(String)
        case dirty(String)

        var errorDescription: String? {
            switch self {
            case .notARepo(let path):
                return "\(path) ist kein Git-Repository — --worktree braucht eines."
            case .gitFailed(let message):
                return "git worktree fehlgeschlagen: \(message)"
            case .dirty(let path):
                return "Worktree \(path) hat uncommittete Änderungen — bitte erst sichern oder verwerfen."
            }
        }
    }

    struct GitResult: Equatable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Test-Seam — Default führt /usr/bin/git aus (Muster: GitProjectStatus).
    var gitRunner: ([String]) -> GitResult

    init(gitRunner: (([String]) -> GitResult)? = nil) {
        self.gitRunner = gitRunner ?? Self.runGit
    }

    // MARK: - API

    /// `git -C <repo> worktree add <destination> -b subagent/<shortId>`
    func createWorktree(repoPath: String, shortId: String, at destination: URL) throws -> AgentJobState.Worktree {
        let inside = gitRunner(["-C", repoPath, "rev-parse", "--is-inside-work-tree"])
        guard inside.exitCode == 0, inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw WorktreeError.notARepo(repoPath)
        }
        let branch = "subagent/\(shortId)"
        let result = gitRunner(["-C", repoPath, "worktree", "add", destination.path, "-b", branch])
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return AgentJobState.Worktree(path: destination.path, branch: branch)
    }

    func isClean(worktreePath: String) -> Bool {
        let result = gitRunner(["-C", worktreePath, "status", "--porcelain"])
        guard result.exitCode == 0 else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Entfernt den Worktree — verweigert bei uncommitteten Änderungen
    /// (beschlossen: `agent rm` warnt dann mit Exit 4, Job-Dir bleibt).
    func removeWorktree(repoPath: String, worktreePath: String) throws {
        guard isClean(worktreePath: worktreePath) else {
            throw WorktreeError.dirty(worktreePath)
        }
        let result = gitRunner(["-C", repoPath, "worktree", "remove", worktreePath])
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Default-Runner

    private static func runGit(_ arguments: [String]) -> GitResult {
        runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments
        )
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 10
    ) -> GitResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-git-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        guard let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return GitResult(exitCode: -1, stdout: "", stderr: "Temporäre Fehlerausgabe konnte nicht angelegt werden.")
        }
        process.standardError = stderrHandle
        defer {
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stderrURL)
        }

        do {
            try process.run()
        } catch {
            return GitResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let timeoutTask = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutTask)

        // stdout vor dem Exit-Wait vollständig leeren; stderr liegt in einer
        // Datei und kann den Kindprozess deshalb ebenfalls nie blockieren.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()
        try? stderrHandle.synchronize()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()

        return GitResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
