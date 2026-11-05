import Foundation
import os

// Entpacken der von Codex komprimierten Protokolle (`rollout-*.jsonl.zst`).
//
// macOS bringt kein zstd mit, und das `Compression`-Framework kann es nicht.
// Eine eigene Implementierung wäre zu groß; deshalb läuft `zstd -dc` als
// Subprozess, wenn es installiert ist (meist über Homebrew). Fehlt es,
// überspringt der Leser die Dateien und vermerkt ihre Anzahl im letzten Lauf.

/// Streamt den entpackten Inhalt einer Datei in Stücken.
protocol StatisticsDecompressing {
    /// `false` bei Fehler, Zeitlimit oder Abbruch — dann zählt der Leser nichts
    /// aus dieser Datei und versucht es beim nächsten Lauf erneut.
    func decompress(path: String, shouldStop: () -> Bool, _ chunk: (UnsafeRawBufferPointer) -> Void) -> Bool
}

/// `zstd -dc` als Subprozess: Login-Umgebung, stdout gestreamt in 1-MB-Stücken,
/// stderr ins Nichts, Abbruch nach `timeout` oder auf Wunsch des Lesers.
struct StatisticsZstdDecompressor: StatisticsDecompressing {
    let executable: String
    var timeout: TimeInterval = 120

    private static let logger = os.Logger(subsystem: "com.whisperm8.app", category: "statistics")

    /// Sucht `zstd` (PATH der Login-Shell, Homebrew). `nil`, wenn es fehlt.
    static func live() -> StatisticsZstdDecompressor? {
        guard let path = AgentCommandBuilder.commandPath("zstd") else { return nil }
        return StatisticsZstdDecompressor(executable: path)
    }

    func decompress(path: String, shouldStop: () -> Bool, _ chunk: (UnsafeRawBufferPointer) -> Void) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-d", "-c", "-q", "--no-progress", "--", path]
        process.environment = LoginShellEnvironment.shared.processEnvironment()
        let output = Pipe()
        // Unsere Enden nicht an fremde Kindprozesse (Chat-Shells) vererben.
        for fd in [output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor] {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .background
        do {
            try process.run()
        } catch {
            Self.logger.error("statistics_zstd_start_failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let kill = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: kill)

        let size = StatisticsLogFileReader.chunkSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        let fd = output.fileHandleForReading.fileDescriptor
        var stopped = false
        var readFailed = false
        while true {
            let got = read(fd, buffer, size)
            if got == 0 { break }
            if got < 0 {
                if errno == EINTR { continue }
                readFailed = true
                break
            }
            chunk(UnsafeRawBufferPointer(start: buffer, count: got))
            if shouldStop() {
                stopped = true
                if process.isRunning { process.terminate() }
                break
            }
        }
        // Rest abräumen, damit zstd nicht an einer vollen Pipe hängt.
        if stopped || readFailed {
            while read(fd, buffer, size) > 0 {}
        }
        process.waitUntilExit()
        kill.cancel()
        let ok = !stopped && !readFailed && !timedOut.withLock({ $0 }) && process.terminationStatus == 0
        if !ok, !stopped {
            Self.logger.info("statistics_zstd_failed status=\(process.terminationStatus, privacy: .public)")
        }
        return ok
    }
}
