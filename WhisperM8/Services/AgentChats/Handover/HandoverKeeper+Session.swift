import Darwin
import Foundation

// MARK: - Protokoll je Verbindung (Aufbewahrer-Seite)

extension HandoverKeeper {
    /// Bedient eine Verbindung bis zu ihrem Ende. Läuft auf einem eigenen
    /// Thread; Zustand nur über `queue.sync`.
    func serve(_ connection: HandoverConnection, peer: HandoverPeer, trusted: Bool) {
        let timeout = configuration.ioTimeout
        guard let first = try? connection.receive(timeout: timeout) else { return }
        closeUnexpected(first)

        switch first.message.type {
        case .status:
            var reply = HandoverMessage(type: .statusResult)
            reply.status = queue.sync { status() }
            reply.runID = configuration.runID
            try? connection.send(reply, timeout: timeout)
        case .release:
            // Grundvertrag: auch ohne HELLO und unabhängig von der Version.
            guard trusted else { return reject(connection, peer: peer) }
            handleRelease(connection)
        case .hello:
            guard trusted else { return reject(connection, peer: peer) }
            switch first.message.role {
            case .deposit: serveDeposit(connection, hello: first.message)
            case .take: serveTake(connection, hello: first.message)
            case nil: try? connection.send(.error("HELLO ohne Rolle"), timeout: timeout)
            }
        default:
            try? connection.send(.error("erst HELLO oder STATUS"), timeout: timeout)
        }
    }

    private func reject(_ connection: HandoverConnection, peer: HandoverPeer) {
        log("peer_rejected reason=binary pid=\(peer.pid.map(String.init) ?? "?")")
        try? connection.send(.error("nur die App dieser Instanz darf das"), timeout: configuration.ioTimeout)
    }

    /// Deskriptoren an Telegrammen, die keinen tragen dürfen, sofort schließen.
    private func closeUnexpected(_ received: HandoverReceived) {
        if received.message.type != .deposit, let fd = received.descriptor { close(fd) }
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
                    // Abgabe nicht bestätigt: Kopien still freigeben.
                    log("deposit_lost chats=\(chats.count)")
                    releaseSilently()
                    finish(.depositLost)
                }
            }
        }
        do {
            try connection.send(okReply(protocolVersion: version), timeout: timeout)
            while true {
                let received = try connection.receive(timeout: max(timeout, configuration.depositSeconds))
                switch received.message.type {
                case .deposit:
                    guard let manifest = received.message.manifest, let fd = received.descriptor else {
                        if let fd = received.descriptor { close(fd) }
                        try connection.send(.error("DEPOSIT ohne Manifest oder Leitung"), timeout: timeout)
                        continue
                    }
                    let problem = queue.sync { addChat(manifest: manifest, descriptor: fd, image: received.payload) }
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
                        // Bestätigung vor dem Zustandswechsel senden wäre falsch:
                        // erst halten, dann OK — die App gibt danach nichts mehr frei.
                        commit()
                        return true
                    }
                    try? connection.send(committed ? okReply(protocolVersion: version) : .error("zu spät"), timeout: timeout)
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
            if let next = try? connection.receive(timeout: timeout) {
                closeUnexpected(next)
                if next.message.type == .release { handleRelease(connection) }
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
                let received = try connection.receive(timeout: configuration.holdSeconds)
                closeUnexpected(received)
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

    /// Ein Chat geht an die neue App. Lesen anhalten, Rest verarbeiten, Bild
    /// sichern, Leitung + Bild schicken, auf ACK warten — erst dann die
    /// eigene Kopie schließen (harte Regel).
    private func handleTake(_ connection: HandoverConnection, chatID: String?) throws {
        let timeout = configuration.ioTimeout
        typealias Prepared = (message: HandoverMessage, fd: Int32?, image: [UInt8])
        let prepared: Prepared? = queue.sync {
            guard let chatID, let chat = chats[chatID], !chat.inTransfer else { return nil }
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
        defer {
            queue.sync {
                guard let chat = chats[chatID] else { return }
                if acknowledged {
                    chat.closeDescriptor()
                    chats[chatID] = nil
                    chatOrder.removeAll { $0 == chatID }
                    log("taken chat=\(chatID) gap_bytes=\(chat.gapBytes)")
                } else {
                    // Kein ACK: die Leitung bleibt beim Aufbewahrer, er liest weiter.
                    chat.inTransfer = false
                    if !chat.exited { chat.startReading() }
                    log("take_not_acknowledged chat=\(chatID)")
                }
            }
        }
        try connection.send(prepared.message, descriptor: prepared.fd, payload: prepared.image, timeout: timeout)
        let reply = try connection.receive(timeout: configuration.ackTimeout)
        closeUnexpected(reply)
        guard reply.message.type == .ack, reply.message.chatID == chatID else {
            throw HandoverWireError.unexpected("ACK erwartet für \(chatID)")
        }
        acknowledged = true
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
