---
status: abgeschlossen
updated: 2026-07-18
description: Quellcodevergleich von musistudio/claude-code-router mit WhisperM8s GPT-Mix-Router — Protokollgrenzen, SSE, Usage, Retry, Modellrouting sowie Prozess- und Port-Lifecycle.
---

# `claude-code-router` vs. WhisperM8-GPT-Mix-Router

## 1. Umfang und Quellenstand

Untersucht wurde der lokale Klon von `musistudio/claude-code-router` bei Commit
`19973394d26fb1afec697f5d091d62d300bcdf50` sowie die produktiven WhisperM8-Dateien
`ClaudeCodeProxyManager.swift` und `ClaudeGPTMixRouter.swift`. Alle Fremdprojektbelege stammen
aus diesem Klon; Webquellen wurden nicht verwendet. Es wurden keine Builds oder Tests
ausgeführt.

Die wichtigste Abgrenzung vorweg: Der lokale `claude-code-router`-Quellcode enthält **nicht**
die vollständige blockweise Anthropic↔OpenAI-Übersetzung. Er deklariert
`@the-next-ai/ai-gateway` als Abhängigkeit (`packages/core/package.json:18-24`), löst dieses
Paket beziehungsweise ein gebündeltes `next-ai-gateway.js` als Child-Entry auf
(`packages/core/src/gateway/internal/shared.ts:293-295`;
`packages/core/src/gateway/core-runtime/supervisor.ts:32-68`) und übergibt ihm Provider mit
einem Protokolltyp (`packages/core/src/providers/runtime-topology.ts:123-161`). Aussagen wie
„CCR übersetzt jedes `tool_result`- oder Thinking-Feld korrekt“ wären aus dem geklonten
Quellcode allein daher nicht belegbar. Das ist keine Nebenbemerkung, sondern die
Architekturgrenze des Vergleichs.

WhisperM8 besitzt eine ähnliche Grenze: Der Swift-Router entscheidet nur anhand des
Top-Level-Modellnamens zwischen Anthropic und dem externen `claude-code-proxy`
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`) und reicht Body sowie
Response-Bytes unverändert weiter (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575,578-621`).
Die eigentliche Anthropic↔Codex-Übersetzung gehört damit nicht zur untersuchten
Swift-Eigenimplementierung.

## 2. Architekturvergleich

### `claude-code-router`

CCR besteht aus einem öffentlichen HTTP-Gateway und einem separaten Core-Gateway-Child. Das
öffentliche Gateway authentisiert Requests, routet Modelle, plant Fallback-Versuche, überwacht
Streams und leitet zum Core weiter (`packages/core/src/gateway/http/request-handler.ts:130-171`;
`packages/core/src/gateway/request/pipeline.ts:490-570`). Der Child wird mit eigener
Loopback-Adresse, eigenem Port, zufälliger Runtime-ID und internem Auth-Token gestartet
(`packages/core/src/gateway/core-runtime/supervisor.ts:19-28,100-115`).

Provider sind nicht nur URLs: CCR normalisiert fünf Protokollfamilien — Anthropic Messages,
OpenAI Responses, OpenAI Chat Completions sowie zwei Gemini-Protokolle
(`packages/core/src/providers/runtime-topology.ts:382-404`) — und wählt für einen
Anthropic-Client eine passende Provider-Capability nach einer expliziten Präferenzordnung
(`packages/core/src/providers/runtime-topology.ts:10-51`).

### WhisperM8

WhisperM8s `ClaudeGPTMixRouter` ist bewusst ein kleiner, loopback-only HTTP/1.1-Switch. Pro
Client-Verbindung wird genau ein Request angenommen; die Antwort wird als HTTP-Chunked-Stream
weitergereicht (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:24-27,481-531,578-601`).
`ClaudeCodeProxyManager` startet bei Bedarf `claude-code-proxy serve --no-monitor --port ...`,
wartet auf `/healthz` und startet anschließend den In-Process-Router
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`). Die einzige
Routingregel lautet faktisch: Modell beginnt mit `gpt-` → Codex-Proxy, sonst Anthropic
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`).

## 3. Punkt-für-Punkt-Vergleich der geforderten Protokollthemen

| Thema | `claude-code-router` | WhisperM8 | Belegtes Urteil |
|---|---|---|---|
| `tool_use` / `tool_result` | Die generische Cross-Protocol-Übersetzung liegt im externen Core-Gateway. Lokal belegbar sind Protokollauswahl sowie ein eigener Hosted-Web-Search-Pfad, der Anthropic-`tool_use` erkennt und `server_tool_use`/`web_search_tool_result` erzeugt (`packages/core/src/providers/runtime-topology.ts:41-51`; `packages/core/src/gateway/features/hosted-web-search/evidence.ts:149-159,559-575`). | Der Swift-Router deserialisiert nur `model`; Content-Blöcke werden nicht gelesen oder verändert (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284,529-575`). | **Kein generischer Übersetzungs-Gap aus diesem Klon beweisbar.** CCR besitzt aber eine explizite Protokoll-/Capability-Schicht und einen speziellen Tool-Pfad, die WhisperM8s Router fehlen. |
| Bilder | CCR liest Modellkatalog-Capabilities und Input-Modalitäten und publiziert `image_input.supported` modellspezifisch (`packages/core/src/gateway/features/model-discovery.ts:433-460,464-502`). | Kein Modellkatalog und keine Capability-Antwort; Bilder werden höchstens transparent an den gewählten Upstream weitergereicht (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284,534-575`). | **Gap:** WhisperM8 kann Claude Code nicht selbst mitteilen, ob das geroutete GPT-Modell Bildinput unterstützt. Keine belegte Aussage zur eigentlichen Bildblock-Übersetzung auf beiden Seiten. |
| Thinking | CCR leitet aus dem Katalog Reasoning und Adaptive Thinking ab und veröffentlicht unterstützte Thinking-Typen sowie Effort-Stufen (`packages/core/src/gateway/features/model-discovery.ts:441-455,483-501`). | Keine Capability-Aushandlung; Request und SSE bleiben opaque Bytes (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-621`). | **Gap:** Capability-Discovery fehlt. Die generische Übersetzung von `thinking`, `thinking_delta`, `signature_delta` oder `redacted_thinking` ist im CCR-Klon nicht implementiert, sondern an das Core-Gateway delegiert; deshalb kein weitergehender Feld-Gap behauptet. |
| `cache_control` | Im lokalen CCR-Code ist keine generische Request-Transformation von `cache_control` auffindbar. Belegt ist dagegen Usage-Normalisierung für Anthropic-, OpenAI- und Gemini-Cachefelder (`packages/core/src/usage/store.ts:1088-1130,1136-1170`). | Der Router verändert `cache_control` nicht, wertet es aber auch nicht aus; geloggt werden nur Modell, Upstream und HTTP-Status (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575,654-657`). | **Gap nur bei Observability/Accounting:** CCR zählt Cache-Read/-Write-Tokens protokollübergreifend, WhisperM8 nicht. Keine belegte Behauptung, CCR übersetze `cache_control` lokal. |
| `stop_reason` | Die generische Normalisierung liegt ebenfalls hinter der Core-Gateway-Grenze. Im eigenen Hosted-Web-Search-Pfad korrigiert CCR jedoch `tool_use` beziehungsweise synthetisches `max_tokens` zu `end_turn`, sofern kein Client-Tool-Use offen ist (`packages/core/src/gateway/features/hosted-web-search/evidence.ts:217-252`). | Keine semantische Prüfung; der SSE-Body wird unverändert gechunkt (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:595-621`). | **Spezifischer Gap:** WhisperM8 besitzt keinen äquivalenten Feature-Pfad und keine Stop-Reason-Validierung. Ein generischer Mapping-Gap ist aus CCRs lokalem Quellcode nicht belegbar. |
| Usage | CCR sampelt Streaming-Responses, erfasst Usage am Stream-Ende und schreibt Modell, Provider, Dauer, Status und Fallback-Kontext (`packages/core/src/gateway/request/pipeline.ts:621-701`). Der Normalizer versteht `input_tokens`/`output_tokens`, `prompt_tokens`/`completion_tokens`, Gemini-`usageMetadata` und Cachefelder (`packages/core/src/usage/store.ts:1104-1170`). | Nur ein einzelner Logeintrag `model`, `upstream`, `status`; keine Token-, Cache-, Dauer- oder Fallbackdaten (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:654-657`). | **Klarer Gap:** protokollübergreifende Usage- und Kostenobservability fehlt vollständig. |
| `/v1/messages/count_tokens` | Das öffentliche Gateway behandelt den Endpoint selbst und antwortet nach Auth/Limitprüfung (`packages/core/src/gateway/http/request-handler.ts:156-168`). Die Zählung ist allerdings nur eine rekursive Heuristik über Messages, System und Tools, keine Provider-Tokenizer-Abfrage (`packages/core/src/gateway/claude-code-router-plugin.ts:172-175,1421-1471`). | Kein eigener Endpoint; der Pfad wird wie jeder Request anhand des Body-Modells zum Upstream geroutet (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:529-575`). | **Gap mit Vorbehalt:** CCR garantiert eine lokale Antwort, WhisperM8 hängt vom jeweiligen Upstream ab. CCRs Ergebnis ist dafür nur geschätzt und nicht tokenidentisch garantiert. |
| SSE-Ereignisfolge | Für eingefügte Hosted-Web-Search-Blöcke erzeugt CCR explizit `content_block_start` → `content_block_delta` → `content_block_stop` (`packages/core/src/gateway/features/hosted-web-search/evidence.ts:182-213`). Generisch erkennt der Stream-Detector `message_stop`, `[DONE]`, Response-Endzustände und eingebettete Error-Events (`packages/core/src/observability/request-log-store.ts:296-304,4376-4455,4458-4505`). | Keine SSE-Syntaxprüfung. Jeder Upstream-Chunk wird in einen HTTP-Chunk gepackt; ein sauberer URLSession-Abschluss erzeugt den HTTP-Nullchunk, auch ohne belegtes `message_stop` (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:595-621`). | **Gap:** keine Erkennung fehlender Terminalevents und keine protokollsemantische Streamfehler-Diagnose. Das heißt nicht, dass WhisperM8 die Ereignisreihenfolge aktiv verfälscht; es validiert sie nur nicht. |
| Client-Abbruch | `response.close` und Schreibfehler aborten den Upstream-Fetch über `AbortController`; danach werden Bodies gecancelt, Pipes gelöst und alle beteiligten Streams zerstört (`packages/core/src/gateway/request/pipeline.ts:183-210,561-584,647-707`; `packages/core/src/gateway/upstream/executor.ts:926-947`). | `NWConnection.failed/cancelled` ruft `finish()` auf, das die URLSession-Task cancelt; ein später Upstream-Fehler nach versandtem Response-Head beendet den Socket absichtlich unvollständig (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:461-479,603-621,646-651`). | Beide brechen grundsätzlich ab. **CCR ist stärker explizit:** Disconnect wird als eigener Zustand/499 erfasst und durch die ganze Fetch-/Streamkette propagiert; WhisperM8 hat keine semantische Abschlussdiagnose. |
| Fehler / Retry | CCR klassifiziert 429, 408/409 und 5xx, respektiert `Retry-After`, nutzt gedeckeltes exponentielles Backoff und kann dasselbe Modell oder eine Modellkette versuchen (`packages/core/src/routing/failure-classifier.ts:10-30`; `packages/core/src/gateway/upstream/retry-policy.ts:5-23,41-52`; `packages/core/src/routing/execution-plan.ts:15-45`). Der Executor drainiert fehlgeschlagene Responses und protokolliert jeden Versuch (`packages/core/src/gateway/upstream/executor.ts:285-414,415-462`). | Vor dem Response-Head wird jeder Upstreamfehler zu 502; danach wird nur die Verbindung abgebrochen. Es gibt genau eine URLSession-Task und keinen Retry-/Fallbackpfad (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:568-575,603-621,689-765`). | **Klarer Gap:** keine Retry-Klassifikation, kein `Retry-After`, kein Backoff und kein Modell-/Credential-Fallback. |
| Router-/Modell-Mapping | CCR validiert Provider/Modell-Selektoren gegen eine Registry, verwirft mehrdeutige unqualifizierte Modelle und diagnostiziert ungültige Rules/Fallbacks (`packages/core/src/routing/model-registry.ts:13-67,73-112,130-155`; `packages/core/src/routing/config-compiler.ts:25-38,55-100,103-123`). Regeln können Body/Headers umschreiben; ein Custom Router und Built-in-Policies fließen in dieselbe Entscheidung (`packages/core/src/gateway/claude-code-router-plugin.ts:49-169`). | Statische Zweiteilung nach `model.hasPrefix("gpt-")`; kein Providername, keine Registry, keine Rule-Diagnostik und keine Fallbackliste (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`). | **Größter Funktions-Gap:** WhisperM8 kann nur „GPT oder Anthropic“, nicht mehrere Provider, virtuelle Modelle, Regeln oder Modellketten. |
| Prozess-/Port-Management | CCR schreibt PID plus zufällige Runtime-ID in einen Marker, prüft die Runtime-ID über `/health`, beendet nur den passenden Altprozess zuerst per SIGTERM und nach Frist per SIGKILL und erzwingt für den Core Loopback (`packages/core/src/gateway/core-runtime/supervisor.ts:335-371,375-439,453-470,480-504`). Der Service überwacht Child-Exit und hält einen expliziten `starting/running/error/stopped`-Status (`packages/core/src/gateway/application/gateway-service.ts:78-170,173-206,257-268`). | Ownership liegt nur in `selfStartedProcess` im Speicher; ein passendes konstantes `/healthz` genügt, um einen bestehenden Listener als Backend zu akzeptieren (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:157-159,218-283,469-537`). Stop sendet nur `terminate()`, ohne Frist/SIGKILL oder Neustart-Marker (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300,444-467,540-557`). | **Klarer Lifecycle-/Security-Gap:** keine crashüberlebende Ownership, keine starke Backend-Identität und keine Eskalation bei hängendem Child. |

## 4. Konkrete Lückenliste

### L1 — Modellrouting ist ein Präfix-Switch statt einer validierten Ausführungsplanung

**CCR:** `ModelRegistry` akzeptiert qualifizierte Provider/Modell-Selektoren, lehnt
Mehrdeutigkeit ab und bindet auf konfigurierte Modelle
(`packages/core/src/routing/model-registry.ts:22-67,73-112`). Die kompilierte
Routerkonfiguration deaktiviert fehlerhafte Rules und entfernt ungültige Fallbackmodelle
(`packages/core/src/routing/config-compiler.ts:25-38,55-100,103-123`). Retry und Modellkette
werden als begrenzte Versuchsfolge geplant (`packages/core/src/routing/execution-plan.ts:15-45`).

**WhisperM8:** Ein beliebiger String mit Präfix `gpt-` geht an genau einen Codex-Proxy; jeder
andere String geht an Anthropic (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`).
Die Upstream-URLs sind genau zwei feste Fälle
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:85-95`).

**Übertragbares Muster:** Keine komplette CCR-Policy-Engine kopieren. Für WhisperM8 genügt
zunächst eine kleine validierte Routingtabelle `clientModel -> backend/model/capabilities` mit
Startzeitdiagnostik und explizitem Default. Ein optionaler Fallback darf erst nach
idempotenz- und Tool-Use-sicheren Fehlerklassen greifen.

### L2 — Keine eigene Capability- und Token-Count-Schicht vor dem GPT-Backend

**CCR:** Der Modell-Discovery-Pfad veröffentlicht Bildinput, Thinking-Typen, Tool Use,
Kontextfenster und weitere Fähigkeiten aus dem Katalog
(`packages/core/src/gateway/features/model-discovery.ts:433-502`).
`/v1/messages/count_tokens` wird lokal garantiert
(`packages/core/src/gateway/http/request-handler.ts:156-168`), wenn auch nur heuristisch
(`packages/core/src/gateway/claude-code-router-plugin.ts:1421-1471`).

**WhisperM8:** Der Router kennt nur Modellname und Bodylänge
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284,529-575`). Er beantwortet
weder Modell-Capabilities noch Token Count selbst.

**Übertragbares Muster:** Capability-Metadaten für die tatsächlich angebotenen GPT-Modelle
explizit pflegen und gegen Backend-Fähigkeiten testen. Für Token Count ist ein sauberer
Upstream-Adapter oder ein bewusst als Schätzung markierter lokaler Endpoint besser als eine
stille pseudoexakte Zahl.

### L3 — Streamabschluss wird transportseitig, nicht protokollsemantisch bewertet

**CCR:** Ein inkrementeller SSE-Parser erkennt Terminal- und Fehlerereignisse über
Chunkgrenzen hinweg (`packages/core/src/observability/request-log-store.ts:4376-4455,4458-4505`).
Der Request-Pfad unterscheidet kompletten Stream, Clientabbruch, SSE-Fehler und Streamfehler
(`packages/core/src/gateway/request/pipeline.ts:621-707`;
`packages/core/src/gateway/internal/shared.ts:236-259`).

**WhisperM8:** `error == nil` in URLSession genügt für den abschließenden HTTP-Nullchunk;
der Inhalt wurde nicht auf `message_stop` oder eingebettete Error-Events geprüft
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-621,756-765`).

**Übertragbares Muster:** Den Proxy weiter transparent streamen lassen, aber parallel einen
kleinen bounded SSE-Monitor führen. Er soll keine Events neu schreiben, sondern nur
Terminalevent, eingebettete API-Fehler, unvollständigen UTF-8/JSON-Tail und Clientabbruch
klassifizieren und strukturiert loggen.

### L4 — Keine Retry-/Fallback-Policy für temporäre Providerfehler

**CCR:** 408/409, 429 und 5xx sind explizite Klassen
(`packages/core/src/routing/failure-classifier.ts:10-30`); `Retry-After` und exponentielles,
gedeckeltes Backoff werden berücksichtigt
(`packages/core/src/gateway/upstream/retry-policy.ts:5-23,41-52`). Netzwerkfehler und
HTTP-Fehler können zum nächsten geplanten Versuch wechseln
(`packages/core/src/gateway/upstream/executor.ts:352-462`).

**WhisperM8:** Ein Fehler vor dem Response-Head wird sofort 502, danach wird der Stream hart
abgebrochen (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-621`).

**Übertragbares Muster:** Zuerst nur Pre-Header-Retries für eindeutig temporäre Fehler und
nur solange noch kein Responsebyte an Claude Code ging. Nach `content_block_start`, Tool Use
oder irgendeinem Downstreambyte nie automatisch erneut ausführen; sonst drohen doppelte
Toolwirkungen und doppelte Kosten.

### L5 — Usage und Cachekosten sind unsichtbar

**CCR:** Streaming-Usage wird am Ende erfasst
(`packages/core/src/gateway/request/pipeline.ts:686-701`) und Anthropic-, OpenAI- sowie
Gemini-Felder einschließlich Cache-Read/-Write vereinheitlicht
(`packages/core/src/usage/store.ts:1104-1170`).

**WhisperM8:** Das einzige Routerlog enthält Modell, Upstream und Status
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:654-657`).

**Übertragbares Muster:** Usage passiv aus dem finalen Message-/SSE-Event lesen und mit
Session-ID, gewähltem Backendmodell, Latenz und Retryzahl korrelieren. Prompts und Toolinhalte
dürfen dafür nicht persistiert werden. Cache-Token müssen separat bleiben, weil Anthropic- und
OpenAI-`input_tokens` sie unterschiedlich bilanzieren können.

### L6 — Prozess-Ownership überlebt keinen App-Crash; Backend-Identität ist imitierbar

**CCR:** Der Marker bindet PID an eine zufällige Runtime-ID; beendet wird nur, wenn `/health`
dieselbe ID meldet (`packages/core/src/gateway/core-runtime/supervisor.ts:335-371,389-410,480-504`).
Der interne Core erhält zusätzlich einen zufälligen Auth-Token
(`packages/core/src/gateway/core-runtime/supervisor.ts:100-115`;
`packages/core/src/gateway/core-runtime/config-compiler.ts:90-101`). Das öffentliche Gateway
verlangt ebenfalls einen API-Key (`packages/core/src/gateway/auth/api-key-authorizer.ts:11-41`).

**WhisperM8:** Der eigene Prozesshandle existiert nur im RAM
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:155-159`). Als Identitätsnachweis
reicht die konstante, öffentlich imitierbare Antwort `{ "ok": true }`
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`), und der Mix-Router
akzeptiert jede Loopback-Verbindung ohne Credential
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`).

**Übertragbares Muster:** Pro Launch zufällige Runtime-ID und getrennte Client-Tokens für
Claude-Code→Mix-Router sowie Mix-Router→Backend; Marker atomar mit PID, Ports, Runtime-ID und
Startzeit persistieren. Nach Crash nur dann aufräumen, wenn Health-Challenge und erwartete
Prozessidentität übereinstimmen. Danach SIGTERM mit Frist und SIGKILL-Eskalation.

## 5. Was ausdrücklich **nicht** als Lücke bestätigt ist

1. **Blockweise Tool-Übersetzung:** Der CCR-Klon konfiguriert das externe Core-Gateway, enthält
   aber dessen generische Anthropic↔OpenAI-Transformatoren nicht. Dasselbe gilt bei WhisperM8
   für `claude-code-proxy`. Aus diesen beiden Wrappern allein lässt sich keine Feld-für-Feld-
   Überlegenheit bei `tool_use`, `tool_result`, Bildern oder Thinking beweisen.
2. **`cache_control`-Requestsemantik:** CCR normalisiert Cache-Usage, aber im lokalen Quellcode
   wurde keine generische `cache_control`-Transformation belegt. Kein bestätigter Request-
   Übersetzungs-Gap.
3. **Transport-Transparenz:** WhisperM8 verändert den JSON-/SSE-Inhalt nicht. Fehlende
   semantische Validierung ist ein Observability- und Fehlerklassifikations-Gap, nicht der
   Beleg, dass der Router reguläre SSE-Ereignisse falsch ordnet.
4. **Abbruch grundsätzlich:** WhisperM8 cancelt die URLSession-Task beim Verbindungsende
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:461-479,646-651`). Der Gap liegt in
   expliziter End-to-End-Propagation, Klassifikation und Diagnostik, nicht in völlig fehlendem
   Cancel.

## 6. Priorisierung für WhisperM8

1. **P0 – Ownership und lokale Authentisierung:** L6 behebt die bereits bestehende lokale
   Capability-Grenze und macht Crash-Recovery möglich.
2. **P0 – semantischer SSE-Monitor:** L3 verhindert „HTTP sauber, Anthropic-Stream
   unvollständig“ als stillen Erfolg und verbessert Abbruchdiagnosen ohne eine eigene Chat-UI
   oder einen eigenen Modellruntime zu bauen.
3. **P1 – validierte Routingtabelle plus Capability-Metadaten:** L1/L2 erlauben mehr als einen
   GPT-Backendtyp, ohne CCRs vollständige Policy-Plattform nachzubauen.
4. **P1 – sichere Pre-Header-Retries:** L4 nur mit striktem Verbot nach begonnenem Stream oder
   Toolwirkung.
5. **P2 – Usage/Cache-Telemetrie:** L5 als inhaltsfreie strukturierte Metrik, nicht als Traffic-
   Logging.

## 7. Fazit

Das wichtigste übertragbare Muster aus `claude-code-router` ist nicht ein einzelner
`tool_use`-Mapper. Es ist die **Trennung von öffentlichem Gateway, validierter Routingplanung,
protokollfähigem Core, Streamdiagnostik und langlebiger Prozess-Ownership**. WhisperM8s kleiner
Swift-Router ist für einen Host der echten Claude-CLI weiterhin eine sinnvolle Form: Er sollte
nicht zum zweiten Claude-Client oder zur kompletten Multi-Provider-Plattform anwachsen. Die
belegten Lücken liegen außen um die delegierte Übersetzung herum — Modell-/Capability-Vertrag,
Retrygrenzen, SSE-Abschlussdiagnostik, Usage und vor allem authentisierte, crashfeste
Prozess-Ownership.
