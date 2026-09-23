# Plan: GPT-Backend Account-Switcher — mehrere ChatGPT-Konten, Wechsel nach Belieben

**Stand:** 2026-09-16 · **Status:** Slice 1 umgesetzt (Branch `feature/gpt-account-switcher`, ungetestet gegen die laufende App), Slice 2–4 offen · **Scope:** GPT-Backend (Proxy, Router, Agent Chats, Settings, CLI)
**Vorbild:** `claude-account-switcher.md` (Slice 1–4) und `claude-account-routing.md` (Slice 5–6) — dieselben Muster, aber ein **Parallelbau**, keine Parametrisierung (es gibt keine Provider-Abstraktion, `ClaudeAccountProfiles` ist bis in den Store hinein auf Claude verdrahtet: `AgentSessionStore.swift:561` erzwingt für Codex `nil`).

## Ziel

Mehrere ChatGPT-Pro-Konten sind dauerhaft im GPT-Backend eingeloggt. Der User wählt in den Settings das aktive Konto für neue GPT-Chats, kann bestehende Chats umstellen und sieht pro Konto das Wochen-Kontingent — analog zu „Claude Accounts", ohne Re-Login und ohne Bruch laufender Sessions.

## Ausgangslage (Analyse 2026-09-16, fünf Agent-Berichte + eigene Verifikation)

**Zwei getrennte Logins.** Das GPT-Backend authentisiert sich **nicht** über `~/.codex/auth.json`, sondern über einen eigenen OAuth-Grant des Proxys unter `~/.config/claude-code-proxy/codex/auth.json` (Schema `access`/`refresh`/`expires`/`accountId`). Die Trennung ist gewollt (`claudex-gpt-backend/PLAN.md:122-123`: „keine Token-Kollision mit der Codex-CLI"). Konsequenz, die heute real zugeschlagen hat: Ein `codex login` mit dem neuen Konto ai@ hat die CLI, das Diktat-Post-Processing, `whisperm8 agent` und ChatGPT.app umgestellt — **das GPT-Backend blieb auf dem gesperrten office-Konto**, und das Usage-Popover (liest `~/.codex/auth.json`, `CodexUsageReader.swift:166`) zeigte gleichzeitig das freie Kontingent des neuen Kontos an.

**Kein Konto-Begriff im GPT-Backend.** Kein Session-Feld (`AgentChat.swift:298-307` kennt nur `claudeProfileName` und `claudeBackendModel`), keine Preference (`AppPreferences.swift:679-686`), keine UI (`GPTBackendSettingsPage.swift:215-257`: genau ein Device-Login-Button, kein Logout, keine Liste). Der Proxy-Start reicht weder `CCP_CONFIG_DIR` noch `CODEX_HOME` weiter (`ClaudeCodeProxyManager.swift:301-322`).

**Ein Prozess = ein Konto.** `ensureRunning(port:)` hält genau einen selbstgestarteten Proxy (`ensureLock`, `selfStartedProcess`), der Router löst den Proxy-Port global auf (`ClaudeGPTMixRouter.swift:85-103`), und die Upstream-Wahl ist rein namensbasiert (`upstream(for:)`, `:326-330`). Der Proxy hält Tokens im Speicher (Refresh 5 min vor Ablauf, Single-Flight); ein Dateitausch wirkt erst nach Neustart.

**Kein Limit-Handling.** Ein 429 aus dem Codex-Zweig wird 1:1 durchgereicht, nirgends erkannt, kein Fallback; die Session zeigt bis zu 180 s „working" (stilles Netz in `AgentSessionStatusCoordinator.swift:380-399`). Das Popover parst `limit_reached`/`allowed` nicht (`CodexUsageReader.swift:190-232`) — gesperrt sieht aus wie 100 %.

## Architektur-Entscheidung (verifiziert)

**Profil = eigenes `CCP_CONFIG_DIR` + eigene Proxy-Instanz auf eigenem Port; die Session-Zuordnung läuft per Request-Header durch den In-Process-Router.**

Selbst verifiziert am 2026-09-16 (Fork `0.1.36-whisperm8.1`, Claude CLI aus `~/.local/bin`):

- `CCP_CONFIG_DIR=<dir> claude-code-proxy codex auth status` meldet als Store `<dir>/codex/auth.json` — der Proxy trennt seinen Credential-Store pro Config-Dir, jedes Profil bekommt einen eigenen Grant mit eigener Refresh-Familie. Genau das Argument, mit dem der Claude-Plan den Keychain-Swap verworfen hat, gilt hier ebenfalls: kein Locking, keine Rotation zwischen Clients, parallele Konten gratis.
- **Stolperfalle, ebenfalls reproduziert:** Ein leeres Config-Dir meldet **nicht** „Not authenticated", sondern fällt still auf den Default-Store bzw. `~/.codex/auth.json` zurück und zeigt dessen Konto. Ein Profil ohne eigene `codex/auth.json` darf deshalb nie gestartet oder angesteuert werden — die App prüft die Datei und die `accountId` selbst, nicht nur den Status-Befehl.
- `ANTHROPIC_CUSTOM_HEADERS="X-WhisperM8-GPT-Profile: <name>"` kommt bei **jedem** Request der Claude-CLI am Router an (Dummy-Endpoint, 5/5 Requests inkl. Retries). Die Variable ist beim Spawn eingefroren → der Stempel ist session-stabil, exakt wie `CLAUDE_CONFIG_DIR`. Subagents (`gpt`-Typ) erben das Env des Elternprozesses und folgen damit automatisch dem Konto der Session.

**Verworfene Alternativen**

| Alternative | Warum nicht |
|---|---|
| `~/.codex/auth.json` tauschen | Refresh-Token ist single-use und rotiert (openai/codex#41973, #15754); ChatGPT.app läuft und schreibt ins selbe Verzeichnis → widerrufene Familie, Logout auf beiden Seiten. Trifft außerdem alle Konsumenten, nicht nur GPT |
| `CODEX_HOME`-Profile | Elf `~/.codex`-Hardcodes in der App (Indexer, Locator, FSEvents, Katalog, Usage), `CODEX_HOME` wird nirgends gelesen → Sessions unsichtbar, Katalog läuft auseinander (Muster des Vorfalls 2026-09-08). Betrifft ohnehin die falsche Spur (CLI statt GPT-Backend) |
| Ein Proxy, Wechsel = Relogin + Neustart (heutiger Handweg) | Global, trifft laufende Sessions, überschreibt den einzigen Slot, kein Parallelbetrieb — das Gegenteil von „nach Belieben" |
| Pfad-Präfix in `ANTHROPIC_BASE_URL` statt Header | Router müsste Targets umschreiben; der Header ist die kleinere, verifizierte Änderung |

**Was gegenüber Claude einfacher ist:** Die Transcripts bleiben bei Claude (`~/.claude` bzw. Claude-Profil) — beim Kontowechsel muss **nichts umziehen**, kein Planner/Journal/Scan-Pause. Ein Wechsel ist ein Stempel plus ein Neustart der Session; für laufende Sessions ist sogar ein Hot-Switch möglich (Slice 4), weil der Router in-process ist.

**Was schwieriger ist:** N Proxy-Prozesse statt einem, mit Lifecycle, Ports und Health pro Instanz.

## Vorab-Verifikation (vor Slice 1, je < 30 min)

| # | Frage | Warum entscheidend | Wie prüfen |
|---|---|---|---|
| V1 | Schreibt der Proxy einen Token-Refresh in `codex/auth.json` zurück? | Sonst liest die Usage-Anzeige nach Ablauf einen toten Token; Fallback wäre `codex auth status` pro Profil | Store von office@ läuft 2026-09-16 18:25 ab; danach mtime der Datei prüfen |
| V2 | Startet `serve` mit `CCP_CONFIG_DIR` und antwortet `/healthz` auf dem Zweitport? | Kern von Slice 2 | Temp-Dir mit kopiertem Store, Port 18770, `curl /healthz` |
| V3 | Sind `proxy.log`/`errors/` unter `~/.local/state/claude-code-proxy` pro Instanz konfliktfrei? | Zwei Instanzen schreiben sonst in dieselbe Datei | Zwei Instanzen starten, Log beobachten; ggf. `CCP_LOG_STDERR` je Instanz |
| V4 | Liefert `wham/usage` mit dem Proxy-Access-Token dieselbe Antwort wie mit dem CLI-Token (inkl. `email`)? | Quelle für Konto-Metadaten und Gauges | Einmaliger GET |
| V5 | Ist der Modellkatalog beider Konten identisch? | Der Proxy liest weiterhin `~/.codex/models_cache.json`; abweichende Pläne (`prolite` vs. `pro`) könnten andere Freigaben haben | `models` des Proxys unter beiden Config-Dirs vergleichen |

**Ergebnisse 2026-09-16 (nachmittags):**

- **V2 bestanden.** `CCP_CONFIG_DIR=<leer> serve --no-monitor --port 18770` kam hoch, `/healthz` liefert `{"ok":true}`, der main-Proxy auf 18765 blieb unberührt, der Prozess trägt die Variable. Das leere Config-Dir bekam dabei **keine** Auth-Datei — der stille Fallback ist damit auch für `serve` bestätigt, nicht nur für `auth status`.
- **V3: `proxy.log` ist geteilt.** Die Zweitinstanz hat an `~/.local/state/claude-code-proxy/proxy.log` angehängt (`server listening … port 18770`). `CCP_CONFIG_DIR` hängt nur die Config-Wurzel um, nicht den State. Append-only, für Slice 2 akzeptabel; jede Zeile trägt den Port. Bei Bedarf `CCP_LOG_STDERR` je Instanz mit eigener Umleitung (Slice 5).
- **V4 offen, wichtiger Befund:** `wham/usage` mit dem Access-Token aus dem Proxy-Store (office@, Claim `exp` erst 18:25) antwortet **401**. Claims sind identisch zum CLI-Token (gleiche `client_id`, gleiche `aud`), der Unterschied ist nur das Fehlen der `api.connectors.*`-Scopes. Wahrscheinlichste Erklärung: der laufende Proxy hat in den acht Tagen im Speicher refresht und die Datei nicht zurückgeschrieben (→ V1). Konsequenz für Slice 3: Usage pro Profil darf sich **nicht** auf den Datei-Token verlassen, 401 muss als eigener Zustand erscheinen („Token in Datei veraltet"); Alternative `codex auth status` mit `CCP_CONFIG_DIR` (löst laut Binary-String „Token refresh unauthorized" einen Refresh aus) ist noch zu verifizieren. Das Proxy-Log protokolliert keine Refreshs, V1 lässt sich daher nur über die mtime der Datei nach 18:25 klären.
- **Machbarkeitstest 2026-09-23 (ohne App-Code):** Profil `~/.gpt-profiles/ai` per `CCP_CONFIG_DIR … codex auth login` mit ai@ eingeloggt (erster Versuch landete auf office@, weil der Browser dort angemeldet war → Inkognito-Fenster; Slice 3 muss darauf hinweisen). Der Default-Store blieb byte-identisch (mtime 06.09.). Zweite Instanz `serve --port 18770` mit dem Profil: `/healthz` ok, `auth status` meldet die ai@-ID, beide Instanzen laufen parallel. **V4 damit beantwortet:** der FRISCHE Profil-Token liefert `wham/usage` HTTP 200 mit `email`, `plan_type` (`prolite`), `limit_reached`, `model_usage` — der 401 vom 16.09. kam vom veralteten main-Store, was die Hypothese „Proxy schreibt Refreshs nicht zurück" (V1) stützt. Der erste echte Request (`claude -p`, `gpt-6-astra`, direkt gegen 18770) endete nach 168 s Retries mit 429 „The usage limit has been reached": das ai@-Konto war zu dem Zeitpunkt selbst zu 100 % im 7-Tage-Fenster (Reset 23.09. 15:31), vermutlich über Codex-CLI/ChatGPT.app seit dem 16.09. Ob Pro Lite `gpt-6-astra` freischaltet, ist also weiter offen; `model_usage` führt das Modell zumindest. Nebenbefund bestätigt: bei Limit blockiert der Proxy ~170 s pro Request (Slice 5).
- **V5 unkritisch.** `claude-code-proxy models` liefert unter beiden Config-Dirs dieselbe Liste; der Katalog ist kontounabhängig (Quelle `~/.codex/models_cache.json`). Ob das `prolite`-Konto `gpt-6-astra` tatsächlich freigeschaltet hat, zeigt erst der erste echte Request.
- **Nebenbefund aus dem Proxy-Log:** Ab 14.09. 18:29 lief jeder GPT-Request ~170 s in internen Retries, bevor der Proxy 429 „The usage limit has been reached" zurückgab. Das erklärt die „working"-Hänger und gehört zu Slice 5 (Limit-Erkennung im Router).

## Vorab-Entscheidungen

### E1 — Wo leben die Profile? (Empfehlung: `~/.gpt-profiles/<name>/`, `main` = Default-Store)

Gleiches Layout wie `~/.claude-profiles`: Unterordner pro Zusatzkonto (Inhalt = `CCP_CONFIG_DIR`, also `codex/auth.json`), `.active` als Aktiv-Marker, `main` steht für den heutigen Default-Store unter `~/.config/claude-code-proxy` auf dem heutigen Port. Damit ist die Migration leer: Sessions ohne Stempel laufen exakt wie heute. Zusätzlich pro Profil `whisperm8-account.json` (E-Mail, Plan, `accountId`, Zeitstempel — aus V4, keine Secrets), das Pendant zu `oauthAccount` in `.claude.json`.

### E2 — Ports (Empfehlung: in-memory, ab Backend-Port + 10)

`main` behält `claudeGPTBackendPort` (18765). Zusatzprofile bekommen beim ersten Start einen freien Port ab 18775, verwaltet in einer Registry im `ClaudeCodeProxyManager`; der Router fragt die Registry. Keine Persistenz nötig — Router und Manager leben im selben Prozess, und `ANTHROPIC_BASE_URL` der Sessions zeigt weiterhin nur auf den Router-Port.

### E3 — Default für neue Sessions (Empfehlung: im Store, wie Claude)

`AgentSessionStore.createSession` bekommt `gptProfile: GPTProfileSelection = .activeDefault` mit injizierbarem Resolver — dieselbe Lösung wie `activeClaudeProfileResolver` (`AgentSessionStore.swift:16-19`), aus demselben Grund: an der Call-Site vergisst man es (Befund 2026-08-22, CLI-Pfad landete auf main). Stempel nur bei `provider == .claude`.

### E4 — Verhalten bei fehlendem Header (Empfehlung: aktives Profil, mit Log)

Requests ohne `X-WhisperM8-GPT-Profile` (Sessions von vor dem Update, extern gestartete Claude-Prozesse mit Router-URL) gehen an das **aktive** Profil, nicht stur an main — sonst liefe ein Chat, der vor dem Update gestartet wurde, weiter gegen das gesperrte Konto, obwohl der User gewechselt hat. Einmalige Info-Zeile im Log pro Verbindung.

### E5 — Wo liegt die Konto-Verwaltung in den Settings? (Empfehlung: auf der Seite „GPT-Backend")

Kein neuer Sidebar-Eintrag und nicht auf der Claude-Seite „Accounts". Die heutige Sektion „ChatGPT-Konto" (Device-Login-Button, `GPTBackendSettingsPage.swift:215-257`) wird durch zwei Sektionen ersetzt, die das Layout der Claude-Accounts-Seite übernehmen: „Aktives ChatGPT-Konto" (Radio-Auswahl, Plan-Badge, E-Mail, Wochen-Gauge mit Gesperrt-Status, `···`-Menü mit Anmelden/Abmelden/Entfernen) und „Konto hinzufügen" (Name + „Anlegen & anmelden…", Device-Code inline wie heute). Gründe: der Login lebt dort bereits; die Seite ist an den Backend-Schalter gekoppelt; ein eigener Block mit dem Zusatz „(GPT-Backend)" hält die Proxy-Konten sichtbar getrennt vom `codex login` der CLI — die Verwechslung vom 16.09. Reihenfolge auf der Seite: Status → Konten → Konto hinzufügen → Konfiguration. Ein eigener Eintrag „GPT-Konten" unter „Claude Code" bleibt der Ausweg, falls die Seite zu lang wird.

## Slice 1 — Profil-Kern und Login pro Konto ✅ (umgesetzt 2026-09-16, Branch `feature/gpt-account-switcher`)

Umgesetzt wie unten beschrieben; Abweichungen: `main`-Metadaten liegen unter `~/.gpt-profiles/.main-account.json` statt im Proxy-Verzeichnis (fremdes Tool, dort schreiben wir nichts); `configDir(forProfile: "main")` folgt `XDG_CONFIG_HOME` wie der Proxy; Kontometadaten werden nur angezeigt, wenn ihre `accountId` zum aktuellen Grant passt (Re-Login mit anderem Konto darf keine alte E-Mail anhaften lassen). Der Fallback-Guard sitzt in `ClaudeCodeProxyManager.authStatus(profile:)`: ohne eigene Auth-Datei läuft der Statusbefehl gar nicht; meldet der Proxy eine fremde `Account:`-ID, gilt das Profil als nicht angemeldet (Warnung `gpt_profile_auth_fallback_detected`). Ein geerbtes `CCP_CONFIG_DIR` wird für Status und Login immer entfernt. `CodexUsageFetcher` kann jetzt aus einem Proxy-Store lesen (`init(proxyAuthFile:)`, `fetchLiveUsage()` ohne JSONL-Fallback). Tests: `GPTAccountProfilesTests` (26), `ClaudeCodeProxyManagerTests` (+6). UI-Verdrahtung des Logins pro Profil folgt in Slice 3.

- **Neu `Services/AgentChats/GPTAccountProfiles.swift`** (Vorlage `ClaudeAccountProfiles.swift:37-300`): `profiles()` (main zuerst), `configDir(forProfile:)` (main → `~/.config/claude-code-proxy`), `authFileURL`, `isLoggedIn` = `codex/auth.json` existiert **und** trägt eine `accountId`, `accountInfo` aus `whisperm8-account.json` mit (mtime, size)-Cache (Grund identisch: Kontextmenü-Rebuilds, `ClaudeAccountProfiles.swift:108-142`), `activeProfileName()`/`activeProfileNameOrNil()`, `validatedProfileName(_:)` (wirft, fällt nie still zurück), `setActiveProfile`, `environmentOverrides(forProfile:)` → `["CCP_CONFIG_DIR": dir]`, `createProfile`, `removeProfile`. `GPTProfileSelection` = `.activeDefault | .explicit(String?)`.
- **`ClaudeCodeProxyManager`**: `authStatus(profile:)` und `startDeviceLogin(profile:…)` reichen `environmentOverrides` in `commandRunner`/`deviceLoginLauncher` durch (`:375-389`, `:512-571`). Nach erfolgreichem Login: `accountId` aus der Datei lesen, per V4 E-Mail/Plan holen, `whisperm8-account.json` schreiben. **Guard:** meldet `authStatus(profile:)` eine `accountId`, die nicht mit der Datei des Profils übereinstimmt (= Fallback-Falle), gilt das Profil als nicht eingeloggt.
- **Kill-Switch** `gptAccountProfilesEnabled` (Default an) in `AppPreferences`; aus → alles verhält sich wie heute.
- **Tests** (`GPTAccountProfilesTests`, Temp-Root): Discovery mit/ohne `.active`, gelöschtes Profil → main, `validatedProfileName` wirft bei unbekannt/nicht eingeloggt, `isLoggedIn` verlangt `accountId`, `environmentOverrides` leer für main und für fehlendes Verzeichnis. `ClaudeCodeProxyManagerTests`: Login/Status-Befehle tragen `CCP_CONFIG_DIR` (Spy auf `commandRunner`).
- **Abnahme:** Zweites Konto per Device-Login in ein Profil eingeloggt; `codex auth status` mit dessen `CCP_CONFIG_DIR` zeigt die andere `accountId`; der Default-Store ist unverändert.

## Slice 2 — Proxy-Instanz je Profil und Routing pro Session

- **`ClaudeCodeProxyManager.ensureRunning(profile:)`**: Registry `[profileName: (port, handle)]` unter `ensureLock`; `main` = heutiger Pfad (Port aus Preferences, ggf. extern laufend); Zusatzprofil → Port aus E2, Env mit `CCP_CONFIG_DIR`, `/healthz`-Probe, `willTerminate` beendet alle selbstgestarteten Instanzen (`stopIfSelfStarted`, `:360-373`). **Startet nie** ein Profil ohne eigene Auth-Datei (Fehler `.profileNotLoggedIn`). Router-Start bleibt einmalig.
- **`ClaudeGPTMixRouter`**: `Upstream.codexProxy` bekommt den Profilnamen (`case codexProxy(profile: String?)`); `upstream(for:headers:)` liest `X-WhisperM8-GPT-Profile`, fehlt er → E4. `upstreamHeaders` entfernt den Header vor **beiden** Upstreams (Anthropic soll ihn nie sehen). `upstreamURLResolver` fragt die Port-Registry; unbekanntes/nicht laufendes Profil → 503 mit klarer Anthropic-förmiger Fehlermeldung („GPT-Konto ‚x' ist nicht eingeloggt") statt stillem main.
- **Session-Stempel `gptProfileName`** in `AgentChat.swift` (neben `claudeProfileName`, `:298-307`, Codable), `createSession` per E3, Fork erbt (`+SessionLifecycle.swift:106`), CLI-Ausgabe (`ChatsOutput.swift:143`).
- **`AgentCommandBuilder`**: `gptProfileEnvironmentResolver` analog `claudeProfileEnvironmentResolver` (`:71-74`); im Router-Env (`:247-283`) zusätzlich `ANTHROPIC_CUSTOM_HEADERS = "X-WhisperM8-GPT-Profile: <name>"` (nur wenn Stempel ≠ main). `LoginShellEnvironment` strippt ein geerbtes `ANTHROPIC_CUSTOM_HEADERS` (Regel wie `CLAUDE_CONFIG_DIR`, `:119`: Routing nur über explizite Overrides).
- **Launch-Guards** (`AgentSessionDetailView.swift:372`, `+BackgroundAgents.swift:88-89`): `ensureRunning(profile: session.gptProfileName)` statt `ensureRunning(port:)`.
- **Tests:** Router — Header wird geparst, entfernt, an keinen Upstream weitergereicht; fehlender Header → Resolver-Default; unbekanntes Profil → 503 vor jedem Upstream (Muster `testRouterRejectsNoncanonicalGPTBeforeEitherUpstream`). Manager — zweites Profil startet mit `CCP_CONFIG_DIR` und eigenem Port; nicht eingeloggt → kein Start. Builder — Env enthält den Header genau bei Stempel. Store — Default-Resolver wird vor der Mutation aufgelöst, Codex bekommt `nil`.
- **Abnahme:** Zwei GPT-Chats laufen gleichzeitig auf zwei Konten (`lsof` zeigt zwei `serve`-Prozesse, `log stream` zeigt je Request das Profil); `/model`-Wechsel innerhalb einer Session bleibt beim Konto der Session; ein `gpt`-Subagent nutzt das Konto seiner Elternsession.

## Slice 3 — Settings-Tab „GPT-Konten" und Usage pro Konto

- **Neu `Views/Settings/Pages/GPTAccountsTab.swift`** nach `AgentChatsClaudeAccountsTab.swift` (Radio-Auswahl `:109`, Identitätsspalte `:138`, Gauges `:191`, Verwaltungsmenü `:215`): Liste aller Profile mit E-Mail/Plan/Login-Status, „Aktiv" schreibt `.active`, „Neu & anmelden…" (Profil anlegen + Device-Login mit Code-Anzeige, bestehende Mechanik aus `GPTBackendSettingsPage.swift:608-634`), „Anmelden…"/„Abmelden"/„Entfernen" (Entfernen stoppt die Instanz und löscht das Verzeichnis). Die heutige Sektion „ChatGPT-Konto" der GPT-Backend-Seite verweist auf den Tab bzw. zeigt nur noch main.
- **`CodexUsageFetcher`**: zweiter Konstruktor aus dem Proxy-Store (`access` + `accountId`) → derselbe Endpoint. **Zusätzlich** `allowed`/`limit_reached`/`model_usage` parsen und im Gauge als „gesperrt bis …" zeigen — der Fehlbefund von heute.
- **`AgentUsagePopovers.swift`** Codex-Seite (`:297-371`): ein Block je eingeloggtem GPT-Profil (Muster Claude `:166-215`), Aktiv-Marker, Aktualisieren-Knopf (fehlt heute), plus der CLI-Account als eigener Block mit Beschriftung „Codex-CLI / Diktat" — damit die beiden Spuren nie wieder verwechselt werden.
- **Tests:** `parseWhamUsage` mit `limit_reached`-Payload (Fixture vom 2026-09-16); Fetcher liest den Proxy-Store. UI → manuelle QA.
- **Abnahme:** Popover zeigt office@ als „gesperrt bis Mo 12:29" und ai@ mit freiem Kontingent, und nennt, welches Konto aktiv ist.

## Slice 4 — Kontowechsel bestehender Chats und CLI

- **Nicht laufende Chats:** Kontextmenü „GPT-Konto → …" (Einzel + Bulk über `actionGroup`/`bulkLabel`), setzt nur den Stempel; kein Transcript-Umzug nötig. Archivierte/Background/Terminal wie im Claude-Slice ausgeschlossen.
- **Laufende Chats (Hot-Switch):** Der Router hält eine Override-Map `sessionID → profile`; die Session sendet dafür zusätzlich `X-WhisperM8-Session-ID` (aus `WHISPERM8_SESSION_ID`, wird beim PTY-Spawn ohnehin injiziert). Wechsel = Stempel + Map-Eintrag, wirkt ab dem nächsten Request, ohne Neustart. Hinweis im Dialog: „Kontingent wechselt ab der nächsten Antwort."
- **CLI:** `whisperm8 chats new --gpt-account <name>` (Validierung über `validatedProfileName`, Fehler statt Fallback), `chats list/overview` zeigen das Konto, `chats move-account` für Bulk. Control-Server-Handler analog `claudeProfile`.
- **Tests:** Override-Map im Router (Vorrang vor Header); CLI-Validierung; Store-Mutation für Bulk bleibt eine Publikation.
- **Abnahme:** Chat läuft auf office@, wird auf ai@ umgestellt, die nächste Antwort kommt laut Log über die ai@-Instanz; Jarvis-`new` landet auf dem aktiven Konto.

## Slice 5 — Ausbaustufen (nicht Teil der Freigabe)

- **Limit-Erkennung im Router:** Codex-429 in `receive(response:)` (`ClaudeGPTMixRouter.swift:776-800`) erkennen, als klare Meldung an die Session reichen, Status sofort auf `turnAborted` statt 180 s „working".
- **Auto-Failover:** bei `limit_reached` des aktiven Kontos neue Chats automatisch auf das nächste freie Profil (Schwelle/Hysterese wie im Claude-Plan aus claude-swap übernommen). Produktentscheidung, kein Selbstläufer.
- **Katalog pro Konto**, falls V5 Abweichungen zeigt.
- **Proxy-Logging:** je Instanz eigene Log-Umleitung; heute schreibt ein App-gestarteter Proxy gar kein Log.

## Risiken & Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| Stiller Fallback des Proxys auf Default-/CLI-Credentials | `isLoggedIn` prüft die Datei + `accountId`-Abgleich; Instanz ohne eigene Auth wird nie gestartet; Router liefert 503 statt main (Slice 2) |
| Zweiter Login überschreibt versehentlich main | Login läuft immer mit `CCP_CONFIG_DIR` des gewählten Profils; main-Login bleibt der bisherige Button, deutlich beschriftet |
| N Proxy-Prozesse bleiben nach Crash verwaist | `willTerminate` beendet alle selbstgestarteten; beim Start `/healthz` je Port prüfen, fremde Listener nicht adoptieren (heutige Signatur-Probe) |
| Header erreicht Anthropic | `upstreamHeaders` entfernt ihn für beide Upstreams, Test erzwingt das |
| Falsches Konto aktiv → teuerster Bedienfehler | Aktiv-Marker im Popover + Konto-Badge am Tab (Folge-Slice, wie bei Claude) |
| `wham/usage` inoffiziell | Fallback auf JSONL-Snapshot bleibt; Fehlerdifferenzierung wie `ClaudeAccountUsageFetcher.swift:32-52` |
| Manuell gestarteter main-Proxy (PPID 1, Vorfall 2026-09-08) | unverändert: main wird nicht adoptiert, nur geprüft; Neustart bleibt Handarbeit |

## Reihenfolge und Freigabe

V1–V5 → Slice 1 → Slice 2 (zusammen freigeben, erst dann ist ein zweites Konto nutzbar) → Slice 3 → Slice 4. Kill-Switch `gptAccountProfilesEnabled` schaltet ab Slice 2 auf heutiges Verhalten zurück; Sessions mit Stempel laufen dann über main.

**Sofortmaßnahme unabhängig vom Plan** (Stand 16.09.): Das GPT-Backend hängt am gesperrten office-Konto. Umstellen = Device-Login in der GPT-Backend-Settings-Seite (oder `claude-code-proxy codex auth login`) mit ai@, danach den Proxy PID 90457 beenden, damit die App ihn mit dem neuen Grant startet.

## Quellen

- Proxy-Doku Codex-Provider und Dateiablage: https://claude-code-proxy.raine.dev/providers/codex/ · https://claude-code-proxy.raine.dev/reference/files-and-storage/
- Codex-Auth und Refresh-Rotation: https://learn.chatgpt.com/docs/auth · openai/codex#41973 · openai/codex#15754
- `ANTHROPIC_CUSTOM_HEADERS`: Claude-Code-Env-Referenz; Verifikation 2026-09-16 gegen lokalen Dummy-Endpoint (5/5 Requests mit Header)
- Analyse-Berichte 2026-09-16 (Auth-Kette, Claude-Profil-Vorlage, externe Fähigkeiten, Usage/Limits, Konsumenten-Inventur) — Scratchpad der Session, Kernbefunde oben eingearbeitet
