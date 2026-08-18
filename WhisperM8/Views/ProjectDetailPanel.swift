import SwiftUI
import UniformTypeIdentifiers

/// Rechtes Projekt-Panel: Working-Tree-Änderungen des fokussierten Projekts
/// als PhpStorm-artiger Changes-Baum (Staged/Unstaged, Einzelkind-Ketten
/// zusammengezogen, Farbcodierung nach Änderungsart). Klick auf eine Datei
/// öffnet sie in PhpStorm (fokussiert die laufende Instanz, siehe
/// `PhpStormLauncher`).
///
/// Performance-Vertrag: Alles lebt nur, solange das Panel sichtbar ist —
/// der FSEvents-Watcher startet in `onAppear`/beim Projektwechsel und stoppt
/// in `onDisappear`. Geladen wird off-main mit EINEM Git-Spawn pro Refresh
/// (`GitChangesSnapshot`), gerendert wird eine flache Zeilenliste
/// (`visibleRows`) im LazyVStack.
struct ProjectDetailPanel: View {
    let project: AgentProject?
    var onOpenPHPStorm: () -> Void

    @State private var snapshot: GitChangesSnapshot?
    @State private var stagedTree: [GitChangesNode] = []
    @State private var unstagedTree: [GitChangesNode] = []
    /// Eingeklappte Knoten (Default = alles auf, PhpStorm-Konvention).
    /// Pfadbasierte IDs → der Zustand überlebt Refreshes desselben Projekts.
    @State private var collapsedIDs: Set<String> = []
    @State private var refreshToken = 0
    @State private var watcher: ProjectChangesWatcher?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AgentTheme.border)
            content
        }
        .background(AgentTheme.background)
        .task(id: "\(refreshToken)|\(project?.path ?? "")") {
            await reload()
        }
        .onAppear { startWatcher() }
        .onDisappear { stopWatcher() }
        .onChange(of: project?.path) {
            collapsedIDs = []
            startWatcher()
        }
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project?.name ?? "Changes")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                if let branch = snapshot?.branch {
                    Text(branch)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            headerButton("arrow.clockwise", help: "Neu laden") { refreshToken += 1 }
            headerButton("arrow.up.left.and.arrow.down.right", help: "Alles aufklappen") {
                collapsedIDs = []
            }
            headerButton("arrow.down.right.and.arrow.up.left", help: "Alles einklappen") {
                collapsedIDs = GitChangesTreeBuilder.directoryIDs(in: stagedTree)
                    .union(GitChangesTreeBuilder.directoryIDs(in: unstagedTree))
            }
            headerButton("chevron.left.forwardslash.chevron.right", help: "Projekt in PhpStorm öffnen", action: onOpenPHPStorm)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func headerButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            if !snapshot.isGitRepository {
                emptyState(icon: "shippingbox", text: "Kein Git-Repository")
            } else if snapshot.entries.isEmpty {
                emptyState(icon: "checkmark.circle", text: "Clean — keine Änderungen")
            } else {
                changesTree(snapshot)
            }
        } else {
            emptyState(icon: "hourglass", text: "Lade Git-Status…")
        }
    }

    private func changesTree(_ snapshot: GitChangesSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !stagedTree.isEmpty {
                    sectionHeader("Staged", count: snapshot.stagedEntries.count, highlighted: true)
                    rows(for: stagedTree)
                }
                if !unstagedTree.isEmpty {
                    sectionHeader("Unstaged", count: snapshot.unstagedEntries.count, highlighted: false)
                    rows(for: unstagedTree)
                }
                if snapshot.truncated {
                    Text("Liste bei \(GitChangesSnapshot.entryCap) Einträgen gekappt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sectionHeader(_ title: String, count: Int, highlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text("\(count) file\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlighted ? AgentTheme.selection : Color.clear)
    }

    private func rows(for nodes: [GitChangesNode]) -> some View {
        ForEach(GitChangesTreeBuilder.visibleRows(nodes: nodes, collapsedIDs: collapsedIDs)) { row in
            GitChangesRowView(
                row: row,
                onToggle: { toggle(row) },
                onOpenFile: { openInPhpStorm(relativePath: row.relativePath) }
            )
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Aktionen & Laden

    private func toggle(_ row: GitChangesRow) {
        guard row.hasChildren else { return }
        if collapsedIDs.contains(row.id) {
            collapsedIDs.remove(row.id)
        } else {
            collapsedIDs.insert(row.id)
        }
    }

    private func openInPhpStorm(relativePath: String) {
        guard let projectPath = project?.path else { return }
        let absolute = (projectPath as NSString).appendingPathComponent(relativePath)
        if !PhpStormLauncher.open(path: absolute) {
            NSWorkspace.shared.open(URL(fileURLWithPath: absolute))
        }
    }

    private func reload() async {
        guard let path = project?.path else {
            snapshot = nil
            stagedTree = []
            unstagedTree = []
            return
        }
        let loaded = await GitChangesSnapshot.load(path: path)
        // Stale-Guard: Projektwechsel/Cancel während des Spawns.
        guard !Task.isCancelled, project?.path == path else { return }
        // Equatable-Gate: identischer Zustand → kein State-Write, kein Re-Render
        // (wichtig, weil der FSEvents-Watcher auch von Events getriggert wird,
        // die den Git-Status gar nicht ändern).
        guard loaded != snapshot else { return }
        snapshot = loaded
        stagedTree = GitChangesTreeBuilder.build(entries: loaded.entries, area: .staged)
        unstagedTree = GitChangesTreeBuilder.build(entries: loaded.entries, area: .unstaged)
    }

    private func startWatcher() {
        stopWatcher()
        guard let path = project?.path else { return }
        let newWatcher = ProjectChangesWatcher { refreshToken += 1 }
        newWatcher.start(path: path)
        watcher = newWatcher
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
    }
}

// MARK: - Zeile

/// Eine Baumzeile: Chevron (Ordner), System-Dateisymbol, Name in der
/// PhpStorm-Farbcodierung, gedimmte Datei-Zähler an Ordnern.
private struct GitChangesRowView: View {
    let row: GitChangesRow
    var onToggle: () -> Void
    var onOpenFile: () -> Void

    @State private var isHovering = false

    private static let indent: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(row.depth) * Self.indent)

            if row.isDirectory {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(row.name)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                Text("\(row.fileCount) file\(row.fileCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Spacer().frame(width: 12)
                Image(nsImage: Self.fileIcon(for: row.name))
                    .resizable()
                    .frame(width: 13, height: 13)
                Text(row.name)
                    .font(.system(size: 12))
                    .foregroundStyle(fileColor)
                    .strikethrough(isDeleted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(isHovering ? AgentTheme.hover : Color.clear)
        .onHover { isHovering = $0 }
        .onTapGesture {
            if row.isDirectory {
                onToggle()
            } else {
                onOpenFile()
            }
        }
        .contextMenu {
            if !row.isDirectory {
                Button("In PhpStorm öffnen", action: onOpenFile)
            }
            Button("Pfad kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.relativePath, forType: .string)
            }
        }
        .help(row.relativePath)
    }

    private var isDeleted: Bool {
        if case .file(kind: .deleted) = row.payload { return true }
        return false
    }

    /// PhpStorm-Farbcodierung: geändert = blau, neu/gestaged-neu = grün,
    /// unversioniert = rotbraun, gelöscht = grau, umbenannt = blau.
    private var fileColor: Color {
        guard case .file(let kind) = row.payload else { return AgentTheme.textPrimary }
        switch kind {
        case .modified, .renamed:
            return Color(red: 0.35, green: 0.62, blue: 0.95)
        case .added:
            return Color(red: 0.45, green: 0.78, blue: 0.45)
        case .untracked:
            return Color(red: 0.82, green: 0.45, blue: 0.38)
        case .deleted:
            return .secondary
        case .conflicted:
            return Color(red: 0.9, green: 0.35, blue: 0.35)
        }
    }

    /// System-Icon per Dateiendung — funktioniert auch für gelöschte Dateien
    /// (kein Pfadzugriff) und wird von AppKit intern gecacht.
    private static func fileIcon(for fileName: String) -> NSImage {
        let ext = (fileName as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
