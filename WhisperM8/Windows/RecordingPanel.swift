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
            return NSSize(width: 590, height: 56)
        case .mini:
            return NSSize(width: 220, height: 46)
        }
    }
}

struct OverlayPositionStore {
    static let styleKey = "overlayStyle"
    static let xKey = "overlayPositionX"
    static let yKey = "overlayPositionY"
    static let defaultBottomOffset: CGFloat = 40

    static func loadStyle() -> OverlayStyle {
        let raw = AppPreferences.shared.overlayStyleRaw
        return OverlayStyle(rawValue: raw) ?? .full
    }

    static func savePosition(_ origin: NSPoint) {
        AppPreferences.shared.set(origin.x, for: xKey)
        AppPreferences.shared.set(origin.y, for: yKey)
    }

    static func clearPosition() {
        AppPreferences.shared.removeObject(for: xKey)
        AppPreferences.shared.removeObject(for: yKey)
    }

    static func loadPosition() -> NSPoint? {
        guard AppPreferences.shared.objectExists(for: xKey),
              AppPreferences.shared.objectExists(for: yKey) else {
            return nil
        }

        let x = AppPreferences.shared.double(for: xKey)
        let y = AppPreferences.shared.double(for: yKey)
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
        clamp(origin: origin, size: size, visibleFrame: screen.visibleFrame)
    }

    static func clamp(origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
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

/// Granulare Bearbeitungs-Aktion auf dem laufenden Recording-Kontext-Bundle.
/// Wird vom Overlay-Menu ausgelöst und vom RecordingCoordinator in die einzelnen
/// Bundle-Slots übersetzt.
enum ContextAction {
    case removeAgentChat
    case removeSelectedText
    case removeAttachment(id: UUID)
}

@MainActor
class OverlayController: ObservableObject {
    private var panel: RecordingPanel?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var previousApp: NSRunningApplication?
    private var modesObserver: NSObjectProtocol?
    private var onCancel: (() -> Void)?
    private var onCancelTranscription: (() -> Void)?
    private var onCancelPostProcessing: (() -> Void)?
    private var onOutputModeChange: ((OutputMode) -> Void)?
    private var onAddScreenshot: (() -> Void)?
    private var onToggleScreenClip: (() -> Void)?
    private var onClearContext: (() -> Void)?
    /// Vereinte Schiene für granulare Kontext-Bearbeitung pro Item.
    private var onContextAction: ((ContextAction) -> Void)?
    @Published var audioLevel: Float = 0
    @Published var duration: TimeInterval = 0
    @Published var isTranscribing: Bool = false
    @Published var isPostProcessing: Bool = false
    @Published var overlayStyle: OverlayStyle = .full
    @Published var selectedOutputMode: OutputMode = OutputMode.defaultMode()
    @Published var outputModes: [OutputMode] = OutputMode.enabledBuiltInModes
    @Published var showModePickerInMiniOverlay: Bool = true
    @Published var selectedContext: SelectedContext = .empty
    @Published var contextBundle: TranscriptContextBundle = .empty
    @Published var isScreenClipRecording: Bool = false
    @Published var postProcessingStatusText: String?

    func show(
        appState: AppState,
        onCancel: @escaping () -> Void,
        onCancelTranscription: @escaping () -> Void,
        onCancelPostProcessing: @escaping () -> Void,
        onOutputModeChange: @escaping (OutputMode) -> Void,
        onAddScreenshot: @escaping () -> Void,
        onToggleScreenClip: @escaping () -> Void,
        onClearContext: @escaping () -> Void,
        onContextAction: @escaping (ContextAction) -> Void
    ) {
        // Capture the frontmost app BEFORE showing our panel
        previousApp = NSWorkspace.shared.frontmostApplication
        Logger.focus.info("Captured previousApp: \(self.previousApp?.localizedName ?? "nil", privacy: .public)")

        hide()  // Cleanup any existing panel first
        self.onCancel = onCancel
        self.onCancelTranscription = onCancelTranscription
        self.onCancelPostProcessing = onCancelPostProcessing
        self.onOutputModeChange = onOutputModeChange
        self.onAddScreenshot = onAddScreenshot
        self.onToggleScreenClip = onToggleScreenClip
        self.onClearContext = onClearContext
        self.onContextAction = onContextAction

        // Initialize state from appState
        self.audioLevel = appState.audioLevel
        self.duration = appState.recordingDuration
        self.isTranscribing = appState.isTranscribing
        self.isPostProcessing = appState.isPostProcessing
        self.selectedOutputMode = appState.selectedOutputMode
        self.outputModes = OutputMode.enabledBuiltInModes
        self.showModePickerInMiniOverlay = AppPreferences.shared.showModePickerInMiniOverlay
        self.selectedContext = appState.selectedContext
        self.contextBundle = appState.contextBundle
        self.isScreenClipRecording = appState.isScreenClipRecording
        self.postProcessingStatusText = appState.postProcessingStatusText
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

        // Event-getriebener Mode-Reload statt Tick-Polling. show() ruft oben
        // hide() auf, das den alten Observer entfernt — re-entrantes show()
        // (z. B. Transkriptions-Retry) registriert also nie doppelt.
        modesObserver = NotificationCenter.default.addObserver(
            forName: OutputModeStore.modesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.outputModes = OutputMode.enabledBuiltInModes
            }
        }
    }

    func hide() {
        if let modesObserver {
            NotificationCenter.default.removeObserver(modesObserver)
            self.modesObserver = nil
        }
        if let origin = panel?.frame.origin {
            OverlayPositionStore.savePosition(origin)
        }
        panel?.close()
        panel = nil
        hostingView = nil
        onCancel = nil
        onCancelTranscription = nil
        onCancelPostProcessing = nil
        onOutputModeChange = nil
        onAddScreenshot = nil
        onToggleScreenClip = nil
        onClearContext = nil
        onContextAction = nil
    }

    func getPreviousApp() -> NSRunningApplication? {
        return previousApp
    }

    func cancelRecording() {
        onCancel?()
    }

    func cancelTranscription() {
        onCancelTranscription?()
    }

    func cancelPostProcessing() {
        onCancelPostProcessing?()
    }

    func setOutputMode(_ mode: OutputMode) {
        selectedOutputMode = mode
        onOutputModeChange?(mode)
    }

    func addScreenshot() {
        onAddScreenshot?()
    }

    func toggleScreenClip() {
        onToggleScreenClip?()
    }

    func clearContext() {
        onClearContext?()
    }

    func performContextAction(_ action: ContextAction) {
        onContextAction?(action)
    }

    func update(appState: AppState) {
        // Only update properties - view stays the same, SwiftUI handles animations.
        //
        // Tick-Diät: update() läuft im 100-ms-Timer. Volatile Felder werden
        // direkt gesetzt; alles andere nur bei echter Änderung, damit der
        // 10-Hz-Tick keinen objectWillChange-Churn im SwiftUI-Overlay erzeugt.
        // Der frühere OutputModeStore-Disk-Load pro Tick ist doppelt entschärft:
        // enabledBuiltInModes ist seit dem Stat-Cache billig, und der Guard
        // verhindert das Publish.
        self.audioLevel = appState.audioLevel
        self.duration = appState.recordingDuration
        setIfChanged(\.isTranscribing, to: appState.isTranscribing)
        setIfChanged(\.isPostProcessing, to: appState.isPostProcessing)
        setIfChanged(\.selectedOutputMode, to: appState.selectedOutputMode)
        setIfChanged(\.outputModes, to: OutputMode.enabledBuiltInModes)
        setIfChanged(\.showModePickerInMiniOverlay, to: AppPreferences.shared.showModePickerInMiniOverlay)
        setIfChanged(\.selectedContext, to: appState.selectedContext)
        setIfChanged(\.contextBundle, to: appState.contextBundle)
        setIfChanged(\.isScreenClipRecording, to: appState.isScreenClipRecording)
        setIfChanged(\.postProcessingStatusText, to: appState.postProcessingStatusText)

        let latestStyle = OverlayPositionStore.loadStyle()
        if latestStyle != overlayStyle {
            overlayStyle = latestStyle
            applyCurrentStyleToPanel()
        }
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<OverlayController, Value>,
        to newValue: Value
    ) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
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
