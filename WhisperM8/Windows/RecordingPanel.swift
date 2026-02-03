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

class OverlayController {
    private var panel: RecordingPanel?

    func show(appState: AppState) {
        let panel = RecordingPanel()
        let view = RecordingOverlayView(
            audioLevel: appState.audioLevel,
            duration: appState.recordingDuration,
            isTranscribing: appState.isTranscribing
        )
        panel.updateContent(with: view)
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    func update(appState: AppState) {
        guard let panel else { return }
        let view = RecordingOverlayView(
            audioLevel: appState.audioLevel,
            duration: appState.recordingDuration,
            isTranscribing: appState.isTranscribing
        )
        panel.updateContent(with: view)
    }
}
