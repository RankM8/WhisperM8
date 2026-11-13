import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Snapshot-Fixtures des Übergangs zwischen ruhender Pille und Diktat
/// (`UnifiedPillMorph`): Schlüsselbilder Ruhe, Mitte, Diktat, ohne Notch und
/// an der Notch. Das mittlere Bild ist echt: Die Ansicht wird umgeschaltet
/// und nach der halben Animationsdauer abfotografiert.
extension UISnapshotGallery {
    private static var morphSummary: NotchSummary { NotchSummary(working: 2, waiting: 1) }

    /// Schreibtisch hinter der Pille, hell bzw. dunkel; an der Notch oben ein
    /// schwarzer Streifen als Hardware-Aussparung.
    private struct MorphDesk<Content: View>: View {
        @Environment(\.colorScheme) private var scheme
        var notch: CGSize?
        @ViewBuilder let content: Content

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.13, green: 0.15, blue: 0.20), Color(red: 0.22, green: 0.18, blue: 0.20)]
                        : [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.96, green: 0.89, blue: 0.80)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                if let notch {
                    // Menüleiste mit Aussparung.
                    Rectangle().fill(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
                        .frame(height: notch.height)
                    Rectangle().fill(Color.black).frame(width: notch.width, height: notch.height)
                }
                // Eigener Rahmen wie das Fenster: Die Ausrichtungslinie der
                // Pille (`centerGuide`) wirkt sonst bis in diesen Stapel.
                GeometryReader { _ in content }
            }
        }
    }

    /// Diktat-Pille im Ruhebild bzw. im Diktat, so verankert wie im Fenster
    /// (`RecordingOverlayView`: Mitte bzw. an der Notch oben).
    @MainActor
    static func morphController(notch: OverlayPresentation?, rest: UnifiedPillRestLook?) -> OverlayController {
        dictationPillController {
            $0.presentation = notch ?? .pill
            // Wie im Fenster der vereinten Pille: Wachsen um die Mitte.
            $0.pillAlignment = .center
            $0.levelModel.level = 0.45
            $0.restLook = rest
            $0.showsRestLook = rest != nil
        }
    }

    @MainActor
    static func pillMorphFixtures() -> [Fixture] {
        let pillSize = CGSize(width: 520, height: 88)
        let notchSize = CGSize(width: 520, height: 112)
        let notch = OverlayPresentation.notch(width: 185, height: 32)
        let notchRest = UnifiedPillRestLook.notch(summary: morphSummary, alert: nil, bodyWidth: 185)

        func frame(_ name: String, notch presentation: OverlayPresentation?, rest: UnifiedPillRestLook?,
                   midway: Bool = false) -> Fixture {
            let size = presentation == nil ? pillSize : notchSize
            return Fixture(name: "uebergang-\(name)", size: size) {
                let controller = morphController(notch: presentation, rest: rest)
                let deskNotch: CGSize? = {
                    if case .notch(let width, let height) = presentation { return CGSize(width: width, height: height) }
                    return nil
                }()
                return AnyView(MorphDesk(notch: deskNotch) {
                    RecordingOverlayView(controller: controller)
                        .environment(\.colorScheme, .dark)
                        .onAppear {
                            guard midway else { return }
                            // Echtes Zwischenbild: nach dem ersten Bild ins
                            // Diktat umschalten, der Renderer fotografiert
                            // mitten in der Animation.
                            DispatchQueue.main.asyncAfter(deadline: .now() + morphMidwayDelay) {
                                controller.showsRestLook = false
                            }
                        }
                })
            }
        }

        return [
            frame("ruhe", notch: nil, rest: .pill(summary: morphSummary, alert: nil)),
            frame("mitte", notch: nil, rest: .pill(summary: morphSummary, alert: nil), midway: true),
            frame("diktat", notch: nil, rest: nil),
            frame("notch-band", notch: notch, rest: .notchBand),
            frame("notch-band-mitte", notch: notch, rest: .notchBand, midway: true),
            frame("notch-zaehler", notch: notch, rest: notchRest),
            frame("notch-zaehler-mitte", notch: notch, rest: notchRest, midway: true),
            frame("notch-diktat", notch: notch, rest: nil),
        ]
    }

    /// Umschalten so, dass der Renderer (Ruhezeit 0,15 s) etwa bei der Hälfte
    /// der 0,35-s-Animation fotografiert.
    static let morphMidwayDelay: TimeInterval = 0.02
}
