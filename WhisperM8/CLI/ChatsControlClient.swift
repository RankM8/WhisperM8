import Foundation
import Darwin

// MARK: - Control-Socket-Client (CLI-Seite)

/// Verbindet sich mit dem `AgentControlServer` der laufenden App, sendet genau
/// einen Request und liest genau eine Response. Blockierend (die CLI ist
/// ohnehin ein kurzlebiger Prozess), mit connect- und read-Timeout.
enum ChatsControlClient {
    enum ClientError: Error {
        case appUnreachable(String)
        case protocolError(String)
    }

    static let connectTimeoutSeconds = 2
    /// Muss GRÖSSER sein als das Server-Handler-Fenster (10 s in
    /// `AgentControlServer.serveConnection`), sonst gibt der Client auf, während
    /// der Server noch antwortet (GPT-Review F: Timeout-Konsistenz).
    static let readTimeoutSeconds = 12

    /// Führt einen Request aus. Wirft `appUnreachable`, wenn der Socket fehlt
    /// oder die App nicht antwortet (→ CLI-Exit 5).
    static func send(method: String, params: [String: Any]) throws -> ChatsControlResponse {
        let socketPath = try resolveSocketPath()
        let fd = try connect(to: socketPath)
        defer { close(fd) }

        let actor = ChatsControlActor(identity: .fromEnvironment())
        let request = ChatsControlRequest(actor: actor, method: method, params: .object(params))
        let line = try ChatsControlCodec.encodeLine(request)
        try writeAll(fd, line)

        guard let responseLine = readLine(fd) else {
            throw ClientError.appUnreachable("Keine Antwort von der App (Verbindung abgebrochen).")
        }
        do {
            return try ChatsControlCodec.decode(ChatsControlResponse.self, from: responseLine)
        } catch {
            throw ClientError.protocolError("Kaputte Response: \(error.localizedDescription)")
        }
    }

    /// `true`, wenn die App erreichbar ist (für den Live-Merge der Lese-Befehle).
    static func ping() -> Bool {
        (try? send(method: "ping", params: [:]))?.ok ?? false
    }

    // MARK: - Socket-Mechanik

    private static func resolveSocketPath() throws -> String {
        let discovery = ChatsControlProtocol.discoveryFileURL()
        guard let path = try? String(contentsOf: discovery, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw ClientError.appUnreachable("WhisperM8-App nicht erreichbar (control.sock fehlt). Starte die App, dann erneut versuchen.")
        }
        return path
    }

    private static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.appUnreachable("Socket konnte nicht erstellt werden (errno \(errno)).")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ClientError.appUnreachable("Socket-Pfad zu lang.")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    destPtr.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }

        // SO_NOSIGPIPE: verhindert, dass ein `write` auf einen server-seitig
        // geschlossenen Socket den CLI-Prozess per SIGPIPE killt.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Read-Timeout setzen.
        var tv = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        guard result == 0 else {
            close(fd)
            throw ClientError.appUnreachable("WhisperM8-App nicht erreichbar (Socket antwortet nicht). Läuft die App?")
        }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.baseAddress!
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n == -1 && errno == EINTR {
                    continue    // Signal unterbrach den Write — wiederholen (GPT-Review)
                } else {
                    throw ClientError.appUnreachable("Schreiben zum Socket fehlgeschlagen.")
                }
            }
        }
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while buffer.count <= ChatsControlCodec.maxLineBytes {
            let n = read(fd, &byte, 1)
            if n == -1 && errno == EINTR { continue }   // Signal — wiederholen
            if n <= 0 { return buffer.isEmpty ? nil : buffer }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
        }
        return buffer
    }
}
