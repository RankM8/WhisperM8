import SwiftUI

struct OutputTemplatesView: View {
    @State private var store = PostProcessingTemplateStore()
    @State private var templates = PostProcessingTemplate.builtInTemplates
    @State private var selectedTemplateID = PostProcessingTemplate.cleanID
    @State private var editableName = ""
    @State private var editableDescription = ""
    @State private var editableInstruction = ""
    @State private var errorMessage: String?

    private var selectedTemplate: PostProcessingTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                templateList
                    .frame(width: 300)

                templateEditor
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(24)
        }
        .navigationTitle("Templates")
        .onAppear(perform: reload)
        .onChange(of: selectedTemplateID) { _, _ in
            loadEditor()
        }
    }

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Templates")
                    .font(.headline)
                Spacer()
                Button {
                    createTemplate()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Create custom template")
            }

            VStack(alignment: .leading, spacing: 14) {
                templateGroup("Built-in", templates.filter(\.isBuiltIn))
                templateGroup("Custom", templates.filter { !$0.isBuiltIn })
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func templateGroup(_ title: String, _ groupTemplates: [PostProcessingTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            if groupTemplates.isEmpty {
                Text("None yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(groupTemplates) { template in
                    Button {
                        selectedTemplateID = template.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.body.weight(.semibold))
                            Text(template.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(template.id == selectedTemplateID ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var templateEditor: some View {
        if let selectedTemplate {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTemplate.name)
                            .font(.title3.weight(.semibold))
                        Text(selectedTemplate.isBuiltIn ? "Read-only built-in template" : "Custom template")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Duplicate") {
                        duplicate(selectedTemplate)
                    }

                    Button("Save") {
                        saveSelectedTemplate()
                    }
                    .disabled(selectedTemplate.isBuiltIn)
                }

                TextField("Name", text: $editableName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedTemplate.isBuiltIn)

                TextField("Description", text: $editableDescription)
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedTemplate.isBuiltIn)

                Text("Placeholders: {rawTranscript}, {selectedContext}, {visualContextSummary}, {screenClipPaths}, {visualInputMode}, {attachmentCount}, {activeApp}, {language}, {date}")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $editableInstruction)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .frame(minHeight: 360)
                    .disabled(selectedTemplate.isBuiltIn)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        } else {
            ContentUnavailableView("No Template Selected", systemImage: "doc.text")
                .frame(maxWidth: .infinity)
        }
    }

    private func reload() {
        templates = store.templates
        if !templates.contains(where: { $0.id == selectedTemplateID }) {
            selectedTemplateID = templates.first?.id ?? PostProcessingTemplate.cleanID
        }
        loadEditor()
    }

    private func loadEditor() {
        guard let selectedTemplate else { return }
        editableName = selectedTemplate.name
        editableDescription = selectedTemplate.description
        editableInstruction = selectedTemplate.instruction
        errorMessage = nil
    }

    private func duplicate(_ template: PostProcessingTemplate) {
        do {
            let duplicated = try store.duplicate(template)
            reload()
            selectedTemplateID = duplicated.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createTemplate() {
        let now = Date()
        let template = PostProcessingTemplate(
            id: UUID().uuidString,
            name: "Custom template",
            description: "Describe what this mode should do.",
            instruction: """
            Rewrite this transcript.

            Rules:
            - Output only the final text.
            - Do not invent facts.

            Language: {language}

            Transcript:
            {rawTranscript}
            """,
            createdAt: now,
            updatedAt: now,
            isBuiltIn: false
        )

        do {
            try store.saveCustomTemplates(templates + [template])
            reload()
            selectedTemplateID = template.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSelectedTemplate() {
        guard let index = templates.firstIndex(where: { $0.id == selectedTemplateID }),
              !templates[index].isBuiltIn else {
            return
        }

        templates[index].name = editableName
        templates[index].description = editableDescription
        templates[index].instruction = editableInstruction
        templates[index].updatedAt = Date()

        do {
            try store.saveCustomTemplates(templates)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
