import KeyboardShortcuts
import SwiftUI

struct SettingsKeyRecorderRow: View {
    let title: String
    let subtitle: String?
    let name: KeyboardShortcuts.Name

    init(title: String, subtitle: String? = nil, name: KeyboardShortcuts.Name) {
        self.title = title
        self.subtitle = subtitle
        self.name = name
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            KeyboardShortcuts.Recorder("", name: name)
                .labelsHidden()
        }
    }
}
