import Foundation

/// Preflight vor jedem Subagent-Spawn: codex-Binary auflösen (inkl.
/// Codex.app-Fallback via `CodexStatusProbe`) und Version prüfen.
///
/// Beschlossene Politik: unter der getesteten Mindestversion → harter
/// Abbruch (CLI: Exit 4); neuere Major-Version → Warnung, aber weiterlaufen
/// (der tolerante Event-Parser fängt kleine Format-Drifts).
struct CodexAgentPreflight {
    /// Gegen codex-cli 0.142.5 entwickelt und getestet (Fixture 2026-07-04).
    /// `--json`/`--output-schema`/`exec resume` existieren deutlich länger —
    /// wir pinnen konservativ auf die verifizierte Linie.
    static let minimumVersion = SemanticVersion(major: 0, minor: 100, patch: 0)
    static let testedMajor = 0

    enum Outcome: Equatable {
        case ok(codexPath: String, version: SemanticVersion, warning: String?)
        case codexMissing
        case versionTooOld(found: SemanticVersion, minimum: SemanticVersion)
        /// Version nicht parsebar → Warnung + weiterlaufen (nicht blocken):
        /// ein kaputter Versions-String soll keinen funktionierenden Spawn
        /// verhindern.
        case versionUnparseable(codexPath: String, raw: String)
    }

    var commandResolver: (String) -> String?
    var versionRunner: (String) async -> String

    init(
        commandResolver: @escaping (String) -> String? = { CodexStatusProbe.resolveCommandPath($0) },
        versionRunner: ((String) async -> String)? = nil
    ) {
        self.commandResolver = commandResolver
        self.versionRunner = versionRunner ?? { path in
            let cli = AgentHeadlessCLI(timeout: 10)
            let output = try? await cli.run(
                executable: URL(fileURLWithPath: path),
                arguments: ["--version"],
                environment: LoginShellEnvironment.shared.processEnvironment()
            )
            return output ?? ""
        }
    }

    func check() async -> Outcome {
        guard let codexPath = commandResolver("codex") else {
            return .codexMissing
        }
        let raw = await versionRunner(codexPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = Self.parseVersion(from: raw) else {
            return .versionUnparseable(codexPath: codexPath, raw: raw)
        }
        if version < Self.minimumVersion {
            return .versionTooOld(found: version, minimum: Self.minimumVersion)
        }
        var warning: String?
        if version.major > Self.testedMajor {
            warning = "codex \(version) ist eine neuere Major-Version als getestet (\(Self.testedMajor).x) — Event-Format könnte abweichen."
        }
        return .ok(codexPath: codexPath, version: version, warning: warning)
    }

    /// Extrahiert die Semver aus `codex --version`-Output wie
    /// `codex-cli 0.142.5` (letztes parsebares Token — tolerant gegenüber
    /// Präfixen und zusätzlichen Zeilen).
    static func parseVersion(from output: String) -> SemanticVersion? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        for token in tokens.reversed() {
            if let version = SemanticVersion(String(token)) {
                return version
            }
        }
        return nil
    }
}
