import AppKit
import SwiftTerm

/// Finger-Bedienung des Chat-Terminals auf einem Touch-Display (WM8-136).
///
/// Ohne eigene Erkennung macht macOS 27 aus jedem Finger-Wisch im Terminal ein
/// Maus-Ziehen, und SwiftTerm markiert Text statt zu scrollen (gemessen am
/// 18.11.2026, siehe docs/features/agent-chats/ui/terminal.md). Deshalb hängen
/// am Terminal zwei Erkenner, die NUR direkte Touches sehen (`buttonMask = 0`,
/// `allowedTouchTypes = .direct`) — Apples Muster „Add touch support to your
/// custom tracking loop“. Maus, Trackpad und Tastatur laufen weiter über
/// `mouseDown`/`scrollWheel`/`keyDown` wie bisher; diese Erkenner sehen sie nie.
///
/// - Sofort wischen: Verlauf scrollen, mit Schwung nach dem Loslassen.
/// - Erst halten, dann ziehen: markieren (über SwiftTerms eigene Markierung).
/// - Tippen: Klick (Fokus, Auswahl aufheben; zweimal = Wort, dreimal = Zeile).
///
/// Kosten: nichts pro Byte oder Zeile. Ein Display-Link läuft nur, solange der
/// Schwung nach einem Wisch ausläuft (höchstens wenige Sekunden).
@MainActor
final class TerminalTouchGestures: NSObject, NSGestureRecognizerDelegate {
    /// Scrollt um `lines` Zeilen (positiv = hoch, ältere Zeilen) an der Stelle
    /// `location` (Ansichtskoordinaten). `false`, wenn sich nichts mehr bewegt
    /// (Anfang/Ende des Verlaufs) — dann endet der Schwung.
    typealias ScrollHandler = (_ lines: Int, _ location: NSPoint) -> Bool

    private weak var terminal: TerminalView?
    private let scroll: ScrollHandler
    private let pan = TerminalTouchPanRecognizer()
    private let tap = NSClickGestureRecognizer()
    /// Absicherung fürs Markieren: Springt der Pan nach längerem Halten nicht
    /// mehr an, übernimmt der Langdruck. Wer zuerst erkennt, gewinnt.
    private let press = NSPressGestureRecognizer()

    private var intent: TerminalTouchIntent?
    private var accumulator = TerminalTouchLineAccumulator()
    private var lastFingerTravel: CGFloat = 0
    private var lastSelectionPoint: NSPoint?
    /// Langdruck erkannt, Finger aber noch nicht bewegt: erst die erste
    /// Bewegung beginnt die Markierung (Halten allein markiert nichts).
    private var pendingSelectionStart: NSPoint?
    private var tapCounter = TerminalTapCounter()
    /// Ein Tipper, der laufenden Schwung anhält, klickt nicht (wie iOS).
    private var swallowNextTap = false

    private var momentum: TerminalTouchMomentum?
    private var momentumLocation: NSPoint = .zero
    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval?
    /// Nur während des Schwungs: Trackpad, Mausrad oder Mausklick im Fenster
    /// halten ihn an, wie bei `NSScrollView`.
    private var interruptMonitor: Any?

    init(attachedTo terminal: TerminalView, scroll: @escaping ScrollHandler) {
        self.terminal = terminal
        self.scroll = scroll
        super.init()

        pan.target = self
        pan.action = #selector(handlePan(_:))
        pan.buttonMask = 0
        pan.allowedTouchTypes = [.direct]
        pan.delegate = self
        terminal.addGestureRecognizer(pan)

        tap.target = self
        tap.action = #selector(handleTap(_:))
        tap.buttonMask = 0
        tap.allowedTouchTypes = [.direct]
        tap.numberOfClicksRequired = 1
        tap.delegate = self
        terminal.addGestureRecognizer(tap)

        press.target = self
        press.action = #selector(handlePress(_:))
        press.buttonMask = 0
        press.allowedTouchTypes = [.direct]
        press.minimumPressDuration = TerminalTouchIntent.holdThreshold
        press.allowableMovement = TerminalTouchPanRecognizer.moveSlop
        press.delegate = self
        terminal.addGestureRecognizer(press)
    }

    func detach() {
        stopMomentum()
        terminal?.removeGestureRecognizer(pan)
        terminal?.removeGestureRecognizer(tap)
        terminal?.removeGestureRecognizer(press)
    }

    /// Hält auslaufenden Schwung an (neuer Finger, Taste).
    func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = nil
        momentum = nil
        if let interruptMonitor {
            self.interruptMonitor = nil
            // Nicht aus dem eigenen Monitor-Aufruf heraus abmelden.
            DispatchQueue.main.async { NSEvent.removeMonitor(interruptMonitor) }
        }
    }

    /// Darf ein Finger an dieser Stelle (Terminal-Koordinaten) von uns bedient
    /// werden? Nicht auf SwiftTerms Scrollleiste: Deren `mouseDown` wartet in
    /// einer eigenen Schleife auf ein echtes Loslassen — ein nachgebildeter
    /// Klick würde die App dort festhalten. Die Leiste bleibt beim System.
    func handlesTouch(at point: NSPoint) -> Bool {
        guard let terminal, terminal.bounds.contains(point) else { return false }
        let hit = terminal.hitTest(terminal.convert(point, to: terminal.superview))
        var view = hit
        while let current = view, current !== terminal {
            if current is NSScroller { return false }
            view = current.superview
        }
        return view === terminal
    }

    // MARK: - Delegate

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        if let terminal, !handlesTouch(at: touch.location(in: terminal)) {
            return false
        }
        // Jeder neue Finger hält laufenden Schwung an; der zugehörige Tipper
        // ist dann nur „Anhalten“, kein Klick.
        if gestureRecognizer === pan {
            swallowNextTap = displayLink != nil
            stopMomentum()
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        // Markiert der Langdruck schon, darf der Pan nicht mehr übernehmen.
        if gestureRecognizer === pan {
            return press.state != .began && press.state != .changed
        }
        // Hat sich der Finger schon bewegt, ist es ein Wisch, kein Langdruck.
        if gestureRecognizer === press {
            return !pan.hasMoved
        }
        return true
    }

    // MARK: - Langdruck (Absicherung fürs Markieren)

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        guard let terminal else { return }
        let location = recognizer.location(in: terminal)
        switch recognizer.state {
        case .began:
            guard intent == nil else { return }
            intent = .select
            swallowNextTap = false
            pendingSelectionStart = location
            Logger.touch.debug("terminal_touch_press_began")
        case .changed:
            guard intent == .select else { return }
            if let start = pendingSelectionStart {
                guard hypot(location.x - start.x, location.y - start.y) >= TerminalTouchPanRecognizer.moveSlop else { return }
                beginSelection(at: start, current: location)
            } else {
                sendMouse(.leftMouseDragged, at: location, clickCount: 1)
                lastSelectionPoint = location
            }
        case .ended, .cancelled, .failed:
            guard intent == .select else { return }
            if pendingSelectionStart == nil {
                sendMouse(.leftMouseUp, at: lastSelectionPoint ?? location, clickCount: 1)
            }
            intent = nil
            pendingSelectionStart = nil
            lastSelectionPoint = nil
        default:
            break
        }
    }

    private func beginSelection(at start: NSPoint, current: NSPoint) {
        pendingSelectionStart = nil
        guard handlesTouch(at: start) else {
            intent = nil
            return
        }
        sendMouse(.leftMouseDown, at: start, clickCount: 1)
        sendMouse(.leftMouseDragged, at: start, clickCount: 1)
        sendMouse(.leftMouseDragged, at: current, clickCount: 1)
        lastSelectionPoint = current
    }

    // MARK: - Wischen und Markieren

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard let terminal else { return }
        let location = recognizer.location(in: terminal)
        switch recognizer.state {
        case .began:
            guard intent == nil else { return }
            let decided = TerminalTouchIntent.decide(restBeforeMove: pan.restBeforeMove())
            intent = decided
            swallowNextTap = false
            Logger.touch.debug("terminal_touch_began intent=\(String(describing: decided), privacy: .public) rest_ms=\(Int(self.pan.restBeforeMove() * 1000))")
            switch decided {
            case .scroll:
                accumulator.reset()
                lastFingerTravel = 0
                applyFingerTravel(of: recognizer, at: location)
            case .select:
                beginSelection(at: pan.touchDownLocation ?? location, current: location)
            }
        case .changed:
            switch intent {
            case .scroll: applyFingerTravel(of: recognizer, at: location)
            case .select:
                sendMouse(.leftMouseDragged, at: location, clickCount: 1)
                lastSelectionPoint = location
            case nil: break
            }
        case .ended:
            switch intent {
            case .scroll:
                applyFingerTravel(of: recognizer, at: location)
                startMomentum(velocity: fingerDown(recognizer.velocity(in: terminal).y), at: location)
            case .select:
                sendMouse(.leftMouseUp, at: lastSelectionPoint ?? location, clickCount: 1)
            case nil: break
            }
            intent = nil
            lastSelectionPoint = nil
        case .cancelled, .failed:
            if intent == .select {
                sendMouse(.leftMouseUp, at: lastSelectionPoint ?? location, clickCount: 1)
            }
            intent = nil
            lastSelectionPoint = nil
        default:
            break
        }
    }

    /// Fingerweg in „positiv = nach unten“ (ältere Zeilen) übersetzen.
    private func fingerDown(_ dy: CGFloat) -> CGFloat {
        guard let terminal else { return 0 }
        return terminal.isFlipped ? dy : -dy
    }

    private func applyFingerTravel(of recognizer: NSPanGestureRecognizer, at location: NSPoint) {
        guard let terminal else { return }
        let travel = fingerDown(recognizer.translation(in: terminal).y)
        let delta = travel - lastFingerTravel
        lastFingerTravel = travel
        let lines = accumulator.lines(forFingerTravel: delta, cellHeight: cellHeight())
        if lines != 0 {
            _ = scroll(lines, location)
        }
    }

    /// Zeilenhöhe aus Größe und Zeilenzahl; SwiftTerms `cellDimension` ist
    /// nicht öffentlich. Für das Umrechnen von Fingerweg genau genug.
    private func cellHeight() -> CGFloat {
        guard let terminal else { return 0 }
        let rows = terminal.getTerminal().rows
        guard rows > 0 else { return 0 }
        return terminal.bounds.height / CGFloat(rows)
    }

    // MARK: - Schwung

    private func startMomentum(velocity: CGFloat, at location: NSPoint) {
        stopMomentum()
        guard let terminal, let start = TerminalTouchMomentum(releaseVelocity: velocity) else { return }
        momentum = start
        momentumLocation = location
        let link = terminal.displayLink(target: self, selector: #selector(momentumFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        interruptMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            if let self, event.window === self.terminal?.window {
                self.stopMomentum()
            }
            return event
        }
    }

    /// Längste Lücke zwischen zwei Schwung-Schritten. Längere Pausen (Fenster
    /// verdeckt oder geschlossen, Terminal ausgehängt) beenden den Schwung,
    /// statt ihn später weiterlaufen zu lassen.
    static let maximumMomentumGap: CFTimeInterval = 0.25

    @objc private func momentumFrame(_ link: CADisplayLink) {
        guard var current = momentum else {
            stopMomentum()
            return
        }
        guard terminal?.window != nil else {
            stopMomentum()
            return
        }
        defer { lastFrameTimestamp = link.timestamp }
        guard let last = lastFrameTimestamp else { return }
        guard link.timestamp - last <= Self.maximumMomentumGap else {
            stopMomentum()
            return
        }
        let travel = current.advance(by: link.timestamp - last)
        momentum = current
        let lines = accumulator.lines(forFingerTravel: travel, cellHeight: cellHeight())
        let moved = lines == 0 || scroll(lines, momentumLocation)
        if current.isFinished || !moved {
            stopMomentum()
        }
    }

    // MARK: - Tippen

    @objc private func handleTap(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, let terminal else { return }
        if swallowNextTap {
            swallowNextTap = false
            return
        }
        let location = recognizer.location(in: terminal)
        guard handlesTouch(at: location) else { return }
        let count = tapCounter.register(
            at: location,
            time: ProcessInfo.processInfo.systemUptime,
            interval: NSEvent.doubleClickInterval
        )
        sendMouse(.leftMouseDown, at: location, clickCount: count)
        sendMouse(.leftMouseUp, at: location, clickCount: count)
    }

    // MARK: - Mausereignisse nachbilden

    /// Schickt ein Mausereignis über `NSApp.sendEvent` — derselbe Weg wie
    /// Apples eigene Emulation (gemessen), damit Fokus, Fenster-Aktivierung und
    /// die Klick-Beobachter der App es genauso sehen wie einen echten Klick.
    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int) {
        guard let terminal, let window = terminal.window else { return }
        // Ein Drücken nur dorthin, wo das Terminal selbst liegt (siehe
        // `handlesTouch`); Ziehen und Loslassen gehen an das gedrückte Ziel.
        if type == .leftMouseDown, !handlesTouch(at: point) { return }
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: terminal.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        NSApp.sendEvent(event)
    }
}

/// Pan-Erkenner, der festhält, wann und wo der Finger aufsetzte und wann er
/// sich zum ersten Mal bewegte. Daraus entscheidet `TerminalTouchIntent`
/// zwischen Scrollen und Markieren.
final class TerminalTouchPanRecognizer: NSPanGestureRecognizer {
    /// Ab dieser Strecke gilt der Finger als bewegt (Punkte).
    static let moveSlop: CGFloat = 4

    private(set) var touchDownLocation: NSPoint?
    private var touchDownTime: TimeInterval?
    private var firstMoveTime: TimeInterval?

    /// Hat sich der Finger seit dem Aufsetzen spürbar bewegt?
    var hasMoved: Bool { firstMoveTime != nil }

    override func touchesBegan(with event: NSEvent) {
        if touchDownTime == nil {
            touchDownTime = event.timestamp
            touchDownLocation = event.touches(matching: .began, in: view).first?.location(in: view)
                ?? location(in: view)
        }
        super.touchesBegan(with: event)
    }

    override func touchesMoved(with event: NSEvent) {
        if firstMoveTime == nil, let start = touchDownLocation {
            let point = event.touches(matching: .moved, in: view).first?.location(in: view) ?? location(in: view)
            if hypot(point.x - start.x, point.y - start.y) >= Self.moveSlop {
                firstMoveTime = event.timestamp
            }
        }
        super.touchesMoved(with: event)
    }

    override func reset() {
        touchDownLocation = nil
        touchDownTime = nil
        firstMoveTime = nil
        super.reset()
    }

    /// Ruhezeit zwischen Aufsetzen und erster Bewegung.
    func restBeforeMove() -> TimeInterval {
        guard let touchDownTime else { return 0 }
        let moved = firstMoveTime ?? ProcessInfo.processInfo.systemUptime
        return max(0, moved - touchDownTime)
    }
}
