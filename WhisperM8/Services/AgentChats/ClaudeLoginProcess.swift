import Foundation

/// Ergebnis eines `claude auth login`-Laufs.
struct ClaudeLoginProcessResult: Equatable {
    enum End: Equatable {
        case exited
        case cancelled
        case timedOut
        case launchFailed(String)
    }

    var end: End
    var exitCode: Int32
    /// stdout und stderr zusammen — enthält die Login-Adresse, nie Tokens.
    var output: String
}

/// Griff auf den laufenden Login: abbrechen oder den Code nachreichen, den
/// claude.ai anzeigt, wenn die Rückleitung in die CLI nicht klappt.
final class ClaudeLoginProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelHandler: (() -> Void)?
    private var codeHandler: ((String) -> Void)?
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = cancelHandler
        lock.unlock()
        handler?()
    }

    func submit(code: String) {
        lock.lock()
        let handler = codeHandler
        lock.unlock()
        handler?(code)
    }

    /// Vom Runner aufgerufen, sobald der Prozess läuft. Wurde vorher schon
    /// abgebrochen, greift der Abbruch sofort.
    func attach(cancel: @escaping () -> Void, submitCode: @escaping (String) -> Void) {
        lock.lock()
        // Der Prozess kann schon beendet sein, bevor der Runner andockt.
        guard !finished else { lock.unlock(); return }
        cancelHandler = cancel
        codeHandler = submitCode
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { cancel() }
    }

    func detach() {
        lock.lock()
        finished = true
        cancelHandler = nil
        codeHandler = nil
        lock.unlock()
    }
}

/// Seam für Tests — die echte Implementierung startet die Claude-CLI.
protocol ClaudeLoginProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environmentOverrides: [String: String],
        workingDirectory: String,
        timeout: TimeInterval,
        control: ClaudeLoginProcessControl,
        onLoginURL: @escaping @Sendable (URL) -> Void
    ) async -> ClaudeLoginProcessResult
}

/// Startet `claude auth login` ohne Terminal. Die CLI öffnet den Browser
/// selbst und wartet auf die Rückleitung an ihren lokalen Port; stdin bleibt
/// als Pipe offen, damit ein angezeigter Code nachgereicht werden kann
/// (geprüft an v2.1.322: mit geschlossenem stdin läuft der Befehl weiter und
/// wartet).
struct ClaudeLoginProcessRunner: ClaudeLoginProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environmentOverrides: [String: String],
        workingDirectory: String,
        timeout: TimeInterval,
        control: ClaudeLoginProcessControl,
        onLoginURL: @escaping @Sendable (URL) -> Void
    ) async -> ClaudeLoginProcessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ClaudeLoginProcessResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

            var environment = LoginShellEnvironment.shared.processEnvironment()
            environment["NO_COLOR"] = "1"
            environment["CLICOLOR"] = "0"
            environment.merge(environmentOverrides) { _, override in override }
            process.environment = environment

            let outputPipe = Pipe()
            let inputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.standardInput = inputPipe
            // Unsere Enden dürfen nicht in Chat-Shells landen, die während des
            // Logins starten (SwiftTerm forkt ohne Deskriptoren zu schließen).
            _ = fcntl(outputPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)

            let state = RunState()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                if let url = state.append(chunk) { onLoginURL(url) }
            }

            // Beenden mit Nachdruck: reagiert die CLI nicht auf SIGTERM, hinge
            // der Lauf sonst für immer (die Continuation wartet auf das Prozessende).
            let stop: (ClaudeLoginProcessResult.End) -> Void = { reason in
                state.markEnd(reason)
                guard process.isRunning else { return }
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGrace) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { stop(.timedOut) }

            process.terminationHandler = { finished in
                timer.cancel()
                control.detach()
                // Kurz warten, bis der Lese-Handler den Rest abgeholt hat. Ein
                // readToEnd könnte hängen, falls ein Kind der CLI die Pipe hält.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    try? inputPipe.fileHandleForWriting.close()
                    let output = state.output
                    // Ein Login, der schon erfolgreich durch war, zählt — auch
                    // wenn Abbruch oder Timeout im selben Moment kamen.
                    let succeeded = finished.terminationReason == .exit
                        && finished.terminationStatus == 0
                        && output.contains("Login successful")
                    continuation.resume(returning: ClaudeLoginProcessResult(
                        end: succeeded ? .exited : (state.end ?? .exited),
                        exitCode: finished.terminationStatus,
                        output: output
                    ))
                }
            }

            // Vor dem Start aktivieren: eine nie aktivierte Dispatch-Quelle
            // darf nicht freigegeben werden.
            timer.resume()
            do {
                try process.run()
            } catch {
                timer.cancel()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: ClaudeLoginProcessResult(
                    end: .launchFailed(error.localizedDescription),
                    exitCode: -1,
                    output: ""
                ))
                return
            }

            control.attach(
                cancel: { stop(.cancelled) },
                submitCode: { code in
                    let line = code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                    // SIGPIPE-Regel: nur das werfende write(contentsOf:).
                    try? inputPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
                }
            )
        }
    }

    /// Frist zwischen SIGTERM und SIGKILL.
    static let killGrace: TimeInterval = 3

    /// Die Adresse, die die CLI als Ausweich-Link druckt („If the browser
    /// didn't open, visit: …"). Sie ist als Terminal-Hyperlink verpackt
    /// (OSC 8), deshalb endet sie am ersten Steuerzeichen.
    static func extractLoginURL(from output: String) -> URL? {
        guard let marker = output.range(of: "visit:") else { return nil }
        let rest = output[marker.upperBound...]
        guard let start = rest.range(of: "https://") else { return nil }
        let candidate = rest[start.lowerBound...].prefix { character in
            !character.isWhitespace && character.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        }
        return URL(string: String(candidate))
    }

    /// Gesammelte Ausgabe und Abbruchgrund, von Lese-Handler, Timer und
    /// Abbruch aus verschiedenen Threads beschrieben.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        /// Rohe Bytes: ein UTF-8-Zeichen kann über zwei Lese-Blöcke verteilt ankommen.
        private var buffer = Data()
        private var reportedURL = false
        private var endReason: ClaudeLoginProcessResult.End?

        var output: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }

        var end: ClaudeLoginProcessResult.End? {
            lock.lock(); defer { lock.unlock() }
            return endReason
        }

        /// Hängt Text an; liefert die Login-Adresse genau einmal, sobald sie
        /// vollständig in der Ausgabe steht.
        func append(_ chunk: Data) -> URL? {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            guard !reportedURL else { return nil }
            let text = String(decoding: buffer, as: UTF8.self)
            // Vollständig ist sie erst, wenn danach noch etwas folgt.
            guard text.contains("Paste code"),
                  let url = ClaudeLoginProcessRunner.extractLoginURL(from: text) else { return nil }
            reportedURL = true
            return url
        }

        /// Der erste Grund gewinnt (Abbruch vor Timeout oder umgekehrt).
        func markEnd(_ reason: ClaudeLoginProcessResult.End) {
            lock.lock(); defer { lock.unlock() }
            if endReason == nil { endReason = reason }
        }
    }
}
