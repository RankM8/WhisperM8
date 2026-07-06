import Foundation
import Observation

@MainActor
@Observable
final class TemplateEditorModel {
    var templates: [PostProcessingTemplate] = []
    var selectedTemplateID: String
    var editableName = ""
    var editableDescription = ""
    var editableInstruction = ""
    var errorMessage: String?

    @ObservationIgnored private let store: PostProcessingTemplateStore
    @ObservationIgnored private let outputModeStore: OutputModeStore

    init(
        fileURL: URL? = nil,
        outputModesFileURL: URL? = nil,
        selectedTemplateID: String = PostProcessingTemplate.cleanID
    ) {
        self.store = PostProcessingTemplateStore(fileURL: fileURL)
        self.outputModeStore = OutputModeStore(fileURL: outputModesFileURL)
        self.selectedTemplateID = selectedTemplateID
        reload()
    }

    var selectedTemplate: PostProcessingTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    var isDirty: Bool {
        guard let selectedTemplate else { return false }
        return editableName != selectedTemplate.name
            || editableDescription != selectedTemplate.description
            || editableInstruction != selectedTemplate.instruction
    }

    var canSave: Bool {
        selectedTemplate?.isBuiltIn == false && isDirty
    }

    func reload() {
        templates = store.templates
        if !templates.contains(where: { $0.id == selectedTemplateID }) {
            selectedTemplateID = templates.first?.id ?? PostProcessingTemplate.cleanID
        }
        loadEditor()
    }

    func select(_ templateID: String) {
        selectedTemplateID = templateID
        loadEditor()
    }

    func createTemplate() {
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
            select(template.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateSelectedTemplate() {
        guard let selectedTemplate else { return }

        do {
            let duplicated = try store.duplicate(selectedTemplate)
            reload()
            select(duplicated.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSelectedTemplate() {
        guard let index = templates.firstIndex(where: { $0.id == selectedTemplateID }),
              !templates[index].isBuiltIn else {
            return
        }

        let trimmedName = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = editableInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Template name cannot be empty."
            return
        }
        guard !trimmedInstruction.isEmpty else {
            errorMessage = "Template instruction cannot be empty."
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

    func usedByModes(for templateID: String? = nil) -> [OutputMode] {
        let id = templateID ?? selectedTemplateID
        return outputModeStore.modes.filter { $0.templateID == id }
    }

    private func loadEditor() {
        guard let selectedTemplate else { return }
        editableName = selectedTemplate.name
        editableDescription = selectedTemplate.description
        editableInstruction = selectedTemplate.instruction
        errorMessage = nil
    }
}
