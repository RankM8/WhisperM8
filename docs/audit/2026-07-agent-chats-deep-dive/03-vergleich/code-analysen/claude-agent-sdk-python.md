# claude-agent-sdk-python

## Untersuchungsrahmen

Analysiert wurde ausschließlich der lokale Klon von `claude-agent-sdk-python` auf Commit `94ff18e08551e1b96ba2668d90eacfedd92a3a55`. Der Stand bezeichnet sich als SDK `0.2.122` und bündelt Claude Code CLI `2.1.214` (`pyproject.toml:5-31`, `src/claude_agent_sdk/_version.py:1-3`, `src/claude_agent_sdk/_cli_version.py:1-3`, `CHANGELOG.md:3-7`).

Das Projekt ist eine besonders relevante Normquelle, weil es nicht versucht, Claude Code nachzubauen: Es startet die echte CLI als Subprozess und legt darüber ein typisiertes Python-Protokoll. Anders als WhisperM8 benutzt es Pipes mit `stream-json`, nicht PTY/TUI. Deshalb ist es Norm für Identität, Resume/Fork, JSONL, Listing und Fehlerwege, aber kein UI- oder PTY-Vorbild.

Der Vergleich mit WhisperM8 bezieht sich auf das im Auftrag beschriebene Wrapper-Modell. Entsprechend der Leseregel wurde kein WhisperM8-Quellcode für diesen Bericht untersucht.

## Projektüberblick

### Stack und Prozessmodell

- Python 3.10+, AnyIO für asyncio/Trio, MCP als Laufzeitabhängigkeit (`pyproject.toml:5-31`).
- Die Claude-Code-CLI ist im Paket gebündelt; alternativ kann ein expliziter `cli_path` verwendet werden (`README.md:11-18`, `src/claude_agent_sdk/types.py:1846-1853`).
- `ClaudeSDKClient` hält einen bidirektionalen, interaktiven CLI-Prozess; `query()` bildet einen kurzlebigen, unidirektionalen Lauf ab (`README.md:85-90`, `src/claude_agent_sdk/query.py:18-42`).
- Der Transport startet die CLI mit `--output-format stream-json --verbose` und immer mit `--input-format stream-json` (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:282-287`, `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:472-476`).
- Persistenz bleibt CLI-nativ: lokale JSONL-Dateien unter dem effektiven `CLAUDE_CONFIG_DIR` sind die Primärkopie. Ein `SessionStore` erhält nur eine zweite, gespiegelte Kopie (`src/claude_agent_sdk/types.py:1426-1438`).

### Relevante Dateien

| Datei | Bedeutung |
|---|---|
| `src/claude_agent_sdk/types.py:1327-1543` | Verbindlicher `SessionKey`- und `SessionStore`-Vertrag |
| `src/claude_agent_sdk/types.py:1551-1608` | Öffentliche Listing- und Nachrichtenmodelle |
| `src/claude_agent_sdk/types.py:1725-1798` | Optionen für Continue, Resume und vorgegebene Session-ID |
| `src/claude_agent_sdk/types.py:1943-1945` | Semantik von `fork_session` |
| `src/claude_agent_sdk/types.py:2058-2082` | Store-Mirroring, Flush-Modi und Resume-Timeout |
| `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:282-476` | Exakte Abbildung der Optionen auf CLI-Flags |
| `src/claude_agent_sdk/_internal/sessions.py:69-184` | UUID-Prüfung, Projektpfade und Fallback bei langen Pfaden |
| `src/claude_agent_sdk/_internal/sessions.py:353-677` | Lokales Listing, Filterung, Worktrees und Deduplizierung |
| `src/claude_agent_sdk/_internal/sessions.py:931-1020` | Rekonstruktion des aktiven JSONL-Zweigs über `parentUuid` |
| `src/claude_agent_sdk/_internal/sessions.py:1419-1430` | Stabile Ableitung des `project_key` |
| `src/claude_agent_sdk/_internal/sessions.py:1578-1732` | Listing aus einem externen Store einschließlich Gap-Fill |
| `src/claude_agent_sdk/_internal/session_resume.py:51-193` | Store-Resume durch Materialisierung in ein temporäres Claude-Config-Verzeichnis |
| `src/claude_agent_sdk/_internal/session_resume.py:247-305` | Auswahl für Continue sowie Timeout- und Adapterfehler |
| `src/claude_agent_sdk/_internal/session_mutations.py:232-484` | Persistentes Forking mit vollständiger UUID-Neuschreibung |
| `src/claude_agent_sdk/_internal/transcript_mirror_batcher.py:46-219` | Reihenfolge, Retry, Timeout und Mirror-Fehler |
| `src/claude_agent_sdk/_internal/session_import.py:28-146` | Reparatur beziehungsweise Nachimport lokaler JSONL-Daten |
| `src/claude_agent_sdk/testing/session_store_conformance.py:54-318` | Ausführbare Verhaltensnorm für Store-Adapter |
| `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:629-829` | Beenden, Reaping, Stream-Framing und Prozessfehler |

## 1. Session-Identität und Wechsel der aktiven Session

### Drei Identitätsebenen

Das SDK trennt faktisch drei Ebenen:

1. Die persistente Claude-Session ist eine UUID. Öffentliche Listing-Einträge beschreiben `session_id` ausdrücklich als eindeutige Session-UUID (`src/claude_agent_sdk/types.py:1551-1577`). Helpers für Lesen, Mutation, Fork und Import akzeptieren nur UUID-förmige IDs (`src/claude_agent_sdk/_internal/sessions.py:45-73`, `src/claude_agent_sdk/_internal/session_import.py:64-73`).
2. Diese UUID ist nicht global allein adressiert, sondern über `SessionKey = project_key + session_id + optional subpath`. Haupttranskripte haben keinen `subpath`; Subagent-Transkripte erhalten beispielsweise `subagents/agent-{id}` (`src/claude_agent_sdk/types.py:1332-1351`).
3. Der laufende Python-/CLI-Prozess ist lediglich ein Träger dieser Identität. `ClaudeSDKClient.connect()` erzeugt den Transport und Prozess; `disconnect()` schließt ihn wieder, ohne die persistente JSONL-Identität zu löschen (`src/claude_agent_sdk/client.py:187-195`, `src/claude_agent_sdk/client.py:612-621`).

Das ist die wichtigste normative Aussage für WhisperM8: Terminaltab, PTY-Prozess und Claude-Session dürfen nicht dieselbe Primär-ID sein.

### Woher kommt die verbindliche ID?

Für neue Läufe kann die CLI selbst eine ID erzeugen oder der Host gibt über `session_id` eine gültige UUID vor. Die Optionsdokumentation verbietet diese Vorgabe zusammen mit Continue oder Resume, außer wenn gleichzeitig geforkt wird (`src/claude_agent_sdk/types.py:1793-1798`). Der Transport setzt daraus `--session-id=<uuid>` (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:352-361`).

Die tatsächlich von der CLI verwendete ID wird in strukturierten Ausgaben zurückgegeben. Insbesondere verlangt `ResultMessage` ein `session_id`-Feld (`src/claude_agent_sdk/types.py:1200-1223`), und der Parser übernimmt genau dieses CLI-Feld (`src/claude_agent_sdk/_internal/message_parser.py:290-317`). Assistant-, Stream-, Task- und Hook-Ereignisse können ebenfalls Session-Zuordnung tragen (`src/claude_agent_sdk/_internal/message_parser.py:192-202`, `src/claude_agent_sdk/types.py:275-281`).

Daneben existiert beim Streaming-Client ein gleichnamiges Eingabefeld, das standardmäßig `default` ist und pro Nachricht gesetzt werden kann (`src/claude_agent_sdk/client.py:263-271`, `src/claude_agent_sdk/client.py:287-315`). Ein Wrapper sollte dieses Routingfeld nicht ungeprüft mit der persistenten Claude-UUID gleichsetzen. Normative Bestätigung ist die von der CLI ausgegebene Session-ID beziehungsweise der dazugehörige JSONL-Pfad.

### Aktive Session wechseln

Eine UI-Auswahl oder ein In-Process-Befehl zum Wechsel auf eine andere persistente Session ist nicht vorhanden. Ein `ClaudeSDKClient` repräsentiert eine laufende CLI-Verbindung. Der Wechsel auf eine andere persistente Session erfolgt durch einen neuen Prozesslauf mit explizitem Resume- oder Fork-Übergang.

Für WhisperM8 folgt daraus:

- Die UI-Auswahl wählt einen persistenten Session-Datensatz.
- Der PTY-Prozess ist eine austauschbare Laufzeitinstanz dieses Datensatzes.
- Das Wechseln der UI-Auswahl darf nicht stillschweigend die Identität eines bereits laufenden PTYs umetikettieren.
- Beim erneuten Aktivieren wird die gespeicherte CLI-UUID über `--resume=<uuid>` gebunden oder bewusst ein neuer Fork gestartet.

## 2. Resume und Fork als getrennte Identitätsübergänge

### Normative Übergangstabelle

| Operation | Quelle | Zielidentität | CLI-/SDK-Semantik |
|---|---|---|---|
| Neu | keine | neue UUID | automatisch oder `--session-id=<uuid>` |
| Resume | konkrete UUID | dieselbe UUID | `--resume=<uuid>` |
| Continue | Projekt-Scope | neueste passende UUID | `--continue`; beim Store vorab auf konkrete UUID aufgelöst |
| Fork | konkrete Quell-UUID | neue UUID | `--resume=<quelle> --fork-session`, optional mit vorgegebener neuer `--session-id=<ziel>` |

`resume` lädt die Historie der angegebenen Session (`src/claude_agent_sdk/types.py:1786-1792`). `fork_session=True` bedeutet dagegen ausdrücklich, dass eine resumte Session unter einer neuen ID weitergeführt wird (`src/claude_agent_sdk/types.py:1943-1945`). Der Transport gibt Resume, Session-ID und Fork als drei getrennte Flags aus (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:349-361`, `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:409-413`).

### Explizites Resume schlägt Continue

Beim Store-Pfad wird die Mehrdeutigkeit vor dem Spawn aufgelöst: Wenn `resume` gesetzt ist, wird exakt diese UUID geladen; nur andernfalls sucht Continue nach der neuesten Session (`src/claude_agent_sdk/_internal/session_resume.py:145-158`). Nach erfolgreicher Materialisierung wird `continue_conversation` gelöscht und ausschließlich `resume=<konkrete UUID>` an den Transport weitergereicht (`src/claude_agent_sdk/_internal/session_resume.py:70-87`). Der Integrationstest prüft, dass dann `--resume=<id>` vorhanden und `--continue` abwesend ist (`tests/test_session_resume.py:745-815`).

Ohne SessionStore ist die Implementierung weniger streng: Der Transport kann `--continue` und `--resume=<id>` gleichzeitig ausgeben (`tests/test_transport.py:426-435`). Die Dataclass erzwingt auch die dokumentierte Exklusivität nicht (`tests/test_types.py:231-235`). Für WhisperM8 sollte daher nicht das permissive Optionsobjekt, sondern die aufgelöste Semantik als Norm gelten: genau ein Übergang pro Spawn.

### Continue-Auswahl

Store-basiertes Continue sortiert nach `mtime` absteigend, verwirft ungültige IDs, leere beziehungsweise fehlende Sessions und Sidechains und wählt erst danach die erste Hauptsession (`src/claude_agent_sdk/_internal/session_resume.py:261-291`). Das verhindert, dass ein zuletzt geschriebener Subagent-Zweig anstelle der Benutzerkonversation fortgesetzt wird.

Wenn Continue keine passende Historie findet, wird eine frische Session begonnen (`src/claude_agent_sdk/_internal/session_resume.py:128-132`). Das ist CLI-kompatibel, aber für eine UI-Aktion mit explizit ausgewähltem Ziel gefährlich: Ein fehlgeschlagenes explizites Resume darf in WhisperM8 nicht als unbemerkte neue Session erscheinen.

### Zwei Fork-Varianten

Das Projekt kennt zwei unterschiedliche Mechanismen:

1. CLI-Fork beim Start: `resume + fork_session`, optional mit vorgegebener Ziel-UUID. Die neue tatsächliche ID muss aus den CLI-Ausgaben übernommen werden.
2. Persistenter Offline-Fork: `fork_session()` beziehungsweise `fork_session_via_store()` erzeugt bereits vor einem CLI-Start ein neues Transkript und gibt dessen neue UUID zurück (`src/claude_agent_sdk/_internal/session_mutations.py:232-267`, `src/claude_agent_sdk/_internal/session_mutations.py:885-962`).

Der Offline-Fork ist keine Dateikopie. Er:

- entfernt Sidechains aus dem Hauptzweig (`src/claude_agent_sdk/_internal/session_mutations.py:366-371`),
- schneidet optional einschließlich einer verifizierten `up_to_message_id` ab (`src/claude_agent_sdk/_internal/session_mutations.py:373-383`),
- erzeugt für jede Nachricht eine neue UUID (`src/claude_agent_sdk/_internal/session_mutations.py:385-400`),
- rekonstruiert `parentUuid`, wobei reine Progress-Knoten übersprungen werden (`src/claude_agent_sdk/_internal/session_mutations.py:405-418`),
- schreibt auf jeder Nachricht die neue `sessionId` und eine Herkunftsreferenz `forkedFrom.sessionId/messageUuid` (`src/claude_agent_sdk/_internal/session_mutations.py:429-442`),
- entfernt sitzungsspezifische Team-/Agent-Felder (`src/claude_agent_sdk/_internal/session_mutations.py:443-445`),
- übernimmt Content-Replacements unter der neuen ID (`src/claude_agent_sdk/_internal/session_mutations.py:449-462`),
- legt die Datei exklusiv mit `O_EXCL` an, sodass kein bestehender Zweig überschrieben wird (`src/claude_agent_sdk/_internal/session_mutations.py:338-343`).

### Schutz vor dem falschen Zweig

Das SDK verlässt sich beim Lesen nicht auf die letzte JSONL-Zeile. Es indexiert Nachrichten nach UUID, findet terminale Knoten, bevorzugt Blätter des Hauptzweigs ohne `isSidechain`, `teamName` oder `isMeta` und läuft anschließend über `parentUuid` zurück zur Wurzel (`src/claude_agent_sdk/_internal/sessions.py:931-1020`). Das ist für WhisperM8 unmittelbar übertragbar: Eine append-only JSONL-Datei kann mehrere Zweige und Metadaten enthalten; Dateireihenfolge allein ist keine Branch-Identität.

Eine Schwäche bleibt: Bei Store-Resume bedeutet ein ungültiges oder nicht gefundenes explizites Resume nur, dass keine Materialisierung stattfindet; die unveränderte Resume-Angabe fällt anschließend an die normale CLI-Behandlung zurück (`src/claude_agent_sdk/_internal/session_resume.py:123-157`). Für eine UI mit bewusst ausgewähltem Chat sollte WhisperM8 strenger sein und einen fehlenden Zielzweig vor dem PTY-Start als sichtbaren Fehler behandeln.

## 3. Schutz vor verlorenen oder nicht wiedergefundenen Sessions

### Lokale JSONL bleibt Primärkopie

`SessionStore.append()` wird erst aufgerufen, nachdem der lokale CLI-Schreibvorgang erfolgreich war (`src/claude_agent_sdk/types.py:1448-1456`). Ein Store-Fehler beendet deshalb die Konversation nicht. Das ist ein bewusstes Durability-Modell: lokal primär, Remote-Mirror sekundär.

Mirror-Batches werden in Aufrufreihenfolge serialisiert. UUID-haltige Einträge sollen als Idempotency Keys behandelt werden; Metadateneinträge ohne UUID werden normal angehängt (`src/claude_agent_sdk/types.py:1457-1466`). Der Batcher versucht normale Adapterfehler bis zu dreimal mit kurzem Backoff. Timeouts werden nicht wiederholt, weil der erste, möglicherweise nicht abbrechbare Schreibvorgang noch landen könnte (`src/claude_agent_sdk/_internal/transcript_mirror_batcher.py:32-35`, `src/claude_agent_sdk/_internal/transcript_mirror_batcher.py:178-203`).

Nach endgültigem Fehlschlag läuft die Session weiter und ein `MirrorErrorMessage` wird erzeugt (`src/claude_agent_sdk/_internal/transcript_mirror_batcher.py:213-219`, `src/claude_agent_sdk/_internal/query.py:151-170`). Diese Meldung selbst kann bei vollem internen Puffer verworfen werden. Ein Mirror ist daher keine garantierte Primärpersistenz.

### Reparaturpfad statt Hoffnung auf Vollständigkeit

`import_session_to_store()` kann eine vorhandene lokale Haupt-JSONL sowie Subagent-JSONLs und `.meta.json`-Sidecars erneut in einen Store einspielen. Der dokumentierte Zweck umfasst ausdrücklich die Reparatur nach einer Mirror-Lücke (`src/claude_agent_sdk/_internal/session_import.py:28-51`, `src/claude_agent_sdk/_internal/session_import.py:89-119`). Der Import nutzt dieselben Schlüssel wie das Live-Mirroring, sodass importierte und live gespiegelte Sessions identisch adressiert werden (`src/claude_agent_sdk/_internal/session_import.py:75-84`).

Das ist ein starkes Muster für WhisperM8: Jede asynchrone Indizierung oder Spiegelung benötigt einen expliziten Reconciliation-/Repair-Pfad aus der autoritativen CLI-JSONL.

### Robustes lokales Listing

`list_sessions()` kann entweder projektspezifisch oder über alle Projekte laufen und sortiert nach `last_modified` (`src/claude_agent_sdk/_internal/sessions.py:680-731`). Die Implementierung:

- akzeptiert nur UUID-benannte `.jsonl`-Dateien (`src/claude_agent_sdk/_internal/sessions.py:519-550`),
- liest für Metadaten nur Stat sowie je 64 KiB Kopf und Ende (`src/claude_agent_sdk/_internal/sessions.py:32-38`, `src/claude_agent_sdk/_internal/sessions.py:353-380`),
- filtert Sidechains und reine Metadaten-Sessions (`src/claude_agent_sdk/_internal/sessions.py:421-461`),
- normalisiert Pfade mit `realpath` und NFC, relevant für macOS-Dateisysteme (`src/claude_agent_sdk/_internal/sessions.py:148-154`),
- toleriert Hash-Unterschiede bei sehr langen Projektpfaden durch Prefix-Fallback (`src/claude_agent_sdk/_internal/sessions.py:157-184`),
- sucht auf Wunsch alle Git-Worktrees ab (`src/claude_agent_sdk/_internal/sessions.py:579-660`),
- dedupliziert identische Session-UUIDs und behält die neueste Kopie (`src/claude_agent_sdk/_internal/sessions.py:553-562`).

Damit behandelt das SDK Sessions als rekonstruierbaren Bestand und nicht als ausschließliches Ergebnis eines UI-Katalogs.

### Store-Listing und stale Sidecars

Ein Store muss zum Listing mindestens `list_sessions()` oder `list_session_summaries()` anbieten. Mit beiden Methoden werden fehlende oder veraltete Summary-Sidecars erkannt, wenn `summary.mtime < session.mtime`, und durch gezielte Loads nachgefüllt (`src/claude_agent_sdk/_internal/sessions.py:1613-1626`, `src/claude_agent_sdk/_internal/sessions.py:1632-1715`). Die Sidecar-Zeit muss aus derselben Speicheruhr wie die Session-Zeit stammen; Entry-Zeitstempel sind dafür ausdrücklich falsch (`src/claude_agent_sdk/types.py:1379-1403`).

Ohne `list_sessions()` kann ein Summary-only-Store fehlende Sidecars nicht entdecken; solche Sessions bleiben unsichtbar (`src/claude_agent_sdk/_internal/sessions.py:1623-1626`). Das ist ein wichtiger Warnhinweis für WhisperM8: Ein abgeleiteter Index darf nie die einzige Entdeckungsquelle sein.

### Grenzen

Nicht auffindbar ist ein persistenter SDK-eigener UI-Katalog, der Prozessinstanzen, Nutzerlabels, Account und CLI-UUID atomar verbindet. Ebenfalls nicht vorhanden ist eine Garantie, dass metadata-only oder beschädigte Sessions im normalen Listing sichtbar bleiben. WhisperM8 braucht deshalb einen eigenen Katalog, muss ihn aber beim Start gegen die externen, read-only Claude-Dateien reconciliieren können.

## 4. Terminal-/PTY-Robustheit und Persistenz über Neustarts

### Was direkt übertragbar ist

Obwohl das SDK Pipes statt PTY benutzt, enthält der Transport mehrere robuste Muster:

- NDJSON wird aus beliebigen Stream-Chunks zeilenweise rekonstruiert. Chunk-Grenzen dürfen mitten in JSON-Strings liegen und Whitespace darf an Grenzen nicht verloren gehen (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:50-83`).
- Leere und eindeutig nicht-JSON-förmige Debugzeilen werden übersprungen; eine mit `{` beginnende, aber ungültige vollständige Zeile erzeugt einen Decode-Fehler (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:86-108`).
- Eine einzelne Nachricht ist standardmäßig auf 1 MiB begrenzt, damit ein nie abgeschlossener Frame den Speicher nicht unbegrenzt wachsen lässt (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:30-31`, `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:773-794`).
- Ein unvollständiger JSON-Rest am EOF wird als abgeschnitten erkannt und verworfen, statt mit späteren Daten vermischt zu werden (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:804-814`).
- Stderr wird unabhängig gelesen und in echte Zeilen gerahmt. Ein fehlerhafter Callback beendet den Reader nicht; auch eine letzte Zeile ohne Newline wird beim Abbruch noch geliefert (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:584-627`).
- Schreibzugriffe und Schließen von stdin teilen sich einen Lock und vermeiden dadurch TOCTOU-Rennen (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:669-684`, `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:730-754`).
- Beim Schließen wird zuerst stdin beendet und bis zu fünf Sekunden auf einen natürlichen Exit gewartet, damit die CLI ihre Sessiondatei fertig schreiben kann. Erst danach folgen Terminate und schließlich Kill, jeweils mit begrenzter Wartezeit (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:691-713`).
- Cleanup läuft in einem gegen AnyIO-Cancellation geschützten Bereich. Noch nicht geerntete Kinder bleiben in einem globalen Set, und ein `atexit`-Handler sendet ihnen SIGTERM (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:33-47`, `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:629-728`).
- Vor jedem Result wird der Mirror geflusht; auch EOF, Fehler und Cancellation lösen einen finalen Flush aus (`src/claude_agent_sdk/_internal/query.py:296-303`, `src/claude_agent_sdk/_internal/query.py:354-373`).

Für WhisperM8 sind besonders die Reihenfolge `Eingabe schließen → CLI-Schreibfrist → TERM → KILL → wait/reap` und die Trennung von Terminaldaten, strukturierten Ereignissen und stderr relevant.

### Persistenz über Neustarts

Persistenz hängt nicht am Clientobjekt. Die lokale JSONL bleibt nach Prozessende liegen und kann gelistet oder mit `--resume` wieder geöffnet werden. Bei einem Remote-Store wird die Session vor dem Spawn in ein temporäres Verzeichnis mit exakt der erwarteten Claude-Verzeichnisstruktur materialisiert und über `CLAUDE_CONFIG_DIR` an die echte CLI übergeben (`src/claude_agent_sdk/_internal/session_resume.py:1-9`, `src/claude_agent_sdk/_internal/session_resume.py:160-193`). Erst nachdem Prozess und Reader geschlossen sind, wird dieses temporäre Verzeichnis entfernt (`src/claude_agent_sdk/client.py:612-621`, `src/claude_agent_sdk/_internal/client.py:73-90`).

Subagent-Transkripte und Metadaten werden beim Resume ebenfalls materialisiert, sofern der Store `list_subkeys()` implementiert (`src/claude_agent_sdk/_internal/session_resume.py:171-175`, `src/claude_agent_sdk/_internal/session_resume.py:437-501`). Externe Subpaths werden gegen absolute Pfade, `..`, Windows-Laufwerkspräfixe, NUL und tatsächliches Ausbrechen aus dem Sessionverzeichnis geprüft (`src/claude_agent_sdk/_internal/session_resume.py:504-536`).

### Was nicht als Beleg für WhisperM8s PTY gelten darf

Nicht vorhanden sind:

- PTY-Anlage und Controlling-Terminal-Semantik,
- Window-Resize beziehungsweise `SIGWINCH`,
- termios-Modi und Restore nach Crash,
- Escape-Sequenz-/Alternate-Screen-Verhalten,
- Foreground-Process-Groups und Signale an Prozessgruppen,
- SwiftTerm-spezifischer Backpressure,
- macOS Sleep/Wake- oder App-Termination-Verhalten.

WhisperM8 bleibt hier selbst verantwortlich. Das SDK ist nur Beleg für die Prozess- und Persistenzreihenfolge, nicht für eine fertige PTY-Lösung.

## 5. Multi-Account-Isolation

### Vorhandene Mechanismen

Der Transport baut für jeden Prozess ein eigenes Environment. Explizite `options.env`-Werte überschreiben geerbte Werte, und ein optionales `user` wird an den Subprozess-Launcher weitergegeben (`src/claude_agent_sdk/types.py:1869-1874`, `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:491-502`, `src/claude_agent_sdk/_internal/transport/subprocess_cli.py:540-548`). `CLAUDE_CONFIG_DIR` wird sowohl beim Finden lokaler Sessions als auch beim Spawn berücksichtigt (`src/claude_agent_sdk/_internal/sessions.py:122-141`). Damit können Accounts durch getrennte Config-Wurzeln und Auth-Environments isoliert werden.

Bei Store-Resume kopiert die Materialisierung Auth-Daten aus dem effektiven Config-Verzeichnis. API-Key und OAuth-Token aus dem Environment werden berücksichtigt; auf macOS existiert ein Keychain-Fallback (`src/claude_agent_sdk/_internal/session_resume.py:319-359`). Ein OAuth-Refresh-Token wird vor dem Schreiben in das temporäre Verzeichnis entfernt, damit der kurzlebige Prozess keinen Single-Use-Refresh verbraucht und die Eltern-Credentials unbrauchbar macht (`src/claude_agent_sdk/_internal/session_resume.py:369-392`).

### Store-Isolation ist nur projektbezogen

Der ausführbare Store-Vertrag prüft, dass gleiche `session_id`-Werte unter verschiedenen `project_key`-Werten getrennt bleiben (`src/claude_agent_sdk/testing/session_store_conformance.py:123-136`). `project_key_for_directory()` wird stabil aus kanonischem Pfad und NFC-normalisierter, portabler Sanitization abgeleitet (`src/claude_agent_sdk/_internal/sessions.py:1419-1430`).

Eine explizite `account_id` gehört aber nicht zum Standardschlüssel. Zwar bezeichnet die Typdokumentation `project_key` als caller-defined Scope und empfiehlt bei Multi-Tenancy Tenant-ID oder Projektname (`src/claude_agent_sdk/types.py:1340-1344`), doch das automatische Live-Mirroring leitet den Schlüssel aus dem CLI-Dateipfad ab (`src/claude_agent_sdk/_internal/session_store.py:149-192`). In `ClaudeAgentOptions` gibt es keine eigene Account-Namespace-Option für den Store.

Damit ist echte Multi-Account-Isolation nicht vollständig gelöst. Verlässlich ist sie nur, wenn der Host pro Account mindestens Folgendes trennt:

- `CLAUDE_CONFIG_DIR`,
- Credentials beziehungsweise Prozess-Environment,
- Store-Instanz oder Store-Prefix,
- lokalen WhisperM8-Katalog,
- Schlüssel für Session-Lookups.

Eine UUID allein darf nie accountübergreifend als Primärschlüssel dienen.

## Verbindlicher SessionStore-Vertrag

### Schlüssel und Datentreue

`SessionStoreEntry` ist absichtlich nur minimal typisiert. Adapter sollen den internen CLI-JSONL-Typ nicht interpretieren, sondern alle unbekannten Felder verlustfrei als JSON-Objekte roundtrippen (`src/claude_agent_sdk/types.py:1354-1367`). Byteidentität ist nicht erforderlich; Deep Equality genügt, weil beispielsweise PostgreSQL JSONB Schlüssel umsortieren darf (`src/claude_agent_sdk/types.py:1470-1482`).

### Pflichtmethoden

- `append(key, entries)`: append-only, aufrufreihenfolgetreu innerhalb eines Prozesses, UUID-Deduplizierung empfohlen (`src/claude_agent_sdk/types.py:1448-1467`).
- `load(key)`: vollständige Session oder `None`, vor dem Spawn aufgerufen (`src/claude_agent_sdk/types.py:1470-1484`).

### Optionale Methoden

- `list_sessions(project_key)`: IDs plus epoch-ms `mtime`; Reihenfolge beliebig, SDK sortiert (`src/claude_agent_sdk/types.py:1486-1496`).
- `list_session_summaries(project_key)`: atomar beziehungsweise per Session serialisiert gepflegte Sidecars (`src/claude_agent_sdk/types.py:1498-1520`).
- `delete(key)`: Hauptsession-Löschung muss Subkeys kaskadieren; ohne Implementierung ist Löschen ein No-op (`src/claude_agent_sdk/types.py:1522-1533`).
- `list_subkeys(key)`: Discovery aller Subagent-Dateien für Resume (`src/claude_agent_sdk/types.py:1535-1543`).

Die mitgelieferte Conformance-Suite prüft 14 Verhaltensverträge: Reihenfolge, Unknown→`None`, leeres Append als No-op, Subpath-Isolation, Projektisolation, epoch-ms-Zeiten, Ausschluss von Subpaths aus dem Hauptlisting, kaskadierendes Löschen und Summary-Verhalten (`src/claude_agent_sdk/testing/session_store_conformance.py:54-318`). Die Beispiel-README spricht noch von 13 Verträgen (`examples/session_stores/README.md:1-13`); das ist erkennbare Dokumentationsdrift, nicht die aktuelle ausführbare Norm.

## Fehlerwege

| Situation | Verhalten | Bewertung für WhisperM8 |
|---|---|---|
| Ungültige UUID bei Read-Helper | leere Liste beziehungsweise `None` (`src/claude_agent_sdk/_internal/sessions.py:1097-1105`) | Für UI-Auswahl besser als expliziter Validierungsfehler sichtbar machen |
| Ungültige UUID bei Mutation/Fork/Import | `ValueError` (`src/claude_agent_sdk/_internal/session_mutations.py:293-308`, `src/claude_agent_sdk/_internal/session_import.py:64-73`) | Gute Fail-fast-Norm |
| Explizite Store-Session fehlt | Materialisierung fällt aus, normale CLI-Behandlung übernimmt (`src/claude_agent_sdk/_internal/session_resume.py:128-157`) | Für ausgewählte WhisperM8-Session zu permissiv |
| Continue findet nichts | frische Session | Nur für ausdrücklich globale Continue-Aktion akzeptabel |
| Store-Load/List timeout | kontextreicher `RuntimeError`; Standard 60 s (`src/claude_agent_sdk/_internal/session_resume.py:294-305`, `src/claude_agent_sdk/types.py:2076-2082`) | Spawn blockieren und Fehler am Session-Datensatz anzeigen |
| Fehler nach Temp-Verzeichnis-Erzeugung | Cleanup auch bei Cancellation über `BaseException` (`src/claude_agent_sdk/_internal/session_resume.py:160-184`) | Direkt übernehmen |
| Mirror-Append schlägt fehl | nicht fatal, Retry und `MirrorErrorMessage` | Session weiterlaufen lassen, aber Reparaturbedarf persistent markieren |
| Einzelner Store-Load im Listing scheitert | Zeile bleibt mit leerer Summary statt Gesamtabbruch (`src/claude_agent_sdk/_internal/sessions.py:1525-1575`) | Gute degradierte Discovery; Fehlerkennzeichen ergänzen |
| Beschädigte lokale JSONL-Zeile | beim historischen Lesen übersprungen (`src/claude_agent_sdk/_internal/sessions.py:897-928`) | Rest der Session retten, Korruption diagnostizieren |
| CLI endet non-zero nach strukturiertem Error-Result | generischer ProcessError wird durch CLI-Fehlertext ersetzt (`src/claude_agent_sdk/_internal/query.py:328-353`) | Strukturierte CLI-Wahrheit vor Exitcode priorisieren |
| Working Directory fehlt | eigener `CLIConnectionError` (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:568-582`) | Vor Spawn prüfen |

## Direkter Vergleich mit WhisperM8s Wrapper-Modell

| Aspekt | SDK | WhisperM8-Bewertung |
|---|---|---|
| Echte CLI als Runtime | Ja, aber über JSON-Pipes | Gleiche richtige Grundentscheidung; WhisperM8 ist für das echte interaktive TUI mit SwiftTerm geeigneter |
| Persistente Identität | UUID plus Projekt-Scope, unabhängig vom Prozess | Normativ stärker als jedes Modell, das Tab oder PTY-PID als Session behandelt |
| Aktive Auswahl | Kein UI-Modell | WhisperM8 braucht zusätzlich eine saubere Trennung zwischen UI-Chat-ID, Claude-UUID und Prozessinstanz |
| Resume | konkrete UUID, Store-Continue wird vor Spawn konkretisiert | Als `--resume=<uuid>` übernehmen; keine implizite Heuristik bei ausgewähltem Chat |
| Fork | ausdrücklich neuer Identitätsübergang; Herkunft und Nachrichten-UUIDs werden getrennt | SDK ist hier die stärkere Norm. WhisperM8 sollte Fork nie als Resume mit umbenanntem UI-Eintrag behandeln |
| Historisches Lesen | Zweigrekonstruktion über `parentUuid` | Deutlich besser als lineares JSONL-Lesen; direkt übertragbar |
| Wiederfinden | Scan über Projekte/Worktrees plus Deduplizierung und Store-Gap-Fill | Robuster als ein reiner Wrapper-Katalog; WhisperM8 sollte beide Quellen reconciliieren |
| Prozessrobustheit | Starker Close-/Reap-/Framing-Pfad | Übertragbar, aber PTY-spezifische Lücken bleiben bei WhisperM8 |
| Persistenz | CLI-JSONL primär, Store sekundär und reparierbar | Passt exakt zum Host-Modell; WhisperM8 sollte externe Claude-Dateien weiterhin nicht mutieren |
| Multi-Account | Config-/Environment-Trennung möglich, kein vollständiger Account-Schlüssel | WhisperM8 kann und sollte stärker sein, indem Account-Scope Teil jeder lokalen Zuordnung wird |
| Hooks | Hookinputs tragen Session-ID, Transkriptpfad und cwd (`src/claude_agent_sdk/types.py:275-281`) | Gute Bestätigungsquelle neben JSONL, aber nicht alleinige Persistenzquelle |

Eine auffällige Lücke in der Python-Typoberfläche: `SessionStartHookSpecificOutput` existiert (`src/claude_agent_sdk/types.py:455-459`), aber `SessionStart` fehlt in der öffentlichen `HookEvent`-Union (`src/claude_agent_sdk/types.py:259-271`), und ein eigener typisierter SessionStart-Input mit Resume-/Fork-Quelle ist nicht auffindbar. Daraus lässt sich keine belastbare Hook-Semantik für die Unterscheidung Resume versus Fork ableiten. WhisperM8 sollte den Übergang deshalb aus dem eigenen Spawn-Intent plus bestätigter CLI-ID und JSONL-Herkunft bestimmen.

## Priorisierte übertragbare Muster

### P0 — Identität als zusammengesetztes, persistentes Modell

WhisperM8 sollte mindestens getrennt speichern:

```text
AgentChatID            stabile UI-/App-ID
AccountScope           Claude-Account beziehungsweise Config-Root
ProjectIdentity        kanonischer cwd plus abgeleiteter CLI-Projektschlüssel
ClaudeSessionUUID      von der CLI bestätigte persistente UUID
BranchOrigin           sourceSessionUUID plus optional sourceMessageUUID
ProcessGeneration      konkrete PTY-Instanz, PID und Startzeit
TransitionState        new, resuming, forking, confirmed, failed
```

UI-Auswahl referenziert `AgentChatID`. `ClaudeSessionUUID` bindet die echte CLI-Historie. `ProcessGeneration` darf nach Crash oder Neustart ersetzt werden, ohne den Chat umzubenennen.

### P0 — Resume/Fork als verifizierte Zustandsmaschine

Vor jedem Spawn muss genau eine Operation aufgelöst sein:

- Neu: frische erwartete Ziel-UUID oder später von CLI übernehmen.
- Resume: Quelle und erwartetes Ziel sind dieselbe UUID.
- Fork: Quelle ist die alte UUID, erwartetes Ziel muss verschieden sein.

Flags mit nicht vertrauenswürdigen Werten als gebundene Argumente übergeben: `--resume=<uuid>` und `--session-id=<uuid>` statt zweier Tokens. Genau dieses Muster wurde im SDK als Schutz vor Flag-Injection eingeführt (`src/claude_agent_sdk/_internal/transport/subprocess_cli.py:352-361`, `tests/test_transport.py:121-144`).

Der Datensatz bleibt bis zur Bestätigung im Übergangszustand. Bestätigung kann aus strukturiertem CLI-Ergebnis, einem Wrapper-Hook mit `session_id/transcript_path` oder einer gezielten JSONL-Reconciliation kommen. Danach gelten harte Invarianten:

- Resume: bestätigte UUID entspricht der Quelle.
- Fork: bestätigte UUID unterscheidet sich von der Quelle.
- Wenn eine Ziel-UUID vorgegeben wurde, muss sie der bestätigten UUID entsprechen.
- Der gefundene Transkriptpfad muss zum erwarteten Account-Config-Root und Projekt-Scope gehören.

Bei Abweichung darf WhisperM8 den Prozess nicht still dem ausgewählten Chat zuordnen.

### P0 — Startup-Reconciliation gegen die CLI-Wahrheit

Beim App-Start und nach unerwartetem Prozessende:

1. lokalen WhisperM8-Katalog laden,
2. die für jeden Account erlaubten Claude-Projektverzeichnisse read-only scannen,
3. UUID, cwd, mtime und Titel aus den JSONLs ableiten,
4. Worktrees und lange Pfadvarianten berücksichtigen,
5. Katalogeinträge mit fehlender Datei als `missing` markieren, nicht löschen,
6. neue externe Sessions als `discovered` anbieten,
7. gleiche UUID nur innerhalb desselben Account-/Projekt-Scope deduplizieren,
8. unbestätigte Resume-/Fork-Übergänge anhand JSONL und Herkunft auflösen.

Das verhindert, dass ein UI-Schreibfehler oder App-Crash eine weiterhin vorhandene Claude-Session unsichtbar macht.

### P1 — Branch-bewusstes JSONL-Lesen

Nicht die letzte Zeile oder den letzten User-/Assistant-Eintrag als aktiven Zweig behandeln. Wie das SDK:

- UUID-Index bauen,
- Sidechains, Team- und Meta-Blätter aus der Hauptauswahl entfernen,
- aktuelles Hauptblatt bestimmen,
- ausschließlich `parentUuid` bis zur Wurzel folgen,
- Compact-Summary-Semantik respektieren,
- beschädigte Einzelzeilen isoliert überspringen und melden.

Für Fork-Verifikation zusätzlich `forkedFrom` lesen, falls die jeweilige CLI-Version es schreibt. Herkunft darf dennoch nicht aus bloßer Titelähnlichkeit geraten werden.

### P1 — PTY-Teardown mit Schreibfrist und sicherem Reaping

Empfohlene Reihenfolge:

1. neue Eingaben sperren,
2. PTY-Eingabeseite geordnet schließen beziehungsweise EOF senden,
3. kurze, begrenzte Frist für finale CLI-/JSONL-Schreibvorgänge,
4. Prozessgruppe mit TERM beenden,
5. nach weiterer Frist KILL,
6. immer `waitpid`/Reap,
7. Reader erst danach endgültig schließen,
8. JSONL/Katalog reconciliieren.

Resize, Prozessgruppe, termios und SwiftTerm-Backpressure müssen PTY-spezifisch ergänzt werden; dafür liefert der Python-Klon keine Implementierung.

### P1 — Account-Scope in jedem Schlüssel

Ein sicherer Lookup-Schlüssel sollte mindestens `accountScope + projectKey + claudeSessionUUID` enthalten. Jeder Account benötigt einen getrennten effektiven `CLAUDE_CONFIG_DIR`, getrennte Credential-Übergabe und einen getrennten Katalog-/Mirror-Namespace. Auch globale Suche nach UUID darf nie ohne Accountfilter erfolgen.

### P2 — Mirror als beobachtbare, reparierbare Sekundärkopie

Falls WhisperM8 einen eigenen Index oder Mirror pflegt:

- lokale CLI-JSONL bleibt autoritativ,
- Append-Reihenfolge bewahren,
- UUID-haltige Entries idempotent behandeln,
- Timeouts nicht blind duplizieren,
- Fehler persistent als Repair-Status speichern,
- Result/Stop/Prozessende als Flush-Barrieren verwenden,
- einen erneuten Import aus JSONL bereitstellen.

Ein flüchtiger Logeintrag reicht nicht, weil auch die Mirror-Fehlermeldung verloren gehen kann.

### P2 — Listing-Index mit Freshness-Prüfung

Für große Bestände kann WhisperM8 inkrementelle Summary-Sidecars führen. Diese bleiben jedoch Cache:

- derselbe Storage-Clock für Transcript- und Summary-mtime,
- stale oder fehlende Summary durch Quell-JSONL nachfüllen,
- Subagent-Entries nicht in die Hauptsession-Summary falten,
- Listing zuerst nach Account und Projekt scopen,
- erst nach Filterung paginieren.

## Drei Kernmuster

1. Persistente Claude-UUID, UI-Chat und PTY-Prozess sind drei verschiedene Identitäten; alle Zuordnungen werden zusätzlich nach Account und Projekt gescopet.
2. Resume und Fork sind explizite, vor dem Spawn festgelegte und nach dem Spawn verifizierte Übergänge: Resume behält die UUID, Fork muss eine neue UUID mit nachvollziehbarer Herkunft ergeben.
3. Claude-JSONL ist die autoritative, read-only rekonstruierbare Wahrheit; WhisperM8s Katalog oder Mirror wird beim Start reconciliiert und besitzt einen Repair-Pfad statt stiller Vollständigkeitsannahmen.

Vorgesehener Dateipfad des Berichts: `docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/code-analysen/agent-sdk-python.md`.
