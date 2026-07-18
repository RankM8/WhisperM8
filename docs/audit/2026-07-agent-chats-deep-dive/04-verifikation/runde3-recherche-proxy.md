---
status: abgeschlossen
updated: 2026-07-18
description: Adversariale Verifikation der beiden Proxy-Recherchen zu claude-code-router und LiteLLM gegen WhisperM8s Mix-Router, Proxy-Manager, Tests sowie den tatsächlich delegierten claude-code-proxy-Vertrag.
---

# Runde 3: Verifikation der Proxy-Recherchen

## Auftrag, Quellen und Maßstab

Geprüft wurden:

- `03-vergleich/code-analysen/claude-code-router.md`,
- `03-vergleich/proxy-muster-litellm.md`,
- die produktiven Swift-Dateien `ClaudeGPTMixRouter.swift` und
  `ClaudeCodeProxyManager.swift`,
- die beiden zugehörigen Swift-Tests,
- Stichproben an den zitierten Stellen der lokalen Klone von
  `claude-code-router` (`19973394d26fb1afec697f5d091d62d300bcdf50`) und
  LiteLLM (`0439bcbfed7204169399d64e30637a71d54c7a4e`),
- als aktiver Widerlegungsversuch zusätzlich der tatsächlich delegierte
  `claude-code-proxy` bei Tag `v0.1.21`.

Quellenkürzel:

- **W/** = `/Users/giulianocosta/repos/whisperm8/`
- **C/** = `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/claude-code-router/`
- **L/** = `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/litellm/`
- **P/** = `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/claude-code-proxy-v0.1.21/`

Urteile:

- **BESTAETIGT** — die konkrete Vertragslücke bleibt nach Suche nach Guards,
  Delegation und Tests bestehen.
- **WIDERLEGT** — der als fehlend behauptete Vertrag wird an anderer Stelle
  tatsächlich behandelt; ein engerer Rest-Gap kann trotzdem verbleiben.
- **UNKLAR** — die verfügbaren Quellen entscheiden den End-to-End-Vertrag nicht.

Wichtigster methodischer Befund: Beide Recherchen grenzen die externe
Übersetzung grundsätzlich korrekt ab, ziehen ihre Lückenurteile danach aber
mehrfach doch nur aus dem transparenten Swift-Wrapper. Das ist zu kurz. Der
aktuelle `claude-code-proxy` besitzt eine eigene Anthropic-SSE-State-Machine,
Tool-Delta-Assembly, Stop-Reason-Mapping, Fehler-SSE, Token-Count-Endpoint und
Retries (`P/src/providers/codex/translate/live_stream.rs:212-238,524-575,854-903`;
`P/src/server.rs:102-128`; `P/src/providers/codex/mod.rs:311-385,556-635`).

## A. Verdicts zu `claude-code-router.md`

### L1 — Präfix-Switch statt validierter Ausführungsplanung

**Urteil: BESTAETIGT — als strukturelle Einschränkung, nicht als aktueller
Produktdefekt.**

Der Swift-Router kennt genau zwei feste Upstreams und entscheidet ausschließlich
über `model.hasPrefix("gpt-")` (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:31-34,85-95,268-284`).
Der Integrationstest fixiert exakt diese Zweiteilung, aber keine Registry oder
ungültigen Modelle (`W/Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:8-23,219-276`).
CCR besitzt dagegen eine Protokollpräferenz und eine begrenzte Versuchsplanung
(`C/packages/core/src/providers/runtime-topology.ts:10-51`;
`C/packages/core/src/routing/execution-plan.ts:8-45`).

Aktiver Gegenbeleg: WhisperM8 hat bereits einen Codex-Modellkatalog mit
Slug-Lookup und modellabhängigen Effort-Stufen
(`W/WhisperM8/Services/Shared/CodexModelCatalog.swift:48-64,123-149`). Er wird
aber nicht in der Routerentscheidung verwendet; das Settings-Modellfeld bleibt
frei editierbar (`W/WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:195-224`).
Für den bewusst engen Produktscope „Anthropic oder ein Codex-Backend“ ist das
Präfixrouting daher funktionsfähig. Mehrprovider-Regeln und Modellketten sind
kein zwingend zu schließender Defekt, solange dieser Scope bestehen bleibt.

### L2 — Keine Capability- und Token-Count-Schicht

**Urteil: WIDERLEGT — in der behaupteten Kombination.**

Der MixRouter implementiert `/v1/messages/count_tokens` nicht selbst und routet
auch diesen Pfad nur nach Body-Modell (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284,529-575`).
Der aktuelle delegierte Backendprozess registriert den Endpoint jedoch explizit
und dispatcht ihn als Count-Token-Request
(`P/src/server.rs:102-128`). Damit ist „Token Count hängt ungesichert vom
Upstream ab“ für das tatsächlich unterstützte GPT-Backend nicht wahr.

Der Capability-Teil bleibt enger bestätigt: Der lokale Katalog kennt Modelle
und Effort-Stufen (`W/WhisperM8/Services/Shared/CodexModelCatalog.swift:48-64,123-149`),
aber der Router veröffentlicht keinen Anthropic-kompatiblen Modellvertrag für
Bildinput, Tools, Kontextfenster oder Thinking und prüft ihn nicht beim Start
(`W/WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`). Das ist
ein Contract-/Versions-Gap, kein fehlender Token-Count-Endpoint. Außerdem ist
der vorhandene Proxy-Zähler nur approximativ; ein lokaler Test prüft für
`count_tokens` lediglich den HTTP-Head ohne Content-Length
(`W/Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:148-154`).

### L3 — Transportabschluss statt protokollsemantischem Streamabschluss

**Urteil: BESTAETIGT — im MixRouter, aber für den GPT-Pfad stark mitigiert.**

Der MixRouter reicht jedes Upstream-Byte unmittelbar weiter und setzt bei
`error == nil` den HTTP-Nullchunk, ohne `message_stop` oder ein eingebettetes
`event: error` zu prüfen (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-621`).
Die Swift-Tests beweisen nur byteweises Relay normaler Mock-Chunks
(`W/Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276`); unvollständige
SSE-Streams und Error-Events fehlen.

Die Forschungsvorlage ist korrekt: CCRs Parser hält UTF-8-/Zeilenreste über
Chunks, erkennt Terminalevents und eingebettete Fehler
(`C/packages/core/src/observability/request-log-store.ts:4376-4455,4458-4505`).
Der aktive Widerlegungsversuch begrenzt jedoch die reale GPT-Wirkung: Der
Codex-Proxy schließt offene Blöcke, emittiert `message_delta` und
`message_stop` (`P/src/providers/codex/translate/live_stream.rs:854-910`) und
synthetisiert bei Translationfehlern oder vorzeitig geschlossenem WebSocket ein
Anthropic-`event: error` (`P/src/providers/codex/mod.rs:556-635`). Offen bleibt
der direkte Anthropic-Pfad und jede lokale MixRouter-Störung nach bereits
gesendetem Response-Head.

### L4 — Keine Retry-/Fallback-Policy

**Urteil: WIDERLEGT — als absolute End-to-End-Aussage.**

Im Swift-Router selbst gibt es tatsächlich genau eine URLSession-Task; ein
Pre-Head-Fehler wird sofort 502 und ein später Fehler zum Disconnect
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:568-575,603-621,689-765`).
Launchzeit-Graceful-Degradation ist vorhanden, aber kein Request-Retry:
Bei unerreichbarem Backend startet der Chat ohne Router und zeigt einen Hinweis
(`W/WhisperM8/Services/AgentChats/ClaudeGPTLaunchGuard.swift:14-40`).

Der aktuelle GPT-Backendprozess besitzt dagegen sowohl Live-Start-Retries mit
gedeckelten Versuchen, `Retry-After` und Backoff als auch Buffered-HTTP-Retries
für temporäre Status- und Transportfehler
(`P/src/providers/codex/mod.rs:311-385,677-727`;
`P/src/providers/codex/client.rs:548-625`). Die Aussage „temporäre
Providerfehler werden nirgends erneut versucht“ ist daher widerlegt.

Als Rest-Gap bleiben eine providerübergreifende Modell-/Credential-Fallbackkette
und ein Retry für den direkten Anthropic-Zweig. Beides ist bei WhisperM8s
derzeitigem Zwei-Backend-Scope niedriger zu priorisieren als in der Recherche.
Insbesondere darf kein zusätzlicher MixRouter-Retry den bereits intern
wiederholten GPT-Request doppelt ausführen.

### L5 — Usage und Cachekosten sind unsichtbar

**Urteil: BESTAETIGT — als beobachteter End-to-End-Defekt; die behauptete
Implementierungsursache ist widerlegt.**

Der MixRouter loggt nur Modell, Upstream und HTTP-Status
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:654-657`). Die
Produktionsreproduktion zeigt in 20 GPT-Assistant-Turns null Input- und
Output-Tokens und daraus folgende blinde Präventivkompaktierung
(`W/docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde3-live-repro-usage-kompaktierung.md:14-43`).
Damit ist der Nutzerdefekt bestätigt.

Falsch ist jedoch die Kausalverkürzung „nirgends übersetzt“: Der delegierte
Proxy liest `input_tokens`, `output_tokens` und Cached Tokens aus der Codex-
Response (`P/src/providers/codex/translate/live_stream.rs:1044-1059`), subtrahiert
Cache-Reads vom ungecacheten Anthropic-Input und emittiert die Felder separat
(`P/src/providers/codex/translate/reducer.rs:1092-1120`). Ein Unit-Test fixiert
100 Gesamtinput, 20 Cache-Read und 50 Output zu 80/20/50
(`P/src/providers/codex/translate/reducer.rs:1510-1522`). Die State-Machine
emittiert diese Usage im finalen `message_delta`
(`P/src/providers/codex/translate/live_stream.rs:854-903`).

Daraus folgt für den Fix: Nicht blind LiteLLMs OpenAI→Anthropic-Adapter im
MixRouter duplizieren. Zuerst ist per echter Proxy-E2E-Fixture zu klären, warum
der Live-Codex-Terminalevent trotz vorhandener Mapper null liefert. Danach muss
der Vertrag am Routerausgang getestet werden.

### L6 — Crash-Ownership und Backend-Identität

**Urteil: BESTAETIGT.**

WhisperM8 hält Ownership nur als RAM-Handle und beendet bei App-Terminierung nur
diesen Handle (`W/WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:155-159,198-205,286-300`).
Nach einem App-Crash ist dieses Wissen verloren. Die Probe akzeptiert jede
Loopback-Antwort mit Status 200, JSON-Content-Type und `{ "ok": true }`
(`W/WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`); genau
diese konstante Antwort liefert der echte Backendprozess
(`P/src/server.rs:102-120`). Die Tests prüfen die Form, aber keine
prozessgebundene Challenge (`W/Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:187-209`).

CCR bindet dagegen PID und Startzeit an eine Runtime-ID, vergleicht sie mit
`/health` und eskaliert nach SIGTERM auf SIGKILL
(`C/packages/core/src/gateway/core-runtime/supervisor.ts:335-371,375-412,480-504`).
Der MixRouter selbst bindet zwar loopback-only
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:127-134`), verlangt
aber pro Verbindung kein lokales Credential
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`). Loopback
reduziert die Reichweite, ersetzt aber keine Prozessidentität oder lokale
Autorisierung.

## B. Verdicts zu `proxy-muster-litellm.md`

### M1 — Fehlender Anthropic-SSE-Zustandsautomat

**Urteil: WIDERLEGT — für den GPT-Gesamtpfad.**

LiteLLM besitzt tatsächlich per Stream isolierte Queue-/Blockzustände und eine
Hold-and-merge-Logik (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:200-237,415-448,519-557`).
Dass der Swift-Router selbst nur Bytes weiterreicht
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`), beweist aber
keine End-to-End-Lücke: Der aktuelle Codex-Proxy erzeugt `message_start`,
blockweise Deltas, Stop-Blöcke, finales `message_delta` und `message_stop`
(`P/src/providers/codex/translate/live_stream.rs:212-238,296-575,854-903`).
Ein zweiter Zustandsautomat im MixRouter wäre doppelte Protokollverantwortung.
Bestätigt bleibt nur L3s fehlender passiver Abschlussmonitor am äußeren Rand.

### M2 — Fehlende Tool-Call-Delta-Assembly

**Urteil: WIDERLEGT — für normale Tool-Calls.**

LiteLLMs Start mit leerem Argumentstring, stabiler Tool-Index und Abschluss
leerer Argumente sind an den zitierten Stellen real
(`L/litellm/llms/anthropic/chat/handler.py:788-825,879-908`). Der delegierte
Codex-Proxy besitzt jedoch ebenfalls indexgebundene Tool-Blöcke, emittiert
`input_json_delta.partial_json` und schließt den Block
(`P/src/providers/codex/translate/live_stream.rs:444-575`). Die Recherche hat
korrekt nur den Swift-Router durchsucht, daraus aber zu viel Risiko abgeleitet.

Ein enger realer Tool-Gap existiert bei multimodalen Tool-Ergebnissen, siehe M5.

### M3 — Token-Usage, Streaming und Cache

**Urteil: BESTAETIGT — End-to-End; Implementierung vorhanden, Live-Vertrag gebrochen.**

LiteLLMs Muster ist korrekt belegt: Es hält den Finish-Chunk, mischt einen
nachfolgenden Usage-Chunk ein und wahrt die Reihenfolge bis `message_stop`
(`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:213-237,423-448,519-552`).
Der Live-Defekt in WhisperM8 bleibt bestätigt
(`W/docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde3-live-repro-usage-kompaktierung.md:14-43`).

Die Schlussfolgerung „fehlende Übersetzung im MixRouter“ ist dagegen nicht
belegt: Der reale Backendadapter mappt Usage cache-bewusst und emittiert sie im
finalen Anthropic-Event
(`P/src/providers/codex/translate/reducer.rs:1092-1120`;
`P/src/providers/codex/translate/live_stream.rs:854-903,1044-1059`). Benötigt
wird zuerst ein Golden-E2E-Test über den echten Proxy, nicht zwingend eine neue
Swift-State-Machine.

### M4 — Stop-Sequenzen und Finish-Reasons fehlen

**Urteil: WIDERLEGT — für die unterstützten Codex-Terminalzustände.**

LiteLLMs Mapping `stop`/`length`/`tool_calls` zu Anthropic ist korrekt belegt
(`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1219-1226`).
Der aktuelle Proxy berechnet äquivalent `max_tokens` bei unvollständiger
Response, `tool_use` nach Tool-Aufruf und sonst `end_turn`, bevor er
`message_delta` und `message_stop` emittiert
(`P/src/providers/codex/translate/live_stream.rs:854-903`). Der opaque Swift-
Body ist daher Absicht, kein fehlendes End-to-End-Mapping. Eine konkret getroffene
`stop_sequence` wird weiterhin nicht rekonstruiert; sowohl Proxy als auch
LiteLLM setzen sie im Abschluss auf `null`
(`P/src/providers/codex/translate/live_stream.rs:887-895`;
`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1344-1353`).

### M5 — Multimodale Blöcke und Tool-Result-Inhalte

**Urteil: BESTAETIGT — nur für Bilder in `tool_result`; als generischer
Multimodal-Gap widerlegt.**

Direkte User-Bilder werden vom aktuellen Proxy zu Codex-`InputImage`
übersetzt (`P/src/providers/codex/translate/request.rs:649-664`). Bei
`tool_result` wird der Inhalt jedoch in einen String für
`FunctionCallOutput` reduziert (`P/src/providers/codex/translate/request.rs:665-692`);
URL- und Base64-Bilder werden dabei absichtlich zu `[image omitted: ...]`
(`P/src/providers/codex/translate/request.rs:847-905`). Der Router kann die
verlorenen Pixel nach dieser Delegationsstufe nicht wiederherstellen
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-600`).

LiteLLM erhält mehrere Text-/Bildteile eines Tool-Results dagegen als eine
zusammengehörige Tool-Message
(`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:418-498`).
Das ist ein echter, enger Funktions-Gap für screenshotbasierte Tools; direkte
Bildeingaben sind nicht betroffen.

### M6 — Fehler-Mapping und terminale Streamfehler

**Urteil: BESTAETIGT — ausschließlich für MixRouter-eigene Fehler; für die
delegierte GPT-Übersetzung widerlegt.**

Der MixRouter sendet lokale Fehler als `text/plain`; Pre-Head-Upstreamfehler
werden 502 und späte Fehler nur zum Socketabbruch
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-633`). Das
verletzt den Anthropic-JSON-/SSE-Fehlervertrag. Die Routertests enthalten keinen
Connect-Fehler, Timeout oder vorzeitig beendeten SSE-Stream
(`W/Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-353`).

Für den GPT-Upstream ist die breitere Behauptung widerlegt: Der Codex-Proxy
klassifiziert Terminal- und Error-Events
(`P/src/providers/codex/mod.rs:665-739`), emittiert auf Übersetzungsfehler und
vorzeitig geschlossenem WebSocket ein Anthropic-`event: error`
(`P/src/providers/codex/mod.rs:556-635`) und erhält normale HTTP-Fehler als
Anthropic-JSON-Antwort (`P/src/providers/codex/mod.rs:767-823`). LiteLLMs
synthetischer Error bei fehlendem Terminalevent ist damit ein vorhandenes, nicht
ein fehlendes Backendmuster
(`L/litellm/llms/anthropic/experimental_pass_through/messages/streaming_iterator.py:186-211`).

## C. Zusätzlich entdeckter Gegenbefund zur Client-Cancellation

Die CCR-Recherche sagt zu Recht, dass `finish()` eine laufende URLSession
cancelt (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:646-651`).
Sie bewertet WhisperM8s Abbruchpfad dennoch zu günstig: Sobald `forward()` die
`upstreamTask` gesetzt hat, verhindert der Guard im Receive-Callback ein
erneutes `receiveMore()` (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:481-499,568-575`).
Ein geordneter Client-FIN während einer langen Pre-Header-Denkphase wird deshalb
nicht aktiv gelesen; `.failed`/`.cancelled` oder erst ein späterer Sendefehler
müssen `finish()` erreichen (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:461-479,636-651`).
Der vorhandene Half-Close-Test endet bereits im lokalen 400-Pfad und übt diesen
Fall nicht aus (`W/Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:297-321`).

**Urteil: BESTAETIGT** als zusätzlicher Ressourcen-/Cancellation-Gap.

## D. Urteilsmatrix

| ID | Behauptete Lücke | Urteil | Entscheidende Korrektur |
|---|---|---|---|
| CCR-L1 | Kein validiertes Routing/Execution Plan | **BESTAETIGT** | Strukturelle Einschränkung; bei heutigem Zwei-Backend-Scope kein akuter Defekt. |
| CCR-L2 | Keine Capabilities und kein Token Count | **WIDERLEGT** | Proxy hat Count-Endpoint; Capability-/Versionsvertrag bleibt unvollständig. |
| CCR-L3 | Kein semantischer Streamabschluss | **BESTAETIGT** | MixRouter überwacht nicht; GPT-Proxy garantiert aber Terminal-/Error-Events. |
| CCR-L4 | Keine Retry-/Fallback-Policy | **WIDERLEGT** | GPT-Proxy retryt; nur Router-/Anthropic-/Modellfallback fehlt. |
| CCR-L5 | Usage/Cache unsichtbar | **BESTAETIGT** | Live null; Mapper existiert, daher Ursache nicht „keine Übersetzung“. |
| CCR-L6 | Keine crashfeste Ownership/Identität | **BESTAETIGT** | RAM-Handle plus imitierbares konstantes Health-JSON. |
| LL-M1 | Kein SSE-Zustandsautomat | **WIDERLEGT** | Zustandsautomat lebt im delegierten Proxy. |
| LL-M2 | Keine Tool-Delta-Assembly | **WIDERLEGT** | Normale Tool-Calls werden index-/blockgebunden übersetzt. |
| LL-M3 | Usage-/Cache-Vertrag fehlt | **BESTAETIGT** | Live-Vertrag gebrochen, obwohl Mapper vorhanden ist. |
| LL-M4 | Stop-/Finish-Mapping fehlt | **WIDERLEGT** | Proxy mappt `end_turn`, `tool_use`, `max_tokens`. |
| LL-M5 | Multimodalität fehlt | **BESTAETIGT**, eng | Nur Tool-Result-Bilder gehen verloren; direkte User-Bilder funktionieren. |
| LL-M6 | Fehler-/Terminal-Mapping fehlt | **BESTAETIGT**, eng | Nur MixRouter-lokale Fehler; GPT-Proxy besitzt Anthropic-Error-SSE. |
| Zusatz | Client-FIN wird beim Denken nicht aktiv gelesen | **BESTAETIGT** | Nach Forward wird kein weiterer Receive armiert. |

Summen ohne Zusatzfinding: **7 BESTAETIGT, 5 WIDERLEGT, 0 UNKLAR**. Mehrere
Bestätigungen sind ausdrücklich enger als die Ausgangsbehauptung.

## E. Priorisierte reale Lücken, die geschlossen werden müssen

1. **P0 — GPT-Usage/Kompaktierungsvertrag E2E reparieren.** Der Live-Ausfall ist
   real, aber der Proxy enthält bereits den Mapper. Zuerst echter Proxy-Terminalevent
   → Routerausgang → Claude-Transcript als Golden-Test; danach Ursache in Proxy,
   Upstreamevent oder Adapter beheben
   (`W/docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde3-live-repro-usage-kompaktierung.md:14-43`;
   `P/src/providers/codex/translate/live_stream.rs:854-903,1044-1059`).
2. **P0 — Externen Übersetzungsvertrag versionieren und lokal qualifizieren.** Health
   belegt nur `{ "ok": true }`, nicht Version oder Fähigkeiten; die Swift-Suite
   ersetzt den Übersetzer durch Byte-Mocks
   (`W/WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`;
   `W/Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276,463-615`).
3. **P1 — Crashfeste Ownership plus lokale Backend-/Router-Authentisierung.** PID,
   Runtime-ID und Startzeit persistieren, Health-Challenge binden und Shutdown
   eskalieren (`W/WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:155-159,286-300,469-537`;
   `C/packages/core/src/gateway/core-runtime/supervisor.ts:335-412,480-504`).
4. **P1 — Client-Disconnect während Pre-Header-Denkphase aktiv erkennen.** Parallel
   zum Upstream weiter Client-EOF lesen und die URLSession sofort canceln
   (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:481-499,646-651`).
5. **P2 — Äußeren Fehler-/SSE-Vertrag härten.** Lokale Fehler als Anthropic-JSON,
   späte lokale Fehler als terminales SSE-Error soweit noch sendbar, plus passiver
   bounded Terminalmonitor; keine zweite Übersetzungsschicht
   (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-633`;
   `C/packages/core/src/observability/request-log-store.ts:4376-4455`).
6. **P2 — Tool-Result-Bilder bewusst entscheiden.** Entweder Pixel erhalten oder die
   dokumentierte Einschränkung als Capability ausweisen und E2E testen
   (`P/src/providers/codex/translate/request.rs:665-692,847-905`).

Nicht als Pflicht-Fix übernommen werden CCRs vollständige Multi-Provider-Policy,
ein zweiter SSE-Transformator im MixRouter oder zusätzliche GPT-Retries: Diese
würden den aktuellen Produktscope vergrößern beziehungsweise bereits vorhandene
Proxyverantwortung duplizieren
(`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:31-34,85-95`;
`P/src/providers/codex/mod.rs:311-385`).
