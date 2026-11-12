import Darwin
import Foundation

// MARK: - Aufbewahrer

/// Hält die PTY-Leitungen laufender Chats, während die App neu startet
/// (Paket 2 aus docs/plans/neustart-ohne-chatverlust.md).
///
/// Ablauf: Die alte App gibt je Chat Manifest, Bild und Leitung ab (`DEPOSIT`,
/// je Chat `ACK`) und bestätigt mit `COMMIT`. Der Aufbewahrer liest jede
/// Leitung in ein Terminal ohne Fenster weiter und beantwortet die Rückfragen
/// der TUIs. Die neue App holt die Chats einzeln zurück (`TAKE` → `CHAT` +
/// Leitung + Bild → `ACK`), danach beendet sich der Aufbewahrer.
///
/// Enden:
/// - alle übernommen (`DONE`) → sofort;
/// - Abgabe abgebrochen oder nie bestätigt → Kopien still schließen (die alte
///   App beendet sich auf dem heutigen Weg);
/// - Frist (Entscheidung 2: höchstens 10 min), `RELEASE`, SIGTERM → geordnet
///   wie heute: zweimal Ctrl+C an TUIs, Leitungen schließen. Die App setzt die
///   Chats danach per `--resume` fort.
///
/// Thread-Modell: aller Zustand auf `queue`; jede Verbindung blockierend auf
/// einem eigenen Thread, der für Zustandsänderungen `queue.sync` nutzt.
final class HandoverKeeper: @unchecked Sendable {
    struct Configuration {
        var paths: HandoverPaths
        var runID: String
        /// Entscheidung 2: höchstens 10 Minuten halten.
        var holdSeconds: TimeInterval = 600
        /// Frist für die Abgabe ab Start (bis `COMMIT`).
        var depositSeconds: TimeInterval = 30
        /// Frist je Telegramm innerhalb einer Verbindung.
        var ioTimeout: TimeInterval = 10
        /// Frist für das `ACK` nach einer übergebenen Leitung.
        var ackTimeout: TimeInterval = 10
        var peerPolicy: HandoverPeerPolicy
        var serializer: HandoverScreenSerializing = HandoverPlainTextSerializer()
        /// Wie `AgentTerminalRegistry.captureAllSnapshotsForAppQuit`: Ctrl+C,
        /// 80 ms, Ctrl+C, 180 ms.
        var interruptPauses: (first: useconds_t, second: useconds_t) = (80_000, 180_000)
        /// Schreibt zusätzlich in `keeper.log` (aus in Tests ohne Platte).
        var logToFile = true
    }

    enum Phase: String {
        case starting, awaitingDeposit, holding, finished
    }

    enum FinishReason: String {
        /// Alle Chats übernommen.
        case allTaken
        /// Alte App hat `ABORT` geschickt.
        case aborted
        /// Abgabe-Verbindung vor `COMMIT` verloren.
        case depositLost
        /// Keine vollständige Abgabe innerhalb der Frist.
        case depositTimeout
        /// Haltefrist abgelaufen, geordnet beendet.
        case holdExpired
        /// Neue App hat `RELEASE` geschickt.
        case released
        /// `DONE`, obwohl noch Chats da waren: der Rest wurde geordnet beendet.
        case doneWithRemaining
        /// SIGTERM/SIGINT.
        case terminated
    }

    enum StartError: Error, Equatable {
        case busy
        case directory
        case socketPath
        case bind(Int32)
    }

    let configuration: Configuration
    let queue = DispatchQueue(label: "com.whisperm8.handover-keeper", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(
        label: "com.whisperm8.handover-keeper.conn", qos: .userInitiated, attributes: .concurrent)
    private let connectionSlots = DispatchSemaphore(value: 4)

    private(set) var phase: Phase = .starting
    private(set) var finishReason: FinishReason?
    let startedAt = Date()
    private(set) var deadline: Date?

    var chats: [String: KeptChat] = [:]
    /// Reihenfolge der Abgabe, damit LIST und STATUS stabil sind.
    var chatOrder: [String] = []
    var depositConnectionActive = false
    var takeConnectionActive = false

    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var boundSocket: (url: URL, device: dev_t, inode: ino_t)?
    private var timer: DispatchSourceTimer?
    private var exitWatcher: HandoverExitWatcher?
    private var activeConnections: Set<Int32> = []
    private let fileLog: LoggerFileSink?
    private var onFinish: ((FinishReason) -> Void)?

    init(configuration: Configuration) {
        self.configuration = configuration
        fileLog = configuration.logToFile
            ? LoggerFileSink(url: configuration.paths.logFileURL, maxBytes: 1_048_576)
            : nil
    }

    // MARK: Start

    /// Lock, Socket, Abgabefrist. `onFinish` läuft genau einmal, nachdem alle
    /// Leitungen geschlossen und Socket und Lock freigegeben sind.
    func start(onFinish: @escaping (FinishReason) -> Void) throws {
        try queue.sync {
            self.onFinish = onFinish
            try openLockAndSocket()
            exitWatcher = HandoverExitWatcher(queue: queue) { [weak self] pid, status in
                self?.processExited(pid: pid, status: status)
            }
            phase = .awaitingDeposit
            arm(deadline: Date().addingTimeInterval(configuration.depositSeconds)) { [weak self] in
                self?.depositDeadlineReached()
            }
            armAccept()
            log("keeper_started run=\(configuration.runID) pid=\(getpid()) socket=\(boundSocket?.url.path ?? "-")")
        }
    }

    private func openLockAndSocket() throws {
        let paths = configuration.paths
        try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        guard AgentControlServer.prepareOwnedDirectory(at: paths.directory) else { throw StartError.directory }

        // Höchstens ein Aufbewahrer je Instanz-Wurzel. O_CLOEXEC wie beim
        // Control-Server, auch wenn der Aufbewahrer selbst nichts startet.
        lockFD = open(paths.lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw StartError.directory }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            lockFD = -1
            throw StartError.busy
        }

        let url = paths.socketURL
        if url != paths.preferredSocketURL {
            guard AgentControlServer.prepareOwnedDirectory(at: url.deletingLastPathComponent()) else {
                releaseLock()
                throw StartError.directory
            }
        }
        guard ChatsControlProtocol.socketPathFits(url), var addr = HandoverSocket.makeAddress(url.path) else {
            releaseLock()
            throw StartError.socketPath
        }
        // Wir halten den Lock: ein vorhandener Socket stammt von einem toten
        // Vorgänger. Nur einen eigenen Socket entfernen, nie etwas anderes.
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == getuid() else {
                releaseLock()
                throw StartError.socketPath
            }
            unlink(url.path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { releaseLock(); throw StartError.bind(errno) }
        HandoverSocket.setCloseOnExec(fd)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            releaseLock()
            throw StartError.bind(code)
        }
        chmod(url.path, 0o600)
        var st = stat()
        if stat(url.path, &st) == 0 { boundSocket = (url, st.st_dev, st.st_ino) }
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            releaseLock()
            throw StartError.bind(code)
        }
        listenFD = fd
        try? (url.path + "\n").write(to: paths.discoveryFileURL, atomically: true, encoding: .utf8)
    }

    private func releaseLock() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    // MARK: Verbindungen annehmen

    private func armAccept() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        let fd = listenFD
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        HandoverSocket.setCloseOnExec(clientFD)
        guard let peer = HandoverPeer.of(socket: clientFD), peer.uid == getuid() else {
            log("peer_rejected reason=uid")
            close(clientFD)
            return
        }
        guard phase != .finished, connectionSlots.wait(timeout: .now()) == .success else {
            close(clientFD)
            return
        }
        let trusted = configuration.peerPolicy.isAllowed(executablePath: peer.executablePath)
        activeConnections.insert(clientFD)
        connectionQueue.async { [weak self] in
            defer { self?.connectionSlots.signal() }
            guard let self else { close(clientFD); return }
            let connection = HandoverConnection(fd: clientFD)
            self.serve(connection, peer: peer, trusted: trusted)
            self.queue.sync { _ = self.activeConnections.remove(clientFD) }
            connection.close()
        }
    }

    // MARK: Chats

    /// Nimmt eine abgegebene Leitung an. Auf `queue`.
    func addChat(manifest: HandoverManifest, descriptor: Int32, image: [UInt8]) -> String? {
        guard phase == .awaitingDeposit else { return "Abgabe ist abgeschlossen" }
        guard chats[manifest.chatID] == nil else { return "Chat \(manifest.chatID) wurde schon abgegeben" }
        guard manifest.pid > 0 else { return "ungültige PID" }
        if let expected = manifest.pidStartTime {
            // Wiederverwendete PID: nie einen fremden Prozess aufbewahren.
            guard let actual = ProcessStartTime.of(pid: manifest.pid),
                  abs(actual.timeIntervalSince1970 - expected) < 1 else {
                return "PID \(manifest.pid) passt nicht zur Startzeit"
            }
        }
        let chat = KeptChat(manifest: manifest, descriptor: descriptor, queue: queue)
        chat.screen.feed(image)
        chats[manifest.chatID] = chat
        chatOrder.append(manifest.chatID)
        if exitWatcher?.watch(pid: manifest.pid) == false {
            // Schon beendet, bevor die Überwachung stand.
            chat.markExited(status: nil)
        }
        chat.startReading()
        log("deposited chat=\(manifest.chatID) kind=\(manifest.kind) pid=\(manifest.pid) image=\(image.count)")
        return nil
    }

    private func processExited(pid: pid_t, status: Int32?) {
        for chat in chats.values where chat.manifest.pid == pid && !chat.exited {
            chat.pump()
            chat.markExited(status: status)
            log("chat_exited chat=\(chat.manifest.chatID) status=\(status.map(String.init) ?? "?")")
        }
    }

    func summaries() -> [HandoverChatSummary] {
        chatOrder.compactMap { chats[$0] }.map {
            HandoverChatSummary(manifest: $0.manifest, exited: $0.exited, exitStatus: $0.exitStatus, gapBytes: $0.gapBytes)
        }
    }

    func status() -> HandoverKeeperStatus {
        HandoverKeeperStatus(
            runID: configuration.runID,
            pid: getpid(),
            phase: phase.rawValue,
            protocolRange: [HandoverProtocol.supported.lowerBound, HandoverProtocol.supported.upperBound],
            build: HandoverProtocol.buildIdentifier,
            startedAt: startedAt.timeIntervalSince1970,
            deadline: deadline?.timeIntervalSince1970,
            chats: chatOrder.compactMap { chats[$0] }.map {
                .init(chatID: $0.manifest.chatID, kind: $0.manifest.kind, pid: $0.manifest.pid,
                      exited: $0.exited, exitStatus: $0.exitStatus, gapBytes: $0.gapBytes,
                      inTransfer: $0.inTransfer)
            }
        )
    }

    // MARK: Phasen und Fristen

    func commit() {
        guard phase == .awaitingDeposit else { return }
        phase = .holding
        log("committed chats=\(chats.count)")
        if chats.isEmpty {
            finish(.allTaken)
            return
        }
        arm(deadline: Date().addingTimeInterval(configuration.holdSeconds)) { [weak self] in
            self?.holdDeadlineReached()
        }
    }

    private func arm(deadline: Date, handler: @escaping () -> Void) {
        timer?.cancel()
        self.deadline = deadline
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
        timer.setEventHandler(handler: handler)
        timer.resume()
        self.timer = timer
    }

    private func depositDeadlineReached() {
        guard phase == .awaitingDeposit else { return }
        log("deposit_deadline_reached chats=\(chats.count)")
        releaseSilently()
        finish(.depositTimeout)
    }

    private func holdDeadlineReached() {
        guard phase == .holding else { return }
        // Nie mitten in einer Übergabe enden: die App hält die Leitung, das
        // ACK fehlt noch (harte Regel). Kurz danach erneut prüfen.
        if chats.values.contains(where: \.inTransfer) {
            arm(deadline: Date().addingTimeInterval(1)) { [weak self] in self?.holdDeadlineReached() }
            return
        }
        log("hold_deadline_reached chats=\(chats.count)")
        shutDownOrderly(reason: .holdExpired)
    }

    /// SIGTERM/SIGINT: wie Fristende.
    func terminate() {
        queue.async { [weak self] in
            guard let self, self.phase != .finished else { return }
            if self.phase == .awaitingDeposit {
                // Die alte App hält ihre Leitungen noch und beendet sich selbst.
                self.releaseSilently()
            } else {
                self.stopReadingAll()
                self.sendInterrupts(to: Array(self.chats.values))
            }
            self.finish(.terminated)
        }
    }

    // MARK: Beenden

    /// Abbruch der Abgabe: Kopien schließen, kein Signal. Die alte App hält
    /// die Originale und beendet sich auf dem heutigen Weg.
    func releaseSilently() {
        for chat in chats.values { chat.closeDescriptor() }
        chats.removeAll()
        chatOrder.removeAll()
    }

    /// Geordnet wie heute: zweimal Ctrl+C an TUIs, dann Leitungen schließen —
    /// die Chats bekommen SIGHUP und enden. Fortgesetzt wird per `--resume`.
    func shutDownOrderly(reason: FinishReason) {
        stopReadingAll()
        sendInterrupts(to: Array(chats.values))
        finish(reason)
    }

    private func stopReadingAll() {
        for chat in chats.values { chat.stopReading() }
    }

    private func sendInterrupts(to list: [KeptChat]) {
        let targets = list.filter { !$0.exited && $0.manifest.sendsInterruptOnStop }
        guard !targets.isEmpty else { return }
        for chat in targets { chat.write([0x03]) }
        usleep(configuration.interruptPauses.first)
        for chat in targets { chat.write([0x03]) }
        usleep(configuration.interruptPauses.second)
    }

    /// Schließt alles und meldet das Ende. Auf `queue`, idempotent.
    func finish(_ reason: FinishReason) {
        guard phase != .finished else { return }
        phase = .finished
        finishReason = reason
        timer?.cancel()
        timer = nil
        for chat in chats.values { chat.closeDescriptor() }
        chats.removeAll()
        chatOrder.removeAll()
        exitWatcher?.cancel()
        exitWatcher = nil
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        for fd in activeConnections { shutdown(fd, SHUT_RDWR) }
        if let bound = boundSocket {
            var st = stat()
            if stat(bound.url.path, &st) == 0, st.st_dev == bound.device, st.st_ino == bound.inode {
                unlink(bound.url.path)
                try? FileManager.default.removeItem(at: configuration.paths.discoveryFileURL)
            }
            boundSocket = nil
        }
        releaseLock()
        log("keeper_finished reason=\(reason.rawValue)")
        let callback = onFinish
        onFinish = nil
        DispatchQueue.global(qos: .userInitiated).async { callback?(reason) }
    }

    // MARK: Log

    func log(_ line: String) {
        Logger.handover.notice("\(line, privacy: .public)")
        fileLog?.append(ISO8601DateFormatter().string(from: Date()) + " " + line + "\n")
    }
}

// MARK: - Ein aufbewahrter Chat

/// Leitung, Manifest und Terminal ohne Fenster eines Chats. Alles auf der
/// Queue des Aufbewahrers.
final class KeptChat {
    let manifest: HandoverManifest
    let screen: HandoverHeadlessTerminal
    private(set) var descriptor: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var readerAtEnd = false
    private(set) var exited = false
    private(set) var exitStatus: Int32?
    private(set) var gapBytes = 0
    /// TAKE gesendet, ACK fehlt noch.
    var inTransfer = false

    init(manifest: HandoverManifest, descriptor: Int32, queue: DispatchQueue) {
        self.manifest = manifest
        self.descriptor = descriptor
        self.queue = queue
        // Antworten des Terminals gehen über den aktuellen Deskriptor des
        // Chats, nie über eine gemerkte Nummer: nach dem Schließen könnte die
        // Nummer schon einer anderen Datei gehören.
        let target = WeakChat()
        screen = HandoverHeadlessTerminal(
            cols: manifest.cols,
            rows: manifest.rows,
            scrollback: manifest.scrollback,
            colors: manifest.terminalColors,
            writeToPTY: { bytes in target.chat?.write(bytes) }
        )
        target.chat = self
    }

    private final class WeakChat {
        weak var chat: KeptChat?
    }

    func markExited(status: Int32?) {
        exited = true
        exitStatus = status
    }

    func startReading() {
        guard reader == nil, descriptor >= 0, !readerAtEnd else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.pump() }
        source.resume()
        reader = source
    }

    /// Dispatch verlangt: Deskriptor erst schließen, wenn der Cancel-Handler
    /// jeder Lesequelle gelaufen ist.
    private var pendingCancels = 0
    private var descriptorToClose: Int32 = -1

    func stopReading() {
        guard let source = reader else { return }
        reader = nil
        pendingCancels += 1
        source.setCancelHandler { [self] in
            pendingCancels -= 1
            if pendingCancels == 0, descriptorToClose >= 0 {
                close(descriptorToClose)
                descriptorToClose = -1
            }
        }
        source.cancel()
    }

    /// Liest, was gerade anliegt, ohne zu blockieren (`poll` mit 0 statt
    /// `O_NONBLOCK`: das Flag gälte für die gemeinsame Dateibeschreibung und
    /// damit auch für die App, die dieselbe Leitung hält).
    func pump() {
        guard descriptor >= 0, !readerAtEnd else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var pfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 0)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 {
                // Kind hat die Gegenseite geschlossen (EIO bzw. 0): nicht mehr lesen,
                // die Leitung aber behalten, bis die App den Chat abholt.
                readerAtEnd = true
                stopReading()
                return
            }
            gapBytes += count
            screen.feed(buffer[0..<count])
        }
    }

    func write(_ bytes: [UInt8]) {
        guard descriptor >= 0 else { return }
        KeptChat.writeAll(fd: descriptor, bytes)
    }

    static func writeAll(fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        var attempts = 0
        while offset < bytes.count, attempts < 100 {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { attempts += 1; usleep(1_000); continue }
                return
            }
            offset += written
        }
    }

    /// Schließt die eigene Kopie der Leitung — bei laufendem oder eben
    /// beendetem Leser erst in dessen Cancel-Handler.
    func closeDescriptor() {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        stopReading()
        if pendingCancels == 0 {
            close(fd)
        } else {
            descriptorToClose = fd
        }
    }
}
