---
status: aktiv
stand: 2026-09-23
feature: GPT-Konten (mehrere ChatGPT-Konten im GPT-Backend)
---

# GPT-Konten (GPT-Backend)

Das GPT-Backend führt beliebig viele ChatGPT-Konten gleichzeitig. Jedes Konto
ist ein eigener Login des `claude-code-proxy` mit eigenem Credential-Store und
eigener Proxy-Instanz; jeder Claude-Chat trägt beim Anlegen den Stempel des
Kontos, über das er laufen soll. Der Wechsel kostet weder Re-Login noch einen
Neustart laufender Sessions.

Grundlagen des Backends selbst (Proxy-Binary, Mix-Router, Modellkatalog)
stehen in `CLAUDE.md` → *GPT-Backend* und im Plan
[`../../plans/claudex-gpt-backend/PLAN.md`](../../plans/claudex-gpt-backend/PLAN.md);
Entwurf und Verifikationsprotokoll der Konto-Fähigkeit in
[`../../plans/gpt-account-switcher.md`](../../plans/gpt-account-switcher.md).

## Zwei getrennte Logins — der wichtigste Punkt

Es gibt **zwei voneinander unabhängige ChatGPT-Anmeldungen**, und sie lassen
sich leicht verwechseln:

| Login | Store | Wer daran hängt |
|---|---|---|
| **GPT-Backend** (diese Seite) | Config-Dir des Proxys, darin `codex/auth.json` | Claude-Chats mit GPT-Modell, native `gpt`-Subagents, GPT-Modelle im `/model`-Picker |
| **Codex-CLI** (`codex login`) | `~/.codex/auth.json` | Codex-Chats, Diktat-Nachbearbeitung, `whisperm8 agent`, ChatGPT-App |

Ein `codex login` stellt also **nicht** das GPT-Backend um, und ein Login in
den GPT-Backend-Einstellungen **nicht** die Codex-CLI. Die Trennung ist
gewollt (keine Token-Kollision zwischen Proxy und CLI, keine rotierende
Refresh-Familie in einem gemeinsamen Verzeichnis). Genau deshalb zeigt das
Usage-Popover beide Spuren getrennt an — einmal je GPT-Konto, darunter ein
eigener Block „Codex-CLI / Diktat".

## Was ein Konto ist

- **`main`** ist der bisherige Default-Store des Proxys unter
  `~/.config/claude-code-proxy` (folgt `XDG_CONFIG_HOME`) und läuft auf dem
  Backend-Port (Standard 18765). Wer nie ein zweites Konto anlegt, merkt vom
  Feature nichts: Sessions ohne Stempel verhalten sich wie vorher.
- **Zusatzkonten** sind Unterordner von `~/.gpt-profiles/<name>`. Der Ordner
  wird dem Proxy als `CCP_CONFIG_DIR` mitgegeben; er legt darin seinen eigenen
  OAuth-Grant ab (`codex/auth.json`, eigene Refresh-Familie).
- **Angemeldet** heißt: die Auth-Datei des Profils existiert *und* trägt eine
  `accountId`. Das wird bewusst an der Datei geprüft, nicht an der Ausgabe von
  `codex auth status`: ein leeres Config-Dir lässt den Proxy still auf den
  Default-Store zurückfallen und dessen Konto melden. Meldet der Statusbefehl
  eine fremde Konto-ID, gilt das Profil als nicht angemeldet (Logzeile
  `gpt_profile_auth_fallback_detected`).
- **`.active`** in `~/.gpt-profiles` merkt sich das aktive Konto. Fehlt die
  Datei oder zeigt sie auf ein gelöschtes Profil, gilt `main`.
- **Kontometadaten** (E-Mail, Plan, `accountId`, Abrufzeitpunkt — keine
  Secrets) liegen als `whisperm8-account.json` im Profilordner, für `main`
  unter `~/.gpt-profiles/.main-account.json`, weil in fremden Tool-Verzeichnissen
  nichts geschrieben wird. Sie werden nur angezeigt, wenn ihre `accountId` zum
  aktuellen Grant passt.

Auch `main` startet inzwischen mit gesetztem `CCP_CONFIG_DIR` — auf genau den
Pfad, den der Proxy ohne die Variable nähme. Grund: ohne die Variable
bevorzugt der Proxy auf macOS den Keychain, dessen Schreibzugriff im
nicht-interaktiven Betrieb scheitert; refreshte Tokens landeten dann nie in
der Datei und die Limit-Anzeige las einen längst abgelaufenen Token. Mit der
Variable arbeitet der Proxy rein dateibasiert.

## Eine Proxy-Instanz je Konto

Ein Proxy-Prozess bedient genau ein Konto, also läuft je Konto eine eigene
Instanz. `main` bleibt auf dem Backend-Port; Zusatzkonten bekommen beim ersten
Start einen freien Port ab **Backend-Port + 10** (Suchfenster 40 Ports, Router-
und main-Port ausgespart). Die Zuordnung lebt nur im Speicher der App — die
Sessions selbst kennen ohnehin nur den Router-Port (Standard 18766).

Gestartet wird eine Instanz beim Aktivieren des Kontos und spätestens beim
Start eines Chats, der darauf gestempelt ist. Ein Profil ohne eigene
Auth-Datei wird **nie** gestartet; ein Chat auf einem abgemeldeten Profil
startet stattdessen über `main`. Beim Beenden der App, beim Abschalten des
Backends und über „Proxy stoppen" werden alle selbst gestarteten Instanzen
mitbeendet; ein von Hand gestarteter main-Proxy wird weiterhin nur geprüft,
nie adoptiert.

## Bedienung

### Konto anlegen und anmelden

Einstellungen → **GPT-Backend** → Abschnitt **„Konto hinzufügen"**: Name
eingeben (ASCII-Buchstaben, Ziffern, `-`, `_`; `main` ist reserviert) und
**„Anlegen & anmelden…"**. Der Gerätecode erscheint daraufhin mit URL und
Kopier-Knopf in der Kontoliste darüber. In den ChatGPT-Sicherheitseinstellungen
muss die Autorisierung per Gerätecode erlaubt sein.

Wichtig beim zweiten Konto: Ist im Browser bereits ein anderes ChatGPT-Konto
angemeldet, landet der Login stillschweigend wieder dort — dann ein
Inkognito-Fenster verwenden. WhisperM8 vergleicht nach dem Login die neue
Konto-ID mit allen anderen Profilen und warnt, wenn dasselbe Konto ein
zweites Mal verbunden wurde.

Ein bereits vorhandenes Profil meldet man über den Knopf **„Anmelden…"** in
seiner Zeile oder über **⋯ → Neu anmelden…** an.

### Konto aktiv setzen

Der Radioknopf links in der Kontozeile bestimmt das Konto für **neu
gestartete** Chats. Nach dem Klick fährt WhisperM8 die zugehörige Proxy-Instanz
gleich hoch (die Zeile zeigt dann „Proxy-Instanz auf Port …"), damit der erste
Chat nicht in den 503-Wiederholversuch läuft. Laufende Chats bleiben
unverändert.

### Bestehende Chats umstellen

Kontextmenü eines Chats (oder einer Mehrfachauswahl) → **„GPT-Konto"** →
Konto wählen. Das Menü gibt es nur für interaktive Claude-Chats bei
aktiviertem GPT-Backend; nicht angemeldete Konten sind ausgegraut. Anders als
beim Claude-Konto zieht dabei **kein Transcript um** — gesetzt wird nur der
Stempel, und der wirkt, wie das Menü auch schreibt, **beim nächsten Start des
Chats**. Ein Hot-Switch laufender Chats existiert noch nicht.

### Abmelden und entfernen

Im ⋯-Menü der Kontozeile, beides mit Rückfrage. **Abmelden** verwirft den
Grant des Profils und stoppt seine Instanz; war es das aktive Konto, fällt die
Auswahl auf `main` zurück, und Chats mit diesem Stempel laufen beim nächsten
Start über das Hauptkonto, bis das Konto wieder angemeldet ist. **Entfernen**
(nicht für `main`, nicht für das aktive Konto) löscht das ganze
Profilverzeichnis, bricht einen laufenden Login des Profils ab und stellt alle
darauf gestempelten Chats auf `main` um. Während ein Gerätecode-Login läuft,
sind Radio, Abmelden und Entfernen gesperrt — der Proxy erlaubt nur einen
Login gleichzeitig.

## Wo das Konto sichtbar wird

- **Settings-Sektion „ChatGPT-Konten (GPT-Backend)"** — je Konto: Radio für
  „aktiv", Name, Plan-Badge (Pro, Pro Lite, Plus, Team, …), `main`-Badge,
  E-Mail (ersatzweise die letzten Stellen der Konto-ID), Port der laufenden
  Instanz, Balken für die Fenster und modellgescopten Zusatzlimits und bei
  erschöpftem Kontingent „Gesperrt — Kontingent erschöpft · frei ab …" (Reset
  des vollen Fensters). Der Knopf **„Limits aktualisieren"** holt die Werte
  aller angemeldeten Konten parallel neu.
- **Usage-Popover** (Kopfzeile der Sidebar) — Überschrift
  „ChatGPT · GPT-Backend" mit Aktualisieren-Knopf, darunter ein Block je
  angemeldetem Konto mit Aktiv-Marker und Limits, dann getrennt der Block
  „Codex-CLI / Diktat" mit dem Konto aus `~/.codex/auth.json`.
- **Statuszeile im Terminal** — solange ein GPT-Modell läuft, steht hinter dem
  Claude-Konto das GPT-Konto der Session als gelbes `⇄gpt:<name>`, für das
  Hauptkonto dezent `⇄gpt:main`. Bei Claude-Modellen erscheint der Zusatz
  nicht. Der Zusatz `gpt:` ist Absicht: „main" allein wäre von Git-Branch und
  Claude-Konto nicht zu unterscheiden.
- **CLI** — `whisperm8 chats show --json` führt das Konto unter
  `detail.gptProfileName` (`null` = `main`).

## Wie das Routing funktioniert

1. **Stempel beim Anlegen.** Jede neue Claude-Session bekommt das aktive Konto
   als `gptProfileName` (`nil` = `main`) — auch ohne GPT-Modell, damit ein
   späterer `/model`-Wechsel auf GPT das Konto trifft, das beim Anlegen aktiv
   war. Codex-Sessions und Background-Agents bekommen immer `nil`. Ein Fork
   erbt den Stempel der Quelle.
2. **Header beim Start.** Der Kommandobauer setzt beim Spawn
   `ANTHROPIC_CUSTOM_HEADERS` auf `X-WhisperM8-GPT-Profile: <name>` — **immer**,
   für das Hauptkonto ausdrücklich `main`. Die Variable ist ab da eingefroren,
   der Stempel also session-stabil: auch ein main-Chat folgt keinem späteren
   Kontowechsel. Subagents erben das Environment und damit das Konto ihrer
   Elternsession. Ein geerbtes `ANTHROPIC_CUSTOM_HEADERS` oder `CCP_CONFIG_DIR`
   aus der Shell, die WhisperM8 gestartet hat, wird vorher entfernt. Zeigt der
   Stempel auf ein entferntes oder abgemeldetes Profil, lautet der Header
   `main` (Logzeile `gpt_profile_unavailable_fallback_main`).
3. **Auflösung im Router.** Der Mix-Router liest den Header, sucht den Port
   der Instanz (`main` → Backend-Port) und entfernt den Header **vor jedem**
   Upstream — Anthropic bekommt ihn nie zu sehen. Header mit ungültigem
   Profilnamen gelten als nicht gesetzt.
4. **Kein Header?** Das betrifft nur Sessions von vor dem Update oder extern
   gestartete Prozesse mit Router-URL. Dann gilt das **aktive** Konto, nicht
   stur `main`, damit ein alter Chat nicht gegen ein erschöpftes Konto läuft,
   obwohl der Nutzer längst gewechselt hat.
5. **Instanz läuft nicht?** Ist das Profil angemeldet, antwortet der Router mit
   `503` („GPT-Konto ‚x' ist nicht verbunden …") und stößt den Start im
   Hintergrund an — pro Profil nur einen gleichzeitig, Fehler landen im Log
   (`gpt_profile_instance_start_failed`). Der nächste Versuch kommt durch. Ist
   das Profil abgemeldet, sagt die 503-Meldung genau das
   (`gpt_profile_not_logged_in`), ohne Startversuch. Ein stiller Rückfall auf
   ein anderes Konto findet im Router nicht statt.

## Kill-Switches

| Schalter | Wirkung |
|---|---|
| `defaults write com.whisperm8.app gptAccountProfilesEnabled -bool NO` | Konto-Profile aus: ein Proxy, ein Konto (der Default-Store), Stempel werden beim Start ignoriert, der Router ignoriert den Header. Die Settings-Seite zeigt wieder die alte Sektion „ChatGPT-Konto" mit dem einzelnen Device-Login, das Kontextmenü „GPT-Konto" entfällt, `main` läuft wieder ohne `CCP_CONFIG_DIR`. |
| Schalter „GPT-Backend aktivieren" (Settings → GPT-Backend) | Aus: alle Claude-Chats verbinden sich direkt mit Anthropic, GPT-Stempel vorhandener Sessions bleiben ungenutzt. |

## Bekannte Grenzen

- **Limit-Anzeige kann leer bleiben.** Die Balken stammen vom
  `wham/usage`-Endpunkt, abgefragt mit dem Access-Token aus der Auth-Datei des
  Profils. Schlägt das fehl, steht dort „Limits nicht abrufbar — Token in der
  Datei veraltet"; die Instanz arbeitet trotzdem weiter, nur die Anzeige fehlt.
  Abhilfe: ⋯ → Neu anmelden…
- **Kein Hot-Switch.** Das Umstellen eines Chats wirkt erst beim nächsten
  Start, weil der Konto-Header beim Spawn eingefroren wird.
- **CLI ohne Konto-Flag.** `whisperm8 chats new` kennt kein `--gpt-account`,
  `chats list` zeigt keine Konto-Spalte. Lesbar ist das Konto bisher nur über
  `chats show --json`.
- **Erschöpftes Kontingent kostet Zeit.** Der Proxy wiederholt intern rund
  170 Sekunden, bevor er ein 429 zurückgibt; die Session steht solange auf
  „working". Eine Limit-Erkennung im Router, die den Zug sofort abbricht,
  gibt es noch nicht.
- **Background-Agents (`claude --bg`) laufen immer über `main`.** Der
  Launch-Guard ist dort portbasiert; ein Konto-Stempel wäre eine Lüge.
- **Login-Zustand lebt in der Settings-Seite.** Wer während eines
  Gerätecode-Logins die Seite verlässt, sieht den Code beim Zurückkommen
  nicht mehr; der Login-Prozess läuft weiter, und die Konto-Aktionen bleiben
  solange gesperrt. Im Zweifel den Login über ⋯ → Neu anmelden… erneut starten.
- **Geteiltes Proxy-Log.** `CCP_CONFIG_DIR` hängt nur die Config-Wurzel um,
  nicht das State-Verzeichnis: alle Instanzen schreiben in dieselbe
  `proxy.log`. Jede Zeile trägt immerhin ihren Port.

## Schlüsseldateien

- `WhisperM8/Services/AgentChats/GPTAccountProfiles.swift` entdeckt Profile, liest `accountId` und Kontometadaten, verwaltet das aktive Profil und liefert den `CCP_CONFIG_DIR`-Override.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift` hält die Instanz-Registry je Profil, vergibt Ports, startet und stoppt Instanzen und führt Auth-Status, Device-Login und Logout pro Konto aus.
- `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift` wertet den Profil-Header aus, entfernt ihn vor den Upstreams und beantwortet fehlende Instanzen mit 503.
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift` setzt den Konto-Header beim Spawn über `ANTHROPIC_CUSTOM_HEADERS`.
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift` stempelt neue Sessions auf das aktive Konto und schreibt Umstellungen bestehender Chats.
- `WhisperM8/Models/AgentChat.swift` trägt den Session-Stempel `gptProfileName`.
- `WhisperM8/Views/Settings/Pages/GPTAccountsSection.swift` rendert Kontoliste, Gauges, Device-Login und Verwaltungsmenü auf der GPT-Backend-Seite.
- `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift` bindet die Sektion ein und hält Status, geführte Einrichtung und Konfiguration des Backends.
- `WhisperM8/Views/AgentChatsView+GPTAccount.swift` baut das Kontextmenü „GPT-Konto" für Einzel- und Mehrfachauswahl.
- `WhisperM8/Views/AgentUsagePopovers.swift` zeigt je GPT-Konto einen Block und darunter das Codex-CLI-Konto.
- `WhisperM8/Services/AgentChats/CodexUsageReader.swift` enthält den `CodexUsageFetcher`, der Plan, E-Mail und Wochenlimits holt — wahlweise aus dem Codex-Home oder aus dem Store eines Profils.
- `WhisperM8/Resources/whisperm8-statusline.sh` liest den Konto-Header aus dem Environment und zeigt `⇄gpt:<name>`.
- `Tests/WhisperM8Tests/GPTAccountProfilesTests.swift` und `Tests/WhisperM8Tests/GPTAccountRoutingTests.swift` decken Discovery, Validierung, Header-Injektion und Routing ab.

## Verwandte Bereiche

- [`../settings/`](../settings/) ordnet die Seite **GPT-Backend** in die Settings-Navigation ein (Gruppe *Claude Code*).
- [`../agent-chats-cli.md`](../agent-chats-cli.md) beschreibt das Claude-Konto-Pendant für `whisperm8 chats new` und den Account-Umzug bestehender Chats.
- [`sub-agents/workflows.md`](sub-agents/workflows.md) beschreibt die nativen `gpt`-Subagents, die das Konto ihrer Elternsession erben.

## Keywords

GPT-Konten, ChatGPT-Konten, GPT-Backend, Konto-Profil, Account-Switcher,
mehrere ChatGPT-Konten, Proxy-Login, `claude-code-proxy`, `CCP_CONFIG_DIR`,
`~/.gpt-profiles`, `.active`, `codex/auth.json`, `whisperm8-account.json`,
`.main-account.json`, `codex login`, Device-Code-Login, Gerätecode,
Inkognito-Fenster, Konto anlegen, Konto aktivieren, Abmelden, Entfernen,
Wochenlimit, Kontingent, `wham/usage`, Plan-Badge, Pro Lite, Limit erschöpft,
Token veraltet, Usage-Popover, Statuszeile, `⇄gpt`, Kontextmenü GPT-Konto,
Session-Stempel, `gptProfileName`, `X-WhisperM8-GPT-Profile`,
`ANTHROPIC_CUSTOM_HEADERS`, Mix-Router, Router-Port, Backend-Port,
Proxy-Instanz, 503, 429, `gptAccountProfilesEnabled`,
`claudeGPTBackendEnabled`, `GPTAccountProfiles`, `GPTAccountsSection`,
`ClaudeCodeProxyManager`, `ClaudeGPTMixRouter`, `CodexUsageFetcher`,
`gpt_profile_auth_fallback_detected`, `gpt_profile_missing`,
`gpt_profile_invalid_name`, `gpt_profile_proxy_started`,
`gpt_profile_proxy_unavailable`, `gpt_profile_not_logged_in`,
`gpt_profile_instance_start_failed`, `gpt_profile_unavailable_fallback_main`.
