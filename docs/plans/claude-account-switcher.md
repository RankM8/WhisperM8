# Plan: Claude-Code Account-Switcher (`ccs`)

**Stand:** 2026-07-12 · **Status:** Slice 1–4 umgesetzt (`~/.claude-profiles/ccs.zsh`, profil-fähige Statusline, WhisperM8-Settings-Tab „Claude Accounts") · **Scope:** CLI-Tool + WhisperM8-Integration

## Ziel

Mit mehreren Claude-Abos arbeiten, schnell und manuell zwischen Accounts wechseln — ohne Re-Authentifizierung — und **vor** wie **während** einer Session sehen, wie viel vom 5h-Fenster und Wochen-Limit pro Account übrig ist.

## Architektur-Entscheidung (verifiziert)

**Profile via `CLAUDE_CONFIG_DIR`, kein Credential-Swap.**

Selbst verifiziert auf claude v2.1.207/macOS (2026-07-12):

- `CLAUDE_CONFIG_DIR` isoliert den Login-Zustand vollständig — auch auf macOS. Pro Config-Dir legt Claude Code einen eigenen Keychain-Eintrag an (`Claude Code-credentials` bzw. mit Hash-Suffix, z. B. `Claude Code-credentials-ff0c143a`). Frisches Config-Dir → „Not logged in".
- Jedes Config-Dir bekommt eigene `.claude.json` (inkl. `oauthAccount`-Metadaten: E-Mail, Org, Tier — keine Secrets), `projects/`, `sessions/`.
- Der `api/oauth/usage`-Endpoint existiert im Binary (4 Vorkommen) — Datenquelle für accountübergreifende Limit-Abfragen.
- Die offizielle Statusline bekommt `rate_limits.five_hour` / `.seven_day` (`used_percentage`, `resets_at`) per stdin-JSON — ohne eigene Netz-Calls (Pro/Max, nach erster API-Response).

**Warum kein Keychain-Swap** (Ansatz von claude-swap/CCSwitcher): Refresh-Tokens rotieren (single-use); Swap-Tools brauchen deshalb Credential-Locks, atomare Writes, 30s-Cache-Handling und treffen alle laufenden Sessions global. Mit Config-Dir-Profilen entfällt diese gesamte Fehlerklasse, und parallele Sessions auf verschiedenen Accounts sind gratis möglich.

## Learnings aus Open Source

| Tool | Stars (API-verifiziert 2026-07-12) | Ansatz | Was wir übernehmen / vermeiden |
|---|---|---|---|
| [claude-swap](https://github.com/realiti4/claude-swap) | ~990, aktiv | Keychain-Swap + Usage-Dashboard + Auto-Rotation | ✅ Dashboard-UX (5h/7d-Bars, Reset-Zeiten, Aktiv-Marker), Rotations-Parametrik (Schwelle 90 %, Cooldown 5 min, Hysterese), adaptives Polling. ❌ Swap als Kernmechanismus |
| [cc-switch](https://github.com/farion1231/cc-switch) | ~116 000 | Desktop-GUI, primär Provider-/API-Config-Switching | Anderes Problem (API-Provider statt Abo-Accounts); Lehre: Ein-Klick-UX, GUI-Polish |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | ~8 400 | Usage-Monitoring + Prognosen | Prognose-/Warn-UX für Limit-Anzeige |
| [CCSwitcher](https://github.com/XueshiQiao/CCSwitcher) | ~150 | Menübar, atomarer Keychain+`.claude.json`-Swap | ❌ Anti-Pattern für unseren Zweck (global, rotationsanfällig) |

## Slices

### Slice 1 — Profil-Kern (`ccs`-CLI)

- Layout: `~/.claude-profiles/<name>/` pro Zusatz-Account; `~/.claude` bleibt unangetastet als Profil `main`; `~/.claude-profiles/.active` (eine Zeile).
- zsh-Funktion `ccs` + Loader-Block in `~/.zshrc`:
  - `ccs add <name>` — Dir anlegen, Shared-Symlinks setzen, `CLAUDE_CONFIG_DIR=… claude /login` (einmalig)
  - `ccs use <name>` — `.active` schreiben + aktuelle Shell exportieren (`main` = unset)
  - `ccs run <name> [args…]` — Einmal-Aufruf ohne Umschalten
  - `ccs list` / `ccs current` — Profile + E-Mail/Org aus `oauthAccount`
  - `ccs remove <name>` — Dir löschen (Keychain-Eintrag-Hinweis ausgeben)
- Shared per Symlink ins Profil: `settings.json`, `keybindings.json`, `commands/`, `agents/`, `skills/`, `plugins/`, globales `CLAUDE.md`. Getrennt: Credentials, `projects/`, `sessions/`, `history.jsonl`.
- **Akzeptanz:** Wechsel < 1 s ohne Login; zwei Terminals gleichzeitig auf zwei Accounts; laufende Sessions bleiben von `ccs use` unberührt.

### Slice 2 — Limits in der Session (Statusline)

- Statusline-Skript (in der geteilten `settings.json` → gilt automatisch für alle Profile): liest stdin-JSON, rendert Profilname + `rate_limits`:
  `firma │ 5h ▓▓░░ 34 % → 16:00 │ Wo 61 % → Mi`
- Profilname aus `CLAUDE_CONFIG_DIR` ableiten (leer = `main`).
- Nebenprodukt: Skript schreibt den letzten `rate_limits`-Stand als Snapshot nach `<profil>/usage-snapshot.json` → Offline-Datenquelle für Slice 3.
- **Akzeptanz:** Nach der ersten Antwort einer Session sind 5h-/Wochen-Stand + Account sichtbar (Pro/Max-Feld, offiziell dokumentiert).

### Slice 3 — `ccs status`: alle Accounts auf einen Blick

Der Kern des „manuell steuern"-Wunsches: **vor** dem Start sehen, welcher Account Luft hat.

- Pro Profil: Access-Token aus dem Keychain lesen (`security find-generic-password … -w`, Service-Name je Profil), `GET https://api.anthropic.com/api/oauth/usage`.
- Fallback-Kette (Endpoint ist inoffiziell): Live-Abfrage → Snapshot aus Slice 2 (mit Alter) → „unbekannt".
- Ausgabe: Tabelle Profil · E-Mail · 5h % · Reset · Woche % · Reset · Aktiv-Marker.
- **Akzeptanz:** Ein Befehl zeigt alle Abos mit Rest-Kontingent; bei Endpoint-Ausfall degradiert die Anzeige sichtbar statt zu brechen.

### Slice 4 — WhisperM8-Integration ✅ (umgesetzt 2026-07-12)

**Umsetzung: Settings-first (User-Entscheidung), kein Profil-Picker im Session-Start-Flow.**

- **Settings → Agent Chats → „Claude Accounts"** (`AgentChatsClaudeAccountsTab`): Übersicht aller Profile (E-Mail/Org, Login-Status, Usage-Snapshot aus dem Statusline-Cache), „Set Active" (schreibt `.active` — dieselbe Datei wie `ccs use`), „Create & Log in…" (legt Profil + Shared-Symlinks an, öffnet Terminal via `login.command` für den einmaligen Browser-Login), „Log in…"/„Remove…" pro Profil.
- **Service `ClaudeAccountProfiles`** (Services/AgentChats): Discovery, aktives Profil, `environmentOverrides(forProfile:)` (`CLAUDE_CONFIG_DIR`), `claudeProjectsRoots()`, `profileName(forTranscriptPath:)`, `createProfile` — dateibasiert, SSoT geteilt mit dem `ccs`-CLI.
- **Session-Stempel `claudeProfileName`** auf `AgentChatSession` (persistiert): beim Erstellen aus dem aktiven Profil gesetzt, Fork erbt von der Quelle, Auto-Import taggt aus dem Transcript-Root. **Resume läuft immer unter dem Config-Dir der Session-Entstehung** — nie unter dem gerade aktiven Profil.
- **Env-Injektion**: `AgentLaunchCommand.environmentOverrides` → PTY-Spawn merged sie über das `LoginShellEnvironment` (`AgentTerminalView.start()`). Nur `claude`-Launches; Codex nie.
- **Multi-Root**: `ClaudeSessionIndexer` (alle `projects/`-Roots), `AgentTranscriptLocator.locateClaude` (Root-Kaskade), `AgentDirectoryEventMonitor` (watcht `~/.claude-profiles` als Ganzes, Filter lässt nur Transcript-JSONL durch — `history.jsonl` etc. triggern keine Scans).
- **Bewusste v1-Grenzen**: Background-Agents (`claude --bg`) laufen immer über main (Jobs-/Daemon-Multi-Root wäre ein eigener Slice); Auto-Namer nutzt main-Quota; kein Account-Badge an Tab/Sidebar-Rows (Folge-Slice); Auto-Failover bei Rate-Limit weiterhin offen.
- Tests: `ClaudeAccountProfilesTests` (14), Builder-Env-Injektion (3), FSEvents-Filter aktualisiert.

## Risiken & Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| `api/oauth/usage` inoffiziell, kann sich ändern | Fallback auf Statusline-Snapshot; Statusline-Feld selbst ist offiziell dokumentiert |
| Keychain-Zugriff durch `ccs status` löst Abfrage-Dialog aus | Einmal „Immer erlauben" für `security`; Fehler sauber abfangen |
| `rate_limits` erst nach erster API-Response, nur Pro/Max | Bekannte Einschränkung, in Anzeige kennzeichnen („noch keine Daten") |
| Geteilte `settings.json` bei parallelen Profilen (last-write-wins) | Akzeptiert — Settings-Writes sind selten |
| Einmalkosten pro Profil: `/login`, Onboarding, Trust-Dialog pro Projekt | Bewusste Einmalkosten, in `ccs add` als Hinweise ausgeben |
| Falscher Account aktiv → teuerster Bedienfehler | Statusline (Slice 2) + Prompt-Indikator wenn ≠ `main` |

## Quellen

- Statusline-`rate_limits` offiziell: [code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline), Praxis-Guide: [Gist (jtbr)](https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b), Feature-Historie: [Issue #20636](https://github.com/anthropics/claude-code/issues/20636)
- Fertige Statusline mit 5h/Wo-Anzeige: [ohugonnot/claude-code-statusline](https://github.com/ohugonnot/claude-code-statusline)
- Multi-Account-Feature-Request (offen): [Issue #44687](https://github.com/anthropics/claude-code/issues/44687)
