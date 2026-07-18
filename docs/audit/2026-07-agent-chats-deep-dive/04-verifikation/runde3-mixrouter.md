---
status: abgeschlossen
updated: 2026-07-18
description: Adversariale Vollverifikation aller sieben Runde-3-Findings zum GPT-Mix-Router gegen Router-, Proxy-, Launch-, Übersetzungs- und Testcode einschließlich Task-Kontext, Ressourcen-Lifecycle, Guards und bewusster Designentscheidungen.
---

# Runde 3: Verifikation GPT-Mix-Router und Protokollübersetzung

## Auftrag, Methode und Bewertungsmaßstab

Geprüft wurden **alle sieben** Findings aus
`02-findings/runde3-gpt-backend-mixrouter.md` gegen den aktuellen Code auf `main`.
Dazu wurden der vollständige Router, sein realer Launch-Aufrufer, Proxy-Manager und
Command-Builder, alle lokalen Router-/Manager-Tests, die CI sowie die betroffenen
Übersetzungsdateien von `raine/claude-code-proxy@v0.1.21` gelesen. Die lokal über
`PATH` aufgelöste Binary meldete bei der nicht mutierenden Versionsabfrage
`claude-code-proxy 0.1.21`; der gelesene Tag entspricht damit dem gegenwärtigen
Laufzeitstand. Es wurden keine Builds oder Tests ausgeführt und kein Produktcode
geändert.

Urteile:

- **BESTAETIGT:** Der behauptete Defekt beziehungsweise die behauptete Vertragslücke ist aus dem aktuellen Code ableitbar; vorhandene Guards schließen sie nicht.
- **WIDERLEGT:** Ein Guard, Aufrufervertrag oder Implementierungsdetail verhindert das behauptete Szenario.
- **UNKLAR:** Der gelesene Code reicht nicht aus, um Auslösung oder Verhinderung belastbar zu entscheiden.

**Gesamturteil:** Alle sieben Findings sind im technischen Kern **BESTAETIGT**.
G01 hat einen E2E-Teilvorbehalt: Ob die aktuell installierte Claude-CLI beim konkreten
`/model`-Wechsel jeden älteren Thinking-Block erneut sendet, ist weder im Repository
noch durch eine gespeicherte Golden-Fixture belegt. Die GPT-Richtung ist dennoch
unabhängig davon als echter Übersetzungsverlust bestätigt, sobald eine solche Historie
im Request steht. G02 wird gegenüber dem Ausgangsdokument auf **mittel** abgestuft:
Der Verlust ist absichtlich, auf Tool-Ergebnisse begrenzt und für das Modell durch einen
Platzhalter erkennbar; direkte User-Bilder funktionieren. G07 ist heute ein
ungegatetes Abhängigkeitsrisiko, kein Nachweis, dass die aktuell installierte Version
bereits inkompatibel ist.

## G01 — Providerwechsel transportiert inkompatible Thinking-Historie

**Urteil:** **BESTAETIGT**, mit E2E-Teilvorbehalt  
**Eigener Schweregrad:** **hoch**

### Exakte Ausführung

1. Der Router wird bewusst auf **jede** normale Claude-PTY-Session gelegt, damit
   `/model` später zwischen Claude und GPT wechseln kann. Dafür setzt der Builder
   `ANTHROPIC_BASE_URL` auf den In-Process-Router und registriert die GPT-Option im
   Picker (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:259-285`).
2. Pro API-Aufruf entscheidet der Router nur anhand von
   `model.hasPrefix("gpt-")`; ein GPT-Modell geht an den Codex-Proxy, alles andere an
   Anthropic (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`).
   Die vollständige Body-`Data` wird danach unverändert in `request.httpBody`
   übernommen (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:529-575`).
3. Der Proxy normalisiert Thinking-Blöcke einschließlich sichtbarem `thinking` und
   optionaler `signature` (`raine/claude-code-proxy@v0.1.21/src/providers/translate_shared.rs:200-213`).
   Im Codex-Input wird ein solcher Block aber nur dann übernommen, wenn
   `decode_reasoning_signature` Erfolg liefert; andernfalls folgt sofort `continue`,
   wodurch **der komplette Thinking-Block einschließlich seiner sichtbaren
   Zusammenfassung** entfällt (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:752-763`).
4. Der Decoder akzeptiert ausschließlich `ccp:codex:v1:` und gibt bei jedem fremden
   Prefix `nil` zurück (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/reasoning_signature.rs:4-5,50-72`).
   Ein Proxy-Test fixiert das Verhalten für eine fremde Anthropic-Signatur sogar
   ausdrücklich als „ignored“ (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/reasoning_signature.rs:104-108`).
5. In Gegenrichtung verpackt der Proxy Codex-Reasoning-ID plus verschlüsselten Inhalt
   in genau dieses proprietäre Prefix (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/reasoning_signature.rs:38-48`).
   Der Live-Übersetzer emittiert es als Anthropic-`signature_delta`, auch wenn keine
   sichtbare Thinking-Zusammenfassung existiert
   (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/live_stream.rs:937-975`),
   beziehungsweise beim Schließen eines sichtbaren Thinking-Blocks
   (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/live_stream.rs:987-1006`).
   WhisperM8 streamt diese Responsebytes ohne semantische Inspektion an die CLI
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`).

Damit ist die Providergrenze real asymmetrisch: Ein Anthropic-Thinking-Block in einer
an GPT gerichteten Historie wird sicher entfernt; ein GPT-Turn erzeugt umgekehrt einen
Anthropic-förmigen Block mit providerfremder Signatur. Der Router hat vor keiner
Richtung eine History-Normalisierung oder Signatur-Guard.

### Widerlegungsversuche und Teilvorbehalt

- **„Der sichtbare Thinking-Text bleibt als Assistant-Text erhalten.“ — widerlegt.**
  Der Match-Zweig ignoriert das Feld `thinking` vollständig und springt bei fremder
  Signatur über den ganzen Block (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:752-763`). Normale Assistant-`text`-Blöcke bleiben zwar erhalten
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:733-768`),
  sie ersetzen aber nicht den verlorenen Thinking-Block.
- **„Der Router korrigiert die Historie beim Modellwechsel.“ — widerlegt.**
  Er liest nur das Top-Level-Modell und weist denselben Body einem der beiden Upstreams
  zu (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284,529-575`).
- **„Der Wechsel ist bereits E2E testgesichert.“ — widerlegt.** Der einzige lokale
  Zwei-Upstream-Test sendet zuerst einen GPT-Request mit leerer History und danach einen
  davon unabhängigen Claude-Request mit ebenfalls leerer History
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276`). Die manuelle QA für
  `/model` hin und zurück ist weiterhin offen
  (`docs/plans/claudex-gpt-backend/QA-CHECKLISTE.md:56-60`).
- **Nicht vollständig belegbar:** Die Claude-CLI ist keine Quelle dieses Repositories.
  Deshalb ist nicht aus lokalem Code beweisbar, welche Thinking-Blöcke ihre konkrete
  Version beim `/model`-Wechsel erneut in den nächsten Request aufnimmt. Ebenso wurde
  keine echte Anthropic-Ablehnung einer `ccp:codex:*`-Signatur beobachtet. Diese zwei
  offenen Glieder schwächen die behauptete Rückrichtung, widerlegen aber nicht den
  eigenständig bestätigten Verlust in Richtung GPT.

### Schweregradbegründung

**Hoch**, weil die absichtlich beworbene Kernfunktion „`/model` mid-session“ genau diese
Providergrenze öffnet (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:267-285`)
und der GPT-seitige Kontextverlust deterministisch ist, sobald die History einen fremd
signierten Thinking-Block enthält. Ein bloßer Router-Mock kann diesen Vertrag nicht
abdecken (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276`).

## G02 — Bilder in Tool-Ergebnissen werden absichtlich verworfen

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **mittel** (Ausgangsdokument: hoch)

### Exakte Ausführung

- Direkte Bildblöcke einer User-Message werden korrekt zu `InputImage` und behalten
  URL beziehungsweise Base64-Daten
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:649-664`,
  `raine/claude-code-proxy@v0.1.21/src/providers/translate_shared.rs:96-101`).
- Bei `tool_result` wird dagegen zuerst eine gegebenenfalls angefangene User-Message
  geflusht, dann der gesamte Tool-Inhalt mit `tool_result_to_string` in einen einzigen
  String für `FunctionCallOutput` umgewandelt
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:665-692`).
- In dieser Stringfunktion werden gültige URL-Bilder zu
  `[image omitted: url]`, gültige Base64-Bilder zu
  `[image omitted: <media-type>]` und sonstige strukturierte Blöcke zu
  `[unsupported content block omitted: ...]`
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:847-905`).
- Das ist kein unbeabsichtigter Randfall: Ein Upstream-Test schreibt genau diese
  Platzhalterausgabe als Sollverhalten fest
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:1522-1535`).

Ein Tool, das Text plus Screenshot/Bild zurückliefert, gibt GPT somit nur Text plus
Omissionsmarker. Pixel werden nicht in einen anschließenden `InputImage`-Block überführt.
WhisperM8 kann dies nicht auffangen, weil sein Router den Body nur bytegleich weitergibt
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:529-575`).

### Gegenbelege und Reichweitengrenzen

- **Direkte User-Bilder funktionieren.** Das begrenzt den Defekt ausdrücklich auf
  Bilder innerhalb von `tool_result`
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:649-664`).
- **Der Verlust ist für das Modell nicht vollkommen still.** Der Platzhalter benennt,
  dass ein Bild ausgelassen wurde
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:858-881`).
  Das Modell erhält aber weder die Pixel noch eine Möglichkeit, sie aus dem Marker
  wiederherzustellen.
- **Bewusste Designentscheidung:** Der Projektplan dokumentiert
  „Bilder in Tool-Results teils `[image omitted]`“ bereits als Risiko
  (`docs/plans/claudex-gpt-backend/PLAN.md:128-134`). Akzeptanz macht den Verlust
  transparent, beseitigt aber nicht seine Produktwirkung.
- Die WhisperM8-Routertests enthalten weder Tool- noch Bildblöcke; der produktive
  Übersetzer wird durch einen Status-/Chunk-Mock ersetzt
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276,463-615`).

### Schweregradbegründung

**Mittel** statt hoch: Text-, Tool-Call- und direkte User-Bild-Pfade bleiben nutzbar,
der Marker macht den Verlust modellseitig erkennbar, und die Grenze ist dokumentiert.
Für screenshot- oder bildbasierte Tool-Workflows ist der Ausfall dennoch vollständig;
kein lokaler Guard verhindert Wiederholungen oder falsche Schlüsse auf unvollständigem
Input.

## G03 — `/count_tokens` kann lange Inhalte massiv unterschätzen

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **hoch**

### Exakte Ausführung

1. Das Routing berücksichtigt nur das Modell im Body, nicht den Pfad. Damit geht auch
   `/v1/messages/count_tokens` bei `gpt-*` an den Codex-Proxy
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284,534-575`).
2. Der Proxy übersetzt den vollständigen Messages-Request und gibt anschließend das
   Ergebnis von `count_translated_tokens` als `input_tokens` zurück
   (`raine/claude-code-proxy@v0.1.21/src/providers/codex/mod.rs:239-286`).
3. Der Zähler summiert zwar Instructions, Input-Items, Tool-Schemas, Modellname und
   feste Item-Overheads (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:5-33,36-94`). Sein Textprimitive erhöht den Zähler aber innerhalb eines
   zusammenhängenden Laufs aus alphanumerischen Zeichen, `-` und `_` nur beim ersten
   Zeichen. Die Länge des Laufs spielt danach keine Rolle
   (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:97-118`).
4. Ein 100.000 Zeichen langer URL-safe-Base64-/Identifier-Lauf zählt daher im
   **Textanteil** als ein Token. Der gesamte Request zählt wegen Modell-, Message- und
   Tool-Overhead mehr als eins; dieser Gegenbeleg ändert die Größenordnung der
   Unterschätzung nicht (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:16-33`).
5. Jedes Input-Bild erhält unabhängig von Dimension, Detailstufe oder Datenmenge
   pauschal 2.000 Tokens
   (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:69-74`).

Die Quelle bezeichnet den Zähler selbst als Approximation für Claude Codes
Kompaktionslogik (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:5-8`).
Damit trifft eine massive Unterschätzung genau den Schutzmechanismus, der rechtzeitig
kompaktieren soll. Ob **ein einzelner** 100.000-Zeichen-Lauf schon das Kontextfenster
sprengt, hängt vom restlichen Kontext ab; nahe der Grenze kann er die gemeldete
Schwelle jedoch deterministisch um viele Tausend echte Tokens verschieben.

### Widerlegungsversuche

- **„Monotonie-Test verhindert die Unterschätzung.“ — widerlegt.** Der Test verlangt
  nur `long >= short` und verwendet einen normal durch Leerzeichen getrennten Satz
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:157-177`).
  Gleichstand für beliebig längere Einzelruns besteht diese Assertion.
- **„Reasoning hat einen Byte-Fallback.“ — nur Teilgegenbeleg.** Verschlüsseltes
  Reasoning wird separat aus Base64-Länge geschätzt
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:53-67,180-185`).
  Normale Texte, Funktionsargumente/-outputs und serialisierte Tool-Schemas gehen
  weiterhin durch den run-basierten Zähler
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:36-55,77-88`).
- Der lokale WhisperM8-Test zu `count_tokens` prüft nur, dass ein GET-Head ohne
  `Content-Length` als Länge null geparst wird; er prüft weder Routingantwort noch
  Zählwert oder Kompaktionsschwelle
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:148-154`).
- Das Router-Bodylimit von 64 MiB verhindert keinen modellseitig viel kleineren
  Kontextgrenzenfehler (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:73-74,513-519`).

### Schweregradbegründung

**Hoch**, weil `/count_tokens` kein dekoratives Telemetrie-Feld, sondern laut
Proxyquelle Eingang der Kompaktionslogik ist
(`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:5-8`).
Lange minifizierte, Base64- oder identifierartige Tool-Ausgaben sind im Agentbetrieb
erreichbar; die falsche Sicherheitsreserve wird erst am echten Provider als zu großer
Kontext sichtbar.

## G04 — Transportfehler werden zu generischem Plaintext-502

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **mittel**

### Exakte Ausführung

- Jeder Forward baut einen `URLRequest` mit 600 Sekunden Timeout
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:548-575`).
  Die pro Request erzeugte ephemere `URLSession` setzt sowohl Request- als auch
  Resource-Timeout ebenfalls auf 600 Sekunden
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:709-729`).
- `completeUpstream(error:)` inspiziert vor dem Response-Head weder `URLError`-Code
  noch Fehlerdomäne. Unabhängig von Timeout, Connection Refused, Reset oder lokalem
  Proxy-Exit loggt und sendet es 502
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-609`).
- `sendSimpleResponse` erzeugt stets `text/plain` mit lediglich
  `<status> <reason>`, nicht den vom Anthropic-Protokoll erwarteten JSON-Fehlerkörper
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:624-633`).
- Ein echter Upstream-HTTP-Status ist ein anderer Pfad: Sobald ein
  `HTTPURLResponse` existiert, werden Status und zulässige Header durchgereicht
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-592`). 429/5xx gehen
  deshalb nicht pauschal in den lokalen 502 über; nur **Transportfehler vor dem Head**
  verlieren ihre Identität.
- Nach bereits gesendetem Head wird korrekt kein zweiter HTTP-Status erfunden: Erfolg
  endet mit 0-Chunk, ein später Fehler mit Verbindungsabbruch
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:612-621`). Das ist ein
  sinnvoller Guard, behebt aber den Pre-Head-Pfad nicht.

### Tatsächlicher Aufrufer- und Task-Kontext

Der Health-Check läuft vor dem PTY-Start in einem `Task.detached`, und sein Erfolg wird
später auf dem MainActor in die Builder-Entscheidung eingefroren
(`WhisperM8/Views/AgentSessionDetailView.swift:387-450,455-482`). Ein Proxy kann nach
der Probe und vor oder während eines Requests sterben; im Requestpfad gibt es keine
erneute Health-Prüfung. Die Router-/URLSession-Callbacks laufen zwar geordnet auf der
seriellen Client-Queue (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:438-449,689-729`), diese Ordnung klassifiziert den Fehler aber nicht.

### Gegenbelege und Tests

- Die kurze Health-Probe besitzt eigene 0,4-/0,5-Sekunden-Fristen
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:472-515`). Sie schützt
  nur den Launchzeitpunkt, nicht den späteren Upstream-Request.
- Die lokalen Routertests verwenden nur sofortige 201-/202-Antworten oder eine
  vorbereitete gzip-200-Antwort
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276,323-353`). Es gibt keinen
  verzögerten Head, Connect-Fehler, Timeout, 429/529 oder späten Stream-Reset.

### Schweregradbegründung

**Mittel**: Der Fehler ist sichtbar und terminiert schließlich; erfolgreiche HTTP-
Fehlerantworten bleiben differenziert. Diagnose, Retry-Entscheidung und Wartezeit sind
bei Pre-Head-Transportfehlern dennoch unnötig schlecht, im Worst Case bis zur
konfigurierten 600-Sekunden-Grenze.

## G05 — Client-Disconnect wird während der Upstream-Denkphase nicht aktiv gelesen

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **mittel**

### Exakte Ausführung und Queue-Reihenfolge

1. `ClientConnection.start` installiert auf seiner seriellen Queue nur einen
   State-Handler für `.failed` und `.cancelled`, startet den Socket und armiert den
   ersten Receive (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:434-469`).
2. Sobald genug Body vorhanden ist, setzt `forward` synchron `upstreamTask` und startet
   die URLSession-Task (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:529-575`).
3. Danach kehrt der aktuelle Receive-Callback zurück. Sein Guard verlangt für einen
   weiteren `receiveMore` ausdrücklich `upstreamTask == nil`; mit laufendem Upstream
   wird kein weiterer Client-Read armiert
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:481-499`).
4. Ein EOF beziehungsweise `isComplete` kann in dieser Phase deshalb nicht über einen
   Receive-Callback erkannt werden. Es bleiben nur `.failed`/`.cancelled` im
   State-Handler oder ein Fehler beim späteren Downstream-`send`
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:461-478,636-652`).
5. Die URLSession- und NWConnection-Callbacks sind absichtlich über dieselbe Queue
   streng geordnet (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:709-724`).
   Das verhindert Datenraces, erzeugt aber keinen fehlenden EOF-Read.

Ein Client, der nach vollständigem Request während eines verzögerten Upstream-Heads
geordnet schließt, kann daher nicht über den expliziten Receive-Pfad die
`StreamingUpstreamTask.cancel()`-Kette auslösen. Erst ein späterer Response-Send, ein
anderer Socketfehler, Router-Stop oder der Upstream-Timeout beendet die Arbeit.
`finish()` würde den Upstream korrekt abbrechen, **wenn** es erreicht wird
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:646-652`).

### Widerlegungsversuche

- **„Der State-Handler erkennt jeden Peer-FIN.“ — im Code nicht belegt.** Er reagiert
  ausschließlich auf `.failed` und `.cancelled`; einen expliziten EOF-Pfad besitzt nur
  der Receive-Callback über `isComplete`
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:461-499`). Genau dieser Read
  wird nach Forward nicht mehr armiert.
- **„`Connection: close` schließt den Client sofort.“ — widerlegt.** Der Router setzt
  den Header erst in seiner Response und schließt nach deren Ende
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-590,616-621`). Während
  der Denkphase existiert noch keine Response.
- Der vorhandene Half-Close-Test betrifft einen bereits lokal abgelehnten kaputten
  Request und erreicht nie einen Upstream
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:297-321`). Ein Test mit
  verzögertem Upstream-Head und Cancellation-Spy fehlt in der vollständigen Testliste
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-353`).

### Schweregradbegründung

**Mittel**: Der Defekt benötigt den engen Zeitpunkt „Request vollständig, noch keine
Upstream-Bytes“ und ist bei kurzer Modelllatenz zeitlich begrenzt. Bei langer
Reasoning-Phase oder hängendem Upstream kann er jedoch bis zur 600-Sekunden-Frist
Rechenzeit/Kontingent binden
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:555,709-714`).

## G06 — Unbegrenzte Parallelität multipliziert große Bodypuffer und URLSessions

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **mittel**

### Exakte Ausführung und Lock-Grenzen

- Der Listener akzeptiert jede neue Verbindung, erzeugt eine UUID und legt den
  `ClientConnection` ohne Zähler, Semaphore oder Bytebudget in `connections` ab
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`).
  `lifecycleQueue` serialisiert nur Listener-/Map-Mutationen; jede angenommene
  Verbindung läuft danach auf einer eigenen seriellen Queue
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:76-83,403-430,434-449`).
- Pro Request werden bis zu 64 MiB Content-Length akzeptiert
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:73-74,502-519`). Der Body
  bleibt vollständig im `buffer`; aus dessen Prefix wird zusätzlich eine `Data` für
  `request.httpBody` erzeugt. `buffer` wird nach `forward` nicht geleert
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:487-531,548-575`).
- Die Verbindung bleibt bis `finish()` in der globalen Map und wird erst danach
  asynchron entfernt
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:413-429,646-652`).
- Jeder Request erzeugt eine eigene ephemere `URLSession`, eine eigene serielle
  `OperationQueue` und einen eigenen DataTask
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:689-729`). Es gibt keine
  wiederverwendete Session und keine globale Taskgrenze.

Acht gleichzeitig akzeptierte Requests mit jeweils knapp 64 MiB halten damit bereits
ungefähr 512 MiB allein in den Client-`buffer`-Feldern; die Body-`Data`, URLSession,
JSON-/TLS-/Response- und Prozesskosten kommen hinzu. Die Rechnung ist konservativ und
setzt nicht voraus, dass jede Zwischen-`Data` physisch sofort kopiert wird.

### Gegenbelege und Reichweitengrenzen

- Der Router bindet nur auf `127.0.0.1`
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:127-134`). Das reduziert
  entfernte DoS-Reichweite, nicht normale Parallelität mehrerer lokaler PTYs und
  nativer Agent-Aufrufe.
- `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3` ist kein Routerbudget. Der Builder setzt es
  nur, wenn `includesGPTTuning` wahr ist
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:286-294`), und ruft diesen
  Modus für normale Chats nur bei bereits GPT-gestempeltem Startmodell auf
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:410-413`). Mehrere PTYs
  teilen weder diesen Wert noch einen gemeinsamen Routerzähler; per `/model` erst
  später auf GPT gewechselte Claude-Starts erhalten das Tuning ebenfalls nicht.
- Das 64-MiB-Limit begrenzt nur **einen** Request; es gibt keine Summe über
  `connections` (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:73-83,513-519`).
- Der Integrationstest schickt GPT und Claude seriell nacheinander
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:241-259`). Parallelannahme,
  Backpressure, Bytebudget und Freigabe nach Cancellation werden nicht geprüft.

### Schweregradbegründung

**Mittel**: Die Auslösung erfordert mehrere sehr große lokale Requests, ist also kein
alltäglicher Ein-Request-Fehler. Sie kann aber die gesamte macOS-Host-App unter
Memory-Pressure treffen; das Einzelrequest-Limit suggeriert Schutz, obwohl der
entscheidende globale Ressourcenvertrag fehlt.

## G07 — Produktiver Übersetzungsvertrag ist weder versioniert noch lokal getestet

**Urteil:** **BESTAETIGT** als Vertrags- und Regressionslücke  
**Eigener Schweregrad:** **mittel**

### Exakte Ausführung

1. `ensureRunning` prüft bei nicht erreichbarem Port nur, ob irgendein
   `claude-code-proxy` über den zentralen Command-Resolver gefunden wird, und startet
   den Pfad direkt mit festen Serve-Argumenten. Ein `--version`-, Semver- oder
   Capability-Schritt existiert in der gesamten Startsequenz nicht
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`).
2. Bei bereits laufendem Dienst genügt die Health-Probe: Status 200,
   `application/json` und `{ "ok": true }`
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`). Der echte
   Proxy v0.1.21 liefert auf `/healthz` ebenfalls nur die konstante Struktur
   `{ "ok": true }`, ohne Produkt, Version oder Fähigkeiten
   (`raine/claude-code-proxy@v0.1.21/src/server.rs:102-120`).
3. Nach positiver Probe startet der Manager den Router und synchronisiert die
   Agent-Definition, ohne Modell-/Endpoint-Probe
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:272-283`).
4. Die Settings zeigen nur den aufgelösten Binary-Pfad und Erreichbarkeit; eine Version
   wird weder gelesen noch angezeigt
   (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:88-117,259-279`).
   Modellfelder sind sogar frei editierbar und die Liste ausdrücklich nur Vorschlag
   (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:167-191`).
5. Die lokale CI baut und testet ausschließlich das Swift-Package; sie installiert
   oder startet keine festgelegte Proxy-Version
   (`.github/workflows/ci.yml:24-44`).

### Widerlegungsversuche und Mitigierungen

- **„Die Übersetzung ist überhaupt nicht getestet.“ — zu absolut.** Der externe Tag
  enthält eigene Unit-Tests, unter anderem für Tool-Result-Bildplatzhalter
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:1522-1535`),
  Codex-Reasoning-Replay
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:1690-1730`)
  und Tokenzählung
  (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:121-185`).
  Diese Tests sind aber weder vendort noch Teil der WhisperM8-CI und können daher eine
  beliebig über PATH aufgelöste Binary nicht qualifizieren.
- **„Die Health-Signatur identifiziert das Produkt eindeutig.“ — widerlegt.** Sowohl
  Manager als auch echte Implementierung prüfen beziehungsweise liefern nur das
  triviale `{ "ok": true }`
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:517-537`,
  `raine/claude-code-proxy@v0.1.21/src/server.rs:118-120`).
- **Kill-Switch und Graceful Degradation mildern den Schaden:** Backend ist standardmäßig
  aus und kann zentral deaktiviert werden
  (`WhisperM8/Support/AppPreferences.swift:257-261`). Scheitert `ensureRunning`, startet
  ein GPT-gestempelter Chat nach Alert ohne Router
  (`WhisperM8/Views/AgentSessionDetailView.swift:399-415,455-482,528-535`). Eine
  **erreichbare**, aber inkompatible Version passiert diesen Guard jedoch gerade und
  fällt erst im Requestpfad auf.
- Die lokalen Routertests ersetzen den Übersetzer durch einen Mock, der nur Request-
  Metadaten erfasst und Status/Chunks zurückgibt
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276,463-615`). Sie können
  keine Drift bei Thinking, Tools, Bildern, Usage, Stop-Reasons oder SSE-Ereignissen
  erkennen.

### Schweregradbegründung

**Mittel**: Die gegenwärtig aufgelöste 0.1.21-Binary passt zu dem geprüften Quellstand;
das Finding beweist daher keinen aktuellen Versionskonflikt. Der ungegatete Vertrag ist
aber real und betrifft die gesamte semantische Übersetzung. Ein Brew-/PATH-Update kann
den Kernpfad ändern, ohne eine rote WhisperM8-Suite oder eine verständliche
Startdiagnose zu erzeugen.

## Urteilsmatrix

| ID | Kurzfassung | Urteil | Eigener Schweregrad | Entscheidender Beleg/Gegenbeleg |
|---|---|---|---|---|
| G01 | Inkompatible Thinking-Historie beim Providerwechsel | **BESTAETIGT**, E2E-Teilvorbehalt | **hoch** | Fremde Signatur überspringt den gesamten Thinking-Block; GPT-Signaturen werden als Anthropic-Block emittiert (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:752-763`; `raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/live_stream.rs:937-1006`). |
| G02 | Tool-Result-Bilder werden verworfen | **BESTAETIGT** | **mittel** | Bildblöcke werden absichtlich zu `[image omitted]`; direkte User-Bilder bleiben intakt (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:649-692,847-905`). |
| G03 | Tokenzähler unterschätzt lange Runs | **BESTAETIGT** | **hoch** | Ein beliebig langer alphanumerischer/`-_`-Run erhöht den Textzähler nur einmal (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:97-118`). |
| G04 | Transportfehler werden Plaintext-502 | **BESTAETIGT** | **mittel** | 600-s-Timeouts; Pre-Head-Fehlerart wird nicht ausgewertet; lokaler Body ist `text/plain` (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:555-575,603-633,709-729`). |
| G05 | Kein aktiver Client-EOF-Read beim Denken | **BESTAETIGT** | **mittel** | Mit gesetzter `upstreamTask` wird `receiveMore` nicht erneut armiert (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:481-499,529-575`). |
| G06 | Kein globales Parallel-/Bytebudget | **BESTAETIGT** | **mittel** | Unbegrenzte `connections`-Map, 64 MiB je Body, eigene URLSession je Request (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:73-83,403-450,487-575,689-729`). |
| G07 | Keine Versions-/Capability-Grenze und keine lokale Contract-Suite | **BESTAETIGT** | **mittel** | Start über beliebigen PATH-Fund, konstantes `{ "ok": true }`, nur Swift-Mocktests (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283,469-537`; `Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-276,463-615`). |

**Summen:** 7 BESTAETIGT, 0 WIDERLEGT, 0 UNKLAR. Der E2E-Teilvorbehalt bei
G01 ist im Urteil ausdrücklich enthalten; der code-seitig bestätigte
Übersetzungsverlust reicht für BESTAETIGT.

## Die drei wichtigsten bestätigten Findings

1. **G01 — Thinking-Providergrenze:** Das Kernversprechen des freien
   Mid-Session-Wechsels trifft auf zwei inkompatible Signaturwelten. In Richtung GPT
   wird ein fremd signierter Thinking-Block deterministisch entfernt
   (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:267-285`;
   `raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:752-763`).
2. **G03 — falsches Kompaktionssignal:** Lange alphanumerische beziehungsweise
   URL-safe-Base64-Runs können um Größenordnungen zu klein gezählt werden, obwohl die
   Quelle diesen Wert ausdrücklich für Claude Codes Kompaktionslogik bereitstellt
   (`raine/claude-code-proxy@v0.1.21/src/providers/codex/count_tokens.rs:5-8,97-118`).
3. **G02 — multimodale Tool-Ergebnisse:** Der Übersetzer verwirft Bilddaten aus
   `tool_result` absichtlich und testgesichert; bildbasierte Agent-Tools verlieren
   dadurch ihren eigentlichen Befund, obwohl direkte User-Bilder funktionieren
   (`raine/claude-code-proxy@v0.1.21/src/providers/codex/translate/request.rs:649-692,847-905,1522-1535`).

## Abschließende adversariale Einordnung

Die Router-interne Serialisierung ist für die untersuchten Pfade grundsätzlich sauber:
Listener-/Connection-Map laufen über `lifecycleQueue`, jede Clientverbindung über eine
eigene serielle Queue und die URLSession-DelegateQueue nutzt dieselbe Queue
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:76-83,403-449,709-724`).
Keines der sieben Findings ist deshalb ein klassischer Datenrace- oder Lock-Inversionsbug.
Die bestätigten Fehler liegen an **Vertragsgrenzen**: providerfremde semantische Blöcke,
approximative Kompaktionsdaten, fehlende Disconnect-/Transportsemantik, globale
Ressourcenbudgets und ungegatete externe Übersetzer-Versionen. Genau diese Grenzen
werden von den vorhandenen Byte-Forwarding-Mocks nicht ausgeübt
(`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-353,463-615`).
