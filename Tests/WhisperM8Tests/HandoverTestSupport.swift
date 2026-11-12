import Darwin
import Foundation
import XCTest
@testable import WhisperM8

// MARK: - /bin/sh-Kind über forkpty

/// Ein Kind wie ein Chat der App: `forkpty`, Shell als Sitzungsleiter mit dem
/// Slave als steuerndem Terminal. Schließt der letzte Halter den Master,
/// bekommt es SIGHUP. Das Skript protokolliert HUP und INT in `markerURL`.
final class HandoverPTYChild {
    let pid: pid_t
    /// Kopie des Testprozesses; nach der Abgabe schließen, sonst kein SIGHUP.
    var master: Int32
    let markerURL: URL
    private var reaped: Int32?

    /// Zählt im Takt von `interval` Sekunden `tick N`-Zeilen.
    static func ticking(interval: String = "0.05", in directory: URL, name: String = UUID().uuidString) throws -> HandoverPTYChild {
        try spawn(script: """
        trap 'echo HUP >> "$MARKER"; exit 129' HUP
        trap 'echo INT >> "$MARKER"' INT
        : > "$READY"
        i=0
        while [ $i -lt 100000 ]; do i=$((i+1)); echo "tick $i"; sleep \(interval); done
        """, in: directory, name: name)
    }

    /// Wartet, bis das Skript `$READY` angelegt hat (sofern es das tut): Ein
    /// Ctrl+C vor den `trap`-Zeilen beendete die Shell sonst sofort.
    static func spawn(script: String, in directory: URL, name: String = UUID().uuidString, cols: UInt16 = 80, rows: UInt16 = 24) throws -> HandoverPTYChild {
        let marker = directory.appendingPathComponent("marker-\(name)")
        let ready = directory.appendingPathComponent("ready-\(name)")
        FileManager.default.createFile(atPath: marker.path, contents: nil)

        // Alles vor fork vorbereiten: im Kind nur execve/_exit.
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(script), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/bin:/usr/bin"), strdup("MARKER=\(marker.path)"), strdup("READY=\(ready.path)"), strdup("LANG=C"), nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var master: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            argv.withUnsafeBufferPointer { a in
                envp.withUnsafeBufferPointer { e in
                    _ = execve("/bin/sh", a.baseAddress, e.baseAddress)
                }
            }
            _exit(127)
        }
        guard pid > 0 else { throw HandoverWireError.io(errno) }
        // Andere Kinder dürfen diesen Master nie erben (Paket 0 behebt das in SwiftTerm).
        HandoverSocket.setCloseOnExec(master)
        if script.contains("$READY") {
            _ = HandoverTestSupport.waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: ready.path) }
        }
        return HandoverPTYChild(pid: pid, master: master, markerURL: marker)
    }

    private init(pid: pid_t, master: Int32, markerURL: URL) {
        self.pid = pid
        self.master = master
        self.markerURL = markerURL
    }

    var marker: String { (try? String(contentsOf: markerURL, encoding: .utf8)) ?? "" }

    func closeMaster() {
        if master >= 0 { close(master); master = -1 }
    }

    /// Wartet auf das Ende (eigenes Kind, deshalb waitpid). `nil` = läuft noch.
    @discardableResult
    func waitForExit(timeout: TimeInterval) -> Int32? {
        if let reaped { return reaped }
        let end = Date().addingTimeInterval(timeout)
        repeat {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = status
                return status
            }
            usleep(10_000)
        } while Date() < end
        return nil
    }

    var isAlive: Bool { reaped == nil && waitForExit(timeout: 0) == nil }

    /// Aufräumen: erst den eigenen Master schließen, dann töten. Hält der
    /// Test den Master, liest aber nicht, wartet macOS beim Prozessende, bis
    /// die Terminal-Ausgabe abgeflossen ist (mehrere Sekunden).
    func kill(_ signal: Int32 = SIGKILL) {
        closeMaster()
        if isAlive { Darwin.kill(pid, signal) }
        waitForExit(timeout: 5)
    }

    func manifest(chatID: String = UUID().uuidString, kind: String = "claude", interrupt: Bool = true) -> HandoverManifest {
        var manifest = HandoverManifest(
            chatID: chatID,
            kind: kind,
            pid: pid,
            pidStartTime: ProcessStartTime.of(pid: pid)?.timeIntervalSince1970,
            cols: 80,
            rows: 24,
            sendsInterruptOnStop: interrupt
        )
        manifest.scrollback = 5_000
        return manifest
    }
}

// MARK: - App-Double

/// Spielt die App: hält eine Leitung, liest sie in ein Terminal ohne Fenster
/// und sichert daraus das Bild — wie es Paket 4 tun wird.
final class HandoverAppDouble {
    let screen: HandoverHeadlessTerminal
    var fd: Int32

    init(fd: Int32, image: [UInt8], scrollback: Int = 5_000) {
        self.fd = fd
        let writeFD = fd
        screen = HandoverHeadlessTerminal(cols: 80, rows: 24, scrollback: scrollback, colors: nil) { bytes in
            _ = KeptChat.writeWithoutWaiting(fd: writeFD, bytes)
        }
        screen.feed(image)
    }

    /// Liest `duration` Sekunden lang, was der Chat schreibt.
    func read(for duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while Date() < end {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 20)
            guard ready > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { return }
            screen.feed(buffer[0..<count])
        }
    }

    var image: [UInt8] { HandoverPlainTextSerializer().serialize(screen.terminal) }

    var text: String { String(decoding: screen.terminal.getBufferAsData(), as: UTF8.self) }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

// MARK: - Hilfen

enum HandoverTestSupport {
    /// Kurzer eigener Ordner (Socket-Pfade sind auf 104 Byte begrenzt).
    static func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("wm8-hk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Fortlaufende `tick N`-Nummern im Text.
    static func ticks(in text: String) -> [Int] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0] == "tick" else { return nil }
            return Int(parts[1])
        }
    }

    /// Lückenlos und ohne Dopplung?
    static func isContinuous(_ ticks: [Int]) -> Bool {
        guard let first = ticks.first else { return false }
        return ticks == Array(first..<(first + ticks.count))
    }

    /// Das gebaute Binary neben dem Test-Bundle (`swift build --build-tests`
    /// legt es dort ab).
    static func keeperBinary() throws -> URL {
        let url = Bundle(for: HandoverAppDouble.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("WhisperM8")
        // `swift test` linkt das Binary mit; fehlt es, ist das ein Fehler, kein
        // Grund, die Pflichttests still zu überspringen.
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw HandoverWireError.unexpected("WhisperM8-Binary fehlt neben dem Test-Bundle: \(url.path)")
        }
        return url
    }

    static var ownExecutablePath: String {
        HandoverPeer.executablePath(of: getpid()) ?? ""
    }

    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(10_000)
        } while Date() < end
        return condition()
    }

    static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !process.isRunning }
    }
}
