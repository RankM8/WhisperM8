---
status: aktiv
updated: 2026-11-06
description: Statistik-Seite in den Einstellungen – aktive Zeit, Agenten-Zeit, Token je Modell, API-Gegenwert in Euro, Hebel der Abos, Limit-Verlauf, Chats, Diktate, Git.
---

# Statistik

Die Seite „Statistics“ (Einstellungen, Gruppe App) zeigt, wie viel mit
WhisperM8 gearbeitet wird: pro Tag, Woche, Monat und insgesamt. Anlass war,
dass die macOS-Bildschirmzeit WhisperM8 nicht als eigene App aufführt (die Zeit
landet dort vermutlich unter „Andere“, weil die App ohne Team-ID signiert ist).

Alles wird lokal gerechnet. Ins Netz gehen nur zwei Abfragen: der EZB-Kurs,
höchstens einmal am Tag, und stündlich `gh pr list` für die eigenen Pull
Requests, sofern `gh` installiert und angemeldet ist. Standardmäßig an; Schalter „Statistik erfassen“ auf
der Seite, zugleich Notbremse `statisticsEnabled`.

## Was gezählt wird

| Wert | Quelle | Zählweise |
|---|---|---|
| Aktive Zeit | App-Ereignisse | WhisperM8 ist vorne und es gab in den letzten 5 Minuten eine Eingabe. Nur solange die App aktiv ist, prüft ein 60-s-Timer die Leerlaufzeit. Schlaf, Sperre und Inaktivität schließen das Intervall sofort. |
| Vordergrund-Zeit | dto. | wie oben, ohne Eingabe-Bedingung |
| Agenten-Zeit, gleichzeitige Chats | Status-Koordinator (`writeStatus`) | Zeit mit mindestens einem arbeitenden Chat (grüner Punkt), zeitgewichteter Durchschnitt, Tagesspitze. Während der Mac schläft, zählt nichts. |
| Neue Chats | `AgentSessionStore.createSession` | nur in WhisperM8 angelegte Chats (`createdManually`), getrennt nach Claude, GPT, Codex, Hintergrund. Chats von vor dem Einschalten werden einmalig aus `createdAt` nachgetragen. |
| Diktate | `saveRunReport` | Anzahl, Audiominuten, Wörter, Modus; fehlgeschlagene zählen nicht |
| Token je Modell, Konto, Projekt | Protokolle `~/.claude*/projects` und `~/.codex/sessions` (nur lesen) | siehe unten |
| Subagents | Claude-Protokolle | jede neue `subagents/agent-*.jsonl` |
| Limits | Statuszeile, vorhandene Abfragen, Codex-Protokolle | letzter Stand und Wochen-Höchstwert je Konto |
| Commits, PRs | `git log`, `gh pr list` | stündlich, nur Projektordner der Chats, nur eigene Commits (`user.email` des Repos), Tag nach Autor-Zeit; umgeschriebene Commits (Rebase, Amend, Cherry-Pick) zählen über Autor-Zeit und Betreff nur einmal |

## Token und API-Gegenwert

Der Protokoll-Leser (`StatisticsLogScanner`) merkt sich je Datei Größe, Datum
und Lese-Position und liest nur neue, vollständige Zeilen. Zeilen ohne
Token-Angaben werden vor dem Dekodieren aussortiert.

- **Doppelte Antworten:** Claude schreibt pro Content-Block eine Zeile mit
  derselben `usage`. Gezählt wird jede Kombination aus `message.id` und
  `requestId` einmal, über alle Dateien und Konten. Das deckt auch Dateien ab,
  die „Zum Hauptkonto machen“ zwischen Profilen kopiert.
- **GPT über den Proxy** steht in den Claude-Protokollen, wird aber unter dem
  Konto `gpt-proxy` geführt (ChatGPT-Abo, nicht Claude).
- **Codex** meldet Gesamtstände. Gezählt wird die Differenz zum letzten Stand
  je Thread (UUID im Dateinamen, nicht der Pfad: Codex verschiebt und
  komprimiert ältere Rollouts); `input_tokens` enthält dort den Cache und wird
  bereinigt. Komprimierte `rollout-*.jsonl.zst` liest der Leser gestreamt mit
  `zstd -dc` (Homebrew). Fehlt `zstd`, werden sie übersprungen und die Seite
  sagt das. Auf dem Entwickler-Mac lagen zwei Drittel der Codex-Historie so vor.
- **Fast-Modus** bekommt die Endung `-fast` und den doppelten Preis.
- **Preise:** `ModelPricing` (USD je Million Token, Quellen im Code).
  Gesucht wird die exakte Modell-ID (ohne Datum, `[1m]` und Proxy-Präfix),
  kein Präfix: `claude-opus-4-8` landet nicht beim Opus-4.0-Preis. Unbekannte
  Modelle erscheinen ohne Gegenwert statt mit einem geratenen; unter der
  Tabelle steht, wie viele Token das betrifft.
- **Euro:** EZB-Referenzkurs (`StatisticsExchangeRate`), Rückfall 0,92.
- **Hebel:** API-Gegenwert geteilt durch die Abo-Kosten des Zeitraums
  (Monatsbetrag × 12 / 365 × Tage). Die Abos stehen auf der Seite.

Der Gegenwert ist ausdrücklich nicht das, was der Nutzer zahlt.

### Einlesen der Historie

Beim ersten Lauf ohne Lese-Positionen liest der Leser alle Protokolle: neueste
Dateien zuerst, auf `.background`, mit Pausen zwischen den Dateien. Während
eines Diktats, im Stromsparmodus, bei hoher Temperatur oder wenn der Nutzer auf
der Seite pausiert, bricht er das Einlesen ab und plant es neu (nach 60 s bzw.
beim Fortsetzen); er blockiert dabei nichts. Neue Zeilen bekannter Dateien
liest jeder Lauf trotzdem, die laufenden Tage stimmen also auch während einer
Pause. Fortschritt steht in `db.backfill`.

Gemessen (Debug-Build, ohne Drossel, 18,8 GB Claude- und 4,1 GB
Codex-Protokolle): Claude-Volllauf 92 s bei höchstens 58 MB Speicher, die 1.015
komprimierten Codex-Dateien 210 s bei höchstens 102 MB; danach ein Lauf ohne
Änderungen unter 0,6 s.

### Ablauf

Erster Lauf 30 s nach dem App-Start, dann alle 15 Minuten und beim Öffnen der
Seite (frühestens 60 s nach dem letzten Lauf). Messpunkt `statistics.scan`
(Budget 1,5 s, Signposter `perf.statistics`). Im Stromsparmodus läuft der
Timer nur stündlich.

## Limits

`StatisticsLimitCollector` liest alle 15 Minuten die Limit-Caches der
Claude-Profile (`$TMPDIR/claude-usage-cache-<profil>.json`) und schreibt mit,
wenn die App ohnehin live abfragt (Konten-Popover, Einstellungen). Neue
Netzwerkabfragen gibt es nicht. Die Statuszeile übernimmt das `rate_limits`-Feld
von Claude Code in denselben Cache, damit er auch ohne OAuth-Abfrage frisch
bleibt. Konto-Schlüssel: Profilname, `chatgpt:<profil>` für GPT-Profile,
`codex` für die Codex-CLI.

## Speicher und Leistung

- Daten: `~/Library/Application Support/WhisperM8/statistics/`: Tagesdateien
  für den laufenden Monat, Monatsdateien für vergangene, Metadaten getrennt;
  dazu Lese-Positionen (Datei plus anhängendes Journal), Doppel-Erkennung
  (anhängende Binärdatei mit 64-bit-Hashes, ~8 Byte je Antwort, wird bewusst
  nicht nach Alter gekürzt) und Git-Cursor. Eine alte `stats.json` wird beim
  ersten Laden übernommen.
- `StatisticsStore` hält alles auf einer eigenen Utility-Queue, schreibt
  gebündelt höchstens einmal pro Minute und nur geänderte Tage, und
  benachrichtigt die Seite höchstens alle 2 Sekunden. Geschätzte Schreiblast im
  Dauerbetrieb: rund 10 MB am Tag. Kaputte Dateien werden beiseitegelegt, nicht
  überschrieben.
- Absturzsicherheit: Zahlen werden vor den Lese-Positionen gesichert. Stürzt
  die App genau dazwischen ab, kann ein Abschnitt doppelt zählen; verloren geht
  nichts.
- „Löschen…“ erhöht eine Generationsnummer im Store. Läufe, die vorher
  begonnen haben, sichern danach nichts mehr und legen den Ordner nicht neu an.
- Die Zähler-Einhakstellen sind O(1) und schreiben nie auf dem Main-Thread.
- Die Seite rechnet nichts in `body`: Schnappschuss holen, `StatisticsReport`
  im Hintergrund bauen, Ergebnis anzeigen.
- „Löschen…“ entfernt den ganzen Ordner; „Neu einlesen“ verwirft
  Lese-Positionen und Token-Werte und startet das Einlesen neu.

## Teilen

„Share…“ erzeugt eine Karte als Bild oder Markdown für Slack oder Mail.
Projektnamen sind standardmäßig ausgeblendet. Ein gemeinsames Team-Board gibt
es noch nicht; es bräuchte einen Server.

## Schlüsseldateien

| Datei | Rolle |
|---|---|
| `Services/Statistics/StatisticsModels.swift` | Tageswerte, Limit-Verlauf, Zeit-Helfer |
| `Services/Statistics/StatisticsStore.swift` | einziger Halter der Daten |
| `Services/Statistics/StatisticsReport.swift` | reine Auswertung für die Seite |
| `Services/Statistics/ModelPricing.swift` | API-Preise, Anzeigenamen |
| `Services/Statistics/StatisticsCollectors.swift` | Start, Stopp, Einhakstellen |
| `Services/Statistics/StatisticsLogScanner.swift` (+ Parser, Reader, ScanState) | Protokoll-Leser |
| `Services/Statistics/StatisticsLimitCollector.swift` | Limit-Verlauf |
| `Services/Statistics/StatisticsGitCollector.swift` (+ GitScanner) | Commits und PRs |
| `Views/Settings/Pages/StatisticsSettingsPage*.swift` | die Seite |

Entwurf: [`../design/statistik.html`](../design/statistik.html).

## Keywords

Statistik, Bildschirmzeit, aktive Zeit, Agenten-Zeit, Token, Kosten,
API-Gegenwert, Hebel, Abo, Limit, Wochenlimit, Commits, Pull Requests,
`StatisticsStore`, `StatisticsReport`, `StatisticsLogScanner`, `ModelPricing`,
`statisticsEnabled`
