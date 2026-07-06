import AppKit
import SwiftUI

struct AboutSettingsPage: View {
    @ObservedObject private var checker = AppUpdateChecker.shared

    private static let websiteURL = URL(string: "https://360web-manager.com/")

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

    private var lastCheckedText: String? {
        guard let lastCheckedAt = checker.lastCheckedAt else {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastCheckedAt, relativeTo: Date()))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader

                SettingsSection("App") {
                    HStack(alignment: .center, spacing: 16) {
                        iconTile

                        VStack(alignment: .leading, spacing: 3) {
                            Text("WhisperM8")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(AppTheme.textPrimary)

                            Text(versionText)
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)

                            Text("Native macOS dictation with AI transcription")
                                .font(.system(size: 11.5))
                                .foregroundStyle(AppTheme.textTertiary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                    }
                }

                SettingsSection("Updates") {
                    VStack(alignment: .leading, spacing: 8) {
                        AboutUpdateSection()

                        if let lastCheckedText {
                            SettingsHelpText(lastCheckedText)
                        }
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                    }
                }

                SettingsSection("Credits") {
                    HStack {
                        if let websiteURL = Self.websiteURL {
                            Link("Built by 360WebManager", destination: websiteURL)
                                .font(.system(size: 11.5))
                        } else {
                            Text("Built by 360WebManager")
                                .font(.system(size: 11.5))
                                .foregroundStyle(AppTheme.textSecondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppTheme.background)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("About")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Version, updates, credits.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.control)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.borderStrong, lineWidth: 1)
                }

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 50, height: 50)
        }
        .frame(width: 64, height: 64)
    }
}
