import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// ENTWURF (19.11.2026), nur Vorschau: die aufgeklappte Anzeige an der
/// Kamera-Insel als EINE Form ohne Hals, wie Apples eigene aufgeklappte
/// Insel. Die echte Anzeige ist unverändert, bis der Entwurf abgenommen ist.
///
/// Maße nach Apples Insel auf einem MacBook Pro mit Kamera-Insel (gemessen
/// am Bildschirmfoto von „Now Playing“, macOS 27.2.1): 286 × 152 pt, 6 pt
/// unter der Oberkante, Ecken rund 36 pt, Innenabstand 16 pt, Inhalt beginnt
/// unter der Zeile mit der Kamera. Apples Insel liegt immer über unseren
/// Fenstern; was sie zeigt (Musik, Mikrofon), steht deshalb oben in der Mitte
/// unserer Form, unser Inhalt beginnt darunter und links und rechts davon.
extension UISnapshotGallery {
    // MARK: Maße des Entwurfs

    fileprivate enum Large {
        /// Abstand der Form zur Oberkante: wie Apples aktive Insel.
        static let top: CGFloat = 6
        static let radius: CGFloat = 36
        static let padding: CGFloat = 18
        /// Kopfzeile: Höhe von Apples Insel (34 pt) plus Luft darunter.
        static let header: CGFloat = 42
        static let menuBar: CGFloat = 45
        static let restIsland = CGSize(width: 65, height: 32)
        static let activeIsland = CGSize(width: 143, height: 34)
        static let green = Color(red: 0.298, green: 0.765, blue: 0.541)
        static let amber = Color(red: 0.914, green: 0.725, blue: 0.286)
        static let red = Color(red: 0.898, green: 0.349, blue: 0.310)
        static let text = Color.white.opacity(0.94)
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.42)
        static let field = Color.white.opacity(0.09)
    }

    /// Was Apples Insel gerade zeigt.
    fileprivate enum AppleIsland {
        case empty, music, microphone

        var size: CGSize { self == .empty ? Large.restIsland : Large.activeIsland }
    }

    // MARK: Schreibtisch

    /// Schreibtisch mit Menüleiste. Apples Insel wird zuletzt gezeichnet,
    /// über allem: So legt macOS sie über jedes Fenster.
    fileprivate struct LargeDesk<Content: View>: View {
        @Environment(\.colorScheme) private var scheme
        let size: CGSize
        var apple: AppleIsland = .empty
        @ViewBuilder let content: Content

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.13, green: 0.15, blue: 0.20), Color(red: 0.22, green: 0.18, blue: 0.20)]
                        : [Color(red: 0.80, green: 0.84, blue: 0.93), Color(red: 0.93, green: 0.86, blue: 0.82)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    ZStack {
                        Rectangle().fill(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
                        menuBarItems
                    }
                    .frame(height: Large.menuBar)
                    Spacer(minLength: 0)
                }
                content.padding(.top, Large.top)
                appleIsland
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }

        private var menuBarItems: some View {
            HStack(spacing: 14) {
                Image(systemName: "apple.logo")
                Text(verbatim: "Safari").fontWeight(.bold)
                Text(verbatim: "File")
                Text(verbatim: "Edit")
                Text(verbatim: "View")
                Text(verbatim: "History")
                Spacer(minLength: 0)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(verbatim: "Do. 19. Nov. 9:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 16)
        }

        @ViewBuilder
        private var appleIsland: some View {
            let islandSize = apple.size
            Capsule()
                .fill(Color.black)
                .overlay { Capsule().strokeBorder(Color.white.opacity(apple == .empty ? 0 : 0.10), lineWidth: 1) }
                .overlay { Circle().fill(Color(white: 0.16)).frame(width: 7, height: 7) }
                .overlay {
                    switch apple {
                    case .empty:
                        EmptyView()
                    case .music:
                        HStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(colors: [.teal, .indigo], startPoint: .top, endPoint: .bottom))
                                .frame(width: 22, height: 14)
                            Spacer()
                            HStack(spacing: 2) {
                                ForEach(Array([6, 11, 15, 9, 13, 7].enumerated()), id: \.offset) { _, height in
                                    Capsule().fill(Color.white.opacity(0.55)).frame(width: 2, height: CGFloat(height))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    case .microphone:
                        HStack(spacing: 10) {
                            Spacer()
                            Circle().fill(Color.orange).frame(width: 5, height: 5)
                            Image(systemName: "mic.fill").font(.system(size: 12)).foregroundStyle(Color.orange)
                        }
                        .padding(.trailing, 16)
                    }
                }
                .frame(width: islandSize.width, height: islandSize.height)
                .padding(.top, apple == .empty ? 8 : Large.top)
        }
    }

    // MARK: Die große Form

    /// EINE schwarze Fläche mit sehr runden Ecken, auf die Kamera zentriert.
    /// `progress`: Stufe der Animation (0 = Apples Insel, 1 = ganz offen);
    /// der Inhalt erscheint erst, wenn die Form steht.
    fileprivate struct LargeShell<Leading: View, Trailing: View, Content: View>: View {
        let width: CGFloat
        let height: CGFloat
        var apple: AppleIsland = .empty
        var progress: CGFloat = 1
        @ViewBuilder let leading: Leading
        @ViewBuilder let trailing: Trailing
        @ViewBuilder let content: Content

        var body: some View {
            let start = apple.size
            let shownWidth = start.width + (width - start.width) * progress
            let shownHeight = start.height + (height - start.height) * progress
            VStack(spacing: 0) {
                // Kopfzeile: in der Mitte der Platz von Apples Insel, links
                // und rechts davon unser eigener Kopf.
                HStack(spacing: 0) {
                    leading.frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: start.width + 16)
                    trailing.frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, Large.padding)
                .frame(height: Large.header)
                content
                    .padding(.horizontal, Large.padding)
                    .padding(.bottom, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: width, height: height)
            .opacity(progress >= 1 ? 1 : 0)
            .frame(width: shownWidth, height: shownHeight, alignment: .top)
            .background { RoundedRectangle(cornerRadius: min(Large.radius, shownHeight / 2), style: .continuous).fill(Color.black) }
            .clipShape(RoundedRectangle(cornerRadius: min(Large.radius, shownHeight / 2), style: .continuous))
            .environment(\.colorScheme, .dark)
        }
    }

    // MARK: Bausteine

    fileprivate struct LargeDot: View {
        let color: Color
        var diamond = false
        var size: CGFloat = 10

        var body: some View {
            Group {
                if diamond {
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: size * 0.8, height: size * 0.8)
                        .rotationEffect(.degrees(45))
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: size, height: size)
        }
    }

    fileprivate static func counter(_ color: Color, _ count: Int, diamond: Bool = false) -> some View {
        HStack(spacing: 6) {
            LargeDot(color: color, diamond: diamond, size: 9)
            Text(verbatim: "\(count)").font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
    }

    fileprivate struct LargeRow: View {
        let color: Color
        var diamond = false
        let title: String
        let detail: String
        let state: String
        var highlighted = false
        var selected = false

        var body: some View {
            HStack(spacing: 12) {
                LargeDot(color: color, diamond: diamond)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Large.text)
                    Text(verbatim: detail).font(.system(size: 12.5)).foregroundStyle(Large.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: state).font(.system(size: 12.5)).foregroundStyle(Large.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.16) : (highlighted ? Large.amber.opacity(0.13) : Color.clear))
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.7), lineWidth: 2)
                }
            }
        }
    }

    fileprivate static func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 11.5, weight: .semibold)).tracking(0.7).foregroundStyle(Large.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14).padding(.top, 10).padding(.bottom, 2)
    }

    /// Hinweise zur Bedienung mit dem Controller: Zeichen der Taste, Wort.
    fileprivate static func padHint(_ glyph: String, _ word: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: glyph)
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Large.text)
                .frame(width: 22, height: 22).background { Circle().fill(Large.field) }
            Text(verbatim: word).font(.system(size: 12.5)).foregroundStyle(Large.secondary)
        }
    }

    fileprivate static func roundButton(_ symbol: String, fill: Color, tint: Color = .white, size: CGFloat = 44) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(tint)
            .frame(width: size, height: size).background { Circle().fill(fill) }
    }

    // MARK: Inhalte

    @ViewBuilder
    fileprivate static var listContent: some View {
        VStack(spacing: 2) {
            sectionTitle("Needs you")
            LargeRow(color: Large.amber, diamond: true, title: "Chat A", detail: "Approval: Bash", state: "Waiting · 2 min", highlighted: true)
            sectionTitle("Working")
            LargeRow(color: Large.green, title: "Chat B", detail: "› writing reply", state: "Working · 5 min")
            LargeRow(color: Large.green, title: "Chat C", detail: "› Edit Store.swift", state: "Working · 1 min")
            sectionTitle("Just finished")
            LargeRow(color: Large.tertiary, title: "Chat D", detail: "All findings addressed.", state: "Ready · 4 min ago")
            Spacer(minLength: 6)
            HStack {
                Label { Text(verbatim: "Turn off") } icon: { Image(systemName: "power") }
                Spacer()
                Text(verbatim: "Esc closes")
            }
            .font(.system(size: 12)).foregroundStyle(Large.tertiary).padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    fileprivate static var alertContent: some View {
        HStack(spacing: 12) {
            LargeDot(color: Large.amber, diamond: true, size: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Chat A").font(.system(size: 16, weight: .semibold)).foregroundStyle(Large.text)
                Text(verbatim: "Approval: Bash").font(.system(size: 13)).foregroundStyle(Large.secondary)
            }
            Spacer()
            Text(verbatim: "waiting for you").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Large.amber)
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    fileprivate static var dictationContent: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    ForEach(Array([10, 18, 26, 34, 22, 30, 38, 24, 14, 28, 36, 20, 12, 24, 32, 18, 10, 22, 30, 16].enumerated()), id: \.offset) { index, height in
                        Capsule().fill(index % 5 == 2 ? Large.amber : Large.green).frame(width: 4, height: CGFloat(height))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                Text(verbatim: "00:27")
                    .font(.system(size: 24, weight: .medium, design: .monospaced)).foregroundStyle(Large.text)
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(verbatim: "Fast").font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Large.text).padding(.horizontal, 16).frame(height: 44)
                .background { Capsule().fill(Large.field) }
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft").font(.system(size: 12, weight: .semibold))
                    Text(verbatim: "Context").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(Large.secondary).padding(.horizontal, 16).frame(height: 44)
                .background { Capsule().fill(Large.field) }
                roundButton("camera.viewfinder", fill: Large.field, tint: Large.secondary)
                Spacer(minLength: 0)
                roundButton("xmark", fill: Color.white.opacity(0.16))
                roundButton("checkmark", fill: Large.green, tint: .black)
            }
        }
        .padding(.top, 6)
    }

    /// Controller: große Felder in zwei Spalten, die Auswahl klar umrandet,
    /// unten die Tasten. Steuerkreuz bewegt, Kreuz öffnet, Kreis schließt.
    @ViewBuilder
    fileprivate static var controllerContent: some View {
        VStack(spacing: 10) {
            Text(verbatim: "Where to?")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Large.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    tile("Chat A", "Waiting for you", Large.amber, diamond: true, selected: true)
                    tile("Chat B", "Working", Large.green)
                }
                GridRow {
                    tile("Chat C", "Working", Large.green)
                    tile("Chat D", "Ready", Large.tertiary)
                }
                GridRow {
                    tile("New chat", "Project A", Large.tertiary, symbol: "plus")
                    tile("Dictate", "Into Chat A", Large.green, symbol: "mic.fill")
                }
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "dpad").font(.system(size: 15)).foregroundStyle(Large.text)
                    Text(verbatim: "Move").font(.system(size: 12.5)).foregroundStyle(Large.secondary)
                }
                padHint("✕", "Open")
                padHint("△", "Next waiting")
                Spacer()
                padHint("○", "Close")
            }
            .padding(.horizontal, 6).padding(.top, 2)
        }
    }

    fileprivate static func tile(
        _ title: String, _ detail: String, _ color: Color, diamond: Bool = false, symbol: String? = nil, selected: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Large.text)
                    .frame(width: 30, height: 30).background { Circle().fill(Large.field) }
            } else {
                LargeDot(color: color, diamond: diamond, size: 12).frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Large.text)
                Text(verbatim: detail).font(.system(size: 12.5)).foregroundStyle(Large.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(selected ? Color.white.opacity(0.18) : Large.field)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.85), lineWidth: 2.5)
            }
        }
    }

    // MARK: Fixtures

    fileprivate enum LargeKind { case list, alert, dictation, controller }

    fileprivate static func largeFixture(
        _ name: String, _ kind: LargeKind, apple: AppleIsland, progress: CGFloat = 1
    ) -> Fixture {
        let shape: (width: CGFloat, height: CGFloat)
        switch kind {
        case .list: shape = (420, 392)
        case .alert: shape = (380, 108)
        case .dictation: shape = (420, 178)
        case .controller: shape = (460, 334)
        }
        let size = CGSize(width: 900, height: max(200, shape.height + 70))
        return Fixture(name: "insel-gross-\(name)", size: size) {
            AnyView(LargeDesk(size: size, apple: apple) {
                LargeShell(width: shape.width, height: shape.height, apple: apple, progress: progress) {
                    // Kopf links: die Zähler, wie bisher über der Liste.
                    HStack(spacing: 12) {
                        counter(Large.amber, 1, diamond: true)
                        counter(Large.green, 2)
                    }
                } trailing: {
                    switch kind {
                    case .list, .alert:
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            Text(verbatim: "1").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        }
                        .foregroundStyle(Large.secondary)
                    case .dictation:
                        Text(verbatim: "Recording").font(.system(size: 13, weight: .medium)).foregroundStyle(Large.secondary)
                    case .controller:
                        Image(systemName: "gamecontroller.fill").font(.system(size: 14)).foregroundStyle(Large.secondary)
                    }
                } content: {
                    switch kind {
                    case .list: listContent
                    case .alert: alertContent
                    case .dictation: dictationContent
                    case .controller: controllerContent
                    }
                }
            })
        }
    }

    @MainActor
    static func islandLargeFixtures() -> [Fixture] {
        [
            largeFixture("liste", .list, apple: .empty),
            largeFixture("liste-musik", .list, apple: .music),
            largeFixture("hinweis", .alert, apple: .empty),
            largeFixture("hinweis-musik", .alert, apple: .music),
            largeFixture("diktat", .dictation, apple: .microphone),
            largeFixture("controller", .controller, apple: .empty),
            largeFixture("controller-musik", .controller, apple: .music),
            // Animation in drei Stufen: Apples Insel, halb offen, ganz offen.
            largeFixture("animation-1-klein", .list, apple: .music, progress: 0),
            largeFixture("animation-2-halb", .list, apple: .music, progress: 0.5),
            largeFixture("animation-3-gross", .list, apple: .music, progress: 1),
        ]
    }
}
