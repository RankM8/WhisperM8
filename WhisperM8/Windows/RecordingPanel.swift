import AppKit
import SwiftUI

enum OverlayStyle: String, CaseIterable {
    case full
    case mini

    var displayName: String {
        switch self {
        case .full:
            return "Full"
        case .mini:
            return "Mini"
        }
    }

    var panelSize: NSSize {
        switch self {
        case .full:
            return NSSize(width: 300, height: 56)
        case .mini:
            return NSSize(width: 124, height: 46)
        }
    }
}

struct OverlayPositionStore {
    static let styleKey = "overlayStyle"
    static let xKey = "overlayPositionX"
    static let yKey = "overlayPositionY"
    static let defaultBottomOffset: CGFloat = 40

    static func loadStyle() -> OverlayStyle {
        let raw = UserDefaults.standard.string(forKey: styleKey) ?? OverlayStyle.full.rawValue
        return OverlayStyle(rawValue: raw) ?? .full
    }

    static func savePosition(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: xKey)
        UserDefaults.standard.set(origin.y, forKey: yKey)
    }

    static func clearPosition() {
        UserDefaults.standard.removeObject(forKey: xKey)
        UserDefaults.standard.removeObject(forKey: yKey)
    }

    static func loadPosition() -> NSPoint? {
        let defaults = UserDefaults.standard

        guard defaults.object(forKey: xKey) != nil, defaults.object(forKey: yKey) != nil else {
            return nil
        }

        let x = defaults.double(forKey: xKey)
        let y = defaults.double(forKey: yKey)
        guard x.isFinite, y.isFinite else { return nil }

        return NSPoint(x: x, y: y)
    }

    static func resolveInitialOrigin(for style: OverlayStyle) -> NSPoint {
        let size = style.panelSize
        guard let activeScreen else { return .zero }

        guard let storedOrigin = loadPosition() else {
            return defaultOrigin(size: size, on: activeScreen)
        }

        guard let storedScreen = screenContainingRect(origin: storedOrigin, size: size) else {
            return defaultOrigin(size: size, on: activeScreen)
        }

        return clamp(origin: storedOrigin, size: size, on: storedScreen)
    }

    static var activeScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    static func screenContainingRect(origin: NSPoint, size: NSSize) -> NSScreen? {
        let rect = NSRect(origin: origin, size: size)
        return NSScreen.screens.first { screen in
            !screen.frame.intersection(rect).isEmpty
        }
    }

    static func defaultOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let visibleFrame = screen.visibleFrame
        let defaultPoint = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + defaultBottomOffset
        )
        return clamp(origin: defaultPoint, size: size, on: screen)
    }

    static func clamp(origin: NSPoint, size: NSSize, on screen: NSScreen) -> NSPoint {
        let visibleFrame = screen.visibleFrame

        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)

        let clampedX = min(max(origin.x, visibleFrame.minX), maxX)
        let clampedY = min(max(origin.y, visibleFrame.minY), maxY)

        return NSPoint(x: clampedX, y: clampedY)
    }
}

class RecordingPanel: NSPanel, NSWindowDelegate {
    var onMove: ((NSPoint) -> Void)?
    private var suppressMoveCallback = false

    init(style: OverlayStyle, initialOrigin: NSPoint) {
        super.init(
            contentRect: NSRect(origin: initialOrigin, size: style.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.hasShadow = false  // Disable window shadow - SwiftUI view has its own
        self.isOpaque = false
        self.delegate = self

        apply(style: style, preferredOrigin: initialOrigin)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(style: OverlayStyle, preferredOrigin: NSPoint? = nil) {
        let size = style.panelSize
        let baseOrigin = preferredOrigin ?? frame.origin

        guard let screen = OverlayPositionStore.screenContainingRect(origin: baseOrigin, size: size)
                ?? OverlayPositionStore.activeScreen else {
            return
        }

        let origin = OverlayPositionStore.clamp(origin: baseOrigin, size: size, on: screen)
        let updatedFrame = NSRect(origin: origin, size: size)

        suppressMoveCallback = true
        setFrame(updatedFrame, display: true)
        suppressMoveCallback = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !suppressMoveCallback else { return }

        let currentOrigin = frame.origin
        let currentSize = frame.size

        guard let screen = OverlayPositionStore.screenContainingRect(origin: currentOrigin, size: currentSize)
                ?? OverlayPositionStore.activeScreen else {
            onMove?(currentOrigin)
            return
        }

        let clampedOrigin = OverlayPositionStore.clamp(origin: currentOrigin, size: currentSize, on: screen)
        if clampedOrigin != currentOrigin {
            suppressMoveCallback = true
            setFrameOrigin(clampedOrigin)
            suppressMoveCallback = false
        }

        onMove?(clampedOrigin)
    }
}

// MARK: - Overlay Controller

class OverlayController: ObservableObject {
    private var panel: RecordingPanel?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var previousApp: NSRunningApplication?
    @Published var audioLevel: Float = 0
    @Published var duration: TimeInterval = 0
    @Published var isTranscribing: Bool = false
    @Published var overlayStyle: OverlayStyle = .full

    func show(appState: AppState) {
        // Capture the frontmost app BEFORE showing our panel
        previousApp = NSWorkspace.shared.frontmostApplication
        Logger.focus.info("Captured previousApp: \(self.previousApp?.localizedName ?? "nil", privacy: .public)")

        hide()  // Cleanup any existing panel first

        // Initialize state from appState
        self.audioLevel = appState.audioLevel
        self.duration = appState.recordingDuration
        self.isTranscribing = appState.isTranscribing
        self.overlayStyle = OverlayPositionStore.loadStyle()

        let initialOrigin = OverlayPositionStore.resolveInitialOrigin(for: overlayStyle)
        let panel = RecordingPanel(style: overlayStyle, initialOrigin: initialOrigin)
        panel.onMove = { origin in
            OverlayPositionStore.savePosition(origin)
        }

        // Create view with bindings (ONCE) - view will update via bindings
        let view = RecordingOverlayView(controller: self)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: overlayStyle.panelSize)

        // Configure hosting view for full transparency
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.contentView = hostingView
        panel.orderFront(nil)
        self.panel = panel
        self.hostingView = hostingView
    }

    func hide() {
        if let origin = panel?.frame.origin {
            OverlayPositionStore.savePosition(origin)
        }
        panel?.close()
        panel = nil
        hostingView = nil
    }

    func getPreviousApp() -> NSRunningApplication? {
        return previousApp
    }

    func update(appState: AppState) {
        // Only update properties - view stays the same, SwiftUI handles animations
        self.audioLevel = appState.audioLevel
        self.duration = appState.recordingDuration
        self.isTranscribing = appState.isTranscribing

        let latestStyle = OverlayPositionStore.loadStyle()
        if latestStyle != overlayStyle {
            overlayStyle = latestStyle
            applyCurrentStyleToPanel()
        }
    }

    private func applyCurrentStyleToPanel() {
        guard let panel else { return }

        let newSize = overlayStyle.panelSize
        hostingView?.frame = NSRect(origin: .zero, size: newSize)
        panel.apply(style: overlayStyle)
        OverlayPositionStore.savePosition(panel.frame.origin)
    }
}
