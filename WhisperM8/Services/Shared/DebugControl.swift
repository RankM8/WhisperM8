import AppKit
import Foundation

// MARK: - Debug-Steuerkanal (`whisperm8 debug …`)
//
// Stufe 2 der UI-Tests ohne Computer Use (docs/features/ui-testing.md): Über
// den vorhandenen Control-Socket kann ein Agent den App-Zustand lesen, Fenster
// öffnen und fotografieren und eine Audiodatei durch den echten
// Transkriptions-Weg schicken. Hier liegen die puren, testbaren Bausteine; die
// App-Anbindung steht in `AgentControlRequestHandler+Debug`.

enum DebugControl {
    static let disabledMessage =
        "Debug-Steuerkanal ist aus. Einschalten: defaults write com.whisperm8.app debugControlEnabled -bool YES (wirkt sofort, kein Neustart)."

    // MARK: open

    enum OpenTarget: Equatable {
        /// `page` = Route-ID wie in `SettingsRouteTarget.resolve` (z. B.
        /// `transcription`, `gpt-backend`); `nil` = fester Einstieg.
        case settings(page: String?)
        case agentChats
        case onboarding

        /// `settings`, `settings/<seite>`, `agent-chats`, `onboarding`.
        /// Unbekannte Settings-Seiten werden abgelehnt statt still auf die
        /// Startseite zu fallen.
        static func parse(_ raw: String) -> OpenTarget? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
            guard let head = parts.first?.lowercased() else { return nil }
            switch head {
            case "settings":
                guard parts.count == 2 else { return .settings(page: nil) }
                let page = parts[1]
                return SettingsRouteTarget.resolve(routeID: page) == nil ? nil : .settings(page: page)
            case "agent-chats", "chats":
                return parts.count == 1 ? .agentChats : nil
            case "onboarding":
                return parts.count == 1 ? .onboarding : nil
            default:
                return nil
            }
        }

        static var usage: String {
            "settings[/<seite>] | agent-chats | onboarding — Seiten: "
                + SettingsPage.allCases.map(\.rawValue).joined(separator: ", ")
        }

        var label: String {
            switch self {
            case .settings(let page): return page.map { "settings/\($0)" } ?? "settings"
            case .agentChats: return "agent-chats"
            case .onboarding: return "onboarding"
            }
        }
    }

    // MARK: Fenster

    struct WindowInfo: Equatable {
        var number: Int
        var identifier: String?
        var title: String
        var className: String
        var isKey: Bool
        var isVisible: Bool
        var isMiniaturized: Bool
        var frame: CGRect

        /// Lesbarer Name für Auswahl und Dateinamen: Titel, sonst Identifier.
        var displayName: String {
            if !title.isEmpty { return title }
            return identifier ?? "fenster-\(number)"
        }

        var json: [String: Any] {
            [
                "number": number,
                "identifier": identifier ?? NSNull(),
                "title": title,
                "class": className,
                "isKey": isKey,
                "isVisible": isVisible,
                "isMiniaturized": isMiniaturized,
                "frame": [
                    "x": Int(frame.origin.x), "y": Int(frame.origin.y),
                    "width": Int(frame.width), "height": Int(frame.height),
                ],
            ]
        }
    }

    /// Nur echte App-Fenster: AppKit führt in `NSApp.windows` auch
    /// Statusleisten-, Popover- und Menü-Hilfsfenster.
    static func isRelevant(_ info: WindowInfo) -> Bool {
        let helperClasses = [
            "NSStatusBarWindow", "_NSPopoverWindow", "NSMenuWindowManagerWindow", "NSCarbonMenuWindow",
            "NSToolTipPanel", "TUINSWindow",
        ]
        guard !helperClasses.contains(where: { info.className.contains($0) }) else { return false }
        return info.frame.width > 1 && info.frame.height > 1
    }

    /// Fensterauswahl für `snapshot`: `nil`/`all` = alle sichtbaren, `key` =
    /// Schlüsselfenster, sonst Teilstring (ohne Groß/klein) von Titel oder
    /// Identifier. Minimierte Fenster liefern kein Bild und fallen raus.
    static func select(_ windows: [WindowInfo], selector: String?) -> [WindowInfo] {
        let candidates = windows.filter { isRelevant($0) && $0.isVisible && !$0.isMiniaturized }
        let needle = selector?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch needle {
        case "", "all":
            return candidates
        case "key":
            return candidates.filter(\.isKey)
        default:
            return candidates.filter {
                $0.title.lowercased().contains(needle) || ($0.identifier?.lowercased().contains(needle) ?? false)
            }
        }
    }

    /// `20261008-221530-settings-3.png` — Zeitstempel, bereinigter Name,
    /// Fensternummer (eindeutig bei gleichen Titeln).
    static func snapshotFileName(for info: WindowInfo, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = info.displayName.lowercased()
            .unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" }
            .reduce(into: "") { result, char in
                if char == "-", result.last == "-" { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let name = slug.isEmpty ? "fenster" : String(slug.prefix(40))
        return "\(formatter.string(from: date))-\(name)-\(info.number).png"
    }

    static var defaultSnapshotDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("debug-snapshots", isDirectory: true)
    }
}

// MARK: - Aufträge (`dictate`)

/// Der Control-Socket bricht jeden Request nach 10 s ab — ein Diktat mit
/// langer Aufnahme dauert länger. `debug.dictate` legt deshalb einen Auftrag an
/// und antwortet sofort; `debug.job` fragt ihn ab (die CLI pollt).
final class DebugJobStore: @unchecked Sendable {
    enum State {
        case running(startedAt: Date)
        case done(result: [String: Any], finishedAt: Date)
        case failed(message: String, finishedAt: Date)

        var json: [String: Any] {
            switch self {
            case .running(let startedAt):
                return ["state": "running", "runningSeconds": Int(Date().timeIntervalSince(startedAt))]
            case .done(let result, _):
                return ["state": "done", "result": result]
            case .failed(let message, _):
                return ["state": "failed", "message": message]
            }
        }
    }

    static let shared = DebugJobStore()

    /// Mehr gleichzeitige Diktate bringen nichts (der GPT-Proxy erlaubt 4
    /// parallele Transkriptionen) und verstopften nur die Anbieter-Limits.
    let maxRunning: Int
    /// Fertige Aufträge bleiben so lange abfragbar.
    let retention: TimeInterval
    private let lock = NSLock()
    private var jobs: [String: State] = [:]

    init(maxRunning: Int = 2, retention: TimeInterval = 600) {
        self.maxRunning = maxRunning
        self.retention = retention
    }

    /// Neuer Auftrag; `nil`, wenn schon `maxRunning` laufen.
    func start(now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)
        let running = jobs.values.filter { if case .running = $0 { return true } else { return false } }.count
        guard running < maxRunning else { return nil }
        let id = UUID().uuidString.lowercased()
        jobs[id] = .running(startedAt: now)
        return id
    }

    func finish(_ id: String, result: [String: Any], now: Date = Date()) {
        set(id, .done(result: result, finishedAt: now))
    }

    func fail(_ id: String, message: String, now: Date = Date()) {
        set(id, .failed(message: message, finishedAt: now))
    }

    func state(_ id: String, now: Date = Date()) -> State? {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)
        return jobs[id]
    }

    private func set(_ id: String, _ state: State) {
        lock.lock()
        defer { lock.unlock() }
        guard jobs[id] != nil else { return }
        jobs[id] = state
    }

    private func prune(now: Date) {
        jobs = jobs.filter { _, state in
            switch state {
            case .running: return true
            case .done(_, let finishedAt), .failed(_, let finishedAt):
                return now.timeIntervalSince(finishedAt) < retention
            }
        }
    }
}

// MARK: - Diktat mit Audiodatei

/// Schickt eine Audiodatei durch DENSELBEN Transkriptions-Weg wie das
/// Hotkey-Diktat (Anbieter/Modell aus den Einstellungen, gleicher
/// Zugangs-Gate, gleiche Service-Factory, ChatGPT-Abo inklusive) — aber ohne
/// Mikrofon, ohne Einfügen, ohne Zwischenablage, ohne Run-Report und ohne
/// `AppState` anzufassen. Nachbearbeitung (OutputModes) läuft nicht.
enum DebugDictation {
    struct Dependencies {
        var storedProvider: () -> TranscriptionProvider
        var storedModel: () -> TranscriptionModel
        var chatGPTEnabled: () -> Bool
        var language: () -> String
        var apiKey: (TranscriptionProvider) -> String?
        var makeService: (TranscriptionProvider, TranscriptionModel, String) -> TranscriptionServiceProtocol

        static var live: Dependencies {
            Dependencies(
                storedProvider: { TranscriptionSettings.loadProvider() },
                storedModel: { TranscriptionSettings.loadModel() },
                chatGPTEnabled: { AppPreferences.shared.isChatGPTTranscriptionEnabled },
                language: { AppPreferences.shared.language },
                apiKey: { provider in provider.keychainKey.flatMap { KeychainManager.load(key: $0) } },
                makeService: { provider, model, apiKey in provider.createService(apiKey: apiKey, model: model) }
            )
        }
    }

    enum Failure: LocalizedError, Equatable {
        case fileMissing(String)
        case unknownProvider(String)
        case providerUnavailable(String)
        case missingAPIKey(String)

        var errorDescription: String? {
            switch self {
            case .fileMissing(let path): return "Audiodatei nicht gefunden: \(path)"
            case .unknownProvider(let raw): return "Unbekannter Anbieter „\(raw)“ (groq, openai, chatgpt)."
            case .providerUnavailable(let raw): return "Anbieter „\(raw)“ ist abgeschaltet (Kill-Switch chatGPTTranscriptionEnabled)."
            case .missingAPIKey(let name): return "Kein API-Key für \(name) gespeichert."
            }
        }
    }

    struct Plan: Equatable {
        var provider: TranscriptionProvider
        var model: TranscriptionModel
        /// `nil` = automatische Erkennung (kein `language`-Feld).
        var language: String?
    }

    /// Pur: Anbieter/Modell/Sprache wie das Diktat, optional überschrieben.
    /// Ein Override-Anbieter nimmt das gespeicherte Modell nur, wenn es zu
    /// ihm gehört, sonst seinen Default. `auto` bzw. leer = Sprache erkennen.
    static func plan(
        providerOverride: String?,
        languageOverride: String?,
        dependencies: Dependencies
    ) throws -> Plan {
        let storedModel = dependencies.storedModel()
        let provider: TranscriptionProvider
        if let raw = providerOverride?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            guard let parsed = TranscriptionProvider(rawValue: raw) else { throw Failure.unknownProvider(raw) }
            guard TranscriptionProvider.selectableProviders(chatGPTAvailable: dependencies.chatGPTEnabled()).contains(parsed) else {
                throw Failure.providerUnavailable(raw)
            }
            provider = parsed
        } else {
            provider = dependencies.storedProvider()
        }
        let model = storedModel.provider == provider ? storedModel : provider.defaultModel
        let rawLanguage = (languageOverride ?? dependencies.language()).trimmingCharacters(in: .whitespacesAndNewlines)
        let language = (rawLanguage.isEmpty || rawLanguage.lowercased() == "auto") ? nil : rawLanguage
        return Plan(provider: provider, model: model, language: language)
    }

    static func run(
        audioURL: URL,
        providerOverride: String?,
        languageOverride: String?,
        dependencies: Dependencies = .live
    ) async throws -> [String: Any] {
        guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw Failure.fileMissing(audioURL.path)
        }
        let plan = try plan(providerOverride: providerOverride, languageOverride: languageOverride, dependencies: dependencies)
        let key = plan.provider.requiresAPIKey ? (dependencies.apiKey(plan.provider) ?? "") : ""
        guard TranscriptionCredentialGate.isSatisfied(provider: plan.provider, typedKey: key, hasSavedKey: false) else {
            throw Failure.missingAPIKey(plan.provider.displayName)
        }
        let audioBytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let started = Date()
        let service = dependencies.makeService(plan.provider, plan.model, key)
        let raw = try await service.transcribe(audioURL: audioURL, language: plan.language, audioDuration: nil)
        return [
            "provider": plan.provider.rawValue,
            "model": plan.model.rawValue,
            "language": plan.language ?? "auto",
            "audioBytes": audioBytes,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
            "rawText": raw,
            "text": TextNormalizer.normalizeTranscriptionText(raw),
        ]
    }
}
