import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// ENTWURF (19.11.2026), nur Vorschau: die Controller-Insel an der
/// Kamera-Insel als große Form (Paket 2, noch nicht gebaut). Hinweis, Liste
/// und Diktat sind gebaut; ihre Bilder stammen aus den echten Ansichten
/// (`UISnapshotGallery+NotchIsland.swift`, `make snapshots ONLY=kamera-insel`).
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

    /// Hinweise zur Bedienung mit dem Controller: Zeichen der Taste, Wort.
    fileprivate static func padHint(_ glyph: String, _ word: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: glyph)
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Large.text)
                .frame(width: 22, height: 22).background { Circle().fill(Large.field) }
            Text(verbatim: word).font(.system(size: 12.5)).foregroundStyle(Large.secondary)
        }
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

    fileprivate static func controllerFixture(_ name: String, apple: AppleIsland) -> Fixture {
        let shape = CGSize(width: 460, height: 334)
        let size = CGSize(width: 900, height: shape.height + 70)
        return Fixture(name: "insel-gross-\(name)", size: size) {
            AnyView(LargeDesk(size: size, apple: apple) {
                LargeShell(width: shape.width, height: shape.height, apple: apple) {
                    HStack(spacing: 12) {
                        counter(Large.amber, 1, diamond: true)
                        counter(Large.green, 2)
                    }
                } trailing: {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 14)).foregroundStyle(Large.secondary)
                } content: {
                    controllerContent
                }
            })
        }
    }

    @MainActor
    static func islandLargeFixtures() -> [Fixture] {
        [
            controllerFixture("controller", apple: .empty),
            controllerFixture("controller-musik", apple: .music),
        ]
    }
}
