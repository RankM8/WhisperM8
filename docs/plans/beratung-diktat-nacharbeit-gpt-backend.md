# Beratung: Diktat-Nacharbeit mit Codex und das GPT-Backend

**Stand:** 2026-11-05 · **Status:** Empfehlung „beides mit Rückfall“ beschlossen und umgesetzt (Branch `feat/dictation-gpt-backend`), dazu HTTP-Transport für alle Proxy-Instanzen und die Diktat-Reparaturen aus Abschnitt 5 (Punkte 2, 4, 5); `make dev` und Feldtest offen · **Scope:** Diktat-Nacharbeit (Ausgabemodi), GPT-Backend (`claude-code-proxy`, Konten, Updates)
**Herkunft:** Chat „4 Lio · Diktat: Codex-Nacharbeit und GPT-Backend“. Belege aus dem Code (Stand `main`, 7ba8670f), aus den Diktat-Berichten unter `~/Library/Application Support/WhisperM8/Reports`, aus Codex' eigener Sitzungsdatenbank (`~/.codex/state_5.sqlite` samt Rollout-Dateien), aus den Proxy-Logs und aus dem Upstream-Repo `raine/claude-code-proxy` (Klon auf Tag v0.1.48). Es wurde kein Modellaufruf gestartet und nichts verändert.

## Kurzfassung

- Die Nacharbeit startet für jedes Diktat einen frischen `codex exec`-Prozess. Dieser lädt die **komplette Codex-Einrichtung** auf diesem Mac mit: 5 aktive MCP-Server, rund 25 Plugins, eine Skill-Liste von 42 KB, Hooks und ein Benachrichtigungsprogramm. Für die eigentliche Aufgabe braucht das Diktat nichts davon.
- Gemessen an 69 echten Läufen seit dem 13.10.: Bis der Text beim Modell ankommt, vergehen im Mittel **3,1 s** (in jedem zehnten Lauf über 7 s, einmal fast 13 s). Das Modell selbst braucht im Mittel **3,8 s**. Jeder Lauf schickt im Mittel **25.700 Eingabe-Token**, das eigene WhisperM8-Prompt macht davon nur etwa 1.000 bis 2.000 aus.
- Zuverlässig ist der Weg trotzdem: 99 nachgearbeitete Diktate seit dem 19.10., **kein einziger Rückfall** auf den Rohtext.
- Das GPT-Backend läuft ohnehin, antwortet in unter 1 ms und trägt schon heute die Transkription der Diktate (Mittel 1,4 bis 1,6 s). Ein direkter Aufruf für die Nacharbeit spart den kompletten Codex-Start und rund 90 % der Token.
- Das Backend ist aber kein Ersatz für alles: Die Modi **Task** und **Ultra-Prompt** dürfen im Projekt lesen. Das kann nur die Codex-CLI. Für sie bleibt Codex.
- **Empfehlung Diktat:** beides mit Rückfall. Reine Textmodi über das GPT-Backend, Task und Ultra-Prompt über Codex, Codex auch als Rückfall und für alle ohne GPT-Backend.
- **Empfehlung Backend:** zuerst zwei kleine Reparaturen in WhisperM8. Das Zusatzkonto `office` läuft noch über die störanfällige WebSocket-Verbindung, und das Auto-Update übernimmt jede neue Upstream-Version ungeprüft. Danach gehören zwei Dinge als PR in den Upstream, weil sie uns Umwege ersparen.

---

## 1. So läuft die Nacharbeit heute

### Der Weg von „Diktat fertig“ bis „Text steht im Feld“

1. **Hotkey losgelassen:** `RecordingCoordinator.stopRecording()` (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:402`) stoppt die Aufnahme, wartet bis zu 1 s auf den Kontext (markierter Text, Chat-Ende, Screenshots), friert den gewählten Ausgabemodus ein und startet `transcribeAndDeliver` als abbrechbaren Task (`:560` ff.).
2. **Transkription:** `RecordingCoordinator+Transcription.swift:45`. Ergebnis wird normalisiert und von Gedankenstrichen befreit.
3. **Nacharbeit nötig?** `processTranscriptIfNeeded` (`RecordingCoordinator+Transcription.swift:178`). Der Modus `raw` („Fast“) springt direkt zur Auslieferung. Sonst wird das Kontextpaket ein letztes Mal aufgefrischt (was während der Transkription kopiert wurde, kommt noch mit), das Prompt für den Bericht gebaut und das Overlay auf „Improving…“ gestellt.
4. **Service:** `PostProcessingService.process` (`PostProcessingService.swift`) prüft die Kontextregel des Modus (`:27`), ruft den Prozessor und filtert am Ende Gedankenstriche aus (`:38`).
5. **Codex-Aufruf:** `CodexPostProcessor.process` (`CodexPostProcessor.swift:36`):
   - Vorlage laden, Anmeldestatus prüfen (`:42`). Der Status kommt aus `CodexStatusCache` (gültig 5 Minuten, bei „nicht angemeldet“ nur 5 s), dahinter steckt ein eigener Prozess `codex login status`.
   - Prompt bauen (`PromptPackageBuilder`), Projektordner bestimmen (`ProjectPathResolver`): nur Task und Ultra-Prompt bekommen ein Projekt, alle anderen laufen im Temp-Ordner.
   - Prozess starten (`performCodexRun`, `:90`). Das Binary ist `/opt/homebrew/bin/codex`, ein Node-Skript (npm-Installation, Version 0.160.1). Umgebung aus `LoginShellEnvironment`.
6. **Argumente** (`CodexSupport.swift:126` ff.):
   `codex exec -m <modell> -c model_reasoning_effort=<stufe> -c service_tier=<fast|default> --sandbox read-only --skip-git-repo-check --output-last-message <tempdatei> [-C <projekt>] [--ephemeral] [--image <datei>]… -`
   Das Prompt geht über die Standardeingabe. Alle Modi außer Task laufen mit `--ephemeral`, Task schreibt eine Sitzung nach `~/.codex/sessions`.
7. **Ergebnis:** Codex schreibt die letzte Antwort in die Temp-Datei. WhisperM8 liest sie nach Prozessende (`:189`), normalisiert sie und gibt sie zurück.
8. **Auslieferung:** in die Zwischenablage (`RecordingCoordinator+Transcription.swift:93`), in den Zwischenablage-Verlauf, dann bei Auto-Paste per Cmd+V in die Ziel-App. Zum Schluss wird der Diktat-Bericht geschrieben.

### Modell, Denktiefe, Tempo auf diesem Mac

Globale Einstellung: Modell `auto` (wird beim Aufruf zum neuesten Spitzenmodell, derzeit `gpt-6.1-sol`), Denktiefe `medium`, Stufe `fast` (Priority). Abweichungen je Modus aus `OutputModes.json`:

| Modus | Denktiefe | Projektzugriff | genutzt seit 19.10. |
|---|---|---|---|
| Clean | low | nein | 12 |
| Fast Prompt | low | nein | 12 |
| Prompt | high | nein | 0 |
| Ultra-Prompt | medium | lesend | 0 |
| Task | medium (global) | lesend, Standardprojekt | 48 |
| Email, Slack, WhatsApp, Notes | medium (global) | nein | 1, 23, 3, 0 |

Dazu 401 Diktate im Modus Fast (ohne Nacharbeit).

### Zeitlimit, Abbruch, Fehler und Rückfall

- **Zeitlimit:** 300 s, für Task und Modi mit Projektzugriff 900 s (`CodexPostProcessor.swift:16`). Danach SIGTERM, nach 3 s SIGKILL (`CodexSupport.swift:40`, `:98`).
- **Abbruch:** nur über den Knopf im Overlay (`RecordingCoordinator.swift:527`). Er beendet alle Diktat-Läufe, nie eine parallele Vorschau im Test-Labor (Besitzer-Kennung `CodexRunOwner`). **ESC wirkt in dieser Phase nicht:** Der ESC-Wächter reagiert nur bei Aufnahme und Transkription (`RecordingCoordinator+UI.swift:38` bis `:55`).
- **Fehler:** Exit-Code ungleich 0 wird zu einer kurzen Meldung verdichtet (`CodexErrorSummary`, Textsuche nach „requires a newer version“ und „not logged in“). Leere Antwort ist ein Fehler.
- **Rückfall:** Bei jedem Fehler nimmt WhisperM8 den Rohtext, solange die Einstellung „bei Fehler Rohtext“ an ist (Standard an, `RecordingCoordinator+Transcription.swift:253`). Für Slack, WhatsApp und E-Mail mit Antwort-Absicht kommt stattdessen ein vorsichtiger Platzhaltersatz („Ich prüfe das kurz …“, `:291`). Nach einem Abbruch durch den Nutzer kommt immer der Rohtext, ohne Fehlermeldung.

### Zwei Diktate kurz hintereinander

Es gibt keine Warteschlange. Solange ein Diktat in Transkription oder Nacharbeit ist, steht `isProcessing` auf wahr. Ein neuer Hotkey-Druck läuft in den Wächter von `startRecording()` (`RecordingCoordinator.swift:186`) und **wird stillschweigend verworfen**: keine Aufnahme, kein Ton, kein Hinweis. Wer während „Improving…“ weiterspricht, verliert das zweite Diktat. Bei 7 bis 15 s Nacharbeit ist das ein realer Fall.

Nur das Test-Labor darf parallel zur Nacharbeit laufen.

---

## 2. Messungen auf diesem Mac

Alle Werte stammen aus vorhandenen Daten, nichts wurde neu ausgelöst. Laufzeiten gibt es nur für den Modus **Task**, denn nur er hinterlässt eine Codex-Sitzung. Die anderen Modi laufen ephemer und tauchen nirgends mit Zeitstempel auf. Sie starten aber denselben Codex mit derselben Einrichtung, nur ohne Projektordner.

### Wartezeit (69 Task-Läufe, 13.10. bis 04.11.)

| Abschnitt | Mittel | jeder 10. Lauf über | Spitze |
|---|---|---|---|
| Codex-Start bis Prompt beim Modell | 3,1 s | 7,3 s | 12,9 s |
| Modell bis Antwort | 3,8 s | 8,0 s | 16,3 s |
| Gesamt laut Codex | 7,2 s | 14,2 s | 44,6 s |
| Codex fertig bis Bericht gespeichert (48 zuordenbare Läufe) | 3,5 s | 6,8 s | 10,9 s |

Nicht enthalten ist die Zeit vom Prozessstart bis zur ersten Codex-Zeile (Node-Start, Laden der 2.287 Zeilen langen `config.toml`). Allein `codex --version` braucht 0,2 s. Die letzte Zeile umfasst Prozessende (Codex beendet MCP-Server, Stop-Hook und Benachrichtigung laufen), die Suche nach der neuen Task-Sitzung und das Einfügen. Wie sich die 3,5 s darauf verteilen, lässt sich aus den Daten nicht trennen.

### Was Codex bei jedem Lauf mitschickt

Aus einer Rollout-Datei vom 04.11. (Task, 25.454 Token): Codex-Grundanweisung 21,8 KB, **Skill-Liste 41,6 KB**, Rollen- und Mehragenten-Text, Sandbox-Beschreibung. Das WhisperM8-Prompt selbst ist 3,6 bis 6,4 KB lang. Über alle 69 Läufe: im Mittel 25.723 Eingabe-Token, davon 13.184 aus dem Cache.

**Werkzeuge benutzt:** in 1 von 69 Task-Läufen. Der Modus ist als Agent gedacht, wird aber praktisch als Textmodus benutzt.

### GPT-Backend

| Messung | Wert |
|---|---|
| `GET /healthz` main (18765) und office (18775) | 0,7 ms und 0,6 ms |
| Transkription über den Proxy, office (64 Anfragen seit 08.10.) | Mittel 1,4 s, 62 erfolgreich, 2 Fehler |
| Transkription über den Proxy, main (948 Anfragen) | Mittel 1,6 s, 916 erfolgreich |
| Anfragen von Claude-Chats an main seit 28.09. | 9.212, davon 99,0 % erfolgreich |
| davon vor 15.10. (WebSocket) | 5.777: 41 × Limit (429), 4 × 502 |
| davon ab 15.10. (HTTP) | 3.435: 35 × 502 (Netzfehler zu chatgpt.com), 8 × 503 |

Die Antwortzeit eines direkten Nacharbeits-Aufrufs über den Proxy habe ich **nicht** gemessen, weil das Kontingent kostet. Siehe Abschnitt 8.

---

## 3. Das GPT-Backend als Ganzes

### Was es ist und wie WhisperM8 es betreibt

- `claude-code-proxy` von Raine Virta, Rust, MIT, 694 Sterne, 43 Mitwirkende, sehr aktiv (70 Releases seit April, Pflege fast allein durch den Maintainer). Er übersetzt Anthropic-Anfragen von Claude Code in Anfragen an `chatgpt.com/backend-api/codex/responses`, also an dieselbe Schnittstelle, die auch die Codex-CLI nutzt.
- WhisperM8 lädt das Binary selbst aus den GitHub-Releases (`ClaudeCodeProxyBinaryInstaller.swift`), prüft die Prüfsumme und hebt es beim App-Start automatisch auf die neueste Version (`ClaudeCodeProxyManager.swift:1002`). Installiert ist **v0.1.47** vom 25.10. Der feste Startwert für Neuinstallationen steht noch auf **0.1.42** (`ClaudeCodeProxyBinaryInstaller.swift:25`).
- Davor sitzt der eigene Router in der App (`ClaudeGPTMixRouter`, Port 18766). Er schickt Claude-Modelle an Anthropic und GPT-Modelle an die Proxy-Instanz des Kontos, das der Chat im Header nennt.
- **Konten:** je Konto ein eigener Proxy-Prozess mit eigenem Login (`~/.gpt-profiles/<name>`, gesetzt als `CCP_CONFIG_DIR` **und** als `HOME`), Ports ab 18775. Auf diesem Mac laufen main (18765) und office (18775).
- **Limits:** Die Anzeige holt Plan und Wochenlimits über `wham/usage` mit dem Token aus der Datei (`CodexUsageReader`). „Gesperrt, Kontingent erschöpft“ ist nur eine Anzeige (`GPTAccountsSection.swift:250`), eine echte Sperre im Router gibt es nicht.
- **Background-Agents** laufen immer über main.

### Was gut passt

- **Ein Proxy je Konto** ist der richtige Weg. Der Upstream kann bis heute nur ein Konto pro Prozess, und es ist auch nichts anderes geplant.
- **Modellangebot als Schnittmenge** aus Codex-Katalog und `/v1/models` des laufenden Proxys verhindert, dass WhisperM8 ein Modell anbietet, das der Proxy ablehnt.
- **Transkription über den Proxy** läuft stabil und schnell und zeigt, dass ein direkter Aufruf vom Diktat aus funktioniert (Port, Prewarm, Neustart bei „Connection refused“, saubere Fehlerliste).
- **Prüfsummen und Waisen-Schutz** beim Binary sind sorgfältig.

### Wo wir hinter dem Upstream stehen

- Installiert ist v0.1.47, und das ist zugleich das neueste **veröffentlichte** Release. v0.1.48 (01.11.) existiert nur als Tag: Der macOS-Build ist abgebrochen, ein GitHub-Release fehlt. Unser Auto-Update fragt `releases/latest` und bleibt deshalb auf 0.1.47.
- Damit fehlen uns aus v0.1.48: Giulianos PR #130 (Modellliste aus dem Codex-Cache, vom Maintainer neu umgesetzt), Transport `auto` mit Rückfall auf HTTP (#173), Limitdaten pro Antwort (`codex_rate_limits`, #149), `gpt-6.1-terra` und Reparaturen bei leeren Antworten.
- Der Fork `GiulianoCosta71/claude-code-proxy` wird nicht mehr gebraucht. Er liegt 125 Commits zurück. Auf dem Zweig `parallel-tool-policy` liegen zwei Commits, die nie als PR eingereicht wurden.

### Was wir selbst gebaut haben und der Upstream inzwischen kann

| Thema | WhisperM8 | Upstream | Folge |
|---|---|---|---|
| Langes Warten bei erschöpftem Limit | Doku sagt: rund 170 s Wiederholung, Abbruch im Router „offen“ | seit v0.1.40 (#139) sofort 429 mit `retry-after` | Doku `gpt-konten.md` ist veraltet. Statt eigener Erkennung reicht es, den 429 sauber anzuzeigen. Live nicht geprüft. |
| Geteiltes Proxy-Log | Doku sagt: alle Instanzen schreiben in dieselbe Datei | Log folgt `HOME` | Durch unseren `HOME`-Trick hat office längst ein eigenes Log unter `~/.gpt-profiles/office/.local/state/…`. Doku veraltet. |
| Modell-Allowlist | eigener Fork, dann Schnittmenge | ab v0.1.48 Codex-Cache eingebaut | Schnittmenge bleibt sinnvoll, wird aber einfacher, sobald 0.1.48 veröffentlicht ist. |
| WebSocket-401-Wellen | per Hand `transport: http` in der main-Config | ab v0.1.48 `auto` mit HTTP-Rückfall | Gilt bisher nur für main, siehe Bruchstellen. |

### Bruchstellen

1. **Konto office läuft über WebSocket.** Die HTTP-Einstellung liegt nur in `~/.config/claude-code-proxy/config.json`. Das Profil hat keine eigene `config.json`, also gilt der Standard von v0.1.47: WebSocket. Belegt im Log: 5.122 Antworten über WebSocket, Abbrüche „WebSocket connection closed before terminal Codex response event“ nach 177 s. Genau dieses Konto ist das aktive und trägt die Diktat-Transkription.
2. **Auto-Update ohne Prüfung.** Jede neue Version wird beim App-Start übernommen, sobald ihre Prüfsumme stimmt. Die Prüfsumme sagt aber nur, dass die Datei vollständig ist, nicht dass die Version gut ist. Beispiel aus dem Upstream: Ab v0.1.43 trat ein 403 beim WebSocket-Aufbau auf (#172), mit 0.1.42 nicht.
3. **Inoffizielle Schnittstelle.** Der Proxy ahmt die Codex-CLI nach. Das README warnt selbst: „Unofficial clients may carry account risk“. Transkription und Bilder laufen über eine interne Schnittstelle, die sich jederzeit ändern kann. Ein offizieller Weg über „Sign in with ChatGPT“ ist als #199 erst vorgeschlagen.
4. **Anmeldung an zwei Stellen.** Transkription und Claude-Chats nutzen das aktive GPT-Konto, die Nacharbeit nutzt den Codex-CLI-Login (`~/.codex/auth.json`). In einem Diktat können also zwei verschiedene Konten arbeiten. Wer bei leerem Kontingent das GPT-Konto wechselt, rettet die Nacharbeit damit nicht.
5. **Altlast im Login-Pfad.** Der Proxy liest und löscht immer auch `$HOME/.config/claude-code-proxy/codex/auth.json`, egal was `CCP_CONFIG_DIR` sagt (`src/providers/codex/auth/token_store.rs:52` bis `:66`, `src/paths.rs:104`). Deshalb müssen wir `HOME` je Profil umbiegen. Funktioniert, ist aber ein Umweg, der jedes vom Proxy gestartete Unterprogramm mit falschem `HOME` laufen lässt.
6. **Fehlerordner wächst.** `~/.local/state/claude-code-proxy/errors` hat 16.673 Dateien (65 MB) seit Juli. Inhalt geprüft: Metadaten ohne Prompt-Text. Trotzdem räumt niemand auf.
7. **Profil-Waisen.** Laut Doku werden Instanzen auf Ports ab 18775 nach einem harten App-Ende nicht aufgeräumt.

### Was in den Upstream gehört

- Den Altlast-Pfad nur lesen, wenn `CCP_CONFIG_DIR` **nicht** gesetzt ist, und das State-Verzeichnis optional an `CCP_CONFIG_DIR` koppeln. Dann fällt unser `HOME`-Trick weg.
- `/healthz` um Version und Anmeldestatus erweitern (oder ein kleines `/status`). Heute erkennen wir die Version per `--version`-Aufruf und die Transkriptions-Route über einen Trick mit Statuscode 415 gegen 404.
- Die offenen PRs #62 (`GET /usage`) und #127 (Limit-Header durchreichen) unterstützen. Dann käme die Limit-Anzeige aus dem laufenden Proxy statt aus einem womöglich veralteten Datei-Token.
- Aufräumregel für `errors/`.
- Beim Maintainer nachfragen, ob der abgebrochene macOS-Build von v0.1.48 wiederholt wird. Erst dann ist #130 bei uns angekommen.

Mehrere Konten in einem Prozess gehören **nicht** in den Upstream. Das wäre ein großer Umbau gegen die Linie des Projekts, und unser Modell mit einer Instanz je Konto funktioniert.

---

## 4. Vergleich: Codex-CLI gegen GPT-Backend für die Nacharbeit

| Punkt | Codex-CLI heute | GPT-Backend direkt |
|---|---|---|
| **Wartezeit** | Start im Mittel 3,1 s (bis 12,9 s), dazu Modell 3,8 s, dazu Prozessende. Gesamt im Mittel über 7 s, jeder 10. Lauf über 14 s. | Proxy läuft bereits, Verbindung unter 1 ms. Übrig bleibt die Modellzeit mit einem etwa 15-mal kleineren Prompt. Erwartet: deutlich unter der Hälfte. **Nicht gemessen.** |
| **Zuverlässigkeit** | 99 von 99 ohne Rückfall. Offizieller Client, Fehler fast nur bei fehlendem Login oder zu alter CLI. | Hauptkonto ab 15.10. rund 1,3 % Fehler, fast alles Netzabbrüche zu chatgpt.com bei langen Chat-Anfragen. Kurze Anfragen sind weniger gefährdet, ein einfacher Wiederholversuch fängt den Rest. Hängt am laufenden Proxy. |
| **Kosten und Kontingent** | Flatrate, keine Abrechnung je Aufruf. Aber rund 25.700 Token pro Diktat, davon 90 % Codex-Beiwerk. | Flatrate, ebenfalls keine Abrechnung je Aufruf. Etwa 1.500 bis 2.500 Token pro Diktat. Belastet das Wochenlimit also nur zu einem Bruchteil. Kontowechsel bei leerem Limit möglich. |
| **Anmeldung und Abhängigkeiten** | Codex-CLI muss installiert und eingeloggt sein (Node, npm). Eigener Login neben dem GPT-Backend. | GPT-Backend muss eingeschaltet sein (Labs) und das aktive Konto angemeldet. Kein Node, kein zweiter Login. |
| **Datenfluss** | Prompt, Kontext und Bilder an OpenAI. Zusätzlich lokal: Task schreibt Sitzungen nach `~/.codex/sessions` (inzwischen 4,1 GB gesamt). Die Hooks des Nutzers (Superset-`notify.sh`) und das Computer-Use-Programm sind für jeden Codex-Lauf eingerichtet. Ob sie im `exec`-Modus feuern und was sie erhalten, habe ich nicht geprüft. | Prompt, Kontext und Bilder an OpenAI über dieselbe Schnittstelle. Lokal nur Logzeilen ohne Text. Keine fremden Hooks, keine Werkzeuge. |
| **Wartbarkeit** | Eigene Prozessverwaltung (Registry, Zeitlimit, SIGTERM/SIGKILL, Pipes), Fehlererkennung über Textsuche in der CLI-Ausgabe, Statusprobe als eigener Prozess. Bricht, wenn die CLI ihre Texte ändert. | Ein HTTP-Aufruf, Abbruch über normale Task-Abbrüche. Vorlage existiert bereits in der Transkription. Hängt dafür an einem inoffiziellen Projekt eines Einzelnen. |
| **Können** | Kann im Projekt lesen und Befehle ausführen (Task, Ultra-Prompt). | Nur Text und Bilder rein, Text raus. Kein Projektzugriff. |

**Zu Giulianos Vermutung:** Das Backend ist nicht „an sich besser“. Beide sprechen mit demselben Dienst und denselben Modellen. Besser ist der **Weg**: kein Programmstart je Diktat und kein mitgeschleppter Ballast. Für Modi, die im Projekt lesen, ist die CLI weiter die bessere und die einzig erlaubte Wahl (WhisperM8 baut keine eigene Agent-Laufzeit).

---

## 5. Technische Schulden, Logik, Effizienz

Geordnet nach Gewicht.

**Hoch**

1. **Codex lädt bei jedem Diktat die volle Einrichtung.** MCP-Server (darunter zwei `npx …@latest`, die jedes Mal npm fragen), Plugins, Skill-Liste, Hooks. Kostet im Mittel 3,1 s, im schlechten Fall über 10 s, und rund 20.000 Token Ballast. Sofortmaßnahme auch ohne Backend: `codex exec --ignore-user-config` für Modi ohne Projektzugriff. Laut `codex exec --help` bleibt die Anmeldung dabei erhalten. Ob damit auch die Skill-Liste wegfällt, muss ein Testlauf zeigen.
2. **Zweites Diktat geht verloren.** Kein Hinweis, keine Warteschlange (`RecordingCoordinator.swift:186`). Mindestens ein Signal (Ton, kurzer Overlay-Hinweis) ist nötig, besser wäre: Aufnahme annehmen und hinten anstellen.
3. **Nach jedem Task-Diktat ein Vollscan im Hauptthread.** `latestTaskAgentSession()` (`RecordingCoordinator+Transcription.swift:277`) liest mit leerem Cache alle 471 Sitzungsdateien unter `~/.codex/sessions` (4,1 GB, nur Kopfdaten) und mischt sie in den Workspace, und zwar im `@MainActor`. Das widerspricht der Regel „kein I/O und kein Session-Scan im Hauptthread“ und ist ein Kandidat für einen Teil der gemessenen 3,5 s nach Codex-Ende. Eine Zeitmessung dafür gibt es nicht.

**Mittel**

4. **ESC bricht die Nacharbeit nicht ab**, nur der Overlay-Knopf (`RecordingCoordinator+UI.swift:38` bis `:55`).
5. **Zeitlimit 5 bzw. 15 Minuten** für einen Umschreibe-Auftrag. Zusammen mit Punkt 2 heißt ein Hänger: bis zu 5 Minuten kein Diktieren möglich. Für reine Textmodi reichen 60 bis 90 s.
6. **Zwei Konten in einem Diktat** (siehe Bruchstelle 4).
7. **Statusprobe als eigener Prozess.** `codex login status` startet alle 5 Minuten im Diktatpfad einen weiteren Node-Prozess (laut Code-Kommentar 100 bis 400 ms).
8. **Fehlererkennung über Textsuche** in der CLI-Ausgabe (`CodexErrorSummary`, `CodexPostProcessor.swift:176` ff.). Eine geänderte Formulierung in einer neuen CLI-Version, und die Meldung wird unverständlich oder der Login-Cache wird nicht mehr zurückgesetzt.
9. **Task ist als Agent gebaut, wird aber als Textmodus benutzt.** 68 von 69 Läufen ohne Werkzeug, trotzdem nicht ephemer und mit Projektordner. Klären, was Task sein soll.

**Niedrig**

10. Prompt wird zweimal gebaut, die Vorlagen zweimal von der Platte gelesen (`processTranscriptIfNeeded` und `CodexPostProcessor.process`).
11. Keine Zeitmessung der Nacharbeit: kein Signpost, keine Dauer im Diktat-Bericht. Die Zahlen oben mussten aus Codex' Datenbank gefischt werden.
12. Statustext „Abgebrochen…“ ist fest auf Deutsch und nicht übersetzt (`RecordingCoordinator.swift:530`).
13. Stufe `fast` (Priority) gilt auch für Clean. Das verbraucht Kontingent schneller, ohne dass man den Unterschied bei einem kurzen Text merkt.

---

## 6. Empfehlung zum Diktat

**Beides, mit Rückfall.**

- **Über das GPT-Backend:** Clean, Fast Prompt, Prompt, Email, Slack, WhatsApp, Notes und eigene Modi ohne Projektzugriff, sobald das Backend eingeschaltet und das aktive Konto angemeldet ist.
- **Über die Codex-CLI:** Ultra-Prompt und Task (Projektzugriff), alle Nutzer ohne GPT-Backend und die Kommandozeile `whisperm8 transcribe --mode` (wie bei der Transkription bleibt die CLI-Seite unabhängig von der App).
- **Rückfall:** Ist das Backend nicht erreichbar oder antwortet es mit einem Fehler, bevor Text kommt, läuft derselbe Auftrag über die Codex-CLI wie heute. Erst wenn auch das scheitert, greift der bekannte Rückfall auf den Rohtext. Ein Rückfall auf die CLI ist hier vertretbar, anders als bei der Transkription: Die Daten gehen in beiden Fällen an denselben Anbieter.

**Für:** spürbar kürzere Wartezeit, ein Bruchteil des Kontingents, ein Konto für das ganze Diktat, kein Node-Start, einfacherer Abbruch. **Wider:** ein zweiter Weg im Code, Abhängigkeit vom inoffiziellen Proxy, Backend bleibt eine Labs-Funktion. Der Rückfall auf die CLI fängt den Ausfall des Proxys auf.

**Was sich beim Umbau ändert:**

- Neu: `GPTBackendPostProcessor` in `Services/Dictation/`, erfüllt das vorhandene Protokoll `PostProcessing`. Ein Aufruf `POST http://127.0.0.1:<port>/v1/messages` an die Instanz des aktiven Kontos, Text plus Bilder als Base64, Denktiefe über `output_config.effort` (im Upstream belegt: `src/providers/translate_shared.rs:69` ff.), Priority über die Modellendung `-fast`. Ohne Streaming, Zeitlimit 60 bis 90 s.
- Übernehmen aus der Transkription: Konto und Port bestimmen, bei „Connection refused“ einmal starten und einmal wiederholen, die Fehlerliste.
- `PostProcessingService` wählt je Modus den Weg und übernimmt den Rückfall.
- Einstellungen, Seite AI-Output → Konto: anzeigen, welcher Weg und welches Konto gilt. Ein Schalter dafür (mit UI-Weg, Eintrag in `PreferenceBedienweg.swift`, Übersetzung).
- Diktat-Bericht: Weg und Dauer der Nacharbeit mitschreiben.
- Tests: Form der Anfrage, Fehlerzuordnung, Rückfall, Abbruch. Doku in `docs/features/dictation/ai-output/` und `gpt-konten.md`.
- Unverändert: Vorlagen, Prompts, Overlay, Auslieferung, Task und Ultra-Prompt.

Größenordnung: ein überschaubarer Umbau an einer klar abgegrenzten Stelle, grob 400 bis 700 Zeilen mit Tests.

**Unabhängig davon sinnvoll:** Punkte 2, 4 und 5 aus Abschnitt 5 (verlorenes zweites Diktat, ESC, Zeitlimit) und `--ignore-user-config` für den CLI-Weg.

---

## 7. Empfehlung zum GPT-Backend

Nach Nutzen geordnet.

1. **HTTP-Transport für alle Instanzen erzwingen.** `CCP_CODEX_TRANSPORT=http` zentral in `launchEnvironment(forProfile:)` setzen statt per Hand in einer Config-Datei. Betrifft heute das aktive Konto office. *WhisperM8, klein.*
2. **Auto-Update entschärfen.** Neue Versionen erst nach einigen Tagen übernehmen, nach dem Wechsel kurz `/healthz` und `/v1/models` prüfen, bei Fehler zur vorherigen Version zurück. Den festen Startwert von 0.1.42 auf 0.1.47 heben. *WhisperM8.*
3. **Limit sauber behandeln.** Seit dem Upstream-Fix kommt ein 429 mit Zeitangabe sofort. Im Chat und im Diktat klar sagen „Konto x ist bis … leer“ und den Wechsel auf ein anderes Konto mit einem Klick anbieten, ohne stillen Wechsel. Doku zu den 170 s und zum geteilten Log korrigieren. *WhisperM8.*
4. **Diktat-Nacharbeit über das Backend** wie in Abschnitt 6. *WhisperM8.*
5. **Altlast-Pfad und State-Verzeichnis an `CCP_CONFIG_DIR` koppeln.** Danach kann der `HOME`-Trick weg. *Upstream-PR.*
6. **Version und Anmeldestatus in `/healthz`.** Ersetzt `--version`-Aufrufe und die 415/404-Probe. *Upstream-PR.*
7. **Limits aus dem Proxy statt aus der Datei.** PRs #62 und #127 unterstützen, später unsere Anzeige darauf umstellen. *Upstream, danach WhisperM8.*
8. **v0.1.48 abholen.** Beim Maintainer den abgebrochenen macOS-Build ansprechen. *Upstream, ein Kommentar.*
9. **Aufräumen:** Profil-Waisen beim App-Start beenden (*WhisperM8*), Aufräumregel für `errors/` (*Upstream*). Den Fork archivieren und die zwei Commits auf `parallel-tool-policy` gegen den heutigen Upstream prüfen, bevor sie verloren gehen.

---

## 8. Was offen ist

- **Echter A/B-Vergleich der Wartezeit.** Je 10 bis 20 kurze Clean-Aufträge über die CLI (mit und ohne `--ignore-user-config`) und über das Backend. Kostet kein Geld, aber etwas Wochenkontingent auf zwei Konten. Nur mit Giulianos Freigabe.
- Ob Codex im `exec`-Modus Hooks und das Benachrichtigungsprogramm auslöst und welche Daten die Hooks bekommen.
- Wie viel der 3,5 s nach Codex-Ende auf den Session-Scan entfällt (braucht eine Messung in der laufenden App, das Systemprotokoll war aus diesem Chat nicht lesbar).
- Verhalten des Proxys bei leerem Limit in v0.1.47, live.

---

## Für dich jetzt

Die eine Entscheidung: **Sollen die reinen Textmodi (Clean, Prompt, Mail, Slack, WhatsApp, Notes) künftig über das GPT-Backend laufen, mit der Codex-CLI für Task und Ultra-Prompt und als Rückfall?**

Meine Empfehlung: **Ja.** Als ersten Schritt den kleinen A/B-Vergleich aus Abschnitt 8 freigeben, damit wir den Zeitgewinn schwarz auf weiß haben, bevor gebaut wird. Die HTTP-Einstellung für das Konto office würde ich unabhängig davon sofort beheben, das ist eine Kleinigkeit mit klarem Nutzen.
