import Foundation

/// Prüft gegen die GitHub-Releases-API, ob eine neuere WhisperM8-Version
/// existiert. Bewusst NUR Anzeige-Infrastruktur: Der Footer-Badge zeigt bei
/// einem Fund den passenden Homebrew-Befehl bzw. den Release-Link — die App
/// tauscht sich nie selbst aus (self-signed Distribution: der Bundle-Swap
/// gehört bewusst in die Hand des Users, inkl. der folgenden TCC-Re-Prompts).
///
/// Vergleichsregel: nur `remote > lokal` meldet ein Update — lokale
/// Dev-Builds mit gleicher oder höherer Version bekommen nie ein Badge.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    /// GitHub-Repo der Releases — muss zum Release-Workflow passen.
    nonisolated static let repoSlug = "RankM8/WhisperM8"
    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
    nonisolated static let fallbackReleasesPageURL = URL(string: "https://github.com/\(repoSlug)/releases")!
    /// Update-Befehl für Cask-Installationen (empfohlener Kanal laut README).
    nonisolated static let brewUpgradeCommand = "brew upgrade --cask whisperm8"
    /// Umstieg auf den Cask für DMG-/Source-Installationen. `--force` ist
    /// hier Pflicht: die App liegt bereits in /Applications (sie läuft ja) —
    /// ohne force bricht brew mit „already an App at …" ab. Der Cask
    /// übernimmt die Kopie, entfernt die Gatekeeper-Quarantäne (self-signed)
    /// und ab dann reicht `brew upgrade`.
    nonisolated static let brewAdoptCommand = "brew install --cask rankm8/tap/whisperm8 --force"
    /// Automatik-Intervall (manueller Check in About geht immer).
    nonisolated static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    /// Verzögerung nach App-Start, damit der Launch-Pfad frei bleibt.
    nonisolated static let initialCheckDelay: TimeInterval = 10

    struct UpdateInfo: Equatable {
        var currentVersion: SemanticVersion
        var latestVersion: SemanticVersion
        var releaseURL: URL
        /// `true` = Installation über den Homebrew-Cask erkannt → der
        /// Upgrade-Befehl ist der richtige Weg; sonst Release-Seite + optional
        /// der Install-Befehl.
        var isBrewInstall: Bool
    }

    enum State: Equatable {
        case unknown
        case checking
        case upToDate(current: SemanticVersion)
        case available(UpdateInfo)
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    /// Zeitpunkt des letzten abgeschlossenen Checks (für die About-Anzeige).
    @Published private(set) var lastCheckedAt: Date?

    private let currentVersionProvider: () -> String?
    private let fetchLatestRelease: () async throws -> Data
    private let brewReceiptExists: () -> Bool
    private let isAutomaticCheckEnabled: () -> Bool

    private var automaticTimer: Timer?
    private var activeCheck: Task<Void, Never>?

    init(
        currentVersionProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        },
        fetchLatestRelease: @escaping () async throws -> Data = {
            var request = URLRequest(url: AppUpdateChecker.latestReleaseURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        },
        brewReceiptExists: @escaping () -> Bool = AppUpdateChecker.defaultBrewReceiptExists,
        isAutomaticCheckEnabled: @escaping () -> Bool = { AppPreferences.shared.isUpdateCheckEnabled }
    ) {
        self.currentVersionProvider = currentVersionProvider
        self.fetchLatestRelease = fetchLatestRelease
        self.brewReceiptExists = brewReceiptExists
        self.isAutomaticCheckEnabled = isAutomaticCheckEnabled
    }

    /// Cask-Receipt-Erkennung: Standard-Caskroom-Pfade für Apple Silicon und
    /// Intel — reicht als Kanal-Heuristik, kein `brew`-Subprozess nötig.
    nonisolated static func defaultBrewReceiptExists() -> Bool {
        let candidates = [
            "/opt/homebrew/Caskroom/whisperm8",
            "/usr/local/Caskroom/whisperm8"
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Automatik: erster Check kurz nach dem Start, danach alle 24 h.
    /// Kill-Switch: `defaults write com.whisperm8.app updateCheckEnabled -bool NO`
    /// (der manuelle Check in den Settings funktioniert weiterhin).
    func scheduleAutomaticChecks() {
        guard automaticTimer == nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.initialCheckDelay * 1_000_000_000))
            guard let self, self.isAutomaticCheckEnabled() else { return }
            await self.checkNow()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.automaticCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAutomaticCheckEnabled() else { return }
                await self.checkNow()
            }
        }
        timer.tolerance = 60 * 10
        automaticTimer = timer
    }

    /// Führt einen Check aus (idempotent — ein laufender Check wird nicht
    /// doppelt gestartet, der Aufruf wartet auf dessen Ergebnis).
    func checkNow() async {
        if let activeCheck {
            await activeCheck.value
            return
        }
        let task = Task { @MainActor in
            await performCheck()
        }
        activeCheck = task
        await task.value
        activeCheck = nil
    }

    private func performCheck() async {
        state = .checking
        defer { lastCheckedAt = Date() }

        guard let rawCurrent = currentVersionProvider(),
              let current = SemanticVersion(rawCurrent) else {
            state = .failed("Installierte Version unbekannt (Info.plist).")
            return
        }

        let data: Data
        do {
            data = try await fetchLatestRelease()
        } catch {
            state = .failed("Update-Prüfung fehlgeschlagen — offline? (\(error.localizedDescription))")
            return
        }

        guard let release = try? JSONDecoder().decode(LatestRelease.self, from: data),
              let latest = SemanticVersion(release.tagName) else {
            state = .failed("Unerwartete Antwort der Release-API.")
            return
        }

        if latest > current {
            let releaseURL = URL(string: release.htmlURL) ?? Self.fallbackReleasesPageURL
            state = .available(UpdateInfo(
                currentVersion: current,
                latestVersion: latest,
                releaseURL: releaseURL,
                isBrewInstall: brewReceiptExists()
            ))
            Logger.debug("[Update] Version \(latest) verfügbar (installiert: \(current))")
        } else {
            state = .upToDate(current: current)
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
