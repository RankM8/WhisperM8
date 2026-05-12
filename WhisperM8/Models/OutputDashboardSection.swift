import Foundation

enum OutputDashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case reports = "Reports"
    case tasks = "Tasks"
    case modes = "Modes"
    case templates = "Templates"
    case codex = "Codex"
    case testLab = "Test Lab"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview:
            return "rectangle.grid.2x2"
        case .reports:
            return "list.bullet.rectangle"
        case .tasks:
            return "checklist"
        case .modes:
            return "slider.horizontal.3"
        case .templates:
            return "doc.text"
        case .codex:
            return "sparkles"
        case .testLab:
            return "testtube.2"
        }
    }
}
