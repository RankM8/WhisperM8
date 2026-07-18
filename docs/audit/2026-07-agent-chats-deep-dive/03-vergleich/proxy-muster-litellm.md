---
status: abgeschlossen
updated: 2026-07-18
description: Musterkatalog der Anthropic-zu-OpenAI-Übersetzung in LiteLLM und Gap-Analyse gegen WhisperM8s ClaudeGPTMixRouter.
---

# Proxy-Muster: LiteLLM Anthropic-Übersetzung vs. WhisperM8

## Scope und Leseschlüssel

Analysiert wurde ausschließlich LiteLLMs Anthropic-Schicht unter `litellm/llms/anthropic/` einschließlich ihrer unmittelbar zugehörigen Message-/Completion-Adapter. Vergleichsziel ist `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift`. Nicht untersucht wurden LiteLLMs sonstige Provider und WhisperM8s Produktcode außerhalb der bereits bestätigten Usage-Einordnung.

Die Belege verwenden folgende Wurzeln:

- **`L/`** = `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/vergleich/litellm/`
- **`W/`** = `/Users/giulianocosta/repos/whisperm8/`

„Im MixRouter nicht behandelt“ bedeutet zunächst eine **Schichtlücke**, nicht automatisch einen End-to-End-Defekt: Der Router kann gültige Anthropic-Bytes transparent erhalten und die semantische Übersetzung an den lokalen Codex-Proxy delegieren. Für Token-Usage ist der End-to-End-Defekt jedoch bereits live bestätigt: Weder MixRouter noch ProxyManager übersetzen die Felder, GPT-Turns erscheinen mit null Tokens (`W/docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde3-live-repro-usage-kompaktierung.md:14-27`).

## Kurzfazit

1. **LiteLLM ist kein Byte-Relay, sondern ein zustandsbehafteter Protokolladapter.** Es erzeugt und ordnet `message_start`, Content-Block-Lebenszyklen, `message_delta` und `message_stop`; WhisperM8s MixRouter streamt Upstream-Bytes lediglich als HTTP-Chunks weiter (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:146-168`, `W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`).
2. **Das wichtigste Fix-Vorbild ist LiteLLMs Hold-and-merge-Logik für Streaming-Usage.** Ein Finish-Chunk wird zurückgehalten, ein nachfolgender usage-only-Chunk hineingemischt und genau ein finales Anthropic-`message_delta.usage` emittiert (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:213-237`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:423-439`).
3. **Tool-Streaming ist block- und indexsensitiv.** LiteLLM trennt Tool-Metadaten im `content_block_start` von fragmentierten Argumenten in `input_json_delta`, verwendet leere Startargumente statt `{}` und schließt jeden Block in korrekter Reihenfolge (`L/litellm/llms/anthropic/chat/handler.py:788-825`, `L/litellm/llms/anthropic/chat/handler.py:879-908`). Der MixRouter inspiziert diese Ereignisse nicht (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`).
4. **Fehler brauchen zwei Ebenen:** HTTP-Status/Body/Headers sowie terminale SSE-Fehler. LiteLLM bewahrt HTTP-Status und Headers, normalisiert unbekannte Fehler auf 500 und synthetisiert bei vorzeitigem Streamende ein Anthropic-`event: error`; der MixRouter reicht Upstream-Fehler zwar transparent durch, erzeugt lokale Fehler aber als `text/plain` und beendet späte Streamfehler nur per Verbindungsabbruch (`L/litellm/llms/anthropic/chat/handler.py:90-113`, `L/litellm/llms/anthropic/experimental_pass_through/messages/streaming_iterator.py:186-211`, `W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-633`).
5. **Multimodalität und Stop-Semantik sind explizite Transformationen, keine bloßen Feldkopien.** LiteLLM normalisiert Base64-/URL-Bilder, Dokumente, Tool-Result-Inhalte sowie Stop-Listen und Finish-Reasons; im MixRouter existiert dafür keine semantische Stufe (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:354-400`, `L/litellm/llms/anthropic/chat/transformation.py:1149-1167`, `W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`).

## Musterkatalog

### M1 — Streaming als expliziter Anthropic-Zustandsautomat

LiteLLM modelliert den Stream als geordnete Ereignisfolge:

1. synthetisches `message_start` mit Modell, leerem Content, leeren Stop-Feldern und initialer Usage,
2. `content_block_start`,
3. ein oder mehrere typisierte `content_block_delta`,
4. `content_block_stop`,
5. finales `message_delta` mit Stop-Reason und Usage,
6. `message_stop`.

Der Wrapper dokumentiert diese Invarianten ausdrücklich und hält dafür pro Stream eigene Flags, Queue und Content-Block-Indizes (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:146-168`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:200-211`). `message_start` wird konkret mit initialer Usage erzeugt (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:371-389`); am Ende schließt LiteLLM einen offenen Block vor dem finalen `message_delta` und sendet danach `message_stop` (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:519-557`).

Explizit behandelte Chunk-Sonderfälle:

- Ein Provider kann Content **und** `finish_reason` im selben Chunk liefern. LiteLLM splittet ihn in Content- und Finish-Chunk, damit Content nicht verloren geht (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:54-71`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:80-119`).
- Leere oder zum aktiven Blocktyp unpassende Deltas werden unterdrückt, weil strikte Anthropic-Clients sonst etwa einen `text_delta` in einem Thinking-Block ablehnen (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:839-876`).
- Beim Wechsel zwischen Text, Thinking und Tool-Use erzeugt LiteLLM Stop/Start und reiht das auslösende erste Delta erneut ein, damit kein erstes Token oder Tool-Argument verloren geht (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:450-486`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:878-919`).

**WhisperM8-Abgleich:** Der MixRouter erkennt keine SSE-Events. Er schreibt die von `URLSession` erhaltenen Bytes sofort in HTTP/1.1-Chunks (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`) und setzt nur bei sauberem Abschluss den HTTP-Nullchunk (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-620`). Damit bewahrt er einen bereits korrekten Anthropic-Stream, kann aber falsche Reihenfolge, kombinierte Chunks oder unvollständige Content-Blöcke eines GPT-Upstreams nicht reparieren.

### M2 — Tool-Call-Deltas: Startmetadaten, Index und fragmentierte Argumente getrennt

Auf der Anthropic→OpenAI-Seite behandelt LiteLLM Tool-Streaming in drei Phasen:

- `content_block_start` erhöht `tool_index`, übernimmt ID und Namen und setzt `arguments` bewusst auf den leeren String; ein initiales `{}` würde sich mit nachfolgenden Fragmenten zu ungültigem JSON verbinden (`L/litellm/llms/anthropic/chat/handler.py:788-825`).
- Nur innerhalb eines aktiven `tool_use`/`server_tool_use`-Blocks wird `input_json_delta.partial_json` als OpenAI-Tool-Call-Delta mit demselben Index ausgegeben; gleichartige Deltas aus Ergebnisblöcken werden nicht fälschlich als Aufruf interpretiert (`L/litellm/llms/anthropic/chat/handler.py:632-651`).
- Ein komplett leerer Argumentstrom wird bei `content_block_stop` als `{}` abgeschlossen; für Server-Tools werden alle Fragmente gesammelt und erst dann per `json.loads` validiert (`L/litellm/llms/anthropic/chat/handler.py:879-908`).

Auf der OpenAI→Anthropic-Seite erzeugt LiteLLM aus ID/Name zunächst einen `tool_use`-Startblock mit leerem `input` (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1370-1392`). Nachfolgende OpenAI-Argumentfragmente werden in ein Anthropic-`input_json_delta.partial_json` übersetzt (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1433-1462`). Tool-Namen, die wegen OpenAIs Längenlimit gekürzt wurden, werden vor dem Anthropic-Startblock wiederhergestellt (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:895-919`).

**WhisperM8-Abgleich:** Der MixRouter liest aus dem JSON-Body nur `model` zur Zielwahl (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`) und sendet den Body danach unverändert (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`). Tool-ID, Index, Blockgrenzen und Argumentfragmente werden dort weder aufgebaut noch validiert.

### M3 — Token-Usage bidirektional und cache-bewusst

#### Anthropic→OpenAI

LiteLLM übersetzt `input_tokens` nach `prompt_tokens`, `output_tokens` nach `completion_tokens` und bildet `total_tokens`. Cache-Read- und Cache-Creation-Tokens werden zum Prompt-Gesamtwert addiert und zugleich in `prompt_tokens_details` separat ausgewiesen; `None` und nichtnumerische Werte werden defensiv auf null normalisiert (`L/litellm/llms/anthropic/chat/transformation.py:2107-2147`, `L/litellm/llms/anthropic/chat/transformation.py:2178-2204`). Usage wird sowohl aus `message_start.message.usage` als auch aus dem finalen `message_delta.usage` gelesen (`L/litellm/llms/anthropic/chat/handler.py:928-950`, `L/litellm/llms/anthropic/chat/handler.py:1033-1051`).

#### OpenAI→Anthropic, nicht streamend

LiteLLM zieht Cache-Read- und Cache-Creation-Tokens von `prompt_tokens` ab, weil Anthropic `input_tokens` als nicht gecachten Anteil führt; beide Cache-Werte werden separat erhalten. `completion_tokens` wird zu `output_tokens` (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1261-1294`). Das Ergebnis landet im nicht streamenden Anthropic-Response unter `usage`, gemeinsam mit `stop_reason` und Content (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1328-1353`).

#### OpenAI→Anthropic, streamend — das direkte Fix-Vorbild

LiteLLM löst den typischen OpenAI-Streamingfall, in dem Finish und Usage in getrennten Chunks eintreffen:

1. `message_start.usage` wird mit null initialisiert, einschließlich Cache-Feldern, damit Clients die Unterstützung erkennen (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:342-361`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:371-386`).
2. Ein Chunk mit `finish_reason` wird zunächst als Anthropic-`message_delta` übersetzt und zurückgehalten (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1472-1500`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:491-505`).
3. Trifft danach ein usage-only-Chunk ein, werden dessen OpenAI-Zähler cache-bewusst übersetzt und in den gehaltenen Stop-Chunk gemischt; erst dann wird genau ein finales `message_delta` ausgegeben (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:213-237`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:423-439`).
4. Falls kein separater Usage-Chunk kommt, wird der gehaltene Stop-Chunk am Streamende in gültiger Reihenfolge geflusht; nach bereits ausgegebener finaler Usage werden nachlaufende Provider-Events verworfen (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:441-448`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:519-552`).

**WhisperM8-Abgleich:** Der MixRouter transformiert weder Request- noch Response-JSON; die Upstream-Antwort wird byteweise weitergegeben (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`, `W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`). Die fehlende Usage-Übersetzung ist zusätzlich negativ per Quelltextsuche und positiv im GPT-Transcript bestätigt (`W/docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde3-live-repro-usage-kompaktierung.md:14-27`).

**Fix-Muster:** Der spätere Fix braucht mindestens (a) OpenAI-Streaming mit `stream_options.include_usage`, (b) einen pro Response isolierten SSE-Zustand, (c) Zurückhalten des Finish-Events bis zum usage-only-Chunk oder Streamende, (d) `prompt_tokens`→`input_tokens` und `completion_tokens`→`output_tokens`, (e) optional cache-bewusste Subtraktion wie LiteLLM und (f) Tests für getrennte sowie kombinierte Finish-/Usage-Chunks. Die bestehende Fix-Skizze fordert bereits den finalen Usage-Chunk und `message_delta.usage` (`W/docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde3-live-repro-usage-kompaktierung.md:55-64`).

### M4 — Stop-Sequenzen und Finish-Reasons

LiteLLMs native OpenAI→Anthropic-Konfiguration normalisiert einen einzelnen `stop`-String zu einer Liste, lässt Listen als Listen und entfernt reine Whitespace-Sequenzen, wenn `drop_params` aktiv ist, weil Anthropic sie nicht akzeptiert (`L/litellm/llms/anthropic/chat/transformation.py:1149-1167`). Das Ergebnis wird als `stop_sequences` in den Anthropic-Request geschrieben (`L/litellm/llms/anthropic/chat/transformation.py:1428-1433`). Im Anthropic-kompatiblen Adapter wird ein eingehendes `stop_sequences` explizit in die internen Completion-Argumente übernommen (`L/litellm/llms/anthropic/experimental_pass_through/adapters/handler.py:407-446`).

Antwortseitig mappt LiteLLM OpenAI `stop`→Anthropic `end_turn`, `length`→`max_tokens` und `tool_calls`→`tool_use`; unbekannte Werte fallen auf `end_turn` zurück (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1219-1226`). Eine Einschränkung des Referenzmusters: Im nicht streamenden Adapter ist `stop_sequence` fest `None`; die konkret ausgelöste Sequenz wird also nicht rekonstruiert (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1344-1353`).

**WhisperM8-Abgleich:** Der MixRouter kennt weder `stop`, `stop_sequences`, `stop_reason` noch `finish_reason`; er entscheidet ausschließlich anhand des Modellpräfixes über den Upstream (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`) und reicht den Body unverändert weiter (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`).

### M5 — Multimodale Content-Blöcke und Tool-Result-Inhalte

LiteLLM normalisiert Anthropic-Bilder in zwei Formen:

- Base64-Quelle → `data:<media_type>;base64,<data>`;
- URL-Quelle → unveränderte URL.

Ungültige oder leere Quellen werden nicht als Bild emittiert (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1113-1138`). User-`image`-Blöcke werden zu OpenAI-`image_url`; Anthropic-`document`-Blöcke werden im Adapter ebenfalls als `image_url` weitergereicht (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:375-400`).

Für `tool_result` wahrt LiteLLM die Anthropic-Invariante „ein Resultat pro `tool_use_id`“: Mehrere Text-/Bildteile werden in **einer** OpenAI-Tool-Message kombiniert statt in mehrere Messages mit derselben ID zerlegt (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:418-498`). Assistant-`tool_use` wird mit ID, Funktionsname und JSON-Argumenten in OpenAI-`tool_calls` übersetzt (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:509-554`).

**WhisperM8-Abgleich:** Der MixRouter parst weder `messages` noch Content-Blöcke; er liest nur `model` (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`) und setzt denselben Body in den Upstream-Request (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`). Damit bleiben bereits Anthropic-kompatible multimodale Requests transparent erhalten; die GPT-Kompatibilität hängt vollständig vom Codex-Proxy ab.

### M6 — Fehler-Mapping und terminale Streamfehler

LiteLLM trennt HTTP-, Provider- und Streamfehler:

- Bei HTTP-Fehlern bewahrt `AnthropicError` Status, Body und soweit vorhanden Response-Headers; nicht klassifizierte Transportfehler werden auf 500 normalisiert (`L/litellm/llms/anthropic/chat/handler.py:90-113`, `L/litellm/llms/anthropic/chat/handler.py:150-181`, `L/litellm/llms/anthropic/common_utils.py:97-104`).
- Ein Anthropic-SSE-Chunk `type: error` wird erkannt, seine Meldung übernommen und mangels Status im Chunk als 500 klassifiziert (`L/litellm/llms/anthropic/chat/handler.py:951-960`).
- Der Pass-through-Stream betrachtet sowohl `message_stop` als auch `event: error` als terminal. Endet der Providerstream ohne eines davon, synthetisiert LiteLLM ein valides Anthropic-`event: error` mit `type: api_error` (`L/litellm/llms/anthropic/experimental_pass_through/messages/streaming_iterator.py:26-53`, `L/litellm/llms/anthropic/experimental_pass_through/messages/streaming_iterator.py:186-211`).

**WhisperM8-Abgleich:** Einen erhaltenen Upstream-HTTP-Status samt Body reicht der MixRouter transparent weiter (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`). Scheitert der Upstream vor den Response-Headers, erzeugt er dagegen einen lokalen 502; scheitert er später, bricht er nur die Verbindung ab (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-620`). Lokale 4xx/5xx-Antworten sind `text/plain`, nicht Anthropic-Error-JSON (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:624-633`). Damit ist HTTP-Pass-through vorhanden, aber kein Anthropic-Fehlermapping und kein terminales SSE-Fehlerereignis.

## Lücken-Tabelle

| Bereich | LiteLLM-Muster | WhisperM8 `ClaudeGPTMixRouter` | Einordnung / Priorität |
|---|---|---|---|
| Streaming-Chunk-Formen | Vollständiger Anthropic-Zustandsautomat; Split kombinierter Content-/Finish-Chunks; typisierte Blockwechsel und strikte Reihenfolge (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:54-119`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:371-389`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:450-505`) | Byteweises HTTP-Chunk-Relay ohne SSE-Parsing (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`) | **Delegiert, mittel:** Für Anthropic-Upstream korrekt transparent; GPT-Pfad benötigt diese Garantie im Codex-Proxy oder in einer neuen Adapterstufe. |
| Tool-Call-Delta-Assembly | Tool-Index pro Block; Start mit leeren Argumenten; `input_json_delta` nur in Tool-Blöcken; leere Args→`{}` (`L/litellm/llms/anthropic/chat/handler.py:788-825`, `L/litellm/llms/anthropic/chat/handler.py:879-908`) | Nur Modell wird geparst, Body unverändert gesendet (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`, `W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`) | **Delegiert, hoch bei GPT-Tools:** Ohne äquivalenten Upstream-Adapter drohen ungültiges JSON, falsche Indizes oder verlorene erste Fragmente. |
| Token-Usage, nicht streamend | Cache-bewusste Übersetzung `prompt_tokens`/`completion_tokens`→`input_tokens`/`output_tokens` (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1261-1301`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1328-1353`) | Keine Response-Transformation; raw forward (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-600`) | **Bestätigter Defekt, hoch:** Live-Repro zeigt null Tokens und blinde Kompaktierung (`W/docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde3-live-repro-usage-kompaktierung.md:14-43`). |
| Token-Usage, streamend | Null-Initialisierung im `message_start`; Finish halten; trailing usage-only-Chunk übersetzen und mergen; finales `message_delta.usage` (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:342-361`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:423-439`) | Keine SSE-Inspektion; Upstream-Bytes werden unverändert gechunkt (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`) | **Bestätigter Defekt, höchste Fix-Relevanz:** Dieses Muster ist die direkte Vorlage für den fehlenden Usage-Chunk. |
| Stop-Sequenzen / Finish-Reasons | String→Liste, Whitespace-Filter, `stop`/`length`/`tool_calls`→`end_turn`/`max_tokens`/`tool_use` (`L/litellm/llms/anthropic/chat/transformation.py:1149-1167`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1219-1226`) | Keine semantische Behandlung; Auswahl nur über `model` (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268-284`) | **Delegiert, mittel:** Invariant muss im Codex-Proxy liegen. LiteLLMs eigenes `stop_sequence=None` ist keine Vorlage für das Rekonstruieren der konkret getroffenen Sequenz (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1344-1353`). |
| Multimodal | Base64/URL→`image_url`; Dokumente; kombinierte multimodale Tool-Results (`L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:1113-1138`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:375-400`, `L/litellm/llms/anthropic/experimental_pass_through/adapters/transformation.py:418-498`) | Body bleibt semantisch unangetastet (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`) | **Delegiert, mittel:** Transparenz schützt Anthropic; GPT-Modellfähigkeit und Formatkonvertierung müssen separat abgesichert werden. |
| Fehler-Mapping | HTTP-Status/Body/Headers erhalten, Unbekanntes→500; SSE-Providerfehler und unvollständige Streams→Anthropic-`event:error` (`L/litellm/llms/anthropic/chat/handler.py:90-113`, `L/litellm/llms/anthropic/experimental_pass_through/messages/streaming_iterator.py:26-53`) | Upstream-Status/Body transparent; lokale Fehler plain text; später Fehler nur Disconnect (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-633`) | **Teilweise, mittel:** Pass-through ist gut; lokale/abgebrochene Fehler verletzen jedoch den Anthropic-Fehlervertrag. |

## Konsequenz für den späteren Fix

Die LiteLLM-Struktur spricht gegen punktuelles String-Ersetzen in beliebigen SSE-Zeilen. Benötigt wird eine **pro Request isolierte, JSON-basierte Adapter-State-Machine**. Für den akuten Usage-Fix kann sie zunächst eng auf `finish_reason` plus usage-only-Chunk begrenzt werden; Tests müssen danach aber die gemeinsame Ordnung mit Tool- und Textblöcken abdecken, weil LiteLLM genau dort zahlreiche Verlust- und Reihenfolgefehler explizit verhindert (`L/litellm/llms/anthropic/experimental_pass_through/adapters/streaming_iterator.py:450-486`).

Architektonisch sollte klar benannt werden, wo diese Semantik lebt: Der aktuelle MixRouter ist nachweislich ein loopback-only HTTP-Router mit unmittelbarem Byte-Streaming (`W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:24-33`, `W/WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:578-600`). Wird die Übersetzung dort ergänzt, ändert sich seine Verantwortung vom Router zum Protokolladapter. Alternativ kann der Codex-Proxy die vollständige Anthropic-Kompatibilität garantieren; dann braucht der MixRouter weiterhin keine doppelte Transformation, aber End-to-End-Tests müssen die in dieser Matrix aufgeführten Verträge am Router-Ausgang prüfen.
