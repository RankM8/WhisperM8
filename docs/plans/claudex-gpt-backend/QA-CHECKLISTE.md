# QA-Checkliste: GPT-Backend / Claudex (nach `make dev`)

Voraussetzung: `make dev` durch den User (Relaunch der App). Der Codex-OAuth-Login
liegt bereits im macOS-Keychain (`claude-code-proxy.codex`) — kein erneuter Login nötig.
Das Proxy-Binary muss im PATH sein (`claude-code-proxy`); ist es das nicht, zeigt die
Settings-Seite den Hinweis. Für die QA lag es im Session-Scratchpad unter
`claudex-test/raine/` — für den Dauerbetrieb per `brew`/GitHub-Release installieren.

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
- [ ] Standard-Modell in Settings z. B. `gpt-5.6-sol`. Neuen Claude-Chat starten.
- [ ] Chat antwortet über GPT (Test: „Welches Modell bist du?").
- [ ] In der Session `/model gpt-5.6-luna` → Wechsel funktioniert mid-session.
- [ ] `/model` zurück auf ein echtes Claude-Modell (z. B. `opus`) → antwortet als Claude
      (Beweis: Router reicht claude-* per OAuth an Anthropic durch).

## 4. Mischbetrieb (Kernziel): Fable-Main + GPT-Subagents
- [ ] Settings → „Subagent-Modell" = `gpt-5.6-sol`; Standard-Modell leer/‌`fable`.
- [ ] Neuen Chat starten (Hauptmodell Claude/Fable).
- [ ] Aufgabe geben, die einen nativen Subagenten spawnt (Agent-Tool / Workflow).
- [ ] Hauptagent bleibt Claude, Subagent läuft auf GPT-5.6 (im Transcript/Verhalten erkennbar).

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

## Bekannte, bewusst offene Grenzen (kein Bug)
- Chunked-Request-Uploads werden mit 411 abgelehnt (Claude Code nutzt Content-Length).
- SSE-Sends ohne Backpressure-Drosselung.
- Kill-Switch-Umschalten wirkt erst auf den nächsten Launch, nicht auf einen laufenden.
- GPT-Reasoning-Blöcke erscheinen nicht in der Claude-UI; GPT-Kostenanzeigen sind fiktiv
  (Abrechnung läuft real über den Codex-Flat-Plan).
