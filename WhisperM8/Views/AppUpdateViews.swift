import AppKit
import SwiftUI

/// Update-Badge für den Sidebar-Footer: erscheint NUR, wenn der
/// `AppUpdateChecker` eine neuere Version gefunden hat — im Alltag bleibt der
/// Footer unverändert ruhig. Eigenständiges View mit eigener Subscription,
/// damit Checker-State-Wechsel nicht den großen AgentChatsView-Body
/// invalidieren.
struct SidebarUpdateBadge: View {
    @ObservedObject private var checker = AppUpdateChecker.shared
    @State private var showPopover = false

    var body: some View {
        if case .available(let info) = checker.state {
            Button {
                showPopover = true
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.accent)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Version \(info.latestVersion) verfügbar — jetzt aktualisieren")
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                AppUpdateDetailsView(info: info)
                    .padding(14)
                    .frame(width: 340)
            }
        }
    }
}

/// Inhalt des Update-Popovers (auch inline in Settings → About verwendet):
/// Versionsvergleich, kopierbarer Homebrew-Befehl bzw. Release-Link, ehrliche
/// Hinweise auf Neustart + erneute Permission-Abfragen (self-signed Builds).
struct AppUpdateDetailsView: View {
    let info: AppUpdateChecker.UpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(info.latestVersion.description) verfügbar")
                    .font(.system(size: 13, weight: .semibold))
                Text("Installiert: \(info.currentVersion.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Updates laufen bewusst IMMER über Homebrew — die App ist
            // self-signed (keine Apple-Lizenz/Notarisierung), das DMG bräuchte
            // einen manuellen Quarantäne-Befehl. Der Cask erledigt das
            // automatisch. Primär steht deshalb überall der offizielle
            // Update-Befehl aus der README.
            CopyableCommandBox(command: AppUpdateChecker.brewUpgradeCommand)

            Text("Im Terminal ausführen. Beim anschließenden Neustart werden laufende Agent-Chats beendet; macOS fragt Berechtigungen danach erneut ab.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !info.isBrewInstall {
                // Ohne Cask-Receipt schlägt `brew upgrade` fehl — Fußnote für
                // DMG-/Source-Installationen: einmalig den Cask übernehmen.
                Text("Noch nicht über Homebrew installiert? Einmalig:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                CopyableCommandBox(command: AppUpdateChecker.brewAdoptCommand)
            }

            Link("Release-Notes ansehen", destination: info.releaseURL)
                .font(.caption)
        }
    }

}

/// Kopierbare Terminal-Befehlszeile mit eigenem Copy-Feedback pro Box.
///
/// WICHTIG (Crash-Falle): Diese Box lebt u. a. in einem `.popover`. Der
/// Copy-Feedback-Swap darf die Content-Größe NICHT (animiert) ändern —
/// `NSPopover` startet sonst eine animierte Fenster-Resize
/// (`PopoverHostingView.updateAnimatedWindowSize` → `NSMoveHelper`) und
/// segfaultet (EXC_BAD_ACCESS, reproduziert 2026-07-03). Deshalb: festes
/// Icon-Frame und bewusst KEIN `withAnimation`.
struct CopyableCommandBox: View {
    let command: String

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(didCopy ? .green : .secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Befehl kopieren")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

/// Update-Bereich für Settings → About: manueller Check + Statusanzeige.
struct AboutUpdateSection: View {
    @ObservedObject private var checker = AppUpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch checker.state {
            case .unknown:
                checkButton("Nach Updates suchen")
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Suche nach Updates …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .upToDate(let current):
                VStack(spacing: 4) {
                    Label("WhisperM8 \(current.description) ist aktuell", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    checkButton("Erneut suchen")
                }
            case .available(let info):
                AppUpdateDetailsView(info: info)
                    .frame(maxWidth: 360)
            case .failed(let message):
                VStack(spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    checkButton("Erneut versuchen")
                }
            }
        }
    }

    private func checkButton(_ title: String) -> some View {
        Button(title) {
            Task { await checker.checkNow() }
        }
        .font(.caption)
    }
}
