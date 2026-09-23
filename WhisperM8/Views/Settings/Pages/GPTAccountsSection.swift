import AppKit
import SwiftUI

/// Sektionen „ChatGPT-Konten (GPT-Backend)" + „Konto hinzufügen" auf der
/// GPT-Backend-Seite — dasselbe Bedienmodell wie der Tab „Claude Accounts":
/// Radio-Auswahl des aktiven Kontos für neue Chats, Identität + Wochen-
/// Gauge pro Konto, ⋯-Menü für Anmelden/Abmelden/Entfernen. Die Konten sind
/// Proxy-Logins (`~/.gpt-profiles/<name>`, `CCP_CONFIG_DIR`) — bewusst
/// sichtbar getrennt vom `codex login` der Codex-CLI (Befund 2026-09-16:
/// beide wurden verwechselt). Plan: docs/plans/gpt-account-switcher.md, E5.
struct GPTAccountsSection: View {
    /// Wird nach Login/Logout/Entfernen gerufen, damit die Seite ihren
    /// Status (Zeile „Authentifizierung", Einrichtung) nachzieht.
    var onAccountsChanged: () -> Void = {}

    private let profileService = GPTAccountProfiles()
    private let proxyManager = ClaudeCodeProxyManager.shared

    @State private var profiles: [GPTAccountProfile] = []
    @State private var activeProfileName = GPTAccountProfiles.mainProfileName
    @State private var usageByProfile: [String: CodexUsage] = [:]
    @State private var usageProblemByProfile: [String: String] = [:]
    @State private var runningPorts: [String: Int] = [:]
    @State private var isFetchingUsage = false
    @State private var newProfileName = ""
    @State private var feedback: String?
    @State private var feedbackTone: SettingsHelpText.Tone = .secondary
    @State private var loginProfileName: String?
    @State private var deviceCodeInfo: ClaudeCodeProxyDeviceCodeInfo?
    @State private var isDeviceLoginRunning = false
    @State private var isBusy = false

    var body: some View {
        Group {
            SettingsSection("ChatGPT-Konten (GPT-Backend)") {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }

                if let deviceCodeInfo, let loginProfileName {
                    deviceCodeRows(deviceCodeInfo, profileName: loginProfileName)
                }

                SettingsHelpText("Das aktive Konto gilt für neu gestartete Claude-Chats (auch für einen späteren /model-Wechsel auf GPT). Laufende Chats behalten ihr Konto; bestehende Chats lassen sich im Kontextmenü umstellen. Background-Agents (claude --bg) nutzen immer das Hauptkonto. Diese Konten sind die Proxy-Logins des GPT-Backends — Codex-CLI, Diktat und die ChatGPT-App nutzen ihren eigenen „codex login“.")

                if let feedback {
                    SettingsHelpText(feedback, tone: feedbackTone)
                }
            }

            SettingsSection("Konto hinzufügen") {
                SettingsRow(
                    title: "Neues Kontoprofil",
                    subtitle: "Legt einen eigenen Proxy-Login an (CCP_CONFIG_DIR), der dauerhaft angemeldet bleibt. Der Login läuft per Gerätecode im Browser — dort mit dem gewünschten ChatGPT-Konto anmelden; ist im Browser schon ein anderes Konto aktiv, ein Inkognito-Fenster nehmen."
                ) {
                    HStack(spacing: 8) {
                        TextField("z. B. ai", text: $newProfileName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(width: 160)

                        Button("Anlegen & anmelden…") {
                            createProfileAndLogin()
                        }
                        .buttonStyle(SettingsButtonStyle.primary)
                        .disabled(
                            loginInProgress
                                || !GPTAccountProfiles.isValidProfileName(
                                    newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                        )
                    }
                }

                SettingsButtonRow(
                    title: "Limits aktualisieren",
                    subtitle: "Fragt die Wochen-Limits aller angemeldeten Konten live ab."
                ) {
                    Button(isFetchingUsage ? "Lade…" : "Aktualisieren") {
                        fetchUsage()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .disabled(isFetchingUsage)
                }
            }
        }
        .onAppear { reload() }
    }

    /// Login laeuft — egal, ob aus dieser Sektion oder von der gefuehrten
    /// Einrichtung gestartet: der Manager erlaubt nur einen Device-Login und
    /// wuerde einen laufenden sonst kommentarlos beenden.
    private var loginInProgress: Bool {
        isDeviceLoginRunning || proxyManager.isDeviceLoginRunning
    }

    // MARK: - Zeilen

    @ViewBuilder
    private func profileRow(_ profile: GPTAccountProfile) -> some View {
        let isActive = profile.name == activeProfileName

        HStack(alignment: .top, spacing: 14) {
            radioButton(for: profile, isActive: isActive)
                .padding(.top, 2)

            identityColumn(for: profile, isActive: isActive)
                .frame(width: 230, alignment: .leading)

            gaugeColumn(for: profile)
                .frame(minWidth: 215, alignment: .leading)

            Spacer(minLength: 8)

            manageMenu(for: profile, isActive: isActive)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }

    private func radioButton(for profile: GPTAccountProfile, isActive: Bool) -> some View {
        Button {
            guard !isActive else { return }
            setActive(profile)
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        isActive ? AppTheme.statusWorking : AppTheme.textTertiary.opacity(0.55),
                        lineWidth: 1.5
                    )
                    .frame(width: 15, height: 15)
                if isActive {
                    Circle()
                        .fill(AppTheme.statusWorking)
                        .frame(width: 7, height: 7)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!profile.isLoggedIn || isBusy || loginInProgress)
        .help(isActive
            ? "Aktives Konto für neue GPT-Chats"
            : profile.isLoggedIn
                ? "Dieses Konto für neue GPT-Chats verwenden"
                : "Zuerst anmelden (⋯-Menü)")
    }

    private func identityColumn(for profile: GPTAccountProfile, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(profile.name)
                    .font(.system(size: 13.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AppTheme.statusWorking : AppTheme.textPrimary)

                if let plan = profile.planDisplayName ?? usageByProfile[profile.name]?.planType
                    .flatMap(GPTAccountProfiles.planDisplayName) {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                }

                if profile.isMain {
                    Text("main")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(Capsule().strokeBorder(AppTheme.border, lineWidth: 1))
                }
            }

            if profile.isLoggedIn {
                if let email = profile.emailAddress ?? usageByProfile[profile.name]?.emailAddress {
                    Text(email)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let accountID = profile.accountID {
                    Text("Konto …\(accountID.suffix(8))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                if let port = runningPorts[profile.name] {
                    // verbatim: SwiftUI formatiert interpolierte Ints sonst mit
                    // Tausendertrennzeichen („18'775").
                    Text(verbatim: "Proxy-Instanz auf Port \(port)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            } else if loginProfileName == profile.name, loginInProgress {
                Text("Login läuft…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.statusAwaiting)
            } else {
                Text("Nicht angemeldet")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.statusAwaiting)
            }
        }
    }

    @ViewBuilder
    private func gaugeColumn(for profile: GPTAccountProfile) -> some View {
        if profile.isLoggedIn {
            usageView(for: profile)
        } else {
            Button(loginProfileName == profile.name && loginInProgress ? "Login läuft…" : "Anmelden…") {
                startLogin(for: profile)
            }
            .buttonStyle(SettingsButtonStyle.standard)
            .disabled(loginInProgress)
            .help("Öffnet den Gerätecode-Login für dieses Profil — im Browser mit dem gewünschten ChatGPT-Konto anmelden, bei Bedarf in einem Inkognito-Fenster.")
        }
    }

    @ViewBuilder
    private func usageView(for profile: GPTAccountProfile) -> some View {
        if let usage = usageByProfile[profile.name] {
            VStack(alignment: .leading, spacing: 5) {
                if let primary = usage.primary {
                    limitGauge(label: primary.label, percent: primary.usedPercent, resetsAt: primary.resetsAt)
                }
                if let secondary = usage.secondary {
                    limitGauge(label: secondary.label, percent: secondary.usedPercent, resetsAt: secondary.resetsAt)
                }
                ForEach(usage.scopedLimits, id: \.name) { scoped in
                    limitGauge(
                        label: scoped.name,
                        percent: scoped.window.usedPercent,
                        resetsAt: scoped.window.resetsAt,
                        labelWidth: 88
                    )
                }
                if usage.isLimitReached {
                    Text("Gesperrt — Kontingent erschöpft\(Self.untilText(Self.lockedUntil(usage)))")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppTheme.statusError)
                }
            }
        } else if let problem = usageProblemByProfile[profile.name] {
            Text(problem)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppTheme.statusAwaiting)
                .frame(maxWidth: 260, alignment: .leading)
        } else if isFetchingUsage {
            Text("lade…")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Reset des Fensters, das die Sperre verursacht: das spaeteste Reset
    /// unter allen vollen Fenstern. `primary` ist nicht zwingend die Woche —
    /// bei einem gesperrten Konto war bisher immer das Wochenlimit voll.
    static func lockedUntil(_ usage: CodexUsage) -> Date? {
        var windows = [usage.primary, usage.secondary].compactMap { $0 }
        windows.append(contentsOf: usage.scopedLimits.map(\.window))
        let full = windows.filter { $0.usedPercent >= 100 }.compactMap(\.resetsAt)
        return full.max() ?? windows.compactMap(\.resetsAt).max()
    }

    private func limitGauge(label: String, percent: Double?, resetsAt: Date?, labelWidth: CGFloat = 34) -> some View {
        let color: Color = {
            guard let percent else { return AppTheme.textTertiary }
            if percent >= 80 { return AppTheme.statusError }
            if percent >= 50 { return AppTheme.statusAwaiting }
            return AppTheme.statusWorking
        }()

        return HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.textTertiary.opacity(0.18))
                    .frame(width: 72, height: 5)
                if let percent {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, 72 * min(percent, 100) / 100), height: 5)
                }
            }

            Text(percent.map { "\(Int($0.rounded())) %" } ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent != nil ? color : AppTheme.textTertiary)
                .frame(width: 38, alignment: .trailing)

            Text(Self.resetText(resetsAt))
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 66, alignment: .leading)
        }
    }

    @ViewBuilder
    private func manageMenu(for profile: GPTAccountProfile, isActive: Bool) -> some View {
        Menu {
            Button(profile.isLoggedIn ? "Neu anmelden…" : "Anmelden…") { startLogin(for: profile) }
                .disabled(loginInProgress)
            if profile.isLoggedIn {
                Button("Abmelden…") { logout(profile) }
                    .disabled(isBusy || loginInProgress)
            }
            if !profile.isMain {
                Divider()
                Button("Entfernen…", role: .destructive) { removeProfile(profile) }
                    .disabled(isActive || isBusy || loginInProgress)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Anmelden, abmelden, entfernen")
    }

    @ViewBuilder
    private func deviceCodeRows(_ info: ClaudeCodeProxyDeviceCodeInfo, profileName: String) -> some View {
        SettingsRow(
            title: "Login für „\(profileName)“",
            subtitle: "URL im Browser öffnen, dort mit dem gewünschten ChatGPT-Konto anmelden und den Code eingeben. Ist im Browser ein anderes Konto aktiv, ein Inkognito-Fenster verwenden."
        ) {
            if let url = URL(string: info.visitURL) {
                Link(info.visitURL, destination: url)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text(info.visitURL).textSelection(.enabled)
            }
        }

        SettingsRow(title: "Gerätecode") {
            HStack(spacing: 10) {
                Text(info.code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)
                    .textSelection(.enabled)

                Button("Code kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.code, forType: .string)
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }
        }
    }

    // MARK: - Laden

    private func reload() {
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        runningPorts = proxyManager.runningProfileInstances()
        fetchUsage()
    }

    /// Live-Limits je angemeldetem Konto aus dem jeweiligen Proxy-Store,
    /// parallel (ein Konto im 6-s-Timeout haelt die anderen nicht auf).
    /// Ein 401 heisst hier meist: der Datei-Token ist veraltet — die Instanz
    /// arbeitet trotzdem, nur die Anzeige fehlt.
    private func fetchUsage() {
        guard !isFetchingUsage else { return }
        isFetchingUsage = true
        let targets = profiles.filter(\.isLoggedIn)
        let service = profileService
        Task {
            let results = await withTaskGroup(of: (GPTAccountProfile, CodexUsage?).self) { group in
                for profile in targets {
                    group.addTask {
                        let usage = await CodexUsageFetcher(
                            proxyAuthFile: service.authFileURL(forProfile: profile.name)
                        ).fetchLiveUsage()
                        return (profile, usage)
                    }
                }
                var collected: [(GPTAccountProfile, CodexUsage?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            await MainActor.run {
                for (profile, usage) in results {
                    if let usage {
                        usageByProfile[profile.name] = usage
                        usageProblemByProfile[profile.name] = nil
                        if let accountID = profile.accountID {
                            try? service.writeAccountInfo(
                                GPTAccountInfo(
                                    accountID: accountID,
                                    emailAddress: usage.emailAddress,
                                    planType: usage.planType,
                                    fetchedAt: Date()
                                ),
                                forProfile: profile.name
                            )
                        }
                    } else {
                        usageByProfile[profile.name] = nil
                        usageProblemByProfile[profile.name] =
                            "Limits nicht abrufbar — Token in der Datei veraltet. Die Instanz läuft weiter; zur Anzeige „Neu anmelden…“ (⋯)."
                    }
                }
                profiles = service.profiles()
                isFetchingUsage = false
            }
        }
    }

    // MARK: - Aktionen

    private func setActive(_ profile: GPTAccountProfile) {
        do {
            try profileService.setActiveProfile(profile.name)
            activeProfileName = profile.name
            showFeedback("Neue GPT-Chats laufen jetzt über „\(profile.name)“. Laufende Chats bleiben unverändert.", tone: .secondary)
        } catch {
            showFeedback("Konto konnte nicht aktiviert werden: \(error.localizedDescription)", tone: .error)
            return
        }
        onAccountsChanged()
        guard !profile.isMain else { return }
        // Instanz vorab hochfahren, damit der erste Chat nicht in den 503-Retry laeuft.
        let manager = proxyManager
        Task.detached(priority: .userInitiated) {
            let result = manager.ensureRunning(profile: profile.name)
            await MainActor.run {
                runningPorts = manager.runningProfileInstances()
                if case .failure(let error) = result {
                    showFeedback("Proxy-Instanz für „\(profile.name)“ konnte nicht starten: \(error.localizedDescription)", tone: .error)
                }
            }
        }
    }

    private func createProfileAndLogin() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let profile = try profileService.createProfile(named: name)
            newProfileName = ""
            profiles = profileService.profiles()
            startLogin(for: profile)
        } catch {
            showFeedback(error.localizedDescription, tone: .error)
        }
    }

    private func startLogin(for profile: GPTAccountProfile) {
        guard !loginInProgress else {
            showFeedback("Es läuft bereits ein Login — bitte zuerst abschließen.", tone: .warning)
            return
        }
        feedback = nil
        deviceCodeInfo = nil
        loginProfileName = profile.name
        isDeviceLoginRunning = true
        let others = profiles.filter { $0.name != profile.name }
        let service = profileService

        let result = proxyManager.startDeviceLogin(
            profile: profile.isMain ? nil : profile.name,
            onCodeInfo: { info in
                Task { @MainActor in deviceCodeInfo = info }
            },
            onCompletion: { exitCode in
                Task { @MainActor in
                    isDeviceLoginRunning = false
                    deviceCodeInfo = nil
                    loginProfileName = nil
                    if exitCode != 0 {
                        showFeedback("Login für „\(profile.name)“ wurde mit Status \(exitCode) beendet.", tone: .error)
                    } else if let newAccountID = service.storedAccountID(forProfile: profile.name) {
                        if let duplicate = others.first(where: { $0.accountID == newAccountID }) {
                            showFeedback("Achtung: Dieses ChatGPT-Konto ist bereits als „\(duplicate.name)“ verbunden. Im Browser war vermutlich das andere Konto angemeldet — für ein zweites Konto den Login in einem Inkognito-Fenster wiederholen (⋯ → Neu anmelden…).", tone: .warning)
                        } else {
                            showFeedback("„\(profile.name)“ ist angemeldet.", tone: .secondary)
                        }
                        if !profile.isMain {
                            // Laufende Instanz benutzt den alten Grant im Speicher —
                            // beim naechsten Chat startet sie mit dem neuen.
                            proxyManager.stopInstance(profile: profile.name)
                        }
                    } else {
                        showFeedback("Login für „\(profile.name)“ beendet, aber keine Anmeldedaten gefunden.", tone: .error)
                    }
                    reload()
                    onAccountsChanged()
                }
            }
        )
        if case .failure(let error) = result {
            isDeviceLoginRunning = false
            loginProfileName = nil
            showFeedback(error.localizedDescription, tone: .error)
        }
    }

    private func logout(_ profile: GPTAccountProfile) {
        let alert = NSAlert()
        alert.messageText = "GPT-Konto „\(profile.name)“ abmelden?"
        alert.informativeText = profile.isMain
            ? "Der Proxy-Login des Hauptkontos wird gelöscht. Chats auf dem Hauptkonto starten dann ohne GPT-Backend, bis du dich erneut anmeldest."
            : "Der Proxy-Login dieses Profils wird gelöscht und seine Instanz beendet. Chats auf diesem Konto laufen beim nächsten Start über das Hauptkonto, bis du dich erneut anmeldest."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Abmelden")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isBusy = true
        let manager = proxyManager
        Task.detached(priority: .userInitiated) {
            let result = manager.logout(profile: profile.isMain ? nil : profile.name)
            await MainActor.run {
                isBusy = false
                switch result {
                case .success:
                    if activeProfileName == profile.name, !profile.isMain {
                        try? profileService.setActiveProfile(GPTAccountProfiles.mainProfileName)
                    }
                    usageByProfile[profile.name] = nil
                    usageProblemByProfile[profile.name] = nil
                    showFeedback("„\(profile.name)“ ist abgemeldet.", tone: .secondary)
                case .failure(let error):
                    showFeedback("Abmelden fehlgeschlagen: \(error.localizedDescription)", tone: .error)
                }
                reload()
                onAccountsChanged()
            }
        }
    }

    private func removeProfile(_ profile: GPTAccountProfile) {
        let alert = NSAlert()
        alert.messageText = "GPT-Konto „\(profile.name)“ entfernen?"
        alert.informativeText = "Der Proxy-Login dieses Profils wird gelöscht und seine Instanz beendet. Chats, die auf dieses Konto gestempelt sind, werden auf das Hauptkonto umgestellt."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Entfernen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if loginProfileName == profile.name {
            proxyManager.cancelDeviceLogin()
        }
        proxyManager.stopInstance(profile: profile.name)
        // Stempel mitziehen: sonst zeigte das Kontextmenue ein Konto, das es
        // nicht mehr gibt, und der Alert-Text stimmte nicht.
        let store = AgentSessionStore()
        let stamped = store.loadWorkspace().sessions
            .filter { $0.gptProfileName == profile.name }
            .map(\.id)
        if !stamped.isEmpty {
            try? store.setGPTSessionProfile(ids: stamped, profileName: nil)
        }
        do {
            try profileService.removeProfile(named: profile.name)
            usageByProfile[profile.name] = nil
            usageProblemByProfile[profile.name] = nil
            showFeedback("„\(profile.name)“ wurde entfernt.", tone: .secondary)
        } catch {
            showFeedback(error.localizedDescription, tone: .error)
        }
        reload()
        onAccountsChanged()
    }

    private func showFeedback(_ text: String, tone: SettingsHelpText.Tone) {
        feedback = text
        feedbackTone = tone
    }

    // MARK: - Formatierung

    private static func resetText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = resetsAt.timeIntervalSinceNow > 86_400 ? "EE HH:mm" : "HH:mm"
        return "→ \(formatter.string(from: resetsAt))"
    }

    private static func untilText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = resetsAt.timeIntervalSinceNow > 86_400 ? "EE dd.MM. HH:mm" : "HH:mm"
        return " · frei ab \(formatter.string(from: resetsAt))"
    }
}
