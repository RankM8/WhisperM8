import Foundation

/// Welche GPT-Modelle der laufende `claude-code-proxy` annimmt — gelesen aus
/// seinem `GET /v1/models`. WhisperM8 bietet im GPT-Backend nur die
/// Schnittmenge aus Codex-Katalog (was dein Codex-Konto kann) und dieser
/// Liste (was der Proxy routet) an. So bietet nie ein Picker, Stempel oder
/// `gpt.md` ein Modell an, das der Proxy mit „Unknown model" ablehnt —
/// ohne eigenen Proxy-Fork (abgelöst 2026-09-23).
///
/// Unbekannt (`nil`) heißt: noch nicht abgefragt oder Proxy nicht erreichbar.
/// Dann gilt der Katalog ungefiltert — lieber ein Modell zu viel anbieten
/// als das GPT-Backend ganz leer zu zeigen.
final class ClaudeCodeProxyModelRegistry: @unchecked Sendable {
    static let shared = ClaudeCodeProxyModelRegistry()

    private let lock = NSLock()
    private var models: Set<String>?
    private let fetcher: (Int) -> Data?

    init(fetcher: @escaping (Int) -> Data? = ClaudeCodeProxyModelRegistry.fetchModelsBlocking) {
        self.fetcher = fetcher
    }

    /// Basis-IDs (ohne `-fast`) der GPT-Modelle, die der Proxy kennt.
    var knownModels: Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return models
    }

    /// Fragt `/v1/models` ab. Ein Fehlschlag überschreibt eine bekannte
    /// Liste nicht — der letzte gute Stand bleibt.
    func refresh(proxyPort: Int) {
        guard let data = fetcher(proxyPort), let parsed = Self.parseModelIDs(data) else {
            Logger.claudeGPTRouter.warning("claude_code_proxy_models_unavailable port=\(proxyPort)")
            return
        }
        lock.lock()
        let changed = models != parsed
        models = parsed
        lock.unlock()
        if changed {
            Logger.claudeGPTRouter.info(
                "claude_code_proxy_models count=\(parsed.count) models=\(parsed.sorted().joined(separator: ","), privacy: .public)"
            )
        }
    }

    func setForTesting(_ ids: Set<String>?) {
        lock.lock(); models = ids; lock.unlock()
    }

    /// `{"data":[{"id":"gpt-6-astra"},…]}` → GPT-Basis-IDs ohne `-fast`.
    static func parseModelIDs(_ data: Data) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return nil }
        var ids = Set<String>()
        for entry in entries {
            guard var id = (entry["id"] as? String)?.lowercased(), id.hasPrefix("gpt-") else { continue }
            if id.hasSuffix("-fast") { id.removeLast("-fast".count) }
            ids.insert(id)
        }
        return ids
    }

    static func fetchModelsBlocking(port: Int) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 4)
        return box.data
    }
}

extension CodexModelCatalog {
    /// Entfernt GPT-Modelle, die der Proxy nicht kennt. `nil` = unbekannt →
    /// Katalog unverändert.
    func restricted(toProxyModels proxyModels: Set<String>?) -> CodexModelCatalog {
        guard let proxyModels else { return self }
        return CodexModelCatalog(
            models: models.filter { !$0.slug.hasPrefix("gpt-") || proxyModels.contains($0.slug) },
            fetchedAt: fetchedAt
        )
    }
}
