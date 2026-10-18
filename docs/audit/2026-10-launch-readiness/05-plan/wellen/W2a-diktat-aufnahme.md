---
status: beschlossen
updated: 2026-10-18
description: Welle W2a des Launch-Readiness-Plans — Diktat: Aufnahme retten und sicher einfügen. Befunde, Abnahmekriterien, Tests zuerst.
---

# W2a · Diktat: Aufnahme retten und sicher einfügen

W2 darf nie still Text verlieren: Aufnahme überlebt Gerätewechsel, Ruhezustand und Quit, gesicherte Aufnahmen lassen sich später erneut transkribieren, Auto-Paste landet nur im geprüften Ziel und mit dem richtigen Tastencode.

**Umfang:** 11 Befunde · P1 2, P2 7, P3 2 · 2 Launch-Blocker · Aufwand M×9, L×2

## Abnahmekriterien der Welle

- [ ] Gerätewechsel im Modus „System Default“ und bei fest gewähltem Gerät: Aufnahme läuft weiter oder wird sichtbar gestoppt, Teilaufnahme liegt in FailedRecordings (Tests mit Engine-Fake + QA-4).
- [ ] Gesicherte Aufnahmen haben einen sichtbaren, später erreichbaren Weg „Erneut transkribieren“ (Menüleiste und Einstellungen).
- [ ] Cmd+Q während einer Aufnahme sichert die Datei synchron und schlank (kein langes terminateLater-Gate; Fix-Notiz aus C beachten).
- [ ] Auto-Paste prüft das Ziel nach dem Fokuswechsel; schlägt die Aktivierung fehl, bleibt der Text in der Zwischenablage mit Hinweis statt in einer fremden App (PasteService-Seam).
- [ ] Tastencode für Cmd+V/Cmd+C aus dem aktiven Layout (QA-3 Dvorak).
- [ ] Stop → Transkriptionsstart ≤ 300 ms: Audiostopp wartet nicht auf den Kontext-Capture (Test `testStopStopsAudioBeforeAwaitingContext`).

## Test-Infrastruktur zuerst

- PasteService-Seam (NSWorkspace/CGEvent hinter Protokoll), Recording-Generation für Gerätewechsel-Tasks (Testmatrix Schwäche 4).

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/diktat.md](../../00-scope/oracle/diktat.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-DIK-004 | P1 | ja | M | mittel | geplant · teilbestätigt | Recorderfehler beim Gerätewechsel umgehen die Aufnahmerettung |
| LR-DIK-012 | P1 | ja | M | mittel | geplant · teilbestätigt | Gesicherte Aufnahmen haben keinen später erreichbaren Retry-Weg |
| LR-DIK-001 | P2 | — | L | mittel | geplant · teilbestätigt | Beenden rettet laufende Diktate nicht |
| LR-DIK-005 | P2 | — | M | mittel | geplant · teilbestätigt | Veraltete Gerätewechsel-Tasks starten nach Stop erneut |
| LR-DIK-006 | P2 | — | M | mittel | geplant · teilbestätigt | Schreibfehler während der Aufnahme bleiben unsichtbar |
| LR-DIK-007 | P2 | — | L | mittel | geplant · teilbestätigt | Auto-Paste prüft weder Ziel-Fenster noch erfolgreichen Fokuswechsel |
| LR-DIK-025 | P2 | — | M | mittel | geplant · unverifiziert | Cmd+V und Cmd+C werden als feste US-Tastencodes gesendet und lösen bei Dvorak/Workman andere Kürzel aus |
| LR-DIK-026 | P2 | — | M | mittel | geplant · unverifiziert | Mit fest gewähltem Mikrofon endet die Aufnahme bei Geräteverlust oder Ruhezustand still |
| LR-VG-002 | P2 | — | M | niedrig | geplant · teilbestätigt | VoiceGate durchsucht bis zu 96 MiB Logs pro Takt auf dem MainActor |
| LR-DIK-018 | P3 | — | M | mittel | geplant · teilbestätigt | Stop wartet bis zu einer Sekunde vor dem eigentlichen Audiostopp |
| LR-VG-001 | P3 | — | M | mittel | geplant · teilbestätigt | VoiceGate sperrt Auswertung bei Diktat oder Abschalten nicht sofort |

### LR-DIK-004 · Recorderfehler beim Gerätewechsel umgehen die Aufnahmerettung

*P1 · Launch-Blocker · diktat / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:307-312`, `WhisperM8/Services/Dictation/AudioRecorder.swift:346-371`, `WhisperM8/Services/Dictation/AudioRecorder.swift:195-200`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:323-338` (Stand `a8e0f35`)

**Fehlerbild:** Nach bereits geschriebenem Audio scheitert beim Gerätewechsel die Formatauflösung oder der Engine-Neustart. AudioRecorder setzt isRecording=false, AppState bleibt jedoch auf Aufnahme. Beim anschließenden Stop liefert der frühe Guard keine Audio-URL; der Coordinator zeigt lediglich „No audio file was created“, statt die vorhandene Teilaufnahme zu retten. Bei Tap-Reinstall-Fehler bleibt sogar das Recorder-Flag auf Aufnahme, obwohl kein Tap mehr läuft.

**Fix:** Fix des Finders ist sinnvoll. ObjC-Tap-Schutz (ObjCException.catching) und die Bluetooth-Stabilisierung beibehalten.

*Ursprünglicher Vorschlag:* Recorderfehler über einen eindeutigen Abschlusszustand an den Coordinator melden. Ressourcen und vorhandene Audio-URL unabhängig vom isRecording-Flag finalisieren und Teilaufnahmen dauerhaft sichern. ObjC-Tap-Schutz und Bluetooth-Stabilisierungslogik beibehalten.

**Test zuerst:** AudioRecorder hat keine DI für die Engine, daher Extraktion nötig. Unit-Test auf einer Zustandsmaschine mit Closure-Hooks: nach simuliertem Format-Fehler muss stopRecording() die Teil-URL liefern oder ein Coordinator-Callback feuern. Heute liefert stopRecording() nil.

<details><summary>Prüfurteil</summary>

Der Code-Pfad ist echt: handleConfigurationChange setzt bei ungültigem Format nach 5x100 ms und bei Engine-Restart-Fehler isRecording=false, während AppState.isRecording true bleibt. stopRecording() liefert dann wegen des Guards nil, der Coordinator zeigt „No audio file was created“, und die bereits geschriebene Teilaufnahme liegt unerreichbar im tmp-Verzeichnis. Beim Tap-Reinstall-Fehler bleibt isRecording true, aber ohne Tap. Auslöser ist ein Gerätewechsel mit dauerhaft ungültigem Format (Gerät abgezogen, Bluetooth-Profilwechsel scheitert) und damit seltener Randfall. Der Nutzer verliert ein Diktat und kann es neu sprechen. Das ist kein Absturz, kein stiller Datenverlust über Neustarts und blockiert keinen Nutzerweg. Die Meldung ist irreführend, deshalb P2 statt P3.

</details>

### LR-DIK-012 · Gesicherte Aufnahmen haben keinen später erreichbaren Retry-Weg

*P1 · Launch-Blocker · diktat / ux · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:31-38`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:45-60`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:81-85`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:97-109` (Stand `a8e0f35`)

**Fehlerbild:** Eine Transkription scheitert wegen eines falschen Keys. Der Nutzer muss den modalen Fehler schließen, um die Einstellungen zu korrigieren; danach ist die einzige Retry-Aktion nicht mehr erreichbar. Nach ESC während des Uploads gibt es nicht einmal diesen Dialog. pendingRetry ist lediglich flüchtiger Coordinator-Zustand; nach Neustart fehlt auch dieser Bezug zur gespeicherten Aufnahme.

**Fix:** Vorschlag vertretbar, aber Scope-Erweiterung statt Bugfix. Zunächst reicht ein Menüleisten-Eintrag Letzte Aufnahme erneut transkribieren.

*Ursprünglicher Vorschlag:* Gesicherte Aufnahmen mit einer sichtbaren Liste und den Aktionen Wiederholen, Exportieren und Löschen zugänglich machen. Benötigte Retry-Metadaten dauerhaft speichern. Die bestehende Count-/Age-Policy beibehalten, aber für Nutzer verständlich erklären.

**Test zuerst:** Kein Regressionstest, da fehlende Funktion. Falls umgesetzt: Test, dass FailedRecordingsStore Sidecar-Metadaten (Modus, Sprache) persistiert und nach Neuinstanziierung eine Liste mit Retry-Eintrag liefert.

<details><summary>Prüfurteil</summary>

Stimmt faktisch: pendingRetry ist reiner Coordinator-Speicher, retryPendingTranscription wird nur aus dem NSAlert-Button aufgerufen, und es gibt keine UI zum Listen oder Wiederholen von FailedRecordings. Die Aufnahme wird aber nie gelöscht und liegt in Application Support, der Datenverlust-Schutz greift also. Nach dem ESC-Abbruch ist sie absichtlich still gesichert. Es fehlt eine Komfortfunktion, kein Defekt. Der Nutzer diktiert im schlechtesten Fall neu. Der Alert bietet Retry sofort an. P1/Blocker nicht haltbar, eher Feature-Wunsch.

</details>

### LR-DIK-001 · Beenden rettet laufende Diktate nicht

*P2 · diktat / datenintegritaet · Aufwand L · Risiko mittel*

**Beleg:** `WhisperM8/WhisperM8App.swift:428-450`, `WhisperM8/Services/Dictation/AudioRecorder.swift:132-150`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:23-29` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer beendet die App während einer langen Aufnahme oder eines Uploads. Der Quit-Hook antwortet sofort mit terminateNow; weder Recorder-Finalisierung noch Verschieben in FailedRecordings erfolgen. Die Aufnahme bleibt unregistriert im temporären Verzeichnis und ist nach dem Neustart nicht wiederherstellbar über die App.

**Fix:** Ein asynchrones .terminateLater-Gate ist riskant (verzögert Quit, SIGTERM von make dev, Crash-Marker-Reihenfolge). Besser schlank: beim Quit nur synchron die laufende Datei finalisieren und in den Store verschieben, kein Warten auf Netzwerk.

*Ursprünglicher Vorschlag:* Ein asynchrones Termination-Gate ergänzt den bestehenden Quit-Vertrag: Aufnahme finalisieren, ausstehendes Audio samt Retry-Metadaten dauerhaft sichern und erst danach beenden. Terminal-/Workspace-Sicherung und Ducking-Restore müssen erhalten bleiben; zusätzlich Crash-Recovery für unfertige Diktatläufe vorsehen.

**Test zuerst:** RecordingCoordinator-Test mit injiziertem FailedRecordingsStore: Aufnahme/Transkription im Zustand 'in flight' simulieren, dann die neue Quit-Vorbereitung (z. B. coordinator.prepareForTermination()) aufrufen; erwartet: Audio liegt im FailedRecordings-Ordner mit Sidecar. Heute existiert dieser Einstieg nicht.

**Zusammengeführt mit:** LR-ONB-001

<details><summary>Prüfurteil</summary>

Der Befund stimmt im Kern: applicationShouldTerminate (WhisperM8App.swift:428-441) antwortet sofort mit .terminateNow und tut nichts für eine laufende Aufnahme oder Transkription. Die M4A bleibt im temporaryDirectory (AudioRecorder.swift:133). Der Fall ist aber vom Nutzer selbst ausgelöst (Cmd+Q mitten im Diktat), keine stille Datenvernichtung. Beim Upload ist die Datei bereits fertig geschrieben und liegt noch einige Tage im tmp-Ordner; nur beim Beenden WÄHREND der Aufnahme ist sie wohl unvollständig. Der Datenverlust-Pfad für Fehler (preserveRecording) funktioniert wie dokumentiert. Ein Quit-Gate wäre eine sinnvolle Härtung, aber kein P0 und kein W1–W7-Verstoß.

</details>

### LR-DIK-005 · Veraltete Gerätewechsel-Tasks starten nach Stop erneut

*P2 · diktat / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:268-305`, `WhisperM8/Services/Dictation/AudioRecorder.swift:324-374`, `WhisperM8/Services/Dictation/AudioRecorder.swift:195-227` (Stand `a8e0f35`)

**Fehlerbild:** Ein Konfigurationswechsel stoppt die Engine und wartet 300 ms. Währenddessen bricht der Nutzer die Aufnahme ab, gegebenenfalls mit anschließendem Neustart einer Aufnahme. Die alte Fortsetzung prüft weder Aufnahmegeneration noch Engine-Identität erneut und installiert/startet ihre lokal gehaltene alte Engine trotzdem. Bei einem neuen Lauf verändert sie zusätzlich dessen gemeinsame Converter-/Recorder-Felder.

**Fix:** Task speichern und bei Stop abbrechen, plus Generationszähler nach jedem await prüfen, ist richtig und risikoarm.

*Ursprünglicher Vorschlag:* Reconfiguration-Task speichern und bei Stop abbrechen; nach jedem await Aufnahmegeneration, aktive Engine und Abschlusszustand prüfen. Alte Fortsetzungen dürfen weder Tap noch Converter oder Flags eines neuen Laufs verändern. Regressionsprüfung mit Stop/Cancel während Stabilisierung und anschließendem Start.

**Test zuerst:** AudioRecorder-Test mit injizierbarem Engine-/Sleep-Seam: handleConfigurationChange starten, während des Sleeps stopRecording (und ggf. startRecording) aufrufen; erwartet: kein installTap/start auf der alten Engine und keine Änderung an converter/isRestarting des neuen Laufs. Der Recorder ist heute nicht injizierbar, der Test setzt einen kleinen Seam voraus.

<details><summary>Prüfurteil</summary>

handleConfigurationChange (AudioRecorder.swift:~268-374) hält die lokale Engine über den 300-ms-Sleep (und die Format-Retries) und prüft danach weder isRecording noch die Engine-Identität. Stoppt der Nutzer in dem Fenster, installiert und startet die alte Engine trotzdem; da stopRecording audioFile/converter schon auf nil gesetzt hat, schreibt sie nichts. Die lokale Engine wird nach Funktionsende freigegeben und damit gestoppt, der Effekt ist also kurz. Schädlich ist nur Stop plus sofortiger Neustart innerhalb dieses Fensters (Converter/Flags des neuen Laufs werden überschrieben). Das braucht einen Gerätewechsel (Bluetooth) und exakt getimtes Stoppen. Echte Race, aber schmal und ohne Absturz oder Verlust.

</details>

### LR-DIK-006 · Schreibfehler während der Aufnahme bleiben unsichtbar

*P2 · diktat / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:515-539`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:45-49`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:150-151` (Stand `a8e0f35`)

**Fehlerbild:** Nach einigen erfolgreichen Buffern läuft die Platte voll und AVAudioFile.write wirft. Der Catch protokolliert nach dem ersten erfolgreichen Buffer nicht einmal mehr einen Fehler und informiert den Coordinator nie. Overlay und Timer laufen weiter; beim Stop kann das verkürzte Audio erfolgreich transkribiert und anschließend gelöscht werden. Der Nutzer erfährt nicht, dass ein Teil seines Diktats fehlt.

**Fix:** Der Audio-Callback darf nur ein Flag setzen und die UI-Eskalation asynchron auf Main auslösen, wie der Finder schon schreibt.

*Ursprünglicher Vorschlag:* Den ersten Writer-/Converterfehler speichern und zum Coordinator eskalieren. Aufnahme kontrolliert beenden, vorhandenes Teil-Audio behalten und den Nutzer über die unvollständige Aufnahme informieren. Der Audio-Callback darf dabei nicht selbst modale UI ausführen.

**Test zuerst:** Nur mit einer Writer-Abstraktion testbar: AudioRecorder bekommt einen injizierbaren Schreib-Closure, der nach N Buffern wirft. Erwartet: ein onWriteFailure-Callback feuert genau einmal. Heute gibt es den Callback nicht.

<details><summary>Prüfurteil</summary>

Der Catch in writeBuffer loggt nach dem ersten erfolgreichen Buffer nichts mehr und meldet nie an den Coordinator; auch Converter-Statusfehler werden still verworfen. Auslöser ist aber ein volles Laufwerk oder ein Schreibfehler mitten in der Aufnahme. M4A mit 16 kHz mono ist winzig (etwa 1 MB pro Minute), ein realistischer Auslöser fehlt also fast völlig. Folge wäre ein verkürztes Diktat ohne Hinweis, kein Absturz und kein Verlust bestehender Daten.

</details>

### LR-DIK-007 · Auto-Paste prüft weder Ziel-Fenster noch erfolgreichen Fokuswechsel

*P2 · diktat / korrektheit · Aufwand L · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/PasteService.swift:69-104`, `WhisperM8/Services/Dictation/PasteService.swift:126-143`, `WhisperM8/Services/Dictation/PasteService.swift:169-183`, `WhisperM8/Windows/RecordingPanel.swift:442-444` (Stand `a8e0f35`)

**Fehlerbild:** Während der Verarbeitung wechselt der Nutzer im selben Browser oder Messenger in ein anderes Fenster beziehungsweise Gespräch. Gespeichert ist nur das App-Objekt, nicht das ursprüngliche Eingabefeld; Cmd+V trifft das neue Ziel. Scheitert bereits die App-Aktivierung, wird nach dem Timeout ausdrücklich trotzdem global gepastet. Zwischen mehreren Anhängen wird das Ziel ebenfalls nicht erneut geprüft.

**Fix:** Die Fix-Variante 'Fenster/Eingabeelement erfassen und vor jedem Paste validieren' (Schwere L) ist überdimensioniert und riskant (AX-Zugriff, Apps ohne AX). Sinnvoll ist nur: nach Aktivierungs-Timeout nicht pasten, sondern per Hinweis auf die Zwischenablage verweisen.

*Ursprünglicher Vorschlag:* PID, Fenster und fokussiertes Eingabeelement als Zustellabsicht erfassen und unmittelbar vor jedem Paste validieren. Bei verändertem oder nicht aktivierbarem Ziel abbrechen und das Ergebnis nur in der Zwischenablage anbieten. Keine Erfolgsbehauptung allein aus erzeugten CGEvents ableiten.

**Test zuerst:** PasteService mit injizierbarem frontmost-Provider: Aktivierung scheitert (frontmost != targetApp nach Timeout); erwartet: kein postPasteEvent, onMissingTarget wird gerufen, Text nur in der Zwischenablage. Heute wird trotzdem gepastet.

**Zusammengeführt mit:** LR-DIK-022

<details><summary>Prüfurteil</summary>

Der Code stimmt mit der Beschreibung überein: PasteService merkt nur NSRunningApplication (RecordingPanel.swift:442-444), aktiviert sie, wartet höchstens 1 s und pastet danach 'anyway' (PasteService.swift:126-143). Das ist aber die bewusste Diktat-Semantik (Text kommt in die vorher aktive App), und der Text liegt zusätzlich immer in der Zwischenablage (RecordingCoordinator+Transcription.swift: copyToClipboard vor dem Paste). Ein Fenster-/Gesprächswechsel innerhalb derselben App während der Verarbeitung ist ein Randfall, bei dem der Text eher dort landet, wo der Nutzer gerade ist. Echtes Restrisiko: scheitert die Aktivierung (App beendet, Fokus anderswo), geht Cmd+V an die zufällige Frontmost-App. Das ist ein Korrektheits-/UX-Thema, kein Datenverlust.

</details>

### LR-DIK-025 · Cmd+V und Cmd+C werden als feste US-Tastencodes gesendet und lösen bei Dvorak/Workman andere Kürzel aus

*P2 · diktat / korrektheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/PasteService.swift:169-183`, `WhisperM8/Services/Dictation/SelectedContextService.swift:99-113`, `WhisperM8/Services/VoiceGate/CodexMuteToggler.swift:48` (Stand `a8e0f35`)

**Fehlerbild:** Auto-Paste erzeugt ein CGEvent mit virtualKey kVK_ANSI_V (Tastencode 9) plus Cmd, die Kontexterfassung eines mit kVK_ANSI_C (Code 8). Apps lösen Menükürzel über das Zeichen des aktiven Layouts auf. Unter Dvorak liegt an Code 9 ein K und an Code 8 ein J: Auto-Paste sendet Cmd+K (Slack-Schnellsuche, Link einfügen, Browser-Suchfeld), die Kontexterfassung Cmd+J (Downloads in Chrome). Unter Workman ist Code 9 ein C, Auto-Paste kopiert also statt einzufügen. Das Diktat erscheint nicht, stattdessen passiert eine fremde Aktion. QWERTZ und AZERTY sind nicht betroffen. Es gibt keine Layout-Abfrage (TISCopyCurrentKeyboardLayoutInputSource/UCKeyTranslate, grep ohne Treffer).

**Fix:** Den Tastencode für "v" bzw. "c" zur Laufzeit über UCKeyTranslate aus dem aktiven ASCII-fähigen Layout ermitteln (Fallback kVK_ANSI_V), wie es etablierte Clipboard-Tools tun. Alternativ beim Einfügen das Menü-Item Bearbeiten > Einsetzen per AX auslösen.

**Test zuerst:** Reiner KeyCodeResolver mit injizierter Layout-Übersetzung: Dvorak liefert für „v“ den Code 47, QWERTZ/QWERTY 9; Fallback kVK_ANSI_V, wenn das Layout nicht ASCII-fähig ist.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-DIK-026 · Mit fest gewähltem Mikrofon endet die Aufnahme bei Geräteverlust oder Ruhezustand still

*P2 · diktat / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:66-71`, `WhisperM8/Services/Dictation/AudioRecorder.swift:236-257`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:66-77` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer hat in den Einstellungen ein bestimmtes Eingabegerät gewählt (USB-Headset, externes Mikrofon, eingebautes Mikrofon). setupConfigurationObserver bricht für alles außer System Default sofort ab, es gibt also keinen Beobachter für AVAudioEngineConfigurationChange. Wird das Gerät während der Aufnahme abgezogen, wechselt die Bluetooth-Route oder klappt der Mac zu und wacht wieder auf, stoppt AVAudioEngine von selbst. Overlay und Timer laufen weiter, der Rest des Diktats wird nicht aufgenommen; beim Stop wird nur der Anfang transkribiert. Kein Hinweis an den Nutzer. Es gibt außerdem keinen Sleep/Wake-Beobachter (grep auf willSleep/didWake ohne Treffer).

**Fix:** Den Konfigurationsbeobachter für alle Modi installieren. Bei Verlust des gewählten Geräts kontrolliert auf System Default wechseln oder die Aufnahme sichtbar stoppen und die Teilaufnahme über FailedRecordingsStore retten. Engine-Laufzustand im Pegel-Timer prüfen.

**Test zuerst:** AudioRecorder-Test mit Engine-Fake: bei fest gewähltem Gerät löst eine ConfigurationChange-Notification Rettung oder Wechsel aus; Engine-stopped im Pegel-Timer beendet die Aufnahme sichtbar und sichert die Teilaufnahme.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-VG-002 · VoiceGate durchsucht bis zu 96 MiB Logs pro Takt auf dem MainActor

*P2 · voicegate / performance · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:13-15`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:105-108`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:152-158`, `WhisperM8/Services/VoiceGate/CodexVoiceSessionProbe.swift:97-118` (Stand `a8e0f35`)

**Fehlerbild:** VoiceGate ist eingeschaltet und Codex läuft mit mehreren großen aktuellen Logdateien. Alle zehn Sekunden ruft der MainActor synchron currentArmState auf. Die Probe liest bis zu zwölfmal acht MiB und zerlegt die Texte in Zeilen, ohne Änderungs-Cache. Diese Arbeit belastet damit auch Diktat-Hotkey, Overlay und übrige App-Interaktionen, obwohl das Labs-Feature nur seinen eigenen Armierungszustand benötigt.

**Fix:** Log-Probe vollständig außerhalb des MainActors ausführen und anhand Dateistempel/Offset inkrementell auswerten. Nur den kleinen Entscheidungssnapshot zurückmelden. Bestehende Altersgrenze, Zeitzonenbehandlung und rein lokale Auswertung erhalten; Main-Thread-Kosten im Lastlauf nachmessen.

**Test zuerst:** In CodexVoiceSessionProbe einen tailReader-Closure-Zähler injizieren. Zweimal lastRealtimeSessionStart() mit unveränderter 8-MiB-Logdatei im Temp-logRoot aufrufen. Erwartung: ein Lesevorgang, denn der zweite Aufruf trifft den mtime/size-Cache. Heute sind es zwei. Dazu ein Test mit einer 9-MiB-Datei, bei der ein 'ä' genau auf der 8-MiB-Grenze liegt und der Marker am Ende steht. Erwartung: Datum gefunden. Heute nil.

### LR-DIK-018 · Stop wartet bis zu einer Sekunde vor dem eigentlichen Audiostopp

*P3 · diktat / performance · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:294-323`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:86-95`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:192-225` (Stand `a8e0f35`)

**Fehlerbild:** Bei einem kurzen Diktat ist das parallele Kontext-Capture noch nicht abgeschlossen, etwa bei langsamem Transcript-Dateizugriff. Stop wartet bis zu einer Sekunde auf diesen Task, bevor audioRecorder.stopRecording aufgerufen wird. Damit werden sowohl das 300-ms-Budget bis Transkriptionsstart überschritten als auch zusätzliche Audiosamples nach dem Stop-Wunsch aufgenommen. Ein laufender Clip muss davor zusätzlich stoppen und Frames extrahieren.

**Fix:** Audio und Zeitmessung unmittelbar beim akzeptierten Stop schließen. Kontext-/Clip-Finalisierung vom Audiostopp trennen und mit der Transkription parallelisieren; vor Codex den konsistenten Kontext übernehmen. Der Schutz gegen eigene Cmd+C-/Restore-Änderungen muss erhalten bleiben.

**Test zuerst:** Den RecordingCoordinator mit einem Capture-Task-Stub testen, der 800 ms schläft. Der Stop-Pfad muss audioRecorder.stopRecording (Spy) sofort aufrufen und erst danach auf den Kontext warten. Heute liegt der Aufruf erst nach etwa 800 ms.

### LR-VG-001 · VoiceGate sperrt Auswertung bei Diktat oder Abschalten nicht sofort

*P3 · voicegate / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:105-108`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:124-130`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:152-170`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:276-298` (Stand `a8e0f35`)

**Fehlerbild:** Direkt nach einer Scharfschaltungsprüfung beginnt ein kurzes Diktat. Bis zum nächsten 10-Sekunden-Tick lauscht VoiceGate weiter; ein im Diktat gesprochenes Codewort kann Codex aktivieren und dessen Mikrofon umschalten. Ebenso können bereits eingeplante Hypothesen oder ein laufender Toggle nach Abschalten weiterwirken: handle und der Tastendruck prüfen weder isEnabled noch den aktuellen Diktatzustand erneut.

**Fix:** Billiger Fix: Guard auf isEnabled und AppState.shared.isRecording in handle() und performPress. Default-aus und on-device-Erkennung unverändert lassen.

*Ursprünglicher Vorschlag:* VoiceGate synchron vor dem Start des Diktat-Recorders suspendieren. Listener-Start, Hypothesen und Toggle-Tasks an eine cancelbare Generation binden und unmittelbar vor dem Tastendruck Enabled-/Diktat-/Arm-Zustand erneut prüfen. Default-aus und strikt lokale Erkennung erhalten.

**Test zuerst:** Gate-Coordinator-Test mit Fake-Probe und Fake-Toggler: isEnabled=false setzen, danach handle() mit passender Hypothese. Erwartet: toggler.toggle() wird nicht aufgerufen. Für den Diktat-Fall AppState.isRecording=true plus passende Hypothese: erwartet kein Press. Heute nur durch Listener-Stopp-Reihenfolge abgedeckt, nicht durch einen Guard.

<details><summary>Prüfurteil</summary>

refreshArmState läuft nur im 10-s-Takt, ein Diktatstart pausiert den Listener also erst beim nächsten Tick. Auch handle() und performPress prüfen weder isEnabled noch Diktatzustand erneut. Technisch richtig. Voraussetzungen sind aber: Feature opt-in (Default aus, Labs), Codex-Desktop mit scharfer Sprachsitzung, manuelle Kürzel-Einrichtung, und der Nutzer sagt genau im Diktat das Codewort. Folge ist ein ungewollter Mute-Toggle in Codex, kein Datenverlust und keine Sicherheitslücke. Labs-Regel: nur relevant bei Gefährdung von Kern, Daten oder Sicherheit, das ist hier nicht der Fall.

</details>
