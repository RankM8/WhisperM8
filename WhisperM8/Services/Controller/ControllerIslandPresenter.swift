import AppKit
import SwiftUI

/// Wert, den die Hosting-View der Insel beobachtet.
@MainActor
final class ControllerIslandViewModel: ObservableObject {
    @Published var display: ControllerIslandDisplay?
    @Published var revealed = false
}

private struct ControllerIslandHostView: View {
    @ObservedObject var model: ControllerIslandViewModel

    var body: some View {
        if let display = model.display {
            ControllerIslandView(display: display, revealed: model.revealed)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
    }
}

/// Lage der Insel in globalen Cocoa-Koordinaten. Pur, damit ohne Bildschirm
/// testbar: Mit Notch liegt oben das Band genau in der Aussparung und der
/// Körper hängt mittig darunter (wie `NotchGeometry.layout`); ohne Notch sitzt
/// die Pille mittig unter der Menüleiste, an derselben Stelle wie die Pille
/// der Notch-Anzeige.
enum ControllerIslandGeometry {
    static func frame(screen: NotchScreenInfo, bodySize: CGSize) -> CGRect {
        if screen.hasNotch {
            // `bodySize` enthält das Band schon (die Ansicht zeichnet es mit).
            return CGRect(
                x: screen.notchCenterX - bodySize.width / 2, y: screen.frame.maxY - bodySize.height,
                width: bodySize.width, height: bodySize.height)
        }
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let top = screen.frame.maxY - (menuBar > 0 ? menuBar : NotchGeometry.fallbackMenuBarHeight)
            - NotchGeometry.pillTopGap
        return CGRect(
            x: screen.frame.midX - bodySize.width / 2, y: top - bodySize.height,
            width: bodySize.width, height: bodySize.height)
    }

    static func style(for screen: NotchScreenInfo) -> ControllerIslandDisplay.Style {
        screen.hasNotch ? .notch(width: screen.notchWidth, height: screen.safeAreaTop) : .pill
    }
}

/// Fenster der Controller-Insel: einmal aufgebaut, danach nur ein- und
/// ausgeblendet. Nicht aktivierend und ohne Maus (bedient wird sie nur mit
/// dem Controller). Es liegt eine Ebene über der Notch-Anzeige mit derselben
/// Band-Geometrie: Steht die Notch-Anzeige auf diesem Bildschirm, wächst die
/// Insel aus ihr heraus und überdeckt sie, ihre Zähler stehen solange rechts
/// im Kopf. Die Notch-Anzeige selbst bleibt unverändert.
@MainActor
final class ControllerIslandPresenter: ControllerIslandPresenting {
    static let shared = ControllerIslandPresenter()

    /// Auf- und Zuklappen; eine Bewegung je Richtung, sonst nichts.
    static let animationDuration: TimeInterval = 0.25

    private let viewModel = ControllerIslandViewModel()
    private var panel: NotchPanel?
    /// Misst die Höhe; eine eigene Ansicht, weil die sichtbare erst im
    /// nächsten Durchlauf den neuen Wert zeichnet.
    private var measuringHost: NSHostingView<ControllerIslandView>?
    private var lastFrame: CGRect?
    /// Zählt Schließ-Vorgänge, damit ein spätes `orderOut` eine neu
    /// geöffnete Insel nicht trifft.
    private var generation = 0

    func show(_ model: ControllerIslandModel, screenDisplayID: UInt32?) {
        guard let screen = Self.screen(displayID: screenDisplayID) else { return }
        var counts: ControllerIslandCounts?
        if let summary = NotchStatusController.shared.visibleSummary(onDisplay: screen.displayID) {
            counts = ControllerIslandCounts(working: summary.working, waiting: summary.waiting)
            // Eine aufgeklappte Liste der Notch-Anzeige ragte unter der Insel hervor.
            NotchStatusController.shared.collapse()
        }
        let display = ControllerIslandDisplay(
            style: ControllerIslandGeometry.style(for: screen), model: model, counts: counts)
        let panel = ensurePanel()
        let wasShown = panel.isVisible && viewModel.revealed
        generation += 1
        if viewModel.display != display { viewModel.display = display }
        let frame = ControllerIslandGeometry.frame(screen: screen, bodySize: measure(display))
        if frame != lastFrame {
            lastFrame = frame
            panel.setFrame(frame, display: true)
        }
        guard !wasShown else { return }
        panel.sharingType = AppPreferences.shared.isNotchStatusHiddenFromCapture ? .none : .readOnly
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            viewModel.revealed = true
            panel.orderFrontRegardless()
            return
        }
        viewModel.revealed = false
        panel.orderFrontRegardless()
        // Erst im nächsten Durchlauf aufklappen, sonst sieht SwiftUI keinen
        // Ausgangszustand und es gäbe keine Bewegung.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewModel.display != nil else { return }
            withAnimation(.timingCurve(0.2, 0.9, 0.25, 1.05, duration: Self.animationDuration)) {
                self.viewModel.revealed = true
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let current = generation
        let close = { [weak self] in
            guard let self, self.generation == current else { return }
            panel.orderOut(nil)
            self.viewModel.display = nil
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            viewModel.revealed = false
            return close()
        }
        withAnimation(.easeIn(duration: Self.animationDuration * 0.8)) { viewModel.revealed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration, execute: close)
    }

    /// Höhe aus der Ansicht selbst (feste Breite je Zustand), damit Fenster
    /// und Inhalt nie auseinanderlaufen.
    private func measure(_ display: ControllerIslandDisplay) -> CGSize {
        let measuring: NSHostingView<ControllerIslandView>
        if let measuringHost {
            measuring = measuringHost
            measuring.rootView = ControllerIslandView(display: display)
        } else {
            measuring = NSHostingView(rootView: ControllerIslandView(display: display))
            measuringHost = measuring
        }
        return CGSize(width: display.bodyWidth, height: max(40, measuring.fittingSize.height))
    }

    private func ensurePanel() -> NotchPanel {
        if let panel { return panel }
        let panel = NotchPanel()
        // Über der Notch-Anzeige (`mainMenu + 3`), damit die Insel sie überdeckt.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let host = NSHostingView(rootView: ControllerIslandHostView(model: viewModel))
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Bildschirm des Agent-Chats-Fensters; ohne Angabe der mit der Menüleiste.
    private static func screen(displayID: UInt32?) -> NotchScreenInfo? {
        let screens = NSScreen.screens.compactMap(NotchScreenInfo.init(screen:))
        if let displayID, let match = screens.first(where: { $0.displayID == displayID }) { return match }
        return screens.first { $0.displayID == CGMainDisplayID() } ?? screens.first
    }
}
