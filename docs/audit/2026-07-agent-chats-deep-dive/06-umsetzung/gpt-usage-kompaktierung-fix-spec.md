---
status: entwurf
updated: 2026-07-18
description: Fix-Spezifikation gegen G-LIVE-01 — usage=0 in GPT-Sessions macht Auto-Kompaktierung und Kontext-Anzeige blind; dreistufiger Fix (Env-Fenster, Upstream-Diagnose, Router-Fallback).
---

# Fix-Spec: Token-Usage und Auto-Kompaktierung in GPT-Sessions (G-LIVE-01)

Bezieht sich auf das Live-Repro-Finding
[runde3-live-repro-usage-kompaktierung.md](../02-findings/runde3-live-repro-usage-kompaktierung.md):
GPT-Sessions melden der Claude-CLI `usage: 0/0`, die präventive Auto-Kompaktierung
feuert nie, lange Sessions sterben am harten Upstream-Limit („Prompt is too long"),
Kontext-%-Anzeige und `/cost` sind blind. Zweimal live reproduziert während
Workflow 3 (Agents `recherche:litellm`, `inventar:diktat`).

## 1. Architektur-Ist (wichtig: wo die Übersetzung wirklich passiert)

```
claude CLI ──ANTHROPIC_BASE_URL──▶ ClaudeGPTMixRouter (in-process, REINES Byte-Passthrough)
                                        ├─ claude-* ──▶ api.anthropic.com (Auth 1:1)
                                        └─ gpt-*    ──▶ raine/claude-code-proxy (extern, Rust, ~/.local/bin, v0.1.21)
                                                             └─▶ Codex-OAuth (ChatGPT-Abo, GPT-5.6, 272k-Limit)
```

- Der MixRouter übersetzt NICHTS — kein Vorkommen von `usage`/`input_tokens` in
  `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift` und
  `ClaudeCodeProxyManager.swift` (grep-Negativbefund). Die Protokoll-Übersetzung
  liegt vollständig im externen `claude-code-proxy`.
- Der Proxy-Quellcode BESITZT ein Usage-Mapping: `parse_codex_usage`
  (`src/providers/codex/translate/reducer.rs:878-891` im Klon unter
  `scratchpad/vergleich/claude-code-proxy-src/`), `final_usage`-Weitergabe
  (`reducer.rs:261,782,833`) und ein Test beweist die Emission echter Zahlen im
  `message_delta` (`src/providers/codex/mod.rs:1001-1017`).
- Trotzdem tragen in unseren Sessions ALLE Assistant-Turns `0/0`
  (Transcript-Beleg im Live-Repro-Dokument). Der Widerspruch ist der zentrale
  Diagnosepunkt (Ebene 2).
- Zusätzlich: Das Proxy-README empfiehlt für GPT-5.6 explizit
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW=272000` und stellt
  `POST /v1/messages/count_tokens` (lokaler `gpt-tokenizer`, o200k_base)
  „für die Kompaktierungslogik von Claude Code" bereit. **WhisperM8 setzt die
  Variable nirgends** (grep über `WhisperM8/` + `Tests/` leer); die
  Env-Injektion in `AgentCommandBuilder.swift:260-292` setzt nur
  `ANTHROPIC_BASE_URL`, `ANTHROPIC_CUSTOM_MODEL_OPTION`,
  `CLAUDE_CODE_SUBAGENT_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`.

## 2. Fix in drei Ebenen (bewusst geschichtet, jede für sich regressionsarm)

### Ebene 1 — Kompaktierungsfenster deklarieren (sofort, ~20 Zeilen + Test)

In `AgentCommandBuilder` für Router-Sessions zusätzlich
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` setzen. Wert aus `AppPreferences`
(neuer Key, Default `272000` = ChatGPT-Limit für GPT-5.6 laut Proxy-README),
auf der GPT-Backend-Settings-Seite editierbar. Damit kennt die CLI das REALE
Fenster statt einer Default-Annahme fürs unbekannte Modell `gpt-5.6-sol`.

Test (Konvention: Closure-DI): `AgentCommandBuilderTests` — Router-Session
enthält die Variable mit Preferences-Wert; Nicht-Router-Session enthält sie
nicht (Regressionsschutz für reine Claude-Sessions).

Grenze dieser Ebene: Sie wirkt nur, wenn die CLI überhaupt Token zählt —
allein heilt sie usage=0 nicht, ist aber Voraussetzung für eine korrekte
Schwelle, sobald Zählung funktioniert.

### Ebene 2 — Upstream-Diagnose und -Fix (die richtige Schicht)

Der Widerspruch „Mapping vorhanden, Nullen beobachtet" ist mit einem
10-Minuten-Experiment auflösbar (curl gegen `127.0.0.1:<proxyPort>/v1/messages`
mit Mini-Request, SSE mitschneiden):

1. Emittiert der Proxy im `message_delta` echte Zahlen? → Dann liest die CLI
   die Usage evtl. nur aus `message_start` (dort 0) — Verhalten der CLI-Version
   2.1.214 verifizieren; ggf. Upstream-Issue „usage auch in message_start
   nachreichen/aktualisieren".
2. Emittiert er Nullen? → Liefert das Codex-Upstream-Response-Objekt für
   unseren Account/Endpoint keine `usage`? (`parse_codex_usage` greift auf
   `response.usage` des `response.completed`-Events; bleibt es leer, bleibt
   `final_usage` None.) → Upstream-Issue/PR bei raine/claude-code-proxy;
   installierte Version 0.1.21 gegen HEAD abgleichen, ggf. Update reicht.

Ergebnisabhängig: Update/Pin der Proxy-Version (Settings-Seite zeigt Version
bereits an — Mindestversion prüfen) oder Upstream-PR. Kein WhisperM8-Code nötig,
wenn Upstream liefert.

### Ebene 3 — Fill-if-missing im MixRouter (Fallback in unserem Code)

Nur falls/solange Ebene 2 keine echten Zahlen liefert: Der MixRouter wird für
`gpt-*`-Upstream (und NUR dort) von Byte-Passthrough auf einen leichten
SSE-Rewriter erweitert, der Usage **nur ergänzt, wenn sie fehlt oder 0 ist**
(„fill if missing" — eine später korrekt liefernde Upstream-Version gewinnt
automatisch):

- `input_tokens`-Schätzung aus der Request-Body-Größe (Bytes/4, o200k-nah) —
  liegt beim Forward (`ClaudeGPTMixRouter.ClientConnection.forward`,
  `ClaudeGPTMixRouter.swift:534`) vollständig vor, BEVOR die Antwort beginnt →
  `message_start.usage.input_tokens` kann inline ersetzt werden.
- `output_tokens`-Schätzung aus den gestreamten `content_block_delta`-Textlängen,
  ins finale `message_delta.usage` geschrieben
  (Empfang in `StreamingUpstreamTask`, `ClaudeGPTMixRouter.swift:689-756`).
- Nicht-Streaming-Antworten: JSON-`usage` direkt ersetzen, falls 0.
- Präzedenz: LiteLLM schätzt Usage lokal, wenn Provider sie nicht liefern —
  etabliertes Muster, keine Hackerei. Zweck ist der Kompaktierungs-Trigger;
  ±20 % Genauigkeit genügt, weil die Schwelle prozentual ist.
- Konkrete Vorlage für die Stream-Mechanik: LiteLLMs „Hold-and-merge"
  (Finish-Chunk zurückhalten, nachfolgenden usage-only-Chunk cache-bewusst
  übersetzen, genau EIN finales `message_delta.usage` emittieren) — im Detail
  dokumentiert in
  [proxy-muster-litellm.md](../03-vergleich/proxy-muster-litellm.md).

Anthropic-gebundener Traffic bleibt byte-identisch (expliziter Test).

Tests (bestehende `ClaudeGPTMixRouterTests`-Infrastruktur mit Fake-Upstream):
(a) Upstream sendet usage=0-Stream → Router liefert plausible Schätzwerte in
`message_start`/`message_delta`; (b) Upstream sendet echte Usage → Router
verändert NICHTS; (c) claude-*-Route → Bytes unverändert; (d) Abbruch
mitten im Stream → kein Hänger, kein kaputtes SSE.

### Validierung (alle Ebenen)

E2E-Smoke nach Rebuild: lange GPT-Session (Datei-lastige Aufgabe) erreicht die
präventive Auto-Kompaktierung statt „Prompt is too long"; Statusline/`/context`
zeigt wachsende Kontext-%; `/cost` zählt. Zusätzlich Negativprobe: reine
Claude-Session unverändert (Graceful Degradation, Kill-Switch).

## 3. Reihenfolge und Timing

1. **Jetzt:** nur diese Spec (Produktcode bleibt unangetastet, solange die
   Runde-3-Refuter die betroffenen Dateien lesen — Datei:Zeile-Stabilität).
2. **Direkt nach Abschluss der Workflow-3-Verifikationsphase:** Ebene 1 +
   Ebene-2-Diagnose (zusammen < 1 h), abhängig vom Diagnoseergebnis Ebene 3
   als eigener Slice. `swift build`/`swift test` genügen; App-Relaunch
   (`make dev`) macht der User.
3. Einordnung Roadmap: gehört sachlich zu Welle 1 (Stabilität/Datenverlust) als
   GPT-Backend-Ergänzung; blockiert nichts anderes, wird aber selbst von jeder
   langen GPT-Session gebraucht — auch von unseren eigenen Audit-Workflows.

## 4. Regressions-Leitplanken

- Reine Claude-Sessions: keinerlei Verhaltensänderung (Tests a/c oben).
- Kill-Switch (`agentEventDrivenWatchEnabled`-Analog des GPT-Backends) und
  Graceful Degradation (Router/Proxy nicht verfügbar → direkt gegen
  api.anthropic.com) bleiben unberührt.
- Ebene 3 ist strikt additiv (fill-if-missing) — niemals echte Upstream-Werte
  überschreiben.

## 5. Diagnose-Ergebnis 2026-07-19 (andere Session): Root Cause bewiesen

Die Ebene-2-Diagnose wurde mit einer isolierten Proxy-Instanz (Port 18799,
`CCP_TRAFFIC_LOG=1`, eigenes `XDG_STATE_HOME`) plus TCP-Tee zwischen CLI und
Proxy durchgeführt. **Die Annahme aus Abschnitt 1 („trotzdem tragen ALLE
Assistant-Turns 0/0") ist falsch** — der Bug ist pfadabhängig, und die
Beweiskette ist geschlossen:

| Messpunkt | Befund |
|---|---|
| Haupt-Chat-Turns (Session 20682a2e) | 115/115 mit echter usage |
| Upstream `response.completed` (Traffic-Capture, inkl. Subagent-Request) | echte usage (z. B. 56453/5) |
| Downstream-Bytes an die CLI (TCP-Tee, Verbindung `cc_entrypoint=sdk`) | echte usage im `message_delta` für ALLE Requests |
| Subagent-Transcript desselben Laufs | `input_tokens: 0, output_tokens: 0` |
| Claude-Modell-Subagents (Anthropic-Zweig) | echte usage (Haiku 18/18) |

**Root Cause:** Der Subagent-/SDK-Harness der Claude-CLI (2.1.214) übernimmt
die usage aus `message_start` und merged das finale `message_delta` NICHT
(der Main-Loop tut es). Der raine-Proxy hartkodiert `message_start.usage` auf
0/0 — in BEIDEN Sendepfaden (`live_stream.rs` `ensure_message_start` und
`stream.rs` Zeile ~55). Anthropic selbst liefert `input_tokens` bereits im
`message_start`, deshalb sind Claude-Subagents gesund. Parallellast, Router,
Transcript-Writer und `previous_response_id`-Continuation (Default aus, keine
Config-Datei vorhanden) sind als Ursachen ausgeschlossen.

**Konsequenz für die Ebenen:**

- **Ebene 1 ist umgesetzt** (2026-07-19, andere Session): Key
  `claudeGPTAutoCompactWindow` (Default 272000) + `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
  nur für GPT-gestempelte Sessions (Variable wirkt prozessweit; Misch-Sessions
  behalten bewusst die Claude-Annahme). Tests: `AgentCommandBuilderTests`
  (34 grün, Exact-Env-Pin inkl. Fenster; stempellose Router-Session pinnt die
  Abwesenheit), `PreferencesTests` (Key-Stabilität, 50 Keys).
- **Ebene 2 präzisiert:** Der Fix gehört in den raine-Proxy, aber NICHT in die
  usage-Übersetzung (die ist korrekt), sondern in `message_start`:
  `usage.input_tokens` dort mit der proxy-eigenen `count_tokens`-Heuristik
  (`src/providers/codex/count_tokens.rs`, bereits vorhanden) aus dem Request
  vorbefüllen — exakt das Verhalten des Anthropic-Originals. Quellcode-Klon
  v0.1.21 liegt bereit; kein Release nach v0.1.21, `main` ist 4 Commits voraus
  ohne usage-Fix (GPT-Recherche 2026-07-19). Upstream-PR sinnvoll; flankierend
  CLI-Issue bei Anthropic (Subagent-Harness sollte `message_delta.usage`
  mergen wie der Main-Loop).
- **Zusatzbefund (GPT-Recherche):** Zwei Tool-Abschlusspfade des Proxys
  finishen mit `usage=None` und verwerfen spätere Events
  (`finish_after_closed_completed_tool_call`, Reparatur whitespace-blockierter
  `Read`-Argumente) — zweiter, unabhängiger Fixpunkt im selben PR.
- **Ebene 3 (Router-Schätzung) entfällt** in der großen Form. Falls der
  Proxy-Patch nicht gewollt ist, wäre die minimale Alternative ein reines
  `message_start`-Rewrite im MixRouter (nur `gpt-*`, nur input-Schätzung) —
  deutlich kleiner als das gesamte fill-if-missing-Konzept.
- **Vergleich (GPT-Recherche mit Quellen):** LiteLLM/copilot-api mappen
  ebenfalls nur ins `message_delta` (hätten denselben Subagent-Bug);
  y-router emittiert Fantasiewerte; JulesMellot/openrouter-proxy und
  badlogic/lemmy schätzen lokal, wenn der Provider nichts liefert. Die
  offizielle Statusline-Doku bestätigt: Kontextstand = usage der letzten
  API-Response (`input + cache_creation + cache_read`).

**Statusline:** Das User-Skript (`~/.claude/statusline-command.sh`) liest
bereits `context_window.current_usage`/`context_window_size` und zeigt seit
2026-07-19 zusätzlich den exakten Wert (`150k/272k`). Korrekt wird die Anzeige
in GPT-Sessions automatisch mit Ebene 1 (Fenster) + Ebene-2-Fix (usage).

**Offener Randbefund:** Vereinzelte Subagent-Turns MIT echter usage (hoher
`cache_read`-Anteil) sind noch unerklärt — beide Proxy-Sendepfade hartkodieren
`message_start` auf 0/0; vermutlich Non-Streaming-Sonderfälle. Für den Fix
unerheblich.

### Nachtrag aus dem vollständigen Recherche-Bericht (2026-07-19)

1. **Das README-Rezept ist zweiteilig** — Modellname `gpt-5.6-sol[1m]` PLUS
   `CLAUDE_CODE_AUTO_COMPACT_WINDOW=272000` (der Proxy strippt `[1m]` vor dem
   Upstream). Laut offizieller Env-Doku wird `CLAUDE_CODE_AUTO_COMPACT_WINDOW`
   **auf das (angenommene) Modellfenster gedeckelt** — für das unbekannte
   `gpt-5.6-sol` nimmt die CLI womöglich 200k an, womit die 272000 wirkungslos
   gedeckelt würden. Das `[1m]`-Suffix hebt die Fenster-Annahme der CLI an,
   die Env-Variable begrenzt dann auf die realen 272k.
   **QA-Pflichtpunkt für Ebene 1:** In einer GPT-gestempelten Session
   `/context` prüfen — zeigt sie ein 200k-Fenster, muss der Session-Stempel/
   `ANTHROPIC_CUSTOM_MODEL_OPTION` auf die `[1m]`-Variante umgestellt werden.
2. **`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100)** existiert offiziell, kann nur
   FRÜHER triggern und gilt auch für Subagents — optionale Sicherheitsmarge,
   solange die Subagent-usage noch nicht gefixt ist. `DISABLE_AUTO_COMPACT`
   schaltet ab (nicht verwenden).
3. **Präzisierung der zwei Fixpunkte:** Die Tool-Finish-Fallbacks
   (`usage=None`, Events danach verworfen) erklären wire-seitige Nullen und
   träfen auch den Main-Loop — sie sind aber selten (nur gestallte/reparierte
   Tool-Streams). Der Tee-Beweis zeigt für den Standard-Subagent-Fall den
   CLI-seitigen Mechanismus (message_start wird übernommen, message_delta
   nicht gemerged). Beide Fixpunkte gehören in denselben Upstream-PR:
   (a) `message_start.usage.input_tokens` lokal vorbefüllen,
   (b) Tool-Finish-Pfade nie kommentarlos mit `usage=None` abschließen.
4. Codex Responses-API braucht kein `stream_options.include_usage` (usage ist
   Teil des terminalen `response.completed`); `store:false`/`previous_response_id`
   sind laut OpenAI-Doku KEINE Ursache fehlender usage — deckt sich mit der
   Capture-Beobachtung, dass der Upstream lieferte.
