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
