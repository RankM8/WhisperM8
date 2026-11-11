import AppKit
import Foundation

// MARK: - debug.controller (`whisperm8 debug controller state|press|sequence`)

/// Debug-Kanal der Controller-Steuerung: Zustand auslesen und künstliche
/// Eingaben durch dieselbe Kette schicken wie echte Hardware.
///
/// Standard ist ein Trockenlauf: Die Antwort nennt Geste, Zusammenhang und
/// Aktion, ausgeführt wird nichts. Ausführen (`execute`) geht nur in der
/// Test-Instanz — ein künstliches Kreuz würde sonst über den Socket eine
/// Freigabe in einem echten Chat bestätigen.
extension AgentControlRequestHandler {
    func debugController(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        switch request.params["op"]?.stringValue {
        case "state":
            let state = await MainActor.run { Self.controllerState(recentLimit: 12) }
            return .success(requestID: request.requestID, result: .object(state))
        case "run":
            return await debugControllerRun(request)
        default:
            return .failure(requestID: request.requestID, code: .invalid, message: "op muss state oder run sein")
        }
    }

    private func debugControllerRun(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let script = request.params["script"]?.stringValue else {
            return .failure(requestID: request.requestID, code: .invalid, message: "script fehlt")
        }
        let steps: [ControllerDebugScript.Step]
        do {
            steps = try ControllerDebugScript.parse(script)
        } catch ControllerDebugScript.ParseError.invalid(let message) {
            return .failure(requestID: request.requestID, code: .invalid, message: message)
        } catch {
            return .failure(requestID: request.requestID, code: .invalid, message: "Skript nicht lesbar")
        }
        let execute = request.params["execute"]?.boolValue ?? false
        guard !execute || AppInstance.isTestInstance else {
            return .failure(
                requestID: request.requestID, code: .unsupported,
                message: "Ausführen geht nur in der Test-Instanz (scripts/test-instance.sh). Ohne --execute läuft ein Trockenlauf.")
        }
        let windowRef = request.params["window"]?.stringValue?.lowercased()
        let frontmost = request.params["frontmost"]?.boolValue ?? false

        let result = await Task { @MainActor () -> [String: Any]? in
            let manager = ControllerManager.shared
            var override = ControllerDebugOverride(assumeFrontmost: frontmost)
            if let windowRef {
                let matches = Self.agentChatWindowIDs
                    .filter { $0.uuidString.lowercased().hasPrefix(windowRef) }
                guard matches.count == 1 else { return nil }
                override.windowID = matches[0]
            }
            let previousDryRun = manager.isDryRun
            manager.isDryRun = !execute
            manager.debugOverride = override
            manager.clearRecentResolutions()
            defer {
                manager.isDryRun = previousDryRun
                manager.debugOverride = nil
            }
            for step in steps {
                switch step {
                case .event(let event):
                    manager.inject(event)
                case .wait(let milliseconds):
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                }
            }
            // Die Kette läuft über die Eingabe-Queue zurück zum Main Thread.
            try? await Task.sleep(for: .milliseconds(200))
            var state = Self.controllerState(recentLimit: 64)
            state["executed"] = execute
            return state
        }.value
        guard let result else {
            return .failure(requestID: request.requestID, code: .notFound, message: "Kein eindeutiges Fenster für --window")
        }
        return .success(requestID: request.requestID, result: .object(result))
    }

    @MainActor
    private static func controllerState(recentLimit: Int) -> [String: Any] {
        let manager = ControllerManager.shared
        let status = manager.status
        let preferences = AppPreferences.shared
        let counted = manager.counters.snapshot
        var counters: [String: Any] = [:]
        for (button, counts) in counted.counts {
            counters[button.rawValue] = [
                "downActive": counts.downActive, "upActive": counts.upActive,
                "downInactive": counts.downInactive, "upInactive": counts.upInactive,
            ]
        }
        var device: Any = NSNull()
        if let info = status.device {
            device = [
                "name": info.name, "category": info.category,
                "battery": info.batteryLevel.map { Double($0) as Any } ?? NSNull(),
                "light": info.hasLight, "haptics": info.hasHaptics,
            ] as [String: Any]
        }
        return [
            "running": status.isRunning,
            "paused": status.isPaused,
            "device": device,
            "background": status.background.rawValue,
            "switches": [
                "feature": preferences.isControllerFeatureEnabled,
                "enabled": preferences.isControllerEnabled,
                "background": preferences.isControllerBackgroundEnabled,
            ],
            "appActive": NSApp.isActive,
            "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
            "windows": Self.agentChatWindowIDs.map(\.uuidString),
            "counters": counters,
            "lastEventAt": counted.lastEventAt.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
            "resolutions": manager.recentResolutions.suffix(recentLimit).map { resolution -> [String: Any] in
                [
                    "gesture": Self.describe(resolution.gesture),
                    "context": Self.describe(resolution.context),
                    "action": resolution.action.map { Self.describe($0) as Any } ?? NSNull(),
                    "executed": resolution.executed,
                ]
            },
        ]
    }

    /// Alle Agent-Chats-Fenster, das Hauptfenster zuerst.
    @MainActor
    private static var agentChatWindowIDs: [UUID] {
        let store = AgentWindowStore.shared
        return [store.primaryWindowID] + store.secondaryWindowIDs
    }

    /// Lesbare Kurzform eines Enum-Werts, ohne Modulnamen.
    private static func describe(_ value: Any) -> String {
        String(describing: value).replacingOccurrences(of: "WhisperM8.", with: "")
    }
}
