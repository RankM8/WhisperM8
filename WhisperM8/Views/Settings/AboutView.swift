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

    var body: some View {
        VStack(spacing: 16) {
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

            Divider()

            AboutUpdateSection()

            Divider()

            Link("Built by 360WebManager", destination: URL(string: "https://360web-manager.com/")!)
                .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
