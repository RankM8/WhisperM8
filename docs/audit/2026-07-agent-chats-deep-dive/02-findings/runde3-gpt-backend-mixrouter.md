---
status: aktiv
updated: 2026-07-18
description: Runde-3-Audit des GPT-Mix-Routers, seiner Anthropic-/Codex-Protokollgrenzen, Streaming- und Fehlerpfade sowie der zugehörigen Tests.
---

# Runde 3: GPT-Backend — Mix-Router und Protokollübersetzung

## Prüfrahmen

Geprüft wurden der aktuelle Stand von `ClaudeGPTMixRouter`, seine Launch-/Proxy-Anbindung und die lokalen Tests. Die eigentliche Anthropic↔OpenAI-Übersetzung liegt **nicht** in WhisperM8, sondern im extern aufgelösten Binary `claude-code-proxy`: WhisperM8 wählt nur anhand des JSON-Felds `model` den Upstream und reicht Body/Response als Bytes weiter (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:529-600`). Deshalb wurde zusätzlich der Quellstand `raine/claude-code-proxy@v0.1.21` gelesen; dies entspricht der lokal aufgelösten Binary-Version. Builds und Tests wurden gemäß Auftrag nicht ausgeführt.

## Zusammenfassung

- kritisch: 0
- hoch: 3
- mittel: 4
- niedrig: 0

Das Kernziel „`/model`-Wechsel mid-session über beide Welten“ besitzt keine Providergrenze für Thinking-Signaturen (G01). Zwei weitere konkrete Übersetzungsverluste liegen im externen, zur Laufzeit nicht versionierten Proxy: Bilder in `tool_result` werden verworfen (G02), und der Tokenzähler kann lange Inhalte massiv unterschätzen (G03). Im Swift-Router fehlen außerdem differenzierte Transportfehler, ein expliziter Client-Disconnect-Pfad während der Upstream-Denkphase und globale Ressourcenlimits (G04–G06). Die vorhandenen Routertests prüfen im Wesentlichen Byte-Forwarding mit einem Mock, nicht den tatsächlich produktiven Übersetzungsvertrag (G07).

## G01: Providerwechsel transportiert inkompatible Thinking-Historie

**Schweregrad:** hoch

**Beleg:** Der Router entscheidet ausschließlich mit `model.hasPrefix("gpt-")`; alle anderen Modelle gehen zu Anthropic (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`). `forward` übernimmt den Request-Body danach unverändert als `URLRequest.httpBody` (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:529-575`). Der Codex-Proxy erzeugt für GPT-Reasoning proprietäre Signaturen mit dem Prefix `ccp:codex:v1:` (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/reasoning_signature.rs:4-48`). In Gegenrichtung akzeptiert seine Request-Übersetzung nur genau dieses Format; fremde, also auch Anthropic-Signaturen werden mitsamt dem Thinking-Block still übersprungen (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:752-763`, `raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/reasoning_signature.rs:50-72`). Die lokalen Tests prüfen nur zwei voneinander unabhängige Requests und keine gemeinsame Historie (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276`).

**Szenario:** Eine Fable-/Claude-Session erzeugt einen signierten Thinking-Block; der User wechselt per `/model` zu `gpt-5.6-sol`. Der Proxy lässt den fremd signierten Thinking-Block beim Aufbau der GPT-Historie vollständig fallen. Nach einem GPT-Turn und Wechsel zurück zu Fable leitet der Swift-Router dagegen die proprietäre `ccp:codex:v1:`-Signatur bytegleich an Anthropic weiter. Damit ist der beworbene Wechsel in beiden Richtungen semantisch asymmetrisch: GPT verliert Kontext; Anthropic erhält providerfremde Signaturen und kann den Turn bei strikter Signaturprüfung ablehnen.

**Fix-Skizze:** Providerwechsel als eigenen Übergang modellieren. Vor GPT-Aufrufen fremdes Thinking in eine explizite, unsignierte Kontextzusammenfassung überführen oder entfernen; vor Anthropic-Aufrufen alle `ccp:codex:*`-Thinking-Blöcke entfernen beziehungsweise durch erlaubte Textzusammenfassungen ersetzen. Golden-E2E-Tests müssen dieselbe Historie `Fable → GPT → Fable` einschließlich Thinking, Tool-Use und Resume durchspielen; ein bloßer Mock-Upstream reicht nicht.

## G02: Bilder in Tool-Ergebnissen werden absichtlich verworfen

**Schweregrad:** hoch

**Beleg:** Normale User-Bilder werden korrekt als `input_image` übersetzt (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:649-664`). `tool_result` wird dagegen in einen reinen String für `function_call_output` umgewandelt (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:665-692`). Dabei werden URL- und Base64-Bilder ausdrücklich nur als `[image omitted: ...]` ausgegeben; andere strukturierte Blöcke werden ebenfalls durch Platzhalter ersetzt (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:847-905`). `ClaudeGPTMixRouterTests` prüft weder die Übersetzung noch einen Request mit Bild- oder Tool-Blöcken, sondern nur unverändertes Forwarding (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276`).

**Szenario:** Ein GPT-Agent liest einen Screenshot oder ein Bild über ein Claude-Code-Tool. Das Tool liefert Text plus einen `image`-Block im `tool_result`. Beim nächsten Modellturn erhält GPT nur den Platzhalter, nicht die Pixel. Es kann deshalb visuelle Befunde nicht auswerten, wiederholt das Tool oder antwortet auf Basis fehlenden Inputs. Direkte Bilder des Users funktionieren, wodurch der Fehler irreführend nur bei Tool-Resultaten auftritt.

**Fix-Skizze:** Den Funktionsoutput weiterhin textuell quittieren, Bildblöcke aber zusätzlich als unmittelbar folgende User-Message mit `input_image` an die Responses-API übergeben und die Zuordnung zum Tool-Call erhalten. URL-, Base64-, gemischte Text/Bild- und mehrere Bildblöcke als Golden-Fälle testen. Bis zur Unterstützung muss die UI/Agent-Definition den Verlust sichtbar melden statt nur einen modellinternen Platzhalter zu erzeugen.

## G03: `/count_tokens` kann lange Inhalte um Größenordnungen unterschätzen

**Schweregrad:** hoch

**Beleg:** GPT-Requests einschließlich `/v1/messages/count_tokens` werden allein über das Modellpräfix zum Codex-Proxy geroutet (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`). Dessen Zähler bezeichnet sich als Approximation und summiert Inputs, Tools und festen Overhead (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:5-33`). Der Textzähler zählt jedoch einen beliebig langen zusammenhängenden alphanumerischen/`-_`-Lauf als **ein** Token (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:97-118`); jedes Bild zählt pauschal 2.000 Tokens (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:69-74`). Der lokale Parser-Test deckt nur einen bodylosen Request-Head ab, nicht die Tokenantwort oder Kompaktionsgrenzen (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:148-154`).

**Szenario:** Ein Tool-Ergebnis enthält 100.000 Zeichen in einem langen Identifier, Hash-/Datenfeld oder minifizierten Payload. Der Schätzer kann diesen Lauf als ein Token zählen. Claude Code verlässt sich für seine Kompaktionslogik auf `/count_tokens`; die Kompaktierung startet dadurch zu spät, und der echte GPT-Aufruf endet erst am Provider mit Context-Window-/413-Fehler. Bei Bildern kann der fixe Wert je nach Auflösung ebenfalls deutlich danebenliegen.

**Fix-Skizze:** Wenn kein echter Provider-Tokenizer verfügbar ist, einen konservativen UTF-8-/Zeichen-Fallback verwenden, etwa `max(lexikalische Schätzung, ceil(bytes / konservativer Faktor))`, und Bildkosten aus Dimension/Detailstufe ableiten. Regressionstests brauchen lange ungetrennte ASCII-/Unicode-Folgen, Base64, große Tool-Schemas, mehrere Bilder und eine End-to-End-Kompaktionsschwelle.

## G04: Transportfehler werden nach bis zu zehn Minuten zu generischem Plaintext-502

**Schweregrad:** mittel

**Beleg:** Jeder Upstream-Request und jede Ressource hat ein Timeout von 600 Sekunden (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:555-575`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:709-729`). Kommt vor dem Response-Head irgendein Fehler, ignoriert `completeUpstream` dessen Typ und sendet immer `502 Bad Gateway` (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-609`). Diese lokale Fehlerantwort ist `text/plain`, nicht das Anthropic-JSON-Fehlerformat (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:624-633`). Nur bereits erhaltene HTTP-Status wie 429/5xx samt Headern werden korrekt durchgereicht (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-592`). Die Tests verwenden ausschließlich sofortige 201-/202-Antworten beziehungsweise gzip und prüfen weder 429/5xx noch Connect-/Header-Timeouts oder späte Streamfehler (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-353`).

**Szenario:** Anthropic hängt vor den Headern, oder der lokale Codex-Proxy stirbt zwischen erfolgreicher Health-Probe und Request. Der Chat kann bis zu zehn Minuten ohne verwertbare Diagnose warten und erhält anschließend in beiden Fällen denselben Plaintext-502. Claude Code kann Timeout, lokalen Prozessausfall und echten Gatewayfehler nicht unterscheiden; strukturierte Fehlermeldung und Retry-Entscheidung gehen verloren.

**Fix-Skizze:** Connect-/Header-/Body-Idle-Timeout separat und deutlich kürzer konfigurieren. `URLError.timedOut` auf 504, Verbindungsablehnung/-reset auf 502 und Client-Abbruch ohne Antwort abbilden; lokale Fehler immer als Anthropic-kompatibles JSON mit stabiler Fehlerart und Request-ID senden. HTTP-429/529/5xx, `Retry-After`, Pre-Header-Timeout, Late-Stream-Reset und halben SSE-Chunk gezielt testen.

## G05: Client-Disconnect wird während der Denkphase nicht aktiv gelesen

**Schweregrad:** mittel

**Beleg:** Nach vollständigem Request startet `consumeBuffer` den Upstream (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:529-575`). Im anschließend zurückkehrenden Receive-Callback beendet `upstreamTask != nil` die Receive-Schleife; es wird kein weiterer Read auf dem Client-Socket armiert (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:481-499`). Abbruch erfolgt danach nur über einen `.failed`/`.cancelled`-State oder über einen Fehler beim späteren `send` (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:461-478`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:636-652`). Ein Test, der den Client nach dem Request schließt und die Upstream-Cancellation beobachtet, fehlt; der einzige Half-Close-Test betrifft einen bereits lokal abgelehnten kaputten Request (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:297-321`).

**Szenario:** Der User schließt den Tab beziehungsweise beendet Claude Code direkt nach dem vollständigen GPT-Request, während der Upstream noch denkt und noch keine Bytes zurückliefert. Da kein Client-Receive mehr offen ist, besitzt der Router in dieser Phase keinen expliziten EOF-Pfad. Bis ein Zustands-/Sendefehler sichtbar wird oder der 600-Sekunden-Timeout greift, kann der Codex-Upstream weiterrechnen und Kontingent verbrauchen; Cancellation ist damit vom nächsten Downstream-Write abhängig statt vom Disconnect.

**Fix-Skizze:** Nach dem Forward einen separaten EOF-/Disconnect-Receive offenhalten und bei EOF sofort `StreamingUpstreamTask.cancel()` auslösen; zusätzliche Requestbytes wegen der „ein Request pro Verbindung“-Policy ablehnen. Im Test einen Upstream mit verzögertem Header verwenden, den Client sofort schließen und über einen Spy nachweisen, dass die Upstream-Task zeitnah abgebrochen wird. Parallel dazu Late-Data-vs.-Cancel-Reihenfolge testen.

## G06: Unbegrenzte Parallelität multipliziert 64-MiB-Bodypuffer und URLSessions

**Schweregrad:** mittel

**Beleg:** Der Router erlaubt pro Request bis zu 64 MiB Body (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:73-74`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:513-519`). Jede Verbindung hält den gesamten Body in `buffer`, erzeugt daraus den Forward-Body und bleibt bis Upstream-Ende in der unbegrenzten `connections`-Map (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:79-83`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:434-450`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:487-531`). Zusätzlich baut jeder Request eine eigene ephemere `URLSession` plus serielle `OperationQueue` (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:689-729`). Der einzige konfigurierte Tool-Concurrency-Wert gilt nur als Environment-Tuning für GPT-gestempelte Hauptsessions; er ist kein globales Routerlimit (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:286-294`). Die Integrationstests senden die beiden Upstreams nacheinander, nicht parallel (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:241-259`).

**Szenario:** Mehrere PTYs/Subagents senden gleichzeitig große Kontexte mit Bildern. Acht Requests nahe dem erlaubten Maximum halten bereits rund 512 MiB reine Eingabedaten, ohne URLSession-/JSON-/Upstream-Overhead; weitere Loopback-Verbindungen werden ohne Backpressure angenommen. Unter macOS-Memory-Pressure kann WhisperM8 dadurch als Host beendet werden, obwohl jede Einzelanfrage formal gültig ist.

**Fix-Skizze:** Globales Limit für aktive Requests und gepufferte Bytes einführen, bei Überschreitung 429/503 mit `Retry-After` liefern und pro Session Fairness vorsehen. Bodylimit auf den real benötigten Claude-Code-Vertrag reduzieren oder Uploads streamen; eine wiederverwendete URLSession statt einer Session pro Request verwenden. Paralleltests müssen Limit, Backpressure, Cancellation und Freigabe des Bytebudgets prüfen.

## G07: Produktiver Übersetzungsvertrag ist weder versioniert noch lokal getestet

**Schweregrad:** mittel

**Beleg:** Bei nicht erreichbarem Backend wird irgendein über PATH aufgelöstes `claude-code-proxy` gestartet; Argumente und Port sind fest, aber es gibt keinen `--version`-/Capability-Check (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-269`). Eine bereits laufende externe Instanz gilt allein dann als passend, wenn `/healthz` Status 200, JSON-Content-Type und `{ "ok": true }` liefert (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`). Danach startet WhisperM8 den Router unabhängig von Übersetzer-Version oder unterstützten Modellen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:272-283`). Die lokalen Routertests verwenden einen simplen `LocalHTTPMockServer`, der nur Status/Chunks sendet und keine Anthropic↔Responses-Übersetzung ausführt (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276`, `Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:463-615`).

**Szenario:** Im PATH liegt eine ältere oder zukünftige inkompatible Proxy-Version, oder auf dem konfigurierten Port läuft ein anderer Dienst mit derselben trivialen Health-Antwort. `ensureRunning` meldet Erfolg; erst reale Requests brechen bei Thinking, Tool-Result-Bildern, SSE-Ereignissen, Modellnamen oder Tokenzählung. Ein Dependency-Update kann so den Kernpfad verändern, ohne dass die WhisperM8-Suite rot wird.

**Fix-Skizze:** Unterstützten Semver-Bereich beziehungsweise Capability-Protokoll festlegen und vor Routerfreigabe prüfen; die Health-Antwort muss Produkt, Version und relevante Fähigkeiten tragen. Mindestens eine hermetische Contract-Suite gegen die unterstützte Proxy-Binary ausführen: Messages/System, Tool-Use/Result, Bilder, Thinking/Cache-Control, Count-Tokens, Usage/Stop-Reasons, 429/5xx/Timeouts, halbe SSE-Frames, Disconnect und parallele Streams. Bei unbekannter Version fail-closed mit klarer Settings-Diagnose statt erst im Chat.

## Positiv geprüft / kein Finding

- Anthropic-Credentials bleiben beim echten Anthropic-Upstream erhalten, werden beim lokalen Codex-Proxy aber case-insensitiv zusammen mit allen `anthropic-*`-Headern entfernt (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:310-339`, `Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:25-53`, `Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:96-119`).
- Hop-by-Hop- sowie dynamisch in `Connection` genannte Header werden entfernt; transparent dekodiertes gzip wird ohne falschen `Content-Encoding` weitergereicht (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:286-307`, `Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:55-93`, `Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:323-353`).
- Listenergeneration und Lifecycle-Queue verhindern, dass ein später Callback eines ersetzten Starts den aktuellen Listener stoppt (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:117-228`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:238-266`).
- Die Fallback-Modellkorrektur aus Commit `11f2ebe` wertet den aufgelösten App-Default als Defaultargument außerhalb der Store-Mutation aus; echte Job-/Codex-Config-Werte gewinnen weiterhin (`WhisperM8/Services/AgentChats/AgentSessionStore.swift:911-916`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:950-951`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1020-1024`). Der historische `gpt-5.5`-Fall wird explizit injiziert statt wieder als Produktdefault einzufrieren (`Tests/WhisperM8Tests/AgentJobWorkspaceSyncTests.swift:221-232`). Hier wurde kein zusätzlicher Fehler gefunden.

## Priorität

1. **Sofort:** G01 als Kernziel-Blocker klären und Providerwechsel mit echter History testen.
2. **Kurzfristig:** G02 und G03 im unterstützten Proxy beheben beziehungsweise eine bekannte gefixte Mindestversion erzwingen.
3. **Danach:** G05 Cancellation und G04 strukturierte Timeout-/Fehlersemantik implementieren.
4. **Härtung:** G06 Ressourcenbudget und G07 versionierten Contract in CI etablieren.
