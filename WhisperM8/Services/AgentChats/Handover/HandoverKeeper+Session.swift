import Darwin
import Foundation

// MARK: - Protokoll je Verbindung (Aufbewahrer-Seite)

extension HandoverKeeper {
    /// Bedient eine Verbindung bis zu ihrem Ende. Läuft auf einem eigenen
    /// Thread; Zustand nur über `queue.sync`.
    ///
    /// Leitungen nimmt der Aufbewahrer ausschließlich an `DEPOSIT` innerhalb
    /// der Abgabe an. An jedem anderen Telegramm schließt `receive` sie sofort.
    ///
    /// Die Gegenseite wird bei **jedem** Telegramm außer `STATUS` neu geprüft,
    /// nicht nur beim `accept`: Der Kernel ordnet einem Unix-Socket den
    /// Prozess zu, der ihn zuletzt benutzt hat, in dessen jetzigem Zustand.
    /// Verbindet sich ein Kind und lädt danach per `exec` das App-Binary,
    /// sähe ein Test beim `accept` „die App“; der Elternprozess, der danach
    /// über dieselbe Verbindung spricht, fällt erst bei seinem Telegramm auf.
    ///
    /// Wer mehr als `STATUS` will, braucht außerdem das Einmal-Geheimnis
    /// (HELLO und RELEASE). Den Inhalt eines Telegramms kann sich ein fremder
    /// Prozess nicht vom App-Binary schreiben lassen, wohl aber dessen
    /// Identität am Socket borgen — deshalb beides.
    func serve(_ connection: HandoverConnection) {
        let timeout = configuration.ioTimeout
        guard let first = try? receiveChecked(connection, timeout: configuration.firstMessageTimeout) else { return }
        if first.message.type == .hello || first.message.type == .release {
            guard hasValidSecret(first.message) else {
                log("peer_rejected reason=secret type=\(first.message.type.rawValue)")
                try? connection.send(.error("ohne gültigen Nachweis"), timeout: timeout)
                return
            }
        }

        switch first.message.type {
        case .status:
            var reply = HandoverMessage(type: .statusResult)
            reply.status = queue.sync { status() }
            reply.runID = configuration.runID
            try? connection.send(reply, timeout: timeout)
        case .release:
            // Grundvertrag: auch ohne HELLO und unabhängig von der Version.
            handleRelease(connection)
        case .hello:
            switch first.message.role {
            case .deposit: serveDeposit(connection, hello: first.message)
            case .take: serveTake(connection, hello: first.message)
            case nil: try? connection.send(.error("HELLO ohne Rolle"), timeout: timeout)
            }
        default:
            try? connection.send(.error("erst HELLO oder STATUS"), timeout: timeout)
        }
    }

    /// Liest ein Telegramm und prüft den Absender, außer bei `STATUS`.
    /// Fremde Absender bekommen ERROR, ihre Leitungen werden geschlossen,
    /// und die Verbindung endet.
    ///
    /// Der erste geprüfte Absender wird festgehalten (PID und PID-Version aus
    /// dem Audit-Token); jedes weitere Telegramm muss von genau ihm kommen.
    func receiveChecked(_ connection: HandoverConnection, timeout: TimeInterval, acceptAttachments: Bool = false) throws -> HandoverReceived {
        let received = try connection.receive(timeout: timeout, acceptAttachments: acceptAttachments)
        guard received.message.type != .status else { return received }
        let peer = HandoverPeer.of(socket: connection.fd)
        var allowed = false
        if let peer, peer.uid == getuid(), configuration.peerPolicy.isAllowed(peer),
           let pid = peer.pid, let version = peer.pidVersion {
            if let pinned = connection.pinnedSender {
                allowed = pinned.pid == pid && pinned.version == version
            } else {
                connection.pinnedSender = (pid, version)
                allowed = true
            }
        }
        guard allowed else {
            if let fd = received.descriptor { close(fd) }
            log("peer_rejected type=\(received.message.type.rawValue) pid=\(peer?.pid.map(String.init) ?? "?") path=\(peer?.executablePath ?? "-")")
            try? connection.send(.error("nur die App dieser Instanz darf das"), timeout: configuration.ioTimeout)
            throw HandoverWireError.unexpected("Gegenseite nicht berechtigt")
        }
        return received
    }

    func hasValidSecret(_ message: HandoverMessage) -> Bool {
        guard let expected = configuration.secret else { return true }
        return HandoverSecret.matches(message.secret, expected: expected)
    }

    private func okReply(protocolVersion: Int) -> HandoverMessage {
        var reply = HandoverMessage(type: .ok)
        reply.protocolVersion = protocolVersion
        reply.runID = configuration.runID
        reply.build = HandoverProtocol.buildIdentifier
        return reply
    }

    // MARK: Abgabe (alte App)

    private func serveDeposit(_ connection: HandoverConnection, hello: HandoverMessage) {
        let timeout = configuration.ioTimeout
        guard let version = hello.protocolVersion, HandoverProtocol.supported.contains(version) else {
            try? connection.send(HandoverMessage(type: .incompatible), timeout: timeout)
            return
        }
        let admitted: String? = queue.sync {
            guard phase == .awaitingDeposit else { return "keine Abgabe mehr möglich (\(phase.rawValue))" }
            guard !depositConnectionActive else { return "belegt" }
            depositConnectionActive = true
            extendDepositDeadline()
            return nil
        }
        if let admitted {
            try? connection.send(.error(admitted), timeout: timeout)
            return
        }
        log("deposit_hello app_pid=\(hello.appPid.map(String.init) ?? "?") build=\(hello.build ?? "?")")
        var committed = false
        defer {
            queue.sync {
                depositConnectionActive = false
                if !committed, phase == .awaitingDeposit {
                    // Abgabe nicht bestätigt: Kopien still freigeben. Die alte
                    // App hält ihre Originale bis COMMIT → OK.
                    log("deposit_lost chats=\(chats.count)")
                    releaseSilently()
                    finish(.depositLost)
                }
            }
        }
        do {
            try connection.send(okReply(protocolVersion: version), timeout: timeout)
            while true {
                let received = try receiveChecked(connection, timeout: configuration.depositSeconds, acceptAttachments: true)
                if received.message.type != .deposit, let stray = received.descriptor { close(stray) }
                switch received.message.type {
                case .deposit:
                    guard let manifest = received.message.manifest, let fd = received.descriptor else {
                        if let fd = received.descriptor { close(fd) }
                        try connection.send(.error("DEPOSIT ohne Manifest oder Leitung"), timeout: timeout)
                        continue
                    }
                    let problem = queue.sync { () -> String? in
                        extendDepositDeadline()
                        return addChat(manifest: manifest, descriptor: fd, image: received.payload)
                    }
                    if let problem {
                        close(fd)
                        log("deposit_rejected chat=\(manifest.chatID) reason=\(problem)")
                        try connection.send(.error(problem), timeout: timeout)
                        continue
                    }
                    var ack = HandoverMessage(type: .ack)
                    ack.chatID = manifest.chatID
                    try connection.send(ack, timeout: timeout)
                case .commit:
                    committed = queue.sync { () -> Bool in
                        guard phase == .awaitingDeposit else { return false }
                        // Erst halten, dann OK: Danach schließt die App ihre Originale.
                        commit()
                        return true
                    }
                    guard committed else {
                        try? connection.send(.error("zu spät"), timeout: timeout)
                        return
                    }
                    do {
                        try connection.send(okReply(protocolVersion: version), timeout: timeout)
                    } catch {
                        // Ohne OK hält die App sich an den heutigen Weg (Ctrl+C,
                        // Originale zu). Dann darf hier keine Kopie die Chats halten.
                        queue.sync {
                            log("commit_ok_lost chats=\(chats.count)")
                            releaseSilently()
                            finish(.depositLost)
                        }
                        return
                    }
                    queue.sync { if phase == .holding, chats.isEmpty { finish(.allTaken) } }
                    return
                case .abort:
                    try? connection.send(okReply(protocolVersion: version), timeout: timeout)
                    queue.sync {
                        log("deposit_aborted chats=\(chats.count)")
                        releaseSilently()
                        finish(.aborted)
                    }
                    committed = true // Ende ist schon gemeldet
                    return
                case .status:
                    var reply = HandoverMessage(type: .statusResult)
                    reply.status = queue.sync { status() }
                    try connection.send(reply, timeout: timeout)
                default:
                    try connection.send(.error("in der Abgabe nicht erlaubt: \(received.message.type.rawValue)"), timeout: timeout)
                }
            }
        } catch {
            log("deposit_connection_error \(error)")
        }
    }

    // MARK: Übernahme (neue App)

    private func serveTake(_ connection: HandoverConnection, hello: HandoverMessage) {
        let timeout = configuration.ioTimeout
        guard let range = hello.protocolRangeValue,
              let version = HandoverProtocol.negotiate(client: range) else {
            log("take_incompatible range=\(hello.protocolRange?.description ?? "?")")
            try? connection.send(HandoverMessage(type: .incompatible), timeout: timeout)
            // Die App darf jetzt noch RELEASE schicken (Grundvertrag).
            if let next = try? receiveChecked(connection, timeout: timeout), next.message.type == .release {
                handleRelease(connection)
            }
            return
        }
        let admitted: String? = queue.sync {
            guard phase == .holding else { return "nichts zu übernehmen (\(phase.rawValue))" }
            guard !takeConnectionActive else { return "belegt" }
            takeConnectionActive = true
            return nil
        }
        if let admitted {
            try? connection.send(.error(admitted), timeout: timeout)
            return
        }
        log("take_hello protocol=\(version) build=\(hello.build ?? "?")")
        defer {
            queue.sync {
                takeConnectionActive = false
                // Verbindung weg und nichts mehr da: fertig. Sonst weiter halten
                // (die nächste App-Instanz kann übernehmen).
                if phase == .holding, chats.isEmpty { finish(.allTaken) }
            }
        }
        do {
            try connection.send(okReply(protocolVersion: version), timeout: timeout)
            while true {
                // Zwischen zwei Befehlen darf die App sich Zeit lassen; die
                // Haltefrist begrenzt das Ganze.
                let received = try receiveChecked(connection, timeout: configuration.holdSeconds)
                switch received.message.type {
                case .list:
                    var reply = HandoverMessage(type: .chats)
                    reply.chats = queue.sync { summaries() }
                    try connection.send(reply, timeout: timeout)
                case .take:
                    try handleTake(connection, chatID: received.message.chatID)
                case .done:
                    try? connection.send(okReply(protocolVersion: version), timeout: timeout)
                    queue.sync {
                        if chats.isEmpty {
                            finish(.allTaken)
                        } else {
                            log("done_with_remaining chats=\(chats.count)")
                            shutDownOrderly(reason: .doneWithRemaining)
                        }
                    }
                    return
                case .release:
                    handleRelease(connection)
                    return
                case .status:
                    var reply = HandoverMessage(type: .statusResult)
                    reply.status = queue.sync { status() }
                    try connection.send(reply, timeout: timeout)
                default:
                    try connection.send(.error("in der Übernahme nicht erlaubt: \(received.message.type.rawValue)"), timeout: timeout)
                }
            }
        } catch {
            log("take_connection_error \(error)")
        }
    }

    /// Ein Chat geht an die neue App:
    /// 1. Lesen anhalten, Rest verarbeiten, Bild sichern.
    /// 2. `CHAT` + Leitung + Bild schicken, auf `ACK` warten (`ackTimeout`).
    /// 3. Mit ACK: `OK {chatID}` senden, danach die eigene Kopie schließen —
    ///    erst mit dem OK übernimmt die App. Ohne ACK oder ohne zugestelltes
    ///    OK (Frist, Abbruch, falsche Antwort): Der Chat bleibt beim
    ///    Aufbewahrer. Ein zu spätes ACK bekommt kein OK, die App schließt
    ///    ihre Kopie dann nur, ohne Ctrl+C.
    private func handleTake(_ connection: HandoverConnection, chatID: String?) throws {
        let timeout = configuration.ioTimeout
        typealias Prepared = (message: HandoverMessage, fd: Int32?, image: [UInt8])
        let prepared: Prepared? = queue.sync {
            guard phase == .holding, let chatID, let chat = chats[chatID], !chat.inTransfer else { return nil }
            chat.stopReading()
            chat.pump()
            let image = configuration.serializer.serialize(chat.screen.terminal)
            chat.inTransfer = true
            var message = HandoverMessage(type: .chat)
            message.chatID = chatID
            message.manifest = chat.manifest
            message.exited = chat.exited
            message.exitStatus = chat.exitStatus
            message.gapBytes = chat.gapBytes
            // Ein beendeter Chat braucht keine Leitung mehr.
            let fd: Int32? = chat.exited ? nil : chat.descriptor
            return (message, fd, image)
        }
        guard let prepared else {
            try connection.send(.error("unbekannter oder belegter Chat"), timeout: timeout)
            return
        }
        let chatID = prepared.message.chatID ?? ""
        var acknowledged = false
        // Läuft bei jedem Ausgang: Die Übergabe ist entschieden.
        func settle() {
            queue.sync {
                guard let chat = chats[chatID] else { return }
                chat.inTransfer = false
                if acknowledged {
                    log("taken chat=\(chatID) gap_bytes=\(chat.gapBytes) dropped_bytes=\(chat.droppedBytes)")
                    remove(chat)
                } else if phase == .closing {
                    // Ende läuft schon: nur schließen, kein Ctrl+C.
                    log("take_not_acknowledged_closing chat=\(chatID)")
                    remove(chat)
                } else {
                    // Die Leitung bleibt beim Aufbewahrer, er liest weiter.
                    if !chat.exited { chat.startReading() }
                    log("take_not_acknowledged chat=\(chatID)")
                }
            }
        }
        // Ein aufgeschobenes Ende erst nach dem OK auslösen, sonst schlösse
        // `finish` die Verbindung, bevor die App ihr OK hat.
        defer { queue.sync { transferSettled() } }
        do {
            try connection.send(prepared.message, descriptor: prepared.fd, payload: prepared.image, timeout: timeout)
            let reply = try receiveChecked(connection, timeout: configuration.ackTimeout)
            guard reply.message.type == .ack, reply.message.chatID == chatID else {
                throw HandoverWireError.unexpected("ACK erwartet für \(chatID)")
            }
            // Erst das OK, solange die eigene Kopie noch offen ist: Geht es
            // nicht hinaus, behält der Aufbewahrer den Chat, statt ihn ohne
            // Halter zurückzulassen (die App schließt ohne OK ihre Kopie).
            var confirm = okReply(protocolVersion: HandoverProtocol.current)
            confirm.chatID = chatID
            try connection.send(confirm, timeout: timeout)
            acknowledged = true
        } catch {
            settle()
            throw error
        }
        settle()
    }

    private func handleRelease(_ connection: HandoverConnection) {
        let accepted: Bool = queue.sync {
            guard phase == .holding else { return false }
            log("release_requested chats=\(chats.count)")
            return true
        }
        guard accepted else {
            try? connection.send(.error("nichts freizugeben"), timeout: configuration.ioTimeout)
            return
        }
        // Erst bestätigen, dann geordnet beenden (die Ctrl+C-Pausen dauern ~260 ms).
        try? connection.send(okReply(protocolVersion: HandoverProtocol.current), timeout: configuration.ioTimeout)
        queue.sync { shutDownOrderly(reason: .released) }
    }
}
