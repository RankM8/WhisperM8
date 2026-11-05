import Foundation

enum StatisticsPreferenceKeys {
    /// Hauptschalter und Notbremse zugleich:
    /// `defaults write com.whisperm8.app statisticsEnabled -bool NO`
    static let enabled = "statisticsEnabled"
    /// Abos für den Hebel, JSON-kodiertes `[StatisticsSubscription]`.
    static let subscriptions = "statisticsSubscriptions"
    /// Dollar-Euro-Kurs (1 USD = x EUR) und Datum des letzten Abrufs.
    static let usdEurRate = "statisticsUsdEurRate"
    static let usdEurRateDate = "statisticsUsdEurRateDate"
    /// Nutzerwahl auf der Seite: Zeitraum (`day`, `week`, `month`, `all`).
    static let period = "statisticsPeriod"
}

/// Ein Abo, das der Nutzer monatlich zahlt — Nenner des Hebels.
struct StatisticsSubscription: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var count: Int
    var monthlyEUR: Double

    var monthlyTotal: Double { Double(count) * monthlyEUR }
}

enum StatisticsSettings {
    /// Startwerte aus dem Entwurf; auf der Seite änderbar.
    static let defaultSubscriptions: [StatisticsSubscription] = [
        StatisticsSubscription(name: "Claude Max", count: 3, monthlyEUR: 180),
        StatisticsSubscription(name: "ChatGPT Pro", count: 1, monthlyEUR: 200),
    ]

    /// Rückfallkurs, solange kein EZB-Kurs abgerufen wurde.
    static let fallbackUsdEurRate = 0.92

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: StatisticsPreferenceKeys.enabled) as? Bool ?? true
    }

    static func subscriptions(_ defaults: UserDefaults = .standard) -> [StatisticsSubscription] {
        guard let json = defaults.string(forKey: StatisticsPreferenceKeys.subscriptions),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([StatisticsSubscription].self, from: data)
        else { return defaultSubscriptions }
        return decoded
    }

    static func setSubscriptions(_ value: [StatisticsSubscription], _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: StatisticsPreferenceKeys.subscriptions)
    }

    static func usdEurRate(_ defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: StatisticsPreferenceKeys.usdEurRate)
        return value > 0.3 && value < 3 ? value : fallbackUsdEurRate
    }

    static func usdEurRateDate(_ defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: StatisticsPreferenceKeys.usdEurRateDate) as? Date
    }
}

/// Holt einmal am Tag den EZB-Referenzkurs EUR/USD. Ein einziger kleiner
/// HTTP-Abruf im Hintergrund; schlägt er fehl, bleibt der letzte Kurs.
enum StatisticsExchangeRate {
    static let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    /// Liest `currency='USD' rate='1.0812'` aus dem EZB-XML und liefert
    /// 1 USD in EUR (= 1 / rate).
    static func parseUsdEurRate(fromECBXML xml: String) -> Double? {
        guard let range = xml.range(of: "currency='USD'") ?? xml.range(of: "currency=\"USD\"") else { return nil }
        let tail = xml[range.upperBound...]
        guard let rateStart = tail.range(of: "rate=") else { return nil }
        let afterQuote = tail[rateStart.upperBound...].dropFirst()
        let number = afterQuote.prefix { $0.isNumber || $0 == "." }
        guard let eurUsd = Double(number), eurUsd > 0 else { return nil }
        return 1 / eurUsd
    }

    static func refreshIfNeeded(
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        session: URLSession = .shared
    ) async {
        if let last = StatisticsSettings.usdEurRateDate(defaults), now.timeIntervalSince(last) < 20 * 3600 { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("WhisperM8", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8),
              let rate = parseUsdEurRate(fromECBXML: xml)
        else { return }
        defaults.set(rate, forKey: StatisticsPreferenceKeys.usdEurRate)
        defaults.set(now, forKey: StatisticsPreferenceKeys.usdEurRateDate)
    }
}
