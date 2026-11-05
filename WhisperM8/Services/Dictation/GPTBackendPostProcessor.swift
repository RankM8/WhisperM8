import Foundation

// MARK: - Diktat-Nacharbeit über das GPT-Backend
//
// Reine Textmodi (ohne Projektzugriff) schicken ihr fertiges Prompt nicht an
// einen frischen `codex exec`-Prozess, sondern als eine Anthropic-Anfrage
// `POST /v1/messages` an die laufende Instanz des GPT-Proxys
// (`claude-code-proxy`). Gemessen am 05.11.2026 (69 Codex-Läufe): der Start
// von Codex kostet im Mittel 3,1 s und schickt rund 25.000 Token Beiwerk mit
// (MCP-Server, Plugins, Skill-Liste). Beides fällt hier weg.
//
// Wie bei der ChatGPT-Abo-Transkription direkt an den INSTANZ-Port des
// aktiven GPT-Kontos, nicht über den Mix-Router. Dasselbe Konto wie die
// Transkription, damit ein Diktat nie zwei Konten belastet.
//
// Jeder Fehler hier ist für den Aufrufer nur ein Grund, auf die Codex-CLI
// auszuweichen (`PostProcessingEngineRouter`). Ausnahmen: Abbruch durch den
// Nutzer und Zeitüberschreitung, die gehen unverändert durch.

/// Abhängigkeiten als Closures (Repo-Konvention), Defaults wie bei der
/// ChatGPT-Abo-Transkription.
struct GPTBackendPostProcessingDependencies {
    /// `claudeGPTBackendEnabled`: ohne GPT-Backend kein Proxy-Prozess.
    var isBackendEnabled: () -> Bool
    /// Aktives GPT-Profil, `nil` = main. Liest eine Datei, nur off-main.
    var activeProfile: () -> String?
    /// Port der laufenden Instanz des Profils (`nil` = unbekannt).
    var knownPort: (String?) -> Int?
    /// Blockierend (Health-Probe, Startschleife), nur off-main.
    var ensureRunning: (String?) -> Result<Void, ClaudeCodeProxyError>
    /// GPT-Modelle, die der laufende Proxy kennt (ohne `-fast`); `nil` = unbekannt.
    var proxyModels: () -> Set<String>?
    /// Unterstützt das Modell die Priority-Stufe (`-fast`-Alias des Proxys)?
    var supportsFast: (String) -> Bool
    var sessionProvider: (TimeInterval) -> URLSession

    static var live: GPTBackendPostProcessingDependencies {
        let chatGPT = ChatGPTTranscriptionDependencies.live
        return GPTBackendPostProcessingDependencies(
            isBackendEnabled: chatGPT.isBackendEnabled,
            activeProfile: chatGPT.activeProfile,
            knownPort: chatGPT.knownPort,
            ensureRunning: chatGPT.ensureRunning,
            proxyModels: { ClaudeCodeProxyModelRegistry.shared.knownModels },
            supportsFast: { ClaudeGPTModelAlias.supportsFast($0) },
            sessionProvider: { timeout in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout + 5
                return URLSession(configuration: configuration)
            }
        )
    }
}

// MARK: - Fehler

/// Warum das GPT-Backend die Nacharbeit nicht geliefert hat. Taucht im Log,
/// im Diktat-Bericht (Rückfallgrund) und, wenn auch Codex scheitert, in der
/// Fehlermeldung auf.
enum GPTBackendPostProcessingError: LocalizedError, Equatable {
    case backendDisabled
    case profileNotLoggedIn(String)
    case proxyUnavailable(String)
    case modelUnavailable(String)
    case notAuthenticated
    case rateLimited
    case http(statusCode: Int, message: String)
    case emptyResponse
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .backendDisabled:
            return String(localized: "The GPT backend is turned off.")
        case .profileNotLoggedIn(let name):
            return String(localized: "The active GPT account “\(name)” is not signed in.")
        case .proxyUnavailable(let reason):
            return String(localized: "The GPT proxy is not reachable: \(reason)")
        case .modelUnavailable(let model):
            return String(localized: "The GPT proxy doesn't offer the model \(model).")
        case .notAuthenticated:
            return String(localized: "The GPT backend is not signed in to ChatGPT or the login has expired.")
        case .rateLimited:
            return String(localized: "The usage limit of the active GPT account is reached.")
        case .http(let statusCode, let message):
            return String(localized: "The GPT backend answered with HTTP \(statusCode): \(message)")
        case .emptyResponse:
            return String(localized: "The GPT backend returned no text.")
        case .network(let error):
            return String(localized: "Network error at the GPT backend: \(error.localizedDescription)")
        }
    }

    /// Kurzer, inhaltsfreier Name fürs Log und den Diktat-Bericht.
    var label: String {
        switch self {
        case .backendDisabled: return "backend_disabled"
        case .profileNotLoggedIn: return "profile_not_logged_in"
        case .proxyUnavailable: return "proxy_unavailable"
        case .modelUnavailable: return "model_unavailable"
        case .notAuthenticated: return "not_authenticated"
        case .rateLimited: return "rate_limited"
        case .http(let statusCode, _): return "http_\(statusCode)"
        case .emptyResponse: return "empty_response"
        case .network(let error): return "network_\(error.code.rawValue)"
        }
    }
}

// MARK: - Abbruch

/// Laufende Backend-Anfragen je Besitzer, damit der Abbruch-Knopf im Overlay
/// (und ESC) auch diesen Weg trifft. Gegenstück zu `CodexProcessRegistry`.
final class GPTBackendRunRegistry: @unchecked Sendable {
    static let shared = GPTBackendRunRegistry()

    private struct Entry {
        var owner: CodexRunOwner
        var cancel: () -> Void
        var cancelled = false
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func register(runID: UUID, owner: CodexRunOwner, cancel: @escaping () -> Void) {
        lock.withLock { entries[runID] = Entry(owner: owner, cancel: cancel) }
    }

    /// Meldet den Lauf ab und sagt, ob er vom Nutzer abgebrochen wurde.
    @discardableResult
    func unregister(runID: UUID) -> Bool {
        lock.withLock { entries.removeValue(forKey: runID)?.cancelled ?? false }
    }

    /// Bricht alle Läufe eines Besitzers ab (Overlay-Knopf → `.dictation`).
    @discardableResult
    func cancel(owner: CodexRunOwner = .dictation) -> Bool {
        let cancels: [() -> Void] = lock.withLock {
            var result: [() -> Void] = []
            for (id, entry) in entries where entry.owner == owner {
                entries[id]?.cancelled = true
                result.append(entry.cancel)
            }
            return result
        }
        cancels.forEach { $0() }
        return !cancels.isEmpty
    }
}

// MARK: - Prozessor

struct GPTBackendPostProcessor: PostProcessing {
    /// Zeitlimit je Anfrage. Ohne Streaming schickt der Proxy bis zum Ende
    /// nichts, das Limit gilt also für die ganze Antwort.
    static let timeout: TimeInterval = 90

    /// Denktiefen, die der Proxy in `output_config.effort` annimmt
    /// (`read_effort` im Upstream). Alles andere lassen wir weg.
    static let acceptedEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// Obergrenze der Antwort; reicht für lange Prompts aus dem Prompt-Modus.
    static let maxTokens = 16_000

    private let templateStore: PostProcessingTemplateStore
    private let promptPackageBuilder: PromptPackageBuilder
    private let dependencies: GPTBackendPostProcessingDependencies
    private let registry: GPTBackendRunRegistry
    private let visualInputModeRaw: () -> String

    init(
        templateStore: PostProcessingTemplateStore = PostProcessingTemplateStore(),
        promptPackageBuilder: PromptPackageBuilder = PromptPackageBuilder(),
        dependencies: GPTBackendPostProcessingDependencies = .live,
        registry: GPTBackendRunRegistry = .shared,
        visualInputModeRaw: @escaping () -> String = { AppPreferences.shared.codexVisualInputModeRaw }
    ) {
        self.templateStore = templateStore
        self.promptPackageBuilder = promptPackageBuilder
        self.dependencies = dependencies
        self.registry = registry
        self.visualInputModeRaw = visualInputModeRaw
    }

    func plannedEngine(for mode: OutputMode) -> PostProcessingEngine? { .gptBackend }

    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        try await processRun(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle).text
    }

    func processRun(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) async throws -> PostProcessingRun {
        guard dependencies.isBackendEnabled() else { throw GPTBackendPostProcessingError.backendDisabled }
        try PostProcessingCancelToken.checkCurrent()
        guard let template = templateStore.template(for: mode.templateID) else {
            throw PostProcessingError.missingTemplate
        }

        let package = promptPackageBuilder.build(
            rawText: rawText,
            mode: mode,
            template: template,
            language: language,
            contextBundle: contextBundle
        )
        let imageURLs = CodexVisualInputSelection(contextBundle: contextBundle, modeRaw: visualInputModeRaw()).imageURLs

        let deps = dependencies
        let model = try Self.resolveModel(mode: mode, dependencies: deps)
        let effort = mode.resolvedCodexReasoningEffortRaw()
        // Bilder lesen und Profil bestimmen (Dateizugriff), nie auf dem Main Actor.
        let (profile, initialPort, images) = try await ChatGPTSubscriptionTranscriptionService.offMain {
            () -> Result<(String?, Int?, [GPTBackendImage]), Error> in
            Result {
                let profile = deps.activeProfile()
                return (profile, deps.knownPort(profile), try imageURLs.map(GPTBackendImage.load))
            }
        }.get()
        let body = try Self.requestBody(prompt: package.prompt, images: images, model: model, effort: effort)
        let profileLabel = profile ?? GPTAccountProfiles.mainProfileName
        let startedAt = Date()

        let runID = UUID()
        let owner = CodexRunOwner.current
        let request = Task { () throws -> String in
            var port: Int
            if let initialPort {
                port = initialPort
            } else {
                port = try await bootstrap(profile: profile)
            }
            do {
                return try await send(body: body, port: port)
            } catch let error as URLError where error.code == .cannotConnectToHost {
                // „Connection refused" heißt: die Anfrage kam nie beim Proxy
                // an. Genau ein Start und ein zweiter Versuch.
                port = try await bootstrap(profile: profile)
                try Task.checkCancellation()
                return try await send(body: body, port: port)
            }
        }
        registry.register(runID: runID, owner: owner) { request.cancel() }
        // Abbruch in der Vorbereitung (Profil, Port, Bilder): da war der Lauf
        // noch nicht angemeldet. Dann die Anfrage sofort beenden.
        let cancelToken = PostProcessingCancelToken.current
        if cancelToken?.isCancelled == true { request.cancel() }

        do {
            let text = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            registry.unregister(runID: runID)
            Logger.transcription.info(
                "dictation_postprocess engine=gpt_backend status=ok ms=\(Self.milliseconds(since: startedAt), privacy: .public) profile=\(profileLabel, privacy: .public) model=\(model, privacy: .public) images=\(images.count, privacy: .public)"
            )
            return PostProcessingRun(text: text, engine: .gptBackend, gptProfile: profileLabel)
        } catch {
            let cancelledByUser = registry.unregister(runID: runID) || cancelToken?.isCancelled == true
            let mapped = cancelledByUser ? PostProcessingError.userCancelled : Self.map(error)
            Logger.transcription.info(
                "dictation_postprocess engine=gpt_backend status=failed ms=\(Self.milliseconds(since: startedAt), privacy: .public) profile=\(profileLabel, privacy: .public) model=\(model, privacy: .public) error=\(Self.label(for: mapped), privacy: .public)"
            )
            throw mapped
        }
    }

    // MARK: Bausteine

    /// Modell des Modus (`auto` → aktuelles Spitzenmodell). Kennt der Proxy es
    /// nicht, übernimmt Codex. Priority-Stufe über die `-fast`-Endung.
    static func resolveModel(mode: OutputMode, dependencies: GPTBackendPostProcessingDependencies) throws -> String {
        let slug = CodexModelSelection.resolveSlug(mode.resolvedCodexModelRaw()).lowercased()
        if let known = dependencies.proxyModels(), !known.contains(slug) {
            throw GPTBackendPostProcessingError.modelUnavailable(slug)
        }
        let wantsFast = CodexServiceTier.resolve(mode.resolvedCodexServiceTierRaw()) == .fast
        return wantsFast && dependencies.supportsFast(slug) ? "\(slug)-fast" : slug
    }

    /// Pur: Anthropic-Messages-Anfrage ohne Streaming. Ein Nutzer-Turn mit dem
    /// fertigen Prompt und den Bildern als Base64 (der Proxy macht daraus
    /// `input_image`).
    static func requestBody(prompt: String, images: [GPTBackendImage], model: String, effort: String) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for image in images {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()],
            ])
        }
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            // Für Codex verwirft der Proxy das Feld (Upstream-Test
            // `max_tokens_is_not_serialized_for_codex`); mitgeschickt, damit
            // die Anfrage auch für strengere Anthropic-Prüfer vollständig ist.
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]],
        ]
        if acceptedEfforts.contains(effort) {
            body["output_config"] = ["effort": effort]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Pur: Text aller `text`-Blöcke der Antwort. Denk-Blöcke fallen weg.
    static func responseText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { return nil }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Pur: HTTP-Status und Fehlerkörper des Proxys.
    static func mapHTTP(statusCode: Int, body: Data) -> GPTBackendPostProcessingError {
        let parsed = ChatGPTTranscriptionErrorMapper.ErrorBody.parse(String(decoding: body, as: UTF8.self))
        // Eigene Auth-Fehler des Proxys; `upstream_error` kommt von chatgpt.com.
        if statusCode == 401 || statusCode == 403, parsed.code != ChatGPTTranscriptionErrorMapper.upstreamErrorCode {
            return .notAuthenticated
        }
        if statusCode == 429 { return .rateLimited }
        let message = parsed.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .http(statusCode: statusCode, message: String((message.isEmpty ? "HTTP \(statusCode)" : message).prefix(200)))
    }

    private func bootstrap(profile: String?) async throws -> Int {
        let deps = dependencies
        let (result, port) = await ChatGPTSubscriptionTranscriptionService.offMain {
            () -> (Result<Void, ClaudeCodeProxyError>, Int?) in
            (deps.ensureRunning(profile), deps.knownPort(profile))
        }
        switch result {
        case .failure(.profileNotLoggedIn(let name)):
            throw GPTBackendPostProcessingError.profileNotLoggedIn(name)
        case .failure(let error):
            throw GPTBackendPostProcessingError.proxyUnavailable(error.localizedDescription)
        case .success:
            guard let port else {
                throw GPTBackendPostProcessingError.proxyUnavailable(String(localized: "Port of the proxy instance unknown."))
            }
            return port
        }
    }

    private func send(body: Data, port: Int) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/messages") else {
            throw GPTBackendPostProcessingError.proxyUnavailable("port \(port)")
        }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = body

        let session = dependencies.sessionProvider(Self.timeout)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            throw Self.mapHTTP(statusCode: statusCode, body: data)
        }
        guard let text = Self.responseText(from: data) else {
            throw GPTBackendPostProcessingError.emptyResponse
        }
        return text
    }

    /// Abbruch von außen (Task-Cancellation) geht unverändert durch,
    /// Zeitüberschreitung wird zu `.timedOut`, Netzfehler werden benannt.
    static func map(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is GPTBackendPostProcessingError, is PostProcessingError:
            return error
        case let urlError as URLError where urlError.code == .cancelled:
            return CancellationError()
        case let urlError as URLError where urlError.code == .timedOut:
            return PostProcessingError.timedOut(timeout)
        case let urlError as URLError:
            return GPTBackendPostProcessingError.network(urlError)
        default:
            return error
        }
    }

    private static func label(for error: Error) -> String {
        switch error {
        case let error as GPTBackendPostProcessingError: return error.label
        case PostProcessingError.userCancelled: return "user_cancelled"
        case PostProcessingError.timedOut: return "timed_out"
        case is CancellationError: return "cancelled"
        default: return String(describing: type(of: error))
        }
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

/// Ein Bild für die Anfrage. Der Proxy nimmt nur Base64 mit bekanntem Typ.
struct GPTBackendImage: Equatable {
    var data: Data
    var mediaType: String

    static func load(_ url: URL) throws -> GPTBackendImage {
        GPTBackendImage(data: try Data(contentsOf: url), mediaType: mediaType(for: url))
    }

    static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}
