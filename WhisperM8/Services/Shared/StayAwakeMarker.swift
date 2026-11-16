import Foundation

/// Merker-Datei des Wach-Knopfs mit Besitzer (WM8-122): In der Datei steht,
/// welche App den Ruhezustand abgeschaltet hat (PID und Startzeit in µs). Zwei
/// Produktiv-Apps teilen sich `Application Support/WhisperM8/stay-awake.active`
/// (Übergabe beim Neustart, `make run` aus dem Projektordner). Vorher setzte
/// die zweite beim Start `disablesleep 0` und löschte den Merker der ersten,
/// und die alte setzte beim Beenden 0, obwohl die neue den Mac wach halten
/// wollte. Jetzt räumt nur der Besitzer auf, oder wer feststellt, dass der
/// Besitzer tot ist.
struct StayAwakeMarker: Equatable, Sendable {
    var pid: Int32
    /// Startzeit des Prozesses in µs seit 1970; unterscheidet ihn von einem
    /// späteren Prozess mit derselben PID. `nil`, wenn nicht lesbar.
    var startMicros: UInt64?

    /// Erste Zeile die PID (die Wache vergleicht nur sie), zweite die Startzeit.
    var fileContents: String {
        "\(pid)\n" + (startMicros.map { "\($0)\n" } ?? "")
    }

    /// `nil` für einen leeren oder fremden Inhalt (Merker älterer Fassungen
    /// waren leer).
    static func parse(_ text: String) -> StayAwakeMarker? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let pid = Int32(first), pid > 0 else { return nil }
        return StayAwakeMarker(pid: pid, startMicros: lines.dropFirst().first.flatMap { UInt64($0) })
    }

    /// Darf dieser Prozess den Ruhezustand wieder einschalten und den Merker
    /// löschen? Ja ohne Merker, bei einem unlesbaren (alter Absturz), beim
    /// eigenen und bei einem toten Besitzer. Nein, solange ein anderer
    /// lebender Prozess Besitzer ist.
    static func mayRelease(marker: StayAwakeMarker?, markerExists: Bool, own: StayAwakeMarker,
                           isAlive: (StayAwakeMarker) -> Bool) -> Bool {
        guard markerExists, let marker else { return true }
        if marker.pid == own.pid { return true }
        return !isAlive(marker)
    }
}
