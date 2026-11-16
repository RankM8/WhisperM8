import SwiftUI

/// „→ Jarvis“ in der Triage: legt Nummer, Titel und Adresse ins Eingabefeld
/// des Board-Chats. Steht nur da, wenn dieses Fenster einen sichtbaren
/// Board-Chat hat.
struct BoardChatHandOffButton: View {
    let windowID: UUID
    var inputs: BoardChatInputs = .shared

    var body: some View {
        if let chat = inputs.boardChat(in: windowID) {
            Button { inputs.handOff(in: windowID) } label: {
                Text(verbatim: "→ \(chat.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AgentTheme.accent, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Put number, title and link into the input field of \(chat.name). Nothing is sent until you press Return."))
            .accessibilityLabel(String(localized: "Hand ticket to \(chat.name)"))
        }
    }
}

/// Leiste unter dem Terminal des Board-Chats: der Bezug vor der nächsten
/// Nachricht (mit ✕ weg) und der Hinweis, wenn nichts eingefügt wurde.
/// Eigene Ansicht: Nur sie beobachtet die Triage, J/K wertet die Spalte
/// samt Terminal nicht neu aus.
struct BoardChatInputBar: View {
    let windowID: UUID
    var inputs: BoardChatInputs = .shared

    var body: some View {
        let reference = inputs.reference(in: windowID)
        let notice = inputs.notices[windowID]
        if reference != nil || notice != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let notice {
                    Text(verbatim: notice.text)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AgentTheme.statusAwaiting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reference {
                    BoardChatReferenceChip(ticketKey: reference.key) { inputs.dismissReference(in: windowID) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// „Bezug: WM8-81 ✕“ in einer Zeile. Wann er mitgeht, sagt die Erklärung
/// beim ersten Öffnen (`BoardChatIntro`) und die Hilfe an der Marke (WM8-124).
struct BoardChatReferenceChip: View {
    let ticketKey: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Re: \(ticketKey)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AgentTheme.accent)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AgentTheme.accent)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove the reference"))
            .accessibilityLabel(String(localized: "Remove the reference to \(ticketKey)"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(AgentTheme.accentTintSoft, in: RoundedRectangle(cornerRadius: 5))
        .help(String(localized: "Goes in front of your next dictation: number, title and link."))
    }
}

/// Meldet den Board-Chat des Fensters an, solange sein Terminal in der Spalte
/// steht, und wieder ab, sobald es verschwindet. Mit eigenem Zeichen: Baut
/// SwiftUI die Ansicht neu, kommt das Verschwinden der alten Instanz manchmal
/// erst nach dem Erscheinen der neuen und darf diese dann nicht abmelden.
struct BoardChatRegistrationModifier: ViewModifier {
    let windowID: UUID
    let sessionID: UUID
    let name: String
    let changed: () -> Void
    var inputs: BoardChatInputs = .shared

    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .task(id: "\(sessionID)|\(name)") {
                inputs.register(windowID: windowID, sessionID: sessionID, name: name, token: token)
                changed()
            }
            .onDisappear {
                inputs.unregister(windowID: windowID, token: token)
                changed()
            }
    }
}

/// Triage-Knöpfe unter der Leiste der Triage (Teil d): sammeln Entscheidungen
/// im Eingabefeld des Board-Chats und gehen zum nächsten Ticket. Stehen nur
/// da, wenn dieses Fenster einen sichtbaren Board-Chat hat.
struct BoardChatTriageButtons: View {
    let windowID: UUID
    let ticketKey: String
    /// Nach einer gesammelten Entscheidung: nächstes Ticket.
    let next: () -> Void
    var inputs: BoardChatInputs = .shared

    var body: some View {
        if let chat = inputs.boardChat(in: windowID) {
            let current = inputs.triageDecision(for: ticketKey, in: windowID)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Triage, collected for \(chat.name):")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .fixedSize()
                    ForEach(TriageDecision.allCases, id: \.self) { decision in
                        Button {
                            if inputs.decide(decision, in: windowID) { next() }
                        } label: {
                            Text(verbatim: decision.label)
                                .font(.system(size: 12, weight: decision == current ? .semibold : .regular))
                                .foregroundStyle(decision == current ? AgentTheme.accent : AgentTheme.textPrimary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(decision == current ? AgentTheme.accentTintSoft : AgentTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AgentTheme.border))
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Adds “\(decision.instruction)” for \(ticketKey) to the input field of \(chat.name). Nothing is sent until you press Return there."))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

/// „→ Annehmen“ an einer Zeile der Triage-Liste: Was für dieses Ticket gesammelt ist.
struct BoardChatTriageMark: View {
    let windowID: UUID
    let ticketKey: String
    var inputs: BoardChatInputs = .shared

    var body: some View {
        if let decision = inputs.triageDecision(for: ticketKey, in: windowID) {
            Text(verbatim: "→ \(decision.label.replacingOccurrences(of: "…", with: "")) · " + String(localized: "collected"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AgentTheme.accent)
        }
    }
}
