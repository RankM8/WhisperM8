import AppKit
import SwiftUI

/// Geteilte UI-Bausteine für die Transcription-Provider-/API-Key-Konfiguration.
/// Werden sowohl in den Settings (`APISettingsView`) als auch im Onboarding
/// (`APIKeyStep`) verwendet, damit beide Screens konsistent sind und Groq als
/// empfohlener Provider zuerst erscheint.

/// Segmented Provider-Picker in `TranscriptionProvider.displayOrder` (Groq zuerst),
/// darunter eine dezente Empfehlungszeile (Badge + Hinweis) für den empfohlenen Provider.
struct TranscriptionProviderPicker: View {
    @Binding var provider: TranscriptionProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provider", selection: $provider) {
                ForEach(TranscriptionProvider.displayOrder, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            // Empfehlung dezent unter dem Picker. Kontextabhängig zum ausgewählten
            // Provider — da Groq per Default vorausgewählt ist, sofort sichtbar.
            if let badge = provider.recommendationBadge {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)

                    if let hint = provider.recommendationHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// API-Key-Feld, das einen bereits gespeicherten Key maskiert als „vorhanden"
/// signalisiert (Dots-Placeholder), ohne den echten Wert je offenzulegen — der echte
/// Key wird nie in `text` geladen; `text` enthält ausschließlich frisch getippte Eingaben.
/// Enthält den Show/Hide-Eye-Toggle. Basiert auf `FocusableTextField` (funktioniert in
/// LSUIElement-/Menüleisten-Kontext wie auch in normalen Fenstern).
struct MaskedAPIKeyField: View {
    @Binding var text: String
    /// Ein Key liegt bereits in der Keychain.
    var hasSavedKey: Bool
    /// Provider-Name für den Placeholder, wenn noch kein Key gespeichert ist.
    var providerName: String

    @State private var isRevealed = false

    /// Fixe Dots-Länge — signalisiert „Key vorhanden", ohne die echte Länge zu verraten.
    private static let maskedPlaceholder = String(repeating: "•", count: 16)

    private var placeholder: String {
        if hasSavedKey {
            return Self.maskedPlaceholder
        }
        return "\(providerName) API key…"
    }

    var body: some View {
        HStack {
            FocusableTextField(
                text: $text,
                placeholder: placeholder,
                isSecure: !isRevealed
            )
            // `isSecure` bestimmt die NSView-Klasse (NSSecureTextField vs. NSTextField)
            // und kann nicht in-place wechseln — die Identität muss sich ändern, damit
            // makeNSView neu läuft und der Eye-Toggle tatsächlich wirkt.
            .id(isRevealed)
            .frame(height: 22)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Hide typed key" : "Show typed key")
        }
    }
}

/// Grüne „API key is saved in Keychain"-Statuszeile. Nur sinnvoll sichtbar, wenn ein Key
/// gespeichert ist und aktuell nichts Neues getippt wurde.
struct TranscriptionKeychainStatusLabel: View {
    var body: some View {
        Label("API key is saved in Keychain", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
    }
}
