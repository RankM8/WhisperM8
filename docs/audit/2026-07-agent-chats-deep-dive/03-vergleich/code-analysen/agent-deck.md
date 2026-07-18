# agent-deck

## Untersuchungsrahmen

Analysiert wurde ausschließlich der lokale Klon von `agent-deck` unter dem vorgegebenen Pfad, Stand `c0d1d0c960da54eb5dea5e66262b978e73f38c03`. Die Zeilenangaben beziehen sich auf diesen Stand. WhisperM8-Code wurde entsprechend der Aufgabenregel nicht gelesen; der Vergleich stützt sich deshalb auf das vorgegebene Wrapper-Modell: native macOS-App, echte Claude-Code-CLI in SwiftTerm-PTYs sowie headless `claude -p` und `claude --bg`.

Vorgesehener Reportpfad: `docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-deck.md`.

## Kurzfazit

Die drei wichtigsten übertragbaren Muster sind:

1. **Fork als expliziter Identitätsübergang:** Agent Deck erzeugt die neue Claude-Session-ID vor dem Prozessstart und startet den Fork mit der eindeutigen Kombination `--session-id <kind> --resume <elternteil> --fork-session`. Für WhisperM8 sollte daraus ein dauerhaftes, zweiphasiges Fork-Datenmodell werden, nicht nur eine Startkommando-Variante.
2. **Wrapper-, CLI- und Prozessidentität getrennt halten:** Agent Deck unterscheidet seine stabile Instanz-ID, die Claude-Session-ID und die tmux-Verbindungsidentität. Diese Trennung passt unmittelbar zu WhisperM8: Workspace-/Chat-ID, Claude-Session-ID und PTY-Prozessinkarnation dürfen nie als dieselbe Identität behandelt werden.
3. **Ein aufgelöster Claude-Kontext pro Session:** Agent Deck besitzt eine starke Hierarchie für gruppen- und accountbezogenes `CLAUDE_CONFIG_DIR`, verwendet diesen Kontext aber nicht lückenlos beim JSONL-Lesen und bei der Wiederherstellung. WhisperM8 sollte Spawn, Resume, Fork, Hooks, JSONL, Recovery und Kollisionsprüfung zwingend über dasselbe aufgelöste Kontextobjekt führen.

Agent Deck ist besonders stark bei der Entkopplung von TUI und langlebigem CLI-Prozess sowie bei konservativer Session-Recovery. Seine größte Schwäche für das Fork/Resume-Problem ist, dass der Fork zwar als eigener Startpfad, aber nicht als dauerhaft protokollierte Eltern-/Kind-Operation modelliert wird.

## 1. Projektüberblick

Agent Deck ist eine Go-TUI auf Basis von Bubble Tea. Claude Code und andere Agenten laufen nicht innerhalb der TUI selbst, sondern in abgekoppelten tmux-Sessions. Die TUI verbindet sich über ein PTY mit tmux und kann dadurch beendet und später wieder geöffnet werden, ohne den eigentlichen Agentenprozess zwangsläufig zu beenden.

Relevanter Stack und Einstiegspunkte:

| Bereich | Beleg | Bedeutung |
|---|---|---|
| Go-Modul und Version | `go.mod:1-3` | Go-Anwendung, im analysierten Stand Go 1.25.12 |
| Bubble Tea, Lipgloss und PTY-Abhängigkeiten | `go.mod:10-15` | Terminal-UI, Darstellung und PTY-Anbindung |
| SQLite-Abhängigkeit | `go.mod:38` | Persistente Zustandsdatenbank |
| TUI-Programmaufbau | `cmd/agent-deck/main.go:23-35` | Hauptanwendung und zentrale Pakete |
| Start des Bubble-Tea-Programms | `cmd/agent-deck/main.go:879-884` | UI-Lebenszyklus ist vom Agentenprozess getrennt |
| Zentrales Sessionmodell | `internal/session/instance.go:117-220` | Wrapper-Instanz, Account- und Tool-Identität |
| Persistenzmodell | `internal/session/storage.go:38-103` | Serialisierte Instanzmetadaten |
| SQLite-Schema | `internal/statedb/statedb.go:385-415` | Dauerhafte Instanzfelder einschließlich Claude-ID und tmux-Socket |
| Sessionauswahl | `internal/ui/session_switcher.go:27-165` | UI-Auswahl arbeitet auf Wrapper-Instanzen |
| Fork-Kommando | `internal/session/instance.go:7323-7443` | Erzeugung von Child-ID, Startkommando und neuer Wrapper-Instanz |
| Resume-Kommando | `internal/session/instance.go:6923-7029` | Entscheidung zwischen `--resume` und neuer `--session-id` |
| tmux-/PTY-Schicht | `internal/tmux/tmux.go:1236-1269`, `internal/tmux/pty.go:258-570` | Langlebiger Agentenprozess und robuste UI-Anbindung |
| Accountauflösung | `internal/session/claude.go:295-390`, `internal/session/claude.go:466-507` | Hierarchie für `CLAUDE_CONFIG_DIR` |

Architektonisch ist Agent Deck damit ebenfalls ein Host der echten CLI. Der wesentliche Unterschied zu WhisperM8 besteht nicht in einer Eigen-Chat-Runtime, sondern in der Prozesshülle: Agent Deck setzt tmux als langlebigen Zwischenmanager ein, während WhisperM8 laut Aufgabenbeschreibung die echte CLI direkt in SwiftTerm-PTYs hostet.

## 2. Session-Identität und Wechsel der aktiven Session

### 2.1 Drei getrennte Identitätsebenen

Agent Deck modelliert mindestens drei voneinander unabhängige Identitäten:

1. **Persistente Wrapper-Identität:** `Instance.ID` identifiziert den Agent-Deck-Eintrag. Daneben speichert die Instanz Titel, Arbeitsverzeichnis, Gruppe, Reihenfolge und weitere UI-/Startmetadaten (`internal/session/instance.go:117-130`).
2. **Claude-Session-Identität:** `ClaudeSessionID` liegt separat von der Wrapper-ID. Auch Tooltyp und toolspezifische IDs sind eigene Felder (`internal/session/instance.go:198-220`).
3. **Prozess-/Verbindungsidentität:** Die tmux-Session beziehungsweise ihr Socketname wird separat verwaltet. Kommentare im Modell erklären ausdrücklich, warum der Socketname gespeichert werden muss (`internal/session/instance.go:264-276`). Die Persistenz übernimmt das Feld in `internal/session/storage.go:58-62`.

Diese Trennung ist auch im Datenbankschema sichtbar: Instanz-ID, Claude-Session-ID, Parent-/Conductor-Zuordnung, Socket und Account werden als getrennte Spalten abgelegt (`internal/statedb/statedb.go:385-415`). Die Umsetzung zwischen Datenbankzeile und Laufzeitobjekt erfolgt unter anderem in `internal/session/storage.go:825-875`; Laden und Rekonstruktion liegen in `internal/session/storage.go:945-1019` und `internal/session/storage.go:1083-1138`.

Damit ist die aktive Session nicht gleichbedeutend mit dem gerade laufenden Prozess. Ein Prozess kann weiterlaufen, während keine TUI daran hängt; umgekehrt kann eine persistente Instanz existieren, deren tmux-Prozess nicht mehr lebt.

### 2.2 UI-Auswahl ist nur ein Zeiger auf die Wrapper-Identität

Der Session-Switcher hält eine Liste von `Instance`-Objekten, Cursorzustand und die ID, von der aus der Wechsel geöffnet wurde (`internal/ui/session_switcher.go:27-48`). Er filtert, sortiert und präselektiert Instanzen, ohne deren Claude- oder Prozessidentität umzuschreiben (`internal/ui/session_switcher.go:79-134`). Das Ergebnis ist erneut eine ausgewählte Wrapper-Instanz (`internal/ui/session_switcher.go:159-165`). Der eigentliche Wechsel wird anhand ihrer stabilen Agent-Deck-ID übernommen (`internal/ui/home.go:18611-18620`).

Beim Anhängen an eine Session verbindet die UI sich mit deren tmux-Backend und synchronisiert anschließend erkannte Session-IDs, ohne allein für den UI-Wechsel einen neuen Claude-Prozess zu starten (`internal/ui/home.go:12762-12781`).

### 2.3 Bewertung für WhisperM8

**Besser als ein prozessorientiertes Modell:** Agent Deck vermeidet die typische Verwechslung von „ausgewähltem Chat“, „laufendem Prozess“ und „Claude-Konversation“. Für WhisperM8 ist das direkt übertragbar. Eine robuste Session sollte mindestens folgende Schlüssel besitzen:

- stabile WhisperM8-Session-ID,
- Claude-Session-ID,
- aktuelle PTY-/Prozessinkarnation,
- optional Headless-Job-ID,
- Workspace- und Accountkontext.

**Nicht direkt besser als WhisperM8:** tmux ist eine zusätzliche Prozessschicht und kein zwingender Bestandteil des geforderten nativen SwiftTerm-Modells. WhisperM8 sollte nicht auf eine Eigen-Chat-UI oder Agent-SDK-Runtime wechseln. Übertragbar ist die Identitätstrennung, nicht zwingend tmux selbst.

## 3. Fork und Resume als Identitätsübergänge

### 3.1 Fork besitzt einen eigenen CLI-Pfad

Agent Deck behandelt Fork nicht als gewöhnliches Resume mit anschließendem Erraten der neuen ID. `CanFork` prüft zunächst, ob für die Claude-Instanz eine ausreichend belastbare Session-ID vorhanden ist (`internal/session/instance.go:7224-7252`). Auch der CLI-Befehl validiert Tooltyp und benötigte Session-ID und versucht fehlende Identität vor dem Fork zu erfassen (`cmd/agent-deck/session_cmd.go:863-955`). Die Zielgruppe wird separat aufgelöst (`cmd/agent-deck/session_cmd.go:957-969`).

Der Kern liegt in `internal/session/instance.go:7323-7366`:

- Vor dem Spawn wird eine neue Child-Session-ID erzeugt.
- Die neue ID wird in der Zielinstanz hinterlegt.
- Der erste Prozessstart erhält Eltern- und Kindidentität gleichzeitig.

Das erzeugte Claude-Kommando entspricht semantisch:

```text
exec claude --session-id <child-id> --resume <parent-id> --fork-session
```

Damit sind die Rollen der IDs beim ersten Start eindeutig: `--resume` bezeichnet die Quelle, `--session-id` das neue Ziel. Dieses Muster verhindert, dass ein Fork versehentlich unter der Eltern-ID weiterarbeitet.

### 3.2 Der Fork erzeugt eine neue Wrapper-Instanz

`ForkInstance` legt eine neue Agent-Deck-Instanz an und kopiert relevante Eigenschaften wie Gruppe, Tool, Wrapper, zusätzliche CLI-Argumente, Optionen und gegebenenfalls Worktree-Kontext (`internal/session/instance.go:7385-7443`). Der Fork ist daher in der UI und im persistenten Instanzbestand ein eigenständiger Eintrag und nicht bloß ein Modus der Elterninstanz.

Der Kommandoablauf erzeugt die Instanz, startet sie, synchronisiert Identitäten, fügt sie dem Bestand hinzu und speichert anschließend (`cmd/agent-deck/session_cmd.go:1214-1265`). Die Ausgabe führt Eltern- und neue Session-ID getrennt auf (`cmd/agent-deck/session_cmd.go:1268-1276`).

### 3.3 Der erste Fork-Start ist ein flüchtiger Sonderzustand

Der vorbereitete Startbefehl wird über `IsForkAwaitingStart` und `ForkStartCommand` gehalten. Beide Felder sind ausdrücklich von der JSON-Persistenz ausgeschlossen (`json:"-"`) (`internal/session/instance.go:350-365`). Der Startpfad konsumiert diesen Sonderzustand, bevor er in den normalen Resume-/Start-Builder fällt (`internal/session/instance.go:1806-1813`, `internal/session/instance.go:3339-3354`).

Das trennt zwar den einmaligen Fork-Start vom späteren Resume, führt aber zu einem Crash-Fenster:

1. Child-ID und Wrapper werden im Speicher vorbereitet.
2. Der tmux-/Claude-Prozess wird gestartet.
3. Erst danach wird die Instanz dauerhaft gespeichert.

Ein Absturz zwischen Prozessstart und Speicherung kann deshalb einen laufenden, aber nicht registrierten Fork hinterlassen. Weil der besondere Fork-Startbefehl nicht persistiert wird, lässt sich auch ein Absturz vor dem erfolgreichen Spawn nicht als vorbereitete Operation fortsetzen.

### 3.4 Resume ist ein anderer Übergang

Der normale Claude-Startpfad untersucht, ob zur gespeicherten Session-ID bereits belastbare Konversationsdaten existieren. Wegen einer möglichen Flush-Verzögerung wird die Prüfung kurz wiederholt (`internal/session/instance.go:6923-7029`). Gibt es Daten, wird ein Resume-Kommando gebaut; andernfalls wird die ID als neue Session über `--session-id` gestartet.

Das ist eine sinnvolle Trennung:

- **Neuanlage:** neue Identität ohne Vorgänger,
- **Resume:** bestehende Identität wird fortgesetzt,
- **Fork:** neue Identität wird aus einer bestehenden Identität abgeleitet.

Nach einem erfolgreichen Fork muss jeder spätere Start die Child-ID resumieren. Die Eltern-ID gehört nur zum ersten Fork-Übergang.

### 3.5 Keine dauerhafte Fork-Lineage gefunden

Das vorhandene Feld `ParentSessionID` ist nach den geprüften Aufrufstellen keine zuverlässige Fork-Elternbeziehung. Der Forkdialog beschreibt es im Zusammenhang mit einer Conductor-/Gruppenbeziehung (`internal/ui/forkdialog.go:170-183`). Quick-Fork übernimmt den bisherigen Conductor (`internal/ui/home.go:11396-11415`), und beim Erstellen wird das Feld nur in diesem Kontext gesetzt (`internal/ui/home.go:11883-11885`). Der eigentliche Fork-Builder setzt keine dauerhafte `forkedFromSessionID`-Beziehung.

Im untersuchten Code wurde weder eine eigene Fork-Operationstabelle noch ein persistentes Feldpaar aus Source-Wrapper-ID und Source-Claude-ID gefunden. Dadurch kann Agent Deck zwar korrekt forken, aber später nicht aus seinem Datenmodell sicher erklären:

- aus welcher Wrapper-Instanz der Fork entstand,
- welche Claude-ID die Quelle war,
- ob der erste Fork-Start vollständig verifiziert wurde,
- ob ein laufender Child-Prozess zu einer nur teilweise gespeicherten Operation gehört.

### 3.6 Risiko durch nicht übernommenen Account

`ForkInstance` kopiert viele Eigenschaften, aber in dem geprüften Kopierpfad wurde keine Übernahme des Instanzfelds `Account` gefunden (`internal/session/instance.go:7385-7443`). Bei gruppenspezifischem Account kann die Gruppe dies indirekt auffangen. Bei einem expliziten instanzbezogenen Account kann der Fork jedoch in einen anderen aufgelösten Claude-Kontext fallen als die Quelle.

### 3.7 Direkter Vergleich zu WhisperM8

**Für WhisperM8 unmittelbar besser:** Die vorab erzeugte Child-ID und der exakte erste Aufruf mit `--session-id`, `--resume` und `--fork-session` sind die stärkste Quelle im Projekt. WhisperM8 sollte einen Fork nie dadurch identifizieren, dass nach dem Start „die neueste JSONL-Datei“ gesucht wird.

**Für WhisperM8 unzureichend:** Ein nur im Speicher gehaltener Fork-Startzustand reicht bei App-Absturz, PTY-Fehler oder verzögertem Hook nicht aus. WhisperM8 braucht eine dauerhafte Fork-Operation mit Eltern-/Kind-Beziehung und Fortschrittsstatus.

## 4. Verlorene oder nicht wiedergefundene Sessions

### 4.1 Persistente Metadaten und UPSERT statt Snapshot-Löschung

Agent Deck speichert Instanzen profilbezogen in einer Zustandsdatenbank (`internal/session/storage.go:1193-1205`). `SaveWithGroups` verwendet UPSERTs und vermeidet bewusst das Löschen aller nicht in einem möglicherweise veralteten In-Memory-Snapshot enthaltenen Datensätze. Der Kommentar beschreibt genau das Risiko, dass parallele oder ältere Zustände sonst Sessions vernichten könnten (`internal/session/storage.go:303-360`).

Das ist für WhisperM8 sehr wertvoll: Sessionpersistenz sollte nicht als „gesamte Liste ersetzen“ implementiert werden, wenn PTY-, Hook- und Headless-Ereignisse konkurrierend eintreffen. Identitätsfelder sollten gezielt und transaktional aktualisiert werden.

### 4.2 Wiederverbindung ohne impliziten Neustart

Beim Laden werden gespeicherte Instanzen rekonstruiert (`internal/session/storage.go:1038-1154`). Die Verbindung zum Backend erfolgt lazy; das Laden der UI startet nicht automatisch jeden Agentenprozess neu (`internal/session/storage.go:1266-1311`). Der gespeicherte tmux-Socket ist dabei wesentlich, weil nur damit das richtige Backend wiedergefunden werden kann (`internal/session/storage.go:1285-1291`).

Agent Deck unterscheidet damit sauber:

- persistente Session vorhanden,
- Backend lebt und kann wieder verbunden werden,
- Backend ist tot und benötigt eine bewusste Aktion.

### 4.3 Gespeicherte oder explizit gesetzte ID ist autoritativ

Wenn eine Claude-ID explizit übergeben wurde, behandelt Agent Deck sie als maßgeblich (`internal/session/instance.go:3140-3165`). Bei brandneuen Sessions ohne frühere Erkennung wird bewusst nicht sofort die Festplatte nach irgendeiner aktuellen JSONL-Datei durchsucht (`internal/session/instance.go:3168-3244`, insbesondere `internal/session/instance.go:3218-3225`). Eine breitere Recovery ist für tatsächliche Neustartfälle getrennt (`internal/session/instance.go:3246-3291`).

Dieses konservative Verhalten verhindert, dass eine zufällig zuletzt geänderte Session eines anderen Terminals an die aktuelle Wrapper-Instanz gebunden wird.

### 4.4 Hook-Rebinding und gezielte Datenbankupdates

Akzeptierte Hook-Ereignisse können die erkannte Claude-Session-ID in Laufzeitobjekt, tmux-Metadaten und Datenbank aktualisieren (`internal/session/instance.go:8198-8251`). Dabei weist der Code selbst auf das Risiko hin, dass ein vollständiges Speichern einer veralteten Instanz eine gerade eingegebene oder anderweitig aktualisierte Session-ID überschreiben könnte (`internal/session/instance.go:8232-8243`). Deshalb ist das gezielte Update einzelner Identitätsfelder die sicherere Form.

Hook-Ereignisse aus terminalen Phasen werden nicht mehr zur Identitätsbindung verwendet (`internal/session/instance.go:4598-4612`). Kandidaten ohne passende Konversationsdaten – etwa fremde `claude -p`-Läufe – werden abgelehnt und der vorherige Zustand wird wiederhergestellt (`internal/session/instance.go:4636-4650`). Größen- und Änderungszeitprüfungen schützen zusätzlich gegen falsche Zuordnung nach `/clear` oder ähnlichen Übergängen (`internal/session/instance.go:4652-4687`).

### 4.5 Recovery ist absichtlich konservativ

Eine tmux-seitig gefundene Claude-ID ohne zugehörige Daten wird als möglicher Zombie verworfen (`internal/session/instance.go:4481-4528`). Die globale Suche auf der Festplatte ist nicht die normale Autorität (`internal/session/instance.go:4541-4555`). Für JSONL-Zuordnungen gibt es kollisionsbewusste Prüfungen (`internal/session/instance.go:5530-5588`). Wenn mehrere Wrapper dieselbe Claude-ID beanspruchen, wird ein deterministischer Besitzer gewählt (`internal/session/instance.go:9033-9065`); beim Start können doppelte laufende tmux-Sessions derselben Claude-ID beendet werden (`internal/session/instance.go:3511-3519`).

Session-ID-Änderungen werden zusätzlich als JSONL-Ereignisse protokolliert (`internal/session/session_id_event_log.go:14-27`, `internal/session/session_id_event_log.go:48-87`). Hook-seitig existiert außerdem eine kleine `.sid`-Ankerdatei (`internal/session/hook_session_anchor.go:9-50`). Das verbessert Diagnose und Wiederauffindbarkeit, ersetzt aber keine transaktionale Operationstabelle.

### 4.6 Grenzen der Wiederherstellung

Der Reviver repariert lebende Sessions beziehungsweise deren Control-Verbindung, startet tote tmux-Sessions aber nicht pauschal automatisch neu (`internal/session/reviver.go:10-26`, `internal/session/reviver.go:250-269`). Ein Kommentar markiert zudem einen noch nicht vollständig gelösten transienten Miss (`internal/session/reviver.go:96-109`).

`LastStartedAt` ist im Laufzeitmodell als persistenzrelevant erkennbar (`internal/session/instance.go:190-196`), wurde in den geprüften Datenbank-Mappings jedoch nicht als vollständig gespeicherter und geladener Wert gefunden. Daraus sollte ohne weitere Quelle keine belastbare Recovery-Garantie abgeleitet werden.

### 4.7 Bewertung für WhisperM8

Agent Deck ist bei der Vermeidung falscher Wiederbindung stärker als ein naiver „neueste JSONL gewinnt“-Ansatz. Für WhisperM8 sollte die Recovery-Reihenfolge lauten:

1. explizit gespeicherte Claude-ID,
2. bestätigtes Hook-Ereignis aus der passenden Prozessinkarnation,
3. JSONL am exakt aufgelösten Account- und Projektpfad,
4. vorsichtige heuristische Suche nur als Recovery-Vorschlag,
5. niemals stillschweigend einen unsicheren Kandidaten übernehmen.

## 5. Terminal-/PTY-Robustheit und Persistenz über Neustarts

### 5.1 Entkopplung von UI und Agentenprozess

Agent Deck startet die eigentliche CLI als initialen Prozess einer abgekoppelten tmux-Session und übergibt Argumente getrennt (`internal/tmux/tmux.go:1236-1269`). Der Bubble-Tea-Prozess ist nur ein Client dieser Session. Das erklärt die hohe Persistenz bei einem Neustart der TUI: Claude läuft weiter, solange tmux und das Betriebssystem weiterleben.

Der Start besitzt mehrere Strategien – systemd-Service, Scope und direkter Fallback – und registriert erfolgreiche Starts im Cache (`internal/tmux/tmux.go:2053-2191`). Diese Linux-spezifische Staffelung ist für eine native macOS-App nicht direkt kopierbar, zeigt aber ein wichtiges Prinzip: Prozessstart, Prozessbesitz und UI-Anbindung sind getrennte Zustände.

### 5.2 Robuster Attach-Lebenszyklus

Die PTY-Anbindung setzt vor dem Attach die Terminalgröße (`internal/tmux/pty.go:258-276`) und validiert den Attach-Prozess (`internal/tmux/pty.go:294-375`). Anschließend werden Raw-Modi, `SIGWINCH`-Weitergabe und Größenänderungen eingerichtet (`internal/tmux/pty.go:378-425`). Ein- und Ausgabe laufen in getrennten Goroutinen (`internal/tmux/pty.go:444-528`).

Beim Ende wartet der Code auf den Attach-Prozess (`internal/tmux/pty.go:530-536`), führt nur ein begrenztes Output-Drain durch, quarantänisiert Eingabe während problematischer Übergänge und setzt Terminalzustände zurück (`internal/tmux/pty.go:540-570`). Eigene Steuersequenzen und Attach-Intents helfen, normales Terminalende, Detach und kontrollierte Wechsel auseinanderzuhalten (`internal/tmux/pty.go:33-60`, `internal/tmux/pty.go:69-127`, `internal/tmux/pty.go:181-213`).

### 5.3 Neustart und Prozessbereinigung

Für einen bewussten Neustart verwendet Agent Deck `respawn-pane -k`, prüft beziehungsweise bereinigt Prozessbäume und verbindet danach erneut (`internal/tmux/tmux.go:2790-2865`). Die Kill-Logik berücksichtigt Prozessbäume (`internal/tmux/tmux.go:2613-2653`). Zusätzliche Hilfen prüfen, ob PIDs tatsächlich beendet wurden, und bieten ein Kill-and-Wait-Verfahren (`internal/tmux/ensure_pids_dead.go:29-91`, `internal/tmux/ensure_pids_dead.go:156-185`).

Ein auffälliger Randfall bleibt: `KillAndWait` ruft tmux an einer Stelle direkt auf (`internal/tmux/ensure_pids_dead.go:171`), während die normale Kill-Implementierung den gespeicherten Socketkontext über `s.tmuxCmd` verwendet (`internal/tmux/tmux.go:2633-2635`). Bei nicht standardmäßigem Socket kann diese Abweichung auf das falsche tmux-Backend zielen oder die Session nicht finden.

### 5.4 Neustartarten unterscheiden

- **TUI-/App-Neustart:** tmux lebt weiter; gespeicherte Socket- und Instanzmetadaten erlauben Lazy-Reconnect.
- **Agentenprozess-Neustart:** Die Wrapper-Instanz bleibt, aber der Prozess wird kontrolliert ersetzt.
- **Maschinenneustart:** Metadaten überleben, tmux-Prozesse jedoch nicht. Der geprüfte Reviver startet tote Sessions bewusst nicht automatisch neu.

Eine macOS-spezifische Wiederbelebung über LaunchAgent oder eine vergleichbare Komponente wurde im untersuchten Projekt nicht gefunden.

### 5.5 Übertragung auf SwiftTerm

WhisperM8 soll laut Constraint weiterhin die echte Claude-CLI direkt in SwiftTerm-PTYs hosten. Daher ist tmux nicht als notwendige Architekturänderung zu empfehlen. Übertragbar ist stattdessen eine explizite PTY-Zustandsmaschine:

- Prozessinkarnation vor jedem Spawn erzeugen,
- Start und Resize serialisieren,
- initiale Fenstergröße vor dem interaktiven Start setzen,
- Resize nur an die aktuelle Inkarnation senden,
- EOF, Benutzer-Detach, App-Abbruch und Prozessfehler getrennt behandeln,
- Ausgabe begrenzt drainieren,
- Eingabe während Reconnect/Restart blockieren,
- Terminalmodi und SwiftTerm-Zustand deterministisch zurücksetzen,
- Prozessbaum nach Abbruch verifizieren,
- niemals gespeicherte Tastatureingaben in einen frisch gestarteten Prozess nachspielen.

Falls ein direkter SwiftTerm-PTY einen App-Absturz technisch nicht überleben kann, sollte WhisperM8 nicht so tun, als sei derselbe Prozess noch vorhanden. Stattdessen bleibt die Wrapper- und Claude-Identität bestehen, während eine neue Prozessinkarnation die gespeicherte Claude-ID über `--resume` öffnet.

## 6. Multi-Account-Isolation und gruppenspezifisches `CLAUDE_CONFIG_DIR`

### 6.1 Hierarchische Kontextauflösung

Agent Deck besitzt eine zentrale Auflösung für den Claude-Konfigurationspfad (`internal/session/claude.go:295-390`, öffentliche Aufrufkette `internal/session/claude.go:466-507`). Die Priorität ist sinngemäß:

1. expliziter Account der Instanz,
2. Account des Conductors beziehungsweise übergeordneter Gruppenkontext,
3. Account der Gruppe,
4. Umgebungswert,
5. aktives Agent-Deck-Profil,
6. globaler beziehungsweise standardmäßiger Claude-Kontext,
7. Fallback auf `~/.claude`.

Gruppen können Einstellungen über ihre Vorfahren erben (`internal/session/userconfig.go:1439-1469`). Gruppenbezogene Felder werden im Konfigurationsschema geführt (`internal/session/userconfig.go:770-812`), ebenso Conductor-bezogene Einstellungen (`internal/session/userconfig.go:824-874`).

### 6.2 Spawn exportiert den aufgelösten Kontext

Beim Prozessstart baut Agent Deck ein Präfix, das unter anderem den ermittelten Claude-Konfigurationspfad und stabile Identitätshinweise exportiert (`internal/session/instance.go:1043-1081`). Die Auflösung wird für Diagnosezwecke protokolliert (`internal/session/instance.go:1118-1136`). Damit kann dieselbe echte Claude-CLI unter unterschiedlichen Accounts beziehungsweise Konfigurationsverzeichnissen laufen, ohne eine eigene Agentenruntime zu benötigen.

Das ist exakt auf WhisperM8s Wrapper-Modell übertragbar: Gruppen- oder Sessionmetadaten bestimmen `CLAUDE_CONFIG_DIR`; der reale CLI-Prozess wird mit diesem Environment gestartet.

### 6.3 Accountwechsel als geordnete Migration

Der Accountwechsel folgt einem bemerkenswert sauberen Ablauf (`cmd/agent-deck/session_switch_account.go:16-193`):

1. Zielaccount validieren (`cmd/agent-deck/session_switch_account.go:59-70`).
2. Laufenden Prozess stoppen und Identität synchronisieren (`cmd/agent-deck/session_switch_account.go:91-100`).
3. Quellkontext vor der Metadatenänderung auflösen und die Session profilübergreifend lokalisieren (`cmd/agent-deck/session_switch_account.go:102-118`).
4. Zielkontext prüfen, bevor der Accountzeiger umgestellt wird (`cmd/agent-deck/session_switch_account.go:125-133`).
5. Trust-/Migrationsschritte ausführen, Metadaten ändern, Prozess neu starten und speichern (`cmd/agent-deck/session_switch_account.go:136-166`).

Die Lokalisierung einer Session über verschiedene Profile liegt in `internal/session/migrate_locate.go:12-77`; die Zielprüfung in `internal/session/migrate_locate.go:120-152`. Die Migration kopiert statt destruktiv zu verschieben, legt Sicherungen an, verifiziert das Ergebnis und berücksichtigt auch Subagent-Verzeichnisse (`internal/session/migrate.go:18-26`, `internal/session/migrate.go:80-115`).

Für WhisperM8 ergibt sich daraus das Muster:

```text
stoppen → aktuelle Claude-ID sichern → Quellkontext auflösen →
Transcript/Session copy-only migrieren → Ziel verifizieren →
Accountmetadaten atomar umstellen → echte CLI mit derselben ID resumieren
```

### 6.4 Inkonsistente Kontextnutzung beim JSONL-Lesen

Die zentrale Accountauflösung ist stark, wird jedoch nicht lückenlos verwendet. Mehrere Pfade zur Transcript- und JSONL-Auflösung greifen auf ein globales `GetClaudeConfigDir()` zurück, darunter `claudeTranscriptDir`, `GetJSONLPath`, Antwortauswertung und die Suche nach dem neuesten Transcript (`internal/session/instance.go:5558-5569`, `internal/session/instance.go:5634-5683`).

Auch die kalte Suche nach der neuesten Claude-JSONL arbeitet global (`internal/session/claude.go:684-714`) und wird aus Recovery-Pfaden aufgerufen (`internal/session/instance.go:3233-3238`, `internal/session/instance.go:3278-3283`). Dadurch kann der Spawn im richtigen gruppenspezifischen `CLAUDE_CONFIG_DIR` erfolgen, während spätere JSONL-Auswertung oder Recovery versehentlich im globalen Profil sucht.

Das ist gerade bei identischen Projektpfaden und mehreren Accounts gefährlich:

- Eine reale Session kann als „nicht vorhanden“ erscheinen.
- Eine fremde Session kann als neuester Kandidat gelten.
- Kollisions- und Datenprüfungen können auf dem falschen Profil arbeiten.
- Ein Fork kann seine Eltern-JSONL nicht finden, obwohl die CLI im richtigen Account gestartet wurde.

### 6.5 Weitere Accountlücke beim Fork

Wie oben beschrieben, kopiert der geprüfte Fork-Pfad den expliziten Instanzaccount nicht sichtbar mit (`internal/session/instance.go:7385-7443`). Gruppenvererbung kann diesen Fehler verdecken, ist aber keine hinreichende Garantie. Ein Fork sollte immer denselben vollständig aufgelösten Accountkontext wie seine Quelle erhalten, sofern der Benutzer nicht ausdrücklich einen anderen Zielaccount auswählt.

### 6.6 Bewertung für WhisperM8

Agent Deck ist bei der deklarativen Hierarchie und der geordneten Accountmigration stärker als ein bloßes Environment-Feld pro Prozess. Schlechter ist die fehlende Durchgängigkeit: Prozessstart und JSONL-Leser können unterschiedliche Kontextquellen verwenden.

WhisperM8 sollte deshalb nicht überall erneut `CLAUDE_CONFIG_DIR` berechnen. Ein einziges `ResolvedClaudeContext` sollte mindestens enthalten:

- Account-/Profil-ID,
- kanonischen `CLAUDE_CONFIG_DIR`,
- Workspace-/Projektpfad und dessen Claude-Kodierung,
- erwarteten Transcriptpfad,
- Hook-Ankerpfad,
- CLI-Pfad und relevantes Environment,
- Herkunft der Auflösung, etwa Session, Gruppe oder Default.

Dieses Objekt muss von Spawn, Fork, Resume, Headless-Aufrufen, Hookvalidierung, JSONL-Lesen, Recovery und Kollisionsprüfung gemeinsam verwendet werden.

## 7. Direkter Vergleich mit WhisperM8s CLI-Host-Modell

Der Vergleich beschränkt sich auf die im Auftrag beschriebene WhisperM8-Architektur; WhisperM8-Dateien wurden nicht untersucht.

| Thema | Agent Deck | WhisperM8-Ansatz | Bewertung |
|---|---|---|---|
| Wrapper-Identität | Eigene persistente `Instance.ID` | Native Session-/Workspace-Metadaten sind vorgesehen | Agent Deck liefert ein gutes Referenzmuster für strikte Trennung von UI-, Claude- und Prozess-ID. |
| Aktive Session | UI-Auswahl zeigt auf persistente Instanz; Backend kann unabhängig leben | SwiftUI-Auswahl plus direkter SwiftTerm-PTY | Auswahl darf in WhisperM8 nur den aktiven Wrapper ändern, nicht implizit Session-IDs umschreiben. |
| Fork | Eigener Startpfad mit vorab erzeugter Child-ID | Muss über echte Claude-CLI erfolgen | Agent Deck ist beim ersten CLI-Aufruf vorbildlich; sein dauerhaftes Lineage-Modell ist zu schwach. |
| Resume | Bestehende ID und JSONL-Daten werden geprüft | `--resume` bleibt der richtige echte-CLI-Pfad | Beide Modelle sind kompatibel; WhisperM8 sollte Resume nie mit Fork vermischen. |
| Prozesspersistenz | tmux überlebt einen TUI-Neustart | Direkter PTY ist stärker an den App-Prozess gebunden | Agent Deck ist beim Manager-Neustart robuster. WhisperM8 sollte bei neuer PTY-Inkarnation ehrlich resumieren statt Prozesskontinuität vorzutäuschen. |
| Session-Recovery | Konservative Hierarchie, Hook- und JSONL-Prüfungen, Dedup | JSONL und Hooks stehen im Wrapper zur Verfügung | Agent Deck ist eine gute Vorlage gegen „neueste Datei gewinnt“; WhisperM8 kann mit nativer persistenter Registry noch atomarer werden. |
| PTY | Zusätzlicher Attach-PTY zu tmux | SwiftTerm hostet die echte CLI direkt | Agent Deck hat mehr Schichten, aber wertvolle Lifecycle-Muster. Ein tmux-Zwang wäre keine notwendige Übertragung. |
| Multi-Account | Starke Gruppenhierarchie und Migration, aber globale JSONL-Restpfade | Gruppenspezifisches `CLAUDE_CONFIG_DIR` ist im Auditfokus | WhisperM8 kann besser werden, wenn wirklich jeder CLI- und Dateipfad denselben Sessionkontext verwendet. |
| Headless-Prozesse | Andere Prozessarten können dieselben Identitätsprobleme erzeugen | `claude -p` und `claude --bg` gehören ausdrücklich zum Modell | WhisperM8 muss Hook-/JSONL-Ereignisse zusätzlich nach interaktiver PTY- oder Headless-Prozessinkarnation zuordnen. |

## 8. Priorisierte übertragbare Muster

### P0 – Fork als persistierte, zweiphasige Operation

WhisperM8 sollte für jeden Fork vor dem Spawn einen dauerhaften Datensatz anlegen, beispielsweise mit:

- `operationID`,
- `sourceWrapperSessionID`,
- `sourceClaudeSessionID`,
- `childWrapperSessionID`,
- `childClaudeSessionID`,
- vollständig aufgelöstem Claude-/Accountkontext,
- `processIncarnationID`,
- Zuständen wie `prepared`, `spawned`, `identityVerified`, `committed` und `failed`,
- Zeitstempeln und Diagnosegrund.

Der Übergang sollte so ablaufen:

1. Child-Wrapper und Child-Claude-ID erzeugen und als `prepared` speichern.
2. Exakt einmal den echten CLI-Aufruf starten:

   ```text
   claude --session-id <child> --resume <parent> --fork-session
   ```

3. Prozessinkarnation und Hook-/JSONL-Belege ausschließlich dem vorbereiteten Child zuordnen.
4. Nach bestätigter Child-Identität auf `committed` wechseln.
5. Bei allen späteren Starts ausschließlich `--resume <child>` verwenden.
6. Beim App-Neustart unvollständige Operationen erkennen und kontrolliert prüfen, statt einen zweiten Child-Fork zu erzeugen.

Damit werden Fork und Resume nicht nur als verschiedene Flags, sondern als verschiedene Identitätstransaktionen behandelt.

### P0 – Ein `ResolvedClaudeContext` als einzige Quelle

Jede Session und jeder Job muss vor Prozess- oder Dateizugriff einen unveränderlichen Kontext erhalten. Dieser Kontext ist obligatorisch für:

- interaktiven PTY-Spawn,
- `--resume`, `--session-id` und `--fork-session`,
- `claude -p` und `claude --bg`,
- Hookinstallation und Hookvalidierung,
- JSONL-/Transcriptpfade,
- Recovery und Sessionerkennung,
- Kollisionsprüfung,
- Accountmigration.

Kein globaler Fallback darf innerhalb eines bereits aufgelösten Sessionvorgangs erneut entscheiden. Ein Fork erbt standardmäßig den aufgelösten Kontext der Quelle; ein Accountwechsel ist eine eigene, validierte Migration.

### P0 – Drei Identitäten plus Prozessgeneration dauerhaft trennen

WhisperM8 sollte separat speichern:

- Wrapper-/Chat-ID,
- Claude-Session-ID,
- PTY-/Headless-Prozessinkarnation,
- gegebenenfalls Backend-/Terminal-ID.

Hook-Ereignisse dürfen die Claude-ID nur aktualisieren, wenn Wrapper-ID, Prozessinkarnation, Accountkontext und Workspace zusammenpassen. Gezielte Compare-and-Swap-Updates sind sicherer als das Speichern eines vollständigen, möglicherweise veralteten Sessionobjekts.

### P1 – Konservative Recovery-Leiter

Empfohlene Priorität:

1. persistierte und bestätigte Claude-ID,
2. bestätigtes Hook-Ereignis der aktuellen Prozessinkarnation,
3. JSONL am exakten Pfad des `ResolvedClaudeContext`,
4. überprüfter Prozesshinweis,
5. heuristische Kandidaten nur sichtbar als Reparaturvorschlag.

Ein Kandidat sollte abgelehnt werden, wenn er einem anderen Wrapper gehört, aus einem anderen Account stammt, keine Konversationsdaten besitzt oder nur von einem fremden Headless-Prozess erzeugt wurde.

### P1 – PTY-Lifecycle als Zustandsmaschine

Für SwiftTerm sollten Zustände wie `idle`, `starting`, `attached`, `detaching`, `exited`, `recovering` und `failed` explizit sein. Resize, Input, Hookannahme und Prozessende müssen an eine Prozessgeneration gebunden werden. Besonders wichtig sind initiale Größe, begrenztes Output-Drain, Input-Quarantäne beim Wechsel und ein deterministischer Terminalreset.

### P1 – UPSERT und gezielte Identitätsupdates

Sessionmetadaten sollten pro Datensatz und möglichst pro Identitätsfeld aktualisiert werden. Ein veralteter UI-Snapshot darf weder neuere Hook-Informationen überschreiben noch Sessions löschen, die ein paralleler Background-Agent angelegt hat.

### P1 – Accountwechsel als copy-only Transaktion

Vor dem Wechsel:

- Prozess stoppen,
- aktuelle ID sichern,
- Quell- und Zielkontext explizit auflösen,
- JSONL-/Sessiondaten mit Backup kopieren,
- Ziel verifizieren,
- erst dann Accountmetadaten umstellen und dieselbe Claude-ID resumieren.

Der Quellbestand sollte bis zur erfolgreichen Verifikation unangetastet bleiben.

### P2 – Identitätsereignisse protokollieren

Ein append-only Diagnoseprotokoll sollte mindestens enthalten:

- Wrapper-ID,
- alte und neue Claude-ID,
- Prozessinkarnation,
- Account-/Gruppenkontext,
- Quelle des Ereignisses, etwa Spawn, Hook, JSONL-Recovery oder Benutzeraktion,
- Fork-Operation-ID,
- Ablehnungs- oder Konfliktgrund.

Agent Deck zeigt mit seinem Session-ID-Ereignislog, dass diese Historie für schwer reproduzierbare Fehlzuordnungen sehr wertvoll ist.

## 9. Nicht oder nur unvollständig auffindbar

Im untersuchten Klon wurden folgende Garantien nicht gefunden:

- kein dauerhaftes, eindeutiges `forkedFrom`-Feld für die tatsächliche Fork-Lineage,
- keine persistente Fork-Operation oder Journal-State-Machine,
- keine atomare Garantie über Spawn und anschließendes Speichern des Forks,
- keine sichtbare Übernahme eines expliziten Instanzaccounts im geprüften Fork-Kopierpfad,
- keine lückenlose Verwendung des sessionspezifischen `CLAUDE_CONFIG_DIR` bei JSONL-, Transcript- und Cold-Recovery-Pfaden,
- keine automatische Wiederbelebung toter Sessions nach einem Maschinenneustart,
- keine belastbare vollständige Persistenz von `LastStartedAt` in den geprüften Storage-Mappings,
- keine macOS-/SwiftTerm-spezifische Lösung, da Agent Deck eine Go-/tmux-TUI ist.

Diese Punkte sind bewusst als „nicht gefunden“ formuliert; aus fehlenden Fundstellen wird nicht behauptet, dass außerhalb der untersuchten Pfade keinerlei weitere Absicherung existiert.

## 10. Schlussfolgerung

Agent Deck bestätigt das richtige Grundmodell für WhisperM8: Die echte Claude-Code-CLI bleibt die Runtime, während der Host Identität, Prozesslebenszyklus, Persistenz und Accountkontext organisiert. Seine stärkste Lösung ist der First-Class-Fork-Aufruf mit vorab festgelegter Child-ID. Seine entscheidende Modelllücke ist, dass diese saubere CLI-Operation nicht als ebenso saubere, dauerhaft nachvollziehbare Eltern-/Kind-Transaktion gespeichert wird.

Für WhisperM8 lautet die wichtigste Konsequenz daher: **Fork, Resume und Neuanlage müssen drei explizite Identitätsübergänge sein.** Die Claude-ID darf nicht aus der UI-Auswahl oder dem jeweils lebenden PTY abgeleitet werden. Ein Fork erzeugt vor dem Spawn eine neue dauerhafte Identität; ein Resume behält die bestehende Identität; ein PTY-Neustart erzeugt lediglich eine neue Prozessinkarnation. Kombiniert mit einem durchgängigen `ResolvedClaudeContext` für gruppenspezifisches `CLAUDE_CONFIG_DIR`, JSONL und Hooks entsteht ein robuster Wrapper, ohne die echte CLI durch eine Eigen-Chat-UI oder Agent-SDK-Runtime zu ersetzen.
