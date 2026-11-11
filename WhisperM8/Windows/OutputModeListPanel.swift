import AppKit
import SwiftUI

/// Wo die Liste der Ausgabemodi steht: mittig über der Pill, mit kleinem
/// Abstand. Reicht der Platz über der Pill nicht (Pill ganz oben), steht sie
/// darunter. Seitlich bleibt sie im sichtbaren Bereich des Bildschirms. Pur.
enum OutputModeListPlacement {
    static let gap: CGFloat = 8

    static func frame(listSize: NSSize, pillFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        var x = pillFrame.midX - listSize.width / 2
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - listSize.width)
        var y = pillFrame.maxY + gap
        if y + listSize.height > visibleFrame.maxY {
            y = pillFrame.minY - gap - listSize.height
        }
        return NSRect(x: x, y: y, width: listSize.width, height: listSize.height)
    }
}

/// Eigenes kleines Panel für die Liste der Ausgabemodi. Bewusst getrennt vom
/// Pill-Panel: Das hat eine feste Größe, an der Treffer-Fläche, Position und
/// Speicherung des Ankers hängen. So bleibt die Pill, wo sie ist.
///
/// Nimmt keine Klicks an und wird nie Key — die Bedienung läuft über den
/// Controller.
@MainActor
final class OutputModeListPresenter {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OutputModeListView>?
    private var visibility = OutputModeListVisibility()
    private var hideWork: DispatchWorkItem?

    var isShown: Bool { panel?.isVisible == true }

    /// Zeigt die Liste über `pillFrame` (Bildschirm-Koordinaten) und plant das
    /// Ausblenden 1,5 s nach diesem Wechsel.
    func show(modes: [OutputMode], selectedID: String, pillFrame: NSRect) {
        guard !modes.isEmpty else { return }
        let view = OutputModeListView(modes: modes, selectedID: selectedID)
        let panel = self.panel ?? makePanel()
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            hostingView.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
        let size = hostingView?.fittingSize ?? .zero
        let screen = NSScreen.screens.first { $0.frame.intersects(pillFrame) } ?? NSScreen.main
        if let screen, size.width > 0 {
            panel.setFrame(
                OutputModeListPlacement.frame(listSize: size, pillFrame: pillFrame, visibleFrame: screen.visibleFrame),
                display: true
            )
        }
        panel.orderFrontRegardless()

        let now = ProcessInfo.processInfo.systemUptime
        visibility.noteChange(at: now)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.visibility.isVisible(at: ProcessInfo.processInfo.systemUptime) { self.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OutputModeListVisibility.hideDelay + 0.01, execute: work)
    }

    func hide() {
        visibility.recordingEnded()
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel
        return panel
    }
}
