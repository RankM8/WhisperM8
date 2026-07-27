import Foundation

// ==============================================================================
// Zustandslogik des Voice Gates.
//
// Der Codex-Shortcut ist ein BLINDER Toggle: er schaltet um, verraet aber
// nicht, wohin. Der wahre Mute-Zustand ist von aussen nicht lesbar. Diese
// Maschine fuehrt deshalb eine ANNAHME und macht sie an drei Stellen robust:
//
//   1. Absicht statt Toggle — „Jarvis Pause" mutet nur, wenn wir offen glauben.
//   2. Wiederholung ueberstimmt — dieselbe Phrase nochmal binnen weniger
//      Sekunden heisst „deine Annahme war falsch", und es wird gedrueckt.
//      Damit hat der Mensch die Selbstkorrektur des Toggles zurueck, ohne
//      dessen Richtungs-Blindheit.
//   3. Passiver Abgleich — empfaengt Codex nachweislich Sprache, ist die
//      Annahme „stumm" widerlegt und wird still korrigiert.
// ==============================================================================

enum VoiceGateAssumedState: String, Equatable {
    /// Codex hoert (Mikrofon frei).
    case open
    /// Codex ist stummgeschaltet.
    case muted
    /// Nach App-Start oder nach einer unbestaetigten Ausfuehrung.
    case unknown
}

enum VoiceGateSkipReason: String, Equatable {
    /// Zu kurz nach der letzten Ausfuehrung — Doppelausloesung.
    case cooldown
    /// Zielzustand laut Annahme bereits erreicht.
    case alreadyInTargetState
}

enum VoiceGatePressReason: String, Equatable {
    /// Annahme und Wunsch weichen ab — der Normalfall.
    case stateMismatch
    /// Annahme sagte „schon erledigt", der Mensch hat widersprochen.
    case repeatOverride
    /// Zustand unbekannt — im Zweifel ausfuehren.
    case unknownState
}

enum VoiceGateAction: Equatable {
    case press(intent: VoiceGateIntent, reason: VoiceGatePressReason)
    case skip(VoiceGateSkipReason)
}

struct VoiceGateStateMachine {
    /// Sperrfrist nach einer Ausfuehrung.
    var cooldown: TimeInterval = 2.5
    /// Fenster, in dem eine Wiederholung als Widerspruch gilt.
    var repeatOverrideWindow: TimeInterval = 4.0

    private(set) var assumed: VoiceGateAssumedState = .unknown
    private(set) var lastPressAt: Date?

    /// Letzte ÜBERSPRUNGENE Absicht. Bewusst nicht die letzte Absicht
    /// ueberhaupt: nach einem erfolgreichen Druck waere eine Wiederholung
    /// kein Widerspruch, sondern eine Doppelerkennung — und wuerde den
    /// gerade erfolgten Druck rueckgaengig machen.
    private var lastSkippedIntent: VoiceGateIntent?
    private var lastSkippedAt: Date?

    init(assumed: VoiceGateAssumedState = .unknown) {
        self.assumed = assumed
    }

    // MARK: - Entscheidung

    mutating func handle(_ intent: VoiceGateIntent, now: Date) -> VoiceGateAction {
        if let lastPressAt, now.timeIntervalSince(lastPressAt) < cooldown {
            return .skip(.cooldown)
        }

        let target = Self.targetState(for: intent)

        guard assumed == target else {
            return .press(intent: intent, reason: assumed == .unknown ? .unknownState : .stateMismatch)
        }

        // Annahme sagt „schon im Zielzustand". Nur die Wiederholung eines
        // zuvor ÜBERSPRUNGENEN Befehls ueberstimmt das — dann hat der Mensch
        // gemerkt, dass nichts passiert ist, und widerspricht.
        if lastSkippedIntent == intent,
           let lastSkippedAt,
           now.timeIntervalSince(lastSkippedAt) <= repeatOverrideWindow {
            return .press(intent: intent, reason: .repeatOverride)
        }

        lastSkippedIntent = intent
        lastSkippedAt = now
        return .skip(.alreadyInTargetState)
    }

    // MARK: - Rueckmeldung der Ausfuehrung

    /// Die Ausfuehrung gilt als bestaetigt — Annahme uebernehmen.
    mutating func confirmPress(_ intent: VoiceGateIntent, now: Date) {
        assumed = Self.targetState(for: intent)
        lastPressAt = now
        clearSkipMemory()
    }

    /// Ausfuehrung nicht nachweisbar. Lieber ehrlich unbekannt als falsch
    /// sicher: der naechste Befehl drueckt dann in jedem Fall.
    mutating func failPress(now: Date) {
        assumed = .unknown
        lastPressAt = now
        clearSkipMemory()
    }

    private mutating func clearSkipMemory() {
        lastSkippedIntent = nil
        lastSkippedAt = nil
    }

    // MARK: - Passiver Abgleich

    /// Codex hat nachweislich Sprache empfangen ⇒ es ist nicht stumm.
    ///
    /// Bewusst asymmetrisch: Ausbleibender Empfang beweist NICHTS (der Mensch
    /// koennte einfach schweigen), deshalb korrigiert nur der positive Fall.
    mutating func observeCodexReceivedAudio() {
        assumed = .open
    }

    /// Manuelle Korrektur aus der Menueleiste.
    mutating func setAssumed(_ state: VoiceGateAssumedState) {
        assumed = state
    }

    static func targetState(for intent: VoiceGateIntent) -> VoiceGateAssumedState {
        switch intent {
        case .mute: return .muted
        case .unmute: return .open
        }
    }
}
