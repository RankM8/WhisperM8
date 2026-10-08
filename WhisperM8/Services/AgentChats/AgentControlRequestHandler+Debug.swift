import AppKit
import Foundation

// MARK: - debug.* (`whisperm8 debug state|open|snapshot|dictate|job`)

/// Debug-Steuerkanal für UI-Tests ohne Computer Use (docs/features/ui-testing.md).
/// Hinter dem Schalter `debugControlEnabled` (Default aus); jeder Aufruf landet
/// im Audit-Log. Lesen und Fotografieren laufen auf dem MainActor, das Diktat
/// als Auftrag im Hintergrund (10-s-Fenster des Sockets).
extension AgentControlRequestHandler {
    static let debugMethods: Set<String> = [
        "debug.state", "debug.open", "debug.snapshot", "debug.dictate", "debug.job",
    ]

    func debugRequest(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let response: ChatsControlResponse
        if AppPreferences.shared.isDebugControlEnabled {
            switch request.method {
            case "debug.state": response = await debugState(request)
            case "debug.open": response = await debugOpen(request)
            case "debug.snapshot": response = await debugSnapshot(request)
            case "debug.dictate": response = debugDictate(request)
            default: response = debugJob(request)
            }
        } else {
            response = .failure(requestID: request.requestID, code: .unsupported, message: DebugControl.disabledMessage)
        }
        // `debug.job` pollt im Halbsekundentakt — nicht ins Audit-Log.
        if request.method != "debug.job" {
            await audit(request.actor, method: request.method.replacingOccurrences(of: ".", with: "-"),
                        target: nil, outcome: response.ok ? "ok" : (response.error?.code ?? "error"), prompt: nil)
        }
        return response
    }

    // MARK: state

    private func debugState(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let state = await MainActor.run { () -> [String: Any] in
            let appState = AppState.shared
            let preferences = AppPreferences.shared
            let windows = Self.currentWindowInfos().filter(DebugControl.isRelevant)
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let registry = AgentTerminalRegistry.shared
            let runningPTYs = workspace.sessions.filter { registry.controller(for: $0.id)?.isRunning == true }.count
            return [
                "app": [
                    "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?",
                    "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    "isActive": NSApp.isActive,
                ],
                "windows": windows.map(\.json),
                // Bewusst nur Längen, keine Diktat-Texte (Audit, Privatsphäre).
                "dictation": [
                    "phase": String(describing: appState.recordingPhase),
                    "isRecording": appState.isRecording,
                    "isTranscribing": appState.isTranscribing,
                    "isPostProcessing": appState.isPostProcessing,
                    "lastError": appState.lastError ?? NSNull(),
                    "lastTranscriptionChars": appState.lastTranscription?.count ?? 0,
                    "outputMode": appState.selectedOutputMode.id,
                    "provider": TranscriptionSettings.loadProvider().rawValue,
                    "model": TranscriptionSettings.loadModel().rawValue,
                    "language": preferences.language.isEmpty ? "auto" : preferences.language,
                ],
                "settings": [
                    "gptBackendEnabled": preferences.claudeGPTBackendEnabled,
                    "chatGPTTranscriptionEnabled": preferences.isChatGPTTranscriptionEnabled,
                    "usageProfile": preferences.usageProfile.rawValue,
                ],
                "agentChats": [
                    "sessions": workspace.sessions.count,
                    "runningPTYs": runningPTYs,
                ],
            ]
        }
        return .success(requestID: request.requestID, result: .object(state))
    }

    // MARK: open

    private func debugOpen(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let raw = request.params["target"]?.stringValue,
              let target = DebugControl.OpenTarget.parse(raw) else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "Ziel fehlt/unbekannt. Erlaubt: \(DebugControl.OpenTarget.usage)")
        }
        await MainActor.run {
            let center = WindowRequestCenter.shared
            switch target {
            case .settings(let page?): center.requestSettings(routeID: page)
            case .settings(nil): center.request(.settings)
            case .agentChats: center.request(.agentChats)
            case .onboarding: center.request(.onboarding)
            }
        }
        return .success(requestID: request.requestID, result: .object(["opened": target.label]))
    }

    // MARK: snapshot

    private func debugSnapshot(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let selector = request.params["window"]?.stringValue
        let directory: URL
        if let path = request.params["outputDir"]?.stringValue, !path.isEmpty {
            guard path.hasPrefix("/") else {
                return .failure(requestID: request.requestID, code: .invalid, message: "outputDir muss ein absoluter Pfad sein")
            }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = DebugControl.defaultSnapshotDirectory
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "Ordner nicht anlegbar: \(error.localizedDescription)")
        }

        let outcome = await MainActor.run { () -> (files: [[String: Any]], error: String?) in
            let infos = DebugControl.select(Self.currentWindowInfos(), selector: selector)
            guard !infos.isEmpty else {
                return ([], "Kein sichtbares Fenster passt auf „\(selector ?? "all")“ (siehe `whisperm8 debug state`).")
            }
            let now = Date()
            var written: [[String: Any]] = []
            for info in infos {
                guard let window = NSApp.window(withWindowNumber: info.number),
                      let content = window.contentView else { continue }
                // Erst mit Titelleiste (Theme-Frame), sonst nur der Inhalt.
                let candidates = [content.superview, content].compactMap { $0 }
                guard let png = candidates.lazy.compactMap({ try? ViewSnapshotRenderer.pngData(of: $0) }).first else {
                    continue
                }
                let file = directory.appendingPathComponent(DebugControl.snapshotFileName(for: info, date: now))
                do {
                    try png.write(to: file)
                    written.append(["path": file.path, "window": info.displayName, "number": info.number])
                } catch {
                    Logger.agentStore.error("debug_snapshot_write_failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
            return written.isEmpty ? ([], "Kein Fenster ließ sich fotografieren.") : (written, nil)
        }
        if let message = outcome.error {
            return .failure(requestID: request.requestID, code: .notFound, message: message)
        }
        return .success(requestID: request.requestID, result: .object(["files": outcome.files]))
    }

    // MARK: dictate / job

    private func debugDictate(_ request: ChatsControlRequest) -> ChatsControlResponse {
        guard let path = request.params["audioPath"]?.stringValue, path.hasPrefix("/") else {
            return .failure(requestID: request.requestID, code: .invalid, message: "audioPath fehlt oder ist nicht absolut")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .failure(requestID: request.requestID, code: .notFound, message: "Audiodatei nicht gefunden: \(path)")
        }
        let store = DebugJobStore.shared
        guard let jobID = store.start() else {
            return .failure(requestID: request.requestID, code: .conflict,
                            message: "Schon \(store.maxRunning) Diktat-Aufträge in Arbeit — später erneut.")
        }
        let provider = request.params["provider"]?.stringValue
        let language = request.params["language"]?.stringValue
        Logger.transcription.info("debug_dictate_started job=\(jobID, privacy: .public) provider=\(provider ?? "settings", privacy: .public)")
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await DebugDictation.run(
                    audioURL: URL(fileURLWithPath: path),
                    providerOverride: provider,
                    languageOverride: language
                )
                store.finish(jobID, result: result)
            } catch {
                store.fail(jobID, message: error.localizedDescription)
            }
        }
        return .success(requestID: request.requestID, result: .object(["jobID": jobID]))
    }

    private func debugJob(_ request: ChatsControlRequest) -> ChatsControlResponse {
        guard let jobID = request.params["jobID"]?.stringValue,
              let state = DebugJobStore.shared.state(jobID) else {
            return .failure(requestID: request.requestID, code: .notFound,
                            message: "Auftrag unbekannt oder abgelaufen (fertige Aufträge bleiben 10 min).")
        }
        return .success(requestID: request.requestID, result: .object(state.json.merging(["jobID": jobID]) { $1 }))
    }

    // MARK: Hilfen

    @MainActor
    static func currentWindowInfos() -> [DebugControl.WindowInfo] {
        NSApp.windows.map { window in
            DebugControl.WindowInfo(
                number: window.windowNumber,
                identifier: window.identifier?.rawValue,
                title: window.title,
                className: String(describing: type(of: window)),
                isKey: window.isKeyWindow,
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                frame: window.frame
            )
        }
    }
}
