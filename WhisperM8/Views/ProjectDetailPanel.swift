import SwiftUI

struct ProjectDetailPanel: View {
    let project: AgentProject?
    let session: AgentChatSession?
    let sessions: [AgentChatSession]
    var onRefresh: () -> Void
    var onNewCodexChat: () -> Void
    var onNewClaudeChat: () -> Void
    var onOpenPHPStorm: () -> Void

    @State private var status: GitProjectStatus?
    /// Manueller Refresh-Zaehler: fliesst in die `.task(id:)`-Identitaet ein,
    /// damit der Reload-Button einen neuen (und der alte einen gecancelten)
    /// Ladevorgang bekommt.
    @State private var gitRefreshToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project context")
                        .font(.headline.weight(.semibold))
                    Text("\(project?.name ?? "-") · \(session?.title ?? "Kein Chat")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    refreshPanel()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            detailCard {
                DetailHeader(title: "Recording Context", icon: "mic")
                DetailRow(label: "Kontextquelle", value: "Aktiver Chat")
                if let session {
                    HStack {
                        AgentSessionIcon(
                            session: session,
                            size: 13,
                            tint: Color(hex: AgentChatColor.fallback(for: session))
                        )
                        Text(session.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text(session.status.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 7))
                }
            }

            detailCard {
                DetailHeader(title: "Branch-Details", icon: "point.topleft.down.curvedto.point.bottomright.up")
                DetailRow(label: "Projekt", value: project?.name ?? "-")
                DetailRow(label: "Branch", value: status?.branch ?? project?.lastBranch ?? "local")
                DetailRow(label: "Pfad", value: project?.path ?? "-", monospaced: true)
            }

            detailCard {
                DetailHeader(title: "Änderungen", icon: "doc.text.magnifyingglass")
                HStack {
                    Text(status?.summary ?? "Kein Git-Status")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let status {
                        Text("+\(status.added) -\(status.deleted)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(status.added > 0 ? .green : .secondary, status.deleted > 0 ? .red : .secondary)
                    }
                }
                .font(.callout)
            }

            detailCard {
                DetailHeader(title: "Git-Aktionen", icon: "arrow.triangle.branch")
                CompactActionButton(title: "Status prüfen", icon: "checklist", action: refreshPanel)
                CompactActionButton(title: "Neuer Codex Chat", icon: "sparkles", action: onNewCodexChat)
                CompactActionButton(title: "Neuer Claude Chat", icon: "seal", action: onNewClaudeChat)
            }

            detailCard {
                DetailHeader(title: "Arbeitsumgebung", icon: "hammer")
                CompactActionButton(title: "PHPStorm öffnen", icon: "chevron.left.forwardslash.chevron.right", action: onOpenPHPStorm)
                DetailRow(label: "Aktiver Chat", value: session?.title ?? "-")
                DetailRow(label: "Provider", value: session?.provider.displayName ?? "-")
            }

            detailCard {
                DetailHeader(title: "Artefakte & Quellen", icon: "shippingbox")
                DetailRow(label: "Chats", value: "\(sessions.count)")
                DetailRow(label: "Screenshots", value: "\(session?.imagePaths.count ?? 0)")
                DetailRow(label: "Modell", value: session?.model ?? "-")
            }

            Spacer()
        }
        .padding(16)
        .background(AgentTheme.background)
        // Off-main, abbrechbar, stale-safe (C13): `.task(id:)` cancelt beim
        // Projektwechsel/Disappear automatisch den alten Ladevorgang.
        .task(id: "\(gitRefreshToken)|\(project?.path ?? "")") {
            await refreshGitStatus()
        }
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgentTheme.border, lineWidth: 1))
    }

    private func refreshPanel() {
        gitRefreshToken += 1
        onRefresh()
    }

    private func refreshGitStatus() async {
        // Alten Status sofort leeren — beim Projektwechsel darf nie der
        // Git-Zustand des vorherigen Projekts stehen bleiben.
        status = nil
        guard let path = project?.path else { return }
        let loaded = await GitProjectStatus.load(path: path)
        // Stale-Guard: Ergebnis nur uebernehmen, wenn weder gecancelt noch
        // das Projekt inzwischen gewechselt wurde.
        guard !Task.isCancelled, project?.path == path else { return }
        status = loaded
    }
}

private struct DetailHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct CompactActionButton: View {
    let title: String
    let icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
