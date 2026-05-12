import SwiftUI

/// Modal-Sheet, das auftaucht wenn der `ClaudeActiveSessionTracker` oder
/// die Resume-Recovery mehrere Kandidaten gefunden hat und nicht
/// automatisch rebinden konnte. Der Nutzer waehlt explizit, welche
/// externe Conversation zu diesem Tab gehoeren soll — oder beginnt eine
/// neue Session.
struct AgentSessionAmbiguousRebindPicker: View {
    let request: AmbiguousRebindRequest
    /// Aufgerufen mit `nil` wenn der Nutzer "Neue Session" gewaehlt hat;
    /// sonst mit der externen Session-ID des gewaehlten Kandidaten.
    let onChoice: (_ externalSessionID: String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.candidates, id: \.externalSessionID) { candidate in
                        candidateRow(candidate)
                    }
                    Divider().padding(.vertical, 4)
                    Button {
                        onChoice(nil)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            VStack(alignment: .leading) {
                                Text("Neue Session starten")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Wirft die alte externe Session-ID weg und beginnt frisch")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AgentTheme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AgentTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }

            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(minWidth: 460, minHeight: 320)
        .background(AgentTheme.background)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welche Claude-Session gehoert zu diesem Tab?")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
            Text("WhisperM8 hat mehrere passende Sessions gefunden. Bitte waehle die richtige aus oder starte eine neue.")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func candidateRow(_ candidate: IndexedAgentSession) -> some View {
        Button {
            onChoice(candidate.externalSessionID)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AgentTheme.textPrimary)
                    HStack(spacing: 6) {
                        Text(relative(candidate.lastActivityAt))
                        Text("·")
                        Text(candidate.externalSessionID.prefix(8) + "…")
                            .monospaced()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
                }
                Spacer()
            }
            .padding(10)
            .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AgentTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
