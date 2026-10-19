import SwiftUI

/// Zustand + Aktionen der geführten CLI-Installation (Onboarding, Einstellungen,
/// Leerzustand beim Chatstart). Alle Abhängigkeiten sind injiziert — Tests und
/// Snapshots fassen nie ein echtes `brew` an.
@MainActor
@Observable
final class AgentCLIInstallModel {
    enum Phase: Equatable {
        case idle
        case installing
        case failed(String)
    }

    let cli: AgentCLI
    private(set) var state: AgentCLIState
    private(set) var phase: Phase = .idle
    private(set) var logTail = ""
    var isConfirming = false

    private let resolver: AgentCLIResolver
    private let installer: AgentCLIInstaller

    init(
        cli: AgentCLI,
        initialState: AgentCLIState? = nil,
        resolver: AgentCLIResolver = .live,
        installer: AgentCLIInstaller? = nil
    ) {
        self.cli = cli
        self.resolver = resolver
        var inst = installer ?? AgentCLIInstaller()
        inst.resolver = resolver
        self.installer = inst
        // Ohne Vorgabe zunächst „fehlt, kein Homebrew"-neutral: der erste recheck() füllt es.
        self.state = initialState ?? .missingNoHomebrew
    }

    /// Auflösung off-main (`which` + Dateiprüfungen sind Subprozess-/I/O-Arbeit).
    func recheck() async {
        let resolver = resolver
        let cli = cli
        let newState = await Task.detached(priority: .userInitiated) {
            resolver.state(of: cli)
        }.value
        state = newState
        if newState.isInstalled { phase = .idle }
    }

    func requestInstall() {
        guard case .missingCanInstall = state else { return }
        isConfirming = true
    }

    /// Nach ausdrücklicher Bestätigung des Nutzers.
    func confirmInstall() async {
        isConfirming = false
        phase = .installing
        logTail = ""
        let outcome = await installer.install(cli) { [weak self] chunk in
            Task { @MainActor in self?.appendLog(chunk) }
        }
        switch outcome {
        case .installed, .alreadyInstalled:
            phase = .idle
        case .homebrewMissing:
            phase = .idle
        case .failed(let message):
            phase = .failed(message)
        case .timedOut:
            phase = .failed(String(localized: "The installation took too long and was stopped. Try again or use the official instructions."))
        }
        await recheck()
    }

    private func appendLog(_ chunk: String) {
        let combined = logTail + chunk
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: true).suffix(4)
        logTail = lines.joined(separator: "\n")
    }
}

/// Geführter Installationsblock. `loginHint` erscheint, sobald die CLI da ist.
struct AgentCLIInstallPanel: View {
    @Bindable var model: AgentCLIInstallModel
    var loginHint: Text?
    /// Wird nach erfolgreicher Prüfung/Installation gemeldet (z. B. Sheet schließen).
    var onInstalled: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .installed(let path):
                Label {
                    Text("\(model.cli.displayName) is installed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.headline)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let loginHint {
                    loginHint
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .missingCanInstall:
                missingHeader
                installActions

            case .missingNoHomebrew:
                missingHeader
                Text("Homebrew is not installed on this Mac. Install Homebrew first, or follow the official instructions for \(model.cli.displayName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("Get Homebrew", destination: AgentCLI.homebrewURL)
                    Link("Official instructions", destination: model.cli.documentationURL)
                }
                .font(.callout)
            }

            if case .failed(let message) = model.phase {
                Label {
                    Text(message).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            if model.phase == .installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing \(model.cli.displayName)…")
                }
                if !model.logTail.isEmpty {
                    Text(model.logTail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !model.state.isInstalled {
                Button("Check Again") {
                    Task {
                        await model.recheck()
                        if model.state.isInstalled { onInstalled?() }
                    }
                }
                .disabled(model.phase == .installing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.recheck() }
        .confirmationDialog(
            "Install \(model.cli.displayName)?",
            isPresented: $model.isConfirming,
            titleVisibility: .visible
        ) {
            Button("Install") {
                Task {
                    await model.confirmInstall()
                    if model.state.isInstalled { onInstalled?() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WhisperM8 will run “\(AgentCLIInstaller.displayCommand(for: model.cli))” with Homebrew. Nothing else is changed on your Mac.")
        }
    }

    private var missingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(model.cli.displayName) is not installed yet")
            } icon: {
                Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
            }
            .font(.headline)
            if model.cli == .claude {
                Text("Chats run the real Claude Code CLI. If you prefer Anthropic's own installer, follow the official instructions and then check again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var installActions: some View {
        HStack {
            Button("Install with Homebrew…") { model.requestInstall() }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase == .installing)
            Link("Official instructions", destination: model.cli.documentationURL)
                .font(.callout)
        }
    }
}

// MARK: - Chatstart ohne CLI (LR-AU-022)

/// Pur: Fehlt für diesen Chatstart die CLI? Terminals brauchen nur die Shell.
enum AgentChatStartGate {
    static func missingCLI(
        provider: AgentProvider,
        kind: AgentSessionKind?,
        commandResolver: (String) -> String?
    ) -> AgentCLI? {
        if kind == .terminal { return nil }
        let cli: AgentCLI = provider == .codex ? .codex : .claude
        return commandResolver(cli.commandName) == nil ? cli : nil
    }

    /// `AgentCommandError.commandNotFound("Claude" | "Codex")` → CLI.
    static func cli(forCommandName name: String) -> AgentCLI {
        name.lowercased().hasPrefix("codex") ? .codex : .claude
    }
}

/// Geführter Leerzustand statt des 12-pt-Balkens: Titel, Installationsweg,
/// „Erneut prüfen" und Login-Hinweis. Legt selbst keine Session an.
struct AgentCLIMissingView: View {
    let cli: AgentCLI
    var onInstalled: () -> Void
    @State private var model: AgentCLIInstallModel

    init(cli: AgentCLI, onInstalled: @escaping () -> Void) {
        self.cli = cli
        self.onInstalled = onInstalled
        _model = State(initialValue: AgentCLIInstallModel(cli: cli))
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("\(cli.displayName) is not installed yet")
                .font(.headline)
            AgentCLIInstallPanel(
                model: model,
                loginHint: cli == .claude
                    ? Text("Next time you start a chat, Claude Code opens here and walks you through signing in.")
                    : Text("Sign in with your ChatGPT account under Settings → AI Output."),
                onInstalled: onInstalled
            )
            .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Sheet für „Neuer Chat" ohne CLI.
struct AgentCLIMissingSheet: View {
    let prompt: MissingCLIPrompt
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgentCLIMissingView(cli: prompt.cli, onInstalled: {})
                .frame(minHeight: 280)
            Divider()
            HStack {
                Button("Close", action: onClose)
                Spacer()
                Button("Start Chat") {
                    onClose()
                    prompt.retry()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480)
    }
}

struct MissingCLIPrompt: Identifiable {
    let id = UUID()
    let cli: AgentCLI
    /// Startet den ursprünglich gewünschten Chat erneut (nach Installation).
    let retry: () -> Void
}
