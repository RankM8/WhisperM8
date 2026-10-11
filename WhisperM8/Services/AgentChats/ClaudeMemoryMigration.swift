import Foundation

/// Einmalige Zusammenführung des Auto-Memorys aller Zusatzprofile nach `main`
/// (Plan `docs/plans/claude-account-switch-ohne-stopp.md`, Slice 1). Seit dem
/// gemeinsamen Memory lesen Chats aller Konten `~/.claude/projects/<p>/memory`
/// — ohne diese Migration fehlte ihnen, was sie vorher unter ihrem Profil
/// gelernt hatten.
///
/// Regeln:
/// - **Kopieren, nie verschieben:** Die Profil-Ordner bleiben unverändert —
///   Terminal-Chats unter einem Profil und der Kill-Switch nutzen sie weiter.
/// - **Backup zuerst:** jeder Quell-Ordner und jeder Ziel-Ordner, den die
///   Migration anfasst, wandert vorher nach `backupRoot/<profil>/<projekt>/memory`.
/// - **Nie überschreiben:** gleicher Name + gleicher Inhalt → überspringen;
///   gleicher Name + anderer Inhalt → als `<name>.<profil>.md` ablegen.
/// - **`MEMORY.md`:** fehlende Index-Zeilen anhängen (Links auf umbenannte
///   Dateien umgeschrieben); Zeilen, deren Link das Ziel schon kennt, entfallen.
/// - Idempotent: ein zweiter Lauf findet alles schon vor und ändert nichts.
struct ClaudeMemoryMigration {
    static let indexFileName = "MEMORY.md"

    var profiles: ClaudeAccountProfiles
    var backupRoot: URL
    var fileManager: FileManager = .default

    struct Report: Equatable {
        var projects = 0
        var copied = 0
        var skippedIdentical = 0
        var renamed = 0
        var indexLinesAdded = 0
    }

    /// Standard-Ablage der Backups: `Application Support/WhisperM8/memory-migration/<zeit>`.
    static func defaultBackupRoot(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8/memory-migration/\(formatter.string(from: now))", isDirectory: true)
    }

    /// Start-Hook der App: läuft genau einmal (Merker
    /// `claudeSharedMemoryMigrationDone`) und nur bei aktivem gemeinsamem Memory.
    /// Scheitert der Lauf, bleibt der Merker aus und der nächste Start versucht
    /// es erneut — schon kopierte Dateien überspringt er dann.
    static func runOnceIfNeeded(preferences: AppPreferences = .shared) {
        guard preferences.isClaudeSharedMemoryEnabled,
              !preferences.claudeSharedMemoryMigrationDone else { return }
        let backupRoot = defaultBackupRoot()
        do {
            let report = try ClaudeMemoryMigration(profiles: ClaudeAccountProfiles(), backupRoot: backupRoot).run()
            preferences.claudeSharedMemoryMigrationDone = true
            Logger.agentStore.notice(
                "claude_memory_migration_done projects=\(report.projects) copied=\(report.copied) identical=\(report.skippedIdentical) renamed=\(report.renamed) indexLines=\(report.indexLinesAdded) backup=\(backupRoot.path, privacy: .public)")
        } catch {
            Logger.agentStore.error(
                "claude_memory_migration_failed error=\(error.localizedDescription, privacy: .public) backup=\(backupRoot.path, privacy: .public)")
        }
    }

    func run() throws -> Report {
        var report = Report()
        let mainProjects = profiles.configDir(forProfile: ClaudeAccountProfiles.mainProfileName)
            .appendingPathComponent("projects", isDirectory: true)
        var backedUpMainProjects: Set<String> = []

        for profile in profiles.profiles() where profile.name != ClaudeAccountProfiles.mainProfileName {
            let projectsDir = profile.configDir.appendingPathComponent("projects", isDirectory: true)
            for project in directoryEntries(projectsDir) {
                let source = project.appendingPathComponent("memory", isDirectory: true)
                let files = memoryFiles(in: source)
                guard !files.isEmpty else { continue }
                let projectName = project.lastPathComponent
                let target = mainProjects
                    .appendingPathComponent(projectName, isDirectory: true)
                    .appendingPathComponent("memory", isDirectory: true)

                try backup(source, as: profile.name, project: projectName)
                if !backedUpMainProjects.contains(projectName), !memoryFiles(in: target).isEmpty {
                    try backup(target, as: ClaudeAccountProfiles.mainProfileName, project: projectName)
                    backedUpMainProjects.insert(projectName)
                }
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try merge(files: files, from: source, into: target, profileName: profile.name, report: &report)
                report.projects += 1
            }
        }
        return report
    }

    // MARK: - Zusammenführen

    private func merge(
        files: [URL],
        from source: URL,
        into target: URL,
        profileName: String,
        report: inout Report
    ) throws {
        var renamedLinks: [String: String] = [:]
        for file in files where file.lastPathComponent != Self.indexFileName {
            let name = file.lastPathComponent
            let destination = target.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: destination.path) else {
                try fileManager.copyItem(at: file, to: destination)
                report.copied += 1
                continue
            }
            if contentsEqual(file, destination) {
                report.skippedIdentical += 1
                continue
            }
            let renamedName = Self.renamedFileName(name, profileName: profileName)
            let renamedDestination = target.appendingPathComponent(renamedName)
            renamedLinks[name] = renamedName
            if fileManager.fileExists(atPath: renamedDestination.path) {
                // Früherer Lauf hat genau diese Kopie schon angelegt.
                if contentsEqual(file, renamedDestination) {
                    report.skippedIdentical += 1
                } else {
                    Logger.agentStore.warning(
                        "claude_memory_migration_conflict_kept file=\(renamedName, privacy: .public) — Quelle bleibt nur im Profil und im Backup")
                }
                continue
            }
            try fileManager.copyItem(at: file, to: renamedDestination)
            report.renamed += 1
        }

        let sourceIndex = (try? String(contentsOf: source.appendingPathComponent(Self.indexFileName), encoding: .utf8)) ?? ""
        let targetIndexURL = target.appendingPathComponent(Self.indexFileName)
        let targetIndex = (try? String(contentsOf: targetIndexURL, encoding: .utf8)) ?? ""
        let merged = Self.mergedIndex(target: targetIndex, source: sourceIndex, renamedLinks: renamedLinks)
        if merged.addedLines > 0 {
            try Data(merged.text.utf8).write(to: targetIndexURL, options: .atomic)
            report.indexLinesAdded += merged.addedLines
        }
    }

    /// `notiz.md` → `notiz.ai2.md`.
    static func renamedFileName(_ name: String, profileName: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(name).\(profileName)" : "\(stem).\(profileName).\(ext)"
    }

    /// Hängt die Index-Zeilen der Quelle an, die das Ziel noch nicht kennt.
    /// Pur und unit-getestet.
    static func mergedIndex(
        target: String,
        source: String,
        renamedLinks: [String: String]
    ) -> (text: String, addedLines: Int) {
        let targetLines = target.components(separatedBy: "\n")
        var known = Set(targetLines.map { $0.trimmingCharacters(in: .whitespaces) })
        var knownLinks = Set(targetLines.flatMap(linkTargets))
        var additions: [String] = []
        for rawLine in source.components(separatedBy: "\n") {
            var line = rawLine
            for target in linkTargets(in: rawLine) {
                if let renamed = renamedLinks[target] {
                    line = line.replacingOccurrences(of: "](\(target))", with: "](\(renamed))")
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Leerzeilen und Überschriften (z. B. „# Memory Index") gehören dem Ziel.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !known.contains(trimmed) else { continue }
            let links = linkTargets(in: line)
            if !links.isEmpty, links.allSatisfy(knownLinks.contains) { continue }
            additions.append(line)
            known.insert(trimmed)
            knownLinks.formUnion(links)
        }
        guard !additions.isEmpty else { return (target, 0) }
        var text = target
        if text.isEmpty {
            text = "# Memory Index\n\n"
        } else if !text.hasSuffix("\n") {
            text += "\n"
        }
        text += additions.joined(separator: "\n") + "\n"
        return (text, additions.count)
    }

    /// Ziele von Markdown-Links `[…](ziel)` in einer Zeile.
    static func linkTargets(in line: String) -> [String] {
        var targets: [String] = []
        var rest = Substring(line)
        while let open = rest.range(of: "](") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            targets.append(String(after[..<close]))
            rest = after[after.index(after: close)...]
        }
        return targets
    }

    // MARK: - Dateisystem

    private func backup(_ directory: URL, as profileName: String, project: String) throws {
        let destination = backupRoot
            .appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: directory, to: destination)
    }

    /// Unterordner eines Ordners, ohne Symlinks zu verfolgen.
    private func directoryEntries(_ directory: URL) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { isPlainDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reguläre, nicht versteckte Dateien eines Memory-Ordners (flach — Claude
    /// legt dort nur Einzeldateien ab). Ein Symlink-Ordner zählt nicht.
    private func memoryFiles(in directory: URL) -> [URL] {
        guard isPlainDirectory(directory) else { return [] }
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func contentsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        fileManager.contentsEqual(atPath: lhs.path, andPath: rhs.path)
    }
}
