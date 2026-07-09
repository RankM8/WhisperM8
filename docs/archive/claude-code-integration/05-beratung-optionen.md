# 05 · Beratung — Wie integrieren wir Agent View richtig in WhisperM8?

> Ziel dieser Datei: Aus dem vollen Verständnis (Files 00–04) konkrete Optionen ableiten, die wir wählen können — mit ehrlichen Pros/Cons und einer klaren Empfehlung.

## 1. Was möchten wir eigentlich erreichen?

Aus deinem Brief:
- WhisperM8 soll die Agent-View-Welt nutzen, weil das **die neue "richtige" Art ist, mehrere Claude-Code-Sessions parallel zu fahren** — Anthropic legt die UX in der TUI fest.
- Wir wollen die einzelnen **Cloud-Agents (= Background-Sessions)** auswählbar haben und perfekte UX drumherum bieten.
- Wir nutzen Claude Code **mit Subscription**, nicht mit der Managed-Agents-Cloud-API.
- Wir wollen **maximales Verständnis** vor Maximalismus in der Implementierung.

## 2. Drei Fundamental-Entscheidungen, die die Doku jetzt erlaubt

### 2.1 "Cloud Agents" sind keine Cloud — sondern lokale Background-Sessions

Die Doku ist hier eindeutig: **Agent-View-Sessions laufen auf deinem Rechner**, gehostet vom lokalen Supervisor-Daemon (`~/.claude/daemon/`). Sie sind nicht "in der Cloud". Echte Cloud-Sessions gibt es nur via [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web) (`claude --remote`), und das ist ein **anderer Code-Pfad**, der mit GitHub-Repos arbeitet — nicht mit lokalen Workspaces.

> **Implikation für WhisperM8**: Wir brauchen *keine* Cloud-API-Anbindung. Das Material liegt bereits im lokalen Dateisystem.

### 2.2 Es gibt keinen offiziellen API-Read-Pfad für die Agent-View-Liste

Anthropic dokumentiert **nicht** ein Format wie "GET /agents/sessions". Die einzigen offiziellen Inputs/Outputs sind:
- **Stream-JSON aus `claude -p`** — pro Session, läuft nur, solange der Process lebt.
- **JSONL pro Session** auf Disk — der "kalte" State.
- **Hooks** — pushen Events in jeden von dir definierten Endpunkt.
- **Die TUI** (`claude agents`) — Rendering-Layer, nichts Reines.

`~/.claude/jobs/<id>/state.json` und `~/.claude/daemon/roster.json` existieren und enthalten genau das, was die TUI rendert — sie sind aber **Implementation-Detail des Supervisors**, nicht versioniert und nicht garantiert stabil.

> **Implikation**: Wir können hier zwei Wege gehen: a) den TUI-Output rendern (was wir heute tun), b) opportunistisch die State-Files lesen (mit Risiko). Eine "saubere" API gibt es nicht.

### 2.3 `claude --bg` ist die Tür, um Background-Sessions *aus WhisperM8* zu spawnen

Eine Background-Session muss nicht in Agent-View-TUI erzeugt werden — `claude --bg "<prompt>"` aus der Shell startet sie genauso, und Stdout liefert die Short-ID:
```
backgrounded · 7c5dcf5d
```

Wenn WhisperM8 das aufruft, haben wir die Short-ID in der Hand und können danach `claude attach`, `logs`, `stop`, `respawn`, `rm` aufrufen — alles aus dem normalen Shell-Layer.

## 3. Vier Integrations-Strategien — Vergleich

Ich strukturiere die möglichen Wege von "minimaler Umbau, schneller Win" bis "deepest integration".

---

### 🅐 **Strategie A — "TUI im Tab" (heutiger Stand, polishen)**

**Was es ist**: Status quo. `claude agents` läuft in einem PTY-Tab. Nutzer arbeitet mit der TUI direkt.

**Vorteile**
- Anthropic-pflegt die UX, wir kriegen Upgrades gratis.
- Funktioniert bereits.
- Wir können sehr gut Hooks/Sidebar drumherum bauen.

**Nachteile**
- Wir haben **keine native macOS-UX** — Maus, Drag, Sidebar-Liste sind alles Anthropic-Conventions.
- Nicht in unsere Sidebar integriert: die Background-Sessions sind im TUI, nicht in unserer Session-Liste.
- Keyboard-Profil und Scroll-Hijack sind bereits ein Workaround.
- Schwer, mehrere Background-Sessions gleichzeitig vor Augen zu haben (eine TUI = ein Layout).

**Aufwand**: Minimal — wir sind schon dort.

---

### 🅑 **Strategie B — "WhisperM8 als nativer Agent-View-Replacement"**

**Was es ist**: Wir bauen die Agent-View-Liste **in Swift native** nach. Wir spawnen Background-Sessions via `claude --bg`, halten Short-IDs, rendern sie als WhisperM8-Tabs/Rows mit eigenen Status-Indikatoren. Beim Attach starten wir `claude attach <id>` in einem PTY-Tab. State-Pollen wir aus `~/.claude/jobs/*/state.json` + JSONL der Session.

**Vorteile**
- **Echte native UX** — Touch-Bar, Drag, Right-Click, Cmd+T, Cmd+W.
- Eine Session = ein Tab, wie bei normalen Claude-Chats. Konsistente Mental-Model.
- Wir können WhisperM8-spezifische Features mischen: Voice-Dictate direkt in die Background-Session schicken, Visual Attachments, Output-Modes.
- Wir bestimmen die UX-Tiefe (Resource-Monitor, Hooks-Bridge, Auto-Naming pro Background-Session).

**Nachteile**
- **`~/.claude/jobs/*` und `roster.json` sind nicht stabil** — wenn Anthropic das Format ändert, brechen wir. Mitigation: defensiv parsen, häufig validieren, Fallback "claude agents (TUI)".
- One-Line-Summary aus dem Supervisor *re-implementieren* heißt: wir müssten selbst einen Haiku-Call pro Session anstoßen (Kosten + Komplexität).
- "Needs input"-Signal: müssen wir aus PreToolUse / Notification Hooks ableiten — wir können das mit der Hook-Bridge erweitern (heute SessionStart/SessionEnd → in Zukunft alle Lifecycle-Events).
- Mehr Code, mehr Testfläche.

**Aufwand**: Mittel-Hoch. Realistisch eine 2–4-Wochen-Initiative.

---

### 🅒 **Strategie C — "Hybrid: TUI bleibt, aber wir spawnen + attachen aus Swift"**

**Was es ist**: Wir behalten den Agent-View-Tab (für Übersicht), bauen aber zusätzlich:
- Eine "+"-Aktion "Neue Background-Session" → ruft `claude --bg "<prompt>"`, parsed Short-ID.
- Neuer Tab-Type `.backgroundChat` (analog `.chat` / `.agentView`) → rendert in einem PTY mit `claude attach <id>`.
- Sidebar-Status für Background-Sessions aus den JSONLs (die wir schon indexieren).
- Lifecycle-Buttons (Stop, Respawn, RM) via Subprocess.

**Vorteile**
- Best of both: User kann zwischen TUI-Übersicht und nativer Tab-Ansicht wählen.
- Kleinerer Wurf als 🅑, größerer Impact als 🅐.
- Wir nutzen sowohl die offizielle TUI **als auch** native Lifecycle-Commands — beide sind stabile Schnittstellen.
- Keine Abhängigkeit von `~/.claude/jobs/state.json`-Format.

**Nachteile**
- Wir duplizieren Konzepte: User sieht eine Session im TUI *und* in der Sidebar (Inkonsistenz, wenn nicht sauber synced).
- Etwas Overhead in der Modellierung (zwei Hierarchien parallel).

**Aufwand**: Mittel. 1–2 Wochen für MVP.

---

### 🅓 **Strategie D — "Programmatic via Agent SDK + Daemon"**

**Was es ist**: Wir liefern in WhisperM8 einen kleinen Python/TypeScript-Sidecar-Daemon mit, der das Agent SDK lädt, MCP-Server bündelt, eigene Hooks/Skills registriert, und mit Swift per IPC kommuniziert. Background-Sessions sind dann SDK-getrieben, nicht CLI-Subprocesses.

**Vorteile**
- Vollster Programm-Zugriff: Permission-Callbacks, Tool-Approval, JSON-Stream-Events, Custom Tools.
- Wir können **eigene MCP-Tools** für WhisperM8-Funktionen (z. B. "diktiere Folge-Prompt", "füge Visual Attachment ein") als first-class Tools registrieren.
- Sub-Agents dynamisch definieren — z. B. ein "WhisperM8 Dictation Agent".

**Nachteile**
- **Massiver Architektur-Sprung**: Wir verlassen die "App ist ein Swift-Wrapper über CLI"-Welt.
- Distribution wird kompliziert: Python/Node mitausliefern, App Store / Notarisierung wird heikler.
- Wir bauen letztlich Agent View *parallel* nach und sind kein direkter Konsument der Anthropic-Innovation mehr.
- Auth: Agent SDK braucht typischerweise einen API-Key, nicht die claude.ai-Subscription. Für unsere Sub-User wäre das eine Umstellung.

**Aufwand**: Sehr hoch. Mehrwöchige Investition + ungewisser ROI.

---

## 4. Bewertung & klare Empfehlung

**Empfehlung: Strategie 🅒 (Hybrid), mit klarem Pfad zu 🅑 nach Validierung.**

Begründung:

1. **🅒 baut auf den stabilsten APIs auf** — `claude --bg`, `claude attach`, `claude logs`, `claude stop`, JSONL-Read. Alles offiziell dokumentiert, alles seit Monaten stabil.
2. **🅒 nutzt unsere bestehenden Stärken** — wir haben schon einen `AgentSessionIndexer`, `ClaudeHookBridge`, `AgentTerminalView`, `AgentSessionStore`. Nur ein neuer `AgentSessionKind.backgroundChat` und ein paar Lifecycle-Commands.
3. **🅒 hält die TUI als Backup** — wenn ein User die Anthropic-TUI bevorzugt, kann er sie weiter nutzen (das ist heute schon der Fall via `.agentView`-Kind).
4. **🅒 vermeidet die Gefahr von 🅑**, dass wir auf `~/.claude/jobs/*/state.json` setzen und uns das Format wegbricht. Erst nach Validierung würden wir das Native-Rendering ausbauen.
5. **🅓** ist für eine Swift-macOS-App in dem Maßstab Overkill — der Mehrwert von SDK-Programmability schlägt nicht die Kosten der zweiten Sprache und Verteilung.
6. **🅐 alleine ist auf Dauer zu wenig** — wir würden uns als "nur ein Terminal mit Whisper" verkürzen.

## 5. Konkreter Phasen-Plan für 🅒

### Phase 1 — Hidden-Plumbing (≈ 3 Tage)
1. Neuer `AgentSessionKind`: `.backgroundChat` (oder `.claudeBackground`).
2. Erweiterung `AgentChatSession`: zusätzliches Feld `backgroundShortID: String?`.
3. `AgentCommandBuilder` lernt zwei neue Commands:
   - **Spawn**: `claude --bg [extra-args] [--agent <name>] "<initial-prompt>"` → läuft *einmalig*, wir parsen Short-ID aus stdout, killen den Process.
   - **Attach**: `claude attach <shortID>` (in unserem PTY) als ein normaler Tab.
4. `AgentSessionStore` persistiert die Short-ID, der Indexer kann die zugehörige JSONL anhand `lastActivityAt` + `cwd` finden (haben wir bereits via `ClaudeActiveSessionResolver`).

### Phase 2 — UI für das "Dispatch & Attach"-Pattern (≈ 5 Tage)
5. "+"-Menu kriegt neuen Eintrag "Neue Background-Session" → öffnet ein Modal:
   - Provider: Claude (Codex hat kein `--bg`-Pendant).
   - Initial-Prompt (Multi-Line + Voice-Dictate).
   - Optional: Sub-Agent auswählen (aus `~/.claude/agents/` + `.claude/agents/` listen).
   - Optional: Permission-Mode.
6. Nach Submit: spawn-call, Short-ID parsen, **Tab als `.backgroundChat` öffnen mit `attach <id>` PTY**.
7. Sidebar zeigt für `.backgroundChat`-Sessions einen "BG"-Badge + Status (running/stopped/needs input) aus dem Runtime-Watcher + dem Indexer.

### Phase 3 — Lifecycle (≈ 3 Tage)
8. Context-Menu auf Background-Session:
   - "Detach (nur Tab schließen, Session läuft weiter)"
   - "In Background schicken" (`/bg`-Kommando ans PTY)
   - "Logs anzeigen" (Modal mit `claude logs <id>`)
   - "Stoppen" (`claude stop <id>`)
   - "Respawnen" (`claude respawn <id>`)
   - "Entfernen" (`claude rm <id>` + lokal löschen)
9. Beim App-Start: `claude logs <id>` für jede registrierte Short-ID prüfen — wenn 404, Session ist im Supervisor weg, wir löschen Lokal-State.

### Phase 4 — Hooks-Bridge auf Background ausweiten (≈ 2 Tage)
10. Aktuell skipt `.agentView` die Hook-Bridge. Für `.backgroundChat` aktivieren wir sie, *aber*: `--settings` wird beim `claude --bg`-Call mitgegeben. Das funktioniert, weil Background-Sessions weiterhin Settings einlesen.
11. Damit kriegen wir **Live-Status** der Background-Session (PreToolUse, Notification → "Needs input", SessionEnd) ohne den TUI-Layer zu brauchen.

### Phase 5 — Polish (≈ 1 Woche)
12. Auto-Naming + Auto-Summary funktionieren weiter via Transcript (sind provider-agnostisch).
13. Visual: BG-Badge, "Needs input"-Pulse-Animation, "Hat PR geöffnet"-Link in Tab.
14. Sub-Agent-Library-View (Read-Only) als Bonus: Liste der Agents aus `~/.claude/agents/`.

### Phase 6 — Nach Validierung optional: Schritt zu 🅑
15. Eigene "Agent-Übersichts-View" (ohne TUI) als drittes UI: Tabelle aller Background-Sessions mit One-Liner, State, Last-Activity. Liest opportunistisch `~/.claude/jobs/*/state.json` und fällt auf JSONL zurück.
16. Wir könnten den existierenden `.agentView`-TUI-Tab dann *deprecaten*.

## 6. Risiken & Mitigations

| Risiko | Mitigation |
| :----- | :--------- |
| Anthropic ändert `claude --bg` Output-Format → unser Stdout-Parser bricht | Defensiv parsen ("backgrounded · "-Prefix als Anker), Failover: nach Spawn die `roster.json` lesen und vergleichen, ob neu hinzugekommen |
| `disableAgentView` ist organisationsweit aktiv → unsere Spawns scheitern | Beim Onboarding `claude --bg --help` prüfen, sonst Background-Feature freundlich grayed out anzeigen |
| Auto-Update bricht Versionen | Wir prüfen `claude --version` und gate Features ab v2.1.139 |
| User hat `CLAUDE_CONFIG_DIR` gesetzt → Pfade ändern sich | Wir lesen `CLAUDE_CONFIG_DIR` und folgen ihm konsequent |
| Hook-Bridge skaliert nicht auf viele Background-Sessions | DispatchSource sind günstig — Anthropics Agent View skaliert auf Dutzende Sessions, unser Watcher ebenso. Bei > 50 Sessions: Throttle / Bulk-Refresh |
| Permission-Mode für Background ist `bypassPermissions` blockiert ohne Pre-Konsens | Onboarding: einmal interaktiv `claude --permission-mode bypassPermissions` ausführen lassen — kennzeichnen, dass Background-Sessions damit laufen |

## 7. Bonus: Was sich später noch lohnen könnte

- **Remote Control auch unterstützen**: Button in einem Chat → `/rc` → QR/URL anzeigen → User kann unterwegs steuern.
- **`/loop`-Patterns**: WhisperM8 könnte einen "Wiederholungs-Job"-Builder bauen, der `claude --bg "/loop 5m /check-ci"` startet.
- **Custom MCP-Server** für WhisperM8: ein Tool, das aus einer Session heraus eine Whisper-Aufnahme als Folge-Prompt zurückreicht. Liegt im Bereich Strategie 🅓, aber als isolierter MCP-Server (`.mcp.json`) installierbar, ohne dass wir den ganzen Stack umbauen.
- **Session-Vergleichs-View**: Mehrere Background-Sessions, die an demselben PR arbeiten, parallel anzeigen.
- **Auto-Bridge zwischen Diktat und Background-Session**: WhisperM8's Diktat-Hotkey kann jetzt einen Prompt direkt in eine Background-Session pasten → "while I work elsewhere, Claude arbeitet weiter".

## 8. Was du jetzt entscheiden musst

| Entscheidung | Vorgeschlagen |
| :----------- | :------------ |
| Strategie | 🅒 (Hybrid) |
| Reihenfolge | Phase 1–3 als ein "Background-Sessions"-Release, Phase 4–5 danach, Phase 6 nach Stabilitäts-Check |
| Naming im UI | "Background-Session" (technisch klar), "Hintergrund-Agent" (deutsch), oder "Cloud Agent" (Marketing — aber nicht ganz korrekt, da lokal) — ich empfehle **"Hintergrund-Agent"** weil ehrlich + DACH-tauglich |
| Soll der `.agentView`-Tab langfristig wegfallen? | Erst nach Validierung von Phase 1–5; vorher als Fallback / Power-User-Feature behalten |
| Soll Codex auch Background-Sessions kriegen? | Nein, Codex hat kein `--bg`-Pendant. Klar dokumentieren |
| Wie weit gehen wir mit Hook-Events? | Mindestens SessionStart/SessionEnd (haben wir), PreToolUse + Notification für "Needs input"-Detection ergänzen |

## 9. Eine letzte zentrale Erkenntnis

> Die Agent View ist Anthropics offizielle Antwort auf "wie verwalte ich viele Claude-Code-Sessions gleichzeitig". Aber sie ist nur eine **Sicht** auf eine Architektur, die größtenteils file-basiert und CLI-driven ist. WhisperM8 hat die Chance, eine **bessere Sicht** zu bauen — mit nativem macOS-Look, Voice-First-Eingabe, persistenten Tabs, Resource-Awareness, und einem konsistenten Sub-Agent-Library-Konzept. Wir müssen dafür **nicht** mit Anthropic-APIs sprechen, die es gar nicht gibt; wir müssen nur die existierenden, gut dokumentierten CLI-Schnittstellen und Disk-Formate sauber nutzen.

Dort liegt die strategische Position für die nächsten 6 Monate Agent-Chats-Roadmap.
