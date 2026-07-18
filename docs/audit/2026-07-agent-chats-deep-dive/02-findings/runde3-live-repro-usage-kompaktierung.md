---
status: aktiv
updated: 2026-07-18
description: Live-Repro während Workflow 3 — GPT-Backend meldet usage=0, wodurch die Claude-CLI-Auto-Kompaktierung blind ist und Sessions am harten Kontextlimit sterben.
---

# Live-Repro (Runde 3): usage=0 aus dem GPT-Backend macht die Auto-Kompaktierung blind

> **Korrektur 2026-07-19 (Root Cause bewiesen, andere Session):** Die unten
> stehende Verallgemeinerung „jede lange GPT-Session stirbt" ist zu breit. Eine
> isolierte Diagnose (Traffic-Capture + TCP-Tee) hat gezeigt: Der Bug trifft nur
> den **Subagent-/SDK-Harness** der Claude-CLI — genau den Pfad, in dem meine
> Workflow-Agents liefen. **Haupt-Chat-Turns sind gesund** (115/115 mit echter
> usage). Ursache: Der raine-Proxy hartkodiert `message_start.usage` auf 0/0 in
> beiden Sendepfaden; der Main-Loop der CLI merged das finale `message_delta`
> (→ gesund), der Subagent-Harness nicht (→ 0/0). Der eigentliche Fix gehört in
> den Proxy (`message_start` vorbefüllen), **Ebene 3 im MixRouter entfällt.**
> Vollständige Beweiskette:
> [gpt-usage-kompaktierung-fix-spec.md, Abschnitt 5](../06-umsetzung/gpt-usage-kompaktierung-fix-spec.md).

Beobachtet am 2026-07-18 ~22:42 während des laufenden Workflow-3-Audits selbst —
die Audit-Agents liefen als GPT-Subagents über das neue GPT-Backend und zwei von
ihnen sind an genau dem Mechanismus gescheitert, den dieses Dokument beschreibt.
Kein hypothetisches Finding, sondern ein reproduzierter Produktionsausfall.

## Finding G-LIVE-01 (hoch): MixRouter propagiert keine Token-Usage

**Beleg (negativ, geprüft per grep):** Weder
`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift` noch
`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift` enthalten
irgendeine Erwähnung von `usage`, `input_tokens` oder `output_tokens`. Die
OpenAI-Antwort-Usage wird also nirgends in das Anthropic-Antwortformat
übersetzt; die Claude-CLI erhält für jeden GPT-Turn `usage: {input_tokens: 0,
output_tokens: 0}`.

**Beleg (Transcript des gescheiterten Agents):**
`~/.claude/projects/-Users-giulianocosta-repos-whisperm8/8b93468c-…/subagents/workflows/wf_e034fbbf-d67/agent-ac043fa7fabf87701.jsonl`
— alle 20 Assistant-Turns tragen `input_tokens: 0, output_tokens: 0`, Modell
`gpt-5.6-sol`, `attributionAgent: "gpt"`.

## Wirkungskette (beobachtet)

1. Die Claude-CLI verfolgt die Kontextauslastung ausschließlich über die
   `usage`-Felder der API-Antworten. Mit dauerhaft 0 Tokens hält sie den
   Kontext für leer.
2. Die **präventive Auto-Kompaktierung feuert deshalb nie** — der Kontext
   wächst ungebremst, bis das Upstream-Modell den Request hart ablehnt.
3. Ergebnis im Workflow: Agent `recherche:litellm` starb nach 11 Tool-Calls
   (~5m31s) mit `Prompt is too long`; die UI zeigte konsistent `0 tok`.
4. Agent `inventar:diktat` lief in denselben Zustand; dort griff die
   **Notfall-Kompaktierung nach dem Fehler** („This session is being continued
   from a previous conversation that ran out of context"), der Job musste vom
   Workflow-Runtime dennoch neu gestartet werden. Der Notfallpfad ist also
   vorhanden, aber unzuverlässig — die präventive Kompaktierung ist der
   eigentliche Vertrag.

## Folgewirkungen über die Kompaktierung hinaus

- Statusline-/`/context`-Anzeige der Kontextauslastung ist in GPT-Sessions
  immer 0 % — der User kann ein nahendes Limit nicht sehen.
- `/cost`- und jede tokenbasierte Verbrauchs-/Limit-Logik der CLI ist für
  GPT-Turns blind.
- Lange GPT-Sessions (genau der Zielanwendungsfall des Features) sind
  strukturell zum Absturz am harten Limit verurteilt; kurze Sessions
  kaschieren den Fehler.

## Fix-Skizze

Im MixRouter die OpenAI-`usage` (`prompt_tokens`/`completion_tokens`, bei
Streaming der finale `usage`-Chunk bzw. `stream_options.include_usage`) in die
Anthropic-Felder (`input_tokens`/`output_tokens`, `message_delta.usage` beim
Streaming) übersetzen; zusätzlich prüfen, ob das an die CLI gemeldete
Kontextfenster des Modells (Model-Mapping) zum realen GPT-Limit passt, damit
die Kompaktierungsschwelle stimmt. Testbar rein über die bestehende
MixRouter-Testsuite (Fake-Upstream mit Usage-Chunk → Assertion auf
Anthropic-Usage im Response/Stream).

## Einordnung

Ergänzt die Runde-3-Findings in
[runde3-gpt-backend-mixrouter.md](runde3-gpt-backend-mixrouter.md); vom
Verifikations-Refuter unabhängig zu bestätigen ist hier nur die Wirkungskette —
die Beleglage (grep-Negativbefund + Transcript) ist direkt reproduzierbar.
