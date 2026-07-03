import SwiftUI

struct AboutView: View {
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (version?, build?) where version != build:
            return "Version \(version) (\(build))"
        case let (version?, _):
            return "Version \(version)"
        case (_, let build?):
            return "Build \(build)"
        default:
            return "Version unknown"
        }
    }

    // WICHTIG (Layout-Falle): Wie ALLE Settings-Detail-Seiten eine Form —
    // der frühere zentrierte Plain-VStack (`maxHeight: .infinity`) überlief
    // bei knapper Fensterhöhe unclipped nach OBEN über die Titelleiste,
    // die daraufhin fürs ganze Fenster kollabierte und auch die Sidebar
    // hinter die Ampel-Buttons schob (reproduziert 2026-07-03, nur auf
    // dieser Seite). Eine Form scrollt statt zu überlaufen.
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    Text("WhisperM8")
                        .font(.title2.bold())

                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Native macOS dictation with AI transcription")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Updates") {
                AboutUpdateSection()
            }

            Section {
                HStack {
                    Spacer()
                    Link("Built by 360WebManager", destination: URL(string: "https://360web-manager.com/")!)
                        .font(.caption)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}
