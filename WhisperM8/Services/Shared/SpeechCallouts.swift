import AVFoundation
import Foundation
import Observation

// MARK: - Gesprochene Ansagen (`whisperm8 speak`, Plan docs/plans/whisperm8-plugin.md §6)

/// Antwort auf eine Ansage — geht 1:1 als `status` an CLI und Mod.
enum SpeechCalloutOutcome: Equatable {
    /// Angenommen; `position` 1 = wird als Nächstes gesprochen.
    case queued(position: Int)
    /// Eine noch wartende Ansage derselben Session wurde ersetzt (neuere gewinnt).
    case replaced(position: Int)
    /// Stumm-Schalter an: angenommen, aber nicht gesprochen.
    case muted
    /// Dieselbe Session hat eben erst gesprochen.
    case debounced(retryAfterSeconds: Int)
    /// Nach dem Säubern blieb kein Text.
    case empty

    var status: String {
        switch self {
        case .queued: return "queued"
        case .replaced: return "replaced"
        case .muted: return "muted"
        case .debounced: return "debounced"
        case .empty: return "empty"
        }
    }

    var json: [String: Any] {
        var result: [String: Any] = ["status": status]
        switch self {
        case .queued(let position), .replaced(let position): result["position"] = position
        case .debounced(let seconds): result["retryAfterSeconds"] = seconds
        case .muted, .empty: break
        }
        return result
    }
}

/// Pure Textregeln: was gesprochen wird und wer spricht.
enum SpeechCalloutText {
    /// Höchstlänge nach dem Säubern. Der Skill verlangt höchstens zwei Sätze;
    /// das hier ist die Bremse, falls ein Modell es nicht tut.
    static let maxCharacters = 280

    /// Markdown-Zeichen raus, Zeilenumbrüche zu Leerzeichen, auf
    /// `maxCharacters` gekürzt: am letzten Satzende, sonst am letzten Wort.
    static func clean(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !"`*#>|".unicodeScalars.contains($0) }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > maxCharacters else { return collapsed }
        let head = String(collapsed.prefix(maxCharacters))
        if let end = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: end) >= maxCharacters / 2 {
            return String(head[...end])
        }
        if let space = head.lastIndex(of: " ") {
            return String(head[..<space]) + " …"
        }
        return head + " …"
    }

    /// Gesprochener Name des Chats: der Teil vor dem ersten Doppelpunkt
    /// („Jarvis: Supervisor ListM8“ → „Jarvis“), höchstens drei Wörter.
    static func spokenName(fromTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var name = trimmed
        if let colon = trimmed.firstIndex(of: ":") {
            let before = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            if before.count >= 3 { name = before }
        }
        let words = name.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    static func utterance(speaker: String?, text: String) -> String {
        guard let speaker, !speaker.isEmpty else { return text }
        return "\(speaker): \(text)"
    }
}

// MARK: - Stimme

/// Die eigentliche Sprachausgabe. `stop()` bricht still ab und ruft
/// `onFinish` NICHT — den Zustand führt das `SpeechCalloutCenter`.
@MainActor
protocol SpeechCalloutEngine: AnyObject {
    var onFinish: (() -> Void)? { get set }
    func speak(_ text: String)
    func stop()
}

/// Systemstimme (`AVSpeechSynthesizer`): lokal, kostenlos, sofort da.
@MainActor
final class SystemSpeechCalloutEngine: NSObject, SpeechCalloutEngine, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private let voiceIdentifier: () -> String?

    init(voiceIdentifier: @escaping () -> String? = { AppPreferences.shared.speechCalloutVoiceIdentifier }) {
        self.voiceIdentifier = voiceIdentifier
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(identifier: voiceIdentifier())
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Gewählte Stimme, sonst die beste installierte deutsche.
    static func voice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
        let best = german.max { lhs, rhs in
            precedes(lhs: (lhs.identifier, lhs.language, lhs.quality.rawValue),
                     rhs: (rhs.identifier, rhs.language, rhs.quality.rawValue))
        }
        return best ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    /// Premium vor Erweitert vor Standard, keine Eloquence-Stimmen („Grandpa“,
    /// „Rocko“ … — auf frischen Macs die Mehrheit), de-DE vor AT/CH, Anna als
    /// Apples deutsche Standardstimme vorn, sonst stabil nach Kennung.
    static func rank(identifier: String, language: String, quality: Int) -> [Int] {
        [
            identifier.contains(".eloquence.") ? 0 : 1,
            quality,
            language == "de-DE" ? 1 : 0,
            identifier.hasSuffix(".Anna") ? 1 : 0,
        ]
    }

    /// `true`, wenn `lhs` schlechter ist als `rhs` (für `max`); bei Gleichstand
    /// gewinnt die alphabetisch erste Kennung.
    static func precedes(lhs: (String, String, Int), rhs: (String, String, Int)) -> Bool {
        let l = rank(identifier: lhs.0, language: lhs.1, quality: lhs.2)
        let r = rank(identifier: rhs.0, language: rhs.1, quality: rhs.2)
        if l != r { return l.lexicographicallyPrecedes(r) }
        return lhs.0 > rhs.0
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onFinish?() }
    }
}

// MARK: - Warteschlange

/// Eine Warteschlange für alle Sessions: nie zwei Ansagen gleichzeitig, nie
/// während einer Diktat-Aufnahme (das Mikrofon nähme sie auf), höchstens eine
/// Ansage je Session in `debounceInterval`, Stumm-Schalter.
@MainActor
@Observable
final class SpeechCalloutCenter {
    struct Item: Equatable {
        let sessionID: UUID?
        let utterance: String
    }

    struct Dependencies {
        var isEnabled: () -> Bool
        var loadMuted: () -> Bool
        var storeMuted: (Bool) -> Void
        /// `true`, solange die Ansage warten muss (Aufnahme läuft).
        var isBlocked: @MainActor () -> Bool
        var now: () -> Date
        /// Erneuter Versuch nach einer Sperre.
        var schedule: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

        static let live = Dependencies(
            isEnabled: { AppPreferences.shared.isSpeechCalloutsEnabled },
            loadMuted: { AppPreferences.shared.isSpeechCalloutsMuted },
            storeMuted: { AppPreferences.shared.isSpeechCalloutsMuted = $0 },
            isBlocked: { AppState.shared.isRecording },
            now: Date.init,
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { action() } }
            }
        )
    }

    static let shared = SpeechCalloutCenter(engine: SystemSpeechCalloutEngine(), dependencies: .live)

    static let debounceInterval: TimeInterval = 20
    static let maxPending = 4
    /// Nach einem Aufnahme-Start: so lange nichts sprechen, auch wenn
    /// `isRecording` noch nicht gesetzt ist (Engine-Start ~0,4 s).
    static let recordingGrace: TimeInterval = 1.5
    static let retryInterval: TimeInterval = 0.5

    private(set) var isMuted: Bool
    private(set) var current: Item?
    private(set) var pending: [Item] = []

    @ObservationIgnored private let engine: SpeechCalloutEngine
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var lastAccepted: [UUID?: Date] = [:]
    @ObservationIgnored private var heldUntil: Date?
    @ObservationIgnored private var retryScheduled = false

    init(engine: SpeechCalloutEngine, dependencies: Dependencies) {
        self.engine = engine
        self.dependencies = dependencies
        self.isMuted = dependencies.loadMuted()
        engine.onFinish = { [weak self] in self?.didFinish() }
    }

    var isEnabled: Bool { dependencies.isEnabled() }

    /// Nimmt eine Ansage an oder lehnt sie begründet ab. `speaker` stellt die
    /// App voran („Jarvis: …“), nie das Modell.
    func enqueue(sessionID: UUID?, speaker: String?, text: String) -> SpeechCalloutOutcome {
        let cleaned = SpeechCalloutText.clean(text)
        guard !cleaned.isEmpty else { return .empty }
        guard !isMuted else {
            Logger.speechCallouts.info("callout_muted chars=\(cleaned.count, privacy: .public)")
            return .muted
        }
        let item = Item(sessionID: sessionID, utterance: SpeechCalloutText.utterance(speaker: speaker, text: cleaned))
        let now = dependencies.now()

        // Wartet von dieser Session noch eine Ansage, gewinnt die neuere.
        if let index = pending.firstIndex(where: { $0.sessionID == sessionID }) {
            pending[index] = item
            lastAccepted[sessionID] = now
            Logger.speechCallouts.info("callout_replaced chars=\(cleaned.count, privacy: .public)")
            return .replaced(position: index + 1 + (current == nil ? 0 : 1))
        }
        if let last = lastAccepted[sessionID], now.timeIntervalSince(last) < Self.debounceInterval {
            let wait = Int((Self.debounceInterval - now.timeIntervalSince(last)).rounded(.up))
            Logger.speechCallouts.info("callout_debounced retry_after=\(wait, privacy: .public)")
            return .debounced(retryAfterSeconds: wait)
        }

        lastAccepted[sessionID] = now
        pending.append(item)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        let position = pending.count + (current == nil ? 0 : 1)
        Logger.speechCallouts.info("callout_queued chars=\(cleaned.count, privacy: .public) position=\(position, privacy: .public)")
        pump()
        return .queued(position: position)
    }

    /// Stumm schalten bricht die laufende Ansage ab und verwirft die wartenden.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        dependencies.storeMuted(muted)
        guard muted else { return }
        pending.removeAll()
        if current != nil {
            engine.stop()
            current = nil
        }
    }

    /// Vom Aufnahme-Start: laufende Ansage sofort abbrechen und danach von
    /// vorn sprechen, bis zum Ende der Aufnahme nichts Neues.
    func holdForRecording() {
        heldUntil = dependencies.now().addingTimeInterval(Self.recordingGrace)
        if let interrupted = current {
            engine.stop()
            current = nil
            pending.insert(interrupted, at: 0)
            Logger.speechCallouts.info("callout_interrupted_by_recording")
        }
        scheduleRetry()
    }

    // MARK: Ablauf

    private var isBlocked: Bool {
        if dependencies.isBlocked() { return true }
        if let heldUntil, dependencies.now() < heldUntil { return true }
        return false
    }

    private func pump() {
        guard current == nil, !pending.isEmpty else { return }
        guard !isBlocked else {
            scheduleRetry()
            return
        }
        let next = pending.removeFirst()
        current = next
        engine.speak(next.utterance)
    }

    private func didFinish() {
        current = nil
        pump()
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        dependencies.schedule(Self.retryInterval) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.pump()
        }
    }
}
