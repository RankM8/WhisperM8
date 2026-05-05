import Foundation

struct PostProcessingTemplateStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    var templates: [PostProcessingTemplate] {
        PostProcessingTemplate.builtInTemplates + loadCustomTemplates()
    }

    func template(for id: String?) -> PostProcessingTemplate? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    func loadCustomTemplates() -> [PostProcessingTemplate] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([PostProcessingTemplate].self, from: data)
        } catch {
            Logger.debug("Failed to load custom templates: \(error.localizedDescription)")
            return []
        }
    }

    func saveCustomTemplates(_ templates: [PostProcessingTemplate]) throws {
        let customTemplates = templates.filter { !$0.isBuiltIn }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(customTemplates)
        try data.write(to: fileURL, options: .atomic)
    }

    func duplicate(_ template: PostProcessingTemplate) throws -> PostProcessingTemplate {
        let duplicated = template.duplicated()
        var customTemplates = loadCustomTemplates()
        customTemplates.append(duplicated)
        try saveCustomTemplates(customTemplates)
        return duplicated
    }

    private static func defaultFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return supportDirectory
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("PostProcessingTemplates.json")
    }
}
