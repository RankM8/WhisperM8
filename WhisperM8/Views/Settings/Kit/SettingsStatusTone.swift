import SwiftUI

enum SettingsStatusTone: CaseIterable, Equatable {
    case ok
    case warn
    case error
    case off

    var tokenName: String {
        switch self {
        case .ok:
            "statusWorking"
        case .warn:
            "statusAwaiting"
        case .error:
            "statusError"
        case .off:
            "textTertiary"
        }
    }

    var color: Color {
        switch self {
        case .ok:
            AppTheme.statusWorking
        case .warn:
            AppTheme.statusAwaiting
        case .error:
            AppTheme.statusError
        case .off:
            AppTheme.textTertiary
        }
    }
}
