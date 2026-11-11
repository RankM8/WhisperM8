import AppKit
import SwiftUI

/// Dialog der Sammel-Erneuerung: Konten wählen, starten, je Konto im Browser
/// bestätigen. Zeigt nur den Stand der `ClaudeLoginRenewalSession`; alle
/// Zustände und Aktionen sind ohne Hover sichtbar.
struct ClaudeLoginRenewalSheet: View {
    @Bindable var session: ClaudeLoginRenewalSession
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var now: Date = Date()

    @Environment(\.dismiss) private var dismiss
    @State private var pastedCode = ""

    static let signOutURL = URL(string: "https://claude.ai/logout")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Renew Claude logins")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button("Close") {
                    session.stop()
                    dismiss()
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }

            Text("Every Claude login ends 30 days after sign-in, no matter how much you use it. For each account your browser opens the Claude sign-in with the email filled in — confirm the link from the email and approve. An account only changes once the right one is signed in.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.rows) { row in
                        rowView(row)
                    }
                }
            }
            .frame(maxHeight: 360)

            if session.claudeMissing {
                Text("Claude CLI not found — install Claude Code first.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.statusError)
            }

            HStack(spacing: 10) {
                if session.isRunning {
                    Button("Stop") { session.stop() }
                        .buttonStyle(SettingsButtonStyle.standard)
                } else {
                    Button(startButtonTitle) { session.start() }
                        .buttonStyle(SettingsButtonStyle.primary)
                        .disabled(session.selectedCount == 0 || session.claudeMissing)
                }
                Spacer()
                Text(progressText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(AppTheme.background)
    }

    // MARK: - Zeile

    @ViewBuilder
    private func rowView(_ row: ClaudeLoginRenewalSession.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { row.isSelected },
                    set: { session.setSelected($0, for: row.name) }
                )) {
                    Text(verbatim: row.name)
                }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(session.isRunning || row.status.isDone)
                .accessibilityLabel(Text(verbatim: row.name))

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(verbatim: row.email)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: 210, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if row.status == .waitingForBrowser {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(verbatim: statusText(row))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(statusColor(row))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            if row.status == .waitingForBrowser, session.currentName == row.name {
                waitingControls
                    .padding(.leading, 30)
            }
            if case .wrongAccount = row.status {
                Button("Sign out on claude.ai") { openURL(Self.signOutURL) }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }

    /// Aktionen, solange die CLI auf den Browser wartet.
    private var waitingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Open sign-in page again") {
                    if let url = session.loginURL { openURL(url) }
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(session.loginURL == nil)

                Button("Skip this account") { session.skipCurrent() }
                    .buttonStyle(SettingsButtonStyle.standard)
            }

            HStack(spacing: 8) {
                TextField("Code from the browser, if it shows one", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 300)
                    .onSubmit(submitCode)
                Button("Submit code", action: submitCode)
                    .buttonStyle(SettingsButtonStyle.standard)
                    .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitCode() {
        session.submit(code: pastedCode)
        pastedCode = ""
    }

    // MARK: - Texte

    private var startButtonTitle: String {
        let count = session.selectedCount
        let paused = session.rows.contains { row in
            if case .wrongAccount = row.status { return true }
            return false
        }
        if paused { return String(localized: "Continue") }
        if count == 1 { return String(localized: "Renew 1 login") }
        return String(localized: "Renew \(count) logins")
    }

    private var progressText: String {
        let done = session.renewedCount
        guard done > 0 else { return "" }
        if done == 1 { return String(localized: "1 login renewed") }
        return String(localized: "\(done) logins renewed")
    }

    private func statusText(_ row: ClaudeLoginRenewalSession.Row) -> String {
        switch row.status {
        case .pending:
            return row.expiry?.summary(now: now) ?? ""
        case .waitingForBrowser:
            return String(localized: "Waiting for your browser — confirm the sign-in there")
        case .renewed(let endsAt):
            guard let endsAt else { return String(localized: "Renewed") }
            let day = endsAt.formatted(.dateTime.day().month(.abbreviated))
            return String(localized: "Renewed — valid until \(day)")
        case .wrongAccount(let signedInAs):
            guard let signedInAs else {
                return String(localized: "Your browser was signed in with another account. Sign out there, then continue.")
            }
            return String(localized: "Your browser was signed in as \(signedInAs). Sign out there, then continue.")
        case .skipped:
            return String(localized: "Skipped")
        case .timedOut:
            return String(localized: "No confirmation within 10 minutes")
        case .failed(let message):
            return message
        }
    }

    private func statusColor(_ row: ClaudeLoginRenewalSession.Row) -> Color {
        switch row.status {
        case .pending:
            switch row.expiry?.urgency(now: now) ?? .none {
            case .none: return AppTheme.textTertiary
            case .soon, .urgent: return AppTheme.statusAwaiting
            case .ended: return AppTheme.statusError
            }
        case .waitingForBrowser:
            return AppTheme.textPrimary
        case .renewed:
            return AppTheme.statusWorking
        case .skipped:
            return AppTheme.textTertiary
        case .wrongAccount, .timedOut:
            return AppTheme.statusAwaiting
        case .failed:
            return AppTheme.statusError
        }
    }
}
