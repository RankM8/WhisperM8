import AppKit
import SwiftUI

/// Was die Statistik-Seite von außen braucht. `.live` spricht mit Store,
/// Laufzeit-Kopplung und Zwischenablage; Snapshots und Tests setzen eigene Werte,
/// damit dort nichts Echtes passiert.
struct StatisticsSettingsDependencies {
    var snapshot: @Sendable () async -> StatsDatabase
    var requestScan: @MainActor () -> Void
    var rescanAll: @MainActor () -> Void
    var setBackfillPaused: @MainActor (Bool) -> Void
    var notifyEnabledChanged: @MainActor (Bool) -> Void
    var reset: @MainActor () -> Void
    /// Läuft im Hintergrund (`Task.detached`), nie auf dem Main-Thread.
    var directorySize: @Sendable () -> Int64
    var loadSubscriptions: () -> [StatisticsSubscription]
    var saveSubscriptions: ([StatisticsSubscription]) -> Void
    var usdEurRate: () -> Double
    var now: () -> Date
    var copyImage: @MainActor (NSImage) -> Void
    var copyText: @MainActor (String) -> Void

    static let live = StatisticsSettingsDependencies(
        snapshot: { await StatisticsStore.shared.snapshot() },
        requestScan: { StatisticsRuntime.requestScan() },
        rescanAll: { StatisticsRuntime.rescanAll() },
        setBackfillPaused: { StatisticsRuntime.setBackfillPaused($0) },
        notifyEnabledChanged: { StatisticsRuntime.notifyEnabledChanged($0) },
        reset: { StatisticsStore.shared.reset() },
        directorySize: { StatisticsDirectorySize.bytes(at: StatisticsStore.shared.directory) },
        loadSubscriptions: { StatisticsSettings.subscriptions() },
        saveSubscriptions: { StatisticsSettings.setSubscriptions($0) },
        usdEurRate: { StatisticsSettings.usdEurRate() },
        now: { Date() },
        copyImage: { image in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            // Eigener Schreibvorgang: nicht im Zwischenablage-Verlauf landen lassen.
            ClipboardInternalWrites.claim(pasteboard)
        },
        copyText: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ClipboardInternalWrites.claim(pasteboard)
        }
    )
}

/// Größe des Statistik-Ordners. Nur aus dem Hintergrund aufrufen.
enum StatisticsDirectorySize {
    static func bytes(at directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

/// Einstellungsseite „Statistik“: Zeit, Token, Geld, Limits, Chats, Diktate, Git.
///
/// Die Seite rechnet nichts im `body`. Beim Öffnen und bei jeder (gedrosselten)
/// Änderungsmeldung des Stores holt sie einen Schnappschuss und baut daraus im
/// Hintergrund `StatisticsPageData`. Abschnitte liegen in thematischen
/// `extension`-Dateien (`StatisticsSettingsPage+…`).
struct StatisticsSettingsPage: View {
    @AppStorage(StatisticsPreferenceKeys.enabled) var enabled = true
    @AppStorage(StatisticsPreferenceKeys.period) var periodRaw = StatisticsPeriod.week.rawValue

    let dependencies: StatisticsSettingsDependencies
    let locale: Locale

    @State var data: StatisticsPageData?
    /// `nil` = alle Konten.
    @State var account: String?
    @State var subscriptions: [StatisticsSubscription]
    @State var folderBytes: Int64?
    @State var confirmDelete = false
    @State var showShare = false
    @State var loadGeneration = 0
    @State var rescanFeedback = SettingsFeedbackState(duration: .seconds(2))

    init(
        dependencies: StatisticsSettingsDependencies = .live,
        initialData: StatisticsPageData? = nil,
        initialFolderBytes: Int64? = nil,
        locale: Locale = .current
    ) {
        self.dependencies = dependencies
        self.locale = locale
        _data = State(initialValue: initialData)
        _folderBytes = State(initialValue: initialFolderBytes)
        _subscriptions = State(initialValue: dependencies.loadSubscriptions())
    }

    var period: StatisticsPeriod { StatisticsPeriod(rawValue: periodRaw) ?? .week }

    /// Während die Historie eingelesen wird, fehlen ältere Token noch.
    var isIncomplete: Bool { data?.backfill.isRunning == true }

    var body: some View {
        SettingsPageContainer(
            title: "Statistics",
            subtitle: "How much you work with WhisperM8. Everything is calculated locally on this Mac, in the background. Only the daily exchange rate and, if gh is signed in, your GitHub pull requests are fetched."
        ) {
            if enabled {
                enabledContent
            } else {
                enableCard
                if data?.hasData == true || (folderBytes ?? 0) > 0 {
                    dataSection
                }
            }
        }
        .onAppear {
            if enabled { dependencies.requestScan() }
            reload()
            refreshFolderSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: StatisticsStore.didChangeNotification)) { _ in
            reload()
            refreshFolderSize()
        }
        .onChange(of: periodRaw) { reload() }
        .onChange(of: account) { reload() }
        .onChange(of: enabled) { _, isOn in
            dependencies.notifyEnabledChanged(isOn)
            if isOn { dependencies.requestScan() }
            reload()
        }
        .onChange(of: subscriptions) { _, value in
            dependencies.saveSubscriptions(value)
        }
        .onChange(of: subscriptions.map(\.monthlyTotal)) { reload() }
        .sheet(isPresented: $showShare) {
            if let data {
                StatisticsShareSheet(data: data, dependencies: dependencies, locale: locale) {
                    showShare = false
                }
            }
        }
        .confirmationDialog("Delete all statistics?", isPresented: $confirmDelete) {
            Button("Delete statistics", role: .destructive) {
                dependencies.reset()
                data = nil
                folderBytes = 0
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All counted values and read positions are deleted. Your chats and logs stay untouched. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var enabledContent: some View {
        controlsBar
        if let data {
            if data.backfill.isRunning {
                backfillBanner(data.backfill)
            }
            if data.hasData {
                kpiGrid(data)
                timeSection(data)
                modelsSection(data)
                moneySection(data)
                limitsSection(data)
                chatsSection(data)
                dictationSection(data)
                gitSection(data)
            } else {
                emptyHint
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading statistics…")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.vertical, 20)
        }
        dataSection
    }

    // MARK: - Laden

    /// Holt einen Schnappschuss und rechnet die Seite im Hintergrund. Ältere,
    /// noch laufende Ladevorgänge verwerfen ihr Ergebnis (Generationszähler).
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let period = period
        let account = account
        let subscriptions = subscriptions
        let rate = dependencies.usdEurRate()
        let now = dependencies.now()
        let locale = locale
        let snapshot = dependencies.snapshot
        Task { @MainActor in
            let database = await snapshot()
            let built = await Task.detached(priority: .utility) {
                StatisticsPageData.build(
                    database: database,
                    period: period,
                    accountFilter: account,
                    subscriptions: subscriptions,
                    usdEurRate: rate,
                    now: now,
                    locale: locale
                )
            }.value
            guard generation == loadGeneration else { return }
            if data != built { data = built }
        }
    }

    func refreshFolderSize() {
        let measure = dependencies.directorySize
        Task { @MainActor in
            let bytes = await Task.detached(priority: .utility) { measure() }.value
            if folderBytes != bytes { folderBytes = bytes }
        }
    }

    // MARK: - Kopf

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $periodRaw) {
                Text("Today").tag(StatisticsPeriod.day.rawValue)
                Text("Week").tag(StatisticsPeriod.week.rawValue)
                Text("Month").tag(StatisticsPeriod.month.rawValue)
                Text("All time").tag(StatisticsPeriod.all.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 0)

            Button("Share…") { showShare = true }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(data?.hasData != true)
        }
    }

    // MARK: - Zustände

    private var enableCard: some View {
        VStack(spacing: 10) {
            Text("Turn on statistics?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("WhisperM8 then keeps track of how long you actively work, how many tokens your chats use and what that would be worth at API prices.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                bullet("Everything stays on this Mac. Nothing is uploaded.")
                bullet("Only the logs of Claude Code and Codex are read. Nothing is written there.")
                bullet("Your previous chats are imported once in the background, throttled, over a few minutes.")
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.vertical, 4)
            Button("Turn on statistics") { enabled = true }
                .buttonStyle(SettingsButtonStyle.primary)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .frame(maxWidth: 560)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: "•")
            Text(key).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(AppTheme.textSecondary)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No values yet")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("The first analysis runs in the background. Values appear here within a few minutes; your previous chats follow during the initial import.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .statisticsCard()
    }

    private func backfillBanner(_ backfill: StatsBackfillState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("Importing your previous chats")
                        .fontWeight(.semibold)
                    Text(verbatim: " · ")
                    Text(String(localized: "\(StatisticsFormat.count(backfill.processedFiles, locale: locale)) of \(StatisticsFormat.count(backfill.totalFiles, locale: locale)) files"))
                        .monospacedDigit()
                }
                .font(.system(size: 12.5))
                .foregroundStyle(AppTheme.textPrimary)
                if backfill.isPaused {
                    Text("Paused. Values from before the import are still incomplete.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textSecondary)
                } else {
                    Text("Runs throttled in the background and pauses during dictation. Older values are still incomplete.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                StatisticsMeter(fraction: backfill.fraction)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                let pause = !backfill.isPaused
                dependencies.setBackfillPaused(pause)
                // Sofort zeigen; die Bestätigung kommt mit der nächsten Store-Meldung.
                data?.backfill.isPaused = pause
            } label: {
                if backfill.isPaused { Text("Resume") } else { Text("Pause") }
            }
            .buttonStyle(SettingsButtonStyle.standard)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.accentTintSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.accent.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Daten

    var dataSection: some View {
        SettingsSection("Data") {
            SettingsToggleRow(
                title: "Collect statistics",
                subtitle: "Off: nothing is counted or imported anymore. Existing values stay until you delete them.",
                isOn: $enabled
            )
            SettingsRow(
                title: "Last analysis",
                subtitle: "Every 15 minutes and when you open this page. Only new lines of changed files are read."
            ) {
                Text(verbatim: lastAnalysisText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
            }
            SettingsButtonRow(
                title: "Stored",
                subtitle: "Daily values under Application Support/WhisperM8/statistics/"
            ) {
                Text(verbatim: folderBytes.map { StatisticsFormat.bytes($0, locale: locale) } ?? "–")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textSecondary)
                Button {
                    dependencies.rescanAll()
                    rescanFeedback.trigger()
                } label: {
                    if rescanFeedback.isActive { Text("Started") } else { Text("Rescan") }
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(!enabled)
                Button("Delete…") { confirmDelete = true }
                    .buttonStyle(SettingsButtonStyle.destructive)
                    .disabled(data?.hasData != true && (folderBytes ?? 0) == 0)
            }
        }
    }

    private var lastAnalysisText: String {
        guard let data else { return "–" }
        if data.backfill.isRunning {
            return String(localized: "Initial import running · \(StatisticsFormat.percent(data.backfill.fraction, locale: locale))")
        }
        guard let scan = data.lastScan else { return String(localized: "Not yet") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: scan.finishedAt, relativeTo: data.now)
        let files = StatisticsFormat.count(scan.filesRead, locale: locale)
        let seconds = StatisticsFormat.decimal(scan.duration, digits: 1, locale: locale)
        return String(localized: "\(relative) · \(files) files · \(seconds) s")
    }
}
