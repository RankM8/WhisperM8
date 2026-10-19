import Foundation

/// Reset-Zeitpunkte der Konto-Nutzung („→ 23:09", „→ Sat 19:00") in der
/// Sprache und Uhrzeit-Konvention des Systems. Vorher war das Muster fest
/// (`de_DE`, `HH:mm`, `dd.MM.`) — eine englische UI zeigte deutsche
/// Wochentage und erzwang 24 h.
enum UsageResetDateFormat {
    /// Kurz: nur Uhrzeit, ab mehr als 24 h Abstand mit Wochentag.
    static func short(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        format(date, template: date.timeIntervalSince(now) > 86_400 ? "EEE jmm" : "jmm", locale: locale)
    }

    /// Lang: ab mehr als 24 h Abstand mit Wochentag und Datum.
    static func long(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        format(date, template: date.timeIntervalSince(now) > 86_400 ? "EEE dMM jmm" : "jmm", locale: locale)
    }

    private static func format(_ date: Date, template: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
