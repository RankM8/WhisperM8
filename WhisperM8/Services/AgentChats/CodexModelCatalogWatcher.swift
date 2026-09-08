import Foundation

/// Beobachtet `~/.codex/models_cache.json` (den Server-Katalog, den die
/// Codex-CLI selbst per ETag-Fetch aktualisiert) und stößt bei Änderung den
/// Abgleich der verwalteten `gpt`-Agent-Definition an. Grund (2026-09-08):
/// Router und Fork-Proxy lesen den Katalog pro Request (stat-gecacht), die
/// `gpt.md` aber trug das beim letzten Backend-Start aufgelöste Modell —
/// ein neues Frontier-Modell wäre dort erst nach App-Neustart angekommen.
///
/// Die Codex-CLI ersetzt die Datei atomar (Rename): Die vnode-Source meldet
/// dann `.rename`/`.delete` und ist danach tot — darum Re-Arm mit kurzer
/// Verzögerung, mit Retry, falls die Datei gerade (noch) fehlt.
@MainActor
final class CodexModelCatalogWatcher {
    static let shared = CodexModelCatalogWatcher()

    private let url: URL
    private let sourceFactory: @MainActor (URL) -> FileEventSource
    private let onCatalogChanged: @MainActor () -> Void
    private let debounceInterval: TimeInterval
    private let rearmInterval: TimeInterval
    private var source: FileEventSource?
    private var debounceWork: DispatchWorkItem?
    private var rearmWork: DispatchWorkItem?
    private var isStarted = false
    private(set) var changeCount = 0

    init(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json"),
        sourceFactory: @escaping @MainActor (URL) -> FileEventSource = { FileEventSource(url: $0) },
        onCatalogChanged: @escaping @MainActor () -> Void = CodexModelCatalogWatcher.syncAgentDefinition,
        debounceInterval: TimeInterval = 1.0,
        rearmInterval: TimeInterval = 2.0
    ) {
        self.url = url
        self.sourceFactory = sourceFactory
        self.onCatalogChanged = onCatalogChanged
        self.debounceInterval = debounceInterval
        self.rearmInterval = rearmInterval
    }

    /// Idempotent. Fehlt die Datei, wird periodisch neu versucht.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        arm()
    }

    func stop() {
        isStarted = false
        debounceWork?.cancel()
        debounceWork = nil
        rearmWork?.cancel()
        rearmWork = nil
        source?.stop()
        source = nil
    }

    var isWatching: Bool { source?.isActive == true }

    private func arm() {
        guard isStarted else { return }
        let source = sourceFactory(url)
        source.onChange = { [weak self] in self?.scheduleChange() }
        source.onFileGone = { [weak self] in
            guard let self else { return }
            self.source = nil
            // Rename = neue Datei mit neuem Inhalt → als Änderung werten
            // UND neu bewaffnen.
            self.scheduleChange()
            self.scheduleRearm()
        }
        guard source.start() else {
            scheduleRearm()
            return
        }
        self.source = source
    }

    private func scheduleRearm() {
        rearmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rearmWork = nil
            self.arm()
        }
        rearmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rearmInterval, execute: work)
    }

    private func scheduleChange() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceWork = nil
            self.changeCount += 1
            Logger.claudeGPTRouter.info(
                "codex_model_catalog_changed path=\(self.url.path, privacy: .public) — gpt-Agent-Definition wird abgeglichen"
            )
            self.onCatalogChanged()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// Default-Reaktion: `gpt.md` gegen Preferences + frischen Katalog
    /// abgleichen (idempotent, schreibt nur bei Abweichung). Off-main, weil
    /// der Sync Dateien liest/schreibt.
    private static func syncAgentDefinition() {
        Task.detached(priority: .utility) {
            ClaudeGPTAgentDefinitionInstaller().syncFromPreferences()
        }
    }
}
