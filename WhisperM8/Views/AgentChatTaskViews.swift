import SwiftUI

// MARK: - Tasks in der Notiz-Karte
//
// Daten: `AgentChatTasksStore` (Claudes Task-Dateien des Chats). Gleiche Zeilen
// wie die Task-Anzeige der Mod (`/t` im Chat): Symbol, #ID, voller Titel,
// @Besitzer, bei laufenden die Tätigkeit, Blocker, klickbare Links. Laufende
// und offene stehen immer da, erledigte hinter „▸ N done“.

struct AgentChatTasksSection: View {
    let tasks: [AgentChatTask]
    /// Ohne Jarvis-Notiz ist der Abschnitt die ganze Karte: dann ohne Überschrift
    /// oben drüber, nur mit den Zahlen.
    var showsTitle = true

    @State private var showsCompleted = false

    private var open: [AgentChatTask] { tasks.filter { $0.status != .completed } }
    private var completed: [AgentChatTask] { tasks.filter { $0.status == .completed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            ForEach(open) { AgentChatTaskRow(task: $0, openIDs: openIDs) }
            if !completed.isEmpty {
                Button {
                    showsCompleted.toggle()
                } label: {
                    (showsCompleted ? Text("▴ hide done") : Text("▸ \(completed.count) done"))
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                .buttonStyle(.plain)
                if showsCompleted {
                    ForEach(completed) { AgentChatTaskRow(task: $0, openIDs: openIDs) }
                }
            }
        }
    }

    private var openIDs: Set<String> { Set(open.map(\.id)) }

    private var header: some View {
        let active = AgentChatTaskSummary.count(tasks, .inProgress)
        let pending = AgentChatTaskSummary.count(tasks, .pending)
        return HStack(spacing: 8) {
            if showsTitle {
                Text("TASKS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(AgentTheme.textTertiary)
            }
            if active > 0 {
                Text("◼ \(active) active")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.statusAwaiting)
            }
            if pending > 0 {
                Text("◻ \(pending) open")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
        }
    }
}

struct AgentChatTaskRow: View {
    let task: AgentChatTask
    let openIDs: Set<String>

    private var isDone: Bool { task.status == .completed }
    private var blockers: [String] { task.blockedBy.filter(openIDs.contains) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(glyph)
                .font(.system(size: 11))
                .foregroundStyle(glyphColor)
            VStack(alignment: .leading, spacing: 2) {
                title
                if task.status == .inProgress, let activeForm = task.activeForm {
                    Text(verbatim: "↳ \(activeForm)")
                        .font(.system(size: 11.5).italic())
                        .foregroundStyle(AgentTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isDone, !blockers.isEmpty {
                    Text("⊘ waiting for \(blockers.map { "#\($0)" }.joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                if !task.links.isEmpty {
                    links
                }
            }
        }
    }

    private var title: some View {
        var line = Text(verbatim: "#\(task.id) ").foregroundStyle(AgentTheme.textTertiary)
            + Text(verbatim: task.subject)
                .foregroundStyle(isDone ? AgentTheme.textTertiary : AgentTheme.textPrimary)
                .fontWeight(task.status == .inProgress ? .semibold : .regular)
        if let owner = task.owner {
            line = line + Text(verbatim: " @\(owner)").foregroundStyle(AgentTheme.accent)
        }
        return line
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Klick öffnet im Browser bzw. bei file:// in der zugehörigen App.
    private var links: some View {
        HStack(spacing: 10) {
            ForEach(task.links, id: \.self) { link in
                Link(destination: link.url) {
                    Text(verbatim: "↗ \(link.label)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AgentTheme.accent)
                }
                .buttonStyle(.plain)
                .help(link.url.absoluteString)
            }
        }
    }

    private var glyph: String {
        switch task.status {
        case .inProgress: return "◼"
        case .pending: return "◻"
        case .completed: return "✔"
        }
    }

    private var glyphColor: Color {
        switch task.status {
        case .inProgress: return AgentTheme.statusAwaiting
        case .pending: return AgentTheme.textTertiary
        // Nicht grün: Grün heißt in der App nur „arbeitet“.
        case .completed: return AgentTheme.textTertiary
        }
    }
}
