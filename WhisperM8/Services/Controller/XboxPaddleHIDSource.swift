import Foundation
import IOKit.hid
import os

/// Liest Paddles und Xbox-Knopf des Xbox-Controllers über rohes HID (Plan
/// `controller-xbox-paddles.md`, „HID-Quelle und Berechtigung“).
///
/// - Öffnet nur Microsoft-Geräte mit Gamepad-Usage (Generic Desktop:
///   GamePad, Joystick, MultiAxis) — nie Tastatur oder Maus, das löste die
///   Rückfrage nach „Eingabeüberwachung“ aus.
/// - Ohne Vereinnahmen (`kIOHIDOptionsTypeNone`), nur lesen: GameController
///   sieht weiter alles.
/// - Fragt nie von selbst nach der Berechtigung; `IOHIDCheckAccess` wird nur
///   gelesen und geloggt.
/// - Läuft auf der Queue der Pumpe (`IOHIDManagerSetDispatchQueue`), damit HID
///   und GameController in einer festen Reihenfolge ankommen. Ereignisgetrieben,
///   kein Zeitgeber, kein Abfragen. Mach-Ports statt Dateideskriptoren.
final class XboxPaddleHIDSource: @unchecked Sendable {
    /// Gebündelter Bericht. Aufgerufen auf `queue`.
    var onReport: (@Sendable (ControllerHIDReport) -> Void)?
    /// Paddles lesbar oder nicht. Aufgerufen auf `queue`.
    var onPaddlesAvailable: (@Sendable (Bool) -> Void)?
    /// Zustand für Anzeige und Debug-Kanal. Auf dem Main Thread.
    var onStateChange: (@MainActor (ControllerPaddleSupport) -> Void)?

    private var manager: IOHIDManager?
    private var queue: DispatchQueue?
    // Nur auf `queue`:
    private var builder = XboxHIDReportBuilder()
    /// Gerät, dessen Werte zählen: das erste Microsoft-Gamepad, eines mit
    /// Paddles bevorzugt. Zwei Elite gleichzeitig: nur das erste.
    private var primary: IOHIDDevice?
    private var devices: [IOHIDDevice] = []
    private var flushScheduled = false

    /// Berechtigung „Eingabeüberwachung“, nur gelesen.
    static var listenAccess: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown"
        }
    }

    // MARK: - Start und Stopp

    func start(queue: DispatchQueue) {
        guard manager == nil else { return }
        self.queue = queue
        let access = Self.listenAccess
        Logger.controller.info("controller_hid_access listen=\(access, privacy: .public)")
        let signpost = OSSignposter(logger: Logger.controller)
        let interval = signpost.beginInterval("controller.hidOpen")
        defer { signpost.endInterval("controller.hidOpen", interval) }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = XboxHID.gamepadUsages.map { usage in
            [
                kIOHIDVendorIDKey: XboxHID.vendorMicrosoft,
                kIOHIDDeviceUsagePageKey: Int(XboxHID.pageGenericDesktop),
                kIOHIDDeviceUsageKey: Int(usage),
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        // Solange der Manager lebt, hält er die Quelle fest; der
        // Abbruch-Handler gibt sie frei (Lehre aus dem FSEvents-Absturz:
        // nie ein unretained Kontext ohne gesicherte Lebensdauer).
        let retained = Unmanaged.passRetained(self)
        let context = retained.toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<XboxPaddleHIDSource>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<XboxPaddleHIDSource>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<XboxPaddleHIDSource>.fromOpaque(context).takeUnretainedValue().valueArrived(value)
        }, context)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            let reason = opened == kIOReturnNotPermitted ? "not permitted" : String(format: "open failed 0x%08x", opened)
            Logger.controller.info("controller_hid_open_failed reason=\(reason, privacy: .public) listen=\(access, privacy: .public)")
            publish(.notReadable(reason: reason))
            retained.release()
            return
        }
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) {
            // Auf `queue`, nachdem der Manager keine Callbacks mehr ruft.
            let source = retained.takeUnretainedValue()
            source.primary = nil
            source.devices = []
            source.builder.reset()
            source.onPaddlesAvailable?(false)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            retained.release()
        }
        IOHIDManagerActivate(manager)
        self.manager = manager
        Logger.controller.info("controller_hid_started")
    }

    /// Abbauen. Der Abbruch-Handler räumt auf der Queue auf und gibt die
    /// Quelle frei.
    func stop() {
        guard let manager else { return }
        self.manager = nil
        IOHIDManagerCancel(manager)
        publish(.none)
        Logger.controller.info("controller_hid_stopped")
    }

    // MARK: - Geräte (auf `queue`)

    private func deviceMatched(_ device: IOHIDDevice) {
        devices.append(device)
        choosePrimary()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        devices.removeAll { $0 == device }
        if primary == device {
            primary = nil
            builder.reset()
        }
        choosePrimary()
    }

    private func choosePrimary() {
        if primary == nil || !(primary.map(Self.hasPaddles) ?? false) {
            primary = devices.first(where: Self.hasPaddles) ?? primary ?? devices.first
        }
        let paddles = primary.map(Self.hasPaddles) ?? false
        onPaddlesAvailable?(paddles)
        let state: ControllerPaddleSupport = primary == nil ? .none : (paddles ? .readable : .noPaddles)
        let product = primary.flatMap { IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int } ?? 0
        Logger.controller.info("controller_hid_device state=\(state.debugName, privacy: .public) product=\(String(format: "0x%04x", product), privacy: .public)")
        publish(state)
    }

    /// Elite: hat das Element Consumer 0x0C/0x81 (nach Element, nicht nach
    /// Produkt-ID — so passen auch ältere Firmware und andere Wege).
    private static func hasPaddles(_ device: IOHIDDevice) -> Bool {
        let match: [String: Any] = [
            kIOHIDElementUsagePageKey: Int(XboxHID.pageConsumer),
            kIOHIDElementUsageKey: Int(XboxHID.usagePaddles),
        ]
        guard let elements = IOHIDDeviceCopyMatchingElements(device, match as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone))
            as? [IOHIDElement] else { return false }
        return !elements.isEmpty
    }

    // MARK: - Werte (auf `queue`)

    private func valueArrived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetDevice(element) == primary else { return }
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard page == XboxHID.pageButton || (page == XboxHID.pageConsumer && usage == XboxHID.usagePaddles) else {
            return
        }
        let finished = builder.add(
            page: page, usage: usage, value: IOHIDValueGetIntegerValue(value),
            timestamp: IOHIDValueGetTimeStamp(value))
        if let finished { onReport?(finished) }
        // Die Werte eines Berichts kommen hintereinander im selben Block der
        // Queue; ein Block danach schließt ihn ab.
        guard builder.pendingTimestamp != nil, !flushScheduled, let queue else { return }
        flushScheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            if let report = self.builder.flush() { self.onReport?(report) }
        }
    }

    private func publish(_ state: ControllerPaddleSupport) {
        let handler = onStateChange
        Task { @MainActor in handler?(state) }
    }
}
