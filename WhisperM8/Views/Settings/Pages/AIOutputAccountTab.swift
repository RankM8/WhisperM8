import SwiftUI

struct AIOutputAccountTab: View {
    @AppStorage("codexPostProcessingModel") private var selectedModelRaw = CodexPostProcessingModel.defaultModel.rawValue
    @AppStorage("codexReasoningEffort") private var reasoningEffortRaw = CodexReasoningEffort.defaultEffort.rawValue
    @AppStorage("codexServiceTier") private var serviceTierRaw = CodexServiceTier.defaultTier.rawValue
    @AppStorage("codexVisualInputMode") private var visualInputModeRaw = CodexVisualInputMode.defaultMode.rawValue
    @AppStorage("defaultOutputModeID") private var defaultOutputModeID = OutputMode.rawID
    @AppStorage("fallbackToRawOnProcessingError") private var fallbackToRawOnProcessingError = true

    @State private var connectionModel = CodexConnectionModel()
    @State private var codexInstallModel = AgentCLIInstallModel(cli: .codex)
    @State private var enabledModes = OutputModeStore().enabledModes
    /// Dynamischer Modellkatalog aus ~/.codex/models_cache.json (Stat-gecacht,
    /// Fallback eingebettet) — Quelle der Model-/Thinking-Picker.
    @State private var catalog = CodexModelCatalogStore.shared.catalog()

    /// "auto" → aktuelles Frontier-Modell; konkrete Slugs unverändert.
    private var effectiveModelSlug: String {
        CodexModelSelection.resolveSlug(selectedModelRaw, catalog: catalog)
    }

    private var selectedServiceTier: CodexServiceTier {
        CodexServiceTier.resolve(serviceTierRaw)
    }

    private var selectedVisualInputMode: CodexVisualInputMode {
        CodexVisualInputMode.resolve(visualInputModeRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("ChatGPT") {
                SettingsStatusRow(
                    title: "ChatGPT via Codex CLI",
                    subtitle: "Uses the official Codex CLI login. This is separate from the OpenAI transcription API key.",
                    tone: connectionModel.statusTone,
                    detail: connectionModel.status.displayText
                ) {
                    // Ohne installierte CLI gibt es nichts anzumelden — dann führt der
                    // Installationsblock darunter (LR-DIK-015).
                    if connectionModel.status != .notInstalled {
                        Button {
                            CodexStatusProbe().openLoginInTerminal()
                        } label: {
                            connectionModel.status == .signedIn ? Text("Reconnect") : Text("Sign In")
                        }
                        .buttonStyle(SettingsButtonStyle.standard)
                    }

                    Button("Check Again") {
                        catalog = CodexModelCatalogStore.shared.catalog()
                        Task { await connectionModel.refresh() }
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                }

                if connectionModel.status == .notInstalled {
                    AgentCLIInstallPanel(
                        model: codexInstallModel,
                        onInstalled: { Task { await connectionModel.refresh() } }
                    )
                    .padding(.vertical, 8)
                }

                SettingsRow(
                    title: "Codex CLI",
                    subtitle: "Version used for non-interactive post-processing."
                ) {
                    Text(settingsLocalized: connectionModel.codexVersion)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            SettingsSection("Post-processing Defaults") {
                SettingsPickerRow(
                    title: "Model",
                    subtitle: modelSubtitle,
                    selection: $selectedModelRaw,
                    options: modelPickerOptions
                ) { rawValue in
                    Text(settingsLocalized: modelLabel(for: rawValue))
                }

                SettingsPickerRow(
                    title: "Thinking",
                    subtitle: thinkingSubtitle,
                    selection: $reasoningEffortRaw,
                    options: catalog.pickerEffortValues(
                        forModelSlug: effectiveModelSlug,
                        including: reasoningEffortRaw
                    )
                ) { rawValue in
                    Text(settingsLocalized: CodexModelCatalog.effortDisplayName(rawValue))
                }

                if let warning = catalogWarning {
                    SettingsHelpText(warning, tone: .warning)
                }

                SettingsPickerRow(
                    title: "Speed",
                    subtitle: [
                        runtimeLocalized(selectedServiceTier.detail),
                        String(localized: "Modes can override speed separately when they need different routing.")
                    ].joined(separator: " "),
                    selection: $serviceTierRaw,
                    options: CodexServiceTier.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(settingsLocalized: CodexServiceTier.resolve(rawValue).displayName)
                }
            }

            SettingsSection("Visual Input") {
                SettingsPickerRow(
                    title: "Screen clips",
                    subtitle: selectedVisualInputMode.detail,
                    selection: $visualInputModeRaw,
                    options: CodexVisualInputMode.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(settingsLocalized: visualInputLabel(for: rawValue))
                }

                SettingsHelpText(
                    "Codex receives extracted frames as images today. Direct video upload is not exposed by codex exec; Video keeps clip paths in the prompt and sends frames as fallback.",
                    tone: .warning
                )
            }

            SettingsSection("Output & Fallback") {
                SettingsPickerRow(
                    title: "Default Mode",
                    subtitle: "New recordings start here. If the stored mode was deleted, recordings fall back to Fast (raw) at runtime.",
                    selection: $defaultOutputModeID,
                    options: enabledModes.map(\.id)
                ) { modeID in
                    Text(settingsLocalized: modeName(for: modeID))
                }

                SettingsToggleRow(
                    title: "Fall back to Fast on processing errors",
                    subtitle: "If Codex fails, WhisperM8 delivers the raw transcript instead.",
                    isOn: $fallbackToRawOnProcessingError
                )

                SettingsHelpText("Privacy controls for captured context live in Context & Privacy. AI Output only sends what those settings allow.")
            }
        }
        .task {
            catalog = CodexModelCatalogStore.shared.catalog()
            await connectionModel.refresh()
            enabledModes = OutputModeStore().enabledModes
        }
        // Nur bei explizitem Modellwechsel: unterstützt das neue Modell das
        // gewählte Thinking-Level nicht (beide katalogbekannt), fällt es auf
        // "high" zurück (beschlossen). Nie beim bloßen Laden der View;
        // katalogfremde Werte bleiben unangetastet.
        .onChange(of: selectedModelRaw) { _, newValue in
            let slug = CodexModelSelection.resolveSlug(newValue, catalog: catalog)
            if catalog.shouldReplaceEffort(reasoningEffortRaw, forModelSlug: slug) {
                reasoningEffortRaw = CodexModelCatalog.conflictFallbackEffort
            }
        }
    }

    // MARK: - Katalog-Helper

    private var modelPickerOptions: [String] {
        [CodexModelSelection.autoRawValue] + catalog.pickerModelSlugs(including: selectedModelRaw)
    }

    private func modelLabel(for rawValue: String) -> String {
        if rawValue == CodexModelSelection.autoRawValue {
            let frontier = catalog.frontierModel?.displayName ?? String(localized: "latest")
            return String(localized: "Auto — latest (\(frontier))")
        }
        guard catalog.model(slug: rawValue) != nil else {
            return String(localized: "\(rawValue) (not in catalog)")
        }
        return catalog.modelDisplayName(rawValue)
    }

    private var modelSubtitle: String {
        let base: String
        if selectedModelRaw == CodexModelSelection.autoRawValue {
            let frontier = catalog.frontierModel?.displayName ?? String(localized: "the newest listed model")
            base = String(localized: "Always uses the newest frontier model from your Codex CLI — currently \(frontier).")
        } else {
            base = catalog.model(slug: selectedModelRaw)?.detail.map(runtimeLocalized)
                ?? String(localized: "Not listed in your Codex CLI's model catalog.")
        }
        return base + " " + String(localized: "Modes can override this value in the Modes tab. New Codex agent chats also start from this default.")
    }

    private var thinkingSubtitle: String {
        let detail = catalog.efforts(forModelSlug: effectiveModelSlug)
            .first { $0.effort == reasoningEffortRaw }?.detail
        let base = detail.map(runtimeLocalized) ?? String(localized: "Reasoning depth for post-processing.")
        return base + " " + String(localized: "Modes can override this value; new Codex agent chats also use it when created.")
    }

    /// Katalog-basierte Warnungen — ersetzt die alte GPT-5.5/"0.120."-Heuristik.
    private var catalogWarning: String? {
        let stand: String
        if let fetchedAt = catalog.fetchedAt {
            let fetchedText = fetchedAt.formatted(date: .abbreviated, time: .shortened)
            stand = String(localized: "catalog as of \(fetchedText)")
        } else {
            stand = String(localized: "embedded fallback catalog")
        }
        if selectedModelRaw != CodexModelSelection.autoRawValue,
           catalog.model(slug: selectedModelRaw) == nil {
            return String(localized: "\(selectedModelRaw) is not in your Codex CLI's model list (\(stand)). If runs fail, pick a listed model or update the Codex CLI.")
        }
        if let model = catalog.model(slug: effectiveModelSlug),
           !model.supportsEffort(reasoningEffortRaw) {
            let effortName = runtimeLocalized(CodexModelCatalog.effortDisplayName(reasoningEffortRaw))
            return String(localized: "\(effortName) is not listed for \(model.displayName) (\(stand)) — Codex may reject or downgrade it.")
        }
        return nil
    }

    private func visualInputLabel(for rawValue: String) -> String {
        let mode = CodexVisualInputMode.resolve(rawValue)
        switch mode {
        case .auto:
            return "Auto (frames today)"
        case .frames:
            return "Frames"
        case .video:
            return "Video (frames fallback)"
        }
    }

    private func modeName(for id: String) -> String {
        enabledModes.first { $0.id == id }?.name ?? id
    }

    /// Übersetzt einen zur Laufzeit gelieferten englischen Text (Katalog-Schlüssel).
    private func runtimeLocalized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }
}
