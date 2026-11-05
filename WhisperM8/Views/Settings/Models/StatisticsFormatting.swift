import Foundation

/// Reine Formatierung der Statistik-Seite. Alles hängt nur an der übergebenen
/// Locale, damit die Tests Deutsch und Englisch prüfen können, ohne dass die
/// Systemsprache mitspielt.
enum StatisticsFormat {
    static func isGerman(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "de"
    }

    /// Ganze Zahl mit Tausendertrennung („25.822“ / „25,822“).
    static func integer(_ value: Double, locale: Locale) -> String {
        value.rounded().formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    static func count(_ value: Int, locale: Locale) -> String {
        integer(Double(value), locale: locale)
    }

    /// Kommazahl mit höchstens `digits` Nachkommastellen („2,4“ / „2.4“).
    static func decimal(_ value: Double, digits: Int = 1, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
    }

    /// Dauer wie im Entwurf: „6h 05min“ (de) bzw. „6h 05m“ (en), unter einer
    /// Stunde nur Minuten, ab 100 Stunden nur noch volle Stunden („412 h“).
    static func duration(_ seconds: Double, locale: Locale) -> String {
        let minutes = max(0, seconds) / 60
        if minutes >= 6000 {
            return integer(minutes / 60, locale: locale) + " h"
        }
        let total = Int(minutes.rounded())
        let hours = total / 60
        let rest = total % 60
        let unit = isGerman(locale) ? "min" : "m"
        if hours > 0 {
            return "\(hours)h " + String(format: "%02d", rest) + unit
        }
        return "\(rest)" + unit
    }

    /// Kurze Stundenangabe für die Teilen-Karte: „4,2 h“, ab 10 Stunden ganzzahlig.
    static func hoursShort(_ seconds: Double, locale: Locale) -> String {
        let hours = max(0, seconds) / 3600
        let number = hours >= 10 ? integer(hours, locale: locale) : decimal(hours, digits: 1, locale: locale)
        return number + " h"
    }

    /// Euro-Betrag: ab 100 € ohne Cent („3.264 €“), darunter mit Cent („7,20 €“).
    static func euro(_ value: Double, locale: Locale) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "EUR", locale: locale)
        if abs(value) >= 100 {
            return value.formatted(style.precision(.fractionLength(0)))
        }
        return value.formatted(style.precision(.fractionLength(2)))
    }

    /// Token-Mengen kompakt: „7,64 Mrd.“ / „7.64B“, „21,4 Mio.“ / „21.4M“,
    /// „228 Tsd.“ / „228K“. Null wird zum Gedankenstrich.
    static func tokens(_ value: Int, locale: Locale) -> String {
        guard value > 0 else { return "–" }
        let german = isGerman(locale)
        let v = Double(value)
        if v >= 1e9 {
            return decimal(v / 1e9, digits: 2, locale: locale) + (german ? " Mrd." : "B")
        }
        if v >= 1e6 {
            return decimal(v / 1e6, digits: 1, locale: locale) + (german ? " Mio." : "M")
        }
        if v >= 1e3 {
            return integer(v / 1e3, locale: locale) + (german ? " Tsd." : "K")
        }
        return count(value, locale: locale)
    }

    /// Anteil 0…1 als Prozent („78 %“ / „78%“).
    static func percent(_ fraction: Double, digits: Int = 0, locale: Locale) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...digits)).locale(locale))
    }

    /// Prozentwert 0…100 (Limits) als Prozent.
    static func percentValue(_ value: Double, locale: Locale) -> String {
        percent(value / 100, locale: locale)
    }

    /// Faktor wie „17,2×“.
    static func multiplier(_ value: Double, locale: Locale) -> String {
        decimal(value, digits: 1, locale: locale) + "×"
    }

    /// Plattengröße („1,4 MB“). Eigene Rechnung statt ByteCountFormatter, weil
    /// der keine Locale annimmt und sich so nicht testen lässt.
    static func bytes(_ value: Int64, locale: Locale) -> String {
        let units: [(Double, String)] = [(1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        let v = Double(max(0, value))
        for (factor, unit) in units where v >= factor {
            return decimal(v / factor, digits: 1, locale: locale) + " " + unit
        }
        return v > 0 ? "1 KB" : "0 KB"
    }

    /// Wochentag und Uhrzeit für den Wochen-Reset („Mo., 09:00“ / „Mon 9:00 AM“).
    static func weekdayTime(_ date: Date, locale: Locale, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated).hour().minute()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Wörter → Tippzeit in Sekunden bei 40 Wörtern pro Minute.
    static func typingSeconds(words: Int, wordsPerMinute: Double = 40) -> Double {
        Double(max(0, words)) / wordsPerMinute * 60
    }
}

// MARK: - Farben je Modell

/// Farbzuordnung der Modelle. Die Farbe folgt dem Modell, nicht dem Rang im
/// gerade gezeigten Zeitraum: Grundlage ist der Gegenwert über die gesamte
/// Historie aller Konten. So behält „Opus 5.5“ seine Farbe, egal ob Heute,
/// Woche oder ein einzelnes Konto gewählt ist.
enum StatisticsPalette {
    /// So viele Farben hat die Referenzpalette; weitere Modelle werden grau.
    static let slotCount = 4

    /// Modelle in Palettenreihenfolge: Gegenwert absteigend, dann Token, dann Name.
    static func modelOrder(database: StatsDatabase) -> [String] {
        var totals: [String: TokenUsage] = [:]
        for day in database.days.values {
            for (model, accounts) in day.tokens {
                for usage in accounts.values {
                    totals[model, default: TokenUsage()].add(usage)
                }
            }
        }
        return totals
            .filter { !$0.value.isEmpty }
            .map { (model: $0.key, usd: ModelPricing.costUSD(model: $0.key, usage: $0.value) ?? -1, tokens: $0.value.totalTokens) }
            .sorted { lhs, rhs in
                if lhs.usd != rhs.usd { return lhs.usd > rhs.usd }
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
                return lhs.model < rhs.model
            }
            .map(\.model)
    }

    /// Palettenplatz 0…3 oder `nil` (grau) für Modelle jenseits der vier Farben.
    static func slot(for model: String, order: [String]) -> Int? {
        guard let index = order.firstIndex(of: model), index < slotCount else { return nil }
        return index
    }
}

// MARK: - Konten

enum StatisticsAccountName {
    /// Anzeigename eines Kontos: `codex` → „Codex (CLI)“, `chatgpt:<profil>` → „ChatGPT (profil)“.
    static func display(_ account: String) -> String {
        if account == "codex" { return "Codex (CLI)" }
        if account.hasPrefix("chatgpt:") {
            let profile = String(account.dropFirst("chatgpt:".count))
            return profile.isEmpty || profile == "main" ? "ChatGPT" : "ChatGPT (\(profile))"
        }
        return account
    }
}
