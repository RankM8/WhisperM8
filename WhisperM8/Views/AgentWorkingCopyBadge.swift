import SwiftUI

/// Marke „Wo arbeitet der Chat?“ (WM8-60, seit WM8-73 nach dem Vorbild
/// Orca). Sie unterscheidet nur den Ordner: Hauptordner grau mit seinem
/// Branch („Main folder · develop“), Arbeitskopie und fremder Ordner lila
/// mit Name und Branch; nennt der Name den Branch schon, nur einmal. Über den
/// Branch wird nicht geurteilt (kein „Standard-Branch“ mehr): Bei Repos, deren
/// GitHub-Standard nicht der Arbeits-Branch ist, war die Marke sonst dauerhaft
/// lila. Losgelöster HEAD steht als „detached“ da. Immer sichtbar (kein
/// Hover-only), Schrift 11 pt, Erklärung und Pfad im Tooltip.
struct AgentWorkingCopyBadge: View {
    let copy: AgentWorkingCopy

    /// Lila wie der Branch-Tag (`BranchTag`): weder Grün (heißt „arbeitet“)
    /// noch der Akzent (heißt „ausgewählt“).
    static let elsewhereColor = Color(red: 0.62, green: 0.45, blue: 0.95)

    private var isElsewhere: Bool { copy.kind != .mainFolder }

    /// Auffällig ist nur ein anderer Ordner als der Hauptordner.
    static func isConspicuous(_ copy: AgentWorkingCopy) -> Bool {
        copy.kind != .mainFolder
    }

    private var color: Color { Self.isConspicuous(copy) ? Self.elsewhereColor : AgentTheme.textTertiary }

    /// Hauptordner: „Main folder“; woanders: der Name.
    private var placeText: String {
        isElsewhere ? (copy.name ?? "") : String(localized: "Main folder")
    }

    /// Branch oder „detached“; `nil`, wenn nichts bekannt ist.
    static func branchText(_ copy: AgentWorkingCopy) -> String? {
        if let branch = copy.branch { return branch }
        return copy.detachedHead == true ? String(localized: "detached") : nil
    }

    /// Branch immer, außer der Name einer Arbeitskopie nennt ihn schon.
    private var showsBranch: Bool {
        guard Self.branchText(copy) != nil else { return false }
        return isElsewhere ? !copy.nameRepeatsBranch : true
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
                    // Wenig Platz im Hauptordner: der Branch bleibt, das
                    // Ordner-Symbol sagt „Hauptordner“.
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
        .help(Self.accessibilityText(copy) + "\n" + copy.displayPath)
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
            if let name = Self.branchText(copy) {
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
        case .otherFolder: place = String(localized: "Works outside the project in \(copy.displayPath)")
        }
        if let branch = copy.branch { return place + ", " + String(localized: "branch \(branch)") }
        if copy.detachedHead == true { return place + ", " + String(localized: "detached HEAD") }
        return place
    }
}

/// Kleines Zeichen für Tab und Seitenleiste: nur, wenn der Chat außerhalb
/// des Hauptordners arbeitet (sonst wäre jede Zeile voll davon). Name und
/// Branch stehen sichtbar in Kachelkopf und Kopfzeile.
struct AgentWorkingCopyMarker: View {
    let copy: AgentWorkingCopy?

    var body: some View {
        if let copy, AgentWorkingCopyBadge.isConspicuous(copy) {
            Image(systemName: AgentWorkingCopyBadge.iconName(copy.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AgentWorkingCopyBadge.elsewhereColor)
                .help(AgentWorkingCopyBadge.accessibilityText(copy))
                .accessibilityLabel(AgentWorkingCopyBadge.accessibilityText(copy))
        }
    }
}
