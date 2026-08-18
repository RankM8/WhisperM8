import Foundation

/// Ein Knoten im Changes-Baum des Projekt-Panels (PhpStorm-Stil): Ordner
/// fassen Einzelkind-Ketten zu einem Pfadsegment zusammen („compact middle
/// packages", z. B. `data/chat/skills/cold-mailing`), Dateien tragen die
/// Änderungsart. IDs sind pfadbasiert und damit über Refreshes stabil —
/// der Expand-State der UI überlebt so jedes Neuladen.
struct GitChangesNode: Equatable, Identifiable {
    enum Payload: Equatable {
        case directory
        case file(kind: GitChangeEntry.Kind)
    }

    /// Stabil: `<area>|<repo-relativer pfad>`.
    var id: String
    /// Anzeigename (bei Ordnern ggf. zusammengefasste Kette `a/b/c`).
    var name: String
    /// Repo-relativer Pfad des Knotens (bei Ordnern der Kettenendpunkt).
    var relativePath: String
    var payload: Payload
    /// Anzahl der Dateien im Teilbaum (Ordner) bzw. 1 (Datei).
    var fileCount: Int
    var children: [GitChangesNode]

    var isDirectory: Bool {
        if case .directory = payload { return true }
        return false
    }
}

enum GitChangesTreeBuilder {
    /// Baut den Baum eines Bereichs (Staged/Unstaged). Sortierung wie
    /// PhpStorm: Ordner vor Dateien, innerhalb alphabetisch (case-insensitiv).
    static func build(entries: [GitChangeEntry], area: GitChangeEntry.Area) -> [GitChangesNode] {
        final class Mutable {
            var name: String
            var relativePath: String
            var fileKind: GitChangeEntry.Kind?
            var children: [String: Mutable] = [:]
            init(name: String, relativePath: String) {
                self.name = name
                self.relativePath = relativePath
            }
        }

        let root = Mutable(name: "", relativePath: "")
        for entry in entries where entry.area == area {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var current = root
            var pathSoFar = ""
            for (offset, component) in components.enumerated() {
                pathSoFar = pathSoFar.isEmpty ? component : pathSoFar + "/" + component
                let isLeaf = offset == components.count - 1
                let child = current.children[component] ?? {
                    let node = Mutable(name: component, relativePath: pathSoFar)
                    current.children[component] = node
                    return node
                }()
                if isLeaf {
                    child.fileKind = entry.kind
                }
                current = child
            }
        }

        let areaPrefix = area == .staged ? "staged" : "unstaged"

        func finalize(_ node: Mutable) -> GitChangesNode {
            if let kind = node.fileKind {
                return GitChangesNode(
                    id: "\(areaPrefix)|\(node.relativePath)",
                    name: node.name,
                    relativePath: node.relativePath,
                    payload: .file(kind: kind),
                    fileCount: 1,
                    children: []
                )
            }
            // Einzelkind-Ordnerketten zusammenziehen: ein Ordner mit genau
            // EINEM Kind, das wieder ein Ordner ist, verschmilzt mit ihm.
            var name = node.name
            var current = node
            while current.fileKind == nil,
                  current.children.count == 1,
                  let only = current.children.values.first,
                  only.fileKind == nil {
                name = name.isEmpty ? only.name : name + "/" + only.name
                current = only
            }
            let children = current.children.values
                .map(finalize)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            return GitChangesNode(
                id: "\(areaPrefix)|\(current.relativePath)",
                name: name,
                relativePath: current.relativePath,
                payload: .directory,
                fileCount: children.reduce(0) { $0 + $1.fileCount },
                children: children
            )
        }

        return root.children.values
            .map(finalize)
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Alle Ordner-IDs eines Baums (für Expand-/Collapse-All).
    static func directoryIDs(in nodes: [GitChangesNode]) -> Set<String> {
        var result = Set<String>()
        func walk(_ node: GitChangesNode) {
            guard node.isDirectory else { return }
            result.insert(node.id)
            node.children.forEach(walk)
        }
        nodes.forEach(walk)
        return result
    }
}

/// Eine sichtbare Zeile des Baums, flach ausgerollt fürs LazyVStack-Rendering
/// (kein verschachteltes SwiftUI-Layout — Layout-Kosten bleiben proportional
/// zur sichtbaren Fläche, Konvention wie die Verlaufsansicht).
struct GitChangesRow: Equatable, Identifiable {
    var id: String
    var name: String
    var relativePath: String
    var payload: GitChangesNode.Payload
    var fileCount: Int
    var depth: Int
    var isExpanded: Bool
    var hasChildren: Bool

    var isDirectory: Bool {
        if case .directory = payload { return true }
        return false
    }
}

extension GitChangesTreeBuilder {
    /// Rollt den Baum unter Berücksichtigung eingeklappter Knoten flach aus.
    /// Default ist „alles aufgeklappt" — `collapsedIDs` sammelt die Ausnahmen,
    /// dadurch startet jeder frische Baum PhpStorm-artig voll expandiert.
    static func visibleRows(
        nodes: [GitChangesNode],
        collapsedIDs: Set<String>,
        depth: Int = 0
    ) -> [GitChangesRow] {
        var rows: [GitChangesRow] = []
        for node in nodes {
            let isExpanded = !collapsedIDs.contains(node.id)
            rows.append(GitChangesRow(
                id: node.id,
                name: node.name,
                relativePath: node.relativePath,
                payload: node.payload,
                fileCount: node.fileCount,
                depth: depth,
                isExpanded: isExpanded,
                hasChildren: !node.children.isEmpty
            ))
            if isExpanded, !node.children.isEmpty {
                rows.append(contentsOf: visibleRows(
                    nodes: node.children,
                    collapsedIDs: collapsedIDs,
                    depth: depth + 1
                ))
            }
        }
        return rows
    }
}
