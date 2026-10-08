---
status: aktiv
updated: 2026-10-08
---

# Transkription über das ChatGPT-Abo (GPT-Backend)

Dritter Diktat-Anbieter neben Groq und OpenAI: `TranscriptionProvider.chatgpt`
(„ChatGPT-Abo"). Er braucht keinen eigenen API-Key, sondern nutzt den
ChatGPT-Login des GPT-Backends. Das Audio geht an den lokalen GPT-Proxy
(`claude-code-proxy`), der es an den **inoffiziellen** Endpoint
`chatgpt.com/backend-api/transcribe` weiterreicht.

Opt-in: wählbar ist der Anbieter standardmäßig, ausgewählt ist er erst, wenn
der Nutzer ihn wählt. Nur im App-Diktat — `whisperm8 transcribe` lehnt
`--provider chatgpt` und `--model chatgpt-transcribe` ab.

Kill-Switch: `defaults write com.whisperm8.app chatGPTTranscriptionEnabled -bool NO`
— die Option verschwindet aus allen Pickern, `TranscriptionSettings.loadProvider()`
liefert Groq (der gespeicherte Wert bleibt, Wiedereinschalten bringt die Wahl
zurück), Proxys starten ohne Flag und der Orphan-Guard prüft die Route nicht.

## Ablauf

1. **Aufnahmestart:** `RecordingCoordinator.startRecording()` ruft nach dem
   Start der Aufnahme den Prewarm-Seam (`ChatGPTTranscriptionWarmup`). Nur für
   `.chatgpt` mit eingeschaltetem Feature und GPT-Backend: im Hintergrund das
   aktive Profil lesen, und wenn dessen Instanz nicht antwortet,
   `ensureRunning(profile:)`. Höchstens ein Prewarm gleichzeitig; außerhalb des
   `recordingStart`-Budgets.
2. **Stopp:** `transcribeAndDeliver` prüft den Zugang über
   `TranscriptionCredentialGate` (Anbieter ohne Key → immer erfüllt) und reicht
   `""` an die Factory; `createService` baut
   `ChatGPTSubscriptionTranscriptionService`.
3. **Service:** Feature und GPT-Backend prüfen (sonst Fehler, ohne Netz),
   aktives Profil und Port lesen (off-main). Port unbekannt (Profil-Instanz
   läuft nicht) → vorher `ensureRunning`.
4. **Upload:** `MultipartTranscriptionClient(apiKey: nil, config: .chatGPTProxy(port:))`
   → `POST http://127.0.0.1:<instanzport>/v1/audio/transcriptions`, ohne
   `Authorization`, ohne `model`-Feld, `language` nur bei gesetzter Sprache, nie
   `response_format`. Dekodiert wird nur `text`; Zusatzfelder wie
   `asset_pointer` werden ignoriert.
5. **Connection refused** (`URLError.cannotConnectToHost`): genau ein
   `ensureRunning` und genau ein Retry — der Request hat den Proxy nie erreicht,
   ein doppelter Upload ist ausgeschlossen. `networkConnectionLost` wird nicht
   wiederholt.
6. **Abbruch:** `CancellationError` und `URLError.cancelled` gehen unverändert
   durch — der Cancel/ESC-Pfad des Coordinators sichert die Aufnahme.

Log (nie Text oder Audio): `chatgpt_transcription status=… ms=… profile=… bootstrap_ms=…`.

## Entscheidungen

| Thema | Entscheidung | Begründung |
|---|---|---|
| Router oder direkter Port | Direkt an den Instanz-Port (main: Backend-Port, Zusatzprofil: `port(forProfile:)`) | Der Mix-Router routet nach dem JSON-Feld `model`; ein Multipart-Body hat keins und landete bei Anthropic. |
| Welches Konto | Das **aktive** GPT-Profil; Profil-Kill-Switch aus → main | Wie der Router für Requests ohne Profil-Header: wer wegen eines Limits umschaltet, erwartet, dass das Diktat mitwechselt. |
| Aktives Profil nicht angemeldet | Fehler `.profileNotLoggedIn`, **kein** Rückfall auf main | Vorhersehbar, welches Konto das Audio bekommt. |
| Flag | `CCP_CODEX_TRANSCRIPTIONS_API=1` bei **jeder** selbst gestarteten Instanz (main und Profile); Kill-Switch aus → aktiv entfernt, auch eine geerbte | Sonst lieferte ein späterer Anbieterwechsel 404 bis zum Proxy-Neustart. Die Route bindet nur auf 127.0.0.1. |
| Alte Waise ohne Route | `ClaudeCodeProxyOrphanGuard` ersetzt beim App-Start zusätzlich eine Waise (PPID 1, Name `claude-code-proxy`) mit fehlender Route (`reason=transcription_route_missing`) | Genau der Update-Fall nach `make dev`. Beim Start sicher: läuft vor `ensureRunning`, es hängt noch kein Request an der Waise. |
| 404 zur Laufzeit | Kein Neustart, nur eine klare Meldung | Laufende GPT-Chats würden abgeschnitten; einen fremden Proxy beendet WhisperM8 nie. |
| GPT-Backend aus | Fehler „GPT-Backend aktivieren" | „Backend aus" heißt „kein Proxy-Prozess". |
| Fallback auf Groq/OpenAI | Keiner | Audio ginge still an einen anderen Anbieter. Die Aufnahme ist gesichert, „Erneut versuchen" liest den Anbieter neu. |
| Modell | Pseudo-Modell `chatgpt-transcribe` | Hält `model.provider == provider` ohne Sonderfälle; geht nie an den Server. |
| Onboarding | Option nur bei aktivem GPT-Backend oder bereits gewähltem Anbieter | Neue Nutzer haben kein GPT-Backend — die Option wäre eine Sackgasse. |

## Route-Probe

`ClaudeCodeProxyManager.transcriptionRouteStatus(port:)` schickt
`POST /v1/audio/transcriptions` mit `Content-Type: text/plain` und leerem Body.
Der Proxy-Handler prüft den Content-Type vor allem anderen: **415** = Route
registriert, **404** (Fallback-Handler, `error.type: "not_found"`) = Route
fehlt, alles andere = `.unknown`. chatgpt.com wird dabei nie angesprochen.
`.unknown` ersetzt nie — schlimmstenfalls bleibt die Meldung statt der Heilung.

## Fehlermatrix

| Antwort des Proxys | Fall | Meldung (Kern) |
|---|---|---|
| Kill-Switch aus | `.featureDisabled` | deaktiviert |
| GPT-Backend aus | `.backendDisabled` | GPT-Backend aktivieren |
| `ensureRunning` → nicht angemeldet | `.profileNotLoggedIn` | aktives GPT-Konto nicht angemeldet |
| anderer Startfehler / 2× Connection refused | `.proxyUnavailable` | Proxy konnte nicht gestartet werden |
| 401 / 403 ohne `upstream_error` | `.notAuthenticated` | Proxy-Login fehlt/abgelaufen (Refresh gescheitert), `codex login` reicht nicht |
| 401 / 403 mit `upstream_error` | `.upstreamRejected` | chatgpt.com hat trotz gültigem Proxy-Login abgewiesen — meist vorübergehend (Live-Test 2026-10-08: einmal beim Kaltstart), erneut versuchen |
| 404 ohne `upstream_error` | `.routeDisabled(origin:)` | extern: mit Flag neu starten oder beenden; selbst gestartet: Binary zu alt (ab v0.1.30), App-Neustart |
| 404 / 410 mit `upstream_error` | `.endpointGone` | Endpoint vermutlich weggefallen, auf Groq/OpenAI wechseln |
| 413 / Datei > 25 MB | `.tooLarge` | max. 25 MB |
| 429 `local_capacity_exceeded` | `.rateLimited(local: true)` | zu viele gleichzeitige (Proxy erlaubt 4) |
| 429 sonst | `.rateLimited(local: false)` | ChatGPT-Limit erreicht |
| 400 / 415 / andere 4xx | `.badRequest` | Meldung des Proxys |
| 5xx | `.upstreamUnavailable` | nicht erreichbar |
| `URLError` außer `.cancelled` | `.network` | Netzwerkfehler |

Die Herkunft (`instanceOrigin`) wird nur bei einer fehlenden Route bestimmt —
für main kostet sie eine Health-Probe.

## Messwerte

Live-Test vor der Umsetzung (main-Profil, kurze Diktate): 0,87–1,33 s vom
Upload bis zum Text. Im Normalfall (Port bekannt, Proxy läuft) kostet der
Anbieter keinen zusätzlichen Overhead — keine Health-Probe, kein
Router-Refresh vor dem Upload.

## Datenschutz und Grenzen

- **Inoffizieller Upstream:** Format, Cloudflare-Verhalten und Speicherdauer
  können sich ohne Ankündigung ändern.
- **Speicherung:** ChatGPT speichert die Aufnahme laut Antwort 30 Tage
  (`asset_ttl`).
- **Kein Prompt/Vokabular:** nur Sprache wird übergeben.
- **Kontingent:** unklar, ob die Transkription auf die Nutzungslimits des
  ChatGPT-Kontos zählt — der Preistext lautet deshalb „im ChatGPT-Abo
  enthalten", nicht „kostenlos".
- **Limits:** 25 MB Audio (`MAX_AUDIO_BYTES` des Proxys), 4 parallele
  Transkriptionen pro Proxy-Instanz.
- **Konto:** der eigene OAuth-Grant des Proxys, nicht `codex login`.

## Offene Punkte

- Wird das GPT-Backend erst zur Laufzeit eingeschaltet und läuft noch eine
  Waise ohne Route, greift der Orphan-Guard nicht (er läuft nur beim
  App-Start mit aktivem Backend) — dann erscheint die Meldung „extern", ein
  App-Neustart behebt es.
- Profil-Instanz-Waisen (Ports main+10 …) werden weiterhin nicht aufgeräumt.
- `ensureRunning` im Retry-Pfad blockiert einen globalen Queue-Thread bis zu
  ~3,5 s; ESC greift erst danach.

## Schlüsseldateien

- `WhisperM8/Services/Dictation/ChatGPTSubscriptionTranscription.swift` — Service, Abhängigkeiten, Fehler, Mapper, Prewarm.
- `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift` — `ProviderConfig.chatGPTProxy(port:)`, optionaler Key und optionales `model`.
- `WhisperM8/Models/TranscriptionProvider.swift` — `.chatgpt`, `chatgpt_transcribe`, `selectableProviders`, `TranscriptionCredentialGate`, Kill-Switch-Fallback.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift` — `launchEnvironment`, Flag, `instanceOrigin`, Route-Probe.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift` — Kriterium `transcription_route_missing`.
- `WhisperM8/Views/TranscriptionAccountControls.swift` — `ChatGPTTranscriptionNotice`.

## Tests

`ChatGPTSubscriptionTranscriptionTests` (Request-Form, Mapper-Tabelle,
Bootstrap, Retry, Abbruch, Prewarm), `ClaudeCodeProxyManagerTests` (Flag,
Kill-Switch, `instanceOrigin`, Probe-Klassifikator),
`ClaudeCodeProxyOrphanGuardTests` (Route-Kriterium, Lazy-Probe),
`RecordingCoordinatorTranscriptionTests`, `PreferencesTests`,
`TranscriptionUtilityTests` (Body ohne `model`), `CLITranscriptionTests`
(Ablehnung in der CLI).
