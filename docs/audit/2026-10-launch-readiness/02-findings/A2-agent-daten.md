---
status: roh
updated: 2026-10-17
description: Workflow A, A2 Agent-Kern Daten — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A2 Agent-Kern Daten

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

A2 statisch auf Commit a8e0f35 geprüft; keine Produktdateien verändert. Ergebnis: 16 Befunde, davon 4 P0, 8 P1 und 4 P2; A2-04 hat mittlere, die übrigen hohe Konfidenz. Kritisch sind insbesondere der Range-Trap im Summary-Parser, destruktive Future-Schema-Migration und vertrauliche Inhalte in Summary-argv. Der Datenfluss bleibt sinnvoll getrennt: externe Claude-/Codex-JSONL → begrenzte Indexer → serialisierter Workspace-Kern → atomare Repository-Persistenz; Verlauf und Zusammenfassungen lesen die nativen Transcripts separat. Bewusst erhalten bleiben sollten Single-Writer/Store-Lock, diff-gated Mutationen, Utility-Flush mit Terminate-Barriere, Generation-Backups, Tail-first-Verlauf mit gemeinsamer Lese-Drosselung und die einzelne TextKit-Ansicht. Native Titel benötigen keinen eigenen Modellaufruf; die Zusammenfassungen dagegen weiterhin schon. Die gewollte kurze Async-Persistenzlücke, Worktree-Filter und bisherigen Schutz-Workarounds wurden nicht pauschal als neue Bugs gezählt.

## Befunde

### LR-AK-001 (A2-01) · : Ungültige Summary-Ausgabe kann die gesamte App beenden

*P0 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-07

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:57-58`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:39-40`, `Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:67-70`

**Szenario:** Das CLI beendet sich erfolgreich, liefert aber etwa `}{`. firstIndex(of: "{") liegt hinter lastIndex(of: "}"). Die anschließende ClosedRange-Konstruktion text[start...end] verletzt eine Swift-Vorbedingung und beendet den App-Prozess statt einen Summary-Fehler zu liefern. Der äußere do/catch fängt diesen Trap nicht.

**Reproduktion:** AgentSummaryGenerator.parseOutput("}{") aufrufen; statisch nachvollzogen, nicht ausgeführt.

**Fix:** Vor der Range-Konstruktion start <= end prüfen; besser JSON-Objekte strukturiert und begrenzt extrahieren. Regressionstests für vertauschte Klammern, Preamble und unvollständiges JSON. Fehlerhafte Modellantworten müssen als Fehlerwert enden, niemals als Trap.

### LR-AK-002 (A2-02) · : Downgrade überschreibt ein neueres Workspace-Schema

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-01, F-AC-02, F-KO-01  ·  **Alt-ID:** N05, R4-SCHEMA-01

**Beleg:** `WhisperM8/Models/AgentChat.swift:615-619`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1499-1507`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:54-64`

**Szenario:** Eine neuere App hat AgentSessions.json mit schemaVersion 2 und zusätzlichen Session-Feldern geschrieben. Dieser Build dekodiert die bekannten Felder, setzt schemaVersion bedingungslos auf 1 und schreibt beim Load sofort zurück. Unbekannte Felder verschwinden aus der aktiven Datei; unbekannte Kinds werden zudem zu normalen Chats. Ein pre-migration-Backup existiert, wird aber nicht automatisch wiederhergestellt und verhindert die destruktive aktive Migration nicht.

**Reproduktion:** Eine ansonsten gültige Workspace-Datei um schemaVersion: 2 und ein zusätzliches Feld ergänzen; repository.load(migrate: AgentSessionStore.migratedWorkspace) verändert und speichert sie. Nicht ausgeführt.

**Fix:** Future-Version vor jeder Migration erkennen und den gesamten Store schreibgesperrt öffnen oder mit verständlichem Update-Hinweis ablehnen. Unbekannte Datensätze nicht in andere Session-Arten umdeuten. Invariante: unverstandene Daten bleiben bytegetreu erhalten; Backup allein ersetzt keinen Write-Guard.

### LR-AK-003 (A2-03) · : Zusammenfassungen legen vertraulichen Chat-Inhalt in argv offen

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-07

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:33-39`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:87-104`, `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:37-40`

**Szenario:** Eine der übernommenen Nutzer- oder Agent-Nachrichten enthält ein Secret, beispielsweise einen API-Key am Anfang des Texts. Der Excerpt übernimmt diesen unverändert. Der komplette Summary-Prompt wird als Argument an `claude -p` beziehungsweise `codex exec` übergeben und ist während des zusätzlichen Modellaufrufs über Prozessinformationen sichtbar. Damit entsteht ein zusätzlicher Klartext-Offenlegungskanal, obwohl nur eine lokale Übersichtskarte geöffnet wurde.

**Fix:** Prompts über stdin an die echten CLIs übergeben; den Headless-Runner um einen begrenzten stdin-Payload erweitern und diesen nie loggen. argv enthält ausschließlich Optionen und nichtvertrauliche Metadaten. Tests müssen ausdrücklich prüfen, dass ein synthetischer Secret-Marker nicht in argv vorkommt.

### LR-AK-004 (A2-04) · : Skalare Tool-Payloads passieren eine NSException-gefährdete JSON-Serialisierung

*P0 · Launch-Blocker · robustheit · Konfidenz mittel · Aufwand S · Risiko niedrig*

**Features:** F-AC-08

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:349-352`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:374-381`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:155-160`, `WhisperM8/Services/AgentChats/Search/ChatSearchContentExtractor.swift:206-213`

**Szenario:** Eine syntaktisch gültige Transcript-Zeile enthält einen Tool-Aufruf mit `input: 1`, `input: true` oder `input: null`. formatToolInput übergibt diesen skalaren Top-Level-Wert an JSONSerialization.data ohne fragmentsAllowed oder isValidJSONObject-Prüfung. Auf Darwin ist dies ein NSInvalidArgumentException-Pfad; try? schützt nicht gegen NSException. Entsprechendes gilt für skalare Codex-tool_search_call-arguments. Der Such-Extractor hat die notwendige Gültigkeitsprüfung bereits, der Anzeige-Reader nicht.

**Reproduktion:** ClaudeTranscriptReader.parseEntry mit {"type":"assistant","message":{"content":[{"type":"tool_use","name":"x","input":1}]}} aufrufen. API-Vertrag statisch geprüft; Darwin-Crashprobe nicht ausgeführt.

**Fix:** Vor JSONSerialization.data isValidJSONObject prüfen oder bewusst fragmentsAllowed verwenden; unerwartete Payloads als ungefährlichen Klartext beziehungsweise Parse-Fehler behandeln. Den Reader gegen alle JSON-Wertarten testen. Ein defektes externes Transcript darf niemals den GUI-Prozess beenden.

### LR-AK-005 (A2-05) · : Fehlgeschlagene Workspace-Writes bleiben unsichtbar und ohne eigenen Retry

*P1 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-01, F-AC-02

**Beleg:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:261-285`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:298-317`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:144-154`, `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift:363-391`

**Szenario:** Ein Flush scheitert kurzzeitig, etwa wegen voller Platte. drain setzt dirty wieder auf true, plant aber keinen neuen Versuch und veröffentlicht keinen Fehlerzustand. Wird anschließend Speicher freigegeben und weder mutiert noch ein Lifecycle-Flush ausgelöst, bleibt der neue Stand beliebig lange nur im RAM. Ein späterer Absturz verliert die Änderungen trotz längst wieder beschreibbarer Platte. Der vorhandene Test erzwingt den Retry selbst mit einem zweiten flush und deckt gerade keinen automatischen Retry ab.

**Fix:** Fehlerzustand beobachtbar machen und mit begrenztem Backoff eigenständig erneut flushen. Bei dauerhaftem Fehler eine verständliche Warnung samt Handlungsoption anzeigen; sauberes Beenden darf fehlgeschlagene Persistenz nicht als gesichert behandeln. Serialisierte Writes und Utility-Queue beibehalten.

### LR-AK-006 (A2-06) · : Der Codex-Statusparser versteht das verwendete Rollout-Format nicht

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-06, F-AC-07

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:112-153`, `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:285-292`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:461-471`, `Tests/WhisperM8Tests/AgentTestSupport.swift:43-61`, `Tests/WhisperM8Tests/AgentTranscriptStatusTests.swift:43-56`

**Szenario:** Ein Codex-Chat schreibt `event_msg` mit payload.type `task_complete`, wie die echte Repo-Fixture. parseCodexLine erwartet stattdessen type `event` und subtype `turn.completed`; die echte Abschlusszeile wird .other. Die App zeigt noch bis zum 30-Sekunden-Heuristikwechsel working und meldet niemals turnFinished für diesen Turn. Bei einem langen stillen Tool-Lauf werden dieselben realen Events ebenfalls nur als .other behandelt und nach 30 Sekunden fälschlich idle. Turn-Ende-abhängige Titel und Benachrichtigungen bleiben aus.

**Reproduktion:** AgentTranscriptParser.parseLine(CodexRolloutFixtures.taskComplete, provider: .codex) liefert anhand des Switches .other statt assistantMessageStopped. Die Status-Tests prüfen ausschließlich das alte type/subtype-Format.

**Fix:** Die tatsächlichen event_msg-/response_item-Payloads abbilden, insbesondere task_started, task_complete und Abbrüche; token_count als statusneutrale Metadaten überspringen. Dieselben realen Rollout-Fixtures für Reader und Statusparser verwenden; alte Formate als Kompatibilität erhalten.

### LR-AK-007 (A2-07) · : Ein großes letztes JSONL-Event macht den gesamten Verlauf unerreichbar

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-08

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:418-432`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:255-267`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:79-91`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:44-59`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:192-208`

**Szenario:** Ein bestehender Chat endet nach einem Abbruch mit einem Tool-Ergebnis oder Bild-Event, dessen einzelne JSONL-Zeile größer als das anfängliche Tail-Fenster ist. Der Tail enthält nur den angeschnittenen Rest dieser Zeile; der Reader entfernt ihn und liefert messages=[] bei hasTruncatedHead=true. Der Container wählt jedoch ausschließlich den Empty-State und baut historyStrip nicht. Der Nutzer sieht eine angeblich leere Konversation und hat keinen Nachlade-Button, obwohl davor lesbare Nachrichten existieren.

**Fix:** Nachladen auch bei leerem, aber kopfgekürztem Transcript anbieten. Alternativ den Reader begrenzt rückwärts bis zu vorherigen vollständigen Events suchen lassen. Das Speicherbudget erhalten; keinen unbeschränkten Voll-Read als Ausweichlösung einführen.

### LR-AK-008 (A2-08) · : Eine UTF-8-Schnittkante verhindert dauerhaft den Import einer gültigen Session

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-05

**Beleg:** `WhisperM8/Services/AgentChats/BoundedJSONLReader.swift:19-27`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:149-150`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:124-131`, `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:60-67`

**Szenario:** Ein gültiges Claude-Transcript ist größer als 1 MiB und Byte 1.048.576 liegt mitten in einem UTF-8-Zeichen, etwa einem Umlaut oder Emoji. Obwohl die ersten vollständigen Zeilen Session-ID, cwd und Prompt enthalten, scheitert String(data:encoding:) für den gesamten Prefix. Der Indexer verwirft die ganze Datei und cached nil mit Größe und mtime. Solange die beendete Datei unverändert bleibt, repariert auch ein erneuter Scan den fehlenden Import nicht.

**Fix:** Prefix zuerst an vollständigen Zeilengrenzen schneiden und die einzelnen Zeilen unabhängig dekodieren; unvollständige Schlussbytes dürfen vorherige gültige Zeilen nicht verwerfen. Flüchtige Lesefehler nicht wie sicher irrelevante Dateien dauerhaft negativ cachen. Grenztests mit mehrbyteigen Zeichen exakt am Leselimit ergänzen.

### LR-AK-009 (A2-09) · : Summary-Hilfsläufe verlieren das Konto und Backend des Chats

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-07, F-KO-01, F-GPT-01, F-GPT-02  ·  **Alt-ID:** C06

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-39`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:312-321`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:340`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:110-127`

**Szenario:** Ein Claude-Chat läuft erfolgreich unter einem eingeloggten Zusatzprofil, main ist abgemeldet. Der Summarizer liest das richtige Transcript, übergibt an generate aber nur provider und prompt. Das allgemeine Environment entfernt CLAUDE_CONFIG_DIR und den GPT-Profilheader; es werden keine sitzungsspezifischen Overrides ergänzt. Die Zusammenfassung läuft deshalb unter main und scheitert trotz gültigem Chat-Login. Ist main eingeloggt, werden dessen Kontingent und gegebenenfalls ein anderer Provider als beim GPT-Chat genutzt.

**Fix:** Einen unveränderlichen Summary-Launch-Kontext aus Konto, Backend, Modell und GPT-Profil der Session übergeben und mit den bestehenden Launch-Bausteinen der echten CLI aufbauen. Bei fehlendem Konto sichtbar abbrechen statt still zu main wechseln. Keine Kontosecrets in argv aufnehmen.

### LR-AK-010 (A2-10) · : Automatische Zusammenfassungen erklären ihren zusätzlichen Datenabfluss nicht

*P1 · Launch-Blocker · privacy · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-AC-07

**Beleg:** `WhisperM8/Support/AppPreferences.swift:239-241`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:124-127`, `WhisperM8/Views/Transcript/SessionSummaryCard.swift:63-69`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:335-340`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-39`

**Szenario:** Bei einer frischen Installation ist Auto-Summary eingeschaltet. Das Anzeigen eines beendeten Chats löst nach zwei Sekunden einen zusätzlichen Remote-Modellaufruf mit Gesprächsausschnitten und extrahierten Fakten aus. Der Einstellungstext sagt nur, dass Timeline-Zusammenfassungen entstehen; weder zusätzliche Übertragung noch verwendetes Konto oder zusätzliche Nutzungskosten werden erklärt. Anders als die direkt darüberstehende Titeloption ist die Zusammenfassung nicht rein lokal. Das verletzt die Datenschutz-DoD trotz vorhandenem Abschaltschalter.

**Fix:** Vor automatischer Aktivierung transparent erklären, welche Inhalte an welchen Dienst und über welches Konto gehen und dass weitere Nutzung entsteht. Bis zur informierten Auswahl opt-in; anschließend sichtbarer Schalter und derselbe Hinweis beim manuellen Erzeugen. Native Titel ohne weiteren Modellaufruf unverändert beibehalten.

### LR-AK-011 (A2-11) · : resumeScans umgeht Single-Flight und kann Account-Stempel zurücksetzen

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-05, F-KO-01, F-KO-02

**Beleg:** `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:90-108`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:120-128`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:159-198`, `WhisperM8/Services/AgentChats/AccountMoveService.swift:66-67`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1127-1135`

**Szenario:** Scan A läuft bereits und hat einen alten Transcript-Root erfasst. Ein Kontoumzug suspendiert neue Scans, bewegt das Transcript und setzt den neuen Profilstempel. resumeScans ruft anschließend direkt startScan auf, obwohl A noch inFlight ist. Damit läuft B parallel. Committen B und danach der alte Snapshot A, schreibt A den alten Account-Stempel wieder in den Workspace; ein Resume kann nun im falschen Config-Dir suchen. Beide Scans schreiben außerdem unabhängig denselben Index-Cache.

**Fix:** Auch den Resume-Pfad über eine Single-Flight-Zustandsmaschine führen. Kontoumzüge erhöhen eine Scan-Generation; Resultate früherer Generationen vor dem Merge verwerfen. Einen frischen Folge-Scan nach Abschluss sicher nachholen, ohne den Account-Move-Cooldown anzuwenden. Invariante: höchstens ein gültiger Scan-Commit und kein Stempel-Rollback durch alte Snapshots.

### LR-AK-012 (A2-12) · : Retention löscht Sessions anhand eines nach await veralteten Schutz-Snapshots

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-12, F-AC-02

**Beleg:** `WhisperM8/Services/AgentChats/SubagentJobRetention.swift:55-66`, `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:251-267`, `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:284-288`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:530-537`

**Szenario:** Ein alter verwaister Subagent-Spiegel ist bei der Kandidatenauswahl weder offen noch laufend. Während die Archivierung auf dem Utility-Task wartet oder andere Kandidaten bearbeitet, öffnet beziehungsweise resumed der Nutzer genau diesen Chat. Nach await löscht runRetentionIfDue trotzdem alle ursprünglich ermittelten IDs, ohne Tabs, Laufstatus oder Änderungen erneut zu prüfen. Auch die Archivierung verwendet den alten Satz. Ein inzwischen genutzter Verlauf kann dadurch aus dem Codex-Root verschoben und sein sichtbarer Workspace-Eintrag entfernt werden.

**Fix:** Retention pro Session mit einem abbrechbaren Claim beziehungsweise einer Generation koordinieren. Öffnen/Resume muss einen noch nicht abgeschlossenen Claim aufheben; vor Datei-Bewegung und Lösch-Commit aktuelle Berechtigung prüfen. Löschung außerdem an das individuelle Archivierungsergebnis koppeln. Datei-I/O weiterhin außerhalb des Workspace-Locks ausführen; keine aktive oder gerade geschützte Session entfernen.

### LR-AK-013 (A2-13) · : Parallele Tool-Ergebnisse werden in Zusammenfassungen vertauscht

*P2 · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-07  ·  **Alt-ID:** N15

**Beleg:** `WhisperM8/Models/AgentChatTranscript.swift:98-102`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:311-315`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:137-153`, `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:228-235`, `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift:25-32`

**Szenario:** Ein Turn startet erst `swift test`, dann `git commit`; das Commit-Ergebnis kommt vor dem Testergebnis zurück. Die Reader verwerfen tool_use_id beziehungsweise call_id, und der TimelineBuilder hängt jedes Ergebnis FIFO an den ersten offenen Aufruf. Damit bekommt der Test das Commit-Ergebnis und der Commit das Testergebnis. Die als deterministische Fakten an den Summarizer übergebenen Commits und Testergebnisse sind anschließend falsch. Die neue flache Verlaufsansicht selbst korreliert nicht mehr; der verbliebene Schaden liegt konkret in der Summary-Pipeline.

**Fix:** Provider-Call-IDs im gemeinsamen Modell erhalten und Resultate darüber korrelieren. Für Legacy-Events ohne ID nur einen ausdrücklich unsicheren Fallback verwenden und daraus keine gesicherten Test-/Commit-Fakten ableiten. Chronologische Darstellung und Erhalt aller Blöcke beibehalten.

### LR-AK-014 (A2-14) · : Ein nur gestarteter Test wird als bestanden an das Modell gemeldet

*P2 · korrektheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-07

**Beleg:** `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:124-131`, `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift:31-32`, `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift:70-75`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:110-111`

**Szenario:** Ein Chat startet `swift test` und wird vor dem Tool-Ergebnis beendet oder unterbrochen. Der offene Tool-Step hat result=nil und isError=false. Die Evidence-Extraktion prüft das fehlende Ergebnis nicht und setzt passed=true. Im Summary-Prompt steht daraufhin `TEST OK: swift test`, obwohl der Test nicht nachweislich beendet wurde. Zusätzlich reicht ein beliebiges Vorkommen von `npm test`, etwa in `echo 'npm test'`, für denselben Erfolgsbeleg.

**Fix:** Tests nur bei zugeordnetem, finalem Ergebnis mit belegtem Exitstatus als erfolgreich klassifizieren. Unvollständig und unbekannt als eigene Zustände erhalten; Kommandos nicht allein per substring erkennen. Tests für Abbruch vor Ergebnis, laufende asynchrone Kommandos und bloßes Zitieren eines Testbefehls ergänzen.

### LR-AK-015 (A2-15) · : Abgebrochene Verlaufsaufbauten rechnen vollständig weiter

*P2 · performance · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-AC-08

**Beleg:** `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:78-80`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:98-109`, `WhisperM8/Services/AgentChats/TranscriptTextRenderer.swift:67-82`, `WhisperM8/Views/Transcript/TranscriptTextView.swift:34-65`

**Szenario:** Der Nutzer lädt große Verlaufsfenster und wechselt rasch zwischen Chats. SwiftUI cancelt zwar den äußeren .task, dessen Task.detached wird aber nicht mit abgebrochen. Renderer und Attributierungsloop prüfen ebenfalls keine Cancellation. Jeder verworfene Aufbau rendert und attributiert somit den kompletten Inhalt weiter; mehrere solche Aufgaben laufen parallel und halten Transcript, Zeilenarray und Dokument gleichzeitig im Speicher. Die Prüfung nach .value verhindert nur das Anzeigen, nicht CPU- und Speicherkosten.

**Fix:** Den Render-Task explizit bei Cancellation abbrechen und Renderer/Attributierung in begrenzten Abständen kooperativ abbrechen lassen; optional global begrenzte Render-Parallelität. Vollständige Prompts, Antworten und Thinking sowie die einzelne TextKit-Ansicht erhalten. Kosten im Nachlauf messen, nicht pauschal neue Inhaltskürzungen einführen.

### LR-AK-016 (A2-16) · : Dauernde externe Transcript-Writes können die Erkennung endlos verschieben

*P2 · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-05

**Beleg:** `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift:88-90`, `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift:112-126`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:130-136`

**Szenario:** Eine extern gestartete, noch nicht überwachte Session schreibt über Minuten alle zwei bis vier Sekunden relevante JSONL-Änderungen. Jeder FSEvents-Burst cancelt den fünfsekündigen Debounce-Task. requestScan wird während dieses gesamten Zeitraums nie aufgerufen; der Zehnsekunden-Cooldown kann deshalb nicht helfen. Ohne Foreground-Wechsel oder manuelles Aktualisieren bleibt die neue Session bis zu einer ausreichend langen Schreibpause unentdeckt.

**Fix:** Trailing-Debounce um eine maximale Wartezeit oder einen führenden, gedrosselten Trigger ergänzen. Unabhängig von weiterem Streaming muss nach einer begrenzten Zeit ein Scan angefordert werden; Single-Flight und bestehende Cooldowns beibehalten.

## Nicht abgedeckt

- Keine Builds, Tests, App-Starts oder realen Provider-Aufrufe ausgeführt; alle Befunde sind statisch. Insbesondere die Darwin-NSException in A2-04 benötigt eine isolierte Crash-Regression außerhalb des GUI-Prozesses.
- Keine Dateien geschrieben. Die übergeordnete Arbeitsanweisung untersagt Markdown-Berichtsdateien; deshalb wurden weder der angeforderte Rohbericht noch die Lagebild-Karte angelegt und report_path ist leer.
- Die ausdrücklich ausgeklammerten AgentChatsView-/Grid-/Tab-/Sidebar-/Switcher-Views, Views/Workspace, AgentWindowStore, AgentSidebarModelBuilder, WorkspaceSlotOps und Services/AgentChats/Layout wurden nicht geprüft. Aussagen zur tatsächlichen Tab-Wiederherstellung und Layout-Migration bleiben dem Delta-Lauf vorbehalten.
- JarvisBoardStore, AgentControlServer, AgentControlRequestHandler*, Chats-Guards/-AuditLog/-StatusJournal, CLI/Chats*, AgentChatsCLICommand und Resources/claude-plugin wurden nicht geprüft.
- AgentSessionRuntimeWatcher, LoginShellEnvironment, WhisperM8App, AgentSessionDetailView, AgentChatsSettingsPage, AppPreferences und AgentTestSupport wurden nur in den zur Fehlerkettenprüfung benötigten Ausschnitten gelesen; sie sind nicht vollständig auditiert.
- Keine Lastmessungen zu perf.store, Leerlauf-CPU, FSEvents-Stürmen, großen Git-Repositories oder Render-Speicherverbrauch. Die Performance-Aussage A2-15 beschreibt nachweisbare unnötige Arbeit, keine gemessene Budgetüberschreitung.
- Crash-Recovery-Marker wurde vollständig statisch gelesen; Mehrprozess-Start, PID-Reuse, erneuter Absturz während Recovery und Stromausfall-Durabilität wurden nicht praktisch verifiziert.
- Search/** wurde vollständig gelesen. Außerhalb dieser Dateien ergab die Produktionsquellensuche keine Aufrufer der neuen ChatSearchDatabase-/Extractor-/Normalizer-Typen; eine aktive Volltextsuch-Pipeline und deren UI-Verhalten konnten deshalb nicht bestätigt werden.
- AgentSessionStore überschreitet mit 1.604 Zeilen den vorgeschlagenen 1.500-Zeilen-Grenzwert. Nicht als eigener Architekturdefekt gemeldet, weil die reine Dateigröße ohne zusätzliche konkrete Fehlwirkung kein belastbarer Befund ist. Vereinfachung nur unter Erhalt von Lock-, Merge-, Profil- und Persistenzinvarianten planen.

## Gelesene Dateien

75 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/findings-matrix.md`
- `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-findings-matrix.md`
- `WhisperM8/Models/AgentChat.swift`
- `WhisperM8/Models/AgentChatTranscript.swift`
- `WhisperM8/Models/AgentUIState.swift`
- `WhisperM8/Models/AgentGridWorkspace.swift`
- `WhisperM8/Models/WorkspaceLayout.swift`
- `WhisperM8/Models/TranscriptTimeline.swift`
- `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift`
- `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift`
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift`
- `WhisperM8/Services/AgentChats/AgentCrashRecovery.swift`
- `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift`
- `WhisperM8/Services/AgentChats/SubagentJobRetention.swift`
- `WhisperM8/Services/AgentChats/LegacyDataCleanup.swift`
- `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift`
- `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift`
- `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift`
- `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift`
- `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift`
- `WhisperM8/Services/AgentChats/BoundedJSONLReader.swift`
- `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift`
- `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift`
- `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift`
- `WhisperM8/Services/AgentChats/CodexTranscriptLocator.swift`
- `WhisperM8/Services/AgentChats/AgentTranscriptCache.swift`
- `WhisperM8/Services/AgentChats/TranscriptTextRenderer.swift`
- `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift`
- `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift`
- `WhisperM8/Services/AgentChats/AgentTranscriptActivityExtractor.swift`
- `WhisperM8/Services/AgentChats/AgentChatTailExtractor.swift`
- `WhisperM8/Services/AgentChats/AgentSessionActivityStore.swift`
- `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift`
- `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift`
- `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift`
- `WhisperM8/Services/AgentChats/NativeSessionTitle.swift`
- `WhisperM8/Services/AgentChats/AgentProjectPath.swift`
- `WhisperM8/Services/AgentChats/AgentProjectIconResolver.swift`
- `WhisperM8/Services/AgentChats/SubAgentDiscovery.swift`
- `WhisperM8/Services/AgentChats/GitBranchReader.swift`
- `WhisperM8/Services/AgentChats/GitChangesSnapshot.swift`
- `WhisperM8/Services/AgentChats/GitChangesTree.swift`
- `WhisperM8/Services/AgentChats/GitProjectStatus.swift`
- `WhisperM8/Services/AgentChats/ProjectChangesWatcher.swift`
- `WhisperM8/Services/AgentChats/Search/ChatSearchContentExtractor.swift`
- `WhisperM8/Services/AgentChats/Search/ChatSearchDatabase.swift`
- `WhisperM8/Services/AgentChats/Search/ChatSearchModels.swift`
- `WhisperM8/Services/AgentChats/Search/ChatSearchNormalizer.swift`
- `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift`
- `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift`
- `WhisperM8/Services/AgentChats/AccountMoveService.swift`
- `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift`
- `WhisperM8/Views/Transcript/MarkdownBlockParser.swift`
- `WhisperM8/Views/Transcript/ReportEvidenceRows.swift`
- `WhisperM8/Views/Transcript/SessionSummaryCard.swift`
- `WhisperM8/Views/Transcript/TeammateMessageParser.swift`
- `WhisperM8/Views/Transcript/TimelinePulsingDot.swift`
- `WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift`
- `WhisperM8/Views/Transcript/TranscriptHistoryState.swift`
- `WhisperM8/Views/Transcript/TranscriptMarkdownView.swift`
- `WhisperM8/Views/Transcript/TranscriptRenderSupport.swift`
- `WhisperM8/Views/Transcript/TranscriptTextView.swift`
- `WhisperM8/Views/AgentSessionDetailView.swift`
- `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift`
- `WhisperM8/Support/AppPreferences.swift`
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift`
- `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift`
- `WhisperM8/WhisperM8App.swift`
- `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift`
- `Tests/WhisperM8Tests/AgentTranscriptStatusTests.swift`
- `Tests/WhisperM8Tests/AgentTranscriptReaderTests.swift`
- `Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift`
- `Tests/WhisperM8Tests/AgentTestSupport.swift`
