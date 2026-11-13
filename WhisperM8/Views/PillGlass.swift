import SwiftUI

/// Dunkles Glas der Diktat-Pille (Prototyp `rgba(19,22,27,.86)`): Material
/// liefert den Blur, die Tönung drückt es Richtung Fast-Schwarz, dazu ein
/// feiner heller Rand. Gemeinsam genutzt von der Diktat-Pille, der Pille der
/// Notch-Anzeige auf Bildschirmen ohne Notch und der Controller-Insel dort —
/// alle drei sehen gleich aus. Die Form gibt der Aufrufer vor (Kapsel in
/// Ruhe, abgerundetes Rechteck für aufgeklappte Inhalte).
///
/// `unified`: Die Fläche gehört zur vereinten Pille (Status-Pille, Diktat
/// ohne Notch, Insel). Nur dann gilt die Einstellung „Tiefschwarzer
/// Hintergrund“ (`PillSurface`); die getrennte Diktat-Pille bleibt Glas.
struct PillGlassBackground<S: InsettableShape>: View {
    let shape: S
    var unified = false

    @ObservedObject private var appearance = PillAppearance.shared
    @Environment(\.pillSolidBlackOverride) private var solidBlackOverride

    var body: some View {
        switch PillSurface.resolve(unified: unified, solidBlack: solidBlackOverride ?? appearance.isSolidBlack) {
        case .glass:
            shape
                .fill(.thinMaterial)
                .overlay(shape.fill(OverlayPalette.glassTint))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        case .solidBlack:
            // Deckend wie die Notch. Der helle Haarstrich bleibt: Auf einem
            // dunklen Schreibtisch hielte sonst nichts den Umriss.
            shape
                .fill(Color.black)
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}

/// Wie eine Fläche der Pille gezeichnet wird. Die einzige Entscheidungsstelle
/// für Glas oder Schwarz; rein.
enum PillSurface: Equatable {
    case glass
    case solidBlack

    static func resolve(unified: Bool, solidBlack: Bool) -> PillSurface {
        unified && solidBlack ? .solidBlack : .glass
    }
}

/// Live-Wert der Einstellung „Tiefschwarzer Hintergrund“ für alle sichtbaren
/// Pillen: einmal gelesen, bei Änderungen der Preferences neu geprüft und nur
/// bei echtem Wechsel gemeldet. So liest kein Body die UserDefaults, und ein
/// Umschalten wirkt sofort, ohne Neustart. Gilt nur mit vereinter Pille
/// (Kill-Switch `unifiedPillEnabled`).
@MainActor
final class PillAppearance: ObservableObject {
    static let shared = PillAppearance()

    @Published private(set) var isSolidBlack: Bool

    private let read: () -> Bool
    private var observer: NSObjectProtocol?

    init(
        read: @escaping () -> Bool = { PillAppearance.isSolidBlack(.shared) },
        center: NotificationCenter = .default
    ) {
        self.read = read
        isSolidBlack = read()
        observer = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Schwarz nur, wenn die Einstellung an ist und die vereinte Pille läuft.
    nonisolated static func isSolidBlack(_ prefs: AppPreferences) -> Bool {
        prefs.isPillSolidBlackEnabled && prefs.isUnifiedPillEnabled
    }

    func refresh() {
        let value = read()
        if value != isSolidBlack { isSolidBlack = value }
    }
}

private struct PillSolidBlackOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Für Snapshots und Pixeltests: Schwarz fest an oder aus, statt der
    /// Einstellung zu folgen. `nil` (Standard) folgt `PillAppearance`.
    var pillSolidBlackOverride: Bool? {
        get { self[PillSolidBlackOverrideKey.self] }
        set { self[PillSolidBlackOverrideKey.self] = newValue }
    }
}

/// Maße und Schatten, die alle Pillen teilen.
enum PillGlass {
    /// Höhe der Pille in Ruhe (wie `PillMetrics.height` der Diktat-Pille).
    static let height: CGFloat = PillMetrics.height
    /// Eckenradius aufgeklappter Inhalte: so rund wie die halbe Pillenhöhe.
    static let cornerRadius: CGFloat = PillMetrics.height / 2
}

extension View {
    /// Schatten der Diktat-Pille. Braucht im Fenster Platz rundum (die
    /// Diktat-Pille hat dafür `OverlayFrameResolver.contentMargin`).
    func pillGlassShadow() -> some View {
        shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 3)
    }
}
