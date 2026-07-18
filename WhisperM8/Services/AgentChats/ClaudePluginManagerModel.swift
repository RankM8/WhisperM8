import Foundation
import Observation

/// UI-Model des Plugin-Managers. Haelt Plugin-/Marketplace-Listen, den
/// Details-Cache (Token-Kosten) und den Operations-Zustand.
///
/// Alle CLI-Operationen laufen STRIKT serialisiert (eine in-flight,
/// `isBusy` disabled derweil die UI): Claudes Config-Dateien sind nicht
/// lock-geschuetzt, parallele `claude plugin`-Aufrufe koennten sie
/// zerschreiben. Nach jeder Mutation wird die Liste neu geladen und
/// `restartRequired` gesetzt — laufende Claude-Sessions sehen
/// Plugin-Aenderungen erst nach einem Neustart.
@MainActor
@Observable
final class ClaudePluginManagerModel {
    var cli = ClaudePluginCLI()

    private(set) var pluginList = ClaudePluginList(installed: [], available: [])
    private(set) var marketplaces: [ClaudeMarketplace] = []
    /// Details-Cache — Key `id@version`, damit ein Update den Eintrag
    /// automatisch invalidiert.
    private(set) var detailsCache: [String: ClaudePluginDetails] = [:]
    private(set) var isBusy = false
    private(set) var restartRequired = false
    private(set) var lastError: String?
    private(set) var pruneOutput: String?
    /// Ziel-Account-Profil (CLAUDE_CONFIG_DIR); nil = Haupt-Account.
    var accountProfileName: String?

    private var hasLoadedOnce = false

    /// Summe der Always-on-Token aller enabled Plugins — nur aus dem Cache;
    /// nil-Anteile machen die Summe unvollstaendig (`isTokenSumComplete`).
    var enabledAlwaysOnTokenSum: Int {
        pluginList.installed
            .filter(\.enabled)
            .compactMap { detailsCache[cacheKey(for: $0)]?.alwaysOnTokens }
            .reduce(0, +)
    }

    var isTokenSumComplete: Bool {
        pluginList.installed
            .filter(\.enabled)
            .allSatisfy { detailsCache[cacheKey(for: $0)] != nil }
    }

    func cacheKey(for plugin: ClaudeInstalledPlugin) -> String {
        "\(plugin.id)@\(plugin.version)"
    }

    // MARK: - Laden

    /// Erst-Load beim Oeffnen der Page (idempotent).
    func loadIfNeeded() async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await reload()
    }

    func reload() async {
        await perform(markRestart: false) {
            self.pluginList = try await self.cli.listPlugins(accountProfile: self.accountProfileName)
            self.marketplaces = try await self.cli.marketplaces(accountProfile: self.accountProfileName)
        }
    }

    /// Details lazy pro Karte; gecacht per id@version.
    func loadDetailsIfNeeded(for plugin: ClaudeInstalledPlugin) async {
        let key = cacheKey(for: plugin)
        guard detailsCache[key] == nil else { return }
        do {
            let details = try await cli.details(
                pluginName: plugin.id,
                accountProfile: accountProfileName
            )
            detailsCache[key] = details
        } catch {
            // Details sind Anzeige-Zucker — Fehler hier nicht als
            // Seiten-Fehler eskalieren, die Karte zeigt "nicht verfuegbar".
            Logger.agentStore.warning("plugin_details_failed plugin=\(plugin.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Mutationen (immer: ausführen → neu laden → restartRequired)

    func setEnabled(_ enabled: Bool, plugin: ClaudeInstalledPlugin) async {
        await performMutation {
            try await self.cli.setEnabled(
                enabled,
                pluginID: plugin.id,
                scope: ClaudePluginCLI.Scope(rawValue: plugin.scope),
                accountProfile: self.accountProfileName
            )
        }
    }

    func install(_ pluginID: String, scope: ClaudePluginCLI.Scope, config: [String: String]) async {
        await performMutation {
            try await self.cli.install(
                pluginID,
                scope: scope,
                config: config,
                accountProfile: self.accountProfileName
            )
        }
    }

    func uninstall(_ plugin: ClaudeInstalledPlugin) async {
        await performMutation {
            try await self.cli.uninstall(
                plugin.id,
                scope: ClaudePluginCLI.Scope(rawValue: plugin.scope),
                accountProfile: self.accountProfileName
            )
        }
    }

    func update(_ plugin: ClaudeInstalledPlugin) async {
        await performMutation {
            try await self.cli.update(plugin.id, accountProfile: self.accountProfileName)
        }
    }

    func prune() async {
        await performMutation {
            self.pruneOutput = try await self.cli.prune(accountProfile: self.accountProfileName)
        }
    }

    func addMarketplace(source: String) async {
        await performMutation {
            try await self.cli.addMarketplace(source: source, accountProfile: self.accountProfileName)
        }
    }

    func removeMarketplace(name: String) async {
        await performMutation {
            try await self.cli.removeMarketplace(name: name, accountProfile: self.accountProfileName)
        }
    }

    func updateMarketplaces(name: String? = nil) async {
        await performMutation {
            try await self.cli.updateMarketplaces(name: name, accountProfile: self.accountProfileName)
        }
    }

    func switchAccountProfile(to name: String?) async {
        accountProfileName = name
        detailsCache = [:]
        await reload()
    }

    func dismissRestartBanner() {
        restartRequired = false
    }

    func dismissPruneOutput() {
        pruneOutput = nil
    }

    // MARK: - Internals

    private func performMutation(_ operation: @escaping () async throws -> Void) async {
        await perform(markRestart: true) {
            try await operation()
            self.pluginList = try await self.cli.listPlugins(accountProfile: self.accountProfileName)
            self.marketplaces = try await self.cli.marketplaces(accountProfile: self.accountProfileName)
        }
    }

    /// Serialisierung: laeuft bereits eine Operation, wird die neue
    /// verworfen (Buttons sind via `isBusy` disabled — das ist ein
    /// Sicherheitsnetz, keine Queue).
    private func perform(markRestart: Bool, _ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await operation()
            if markRestart {
                restartRequired = true
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
