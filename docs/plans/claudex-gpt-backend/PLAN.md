# Claudex: GPT-5.6 als Backend für Claude-Code-Sessions in WhisperM8

**Stand:** 2026-07-18 · **Status:** KERNFUNKTION UMGESETZT UND E2E-VALIDIERT — Slices 0–4 committet (`30c4661`, `12fe54f`, `204e7d8`); Härtung gemäß P0/P1-Findings noch offen.
Testsuite komplett grün; adversariales Codex-Review und native GPT-E2E-Smoke-Tests durchgeführt. Einzelne manuelle QA-Punkte bleiben in der [QA-CHECKLISTE.md](QA-CHECKLISTE.md) offen. Der vollständige 32-Agent-Review mit 24 verifizierten Findings, Priorisierung und Fix-Paketen steht in [REVIEW-2026-07-18.md](REVIEW-2026-07-18.md).
**Vorarbeit:** Recherche + End-to-End-Beweis am 2026-07-18 (siehe Memory `claudex-gpt56-in-claude-code`):
`claude --model gpt-5.6-sol` läuft über raine/claude-code-proxy (Codex-Subscription-OAuth, eigener
Keychain-Grant, koexistiert mit der Codex CLI); Modell-Mix Parent=Terra/Subagent=Sol in einer Session
per `CLAUDE_CODE_SUBAGENT_MODEL` bewiesen (CLI 2.1.214, `--allowedTools "Agent"` reicht headless).

## Ziel

1. Beim Start eines Claude-Code-Chats in WhisperM8 GPT-5.6 (Sol/Luna/Terra, weitere Proxy-Modelle)
   als Modell wählbar machen — abgerechnet über den Codex-Flat-Plan.
2. Native Claude-Code-Subagents (Agent-Tool, Workflows, Agent-Teams) in diesen Sessions auf
   GPT-Modelle routen können.
3. Kein Konflikt mit dem Claude-Account-Switcher (`ClaudeAccountProfiles`/`CLAUDE_CONFIG_DIR`)
   und den parallel laufenden Codex-Sessions.

4. **Endziel (Slice 4):** Echter Mischbetrieb — reales Fable (Anthropic-Abo) als Hauptmodell,
   GPT-5.6 als native Subagents in DERSELBEN Session, inkl. `/model`-Wechsel und Workflows,
   die Claude- und GPT-Modelle mischen.

**Zielbild (User-Klarstellung 2026-07-18): VOLLE Freiheit als Standard.** Jede Claude-Code-Session
in WhisperM8 läuft im Endzustand über den Mini-Router und hat damit gleichzeitig Zugriff auf
echte Claude-Modelle (Abo) UND GPT-Modelle (Codex-Plan): `/model`-Wechsel mid-session über beide
Welten, native Subagents/Workflows beliebig gemischt (z. B. Fable-Main + Sol-Subagents — live
bewiesen). Die Slices sind reine BAU-Reihenfolge, kein Feature-Verzicht: 0–3 liefern
Proxy-Lifecycle, Env-Injektion, Settings und Tests; Slice 4 setzt den Router obendrauf und
macht ihn zum Default. **Graceful Degradation:** ist Router oder Codex-Proxy nicht verfügbar,
startet die Session automatisch direkt gegen api.anthropic.com (heutiges Verhalten) — GPT-Wahl
ist dann temporär ausgegraut, Claude funktioniert immer.

## Architektur: Zwei Spuren + Ausbaustufe

```
Spur 1 (unverändert): Claude-Session → claude CLI → api.anthropic.com  (Account-Profil via CLAUDE_CONFIG_DIR)
Spur 2 (neu):         GPT-Session    → claude CLI → 127.0.0.1:<port> raine/claude-code-proxy → Codex-OAuth
V2 (Ausbaustufe):     Mix-Session    → claude CLI → Passthrough-Router → { claude-* → api.anthropic.com (Auth 1:1 durchgereicht),
                                                                           gpt-*    → Codex-OAuth }
```

Warum getrennte Spuren: `ANTHROPIC_BASE_URL` gilt prozessweit. Reine Claude-Sessions bleiben
proxyfrei (null neue Fehlermodi, null ToS-Fragen); reine GPT-Sessions setzen `ANTHROPIC_AUTH_TOKEN`,
wodurch das Claude-Abo nachweislich unbenutzt bleibt. Der Proxy-Login ist ein separater
OAuth-Grant — niemals `~/.codex/auth.json` mitbenutzen (Refresh-Token-Rotation, single-use).

## Slices

### Slice 0 — Proxy-Lifecycle (`ClaudeCodeProxyManager`)

Neuer Service in `Services/AgentChats/` (Test-Injection via Closures, wie üblich):

- **Binary-Auflösung** über das bestehende `AgentCommandBuilder.commandPath`-Muster
  (`claude-code-proxy` via which + Fallback-Dirs). Installation bleibt beim User
  (brew/GitHub-Release); Settings zeigen Zustand + Anleitung. Kein Bundling (Updates, Lizenz).
- **Health-Check:** TCP-Connect auf den Port + `GET /` — vor jedem GPT-Session-Launch.
- **Autostart on demand:** erster GPT-Launch startet `claude-code-proxy serve --no-monitor
  --port <fix>` als überwachten Subprocess (fixer Port aus Preferences, Default 18765;
  loopback-only ist Proxy-Default). App-Quit beendet nur selbst gestartete Proxys.
- **Auth-Zustand:** `codex auth status` geparst; Settings-Seite zeigt Account/Ablauf und führt
  den Device-Code-Login (Code + URL im UI anzeigen; Voraussetzung „Gerätecode-Autorisierung"
  in den ChatGPT-Sicherheitseinstellungen dokumentieren — Browser-PKCE scheiterte im Test).

### Slice 1 — GPT-Backend pro Session (Launch-Pfad)

- **Modell:** `AgentChatSession` hat bereits `model`/`reasoningEffort` (heute nur von Codex
  genutzt; Claude-Launches ignorieren beide). Neues optionales Feld `claudeBackendModel: String?`
  — `nil` = heutiges Verhalten (Account-Default), sonst Proxy-Modellname (`gpt-5.6-sol`, …).
  Explizites Feld statt Umdeutung von `model`, damit Migration/Equatable-Diff und der
  Codex-Pfad unberührt bleiben. Session-stabil (Resume läuft immer mit demselben Backend).
- **`AgentCommandBuilder.claudeCommand`:** wenn `claudeBackendModel` gesetzt →
  `arguments += ["--model", m]` und `environmentOverrides +=`:
  `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`, `ANTHROPIC_AUTH_TOKEN=whisperm8` (verhindert
  OAuth-Header-Leak an den Proxy), `ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.4-mini`
  (Hintergrund-Calls: Titel etc.), `CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1`,
  `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3` (Tibo-Rezept; als Preferences-Strings überschreibbar).
  Merge NACH dem Profil-Env — Account-Profil (`CLAUDE_CONFIG_DIR`) bleibt zusätzlich aktiv,
  damit Transcripts im gewohnten Profil-Root landen (Indexer/Watcher/Resume unverändert).
- **Launch-Guard:** vor dem PTY-Start Health-Check; Proxy tot → Autostart-Versuch → sonst
  klarer NSAlert („GPT-Backend nicht erreichbar — Proxy/Login in Settings prüfen").
- **UI (per E3 entschieden: Settings-Default):** KEIN per-Chat-Picker — ein globaler
  Backend-Default in den Settings bestimmt, womit neue Claude-Chats starten (Account-Default
  oder GPT-Modell); der Stempel wird bei Erstellung in die Session geschrieben und bleibt
  session-stabil (Resume/Fork erben ihn). Sidebar-/Tab-Kennzeichnung der GPT-Sessions
  (kleines Badge, dauerhaft sichtbar — kein Hover-only), damit man Alt-Sessions vom
  aktuellen Default unterscheiden kann.

### Slice 2 — Subagent-/Workflow-Modell

- Per-Session-Option `subagentModel: String?` → `CLAUDE_CODE_SUBAGENT_MODEL` im Env-Override.
  Gilt laut Doku für Subagents, Agent-Teams und Workflow-Agents.
- **Konsistenz-Regel V1:** GPT-Subagent-Modelle nur wählbar, wenn die Session selbst auf dem
  Proxy läuft (sonst ginge `gpt-*` an api.anthropic.com → Fehler). Innerhalb einer GPT-Session
  frei: z. B. Parent Terra, Subagents Sol.
- Default-Preset in den Settings (z. B. „Subagents: gpt-5.6-sol"), pro Session überschreibbar.

### Slice 3 — Settings-Seite + Tests + QA

- **Master-Schalter „GPT-Backend aktivieren" (User-Anforderung 2026-07-18):** oberster Toggle
  der Settings-Seite, Default AUS bis Setup abgeschlossen. Bei AUS gilt exakt das heutige
  Verhalten: kein Router, kein Proxy-Autostart, keine Proxy-Env — alle Claude-Sessions starten
  direkt gegen api.anthropic.com. GPT-Modellwahlen sind ausgegraut; Sessions mit GPT-Stempel
  resumen trotzdem (Stempel wird ignoriert, Transcript-JSONL ist formatgleich — sie laufen dann
  auf dem Claude-Default weiter). Der Schalter ist damit ein echter Kill-Switch für alle
  Zukunftsprobleme (ToS-Kurswechsel, Proxy-Bugs, Modell-Abkündigungen), ohne Datenverlust.
  Zusätzlich als Defaults-Override für Support-Fälle:
  `defaults write com.whisperm8.app claudeGPTBackendEnabled -bool NO`
  (gleiche Konvention wie `agentEventDrivenWatchEnabled`).
- Settings „GPT-Backend": Proxy-Status (Binary/Prozess/Auth), Port, Device-Code-Login-Flow,
  Default-Modell, Subagent-Default, Tuning-Envs, Stop/Restart-Button.
- **Unit-Tests:** `AgentCommandBuilderTests`-Erweiterung (Backend gesetzt → Args/Env exakt;
  Backend nil → byte-identisches Verhalten zu heute = Feature-Erhalt-Beweis);
  `ClaudeCodeProxyManagerTests` mit ProcessRunner-Spies (Health, Autostart, Status-Parsing).
- **Manuelle QA:** GPT-Chat starten/resumen, `/model`-Wechsel, Subagent-Spawn, Account-Profil-
  Session parallel, Codex-Session parallel (Token-Koexistenz), Proxy-Kill unter Last.

## Impact-Analyse (Feature-Erhalt)

| Bestehendes Feature | Auswirkung |
|---|---|
| Claude-Sessions ohne Backend | Keine — `claudeBackendModel == nil` durchläuft exakt den heutigen Code (testgesichert) |
| Account-Switcher (`CLAUDE_CONFIG_DIR`) | Kompatibel; Profil-Env wird gemerged, Transcript-Root unverändert; bei GPT-Sessions ist der Claude-Account nachweislich unbenutzt (`ANTHROPIC_AUTH_TOKEN` gesetzt) |
| Codex-Sessions & `whisperm8 agent`-Subagents | Unberührt; Proxy nutzt separaten OAuth-Grant (Keychain), keine Token-Kollision |
| Indexer/Runtime-Watcher/Hook-Bridge | Unverändert — Proxy-Sessions schreiben normale JSONL ins gewohnte `projects/`-Root, Hooks sind lokal |
| Resume/Fork | Backend-Stempel session-stabil, Env wird bei jedem Launch reproduziert |
| Background-Agents (`--bg`) | **V1 ausgenommen** — der Supervisor-Daemon hostet die Prozesse, Env-Vererbung ungeklärt; eigener Folgetest |

## Risiken

- **Rate Limits:** Claude-Harness ist tool-call-intensiver als Codex → Flat-Plan brennt schneller; Sol braucht Pro/Max.
- **ToS:** OpenAI toleriert demonstrativ (Codex-Lead), aber ohne Garantie — Kill-Switch ist trivial (Backend-Feld ignorieren).
- **Kompatibilität:** Codex-Reasoning-Blöcke erscheinen nicht in der Claude-UI; Bilder in Tool-Results teils `[image omitted]`; `cost`-Anzeigen sind fiktiv.
- **Proxy = neuer Single Point of Failure für GPT-Sessions** — durch Health-Check + Autostart + klare Fehler entschärft; Claude-Sessions nie betroffen.
- **WebFetch-Preflight** geht immer direkt an api.anthropic.com (bei Bedarf `skipWebFetchPreflight`).

### Slice 4 — Echter Mischbetrieb: Fable-Main + GPT-Subagents (Endziel)

Mechanik: eine Mix-Session läuft OHNE `ANTHROPIC_AUTH_TOKEN` gegen einen lokalen
**Passthrough-Router**. Die CLI sendet dann nachweislich (Smoke-Test 2026-07-18) ihren
Abo-OAuth-Header mit — der Router dispatcht pro Request nach Modellname:

- `claude-*`/`fable` → **1:1-Forward an api.anthropic.com**, eingehende Header (inkl.
  `Authorization` + `anthropic-beta`) unverändert durchgereicht. Das ist der von Anthropic
  offiziell dokumentierte Gateway-Modus („saved claude.ai login remains the active credential";
  Gateways müssen die OAuth-Capability forwarden) — Harness bleibt die echte CLI.
- `gpt-*` → Forward an den raine-Proxy (localhost), der die Codex-OAuth macht.

Session-Env: `CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-sol` (o. per-Session-Wahl) + `--model fable`
→ Fable denkt, GPT-Subagents schuften. Wichtig: die raine-eigenen `claude-*`-Namen sind KEIN
echtes Claude (Codex-Backend antwortet) — echtes Fable geht nur über den Passthrough.

Router-Optionen (Entscheidung E4): **(a)** LiteLLM (offizielles Passthrough-Tutorial existiert;
Python-Stack, bekannte Reibungen: Param-Drops, Versions-Vorsicht wegen Malware-Vorfall 1.82.7/8)
oder **(b)** eigener Mini-Router in WhisperM8 (schlank: HTTP-Server, Modellpräfix-Dispatch,
SSE-Byte-Streaming, ZERO eigene Auth-Logik — Claude-Auth kommt vom Client, Codex-Auth macht der
raine-Proxy; volle Kontrolle, testbar, kein Fremd-Stack). Vorab ein reiner Passthrough-Smoke-Test
(Mini-Python-Forwarder, eine Session, ein Subagent) zur Risiko-/Funktionsvalidierung.

**✅ Smoke-Test bestanden (2026-07-18, mit User-Freigabe):** Python-Mini-Router
(Modellpräfix-Dispatch, Header 1:1, chunked SSE-Forwarding) — eine Session mit
`--model fable` + `CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-sol`: Main-Agent lief als echtes
`claude-fable-5` über api.anthropic.com (Abo-OAuth durchgereicht, 200er), der native
Agent-Tool-Subagent als `gpt-5.6-sol` über den Codex-Proxy; `modelUsage` weist beide aus,
Utility-Calls (`claude-sonnet-5`) liefen korrekt über Anthropic. Die Slice-4-Mechanik ist
damit end-to-end validiert; der produktive Mini-Router ist reine Fleißarbeit
(Robustheit, Lifecycle, Tests), kein Forschungsrisiko mehr.

## Entscheidungen (User, 2026-07-18)

- **E1 Proxy-Verwaltung:** WhisperM8-managed Autostart. ✓
- **E2 V1-Umfang:** Foreground-PTY-Chats + native Subagents; `--bg`/Headless als Folgeschritt. ✓
- **E3 UI-Ort der Modellwahl:** Nur Settings-Default (kein per-Chat-Picker); der Settings-Default
  bestimmt das START-Modell — danach ist `/model` in der Session ohnehin frei (Router-Standard). ✓
- **E4 Mischbetrieb-Router:** Eigener Mini-Router in WhisperM8; Passthrough-Smoke-Test freigegeben. ✓

## Umsetzung

Implementierung gemäß Projektkonvention Codex-first: Slices als Codex-Subagent-Jobs
(gpt-5.6-sol, effort high) mit Claude-Review; Tests vor UI. Kein `make dev` aus der Session —
Build-Verifikation via `swift build`/`swift test`, App-Relaunch macht der User.
