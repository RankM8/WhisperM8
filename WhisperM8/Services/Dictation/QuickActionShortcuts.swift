import AppKit
import KeyboardShortcuts

/// Kurzbefehle „ohne Diktat“: je Modus einer. Ab Werk belegt ist nur
/// Korrigieren mit ⇧⌘K (Entscheidung Giuliano, 05.11.2026); alle anderen
/// Modi sind leer, bis der Nutzer selbst einen aufnimmt.
enum QuickActionShortcuts {
    static let namePrefix = "quickAction."

    /// Standard für Korrigieren. Weder macOS noch WhisperM8 belegen ⇧⌘K; als
    /// globaler Kurzbefehl überdeckt er aber gleichnamige Befehle einzelner
    /// Apps (etwa Xcode „Clean Build Folder“, VS Code „Zeile löschen“).
    static let correctDefault = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])

    /// `default` greift nur, solange der Nutzer nichts gespeichert hat. Wer den
    /// Kurzbefehl entfernt, behält das (die Bibliothek merkt sich „aus“).
    static func name(for modeID: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name(namePrefix + modeID, default: defaultShortcut(for: modeID))
    }

    static func defaultShortcut(for modeID: String) -> KeyboardShortcuts.Shortcut? {
        modeID == OutputMode.correctID ? correctDefault : nil
    }

    /// Vorschlag, der in den Einstellungen angeboten wird, wenn kein
    /// Kurzbefehl gesetzt ist. Nur für die beiden Schreib-Modi.
    static func suggestion(for modeID: String) -> KeyboardShortcuts.Shortcut? {
        switch modeID {
        case OutputMode.correctID: return correctDefault
        case OutputMode.rephraseID: return .init(.r, modifiers: [.control, .option])
        default: return nil
        }
    }

    /// Modi, die einen Kurzbefehl bekommen können: alle mit Nacharbeit.
    static func eligibleModes(_ modes: [OutputMode]) -> [OutputMode] {
        modes.filter(\.usesPostProcessing)
    }

    /// Andere WhisperM8-Kurzbefehle, mit denen sich ein Schnellaktions-
    /// Kurzbefehl nicht überschneiden darf (der Recorder prüft nur System
    /// und Hauptmenü). Rückgabe: Anzeigename des Konflikts.
    static func conflict(
        for shortcut: KeyboardShortcuts.Shortcut?,
        excluding modeID: String,
        modes: [OutputMode],
        lookup: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: $0) }
    ) -> String? {
        guard let shortcut else { return nil }
        let fixed: [(KeyboardShortcuts.Name, String)] = [
            (.toggleRecording, String(localized: "Recording hotkey")),
            (.clipboardHistory, String(localized: "Clipboard history")),
            (.toggleNotchStatus, String(localized: "Notch display")),
        ]
        for (name, label) in fixed where lookup(name) == shortcut {
            return label
        }
        for mode in eligibleModes(modes) where mode.id != modeID && lookup(name(for: mode.id)) == shortcut {
            return mode.displayName
        }
        return nil
    }
}

/// Meldet die Kurzbefehle aller Modi an und folgt neuen Modi. Ein Handler je
/// Name; gelöschte Modi verlieren beim Löschen ihre Belegung, ihr Handler
/// findet den Modus dann nicht mehr und tut nichts.
@MainActor
final class QuickActionHotkeys {
    static let shared = QuickActionHotkeys()

    private var registeredModeIDs = Set<String>()
    private var modesObserver: NSObjectProtocol?

    func start(onTrigger: @escaping @MainActor (String) -> Void) {
        guard modesObserver == nil else { return }
        register(onTrigger: onTrigger)
        modesObserver = NotificationCenter.default.addObserver(
            forName: OutputModeStore.modesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.register(onTrigger: onTrigger) }
        }
    }

    private func register(onTrigger: @escaping @MainActor (String) -> Void) {
        for mode in QuickActionShortcuts.eligibleModes(OutputModeStore().modes)
        where registeredModeIDs.insert(mode.id).inserted {
            let modeID = mode.id
            KeyboardShortcuts.onKeyDown(for: QuickActionShortcuts.name(for: modeID)) {
                Task { @MainActor in onTrigger(modeID) }
            }
        }
    }
}
