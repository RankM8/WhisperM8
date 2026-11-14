import SwiftUI

/// Marke „Wo arbeitet der Chat?“: Hauptordner oder Arbeitskopie, dazu der
/// Branch. Immer sichtbar (kein Hover-only), Schrift 11 pt.
struct AgentWorkingCopyBadge: View {
    enum Style {
        /// Variante A: ein Chip mit Ort und Branch.
        case chip
        /// Variante B: Hauptordner nur als leiser Branch-Text, Arbeitskopie
        /// als farbiger Chip mit Namen, Branch daneben.
        case split
    }

    let copy: AgentWorkingCopy
    var style: Style = .chip
    var maxWidth: CGFloat = 300

    /// Akzent statt Grün: Grün heißt in der App nur „arbeitet“.
    static let worktreeColor = AgentTheme.accent

    var body: some View {
        switch style {
        case .chip: chip
        case .split: split
        }
    }

    private var isElsewhere: Bool { copy.kind != .mainFolder }
    private var color: Color { isElsewhere ? Self.worktreeColor : AgentTheme.textTertiary }
    private var iconName: String {
        switch copy.kind {
        case .mainFolder: return "folder"
        case .worktree: return "square.on.square"
        case .otherFolder: return "folder.badge.questionmark"
        }
    }
    private var placeText: String {
        switch copy.kind {
        case .mainFolder: return String(localized: "main folder")
        case .worktree, .otherFolder: return copy.name ?? ""
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName).font(.system(size: 9, weight: .semibold))
            Text(placeText)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 130, alignment: .leading)
                .fixedSize(horizontal: placeText.count <= 18, vertical: false)
            if let branch = copy.branch {
                Text("·").font(.system(size: 11)).opacity(0.6)
                Text(branch)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.30), lineWidth: 0.5))
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .help(copy.path)
        .accessibilityLabel(accessibilityText)
    }

    private var split: some View {
        HStack(spacing: 5) {
            if isElsewhere {
                HStack(spacing: 4) {
                    Image(systemName: iconName).font(.system(size: 9, weight: .semibold))
                    Text(placeText)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.30), lineWidth: 0.5))
            }
            if let branch = copy.branch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(AgentTheme.textTertiary)
            } else if !isElsewhere {
                Text(placeText)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .help(copy.path)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
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
/// Hauptordner arbeitet (sonst wäre jede Zeile voll davon).
struct AgentWorkingCopyMarker: View {
    let copy: AgentWorkingCopy?

    var body: some View {
        if let copy, copy.kind != .mainFolder {
            Image(systemName: copy.kind == .worktree ? "square.on.square" : "folder.badge.questionmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AgentWorkingCopyBadge.worktreeColor)
                .help(copy.name.map { String(localized: "Works in \($0)") } ?? copy.path)
                .accessibilityLabel(copy.name.map { String(localized: "Works in \($0)") } ?? copy.path)
        }
    }
}
