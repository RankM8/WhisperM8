import SwiftUI

/// Marke „Wo arbeitet der Chat?“ (WM8-60): ein Chip mit Ort und Branch.
/// Hauptordner leise grau mit Ordner-Symbol und nur dem Branch (der Name
/// „Hauptordner“ stünde sonst neben „main“-Konto und „main“-Branch dreifach),
/// Arbeitskopie farbig mit Kopie-Symbol, Name und Branch. Immer sichtbar
/// (kein Hover-only), Schrift 11 pt, voller Pfad im Tooltip.
struct AgentWorkingCopyBadge: View {
    let copy: AgentWorkingCopy

    /// Lila wie der Branch-Tag (`BranchTag`): weder Grün (heißt „arbeitet“)
    /// noch der Akzent (heißt „ausgewählt“).
    static let elsewhereColor = Color(red: 0.62, green: 0.45, blue: 0.95)

    private var isElsewhere: Bool { copy.kind != .mainFolder }
    private var color: Color { isElsewhere ? Self.elsewhereColor : AgentTheme.textTertiary }
    /// Hauptordner: der Branch (sonst „main folder“); woanders: der Name.
    private var placeText: String {
        isElsewhere ? (copy.name ?? "") : (copy.branch ?? String(localized: "main folder"))
    }

    /// Je nach Platz im Kopf: Ort und Branch, nur der Ort, der Ort gekürzt,
    /// nur das Symbol. Der Titel davor behält so Vorrang, ohne dass die Marke
    /// zu unlesbaren Fetzen zusammengedrückt wird.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            if isElsewhere, copy.branch != nil {
                chip(place: .full, branch: .full)
                chip(place: .full, branch: .truncated(110))
            }
            chip(place: .full, branch: .hidden)
            chip(place: .truncated(84), branch: .hidden)
            chip(place: .hidden, branch: .hidden)
        }
        // Kein Breitenrahmen: ViewThatFits meldet nur die Breite der
        // gewählten Stufe und nimmt der Konto-Marke nichts weg. Vorrang vor
        // dem Spacer, sonst teilt der HStack den Rest mit ihm und der Branch
        // fällt trotz Platz weg.
        .layoutPriority(0.5)
        .help(copy.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(copy))
    }

    private enum PlaceStyle { case full, truncated(CGFloat), hidden }

    private func chip(place: PlaceStyle, branch: PlaceStyle) -> some View {
        HStack(spacing: 4) {
            Image(systemName: Self.iconName(copy.kind)).font(.system(size: 9, weight: .semibold))
            switch place {
            case .full:
                Text(placeText).font(placeFont).lineLimit(1).fixedSize()
            case .truncated(let width):
                Text(placeText).font(placeFont).lineLimit(1).truncationMode(.middle).frame(width: width, alignment: .leading)
            case .hidden:
                EmptyView()
            }
            if let name = copy.branch {
                switch branch {
                case .full:
                    Text("·").font(.system(size: 11)).opacity(0.6)
                    Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1).fixedSize()
                case .truncated(let width):
                    Text("·").font(.system(size: 11)).opacity(0.6)
                    Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        .truncationMode(.middle).frame(width: width, alignment: .leading)
                case .hidden:
                    EmptyView()
                }
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.30), lineWidth: 0.5))
        .fixedSize()
    }

    /// Hauptordner zeigt den Branch, also Schreibmaschinenschrift.
    private var placeFont: Font {
        isElsewhere || copy.branch == nil
            ? .system(size: 11, weight: .semibold) : .system(size: 11, design: .monospaced)
    }

    static func iconName(_ kind: AgentWorkingCopy.Kind) -> String {
        switch kind {
        case .mainFolder: return "folder"
        case .worktree: return "square.on.square"
        case .otherFolder: return "folder.badge.questionmark"
        }
    }

    static func accessibilityText(_ copy: AgentWorkingCopy) -> String {
        let place: String
        switch copy.kind {
        case .mainFolder: place = String(localized: "Works in the main folder")
        case .worktree: place = String(localized: "Works in the worktree \(copy.name ?? "")")
        case .otherFolder: place = String(localized: "Works in the folder \(copy.name ?? "")")
        }
        guard let branch = copy.branch else { return place }
        return place + ", " + String(localized: "branch \(branch)")
    }
}

/// Kleines Zeichen für Tab und Seitenleiste: nur, wenn der Chat NICHT im
/// Hauptordner arbeitet (sonst wäre jede Zeile voll davon). Name und Branch
/// stehen sichtbar in Kachelkopf und Kopfzeile.
struct AgentWorkingCopyMarker: View {
    let copy: AgentWorkingCopy?

    var body: some View {
        if let copy, copy.kind != .mainFolder {
            Image(systemName: AgentWorkingCopyBadge.iconName(copy.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AgentWorkingCopyBadge.elsewhereColor)
                .help(AgentWorkingCopyBadge.accessibilityText(copy))
                .accessibilityLabel(AgentWorkingCopyBadge.accessibilityText(copy))
        }
    }
}
