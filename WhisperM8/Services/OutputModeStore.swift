import Foundation

struct OutputModeStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    var modes: [OutputMode] {
        var loadedModes = loadModes()
        if loadedModes.isEmpty {
            loadedModes = OutputMode.builtInModes
        }
        return normalized(loadedModes)
    }

    var enabledModes: [OutputMode] {
        modes.filter(\.isEnabled)
    }

    func mode(for id: String?) -> OutputMode {
        let requestedID = id?.isEmpty == false ? id : AppPreferences.shared.defaultOutputModeID
        return modes.first { $0.id == requestedID } ?? modes.first { $0.id == OutputMode.rawID } ?? OutputMode.builtInModes[0]
    }

    func saveModes(_ modes: [OutputMode]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized(modes))
        try data.write(to: fileURL, options: .atomic)
    }

    func createCustomMode() -> OutputMode {
        OutputMode(
            id: UUID().uuidString,
            name: "Custom Mode",
            shortLabel: "Custom",
            kind: .custom,
            templateID: PostProcessingTemplate.cleanID,
            isEnabled: true,
            isDefault: false
        )
    }

    private func loadModes() -> [OutputMode] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([OutputMode].self, from: data)
        } catch {
            Logger.debug("Failed to load output modes: \(error.localizedDescription)")
            return []
        }
    }

    private func normalized(_ modes: [OutputMode]) -> [OutputMode] {
        var byID = Dictionary(uniqueKeysWithValues: modes.map { ($0.id, $0) })

        for builtInMode in OutputMode.builtInModes where byID[builtInMode.id] == nil {
            byID[builtInMode.id] = builtInMode
        }

        let defaultID = AppPreferences.shared.defaultOutputModeID
        let builtInOrder = OutputMode.builtInModes.map(\.id)
        let builtIns = builtInOrder.compactMap { id -> OutputMode? in
            guard var mode = byID[id] else { return nil }
            mode.isDefault = mode.id == defaultID
            if mode.id == OutputMode.rawID {
                mode.isEnabled = true
                mode.kind = .raw
                mode.templateID = nil
            }
            return mode
        }

        let customModes = byID.values
            .filter { !builtInOrder.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { mode -> OutputMode in
                var updatedMode = mode
                updatedMode.kind = .custom
                updatedMode.isDefault = updatedMode.id == defaultID
                return updatedMode
            }

        return builtIns + customModes
    }

    private static func defaultFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return supportDirectory
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("OutputModes.json")
    }
}
