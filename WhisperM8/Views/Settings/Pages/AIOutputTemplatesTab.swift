import SwiftUI

struct AIOutputTemplatesTab: View {
    @Bindable var model: TemplateEditorModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            templateList
                .frame(width: 280, alignment: .topLeading)

            templateEditor
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { model.reload() }
    }

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Templates")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button {
                    model.createTemplate()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Create custom template")
                .buttonStyle(SettingsButtonStyle.standard)
            }

            VStack(alignment: .leading, spacing: 14) {
                templateGroup("Built-in", model.templates.filter(\.isBuiltIn))
                templateGroup("Custom", model.templates.filter { !$0.isBuiltIn })
            }
            .padding(8)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
        }
    }

    private func templateGroup(_ title: String, _ templates: [PostProcessingTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 8)

            if templates.isEmpty {
                Text("None yet")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(templates) { template in
                    Button {
                        model.select(template.id)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.system(size: 13, weight: template.id == model.selectedTemplateID ? .semibold : .regular))
                                    .foregroundStyle(template.id == model.selectedTemplateID ? AppTheme.accent : AppTheme.textPrimary)
                                Text(template.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.textTertiary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            if template.isBuiltIn {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(template.id == model.selectedTemplateID ? AppTheme.accentTint : AppTheme.surface.opacity(0))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var templateEditor: some View {
        if let selectedTemplate = model.selectedTemplate {
            VStack(alignment: .leading, spacing: 18) {
                editorHeader(selectedTemplate)

                SettingsSection("Template") {
                    SettingsRow(title: "Name") {
                        TextField("Name", text: $model.editableName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                            .disabled(selectedTemplate.isBuiltIn)
                    }

                    SettingsRow(title: "Description") {
                        TextField("Description", text: $model.editableDescription)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 420)
                            .disabled(selectedTemplate.isBuiltIn)
                    }

                    SettingsRow(
                        title: "Instruction",
                        subtitle: "Embedded as \"## Mode Instruction\" into the full prompt with the global contract and context blocks."
                    )

                    SettingsTextArea(text: $model.editableInstruction, minHeight: 340)
                        .disabled(selectedTemplate.isBuiltIn)
                }

                SettingsSection("Usage") {
                    SettingsRow(
                        title: "Used by modes",
                        subtitle: usedByModesText
                    )

                    SettingsRow(
                        title: "Placeholders",
                        subtitle: placeholderHelp
                    )
                }

                if let errorMessage = model.errorMessage {
                    SettingsHelpText(errorMessage, tone: .error)
                }
            }
        } else {
            ContentUnavailableView("No Template Selected", systemImage: "doc.text")
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func editorHeader(_ template: PostProcessingTemplate) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(template.isBuiltIn ? "Read-only built-in template" : model.isDirty ? "Custom template with unsaved changes" : "Custom template")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            Spacer()

            Button("Duplicate") {
                model.duplicateSelectedTemplate()
            }
            .buttonStyle(SettingsButtonStyle.standard)

            Button("Save") {
                model.saveSelectedTemplate()
            }
            .disabled(!model.canSave)
            .buttonStyle(SettingsButtonStyle.primary)
        }
    }

    private var usedByModesText: String {
        let modes = model.usedByModes()
        guard !modes.isEmpty else { return "No modes use this template." }
        return modes.map(\.name).joined(separator: " · ")
    }

    private var placeholderHelp: String {
        "{rawTranscript}, {selectedContext}, {visualContextSummary}, {screenClipPaths}, {visualInputMode}, {attachmentCount}, {activeApp}, {agentChatTitle}, {agentChatProject}, {agentChatPath}, {agentChatProvider}, {agentChatExternalID}, {agentChatTail}, {language}, {date}"
    }
}
