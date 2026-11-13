import AppKit
import Darwin
import SwiftTerm

/// Ein abgelöster Chat, bereit für `DEPOSIT`.
struct HandoverDetachedChat {
    var sessionID: UUID
    var handle: LocalProcess.HandoverHandle
    /// ANSI-Strom des Terminals zum Zeitpunkt des Ablösens.
    var image: [UInt8]
    var cols: Int
    var rows: Int
    var colors: HandoverTerminalColors?
}

// MARK: - Neustart ohne Chatverlust: Abgabe

extension AgentTerminalController {
    /// Löst die Leitung vom Terminal, ohne Signal und ohne sie zu schließen.
    /// Alles bereits Gelesene steht danach im Terminal, das Bild entspricht
    /// genau dem Stand, ab dem der Aufbewahrer liest. Nur auf dem Main Thread.
    ///
    /// `nil`, wenn nichts läuft oder das Lesen nicht rechtzeitig anhielt —
    /// dann läuft der Chat unverändert weiter und endet auf dem heutigen Weg.
    func detachForHandover(
        serializer: HandoverScreenSerializing = HandoverTerminalSerializer()
    ) -> HandoverDetachedChat? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning, !isHandedOver, handoverHandle == nil,
              let handle = terminal.process.detachForHandover() else { return nil }
        handoverHandle = handle
        // Gedrosselte Ausgabe (Hintergrund-Pane) gehört noch ins Bild.
        terminal.flushPendingOutput()
        let core = terminal.getTerminal()
        return HandoverDetachedChat(
            sessionID: sessionID,
            handle: handle,
            image: serializer.serialize(core),
            cols: core.cols,
            rows: core.rows,
            colors: HandoverTerminalColors(
                foreground: Self.hex(terminal.nativeForegroundColor),
                background: Self.hex(terminal.nativeBackgroundColor))
        )
    }

    /// Abgabe gescheitert, bevor `COMMIT` durch war: Die Leitung kommt ans
    /// Terminal zurück, der Chat läuft weiter, als wäre nichts gewesen.
    /// `false`, wenn das nicht ging; dann bleibt der Prozess ohne Leser und
    /// bekommt beim App-Ende ein SIGHUP (wie heute bei einem Absturz).
    @discardableResult
    func reattachAfterFailedHandover() -> Bool {
        guard let handle = handoverHandle else { return false }
        handoverHandle = nil
        if terminal.process.adopt(handle) { return true }
        Darwin.close(handle.fileDescriptor)
        Logger.agentStore.error("handover_reattach_failed session=\(self.sessionID.uuidString, privacy: .public)")
        return false
    }

    /// `#rrggbb` aus einer Farbe der Terminal-View (für OSC 10/11 beim
    /// Aufbewahrer).
    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

// MARK: - Neustart ohne Chatverlust: Übernahme

extension AgentTerminalController {
    /// Spielt das Bild in ein Terminal derselben Größe und übernimmt die
    /// Leitung. Nur auf dem Main Thread und nie, während anderswo ein
    /// `forkpty` läuft (close-on-exec der empfangenen Leitung).
    /// `false`, wenn SwiftTerm die Leitung nicht nimmt; der Aufrufer schließt
    /// sie dann und fällt auf `--resume` zurück.
    func adoptHandedOver(descriptor: Int32, manifest: HandoverManifest, image: [UInt8]) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        loadImage(image, cols: manifest.cols, rows: manifest.rows)
        let handle = LocalProcess.HandoverHandle(fileDescriptor: descriptor, pid: manifest.pid)
        guard terminal.process.adopt(handle) else { return false }
        markAdopted(token: manifest.controlToken,
                    startedAt: manifest.pidStartTime.map(Date.init(timeIntervalSince1970:)))
        if manifest.hasComposerDraft != false {
            // Unbekannt zählt als „Entwurf vorhanden“: Queue und `chats send`
            // schreiben sonst in einen halb getippten Text.
            noteComposerTextInserted()
        }
        return true
    }

    /// Chat endete in der Lücke: letztes Bild zeigen, Status „beendet“.
    func showEndedInGap(manifest: HandoverManifest, image: [UInt8], exitStatus: Int32?) {
        loadImage(image, cols: manifest.cols, rows: manifest.rows)
        markEndedInGap(exitCode: exitStatus)
    }

    private func loadImage(_ image: [UInt8], cols: Int, rows: Int) {
        let core = terminal.getTerminal()
        if core.cols != cols || core.rows != rows {
            core.resize(cols: max(cols, 2), rows: max(rows, 1))
        }
        terminal.feed(byteArray: image[...])
    }
}
