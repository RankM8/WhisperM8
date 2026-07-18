# claude-code-log

## Projektüberblick

`claude-code-log` ist eine Python-3.10+-CLI, die Claude-Code-JSONL in HTML und Markdown aufbereitet. Click, Pydantic, Jinja2, Mistune und Textual bilden den Kernstack (`pyproject.toml:1-29`, `README.md:1-17`). Für diesen Audit sind vor allem diese Pfade relevant:

- `claude_code_log/converter.py:251-423` — zeilenweises Laden, Fehlerisolation und Event-Dispatch.
- `claude_code_log/factories/transcript_factory.py:93-149,157-254` — tolerante Content-Normalisierung und typisierte Entry-Erzeugung.
- `claude_code_log/models.py:136-164,198-242,304-375` — Tool-, Transcript- und strukturelle Passthrough-Modelle.
- `claude_code_log/dag.py:119-181,189-282,872-1008` — UUID-Index, Parent-Graph, Reparatur und vollständige Traversierung.
- `claude_code_log/renderer.py:1760-1815,1978-2002,2202-2255` — Tool-Use/Result-Korrelation und Reordering.
- `claude_code_log/converter.py:960-1104` — semantische Deduplizierung samt Parent-Referenz-Reparatur.

Das Projekt ist ein Offline-Log-Rekonstrukteur, kein PTY- oder CLI-Host. Prozesslebensdauer, `--resume`/`--fork-session`, Neustart-Persistenz und Multi-Account-Isolation sind im untersuchten Parserpfad daher nicht implementiert beziehungsweise nicht auffindbar.

## Konkrete Lösungen im Fokus

### 1. JSONL wird fehlertolerant und lokal isoliert gelesen

Der Loader iteriert die Datei zeilenweise, ersetzt ungültige UTF-8-Sequenzen und behandelt jede Zeile separat (`claude_code_log/converter.py:308-324`). Nicht-Objekte, kaputtes JSON, Pydantic-Validierungsfehler und unerwartete Exceptions werden protokolliert; die nächste Zeile wird weiterverarbeitet (`claude_code_log/converter.py:325-329,400-423`). Das ist für eine live wachsende Claude-Datei robuster als ein atomarer Whole-File-Decode.

Grenzen: Eine beim Lesen nur teilweise geschriebene letzte Zeile wird verworfen und nicht später erneut versucht. Ein syntaktisch gültiges, aber schemawidriges bekanntes Event fällt als ganze Zeile aus. Der Loader streamt zwar Bytes beziehungsweise Zeilen, hält danach jedoch `messages`, UUID-Index und DAG vollständig im Speicher (`claude_code_log/converter.py:302-306`; `claude_code_log/dag.py:119-181`). Es gibt keinen belegten Hard-Limit- oder Backpressure-Mechanismus.

### 2. Compact- und Parent-Chain werden als reparierbarer Graph behandelt

Identität liegt auf drei Ebenen: `sessionId` gruppiert, `uuid` identifiziert ein Event und `parentUuid` definiert die Kante (`claude_code_log/models.py:198-206`; `claude_code_log/dag.py:57-80`). Doppelte UUIDs werden deterministisch der zeitlich frühesten Session zugeordnet (`claude_code_log/dag.py:119-181`). Fehlende Parents werden nicht zum Totalfehler: Die Kante wird gelöscht und das Kind zum Root hochgestuft (`claude_code_log/dag.py:206-238`). Zyklen, einschließlich Self-Loops, werden vor Aufbau der Child-Kanten gebrochen; die Prüfung ist amortisiert O(n) (`claude_code_log/dag.py:240-282`).

`/compact` ist ausdrücklich kein Sessionwechsel: `compact_boundary` darf innerhalb derselben `sessionId` einen neuen Root eröffnen (`claude_code_log/dag.py:423-452`). Alle Roots werden traversiert, Coverage wird geprüft und unvollständige Walks fallen auf Timestamp-Sortierung zurück (`claude_code_log/dag.py:894-973`). Die Root-Segmente derselben Session werden anschließend chronologisch zusammengeführt, statt ältere Segmente zu verlieren (`claude_code_log/dag.py:975-1006`). Deduplizierung führt zusätzlich eine `dropped_uuid -> survivor_uuid`-Map und schreibt `parentUuid` beziehungsweise `leafUuid` um (`claude_code_log/converter.py:974-978,991-997,1078-1103`).

Das ist für WhisperM8s Wrapper-Modell besser als eine rein lineare Anzeige nach Dateireihenfolge: PTY-Prozess, persistente Claude-`sessionId` und ausgewählter UI-Chat dürfen nicht als dieselbe Identität behandelt werden. Für Rekonstruktion sollte die JSONL-Parent-Chain maßgeblich sein; Compact bleibt ein Segmentwechsel innerhalb derselben persistenten Session.

### 3. Tool-Ergebnisse werden über stabile IDs statt über Nachbarschaft zugeordnet

`tool_use.id` und `tool_result.tool_use_id` sind explizite Modelle (`claude_code_log/models.py:136-148`). Der Renderer baut O(n)-Indices mit dem Schlüssel `(session_id, tool_use_id)` (`claude_code_log/renderer.py:1760-1793`) und paart auch nicht benachbarte Events (`claude_code_log/renderer.py:1978-2002`). Das Session-Scope verhindert Kollisionen beim Resume; beim Reordering wird derselbe zusammengesetzte Schlüssel erneut verwendet (`claude_code_log/renderer.py:2215-2255`). Fortsetzungsprosa zwischen Use und Result verhindert bewusst ein chronologisch falsches Heranziehen des Results (`claude_code_log/renderer.py:1940-2002`).

Defektkante: Die Dict-Zuweisung ist Last-Write-Wins. Zwei Uses oder Results mit identischem Schlüssel innerhalb derselben Session werden nicht als Mehrdeutigkeit markiert (`claude_code_log/renderer.py:1786-1793`). Orphan-Results bleiben erhalten, aber unpaired. WhisperM8 sollte die Zuordnung deshalb als `0..n`-Diagnose modellieren: genau 1:1 paaren, 0 oder mehr als 1 sichtbar als Parserdefekt ausweisen und niemals heuristisch über Nachbarschaft oder Toolname verbinden.

### 4. Unbekannte Event-Typen bleiben strukturell erhalten

Unbekannte Top-Level-Typen mit `uuid` und `sessionId` werden als `PassthroughTranscriptEntry` aufgenommen, damit ihre Parent-Kante nicht verschwindet (`claude_code_log/converter.py:371-385`; `claude_code_log/models.py:304-326`). Unbekannte Metadaten ohne DAG-Felder werden übersprungen und pro Typ höchstens einmal gewarnt (`claude_code_log/converter.py:387-399`). Unbekannte oder schemawidrige Content-Blöcke werden als Text-Fallback erhalten (`claude_code_log/factories/transcript_factory.py:107-118,134-149`).

Das ist für einen Host der echten CLI klar besser als ein geschlossenes Event-Enum, das bei einem Claude-Update die Kette zerreißt. Schlechter ist der verlustreiche Content-Fallback über `str(dict)`: Für WhisperM8 sollte der rohe JSON-Wert zusätzlich unverändert erhalten bleiben, auch wenn die aktuelle UI ihn nicht versteht.

### 5. Große Dateien: linearer Kern, aber kein Bounded-Memory-Parser

Die Quelldatei wird nicht mit `readToEnd` geladen (`claude_code_log/converter.py:317-324`). Parent-Zyklusprüfung und Pairing sind indexbasiert und linear angelegt (`claude_code_log/dag.py:248-267`; `claude_code_log/renderer.py:1760-1815,2062-2074`). Reale Fixtures enthalten laut Testkommentar einzelne Dateien um 5 MB; normale Integrationstests kürzen Kopien auf vollständige Zeilengrenzen, während volumenbezogene Tests die Originale behalten (`test/test_integration_realistic.py:39-81`). Ein Regressionstest schützt außerdem gegen zyklische Parent-Ketten, die früher Endlosschleifen und gigabyteweise Zustand erzeugten (`test/test_dag.py:641-717`).

Für WhisperM8 ist das ein guter erster Sicherheitsstandard, aber keine vollständige Lösung für sehr große Langzeitsessions. Empfohlen ist inkrementelles Einlesen ab gespeichertem Byte-Offset plus kompakter UUID-Metadatenindex. UI-Pagination darf erst nach globaler Korrelation erfolgen, sonst können Tool-Paare und Parent-Kanten über Seitengrenzen verloren gehen.

## Direkter Vergleich zum WhisperM8-CLI-Host-Modell

- **Besser übertragbar:** Die Referenz trennt Prozessdarstellung von persistenter Log-Identität und rekonstruiert ausschließlich aus `sessionId`, `uuid` und `parentUuid`. WhisperM8 sollte beim Start via `--session-id`, beim Resume via `--resume` und beim Fork via `--fork-session` den erwarteten Identitätsübergang speichern und anschließend gegen die tatsächlich gelesene JSONL verifizieren.
- **Besser in der Referenz:** Unbekannte strukturelle Events, Compact-Roots, Orphans und Zyklen führen nicht zum Verlust der restlichen Session.
- **Besser bei WhisperM8 möglich:** Als Host kennt WhisperM8 zusätzlich Spawn-Intent, Account- beziehungsweise Environment-Kontext, PTY-Lebensdauer und aktive UI-Auswahl. Diese Metadaten können Parserdiagnosen erklären, dürfen aber JSONL-IDs nicht überschreiben.
- **Nicht vergleichbar oder auffindbar:** Die Referenz löst keine PTY-Robustheit oder Account-Isolation. Für WhisperM8 muss der JSONL-Index mindestens nach Account- beziehungsweise Claude-Config-Root und Projekt partitioniert sein; bloße `sessionId`-Gleichheit darf keine kontoübergreifende Zuordnung erlauben.

## Priorisierte übertragbare Muster und Test-Fixtures

### P0 — toleranter Zeilen-Decoder mit Rohdaten-Erhalt

Parservertrag: Eine defekte Zeile darf weder vorherige noch folgende Events verlieren; jede akzeptierte Zeile behält Raw JSON, Parse-Status und Zeilennummer.

Fixtures und Defektfälle:

1. Gültig → abgeschnittene JSON-Zeile → gültig: zwei Events, ein Decode-Diagnostic; nach Dateiwachstum muss die Tail-Zeile nachparsebar sein.
2. Gültiges JSON, aber Array oder String statt Objekt: überspringen, Diagnose, kein Sessionabbruch.
3. Bekanntes `assistant`-Event mit fehlendem Pflichtfeld: isolierter Schemafehler; Parent-Kinder dahinter werden als Orphans erhalten.
4. Unbekannter Top-Level-Typ mit `uuid`, `sessionId` und `parentUuid`: unsichtbarer struktureller Node bleibt in der Kette.
5. Unbekannter Content-Block: Raw JSON bleibt byte- beziehungsweise wertgleich verfügbar, auch wenn nur ein Fallback gerendert wird.

### P0 — Parent-Graph mit Compact-Segmenten und vollständiger Coverage

Fixtures und Defektfälle:

1. Eine `sessionId`, zwei `compact_boundary`-Roots: beide Segmente erscheinen chronologisch genau einmal.
2. Fehlender Parent mitten in der Datei: Kind wird Root, seine Nachfahren bleiben verkettet; Diagnostic nennt UUID und fehlenden Parent.
3. Self-Loop, Zwei- und Drei-Knoten-Zyklus: Terminierung unter festem Zeitlimit, jedes Event höchstens einmal, Zyklus-Diagnostic.
4. Deduplizierter Zwischenknoten mit Kind: Child-Parent wird auf Survivor umgeschrieben, kein künstlicher Root.
5. Walk-Coverage kleiner als Nodezahl: deterministischer Timestamp-Fallback plus Warnung, kein stiller Verlust.

### P1 — session- und account-gescopte Tool-Korrelation

Fixtures und Defektfälle:

1. Zwei Sessions verwenden dieselbe `tool_use_id`: Result paart nur innerhalb seiner `sessionId`.
2. Gleiches ID-Paar in zwei Accounts oder Config-Roots: keinerlei Cross-Account-Pairing.
3. Result vor oder weit nach Use sowie über eine UI-Paginierungsgrenze: weiterhin 1:1 gekoppelt.
4. Fortsetzungsprosa zwischen Use und Result: semantische Paarung bleibt bekannt, Anzeigeordnung bleibt chronologisch.
5. Orphan-Use, Orphan-Result und doppelte Uses oder Results: keine Nachbarschaftsheuristik; explizite Null- beziehungsweise Mehrdeutigkeitsdiagnose.

## Fazit

Die drei stärksten Muster für WhisperM8 sind erstens zeilenweise Fehlerisolation mit Rohdaten-Erhalt, zweitens eine reparierbare `uuid`/`parentUuid`-DAG-Rekonstruktion, die Compact als Multi-Root derselben Session versteht, und drittens Tool-Result-Zuordnung über einen mindestens `(Account-Kontext, sessionId, tool_use_id)`-gescopten Schlüssel. Sie passen direkt zum Host-der-echten-CLI-Constraint: WhisperM8 steuert Prozesse und Flags, rekonstruiert die Wahrheit der Unterhaltung aber aus der persistenten JSONL-Identität.
