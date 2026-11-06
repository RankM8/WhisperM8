import Foundation

// Dateiebene des Protokoll-Lesers: Dateien finden, neue Bytes zeilenweise
// lesen und das Ergebnis in einem `StatisticsScanBatch` sammeln. Alles hier
// läuft auf der Queue des `StatisticsLogScanner`, nie auf dem Main-Thread.

/// Eine Wurzel, unter der Protokolle liegen.
struct StatisticsLogSource: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `<configDir>/projects` eines Claude-Profils.
        case claude(profile: String)
        /// `~/.codex/sessions` bzw. `~/.codex/archived_sessions`.
        case codex
    }

    var kind: Kind
    var root: URL

    /// Alle Claude-Profile plus Codex. Ein Profil, dessen `projects` auf
    /// denselben Ordner zeigt wie ein anderes (Symlink), wird nur einmal gelesen.
    static func live(home: URL = AppInstance.home) -> [StatisticsLogSource] {
        var sources: [StatisticsLogSource] = []
        var seen = Set<String>()
        let profiles = ClaudeAccountProfiles(homeDirectory: home)
        for name in profiles.profileNames() {
            let root = profiles.configDir(forProfile: name).appendingPathComponent("projects", isDirectory: true)
            let canonical = root.resolvingSymlinksInPath().path
            guard seen.insert(canonical).inserted else { continue }
            sources.append(StatisticsLogSource(kind: .claude(profile: name), root: root))
        }
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        sources.append(StatisticsLogSource(kind: .codex, root: codex.appendingPathComponent("sessions", isDirectory: true)))
        sources.append(StatisticsLogSource(kind: .codex, root: codex.appendingPathComponent("archived_sessions", isDirectory: true)))
        return sources
    }
}

/// Eine gefundene Protokolldatei mit ihrem aktuellen `stat`.
struct StatisticsLogFile: Equatable, Sendable {
    static let codexKeyPrefix = "codex:"

    var path: String
    var kind: StatisticsLogSource.Kind
    var size: Int64
    var mtime: Double
    var inode: UInt64
    /// Schlüssel eines Subagent-Laufs (Pfad relativ zu `projects/`), sonst `nil`.
    var subagentKey: String?
    /// Schlüssel des Lesestands: der Pfad, bei Codex `codex:<thread-uuid>` —
    /// so zählt eine verschobene, komprimierte oder entpackte Datei nicht doppelt.
    var cursorKey: String
    /// `.jsonl.zst` (von Codex komprimiert): nur über den Entpacker lesbar.
    var isCompressed: Bool

    init(
        path: String,
        kind: StatisticsLogSource.Kind,
        size: Int64,
        mtime: Double,
        inode: UInt64,
        subagentKey: String? = nil,
        cursorKey: String? = nil,
        isCompressed: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.inode = inode
        self.subagentKey = subagentKey
        self.cursorKey = cursorKey ?? path
        self.isCompressed = isCompressed
    }

    /// Muss die Datei gelesen werden?
    func needsRead(_ cursor: StatisticsFileCursor?) -> Bool {
        guard let cursor else { return true }
        if let known = cursor.path, known != path { return true }
        return cursor.size != size || cursor.mtime != mtime || cursor.inode != inode
    }

    /// `rollout-2026-07-30T14-00-47-019fb2af-17f7-73d1-9913-e553175e6b3b.jsonl(.zst)`
    /// → `019fb2af-17f7-73d1-9913-e553175e6b3b`.
    static func codexThreadID(fromFileName name: String) -> String? {
        var stem = Substring(name)
        if stem.hasSuffix(".zst") { stem = stem.dropLast(4) }
        guard stem.hasSuffix(".jsonl") else { return nil }
        stem = stem.dropLast(6)
        guard stem.count >= 36 else { return nil }
        let id = stem.suffix(36)
        let groups = id.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12],
              groups.allSatisfy({ $0.allSatisfy(\.isHexDigit) })
        else { return nil }
        return id.lowercased()
    }
}

// MARK: - Auflisten

enum StatisticsLogLister {
    /// Listet alle Protokolle aller Quellen. Claude: `<projekt>/<session>.jsonl`
    /// plus alles unter `<session>/subagents/` — andere Unterordner
    /// (`tool-results` u. a.) werden gar nicht betreten. Codex: alle
    /// `rollout-*.jsonl` und die von Codex komprimierten `rollout-*.jsonl.zst`.
    /// Liegt ein Thread kurz in beiden Formen da (Codex komprimiert gerade),
    /// zählt nur die lesbare `.jsonl`.
    static func list(_ sources: [StatisticsLogSource]) -> [StatisticsLogFile] {
        var files: [StatisticsLogFile] = []
        var codex: [String: StatisticsLogFile] = [:]
        for source in sources {
            switch source.kind {
            case .claude:
                listClaude(source, into: &files)
            case .codex:
                walk(source.root.path, depthLeft: 4) { name, path in
                    guard name.hasPrefix("rollout-") else { return }
                    let compressed = name.hasSuffix(".jsonl.zst")
                    guard compressed || name.hasSuffix(".jsonl") else { return }
                    let key = StatisticsLogFile.codexThreadID(fromFileName: name).map { StatisticsLogFile.codexKeyPrefix + $0 }
                    guard var file = statFile(path: path, kind: source.kind, subagentKey: nil) else { return }
                    file.isCompressed = compressed
                    guard let key else {
                        files.append(file)
                        return
                    }
                    file.cursorKey = key
                    if let existing = codex[key], !existing.isCompressed || compressed {
                        // Unkomprimiert gewinnt; bei Gleichstand die zuletzt geänderte.
                        if existing.isCompressed == compressed, file.mtime > existing.mtime { codex[key] = file }
                        return
                    }
                    codex[key] = file
                }
            }
        }
        files.append(contentsOf: codex.values)
        return files
    }

    private static func listClaude(_ source: StatisticsLogSource, into files: inout [StatisticsLogFile]) {
        let fm = FileManager.default
        let root = source.root.path
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return }
        for project in projects where !project.hasPrefix(".") {
            let projectPath = root + "/" + project
            guard let entries = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let entryPath = projectPath + "/" + entry
                if entry.hasSuffix(".jsonl") {
                    if let file = statFile(path: entryPath, kind: source.kind, subagentKey: nil) { files.append(file) }
                    continue
                }
                // Session-Ordner: nur `subagents/` interessiert (auch `subagents/workflows/<id>/`).
                let subagents = entryPath + "/subagents"
                walk(subagents, depthLeft: 3) { name, path in
                    guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { return }
                    let relative = String(path.dropFirst(root.count + 1))
                    if let file = statFile(path: path, kind: source.kind, subagentKey: relative) { files.append(file) }
                }
            }
        }
    }

    /// Rekursiver Gang über Dateien (ohne versteckte Einträge), begrenzt in der Tiefe.
    private static func walk(_ directory: String, depthLeft: Int, visit: (String, String) -> Void) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in entries where !name.hasPrefix(".") {
            let path = directory + "/" + name
            var info = Darwin.stat()
            guard lstat(path, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                if depthLeft > 0 { walk(path, depthLeft: depthLeft - 1, visit: visit) }
            } else if (info.st_mode & S_IFMT) == S_IFREG {
                visit(name, path)
            }
        }
    }

    static func statFile(path: String, kind: StatisticsLogSource.Kind, subagentKey: String?) -> StatisticsLogFile? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return StatisticsLogFile(
            path: path,
            kind: kind,
            size: Int64(info.st_size),
            mtime: mtime,
            inode: UInt64(info.st_ino),
            subagentKey: subagentKey
        )
    }
}

// MARK: - Sammeln

/// Ergebnis eines Laufs (oder eines Backfill-Abschnitts), noch nicht im Store.
struct StatisticsScanBatch {
    /// Tagesschlüssel → nur die gezählten Felder (`tokens`, `projectTokens`, `subagentsStarted`).
    var days: [String: StatsDay] = [:]
    var codexLimit: LimitSnapshot?
    var codexPlan: String?
    /// Wochenschlüssel → höchste Wochen-Auslastung in diesem Abschnitt.
    var codexWeeklyPeaks: [String: Double] = [:]
    var filesRead = 0

    private let calendar: Calendar
    /// Viertelstunde → Tagesschlüssel. Alle Zeitzonen-Versätze sind Vielfache
    /// von 15 Minuten, ein Tageswechsel fällt also nie mitten in einen Eimer.
    private var dayKeyCache: [Int: String] = [:]

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    var hasData: Bool { !days.isEmpty || codexLimit != nil }

    mutating func dayKey(for date: Date) -> String {
        let bucket = Int((date.timeIntervalSince1970 / 900).rounded(.down))
        if let cached = dayKeyCache[bucket] { return cached }
        let key = StatisticsTime.dayKey(for: date, calendar: calendar)
        if dayKeyCache.count > 4096 { dayKeyCache.removeAll(keepingCapacity: true) }
        dayKeyCache[bucket] = key
        return key
    }

    mutating func addTokens(_ usage: TokenUsage, model: String, account: String, project: String?, at date: Date) {
        let key = dayKey(for: date)
        days[key, default: StatsDay()].addTokens(usage, model: model, account: account, project: project)
    }

    mutating func addSubagent(at date: Date) {
        let key = dayKey(for: date)
        days[key, default: StatsDay()].subagentsStarted += 1
    }

    mutating func recordCodexLimits(_ limits: CodexRateLimits, at date: Date) {
        guard let snapshot = limits.snapshot(capturedAt: date) else { return }
        if let week = snapshot.weekPercent {
            let key = StatisticsTime.weekKey(for: date, calendar: calendar)
            codexWeeklyPeaks[key] = max(codexWeeklyPeaks[key] ?? 0, week)
        }
        if codexLimit == nil || codexLimit!.capturedAt <= date {
            codexLimit = snapshot
            if let plan = limits.planType, !plan.isEmpty { codexPlan = plan }
        }
    }

    /// Leerer Abschnitt mit demselben Kalender.
    func emptyCopy() -> StatisticsScanBatch {
        StatisticsScanBatch(calendar: calendar)
    }

    /// Nimmt einen anderen Abschnitt auf (z. B. eine fertig entpackte Datei).
    mutating func merge(_ other: StatisticsScanBatch) {
        for (key, delta) in other.days {
            days[key, default: StatsDay()].mergeScanned(delta)
        }
        for (week, peak) in other.codexWeeklyPeaks {
            codexWeeklyPeaks[week] = max(codexWeeklyPeaks[week] ?? 0, peak)
        }
        if let snapshot = other.codexLimit, codexLimit.map({ $0.capturedAt <= snapshot.capturedAt }) ?? true {
            codexLimit = snapshot
            if let plan = other.codexPlan { codexPlan = plan }
        }
        filesRead += other.filesRead
    }

    /// Leert die Zählwerte, behält den Tages-Cache.
    mutating func clear() {
        days.removeAll()
        codexLimit = nil
        codexPlan = nil
        codexWeeklyPeaks.removeAll()
        filesRead = 0
    }

    /// Überträgt den Abschnitt in die Datenbank.
    func apply(to db: inout StatsDatabase) {
        for (key, delta) in days {
            db.updateDay(key) { $0.mergeScanned(delta) }
        }
        guard let snapshot = codexLimit else { return }
        var history = db.limits[StatisticsLogParser.codexAccount] ?? LimitHistory(provider: "chatgpt")
        history.provider = "chatgpt"
        for (week, peak) in codexWeeklyPeaks {
            history.weeklyPeaks[week] = max(history.weeklyPeaks[week] ?? 0, peak)
        }
        let isNewest = history.current.map { $0.capturedAt <= snapshot.capturedAt } ?? true
        if isNewest, let plan = codexPlan { history.plan = Self.planDisplayName(plan) }
        history.record(snapshot, calendar: calendar)
        db.limits[StatisticsLogParser.codexAccount] = history
    }

    /// `pro` → `Pro`, `plus` → `Plus`.
    static func planDisplayName(_ raw: String) -> String {
        raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

extension StatsDay {
    /// Addiert die vom Protokoll-Leser gezählten Felder eines anderen Tags.
    mutating func mergeScanned(_ delta: StatsDay) {
        for (model, accounts) in delta.tokens {
            for (account, usage) in accounts {
                tokens[model, default: [:]][account, default: TokenUsage()].add(usage)
            }
        }
        for (project, models) in delta.projectTokens {
            for (model, usage) in models {
                projectTokens[project, default: [:]][model, default: TokenUsage()].add(usage)
            }
        }
        subagentsStarted += delta.subagentsStarted
    }

    /// „Neu einlesen“: alles weg, was aus den Protokollen stammt.
    mutating func clearScanned() {
        tokens = [:]
        projectTokens = [:]
        subagentsStarted = 0
    }
}

// MARK: - Lesen

enum StatisticsLogFileReader {
    /// Lesepuffer je Aufruf. Klein genug, dass auch eine 300-MB-Datei nur ein
    /// MB im Speicher belegt.
    static let chunkSize = 1 << 20
    /// Längere Zeilen werden übersprungen. Antworten und Codex-Events sind um
    /// Größenordnungen kleiner; so lang werden nur eingebettete Bilder.
    static let maxLineLength = 8 << 20

    enum Result: Equatable {
        /// Gelesen; neuer Lesestand.
        case read(StatisticsFileCursor)
        /// Komprimiert, aber kein Entpacker vorhanden.
        case skipped
        /// Entpacken fehlgeschlagen, Zeitlimit oder Abbruch: nichts gezählt.
        case failed
    }

    /// Liest die neuen Bytes einer Datei und gibt den neuen Cursor zurück.
    /// Gelesen wird nur bis zum letzten Zeilenumbruch — eine halbe Zeile am
    /// Ende kommt beim nächsten Lauf vollständig dran.
    ///
    /// Muss eine schon bekannte Codex-Datei von vorn gelesen werden (ersetzt,
    /// verschoben, komprimiert), zählt nur, was über ihren letzten
    /// Gesamtstand hinausgeht.
    static func process(
        _ file: StatisticsLogFile,
        cursor previous: StatisticsFileCursor?,
        dedup: StatisticsDedupSet,
        batch: inout StatisticsScanBatch,
        decompressor: StatisticsDecompressing? = nil,
        shouldStop: () -> Bool = { false }
    ) -> Result {
        var cursor = StatisticsFileCursor(size: file.size, mtime: file.mtime, inode: file.inode, offset: 0)
        var baseline: CodexTokenTotals?
        if !file.isCompressed, let previous, previous.inode == file.inode, previous.offset <= file.size,
           previous.path.map({ !$0.hasSuffix(".zst") }) ?? true {
            cursor = previous
            cursor.size = file.size
            cursor.mtime = file.mtime
        } else if file.kind == .codex {
            // Neue, ersetzte, geschrumpfte, verschobene oder komprimierte Datei
            // → von vorn, aber erst über dem alten Gesamtstand zählen.
            baseline = previous?.codexTotals
        }
        if file.cursorKey != file.path { cursor.path = file.path }

        if file.isCompressed {
            guard let decompressor else { return .skipped }
            // Eigener Abschnitt: Bricht das Entpacken ab, zählt nichts davon.
            var local = batch.emptyCopy()
            var handler = LineHandler(file: file, cursor: cursor, dedup: dedup, replayBaseline: baseline)
            var splitter = StatisticsLineSplitter(start: 0)
            let ok = decompressor.decompress(path: file.path, shouldStop: shouldStop) { chunk in
                splitter.feed(chunk) { handler.handle($0, batch: &local) }
            }
            guard ok else { return .failed }
            batch.merge(local)
            cursor = handler.finishedCursor
            cursor.offset = splitter.consumed
            return .read(cursor)
        }

        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .failed }
        defer { close(fd) }

        var handler = LineHandler(file: file, cursor: cursor, dedup: dedup, replayBaseline: baseline)
        let consumed = forEachLine(fd: fd, from: cursor.offset, to: file.size) { line in
            handler.handle(line, batch: &batch)
        }
        cursor = handler.finishedCursor
        cursor.offset = consumed
        return .read(cursor)
    }

    /// Ruft `body` für jede vollständige Zeile in `[start, end)` und liefert
    /// die Position hinter dem letzten Zeilenumbruch.
    static func forEachLine(fd: Int32, from start: Int64, to end: Int64, _ body: (UnsafeRawBufferPointer) -> Void) -> Int64 {
        guard end > start else { return start }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }

        var splitter = StatisticsLineSplitter(start: start)
        var position = start
        while position < end {
            let want = Int(min(Int64(chunkSize), end - position))
            let got = pread(fd, buffer, want, off_t(position))
            guard got > 0 else { break }
            position += Int64(got)
            splitter.feed(UnsafeRawBufferPointer(start: buffer, count: got), body)
        }
        return splitter.consumed
    }

    /// Zustand beim Lesen einer Datei.
    private struct LineHandler {
        let file: StatisticsLogFile
        var cursor: StatisticsFileCursor
        let dedup: StatisticsDedupSet
        /// Codex: bis hierher ist der Thread schon gezählt.
        var replayBaseline: CodexTokenTotals?

        init(file: StatisticsLogFile, cursor: StatisticsFileCursor, dedup: StatisticsDedupSet, replayBaseline: CodexTokenTotals? = nil) {
            self.file = file
            self.cursor = cursor
            self.dedup = dedup
            self.replayBaseline = replayBaseline
        }

        /// Lesestand nach der Datei. Kam der alte Gesamtstand nicht wieder
        /// vor, bleibt er die Schwelle für den nächsten Lauf.
        var finishedCursor: StatisticsFileCursor {
            var result = cursor
            if let base = replayBaseline { result.codexTotals = base }
            return result
        }

        mutating func handle(_ line: UnsafeRawBufferPointer, batch: inout StatisticsScanBatch) {
            switch file.kind {
            case .claude(let profile):
                handleClaude(line, profile: profile, batch: &batch)
            case .codex:
                handleCodex(line, batch: &batch)
            }
        }

        private mutating func handleClaude(_ line: UnsafeRawBufferPointer, profile: String, batch: inout StatisticsScanBatch) {
            if let key = file.subagentKey, cursor.subagentCounted != true,
               let date = StatisticsLogParser.firstTimestamp(in: line) {
                cursor.subagentCounted = true
                // Dedup über den relativen Pfad: Beim Kontowechsel kopiert
                // Claude `projects/` in ein anderes Profil — derselbe Lauf
                // läge dann zweimal da.
                if dedup.insert(AppInstance.stableHash("subagent|" + key)) {
                    batch.addSubagent(at: date)
                }
            }
            guard let record = StatisticsLogParser.parseClaudeLine(line) else { return }
            if let key = record.dedupKey, !dedup.insert(key) { return }
            batch.addTokens(
                record.usage,
                model: record.model,
                account: StatisticsLogParser.claudeAccount(profile: profile, model: record.model),
                project: record.project,
                at: record.timestamp
            )
        }

        private mutating func handleCodex(_ line: UnsafeRawBufferPointer, batch: inout StatisticsScanBatch) {
            guard let event = StatisticsLogParser.parseCodexLine(line) else { return }
            switch event {
            case .sessionMeta(let cwd):
                if let project = StatisticsLogParser.projectName(fromCwd: cwd) { cursor.codexProject = project }
            case .turnContext(let model, let cwd):
                if let model, !model.isEmpty { cursor.codexModel = model }
                if let project = StatisticsLogParser.projectName(fromCwd: cwd) { cursor.codexProject = project }
            case .tokenCount(let date, let totals, let limits):
                if let totals {
                    var previous = cursor.codexTotals ?? CodexTokenTotals()
                    if let base = replayBaseline {
                        if totals.input <= base.input, totals.cached <= base.cached, totals.output <= base.output {
                            // Schon gezählt — Limits dürfen trotzdem durch (die nehmen nur Neueres).
                            if let limits { batch.recordCodexLimits(limits, at: date) }
                            return
                        }
                        replayBaseline = nil
                        previous = CodexTokenTotals(
                            input: min(base.input, totals.input),
                            cached: min(base.cached, totals.cached),
                            output: min(base.output, totals.output)
                        )
                    }
                    if let delta = StatisticsLogParser.codexDelta(from: previous, to: totals) {
                        batch.addTokens(
                            delta,
                            model: cursor.codexModel ?? StatisticsLogParser.codexFallbackModel,
                            account: StatisticsLogParser.codexAccount,
                            project: cursor.codexProject,
                            at: date
                        )
                    }
                    cursor.codexTotals = totals
                }
                if let limits { batch.recordCodexLimits(limits, at: date) }
            }
        }
    }
}

extension StatisticsLogParser {
    private static let timestampNeedle = Array(#""timestamp":""#.utf8)

    /// Zeitstempel einer beliebigen Zeile, ohne sie zu dekodieren — für den
    /// Start eines Subagent-Laufs.
    static func firstTimestamp(in line: UnsafeRawBufferPointer) -> Date? {
        guard let base = line.baseAddress, line.count > timestampNeedle.count else { return nil }
        let found = timestampNeedle.withUnsafeBytes { needle in
            memmem(base, line.count, needle.baseAddress, needle.count)
        }
        guard let found else { return nil }
        let start = base.distance(to: found) + timestampNeedle.count
        var end = start
        while end < line.count, end - start < 40, line[end] != 0x22 { end += 1 }
        guard end < line.count, line[end] == 0x22 else { return nil }
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
        return parseTimestamp(text)
    }
}

// MARK: - Zeilen

/// Zerlegt einen Bytestrom (Datei-Stücke oder entpackte Daten) in Zeilen,
/// ohne ihn ganz im Speicher zu halten. Zeilen über `maxLineLength` werden
/// übersprungen.
struct StatisticsLineSplitter {
    private var carry: [UInt8] = []
    private var skippingLongLine = false
    private var position: Int64
    /// Position hinter dem letzten Zeilenumbruch.
    private(set) var consumed: Int64

    init(start: Int64) {
        position = start
        consumed = start
    }

    mutating func feed(_ chunk: UnsafeRawBufferPointer, _ body: (UnsafeRawBufferPointer) -> Void) {
        guard let buffer = chunk.baseAddress, chunk.count > 0 else { return }
        let got = chunk.count
        let chunkStart = position
        position += Int64(got)

        var lineStart = 0
        while lineStart < got, let hit = memchr(buffer + lineStart, 0x0A, got - lineStart) {
            let newline = buffer.distance(to: UnsafeRawPointer(hit))
            if skippingLongLine {
                skippingLongLine = false
            } else if carry.isEmpty {
                body(UnsafeRawBufferPointer(start: buffer + lineStart, count: newline - lineStart))
            } else {
                carry.append(contentsOf: UnsafeRawBufferPointer(start: buffer + lineStart, count: newline - lineStart))
                carry.withUnsafeBytes { body($0) }
                // Große Reste nicht dauerhaft festhalten.
                if carry.count > StatisticsLogFileReader.chunkSize { carry = [] } else { carry.removeAll(keepingCapacity: true) }
            }
            lineStart = newline + 1
            consumed = chunkStart + Int64(lineStart)
        }

        if lineStart < got, !skippingLongLine {
            carry.append(contentsOf: UnsafeRawBufferPointer(start: buffer + lineStart, count: got - lineStart))
            if carry.count > StatisticsLogFileReader.maxLineLength {
                carry = []
                skippingLongLine = true
            }
        }
    }
}
