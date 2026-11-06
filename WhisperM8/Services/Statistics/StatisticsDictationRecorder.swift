import Foundation

/// Zählt fertige Diktate: Anzahl, Audiolänge, Wörter und Ausgabemodus.
/// Der Aufrufer (Main-Thread) übergibt nur die Werte; Wörter werden erst auf
/// der Store-Queue gezählt, weil der Text lang sein kann.
enum StatisticsDictationRecorder {
    /// Wörter nach den Wortgrenzen von Foundation: Satzzeichen zählen nicht,
    /// „geht's“ ist ein Wort.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Endtext, wenn es einen gibt, sonst das Rohtranskript.
    static func countedText(rawText: String?, finalText: String?) -> String {
        if let finalText, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return finalText
        }
        return rawText ?? ""
    }

    static func record(
        status: TranscriptRunStatus,
        audioDuration: TimeInterval,
        rawText: String?,
        finalText: String?,
        modeName: String,
        at date: Date,
        store: StatisticsStore,
        calendar: Calendar = .current
    ) {
        guard status != .failed else { return }
        let key = StatisticsTime.dayKey(for: date, calendar: calendar)
        let duration = audioDuration.isFinite ? max(0, audioDuration) : 0
        store.update { db in
            let words = wordCount(countedText(rawText: rawText, finalText: finalText))
            db.updateDay(key) { day in
                day.dictations += 1
                day.dictationAudioSeconds += duration
                day.dictationWords += words
                if !modeName.isEmpty { day.dictationModes[modeName, default: 0] += 1 }
            }
        }
    }
}
