import AppKit
import SwiftUI

class RecordingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isOpaque = false

        positionAtBottomCenter()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + 40
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func updateContent(with view: some View) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 56)
        self.contentView = hostingView
    }
}

// MARK: - Overlay Controller

class OverlayController: ObservableObject {
    private var panel: RecordingPanel?
    @Published var audioLevel: Float = 0
    @Published var duration: TimeInterval = 0
    @Published var isTranscribing: Bool = false

    func show(appState: AppState) {
        hide()  // Cleanup any existing panel first

        // Initialize state from appState
        self.audioLevel = appState.audioLevel
        self.duration = appState.recordingDuration
        self.isTranscribing = appState.isTranscribing

        let panel = RecordingPanel()

        // Create view with bindings (ONCE) - view will update via bindings
        let view = RecordingOverlayView(
            audioLevel: Binding(get: { self.audioLevel }, set: { self.audioLevel = $0 }),
            duration: Binding(get: { self.duration }, set: { self.duration = $0 }),
            isTranscribing: Binding(get: { self.isTranscribing }, set: { self.isTranscribing = $0 })
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 56)
        panel.contentView = hostingView
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    func update(appState: AppState) {
        // Only update properties - view stays the same, SwiftUI handles animations
        self.audioLevel = appState.audioLevel
        self.duration = appState.recordingDuration
        self.isTranscribing = appState.isTranscribing
    }
}
