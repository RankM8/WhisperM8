---
status: beschlossen
updated: 2026-10-18
description: Welle W0 des Launch-Readiness-Plans — Sofortfixes: Abstürze, Hänger, CPU. Befunde, Abnahmekriterien, Tests zuerst.
---

# W0 · Sofortfixes: Abstürze, Hänger, CPU

Alle bekannten Wege, auf denen die App abstürzt, still endet oder den Main Thread blockiert, mit kleinen Eingriffen schließen und die CPU-Dauerlast aus dem Bericht 3c beseitigen. Jeder Fix ist klein, lokal und einzeln rückrollbar.

**Umfang:** 19 Befunde · P1 4, P2 10, P3 5 · 3 Launch-Blocker · Aufwand S×17, M×2

## Abnahmekriterien der Welle

- [ ] Kein bekannter Trap mehr auf Eingabedaten: Summary-Range, Proxy-Port, doppelte Mode-IDs, skalare Tool-Payloads – je mit Regressionstest, der vorher abstürzt bzw. rot ist.
- [ ] Datei-Logger nutzt nur noch `write(contentsOf:)` und rotiert; absturzrelevante Logs überleben einen Neustart (Laufzeitprüfung QA-12).
- [ ] „Alle Chats stoppen“ und Cmd+Q blockieren den Main Thread höchstens einmal kurz, nicht linear pro PTY (Test mit Sleeper-Seam).
- [ ] CPU: Vorher/Nachher-Sample unter derselben Last (5 working-Chats, 12 offen). Ziel: Indexer-Thread < 5 % statt Dauer-100 %, Main Thread ohne Dauer-Layout durch Pulse; WindowServer-Anteil sichtbar gesunken. Messwerte im Umsetzungsprotokoll.
- [ ] Zustand bleibt sichtbar: working ist ohne Dauerbewegung weiterhin eindeutig erkennbar ([[kein-hover-only-ui]]).
- [ ] Volle Suite grün, `make dev`, QA durch den User.

## Test-Infrastruktur zuerst

- Sleeper-Seam für `AgentTerminalRegistry.terminateAll` (Testmatrix-Lücke LR-TRM-001).

## Lückenschluss zu Beginn (Kritiker Delta-Lauf)

- Synchrone Prozess-/Disk-Zugriffe in View-Bodies und Event-Monitoren sowie Sidebar mit 1000+ Chats: beim CPU-Paket mitmessen (`scripts/perf-load.sh`) und neue Funde ins Register.

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/agent-laufzeit.md](../../00-scope/oracle/agent-laufzeit.md), [oracle/shared-infra.md](../../00-scope/oracle/shared-infra.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-AK-001 | P1 | ja | S | niedrig | geplant · bestätigt | Ungültige Summary-Ausgabe kann die gesamte App beenden |
| LR-AK-033 | P1 | ja | M | niedrig | geplant · bestätigt | Session-Indexer parst wachsende Transcripts bei jedem Scan neu und läuft per FSEvents in Dauerschleife |
| LR-DIK-003 | P1 | — | S | niedrig | geplant · bestätigt | CLI-Batchausgabe überschreibt vorhandene Dateien ungefragt |
| LR-GPT-003 | P1 | — | S | niedrig | geplant · bestätigt | Hohe konfigurierte Proxyports bringen die gesamte App beim Profilstart zum Absturz |
| LR-TRM-001 | P2 | ja | S | niedrig | geplant · bestätigt | [A3-15] Alle Chats stoppen blockiert den Main Thread linear pro PTY |
| LR-AK-004 | P2 | — | S | niedrig | geplant · teilbestätigt | Skalare Tool-Payloads passieren eine NSException-gefährdete JSON-Serialisierung |
| LR-AK-007 | P2 | — | S | niedrig | geplant · teilbestätigt | Ein großes letztes JSONL-Event macht den gesamten Verlauf unerreichbar |
| LR-AK-008 | P2 | — | S | niedrig | geplant · bestätigt | Eine UTF-8-Schnittkante verhindert dauerhaft den Import einer gültigen Session |
| LR-AU-002 | P2 | — | S | niedrig | geplant · bestätigt | Dauer-Pulse der Status-Punkte halten die Layout-Schleife des ganzen Fensters am Laufen |
| LR-AU-008 | P2 | — | S | niedrig | geplant · unverifiziert | Fenster-Verschieben (isMovable) kann dauerhaft aus bleiben: SidebarResizeHandle und Inspector setzen den Hover beim Verschwinden nicht zurück |
| LR-AU-016 | P2 | — | S | niedrig | geplant · unverifiziert | Pane-Fokus-Routing per Maus hängt am Hover-Flag ohne zustandslosen Gegencheck: ein verlorenes onHover(false) lässt Klicks außerhalb des Grids die Selektion verschieben |
| LR-DIK-020 | P2 | — | S | niedrig | geplant · teilbestätigt | Doppelte Output-Mode-IDs beenden die App weiterhin per Trap |
| LR-GPT-008 | P2 | — | S | niedrig | geplant · bestätigt | Mix-Router parst jeden Request-Body drei- bis viermal vollständig |
| LR-PJ-003 | P2 | — | M | niedrig | geplant · unverifiziert | Plugin-Mod verursacht in jedem WhisperM8-Chat CLI-Kaltstarts und stapelt bei jedem session.start einen weiteren 30-s-Timer |
| LR-AU-003 | P3 | — | S | niedrig | geplant · bestätigt | Ressourcen-Anzeiger forkt alle 10 s und bei jedem Statuswechsel ps über alle Prozesse |
| LR-BR-009 | P3 | — | S | niedrig | geplant · bestätigt | Store-Test verwechselt Scheduler-Verzögerung mit blockierendem Flush |
| LR-SH-013 | P3 | — | S | niedrig | geplant · unverifiziert | Logger.info wird von macOS standardmäßig nicht persistiert; die Absturz-Diagnose-Regel verfehlt ihr Ziel |
| LR-SH-014 | P3 | — | S | niedrig | geplant · unverifiziert | Stall-Monitor ohne App-Nap-Ausnahme kann im Hintergrund falsche main_thread_blocked_ongoing-Fehler melden |
| LR-SH-015 | P3 | — | S | niedrig | geplant · unverifiziert | Debug-Datei-Log wächst ohne Rotation und nutzt das NSException-werfende FileHandle.write |

### LR-AK-001 · Ungültige Summary-Ausgabe kann die gesamte App beenden

*P1 · Launch-Blocker · agent-kern / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:57-58`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:39-40`, `Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:67-70` (Stand `a8e0f35`)

**Fehlerbild:** Das CLI beendet sich erfolgreich, liefert aber etwa `}{`. firstIndex(of: "{") liegt hinter lastIndex(of: "}"). Die anschließende ClosedRange-Konstruktion text[start...end] verletzt eine Swift-Vorbedingung und beendet den App-Prozess statt einen Summary-Fehler zu liefern. Der äußere do/catch fängt diesen Trap nicht.

**Fix:** Fix: start <= end prüfen (oder text[start...].firstIndex(of:"}")-Suche ab start). Ein strukturierter Extractor ist nicht nötig.

*Ursprünglicher Vorschlag:* Vor der Range-Konstruktion start <= end prüfen; besser JSON-Objekte strukturiert und begrenzt extrahieren. Regressionstests für vertauschte Klammern, Preamble und unvollständiges JSON. Fehlerhafte Modellantworten müssen als Fehlerwert enden, niemals als Trap.

**Test zuerst:** AgentSummaryGeneratorTests: XCTAssertNil(AgentSummaryGenerator.parseOutput("}{")) sowie "} text {" und "{ unvollständig"; heute Trap (Testprozess stürzt ab), erwartet nil.

<details><summary>Prüfurteil</summary>

Der Defekt ist real: parseOutput bildet text[start...end] ohne start<=end zu prüfen; bei Ausgabe wie `}{` (letztes `}` vor erstem `{`) trappt die ClosedRange-Vorbedingung auch im Release, kein do/catch fängt das. Der Auslöser ist aber eine ungewöhnliche Modellausgabe (nur wenn ein `}` vor dem ersten `{` steht, nicht bei normalem Prosatext oder JSON), daher P1 statt P0. Auto-Läufe laufen bei jedem Anzeigen eines beendeten Chats, die DoD-Zeile 'kein bekannter Weg, auf dem die App still beendet wird' ist literal verletzt. Der Fix ist S und trivial, deshalb Blocker.

</details>

### LR-AK-033 · Session-Indexer parst wachsende Transcripts bei jedem Scan neu und läuft per FSEvents in Dauerschleife

*P1 · Launch-Blocker · agent-kern / performance · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:60-67`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:149`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:179`, `WhisperM8/Services/AgentChats/NativeSessionTitle.swift:52-53` (Stand `001ce26`)

**Fehlerbild:** Mit aktiven Chats verfehlen wachsende Transcripts den mtime/size-Cache; jeder Scan parst ihren 1-MB-Kopf neu (~2,5 s je Datei, zeichenweise Substring.contains). FSEvents ohne Flag-Auswertung stoßen alle 15 s den nächsten Scan an — ein Kern dauerhaft bei 100 % (Sample: 1958/1976 Samples).

**Fix:** A: Parse-Kern auf Bytes (memmem-Vorfilter, nur Treffer parsen). B: gesättigten Kopf im Cache markieren, bei Wachstum nur lastActivityAt nachziehen. C: FSEvents nur Created/Renamed. D: Cooldown ≥ 3× Scandauer.

**Test zuerst:** ClaudeSessionIndexer-Test: wachsende Datei mit gesättigtem Kopf wird nicht neu geparst (Parse-Zähler), nur lastActivityAt/Größe/mtime ziehen nach; Titel-Semantik (custom > ai > erster Prompt) per bestehender Fixtures unverändert. FSEvent-Monitor-Test: reines Modify auf bekannte Datei löst keinen Scan aus.

### LR-DIK-003 · CLI-Batchausgabe überschreibt vorhandene Dateien ungefragt

*P1 · diktat / datenintegritaet · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/CLI/CLITranscribe.swift:41-44`, `WhisperM8/CLI/CLITranscribe.swift:254-258`, `WhisperM8/CLI/CLIArguments.swift:23-36` (Stand `a8e0f35`)

**Fehlerbild:** Neben meeting.mp3 liegt eine bereits bearbeitete meeting.txt. Bei Transkription mehrerer Eingabedateien bestimmt die CLI automatisch meeting.txt als Ausgabe und ersetzt deren Inhalt ohne Nachfrage oder Force-Option. Auch meeting.wav und meeting.mp3 kollidieren im selben Batch miteinander.

**Fix:** Fix des Finders (Vorab-Prüfung aller Zielpfade, Standard abbrechen, --force zum Überschreiben) ist vernünftig. Bei Wiederholungsläufen darf das nicht den üblichen Re-Run blockieren, daher --force oder --overwrite anbieten.

*Ursprünglicher Vorschlag:* Alle Zielpfade vor dem ersten Schreibzugriff auf Bestandsdateien und gegenseitige Kollisionen prüfen. Standardmäßig abbrechen oder eindeutige Namen verwenden; Überschreiben nur ausdrücklich per Option erlauben. Atomisches Schreiben und unveränderte Quelldateien bleiben Invarianten.

**Test zuerst:** CLITranscriptionTests: emit() (bzw. ein extrahierter Pfad-Planer) mit temporärem Verzeichnis, in dem meeting.mp3, meeting.wav und eine vorhandene meeting.txt liegen, inputs.count == 2; erwartet: Abbruch oder eindeutige Namen vor dem ersten Schreiben, bestehende meeting.txt unverändert. Schlägt heute fehl.

<details><summary>Prüfurteil</summary>

emit() (CLITranscribe.swift:254-258) schreibt bei mehreren Eingaben nach <basename>.<format> neben der Quelle, mit rendered.write(atomically:) ohne Existenz- oder Kollisionsprüfung. Eine vorhandene, handbearbeitete meeting.txt wird also still ersetzt; meeting.mp3 und meeting.wav im selben Aufruf überschreiben sich gegenseitig. Das Ziel-neben-Quelle ist dokumentiertes Verhalten (CLITranscribe.swift:47), die fehlende Kollisionsprüfung nicht. Es ist ein echter, aber enger Datenverlust-Pfad (nur Batch-Modus, nur Erweitert-Feature F-DIK-11, kein Nutzerweg W1–W7), daher P1 statt P0 und kein Launch-Blocker.

</details>

### LR-GPT-003 · Hohe konfigurierte Proxyports bringen die gesamte App beim Profilstart zum Absturz

*P1 · gpt-backend / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:270-275`, `WhisperM8/Support/AppPreferences.swift:273-278`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:727-735`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:748-752` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer trägt beispielsweise 65530 als Port ein und aktiviert anschließend ein angemeldetes Zusatzprofil. Der Preference-Getter akzeptiert den positiven Wert. allocateProfilePort addiert zehn und übergibt 65540 an isPortFree; UInt16(port) löst einen Overflow-Trap aus. Damit endet die gesamte App einschließlich aller normalen Diktate und PTY-Chats.

**Fix:** Fix des Finders ist richtig und klein (UInt16(exactly:), Obergrenze 65535 begrenzen, Eingabe auf 1024...65535 clampen). Auch der Router-/Main-Port ebenso validieren.

*Ursprünglicher Vorschlag:* Ports an UI- und Servicegrenzen validieren; den Profilbereich vor Addition auf 1...65535 begrenzen und UInt16(exactly:) verwenden. Bei erschöpftem Bereich einen verständlichen Fehler liefern, niemals trapen. Grenzwerttests für 65525, 65530, 65535 und Int.max ergänzen.

**Test zuerst:** ClaudeCodeProxyManagerTests: mainPortResolver = { 65530 }, portAvailabilityResolver NICHT überschreiben (Default isPortFree) und ensureRunning(profile:) bzw. allocateProfilePort aufrufen; erwartet Failure statt Trap. Zusätzlich direkt ClaudeCodeProxyManager.isPortFree(65536), (Int.max) -> false. Heute: Prozessabbruch.

<details><summary>Prüfurteil</summary>

Der Overflow ist real: AppPreferences.claudeGPTBackendPort akzeptiert jeden Wert > 0 (AppPreferences.swift:273-278), das Textfeld validiert nichts (GPTBackendSettingsPage:271), allocateProfilePort addiert +10 und isPortFree ruft UInt16(port) (ClaudeCodeProxyManager.swift:727-752) - bei Port >= 65526 ergibt sich >= 65536 und die App trappt. Auslöser ist aber, dass ein Nutzer bewusst einen Port nahe 65535 einträgt (Standard 18765) und zusätzlich GPT-Backend plus angemeldetes Zusatzprofil aktiviert; Labs, Default aus. Absturz ist grundsätzlich P0-Klasse, die Erreichbarkeit rechtfertigt aber nur P2; Fix ist trivial.

</details>

### LR-TRM-001 · [A3-15] Alle Chats stoppen blockiert den Main Thread linear pro PTY

*P2 · Launch-Blocker · terminal / performance · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentTerminalView.swift:350-351`, `WhisperM8/Views/AgentTerminalView.swift:432-436`, `WhisperM8/Views/AgentTerminalView.swift:914-924`, `WhisperM8/Models/AppState.swift:137-150` (Stand `a8e0f35`)

**Fehlerbild:** Bei zehn laufenden Vordergrundchats ruft terminateAll zehnmal den Einzelstopp mit 80 ms plus 180 ms usleep auf dem MainActor auf. Schon die festen Pausen blockieren die App mindestens 2,6 Sekunden; bei zwanzig Chats 5,2 Sekunden, zusätzlich zu Flush/Teardown. Das verletzt W5 unabhängig von einer Performance-Messung.

**Fix:** terminateAll auf den bereits vorhandenen gemeinsamen terminate(sessionIDs:)-Pfad umstellen; längerfristig Grace-Wartezeiten suspendierend statt per usleep abwickeln. Zwei Interrupts, FIFO-Flush, Prozess-Reaping und Rückgabe aller gestoppten IDs erhalten.

**Test zuerst:** In AgentTerminalController/Registry den Schlaf als Closure injizieren (sleep: (useconds_t) -> Void, Spy in AgentTestSupport.swift). Mit 5 laufenden Fake-Controllern terminateAll() aufrufen. Erwartung: sleep wird genau zweimal aufgerufen (80 ms + 180 ms). Heute sind es zehn Aufrufe.

### LR-AK-004 · Skalare Tool-Payloads passieren eine NSException-gefährdete JSON-Serialisierung

*P2 · agent-kern / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:349-352`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:374-381`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:155-160`, `WhisperM8/Services/AgentChats/Search/ChatSearchContentExtractor.swift:206-213` (Stand `a8e0f35`)

**Fehlerbild:** Eine syntaktisch gültige Transcript-Zeile enthält einen Tool-Aufruf mit `input: 1`, `input: true` oder `input: null`. formatToolInput übergibt diesen skalaren Top-Level-Wert an JSONSerialization.data ohne fragmentsAllowed oder isValidJSONObject-Prüfung. Auf Darwin ist dies ein NSInvalidArgumentException-Pfad; try? schützt nicht gegen NSException. Entsprechendes gilt für skalare Codex-tool_search_call-arguments. Der Such-Extractor hat die notwendige Gültigkeitsprüfung bereits, der Anzeige-Reader nicht.

**Fix:** isValidJSONObject-Guard (wie im Extractor) reicht; fragmentsAllowed ist nicht nötig.

*Ursprünglicher Vorschlag:* Vor JSONSerialization.data isValidJSONObject prüfen oder bewusst fragmentsAllowed verwenden; unerwartete Payloads als ungefährlichen Klartext beziehungsweise Parse-Fehler behandeln. Den Reader gegen alle JSON-Wertarten testen. Ein defektes externes Transcript darf niemals den GUI-Prozess beenden.

**Test zuerst:** ClaudeTranscriptReader.parseEntry mit tool_use input 1, true, null, "x" und Array; CodexTranscriptReader mit tool_search_call arguments 1. Erwartung: kein Crash, input als String. Heute ObjC-Exception-Abbruch des Testprozesses.

<details><summary>Prüfurteil</summary>

API-Vertrag stimmt: JSONSerialization.data(withJSONObject:) mit skalarem Top-Level wirft unter Darwin eine NSException, try? fängt sie nicht; der Search-Extractor prüft isValidJSONObject, die Display-Reader nicht. Der Auslöser ist aber ein malformierter Transcript: Claude-tool_use.input ist laut API immer ein Objekt, und die echte Codex-Fixture hat arguments als Dictionary. Ein skalarer Wert kommt aus keinem bekannten Erzeuger. Bei manuell beschädigten oder künftig geänderten Dateien wäre der Absturz aber deterministisch bei jedem Öffnen.

</details>

### LR-AK-007 · Ein großes letztes JSONL-Event macht den gesamten Verlauf unerreichbar

*P2 · agent-kern / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:418-432`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:255-267`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:79-91`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:44-59` (Stand `a8e0f35`)

**Fehlerbild:** Ein bestehender Chat endet nach einem Abbruch mit einem Tool-Ergebnis oder Bild-Event, dessen einzelne JSONL-Zeile größer als das anfängliche Tail-Fenster ist. Der Tail enthält nur den angeschnittenen Rest dieser Zeile; der Reader entfernt ihn und liefert messages=[] bei hasTruncatedHead=true. Der Container wählt jedoch ausschließlich den Empty-State und baut historyStrip nicht. Der Nutzer sieht eine angeblich leere Konversation und hat keinen Nachlade-Button, obwohl davor lesbare Nachrichten existieren.

**Fix:** Einfachster Fix: im Container den Nachladen-Pfad auch bei leerem, aber kopfgekürztem Transcript zeigen; kein unbeschränkter Rückwärts-Read.

*Ursprünglicher Vorschlag:* Nachladen auch bei leerem, aber kopfgekürztem Transcript anbieten. Alternativ den Reader begrenzt rückwärts bis zu vorherigen vollständigen Events suchen lassen. Das Speicherbudget erhalten; keinen unbeschränkten Voll-Read als Ausweichlösung einführen.

**Test zuerst:** TranscriptTailReader/ClaudeTranscriptReader: Datei = kleine gültige Zeilen + zuletzt eine Zeile > tailBytes; readTail muss entweder frühere Zeilen liefern oder (messages leer, hasTruncatedHead true) so markiert sein, dass der Container den Nachladen-Button zeigt (ViewInspector/Logiktest auf showsHistorySection).

<details><summary>Prüfurteil</summary>

Logik stimmt: TranscriptTailReader verwirft die angeschnittene erste Zeile; ist die letzte JSONL-Zeile größer als das 512-KiB-Fenster (AgentSessionDetailView.initialTailBytes), bleibt messages=[] bei hasTruncatedHead=true, der Container nimmt dann nur den Empty-State ohne Nachladen-Button. Voraussetzung ist, dass die Datei genau mit einer >512 KiB großen Zeile endet (z. B. Bild-/Riesen-Tool-Result direkt vor Abbruch); normalerweise folgt eine Assistant-Zeile. Seltener Randfall, aber ohne Ausweg für den Nutzer, und nur die Verlaufsansicht, kein Datenverlust.

</details>

### LR-AK-008 · Eine UTF-8-Schnittkante verhindert dauerhaft den Import einer gültigen Session

*P2 · agent-kern / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/BoundedJSONLReader.swift:19-27`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:149-150`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:124-131`, `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:60-67` (Stand `a8e0f35`)

**Fehlerbild:** Ein gültiges Claude-Transcript ist größer als 1 MiB und Byte 1.048.576 liegt mitten in einem UTF-8-Zeichen, etwa einem Umlaut oder Emoji. Obwohl die ersten vollständigen Zeilen Session-ID, cwd und Prompt enthalten, scheitert String(data:encoding:) für den gesamten Prefix. Der Indexer verwirft die ganze Datei und cached nil mit Größe und mtime. Solange die beendete Datei unverändert bleibt, repariert auch ein erneuter Scan den fehlenden Import nicht.

**Fix:** Prefix an der letzten vollständigen Zeilengrenze (letztes 0x0A) kürzen, oder String(decoding:) pro Zeile verwenden.

*Ursprünglicher Vorschlag:* Prefix zuerst an vollständigen Zeilengrenzen schneiden und die einzelnen Zeilen unabhängig dekodieren; unvollständige Schlussbytes dürfen vorherige gültige Zeilen nicht verwerfen. Flüchtige Lesefehler nicht wie sicher irrelevante Dateien dauerhaft negativ cachen. Grenztests mit mehrbyteigen Zeichen exakt am Leselimit ergänzen.

**Test zuerst:** BoundedJSONLReaderTests: Datei >1 MiB, bei der Byte 1.048.576 mitten in einem 'ä' oder Emoji liegt; lines(from:maxLines:maxBytes:) muss die vollständigen Zeilen davor liefern (heute nil). Zusätzlich ClaudeSessionIndexer-Test: Session wird importiert.

<details><summary>Prüfurteil</summary>

BoundedJSONLReader.lines liest exakt 1 MiB und dekodiert den ganzen Prefix mit String(data:encoding:.utf8), das bei einem abgeschnittenen Multibyte-Zeichen nil liefert; parseSessionFile gibt nil zurück und der Indexer cached nil für Größe+mtime. Eine beendete Datei bleibt so dauerhaft ungescannt. Betroffen sind externe, nicht in WhisperM8 gestartete Sessions >1 MiB mit Zeichen genau an der Grenze (einige Prozent der großen Dateien, bei Umlauten/Emoji); in der App gestartete Sessions sind im Workspace und unberührt. Fehlender Import externer Chats, kein Datenverlust.

</details>

### LR-AU-002 · Dauer-Pulse der Status-Punkte halten die Layout-Schleife des ganzen Fensters am Laufen

*P2 · agent-ui / performance · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentStatusIndicator.swift:59-62`, `WhisperM8/Views/AgentChatChromeViews.swift:565`, `WhisperM8/Views/AgentChatsView+Grid.swift:902`, `WhisperM8/Views/AgentChatsSidebarViews.swift:630` (Stand `001ce26`)

**Fehlerbild:** Jeder arbeitende Chat startet repeatForever-Pulse (Sidebar, seit e8e8d12 auch Kachelkopf) bzw. eine 30-fps-TimelineView (SubagentRoad); jeder Frame gleicht die Display-List des ganzen Fensters ab (~640 Samples Layout/Render, 714 CA-Commit), der WindowServer komponiert mit (~50 %). Gegenprobe per Schalter steht aus.

**Fix:** A/B-Messung mit Schalter; Puls statisch bzw. einmalig beim Wechsel, Kachelkopf/Tab ohne Puls; SubagentRoad langsamer; Animationen nur im sichtbaren Fenster.

**Test zuerst:** Messung zuerst (Schalter „Pulse aus“, sample/Instruments vorher/nachher). Danach Snapshot-Fixture: working-Status statisch sichtbar; Guard-Test, dass in Kachelkopf und Tab kein repeatForever mehr steht.

### LR-AU-008 · Fenster-Verschieben (isMovable) kann dauerhaft aus bleiben: SidebarResizeHandle und Inspector setzen den Hover beim Verschwinden nicht zurück

*P2 · agent-ui / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/SidebarResizeHandle.swift:36-40 (onHover meldet onHoverChanged)`, `WhisperM8/Views/SidebarResizeHandle.swift:57-61 (onDisappear setzt nur den Cursor zurück, ruft onHoverChanged(false) nicht)`, `WhisperM8/Views/AgentChatsView.swift:749 und 777 (onHoverChanged → hostWindow?.isMovable = !hovering)`, `WhisperM8/Views/AgentChatsView.swift:1095-1100 und 2901 (Tab-Strip: isHoveringTabStrip → isMovable)` (Stand `76256ad`)

**Fehlerbild:** Maus steht über dem Sidebar-Resize-Rand oder einem Tab. Der Nutzer blendet per Tastenkürzel Sidebar oder Inspector aus, öffnet ein Kontextmenü oder wechselt per Cmd+Tab. onHover(false) kommt nie an, window.isMovable bleibt false. Das Fenster lässt sich über das Titelband nicht mehr verschieben, bis die Maus zufällig wieder über die Leiste oder den Rand fährt und sie verlässt. Für Laien wirkt das wie ein hängendes Fenster. Wahrscheinlichkeit gering (der Vorfall 23.08. betraf dasselbe Flag-Muster), Wirkung begrenzt.

**Fix:** isMovable zustandslos setzen. Im vorhandenen leftMouseDown-Monitor (installTitleBarZoomHandlerIfNeeded) vor jedem Mausklick isMovable = !(isPointerInTabStripBand(event) // Zeiger über Resize-Handle) berechnen. Zusätzlich in SidebarResizeHandle.onDisappear und im onResignKey-Callback hostWindow.isMovable = true setzen.

**Test zuerst:** Manuelle QA: Zeiger auf Resize-Rand, Sidebar per Shortcut ausblenden, danach Fenster am Titelband ziehen.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-016 · Pane-Fokus-Routing per Maus hängt am Hover-Flag ohne zustandslosen Gegencheck: ein verlorenes onHover(false) lässt Klicks außerhalb des Grids die Selektion verschieben

*P2 · agent-ui / race · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView+Grid.swift:866-872 (onHover setzt/räumt hoveredGridPaneID)`, `WhisperM8/Views/AgentChatsView+Grid.swift:1052-1078 (handleGridPaneMouseDown: selectedSessionID = hovered bei JEDEM Linksklick im Fenster, kein Abgleich mit der Klickposition)`, `WhisperM8/Views/AgentChatsView+Shortcuts.swift:548-556 (leftMouseDown-Monitor)`, `WhisperM8/Views/AgentChatsView+Grid.swift:1063-1072 (Selbstheilung nur für hoveredNoteCardID, und die vergleicht gegen genau dieses Flag)` (Stand `76256ad`)

**Fehlerbild:** Maus steht über nicht fokussierter Pane X, ein Kontextmenü am Pane-Header, ein Drag oder ein Cmd+Tab verschluckt das onHover(false), das Flag bleibt auf X. Der User klickt danach in das Suchfeld der Sidebar oder auf einen Header-Button: der Monitor setzt zuerst selectedSessionID = X, der onChange ruft X.focusTerminal() und das Terminal reißt den Tastaturfokus aus dem Suchfeld. Folge: Tippen landet im Chat X. Nicht reproduziert, die Lücke ist aus dem Code und dem Vorfall abgeleitet.

**Fix:** Das Flag nicht allein vertrauen: im Monitor per Pane-Rechtecke (onGeometryChange in einen nicht beobachteten Dictionary-Cache) oder per hostWindow.contentView?.hitTest(event.locationInWindow) prüfen, dass der Klick wirklich in der Hover-Pane liegt (zustandslos wie isPointerInTabStripBand). Optional zusätzlich das Flag bei NSWindow.didResignKey/didBecomeKey und bei Drag-Ende räumen.

**Test zuerst:** Pure Funktion `GridPaneHitResolver.pane(at:frames:)` testen. Manuell: Header-Kontextmenü öffnen, schließen, Sidebar-Suchfeld anklicken, Fokus darf nicht in den Terminal springen.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-DIK-020 · Doppelte Output-Mode-IDs beenden die App weiterhin per Trap

*P2 · diktat / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Dictation/OutputModeStore.swift:162`, `WhisperM8/Services/Dictation/OutputModeStore.swift:64-69` (Stand `a8e0f35`)

**Fehlerbild:** OutputModes.json enthält zwei ansonsten gültige Einträge mit derselben nicht stillgelegten ID. Das Laden erreicht Dictionary(uniqueKeysWithValues:); dessen Vorbedingung beendet den Prozess statt eines abfangbaren Decode-Fehlers.

**Fix:** Vor der Dictionary-Konstruktion deterministisch deduplizieren, Originaldatei sichern und beschädigte Einträge sichtbar melden. Built-in-Reihenfolge, benutzerdefinierte Anpassungen und Migration stillgelegter Modi erhalten; Regressionstest mit doppelter Custom- und Built-in-ID ergänzen.

**Test zuerst:** OutputModeStoreTests mit temporärer Datei: JSON mit zwei Einträgen derselben Custom-ID und zwei mit derselben Built-in-ID schreiben. Erwartet: store.modes liefert deterministisch dedupliziert ohne Crash, und die Built-in-Reihenfolge bleibt erhalten. Heute beendet der Test den Prozess per Precondition.

<details><summary>Prüfurteil</summary>

Der Trap ist real: normalized() baut Dictionary(uniqueKeysWithValues:) über die geladenen Modi (OutputModeStore:162), und doppelte IDs lösen eine Precondition aus. Die App selbst erzeugt aber keine doppelten IDs: Custom-Modi haben UUID-IDs (createCustomMode), saveModes läuft ebenfalls durch normalized, und die Datei wird atomar geschrieben. Auslösen kann das nur eine handbearbeitete, synchronisierte oder fremd zusammengeführte OutputModes.json. Das ist ein unplausibler Auslöser für die Zielgruppe. Die Auswirkung wäre allerdings ein Crash-Loop bei jedem Start, deshalb liegt die Schwere über P3. P0 ist nicht haltbar, weil kein realistischer Auslöser existiert. Billiger Fix, deshalb unbedingt mitnehmen.

</details>

### LR-GPT-008 · Mix-Router parst jeden Request-Body drei- bis viermal vollständig

*P2 · gpt-backend / performance · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:391-405`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:440`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:873-892`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:999` (Stand `001ce26`)

**Fehlerbild:** Bei GPT-Backend-Chats mit mehreren MB Kontext parst forward() den Body für resolvingAutoModel, model(in:) und upstream(for:) je neu (gpt-* zusätzlich Sanitizer), plus volle Kopien und allHeaderFields je Response — ~2100 Samples Parse auf drei Threads.

**Fix:** model einmal per Byte-Scan (Fallback Parse); Sanitizer nur bei Treffer; Kopien vermeiden; gezielte Header-Lookups.

**Test zuerst:** ClaudeGPTMixRouterTests: Byte-Scan liefert dasselbe model wie der volle Parse für alle bestehenden Fixtures; Body ohne Treffer wird genau einmal geparst (Zähler).

### LR-PJ-003 · Plugin-Mod verursacht in jedem WhisperM8-Chat CLI-Kaltstarts und stapelt bei jedem session.start einen weiteren 30-s-Timer

*P2 · plugin-jarvis / performance · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Resources/claude-plugin/hooks/register.tsx:436-460`, `WhisperM8/CLI/ChatsBoardCommand.swift:309-337`, `WhisperM8/CLI/ChatsWorkspaceReader.swift:49-67`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:96-99` (Stand `76256ad`)

**Fehlerbild:** (a) session.start wartet vor `return started` auf refresh() und damit auf einen `whisperm8 chats board --json`-Prozess. Er startet das ganze App-Binary im CLI-Modus und laedt per ChatsCommandContext.load() den kompletten Workspace von Disk, auch wenn kein Board existiert. Bei 5500 Sessions ist das mehrere MB JSON je Chatstart. Nach App-Neustart oder Crash-Recovery mit 20 Chats starten 20 solche Prozesse gleichzeitig. Dazu laeuft pro Prompt der Send-Guard-Hook `whisperm8 chats _prompt-guard` als eigener Kaltstart des Binarys. (b) Jedes session.start (Start, Resume, /clear, Compact) registriert ueber $.clock.every einen weiteren 30-s-Intervall, der nie beendet wird. Nach mehreren /clear laufen mehrere Timer je Chat, jeder loest ein Atom-Update und Re-Render aus. Messwerte fehlen, die Einschaetzung ist statisch.

**Fix:** In der Mod das Board-Lesen erst bei Bedarf starten (nach dem ersten Weck-Ereignis oder wenn Jarvis aktiviert wird) und nicht awaiten. In `chats board` bei @self und fehlender Boarddatei den Workspace-Load ueberspringen. Das Timer-Handle merken und vor einer erneuten Registrierung beenden oder die Registrierung per Flag auf einmal je Session beschraenken. Kaltstartzeit des Hooks messen.

**Test zuerst:** Mod-Test: zweimal session.start registriert genau einen Intervall. CLI-Test: `chats board --json` ohne Boarddatei liest die Workspace-Datei nicht.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-003 · Ressourcen-Anzeiger forkt alle 10 s und bei jedem Statuswechsel ps über alle Prozesse

*P3 · agent-ui / performance · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentResourceMonitor.swift:150`, `WhisperM8/Views/AgentResourceSummaryButton.swift:55-75` (Stand `001ce26`)

**Fehlerbild:** Auf ausgelasteten Macs kostet der ps -ax-Fork je Tick spürbar Systemlast; onChange(descriptors) löst zusätzliche Forks bei jedem Status-/Titelwechsel aus.

**Fix:** ps -p <Chat-PIDs> + Kinder, onChange entprellen, Badge-Takt 30 s; später proc_listchildpids/proc_pidinfo ohne Fork.

**Test zuerst:** AgentResourceMonitor-Test mit Process-Runner-Spy: ps nur mit -p der Chat-PIDs, Statuswechsel innerhalb des Entprellfensters lösen keinen zusätzlichen Aufruf aus.

### LR-BR-009 · Store-Test verwechselt Scheduler-Verzögerung mit blockierendem Flush

*P3 · build-release / infra · Aufwand S · Risiko niedrig*

**Beleg:** `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift:306-337`, `Tests/WhisperM8Tests/TestTiming.swift:4-16` (Stand `a8e0f35`)

**Fehlerbild:** Der Testprozess wird zwischen Date()-Start und der Messung nach store.flush() auf einem belasteten Runner länger als 100 ms nicht eingeplant. Obwohl flush nicht auf Persistenz wartet, schlägt XCTAssertLessThan(..., 0.1) fehl. Der vorhandene TestTiming-Kommentar dokumentiert genau dieses Problem der Wandzeitmessung unter paralleler Last; dieser Test verwendet weiterhin die empfindliche Wandzeitgrenze.

**Fix:** Die Nichtblockierung über ein kontrolliertes Synchronisationsprotokoll prüfen: Persistenz bleibt gesperrt, während die Rückkehr von flush unabhängig bestätigt wird. Einen großzügigen Deadlock-Timeout verwenden, nicht ein 100-ms-Performance-Budget. Thread-CPU-Zeit allein wäre hier kein Ersatz, weil sie blockierendes Warten ebenfalls nicht misst.

**Test zuerst:** Kein neuer Produkttest. Die Wandzeit-Assertion in testFlushReturnsWithoutWaitingForPersistAndWritesAsynchronously streichen, alternativ auf ≥ 1,0 s anheben, deutlich unter dem 2-s-Semaphor-Timeout. Die Aussage trägt dann allein die Reihenfolge persistStarted → saveCount == 0 → signal.

### LR-SH-013 · Logger.info wird von macOS standardmäßig nicht persistiert; die Absturz-Diagnose-Regel verfehlt ihr Ziel

*P3 · shared / infra · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/Logger.swift:44-58`, `WhisperM8/Services/Dictation/AudioRecorder.swift:161`, `WhisperM8/Services/Dictation/AudioRecorder.swift:352`, `WhisperM8/Info.plist (kein OSLogPreferences-Eintrag)` (Stand `a8e0f35`)

**Fehlerbild:** CLAUDE.md und der Kommentar in Logger.info gehen davon aus, dass .info im persistenten Log-Store landet. Laut Apples Unified-Logging-Modell werden Info-Meldungen ohne Konfigurationsprofil nur im Speicher gehalten und nur bei log collect bzw. nach Fault-Ereignissen gesichert. Nach einem Absturz oder Neustart fehlen genau die Audio-Zeilen, die den Absturz erklären sollten (Tap-Fehler, Formatwechsel); 120 .info-Aufrufe sind betroffen. Für den Nutzer folgenlos, für die Fehleranalyse nach dem Launch aber eine Lücke.

**Fix:** Absturzrelevante Ereignisse auf .notice/.error heben oder per OSLogPreferences im Info.plist die Persistenz für das Subsystem auf Info setzen; danach CLAUDE.md-Regel korrigieren.

**Test zuerst:** InfoPlistContractTests: OSLogPreferences für com.whisperm8.app setzt Persist auf Info – oder Guard-Test, dass absturzrelevante Logs .notice nutzen; CLAUDE.md-Regel angepasst.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-SH-014 · Stall-Monitor ohne App-Nap-Ausnahme kann im Hintergrund falsche main_thread_blocked_ongoing-Fehler melden

*P3 · shared / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/MainThreadStallMonitor.swift:86-99`, `WhisperM8/Services/Shared/StallWatchdog.swift:29`, `WhisperM8/Services/Shared/StallWatchdog.swift:95-102`, `WhisperM8/Info.plist (kein NSAppSleepDisabled, kein beginActivity im Code)` (Stand `a8e0f35`)

**Fehlerbild:** Der 100-ms-Timer läuft dauerhaft und ohne Toleranz, der Watchdog meldet ab 1 s fehlenden Herzschlag auf Error-Level. Ist die App lange ohne sichtbares Fenster im Hintergrund, darf macOS sie per App Nap drosseln und Timer stark zusammenfassen. Verzögert sich der Main-Timer dadurch über 1 s, entstehen Fehlalarme, die die DoD-Messung (kein main_thread_blocked_ongoing) und spätere Analysen verfälschen; zugleich verhindern 10 Wakeups/s Energiesparen.

**Fix:** Timer mit Toleranz versehen und Herzschlag-Alter nur werten, wenn die App nicht von App Nap gedrosselt ist (NSApplication.occlusionState/aktive Fenster), oder Monitor nur bei sichtbaren Fenstern bzw. Detail-Stufe laufen lassen.

**Test zuerst:** StallWatchdogTests: bei gemeldetem App-Nap-/Occlusion-Zustand wird kein main_thread_blocked_ongoing ausgelöst; im sichtbaren Zustand weiterhin schon.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-SH-015 · Debug-Datei-Log wächst ohne Rotation und nutzt das NSException-werfende FileHandle.write

*P3 · shared / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/Logger.swift:60-90`, `WhisperM8/Support/AppPreferences.swift:79-82` (Stand `a8e0f35`)

**Fehlerbild:** Ein Nutzer schaltet auf Bitte des Supports debugFileLoggingEnabled ein und vergisst es. Logger.debug wird an rund 150 Stellen aufgerufen, die Datei unter ~/Library/Logs/WhisperM8 wächst unbegrenzt. Läuft die Platte voll, wirft handle.write(_:) bei ENOSPC eine NSFileHandleOperationException, die Swift nicht fängt, und die App beendet sich samt aller Chats. Das widerspricht der eigenen Regel, nur write(contentsOf:) zu nutzen. Nur per defaults write auslösbar, daher P3.

**Fix:** write(contentsOf:) mit try? verwenden, Größenlimit mit einfacher Rotation (z. B. 10 MB, eine Vorversion) einführen.

**Test zuerst:** LoggerFileSinkTests: Datei über Limit wird rotiert (eine Vorversion), Schreiben auf ein schreibgeschütztes Ziel wirft keine NSException; Guard-Test gegen `FileHandle.write(_:)` im Logger.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.
