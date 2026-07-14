import SwiftUI

/// Geteilte Subagent-Kind-Darstellung (Variante D) unter einer Parent-Row —
/// genutzt von der WORKSPACE-Sektion, der flachen Listenansicht und GEPINNT.
/// (ProjectChatGroup hält aus Equatable-/Performance-Gründen eine eigene,
/// optisch identische Ausprägung — bei Änderungen beide Stellen pflegen.)
///
/// Stufe 1 (Chip-Chevron am Parent) teilen sich alle Sektionen über
/// `windowStore.expandedSubagentParentIDs`; Stufe 2 („N fertig"-Fußzeile)
/// hält jede Sektion als eigenen View-State und reicht sie über
/// `isFinishedExpanded`/`onToggleFinished` herein.
extension AgentChatsView {
    /// Kind-Zeilen + Fußzeile unter einer Parent-Row. `extraLeadingInset`
    /// gleicht den Einzug der jeweiligen Sektion aus (Workspace-Rows sind
    /// 10 pt eingerückt, Flat-/Gepinnt-Rows nicht).
    @ViewBuilder
    func subagentChildrenRows(
        parent: AgentChatSession,
        children: [AgentChatSession],
        split: SubagentChildSplit,
        extraLeadingInset: CGFloat = 0,
        isFinishedExpanded: Bool,
        onToggleFinished: @escaping () -> Void
    ) -> some View {
        let isTopExpanded = windowStore.expandedSubagentParentIDs.contains(parent.id)
            || children.contains { $0.id == selectedSessionID }
        if isTopExpanded {
            ForEach(split.visible) { child in
                subagentListChildRow(child, extraLeadingInset: extraLeadingInset)
            }
            if !split.hidden.isEmpty {
                subagentListFooterRow(
                    split: split,
                    extraLeadingInset: extraLeadingInset,
                    isExpanded: isFinishedExpanded,
                    onToggle: onToggleFinished
                )
                if isFinishedExpanded {
                    ForEach(split.hidden) { child in
                        subagentListChildRow(child, extraLeadingInset: extraLeadingInset)
                    }
                }
            }
        }
    }

    /// Kind-Zeile — dieselbe Row wie in der Chat-Liste (`SessionListButton`
    /// mit Subagent-Einzug). Bewusst ohne Drag&Drop (Kinder kleben an ihrem
    /// Parent).
    @ViewBuilder
    private func subagentListChildRow(
        _ child: AgentChatSession,
        extraLeadingInset: CGFloat
    ) -> some View {
        SessionListButton(
            session: child,
            isSelected: selectedSessionID == child.id,
            isMultiSelected: false,
            isOpenTab: openTabIDs.contains(child.id),
            accentColorHex: workspace.projects.first { $0.id == child.projectID }?.color,
            statusStore: runtimeStatusStore,
            isAutoRenaming: false,
            isMissingTranscript: false,
            indentAsSubagent: true,
            isUnreadSubagentResult: windowStore.unreadSubagentSessionIDs.contains(child.id),
            onSelect: {
                selectedSessionID = child.id
                multiSelection = []
            },
            onClose: { requestArchive([child]) }
        )
        .equatable()
        .padding(.leading, extraLeadingInset)
        .contextMenu {
            Button("Umbenennen…", systemImage: "pencil") {
                beginRename(child)
            }
            Divider()
            Button("Archivieren", systemImage: "archivebox") {
                requestArchive([child])
            }
        }
    }

    /// „N fertig"-Fußzeile (Stufe 2) — Layout wie in `ProjectChatGroup`
    /// (52 pt Subagent-Ebene) plus dem Sektions-Einzug.
    private func subagentListFooterRow(
        split: SubagentChildSplit,
        extraLeadingInset: CGFloat,
        isExpanded: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 6.5, weight: .semibold))
                Text("\(split.hidden.count) fertig")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                if split.hiddenUnreadCount > 0 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(AgentTheme.textTertiary)
            .padding(.leading, 52 + extraLeadingInset)
            .padding(.trailing, 8)
            .frame(minHeight: 22, maxHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(split.hidden.count) fertige Subagents"
            + (split.hiddenUnreadCount > 0 ? " · \(split.hiddenUnreadCount) ungelesen" : "")
            + " — klicken zum \(isExpanded ? "Einklappen" : "Anzeigen")")
    }
}
