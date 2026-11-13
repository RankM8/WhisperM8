---
status: aktiv
updated: 2026-11-13
description: Claude-Konten in Agent Chats — Konto neuer Chats, Login-Frist und Erneuerung, Hauptkonto tauschen, gemeinsames Memory, Kontowechsel ohne Stoppen, MCP-Angleich.
---

# Claude-Konten

Mehrere Claude-Konten über eigene `CLAUDE_CONFIG_DIR`-Profile; Gegenstück für ChatGPT: [gpt-konten.md](gpt-konten.md).

## Welches Konto ein neuer Chat bekommt

Neue Claude-Chats starten im Konto, das unter Einstellungen → Konten aktiv ist (Datei `~/.claude-profiles/.active`,
fehlt sie, ist es `main`). Das gilt für die Oberfläche wie für `whisperm8 chats new`; dort wählt `--account <profil>`
ein anderes angemeldetes Konto, auch `main`. Die CLI prüft das Konto vor dem Anlegen und bricht ab, wenn es fehlt,
abgemeldet ist oder sein Login abgelaufen ist — kein stiller Rückfall auf `main`. Ausnahmen: Background-Agenten laufen
immer in `main`, ein Fork erbt das Konto der Quelle, ein Resume bleibt im Konto des Chats. Umziehen bestehender Chats
und das Ablesen des Kontos (`list`/`show --json`, Feld `account`): [agent-chats-cli.md](../agent-chats-cli.md).

## Login-Frist und Erneuerung

Seit 10.11.2026. Anlass: Mit sieben Konten musste alle paar Tage eines neu angemeldet werden.

**Warum Logins enden.** Jeder `/login` hat ein festes Enddatum von 30 Tagen. Claude Code legt es im Keychain-Eintrag als
`claudeAiOauth.refreshTokenExpiresAt` ab. Das laufende Erneuern des Access-Tokens (etwa alle acht Stunden) verschiebt das
Datum nicht, nur ein neuer Browser-Login. Ist die Frist um, leert die CLI beide Tokens und vermerkt `loginEnded: "time_limit"`
(gemessen an Claude Code 2.1.322). Das Limit sitzt bei Anthropic; es lässt sich weder verlängern noch umgehen. Der einzige
offizielle Ausweg ist `claude setup-token` (ein Jahr gültig, kann aber nur Modell-Anfragen: kein Remote Control, keine
claude.ai-Connectoren, keine Live-Limits). Den nutzt WhisperM8 nicht.

**Anzeige und Vorwarnung.** `ClaudeLoginExpiry` liest Frist und Zustand aus dem Keychain-Secret. Der `ClaudeLoginExpiryStore`
prüft beim App-Start und danach stündlich alle Konten mit Kontodaten (ein `security`-Aufruf je Konto, abseits des Main Threads)
und hält das Ergebnis für die Oberfläche bereit; Ansichten lesen nie selbst den Keychain. Sichtbar wird die Frist an drei Stellen:

- Konten-Seite: unter jedem Konto steht, bis wann der Login gilt. Ab sieben Tagen Rest wird die Zeile farbig.
- Seitenleiste: Punkt am Claude-Symbol, sobald ein Login in drei Tagen endet oder beendet ist. Das Usage-Popover nennt die
  betroffenen Konten und führt zur Konten-Seite.
- Mitteilung: einmal je Frist, wenn ein Login in drei Tagen endet, und einmal, wenn er beendet ist
  (`ClaudeLoginExpiryWarningPlanner`, Merker in `claudeLoginExpiryNotifiedMarkers`). Ein Klick öffnet die Konten-Seite.

Punkt und Mitteilung schaltet „Warn before a login ends“ auf der Konten-Seite ab (`claudeLoginExpiryWarningEnabled`); die
Frist auf der Konten-Seite bleibt immer sichtbar.

**Sammel-Erneuerung.** „Renew…“ auf der Konten-Seite öffnet einen Dialog mit allen Konten, deren Adresse bekannt ist.
Vorgewählt sind alle außer den gerade erst erneuerten, damit die Konten denselben Stichtag bekommen. Die
`ClaudeLoginRenewalSession` geht die Auswahl nacheinander durch, immer ein Konto zur Zeit, weil der Browser nur eine
claude.ai-Sitzung hat. Je Konto (`ClaudeLoginRenewer`):

1. `claude auth login --claudeai --email <adresse>` läuft ohne Terminal in einem leeren Zwischenordner unter
   `Application Support/WhisperM8/claude-login-staging/<id>/` (eigenes `CLAUDE_CONFIG_DIR`, eigener Keychain-Eintrag).
   Die CLI öffnet den Browser selbst; die Adresse ist eingetragen, der Nutzer bestätigt den Link aus der Mail und gibt frei.
2. Danach wird geprüft, wer im Zwischenordner angemeldet ist (`oauthAccount` in dessen `.claude.json`): Konto und
   Organisation müssen zum Profil passen. War im Browser ein anderes Konto angemeldet, wird der Zwischen-Login verworfen,
   das Profil bleibt unverändert, und der Lauf hält an, bis der Nutzer sich im Browser abgemeldet hat.
3. Passt das Konto, ersetzt der neue Login das `claudeAiOauth` im Keychain-Eintrag des Profils. Alles andere im Eintrag
   (`mcpOAuth`) bleibt stehen. Vorher wird das Konto des Profils noch einmal abgeglichen (der Login kann zehn Minuten
   gedauert haben). Lässt sich der bestehende Eintrag nicht sicher lesen (Lesefehler, kein JSON), wird nichts geschrieben:
   ein Lesefehler ist nicht „kein Eintrag“, sonst gingen die MCP-Logins verloren. Schlägt das Schreiben fehl, kommt der
   alte Eintrag zurück.
4. Nach anderthalb Sekunden wird nachgeprüft, ob der neue Login noch im Eintrag steht. Hat ein laufender Chat desselben
   Kontos in dem Moment seinen alten Stand zurückgeschrieben, wird einmal neu zusammengeführt und geschrieben.
5. Zwischen-Eintrag und Zwischenordner werden gelöscht. Der Login ist damit verschoben, nicht kopiert.

Der Umweg über den Zwischenordner ist der Kern: Ein Login direkt im Profil hätte bei falscher Browser-Sitzung dessen noch
gültigen Login mit dem falschen Konto überschrieben. Zeigt claude.ai statt der Rückleitung einen Code, lässt er sich im
Dialog einfügen; „Open sign-in page again“ öffnet die Ausweich-Adresse der CLI. Ein Login wartet höchstens zehn Minuten;
reagiert die CLI beim Abbruch nicht auf SIGTERM, folgt nach drei Sekunden SIGKILL.

Es läuft nie mehr als ein Login, und nie einer ohne sichtbaren Dialog: Verschwindet die Konten-Seite oder wird die App
beendet, endet der laufende Login. Liegengebliebene Zwischenordner samt Zwischen-Eintrag (Absturz mitten im Login) räumt
der App-Start weg, sonst der nächste Lauf nach 30 Minuten.

Der erste Login eines neuen Profils läuft weiter über das Terminal („Create & Log in…“), weil es dort noch keine
Kontodaten zum Abgleich gibt.

**Grenzen.** Laufende Chats behalten ihren alten Token im Speicher und lesen den neuen Eintrag, sobald sie das nächste Mal
erneuern; ob Claude dabei in jedem Fall ohne Neustart weiterläuft, ist nicht gemessen. Die Übernahme läuft ohne Claudes
eigenes Lock (`<config-dir>.lock`); die Nachprüfung in Schritt 4 fängt den wahrscheinlichsten Zusammenstoß ab, eine
gleichzeitige Änderung an `mcpOAuth` im selben Augenblick kann verloren gehen. Einträge über etwa 1,9 KB (mehrere
MCP-Logins) schreibt `keychainWriter` wie bisher kurz über die Argumente von `security` statt über stdin — das betrifft
jetzt auch die Erneuerung. Den Namen des Keychain-Eintrags
bildet Claude aus dem unveränderten Wert von `CLAUDE_CONFIG_DIR` (sha256, erste acht Hex-Zeichen), auch mit Leerzeichen
und Umlauten im Pfad (nachgemessen an 2.1.322 über die `security`-Aufrufe der CLI).

## Betriebswissen aus CLAUDE.md

*Am 19.10.2026 wörtlich aus der Projekt-CLAUDE.md übernommen (LR-DOK-008); dort stehen nur noch die Arbeitsregeln. Beim nächsten Überarbeiten dieser Seite in den Fließtext einarbeiten.*

- **Hauptkonto tauschen** (seit 08.10.2026, ⋯-Menü „Make Main Account…" bzw. „Zum Hauptkonto machen…"): `main` ist kein Zeiger, sondern das Default-Verzeichnis (`~/.claude` bzw. Default-Store des Proxys) — dort laufen Terminal-`claude`, `claude --bg` und alle ungestempelten Chats. Ein totes Konto in main ließ sich bisher weder ersetzen noch entfernen. Der Login des Profils wird nach main **verschoben, nie kopiert** (zwei Stores mit derselben Refresh-Familie entwerten sich beim ersten Refresh gegenseitig), der alte main-Login ist danach weg, das Profil verschwindet. Claude (`ClaudeAccountProfiles+Promote`): Keychain-Secret + `oauthAccount` in `~/.claude.json` (Rest der Datei bleibt), `projects/` und `file-history/` werden in main gemischt (gleichnamige Dateien wie `memory/MEMORY.md` nie überschrieben, sie gehen mit dem Profil-Ordner in den Papierkorb), Stempel → `nil`; gesperrt, solange ein Chat des Profils läuft. GPT (`GPTAccountProfiles.promoteToMain` über `ClaudeCodeProxyManager.replaceMainGrant`): Profil-Instanz und main-Proxy werden vor dem Datei-Tausch beendet (sonst schriebe einer seinen alten Grant zurück), main startet danach neu; ein extern gestarteter main-Proxy blockiert. Laufende Chats mit eingefrorenem Profil-Header leitet der Router per In-Memory-Alias (`GPTPromotedProfiles`) an main.
- **Gemeinsames Claude-Memory** (seit 11.10.2026, Plan `docs/plans/claude-account-switch-ohne-stopp.md`, Slice 1): Claude legt Auto-Memory pro Config-Dir ab — ein Chat unter `ai2` kannte nicht, was einer unter `main` gelernt hatte. Chats von Zusatzprofilen bekommen deshalb in ihrer Session-Settings-Datei (`claude-hooks/<id>.json`, ohnehin per `--settings`) die offizielle Einstellung `autoMemoryDirectory` → `~/.claude/projects/<kodiert>/memory` (`ClaudeSharedMemoryPath`, Fragment über `AgentSessionStatusCoordinator.sharedMemoryFragmentResolver`). **Keine Symlinks, nichts an Claude Code geändert** — Claude liest den Schlüssel aus Flag-Settings ohne Trust-Prüfung und ohne Freigabe-Rückfrage (Prototyp P1). `main` selbst bekommt kein Fragment (dort ist es Claudes Standard; so bleibt main exakt wie vorher, falls die Berechnung je abweicht). Die Pfadregel ist aus Claude Code 2.1.296 nachgebaut: **realpath(3)** des Projektpfads (nicht `resolvingSymlinksInPath`/`standardizingPath` — beide kürzen `/private/…` still), Git-Root, Worktree → Haupt-Repo über `gitdir`/`commondir` (reine Dateizugriffe, kein `git`-Subprozess), Kodierung jede UTF-16-Einheit außer `[A-Za-z0-9]` → `-`, über 200 Zeichen gekürzt plus Java-String-Hash Basis 36. Einmalig beim Start führt `ClaudeMemoryMigration` die Profil-Memorys nach main zusammen: kopieren statt verschieben, Backup nach `Application Support/WhisperM8/memory-migration/<zeit>/`, nie überschreiben (Konflikt → `<name>.<profil>.md`), fehlende `MEMORY.md`-Zeilen anhängen, idempotent (Merker `claudeSharedMemoryMigrationDone`). Kill-Switch: `defaults write com.whisperm8.app claudeSharedMemoryEnabled -bool NO` (wirkt für neu gestartete Chats; jedes Profil nutzt dann wieder sein eigenes, unverändertes Memory).
- **Kontowechsel ohne Stoppen** (seit 11.10.2026, Plan `docs/plans/claude-account-switch-ohne-stopp.md`, Slice 2): „Zu Account verschieben" überspringt laufende Chats nicht mehr. `AccountSwitchPlanner` (pur) teilt auf: läuft nicht → sofort umziehen; läuft und ruht → anhalten, Prozessende abwarten, umziehen, im Tab fortsetzen (`shouldLaunchOnOpen`); arbeitet / Rückfrage offen / Entwurf im Eingabefeld → **vormerken** und nach dem Turn wechseln (`AccountSwitchCoordinator`, prüft per 2-s-Timer nur solange Vormerkungen bestehen, flüchtig, aufhebbar im Kontextmenü). Unbekannter Status zählt als beschäftigt. Alle sofortigen Bewegungen einer Aktion teilen einen Journal-Batch (ein „Rückgängig"). **Trust ist hart:** Hat das Zielkonto den Ordner nie freigegeben (`projects[<realpath>].hasTrustDialogAccepted` in seiner `.claude.json`, auch geerbt von Elternordnern, nur gelesen — `ClaudeAccountPreflight`), wird ein arbeitender Chat nicht vorgemerkt: der unbeobachtete Neustart landete in Claudes Trust-Dialog mit Vorauswahl „No, exit" (Prototyp P3). Die CLI (`chats move-account --stop-and-resume`) hält in diesem Fall ohne `--force` auch einen ruhenden Chat nicht an, weil sie meist unbeobachtet läuft (`stopBlocked: trustMissing`, Details in [agent-chats-cli.md](../agent-chats-cli.md)). Das Sheet nennt außerdem fehlende User-MCP-Server des Ziels und dass Claude den Verlauf im Ziel einmal ohne Cache neu einliest (früheres Thinking bleibt beim alten Konto — Claude zeigt dafür selbst einen Hinweis). Kill-Switch: `defaults write com.whisperm8.app accountSwitchAfterTurnEnabled -bool NO` (laufende Chats werden wieder übersprungen).
- **MCP-Angleich über Konten** (seit 11.10.2026, `ClaudeMCPSync`, Sektion „MCP Servers" auf der Konten-Seite): Claude speichert User-MCP-Server pro `CLAUDE_CONFIG_DIR` (`mcpServers` in der jeweiligen `.claude.json`) — ein neu eingerichteter Server landet nur im Konto des Chats. Die Sektion zeigt je Server, in welchen Konten er fehlt; „Copy" trägt ihn per **`claude mcp add-json -s user`** nach (Profile mit `CLAUDE_CONFIG_DIR`, main ohne). Nur ergänzen, nie löschen; verschiedene Definitionen unter einem Namen werden nie verteilt (Konflikt); Ausnahmen pro Server (`mcpSyncExcludedServers`); Definitionen (Header-Tokens) nie im Log. Auto-Angleich beim Start: `defaults write com.whisperm8.app mcpAutoSyncEnabled -bool YES` (Default aus). **Bewusst nicht** `managedMcpServers` in `/Library/Application Support/ClaudeCode/managed-settings.json`: maschinenweit, Admin-Rechte, kollidiert mit Firmen-MDM und nur http/https. OAuth-Logins bleiben pro Konto (`/mcp`).
- **Keychain-Zugriff immer mit Account** (seit 22.10.2026, `ClaudeAccountProfiles.readKeychainSecret`/`deleteKeychainSecret`): Claude Code liest und schreibt seinen Login mit `security … -a <account> -s <service>`, `account` = `$USER`, sonst Login-Name, bei ungültigen Zeichen `claude-code-user` (`claudeKeychainAccount`, nachgebaut nach v2.1.308). WhisperM8 und die Statusline lasen früher nur mit `-s` — bei zwei Items mit gleichem Service-Namen liefert `security` dann ein beliebiges. Vorfall 22.10.2026: ein fremdes Item `Claude Code-credentials`/Account `unknown` (nur `mcpOAuth`, angelegt 18.10.) verdeckte den echten main-Login, das Usage-Popover zeigte für das aktive Konto „Keine Daten“, und „Zum Hauptkonto machen“ hätte beim Rücklesen das fremde Item erwischt und per Rollback den echten Login überschrieben. Fehlt einem Profil mit `oauthAccount` der Token (z. B. von der CLI geleert, nachdem der Refresh-Token abgelehnt wurde: leere Tokens, `expiresAt` 0), meldet der Usage-Abruf `noCredentials` statt nichts. Das Popover sagt dann „neu anmelden“.
