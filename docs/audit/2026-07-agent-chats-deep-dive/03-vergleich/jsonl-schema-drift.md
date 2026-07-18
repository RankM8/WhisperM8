---
status: abgeschlossen
updated: 2026-07-18
description: Feldvergleich robuster JSONL-Decoder für Claude Code und Codex mit Fokus auf Schema-Drift, unbekannte Events, parallele Tool-Korrelation, Teilzeilen und große Transcripts.
---

# JSONL unter Schema-Drift: robuste Transcript-Decoder

## 1. Fragestellung und Quellenstand

Dieser Vergleich untersucht zwei bestätigte WhisperM8-Risiken:

- **N15:** Tool-Aufrufe und Tool-Ergebnisse verlieren ihre Provider-Korrelations-ID; parallele Aufrufe können dadurch falsch gepaart werden.
- **N16:** syntaktisch gültige, aber unbekannte Codex-Events verschwinden ohne sichtbare Diagnose.

Die Referenzen wurden direkt aus den lokalen Klonen gelesen:

- `ccusage/rust/crates/ccusage/src/adapter/` — aktuelle Rust-Adapter für Claude und Codex,
- `sniffly/sniffly/core/processor.py` — Claude-JSONL-Verarbeitung,
- `lemmy/apps/claude-trace/src/` — API-Traffic-/SSE-Trace und Konversationsprojektion.

`claude-trace` liest nicht die nativen `~/.claude`-/`~/.codex`-Transcripts, sondern selbst aufgezeichnete Request/Response-Paare der Claude API. Sein **Raw-plus-Projektion**-Muster und seine ID-basierte Tool-Korrelation sind trotzdem direkt auf WhisperM8s Decodergrenze übertragbar (`lemmy/apps/claude-trace/src/types.ts:3-32`; `lemmy/apps/claude-trace/src/shared-conversation-processor.ts:28-32,587-638`).

## 2. Ist-Befund in WhisperM8

### 2.1 N15: Provider-IDs gehen vor der Timeline verloren

Das gemeinsame Datenmodell trägt bei `.toolUse` nur Name und Input und bei `.toolResult` nur Inhalt und Fehlerstatus; weder Claude-`tool_use.id`/`tool_use_id` noch Codex-`call_id` haben einen Speicherplatz (`WhisperM8/Models/AgentChatTranscript.swift:93-109`). Entsprechend liest der Claude-Reader beim `tool_use` nur `name` und `input` und beim `tool_result` nur `is_error` und `content` (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:160-180,204-220`). Der Codex-Reader verwirft `call_id` bei `function_call` und `function_call_output` ebenfalls (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:151-170`).

Die Timeline ersetzt die verlorene Identität durch eine globale FIFO-Liste offener Tool-Schritte und hängt jedes Resultat an deren ersten Eintrag (`WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:89-100,119-138,228-251`). Die dokumentierte Annahme „Claude sendet sie in Aufruf-Reihenfolge zurück“ ist damit eine Korrektheitsinvariante des UI-Codes, obwohl die Quelldaten stabile IDs liefern (`WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:7-18`). Sobald zwei Tool-Aufrufe parallel offen sind und Resultate nicht in Aufrufreihenfolge eintreffen, kann die Timeline Resultat A an Aufruf B hängen.

### 2.2 N16: `nil` bedeutet zugleich „bewusst irrelevant“ und „unbekannt“

`CodexTranscriptReader.parseEntry` liefert für unbekannte äußere Typen und unbekannte `event_msg`-Payloads und `response_item`-Payloads unterschiedslos `nil` (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:112-145,151-199`). `readTail` entfernt diese Fälle anschließend über `compactMap`; der Voll-Reader zählt nur syntaktisch nicht parsebare Zeilen als `skipped`, nicht syntaktisch gültige unbekannte Events (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:65-86,95-107`). Damit ist weder im Log noch im Modell unterscheidbar, ob eine Zeile absichtlich ignoriert, wegen Schema-Drift nicht erkannt oder wegen fehlender Pflichtfelder nicht projizierbar war.

Der Claude-Reader hat dieselbe geschlossene Projektion: nur `user` und `assistant` passieren den Top-Level-Switch, unbekannte Content-Blöcke fallen über `default: break` heraus (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:132-144,160-183,204-221`). Dort ist das Auslassen einiger Metadaten-Typen zwar ausdrücklich beabsichtigt, aber auch hier trennt der Rückgabetyp „bekannt ignoriert“ nicht von „neu und unbekannt“ (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:7-22`).

### 2.3 Große Dateien sind zeilenweise, aber nicht vollständig bounded

Der Voll-Reader liest in 64-KiB-Chunks, hält jedoch den Puffer bis zum nächsten Newline und materialisiert danach das vollständige JSON-Objekt; die Spitzennutzung ist daher mindestens O(größte Zeile), und alle projizierten Messages bleiben bis zum Ende im Array (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:79-100,301-334`). Bei Image-Blöcken wird Base64 zwar nicht im Zielmodell behalten, aber `JSONSerialization` hat den String während des Parses bereits materialisiert; anschließend wird nur seine Zeichenlänge gespeichert (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:85-94,169-172`).

Der Tail-Pfad begrenzt den Dateislice standardmäßig auf 256 KiB und verwirft am angeschnittenen Kopf die erste Zeile (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:271-297`). Eine nicht newline-terminierte letzte Zeile wird jedoch sowohl vom Voll- als auch Tail-Reader als regulärer Parseversuch behandelt; bei einem gerade appendenden Prozess wird ein halbes JSON-Objekt dadurch vorübergehend wie eine kaputte Zeile behandelt beziehungsweise still aus dem Tail entfernt (`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:288-294,311-334`; `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:95-107`).

## 3. Musterkatalog aus den Vergleichsprojekten

### Muster A — Erst toleranter Envelope, dann typisierte Projektion

`ccusage` trennt die schnelle Zeilen-/Record-Schicht von feldspezifischen Decodern. Die gemeinsamen Hilfen deserialisieren bekannte Records direkt, geben fehlenden oder falsch typisierten Zahlen definierte Defaults, behandeln defekte Nested-Objects als abwesend und können in Arrays nur die ungültigen Elemente auslassen, statt die ganze Zeile zu verlieren (`ccusage/rust/crates/ccusage/src/adapter/jsonl.rs:47-83,86-140,143-185`). Die zugehörigen Tests decken Nicht-Objekte, falsche Zahltypen, kaputte Array-Elemente und fehlende Felder explizit ab (`ccusage/rust/crates/ccusage/src/adapter/jsonl.rs:244-255,258-301,304-395`).

Der Codex-Adapter akzeptiert außerdem mehrere tatsächlich beobachtete Formen statt einer einzigen starren Struktur: Timestamps als String oder Zahl, `created_at` oder `createdAt`, Nutzungsdaten unter Root, `data`, `result` oder `response`, Modellnamen als `model`, `model_name` oder `metadata.model` (`ccusage/rust/crates/ccusage/src/adapter/codex/types.rs:7-66,68-128`; `ccusage/rust/crates/ccusage/src/adapter/codex/parser.rs:607-668,685-730,733-837`). Tokenfelder werden über Aliasgruppen wie `input_tokens|prompt_tokens|input` und `output_tokens|completion_tokens|output` normalisiert (`ccusage/rust/crates/ccusage/src/adapter/codex/types.rs:136-198`).

Für einen Host ist wichtig, auch die Grenze dieses Musters zu übernehmen: `ccusage` darf als Statistiktool irrelevante oder nicht decodierbare Records still auslassen (`ccusage/rust/crates/ccusage/src/adapter/jsonl.rs:21-30,47-61`). WhisperM8 darf diesen **toleranten Felddecoder** übernehmen, nicht aber dessen **verlustreiche Eventauswahl**.

**Übertragbares Muster:**

1. Zeile minimal als Envelope lesen: Provider, äußerer `type`, innerer `payload.type`, Timestamp, optionale Provider-Version, Source-Range.
2. Bekannte Kombinationen mit kleinen, toleranten Decodern projizieren.
3. Falsch typisierte optionale Felder auf `nil`/Default degradieren; nur wirklich notwendige Felder machen die Projektion unvollständig.
4. Den Envelope unabhängig vom Projektionserfolg klassifizieren und diagnostizieren.

### Muster B — Raw Capture bleibt neben der Komfortprojektion bestehen

`sniffly` verarbeitet Dateien zeilenweise und isoliert jede Exception auf die einzelne Zeile; spätere Zeilen laufen weiter (`sniffly/sniffly/core/processor.py:340-403`). Für erkannte Summary-, Compact- und reguläre Message-Einträge speichert es zusätzlich das ursprüngliche Dictionary als `_raw_data`, während die Komfortprojektion Text, Tools und Token separat extrahiert (`sniffly/sniffly/core/processor.py:361-399,424-479`). Das schützt bekannte Messages gegen spätere Anforderungen an heute noch nicht projizierte Felder.

Die Grenze ist ebenso aufschlussreich: Nur Einträge mit `message` und `type` gelangen in den regulären Pfad; unbekannte Top-Level-Events werden nicht als Raw-Envelope aufgenommen. Innerhalb von `message.content` versteht die Projektion nur `text`, `tool_use` und `tool_result`; andere Blocks bleiben lediglich indirekt im `_raw_data` der bekannten Message erhalten (`sniffly/sniffly/core/processor.py:390-400,481-521`). Das ist besser als irreversibles Wegwerfen, aber noch kein vollständiges „capture unknown“.

`claude-trace` setzt das Dualmodell konsequenter um: Ein `RawPair` bewahrt Request-Body, Response-Body oder rohen Response-Text mit offenen `any`-Feldern; die typisierte Konversationsansicht ist eine zweite Schicht (`lemmy/apps/claude-trace/src/types.ts:3-32,49-88`). Beim Verarbeiten bleibt `rawStreamData` am projizierten Pair erhalten (`lemmy/apps/claude-trace/src/shared-conversation-processor.ts:67-105`). Standard-SSE-Zeilen werden einzeln geparst; ungültige Events werden gewarnt und übersprungen, aber der komplette rohe Stream bleibt im Pair verfügbar (`lemmy/apps/claude-trace/src/shared-conversation-processor.ts:263-286`). Der geschlossene Event-Switch projiziert nur bekannte Event- und Delta-Typen, ohne dadurch die Raw-Quelle zu vernichten (`lemmy/apps/claude-trace/src/shared-conversation-processor.ts:292-431`).

**Übertragbares Muster:** Eine unbekannte, syntaktisch gültige Zeile ist kein Parserfehler und kein `nil`, sondern ein `UnknownEvent` mit Discriminator, Source-Position und Raw-Zugriff. Die UI darf daraus nur einen kompakten Hinweis bauen; Detailansicht und Diagnostik müssen den Rohinhalt weiterhin erreichbar machen.

### Muster C — Tool-Korrelation ausschließlich über Provider-ID

`claude-trace` hält offene Uses in einem Dictionary nach `tool_use.id`. Ein `tool_result.tool_use_id` adressiert exakt diesen Eintrag, unabhängig davon, wie viele Uses offen sind oder in welcher Reihenfolge die Resultate erscheinen; die Result-only-Message kann danach in der Komfortansicht versteckt werden, weil ihr Inhalt am richtigen Use hängt (`lemmy/apps/claude-trace/src/shared-conversation-processor.ts:587-638`). Damit ist Parallelität keine Sonderbehandlung, sondern eine direkte Folge des Datenmodells.

`sniffly` zeigt die unzureichende Zwischenstufe: Es bewahrt `tool_use.id` und dedupliziert Tool-Uses damit (`sniffly/sniffly/core/processor.py:87-110,157-169`), gruppiert Resultate aber nur nach zeitlicher Zugehörigkeit zur aktuellen User-Interaktion (`sniffly/sniffly/core/processor.py:961-1005`). Die spätere Abgleichlogik zählt eindeutige Use-IDs und Result-Blöcke, paart sie jedoch nicht über `tool_use_id`; bei mehr Resultaten setzt sie lediglich den Zähler hoch (`sniffly/sniffly/core/processor.py:1087-1115`). Für N15 ist daher `claude-trace`, nicht `sniffly`, das Zielmuster.

**Übertragbares Muster:** Provider + Session/Turn + Korrelations-ID bilden den Schlüssel. Eine 1:1-Zuordnung wird nur bei genau einem Use und einem Result hergestellt. Doppelte IDs, Resultate ohne Use und offene Uses ohne Result werden als eigene Diagnosen sichtbar; sie dürfen weder Last-Write-Wins noch stiller FIFO werden.

### Muster D — Feature Detection vor globaler Schema-Version

Der `ccusage`-Codexpfad wählt zwischen Session- und Headless-Form anhand vorhandener Discriminator-/Usage-Felder und versucht bei einer Headless-Zeile erst einen typisierten Decode, dann einen dynamischen `Value`-Fallback (`ccusage/rust/crates/ccusage/src/adapter/codex/parser.rs:138-235,401-425`). Modell- und Timestamp-Lookups laufen als geordnete Feldketten über mehrere beobachtete Positionen und Schreibweisen (`ccusage/rust/crates/ccusage/src/adapter/codex/parser.rs:591-668,733-918`). Das ist Feature Detection: Der Parser fragt „welche Struktur ist vorhanden?“ statt „welche einzige Gesamtversion gilt?“.

`ccusage` liest zwar ein optionales Claude-`version`-Feld, verwendet es im untersuchten Daily-Pfad aber nur als Plausibilitätsprüfung auf semver-artige Syntax; daraus folgt keine separate Decoder-Migration (`ccusage/rust/crates/ccusage/src/adapter/claude/daily.rs:127-160,349-387`). `claude-trace` erkennt Standard-SSE versus Bedrock über das tatsächlich beobachtete Streamformat und behält fehlgeschlagenes partielles Tool-Input-JSON als String statt den gesamten Block zu verlieren (`lemmy/apps/claude-trace/src/shared-conversation-processor.ts:73-83,112-159,345-355,379-393`).

**Übertragbares Muster:** Eine vorhandene Provider-Version wird als Telemetrie und Test-Fixture-Metadatum gespeichert. Dispatch und Fallback richten sich primär nach äußeren/inneren Discriminators und Feld-Features. Eine unbekannte Version mit bekannten Features bleibt lesbar; eine bekannte Version mit unbekanntem Event bleibt sichtbar unbekannt.

### Muster E — Zeilenfehler isolieren, Teilzeile aber anders behandeln

`sniffly` und der `ccusage`-Codexadapter lesen mit einem Dateiiterator beziehungsweise `BufReader.read_until('\n')`; ein fehlerhafter Decode beendet nicht die Datei (`sniffly/sniffly/core/processor.py:340-403`; `ccusage/rust/crates/ccusage/src/adapter/codex/parser.rs:138-174,213-235`). `claude-trace` isoliert in seinem HTML-JSONL-Loader kaputtes JSON ebenfalls pro Zeile und meldet Zeilennummer plus Preview (`lemmy/apps/claude-trace/src/html-generator.ts:134-163`).

Keines der drei Projekte ist als Ganzes ein Bounded-Memory-Vorbild für WhisperM8: `sniffly` sammelt alle extrahierten Messages und mehrere abgeleitete Listen vor dem finalen Limit (`sniffly/sniffly/core/processor.py:267-325`); `ccusage` liest im Claude-Daily-Pfad jede Datei vollständig, bevor es Bytezeilen bildet (`ccusage/rust/crates/ccusage/src/adapter/claude/daily.rs:241-266`); `claude-trace` lädt das ganze JSONL in einen String und hält alle Pairs (`lemmy/apps/claude-trace/src/html-generator.ts:143-170`). Das robuste Ziel muss deshalb WhisperM8s vorhandenes Chunk-/Tail-Prinzip behalten und nur die Diagnose- und Teilzeilen-Semantik verbessern.

**Übertragbares Muster:**

- Nicht newline-terminierter EOF-Rest einer potenziell live wachsenden Datei wird als `pendingFragment` zurückgestellt, nicht als `malformed` gezählt.
- Newline-terminiertes ungültiges JSON wird als `MalformedLine` mit Zeilennummer/Byte-Range, Fehlerklasse und begrenzter Preview erfasst; danach geht es weiter.
- Für ungewöhnlich große Einzelzeilen gilt eine eigene Policy. Besonders Base64-Image-`data` sollte beim inkrementellen Scan gezählt/übersprungen statt als riesiger Swift-String dauerhaft materialisiert werden.
- Full- und Tail-Reader verwenden denselben Decoder und dieselben Outcomes; nur die Source-Range unterscheidet sich.

## 4. Konkretes Zielmodell für WhisperM8

### 4.1 Parser-Outcome statt optionaler Message

Beide Reader sollten intern nicht mehr `AgentChatMessage?`, sondern einen expliziten Outcome liefern:

```swift
enum TranscriptParseOutcome {
    case projected(AgentChatMessage)
    case ignoredKnown(TranscriptEventDescriptor)
    case unknown(UnknownTranscriptEvent)
    case malformed(TranscriptParseDiagnostic)
    case pendingFragment(SourceRange)
}
```

`ignoredKnown` ist für bewusst nicht angezeigte Claude-/Codex-Metadaten. `unknown` ist syntaktisch gültig, aber dem aktuellen Build unbekannt oder nicht projizierbar. `malformed` ist ausschließlich ungültiges JSON beziehungsweise eine harte Envelope-Verletzung. Damit verschwinden N16-Fälle nicht mehr in demselben `nil` wie absichtlich ignorierte Zeilen.

`AgentChatTranscript` braucht zusätzlich aggregierte Diagnosen oder Events; mindestens `unknownCount`, `malformedCount`, `pendingFragmentCount`, betroffene Discriminators und Source-Ranges. In der Timeline wird ein unbekanntes Event als kompakter `.system`-/`.note`-Schritt sichtbar („Unbekanntes Codex-Ereignis: response_item/new_type“), nicht als vollständiger Raw-Dump. Der Raw-Zugriff kann speicherschonend über `(fileURL, byteRange, digest, boundedPreview)` erfolgen.

### 4.2 Korrelations-ID in das gemeinsame Blockmodell heben

Das gemeinsame Modell sollte mindestens folgende Signaturen tragen:

```swift
case toolUse(id: String?, name: String, input: String)
case toolResult(toolUseID: String?, content: String, isError: Bool)
```

Der Claude-Reader setzt `id` aus `tool_use.id` und `toolUseID` aus `tool_result.tool_use_id`; der Codex-Reader verwendet für beide Seiten `call_id`. Die stabile Message-ID muss diese IDs in ihren Digest aufnehmen, damit inhaltlich gleiche parallele Uses nicht nur über den Parse-lokalen Occurrence-Zähler unterschieden werden. Der heutige Digest kennt ausschließlich Name/Input beziehungsweise Resultinhalt/Fehlerstatus (`WhisperM8/Models/AgentChatTranscript.swift:53-79`).

Die Timeline ersetzt `openToolStepIndices: [Int]` durch einen Multi-Index, beispielsweise `[ToolCorrelationKey: [Int]]`. Resultate mit ID werden nie per FIFO gepaart. Für historische oder providerseitig ID-lose Daten darf es höchstens einen ausdrücklich als heuristisch markierten Fallback geben; bei mehr als einem offenen Kandidaten bleibt das Resultat orphaned statt potenziell falsch zugeordnet.

### 4.3 Zweistufiger Decoder pro Provider

**Gemeinsame Stufe:** Newline-/Fragment-Erkennung, Source-Range, JSON-Objektprüfung, Timestamp-Normalisierung, Discriminator-Erfassung, Größen-/Preview-Limits und Outcome-Zähler.

**Claude-Projektion:**

- bekannte Top-Level-Metadaten explizit `ignoredKnown`, nicht pauschal `default: nil`;
- `user`/`assistant` tolerant blockweise projizieren;
- unbekannte Content-Block-Typen als Unknown-Block beziehungsweise Message-Diagnose behalten;
- `tool_use.id` und `tool_result.tool_use_id` immer übernehmen.

**Codex-Projektion:**

- Dispatch über `(outerType, payloadType)`;
- `event_msg/user_message`, `event_msg/agent_message` und bekannte `response_item`-Typen projizieren;
- unbekannte Kombinationen als `unknown`, einschließlich bounded Raw-Preview;
- `function_call.call_id` und `function_call_output.call_id` übernehmen;
- Feldaliases und tolerante Nested-Decodes nach dem `ccusage`-Muster verwenden, ohne unbekannte Events auszulassen.

## 5. Priorisierte Umsetzungsempfehlung

| Priorität | Änderung | Behebt | Regressions-Gate |
|---|---|---|---|
| P0 | Korrelations-ID in `AgentChatBlock`, beide Reader und Stable-ID-Digest aufnehmen; Timeline per ID statt FIFO paaren | N15 | Zwei parallele Uses, Resultate in umgekehrter Reihenfolge; Orphan-, Duplicate- und Missing-ID-Fälle |
| P0 | `TranscriptParseOutcome` einführen; unbekannte gültige Codex-Events zählen und sichtbar degradieren | N16 | unbekannter äußerer Typ, unbekannter `event_msg`-Typ, unbekannter `response_item`-Typ, unbekannter Content-Block |
| P1 | Gemeinsamen Envelope-/Diagnostikpfad für Full und Tail; nicht terminierte EOF-Zeile als pending behandeln | Drift + Live-Append | Datei endet mitten im JSON; dieselbe Zeile wird nach Append genau einmal projiziert |
| P1 | Tolerante Feldaliases/Shape-Decodes; Version nur als Telemetrie, Feature Detection für Dispatch | zukünftige Schemaformen | String-/Zahl-Timestamp, optionale Felder mit falschem Typ, bekannte Features bei unbekannter Version |
| P2 | Byte-Offset-/Source-Range-basierter Raw-Zugriff, Oversize-Line-/Base64-Policy, inkrementelles Nachladen | große Dateien | >50-MB-File, >256-KiB-Einzelzeile, großes Image-`data`, bounded Preview |

Die Reihenfolge ist absichtlich konservativ: Erst wird die semantische Datenintegrität von Tool-Paaren und unbekannten Events abgesichert, dann werden Reader-Lifecycle und Speichergrenzen vereinheitlicht. Das bestehende UI-Verhalten für bekannte Text-, Thinking-, Image- und Tool-Blöcke bleibt dabei erhalten; nur bisher falsche Paarungen und unsichtbare Drift werden sichtbar korrigiert.

## 6. Schlussurteil

Die belastbarste Kombination ist nicht ein einzelnes Referenzprojekt, sondern drei klar getrennte Muster: `ccusage` liefert tolerante Shape-/Alias-Decoder, `claude-trace` liefert Raw-plus-Projektion und ID-basierte Tool-Korrelation, und `sniffly` bestätigt die Praxis der zeilenweisen Fehlerisolation sowie den Nutzen einer Raw-Seitenablage für bekannte Messages. Ihre Grenzen sind ebenso wichtig: Statistikparser dürfen unbekannte Events still auslassen, Transcript-Viewer nicht; und keiner der drei Vergleichspfade löst große Dateien so gut, dass WhisperM8 sein vorhandenes Tail-/Chunk-Prinzip dafür aufgeben sollte.
