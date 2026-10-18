---
status: roh
updated: 2026-10-17
description: Workflow A, A1 Diktat + VoiceGate — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A1 Diktat + VoiceGate

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

Statische Prüfung mit 21 Befunden: 3 P0, 13 P1 und 5 P2. Besonders kritisch sind fehlende Aufnahmerettung beim Beenden, überschreibbare Nutzerdaten und unwirksames Entfernen bereits erfasster Kontextdaten. Datenfluss: Hotkey → AppState/RecordingCoordinator → AudioRecorder und Kontext-Capture → Groq/OpenAI → optional echte Codex-CLI → Zwischenablage/Auto-Paste → lokales Archiv. Erhalten bleiben sollten die ObjC-Absicherung beider installTap-Aufrufe, gestreamte Multipart-Uploads, Aufbewahrung bei Upload-Fehlern sowie Codex-Sandbox und Raw-Fallback. Die Cache- und Overlay-Tick-Trennung sind ebenfalls bewusst gelöst. Keine Builds, Tests oder App-Starts ausgeführt. Keine Dateien verändert; gemäß der übergeordneten Vorgabe wurden auch keine Berichtsdateien angelegt.

## Befunde

### LR-DIK-001 (A1-01) · Beenden rettet laufende Diktate nicht

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand L · Risiko mittel*

**Features:** F-DIK-01, F-DIK-02  ·  **Alt-ID:** N02

**Beleg:** `WhisperM8/WhisperM8App.swift:428-450`, `WhisperM8/Services/Dictation/AudioRecorder.swift:132-150`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:23-29`

**Szenario:** Der Nutzer beendet die App während einer langen Aufnahme oder eines Uploads. Der Quit-Hook antwortet sofort mit terminateNow; weder Recorder-Finalisierung noch Verschieben in FailedRecordings erfolgen. Die Aufnahme bleibt unregistriert im temporären Verzeichnis und ist nach dem Neustart nicht wiederherstellbar über die App.

**Fix:** Ein asynchrones Termination-Gate ergänzt den bestehenden Quit-Vertrag: Aufnahme finalisieren, ausstehendes Audio samt Retry-Metadaten dauerhaft sichern und erst danach beenden. Terminal-/Workspace-Sicherung und Ducking-Restore müssen erhalten bleiben; zusätzlich Crash-Recovery für unfertige Diktatläufe vorsehen.

### LR-DIK-002 (A1-02) · Ein inkompatibler Modus führt zum Überschreiben aller Custom-Modi

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-09  ·  **Alt-ID:** N04

**Beleg:** `WhisperM8/Services/Dictation/OutputModeStore.swift:64-69`, `WhisperM8/Services/Dictation/OutputModeStore.swift:118-134`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:45-57`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:204-216`

**Szenario:** OutputModes.json enthält mehrere gültige eigene Modi und einen Eintrag mit einem nicht dekodierbaren Enum-Wert, etwa nach einem Downgrade. Der kollektive Decode scheitert und die UI lädt ausschließlich Built-ins. Die nächste normale Änderung speichert diese Ersatzliste über die Originaldatei und entfernt damit auch sämtliche gültigen Custom-Modi.

**Fix:** Fehlenden Bestand von beschädigtem/inkompatiblem Bestand unterscheiden. Nach Ladefehlern nicht über die Originaldatei speichern; Sicherung und verständlichen Wiederherstellungsweg anbieten. Einträge einzeln validieren, ohne Built-in-Migrationen und gültige Overrides zu verlieren.

### LR-DIK-003 (A1-03) · CLI-Batchausgabe überschreibt vorhandene Dateien ungefragt

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-DIK-11

**Beleg:** `WhisperM8/CLI/CLITranscribe.swift:41-44`, `WhisperM8/CLI/CLITranscribe.swift:254-258`, `WhisperM8/CLI/CLIArguments.swift:23-36`

**Szenario:** Neben meeting.mp3 liegt eine bereits bearbeitete meeting.txt. Bei Transkription mehrerer Eingabedateien bestimmt die CLI automatisch meeting.txt als Ausgabe und ersetzt deren Inhalt ohne Nachfrage oder Force-Option. Auch meeting.wav und meeting.mp3 kollidieren im selben Batch miteinander.

**Fix:** Alle Zielpfade vor dem ersten Schreibzugriff auf Bestandsdateien und gegenseitige Kollisionen prüfen. Standardmäßig abbrechen oder eindeutige Namen verwenden; Überschreiben nur ausdrücklich per Option erlauben. Atomisches Schreiben und unveränderte Quelldateien bleiben Invarianten.

### LR-DIK-004 (A1-04) · Recorderfehler beim Gerätewechsel umgehen die Aufnahmerettung

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-01, F-DIK-05

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:307-312`, `WhisperM8/Services/Dictation/AudioRecorder.swift:346-371`, `WhisperM8/Services/Dictation/AudioRecorder.swift:195-200`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:323-338`

**Szenario:** Nach bereits geschriebenem Audio scheitert beim Gerätewechsel die Formatauflösung oder der Engine-Neustart. AudioRecorder setzt isRecording=false, AppState bleibt jedoch auf Aufnahme. Beim anschließenden Stop liefert der frühe Guard keine Audio-URL; der Coordinator zeigt lediglich „No audio file was created“, statt die vorhandene Teilaufnahme zu retten. Bei Tap-Reinstall-Fehler bleibt sogar das Recorder-Flag auf Aufnahme, obwohl kein Tap mehr läuft.

**Fix:** Recorderfehler über einen eindeutigen Abschlusszustand an den Coordinator melden. Ressourcen und vorhandene Audio-URL unabhängig vom isRecording-Flag finalisieren und Teilaufnahmen dauerhaft sichern. ObjC-Tap-Schutz und Bluetooth-Stabilisierungslogik beibehalten.

### LR-DIK-005 (A1-05) · Veraltete Gerätewechsel-Tasks starten nach Stop erneut

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-01, F-DIK-05  ·  **Alt-ID:** C02

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:268-305`, `WhisperM8/Services/Dictation/AudioRecorder.swift:324-374`, `WhisperM8/Services/Dictation/AudioRecorder.swift:195-227`

**Szenario:** Ein Konfigurationswechsel stoppt die Engine und wartet 300 ms. Währenddessen bricht der Nutzer die Aufnahme ab, gegebenenfalls mit anschließendem Neustart einer Aufnahme. Die alte Fortsetzung prüft weder Aufnahmegeneration noch Engine-Identität erneut und installiert/startet ihre lokal gehaltene alte Engine trotzdem. Bei einem neuen Lauf verändert sie zusätzlich dessen gemeinsame Converter-/Recorder-Felder.

**Fix:** Reconfiguration-Task speichern und bei Stop abbrechen; nach jedem await Aufnahmegeneration, aktive Engine und Abschlusszustand prüfen. Alte Fortsetzungen dürfen weder Tap noch Converter oder Flags eines neuen Laufs verändern. Regressionsprüfung mit Stop/Cancel während Stabilisierung und anschließendem Start.

### LR-DIK-006 (A1-06) · Schreibfehler während der Aufnahme bleiben unsichtbar

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-01

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:515-539`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:45-49`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:150-151`

**Szenario:** Nach einigen erfolgreichen Buffern läuft die Platte voll und AVAudioFile.write wirft. Der Catch protokolliert nach dem ersten erfolgreichen Buffer nicht einmal mehr einen Fehler und informiert den Coordinator nie. Overlay und Timer laufen weiter; beim Stop kann das verkürzte Audio erfolgreich transkribiert und anschließend gelöscht werden. Der Nutzer erfährt nicht, dass ein Teil seines Diktats fehlt.

**Fix:** Den ersten Writer-/Converterfehler speichern und zum Coordinator eskalieren. Aufnahme kontrolliert beenden, vorhandenes Teil-Audio behalten und den Nutzer über die unvollständige Aufnahme informieren. Der Audio-Callback darf dabei nicht selbst modale UI ausführen.

### LR-DIK-007 (A1-07) · Auto-Paste prüft weder Ziel-Fenster noch erfolgreichen Fokuswechsel

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand L · Risiko mittel*

**Features:** F-DIK-01, F-DIK-07  ·  **Alt-ID:** N11

**Beleg:** `WhisperM8/Services/Dictation/PasteService.swift:69-104`, `WhisperM8/Services/Dictation/PasteService.swift:126-143`, `WhisperM8/Services/Dictation/PasteService.swift:169-183`, `WhisperM8/Windows/RecordingPanel.swift:442-444`

**Szenario:** Während der Verarbeitung wechselt der Nutzer im selben Browser oder Messenger in ein anderes Fenster beziehungsweise Gespräch. Gespeichert ist nur das App-Objekt, nicht das ursprüngliche Eingabefeld; Cmd+V trifft das neue Ziel. Scheitert bereits die App-Aktivierung, wird nach dem Timeout ausdrücklich trotzdem global gepastet. Zwischen mehreren Anhängen wird das Ziel ebenfalls nicht erneut geprüft.

**Fix:** PID, Fenster und fokussiertes Eingabeelement als Zustellabsicht erfassen und unmittelbar vor jedem Paste validieren. Bei verändertem oder nicht aktivierbarem Ziel abbrechen und das Ergebnis nur in der Zwischenablage anbieten. Keine Erfolgsbehauptung allein aus erzeugten CGEvents ableiten.

### LR-DIK-008 (A1-08) · Entfernen des Chat-Kontexts lässt den Gesprächsverlauf im Prompt

*P1 · Launch-Blocker · privacy · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-DIK-08, F-DIK-09

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:175-179`, `WhisperM8/Models/PostProcessingTemplate.swift:19-35`, `WhisperM8/Models/PostProcessingTemplate.swift:134-149`, `WhisperM8/Models/TranscriptContextBundle.swift:97-104`

**Szenario:** Der Chat-Tail wurde bereits nachgeladen. Der Nutzer entfernt danach im Overlay den Chat-Kontext und verwendet Fast Prompt, Prompt, Ultra-Prompt oder Task. Entfernt wird ausschließlich agentChat; agentChatTail bleibt erhalten und wird über den Template-Platzhalter weiterhin an Codex gesendet. Ohne andere Inhalte kann die UI dabei sogar keinen Kontext mehr anzeigen.

**Fix:** Beim Entfernen der Chat-Referenz auch deren Tail löschen. Zusätzlich Template-Rendering und Bundle-Normalisierung so absichern, dass ein Tail ohne zugehörige freigegebene Chat-Referenz niemals ausgegeben wird. Das vorhandene Merge-Verhalten für vorzeitig entfernte Referenzen beibehalten.

### LR-DIK-009 (A1-09) · Entfernte Screen-Clips behalten ihre versendbaren Einzelbilder

*P1 · Launch-Blocker · privacy · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-07

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:198-210`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:34-36`, `WhisperM8/Services/Dictation/CodexSupport.swift:100-111`, `WhisperM8/Views/OverlayPhase.swift:140-175`

**Szenario:** Ein Screen-Clip erzeugt bis zu fünf visualFrames. Anschließend entfernt der Nutzer den Clip aus dem Kontext. Die Aktion entfernt nur screenClips; die zugehörigen Frames bleiben in visualFrames und werden weiterhin als Bilder an Codex beziehungsweise die Ziel-App geliefert. Die Kontext-Chip-Segmente zeigen Einzelbilder absichtlich nicht separat und können deshalb „No Ctx“ suggerieren.

**Fix:** Abgeleitete Frames explizit mit der Clip-ID verknüpfen und beim Entfernen des Clips gemeinsam entfernen und gemäß Löschpolicy aufräumen. Unabhängige Screenshots und Frames anderer Clips müssen erhalten bleiben; Anzeige und tatsächlich versendbarer Kontext müssen übereinstimmen.

### LR-DIK-010 (A1-10) · Ein startender Screen-Clip kann den Diktatabbruch überleben

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-07

**Beleg:** `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:130-152`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:169-178`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:469-498`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:9-16`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:47-53`

**Szenario:** Der Nutzer startet einen Clip und bricht das Diktat ab, während makeCaptureTarget oder stream.startCapture noch wartet. cancelActiveClip findet noch keine aktive Session. Die alte Startfortsetzung speichert danach trotzdem die nun laufende Session und setzt den UI-Status. Deren Zeitlimit beendet sich wegen isRecording=false ohne Stop; die Bildschirmaufnahme kann unsichtbar weiterlaufen.

**Fix:** Bereits den Zustand starting exklusiv reservieren und Start-/Stop-Tasks an eine Aufnahmegeneration binden. Nach jedem await erneut prüfen; eine verspätet gestartete Session sofort stoppen. Das harte Zeitlimit muss eine laufende Session unabhängig vom Diktat-UI-Flag beenden.

### LR-DIK-011 (A1-11) · Später Kontext wird verarbeitet, aber nicht zugestellt oder archiviert

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-07, F-DIK-09

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:168-175`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:77-82`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:124-151`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:308-310`

**Szenario:** Der Nutzer kopiert während der Transkription einen Screenshot, wie ausdrücklich unterstützt. processTranscriptIfNeeded verarbeitet das aktualisierte Live-Bundle. Die anschließende Bildzustellung, der Report und cleanup verwenden jedoch weiterhin das beim Stop eingefrorene alte Bundle. Der erzeugte Prompt kann auf ein Bild verweisen, das im Ziel fehlt; der Report dokumentiert den tatsächlich gesendeten Kontext nicht vollständig.

**Fix:** Vor dem Modellaufruf einen einzigen effektiven Kontext-Snapshot festschreiben und für Prompt, Bildinput, Zustellung, Report und Cleanup zurückgeben beziehungsweise weiterreichen. Unterstützte Kopien während der Transkription bleiben erhalten; spätere Kopien benötigen eine explizite Zuordnung statt stiller Vermischung.

### LR-DIK-012 (A1-12) · Gesicherte Aufnahmen haben keinen später erreichbaren Retry-Weg

*P1 · Launch-Blocker · ux · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-01, F-DIK-02

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:31-38`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:45-60`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:81-85`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:97-109`, `WhisperM8/Models/AppState.swift:97-135`

**Szenario:** Eine Transkription scheitert wegen eines falschen Keys. Der Nutzer muss den modalen Fehler schließen, um die Einstellungen zu korrigieren; danach ist die einzige Retry-Aktion nicht mehr erreichbar. Nach ESC während des Uploads gibt es nicht einmal diesen Dialog. pendingRetry ist lediglich flüchtiger Coordinator-Zustand; nach Neustart fehlt auch dieser Bezug zur gespeicherten Aufnahme.

**Fix:** Gesicherte Aufnahmen mit einer sichtbaren Liste und den Aktionen Wiederholen, Exportieren und Löschen zugänglich machen. Benötigte Retry-Metadaten dauerhaft speichern. Die bestehende Count-/Age-Policy beibehalten, aber für Nutzer verständlich erklären.

### LR-DIK-013 (A1-13) · Hängende Codex-Nachbearbeitung hat keine Abschlussgarantie

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-09

**Beleg:** `WhisperM8/Services/Dictation/CodexPostProcessor.swift:102-134`, `WhisperM8/Services/Dictation/CodexSupport.swift:30-39`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:116-117`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:348-363`

**Szenario:** Ein gestarteter Codex-Prozess hängt, etwa in einem Wrapper oder externen Tool, und beendet sich auch auf SIGTERM nicht. performCodexRun wartet unbegrenzt in waitUntilExit. Der Abbruch-Button sendet nur terminate ohne Eskalation; der Coordinator behält isProcessing und lässt keine weitere Aufnahme zu.

**Fix:** Pro Lauf eine Deadline und kooperative Cancellation mit TERM→KILL-Eskalation samt kontrolliertem Pipe-Abschluss implementieren. Danach den vorhandenen Raw-Fallback beziehungsweise Audio-Preserve-Pfad abschließen. Echte Codex-CLI, Sandbox, Modelloptionen und Nutzerabbruch-Semantik erhalten.

### LR-DIK-014 (A1-14) · Parallele Codex-Läufe teilen sich einen falschen Cancel-Slot

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-09

**Beleg:** `WhisperM8/Services/Dictation/CodexSupport.swift:6-48`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:102-106`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:130-134`, `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:111-118`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:370-373`

**Szenario:** Während Diktat A nachbearbeitet wird, startet der Nutzer eine Test-Lab-Preview B. Beide registrieren sich im selben Singleton; B überschreibt current. Der Abbruch im Diktat-Overlay beendet deshalb B statt A. cancelledByUser ist ebenfalls global und kann anschließend das Ergebnis des falschen Laufs als abgebrochen klassifizieren.

**Fix:** Cancellation und Prozessstatus pro Aufruf über eine Run-ID beziehungsweise einen eigenen Handle führen. Overlay und Test Lab müssen jeweils ausschließlich ihren Lauf abbrechen können; Task-Cancellation muss auch den detached Prozesslauf erreichen. Parallele Nutzung nicht still funktional einschränken.

### LR-DIK-015 (A1-15) · Fehlende Codex-CLI führt nur zu einer Hilfeseite statt Installation

*P1 · Launch-Blocker · ux · Konfidenz hoch · Aufwand L · Risiko mittel*

**Features:** F-DIK-09, F-APP-01

**Beleg:** `WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift:32-49`, `WhisperM8/Services/Dictation/CodexSupport.swift:191-204`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:25-29`

**Szenario:** Auf einem frischen Mac fehlt Codex. Die Account-Seite zeigt „Not installed“, bietet aber „Sign In“ an. Die Aktion öffnet lediglich eine externe Hilfeseite; der vorhandene Login-Skriptpfad setzt eine bereits installierte CLI voraus. Ein E-Mail-Lauf scheitert an der Bereitschaftsprüfung und fällt auf Raw zurück, statt W3 ohne Terminal-Nacharbeit zu ermöglichen.

**Fix:** Den Zustand notInstalled mit einem eigenen geführten Installationsschritt über einen offiziellen Installer behandeln, ausdrücklich bestätigt durch den Nutzer; danach Version, Login und Testlauf prüfen. Die echten CLIs bleiben Laufzeitbasis. Mit A5 für Onboarding und gemeinsame Setup-UX abstimmen.

### LR-VG-001 (A1-16) · VoiceGate sperrt Auswertung bei Diktat oder Abschalten nicht sofort

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-VG-01, F-DIK-01

**Beleg:** `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:105-108`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:124-130`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:152-170`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:276-298`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:343-380`, `WhisperM8/Services/VoiceGate/CodexMuteToggler.swift:73-89`

**Szenario:** Direkt nach einer Scharfschaltungsprüfung beginnt ein kurzes Diktat. Bis zum nächsten 10-Sekunden-Tick lauscht VoiceGate weiter; ein im Diktat gesprochenes Codewort kann Codex aktivieren und dessen Mikrofon umschalten. Ebenso können bereits eingeplante Hypothesen oder ein laufender Toggle nach Abschalten weiterwirken: handle und der Tastendruck prüfen weder isEnabled noch den aktuellen Diktatzustand erneut.

**Fix:** VoiceGate synchron vor dem Start des Diktat-Recorders suspendieren. Listener-Start, Hypothesen und Toggle-Tasks an eine cancelbare Generation binden und unmittelbar vor dem Tastendruck Enabled-/Diktat-/Arm-Zustand erneut prüfen. Default-aus und strikt lokale Erkennung erhalten.

### LR-DIK-016 (A1-17) · Clipboard-Fallback überschreibt zwischenzeitliche Nutzerkopien

*P2 · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-06

**Beleg:** `WhisperM8/Services/Dictation/SelectedContextService.swift:76-96`, `WhisperM8/Services/Dictation/SelectedContextService.swift:133-142`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:73-78`

**Szenario:** Im Clipboard-Fallback liegen zwischen Snapshot und Restore mindestens 220 ms Wartezeit. Kopiert der Nutzer währenddessen einen anderen Text, kann dieser als angeblich markierter Kontext gelesen und anschließend durch den alten Snapshot überschrieben werden. Der nachfolgende changeCount-Resync verschluckt zusätzlich die echte Kopie.

**Fix:** Temporären Clipboard-Zugriff mit klarer Eigentümerschaft und Konflikterkennung kapseln; fremde Änderungen dürfen nicht blind restauriert oder als eigene Cmd+C-Antwort importiert werden. Im nicht eindeutig auflösbaren Fall Capture abbrechen und Nutzerinhalt erhalten. AX bleibt der bevorzugte Pfad.

### LR-DIK-017 (A1-18) · Jeder Report-Save durchsucht das gesamte Archiv auf dem MainActor

*P2 · performance · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-01, F-DIK-07, F-DIK-09

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:338-341`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:86-93`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:185-187`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:218-228`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:537-550`

**Szenario:** Bei gefülltem Archiv führt der Abschluss jedes Diktats synchron auf dem MainActor Attachment-Kopien und anschließend Cleanup aus. Cleanup lädt dabei sämtliche Reports erneut und enumeriert deren Dateien für Größenmessungen: beim Produktionslimit bis zu rund 500 JSON-Decodes plus rekursive Datei-Metadatenzugriffe pro Diktat. Größere Kontextdateien erhöhen zusätzlich die synchronen Kopierkosten.

**Fix:** Archivoperationen über eine serialisierte Hintergrund-Komponente abwickeln und das Ergebnis nur zur UI-Aktualisierung zurückmelden. Cleanup inkrementell beziehungsweise gebündelt ausführen und Größenmetadaten führen. Atomische Speicherung, Suchindex, Retention und Archivfunktionen erhalten; konkrete W5-Latenz anschließend messen.

### LR-DIK-018 (A1-19) · Stop wartet bis zu einer Sekunde vor dem eigentlichen Audiostopp

*P2 · Launch-Blocker · performance · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-01, F-DIK-06, F-DIK-08

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:294-323`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:86-95`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:192-225`

**Szenario:** Bei einem kurzen Diktat ist das parallele Kontext-Capture noch nicht abgeschlossen, etwa bei langsamem Transcript-Dateizugriff. Stop wartet bis zu einer Sekunde auf diesen Task, bevor audioRecorder.stopRecording aufgerufen wird. Damit werden sowohl das 300-ms-Budget bis Transkriptionsstart überschritten als auch zusätzliche Audiosamples nach dem Stop-Wunsch aufgenommen. Ein laufender Clip muss davor zusätzlich stoppen und Frames extrahieren.

**Fix:** Audio und Zeitmessung unmittelbar beim akzeptierten Stop schließen. Kontext-/Clip-Finalisierung vom Audiostopp trennen und mit der Transkription parallelisieren; vor Codex den konsistenten Kontext übernehmen. Der Schutz gegen eigene Cmd+C-/Restore-Änderungen muss erhalten bleiben.

### LR-DIK-019 (A1-20) · Löschschalter lässt weitere visuelle Dateikopien bestehen

*P2 · privacy · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-DIK-07

**Beleg:** `WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:44-46`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:181-188`, `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:27-41`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:371-386`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:44-47`

**Szenario:** Der Nutzer aktiviert „Delete visual context files after processing“ und verarbeitet einen vertraulichen Screenshot. cleanup löscht nur die im Bundle referenzierten Originale. Delivery-Kopien bleiben im temporären WhisperM8Delivery-Verzeichnis, Archivkopien samt separater Thumbnail-Kopie unter Reports. Der Schalter erklärt diese verbleibenden Kopien nicht; die Archivpolicy kann sie bis zu 180 Tage behalten.

**Fix:** Die Löschpolicy auch für temporäre Delivery-Kopien zuverlässig umsetzen, unter Berücksichtigung asynchron lesender Ziel-Apps. Archivaufbewahrung ausdrücklich separat erklären und steuerbar machen; nicht still das vorhandene Archivfeature entfernen. Ein Löschwunsch muss alle davon erfassten Kopien erreichen.

### LR-VG-002 (A1-21) · VoiceGate durchsucht bis zu 96 MiB Logs pro Takt auf dem MainActor

*P2 · performance · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-VG-01, F-DIK-01

**Beleg:** `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:13-15`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:105-108`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:152-158`, `WhisperM8/Services/VoiceGate/CodexVoiceSessionProbe.swift:97-118`, `WhisperM8/Services/VoiceGate/CodexVoiceSessionProbe.swift:144-166`

**Szenario:** VoiceGate ist eingeschaltet und Codex läuft mit mehreren großen aktuellen Logdateien. Alle zehn Sekunden ruft der MainActor synchron currentArmState auf. Die Probe liest bis zu zwölfmal acht MiB und zerlegt die Texte in Zeilen, ohne Änderungs-Cache. Diese Arbeit belastet damit auch Diktat-Hotkey, Overlay und übrige App-Interaktionen, obwohl das Labs-Feature nur seinen eigenen Armierungszustand benötigt.

**Fix:** Log-Probe vollständig außerhalb des MainActors ausführen und anhand Dateistempel/Offset inkrementell auswerten. Nur den kleinen Entscheidungssnapshot zurückmelden. Bestehende Altersgrenze, Zeitzonenbehandlung und rein lokale Auswertung erhalten; Main-Thread-Kosten im Lastlauf nachmessen.

## Nicht abgedeckt

- Keine dynamische Verifikation: Builds, Tests, App-Starts, reale Bluetooth-/USB-Wechsel, TCC-Dialoge, Clipboard-Interleavings, Auto-Paste und Latenzmessungen waren ausgeschlossen. Die Szenarien sind statisch aus den Kontrollflüssen abgeleitet, nicht als ausgeführte Reproduktionen zu verstehen.
- Die ausdrücklich ausgeklammerten Agent-Chats-, Workspace-, Grid-/Tab-/Sidebar-, Control-Server-, Chats-CLI- und Plugin-Bereiche wurden nicht geprüft.
- /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/ChatGPTSubscriptionTranscription.swift: Details bei A4; hier ausschließlich die Auswahl-/Aufrufstellen in Provider und Coordinator geprüft.
- VoiceGate nur auf Seiteneffekte geprüft. Matcher, Zustandsmaschine, Locale-Auswahl, Health- und Watchdog-Policy wurden nicht vollständig gelesen oder auf Erkennungsqualität geprüft.
- Overlay-Geometrie, Ausgabe-Detailansichten, TranscriptionAccountControls und die übrigen AIOutput-Modi-/Vorlagen-Seiten wurden nicht vollständig geprüft. Die allgemeinen Settings-UX- und Lokalisierungsfragen liegen bei A5.
- /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/WhisperM8App.swift wurde nur im Termination-/Quit-Auszug gelesen; übrige App-Initialisierung nicht vollständig geprüft.
- CLI-Chunk-Zeitbasis bei Startoffset größer null benötigt einen AVFoundation-Roundtrip. Reader-Zeitbereich und Writer-Sessionbeginn wurden gelesen, aber ohne Laufzeitnachweis kein Timestamp-Finding aufgenommen.
- Juli-Auditmatrizen und Refactoring-Audit nur gezielt nach Dateinamen/Themen durchsucht; Legacy-IDs N02, N04, N11 und C02 zugeordnet. Frühere Format-/installTap-Befunde wurden wegen des inzwischen vorhandenen ObjC-Schutzes nicht ungeprüft wiederholt.
- Keine Markdown-Rohbericht- oder Lagebilddatei erstellt, da die übergeordnete Arbeitsanweisung das Schreiben von Berichtsdateien untersagt. report_path ist daher bewusst leer.

## Gelesene Dateien

84 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `docs/features/dictation/visual-context/README.md`
- `WhisperM8/WhisperM8App.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift`
- `WhisperM8/Services/Dictation/AudioRecorder.swift`
- `WhisperM8/Services/Dictation/AudioDeviceManager.swift`
- `WhisperM8/Services/Dictation/AudioDuckingManager.swift`
- `WhisperM8/Services/Dictation/AudioFormatDecision.swift`
- `WhisperM8/Services/Dictation/AudioLevelMeter.swift`
- `WhisperM8/Services/Dictation/CoreAudioVolumeController.swift`
- `WhisperM8/Services/Dictation/PasteService.swift`
- `WhisperM8/Services/Dictation/SelectedContextService.swift`
- `WhisperM8/Services/Dictation/FailedRecordingsStore.swift`
- `WhisperM8/Services/Dictation/CodexPostProcessor.swift`
- `WhisperM8/Services/Dictation/CodexSupport.swift`
- `WhisperM8/Services/Dictation/CodexStatusCache.swift`
- `WhisperM8/Services/Dictation/CodexErrorSummary.swift`
- `WhisperM8/Services/Dictation/PostProcessingService.swift`
- `WhisperM8/Services/Dictation/PostProcessing.swift`
- `WhisperM8/Services/Dictation/VisualContextCaptureService.swift`
- `WhisperM8/Services/Dictation/ManualScreenClipSession.swift`
- `WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift`
- `WhisperM8/Services/Dictation/ContextCaptureMerge.swift`
- `WhisperM8/Services/Dictation/RecordingTimer.swift`
- `WhisperM8/Services/Dictation/TranscriptionService.swift`
- `WhisperM8/Services/Dictation/TranscriptionProviders.swift`
- `WhisperM8/Services/Dictation/TranscriptionModels.swift`
- `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift`
- `WhisperM8/Services/Dictation/OutputModeStore.swift`
- `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift`
- `WhisperM8/Services/Dictation/ProjectPathResolver.swift`
- `WhisperM8/Services/Dictation/PromptPackageBuilder.swift`
- `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift`
- `WhisperM8/Models/AppState.swift`
- `WhisperM8/Models/OutputMode.swift`
- `WhisperM8/Models/PostProcessingTemplate.swift`
- `WhisperM8/Models/SelectedContext.swift`
- `WhisperM8/Models/TranscriptContextBundle.swift`
- `WhisperM8/Models/TranscriptionProvider.swift`
- `WhisperM8/Models/TranscriptRunReport.swift`
- `WhisperM8/Models/TranscriptRunReportSummary.swift`
- `WhisperM8/Models/CodexPostProcessingModel.swift`
- `WhisperM8/Models/CodexReasoningEffort.swift`
- `WhisperM8/Models/CodexServiceTier.swift`
- `WhisperM8/Models/CodexVisualInputMode.swift`
- `WhisperM8/Models/OutputHistoryFilter.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateListener.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateAudioSource.swift`
- `WhisperM8/Services/VoiceGate/CodexMuteToggler.swift`
- `WhisperM8/Services/VoiceGate/CodexVoiceSessionProbe.swift`
- `WhisperM8/Services/VoiceGate/CodexCommandExecutionProbe.swift`
- `WhisperM8/Windows/RecordingPanel.swift`
- `WhisperM8/Views/RecordingOverlayView.swift`
- `WhisperM8/Views/RecordingPillView.swift`
- `WhisperM8/Views/OverlayPhase.swift`
- `WhisperM8/Views/OverlayScrollers.swift`
- `WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift`
- `WhisperM8/Views/Settings/Models/CodexConnectionModel.swift`
- `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift`
- `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift`
- `WhisperM8/CLI/CLITranscribe.swift`
- `WhisperM8/CLI/CLIAudioChunker.swift`
- `WhisperM8/CLI/CLIAudioExtractor.swift`
- `WhisperM8/CLI/CLIArguments.swift`
- `WhisperM8/CLI/CLIOutputFormatter.swift`
- `Sources/ObjCExceptionBridge/ObjCExceptionBridge.m`
- `Sources/ObjCExceptionBridge/include/ObjCExceptionBridge.h`
- `WhisperM8/Services/Shared/ObjCException.swift`
- `Tests/WhisperM8Tests/RecordingCoordinatorTranscriptionTests.swift`
- `Tests/WhisperM8Tests/RecordingCoordinatorClipboardTests.swift`
- `Tests/WhisperM8Tests/FailedRecordingsStoreTests.swift`
- `Tests/WhisperM8Tests/VisualContextScreenshotTests.swift`
- `Tests/WhisperM8Tests/DictationHotPathTests.swift`
