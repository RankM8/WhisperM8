import SwiftUI

/// Marke „Wo arbeitet der Chat?“ (WM8-60). Hauptordner auf dem
/// Standard-Branch: leiser grauer Chip „Main folder“ OHNE Branch — „main“
/// stünde sonst als Branch direkt neben dem Konto „main“ und ließe sich
/// verwechseln. Hauptordner auf einem anderen Branch: auffällig mit Branch
/// (der Fall, den man sehen will). Arbeitskopie und fremder Ordner: farbig mit
/// Name und Branch; nennt der Name den Branch schon, nur einmal. Immer
/// sichtbar (kein Hover-only), Schrift 11 pt, Erklärung und Pfad im Tooltip.
struct AgentWorkingCopyBadge: View {
    let copy: AgentWorkingCopy

    /// Lila wie der Branch-Tag (`BranchTag`): weder Grün (heißt „arbeitet“)
    /// noch der Akzent (heißt „ausgewählt“).
    static let elsewhereColor = Color(red: 0.62, green: 0.45, blue: 0.95)

    private var isElsewhere: Bool { copy.kind != .mainFolder }
    /// Auffällig: woanders, oder im Hauptordner auf einem Nicht-Standard-Branch.
    static func isConspicuous(_ copy: AgentWorkingCopy) -> Bool {
        copy.kind != .mainFolder || !copy.isOnDefaultBranch
    }
    private var color: Color { Self.isConspicuous(copy) ? Self.elsewhereColor : AgentTheme.textTertiary }
    /// Hauptordner: „Main folder“; woanders: der Name.
    private var placeText: String {
        isElsewhere ? (copy.name ?? "") : String(localized: "Main folder")
    }
    /// Branch nur, wenn er etwas sagt: im Hauptordner nur abseits des
    /// Standard-Branchs, woanders nur, wenn der Name ihn nicht schon nennt.
    private var showsBranch: Bool {
        guard copy.branch != nil else { return false }
        return isElsewhere ? !copy.nameRepeatsBranch : !copy.isOnDefaultBranch
    }

    /// Je nach Platz im Kopf: Ort und Branch, nur der Ort, der Ort gekürzt,
    /// nur das Symbol. Der Titel davor behält so Vorrang, ohne dass die Marke
    /// zu unlesbaren Fetzen zusammengedrückt wird.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            if showsBranch {
                chip(place: .full, branch: .full)
                chip(place: .full, branch: .truncated(110))
                if !isElsewhere {
                    // Hauptordner auf fremdem Branch: der Branch ist die
                    // Nachricht, das Ordner-Symbol sagt „Hauptordner“.
                    chip(place: .hidden, branch: .full)
                    chip(place: .hidden, branch: .truncated(90))
                }
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
        .help(Self.accessibilityText(copy) + "\n" + copy.path)
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
                let separator = { if case .hidden = place { return false } else { return true } }()
                switch branch {
                case .full:
                    if separator { Text("·").font(.system(size: 11)).opacity(0.6) }
                    Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1).fixedSize()
                case .truncated(let width):
                    if separator { Text("·").font(.system(size: 11)).opacity(0.6) }
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

    private var placeFont: Font { .system(size: 11, weight: .semibold) }

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
        case .otherFolder: place = String(localized: "Works outside the project in \(copy.path)")
        }
        guard let branch = copy.branch else { return place }
        return place + ", " + String(localized: "branch \(branch)")
    }
}

/// Kleines Zeichen für Tab und Seitenleiste: nur, wenn der Chat außerhalb
/// des Hauptordners oder dort auf einem Nicht-Standard-Branch arbeitet (sonst
/// wäre jede Zeile voll davon). Name und Branch stehen sichtbar in Kachelkopf
/// und Kopfzeile.
struct AgentWorkingCopyMarker: View {
    let copy: AgentWorkingCopy?

    var body: some View {
        if let copy, AgentWorkingCopyBadge.isConspicuous(copy) {
            Image(systemName: copy.kind == .mainFolder ? "arrow.triangle.branch" : AgentWorkingCopyBadge.iconName(copy.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AgentWorkingCopyBadge.elsewhereColor)
                .help(AgentWorkingCopyBadge.accessibilityText(copy))
                .accessibilityLabel(AgentWorkingCopyBadge.accessibilityText(copy))
        }
    }
}
