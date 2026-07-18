# QA-Checkliste: GPT-Backend / Claudex (nach `make dev`)

Voraussetzung: `make dev` durch den User (Relaunch der App). Der Codex-OAuth-Login
liegt bereits im macOS-Keychain (`claude-code-proxy.codex`) — kein erneuter Login nötig.
Das Proxy-Binary muss im PATH sein (`claude-code-proxy`); ist es das nicht, zeigt die
Settings-Seite den Hinweis. Für die QA lag es im Session-Scratchpad unter
`claudex-test/raine/` — für den Dauerbetrieb per `brew`/GitHub-Release installieren.

**Review-Nachweis:** Der vollständige native GPT-Review-Workflow (32 Agents, 24 verifizierte Findings) ist in [REVIEW-2026-07-18.md](REVIEW-2026-07-18.md) dokumentiert.

## Automatisiert und empirisch validiert (2026-07-18)

- [x] Proxy `/healthz` und Router erreichbar; `gpt.md` in Main- und beiden Profil-Roots identisch.
- [x] GPT-Hauptrequest über den Router antwortet als `gpt-5.6-sol`.
- [x] Claude/Fable läuft parallel über den Anthropic-Zweig; gzip-Response-Regression ist E2E getestet.
- [x] Nativer Agent-Typ `gpt` läuft über den Router; das Session-Transcript weist `model: gpt-5.6-sol` aus.
- [x] Dynamic Workflow mit drei parallelen GPT-Steps und GPT-Verifier: 4/4 Structured Outputs korrekt.
- [x] Vollreview als Belastungstest: 32 native GPT-Agents, 377 Tool-Aufrufe, 0 Agent-Fehler.

**Reproduzierbare Evidenz:**

```bash
# Proxy
curl -s http://127.0.0.1:18765/healthz

# gzip-Regression im Anthropic-Zweig
swift test --filter testRouterDeliversPlaintextWhenUpstreamCompressesWithGzip

# Tatsächliche Modelle einer Session (Beispiel-Session des E2E-Laufs)
grep -o '"model":"[^"]*"' \
  ~/.claude-profiles/PowerUser/projects/-Users-giulianocosta-repos-whisperm8/20682a2e-1218-441e-adfb-3f35568c7286.jsonl \
  | sort | uniq -c
```

Workflow-IDs: `wf_d92a019d-d9e` (3× GPT-Fan-out + Verifier, 4/4 korrekt) und `wf_589ca51f-7aa` (Vollreview). Persistierte Evidenz:

- E2E: [Skript](artifacts/gpt-native-e2e-workflow.js) und [Roh-Journal mit vier Ergebnissen](artifacts/gpt-native-e2e-journal.jsonl). Ausführung über die Dynamic-Workflow-Runtime; das Skript gibt `{ results, verdict }` zurück und prüft drei Rechenwerte plus `ANTHROPIC_BASE_URL`.
- Vollreview: [Skript](artifacts/gpt-integration-review-workflow.js), [Roh-Journal](artifacts/gpt-integration-review-journal.jsonl) und [normalisierte Run-Summary](artifacts/gpt-integration-review-run-summary.json).

> **Modellnachweis:** Die Selbstauskunft „Welches Modell bist du?“ ist unzuverlässig, weil GPT-Subagents den Claude-Systemprompt sehen. Verlässlich sind nur die `model`-Felder im Session-JSONL beziehungsweise die vom Workflow-Harness erfassten Modelle.

## 1. Grundzustand (Kill-Switch aus = heutiges Verhalten)
- [ ] Einstellungen → „GPT-Backend": Master-Toggle ist **aus** (Default).
- [ ] Neuen Claude-Chat starten → läuft wie immer direkt gegen Anthropic (kein Proxy).
- [ ] Bestehende Claude- und Codex-Chats verhalten sich unverändert.

## 2. Proxy-Lifecycle & Login (Settings-Seite)
- [ ] Master-Toggle **an**. Status-Sektion erscheint.
- [ ] „Neu prüfen": Binary gefunden? Auth = authenticated (Account/Ablauf)?
- [ ] Ist der Proxy nicht erreichbar → „Proxy starten": WhisperM8 fährt ihn selbst hoch
      (managed Autostart), Status wird grün.
- [ ] (Optional) Falls Auth = notAuthenticated: „Mit ChatGPT-Konto verbinden" → Code + URL
      werden angezeigt; nach Bestätigung auf auth.openai.com/codex/device wird der Status grün.
      (In den ChatGPT-Sicherheitseinstellungen muss „Gerätecode-Autorisierung" an sein.)

## 3. Reine GPT-Session
- [ ] Standard-Modell leer lassen → neuer Claude-Chat startet mit dem normalen Claude-Default.
- [ ] `/model` zeigt `gpt-5.6-sol` als Custom-Option; Wechsel auf GPT funktioniert mid-session.
- [ ] `/model` zurück auf ein echtes Claude-Modell (z. B. `fable`) → Anthropic-Zweig antwortet ohne ZlibError.
- [ ] Modellwechsel im Transcript über die tatsächlichen `model`-Felder prüfen, nicht über Selbstauskunft.

## 4. Mischbetrieb (Kernziel): Fable-Main + GPT-Subagents
- [ ] Settings → „Subagent-Modell“ leer lassen (kein globaler Zwangs-Override); Standard-Modell ebenfalls leer.
- [ ] Neuen Chat starten (Hauptmodell Claude/Fable).
- [ ] Explizit den verwalteten nativen Agent-Typ `gpt` starten oder Claude eine passende GPT-Teilaufgabe delegieren lassen.
- [ ] Hauptagent bleibt Claude, Subagent läuft auf GPT-5.6; im Transcript `model: gpt-5.6-sol` prüfen.
- [ ] Optional: „Subagent-Modell“ = `gpt-5.6-sol` testen → erzwingt GPT für alle nativen Subagents und Workflows.

## 5. Kill-Switch & Graceful Degradation
- [ ] Bei laufendem GPT-Setup Master-Toggle **aus** → neue Chats gehen wieder direkt zu Anthropic;
      Proxy/Router werden gestoppt.
- [ ] Toggle an, aber Proxy killen (`pkill -f 'claude-code-proxy serve'`) und GPT-Chat starten →
      NSAlert „GPT-Backend nicht erreichbar", Chat startet trotzdem mit Claude-Standardmodell.
- [ ] Notfall-Override testbar: `defaults write com.whisperm8.app claudeGPTBackendEnabled -bool NO`.

## 6. Koexistenz
- [ ] Parallel eine echte Codex-Session in WhisperM8 laufen lassen → kein Login-Konflikt
      (Proxy nutzt eigenen OAuth-Grant, Codex CLI ihren eigenen).
- [ ] Account-Switcher (CLAUDE_CONFIG_DIR-Profil) + GPT-Session parallel → Transcripts landen
      im richtigen Profil-Root, keine Vermischung.

## Bekannte Grenzen und Review-Findings
- Chunked-Request-Uploads werden mit 411 abgelehnt (aktuelle Claude-Code-Requests nutzen Content-Length).
- Response-Streaming besitzt noch kein Backpressure; als P0 in [REVIEW-2026-07-18.md](REVIEW-2026-07-18.md#f-01--p0--hoch--confirmed) erfasst.
- Kill-Switch-Umschalten wirkt erst auf den nächsten Launch, nicht auf einen laufenden.
- GPT-Reasoning-Blöcke erscheinen nicht in der Claude-UI; GPT-Kostenanzeigen sind fiktiv
  (Abrechnung läuft real über den Codex-Flat-Plan).
- Background-GPT-Spawns, Attach-Argumente und Proxy-Lifecycle benötigen weitere Härtung; vollständige Liste und Abnahmekriterien im Review-Bericht.
