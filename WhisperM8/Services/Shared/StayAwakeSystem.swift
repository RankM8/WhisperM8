import Darwin
import Foundation
import IOKit.ps

/// Systemzugriffe des Wach-Knopfs. Alle Aufrufe blockieren und laufen nur
/// off-main (`StayAwakeController.queue`).
protocol StayAwakeSystem: Sendable {
    /// Ist die sudo-Regel da? (`sudo -n -l`, fragt nie nach einem Passwort.)
    func isPermissionInstalled() -> Bool
    /// Admin-Dialog von macOS, danach die Regel. `false` bei Abbruch.
    func installPermission(prompt: String) -> Bool
    func removePermission(prompt: String) -> Bool
    func setSleepDisabled(_ disabled: Bool) -> Bool
    func isSleepDisabled() -> Bool?
    func startWatchdog(appPID: Int32, marker: URL)
    func powerState() -> (onACPower: Bool, batteryPercent: Int?)
}

struct LiveStayAwakeSystem: StayAwakeSystem {
    func isPermissionInstalled() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", SleepDisablePermission.pmset] + SleepDisablePermission.pmsetArguments(disabled: true)).status == 0
    }

    func installPermission(prompt: String) -> Bool {
        guard let script = SleepDisablePermission.installScript(user: NSUserName()) else { return false }
        return runAdmin(script, prompt: prompt) && isPermissionInstalled()
    }

    func removePermission(prompt: String) -> Bool {
        runAdmin(SleepDisablePermission.removeScript, prompt: prompt)
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", SleepDisablePermission.pmset] + SleepDisablePermission.pmsetArguments(disabled: disabled)).status == 0
    }

    func isSleepDisabled() -> Bool? {
        SleepDisablePermission.parseSleepDisabled(run(SleepDisablePermission.pmset, ["-g"]).output)
    }

    func startWatchdog(appPID: Int32, marker: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SleepDisablePermission.watchdogScript, "whisperm8-wach", String(appPID), marker.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func powerState() -> (onACPower: Bool, batteryPercent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = providing != kIOPSBatteryPowerValue
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (onAC, current * 100 / max)
        }
        return (onAC, nil)
    }

    private func runAdmin(_ shell: String, prompt: String) -> Bool {
        run("/usr/bin/osascript", ["-e", SleepDisablePermission.adminAppleScript(shell: shell, prompt: prompt)]).status == 0
    }

    /// Feste Sprache, damit Ausgaben nie mit Komma oder übersetzt kommen.
    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = LoginShellEnvironment.shared.processEnvironment()
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
