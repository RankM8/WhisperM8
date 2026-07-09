import SwiftUI

struct AIOutputAccountTab: View {
    @AppStorage("codexPostProcessingModel") private var selectedModelRaw = CodexPostProcessingModel.defaultModel.rawValue
    @AppStorage("codexReasoningEffort") private var reasoningEffortRaw = CodexReasoningEffort.defaultEffort.rawValue
    @AppStorage("codexServiceTier") private var serviceTierRaw = CodexServiceTier.defaultTier.rawValue
    @AppStorage("codexVisualInputMode") private var visualInputModeRaw = CodexVisualInputMode.defaultMode.rawValue
    @AppStorage("defaultOutputModeID") private var defaultOutputModeID = OutputMode.rawID
    @AppStorage("fallbackToRawOnProcessingError") private var fallbackToRawOnProcessingError = true

    @State private var connectionModel = CodexConnectionModel()
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
                    Button(connectionModel.status == .signedIn ? "Reconnect" : "Sign In") {
                        CodexStatusProbe().openLoginInTerminal()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)

                    Button("Check Again") {
                        catalog = CodexModelCatalogStore.shared.catalog()
                        Task { await connectionModel.refresh() }
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                }

                SettingsRow(
                    title: "Codex CLI",
                    subtitle: "Version used for non-interactive post-processing."
                ) {
                    Text(connectionModel.codexVersion)
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
                    Text(modelLabel(for: rawValue))
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
                    Text(CodexModelCatalog.effortDisplayName(rawValue))
                }

                if let warning = catalogWarning {
                    SettingsHelpText(warning, tone: .warning)
                }

                SettingsPickerRow(
                    title: "Speed",
                    subtitle: "\(selectedServiceTier.detail) Modes can override speed separately when they need different routing.",
                    selection: $serviceTierRaw,
                    options: CodexServiceTier.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(CodexServiceTier.resolve(rawValue).displayName)
                }
            }

            SettingsSection("Visual Input") {
                SettingsPickerRow(
                    title: "Screen clips",
                    subtitle: selectedVisualInputMode.detail,
                    selection: $visualInputModeRaw,
                    options: CodexVisualInputMode.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(visualInputLabel(for: rawValue))
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
                    Text(modeName(for: modeID))
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
            let frontier = catalog.frontierModel?.displayName ?? "latest"
            return "Auto — latest (\(frontier))"
        }
        guard catalog.model(slug: rawValue) != nil else {
            return "\(rawValue) (not in catalog)"
        }
        return catalog.modelDisplayName(rawValue)
    }

    private var modelSubtitle: String {
        let base: String
        if selectedModelRaw == CodexModelSelection.autoRawValue {
            let frontier = catalog.frontierModel?.displayName ?? "the newest listed model"
            base = "Always uses the newest frontier model from your Codex CLI — currently \(frontier)."
        } else {
            base = catalog.model(slug: selectedModelRaw)?.detail
                ?? "Not listed in your Codex CLI's model catalog."
        }
        return "\(base) Modes can override this value in the Modes tab. New Codex agent chats also start from this default."
    }

    private var thinkingSubtitle: String {
        let detail = catalog.efforts(forModelSlug: effectiveModelSlug)
            .first { $0.effort == reasoningEffortRaw }?.detail
        let base = detail ?? "Reasoning depth for post-processing."
        return "\(base) Modes can override this value; new Codex agent chats also use it when created."
    }

    /// Katalog-basierte Warnungen — ersetzt die alte GPT-5.5/"0.120."-Heuristik.
    private var catalogWarning: String? {
        let stand: String
        if let fetchedAt = catalog.fetchedAt {
            stand = "catalog as of \(fetchedAt.formatted(date: .abbreviated, time: .shortened))"
        } else {
            stand = "embedded fallback catalog"
        }
        if selectedModelRaw != CodexModelSelection.autoRawValue,
           catalog.model(slug: selectedModelRaw) == nil {
            return "\(selectedModelRaw) is not in your Codex CLI's model list (\(stand)). If runs fail, pick a listed model or update the Codex CLI."
        }
        if let model = catalog.model(slug: effectiveModelSlug),
           !model.supportsEffort(reasoningEffortRaw) {
            return "\(CodexModelCatalog.effortDisplayName(reasoningEffortRaw)) is not listed for \(model.displayName) (\(stand)) — Codex may reject or downgrade it."
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
}
