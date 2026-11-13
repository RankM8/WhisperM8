import AppKit
import Foundation
import IOKit.hid
import os

/// Liest Paddles und Xbox-Knopf des Xbox-Controllers über rohes HID (Plan
/// `controller-xbox-paddles.md`, „HID-Quelle und Berechtigung“).
///
/// - Findet nur Microsoft-Geräte, deren Haupt-Usage ein Gamepad ist (Generic
///   Desktop: GamePad, Joystick, MultiAxis). Der Manager dient nur dem Finden
///   und wird nie geöffnet; jedes Gerät wird einzeln geprüft und geöffnet.
/// - Tritt ein Gerät zusätzlich als Tastatur oder Ziffernblock auf (der Elite
///   über Bluetooth LE tut das), wird es nur bei erteilter
///   „Eingabeüberwachung“ geöffnet, sonst gilt es als „nicht lesbar“. Nach der
///   Berechtigung fragt die Quelle nie von selbst (`IOHIDCheckAccess` wird nur
///   gelesen).
/// - Ohne Vereinnahmen (`kIOHIDOptionsTypeNone`), nur lesen: GameController
///   sieht weiter alles.
/// - Läuft auf der Queue der Pumpe, damit HID und GameController in einer
///   festen Reihenfolge ankommen. Ereignisgetrieben, kein Zeitgeber, kein
///   Abfragen. Mach-Ports statt Dateideskriptoren.
/// - Jeder Lauf ist ein eigenes `XboxHIDSession`-Objekt: Ein Abbruch-Handler
///   eines alten Laufs räumt nur seinen eigenen Zustand ab, nie den eines
///   neuen.
final class XboxPaddleHIDSource: @unchecked Sendable {
    /// Gebündelter Bericht. Aufgerufen auf `queue`.
    var onReport: (@Sendable (ControllerHIDReport) -> Void)?
    /// Paddles lesbar oder nicht. Aufgerufen auf `queue`.
    var onPaddlesAvailable: (@Sendable (Bool) -> Void)?
    /// Zustand für Anzeige und Debug-Kanal. Auf dem Main Thread.
    var onStateChange: (@MainActor (ControllerPaddleSupport) -> Void)?

    /// Laufender Lauf. Nur in `start`/`stop` (Main Thread) gelesen und gesetzt.
    private var session: XboxHIDSession?

    /// Berechtigung „Eingabeüberwachung“, nur gelesen.
    static var listenAccess: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "unknown"
        }
    }

    /// Nur auf Klick in den Einstellungen: nach „Eingabeüberwachung“ fragen
    /// und die passende Stelle der Systemeinstellungen öffnen. Wirkt erst nach
    /// einem Neustart der App.
    @MainActor
    static func requestListenAccess() {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        Logger.controller.info("controller_hid_access_requested granted=\(granted, privacy: .public)")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Start und Stopp

    func start(queue: DispatchQueue) {
        guard session == nil else { return }
        let access = Self.listenAccess
        Logger.controller.info("controller_hid_access listen=\(access, privacy: .public)")
        let session = XboxHIDSession(
            queue: queue, listenAccessGranted: access == "granted",
            onReport: onReport, onPaddlesAvailable: onPaddlesAvailable, onStateChange: onStateChange)
        session.start()
        self.session = session
        Logger.controller.info("controller_hid_started")
    }

    /// Abbauen. Der Lauf meldet danach nichts mehr; seine Abbruch-Handler
    /// schließen die Geräte auf der Queue und geben ihn frei.
    func stop() {
        guard let session else { return }
        self.session = nil
        session.cancel()
        let handler = onStateChange
        Task { @MainActor in handler?(.none) }
        Logger.controller.info("controller_hid_stopped")
    }
}

/// Ein Lauf der HID-Quelle: Manager, geöffnete Geräte, Bündler. Lebt, bis
/// der Abbruch-Handler des Managers und aller Geräte gelaufen ist (jeder hält
/// einen eigenen Verweis über seinen Kontext).
private final class XboxHIDSession: @unchecked Sendable {
    private struct Device {
        /// Gerät des Managers: nur zum Wiedererkennen beim Entfernen.
        var matched: IOHIDDevice
        /// Eigenes, einzeln geöffnetes Gerät; liefert die Werte.
        var opened: IOHIDDevice
    }

    private let queue: DispatchQueue
    private let listenAccessGranted: Bool
    private let onReport: (@Sendable (ControllerHIDReport) -> Void)?
    private let onPaddlesAvailable: (@Sendable (Bool) -> Void)?
    private let onStateChange: (@MainActor (ControllerPaddleSupport) -> Void)?
    /// Abgebrochen: keine Meldungen mehr nach außen. Unter dem Sperrobjekt,
    /// damit eine Meldung entweder ganz vor oder gar nicht nach `cancel` kommt.
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private var manager: IOHIDManager?

    // Nur auf `queue`:
    private var builder = XboxHIDReportBuilder()
    private var devices: [Device] = []
    /// Gefundene Geräte, die wegen fehlender Eingabeüberwachung zu bleiben.
    private var blocked: [IOHIDDevice] = []
    /// Letzter Grund, warum ein Öffnen scheiterte.
    private var openFailure: String?
    /// Gerät, dessen Werte zählen: das erste Microsoft-Gamepad, eines mit
    /// Paddles bevorzugt. Zwei Elite gleichzeitig: nur das erste.
    private var primary: IOHIDDevice?
    private var flushScheduled = false

    init(
        queue: DispatchQueue, listenAccessGranted: Bool,
        onReport: (@Sendable (ControllerHIDReport) -> Void)?,
        onPaddlesAvailable: (@Sendable (Bool) -> Void)?,
        onStateChange: (@MainActor (ControllerPaddleSupport) -> Void)?
    ) {
        self.queue = queue
        self.listenAccessGranted = listenAccessGranted
        self.onReport = onReport
        self.onPaddlesAvailable = onPaddlesAvailable
        self.onStateChange = onStateChange
    }

    func start() {
        let signpost = OSSignposter(logger: Logger.controller)
        let interval = signpost.beginInterval("controller.hidOpen")
        defer { signpost.endInterval("controller.hidOpen", interval) }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = XboxHID.gamepadUsages.map { usage in
            [
                kIOHIDVendorIDKey: XboxHID.vendorMicrosoft,
                kIOHIDPrimaryUsagePageKey: Int(XboxHID.pageGenericDesktop),
                kIOHIDPrimaryUsageKey: Int(usage),
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        // Der Manager hält den Lauf fest, bis sein Abbruch-Handler läuft
        // (Lehre aus dem FSEvents-Absturz: nie ein unretained Kontext ohne
        // gesicherte Lebensdauer).
        let retained = Unmanaged.passRetained(self)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<XboxHIDSession>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
        }, retained.toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<XboxHIDSession>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, retained.toOpaque())
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) {
            // Auf `queue`, nachdem der Manager keine Callbacks mehr ruft. Nur
            // der eigene Zustand: Ein neuer Lauf hat seinen eigenen.
            let session = retained.takeUnretainedValue()
            for device in session.devices { IOHIDDeviceCancel(device.opened) }
            session.devices = []
            session.blocked = []
            session.primary = nil
            session.builder.reset()
            retained.release()
        }
        IOHIDManagerActivate(manager)
        self.manager = manager
    }

    /// Vom Main Thread. Danach meldet der Lauf nichts mehr nach außen.
    func cancel() {
        cancelled.withLock { $0 = true }
        if let manager { IOHIDManagerCancel(manager) }
        manager = nil
    }

    /// Meldung nach außen nur, solange der Lauf nicht abgebrochen ist. Die
    /// Empfänger stellen nur auf die Queue der Pumpe ein, das ist kurz genug
    /// für das Sperrobjekt.
    private func deliver(_ body: () -> Void) {
        cancelled.withLock { isCancelled in
            guard !isCancelled else { return }
            body()
        }
    }

    // MARK: - Geräte (auf `queue`)

    private func deviceMatched(_ device: IOHIDDevice) {
        let product = Self.productID(device)
        guard XboxHID.mayOpen(usagePairs: Self.usagePairs(device), listenAccessGranted: listenAccessGranted) else {
            Logger.controller.info("controller_hid_device_blocked reason=keyboard_without_listen_access product=\(product, privacy: .public)")
            blocked.append(device)
            choosePrimary()
            return
        }
        // Eigenes Geräteobjekt: Das des Managers ist schon an dessen Queue
        // gebunden und nähme keinen eigenen Werte-Callback mehr an.
        guard let opened = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(device)) else {
            openFailure = "device create failed"
            choosePrimary()
            return
        }
        let result = IOHIDDeviceOpen(opened, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let reason = result == kIOReturnNotPermitted ? "not permitted" : String(format: "open failed 0x%08x", result)
            Logger.controller.info("controller_hid_open_failed reason=\(reason, privacy: .public) product=\(product, privacy: .public)")
            openFailure = reason
            choosePrimary()
            return
        }
        let retained = Unmanaged.passRetained(self)
        IOHIDDeviceRegisterInputValueCallback(opened, { context, _, _, value in
            guard let context else { return }
            Unmanaged<XboxHIDSession>.fromOpaque(context).takeUnretainedValue().valueArrived(value)
        }, retained.toOpaque())
        IOHIDDeviceSetDispatchQueue(opened, queue)
        IOHIDDeviceSetCancelHandler(opened) {
            IOHIDDeviceClose(opened, IOOptionBits(kIOHIDOptionsTypeNone))
            retained.release()
        }
        IOHIDDeviceActivate(opened)
        devices.append(Device(matched: device, opened: opened))
        openFailure = nil
        choosePrimary()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        blocked.removeAll { $0 == device }
        if let index = devices.firstIndex(where: { $0.matched == device }) {
            let removed = devices.remove(at: index)
            IOHIDDeviceCancel(removed.opened)
            if primary == removed.opened {
                primary = nil
                builder.reset()
            }
        }
        choosePrimary()
    }

    private func choosePrimary() {
        let opened = devices.map(\.opened)
        if primary == nil || !(primary.map(Self.hasPaddles) ?? false) {
            primary = opened.first(where: Self.hasPaddles) ?? primary ?? opened.first
        }
        let paddles = primary.map(Self.hasPaddles) ?? false
        let state: ControllerPaddleSupport
        if let primary {
            state = Self.hasPaddles(primary) ? .readable : .noPaddles
        } else if !blocked.isEmpty {
            state = .notReadable(reason: "input monitoring not granted")
        } else if let openFailure {
            state = .notReadable(reason: openFailure)
        } else {
            state = .none
        }
        let product = primary.map(Self.productID) ?? "0x0000"
        Logger.controller.info("controller_hid_device state=\(state.debugName, privacy: .public) product=\(product, privacy: .public)")
        let handler = onStateChange
        deliver {
            onPaddlesAvailable?(paddles)
            Task { @MainActor [cancelled = self.cancelled] in
                // Auf dem Main Thread geprüft, wo auch `cancel` läuft.
                guard !cancelled.withLock({ $0 }) else { return }
                handler?(state)
            }
        }
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

    private static func usagePairs(_ device: IOHIDDevice) -> [(page: UInt32, usage: UInt32)] {
        let raw = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? []
        return raw.compactMap { pair in
            guard let page = pair[kIOHIDDeviceUsagePageKey] as? Int, let usage = pair[kIOHIDDeviceUsageKey] as? Int else {
                return nil
            }
            return (UInt32(truncatingIfNeeded: page), UInt32(truncatingIfNeeded: usage))
        }
    }

    private static func productID(_ device: IOHIDDevice) -> String {
        let id = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        return String(format: "0x%04x", id)
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
        if let finished { deliver { onReport?(finished) } }
        // Die Werte eines Berichts kommen hintereinander im selben Block der
        // Queue; ein Block danach schließt ihn ab.
        guard builder.pendingTimestamp != nil, !flushScheduled else { return }
        flushScheduled = true
        queue.async { [self] in
            flushScheduled = false
            if let report = builder.flush() { deliver { onReport?(report) } }
        }
    }
}
