import Foundation

// ==============================================================================
// Erkennung der Codewort-Phrase („Jarvis Pause" / „Jarvis weiter").
//
// Bewusst ohne Speech-Framework-Typen: der Matcher bekommt nur normalisierte
// Segmente mit Zeitstempeln und ist damit vollstaendig unit-testbar. Die
// Bruecke zum `SFSpeechRecognizer` sitzt im `VoiceGateListener`.
// ==============================================================================

/// Ein einzelnes erkanntes Wort aus der Spracherkennung.
struct VoiceGateSegment: Equatable {
    let text: String
    /// Startzeit relativ zum Beginn der Erkennungs-Session.
    let start: TimeInterval
    let duration: TimeInterval
    /// 0…1. `SFSpeechRecognizer` liefert bei Teilergebnissen 0 — die Schwelle
    /// greift deshalb nur fuer Werte > 0 (siehe `confidencePasses`).
    let confidence: Float

    var end: TimeInterval { start + duration }

    init(text: String, start: TimeInterval, duration: TimeInterval = 0.3, confidence: Float = 0) {
        self.text = text
        self.start = start
        self.duration = duration
        self.confidence = confidence
    }
}

enum VoiceGateIntent: String, Equatable {
    case mute
    case unmute
}

/// Warum ein Kandidat verworfen wurde. Landet im Log und ist die Datengrundlage
/// fuers Schwellen-Tuning im Trockenlauf — Beinahe-Treffer sind dort wertvoller
/// als Treffer.
enum VoiceGateRejection: String, Equatable {
    /// Kein Traegerwort in der Hypothese.
    case noCarrier
    /// Traegerwort da, aber kein bekanntes Kommando direkt dahinter.
    case noCommandAfterCarrier
    /// Kommando da, aber zu weit hinter dem Traegerwort.
    case gapTooLarge
    /// Traegerwort steckte mitten in einer laufenden Aeusserung.
    case noUtteranceBoundary
    /// Erkenner war sich zu unsicher.
    case lowConfidence
}

enum VoiceGateMatch: Equatable {
    case matched(intent: VoiceGateIntent, at: TimeInterval, confidence: Float)
    case rejected(VoiceGateRejection)
}

/// Vokabular und Schwellen. Alles konfigurierbar, damit der Trockenlauf ohne
/// Rebuild nachjustiert werden kann.
struct VoiceGateVocabulary: Equatable {
    var carrier: String = "jarvis"
    var muteCommand: String = "pause"
    var unmuteCommand: String = "weiter"

    /// Zugelassene Tippdistanz fuer das Traegerwort — Erkenner verbiegen
    /// Eigennamen gern („Jarvis" → „Jervis").
    var maxCarrierEditDistance: Int = 1

    /// … aber nur ab dieser Laenge. Bei einem kurzen Traegerwort wie „anna"
    /// liegen „anne", „hanna", „manna" und „wanna" alle in Distanz 1 — das
    /// waere ein offenes Scheunentor. Ab sechs Zeichen ist ein Nachbar in
    /// Distanz 1 dagegen fast immer eine Fehlerkennung desselben Wortes.
    var minCarrierLengthForFuzzyMatch: Int = 6

    /// Effektive Toleranz fuer das konfigurierte Traegerwort.
    func carrierDistanceAllowance() -> Int {
        let normalized = VoiceGateCommandMatcher.normalize(carrier)
        return normalized.count >= minCarrierLengthForFuzzyMatch ? maxCarrierEditDistance : 0
    }
    /// Kommandowoerter: EXAKT. Schon Distanz 1 macht „Wetter" zu „weiter"
    /// und „Hause" zu „Pause" — beides Alltagswoerter, beides ein Fehlalarm
    /// mitten im Gespraech. Von einem Unit-Test gefunden, nicht geraten.
    var maxCommandEditDistance: Int = 0

    /// Hoechstabstand zwischen Ende des Traegerworts und Beginn des Kommandos.
    var maxGap: TimeInterval = 1.5
    /// Mindeststille vor dem Traegerwort. Verhindert Treffer mitten im Satz.
    var minLeadingSilence: TimeInterval = 0.3
    /// Gilt nur fuer Segmente mit Konfidenz > 0 (also finale Ergebnisse).
    var minConfidence: Float = 0.4

    static let `default` = VoiceGateVocabulary()
}

struct VoiceGateCommandMatcher {
    let vocabulary: VoiceGateVocabulary

    init(vocabulary: VoiceGateVocabulary = .default) {
        self.vocabulary = vocabulary
    }

    /// Sucht die Phrase in einer Erkennungs-Hypothese. Ausgewertet wird von
    /// hinten nach vorn: die juengste Aeusserung ist die interessante.
    func match(segments: [VoiceGateSegment]) -> VoiceGateMatch {
        let normalized = segments.map { NormalizedSegment(segment: $0) }
        // Zuerst die zusammengeklebte Form. Der On-Device-Erkenner verschmilzt
        // benachbarte Woerter regelmaessig zu einem Token — gemessen am
        // 27.07.2026: „anna pause" kam mehrfach als „annapause" an (und
        // „auf jeden" als „aufjeden"). Ohne diesen Pfad greift die Phrase mal
        // und mal nicht, je nachdem wie der Erkenner gerade segmentiert.
        if let glued = matchGlued(normalized) {
            return glued
        }

        let allowance = vocabulary.carrierDistanceAllowance()
        let carrierIndices = normalized.indices.filter { index in
            Self.isWithinEditDistance(
                normalized[index].text,
                vocabulary.carrier,
                maxDistance: allowance
            )
        }

        guard !carrierIndices.isEmpty else { return .rejected(.noCarrier) }

        // Der letzte Kandidat gewinnt; scheitert er, wird sein Grund berichtet.
        var lastRejection: VoiceGateRejection = .noCarrier
        for index in carrierIndices.reversed() {
            switch evaluate(carrierIndex: index, in: normalized) {
            case .matched(let intent, let at, let confidence):
                return .matched(intent: intent, at: at, confidence: confidence)
            case .rejected(let reason):
                lastRejection = reason
            }
        }
        return .rejected(lastRejection)
    }

    // MARK: - Zusammengeklebte Form („annapause")

    /// Sucht Traeger+Kommando in EINEM Segment. Liefert `nil`, wenn nichts
    /// passt — dann uebernimmt die normale Zwei-Segment-Suche samt ihrer
    /// aussagekraeftigeren Ablehnungsgruende.
    private func matchGlued(_ segments: [NormalizedSegment]) -> VoiceGateMatch? {
        let candidates: [(text: String, intent: VoiceGateIntent)] = [
            (Self.normalize(vocabulary.carrier + vocabulary.muteCommand), .mute),
            (Self.normalize(vocabulary.carrier + vocabulary.unmuteCommand), .unmute)
        ]

        for index in segments.indices.reversed() {
            let segment = segments[index]

            // Aeusserungsgrenze gilt hier genauso — sonst wuerde die Phrase
            // mitten im Redefluss greifen.
            if index > 0 {
                let silence = segment.segment.start - segments[index - 1].segment.end
                guard silence >= vocabulary.minLeadingSilence else { continue }
            }

            for candidate in candidates {
                // Das verschmolzene Wort ist lang; ein Nachbar in Distanz 1 ist
                // dort praktisch immer dasselbe Wort, nur verhoert.
                guard Self.isWithinEditDistance(segment.text, candidate.text, maxDistance: 1) else { continue }

                let confidence = segment.segment.confidence
                if confidence > 0, confidence < vocabulary.minConfidence {
                    return .rejected(.lowConfidence)
                }
                return .matched(intent: candidate.intent, at: segment.segment.end, confidence: confidence)
            }
        }
        return nil
    }

    // MARK: - Einzelkandidat

    private func evaluate(carrierIndex: Int, in segments: [NormalizedSegment]) -> VoiceGateMatch {
        let carrier = segments[carrierIndex]

        // 1. Aeusserungsgrenze: entweder Beginn der Hypothese oder genug Stille davor.
        if carrierIndex > 0 {
            let previous = segments[carrierIndex - 1]
            let silence = carrier.segment.start - previous.segment.end
            guard silence >= vocabulary.minLeadingSilence else {
                return .rejected(.noUtteranceBoundary)
            }
        }

        // 2. Direkt folgendes Kommandowort.
        let commandIndex = carrierIndex + 1
        guard commandIndex < segments.count else {
            return .rejected(.noCommandAfterCarrier)
        }
        let command = segments[commandIndex]

        guard let intent = intent(for: command.text) else {
            return .rejected(.noCommandAfterCarrier)
        }

        // 3. Zeitlicher Zusammenhang.
        let gap = command.segment.start - carrier.segment.end
        guard gap <= vocabulary.maxGap else {
            return .rejected(.gapTooLarge)
        }

        // 4. Konfidenz — nur pruefbar, wenn der Erkenner welche geliefert hat.
        let confidences = [carrier.segment.confidence, command.segment.confidence].filter { $0 > 0 }
        if let weakest = confidences.min(), weakest < vocabulary.minConfidence {
            return .rejected(.lowConfidence)
        }

        return .matched(
            intent: intent,
            at: command.segment.end,
            confidence: confidences.min() ?? 0
        )
    }

    private func intent(for text: String) -> VoiceGateIntent? {
        if Self.isWithinEditDistance(text, vocabulary.muteCommand, maxDistance: vocabulary.maxCommandEditDistance) {
            return .mute
        }
        if Self.isWithinEditDistance(text, vocabulary.unmuteCommand, maxDistance: vocabulary.maxCommandEditDistance) {
            return .unmute
        }
        return nil
    }

    // MARK: - Normalisierung & Distanz

    private struct NormalizedSegment {
        let segment: VoiceGateSegment
        let text: String

        init(segment: VoiceGateSegment) {
            self.segment = segment
            self.text = VoiceGateCommandMatcher.normalize(segment.text)
        }
    }

    /// Kleinschreibung, Diakritika gefaltet, alles Nicht-Buchstabige raus.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
        return String(folded.unicodeScalars.filter { CharacterSet.letters.contains($0) })
    }

    /// Levenshtein mit Abbruch, sobald die Schranke ueberschritten ist.
    static func isWithinEditDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Bool {
        let target = normalize(rhs)
        if lhs == target { return true }
        if abs(lhs.count - target.count) > maxDistance { return false }
        return editDistance(Array(lhs), Array(target)) <= maxDistance
    }

    static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
