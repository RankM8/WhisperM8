---
status: S1–S5 umgesetzt (08.10.2026), S6–S8 (Voice-Callouts) offen
stand: 2026-10-08
---

# WhisperM8-Plugin mit Jarvis-Board

Ein Claude-Code-Plugin `whisperm8` bündelt alle Agent-Skills der App und
bringt als erste Mod ein **Jarvis-Board** mit: eine immer sichtbare Übersicht
der Chats, die Jarvis gerade aktiv betreut, mit Ampel, Auftrag und nächstem
Schritt. Das Board erscheint nur, wenn Jarvis läuft, und lässt sich jederzeit
ausschalten.

## Entscheidungen des Users (08.10.2026)

| Frage | Entscheidung |
|---|---|
| Wer bestimmt, was auf dem Board steht? | Jarvis selbst über ein eigenes Tool. Die übrigen Sessions erscheinen nicht. |
| Wo liegt die Liste? | In der App, gepflegt über neue CLI-Befehle `whisperm8 chats board …`, nicht in einer Datei der Mod |
| Anzeige | Band über dem Prompt (immer), Panel auf `/board` (Details, Buttons). Keine Statuszeile (siehe „Was sich am Plan ändert“) |
| Wecken | Toast und Ton, wenn ein Board-Chat auf den User wartet oder fertig ist. Zusätzlich reiht die Mod einen Prompt bei Jarvis ein. |
| Verpackung | **Ein** Plugin `whisperm8` mit allen Skills und Mods; der Namensraum (`/whisperm8:jarvis`) ist in Ordnung |
| Vorgehen | Erst dieser Plan, dann Freigabe zum Bau |

## Ist-Stand (geprüft am 08.10.2026)

- **Skills:** `scripts/sync-skills.sh` und `CLISkillExporter` kopieren fünf
  Skills aus `WhisperM8/Resources/` nach `~/.claude/skills/<name>`, mit
  Install-Stempel `.whisperm8-state.json`. Die Skills sind `whisperm8-transcription`,
  `codex-subagent`, `whisperm8-chats`, `gpt-coworker` und `gpt-workflow`. Die Profile unter
  `~/.claude-profiles/*/skills` sind Symlinks auf `~/.claude/skills`, es gibt
  also nur eine Kopie.
- **`jarvis` ist nicht Teil der App.** Der Skill liegt nur lose in
  `~/.claude/skills/jarvis/SKILL.md`, ohne Stempel, ohne Repo und ohne Versionierung.
- **CLI-Bausteine für das Board gibt es schon:**
  - `chats snapshot` (`wm8.overview/1`): 1.484 Bytes, 0,39 s
  - `overview --json`: 920 KB, 0,7–0,9 s, für 928 Sessions
  - `chats since --cursor` liefert Änderungen seit einem Cursor, `gap: true` erzwingt einen frischen Snapshot.
  - `chats watch` liefert dieselben Ereignisse als NDJSON-Strom, ausdrücklich für Sidecars.
- **Plugin-Manager:** Das Audit vom Juli
  (`docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde4-plugin-manager.md`)
  beschreibt `ClaudePluginCLI`. Im heutigen Code gibt es die Datei nicht mehr.
- **Vorbild Mod:** Das Outreach-Plugin (`RankM8/outreach-plugins`,
  `plugins/outreach/hooks/register.tsx`) zeichnet Lead-Läufe als Band über dem
  Prompt. Es nutzt Atome in `$.state`, fragt alle 20 s ab und lässt sich mit
  `/outreach-status zu|auf` einklappen.

## Was eine Mod kann (Claude Code 2.1.294, Typen der Mod-Engine)

| Baustein | Fakt | Nutzen hier |
|---|---|---|
| `$.tool.register` | Tool `mcp__whisperm8__<name>`; mit `isDeferred: false` steht es ab Turn 1 in der Liste | Jarvis pflegt damit das Board |
| `skill.prompt` | Feuert, wenn ein Skill expandiert wird (`/name`, Skill-Tool, Preload); ein Matcher auf den Skill ist möglich | Aktiviert das Board sicher beim Start von Jarvis |
| `$.env.get` | Liest die Umgebung, z. B. `WHISPERM8_SESSION_ID` | Die Mod weiß, ob sie in der Jarvis-Session läuft |
| `$.process.spawn` | Ein Kindprozess für die ganze Session ist ein dokumentiertes Muster (Schleife aus `session.start`, endet mit dem Kind oder dem Modul) | Hört auf `chats watch`, keine Abfrage im Takt |
| `$.process.run` | Einmaliger Befehl, 30 s Standard-Timeout, höchstens 10 min | `snapshot`, `board`, `workspace add/open` |
| `AbovePrompt` | Band über dem Prompt, bei jeder Breite | Die Übersicht, die immer sichtbar ist |
| `$.ui.open` (Pane) | Seitenleiste nur im Vollbild-Layout ab 110 Spalten, sonst über dem Prompt. Öffnet die Mod es ungefragt, braucht es ab 144 Spalten (110, wenn der User es schon einmal geöffnet hat). | Detailansicht nur auf Zuruf |
| `$.ui.status` / `toast` / `$.audio.play` | Statuszeile, Benachrichtigung, Ton | Ampel-Zähler, Hinweis bei Ereignissen |
| `$.prompt.submit` | Reiht einen Prompt ein, der einen eigenen Turn startet, sobald die Session frei ist | Jarvis wecken |
| `$.state` / `$.store` | Werte der Session, die ein Neuladen überleben / Werte über Sessions hinweg (4 MiB) | Nur für die Anzeige. Die Wahrheit liegt in der App. |

## Architektur

### 1. Plugin `whisperm8`

```
whisperm8/                         (Quelle: WhisperM8/Resources/claude-plugin/)
├── .claude-plugin/plugin.json     name "whisperm8", version = App-Version, types
├── skills/
│   ├── whisperm8-chats/SKILL.md
│   ├── jarvis/SKILL.md            neu im Repo (heute nur lose in ~/.claude/skills)
│   ├── codex-subagent/…           inkl. references/
│   ├── gpt-coworker/SKILL.md
│   ├── gpt-workflow/…             inkl. examples/
│   └── whisperm8-transcription/SKILL.md
├── hooks/hooks.json               { "modules": ["./register.tsx"] }
├── hooks/register.tsx             Jarvis-Board (weitere Mods als eigene Dateien, importiert)
├── types/index.d.ts               PluginState-Vertrag des Boards
└── hooks/*.test.ts                `claude plugin test`
```

### 2. Verteilung

**Empfohlen: Die App setzt `CLAUDE_CODE_PLUGIN_DIRS` beim Start jeder
Session.** Die App startet jede Claude-Session selbst im PTY. Sie legt den
Plugin-Ordner aus dem Bundle unter
`~/Library/Application Support/WhisperM8/claude-plugin/whisperm8/` ab und
übergibt diesen Pfad in der Umgebung des PTY. So ist das Plugin in jedem Profil
geladen, ohne `claude plugin install`, und hat immer den Stand der App. Ein
Update der App bedeutet ein Update des Plugins.

- Sessions außerhalb der App sehen das Plugin nicht. Das ist vertretbar, weil
  die `whisperm8`-CLI für die Handeln-Befehle ohnehin die laufende App braucht.
  Später optional: der Plugin-Ordner wird als lokaler Marketplace eingebunden
  und per `claude plugin install` installiert, für Terminals ohne App.
- **Migration:** Beim ersten Start mit Plugin räumt die App die alten Kopien in
  `~/.claude/skills/` weg, sonst gibt es jeden Skill doppelt (als `jarvis` und
  `whisperm8:jarvis`). Entfernt wird nur, was laut Stempel unverändert ist.
  `jarvis` hat keinen Stempel; er wird vorher nach
  `~/.claude/skills/.whisperm8-backup/` gesichert. Das Statusline-Skript
  bleibt, wo es ist.
- Kill-Switch analog zu den übrigen: `defaults write com.whisperm8.app
  claudePluginEnabled -bool NO`. Dann setzt die App die Variable nicht mehr und
  kopiert wieder die Skills.

**Zu verifizieren vor dem Bau:**
- Lädt Claude Code ein Plugin aus `CLAUDE_CODE_PLUGIN_DIRS` in der PTY-Session wie `--plugin-dir`?
- Wie heißen dessen Skills (`whisperm8:jarvis` oder `whisperm8@inline`)?
- Wird der Ordner überwacht?

### 3. Board in der App (`whisperm8 chats board`)

Die App ist der einzige Schreiber, wie beim Workspace. Lesen geht direkt von
der Platte.

```
BoardEntry {
  sessionID, owner            # owner = WHISPERM8_SESSION_ID des Jarvis
  light: needsYou | running | done | parked
  mission                     # eine Zeile: was der Chat tut
  needs                       # was er von wem braucht ("Entscheidung Opener-Schluss")
  next                        # nächster Schritt
  updatedAt
}
Board { owner, isActive, entries[] }    # eines je Jarvis-Session
```

| Befehl | Zweck |
|---|---|
| `chats board [--owner @self] [--json]` | Board lesen, auch bei geschlossener App |
| `chats board set <ref> --light … --mission … --needs … --next …` | Eintrag anlegen oder ändern |
| `chats board remove <ref>` / `chats board clear` | Eintrag oder alles entfernen |
| `chats board activate` / `deactivate` | Board der aufrufenden Session ein- oder ausschalten |

Jede Änderung am Board ist ein Ereignis im Journal. `since` und `watch`
liefern sie mit, die Mod braucht also keinen zweiten Kanal. Ablage:
`~/Library/Application Support/WhisperM8/jarvis-board.json`. Das Board hängt
an keinem Claude-Profil und überlebt deshalb einen Kontowechsel. Später kann
die App dasselbe Board auch selbst anzeigen.

### 4. Die Mod

**An und Aus.** Ausgeschaltet zeichnet die Mod kein Band, startet keinen
Prozess und bietet kein Tool an. In jeder Session, die nicht Jarvis ist,
kostet sie also nichts.
- **Automatisch:** Ein Hook auf `skill.prompt` für `whisperm8:jarvis` ruft
  `chats board activate` auf. Das hängt nicht daran, dass das Modell es tut.
- **Durch das Modell:** Tool `mcp__whisperm8__board` mit
  `set | remove | activate | deactivate`.
- **Durch den User:** `/board an | aus | zu | auf`.
- **Nach einem Neustart:** Die Mod liest beim `session.start` das Board.
  Gehört eines zu dieser `WHISPERM8_SESSION_ID` und ist es aktiv, ist das Band
  sofort wieder da.

**Live-Status.** Ein Kindprozess `chats watch --cursor <c>` für die ganze
Session, gefiltert auf die Refs des Boards. Bei `gap: true` oder wenn der Strom
endet: `snapshot` holen und neu ansetzen. Fallback: alle 30 s `since`.

**Anzeige.**
- **Band:** eine Zeile je Board-Chat. Sie zeigt Ampel-Symbol, Name mit Kurz-Ref, `needs` bzw. `next` und „seit 4 min“. Einklappbar auf eine Summenzeile.
- **Panel (`/board`):** Zeigt alle Felder und die Warteschlange je Chat. Buttons:
  - „In den Workspace holen“: `chats workspace add` + `workspace open --slot`. Nie `chats open`, so verlangt es der Jarvis-Skill.
  - „Jarvis fragen“: `$.prompt.fill` mit „Stand zu <Name>?“.
- **Statuszeile:** entfallen (08.10.2026). Claude Code setzt „⚠“ vor jede Plugin-Statuszeile; sie sah nach einer Warnung aus und wiederholte nur das Band.

**Wecken.** Wechselt ein Board-Chat auf `needsInput` oder `turnDone`, kommen
Toast und Ton. Dazu reiht `$.prompt.submit` bei Jarvis ein:
`[Board] <Name> (<ref>): wartet auf dich | fertig – prüfen, Board
nachführen`. Höchstens einmal je Chat und Zustand, mit Entprellung. Über
`userConfig` lässt sich einstellen: `wecken: turn | toast | aus`, Standard
`turn`. Das ersetzt den Watch-Befehl im Hintergrund, den der Jarvis-Skill
heute verlangt.

**Andere Sessions.** Optional, Slice 4: Ein betreuter Chat zeigt eine einzige
dezente Zeile „Betreut von Jarvis: <mission>“.

### 5. Anpassungen am Skill `jarvis`

- **Neuer Abschnitt „Board“:**
  - Nur aktiv betreute Chats kommen auf das Board.
  - Die Felder `mission`, `needs` und `next` werden nach jedem verifizierten Ereignis nachgeführt.
  - Fertig gemeldete Chats bleiben mit Ampel `done` stehen, bis der User sie zur Kenntnis genommen hat.
- **Watch-Disziplin:** Ist das Board aktiv, entfällt der Watch-Befehl im Hintergrund, denn das Wecken übernimmt die Mod. Die Pflicht zur Verifikation bleibt.
- **Aktiv-Workspace:** bleibt die Klick-Ansicht für „braucht dich jetzt“. Das Board ist die Übersicht, der Workspace der Arbeitsplatz.

### 6. Zweite Mod: Voice-Callouts

**Ziel.** Claude arbeitet wie immer. Wenn es eine Ansage für nötig hält,
spricht es am Ende des Turns eine kurze Zusammenfassung aus. Das gilt für
Jarvis immer und für jede andere Session, sobald der User den Callout-Skill
lädt.

**Ablauf.**

```
Skill whisperm8:callout (oder whisperm8:jarvis)
  → Hook skill.prompt schaltet den Modus der Session an
  → Claude ruft am Turn-Ende mcp__whisperm8__speak({ text })
  → Mod: whisperm8 speak --from @self "<text>"   (kehrt sofort zurück)
  → App: Warteschlange → Stimme
```

**Skill `whisperm8:callout`.** Er heißt bewusst nicht `voice`, denn Claude
Code hat ein eingebautes `/voice` für das Diktat. `jarvis` lädt ihn mit.
- **Wann sprechen:** wenn der Turn auf den User wartet (Entscheidung,
  Freigabe), wenn eine längere Aufgabe fertig ist, wenn Claude festhängt.
- **Wann schweigen:** bei Rückfragen mitten im Dialog, bei kurzen Antworten,
  die der User ohnehin liest.
- **Wie:** höchstens zwei Sätze auf Deutsch. Keine Pfade, kein Code, keine
  IDs. Den Namen des Chats nennt die App, nicht das Modell.

**Mod `callout.tsx`** (neben `register.tsx`, von dort importiert).
- **An und Aus:** Der Hook `skill.prompt` mit den vollen Namen
  `whisperm8:callout` und `whisperm8:jarvis` schaltet den Modus an. Der
  Zustand liegt in `$.state` und überlebt so ein Neuladen. Zusätzlich gibt es
  den Befehl `/callout an | aus`.
- **Tool `speak`:** Es ist nur bei aktivem Modus angeboten, siehe offener
  Punkt 5. Es übergibt den Text per `$.process.run` an die App und wartet
  nicht auf die Ausgabe. Der Turn blockiert also nicht.
- **Rückmeldung:** Ein `toast` „🔊 vorgelesen“. Hat die App stumm geschaltet,
  meldet die Mod „stumm, nicht vorgelesen“.

**App: `whisperm8 speak` und `SpeechCalloutCenter`.** Die App spricht, nicht
die Mod. Nur sie sieht alle Sessions und den Zustand des Diktats.
- **Socket-Befehl `speak`:** Er geht wie `send` über den `AgentControlServer`.
  Die Identität kommt aus `WHISPERM8_SESSION_ID` mit Token. Die App stellt den
  Namen des Chats voran: „Jarvis: …“.
- **Eine Warteschlange für alle Sessions:** Es spricht nie mehr als ein Chat
  gleichzeitig.
- **Nie während einer Aufnahme:** Läuft das Diktat, hält die App die Ansage
  zurück und spricht sie danach. Das Mikrofon würde sonst die eigene Ansage
  aufnehmen.
- **Bremsen:** eine Höchstlänge, höchstens eine Ansage je Session in einem
  kurzen Zeitfenster (Entprellung), ein Stumm-Schalter in der Menüleiste.
- **Kill-Switch:** `defaults write com.whisperm8.app speechCalloutsEnabled -bool NO`.
- **Codex-Chats:** Sie haben keine Mods, können aber `whisperm8 speak` per
  Skill direkt aufrufen. Dieselbe App-Seite reicht.

**Stimme.** Ein Protokoll `SpeechCalloutEngine` mit zwei Umsetzungen:

1. **Systemstimme** (`AVSpeechSynthesizer`, eine deutsche Premium-Stimme).
   Sie ist lokal, kostenlos und sofort verfügbar. Sie ist der Standard und
   der Rückfall.
2. **ChatGPT-Abo-Stimme über Codex Realtime.** Sie klingt deutlich
   natürlicher. Der Spike unten belegt, dass sie mit dem ChatGPT-Login geht.
   Sie ist aufwendiger, deshalb kommt sie als eigener Slice.

Es gibt **keinen** Weg über den `claude-code-proxy`. Er kennt weder
Sprachausgabe noch eingehende WebSocket-Verbindungen. Sein
Transkriptions-Endpoint ist nur die Gegenrichtung.

#### Spike-Ergebnis: Sprachausgabe über Codex Realtime (08.10.2026)

Wegwerf-Client in Python (aiortc) außerhalb des Repos. Er steuerte
`codex app-server` (Codex CLI 0.160.1) über stdio. Ablauf: `initialize` mit
`experimentalApi`, `thread/start` (ephemeral, read-only), dann
`thread/realtime/start` und `thread/realtime/appendSpeech` mit
Ausgabe-Modalität `audio`.

| # | Frage | Ergebnis | Beleg |
|---|---|---|---|
| 1 | Websocket-Transport mit ChatGPT-Login? | **Nein.** | `thread/realtime/error`: „realtime conversation requires API key auth“ |
| 2 | WebRTC mit ChatGPT-Login, Standardversion? | **Nein.** | Der Call geht an `chatgpt.com/backend-api/codex/realtime/calls`. Er scheitert mit „AVAS requires OpenAI-Alpha: quicksilver=v2.“ |
| 3 | WebRTC mit `version: "v3"`? | **belegt** | `thread/realtime/started` (v3) nach ~5,6 s, SDP-Answer kommt, die Audiospur kommt an |
| 4 | Spricht `appendSpeech` den Text? | **belegt, frei formuliert** | Die erste Transcript-Delta kam 0,65 s nach `appendSpeech`, ~8 s Sprache für drei Sätze. Die Kontroll-Transkription der WAV ergab: „Kilian, kleines Update, der Chatlist hier ist durch, alle Tests sind grün. Der Opener Chat wartet noch auf deinen Schlusssatz.“ |
| 5 | Format | belegt | Opus über RTP, aiortc liefert 48 kHz stereo. Parallel liefert der App-Server `thread/realtime/transcript/delta` und `…/done` mit dem gesprochenen Text. |
| 6 | Stimmen | belegt | `thread/realtime/listVoices`: v1 `juniper … cove` (Standard `cove`), v2 `alloy … cedar` (Standard `marin`) |
| 7 | Nebenwirkungen | keine gesehen | Es wurde kein Codex-Turn gestartet und kein Mikrofon genutzt (der Client sendet Stille). Nach `stop` blieb kein `app-server` übrig. |

**Was daraus folgt.**

- **Fakt:** Das Modell liest nicht wörtlich vor. Es formuliert um und hat
  einen Namen ergänzt, den der Text nicht enthielt. Ob `prompt` oder
  `realtimeStartInstructions` es auf wörtliches Vorlesen festlegen, ist nicht
  getestet.
- **Fakt:** Der Aufbau einer Session dauert ~6 s, jede Ansage danach unter
  1 s. Bei aktivem Callout-Modus hält die App deshalb eine Session warm. Ob
  eine offene Session Kontingent des Abos verbraucht, ist offen.
- **Fakt:** Die API ist als EXPERIMENTAL markiert. Die nötige Version hat sich
  schon einmal geändert (v2 → v3 für AVAS).
- **Fakt:** macOS bringt keinen WebRTC-Stack mit. Die App braucht dafür ein
  Binär-Paket (WebRTC.framework über SwiftPM) mit Größe und
  Pflegeaufwand. Alternative: Codex' eigener Helfer `codex-voice-host` im
  Codex-Repo. Laut seiner README ist er noch nicht ausgeliefert („does not
  enable voice in the TUI“). Ihn zu beobachten lohnt sich.
- **Vermutung:** Die Nutzung zählt gegen die Voice-Limits des ChatGPT-Abos
  wie `/voice` in der TUI. Nicht geprüft.

## Slices

| # | Inhalt | Ergebnis |
|---|---|---|
| S1 | Plugin-Ordner im Bundle; `jarvis` ins Repo; Verteilung über `CLAUDE_CODE_PLUGIN_DIRS`; Migration der alten Kopien mit Backup | Alle Skills kommen aus einem Plugin, in allen Profilen |
| S2 | `chats board` mit Datenmodell, Socket-Befehlen, Journal-Ereignissen und Tests | Jarvis kann das Board per CLI pflegen |
| S3 | Mod nur lesend: Aktivierung, `watch`-Strom, Band, Panel, Statuszeile, `/board` | Board sichtbar, nur in der Jarvis-Session |
| S4 | Wecken (Toast, Ton, `prompt.submit`), Buttons, Zeile in betreuten Chats | Jarvis wird ereignisgesteuert |
| S5 | Skill `jarvis` und `whisperm8-chats` nachziehen, Feature-Doku | Arbeitsweise passt zur Mod |
| S6 | App: `whisperm8 speak`, `SpeechCalloutCenter` (Warteschlange, Sperre während Aufnahme, Stumm-Schalter, Kill-Switch), Systemstimme, Tests. Unabhängig vom Plugin baubar. | Jede Session (auch Codex) kann sprechen |
| S7 | Skill `whisperm8:callout`, Mod `callout.tsx` mit Tool `speak` und `/callout`, Anbindung an `jarvis` | Claude spricht bei Bedarf am Turn-Ende |
| S8 | ChatGPT-Abo-Stimme: Spike in Swift (WebRTC-Paket oder `codex-voice-host`), warme Session, wörtliches Vorlesen | Natürliche Stimme ohne API-Key |

## Offene Punkte

1. **Breite im Grid:** Jarvis sitzt im letzten Slot. Dort wird das Panel
   vermutlich nie zur Seitenleiste, sondern erscheint über dem Prompt. Deshalb
   ist das Band die tragende Anzeige. Ob die PTY-Sessions das Vollbild-Layout
   von Claude Code nutzen, ist am echten Grid zu messen.
2. **Mehrere Jarvis-Sessions:** Je Session gibt es ein eigenes Board (`owner`).
   Soll ein Chat auf zwei Boards stehen dürfen? Vorschlag: ja, ein Hinweis zeigt
   den anderen Besitzer.
3. **Kosten des Weckens:** Jedes Wecken ist ein Turn von Jarvis. Die
   Entprellung muss verhindern, dass ein flackernder Chat Jarvis im Minutentakt
   weckt.
4. **Sessions außerhalb der App:** Ist ein Marketplace für Terminals ohne App nötig?
5. **Tool nur bei aktivem Modus:** Lässt sich ein per `$.tool.register`
   angelegtes Tool je Session ein- und ausblenden? Der Prototyp hat nur
   `isDeferred: false` geprüft. Rückfall: Das Tool steht immer in der Liste.
   Es tut bei inaktivem Modus nichts, und der Skill regelt das „wann“.
6. **Wörtlich oder frei:** Darf die ChatGPT-Stimme umformulieren? Ein
   ergänzter Name (Spike #4) ist harmlos, ein verdrehter Inhalt nicht.
   Vorschlag: auf wörtliches Vorlesen festlegen und es testen. Gelingt das
   nicht, bleibt die Systemstimme Standard.
7. **Kontingent:** Was kostet eine warm gehaltene Realtime-Session im
   ChatGPT-Abo? Vor S8 messen.

## Prototyp-Ergebnis (08.10.2026)

Wegwerf-Plugin `whisperm8-proto` außerhalb des Repos unter
`~/Library/Application Support/WhisperM8/claude-plugin-proto/whisperm8-proto/`
(Dummy-Skill `jarvis-proto`, Mod mit Band, Statuszeile, `skill.prompt`-Hook,
Tool `probe`, `chats watch`-Strom, Test-Pane). `claude plugin validate`: grün,
`claude plugin test`: 3/3 grün. Geladen wurde nur über
`CLAUDE_CODE_PLUGIN_DIRS` in der Prozess-Umgebung (Claude Code 2.1.294,
Profil `ai3`, Pfad mit Leerzeichen), mit Fake-`WHISPERM8_SESSION_ID`;
interaktiv in einem PTY mit pyte-Emulation.

| # | Frage | Ergebnis | Beleg |
|---|---|---|---|
| 1 | Lädt `CLAUDE_CODE_PLUGIN_DIRS`? | **belegt**, headless und interaktiv | `-p … --output-format stream-json`: Init-Nachricht `plugins: [{name: "whisperm8-proto", source: "whisperm8-proto@inline"}]`; interaktiv zeichnet das Band |
| 2 | Skill-Name, Aufruf | **belegt**: `whisperm8-proto:jarvis-proto`. Läuft per Skill-Tool, `/whisperm8-proto:jarvis-proto` und kurz `/jarvis-proto` | Init `skills`; drei Läufe mit Antwort `JARVIS-PROTO-SKILL-GELADEN` |
| 3 | `skill.prompt`-Matcher, `$.env.get` | **belegt**. Nur der volle Name matcht (`{ skill: 'whisperm8-proto:jarvis-proto' }`), der kurze nie, auch nicht bei `/jarvis-proto`. Env liefert den Wert aus der Prozess-Umgebung. | Probe `skillHits`, `sessionId: "PROTO-FAKE-0002"` |
| 4 | Tool mit `isDeferred: false` ab Turn 1 | **belegt** | Init `tools` enthält `mcp__whisperm8-proto__probe`; Haiku ruft es im ersten Turn direkt auf, ohne ToolSearch (Profil hat `ENABLE_TOOL_SEARCH=true`) |
| 5 | `chats watch` über `$.process.spawn` | **belegt** | Zwei Sessions parallel, 2 min: je ein Kind, Änderung `seq 10191` (17:23:49) kam live in beiden an; nach Session-Ende 0 Kinder |
| 6 | Band, Layout, Breiten | **belegt bis auf die 3×3-Slot-Breite**, siehe unten | Bildschirm-Captures 60×27, 93×30, 100×30, 109/110/184 Spalten |
| 7 | Hot-Reload, mehrere Sessions | **belegt** (interaktiv) | Edit von außen (`MARKER v1→v2`): beide laufenden Sessions melden `whisperm8-proto: reloaded (5 hooks …)`, `$.state` bleibt (`loads 2`), das alte `watch`-Kind wird beendet und ein neues gestartet (stets 2 Prozesse, nie 4) |

**Zu 6 im Detail.**

- **Fakt:** Alle acht Profile (`~/.claude` und `~/.claude-profiles/*`) haben
  `"tui": "default"`, also den klassischen Main-Screen-Renderer. Die App setzt
  `CLAUDE_CODE_NO_FLICKER` nicht. Die WhisperM8-Sessions laufen damit **nicht**
  im Vollbild-Layout: `isFullscreen false`.
- **Fakt:** Das Band zeichnet bei jeder Breite. Die Mod bekommt
  `bodyColumns` = Spalten − 5 (60 → 55, 93 → 88, 184 → 179).
- **Fakt:** Ein Pane ist im Main-Screen immer `inline` über dem Prompt, auch
  bei 184 Spalten. Im Vollbild (`CLAUDE_CODE_NO_FLICKER=1`) dockt es ab genau
  110 Spalten, bei 109 bleibt es inline. Gedockt schrumpft das Transcript:
  bei 184 Spalten 102 Spalten Transcript und 81 Spalten Pane, bei 110 Spalten 70
  und 39.
- **Fakt:** Gemessene PTY-Größen der laufenden App-Sessions (`stty -f`, nur
  lesend): 184×83 für den aktiven Einzel-Tab, 140×54 für andere. Das Grid war
  während der Messung nicht sichtbar (`showsGrid: false`).
- **Offen:** Die Breite eines echten Grid-Slots wurde nicht gemessen.
  **Schluss:** Im 3×3-Workspace „ListM8“ sind es grob 184 / 3 ≈ 60 Spalten
  und 83 / 3 ≈ 27 Zeilen, also etwa 55 Spalten fürs Band.
- **Fakt (Nachtrag, echte App-Session):** Die Mod wurde per Hot-Reload in die
  laufende WhisperM8-Session `6C7DAE08` geladen. Der Band-Hook hat dort
  gezeichnet und protokolliert `{"surface":"terminal","viewport":{"columns":184,
  "rows":83,"isFullscreen":false},"bodyColumns":179}`. Das Tool las
  `WHISPERM8_SESSION_ID=6C7DAE08-…`, und der `watch`-Strom lief live mit 4
  Ereignissen. Der Sampler sah diese Session um 17:28 für 45 s mit 89×38,
  vermutlich in einer Zwei-Spalten-Ansicht.
- **Fakt (Screenshot des Users, 17:31):** Das Band steht in SwiftTerm direkt
  über der Prompt-Linie, Farbe korrekt (cyan und gedimmt). Der User hat es
  zunächst übersehen, weil es aussieht wie die letzte Zeile des Transcripts.
  **Folge fürs Board:** Das Band braucht einen sichtbaren Rahmen oder eine
  Kopfzeile (`Box` mit `borderStyle`), sonst geht es im Verlauf unter.

**Nebenbefunde.**

- **Fakt:** Ein per `$.command.register` angelegter Befehl erscheint ohne
  Namensraum (`/proto`, nicht `/whisperm8-proto:proto`).
- **Fakt:** `$.ui.status` erscheint als eigene Zeile unter dem Prompt
  (`⚠ whisperm8-proto: …`).
- **Fakt:** Watch-Änderungszeilen haben kein `event`-Feld. Nur `started` und
  `timeout` tragen eines.
- **Fakt:** Beim Session-Ende stirbt das Kind vor dem Modul, und eine naive
  Neustart-Schleife startet einmal nach. Die Schleife muss deshalb
  `session.end` beachten und mit Backoff neu ansetzen.
- **Fakt:** `claude plugin test` hat weder fs noch process. Jeder
  Hintergrund-Strom braucht ein `.catch`, sonst scheitert der Test an
  „a rejection nothing handled“.

### Was sich am Plan ändert

1. **Verteilung über `CLAUDE_CODE_PLUGIN_DIRS` trägt.** Für S1 ist kein
   Marketplace nötig.
2. **Atomar ausrollen.** Jede laufende Session lädt neu, sobald sich der
   Ordner ändert. Ein App-Update schreibt deshalb in einen neuen versionierten
   Ordner und schaltet erst danach um (Rename oder Symlink; ein verlinkter
   Ordner wird laut Doku am Ziel überwacht). Kopieren in den laufenden Ordner
   ist verboten.
3. **Namen.** Skills heißen `whisperm8:<skill>`, der Hook-Matcher braucht den
   vollen Namen `{ skill: 'whisperm8:jarvis' }`. Der Kurzaufruf `/jarvis`
   funktioniert nur, solange er eindeutig ist. Die Migration der alten Kopien
   in `~/.claude/skills/` bleibt deshalb Pflicht. **Vermutung:** Liegen beide
   parallel, gewinnt bei `/jarvis` die lose Kopie. Das ist nicht getestet.
4. **`/board` bleibt `/board`**, weil Mod-Befehle keinen Namensraum tragen.
   Kollisionen mit anderen Plugins sind dadurch möglich.
5. **Offener Punkt 1 ist entschieden:** Das Panel erscheint in App-Sessions
   immer inline über dem Prompt, weil `tui: default` gilt. Das Band ist die
   tragende Anzeige. Das Panel bleibt Detailansicht auf Zuruf und öffnet sich
   nie ungefragt.
6. **Watch-Strom:** Je aktiver Board-Session ein Kind. Neustart mit Backoff,
   Ende bei `session.end`, Cursor weiterreichen (`--cursor`, `resumed: true`).
7. **Neu offen:** Erben Background-Agents (`claude --bg`, gestartet vom
   Supervisor-Daemon) und `claude attach` die PTY-Umgebung und damit
   `CLAUDE_CODE_PLUGIN_DIRS`? Nicht getestet. Vor S1 prüfen.

### Band-Gestaltung (Prototyp `jarvis-board-proto`, 08.10.2026)

Wegwerf-Mod mit Beispieldaten, ohne Board-Logik. Sie liegt nur im Mod-Ordner
der Session (`~/.claude-profiles/ai3/dev-mods/<session>/jarvis-board-proto/`),
mit `validate` grün und 3/3 Tests. Die Captures stammen aus dem PTY.

```
╭──────────────────────────────────────────────────────────────────────────────────╮ [-]
│ Jarvis · Board  ● 2 wartet  ● 2 läuft  ● 1 fertig  ○ 1 geparkt             z: zu │
│ ● Akquise Import     Freigabe: 500 Leads importieren                         12m │
│ ● Outreach Copy-Rev… Entscheidung: Opener-Schluss A oder B                    4m │
│ ● Tab-Switcher Revi… fertig · Ergebnis prüfen                                 2m │
│ ● ListM8 Lead-Run    Qualifizierung 40/150                                   18m │
│ ○ GPT-Konten Slice 5 wartet auf Proxy-Release                                 3h │
╰──────────────────────────────────────────────────────────────────────────────────╯
╭─────────────────────────────────────────────────────╮ [-]     (60 Spalten, Grid-Slot)
│ Jarvis  ● 2 wartet  ● 2  ● 1  ○ 1             z: zu │
│ ● Akquise Import  Freigabe: 500 Leads import…   12m │
▸ Jarvis  ● 2 wartet  ● 2  ● 1  ○ 1                     a: auf   (eingeklappt)
```

Regeln, die sich bewährt haben:

- **Rahmen statt Linie.** Ein `round`-Rahmen trennt das Band vom Verlauf. Die
  Rahmenfarbe ist die Gesamtampel: rot, sobald ein Chat wartet, sonst grün bei
  „fertig“, sonst grau.
- **Reihenfolge:** wartet, fertig, läuft, geparkt. Innerhalb einer Ampel steht
  der älteste Eintrag oben, wer am längsten wartet, also zuerst.
- **Eine Zeile je Chat:** Ampel, Name, bei mindestens 90 Spalten der Kurz-Ref,
  danach das Anliegen (bei „wartet“ in Rot), sonst der nächste Schritt (gedimmt).
  Rechts bündig steht das Alter.
- **Drei Breiten:** Ab 90 Spalten mit Wörtern und Ref. Ab 64 ohne Ref, mit
  kurzem Alter. Darunter sind die Zahlen nur noch farbig markiert; nur
  „wartet“ behält sein Wort.
- **Platz:** Rahmen und Kopf kosten 3 Zeilen. Reicht `maxRows` nicht, zeigt die
  letzte Zeile „+N weitere“.
- **Einklappen** auf eine Zeile mit `z`/`a` oder `/board zu|auf`. Die Summe
  bleibt sichtbar.
- **Farben nur über Theme-Schlüssel** (`error`, `warning`, `success`,
  `inactive`, `claude`). Damit passen sie zu hellem und dunklem Theme. Statt
  Emoji `●`/`○`, weil Emoji in SwiftTerm doppelt breit laufen können.
- **Alter** tickt im 30-s-Takt über ein State-Atom und zeichnet nur das Band
  neu.

## Nicht-Ziele

- Kein natives Board in der App in diesem Plan. Die Daten liegen aber so, dass es später möglich ist.
- Keine Änderung am öffentlichen Outreach-Plugin.
- Kein Dashboard im Terminal für die CLI. Die Ausgabe bleibt ein JSON-Vertrag (siehe `docs/features/agent-chats-cli.md`).
