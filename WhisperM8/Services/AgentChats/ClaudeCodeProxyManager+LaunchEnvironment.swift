import Foundation

// Umgebung für Proxy-Aufrufe und den Start von Proxy-Instanzen. Aus
// `ClaudeCodeProxyManager.swift` ausgelagert (Dateigrenze, WM8-133).
extension ClaudeCodeProxyManager {
    /// Env-Variable, mit der der Proxy `/v1/audio/transcriptions` registriert
    /// (Diktat-Anbieter „ChatGPT-Abo"). Ohne sie antwortet die Route mit 404.
    static let transcriptionsAPIEnvironmentKey = "CCP_CODEX_TRANSCRIPTIONS_API"

    /// Transport des Proxys zu chatgpt.com (`http`, `websocket`, ab v0.1.48
    /// auch `auto`). WhisperM8 setzt `http`, siehe `launchEnvironment`.
    static let transportEnvironmentKey = "CCP_CODEX_TRANSPORT"

    /// Ab v0.1.48 ergänzt der Proxy seine Modellliste aus
    /// `$CODEX_HOME/models_cache.json` (sonst `$HOME/.codex`).
    static let codexHomeEnvironmentKey = "CODEX_HOME"

    /// Login-Shell-Env plus Profil-Overrides. Ein geerbtes `CCP_CONFIG_DIR`
    /// wird IMMER ueberschrieben bzw. entfernt — Routing laeuft nur ueber
    /// explizite Per-Aufruf-Overrides, nie ueber Vererbung (Regel wie bei
    /// `CLAUDE_CONFIG_DIR` in `LoginShellEnvironment`).
    func environment(forProfile profile: String?) -> [String: String] {
        var environment = environmentResolver()
        environment.removeValue(forKey: GPTAccountProfiles.configDirEnvironmentKey)
        environment.merge(profileEnvironmentResolver(profile)) { _, override in override }
        return environment
    }

    /// Env fuer den Start einer Proxy-Instanz (main und Zusatzprofile) — ein
    /// Ort statt zwei kopierter Bloecke in den beiden Startpfaden.
    func launchEnvironment(forProfile profile: String?) -> [String: String] {
        var environment = environment(forProfile: profile)
        // Die Tier-Env des Proxy hat Vorrang vor jedem Modell-Alias
        // und wuerde damit Toggle, plain /model sowie den guenstigen
        // Haiku-Ersatz global ueberstimmen. Ein bewusster Override in
        // der Proxy-Konfiguration oder einem externen Prozess bleibt.
        if environment.removeValue(forKey: "CCP_CODEX_SERVICE_TIER") != nil {
            let profileLabel = profile ?? GPTAccountProfiles.mainProfileName
            Logger.agentStore.warning(
                "claude_code_proxy_inherited_service_tier_removed key=CCP_CODEX_SERVICE_TIER profile=\(profileLabel, privacy: .public)"
            )
        }
        // Die echte Loopback-Garantie liefert das Binary selbst: der
        // raine-Proxy bindet hart auf 127.0.0.1 (verifiziert per lsof;
        // `serve` kennt keinen --host/--bind-Flag). CCP_BIND_ADDRESS
        // setzen wir nur als Defense-in-Depth — falls eine kuenftige
        // Version oder ein alternativer Proxy die Variable auswertet,
        // erzwingt sie ebenfalls loopback statt 0.0.0.0.
        environment["CCP_BIND_ADDRESS"] = "127.0.0.1"
        // HTTP statt WebSocket für jede Instanz: Der Proxy nimmt bis v0.1.47
        // WebSocket als Standard, und darüber kamen die 401-Wellen und
        // Abbrüche nach rund 177 s (Upstream #73/#172). Die Einstellung lag
        // bisher nur per Hand in der main-Config, Zusatzkonten haben keine
        // eigene `config.json` und liefen deshalb über WebSocket. Die
        // Umgebungsvariable gewinnt im Proxy vor der Config-Datei. Ein
        // bewusst geerbter Wert (Login-Shell) bleibt stehen.
        if environment[Self.transportEnvironmentKey]?.isEmpty ?? true {
            environment[Self.transportEnvironmentKey] = "http"
        }
        // Proxy und App (Picker, `CodexModelCatalogWatcher`) müssen dieselbe
        // `models_cache.json` lesen, sonst böte die App ein Modell an, das
        // die Instanz ablehnt. Zusatzkonten laufen mit HOME = Profilordner
        // und fänden dort keinen Katalog (WM8-133). Deshalb immer der Pfad
        // der App, auch gegen ein geerbtes `CODEX_HOME`.
        if let codexHome = codexHomeResolver() {
            environment[Self.codexHomeEnvironmentKey] = codexHome
        }
        // Transkriptions-Route (`/v1/audio/transcriptions`) fuer den Diktat-
        // Anbieter „ChatGPT-Abo". Bei JEDER selbst gestarteten Instanz, nicht
        // nur bei gewaehltem Anbieter — sonst liefert ein spaeterer Wechsel
        // 404, bis der Proxy neu startet. Kill-Switch aus → aktiv entfernen,
        // auch eine aus der Login-Shell geerbte Variable.
        if transcriptionsAPIEnabledResolver() {
            environment[Self.transcriptionsAPIEnvironmentKey] = "1"
        } else {
            environment.removeValue(forKey: Self.transcriptionsAPIEnvironmentKey)
        }
        return environment
    }
}
