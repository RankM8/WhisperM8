---
status: abgeschlossen
updated: 2026-07-18
description: Vollständiges Referenzinventar der sichtbaren Funktionen und Erhaltungsinvarianten der Diktat-Hälfte vor den geplanten Refactor-Wellen.
---

# Feature-Inventar Diktat

## Zweck und Leseregel

Dieses Dokument beschreibt den Produktstand der gesamten Diktat-Hälfte von WhisperM8. Es ist kein Soll-Konzept und keine Qualitätsbewertung, sondern ein Regressions-Oracle: Eine Roadmap-Maßnahme darf die hier belegten Nutzerfunktionen und Invarianten nicht unbeabsichtigt verändern.

- **Einstiegspunkt** nennt den produktiven Einstieg als `Datei:Zeile`; ergänzende Belege folgen bei Bedarf.
- **Sichtbares Verhalten** beschreibt, was ein Nutzer tatsächlich sieht oder auslösen kann.
- **Erhaltungsinvarianten** enthalten auch bewusst ungewöhnliche Guards, Fallbacks und Workarounds. Ein Punkt ist nicht deshalb entbehrlich, weil er wie ein Bug wirkt.
- **Roadmap-Bezug** ordnet bestätigte Findings `C01–C16`/`N01–N16` und Maßnahmen aus `05-roadmap/refactor-roadmap.md` zu. „Kein eigener Finding“ bedeutet: allgemeines Ship-/Regression-Gate.

## 1. Trigger, Aufnahme und sichtbarer Lifecycle

### DI-01 · Globaler Aufnahme-Hotkey mit Tap-to-toggle-Semantik

- **Funktion:** Registriert einen globalen `KeyboardShortcuts`-Shortcut; `keyDown` startet und `keyUp` stoppt auf dem Main Actor (`WhisperM8/WhisperM8App.swift:101`, `WhisperM8/WhisperM8App.swift:108`).
- **Einstiegspunkt:** `WhisperM8/WhisperM8App.swift:101`, `WhisperM8/Models/AppState.swift:97`.
- **Sichtbares Verhalten:** Ein kurzer Tastendruck startet die Aufnahme; der nächste Tastendruck beendet und transkribiert sie. Das Onboarding beschreibt genau diese Bedienung und lässt den Shortcut konfigurieren (`WhisperM8/Views/OnboardingView.swift:523`, `WhisperM8/Views/OnboardingView.swift:531`).
- **Erhaltungsinvarianten:** Ein Stop weniger als 0,3 Sekunden nach Start wird absichtlich ignoriert. Dieser Guard darf nicht in „kurze Aufnahme verwerfen“ umgedeutet werden, weil sonst das Tap-to-toggle-Verhalten wieder bricht (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:259`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 0 `W0.1` und Welle 4 `P2.5+P2.6` müssen Hotkey-Dispatch, MainActor-Handoff und Tap-Semantik unverändert halten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-02 · Serialisierter Aufnahme-Lifecycle und öffentliche Phasen

- **Funktion:** `RecordingCoordinator` orchestriert Start, Stop, Transkription, Post-Processing und Delivery; `AppState` projiziert den beobachtbaren Zustand in `idle`, `recording`, `transcribing` und `postProcessing` (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:25`, `WhisperM8/Models/AppState.swift:3`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:106`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:244`.
- **Sichtbares Verhalten:** Wiederholte Start-/Stop-Ereignisse während eines laufenden Übergangs werden ignoriert; Status, Menüleisten-Icon und Overlay folgen den öffentlichen Flags (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:106`, `WhisperM8/Models/AppState.swift:54`).
- **Erhaltungsinvarianten:** `isProcessing`, `transcriptionTask` und `isDeliveringTranscription` sind zusätzliche Reentranz-Gates. Die sichtbaren Booleans allein sind keine vollständige Zustandsmaschine; insbesondere ist Delivery intern busy, obwohl die sichtbaren Busy-Flags schon false sein können (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:38`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:174`).
- **Roadmap-Bezug:** Welle 0 `W0.1` als Oracle-Baseline und Welle 4 `P2.5+P2.6` für den späteren Dictation-Target-Schnitt; keine Phase oder Guard-Reihenfolge darf dabei still verschwinden (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-03 · Aufnahme-Intent mit Quell-App und aktivem Agent-Fenster

- **Funktion:** Friert beim Aufnahmestart die vorderste App ein und übernimmt einen Agent-Chat nur, wenn WhisperM8 selbst vorderste App und ein Agent-Chat-Fenster Key-Window war (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:118`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:120`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:118`.
- **Sichtbares Verhalten:** Diktat aus Browser, Editor oder anderer App erbt keinen zufällig zuletzt ausgewählten Chat. In einem aktiven Agent-Chat zeigt das Overlay dagegen „Chat“ als Kontext (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:125`, `WhisperM8/Models/AppState.swift:45`).
- **Erhaltungsinvarianten:** Settings- und Onboarding-Fenster dürfen den letzten Chat nicht als Diktatkontext erben; Quell-App und Chat-Intent müssen bis Prompt und Auslieferung demselben Lauf zugeordnet bleiben (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:120`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:172`).
- **Roadmap-Bezug:** `N11`; Welle 2 `R2.6` erweitert genau diesen Aufnahme-Intent um Ziel-Fenster-/Session-Identität und Paste-Policy (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`).

### DI-04 · Eingabegeräte-Auswahl und Default-Geräte-Fallback

- **Funktion:** Inventarisiert CoreAudio-Eingabegeräte, persistiert eine UID-Auswahl und beobachtet Geräte- sowie Default-Geräte-Wechsel (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:45`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:55`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:178`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/AudioDeviceManager.swift:113`, `WhisperM8/Views/MenuBarView.swift:71`.
- **Sichtbares Verhalten:** Nutzer wählen in der Menüleiste „System Default“ oder ein verfügbares Mikrofon; verschwindet das gewählte Gerät, fällt die Aufnahme auf System Default zurück (`WhisperM8/Views/MenuBarView.swift:72`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:73`).
- **Erhaltungsinvarianten:** Bluetooth-Geräte werden für die HFP-Umschaltung bewusst über System Default statt durch erzwungene Device-ID gebunden; dieser Fallback ist Teil der Gerätekompatibilität (`WhisperM8/Services/Dictation/AudioDeviceManager.swift:79`).
- **Roadmap-Bezug:** `C01–C03`; Welle 1 `P0.1+P0.2`, Welle 2 `P0.3` und Welle 5 `P2.8b` schützen Gerätewahl, Hotplug und Bluetooth-Profilwechsel (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:65`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:188`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-05 · Mikrofonaufnahme als 16-kHz-Mono-M4A

- **Funktion:** Fordert Mikrofonzugriff an, bindet das Eingabegerät, validiert das Hardwareformat, konvertiert bei Bedarf und schreibt AAC/M4A mit 16 kHz Mono (`WhisperM8/Services/Dictation/AudioRecorder.swift:53`, `WhisperM8/Services/Dictation/AudioRecorder.swift:101`, `WhisperM8/Services/Dictation/AudioRecorder.swift:122`, `WhisperM8/Services/Dictation/AudioRecorder.swift:132`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/AudioRecorder.swift:33`.
- **Sichtbares Verhalten:** Eine Aufnahme beginnt erst sichtbar, nachdem `engine.start()` erfolgreich war; Startfehler erscheinen als `lastError`, ohne ein falsches Recording-Overlay zu zeigen (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:147`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:151`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:162`).
- **Erhaltungsinvarianten:** Genau ein Tap auf Input-Bus 0; Tap-Format, Converter-Input und aktuelles Hardwareformat müssen zusammenpassen; Stop entfernt den Tap vor `engine.stop()` (`WhisperM8/Services/Dictation/AudioRecorder.swift:359`, `WhisperM8/Services/Dictation/AudioRecorder.swift:182`).
- **Roadmap-Bezug:** `C01`, `C02`; Welle 1 `P0.1+P0.2` macht Tap/Format/Reconfiguration fail-closed, Welle 5 `P2.8b` verlangt AVAudioEngine als erhaltenen Fallback (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:65`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-06 · Live-Pegel und Aufnahmedauer

- **Funktion:** Berechnet im Audio-Tap einen normalisierten Pegel und aktualisiert Pegel, Dauer und Overlay alle 100 Millisekunden (`WhisperM8/Services/Dictation/AudioRecorder.swift:372`, `WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift:67`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift:67`, `WhisperM8/Views/RecordingPillView.swift:212`.
- **Sichtbares Verhalten:** Die Pill zeigt eine reagierende Waveform beziehungsweise Kernanimation und eine formatierte Laufzeit während der Aufnahme (`WhisperM8/Views/RecordingPillView.swift:220`, `WhisperM8/Views/RecordingPillView.swift:365`).
- **Erhaltungsinvarianten:** Der Realtime-Audio-Callback darf nicht auf den Main Actor warten; nur die UI-Publikation wird zum Main Actor übergeben (`WhisperM8/Services/Dictation/AudioRecorder.swift:372`, `WhisperM8/Services/Dictation/AudioRecorder.swift:386`).
- **Roadmap-Bezug:** `C03`; Welle 2 `P0.3` nennt Pegel- und Latenz-QA ausdrücklich und verbietet blockierendes MainActor-Warten im Audio-Callback (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:188`).

### DI-07 · Audio-Ducking mit Multi-Device-Restore

- **Funktion:** Erfasst vor dem Engine-Start die aktuelle Ausgabelautstärke, senkt sie konfigurierbar ab, verfolgt Routingwechsel und stellt alle erfassten Geräte wieder her (`WhisperM8/Services/Dictation/AudioDuckingManager.swift:92`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:127`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:256`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:142`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:95`.
- **Sichtbares Verhalten:** Systemaudio wird während der Aufnahme leiser und nach Stop, Cancel, Startfehler oder App-Quit wiederhergestellt; Stärke und Aktivierung sind einstellbar (`WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift:55`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:309`, `WhisperM8/WhisperM8App.swift:354`).
- **Erhaltungsinvarianten:** Der Volume-Snapshot muss vor einem Bluetooth-A2DP→HFP-Wechsel entstehen; `beginCapture`/`endCapture` sind idempotent und Ducking umschließt die Engine-Lebensdauer. Eine manuelle Lautstärkeänderung während der Aufnahme wird am Ende bewusst trotzdem auf den Originalwert zurückgesetzt: macOS liefert kein zuverlässiges Signal zur Unterscheidung von User-Änderung und BT-Profilwechsel, und ein unterbliebener Restore wiegt schwerer (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:142`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:16`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:29`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:106`, `WhisperM8/Services/Dictation/AudioDuckingManager.swift:130`).
- **Roadmap-Bezug:** `C01–C03`; Welle 1 `P0.1+P0.2`, Welle 2 `P0.3` und Welle 5 `P2.8b` müssen Ducking und Routing-Parität erhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:65`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:188`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-08 · Nicht-aktivierendes Recording-Panel und Phasenanzeige

- **Funktion:** Zeigt ein borderless, nicht aktivierendes Floating-Panel auf allen Spaces mit Phase, Pegel, Dauer, Output-Modus, Kontext und Aktionen (`WhisperM8/Windows/RecordingPanel.swift:169`, `WhisperM8/Windows/RecordingPanel.swift:180`, `WhisperM8/Views/RecordingPillView.swift:28`).
- **Einstiegspunkt:** `WhisperM8/Windows/RecordingPanel.swift:429`, `WhisperM8/Views/RecordingPillView.swift:33`.
- **Sichtbares Verhalten:** Recording, Transcribing und Improving besitzen unterschiedliche Farbe/Animation und kontextsensitive Abbruch-Hilfen; Output-Auswahl ist in Busy-Phasen gesperrt (`WhisperM8/Views/OverlayPhase.swift:9`, `WhisperM8/Views/RecordingPillView.swift:104`, `WhisperM8/Views/RecordingPillView.swift:624`).
- **Erhaltungsinvarianten:** Das Panel darf beim Anzeigen nicht die Ziel-App aktivieren; die vorherige App wird vor dem Panel-Aufbau gespeichert und später für Auto-Paste verwendet (`WhisperM8/Windows/RecordingPanel.swift:443`, `WhisperM8/Windows/RecordingPanel.swift:612`).
- **Roadmap-Bezug:** `N11`; Welle 2 `R2.6` ersetzt die schwache App-Referenz durch einen geprüften Aufnahme-Intent, ohne das nicht-aktivierende Overlay oder den Happy-Path zu verlieren (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`).

### DI-09 · Full-/Mini-Pill, Hover-Expansion und persistente Position

- **Funktion:** Unterstützt eine permanent erweiterte Full-Pill und eine Mini-Pill, die per Hover mit Grace-Period expandiert; die ganze Pill ist ziehbar und ein Doppelklick setzt sie auf die Standardposition zurück (`WhisperM8/Views/RecordingPillView.swift:35`, `WhisperM8/Views/RecordingPillView.swift:182`, `WhisperM8/Windows/RecordingPanel.swift:827`).
- **Einstiegspunkt:** `WhisperM8/Windows/RecordingPanel.swift:43`, `WhisperM8/Windows/RecordingPanel.swift:478`.
- **Sichtbares Verhalten:** Nutzer können Stil und Position ändern; die Position bleibt über Aufnahmen erhalten und wird auf Multi-Monitor-Setups in den passenden Screen geklemmt (`WhisperM8/Windows/RecordingPanel.swift:478`, `WhisperM8/Windows/RecordingPanel.swift:223`).
- **Erhaltungsinvarianten:** Nur echte User-Drags erzeugen eine Custom-Position; Default-Positionen werden nicht versehentlich persistiert. Offene Menüs halten Mini expandiert, und Reset darf nicht durch normalen Mouse-up ausgelöst werden. Nachzentrieren ist absichtlich nur kurz nach einem expliziten Doppelklick-Reset erlaubt: Organische Breitenänderungen durch nachgereichten Kontext lassen die Pill liegen, weil das Nachrücken während der Transkription störender ist als leichter Drift (`WhisperM8/Windows/RecordingPanel.swift:403`, `WhisperM8/Windows/RecordingPanel.swift:409`, `WhisperM8/Windows/RecordingPanel.swift:415`, `WhisperM8/Windows/RecordingPanel.swift:420`, `WhisperM8/Windows/RecordingPanel.swift:497`).
- **Roadmap-Bezug:** Kein eigener Finding; allgemeines UI-Regression-Gate für Welle 4 `P2.5+P2.6` und `P2.7` (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:417`).

### DI-10 · Phasengerechte Stop- und Abbruchaktionen

- **Funktion:** ✓ stoppt Recording und startet Transkription; ✕/ESC verwirft Recording, cancelt einen laufenden Upload oder beendet Codex-Post-Processing mit Raw-Fallback (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:195`, `WhisperM8/Views/RecordingPillView.swift:624`, `WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift:32`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:348`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:357`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:448`.
- **Sichtbares Verhalten:** ESC während Recording löscht die temporäre Aufnahme; ESC während Upload sichert sie als fehlgeschlagenen Lauf; Abbruch während Improving liefert das Raw-Transkript ohne zusätzliche Fehlermeldung (`WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift:38`, `WhisperM8/Services/Dictation/RecordingCoordinator+UI.swift:45`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:204`).
- **Erhaltungsinvarianten:** Nach eingetroffener Transkriptionsantwort ist Cancel ein No-op, damit Paste-Delays und CGEvent-Reihenfolge nicht durch Task-Cancellation kollabieren (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:357`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:39`).
- **Roadmap-Bezug:** Welle 0 `W0.1` als Lifecycle-Oracle; Welle 1 `P0.1+P0.2` muss Cancel an jedem Reconfiguration-Suspension-Point recoverbar halten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:65`).

### DI-11 · Stop-Commit mit eingefrorenem Modus und Basiskontext

- **Funktion:** Stop beendet einen aktiven Screen-Clip, wartet begrenzt auf den parallelen Kontext-Task, führt einen letzten Clipboard-Sweep aus und friert Dauer, Output-Modus und Kontext für den Lauf ein (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:275`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:279`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:289`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:244`.
- **Sichtbares Verhalten:** Ein während der Aufnahme gewählter Modus und vorgenommene Kontext-Edits gelten für genau diesen Lauf, auch wenn globale Settings danach wechseln (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:289`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:324`).
- **Erhaltungsinvarianten:** Kontext-Warten ist auf eine Sekunde begrenzt; der finale Sweep kommt erst danach, damit interne Cmd+C-/Restore-Änderungen nicht als Nutzerkontext importiert werden. Der aktuelle Split ist ausdrücklich zu beachten: Codex liest danach das Live-Bundle, Attachment-Paste, Report und Cleanup weiterhin das beim Stop eingefrorene Bundle; eine Vereinheitlichung ist eine bewusste Verhaltensänderung, kein mechanischer Move (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:279`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:82`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:156`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:65`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:112`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 0 `W0.1` und Welle 4 `P2.5+P2.6` müssen Snapshot- und Ordering-Vertrag als Golden-Flow halten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

## 2. Kontext-Erfassung und visuelle Anhänge

### DI-12 · Ausgewählten Text per Accessibility mit Clipboard-Fallback erfassen

- **Funktion:** Liest zuerst `kAXSelectedTextAttribute`; falls das nicht gelingt, aktiviert es bei erteilter Accessibility-Berechtigung die Quell-App und sendet Cmd+C (`WhisperM8/Services/Dictation/SelectedContextService.swift:8`, `WhisperM8/Services/Dictation/SelectedContextService.swift:42`, `WhisperM8/Services/Dictation/SelectedContextService.swift:76`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/SelectedContextService.swift:9`.
- **Sichtbares Verhalten:** Markierter Text aus der beim Start aktiven App erscheint automatisch als Kontext; ohne Permission oder Auswahl läuft Diktat ohne Fehler mit leerem Textkontext weiter (`WhisperM8/Services/Dictation/SelectedContextService.swift:16`, `WhisperM8/Services/Dictation/SelectedContextService.swift:25`).
- **Erhaltungsinvarianten:** Der Clipboard-Fallback sichert und restauriert alle Pasteboard-Items samt Typrepräsentationen; AX-IPC besitzt ein 0,5-Sekunden-Timeout, damit eine hängende Ziel-App das Overlay nicht sekundenlang blockiert (`WhisperM8/Services/Dictation/SelectedContextService.swift:46`, `WhisperM8/Services/Dictation/SelectedContextService.swift:79`, `WhisperM8/Services/Dictation/SelectedContextService.swift:123`).
- **Roadmap-Bezug:** Welle 5 `P2.8b` trennt Clipboard-Vollsnapshot, Ownership-Check und Paste-Fallback als eigenen Spike und verlangt Erhalt von Nicht-Text-Inhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-13 · Paralleler Kontext-Capture nach hörbarem Aufnahmestart

- **Funktion:** Startet Audio zuerst und erfasst Selected Text und Agent-Chat-Tail danach parallel; der JSONL-Tail wird off-main gelesen (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:135`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:12`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:23`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:12`.
- **Sichtbares Verhalten:** Die ersten Silben gehen nicht durch eine vorangestellte Kontext-Erfassung verloren; Kontext-Pills können kurz nach dem Aufnahmestart nachgereicht werden (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:135`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:54`).
- **Erhaltungsinvarianten:** Ein Nutzer-Clear oder das Entfernen der Text-Pill während Capture wird beim Merge respektiert; ein gecancelter oder zu langsamer Task darf später keinen Kontext in einen anderen Lauf schreiben (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:54`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:86`).
- **Roadmap-Bezug:** `C12`, `C15` indirekt über den Diktat-Hotpath; Welle 3 `P1.5+P1.8` nennt ausdrücklich identischen Diktatkontext als Regression-Gate (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:307`).

### DI-14 · Aktiver Agent-Chat und Konversations-Tail als Kontext

- **Funktion:** Speichert Provider, Titel, Projektpfad und externe Session-ID des aktiven Chats und extrahiert den letzten relevanten User-/Assistant-Ausschnitt aus dessen Transcript (`WhisperM8/Models/TranscriptContextBundle.swift:53`, `WhisperM8/Models/TranscriptContextBundle.swift:58`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:27`).
- **Einstiegspunkt:** `WhisperM8/Models/AppState.swift:45`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:120`.
- **Sichtbares Verhalten:** Prompt-Nachbearbeitung kennt den laufenden Gesprächs- und Projektkontext, ohne eine Nachricht direkt an die Session zu senden (`WhisperM8/Services/Dictation/PromptPackageBuilder.swift:275`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:295`).
- **Erhaltungsinvarianten:** Sessions ohne externe ID können einen Chat-Ref, aber keinen Transcript-Tail liefern; der Tail ist Orientierung und darf nur dann als Faktenquelle dienen, wenn sich das Diktat ausdrücklich darauf bezieht (`WhisperM8/Models/TranscriptContextBundle.swift:62`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:315`).
- **Roadmap-Bezug:** `C12`, `C15`; Welle 3 `P1.5+P1.8` muss den Diktat-Aufrufer und seinen Chatkontext in jeder Store-/Merge-Optimierung mitführen (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:307`).

### DI-15 · Live-Clipboard-Kontext während Aufnahme und Verarbeitung

- **Funktion:** Pollt das Pasteboard alle 500 Millisekunden während Recording, Transcribing und Improving; Bilder werden zuerst als Screenshot, sonst Text normalisiert und angehängt (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:57`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:70`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:76`.
- **Sichtbares Verhalten:** Was Nutzer während Sprechen oder Verarbeitung kopieren, kann noch in den Codex-Prompt einfließen. Doppelte Textblöcke werden nicht erneut angehängt (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:73`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:187`).
- **Erhaltungsinvarianten:** Bilddetektion stützt sich auf deklarierte Bildtypen statt auf das zu permissive `NSImage(pasteboard:)`; interne Clipboard-Restores werden durch `changeCount`-Resync nicht als Nutzerkopie importiert (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:106`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:73`).
- **Roadmap-Bezug:** Welle 5 `P2.8b` muss Privacy, Nicht-Text-Inhalte und Paste-Fallback getrennt absichern (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-16 · Interaktiver Bereichs-Screenshot ohne Clipboard-Veränderung

- **Funktion:** Startet `/usr/sbin/screencapture -i`, schreibt direkt eine PNG-Datei und hängt sie an den laufenden Kontext (`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:50`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:81`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:110`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:110`, `WhisperM8/Views/RecordingPillView.swift:506`.
- **Sichtbares Verhalten:** Nutzer ziehen eine Region oder wählen ein Fenster; ESC bricht still ab, leere Dateien werden entfernt und erzeugen keinen Fehler-Toast (`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:63`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:65`).
- **Erhaltungsinvarianten:** Die Aufnahme muss noch laufen, wenn der asynchrone Screenshot zurückkehrt; während Screen-Clip oder Busy-Phase ist die Aktion gesperrt (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:111`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:127`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 4 `P2.5+P2.6` und Welle 5 `P2.8b` müssen absolute System-Binary-Nutzung, stillen User-Cancel und unberührtes Clipboard erhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-17 · Screenshot-Import aus der Zwischenablage mit Quota

- **Funktion:** Importiert echte PNG/TIFF/JPEG/HEIC/PDF-Bilddaten aus dem Pasteboard automatisch oder über „Import Clipboard Screenshot“ (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:110`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:130`, `WhisperM8/Views/RecordingOverlayView.swift:61`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:98`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:160`.
- **Sichtbares Verhalten:** Ein Clipboard-Bild wird als sichtbare Kontext-Pill angehängt; fehlt ein Bild oder ist das konfigurierbare Maximum erreicht, erscheint eine verständliche Fehlermeldung (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:98`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:132`).
- **Erhaltungsinvarianten:** Quota gilt für automatische und manuelle Importe; ein erfolgreicher Bildimport verhindert, dass derselbe Pasteboard-Inhalt zusätzlich als Text importiert wird (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:92`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:127`).
- **Roadmap-Bezug:** Welle 5 `P2.8b`; bestehender Clipboard- und Paste-Pfad bleibt Fallback, Nicht-Text-Inhalte sind explizites Regression-Gate (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-18 · Screen-Clip mit Auto-Stop und visuellen Standbildern

- **Funktion:** Nimmt den aktiven Bildschirm per ScreenCaptureKit als MP4 auf, schließt WhisperM8 aus dem Bild aus und extrahiert bis zu fünf verkleinerte Standbilder für Codex (`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:130`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:155`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:192`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:230`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:9`, `WhisperM8/Views/RecordingPillView.swift:534`.
- **Sichtbares Verhalten:** Die Pill zeigt einen roten Clip-Zustand; erneuter Klick, Recording-Stop oder das konfigurierbare Zeitlimit stoppt den Clip und hängt Clip plus Frames an (`WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:27`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:47`).
- **Erhaltungsinvarianten:** Screen-Recording-Permission und genau eine aktive Clip-Session sind Pflicht; der komplette Clip bleibt lokale Referenz, Codex erhält derzeit die extrahierten Bilder als direkte visuelle Eingabe (`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:134`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:137`, `WhisperM8/Models/TranscriptContextBundle.swift:193`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 4 `P2.5+P2.6` muss ScreenCaptureKit-/AVAssetWriter-Grenzen erhalten. Welle 5 `P2.8b` betrifft nur Audio/STT/Clipboard und darf Screen-Clips nicht beiläufig umbauen (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-19 · Granulare Kontextbearbeitung im Overlay

- **Funktion:** Entfernt Agent-Chat, Selected Text oder einzelne Screenshot-/Clip-/Frame-Anhänge; „Clear“ leert den gesamten Laufkontext (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:155`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:173`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:182`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:192`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:227`, `WhisperM8/Views/RecordingOverlayView.swift:90`.
- **Sichtbares Verhalten:** Kontext-Pills sind vor Stop einzeln entfernbar; andere Slots bleiben erhalten. Während eines aktiven Clips ist Gesamt-Clear beziehungsweise Attachment-Entfernung gesperrt (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:155`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:195`).
- **Erhaltungsinvarianten:** Ein explizites User-Clear gewinnt gegen einen später fertig werdenden Capture-Task; beim Entfernen werden zugehörige temporäre Dateien gemäß Cleanup-Policy behandelt (`WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:157`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:215`).
- **Roadmap-Bezug:** `C12`, `C15` indirekt; Welle 3 `P1.5+P1.8` verlangt identischen Diktatkontext und darf User-Edits nicht durch stale Merge-Ergebnisse zurückdrehen (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:307`).

### DI-20 · Versionierbares Kontext-Bundle und additive Kompatibilität

- **Funktion:** Vereinigt Selected Text, optionalen Agent-Chat/Tail, Screenshots, Annotationen, Clips, Visual Frames und Quell-App-Metadaten in einem `Codable`-Bundle (`WhisperM8/Models/TranscriptContextBundle.swift:51`).
- **Einstiegspunkt:** `WhisperM8/Models/TranscriptContextBundle.swift:51`, `WhisperM8/Models/TranscriptContextBundle.swift:208`.
- **Sichtbares Verhalten:** Overlay, Prompt, Run-Report und Retry können denselben strukturierten Kontext anzeigen beziehungsweise wiederverwenden (`WhisperM8/Models/TranscriptContextBundle.swift:122`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:18`).
- **Erhaltungsinvarianten:** `agentChat` bleibt optional, damit ältere JSONs ohne Feld dekodierbar bleiben; Attachment-Arten und lokale Clip-Pfade dürfen beim Report-/Retry-Roundtrip nicht verlorengehen (`WhisperM8/Models/TranscriptContextBundle.swift:53`, `WhisperM8/Models/TranscriptContextBundle.swift:114`).
- **Roadmap-Bezug:** Welle 4 `P2.5+P2.6` muss Modell- und Target-Grenzen additiv schneiden; Welle 3 `P1.5+P1.8` schützt den Diktatkontext als explizites Regression-Gate (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:307`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-21 · Kontext-Privacy, Quoten und Datei-Cleanup

- **Funktion:** Nutzer können Selected-Text-/Visual-Capture aktivieren, Screenshot-Anzahl und Clip-Dauer begrenzen sowie temporäre Kontextdateien nach Verarbeitung löschen lassen (`WhisperM8/Support/AppPreferences.swift:121`, `WhisperM8/Support/AppPreferences.swift:126`, `WhisperM8/Support/AppPreferences.swift:131`, `WhisperM8/Support/AppPreferences.swift:142`, `WhisperM8/Support/AppPreferences.swift:150`).
- **Einstiegspunkt:** `WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:6`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:181`.
- **Sichtbares Verhalten:** Limits wirken pro Aufnahme; Cleanup ist standardmäßig aus, sodass Reports und lokale Referenzen nicht unerwartet verschwinden (`WhisperM8/Support/AppPreferences.swift:150`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:181`).
- **Erhaltungsinvarianten:** Screenshot-Limit wird auf einen gültigen Bereich geklemmt; Cleanup löscht nur Dateien des übergebenen Bundles und respektiert unterschiedliche Thumbnail-/Originalpfade (`WhisperM8/Support/AppPreferences.swift:131`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:184`).
- **Roadmap-Bezug:** Welle 5 `P2.8b` verlangt Privacy- und Nicht-Text-Tests; Welle 4 `P2.5+P2.6` darf Persistenz-/Cleanup-Defaults nicht verändern (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

## 3. Transkription, Output-Modi und Codex-Nachbearbeitung

### DI-22 · OpenAI-/Groq-Provider, Modelle, Sprache und Keychain-Key

- **Funktion:** Löst Provider, providerkompatibles Modell, Sprachhinweis und API-Key aus Settings/Keychain auf und erzeugt den passenden Transkriptionsservice (`WhisperM8/Models/TranscriptionProvider.swift:5`, `WhisperM8/Models/TranscriptionProvider.swift:60`, `WhisperM8/Models/TranscriptionProvider.swift:74`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:17`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:17`, `WhisperM8/Models/TranscriptionProvider.swift:125`.
- **Sichtbares Verhalten:** Nutzer wählen OpenAI oder Groq, ein verfügbares Modell und eine Sprache beziehungsweise Auto-Detect; ein fehlender Key bricht recoverbar mit verständlichem Fehler ab (`WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:33`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:21`).
- **Erhaltungsinvarianten:** Providerwechsel wählt nötigenfalls dessen Default-Modell und nutzt einen getrennten Keychain-Key; Auto-Detect übergibt kein `language`-Multipart-Feld (`WhisperM8/Models/TranscriptionProvider.swift:187`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:35`).
- **Roadmap-Bezug:** `N06`; Welle 1 `R2.3` macht Keychain-Migration transaktional. Welle 5 `P2.8b` muss bestehende OpenAI-/Groq-/Whisper-Pfade als Fallback erhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:110`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-23 · Speicherarmer Multipart-Upload mit Größen- und Timeout-Vertrag

- **Funktion:** Prüft Dateigröße, streamt Audio in eine separate Multipart-Tempdatei und lädt sie mit einem aus Audiodauer berechneten Timeout hoch (`WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:124`, `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:153`, `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:177`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:54`, `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:128`.
- **Sichtbares Verhalten:** Lange Aufnahmen erhalten längere Timeouts; Dateien über 25 MB, HTTP-Fehler und ungültige Antworten werden als Transkriptionsfehler statt als stilles Leerergebnis gemeldet (`WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:5`, `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:160`, `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:199`).
- **Erhaltungsinvarianten:** Der Upload ist kooperativ cancelbar und nutzt keine vollständige Audio-Dateikopie im RAM; temporärer Multipart-Body wird nach dem Request entfernt (`WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:126`, `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:191`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 0 `W0.1`, Welle 4 `P2.5+P2.6` und Welle 5 `P2.8b` müssen Upload-, Cancel-, Provider- und Timeout-Parität erhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-24 · Raw-Transkript-Normalisierung und Delivery-Grenze

- **Funktion:** Normalisiert die Providerantwort, speichert Raw- und Final-Text getrennt und setzt unmittelbar vor Delivery den Nicht-mehr-cancelbar-Guard (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:39`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:47`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:52`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:9`.
- **Sichtbares Verhalten:** „Fast“ liefert den normalisierten Providertext direkt; veredelte Modi zeigen während Codex eine Improving-Phase (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:142`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:174`).
- **Erhaltungsinvarianten:** Cancellation wird genau vor `isDeliveringTranscription = true` nochmals geprüft; danach darf sie Clipboard/Paste/Report/Cleanup nicht mehr unterbrechen (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:39`).
- **Roadmap-Bezug:** Kein eigener Finding; Lifecycle-Oracle in Welle 0 `W0.1`, Modulgrenze in Welle 4 `P2.5+P2.6` (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-25 · Built-in-Output-Modi und profilabhängige Verfügbarkeit

- **Funktion:** Liefert `Fast`, `Clean`, `Prompt`, `Ultra-Prompt`, `Task`, `Email`, `Slack`, `WhatsApp` und `Notes` mit festen IDs, Templates und Defaults (`WhisperM8/Models/OutputMode.swift:145`, `WhisperM8/Models/OutputMode.swift:167`).
- **Einstiegspunkt:** `WhisperM8/Models/OutputMode.swift:167`, `WhisperM8/Windows/RecordingPanel.swift:390`.
- **Sichtbares Verhalten:** Der Output-Chip im Overlay zeigt nur aktivierte, für das Nutzungsprofil verfügbare Modi; Dictation-only fällt effektiv auf Raw/Fast zurück, ohne die gespeicherte Codex-Präferenz zu löschen (`WhisperM8/Models/OutputMode.swift:267`, `WhisperM8/Models/OutputMode.swift:282`).
- **Erhaltungsinvarianten:** Fast bleibt immer aktiv, Raw, ohne Kontext, Attachments, Projektzugriff oder Codex-Overrides; die stillgelegte Chat-ID wird migriert und darf nicht als Zombie-Custom-Mode wiederkehren (`WhisperM8/Services/Dictation/OutputModeStore.swift:173`, `WhisperM8/Models/OutputMode.swift:156`).
- **Roadmap-Bezug:** `N03`, `N04`; Welle 1 `R2.2` muss Built-ins, Custom-Modi, Templates und Reihenfolge gültiger Dateien unverändert halten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97`).

### DI-26 · Custom-Modi, Defaults, Aktivierung und Mode-Overrides

- **Funktion:** Nutzer erstellen/löschen Custom-Modi, wählen Default, Sichtbarkeit, Template, Kontextpolicy, Attachment-Paste, Projektzugriff sowie optionale Codex-Modell-/Reasoning-/Service-Tier-Overrides (`WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:54`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:68`, `WhisperM8/Views/Settings/Pages/AIOutputModesTab.swift:206`, `WhisperM8/Views/Settings/Pages/AIOutputModesTab.swift:242`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/OutputModeStore.swift:44`, `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:54`.
- **Sichtbares Verhalten:** Änderungen werden atomar in `OutputModes.json` gespeichert und eventgetrieben im offenen Recording-Overlay aktualisiert; Custom-Modi werden alphabetisch nach Built-ins angezeigt (`WhisperM8/Services/Dictation/OutputModeStore.swift:81`, `WhisperM8/Services/Dictation/OutputModeStore.swift:195`, `WhisperM8/Windows/RecordingPanel.swift:535`).
- **Erhaltungsinvarianten:** Default-Modus ist immer enabled; Löschen des Defaults fällt auf Fast zurück. Der aktuelle Loader dekodiert das Array alles-oder-nichts und `Dictionary(uniqueKeysWithValues:)` setzt eindeutige IDs voraus; `R2.2` darf nur dieses Fehlerverhalten härten, nicht gültige Custom-Modi oder ihre Ordnung verändern (`WhisperM8/Views/Settings/Models/OutputModesViewModel.swift:68`, `WhisperM8/Services/Dictation/OutputModeStore.swift:126`, `WhisperM8/Services/Dictation/OutputModeStore.swift:162`).
- **Roadmap-Bezug:** `N03`, `N04`; Welle 1 `R2.2` ersetzt Crash-/Alles-oder-nichts-Load durch Quarantäne und Backup, ohne gültige Reihenfolge und Inhalte zu verändern (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97`).

### DI-27 · Built-in- und Custom-Post-Processing-Templates

- **Funktion:** Lädt unveränderliche Built-in-Templates plus persistierte Custom-Templates; Nutzer können neue Templates anlegen, Built-ins duplizieren und Name, Beschreibung und Instruktion eigener Templates bearbeiten (`WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:14`, `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:37`, `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift:58`, `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift:88`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:3`, `WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift:17`.
- **Sichtbares Verhalten:** Built-ins erscheinen read-only; Kopien und neue Templates sind editierbar und können von Output-Modi referenziert werden (`WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift:79`, `WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift:150`).
- **Erhaltungsinvarianten:** Persistiert werden nur Custom-Templates; Built-in-IDs und Platzhalter wie Raw-Text, Kontext, Bilder, Chat, Sprache und Datum müssen beim Rendern stabil bleiben (`WhisperM8/Services/Dictation/PostProcessingTemplateStore.swift:37`, `WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift:183`).
- **Roadmap-Bezug:** `N04`; Welle 1 `R2.2` muss bei partieller Korruption gültige Custom-Templates erhalten und vor Repair-Save sichern (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97`).

### DI-28 · Kontextpolicy `off`/`auto`/`required`

- **Funktion:** Filtert das erfasste Bundle pro Modus vollständig weg, reicht es automatisch durch oder verlangt nichtleeren Kontext (`WhisperM8/Services/Dictation/PostProcessingService.swift:26`, `WhisperM8/Services/Dictation/PostProcessingService.swift:39`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/PostProcessingService.swift:11`, `WhisperM8/Models/OutputMode.swift:26`.
- **Sichtbares Verhalten:** Modi mit `off` ignorieren Selected Text und Bilder; `required` bricht verständlich ab, wenn kein Kontext vorhanden ist; `auto` nutzt verfügbaren Kontext (`WhisperM8/Services/Dictation/PostProcessingService.swift:27`, `WhisperM8/Services/Dictation/PostProcessingService.swift:39`).
- **Erhaltungsinvarianten:** Raw/Fast umgeht Post-Processing vollständig; Custom-Modi mit Kontext defaulten auf Attachment-Paste, Built-ins behalten ihre ID-basierten Defaults (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:152`, `WhisperM8/Models/OutputMode.swift:313`).
- **Roadmap-Bezug:** `N03`, `N04`; Welle 1 `R2.2` muss Policies und additive Defaults beim Roundtrip erhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97`).

### DI-29 · Intent-Routing und Prompt-Paket mit Visual Manifest

- **Funktion:** Klassifiziert Diktate in Prompt-Paket, direkte Antwort, Agentic Reply oder Formatierung und baut daraus globalen Vertrag, Modus-Instruktion, Agent-Chat-Block und Visual Manifest (`WhisperM8/Services/Dictation/PromptPackageBuilder.swift:3`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:49`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:237`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:244`.
- **Sichtbares Verhalten:** Prompt-Modi liefern einen ausführbaren Markdown-Prompt statt die Aufgabe auszuführen; Slack, WhatsApp und Email liefern die fertige Nachricht; Bilder werden nummeriert und im Prompt referenziert (`WhisperM8/Services/Dictation/PromptPackageBuilder.swift:321`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:348`).
- **Erhaltungsinvarianten:** Jedes an Codex angehängte Bild muss im Manifest eindeutig korrespondieren; Kontext ist vorsichtig zu verwenden und fehlender Kontext darf nicht erfunden werden (`WhisperM8/Services/Dictation/PromptPackageBuilder.swift:154`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:313`, `WhisperM8/Services/Dictation/PromptPackageBuilder.swift:316`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 4 `P2.5+P2.6` muss Prompt-/Modellgrenzen erhalten, Welle 5 `P2.8b` muss Provider-Fallback denselben Promptvertrag speisen (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-30 · Codex-CLI-Nachbearbeitung mit Read-only-Sandbox

- **Funktion:** Prüft einen gecachten Codex-Status, baut Prompt und Bildliste und startet `codex exec` off-main mit Login-Shell-Environment, `--sandbox read-only` und `--output-last-message` (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:25`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:55`, `WhisperM8/Services/Dictation/CodexSupport.swift:52`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/CodexPostProcessor.swift:20`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:61`.
- **Sichtbares Verhalten:** Nicht bereiter oder nicht installierter Codex führt je nach Setting zu Raw-Fallback; Modus-spezifische Modell-, Reasoning- und Service-Tier-Werte überschreiben globale Defaults (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:25`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:62`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:74`).
- **Erhaltungsinvarianten:** Projektzugriff bleibt lesend; Codex bekommt Prompt über stdin, Bilder über `--image`, und ein leerer Output gilt als Fehler statt als erfolgreicher Leertext (`WhisperM8/Services/Dictation/CodexSupport.swift:72`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:107`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:144`).
- **Roadmap-Bezug:** Kein direkter Finding für diesen lokalen Lauf; Welle 4 `P2.5+P2.6` löst `CodexStatusProbe`-Kopplung vor Targets und muss CLI-/Environment-/Sandbox-Parität halten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-31 · Projektzugriff und persistenter Task-Modus

- **Funktion:** `Prompt`-nahe Modi können den aktiven Agent-Chat-Pfad, sonst das Default-Projekt als Codex-cwd erhalten; `Task` läuft als einziger Modus nicht ephemer (`WhisperM8/Services/Dictation/ProjectPathResolver.swift:7`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:42`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:80`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/ProjectPathResolver.swift:16`, `WhisperM8/Services/Dictation/CodexSupport.swift:53`.
- **Sichtbares Verhalten:** Ultra-Prompt und Task dürfen Projektdateien lesend inspizieren; Task erzeugt eine fortsetzbare Codex-Session, deren ID/Projekt später im Run-Report auftaucht (`WhisperM8/Models/OutputMode.swift:302`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:186`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:238`).
- **Erhaltungsinvarianten:** `.off` erhält kein `-C`; `.readOnly` ändert nicht die Sandbox-Schreibrechte. Task-Session-Sync matcht nur standardisierte cwd-Gleichheit (`WhisperM8/Models/OutputMode.swift:3`, `WhisperM8/Services/Dictation/CodexSupport.swift:77`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:244`).
- **Roadmap-Bezug:** `C12`, `C15` indirekt wegen des Diktat-Hotpath-Merge; Welle 3 `P1.5+P1.8` muss Task-Session-Sync und Diktatkontext unverändert halten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:307`).

### DI-32 · Kontrollierter Raw-Fallback bei Codex-Fehler oder User-Cancel

- **Funktion:** Fängt Codex-Cancel und Nachbearbeitungsfehler ab; bei aktivem Fallback liefert es Raw beziehungsweise einen vorsichtigen Modus-Fallback und protokolliert `rawFallback` (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:199`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:215`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:142`.
- **Sichtbares Verhalten:** Abbruch von Improving liefert das Raw-Transkript ohne Alarm; bei Codex-Fehler bleibt das Diktat nutzbar und eine Fehlermeldung erklärt die Degradation (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:204`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:215`).
- **Erhaltungsinvarianten:** Ist `fallbackToRawOnProcessingError` deaktiviert, propagiert der Fehler in den Preserve-/Retry-Pfad; Cancel darf nicht als technischer Fehler angezeigt werden (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:204`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:234`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 4 `P2.5+P2.6` und Welle 5 `P2.8b` müssen den Fallbackvertrag über Provider-/Modulgrenzen erhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

## 4. Clipboard, Auto-Paste und Agent-Chat-Routing

### DI-33 · Finaltext immer in die Zwischenablage kopieren

- **Funktion:** Schreibt jeden erfolgreichen Finaltext unabhängig von Auto-Paste in das System-Clipboard und aktualisiert Raw-/Final-/Last-Transcription-State (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:78`, `WhisperM8/Services/Dictation/PasteService.swift:31`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:78`.
- **Sichtbares Verhalten:** Bei deaktiviertem Auto-Paste endet die Pipeline mit kopiertem Text; die Menüleiste zeigt eine gekürzte letzte Transkription (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:102`, `WhisperM8/Views/MenuBarView.swift:36`).
- **Erhaltungsinvarianten:** Clipboard-Copy ist der sichere Fallback bei fehlender Ziel-App, Permission oder Attachment-Fehlern; Delivery-Fehler dürfen den Finaltext nicht verlieren (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:78`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:107`).
- **Roadmap-Bezug:** `N11`; Welle 2 `R2.6` schreibt bei Zielabweichung ausdrücklich „nur kopieren“ vor. Welle 5 `P2.8b` behält Clipboard als Fallback (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-34 · Auto-Paste in die vor dem Overlay gespeicherte App

- **Funktion:** Aktiviert die vom Overlay gespeicherte vorherige App, wartet bis zu eine Sekunde auf Fokus und sendet Cmd+V über nil-geprüfte CGEvents (`WhisperM8/Services/Dictation/PasteService.swift:52`, `WhisperM8/Services/Dictation/PasteService.swift:126`, `WhisperM8/Services/Dictation/PasteService.swift:169`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:84`, `WhisperM8/Services/Dictation/PasteService.swift:52`.
- **Sichtbares Verhalten:** Bei aktivierter Option erscheint der Text automatisch in der ursprünglichen Ziel-App; ohne Accessibility-Berechtigung oder gespeichertes Ziel bleibt er kopiert und ein sichtbarer Fehler wird gesetzt (`WhisperM8/Services/Dictation/PasteService.swift:58`, `WhisperM8/Services/Dictation/PasteService.swift:69`).
- **Erhaltungsinvarianten:** Aktivierungs-Timeout darf Paste nicht dauerhaft blockieren; Permission-Anfrage und Missing-Target-Pfad dürfen keinen beliebigen aktuell fokussierten Empfänger verwenden (`WhisperM8/Services/Dictation/PasteService.swift:126`, `WhisperM8/Services/Dictation/PasteService.swift:142`).
- **Roadmap-Bezug:** `N11`; Welle 2 `R2.6` prüft App, Fenster und Session vor Delivery neu und fällt bei Abweichung auf Clipboard plus Bestätigung zurück, während Happy-Path und Clipboard-Wiederherstellung erhalten bleiben (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`).

### DI-35 · Sequenzielles Paste visueller Anhänge

- **Funktion:** Baut aus den ersten erlaubten visuellen Attachments ein Paste-Payload, pastet zuerst Text und danach Bilder einzeln und stellt am Ende den Text wieder ins Clipboard (`WhisperM8/Services/Dictation/VisualAttachmentDeliveryBuilder.swift:16`, `WhisperM8/Services/Dictation/PasteService.swift:90`, `WhisperM8/Services/Dictation/PasteService.swift:97`, `WhisperM8/Services/Dictation/PasteService.swift:114`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:65`, `WhisperM8/Services/Dictation/PasteService.swift:52`.
- **Sichtbares Verhalten:** Modi mit `pasteVisualAttachments` liefern Screenshot-/Frame-Bilder nach dem Text; fehlende oder nicht schreibbare Einzelbilder werden als Delivery-Fehler gemeldet, ohne die übrige Pipeline zu verwerfen (`WhisperM8/Services/Dictation/PasteService.swift:97`, `WhisperM8/Services/Dictation/PasteService.swift:107`).
- **Erhaltungsinvarianten:** Screen-Clip-Dateien selbst gehören nicht zur direkten Bild-Paste-Liste; Clipboard enthält nach Abschluss wieder den Finaltext, nicht das letzte Bild (`WhisperM8/Models/TranscriptContextBundle.swift:106`, `WhisperM8/Services/Dictation/PasteService.swift:114`).
- **Roadmap-Bezug:** `N11`; Welle 2 `R2.6` erhält den Auto-Paste-Happy-Path, Welle 5 `P2.8b` schützt Nicht-Text-Inhalte und Paste-Fallback (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

### DI-36 · Agent-Chat-Routing ausschließlich über Kontext und Auto-Paste

- **Funktion:** Ein aktiver Chat beeinflusst Prompt, Projekt-cwd und Report; der Finaltext wird nicht über eine Session-API versendet, sondern nur über den allgemeinen Auto-Paste-Pfad in das gespeicherte Ziel-Fenster eingefügt (`WhisperM8/Services/Dictation/PromptPackageBuilder.swift:283`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:42`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:84`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:120`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:84`.
- **Sichtbares Verhalten:** Diktat in einem Agent-Chat verhält sich für den Nutzer wie Eingabe in das Terminal/Chat-Fenster; es entsteht kein zweiter verdeckter Sendekanal (`WhisperM8/Services/Dictation/PasteService.swift:79`, `WhisperM8/Models/AppState.swift:45`).
- **Erhaltungsinvarianten:** Chat-Kontext ist nicht gleich Paste-Berechtigung und nicht gleich Zielidentität; ein Refactor darf keinen automatischen Session-Turn aus bloßer Kontextanwesenheit ableiten (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:120`, `WhisperM8/Services/Dictation/PasteService.swift:52`).
- **Roadmap-Bezug:** `N11`; Welle 2 `R2.6` bindet den vorhandenen Paste-Kanal enger an Aufnahme-Intent, nicht an den aktuell sichtbaren oder zuletzt selektierten Chat (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`).

## 5. Fehler, Retry, Reports, Menüleiste und Berechtigungen

### DI-37 · Preserve und Retry fehlgeschlagener Transkriptionen

- **Funktion:** Verschiebt Audio samt JSON-Sidecar bei Upload-Cancel oder jedem Transkriptionsfehler nach Application Support und merkt Modus, Sprache, Dauer und Kontext für Retry (`WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:11`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:45`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:65`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:368`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:418`.
- **Sichtbares Verhalten:** Fehler-Alert bietet „Erneut versuchen“, wenn Preserve gelungen ist; Retry verwendet dieselbe Aufnahme, denselben Output-Modus und dasselbe Kontext-Bundle (`WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:31`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:422`).
- **Erhaltungsinvarianten:** Audio wird nur bei erfolgreicher Delivery gelöscht; Store hält höchstens zehn Aufnahmen beziehungsweise sieben Tage und bevorzugt eine überzählige Datei gegenüber einem verfrühten Datenverlust (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:368`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:27`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:51`).
- **Roadmap-Bezug:** `N02` berührt Pending-Record-Persistenz beim Quit; Welle 1 `R2.1` darf eine abgebrochene Aufnahme sichern, aber niemals automatisch versenden (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:84`).

### DI-38 · Run-Reports, Output-History, Suche und Löschen

- **Funktion:** Archiviert Status, Fehler, Provider/Modell/Sprache, Raw-/Finaltext, Prompt, Intent, Codex-Aufruf, Kontext, Attachments und Paste-Ergebnis pro erfolgreichem beziehungsweise Raw-Fallback-Lauf (`WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:72`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:112`).
- **Einstiegspunkt:** `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:72`, `WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift:11`.
- **Sichtbares Verhalten:** „Output & History“ zeigt paginierte Runs, Detailansicht, Volltextsuche und Löschbestätigung (`WhisperM8/Views/MenuBarView.swift:95`, `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift:140`, `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift:196`, `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift:290`).
- **Erhaltungsinvarianten:** Reportdatei und Index werden atomar geschrieben beziehungsweise bei Drift neu aufgebaut; Produktions-Retention ist 180 Tage, 500 Runs oder 2 GB, wobei die jeweils strengste Grenze greift (`WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:44`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:182`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:274`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 4 `P2.5+P2.6` muss Ressourcen, Modelle und Report-Roundtrip beim Target-Schnitt unverändert halten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-39 · Menüleisten-Status und Diktat-Quick-Actions

- **Funktion:** `MenuBarExtra` hält die App ohne Fenster bedienbar und zeigt Recording/Transcribing/Ready, letzte Transkription, Fehler, Hotkey, Eingabegerät sowie Links zu Settings und Output-History (`WhisperM8/WhisperM8App.swift:70`, `WhisperM8/Views/MenuBarView.swift:11`).
- **Einstiegspunkt:** `WhisperM8/WhisperM8App.swift:70`, `WhisperM8/Views/MenuBarView.swift:4`.
- **Sichtbares Verhalten:** Nutzer sehen den laufenden Diktatstatus, wechseln das Mikrofon und öffnen Settings oder Verlauf direkt aus der Menüleiste; Schließen des letzten Fensters beendet die App nicht (`WhisperM8/Views/MenuBarView.swift:13`, `WhisperM8/Views/MenuBarView.swift:71`, `WhisperM8/Views/MenuBarView.swift:90`, `WhisperM8/WhisperM8App.swift:329`).
- **Erhaltungsinvarianten:** Hotkey-Recording und Output-Modi funktionieren ohne offenes Hauptfenster; Dictation-only-/Enrichment-Profile dürfen als reine Menüleisten-App laufen (`WhisperM8/WhisperM8App.swift:210`, `WhisperM8/WhisperM8App.swift:329`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 4 `P2.5+P2.6` muss App-Shell-/Ressourcen-Verhalten erhalten. Welle 1 `R2.1` vereinheitlicht Menü-Quit und System-Quit (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:84`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-40 · Profilabhängiges Onboarding mit Live-Test

- **Funktion:** Führt durch Profil, essenzielle Permissions, Hotkey, Provider/API-Key/Modell, optional Codex und einen echten Diktat-Test (`WhisperM8/Views/OnboardingView.swift:36`, `WhisperM8/Views/OnboardingView.swift:102`).
- **Einstiegspunkt:** `WhisperM8/Views/OnboardingView.swift:19`, `WhisperM8/WhisperM8App.swift:300`.
- **Sichtbares Verhalten:** Weiter geht es erst mit Mikrofon, Accessibility, Hotkey und vorhandenem API-Key; der Test-Schritt zeigt Recording, Transcribing, Resultat oder Fehler live (`WhisperM8/Views/OnboardingView.swift:150`, `WhisperM8/Views/OnboardingView.swift:731`).
- **Erhaltungsinvarianten:** Codex-Schritt erscheint nur für Profile mit Enrichment; Onboarding wird permission-basiert geöffnet statt über einen anfälligen „Done“-Flag und bleibt als reguläres fokussierbares Fenster sichtbar (`WhisperM8/Views/OnboardingView.swift:38`, `WhisperM8/WhisperM8App.swift:201`, `WhisperM8/WhisperM8App.swift:300`).
- **Roadmap-Bezug:** `N06` für Keychain-Migration und allgemein Welle 4 `P2.5+P2.6`; Profile, Window-Gate und Live-Test sind Ship-Gates (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:110`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-41 · Mikrofon-, Accessibility- und Screen-Recording-Berechtigungen

- **Funktion:** Prüft und beantragt Mikrofon-, Accessibility- und ScreenCapture-Rechte und öffnet die jeweiligen System-Settings-Panes (`WhisperM8/Services/Shared/PermissionService.swift:6`, `WhisperM8/Services/Shared/PermissionService.swift:23`, `WhisperM8/Services/Shared/PermissionService.swift:28`, `WhisperM8/Services/Shared/PermissionService.swift:32`).
- **Einstiegspunkt:** `WhisperM8/Services/Shared/PermissionService.swift:6`, `WhisperM8/Views/OnboardingView.swift:370`.
- **Sichtbares Verhalten:** Mikrofon und Accessibility sind Onboarding-Pflicht; Screen Recording wird erst beim Clip-Feature angefragt und blockiert normale Audio-Diktate nicht. Die Permissions-Seite zeigt alle drei Zustände, lässt sie neu prüfen oder reparieren und öffnet die passenden Systemeinstellungen, ohne das Onboarding erneut zu starten (`WhisperM8/Views/OnboardingView.swift:381`, `WhisperM8/Views/RecordingPillView.swift:541`, `WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift:11`, `WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift:72`).
- **Erhaltungsinvarianten:** Accessibility dient sowohl Selected-Text-Clipboard-Fallback als auch Auto-Paste; fehlendes Screen-Recht darf Screenshot-via-`screencapture` beziehungsweise reines Audio nicht pauschal sperren (`WhisperM8/Services/Dictation/SelectedContextService.swift:25`, `WhisperM8/Services/Dictation/PasteService.swift:58`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:134`).
- **Roadmap-Bezug:** Kein eigener Permission-Finding; Welle 4 `P2.5+P2.6` muss Shared-/Dictation-Modulgrenzen ohne Berechtigungsregression schneiden (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-42 · App-Quit während Diktat und Ducking-Sicherheitsnetz

- **Funktion:** Menü-Quit und System-Quit laufen über AppKit; `applicationWillTerminate` stellt aktives Ducking sofort wieder her (`WhisperM8/Views/MenuBarView.swift:113`, `WhisperM8/WhisperM8App.swift:343`, `WhisperM8/WhisperM8App.swift:354`).
- **Einstiegspunkt:** `WhisperM8/WhisperM8App.swift:343`, `WhisperM8/WhisperM8App.swift:357`.
- **Sichtbares Verhalten:** Die App beendet sich ohne dauerhaft abgesenkte Systemlautstärke. Der aktuelle Code finalisiert oder persistiert eine gerade laufende temporäre M4A jedoch noch nicht (`WhisperM8/WhisperM8App.swift:351`, `WhisperM8/WhisperM8App.swift:357`).
- **Erhaltungsinvarianten:** Eine Quit-Härtung darf weder hängen noch eine abgebrochene Aufnahme automatisch transkribieren oder versenden; sie muss Recorder und Ducking geordnet abschließen (`WhisperM8/WhisperM8App.swift:343`, `WhisperM8/WhisperM8App.swift:357`).
- **Roadmap-Bezug:** `N02`; Welle 1 `R2.1` führt `.terminateLater` und recoverbaren Pending-Record für Quit während Capture, Reconfiguration, Transkription und Post-Processing ein (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:84`).

## 6. Diagnose- und Vorschauwerkzeuge

### DI-43 · AI Output Test Lab ohne Audioaufnahme

- **Funktion:** Führt einen gewählten aktivierten Output-Modus auf manuell eingegebenem Raw-Text aus, ohne Mikrofon, Selected-Text-Capture oder Recording-Lifecycle zu starten (`WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:18`, `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:68`).
- **Einstiegspunkt:** `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:4`, `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:98`.
- **Sichtbares Verhalten:** Nutzer wählen einen Modus, starten eine Preview, sehen Ergebnis oder Fehler und können die Preview kopieren; bei aktiviertem Fallback erscheint normalisierter Raw-Text mit Warnung (`WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:18`, `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:31`, `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:125`).
- **Erhaltungsinvarianten:** Eine neue Preview cancelt die alte und eine Generation verhindert stale Resultate; Schließen des Tabs cancelt den Task. Der Test nutzt dieselbe Sprache, Mode-Auflösung und `PostProcessingService`-Pipeline wie echtes Diktat, aber bewusst leeren Kontext (`WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:69`, `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:89`, `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift:111`).
- **Roadmap-Bezug:** `N03`, `N04`; Welle 1 `R2.2` muss gültige Mode-/Template-Auswahl erhalten. Welle 0 `W0.1` und Welle 4 `P2.5+P2.6` dürfen Vorschau und Produktionspipeline nicht semantisch auseinanderlaufen lassen (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`).

### DI-44 · Datei-Transkription über die `whisperm8`-CLI

- **Funktion:** `whisperm8 transcribe` normalisiert Audio oder Video, teilt lange Medien in Chunks, transkribiert sie über OpenAI oder Groq, fügt Text und Zeitsegmente wieder zusammen und kann anschließend denselben Output-Mode-/Codex-Pfad wie die GUI anwenden (`WhisperM8/CLI/CLIEntryPoint.swift:74`, `WhisperM8/CLI/CLITranscribe.swift:84`, `WhisperM8/CLI/CLITranscribe.swift:101`, `WhisperM8/CLI/CLITranscribe.swift:119`, `WhisperM8/CLI/CLITranscribe.swift:131`).
- **Einstiegspunkt:** `WhisperM8/CLI/CLIEntryPoint.swift:89`, `WhisperM8/CLI/CLITranscribe.swift:7`.
- **Sichtbares Verhalten:** Nutzer transkribieren eine oder mehrere lokale Medien nach stdout oder in Dateien, wählen `txt`, `json`, `srt` oder `vtt`, Provider, Modell, Sprache, Output-Mode und Chunk-Länge oder lassen mit `--dry-run` nur Dauer, Chunkzahl und Kosten schätzen. `whisperm8 modes` listet nachbearbeitbare Modi (`WhisperM8/CLI/CLIArguments.swift:5`, `WhisperM8/CLI/CLIArguments.swift:67`, `WhisperM8/CLI/CLITranscribe.swift:57`, `WhisperM8/CLI/CLITranscribe.swift:254`, `WhisperM8/CLI/CLITranscribe.swift:270`, `WhisperM8/CLI/CLITranscribe.swift:325`).
- **Erhaltungsinvarianten:** SRT/VTT benötigen ein Segment-fähiges Whisper-Modell und sind mit `--mode` unvereinbar; mehrere Inputs verbieten ein gemeinsames `-o` und schreiben stattdessen neben die Quelldateien. Chunk-Uploads laufen mit maximal drei parallelen Tasks und Retry nur für 429, 5xx sowie ausgewählte Netzwerkfehler. API-Key-Priorität bleibt `--api-key` vor Provider-Umgebungsvariable vor WhisperM8-Keychain; stdout enthält ausschließlich das Ergebnis, Fortschritt und Fehler gehen nach stderr (`WhisperM8/CLI/CLITranscribe.swift:19`, `WhisperM8/CLI/CLITranscribe.swift:27`, `WhisperM8/CLI/CLITranscribe.swift:41`, `WhisperM8/CLI/CLITranscribe.swift:155`, `WhisperM8/CLI/CLITranscribe.swift:230`, `WhisperM8/CLI/CLITranscribe.swift:309`, `WhisperM8/CLI/CLIEntryPoint.swift:107`).
- **Roadmap-Bezug:** Kein eigener Finding; Welle 4 `P2.5+P2.6` nennt signiertes Executable, CLI-Symlink und Ressourcen ausdrücklich als Ship-Gate. Welle 5 `P2.8b` darf die bestehenden Groq-/Whisper-/OpenAI-Pfade und ihren Codex-/Output-Mode-Fallback nicht nur in der GUI, sondern auch in der Datei-Pipeline verlieren (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`).

## Querschnitt: Erhaltungsinvarianten mit höchstem Regressionsrisiko

1. **Tap/Format/Generation sind eine Einheit:** Nur die aktive Recording-Generation darf Tap, Converter und Datei benutzen; Hardwareformat unmittelbar vor Tap/Start und nach jedem Reconfiguration-`await` erneut validieren (`WhisperM8/Services/Dictation/AudioRecorder.swift:101`, `WhisperM8/Services/Dictation/AudioRecorder.swift:252`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:65`).
2. **Tap-to-toggle bleibt bewusst asymmetrisch:** `keyDown` startet, frühes `keyUp` wird ignoriert, der nächste Tastendruck stoppt (`WhisperM8/WhisperM8App.swift:101`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:259`).
3. **Audio startet vor Kontext-I/O:** Selected-Text-/Chat-Tail-Capture darf die ersten Silben nicht wieder verzögern; der spätere Merge respektiert User-Clear (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:135`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:54`).
4. **Quell-App, Chat-Kontext und Paste-Ziel sind getrennte Begriffe:** Chat-Präsenz erzeugt keinen direkten Sendekanal; Auto-Paste darf nur den geprüften Aufnahme-Intent bedienen und fällt sonst auf Clipboard zurück (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:120`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:84`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`).
5. **Cancel endet an der Delivery-Grenze:** Vor Response ist Upload cancelbar und Audio wird gesichert; danach bleiben Paste-Timings, Report und Cleanup ungestört (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:39`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:357`).
6. **Finaltext ist nie von Auto-Paste abhängig:** Clipboard-Copy passiert immer zuerst; Permission-, Fokus- und Attachment-Fehler dürfen ihn nicht verlieren (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:78`, `WhisperM8/Services/Dictation/PasteService.swift:58`).
7. **Task ist absichtlich anders als andere Output-Modi:** Nur Task ist nicht ephemer und wird anschließend als fortsetzbare Codex-Session synchronisiert (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:80`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:186`).
8. **Gültige Nutzerkonfiguration überlebt Reparaturen:** Built-ins, Custom-Modi, Custom-Templates, Reihenfolge und additive Defaults dürfen bei Duplikaten oder einer korrupten Zeile nicht global zurückgesetzt werden (`WhisperM8/Services/Dictation/OutputModeStore.swift:145`, `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97`).
9. **Ducking umschließt die reale Engine-Lebensdauer:** Snapshot vor Bluetooth-Profilwechsel, Restore bei Stop, Cancel, Fehler und Quit (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:142`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:309`, `WhisperM8/WhisperM8App.swift:354`).
10. **Quit sichert, aber sendet nicht:** Welle 1 darf eine laufende Aufnahme finalisieren oder als Pending-Record persistieren, niemals still transkribieren/pasten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:84`).
11. **GUI und CLI teilen Provider und Output-Modes, aber nicht denselben Lifecycle:** Datei-Transkription behält Chunking, bounded concurrency, Retry, Zeitsegmente, stdout/stderr-Trennung und Key-Priorität; ein Modulschnitt darf die CLI nicht als bloßen GUI-Wrapper behandeln (`WhisperM8/CLI/CLITranscribe.swift:84`, `WhisperM8/CLI/CLITranscribe.swift:155`, `WhisperM8/CLI/CLITranscribe.swift:200`, `WhisperM8/CLI/CLITranscribe.swift:309`, `WhisperM8/CLI/CLIEntryPoint.swift:107`).

## Abdeckungsmatrix der Roadmap-Maßnahmen

| Welle / Maßnahme | Betroffene Inventar-Features | Zwingendes Regressions-Gate |
|---|---|---|
| Welle 0 `W0.1` | DI-01, DI-02, DI-10, DI-11, DI-23, DI-24, DI-43 | Hotkey-, Lifecycle-, Cancel-, Upload-, Snapshot- und Preview-Oracles vor Isolation/Modulschnitt (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:49`). |
| Welle 1 `P0.1+P0.2` (`C01`, `C02`) | DI-04–DI-07, DI-10 | Built-in/Bluetooth, Hotplug, Start/Stop/Cancel; kein Prozessabbruch, Zombie-Tap oder verlorenes Ducking (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:65`). |
| Welle 1 `R2.1` (`N02`) | DI-37, DI-39, DI-42 | Quit in jeder Phase sichert/finalisiert recoverbar, hängt nicht und sendet nie automatisch (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:84`). |
| Welle 1 `R2.2` (`N03`, `N04`) | DI-25–DI-28, DI-43 | Built-ins, Custom-Modi/Templates, Default, Reihenfolge, Preview-Auswahl und gültige Records überleben partielle Korruption (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97`). |
| Welle 1 `R2.3` (`N06`) | DI-22, DI-40 | API-Key erst nach erfolgreichem Write+Readback migrieren; Provider-/Modellzuordnung bleibt gültig (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:110`). |
| Welle 2 `P0.3` (`C03`) | DI-04–DI-07 | Immutable Device-Snapshots, Swift-6-/TSan-Baseline, Audio-Callback wartet nie auf MainActor (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:188`). |
| Welle 2 `R2.6` (`N11`) | DI-03, DI-08, DI-33–DI-36 | Aufnahme-Intent erneut validieren; Fokuswechsel fällt sichtbar auf Clipboard zurück, Happy-Path bleibt (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251`). |
| Welle 3 `P1.5+P1.8` (`C12`, `C15`) | DI-13, DI-14, DI-19, DI-20, DI-31 | Diktat-Hotpath in Merge-/Store-Optimierung berücksichtigen; Chat-/Selected-/Visual-Kontext bleibt identisch (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:307`). |
| Welle 4 `P2.5+P2.6` | Alle DI-Features, besonders DI-02, DI-08–DI-09, DI-20, DI-22–DI-32, DI-38–DI-41, DI-43 | Kleine Leaf-Targets zuerst; signiertes Executable, Ressourcen, CLI-Symlink, Preview und GUI-Pipeline bleiben nach jedem Schnitt shipbar (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:402`). |
| Welle 5 `P2.8b` | DI-04–DI-07, DI-12, DI-15–DI-17, DI-21–DI-23, DI-32–DI-35, DI-44 | AUHAL/lokale STT/Clipboard getrennt evaluieren; AVAudioEngine, Groq/Whisper/OpenAI, CLI-Dateipipeline und Paste bleiben Fallback, Privacy/Nicht-Text-Inhalte bleiben erhalten (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:446`). |
