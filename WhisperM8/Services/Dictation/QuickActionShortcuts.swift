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

    /// Nur zum Nachschlagen: derselbe Schlüssel, aber ohne `default`. Das
    /// Bauen eines Namens mit `default` schreibt den Standard in die
    /// Defaults, das soll beim bloßen Prüfen nicht passieren.
    static func lookupName(for modeID: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name(namePrefix + modeID)
    }

    /// Schlüssel, unter dem die Bibliothek den Kurzbefehl in den Defaults ablegt.
    static func storageKey(for modeID: String) -> String {
        "KeyboardShortcuts_" + namePrefix + modeID
    }

    /// Hat der Nutzer für Korrigieren noch nie etwas gespeichert, ⇧⌘K aber
    /// schon anders vergeben (Aufnahme-Hotkey, anderer Modus), wird der
    /// Standard nicht gesetzt, sondern als „aus“ gespeichert. Sonst lösten
    /// beide auf denselben Tastendruck aus. Läuft beim Start vor der Anmeldung.
    static func resolveCorrectDefault(
        modes: [OutputMode],
        defaults: UserDefaults = .standard,
        lookup: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: $0) }
    ) {
        let key = storageKey(for: OutputMode.correctID)
        guard defaults.object(forKey: key) == nil,
              conflict(for: correctDefault, excluding: OutputMode.correctID, modes: modes, lookup: lookup) != nil else { return }
        // „aus“ so ablegen, wie die Bibliothek es selbst tut (`false`). Direkt
        // statt über `setShortcut(nil)`: das wirkt nur, wenn schon ein Wert
        // gespeichert ist, und meldete ⇧⌘K vorher kurz systemweit an. Steht
        // der Schlüssel, schreibt `Name(…, default:)` den Standard nicht mehr.
        defaults.set(false, forKey: key)
    }

    /// Vorschlag, der in den Einstellungen angeboten wird, wenn kein
    /// Kurzbefehl gesetzt ist. Nur für Besser formulieren; Korrigieren hat
    /// seinen Standard und keinen Vorschlag-Knopf (Entscheidung 05.11.2026).
    static func suggestion(for modeID: String) -> KeyboardShortcuts.Shortcut? {
        modeID == OutputMode.rephraseID ? .init(.r, modifiers: [.control, .option]) : nil
    }

    /// Modi, die einen Kurzbefehl bekommen können: alle mit Nacharbeit.
    static func eligibleModes(_ modes: [OutputMode]) -> [OutputMode] {
        modes.filter(\.usesPostProcessing)
    }

    /// Feste WhisperM8-Kurzbefehle außerhalb der Schnellaktionen.
    static var fixedAppShortcuts: [(name: KeyboardShortcuts.Name, label: String)] {
        [
            (.toggleRecording, String(localized: "Recording hotkey")),
            (.clipboardHistory, String(localized: "Clipboard history")),
            (.toggleNotchStatus, String(localized: "Notch display")),
        ]
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
        for (name, label) in fixedAppShortcuts where lookup(name) == shortcut {
            return label
        }
        return quickActionUsing(shortcut, excluding: modeID, modes: modes, lookup: lookup)
    }

    /// Umgekehrte Richtung für die Recorder von Aufnahme, Verlauf und Notch:
    /// welche Schnellaktion nutzt diesen Kurzbefehl schon? Anzeigename des
    /// Modus oder `nil`.
    static func quickActionUsing(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        excluding modeID: String? = nil,
        modes: [OutputMode],
        lookup: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: $0) }
    ) -> String? {
        guard let shortcut else { return nil }
        return eligibleModes(modes)
            .first { $0.id != modeID && lookup(lookupName(for: $0.id)) == shortcut }?
            .displayName
    }

    /// Namen, die im Umfang „Nur Diktat“ abgemeldet werden. Ausgenommen sind
    /// Kurzbefehle, die zugleich ein fester App-Kurzbefehl sind: die
    /// Bibliothek meldet je Tastenkombination ab und nähme dem Aufnahme-Hotkey
    /// sonst seine Taste.
    static func namesToSuspend(
        modes: [OutputMode],
        lookup: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: $0) }
    ) -> [KeyboardShortcuts.Name] {
        let fixed = Set(fixedAppShortcuts.compactMap { lookup($0.name) })
        return eligibleModes(modes).map { lookupName(for: $0.id) }.filter { name in
            guard let shortcut = lookup(name) else { return false }
            return !fixed.contains(shortcut)
        }
    }
}

/// Meldet die Kurzbefehle aller Modi an und folgt neuen Modi. Ein Handler je
/// Name; gelöschte Modi verlieren beim Löschen ihre Belegung, ihr Handler
/// findet den Modus dann nicht mehr und tut nichts. Im Umfang „Nur Diktat“
/// gibt es keine Nacharbeit: dann sind die Kurzbefehle abgemeldet (andere
/// Apps bekommen ⇧⌘K zurück), gespeichert bleiben sie.
@MainActor
final class QuickActionHotkeys {
    static let shared = QuickActionHotkeys()

    /// Systemzugriffe; Tests ersetzen sie.
    struct Hooks {
        var modes: @MainActor () -> [OutputMode] = { OutputModeStore().modes }
        var isAvailable: @MainActor () -> Bool = { AppPreferences.shared.usageProfile.wantsCodexEnrichment }
        var addHandler: @MainActor (KeyboardShortcuts.Name, @escaping () -> Void) -> Void = { name, action in
            KeyboardShortcuts.onKeyDown(for: name, action: action)
        }
        var setEnabled: @MainActor (_ names: [KeyboardShortcuts.Name], _ enabled: Bool) -> Void = { names, enabled in
            if enabled { KeyboardShortcuts.enable(names) } else { KeyboardShortcuts.disable(names) }
        }
        var lookup: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: $0) }
        var resolveDefault: @MainActor ([OutputMode]) -> Void = { QuickActionShortcuts.resolveCorrectDefault(modes: $0) }
    }

    private let hooks: Hooks
    private var registeredModeIDs = Set<String>()
    private var modesObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?
    private var appliedAvailable: Bool?

    /// Meldung der Bibliothek, wenn ein Kurzbefehl gesetzt oder entfernt wird
    /// (dabei meldet sie ihn auch an). Ihr Name ist dort `internal`, der
    /// Text aber fest.
    static let shortcutDidChangeNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    init(hooks: Hooks = Hooks()) {
        self.hooks = hooks
    }

    func start(onTrigger: @escaping @MainActor (String) -> Void) {
        guard modesObserver == nil else { return }
        hooks.resolveDefault(hooks.modes())
        register(onTrigger: onTrigger)
        modesObserver = NotificationCenter.default.addObserver(
            forName: OutputModeStore.modesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.register(onTrigger: onTrigger)
                self?.applyScope(force: true)
            }
        }
        // Der Umfang liegt in den Defaults. Jede Änderung irgendeiner
        // Einstellung kommt hier an; `applyScope` tut nur beim echten Wechsel
        // des Umfangs etwas (ein Defaults-Wert lesen, sonst nichts).
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyScope() }
        }
        // Ein frisch aufgenommener Kurzbefehl ist sofort angemeldet; bei
        // „Nur Diktat“ wieder abmelden.
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: Self.shortcutDidChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name
            MainActor.assumeIsolated { self?.shortcutDidChange(name) }
        }
        applyScope(force: true)
    }

    private func register(onTrigger: @escaping @MainActor (String) -> Void) {
        for mode in QuickActionShortcuts.eligibleModes(hooks.modes())
        where registeredModeIDs.insert(mode.id).inserted {
            let modeID = mode.id
            hooks.addHandler(QuickActionShortcuts.name(for: modeID)) {
                Task { @MainActor in onTrigger(modeID) }
            }
        }
    }

    /// An- oder abmelden je nach Umfang, nur beim Wechsel (oder `force`).
    func applyScope(force: Bool = false) {
        let available = hooks.isAvailable()
        if !force, available == appliedAvailable { return }
        appliedAvailable = available
        let modes = hooks.modes()
        if available {
            hooks.setEnabled(QuickActionShortcuts.eligibleModes(modes).map { QuickActionShortcuts.lookupName(for: $0.id) }, true)
        } else {
            hooks.setEnabled(QuickActionShortcuts.namesToSuspend(modes: modes, lookup: hooks.lookup), false)
        }
    }

    /// Ein Kurzbefehl wurde gesetzt oder entfernt. Nur bei „Nur Diktat“ und
    /// nur für Schnellaktionen von Belang: die Bibliothek hat ihn gerade
    /// angemeldet.
    func shortcutDidChange(_ name: KeyboardShortcuts.Name?) {
        guard appliedAvailable == false, let name, name.rawValue.hasPrefix(QuickActionShortcuts.namePrefix) else { return }
        let suspend = QuickActionShortcuts.namesToSuspend(modes: hooks.modes(), lookup: hooks.lookup)
            .filter { $0.rawValue == name.rawValue }
        if !suspend.isEmpty { hooks.setEnabled(suspend, false) }
    }
}
