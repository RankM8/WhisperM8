import SwiftUI
@testable import WhisperM8

/// Fixtures der Tickets: Einstellungsseite in ihren Zuständen.
extension UISnapshotGallery {
    @MainActor
    static func ticketSettingsFixtures() -> [Fixture] {
        typealias Model = TicketsSettingsModel
        let home = NSHomeDirectory()
        let projects = [
            TicketProjectChoice(name: "whisperm8", path: home + "/repos/whisperm8"),
            TicketProjectChoice(name: "ListM8", path: home + "/repos/ListM8"),
            TicketProjectChoice(name: "akquise-ai", path: home + "/repos/akquise-ai"),
        ]
        /// Abhängigkeiten, die genau den gezeigten Zustand zurückgeben: Der
        /// Lauf von `load()` beim Erscheinen ändert das Bild nicht.
        func page(workspaces: [Model.Workspace], mappings: [Model.Mapping]) -> AnyView {
            var config = TicketConfig()
            for workspace in workspaces { config.add(workspace: workspace.name) }
            for mapping in mappings {
                if let workspace = mapping.workspace { config.set(workspace: workspace, forTeam: mapping.team) }
                config.set(team: mapping.team, forProject: mapping.path)
            }
            let withKey = Set(workspaces.filter(\.hasKey).map(\.name))
            let teams = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.name, $0) })
            let dependencies = TicketsSettingsDependencies(
                loadConfig: { config }, loadConfigForChange: { config }, saveConfig: { _ in },
                hasKey: { withKey.contains($0) }, storeKey: { _, _ in false }, deleteKey: { _ in false },
                account: { _ in .failure(.unauthorized) },
                teams: { name in teams[name]?.problem == nil ? .success(teams[name]?.teams ?? []) : .failure(.unauthorized) },
                projects: { projects }, chooseFolder: { nil })
            let model = Model(dependencies: dependencies, workspaces: workspaces, mappings: mappings, projects: projects)
            return AnyView(TicketsSettingsPage(dependencies: dependencies, model: model))
        }
        let size = CGSize(width: 760, height: 900)
        let on: [String: Any] = [PreferenceKeys.ticketBoardEnabled: true]
        return [
            Fixture(name: "tickets-einstellungen-aus", size: CGSize(width: 760, height: 420)) {
                page(workspaces: [], mappings: [])
            },
            Fixture(name: "tickets-einstellungen-leer", size: CGSize(width: 760, height: 640), storage: on) {
                page(workspaces: [], mappings: [])
            },
            Fixture(name: "tickets-einstellungen-eingerichtet", size: size, storage: on) {
                page(
                    workspaces: [
                        Model.Workspace(name: "dealsupply", hasKey: true, teams: ["DEA", "DS", "PRB"]),
                        Model.Workspace(name: "whisperm8", hasKey: true, teams: ["WM8"]),
                    ],
                    mappings: [
                        Model.Mapping(path: home + "/repos/ListM8", team: "DS", workspace: "dealsupply"),
                        Model.Mapping(path: home + "/repos/whisperm8", team: "WM8", workspace: "whisperm8"),
                    ])
            },
            Fixture(name: "tickets-einstellungen-stoerung", size: size, storage: on) {
                page(
                    workspaces: [
                        Model.Workspace(name: "dealsupply", hasKey: false),
                        Model.Workspace(name: "whisperm8", hasKey: true, problem: TicketSourceError.unauthorized.userText),
                    ],
                    mappings: [
                        Model.Mapping(path: home + "/repos/ListM8", team: "DS", workspace: "dealsupply"),
                        Model.Mapping(path: home + "/repos/alt", team: "ALT", workspace: nil),
                    ])
            },
        ]
    }
}
