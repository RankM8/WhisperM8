import Foundation

/// Stufen des Wach-Knopfs in der Sidebar. Ein Klick schaltet zur nächsten.
enum StayAwakeMode: String, Equatable, Sendable {
    /// Der Mac schläft wie gewohnt.
    case off
    /// Am Strom wach, auch zugeklappt, solange ein Chat arbeitet.
    case whileWorking
    /// Immer wach, auch mit Akku und zugeklappt. Mit Sicherungen.
    case always

    var next: StayAwakeMode {
        switch self {
        case .off: return .whileWorking
        case .whileWorking: return .always
        case .always: return .off
        }
    }
}

/// Warum „Immer wach“ von selbst ausgegangen ist.
enum StayAwakeEndReason: String, Equatable, Sendable {
    case lowBattery
    case hot
    case timeLimit
}

/// Was die Entscheidung braucht, ohne Systemzugriff.
struct StayAwakeConditions: Equatable, Sendable {
    var anyChatWorking: Bool
    var onACPower: Bool
    /// `nil` bei Macs ohne Akku.
    var batteryPercent: Int?
    var thermalState: ProcessInfo.ThermalState
}

/// Pure Regeln: ob der Ruhezustand gerade aus sein soll und wann „Immer wach“
/// endet.
enum StayAwakePolicy {
    /// Nach dem letzten Turn noch so lange wach: Zwischen zwei Turns oder
    /// Tool-Aufrufen steht ein Chat kurz nicht auf „arbeitet“.
    static let workingGrace: TimeInterval = 120
    static let alwaysTimeLimit: TimeInterval = 4 * 3600
    static let lowBatteryPercent = 20

    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    /// Muss „Immer wach“ enden? Reihenfolge: Hitze vor Akku vor Zeit.
    static func endReason(_ conditions: StayAwakeConditions, alwaysSince: Date, now: Date) -> StayAwakeEndReason? {
        if isHot(conditions.thermalState) { return .hot }
        if !conditions.onACPower, let battery = conditions.batteryPercent, battery <= lowBatteryPercent {
            return .lowBattery
        }
        if now.timeIntervalSince(alwaysSince) >= alwaysTimeLimit { return .timeLimit }
        return nil
    }

    static func shouldDisableSleep(
        mode: StayAwakeMode,
        conditions: StayAwakeConditions,
        lastWorkingAt: Date?,
        now: Date
    ) -> Bool {
        switch mode {
        case .off:
            return false
        case .always:
            return true
        case .whileWorking:
            guard conditions.onACPower, !isHot(conditions.thermalState) else { return false }
            if conditions.anyChatWorking { return true }
            guard let lastWorkingAt else { return false }
            return now.timeIntervalSince(lastWorkingAt) < workingGrace
        }
    }
}

/// Die einmalige Freigabe: eine sudo-Regel, die genau
/// `pmset -a disablesleep 0` und `… 1` ohne Passwort erlaubt. Nur Texte und
/// Parser, ausgeführt wird in `StayAwakeSystem`.
enum SleepDisablePermission {
    static let sudoersPath = "/etc/sudoers.d/whisperm8-sleep"
    static let pmset = "/usr/bin/pmset"

    static func pmsetArguments(disabled: Bool) -> [String] {
        ["-a", "disablesleep", disabled ? "1" : "0"]
    }

    /// Nur übliche macOS-Kontonamen. Alles andere landet nie in der sudo-Regel.
    static func isSafeUserName(_ user: String) -> Bool {
        !user.isEmpty && user.count <= 64
            && user.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
            && !user.hasPrefix("-")
    }

    static func sudoersLine(user: String) -> String? {
        guard isSafeUserName(user) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
    }

    /// Läuft als root: Regel in eine Temp-Datei, mit `visudo` prüfen, dann mit
    /// festen Rechten installieren. Eine kaputte Regel landet so nie in
    /// `/etc/sudoers.d`.
    static func installScript(user: String) -> String? {
        guard let line = sudoersLine(user: user) else { return nil }
        return [
            "tmp=$(/usr/bin/mktemp /tmp/whisperm8-sleep.XXXXXX) || exit 1",
            "printf '%s\\n' '\(line)' > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\" >/dev/null && /usr/bin/install -m 0440 -o root -g wheel \"$tmp\" \(sudoersPath)",
            "rc=$?",
            "/bin/rm -f \"$tmp\"",
            "exit $rc",
        ].joined(separator: "\n")
    }

    static let removeScript = "\(pmset) -a disablesleep 0; /bin/rm -f \(sudoersPath)"

    /// AppleScript für den Admin-Dialog von macOS.
    static func adminAppleScript(shell: String, prompt: String) -> String {
        "do shell script \"\(escapeForAppleScript(shell))\" with prompt \"\(escapeForAppleScript(prompt))\" with administrator privileges"
    }

    static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `SleepDisabled` aus `pmset -g`; `nil`, wenn die Zeile fehlt.
    static func parseSleepDisabled(_ pmsetOutput: String) -> Bool? {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", let value = parts.last {
                return value == "1"
            }
        }
        return nil
    }

    /// Wache für Abstürze, läuft als eigener Prozess des Users. Stirbt die App
    /// und steht die Merker-Datei noch, schaltet sie den Ruhezustand wieder ein.
    /// `$1` = PID der App, `$2` = Merker-Datei.
    static let watchdogScript = """
    while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 2; done
    if [ -e "$2" ]; then /usr/bin/sudo -n \(pmset) -a disablesleep 0 && /bin/rm -f "$2"; fi
    """
}
