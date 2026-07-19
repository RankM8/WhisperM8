---
status: aktiv
updated: 2026-07-19
description: Runde-4-Abdeckungssweep der bisher ungeprüften Agent-Chats-relevanten Service-Dateien mit Tiefenangabe, Risikourteil und verifizierten Findings.
---

# Runde 4: Abdeckungssweep Services

## 0. Auftrag, Scope und Methodik

Diese Prüfung schließt die in der Runde-3-Vollständigkeitskritik mechanisch ausgewiesenen Finder-Lücken unter `WhisperM8/Services/AgentChats` und `WhisperM8/Services/Shared`; aus `Services/Dictation` werden nur Agent-Chats-relevante Codex-/Projektpfade einbezogen. Dateien aus dem Feature-Zuwachs `e8b7661..HEAD`, die in Runde 4 bereits als neue Feature-Dateien separat auditiert werden, sind hier ausgeschlossen.

**Tiefenskala:**

- **oberflächlich:** `rg`-gestützter Struktur-, Fehlerpfad-, Secret-, Prozess- und Force-Unwrap-Sweep; einzelne relevante Abschnitte gelesen.
- **gezielt:** alle risikotragenden Funktionen und ihre unmittelbaren Aufrufer/Tests abschnittsweise gelesen.
- **vertieft:** Zustands-/Lifecycle-Pfad über mehrere Funktionen/Dateien und vorhandene Tests nachvollzogen.

Keine Builds oder Tests wurden ausgeführt. Testaussagen beruhen ausschließlich auf gelesenen Testquellen. Zeilenangaben beziehen sich auf `HEAD` am 2026-07-19.

## 1. Scope-Abgrenzung

Die Runde-3-Liste enthält 19 AgentChats-, 9 Shared- und 14 Dictation-Dateien. Ein dateispezifischer Abgleich mit `git diff --name-status e8b7661..HEAD -- WhisperM8/Services` und den parallelen Runde-4-Berichten ergab zwei Ausschlüsse: `StatuslineInstaller.swift` ist eine im Zuwachs neu angelegte Feature-Datei und wird in `runde4-statusline-skills.md` auditiert; die im Delta erweiterte `AgentChatLaunchService.swift` wird bereits in `runde4-chats-cli.md` einschließlich Control-Launch-Pfad geprüft. Aus Dictation sind `CodexErrorSummary.swift`, `CodexStatusCache.swift` und `ProjectPathResolver.swift` unmittelbar für Codex-/Agent-Chat-Pfade relevant; reine Audio-, Transkriptions- und Attachment-Dateien bleiben draußen. Damit umfasst dieser Bericht **29 Dateien**.

## 2. Verifizierte Findings

### R4-AS-01 — hoch — Theme-Sync kann parallele Claude-Settings-Änderungen dauerhaft verlieren

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:15-18,108-119,126-153`; fehlende I/O-/Konkurrenztests: `Tests/WhisperM8Tests/ThemeManagerTests.swift:66-67`.

**Auslöseszenario:** WhisperM8 liest `~/.claude/settings.json`; danach schreibt Claude Code parallel etwa einen Hook-, Permission- oder Plugin-Key; anschließend ersetzt WhisperM8 die komplette Datei mit seinem aus dem älteren Snapshot serialisierten Objekt. Das atomare `replaceItemAt` verhindert nur eine partiell geschriebene Zieldatei, aber keinen Read-modify-write-Lost-Update. Der fremde Key verschwindet dauerhaft, obwohl der Code gerade wegen bekannter paralleler Writer antritt.

**Fix-Skizze:** Vor dem Replace Dateidentität plus Inhalts-Hash des gelesenen Snapshots erneut prüfen; bei Abweichung neu lesen, nur `theme` mergen und begrenzt wiederholen. Wenn möglich den Schreibpfad über eine von Claude unterstützte Settings-Operation serialisieren; mindestens nach dem Replace re-read/verify und Konflikte sichtbar melden. Tests müssen einen externen Write zwischen Read und Replace injizieren.

### R4-AS-02 — mittel — Usage-Cache benutzt den falschen Temp-Namespace und vertraut einen Shared-`/tmp`-Pfad

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift:23-26,68-83`; der eigentliche Statusline-Produzent verwendet absichtlich den privaten Temp-Ordner: `WhisperM8/Resources/whisperm8-statusline.sh:98-105,160-162`; Tests prüfen nur Parser: `Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:377-401,420-435`.

**Auslöseszenario:** Auf macOS schreibt die Statusline nach `$TMPDIR/claude-usage-cache-<profil>.json`, der Swift-Fallback liest und schreibt dagegen `/tmp/claude-usage-cache-<profil>.json`. Nach einem Live-Fetch-Fehler findet die App den von der Statusline gepflegten Cache nicht und zeigt keine bzw. veraltete Limits. Zusätzlich kann ein anderer lokaler Benutzer vorab den vorhersagbaren `/tmp`-Pfad belegen; `cachedUsage` prüft weder Eigentümer noch Dateityp und übernimmt dessen JSON als Usage-Wahrheit.

**Fix-Skizze:** Eine gemeinsame Pfadfunktion auf Basis von `FileManager.default.temporaryDirectory` verwenden, Profilnamen weiterhin validieren, Cache atomar mit restriktiven Rechten schreiben und beim Lesen reguläre Datei/Eigentümer prüfen. End-to-end-Test: Statusline-kompatibler Temp-Pfad, Live-Fehler und Cache-Fallback; separater Test für fremde/unzulässige Cache-Datei.

### R4-AS-03 — hoch — Git-Worktree-Subprozess kann vor dem Pipe-Read unbegrenzt blockieren

**Beleg:** `WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:52-64,72-87`; Tests injizieren überwiegend `gitRunner` und der Real-Git-Test erzeugt nur ein Kleinstrepo: `Tests/WhisperM8Tests/AgentWorktreeManagerTests.swift:8-39,54-83`.

**Auslöseszenario:** `runGit` ruft `waitUntilExit()` auf, bevor stdout und stderr geleert werden. Bei `agent rm` führt `isClean` ein `git status --porcelain` aus; enthält ein großes Worktree tausende geänderte/untracked Dateien, überschreitet dessen stdout den Pipe-Puffer. Git blockiert beim Schreiben, während der Parent auf Exit wartet. Der Remove-Befehl hängt dann ohne Timeout dauerhaft und erreicht weder Dirty-Warnung noch Cleanup. `git worktree add` kann dieselbe Klasse über große Progress-/Fehlerausgabe auf stderr treffen.

**Fix-Skizze:** Beide Pipes während der Prozesslaufzeit parallel drainieren (Readability-Handler oder getrennte Tasks), erst danach auf Exit warten; begrenzte Ausgabe und Timeout/Terminate-Eskalation ergänzen. Ein Test-Helper muss >Pipe-Puffer gleichzeitig auf stderr/stdout schreiben und terminieren.

### R4-AS-04 — mittel — Ein verspätetes vnode-Event kann eine neu gestartete File-Source wieder stoppen

**Beleg:** `WhisperM8/Services/Shared/FileEventSource.swift:38-59,63-67`; Tests decken Write, Delete und Open-Fehler ab, aber kein Stop→Start mit altem queued Event: `Tests/WhisperM8Tests/AgentSessionEventWatchTests.swift:16-56`.

**Auslöseszenario:** `stop()` cancelt die alte DispatchSource und setzt `source = nil`; ein sofortiges `start()` installiert eine neue Source. Ein bereits auf der Main Queue liegendes Delete/Rename-Event der alten Source führt später `self.stop()` aus und cancelt damit die **neue** Source, weil der Handler nicht prüft, ob er noch zur aktuell gespeicherten Generation gehört. Der Runtime-Watcher verliert danach Events, obwohl `start()` erfolgreich war.

**Fix-Skizze:** Pro Start eine Generation bzw. Source-Identität erfassen und im Handler vor jedem Callback `guard generation == currentGeneration` prüfen; `stop()` invalidiert die Generation. Deterministischer Test mit injizierbarer Source/Queue und verspäteter Alt-Callback-Ausführung nach Re-Arm.

### R4-AS-05 — mittel — `invalidate()` kann von einem laufenden Codex-Status-Probe rückgängig gemacht werden

**Beleg:** `WhisperM8/Services/Dictation/CodexStatusCache.swift:34-60`; vorhandene Tests sind strikt seriell: `Tests/WhisperM8Tests/DictationHotPathTests.swift:105-152`.

**Auslöseszenario:** Thread A sieht einen abgelaufenen Cache, entsperrt bei Zeile 45 und startet den teuren Probe. Thread B verarbeitet inzwischen einen Auth-Fehler und ruft `invalidate()` auf. Wenn A danach zurückkehrt, schreibt es sein vor der Invalidierung gewonnenes `.signedIn` bei Zeile 50 wieder in den Cache; weitere Läufe vertrauen bis zu fünf Minuten dem explizit verworfenen Zustand. Zwei parallele Probes können analog in umgekehrter Abschlussreihenfolge den neueren Status überschreiben.

**Fix-Skizze:** Unter dem Lock eine Generation erhöhen; Probe mit Startgeneration ausführen und Ergebnis nur speichern, wenn die Generation unverändert ist. Alternativ einen einzigen in-flight Probe koaleszieren und Invalidierung als Epoch-Grenze behandeln. Konkurrenztests mit blockierbarer Probe-Closure ergänzen.

### R4-AS-06 — mittel — Extrem große JSON-Zahlen können den toleranten Codex-Event-Parser crashen

**Beleg:** `WhisperM8/Services/AgentChats/CodexExecEventParser.swift:63-70,88-93`; Tests prüfen normale Integer, aber keine Bereichsgrenzen: `Tests/WhisperM8Tests/CodexExecEventParserTests.swift:46-52,85-94`.

**Auslöseszenario:** Ein Codex-Update, Proxy oder beschädigter Stream liefert etwa `{"type":"turn.completed","usage":{"input_tokens":1e300}}`. `JSONSerialization` repräsentiert den Wert als `Double`; `Int(double)` ist für außerhalb des `Int`-Bereichs liegende Werte nicht repräsentierbar und kann mit einem Runtime-Trap den gesamten Supervisor/App-Prozess beenden. Das widerspricht dem dokumentierten „wirft nie"-Vertrag.

**Fix-Skizze:** Vor der Konvertierung `isFinite`, `Int.min...Int.max` und bei Tokenzahlen Nichtnegativität prüfen; nicht repräsentierbare Werte als `nil` behandeln. Grenzwert-, Exponenten-, negative und fraktionale Fixtures ergänzen.

### R4-AS-07 — mittel — Subagent-Discovery lädt entgegen ihrem 16-KB-Vertrag die komplette Datei

**Beleg:** `WhisperM8/Services/AgentChats/SubAgentDiscovery.swift:104-109`; Tests verwenden nur kleine Fixtures: `Tests/WhisperM8Tests/SubAgentDiscoveryTests.swift:23-69,88-148`.

**Auslöseszenario:** Ein geöffnetes oder geklontes Projekt enthält `.claude/agents/large.md` mit mehreren hundert MB. `Data(contentsOf:)` lädt die gesamte Datei, erst danach wird `prefix(16 * 1024)` gebildet. Das Öffnen der Agent-Auswahl kann dadurch massiven Speicherverbrauch oder einen App-Abbruch auslösen; der Kommentar verspricht gerade den gegenteiligen Schutz.

**Fix-Skizze:** Mit `FileHandle.read(upToCount: 16 * 1024)` tatsächlich begrenzt lesen, Dateityp/Größe vorab prüfen und Symlinks bewusst behandeln. Test mit großer Sparse-/Fixture-Datei und instrumentiertem Reader ergänzen.

### R4-AS-08 — mittel — Die PID-Ahnenkette ist kein kohärenter Prozess-Snapshot

**Beleg:** separate `sysctl`-Reads und ungeprüfter Kettenübergang: `WhisperM8/Services/AgentChats/ProcessAncestry.swift:18-31,81-93`; Capture und persistenter Backfill: `WhisperM8/CLI/AgentCLICommand.swift:101-113`, `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:129-149,230-245`; Tests modellieren statische Bäume bzw. nur die Startzeit des finalen Kandidaten: `Tests/WhisperM8Tests/ProcessAncestryTests.swift:15-74`, `Tests/WhisperM8Tests/AgentJobWorkspaceSyncTests.swift:62-130`.

**Auslöseszenario:** Während `ancestorChain` von PID zu PPID läuft, endet ein Zwischenprozess und seine PID wird wiederverwendet. Der nächste `infoProvider(current)` kann dann die Elternkante eines anderen Prozesses liefern. Der spätere Schutz prüft nur, ob der **final gematchte** Live-PID vor `job.createdAt` gestartet wurde; er validiert weder die Startidentität jedes Kettenglieds noch die Kohärenz der Elternkanten. Gerät so die PID eines bereits älteren, fremden Agent-Chats in die Kette, wird dessen External-ID dauerhaft als Parent backgefüllt und laut Merge-Vertrag nicht mehr überschrieben.

**Fix-Skizze:** Bereits beim Capture pro Kettenglied `(pid,startTime,ppid,parentStartTime)` erfassen und jede Kante durch einen zweiten Read/CAS-artigen Identitätsvergleich bestätigen; bei jeder Änderung die gesamte Kette verwerfen. Persistiert und gematcht werden Prozessidentitäten, nicht nackte PIDs. Testprovider muss zwischen aufeinanderfolgenden Reads PID-Reuse und wechselnde PPIDs simulieren.

### R4-AS-09 — mittel — Zeitbasierte Close-Tracking-Suspension ist nicht generationenfest

**Beleg:** `WhisperM8/Services/Shared/AppProfileActivator.swift:23-40`; der Store hält nur ein Boolean: `WhisperM8/Services/AgentChats/AgentWindowStore.swift:726-738`; es gibt keine Tests für `AppProfileActivator`.

**Auslöseszenario:** Der User wechselt in ein Menüleistenprofil; Close-Tracking wird suspendiert und erst nach 500 ms reaktiviert. Wechselt er innerhalb dieses Fensters zurück zu „Full", können Fenster bereits wieder erscheinen, während die alte Suspension noch gilt; ein echter User-Close wird dann nicht persistiert. Bei zwei überlappenden Close-Zyklen kann außerdem der ältere Task das Boolean reaktivieren, obwohl der jüngere Zyklus noch suspendiert sein will.

**Fix-Skizze:** Suspension als Token/Referenzzähler oder Generation modellieren; nur der Besitzer des aktuellen Tokens darf sie beenden. Besser das Ende an bestätigte `willClose`-Ereignisse der konkret angeforderten Fenster statt an 500 ms koppeln. Tests für Full→Menu→Full und zwei überlappende Zyklen ergänzen.

### R4-AS-10 — niedrig — Der begrenzte Codex-Tail kann an einer UTF-8-Grenze vollständig ausfallen

**Beleg:** willkürlicher Byte-Offset und strikte Dekodierung des gesamten Tails: `WhisperM8/Services/AgentChats/CodexUsageReader.swift:77-93`; der einzige Datei-Test bleibt weit unter 256 KB und rein ASCII: `Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:577-591`.

**Auslöseszenario:** Eine Codex-Session ist größer als 256 KB und das berechnete Offset landet auf einem Fortsetzungsbyte eines mehrbyteigen Zeichens aus einem deutschen oder sonstigen Unicode-Prompt. `String(data:encoding:.utf8)` liefert dann für den kompletten Tail `nil`; auch eine vollständig gültige spätere `rate_limits`-Zeile wird nicht mehr gesucht. Fällt zugleich der Live-Endpoint aus, zeigt die Usage-UI keinen lokalen Fallback, obwohl er in der Datei vorhanden ist.

**Fix-Skizze:** Nach dem Seek bis zum ersten Newline verwerfen und nur die danach beginnenden vollständigen Zeilen dekodieren; alternativ verlustbehaftet dekodieren und die absichtlich unvollständige erste Zeile überspringen. Testdatei >256 KB so konstruieren, dass das Offset mitten in einem Mehrbytezeichen liegt und danach ein gültiges Rate-Limit-Event folgt.

### R4-AS-11 — hoch — Doppelte persistierte Session-IDs crashen den verzögerten Startup-Abgleich

**Beleg:** ungeprüftes `Dictionary(uniqueKeysWithValues:)`: `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:8-19`; Workspace-Load dekodiert und migriert ohne ID-Eindeutigkeitsprüfung: `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:49-64`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1182-1201`; automatischer Aufruf zehn Sekunden nach Start: `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:215-234`. Tests verwenden ausschließlich eindeutige IDs: `Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:83-141`.

**Auslöseszenario:** Eine syntaktisch gültige `AgentSessions.json` enthält nach manueller Bearbeitung, Sync-Konflikt oder früherem Schreibfehler zwei Sessions mit derselben UUID. Decoding und Migration akzeptieren beide. Ist Auto-Summary aktiv, ruft der Startup-Task nach zehn Sekunden den Planer auf; der Dictionary-Initializer löst bei dem doppelten Key einen Fatal Error aus und beendet die gesamte App bei jedem weiteren Start erneut.

**Fix-Skizze:** Eindeutigkeit bereits an der Repository-/Migrationsgrenze validieren und Konflikte deterministisch quarantänisieren bzw. reparieren. Der Planer selbst darf zusätzlich kein trap-fähiges API verwenden: Dictionary iterativ mit dokumentierter First-/Last-wins-Politik aufbauen. Persistenz- und Planertest mit doppelter UUID ergänzen.

### R4-AS-12 — mittel — Evidence-Extraktion meldet bloße Texttreffer als ausgeführte, bestandene Tests

**Beleg:** Kommentar verspricht Erkennung am Anfang, Implementierung nutzt ungebundenes `contains` und setzt Erfolg allein aus `!isError`: `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift:67-74`; Tests prüfen nur echte, direkt beginnende Kommandos: `Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:43-51`.

**Auslöseszenario:** Ein Agent sucht etwa mit `rg -n 'swift test' README.md` nach Dokumentation oder führt `echo 'swift test'` aus. Weil der Bash-Step keinen Toolfehler hat, persistiert die Session-Zusammenfassung daraus einen angeblich bestandenen Testlauf. Der User erhält damit gerade in der als deterministisch und nicht halluziniert beschriebenen Evidence-Liste eine falsche Verifikationsaussage.

**Fix-Skizze:** Das tatsächlich ausgeführte Kommando tokenisieren und nur erlaubte Test-Runner am Kommandostart beziehungsweise nach explizit unterstützten Präfixen (`env`, Zuweisungen, `cd … &&`) akzeptieren. Erfolg an einen verlässlichen Exitcode binden, nicht nur an die Abwesenheit eines Parser-Fehlerflags. Negative Tests für `echo`, `rg`, Kommentare und Stringliterale ergänzen.

### R4-AS-13 — mittel — Icon-Erkennung liest gefundene Web-Manifeste unbeschränkt in den Speicher

**Beleg:** das Scan-Budget begrenzt nur Verzeichniseinträge (`WhisperM8/Services/AgentChats/AgentProjectIconResolver.swift:49-54,326-352`), jedes gefundene Manifest wird dagegen vollständig mit `Data(contentsOf:)` geladen (`AgentProjectIconResolver.swift:172-192`); der Auto-Lookup läuft für manuell hinzugefügte Projekte (`WhisperM8/Views/AgentChatsView+ProjectManagement.swift:167-193`). Tests verwenden nur kleine Manifest-Strings: `Tests/WhisperM8Tests/AgentProjectMetadataTests.swift:50-91`.

**Auslöseszenario:** Ein manuell hinzugefügtes oder geklontes Repository enthält ein generiertes `manifest.json`/`site.webmanifest` von mehreren hundert MB. Der automatische Icon-Lookup findet die Datei trotz Entry-/Tiefenbudget und lädt sie komplett, bevor JSON geparst wird. Der Utility-Task blockiert damit zwar nicht direkt den MainActor, kann aber den Prozess durch Speicherdruck beenden.

**Fix-Skizze:** Vor dem Read Regular-File- und Größenlimit prüfen und große Manifeste überspringen; für die erwartete kleine JSON-Struktur eine harte Obergrenze lesen. Sparse-/Großdatei- und Symlink-Fixtures ergänzen und verifizieren, dass außerhalb des Projektroots liegende Ziele verworfen werden.

## 3. Kurzreviews je Datei

### 3.1 `Services/AgentChats`

#### `AgentDirectoryEventMonitor.swift` — gezielt — **prüfwürdig**

- **Zweck/Tiefe:** Pfadfilter, FSEvents-Erzeugung, Callback-Lifetime, Stop und Debounce vollständig gelesen (`WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift:34-115`).
- **Risiko/Urteil:** Der Rückgabewert von `FSEventStreamStart` wird ignoriert und die Source danach als aktiv gespeichert/logged (`AgentDirectoryEventMonitor.swift:70-86`). Bei Startfehler verhindert `stream != nil` jeden Retry (`AgentDirectoryEventMonitor.swift:52-53`). Das ist ein seltener, aber echter stiller Degradationspfad; keine zusätzliche Race nachgewiesen.
- **Tests:** `AgentSessionEventWatchTests` prüft nur `relevantPaths` (`Tests/WhisperM8Tests/AgentSessionEventWatchTests.swift:63-104`), nicht FSEvents-Startfehler, Stop oder Debounce.

#### `AgentJobRuntimeModel.swift` — gezielt — **unauffällig**

- **Zweck/Tiefe:** Sämtliche Mutationen und Abfragen gelesen (`WhisperM8/Services/AgentChats/AgentJobRuntimeModel.swift:13-68`).
- **Risiko/Urteil:** MainActor-Isolation, kompletter diff-gated Snapshot-Austausch und das Aufräumen lokaler Takeover-Marker sind konsistent (`AgentJobRuntimeModel.swift:8-10,49-67`). Keine Subprozesse, Secrets, Force-Unwraps oder Persistenz.
- **Tests:** Kein dedizierter Test des Observable-Modells; die risikotragende Merge-/Projektionswahrheit liegt im separat getesteten Sync (`WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:118-180`; `Tests/WhisperM8Tests/AgentJobWorkspaceSyncTests.swift:62-130`), nicht in diesem Projektionsobjekt.

#### `AgentProjectIconResolver.swift` — vertieft — **Finding R4-AS-13**

- **Zweck/Tiefe:** Quick-Probe, Manifest-Auflösung, Scoring, Rekursionsgrenzen, Dateilesegrenze und Relative-Path-Helfer gelesen (`WhisperM8/Services/AgentChats/AgentProjectIconResolver.swift:55-80,111-209,225-310,326-385`).
- **Risiko/Urteil:** Scan-Budget, Tiefe und Pruning begrenzen normale Großrepos (`AgentProjectIconResolver.swift:48-53,343-352`), nicht aber die Größe jedes gelesenen Manifests; siehe R4-AS-13. Manifest-`src` darf zudem über `..` bzw. Symlinks außerhalb des Projekts zeigen und wird nur auf Existenz geprüft (`AgentProjectIconResolver.swift:189-207`); der konkrete Consumer hängt den Wert wieder an den Projektpfad (`WhisperM8/Models/AgentChat.swift:222-226`), daher wurde hierfür ohne verifizierten Escape kein zweites Finding erhoben. Kanonische Root- und Regular-Image-Prüfung bleiben erforderlich.
- **Tests:** Gute Konventions-/Manifest-/Scoring-Abdeckung (`Tests/WhisperM8Tests/AgentProjectMetadataTests.swift:17-191`), aber keine `../`-, Symlink-, übergroße Manifest- oder Entry-Budget-Fixture.

#### `AgentResourceMonitor.swift` — gezielt — **unauffällig**

- **Zweck/Tiefe:** Snapshot-Aggregation, Prozessbaum, `ps`-Parser und Subprozess-Drain gelesen (`WhisperM8/Services/AgentChats/AgentResourceMonitor.swift:79-153,156-228`).
- **Risiko/Urteil:** Der `ps`-Snapshot ist für reine Telemetrie angemessen, Zyklen sind durch `seen` begrenzt (`AgentResourceMonitor.swift:142-151`), stdout wird vor `waitUntilExit` geleert (`AgentResourceMonitor.swift:218-227`). stderr wird zwar erst nach stdout gelesen, die zwei fest verdrahteten Systemkommandos erzeugen aber keine realistische große stderr-Menge; kein belastbares Deadlock-Szenario wie bei R4-AS-03.
- **Tests:** Baumaggregation, Summen, fehlender Gesamtspeicher und tote Descriptoren werden über injizierte Samples geprüft (`Tests/WhisperM8Tests/AgentResourceMonitorTests.swift:5-79`); der `ps`-Textparser und PID-Reuse fehlen. PID-Reuse kann kurzfristig Telemetrie falsch zuordnen, hat hier aber keine steuernde Wirkung.

#### `AgentWorktreeManager.swift` — vertieft — **Finding R4-AS-03**

- **Zweck/Tiefe:** Create/Clean/Remove samt echtem Process-Runner und Tests gelesen (`WhisperM8/Services/AgentChats/AgentWorktreeManager.swift:38-91`; `Tests/WhisperM8Tests/AgentWorktreeManagerTests.swift:8-83`).
- **Urteil:** Direkte argv-Nutzung verhindert Shell-Injection (`AgentWorktreeManager.swift:73-79`), aber die Pipe-/Exit-Reihenfolge kann den Spawn dauerhaft hängen lassen; siehe R4-AS-03. Tests decken Schmutzschutz und Kleinstrepo ab, nicht Pipe-Druck/Timeout.

#### `ClaudeAccountUsageFetcher.swift` — vertieft — **Finding R4-AS-02**

- **Zweck/Tiefe:** Keychain-Leseweg, HTTP-Header, Cache-Fallback, Cache-Schreiben und Parser gelesen (`WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift:20-83,85-138`) und gegen Statusline-Produzent abgeglichen (`WhisperM8/Resources/whisperm8-statusline.sh:98-105,133-162`).
- **Urteil:** Das OAuth-Token bleibt im Request-Header und wird nicht geloggt (`ClaudeAccountUsageFetcher.swift:42-64`), also keine N09/N10-Wiederholung. Cache-Pfad und Trust Boundary sind dagegen fehlerhaft; siehe R4-AS-02.
- **Tests:** Parserformen sind abgedeckt (`Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:377-435`), Live→Cache, gemeinsamer Pfad und lokale Manipulation nicht.

#### `ClaudeThemeWriter.swift` — vertieft — **Finding R4-AS-01**

- **Zweck/Tiefe:** Debounce, Seed, Read/Parse/Merge/Replace, Permissions und Backup vollständig in zwei Abschnitten gelesen (`WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:54-78,82-190`).
- **Urteil:** Parse-Fehler werden sicher nicht überschrieben und Permissions übernommen (`ClaudeThemeWriter.swift:108-119,142-153`), aber atomarer Replace ist kein Schutz gegen parallele Read-modify-write-Lost-Updates; siehe R4-AS-01.
- **Tests:** `ThemeManagerTests` prüft nur Light/Dark-Mapping (`Tests/WhisperM8Tests/ThemeManagerTests.swift:66-67`), keinerlei Dateischreibpfad.

#### `CodexAgentPreflight.swift` — gezielt — **unauffällig**

- **Zweck/Tiefe:** Resolver, Login-Shell-Environment, Timeout-Runner, Versionspolitik und Parser gelesen (`WhisperM8/Services/AgentChats/CodexAgentPreflight.swift:8-72`).
- **Risiko/Urteil:** Binary wird zentral aufgelöst, Environment korrekt propagiert und kein Secret in argv ergänzt (`CodexAgentPreflight.swift:28-41`). Unparsebare Version ist ein expliziter, typisierter Outcome statt stilles `ok` (`CodexAgentPreflight.swift:44-59`).
- **Tests:** Missing/alt/neu/unparsebar und Versionsformen sind in `CodexAgentPreflightTests` abgedeckt (`Tests/WhisperM8Tests/CodexAgentPreflightTests.swift:4-89`); echte Timeout-/hängende-Binary-Wirkung gehört zum separat auditierten `AgentHeadlessCLI`.

#### `CodexExecEvent.swift` — oberflächlich — **unauffällig**

- **Zweck/Tiefe:** Gesamtes Typmodell gelesen (`WhisperM8/Services/AgentChats/CodexExecEvent.swift:7-48`).
- **Risiko/Urteil:** Reine Werttypen, optionale driftanfällige Felder und `.unknown`-Fallback; keine Lifecycle-, I/O- oder Secret-Fläche. Das unbeschränkte `aggregatedOutput` (`CodexExecEvent.swift:28-39`) wird vom Stream-Layer begrenzt bzw. getragen, nicht hier.
- **Tests:** Indirekt über normale, unbekannte und kaputte Parser-Events geprüft (`Tests/WhisperM8Tests/CodexExecEventParserTests.swift:35-114`); kein eigener Bedarf jenseits Parsergrenzen.

#### `CodexExecEventParser.swift` — vertieft — **Finding R4-AS-06**

- **Zweck/Tiefe:** Event-Switch und alle Teilparser vollständig gelesen (`WhisperM8/Services/AgentChats/CodexExecEventParser.swift:7-93`).
- **Urteil:** Unbekannte Typen und fehlende IDs degradieren kontrolliert (`CodexExecEventParser.swift:14-25,41-43`); die Double→Int-Grenze kann trotzdem den Prozess trapen, siehe R4-AS-06.
- **Tests:** Normale Fixture, Unknown und malformed JSON sind abgedeckt (`Tests/WhisperM8Tests/CodexExecEventParserTests.swift:46-52,85-94`), numerische Extremwerte nicht.

#### `CodexReportSchema.swift` — gezielt — **unauffällig**

- **Zweck/Tiefe:** Eingebettetes JSON-Schema, Schreibpfade und Abschlussreport-Parser vollständig gelesen (`WhisperM8/Services/AgentChats/CodexReportSchema.swift:13-59,68-109`).
- **Risiko/Urteil:** Temp-Dateiname ist UUID-basiert und wird atomar geschrieben (`CodexReportSchema.swift:49-58`); Parser fällt bei Drift auf `nil`, statt falsche Defaults zu erfinden (`CodexReportSchema.swift:90-96`). Keine Force-Unwraps oder Secrets.
- **Tests:** `AgentReportTests` deckt gültig, ungültig und Fences ab (`Tests/WhisperM8Tests/AgentReportTests.swift:4-68`); nicht abgedeckt ist Output-Schema-Drift auf zusätzliche/umbenannte Felder, der aktuell bewusst als Rohtext-Fallback behandelt wird.

#### `CodexUsageReader.swift` — vertieft — **Finding R4-AS-10**

- **Zweck/Tiefe:** Dateisuche, 256-KB-Tail samt Byte-/UTF-8-Grenze, Rate-Limit-Parser, `auth.json`-Leseweg, Live-Request und Wham-Parser gelesen (`WhisperM8/Services/AgentChats/CodexUsageReader.swift:44-140,143-232`).
- **Risiko/Urteil:** Access-Token und Account-ID gehen ausschließlich in HTTP-Header, nicht argv/env/log (`CodexUsageReader.swift:165-183`). Die Bytezahl ist speicherbegrenzt, aber eine UTF-8-Trennung kann den gesamten Tail verwerfen; siehe R4-AS-10. Zusätzliche Parser-Drift bleibt möglich: feste Schlüssel `rate_limits`, `used_percent` und `window_minutes` führen bei Formatänderung still zu nil (`CodexUsageReader.swift:97-121`); Live-Fallback mildert das.
- **Tests:** Parser des lokalen und Live-Schemas ist abgedeckt (`Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:522-591`); keine abgeschnittene erste Tail-Zeile, UTF-8-Grenze, >256-KB-letztes Event, HTTP-Status- oder Schema-Drift-Fixture.

#### `ExternalClaudeHooksInspector.swift` — gezielt — **prüfwürdig**

- **Zweck/Tiefe:** Beide Settings-Pfade, JSON-Struktur, Eventfilter und Command-Preview vollständig gelesen (`WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift:24-81`).
- **Risiko/Urteil:** Rein lesend und tolerant. Neue Hook-Varianten ohne `command` oder mit anderer Containerstruktur werden still ignoriert (`ExternalClaudeHooksInspector.swift:60-66`); das kann die Warn-UI unvollständig machen, verursacht aber keinen ausführenden Fehler.
- **Tests:** Standardstruktur, Filter und Preview sind abgedeckt (`Tests/WhisperM8Tests/ExternalClaudeHooksInspectorTests.swift:4-101`); keine unbekannten zukünftigen Hooktypen oder große Settings-Datei.

#### `ProcessAncestry.swift` — vertieft — **Finding R4-AS-08**

- **Zweck/Tiefe:** Beide `sysctl`-Abfragen, Namenssuche, Kettenlauf, CLI-Capture, Match und Backfill über Dateigrenzen verfolgt (`WhisperM8/Services/AgentChats/ProcessAncestry.swift:16-93`; `WhisperM8/CLI/AgentCLICommand.swift:101-113`; `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:129-149,230-245`).
- **Urteil:** Finaler PID-Reuse-Check ist vorhanden, schließt inkohärente Zwischenkanten aber nicht; siehe R4-AS-08.
- **Tests:** Statische Bäume, reale Eigenprozess-Lektüre und finaler Startzeitfilter sind gut abgedeckt (`Tests/WhisperM8Tests/ProcessAncestryTests.swift:15-99`; `Tests/WhisperM8Tests/AgentJobWorkspaceSyncTests.swift:62-130`), mutierende Providersequenzen nicht.

#### `SubAgentDiscovery.swift` — vertieft — **Finding R4-AS-07**

- **Zweck/Tiefe:** Scope-Priorität, Directory-Scan, File-Read, Frontmatter und Quote-Parser vollständig gelesen (`WhisperM8/Services/AgentChats/SubAgentDiscovery.swift:51-173`).
- **Urteil:** Einfache Frontmatter-Drift degradiert bewusst; der behauptete 16-KB-Schutz ist jedoch nicht implementiert, siehe R4-AS-07.
- **Tests:** Frontmatter, Quotes, Scope und Override sind abgedeckt (`Tests/WhisperM8Tests/SubAgentDiscoveryTests.swift:23-148`); tatsächliche Read-Grenze, Symlink und große Datei nicht.

#### `SummaryStartupPlanner.swift` — vertieft — **Finding R4-AS-11**

- **Zweck/Tiefe:** Gesamten Planer, verzögerten Startup-Aufruf sowie Workspace-Load/Migration auf die vorausgesetzte ID-Eindeutigkeit gelesen (`WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift:8-33`; `AgentSessionSummarizer.swift:215-234`; `AgentWorkspaceRepository.swift:49-64`; `AgentSessionStore.swift:1182-1201`).
- **Risiko/Urteil:** Tab-Deduplizierung, Filter und Kandidatendeckel sind für valide Daten korrekt (`SummaryStartupPlanner.swift:17-32`); doppelte persistierte Session-UUIDs verletzen jedoch eine nirgends am Load erzwungene Annahme und trapen im Dictionary-Initializer; siehe R4-AS-11.
- **Tests:** `AgentSessionSummarizerTests` deckt Auswahl, Staleness und Begrenzung nur mit eindeutigen Session-IDs ab (`Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:83-141`); syntaktisch valider Persistenzinput mit doppelter UUID fehlt.

#### `TranscriptEvidenceExtractor.swift` — vertieft — **Finding R4-AS-12**

- **Zweck/Tiefe:** Gesamte Extraktion, Commit-Regex, Testkommando-Erkennung, Evidence-Verbrauch und zugehörige Tests gelesen (`WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift:9-74`; `Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:3-51`).
- **Risiko/Urteil:** Harte Deckel verhindern Summary-Aufblähung (`TranscriptEvidenceExtractor.swift:39-43`). Die ungebundene Substring-Suche kann aber bloße Such-/Echo-Kommandos als bestandenen Test persistieren; siehe R4-AS-12.
- **Tests:** Typische direkte Commit-/Testkommandos sind abgedeckt (`Tests/WhisperM8Tests/AgentSessionSummarizerTests.swift:20-51`), nicht Marker in Echo, Suche, Kommentar oder Stringliteral und nicht Exitcode-vs-`isError`-Abweichung.

#### `WorkspaceSlotOps.swift` — vertieft — **unauffällig**

- **Zweck/Tiefe:** Add/Replace/Swap/Move sowie Capacity-Preview und TOCTOU-Bestätigung vollständig gelesen (`WhisperM8/Services/AgentChats/WorkspaceSlotOps.swift:44-96,100-198`).
- **Risiko/Urteil:** Pure Wertsemantik; Shrink verlangt exakt die zuvor bestätigte Eviction-Liste und lehnt stale Bestätigungen ab (`WorkspaceSlotOps.swift:154-196`). Keine I/O-, Lock- oder Secret-Fläche.
- **Tests:** Breite Tabellen-/Edge-Abdeckung einschließlich Full/Grow/Shrink/Swap (`Tests/WhisperM8Tests/WorkspaceSlotOpsTests.swift:6-252`; ergänzende Grid-State-Tests: `Tests/WhisperM8Tests/AgentGridLayoutTests.swift:9-151`); Interaktions-Races liegen im `AgentWindowStore`, nicht hier.

### 3.2 `Services/Shared`

#### `AppProfileActivator.swift` — vertieft — **Finding R4-AS-09**

- **Zweck/Tiefe:** Profilanwendung und kompletten Fenster-Close-Pfad gelesen und Boolean-Store nachverfolgt (`WhisperM8/Services/Shared/AppProfileActivator.swift:10-40`; `WhisperM8/Services/AgentChats/AgentWindowStore.swift:724-750`).
- **Urteil:** Die 500-ms-Heuristik ist nicht generationenfest; siehe R4-AS-09.
- **Tests:** Kein dedizierter Symboltreffer; schnelle Profilwechsel und verzögertes `willClose` sind ungetestet.

#### `CodexGlobalConfigReader.swift` — vertieft — **unauffällig**

- **Zweck/Tiefe:** Locking, Stat-Cache, stale-good-Fallback und Top-Level-TOML-Subset vollständig gelesen (`WhisperM8/Services/Shared/CodexGlobalConfigReader.swift:12-94`).
- **Risiko/Urteil:** Lock schützt Cache; Subprozess gibt es nicht. Datei fehlt/unlesbar behält bewusst den letzten guten Stand (`CodexGlobalConfigReader.swift:43-60`), und der Test fixiert genau diesen Vertrag (`Tests/WhisperM8Tests/CodexGlobalConfigReaderTests.swift:48-72`). Parser ist absichtlich kein Voll-TOML und stoppt vor Profilsektionen (`CodexGlobalConfigReader.swift:63-91`).
- **Tests:** Cache-Invalidierung per Stat, Missing-Fallback und Parserfälle sind vorhanden (`Tests/WhisperM8Tests/CodexGlobalConfigReaderTests.swift:7-72`); keine gleichzeitigen Caller, aber die gesamte Mutation liegt unter `NSLock`.

#### `CodexModelCatalog.swift` — vertieft — **unauffällig**

- **Zweck/Tiefe:** Lookup, Frontier-Auswahl, Picker-Konfliktlogik, Fallback, Auto-Sentinel sowie Store/lenient Parser/Merge gelesen (`WhisperM8/Services/Shared/CodexModelCatalog.swift:41-149,151-248,251-404`).
- **Risiko/Urteil:** Store ist read-only und lock-serialisiert (`CodexModelCatalog.swift:258-302`); kaputte einzelne Modelle werden verworfen, Cache und Fallback deterministisch gemergt (`CodexModelCatalog.swift:321-396`). Kein Lost-Update-Pfad. Parser-Drift kann Modelle auslassen, der eingebettete Fallback verhindert leere Auswahl.
- **Tests:** Katalog-, Auswahl-, Cache- und Fallback-Verträge sind breit abgedeckt (`Tests/WhisperM8Tests/CodexModelCatalogTests.swift:8-260`); unbekannte zukünftige Visibility-Werte werden bewusst nicht angezeigt (`CodexModelCatalog.swift:390-396`).

#### `FileEventSource.swift` — vertieft — **Finding R4-AS-04**

- **Zweck/Tiefe:** FD-Lifetime, Source-Erzeugung, Event-/Cancel-Handler, Stop und Re-Arm-Vertrag vollständig gelesen (`WhisperM8/Services/Shared/FileEventSource.swift:6-69`).
- **Urteil:** FD wird im Cancel-Handler geschlossen (`FileEventSource.swift:55-57`), aber Alt-Callbacks sind nicht an die aktuelle Source gebunden; siehe R4-AS-04.
- **Tests:** Basiserfolg vorhanden, Stop→Start/queued old event fehlt (`Tests/WhisperM8Tests/AgentSessionEventWatchTests.swift:16-56`).

#### `GridPerformanceTracker.swift` — vertieft — **unauffällig**

- **Zweck/Tiefe:** Build- und Fokusmessung einschließlich Generationen, Timeout und Abbruch vollständig gelesen (`WhisperM8/Services/Shared/GridPerformanceTracker.swift:14-160`).
- **Risiko/Urteil:** Alte Async-/Timeout-Callbacks werden durch Generation und Fokusziel abgewehrt (`GridPerformanceTracker.swift:53-100,113-155`). Die bekannte A→B→A-Messungenauigkeit ist explizit auf Telemetrie beschränkt (`GridPerformanceTracker.swift:32-39`), kein Produktzustand.
- **Tests:** Supersede, Timeout, falsches Ziel und Abort sind abgedeckt (`Tests/WhisperM8Tests/GridPerformanceTrackerTests.swift:8-135`); keine Finding-Klasse überlebt.

#### `PermissionService.swift` — oberflächlich — **unauffällig**

- **Zweck/Tiefe:** Gesamte Datei gelesen (`WhisperM8/Services/Shared/PermissionService.swift:5-52`).
- **Risiko/Urteil:** Dünne Wrapper um Apple-APIs und feste Settings-URLs; keine gespeicherten Secrets, keine Force-Unwraps, keine Nebenläufigkeitszustände. Rückgabewert von `NSWorkspace.open` wird nicht ausgewertet (`PermissionService.swift:47-51`), höchstens fehlende UX-Rückmeldung.
- **Tests:** Kein dedizierter Test; echte TCC-Dialoge sind primär manuelle Integrations- statt Unit-Test-Fläche.

#### `SemanticVersion.swift` — gezielt — **unauffällig**

- **Zweck/Tiefe:** Parser und Vergleich vollständig gelesen (`WhisperM8/Services/Shared/SemanticVersion.swift:7-46`).
- **Risiko/Urteil:** Bereichsüberlauf degradiert über `Int(part)` zu nil, negative und leere Komponenten werden abgewiesen (`SemanticVersion.swift:18-37`). Keine Crashkante.
- **Tests:** Formate, fehlende Komponenten, Ablehnungen und numerischer Vergleich sind abgedeckt (`Tests/WhisperM8Tests/AppUpdateCheckerTests.swift:5-35`; ergänzend Preflight-Parsing: `Tests/WhisperM8Tests/CodexAgentPreflightTests.swift:4-30`); Prerelease ist laut Vertrag bewusst unsupported (`SemanticVersion.swift:2-6`).

#### `SystemSoundCatalog.swift` — oberflächlich — **unauffällig**

- **Zweck/Tiefe:** Gesamte Datei gelesen (`WhisperM8/Services/Shared/SystemSoundCatalog.swift:4-29`).
- **Risiko/Urteil:** Read-only-Verzeichnisliste, Extension-Allowlist, Fallback-Sound; kein Pfad aus Userinput wird geöffnet (`SystemSoundCatalog.swift:10-28`). `NSSound.play`-Fehler ist bewusst optional und ohne Lifecycle-Folge.
- **Tests:** Kein dedizierter Test; prüfenswert nur manuelle OS-Kompatibilität der verfügbaren Soundnamen.

### 3.3 Agent-Chats-relevante `Services/Dictation`

#### `CodexErrorSummary.swift` — gezielt — **unauffällig**

- **Zweck/Tiefe:** Priorisierung und Fallback vollständig gelesen (`WhisperM8/Services/Dictation/CodexErrorSummary.swift:6-20`).
- **Risiko/Urteil:** Pure String-Reduktion. Die letzte stderr-Zeile wird ungefiltert userseitig angezeigt (`CodexErrorSummary.swift:14-18`); da der Codex-Spawn Secrets weder in argv noch in standardisierte Fehlermeldungen legt, kein belegter Leak. Bei künftigen Drittanbieterfehlern Redaction erwägen.
- **Tests:** Update, Login, Priorität, letzte Zeile und leer sind abgedeckt (`Tests/WhisperM8Tests/CodexErrorSummaryTests.swift:7-43`); keine Secret-Muster-Fixture.

#### `CodexStatusCache.swift` — vertieft — **Finding R4-AS-05**

- **Zweck/Tiefe:** TTL-Entscheid, Lock-Grenze, Probe und Invalidierung vollständig gelesen (`WhisperM8/Services/Dictation/CodexStatusCache.swift:12-60`).
- **Urteil:** Subprozess liegt korrekt außerhalb des Locks (`CodexStatusCache.swift:45-50`), dadurch entsteht ohne Generation aber die Invalidierungs-/Completion-Race; siehe R4-AS-05.
- **Tests:** Nur serielle TTL- und Invalidierungsabläufe (`Tests/WhisperM8Tests/DictationHotPathTests.swift:105-152`), keine blockierende Parallelprobe.

#### `ProjectPathResolver.swift` — gezielt — **unauffällig**

- **Zweck/Tiefe:** Gesamte Pfadauflösung gelesen (`WhisperM8/Services/Dictation/ProjectPathResolver.swift:6-33`).
- **Risiko/Urteil:** Pure Auswahl; Task-Modus hält bewusst den Defaultpfad, andere Read-only-Modi bevorzugen den Agent-Chat-Kontext (`ProjectPathResolver.swift:15-25`). Existenz/Kanonikalisierung ist Aufgabe der Egress-Grenze; hier keine Mutation oder Shell-Interpolation.
- **Tests:** Off/Task/Agent-Chat/Default/Whitespace sind abgedeckt (`Tests/WhisperM8Tests/ProjectPathResolverTests.swift:4-96`); keine Finding-Klasse.

## 4. Testlücken und Gesamturteil

### 4.1 Ergebnis in Zahlen

- **29 Dateien** einzeln geprüft: 13 mit Finding, 2 prüfwürdig ohne ausreichenden Impact-Beleg, 14 unauffällig.
- **13 Findings:** 3 hoch, 9 mittel, 0 kritisch, 1 niedrig.
- **Tiefenverteilung:** Die I/O-, Prozess-, PID-, Parser-, Cache- und Lifecycle-Dateien wurden gezielt bis vertieft gelesen; reine Wert-/Wrapperdateien oberflächlich bis gezielt. Das ist ein breiter statischer Abdeckungssweep, kein Ersatz für die ausdrücklich genannten Konkurrenz-/Integrationstests.

### 4.2 Systemische Muster

1. **„Atomar" wird mit „konfliktfrei" verwechselt.** `ClaudeThemeWriter` erzeugt zwar immer valides JSON, kann aber wie der parallel auditierte Statusline-Installer fremde Read-modify-write-Änderungen verlieren (R4-AS-01). Extern gemeinsam beschriebene Settings brauchen eine Optimistic-Concurrency-Grenze, nicht nur Rename.
2. **Generationen fehlen an asynchronen Grenzen.** File-Source-Rearm, Statuscache-Invalidierung und Fenster-Close-Suspension besitzen jeweils einen alten Completion-/Callback-Pfad, der neueren Zustand überschreiben kann (R4-AS-04, R4-AS-05, R4-AS-09).
3. **Prozessidentität bleibt an einer Stelle PID-basiert.** Der spätere Startzeitcheck ist sinnvoll, aber die Ahnenkette selbst wird aus mehreren nicht kohärenten PID-Reads aufgebaut (R4-AS-08).
4. **„Tolerante" Parser/Reader haben harte Randkanten.** Unbekannte Eventtypen sind sauber modelliert, numerische Bereichsfehler können dennoch trapen; zwei angeblich begrenzte Reader scheitern an realen Datei-/Encodinggrenzen oder laden trotzdem alles (R4-AS-06, R4-AS-07, R4-AS-10, R4-AS-13).
5. **Ungeprüfte semantische Invarianten werden zu harter oder falscher Wahrheit.** Doppelte Session-IDs trapen statt am Load abgefangen zu werden; eine bloße Testnamen-Substring-Übereinstimmung wird als bestandene Verifikation persistiert (R4-AS-11, R4-AS-12).
6. **Secrets sind in den gelesenen Swift-Pfaden überwiegend korrekt behandelt.** Claude- und Codex-OAuth-Tokens gehen in HTTP-Header und weder in argv noch Environment oder Logs (`WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift:42-64`; `WhisperM8/Services/AgentChats/CodexUsageReader.swift:165-183`). Das neue Problem liegt beim Cache-Trust, nicht beim Token-Egress (R4-AS-02).

### 4.3 Was vorhandene Tests systematisch nicht abdecken

- **Deterministische Konkurrenzfenster:** externer Settings-Write zwischen Read und Replace; `invalidate` während laufendem Probe; Stop→Start vor altem vnode-Callback; überlappende Profilwechsel.
- **Subprozess-Backpressure und Teardown:** Real-Git-Test mit >Pipe-Puffer-Ausgabe, Timeout und Nachkommen; der aktuelle Kleinstrepo-Test erreicht diese Klasse nicht (`Tests/WhisperM8Tests/AgentWorktreeManagerTests.swift:54-83`).
- **Adversariale Parser-/Dateigrenzen:** `1e300`, negative/fraktionale Tokenwerte, tatsächlich große Agent-Markdown-/Web-Manifest-Dateien, UTF-8-Split am 256-KB-Tail, Manifest-`../`/Symlink.
- **Semantisch korrupte, aber dekodierbare Daten:** doppelte persistierte Session-UUID sowie Bash-Kommandos, die Testnamen nur suchen, ausgeben oder zitieren; normale Parser-/Planer-Fixtures erreichen diese Klassen nicht.
- **Mutierende Prozesswelt:** Tests verwenden statische `infoProvider`-Bäume und getrennte Startzeit-Fixtures, aber keinen PID-Reuse zwischen zwei aufeinanderfolgenden Ahnen-Reads (`Tests/WhisperM8Tests/ProcessAncestryTests.swift:15-74`; `Tests/WhisperM8Tests/AgentJobWorkspaceSyncTests.swift:62-130`).
- **Produktionspfad statt purem Helper:** Theme-Tests prüfen nur das Mapping, Usage-Tests nur Parser und Directory-Monitor-Tests nur den Pfadfilter (`Tests/WhisperM8Tests/ThemeManagerTests.swift:66-67`; `Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:377-435`; `Tests/WhisperM8Tests/AgentSessionEventWatchTests.swift:63-104`).

### 4.4 Priorität

1. **Sofort:** R4-AS-01, R4-AS-03 und R4-AS-11 — persistenter Fremddatenverlust, unbegrenzt hängender Kernprozess bzw. reproduzierbarer Fatal Error auf dekodierbaren Persistenzdaten.
2. **Danach als gemeinsame Lifecycle-Welle:** R4-AS-04, R4-AS-05 und R4-AS-09 mit einem einheitlichen Generation-/Token-Muster.
3. **Identitätswelle:** R4-AS-08 zusammen mit den bestehenden N01-artigen PID-Verträgen lösen; nackte PIDs nicht erneut als langlebige Wahrheit etablieren.
4. **Parser-/Boundary-Härtung:** R4-AS-02, R4-AS-06, R4-AS-07, R4-AS-10 und R4-AS-13 samt adversarialen Tests.
5. **Evidence-Vertrag:** R4-AS-12 vor weiterer prominenter Nutzung der automatisch erzeugten Session-Zusammenfassungen korrigieren.

**Gesamturteil:** Der Großteil der bisher ungenannten Services ist klein, rein oder sinnvoll diff-/lock-gated. Die verbleibenden Fehler konzentrieren sich nicht auf Businesslogik, sondern auf genau die aus Runde 1–3 bekannten Klassen: externe Lost Updates, Completion-/Teardown-Races, PID-Identität, Pipe-Backpressure, ungeprüfte Persistenzinvarianten und Parser-/Dateigrenzen. Der Sweep schließt die mechanische Service-Lücke, ersetzt aber für diese dreizehn Findings nicht die jeweils skizzierten deterministischen Verify-Tests.
