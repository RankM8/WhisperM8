import Foundation

// MARK: - Linear: ein GraphQL-Aufruf

/// Schickt genau eine Anfrage an Linears GraphQL-Schnittstelle und übersetzt
/// Fehler in `TicketSourceError`. Schlüssel und Transport kommen als Closures,
/// damit Tests ohne Netz und ohne Schlüsselbund laufen. Der Schlüssel wird nie
/// geloggt und steht in keiner Fehlermeldung.
struct LinearGraphQLClient {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    var apiKey: () -> String?
    /// Liefert Antwortdaten und HTTP-Status.
    var transport: (URLRequest) async throws -> (Data, Int)
    /// Linear hat den Key abgelehnt: gemerkten Key verwerfen, damit ein
    /// ersetzter Key ohne Neustart gilt.
    var keyRejected: () -> Void = {}

    /// Zugang eines Workspaces: Jeder hat seinen eigenen Key.
    static func live(workspace: String) -> LinearGraphQLClient {
        LinearGraphQLClient(
            apiKey: { TicketCredentialCache.shared.value(for: workspace) { TicketCredentialStore.live.read(workspace) } },
            transport: liveTransport,
            keyRejected: { TicketCredentialCache.shared.invalidate(workspace) }
        )
    }

    /// Mit einem Key, der noch nicht gespeichert ist (Prüfung bei der Einrichtung).
    static func live(key: String) -> LinearGraphQLClient {
        LinearGraphQLClient(apiKey: { key }, transport: liveTransport)
    }

    static let liveTransport: (URLRequest) async throws -> (Data, Int) = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Führt die Anfrage aus und liefert das Feld `data`.
    func run(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard let key = apiKey(), !key.isEmpty else { throw TicketSourceError.notConfigured }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        // Persönliche Keys ohne „Bearer“.
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport(request)
        } catch let error as TicketSourceError {
            throw error
        } catch {
            // Abgebrochen (Ansicht geschlossen) ist kein Netzfehler.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw TicketSourceError.network((error as? URLError)?.code.rawValue.description ?? "Netzfehler")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 401 || status == 403 { throw TicketSourceError.unauthorized }
            throw TicketSourceError.invalidResponse("HTTP \(status)")
        }
        if let errors = object["errors"] as? [[String: Any]], let first = errors.first {
            let error = Self.error(from: first, status: status)
            if error == .unauthorized { keyRejected() }
            throw error
        }
        guard let payload = object["data"] as? [String: Any] else {
            if status == 401 || status == 403 { throw TicketSourceError.unauthorized }
            throw TicketSourceError.invalidResponse("ohne Daten, HTTP \(status)")
        }
        return payload
    }

    static func error(from entry: [String: Any], status: Int) -> TicketSourceError {
        let message = entry["message"] as? String ?? "unbekannt"
        let extensions = entry["extensions"] as? [String: Any] ?? [:]
        let code = extensions["code"] as? String ?? ""
        if code == "AUTHENTICATION_ERROR" || status == 401 { return .unauthorized }
        if code == "RATELIMITED" || status == 429 { return .rateLimited }
        if message.hasPrefix("Entity not found") {
            return .notFound(message.replacingOccurrences(of: "Entity not found: ", with: ""))
        }
        let shown = extensions["userPresentableMessage"] as? String ?? message
        return .rejected(String(shown.prefix(300)))
    }
}

// MARK: - Zugang im Schlüsselbund

/// Merkt sich die Keys für die Dauer des Prozesses, je Workspace einen. Ohne
/// das startete jeder GraphQL-Aufruf einen `security`-Prozess, in der App alle
/// 30 Sekunden.
final class TicketCredentialCache: @unchecked Sendable {
    static let shared = TicketCredentialCache()

    private let lock = NSLock()
    private var cached: [String: String] = [:]

    func value(for workspace: String, _ read: () -> String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = cached[workspace] { return known }
        // Ein fehlender Key wird nicht gemerkt: Er kann gleich eingerichtet werden.
        let fresh = read()
        cached[workspace] = fresh
        return fresh
    }

    func invalidate(_ workspace: String) {
        lock.lock()
        cached[workspace] = nil
        lock.unlock()
    }
}

/// Der Linear-Key liegt im Login-Schlüsselbund und wird über `/usr/bin/security`
/// gelesen und geschrieben, so wie Claude Code es mit seinem Login macht.
/// Grund: Ein Eintrag, den die App über die Schlüsselbund-API anlegt, ist an
/// die Signatur des Builds gebunden. Ohne Entwicklerkonto gilt jeder neue
/// Build als fremde App, und der Eintrag wäre nach jedem `make dev` gesperrt.
/// Einträge, die `security` anlegt, liest `security` ohne Rückfrage, egal aus
/// welchem Build und aus welchem Claude-Konto.
///
/// Je Workspace ein Eintrag: derselbe Dienst, das Konto ist das Kürzel des
/// Workspaces. So kann ein Aufruf für die eine Firma nie mit dem Key der
/// anderen laufen.
///
/// Die Test-Instanz hat einen eigenen Dienstnamen. `security` läuft hier mit
/// dem echten Home (sonst fände es den Login-Schlüsselbund nicht); ohne
/// eigenen Namen läse, überschriebe und löschte ein Befehl der Test-Instanz
/// den echten Key und schriebe ins echte Ticket-System.
struct TicketCredentialStore {
    static var service: String { service(isTestInstance: AppInstance.isTestInstance) }

    static func service(isTestInstance: Bool) -> String {
        isTestInstance ? "whisperm8-linear-api-key.test" : "whisperm8-linear-api-key"
    }

    var read: (_ workspace: String) -> String?
    /// `false`, wenn der Eintrag danach nicht lesbar ist.
    var write: (_ workspace: String, _ key: String) -> Bool
    var delete: (_ workspace: String) -> Void

    static let live = TicketCredentialStore(
        read: { workspace in
            guard TicketConfig.isWorkspaceName(workspace) else { return nil }
            let result = SecurityTool.run(["find-generic-password", "-a", workspace, "-s", service, "-w"])
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.exitCode == 0 && !value.isEmpty ? value : nil
        },
        write: { workspace, key in
            guard isStorable(key), TicketConfig.isWorkspaceName(workspace) else { return false }
            // Über stdin, nie als Argument: Argumente stehen in der Prozessliste.
            let command = "add-generic-password -U -a \"\(workspace)\" -s \"\(service)\" -l \"WhisperM8 Linear API-Key \(workspace)\" -w \"\(key)\"\n"
            _ = SecurityTool.run(["-i"], stdin: command)
            TicketCredentialCache.shared.invalidate(workspace)
            let check = SecurityTool.run(["find-generic-password", "-a", workspace, "-s", service, "-w"])
            return check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == key
        },
        delete: { workspace in
            guard TicketConfig.isWorkspaceName(workspace) else { return }
            _ = SecurityTool.run(["delete-generic-password", "-a", workspace, "-s", service])
            TicketCredentialCache.shared.invalidate(workspace)
        }
    )

    /// Der Key wandert in eine Befehlszeile von `security -i`; Zeichen, die
    /// dort die Zeile sprengen würden, kommen in Linear-Keys nicht vor.
    static func isStorable(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 512 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// Minimaler Aufruf von `/usr/bin/security`. Absoluter Pfad und eigene, knappe
/// Umgebung: Es wird nichts aus der Umgebung des Aufrufers vererbt.
///
/// Blockiert bis zum Ende des Kindprozesses, höchstens `timeout` lang. Nie auf
/// dem Main Thread aufrufen.
enum SecurityTool {
    struct Result { var exitCode: Int32; var stdout: String }

    /// Der Kindprozess lief länger als erlaubt und wurde beendet.
    static let timedOut: Int32 = -2

    static func run(_ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 10,
                    executable: String = "/usr/bin/security",
                    beforeStart: ((_ output: Pipe, _ input: Pipe) -> Void)? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        // Die Enden in diesem Prozess dürfen nicht an gleichzeitig startende
        // Chats vererbt werden (SwiftTerm schließt beim Start nichts). Das Kind
        // bekommt seine Kopien trotzdem, sie werden auf 0 und 1 dupliziert.
        //
        // macOS kann eine Pipe nicht in einem Zug mit close-on-exec anlegen.
        // Zwischen `Pipe()` und `fcntl` bleibt ein Fenster von Mikrosekunden,
        // in dem ein startender Chat die Enden erbt. Deshalb hängt unten nichts
        // am Ende der Pipe: Gewartet wird auf den Prozess, mit Frist.
        for handle in [output.fileHandleForReading, output.fileHandleForWriting,
                       input.fileHandleForReading, input.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // Tests stellen hier einen fremden Halter der Pipe-Enden nach.
        beforeStart?(output, input)
        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, stdout: "")
        }
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        // Hält ein fremder Prozess das Schreib-Ende der Eingabe, sieht das Kind
        // nie deren Ende und liefe ewig. Nach der Frist wird es beendet.
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return Result(exitCode: timedOut, stdout: "")
        }
        // Erst nach dem Ende lesen und nicht auf das Ende der Pipe warten: Hält
        // ein fremder Prozess das Schreib-Ende der Ausgabe, käme es nie. Die
        // Ausgabe ist eine Zeile und liegt vollständig im Puffer der Pipe.
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return Result(exitCode: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}
