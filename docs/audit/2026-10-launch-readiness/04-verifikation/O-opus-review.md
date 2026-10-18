---
status: aktiv
updated: 2026-10-17
description: Workflow O (5 Opus-Agents) — Kalibrierung der Sonnet-Herabstufungen, Erstprüfung der P2, Red Team für blinde Flecken.
---

# Opus-Review (Workflow O)

| Agent | Auftrag | Umfang |
|---|---|---|
| O1 | Herabstufungen P1→P2/P3 kalibrieren (Diktat, Konten, GPT, Onboarding, Doku) | 25 |
| O2 | Herabstufungen P1→P2/P3 kalibrieren (Agent-Kern, Shared, Plugin, Build) | 26 |
| O3 | Unverifizierte P2 erstmals prüfen | 26 |
| O4 | Red Team: blinde Flecken quer zu den Subsystemen | 13 neue Befunde, 15 Laufzeitprüfungen |
| O5 | Anforderungs- und Testmatrix | [05-plan/anforderungs-testmatrix.md](../05-plan/anforderungs-testmatrix.md) |

## Geänderte Einstufungen

| ID | vorher | Opus | Agent | Titel |
|---|---|---|---|---|
| LR-AK-010 | P2 | P2! | o2 | : Automatische Zusammenfassungen erklären ihren zusätzlichen Datenabfluss nicht |
| LR-AK-013 | P2 | P3 | o3 | : Parallele Tool-Ergebnisse werden in Zusammenfassungen vertauscht |
| LR-AK-014 | P2 | P3 | o3 | : Ein nur gestarteter Test wird als bestanden an das Modell gemeldet |
| LR-AK-016 | P2 | P3 | o3 | : Dauernde externe Transcript-Writes können die Erkennung endlos verschieben |
| LR-AK-031 | P2 | P3 | o2 | Job-State-Korrektur und PID-Nachtrag überschreiben neuere Zustände |
| LR-AU-001 | P2 | P3 | o2 | [A3-10] UI-Composer umgeht die gehärtete Supervisor-PID-Transaktion |
| LR-BR-001 | P2 | P2! | o2 | : Brew-Zap lässt installierte Statuslines und fremde Konfigurationsänderungen zurück |
| LR-BR-009 | P2 | P3 | o3 | Store-Test verwechselt Scheduler-Verzögerung mit blockierendem Flush |
| LR-DIK-004 | P2 | P1! | o1 | Recorderfehler beim Gerätewechsel umgehen die Aufnahmerettung |
| LR-DIK-012 | P2 | P1! | o1 | Gesicherte Aufnahmen haben keinen später erreichbaren Retry-Weg |
| LR-DIK-016 | P2 | P3 | o3 | Clipboard-Fallback überschreibt zwischenzeitliche Nutzerkopien |
| LR-DIK-018 | P2! | P3 | o3 | Stop wartet bis zu einer Sekunde vor dem eigentlichen Audiostopp |
| LR-DOK-002 | P2 | P3 | o3 | DMG-Anleitung verspricht einen nicht mehr unterstützten Build ohne Xcode |
| LR-DOK-006 | P2! | P3! | o3 | Aktive Feature-Doku beschreibt abgelöste Transcript- und Titelpfade |
| LR-DOK-007 | P2! | P3! | o3 | Die Datenschutzerklärung im Handbuch verschweigt dauerhaft gesicherte Abbruch-Audios |
| LR-GPT-007 | P2 | P3 | o3 | Das normale Usage-Popover fragt GPT-Profilkonten trotz ausgeschaltetem Backend ab |
| LR-ONB-010 | P2! | P2 | o3 | : Der Update-Dialog endet bei einem Terminal-Befehl statt einer geführten Aktualisierung |
| LR-ONB-012 | P2! | P2 | o3 | : Kern-Settings trennen Labs und Expertenfunktionen nicht vom normalen Setup |
| LR-ONB-013 | P2! | P2 | o3 | : Ungültiger Key und fehlgeschlagenes Testdiktat verhindern keine Erfolgsmeldung |
| LR-ONB-014 | P2 | P3 | o3 | : Die Modellauswahl im Onboarding ist nicht per Tastatur bedienbar |
| LR-ONB-015 | P2 | P3 | o3 | : Nach fehlgeschlagenem Vorlagen-Speichern wird Save deaktiviert |
| LR-ONB-016 | P2 | P3 | o3 | : Zentrale Hilfetexte unterschreiten den normalen Textkontrast |
| LR-PJ-001 | P3 | P2 | o2 | : Die Plugin-Migration räumt fremde, ungestempelte Skills automatisch weg |
| LR-SH-007 | P2 | P2! | o2 | : Die Login-Shell-Abfrage kann den ersten Chatstart dauerhaft auf dem Hauptthread blockieren |
| LR-SH-008 | P2 | P3 | o3 | : Fehlerhafte Transkriptionsantworten schreiben diktierte Inhalte in öffentliche Logs |

`!` = Launch-Blocker.

## Kalibrierungs-Notizen

### O1

Gesamtbild: 23 von 25 Herabstufungen tragen. Zwei korrigiere ich wieder auf P1 mit Blocker, beide in der Diktat-Aufnahmerettung (Kern): LR-DIK-004 und LR-DIK-012.

Das systematische Muster beim Sonnet-Prüfer: Die Begründungen „selten / Zeitfenster eng / Erweitert oder Labs“ sind für Races in Erweitert und Labs (KO-*, GPT-*, VG, DIK-014) fast durchweg korrekt. Dort war GPT klar zu hart: Mikrosekunden- bzw. Millisekunden-Races wurden als P1 eingestuft, die Klasse wurde ignoriert.

In Kern-Pfaden ist der Prüfer dagegen zu weich, und zwar bei Ereignissen, die im Alltag vorkommen, aber als Randfall gelten:
- Gerätewechsel im Default-Modus „System Default“ (DIK-004; Instabilität des Feldformats durch den eigenen Vorfall vom 01.08.2026 belegt).
- Dauerhafte Transkriptionsfehler wie falscher Key, längerer Netzausfall oder Quota (DIK-012).

Außerdem stuft der Prüfer gebrochene Rettungsversprechen der UI als „Feature-Wunsch“ ein. Der Alert verspricht wörtlich eine erneute Transkription, und die ESC-Sicherung ist ohne jeden Retry-Weg wirkungslos. Für Laien ist das faktischer Datenverlust.

Einzelne Gegenbelege des Prüfers sind sachlich falsch. Bei ONB-006 behauptet er, der alte Key sei beim Anbieter wieder abrufbar; OpenAI- und Groq-Keys werden aber nur einmal angezeigt. An der Schwere ändert das nichts, die Begründung muss aber korrigiert werden.

Inkonsistenzen im Register, die nicht in meiner Liste stehen:
1. LR-DIK-007 (P2) und sein Duplikat LR-DIK-022 (P1, Blocker) beschreiben denselben Activation-Timeout-Paste. Sie brauchen eine gemeinsame Schwere; ich empfehle P2.
2. LR-DIK-001 (P2) und LR-ONB-001 (P0) betreffen denselben Quit-Pfad. Auch hier ist eine Vereinheitlichung nötig; plausibel ist P1/P2, P0 ist überhöht.

Querverweis zu E4: Der Wechsel auf Developer ID verändert die Keychain-ACLs für Bestandsnutzer. ONB-007 und SH-009 sollten deshalb als W6-Testfall laufen.

Doku-Befunde (DOK-004/005) sind konsistent als P2 mit Blocker über die DoD eingestuft.

Daumenregel für den Rest: In Erweitert und Labs sind die Sonnet-Urteile verlässlich. In Kern-Diktat und Onboarding lohnt eine zweite Prüfung immer dann, wenn das Wort „selten“ fällt.

### O2

Gesamtbild: Bei der Schwere sind die Herabstufungen von P1 durchweg berechtigt. Keiner der 26 Befunde ist nach dem Maßstab ein P1. Die GPT-Finder haben systematisch enge Races (Mikrosekunden- bis Sekundenfenster) und Härtungslücken in Erweitert-Features (Subagent-Jobs, Background-Agents, Kontowechsel) als P1 mit Blocker eingestuft. Dort ist das Muster klar zu hart.

Beim Sonnet-Prüfer sehe ich vier wiederkehrende Fehleinschätzungen:

1. Zu weich beim Blocker-Flag, sobald er eine DoD- oder W-Verletzung selbst feststellt. Er schreibt „verletzt formal W7“ (LR-BR-001) bzw. „verletzt formal die DoD-Zeile ‚erklärt‘“ (LR-AK-010) und setzt trotzdem launch_blocker=false, weil der Schaden klein sei. Die Regel lautet aber: Blocker bei Verletzung von DoD oder W1–W7, und zwar unabhängig von der Schwere. Gerade solche billigen Fixes gehören auf die Launch-Liste. Korrigiert habe ich LR-BR-001, LR-AK-010 und LR-SH-007 (dort die DoD-Zeile „kein bekannter Weg zu dauerhaftem Einfrieren“).

2. Gegenbelege, die im Auslösefall nicht gelten. Bei LR-SH-007 schützt der Prewarm nur, wenn die Shell zurückkommt; genau im Hängefall cached er nie. Bei LR-AK-010 stimmt „Empfänger = Provider der Session“ nicht für GPT-Backend-Chats (provider=.claude, ohne Router-URL), deren Inhalt so an Anthropic geht. Bei LR-PJ-001 betrifft die Annahme „nur WhisperM8-eigene Namen“ auch generische Namen wie `jarvis`/`callout`, und jarvis wird sogar ohne Stempelprüfung verschoben. Wenn ein Gegenbeleg eine Annahme über die Umgebung enthält, muss er gegen genau den Auslösefall geprüft werden.

3. Die Launch-Klasse wird mit der Schwere vermischt („Erweitert, also P2“). Der Maßstab definiert die Schwere über die Wirkung, die Klasse entscheidet nur über den Blocker. Am Ergebnis ändert das hier selten etwas, weil die betroffenen Races ohnehin unwahrscheinlich sind. Bei echt kaputten Teilfunktionen in Erweitert (etwa LR-AK-022, Logs-Ansicht im Timeout) sollte die Begründung aber über die Wirkung laufen, nicht über die Klasse.

4. Uneinheitliche Behandlung von Dubletten. LR-AK-024 (P3), LR-AU-001 (P2) und LR-AK-031 (P2) beschreiben denselben Mechanismus (ungelockter Read-Modify-Write auf state.json) mit gleicher Wahrscheinlichkeit. Ich habe sie einheitlich auf P3 gesetzt und rate, sie zusammenzuführen. Ebenso muss LR-BR-004 als Teilaufgabe an LR-BR-003 hängen, sonst fällt eine Voraussetzung für E4 durchs Raster.

Für die Einordnung: Herabstufungen bei Race-, Robustheits- und Hygiene-Befunden sind verlässlich. Bei Befunden mit Bezug zu Datenschutz, Installation/Deinstallation oder fremden Claude-Setups sollte man die Blocker-Entscheidung des Prüfers gezielt gegenprüfen, dort liegt er systematisch zu weich.

## Neue Befunde (O4)

Red-Team-Lauf quer zu den Subsystemen: 13 neue Befunde, alle per grep gegen findings.jsonl auf Dubletten geprüft und im Code belegt. Am schwersten wiegen zwei P1: (1) Der Zwischenablage-Monitor übernimmt während Aufnahme, Transkription UND Nachbearbeitung jeden kopierten Text in den Kontext, ohne die Vertraulich-Markierung der Passwort-Manager (org.nspasteboard.ConcealedType) zu beachten. Ein in dieser Zeit kopiertes Passwort geht an Codex/OpenAI und liegt bis zu 180 Tage im Report-Archiv (Default an). (2) Die Diktiersprache ist ohne gespeicherten Wert fest auf \"de\" gestellt, das Onboarding fragt nicht nach. Englisch- oder anderssprachige Nutzer bekommen beim ersten Diktat (W2) erzwungen deutschen bzw. übersetzten Text; die Einstellungen bieten nur de/en/Auto. Als Kern-P1 verstößt das gegen die DoD, daher launch_blocker. P2: Cmd+V/Cmd+C werden als feste US-Tastencodes gesendet (unter Dvorak/Workman lösen sie andere Kürzel aus); mit fest gewähltem Mikrofon fehlt der Konfigurationsbeobachter, sodass Geräteverlust oder Ruhezustand die Aufnahme still beendet; Chats und Codex erben nur den PATH der Login-Shell, aber keine Proxy-/CA-Variablen (in Firmennetzen kaputt, im Terminal heil); der Kontext-Fallback liest und schreibt die ganze Zwischenablage auf dem Main Thread und kopiert in Editoren ohne Auswahl die aktuelle Zeile. Dazu sieben P3: H.264-Grenze bei Ultrawide-Screen-Clips, nicht persistierte Logger.info-Diagnose (die CLAUDE.md-Regel verfehlt ihr Ziel), mögliche App-Nap-Fehlalarme des Stall-Monitors, Debug-Datei-Log ohne Rotation mit NSException bei voller Platte, /tmp-Usage-Cache auf Mehrbenutzer-Macs, jq-Abhängigkeit der Statusline auf macOS 14, deutsche Stimme bei englischen Callouts. Geprüft und ohne Befund: Pfadkodierung mit Umlauten/Emojis (realpath + UTF-16 korrekt, mit Glob-Fallback), FSEvents auf noch fehlende ~/.claude, Datumsparser (POSIX-Locale gesetzt, wo geparst wird), Overlay über Spaces/Vollbild (canJoinAllSpaces + fullScreenAuxiliary, Anker-Fallback), Upload-Grenze (32 kbit/s ergeben etwa 100 min unter 25 MB), Retention für Hook-, Report- und Failed-Recording-Dateien, macOS-14-API-Verfügbarkeit (Compiler erzwingt sie über .macOS(.v14)). Intel-Architektur, TCC-Neuabfrage nach Update und Cask-Uninstall stehen schon im Register (LR-BR-003/005/006). 15 Laufzeitprüfungen für die manuelle QA-Liste stehen in runtime_checks.

| ID | Schwere | Blocker | Bereich | Titel |
|---|---|---|---|---|
| LR-DIK-023 | P1 | — | diktat/kontext (querliegend: Datenschutz) | Passwörter aus Passwort-Managern landen über den Zwischenablage-Monitor im Diktat-Kontext und für 180 Tage im Report-Archiv |
| LR-DIK-024 | P1 | ja | diktat/onboarding (querliegend: Lokalisierung) | Diktiersprache ist fest auf Deutsch voreingestellt, das Onboarding fragt sie nicht ab |
| LR-DIK-025 | P2 | — | diktat/einfügen (querliegend: Tastaturlayouts) | Cmd+V und Cmd+C werden als feste US-Tastencodes gesendet und lösen bei Dvorak/Workman andere Kürzel aus |
| LR-DIK-026 | P2 | — | diktat/audio (querliegend: Hardware, Ruhezustand) | Mit fest gewähltem Mikrofon endet die Aufnahme bei Geräteverlust oder Ruhezustand still |
| LR-SH-012 | P2 | — | shared/prozessumgebung (querliegend: Firmennetze) | Agent-Chats und Codex erben nur den PATH der Login-Shell, keine Proxy- und Zertifikats-Variablen |
| LR-DIK-027 | P2 | — | diktat/kontext (querliegend: Performance, Fremd-Apps) | Kontext-Fallback liest und schreibt die komplette Zwischenablage auf dem Main Thread und kopiert in VS Code ungefragt die aktuelle Zeile |
| LR-DIK-028 | P3 | — | diktat/visueller-kontext (querliegend: mehrere Monitore) | Screen-Clip nutzt H.264 in voller Displaybreite und scheitert vermutlich auf Ultrawide-/5K-Monitoren |
| LR-SH-013 | P3 | — | shared/logging (querliegend: Diagnose nach Absturz) | Logger.info wird von macOS standardmäßig nicht persistiert; die Absturz-Diagnose-Regel verfehlt ihr Ziel |
| LR-SH-014 | P3 | — | shared/perf (querliegend: Langzeitbetrieb) | Stall-Monitor ohne App-Nap-Ausnahme kann im Hintergrund falsche main_thread_blocked_ongoing-Fehler melden |
| LR-SH-015 | P3 | — | shared/logging | Debug-Datei-Log wächst ohne Rotation und nutzt das NSException-werfende FileHandle.write |
| LR-KO-012 | P3 | — | konten/usage (querliegend: mehrere macOS-Benutzer) | Usage-Cache liest weiterhin weltschreibbare /tmp-Dateien; auf Mehrbenutzer-Macs zeigt die App fremde Limits |
| LR-SH-016 | P3 | — | shared/statusline (querliegend: frischer Mac) | Installierbare Statusline braucht jq, das macOS 14 nicht mitbringt; weder Cask noch Einstellungen prüfen das |
| LR-SH-017 | P3 | — | shared/speech (querliegend: Lokalisierung) | Voice-Callouts wählen immer eine deutsche Stimme, auch für englische Ansagen |

### LR-DIK-023 · Passwörter aus Passwort-Managern landen über den Zwischenablage-Monitor im Diktat-Kontext und für 180 Tage im Report-Archiv

*P1 · diktat/kontext (querliegend: Datenschutz) · Konfidenz hoch · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:57-67`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:76-100`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:165-196`, `WhisperM8/Support/AppPreferences.swift:121-124`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:45-47`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:161`, `WhisperM8/Services/Dictation/SelectedContextService.swift:123-145`

**Szenario:** Der Nutzer diktiert eine E-Mail (Modus mit Codex-Nachbearbeitung). Während Transkription und Umformulierung laufen (mehrere Sekunden), kopiert er in 1Password/Bitwarden/Schlüsselbund ein Passwort, um sich irgendwo anzumelden. Der 500-ms-Monitor läuft bewusst während isRecording, isTranscribing UND isPostProcessing, liest jeden neuen String der Zwischenablage und hängt ihn an selectedText an. Die von Passwort-Managern gesetzte Markierung org.nspasteboard.ConcealedType/TransientType wird nirgends geprüft (grep ohne Treffer). Das Passwort geht damit in den Nachbearbeitungs-Prompt an Codex/OpenAI und wird — auch im Rohmodus ohne Nachbearbeitung — als selectedText im Report-JSON unter Application Support bis zu 180 Tage gespeichert. Der Default für die Kontexterfassung ist an. Zusätzlich schreibt PasteboardSnapshot.restore einen zuvor kopierten Inhalt mit neuem changeCount zurück; Passwort-Manager, die ihr Auto-Leeren am changeCount festmachen, löschen dann nicht mehr.

**Warum bisher übersehen:** Die Diktat-Finder haben Kontexterfassung und Clipboard-Rennen (LR-DIK-016) funktional geprüft; die Interaktion mit Drittanwendungen, die Zwischenablage-Inhalte als vertraulich markieren, liegt außerhalb des Subsystems und ist nur über die nspasteboard.org-Konvention sichtbar.

**Fix:** In observeClipboardChange/importClipboardText (und in captureViaClipboard) Inhalte mit org.nspasteboard.ConcealedType, org.nspasteboard.TransientType oder org.nspasteboard.AutoGeneratedType überspringen und nur deren Vorhandensein loggen. Monitor nach Aufnahmeende auf ausdrücklich angefordertes Kopieren beschränken oder in der UI erklären. Restore nur ausführen, wenn der Snapshot keinen Concealed-Typ trägt. Test mit synthetischem Pasteboard-Typ.

### LR-DIK-024 · Diktiersprache ist fest auf Deutsch voreingestellt, das Onboarding fragt sie nicht ab

*P1 · Launch-Blocker · diktat/onboarding (querliegend: Lokalisierung) · Konfidenz hoch · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Support/AppPreferences.swift:36-38`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:39`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:180-189`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:39-47`, `WhisperM8/Models/PostProcessingTemplate.swift:36`, `WhisperM8/Views/OnboardingView.swift (kein Sprachschritt: grep nach language/Sprache ohne Treffer)`

**Szenario:** Ein englisch-, französisch- oder spanischsprachiger Nutzer installiert die App (E1 c: Englisch ist Basissprache) und macht im Onboarding das Testdiktat. AppPreferences.language fällt ohne gespeicherten Wert auf "de" zurück, und dieser Wert geht als language-Feld an OpenAI/Groq. Whisper erzwingt dann deutsche Ausgabe; englische Sprache kommt übersetzt oder phonetisch verstümmelt heraus. Auch die Nachbearbeitungs-Vorlagen bekommen Language: de. In den Einstellungen stehen nur de, en und Auto zur Wahl, für andere Sprachen bleibt nur Auto. W2 liefert für Nicht-Deutschsprachige damit falschen Text, ohne dass der Nutzer erkennt, warum.

**Warum bisher übersehen:** Alle Finder arbeiten auf einem deutschen System mit deutschem Nutzerprofil; der Default fällt nur bei einer frischen Installation in einer anderen Sprache auf. Das Lokalisierungs-Inventar betrachtet UI-Strings, nicht fachliche Defaults.

**Fix:** Default aus Locale.preferredLanguages ableiten (unterstützte Sprache, sonst Auto) und im Onboarding vor dem Testdiktat einen Sprachschritt zeigen. Die Optionen auf die von Whisper unterstützten Sprachen erweitern. Gespeicherte Werte bestehender Nutzer nicht verändern.

### LR-DIK-025 · Cmd+V und Cmd+C werden als feste US-Tastencodes gesendet und lösen bei Dvorak/Workman andere Kürzel aus

*P2 · diktat/einfügen (querliegend: Tastaturlayouts) · Konfidenz hoch · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Dictation/PasteService.swift:169-183`, `WhisperM8/Services/Dictation/SelectedContextService.swift:99-113`, `WhisperM8/Services/VoiceGate/CodexMuteToggler.swift:48`

**Szenario:** Auto-Paste erzeugt ein CGEvent mit virtualKey kVK_ANSI_V (Tastencode 9) plus Cmd, die Kontexterfassung eines mit kVK_ANSI_C (Code 8). Apps lösen Menükürzel über das Zeichen des aktiven Layouts auf. Unter Dvorak liegt an Code 9 ein K und an Code 8 ein J: Auto-Paste sendet Cmd+K (Slack-Schnellsuche, Link einfügen, Browser-Suchfeld), die Kontexterfassung Cmd+J (Downloads in Chrome). Unter Workman ist Code 9 ein C, Auto-Paste kopiert also statt einzufügen. Das Diktat erscheint nicht, stattdessen passiert eine fremde Aktion. QWERTZ und AZERTY sind nicht betroffen. Es gibt keine Layout-Abfrage (TISCopyCurrentKeyboardLayoutInputSource/UCKeyTranslate, grep ohne Treffer).

**Warum bisher übersehen:** Diktat-Finder prüften Fokus und Timing des Einfügens; das Layout-Thema zeigt sich nur auf Systemen mit alternativem Layout und ist im Code nur an der Konstante erkennbar.

**Fix:** Den Tastencode für "v" bzw. "c" zur Laufzeit über UCKeyTranslate aus dem aktiven ASCII-fähigen Layout ermitteln (Fallback kVK_ANSI_V), wie es etablierte Clipboard-Tools tun. Alternativ beim Einfügen das Menü-Item Bearbeiten > Einsetzen per AX auslösen.

### LR-DIK-026 · Mit fest gewähltem Mikrofon endet die Aufnahme bei Geräteverlust oder Ruhezustand still

*P2 · diktat/audio (querliegend: Hardware, Ruhezustand) · Konfidenz mittel · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Dictation/AudioRecorder.swift:66-71`, `WhisperM8/Services/Dictation/AudioRecorder.swift:236-257`, `WhisperM8/Services/Dictation/AudioDeviceManager.swift:66-77`

**Szenario:** Der Nutzer hat in den Einstellungen ein bestimmtes Eingabegerät gewählt (USB-Headset, externes Mikrofon, eingebautes Mikrofon). setupConfigurationObserver bricht für alles außer System Default sofort ab, es gibt also keinen Beobachter für AVAudioEngineConfigurationChange. Wird das Gerät während der Aufnahme abgezogen, wechselt die Bluetooth-Route oder klappt der Mac zu und wacht wieder auf, stoppt AVAudioEngine von selbst. Overlay und Timer laufen weiter, der Rest des Diktats wird nicht aufgenommen; beim Stop wird nur der Anfang transkribiert. Kein Hinweis an den Nutzer. Es gibt außerdem keinen Sleep/Wake-Beobachter (grep auf willSleep/didWake ohne Treffer).

**Warum bisher übersehen:** LR-DIK-004/005 behandeln Fehler INNERHALB des Beobachter-Pfads; dass der Pfad für ausdrücklich gewählte Geräte gar nicht existiert, sieht man nur, wenn man die Geräteauswahl (F-DIK-05) und den Ruhezustand quer zum Recorder betrachtet.

**Fix:** Den Konfigurationsbeobachter für alle Modi installieren. Bei Verlust des gewählten Geräts kontrolliert auf System Default wechseln oder die Aufnahme sichtbar stoppen und die Teilaufnahme über FailedRecordingsStore retten. Engine-Laufzustand im Pegel-Timer prüfen.

### LR-SH-012 · Agent-Chats und Codex erben nur den PATH der Login-Shell, keine Proxy- und Zertifikats-Variablen

*P2 · shared/prozessumgebung (querliegend: Firmennetze) · Konfidenz mittel · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:129`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:174-193`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:465`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:434`, `WhisperM8/Views/AgentTerminalView.swift:905-908`

**Szenario:** In einer Firmenumgebung mit Pflicht-Proxy oder TLS-Inspektion setzt der Nutzer bzw. die IT HTTPS_PROXY, NO_PROXY, NODE_EXTRA_CA_CERTS oder SSL_CERT_FILE in ~/.zprofile/~/.zshrc. Im Terminal funktionieren claude und codex. WhisperM8 fragt aus der Login-Shell nur echo $PATH ab und startet claude/codex direkt (nicht über eine Shell) mit der launchd-Umgebung der GUI-App. Die Proxy- und CA-Variablen fehlen, die CLIs ignorieren die macOS-Systemproxy-Einstellung. Ergebnis: Chats und Codex-Nachbearbeitung brechen mit Verbindungs- oder Zertifikatsfehlern ab, obwohl dieselbe CLI im Terminal läuft. Dasselbe gilt für ANTHROPIC_API_KEY/OPENAI_API_KEY-Nutzer ohne Abo-Login.

**Warum bisher übersehen:** Die Finder haben die Umgebungs-Bereinigung (Secrets, CLAUDE_CODE_*) geprüft, also was zu viel vererbt wird; dass gezielt benötigte Variablen fehlen, zeigt sich nur in Netzen mit Proxy und wurde auf dem Entwicklungsrechner nie ausgelöst.

**Fix:** Aus der Login-Shell zusätzlich eine kleine Positivliste übernehmen (HTTPS_PROXY/HTTP_PROXY/ALL_PROXY/NO_PROXY in beiden Schreibweisen, NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, REQUESTS_CA_BUNDLE), z. B. per env -0 statt echo $PATH. Keine Secrets übernehmen. Diagnose-Hinweis bei Verbindungsfehlern.

### LR-DIK-027 · Kontext-Fallback liest und schreibt die komplette Zwischenablage auf dem Main Thread und kopiert in VS Code ungefragt die aktuelle Zeile

*P2 · diktat/kontext (querliegend: Performance, Fremd-Apps) · Konfidenz mittel · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Dictation/SelectedContextService.swift:8-40`, `WhisperM8/Services/Dictation/SelectedContextService.swift:76-97`, `WhisperM8/Services/Dictation/SelectedContextService.swift:123-145`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:18-22`

**Szenario:** Bei jedem Diktat in einer App ohne AX-Textauswahl (Electron-Apps wie Slack/VS Code, viele Browser-Felder) fällt die Erfassung auf Cmd+C zurück. PasteboardSnapshot.capture fordert vorher für JEDES Item JEDEN Typ als Data an, restore schreibt alles zurück, beides im @MainActor-Task. Liegt in der Zwischenablage ein großes Bild, eine Excel-Auswahl mit vielen Formaten oder versprochene Daten, muss die Quell-App alle Varianten synchron liefern; der Main Thread steht, das Overlay friert ein und der Stop-Hotkey wird verzögert. Zweiter Effekt: In VS Code und anderen Editoren kopiert Cmd+C ohne Auswahl die ganze aktuelle Zeile, die dann als markierter Text im Kontext landet und an Codex geht.

**Warum bisher übersehen:** LR-DIK-016 betrachtet das Zeitfenster zwischen Snapshot und Restore; Inhaltsgröße, Lazy-Provider anderer Apps und Editor-Verhalten bei leerer Auswahl liegen außerhalb der Diktat-Logik.

**Fix:** Snapshot nur für Text-/kleine Typen oder off-main mit Größen- und Zeitlimit; bei großem Inhalt den Fallback überspringen. Fallback nur auslösen, wenn AX eine nicht-leere Auswahl meldet oder eine Allowlist greift; Bundle-IDs mit Copy-Line-Verhalten (VS Code, JetBrains) ausnehmen.

### LR-DIK-028 · Screen-Clip nutzt H.264 in voller Displaybreite und scheitert vermutlich auf Ultrawide-/5K-Monitoren

*P3 · diktat/visueller-kontext (querliegend: mehrere Monitore) · Konfidenz niedrig · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Dictation/ManualScreenClipSession.swift:50-72`, `WhisperM8/Services/Dictation/ManualScreenClipSession.swift:86-89`

**Szenario:** Breite und Höhe kommen direkt aus CGDisplayPixelsWide/High des Ziel-Displays und gehen unverändert in AVAssetWriter mit H.264. Die Hardware-Encoder von Apple Silicon unterstützen H.264 nur bis etwa 4096 Pixel Breite. Auf einem 5120x1440-Ultrawide oder einem 5K/6K-Display im nativen Modus scheitert vermutlich startWriting/append, der Screen-Clip liefert dann einen Fehler oder ein leeres Video.

**Warum bisher übersehen:** Wird nur mit einem bestimmten Monitor-Setup ausgelöst; die Finder hatten keinen Anlass, Encoder-Grenzen gegen Displaygrößen zu prüfen.

**Fix:** Ausgabegröße auf maximal 3840 bzw. 4096 Breite skalieren (Seitenverhältnis halten) oder HEVC verwenden; bei Fehlern klare Meldung.

### LR-SH-013 · Logger.info wird von macOS standardmäßig nicht persistiert; die Absturz-Diagnose-Regel verfehlt ihr Ziel

*P3 · shared/logging (querliegend: Diagnose nach Absturz) · Konfidenz mittel · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Shared/Logger.swift:44-58`, `WhisperM8/Services/Dictation/AudioRecorder.swift:161`, `WhisperM8/Services/Dictation/AudioRecorder.swift:352`, `WhisperM8/Info.plist (kein OSLogPreferences-Eintrag)`

**Szenario:** CLAUDE.md und der Kommentar in Logger.info gehen davon aus, dass .info im persistenten Log-Store landet. Laut Apples Unified-Logging-Modell werden Info-Meldungen ohne Konfigurationsprofil nur im Speicher gehalten und nur bei log collect bzw. nach Fault-Ereignissen gesichert. Nach einem Absturz oder Neustart fehlen genau die Audio-Zeilen, die den Absturz erklären sollten (Tap-Fehler, Formatwechsel); 120 .info-Aufrufe sind betroffen. Für den Nutzer folgenlos, für die Fehleranalyse nach dem Launch aber eine Lücke.

**Warum bisher übersehen:** Auf dem Entwicklungsrechner läuft meist ein log stream oder Instruments mit, dann sind Info-Meldungen sichtbar; der Unterschied zeigt sich nur bei einer Analyse im Nachhinein.

**Fix:** Absturzrelevante Ereignisse auf .notice/.error heben oder per OSLogPreferences im Info.plist die Persistenz für das Subsystem auf Info setzen; danach CLAUDE.md-Regel korrigieren.

### LR-SH-014 · Stall-Monitor ohne App-Nap-Ausnahme kann im Hintergrund falsche main_thread_blocked_ongoing-Fehler melden

*P3 · shared/perf (querliegend: Langzeitbetrieb) · Konfidenz niedrig · Laufzeitprüfung nötig*

**Beleg:** `WhisperM8/Services/Shared/MainThreadStallMonitor.swift:86-99`, `WhisperM8/Services/Shared/StallWatchdog.swift:29`, `WhisperM8/Services/Shared/StallWatchdog.swift:95-102`, `WhisperM8/Info.plist (kein NSAppSleepDisabled, kein beginActivity im Code)`

**Szenario:** Der 100-ms-Timer läuft dauerhaft und ohne Toleranz, der Watchdog meldet ab 1 s fehlenden Herzschlag auf Error-Level. Ist die App lange ohne sichtbares Fenster im Hintergrund, darf macOS sie per App Nap drosseln und Timer stark zusammenfassen. Verzögert sich der Main-Timer dadurch über 1 s, entstehen Fehlalarme, die die DoD-Messung (kein main_thread_blocked_ongoing) und spätere Analysen verfälschen; zugleich verhindern 10 Wakeups/s Energiesparen.

**Warum bisher übersehen:** Bei aktiver Entwicklung ist die App fast immer sichtbar und aktiv; App Nap greift erst im echten Alltagsbetrieb über Stunden.

**Fix:** Timer mit Toleranz versehen und Herzschlag-Alter nur werten, wenn die App nicht von App Nap gedrosselt ist (NSApplication.occlusionState/aktive Fenster), oder Monitor nur bei sichtbaren Fenstern bzw. Detail-Stufe laufen lassen.

### LR-SH-015 · Debug-Datei-Log wächst ohne Rotation und nutzt das NSException-werfende FileHandle.write

*P3 · shared/logging · Konfidenz hoch*

**Beleg:** `WhisperM8/Services/Shared/Logger.swift:60-90`, `WhisperM8/Support/AppPreferences.swift:79-82`

**Szenario:** Ein Nutzer schaltet auf Bitte des Supports debugFileLoggingEnabled ein und vergisst es. Logger.debug wird an rund 150 Stellen aufgerufen, die Datei unter ~/Library/Logs/WhisperM8 wächst unbegrenzt. Läuft die Platte voll, wirft handle.write(_:) bei ENOSPC eine NSFileHandleOperationException, die Swift nicht fängt, und die App beendet sich samt aller Chats. Das widerspricht der eigenen Regel, nur write(contentsOf:) zu nutzen. Nur per defaults write auslösbar, daher P3.

**Warum bisher übersehen:** Datei-Logging gilt als intern und ist standardmäßig aus; die SIGPIPE/FileHandle-Regel wurde nur für Pipes angewendet, nicht für reguläre Dateien bei voller Platte.

**Fix:** write(contentsOf:) mit try? verwenden, Größenlimit mit einfacher Rotation (z. B. 10 MB, eine Vorversion) einführen.

### LR-KO-012 · Usage-Cache liest weiterhin weltschreibbare /tmp-Dateien; auf Mehrbenutzer-Macs zeigt die App fremde Limits

*P3 · konten/usage (querliegend: mehrere macOS-Benutzer) · Konfidenz hoch*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift:250-269`

**Szenario:** cachedUsage liest neben $TMPDIR auch den Alt-Pfad /tmp/claude-usage-cache-<profil>.json. /tmp ist für alle Benutzer gemeinsam; eine Datei eines anderen Benutzers (ältere Version oder bewusst abgelegt) mit Namen ...-main.json wird gelesen, wenn der eigene Cache fehlt. Die Usage-Anzeige zeigt dann die Limits eines fremden Kontos oder manipulierte Werte. Kein Secret-Abfluss, aber falsche Entscheidungsgrundlage.

**Warum bisher übersehen:** Statusline-Skript und App wurden bewusst auf $TMPDIR umgestellt; der Lese-Fallback auf den Alt-Pfad fällt nur mit einem zweiten Benutzerkonto auf.

**Fix:** Alt-Pfad nur lesen, wenn die Datei dem eigenen UID gehört (stat st_uid), oder den Fallback nach einer Übergangszeit entfernen.

### LR-SH-016 · Installierbare Statusline braucht jq, das macOS 14 nicht mitbringt; weder Cask noch Einstellungen prüfen das

*P3 · shared/statusline (querliegend: frischer Mac) · Konfidenz hoch*

**Beleg:** `WhisperM8/Resources/whisperm8-statusline.sh:12-16`, `WhisperM8/Resources/whisperm8-subagent-statusline.sh:6-13`, `scripts/update-cask.sh:38`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:528-600`

**Szenario:** Auf einem frischen macOS 14 installiert der Nutzer in den Einstellungen die Statusline. Die Einstellungsseite meldet Erfolg, Claude Code zeigt danach aber nur noch die Zeile "whisperm8-statusline: jq fehlt (brew install jq)". Der Cask deklariert kein depends_on formula: "jq", die Settings-Seite prüft jq nicht.

**Warum bisher übersehen:** Auf dem Entwicklungsrechner ist jq über Homebrew bzw. macOS 15+ vorhanden.

**Fix:** Im Cask depends_on formula: "jq" ergänzen oder vor der Installation jq prüfen und einen geführten Hinweis zeigen.

### LR-SH-017 · Voice-Callouts wählen immer eine deutsche Stimme, auch für englische Ansagen

*P3 · shared/speech (querliegend: Lokalisierung) · Konfidenz hoch*

**Beleg:** `WhisperM8/Services/Shared/SpeechCallouts.swift:120-128`

**Szenario:** Ohne explizit gewählte Stimme nimmt voice(identifier:) die beste installierte Stimme mit Sprachpräfix de, sonst de-DE. Bei englischer UI (E1 c) und englischen Ansagetexten liest eine deutsche Stimme Englisch vor, schwer verständlich.

**Warum bisher übersehen:** Entwicklung und Test ausschließlich mit deutschem Nutzer und deutschen Ansagen.

**Fix:** Stimme nach Sprache des Ansagetexts (NLLanguageRecognizer) oder nach Locale.preferredLanguages wählen, Deutsch nur als Fallback.

## Einzelurteile

### LR-DIK-004 · Recorderfehler beim Gerätewechsel umgehen die Aufnahmerettung

*O1 · Herabstufung zurückgenommen → P1 · Launch-Blocker*

Der Code bestätigt alle drei Pfade. Beim Formatfehler nach 300 ms plus 5×100 ms und beim Fehler im Engine-Neustart setzt AudioRecorder nur isRecording=false. Engine, audioFile und recordingURL bleiben stehen, und der Coordinator erfährt nichts, weil kein Callback und kein Observer existiert. Der Nutzer spricht danach unter Umständen minutenlang weiter. Beim Stop liefert der Guard in stopRecording nil, der Nutzer sieht „No audio file was created.“, und die vor dem Wechsel geschriebene Teilaufnahme liegt verwaist in tmp. Den Rettungspfad (preserveRecording) erreicht der Fall nie. Beim Tap-Reinstall-Fehler bleibt isRecording=true, aber ohne Tap: das Diktat wird still abgeschnitten und nur der Anfang transkribiert. Das Argument „seltener Randfall“ trägt nicht. Der Config-Observer ist genau im Default-Modus „System Default“ aktiv. Auslöser ist ein normaler Gerätewechsel (AirPods einsetzen oder abziehen, Wechsel des Bluetooth-Profils). Dass das Format über mehr als eine Sekunde instabil bleibt und installTap deswegen wirft, belegt der eigene Kommentar zum Vorfall 01.08.2026 (1,6 s). Nach dem Schweremaßstab ist das ein seltener, aber im normalen Gebrauch auslösbarer Verlust gesprochener Nutzerdaten in einer Kern-Funktion (F-DIK-01/05), also P1. Die DoD verlangt keine P1 in Kern, daher Blocker. Die Lösung ist überschaubar: Abschluss an den Coordinator melden und die URL unabhängig vom Flag finalisieren.

**Belege:** `WhisperM8/Services/Dictation/AudioRecorder.swift:307-313 (Formatfehler: nur isRecording=false, recordingURL/engine bleiben)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:342-351 (Tap-Reinstall-Fehler: isRecording bleibt true, Observer nicht neu installiert → stille Kürzung)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:358-368 (Engine-Restart-Fehler: isRecording=false)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:195-200 (stopRecording-Guard liefert nil, recordingURL wird nicht freigegeben)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:69 (Observer nur bei System Default = Standardauswahl)`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:325-339 (nil-URL → „No audio file was created.“, kein preserveRecording)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:396-401 (Vorfall 01.08.2026: 1,6 s Formatwechsel im Feld)`

### LR-DIK-005 · Veraltete Gerätewechsel-Tasks starten nach Stop erneut

*O1 · Herabstufung getragen → P2*

Die Race ist echt. handleConfigurationChange hält die lokale Engine über den Sleep von 300 bis 800 ms und prüft danach weder Generation noch isRecording. Ein Stop allein ist harmlos, weil audioFile dann nil ist und die alte Engine beim Funktionsende freigegeben wird. Schaden entsteht nur bei Stop und Neustart innerhalb dieses Fensters während eines Gerätewechsels. Dann schreibt der alte Tap in die Datei des neuen Laufs, der Converter wird überschrieben und setupConfigurationObserver hängt einen doppelten Observer an die neue Engine. Das ergibt verunstaltetes Audio, aber keinen Absturz. Das Fenster ist schmal und zusätzlich an einen Gerätewechsel gebunden, deshalb P2. Am besten zusammen mit DIK-004 beheben (Generationszähler).

**Belege:** `WhisperM8/Services/Dictation/AudioRecorder.swift:268-276 (Guard nur vor dem Sleep)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:285-287 (300-ms-Sleep ohne Re-Check)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:323-331 (Converter des neuen Laufs überschrieben)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:355-362 (Start der alten Engine + Observer auf self.engine)`

### LR-DIK-006 · Schreibfehler während der Aufnahme bleiben unsichtbar

*O1 · Herabstufung getragen → P2*

Der stille Catch ist bestätigt: nach dem ersten erfolgreichen Buffer gibt es weder Log noch Eskalation, und Converter-Fehler werden verschluckt. Als Auslöser bleibt aber praktisch nur eine volle Platte oder ein I/O-Fehler mitten in einer Aufnahme. AAC mit 16 kHz mono und 32 kbit/s erzeugt etwa 240 KB pro Minute. Im normalen Gebrauch ist das kaum auslösbar, deshalb P2. Der Fix (Flag im Callback setzen, asynchron an Main melden) ist trotzdem sinnvoll.

**Belege:** `WhisperM8/Services/Dictation/AudioRecorder.swift:531-535 (Catch loggt nur bei buffersWritten==0)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:505-516 (Converter-Status != haveData wird still verworfen)`, `WhisperM8/Services/Dictation/AudioRecorder.swift:141-146 (16 kHz mono, 32 kbit/s)`

### LR-DIK-007 · Auto-Paste prüft weder Ziel-Fenster noch erfolgreichen Fokuswechsel

*O1 · Herabstufung getragen → P2*

Dass Fenster oder Gespräch innerhalb derselben App wechseln, gehört zur bewussten Diktat-Semantik: Ziel ist die App, nicht das Feld. Für die geforderte AX-Validierung des Eingabefelds ist das Verhältnis von Aufwand zu Risiko schlecht. Der eigentliche Mangel ist der Teilfall „Aktivierung scheitert → trotzdem pasten“ (PasteService.swift:126-142). Der Text landet dann in der zufällig vorderen App, liegt aber zusätzlich in der Zwischenablage. Daten gehen nicht verloren, eine automatische Absendung findet nicht statt. P2 trägt. Achtung, Inkonsistenz: Genau dieser Teilfall steht als LR-DIK-022 mit P1/Blocker im Register (also_reported_by). Die Duplikate müssen eine gemeinsame Schwere bekommen. Für beide halte ich P2 für richtig.

**Belege:** `WhisperM8/Services/Dictation/PasteService.swift:81-92 (activate + waitForActivation + Paste ohne Ergebnisprüfung)`, `WhisperM8/Services/Dictation/PasteService.swift:126-142 (Timeout → 'pasting anyway')`, `WhisperM8/Windows/RecordingPanel.swift:442-444 (nur NSRunningApplication gemerkt)`

### LR-DIK-009 · Entfernte Screen-Clips behalten ihre versendbaren Einzelbilder

*O1 · Herabstufung getragen → P2*

Bestätigt: removeAttachmentFromContext entfernt nur den Clip, und dessen visualFrames gehen weiter über visualAttachments an Codex und in die Ziel-App. Die chipSegments lassen visualFrames weg. Der Datenabfluss ist aber nicht verborgen: das Menü „Visuals (N)“ führt jeden Frame einzeln mit Entfernen-Aktion (allAttachments enthält visualFrames), und der Nutzer hat den Clip selbst aufgenommen. Die DoD-Zeile „erklärt und abschaltbar“ ist damit formal erfüllt, das UI-Modell aber irreführend. P2 und kein Blocker passt.

**Belege:** `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:194-210 (nur Element mit ID entfernt)`, `WhisperM8/Models/TranscriptContextBundle.swift:106-116 (visualAttachments/allAttachments enthalten visualFrames)`, `WhisperM8/Views/OverlayPhase.swift:140-175 (Chip ohne Frames)`, `WhisperM8/Views/RecordingOverlayView.swift:126-140 (Frames einzeln gelistet und entfernbar)`

### LR-DIK-010 · Ein startender Screen-Clip kann den Diktatabbruch überleben

*O1 · Herabstufung getragen → P2*

Bestätigt, und die Folge ist schlimmer als „kurz“. activeClipSession wird erst nach den awaits gesetzt, und cancelRecording bricht screenClipLimitTask ab, bevor der Start fertig ist. Danach plant startScreenClip ein neues Limit, das wegen isRecording==false nichts stoppt. Die Aufnahme des ganzen Displays mit 12 fps läuft also bis zum App-Ende in eine lokale MP4, und jeder weitere Clip scheitert mit alreadyRecording. Abgeflossen wird nichts, macOS zeigt den Aufnahme-Indikator, und Auslöser ist ein Abbruch innerhalb von etwa 0,1 bis 0,5 s nach dem Clip-Start. Das bleibt eine schmale Race, deshalb P2. Für den Fix muss das harte Limit unabhängig von isRecording greifen.

**Belege:** `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:130-152 (Session erst nach awaits gesetzt)`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:169-178 (cancelActiveClip findet nichts)`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:9-16,47-53 (neues Limit, Guard isRecording verhindert Stop)`, `WhisperM8/Services/Dictation/ManualScreenClipSession.swift:51-57 (volle Auflösung, 12 fps)`

### LR-DIK-011 · Später Kontext wird verarbeitet, aber nicht zugestellt oder archiviert

*O1 · Herabstufung getragen → P2*

Die Asymmetrie zwischen Live-Bundle (Prompt) und eingefrorenem Bundle (Zustellung, Report, Cleanup) ist bestätigt. Die Nutzung des Live-Bundles im Prompt ist dokumentierte Absicht. Folgen sind ein Prompt, der auf ein nicht mitgeliefertes Bild verweisen kann, ein unvollständiger Report und eine liegengebliebene Temp-Datei. Das ist ein Korrektheitsmangel ohne Verlust oder Hänger und gilt nur in Nachbearbeitungsmodi bei Kopien während der Verarbeitung. P2.

**Belege:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:308-310 (frozenContextBundle)`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:168-175 (Live-Bundle im Prompt, kommentierte Absicht)`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:77-82,124-151 (Zustellung/Report/Cleanup mit eingefrorenem Bundle)`

### LR-DIK-012 · Gesicherte Aufnahmen haben keinen später erreichbaren Retry-Weg

*O1 · Herabstufung zurückgenommen → P1 · Launch-Blocker*

Das ist kein Feature-Wunsch, sondern ein gebrochenes Versprechen in einem Kern-Pfad. Der Alert verspricht wörtlich „Die Aufnahme wurde gesichert und kann erneut transkribiert werden.“ Retry gibt es aber nur im modalen Alert (runModal). Außer dem Alert-Button ruft niemand retryPendingTranscription auf, und es gibt weder Menüeintrag noch Liste der FailedRecordings. Bei dauerhaften Fehlern bringt der Retry-Button nichts: ein falscher oder abgelaufener Key (W2, Erstnutzer), ein Netz, das länger ausfällt, oder ein Quota-Limit. Der Nutzer muss den Alert schließen, um die Ursache zu beheben, und damit ist das Diktat für ihn unerreichbar. Die Datei liegt nur noch versteckt unter ~/Library/Application Support/WhisperM8/FailedRecordings und wird nach 7 Tagen bzw. ab 10 Einträgen weggeräumt. Beim ESC-Pfad („ein versehentliches ESC darf kein Diktat kosten“) wird gesichert, eine Wiederholung ist aber überhaupt nicht möglich. Für Laien ist das ein faktischer Datenverlust bei normalen Ereignissen (Netzfehler, falscher Key). Nach dem Schweremaßstab P1 in Kern, damit Blocker laut DoD. Ein Menüeintrag „Letzte Aufnahme erneut transkribieren“ samt persistierter Retry-Metadaten genügt als Fix (Aufwand S/M).

**Belege:** `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:97-109 (Alert-Text verspricht Retry, runModal)`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:31-38 (einziger Retry-Auslöser)`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:45-60 (ESC: sichern ohne jeden Retry-Weg)`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:62,443 (pendingRetry nur flüchtig; grep: keine weiteren Aufrufer/UI)`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:47-55 (maxCount 10, maxAge 7 Tage)`

### LR-DIK-013 · Hängende Codex-Nachbearbeitung hat keine Abschlussgarantie

*O1 · Herabstufung getragen → P2*

Bestätigt: waitUntilExit hat keine Deadline, und cancel() schickt nur SIGTERM. Die Pipes werden aber per readabilityHandler laufend geleert, ein Pipe-Deadlock entsteht also nicht. Der Cancel-Button im Overlay beendet einen normal hängenden Codex-Prozess, danach greift der Raw-Fallback. Dauerhaft blockiert ist der Nutzer nur, wenn Codex SIGTERM ignoriert. Als Härtung P2 (großzügige Deadline plus TERM→KILL).

**Belege:** `WhisperM8/Services/Dictation/CodexPostProcessor.swift:91-99 (readabilityHandler drainiert)`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:116 (waitUntilExit ohne Deadline)`, `WhisperM8/Services/Dictation/CodexSupport.swift:30-39 (nur terminate)`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:370-373 (Cancel-Button-Pfad)`

### LR-DIK-014 · Parallele Codex-Läufe teilen sich einen falschen Cancel-Slot

*O1 · Herabstufung getragen → P3*

Der Singleton mit nur einem Slot ist bestätigt. Auslösen lässt sich der Fehler aber nur, wenn der Nutzer in den Settings eine Test-Lab-Vorschau startet, während ein Diktat gerade wenige Sekunden lang nachbearbeitet wird. Die Folge ist ein falscher Abbruch oder Raw-Fallback ohne Datenverlust, deshalb P3.

**Belege:** `WhisperM8/Services/Dictation/CodexSupport.swift:6-48 (ein current-Slot, globales cancelledByUser)`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:370-373 (Cancel nur bei isPostProcessing)`

### LR-VG-001 · VoiceGate sperrt Auswertung bei Diktat oder Abschalten nicht sofort

*O1 · Herabstufung getragen → P3*

Technisch stimmt der Befund: Die Pause greift erst beim 10-s-Tick, und handle/performPress prüfen weder isEnabled noch isRecording erneut. Das Feature ist aber Labs, standardmäßig aus und braucht eine manuelle Kürzel-Einrichtung in Codex. Die Folge ist ein ungewollter Mute-Toggle in Codex samt Fokuswechsel. Die Paste-Zustellung des Diktats nutzt die vorher gemerkte Ziel-App und bleibt unberührt. Kern, Daten und Sicherheit sind nicht betroffen, deshalb P3.

**Belege:** `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:124-130 (stop synchron)`, `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:276-298 (handle ohne Re-Check)`, `WhisperM8/Services/VoiceGate/CodexMuteToggler.swift:73-89`

### LR-KO-005 · Ein laufendes inaktives Claude-Profil lässt sich ohne Prozessschutz entfernen

*O1 · Herabstufung getragen → P2*

Bestätigt: Remove hat keinen Laufzeit-Guard wie Rename. Die Aktion löst der Nutzer aber bewusst über einen Warndialog aus, und der Ordner landet im Papierkorb, ist also rettbar. Der laufende Prozess spaltet höchstens den weiteren Verlauf ab. Betroffen ist Erweitert (F-KO-01) ohne endgültigen Verlust, deshalb P2. Den Fix sollte man trotzdem als Einzeiler mitnehmen (gleicher Guard wie bei Rename, nach der Bestätigung erneut prüfen).

**Belege:** `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:231-234 (nur aktives Profil gesperrt)`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:612-635 (trashItem ohne Laufzeitprüfung)`

### LR-KO-006 · Profil-Rename bricht profilgebundene Plugin-Registrierungen für alle Konten

*O1 · Herabstufung getragen → P2*

Bestätigt: Rename hat keinen pluginRegistryReferences-Guard, Promote und Remove haben einen. Nach einem seltenen Rename sind die Plugins still nicht mehr ladbar, eine Neuinstallation behebt das. Kein Datenverlust, Erweitert, P2. Der Fix ist trivial (denselben Guard verwenden).

**Belege:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:449-463 (Rename ohne Guard)`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+Promote.swift:81-84 (Guard bei Promote)`

### LR-KO-007 · Ein Keychain-Lesefehler wird beim Rename als fehlender Login behandelt

*O1 · Herabstufung getragen → P2*

Bestätigt: Jeder Status ungleich 0 gilt als „kein Login“. Das Keychain-Item bleibt aber unter dem alten Service-Namen erhalten, und Zurückbenennen stellt den Login wieder her. Auslöser ist ein verweigerter Keychain-Prompt bei einer seltenen Admin-Aktion (Erweitert). P2.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:457-477`, `Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:394-406 (nur Status 44 getestet)`

### LR-KO-008 · Transcript-Kollisionen werden beim Umzug nach main als erfolgreicher No-op verschleiert

*O1 · Herabstufung getragen → P2*

Die Logiklücke ist nachvollziehbar, setzt aber zwei Kopien derselben Session-ID in zwei Roots voraus. WhisperM8 verschiebt selbst nur, und Promote überschreibt beim Mischen nie. Das aktuelle Transcript bleibt in A erhalten, Resume springt nur auf einen alten Stand zurück. Erweitert, selten, ohne Löschung: P2.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:527-539,570-579 (main-first-Locator, No-op)`, `WhisperM8/Services/AgentChats/AccountMoveService.swift:81-95 (Stempel trotz No-op)`

### LR-KO-009 · Teilweise fehlgeschlagenes Rückgängig löscht auch die noch offenen Journal-Einträge

*O1 · Herabstufung getragen → P2*

Der Fehler ist bestätigt: Bei Teilerfolg wird der ganze Batch gelöscht. Er greift nur bei einem Undo mit Teilerfolg und gleichzeitigem zweitem Fehler. Die Chats bleiben intakt und lassen sich manuell zurückverschieben, der Fehlschlag wird im Outcome gemeldet. Am unteren Rand von P2 (P3 wäre vertretbar), kein Blocker.

**Belege:** `WhisperM8/Services/AgentChats/AccountMoveService.swift:137-169`

### LR-GPT-004 · Ein paralleler Start kann den Proxy nach Stop oder App-Quit weiterlaufen lassen

*O1 · Herabstufung getragen → P2*

Die Race ist echt: stopIfSelfStarted liest den Handle ohne ensureLock. Das Fenster reicht aber nur bis zum Launch, also über die Binary-Auflösung bzw. den Download beim ersten GPT-Start. Beim nächsten App-Start räumt der Orphan-Guard Waisen auf. Das Feature ist Labs und standardmäßig aus. Ein W7-Verstoß ist nur bei einem Quit genau in diesem Fenster plus anschließendem zap denkbar. P2.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:404-435 (Handle erst nach Launch)`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:761-777 (Stop ohne ensureLock)`

### LR-GPT-005 · GPT-Hauptkonto wird auch bei weiterhin lebenden alten Proxys ausgetauscht

*O1 · Herabstufung getragen → P2*

Bestätigt: Nach 3 s wird moveGrant ohne erneute isRunning-Prüfung ausgeführt. Ein Proxy, der SIGTERM ignoriert, ist ein seltener Ausnahmefall, das Feature ist Labs, und die Aktion ist selten und bewusst. Folge ist eine Konto-Inkonsistenz, kein Verlust von Nutzerdaten. P2.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:662-681`

### LR-GPT-006 · Waisen-Schutz beendet auch bewusst extern gestartete Hintergrund-Proxys

*O1 · Herabstufung getragen → P3*

Das Verhalten ist beabsichtigt und als Soll getestet (Waise mit PPID 1 und anderem Binary). Betroffen ist nur, wer einen eigenen Proxy per launchd genau auf dem von WhisperM8 konfigurierten Port betreibt und das GPT-Backend (Labs) eingeschaltet hat. P3 als Härtung.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift:55-68,88-103`, `Tests/WhisperM8Tests/ClaudeCodeProxyOrphanGuardTests.swift:13-17`

### LR-ONB-005 · : Nach Rechtevergabe kann ein unvollständiges Setup dauerhaft verschwinden

*O1 · Herabstufung getragen → P2*

Bestätigt: needsOnboarding prüft nur Mikrofon und Accessibility. Es gibt keinen Default-Hotkey (KeyboardShortcuts.Name ohne Default), wer den Wizard nach dem Rechteschritt schließt, landet also ohne Hotkey und Key. Einen Ausweg gibt es aber: Das Menü zeigt „No hotkey configured“, missingAPIKey meldet „Please enter your API key in settings.“, und „Open WhisperM8…“ ist im Menü. Der Nutzer hat den Wizard bewusst verlassen, der Pfad W2 selbst funktioniert. Spürbarer Mangel für Laien, besonders in Diktat-only-Profilen ohne Wiedereinstieg, aber keine harte Sackgasse. P2. Ein Hinweisband bzw. ein Menüeintrag „Setup fortsetzen“ reicht als Fix.

**Belege:** `WhisperM8/WhisperM8App.swift:204-208,385-395`, `WhisperM8/WhisperM8App.swift:528 (toggleRecording ohne Default-Shortcut)`, `WhisperM8/Views/MenuBarView.swift:63-70`, `WhisperM8/Services/Dictation/TranscriptionModels.swift:72-73`

### LR-ONB-006 · : Schon ein versehentlich getipptes Zeichen ersetzt den funktionierenden API-Key

*O1 · Herabstufung getragen → P2*

Bestätigt: onChange speichert jeden nicht leeren Zwischenstand per KeychainManager.save, Leeren stellt nichts wieder her, in den Settings wie im Onboarding. Ein Teil der Gegenstelle des Prüfers ist falsch. OpenAI- und Groq-Keys lassen sich beim Anbieter nicht erneut anzeigen, verloren ist also der Key, den der Nutzer kannte, und er muss einen neuen erzeugen. Realistischer Auslöser ist eher ein versehentliches Cmd+V mit falscher Zwischenablage als ein getipptes x. Behebbar ist der Schaden mit einem neuen Key, Nutzerinhalte gehen nicht verloren, also P2. Den Fix (Entwurf plus expliziter Save) mit hoher Priorität einplanen.

**Belege:** `WhisperM8/Views/OnboardingView.swift:635-640`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:107-113`, `WhisperM8/Services/Shared/KeychainManager.swift:23-31 (SecItemUpdate ersetzt)`

### LR-ONB-007 · : Fehlgeschlagene Keychain-Writes werden im Setup als vorhandener Zugang behandelt

*O1 · Herabstufung getragen → P2*

Bestätigt: save liefert Void, und apiKeyAvailable wird unabhängig vom Ergebnis true. Spätestens beim ersten Diktat wird der Fehler sichtbar (missingAPIKey). P2 bleibt. Hinweis zur Einordnung: Mit dem beschlossenen Wechsel auf Developer ID (E4) ändert sich für Bestandsnutzer die Code-Signatur. Keychain-Items mit alter ACL lösen dann Zugriffs-Prompts aus, und wer dort ablehnt, gerät in eine Schleife, in der „Saved Key“ angezeigt wird und das Diktat mit „No API key“ scheitert. Das gehört als Testfall in W6 und erhöht die Priorität, aber nicht die Schwere.

**Belege:** `WhisperM8/Services/Shared/KeychainManager.swift:10-34`, `WhisperM8/Views/OnboardingView.swift:639-640`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:111-119`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:26-33`

### LR-ONB-017 · : Das Codex-Login-Skript quotiert den aufgelösten Binary-Pfad nicht

*O1 · Herabstufung getragen → P2*

Bestätigt und trivial behebbar. Die Standard-Auflösungsorte enthalten keine Leerzeichen, und macOS-Kurznamen unter /Users erlauben keine. W3 ist ohnehin über LR-ONB-002 und LR-DIK-015 blockiert. Für sich genommen ist das P2, kein eigener Blocker.

**Belege:** `WhisperM8/Services/Dictation/CodexSupport.swift:191-205`, `WhisperM8/Views/OnboardingView.swift:320-337`

### LR-DOK-004 · Das Handbuch empfiehlt vollständige Datenlöschung als normale Fehlerbehebung

*O1 · Herabstufung getragen → P2 · Launch-Blocker*

Die Schwere P2 trägt: Der destruktive Befehl setzt ein geklontes Repo voraus, das die Brew-Zielgruppe nicht hat. Blocker bleibt richtig, weil die DoD einen User Guide im Ist-Stand verlangt. Die Neufassung zusammen mit DOK-005 behebt beides.

**Belege:** `docs/USER_GUIDE.md:20-22,56-64,200-207`, `scripts/clean-install.sh:55-75`

### LR-DOK-005 · Das Anwenderhandbuch führt zu nicht mehr vorhandenen Einstellungsseiten

*O1 · Herabstufung getragen → P2 · Launch-Blocker*

Bestätigt: Die Tabs API, Hotkey, Behavior und Audio gibt es nicht, und Profile, Codex-Login und der erste Chat fehlen im Guide. Es ist ein reiner Doku-Mangel, deshalb P2, aber nach DoD ein Blocker.

**Belege:** `docs/USER_GUIDE.md:88-105,150-180`, `WhisperM8/Views/SettingsView.swift:3-16`

### LR-AK-005 · : Fehlgeschlagene Workspace-Writes bleiben unsichtbar und ohne eigenen Retry

*O2 · Herabstufung getragen → P2*

Am Code bestätigt: drain setzt bei Schreibfehler nur dirty=true und plant keinen neuen Versuch. Die Gegenstelle trägt aber. Jede weitere Mutation läuft über persistLocked und plant einen neuen Flush, didResignActive flusht bei jedem App-Wechsel, willTerminate flusht synchron. Zum Verlust braucht es einen anhaltenden Schreibfehler, keine einzige weitere Mutation und keinen Fokuswechsel bis zum Absturz. Der stille Fehler ohne Hinweis ist ein echter Mangel, aber kein im normalen Gebrauch auslösbarer Datenverlust.

**Belege:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:298-317 (catch setzt nur dirty=true)`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:89-98 (Resign-Flush)`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:331-351 (persistLocked plant bei jeder Mutation neu)`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:233-247 (flushSync beim Beenden)`

### LR-AK-007 · : Ein großes letztes JSONL-Event macht den gesamten Verlauf unerreichbar

*O2 · Herabstufung getragen → P2*

Bestätigt: tailLinesWithTruncation verwirft die angeschnittene erste Zeile, isEmpty führt dann zum Empty-State ohne historyStrip und damit ohne Nachladen-Pill, obwohl canLoadFromDisk wahr wäre. Auslöser ist nur eine letzte JSONL-Zeile über 512 KiB ohne nachfolgende Nachrichtenzeile. Es betrifft nur die Anzeige; der Chat selbst und das Transcript bleiben unberührt, Resume funktioniert. Seltener Randfall ohne Ausweg in der Ansicht, also P2.

**Belege:** `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:44-51 (isEmpty → nur TranscriptEmptyStateView)`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:200-206 (canLoadFromDisk würde greifen, wird aber nie gerendert)`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:418-432`, `WhisperM8/Views/AgentSessionDetailView.swift:51`

### LR-AK-008 · : Eine UTF-8-Schnittkante verhindert dauerhaft den Import einer gültigen Session

*O2 · Herabstufung getragen → P2*

Bestätigt: String(data:encoding:.utf8) über den ganzen 1-MiB-Prefix liefert bei angeschnittenem Mehrbytezeichen nil. Der Indexer cached dann nil mit Größe und mtime, eine beendete Datei bleibt dauerhaft unsichtbar. Betroffen sind nur extern gestartete Sessions über 1 MiB mit ungünstiger Byte-Grenze. In der App gestartete Chats stehen bereits im Workspace. Folge: ein fehlender Import, kein Datenverlust. Ein Nebeneffekt bei Kontoumzug (Stempel-Selbstheilung im Merge sieht die Datei nicht) gilt nur für Erweitert. Der Fix ist ein Einzeiler und sollte trotz P2 mitgenommen werden.

**Belege:** `WhisperM8/Services/AgentChats/BoundedJSONLReader.swift:19-27`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:124-131 (cache[...] = nil bei Parse-Fehler)`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:149`, `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:60-67 (Treffer nur über Größe+mtime)`

### LR-AK-009 · : Summary-Hilfsläufe verlieren das Konto und Backend des Chats

*O2 · Herabstufung getragen → P2*

Bestätigt: generate bekommt nur Provider und Prompt, das Environment kommt aus processEnvironment() ohne CLAUDE_CONFIG_DIR, GPT-Header und Router-Basis-URL (ANTHROPIC_BASE_URL wird nur per Launch-Override im AgentCommandBuilder gesetzt). Summaries laufen deshalb immer unter main. Betroffen sind Mehrkonto-Nutzer (Erweitert) und GPT-Chats (Labs); Einkonto-Nutzer nicht. Folge ist eine fehlende Zusammenfassung oder Kontingent auf main, kein Absturz und kein Datenverlust. P2 trägt. Den Datenschutzaspekt (GPT-Chat-Inhalte gehen an Anthropic) bewerte ich unter LR-AK-010.

**Belege:** `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-39`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:108-127`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:285 (Router-URL nur im Chat-Launch)`, `WhisperM8/Models/AgentChat.swift:3-5 (Provider kennt nur codex/claude)`

### LR-AK-010 · : Automatische Zusammenfassungen erklären ihren zusätzlichen Datenabfluss nicht

*O2 · Herabstufung zurückgenommen → P2 · Launch-Blocker*

Die Schwere P2 trägt, der Entzug des Blocker-Flags nicht. Die Fakten stimmen: Auto-Summary ist standardmäßig an, beim Anzeigen läuft ein zusätzlicher `claude -p`/`codex exec` mit Gesprächsauszug, und der Einstellungstext nennt weder Modellaufruf noch Kosten. Die Gegenstelle („Empfänger = Provider der Session, kein neuer Dritter“) gilt nur für reine Claude- und Codex-Chats. GPT-Backend-Chats haben provider=.claude, der Summarizer setzt keine Router-URL, ihr Inhalt geht also per `claude -p` auf dem main-Konto an Anthropic, obwohl der Nutzer ihn bewusst über OpenAI geleitet hat. Das ist genau der Seiteneffekt, den E2 für Labs prüfen lässt. Die DoD-Zeile „jeder Datenabfluss an Dritte ist in der UI erklärt und abschaltbar“ ist ohne Klassenbeschränkung verletzt; abschaltbar ja, erklärt nein. Der Fix ist klein: Text ehrlich machen und GPT-Sessions überspringen oder über das passende Backend leiten. Nebenbei steht der Gesprächsauszug in argv (`-p <prompt>`), was die DoD-Zeile „keine Secrets in argv“ berührt, sobald Chats eingefügte Schlüssel enthalten.

**Belege:** `WhisperM8/Support/AppPreferences.swift:239-241 (Default true)`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:124-127 (Text ohne Modellaufruf/Kosten)`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:34-38 (`-p`, prompt in argv, processEnvironment ohne Router-Override)`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:285 (GPT-Routing nur im Chat-Launch)`

### LR-AK-011 · : resumeScans umgeht Single-Flight und kann Account-Stempel zurücksetzen

*O2 · Herabstufung getragen → P2*

Der doppelte Scan über resumeScans ist real. Ein Stempel-Rollback setzt aber voraus, dass der früher gestartete Scan A nach Scan B committet. Außerdem korrigiert die Stempel-Selbstheilung im Merge anhand des beobachteten Ablageorts beim nächsten Scan. Das betrifft nur den Kontoumzug (Erweitert) im Fenster eines laufenden Scans; das Transcript liegt richtig. P2 trägt.

**Belege:** `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:90-108`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1127-1135`

### LR-AK-012 · : Retention löscht Sessions anhand eines nach await veralteten Schutz-Snapshots

*O2 · Herabstufung getragen → P3*

Der veraltete Schutz-Snapshot nach await existiert. Kandidaten sind aber nur Subagent-Spiegel, die mindestens 7 Tage inaktiv sind und kein Job-Verzeichnis mehr haben. Das Transcript wird ins Archiv verschoben, nicht gelöscht, und der Nutzer müsste genau diesen Eintrag im Archivierungsfenster öffnen. Praktisch nicht auslösbar, also P3.

**Belege:** `WhisperM8/Services/AgentChats/SubagentJobRetention.swift:55-107`, `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:251-288`

### LR-AK-019 · [A3-04] Nach externer ID-Umbindung beobachtet der Watcher weiterhin das alte Transcript

*O2 · Herabstufung getragen → P2*

Bestätigt: watch() übernimmt die neue externe ID, behält aber eine vorhandene transcriptURL samt Caches und Event-Source. setExternalSessionID wäre der richtige Pfad. Da /clear häufig vorkommt, ist der Auslöser alltäglich. Die Folgen bleiben aber auf Nebenpfade begrenzt. Hook-live-Sessions nehmen ihren Status aus Hooks, und PreToolUse/PostToolUse sind registriert; das stille Netz greift deshalb erst nach über 180 s ganz ohne Hook-Event. Ein ESC, der nicht abbricht (bei Streaming ohne Tool), kann binnen 5 s fälschlich als Abbruch bestätigt werden, weil die alte mtime nie wächst. Auto-Naming und Stand-Zeile veralten. Das ist ein gelegentlich falscher Status und kein kaputtes Feature, also P2. Der Fix ist klein und sollte vor dem Launch kommen, weil W4 „Status stimmt“ verlangt.

**Belege:** `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:141-170 (URL wird nur bei nil aufgelöst)`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:186-198 (setExternalSessionID ohne Aufrufer im Rebind-Pfad)`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:393-420 (Hooks primär, Transcript nur für Abort/Heilung)`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:26-33 (Pre-/PostToolUse registriert)`

### LR-AK-020 · [A3-05] Ignorierte Background-Forks verändern trotzdem den Vordergrundstatus

*O2 · Herabstufung getragen → P2*

Fork-Events laufen ohne ID-Filter auf den Vordergrundstatus. Der typische Fall ist /background mit leerer Vordergrund-Session; dann flackert der Status, und eine vorgemerkte Queue-Zustellung kann in die falsche (leere) Session gehen. Das gehört zu Background-Agents (Erweitert), ohne Datenverlust. P2 trägt.

**Belege:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:330-355`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:729-735 (forkExternalIDs vorhanden, aber im Statuspfad ungenutzt)`

### LR-AK-021 · [A3-06] Bereits gestarteter Chat ohne Bindung wird still als neuer Chat gestartet

*O2 · Herabstufung getragen → P2*

Der Builder resumt nur mit gebundener externer ID. hasLaunchedInitialPrompt=true ohne ID ist zugleich der legitime Fall eines nie beschriebenen Chats. Der Fehlerfall braucht den Ausfall der Hook-Bindung und zusätzlich des Indexer-Fallbacks (bindExternalSessionIDWhenAvailable) und von ClaudeExternalIDRecovery. Das alte Transcript bleibt auf Disk und wird als externe Session indiziert. Kein Datenverlust, P2 trägt. Der vom Finder vorgeschlagene harte Abbruch wäre schädlich.

**Belege:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:561-578`, `WhisperM8/Views/AgentSessionDetailView.swift:628-645 (markLaunched: flushNow + Zweitbindung)`

### LR-AK-022 · [A3-07] Background-Logs können den Prozessrunner am vollen Pipe-Puffer blockieren

*O2 · Herabstufung getragen → P2*

Der klassische Pipe-Deadlock ist bestätigt: Der DefaultProcessRunner liest erst im terminationHandler. Die Logs-Ansicht langer Background-Agents läuft dadurch in den Timeout. Der Health-Check beim Start wertet den Timeout als .error und lässt die Session bewusst stehen; nach dem Timeout beendet terminate() das Kind, ein Folgeschaden bleibt aus. Das ist eine Teilfunktion eines Erweitert-Features, P2 trägt.

**Belege:** `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:269-299`, `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:118-139 (Health-Check, Timeout → .error ohne Aufräumen)`

### LR-AK-023 · [A3-08] Frühes Stop-Signal verhindert den späteren Codex-Start nicht

*O2 · Herabstufung getragen → P2*

Der Stop-Latch wird vor runner.run nicht erneut geprüft. Ein Stop im Vorbereitungsfenster (einige hundert ms) lässt den Codex-Turn trotzdem laufen, und der kann Dateien ändern. Die Folge ist schwerer als bei den reinen Status-Races, deshalb P2 statt P3. Es betrifft aber nur Codex-Subagents (Erweitert) mit engem Zeitfenster.

**Belege:** `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-56`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:100-126`

### LR-AK-024 · [A3-09] Orphan-Korrektur kann einen neueren Jobzustand überschreiben

*O2 · Herabstufung getragen → P3*

correctIfOrphaned schreibt ohne Lock und ohne erneutes Lesen zurück. Der Pfad für spawning ohne PID verlangt aber einen über 30 s alten Snapshot, während der Supervisor genau dann running schreibt. Praktisch nicht erreichbar, die Folge ist ein falsch angezeigter Job. P3 trägt.

**Belege:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:285-305`

### LR-AU-001 · [A3-10] UI-Composer umgeht die gehärtete Supervisor-PID-Transaktion

*O2 · Herabstufung getragen → P3*

Die Herabstufung trägt und geht mir noch nicht weit genug. Die UI schreibt die PID per mutateState direkt nach der Rückkehr von launchDetached und ohne Lock. Der Supervisor muss erst als eigener Prozess hochfahren, den Prompt konsumieren und den Lock nehmen. Das Lost-Update-Fenster ist damit praktisch geschlossen, die Folge ist ein falsch angezeigter Job. Gleicher Mechanismus und gleiche Wahrscheinlichkeit wie LR-AK-024 (P3). Für eine einheitliche Skala also P3; der Fix (gemeinsamer launchDetachedSupervisor) bleibt sinnvoll.

**Belege:** `WhisperM8/Views/SubagentJobDetailView.swift:490-496 (mutateState ohne withExclusiveLock)`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:83-87`

### LR-AK-025 · [A3-11] Background-Task-Cache verwirft gültige Resets auf kleinere Transcripts

*O2 · Herabstufung getragen → P2*

Der Merge-Fehler in updatedTracker (größerer Offset gewinnt ohne Identitätsvergleich) ist bestätigt. Auslöser ist /clear nach großem Transcript, dazu laufende Background-Tasks und ein Kontowechsel in genau diesem Zustand. Schaden: ein Task wird beim Anhalten beendet. Das betrifft F-KO-02 (Erweitert), P2 trägt.

**Belege:** `WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift:159-181`, `WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift:40-48`

### LR-AK-026 · [A3-12] Send-Guard blockiert Erstzustellungen bei Token-I/O-Fehlern

*O2 · Herabstufung getragen → P2*

Der I/O-Fehler wird im Token-Store wie eine Wiedervorlage behandelt. Auslöser ist aber eine volle Platte oder kaputte Rechte in Application Support, und betroffen sind nur Prompts mit dem Marker [via whisperm8 chats], nie normale Eingaben. Der Block ist mit einem Hinweis behebbar. P2 trägt.

**Belege:** `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:80-119`, `WhisperM8/CLI/ChatsPromptGuardCommand.swift:46-66`

### LR-AK-027 · [A3-13] Zustell-Token kann mehrfach erfolgreich konsumiert werden

*O2 · Herabstufung getragen → P3*

Das ignorierte removeItem-Ergebnis erlaubt statisch einen doppelten Verbrauch. Real braucht es eine gleichzeitige Doppel-Submission desselben Marker-Texts oder ein dauerhaft scheiterndes Löschen. Wirkung höchstens ein zusätzlicher Freipass innerhalb der TTL. P3 trägt.

**Belege:** `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:104-117`

### LR-AK-028 · [A3-14] Codex-Exit 0 gilt auch ohne nachgewiesenes Turn-Ende als Erfolg

*O2 · Herabstufung getragen → P2*

mapOutcome wertet Exit 0 ohne Turn-Nachweis als done. Mit der unterstützten Codex-CLI gibt es heute keinen sicheren Auslöser. Ändert aber ein Codex-Update das Event-Schema (die CLI aktualisiert sich häufig), würde ein nicht ausgeführter Auftrag still als Erfolg gemeldet. Der Fehler versteckt also eine Inkompatibilität, statt sie zu melden. P2 statt P3 ist deshalb vertretbar; Erweitert, kein Blocker.

**Belege:** `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-119`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:488-497`

### LR-SH-007 · : Die Login-Shell-Abfrage kann den ersten Chatstart dauerhaft auf dem Hauptthread blockieren

*O2 · Herabstufung zurückgenommen → P2 · Launch-Blocker*

Die Schwere P2 trägt, der Entzug des Blocker-Flags nicht. queryLoginShellPath wartet per waitUntilExit ohne Timeout, stderr wird nie geleert, und path hält beim Laden keinen Cache-Platzhalter. Die Gegenstelle („Prewarm fängt den Normalfall ab“) versagt genau im Auslösefall: Hängt die Login-Shell, kommt auch der Prewarm nie zurück und schreibt nie einen Cache. Dann ruft jeder erste Chatstart den Loader auf dem Main Thread selbst auf, und die App friert zuverlässig und unbegrenzt ein. Das ist kein Race, sondern deterministisch, sobald die Umgebung so ist. Die Umgebung (blockierende .zprofile, Netzwerkaufruf ohne Timeout, Passwortabfrage eines Tools) ist bei der Laien-Zielgruppe selten, darum P2. Die DoD verlangt aber ausdrücklich „kein bekannter Weg, auf dem die App dauerhaft einfriert“, und dies ist ein bekannter Weg. Ein langsamer .zprofile (1–3 s) verletzt bei einem Chatstart während des Prewarms (Crash-Recovery startet Tabs direkt beim Launch) außerdem das W5-Budget von 1 s. Der Fix ist klein: Deadline von etwa 5 s, stdin/stderr auf /dev/null, Fallback-PATH statt Warten auf dem Main Thread.

**Belege:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:59-79 (kein Lock/Platzhalter während pathLoader)`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:174-193 (waitUntilExit ohne Timeout, stderr-Pipe ungelesen)`, `WhisperM8/WhisperM8App.swift:308-317 (Prewarm cached nur bei Rückkehr)`, `WhisperM8/Views/AgentTerminalView.swift:870-879 (start() auf Main ruft terminalEnvironmentArray → path)`

### LR-PJ-001 · : Die Plugin-Migration räumt fremde, ungestempelte Skills automatisch weg

*O2 · Herabstufung zurückgenommen → P2*

Die Herabstufung auf P1 trägt, die auf P3 ist zu weich. Die Gegenstelle nimmt an, dass nur WhisperM8-spezifische Namen betroffen sind. Unter den Plugin-Skills sind aber die generischen Namen `jarvis` und `callout`, und `jarvis` wird ausdrücklich ohne jede Stempelprüfung immer verschoben, selbst bei lokaler Änderung. Ein eigener Skill namens „jarvis“ ist bei Claude-Code-Nutzern alles andere als exotisch. Die Migration läuft beim ersten Start ungefragt. Der Skill verschwindet für Claude außerhalb der App und liegt nur in einem versteckten Ordner `~/.claude/skills/.whisperm8-backup/`. Das verletzt die Inventar-Vorgabe für F-AUT-02 („darf fremde Claude-Setups nicht stören“). Es gibt keinen Datenverlust, aber eine stille Fremdänderung mit Funktionsausfall, also P2. Den W7-Anteil (bleibt nach Zap zurück) deckt LR-BR-001 ab.

**Belege:** `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:309-325 (jarvis immer verschoben; sonst nur modifiedLocally geschützt)`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:279-301 (Backup unter ~/.claude/skills/.whisperm8-backup)`, `WhisperM8/Services/Shared/CLISkillExporter.swift:112-120 (Namen jarvis, callout)`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:363-379 (Migration beim ersten Start)`

### LR-BR-001 · : Brew-Zap lässt installierte Statuslines und fremde Konfigurationsänderungen zurück

*O2 · Herabstufung zurückgenommen → P2 · Launch-Blocker*

Die Schwere P2 trägt, der Entzug des Blocker-Flags nicht. Der Prüfer stellt selbst fest, dass W7 verletzt ist, und nimmt das Flag trotzdem weg. Nach den Regeln ist eine W7-Verletzung aber ein Blocker. W7 verlangt wörtlich „keine Fremdänderungen in ~/.claude“ nach `brew uninstall --zap`. Der Zap entfernt nur Application Support, Caches und Preferences. Zurück bleiben die Statusline-Skripte, die direkt in `~/.claude/` liegen, samt Einträgen in `settings.json`, die Backup-Ordner der Plugin-Migration in `~/.claude/skills/.whisperm8-backup/` (ohne Wiederherstellung der verschobenen Skills) und der automatisch angelegte, danach tote Symlink `~/.local/bin/whisperm8`. Das Argument „bewusst installiert“ trägt nur für die Statusline. Migration und Symlink passieren ungefragt. Die Größe des Fixes ist kein Grund gegen das Flag: Das Journal-System muss es nicht sein. Zap-Einträge für Symlink, Skripte und Stempel genügen, dazu eine Statusline, die ohne Skript nichts ausgibt, und ein Hinweis bzw. Rückbau der Migration.

**Belege:** `scripts/update-cask.sh:49-53 (zap nur drei app-eigene Pfade)`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:66-78 (Skripte in ~/.claude)`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:279-301 (Backup in ~/.claude/skills)`, `WhisperM8/WhisperM8App.swift:303-305 (Symlink automatisch beim Start)`

### LR-PJ-002 · : Die Umgebungssäuberung entfernt fremde Plugin-Verzeichnisse vor deren angeblichem Erhalt

*O2 · Herabstufung getragen → P3*

Bestätigt: Der Erhalt eines geerbten CLAUDE_CODE_PLUGIN_DIRS ist im Produktivpfad totes Verhalten, weil inherited aus dem bereits bereinigten Env gelesen wird. Eine aus dem Dock gestartete App erbt die Variable aber praktisch nie. Der CLAUDE_CODE_*-Strip ist ein dokumentierter, wichtiger Schutz. Ein Konsistenzfehler mit minimaler Reichweite, P3 trägt.

**Belege:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:106-108`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:385-391`

### LR-BR-004 · Developer-ID-Build bricht am fehlenden Frameworks-Ordner ab

*O2 · Herabstufung getragen → P2*

Bestätigt: Unter set -euo pipefail bricht `find` auf dem fehlenden Contents/Frameworks den Developer-ID-Zweig ab, bevor das Bundle signiert wird. Heute setzt niemand DEVELOPER_ID_APPLICATION. Mit E4 (b) ist dieser Zweig aber der vorgesehene Launch-Weg. Den Blocker trägt LR-BR-003 (P1), dieser Befund muss dort als zwingende Teilaufgabe verknüpft werden, damit er nicht verloren geht. Eigenständig P2, weil der Fehler beim ersten Versuch sofort auffällt und mit einem Einzeiler behoben ist.

**Belege:** `scripts/build-dmg.sh:5`, `scripts/build-dmg.sh:32-48`

### LR-BR-007 · Tag-Releases werden ohne Test-Gate veröffentlicht

*O2 · Herabstufung getragen → P2*

release.yml läuft auf Tags ohne Tests und ohne needs, ci.yml nicht auf Tags. Ausgeliefert wird Defektes erst durch einen Prozessfehler (Tag auf einem Commit ohne grüne CI). Die DoD-Zeile „swift test grün in CI“ ist über main erfüllt. Das ist Release-Hygiene, P2 trägt; den Fix per workflow_call und needs trotzdem vor dem Launch umsetzen.

**Belege:** `.github/workflows/release.yml:12-15`, `.github/workflows/release.yml:55-70`, `.github/workflows/ci.yml:10-13`

### LR-BR-008 · Clean-Install beendet fremde Prozesse und kann sich selbst töten

*O2 · Herabstufung getragen → P2*

`pkill -9 -f whisperm8` trifft alle Prozesse, deren argv den Text enthält, auch jede Chat-CLI mit einem --settings-Pfad unter Application Support/WhisperM8, und das mit SIGKILL. Das Skript ist aber ein ausdrücklich destruktiver Maintainer-Reset und liegt nicht im Brew-Weg. Der Verweis in „LIES MICH.txt“ der DMG zeigt Endnutzern auf ein Skript, das sie nicht haben. Das ist ein Doku-Fehler; die DMG ist kein beworbener Weg. P2 trägt, eher an der Grenze zu P3.

**Belege:** `scripts/clean-install.sh:14-19`, `scripts/build-dmg.sh:70-82 (LIES MICH verweist auf ./scripts/clean-install.sh)`

### LR-AK-031 · Job-State-Korrektur und PID-Nachtrag überschreiben neuere Zustände

*O2 · Herabstufung getragen → P3*

Er überschneidet sich mit LR-AK-024 (Orphan-Korrektur) und LR-AU-001 (PID-Nachtrag). Neu ist nur der Fall, dass done zu failed überschrieben wird: Zwischen readState und livenessProbe, also in Mikrosekunden, müsste der Supervisor done schreiben und sich beenden. Folge ist ein falsch angezeigter Status, der Report bleibt erhalten. Gleicher Mechanismus und gleiche Wahrscheinlichkeit wie LR-AK-024, das P3 hat. Für eine einheitliche Skala also P3, und am besten mit 024 und AU-001 zu einem Befund zusammenführen.

**Belege:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:285-305 (Read → Probe → Write ohne Lock)`, `WhisperM8/Views/SubagentJobDetailView.swift:490-496`

### LR-DIK-016 · Clipboard-Fallback überschreibt zwischenzeitliche Nutzerkopien

*O3 · teilbestätigt → P3*

Der Ablauf stimmt: Der Clipboard-Fallback greift immer, wenn AX keinen markierten Text liefert, und der kommt häufig vor (keine Markierung, Electron/Chrome). Er schreibt den Snapshot nach rund 240 ms (60 ms Aktivierung, 20 ms Tastendruck, 160 ms copyDelay) blind zurück. Eine Nutzerkopie in diesem Fenster würde als Kontext gelesen und danach überschrieben, und der Resync in RecordingCoordinator+Context.swift:73-78 verschluckt sie. Der Code-Kommentar nennt das selbst eine 'bekannte Restlücke'. Auslösbar ist es aber nur, wenn der Nutzer innerhalb von etwa 240 ms nach dem Hotkey selbst Cmd+C drückt. Das ist im normalen Gebrauch sehr unwahrscheinlich, und der Schaden beschränkt sich auf eine einzelne Kopie. Deshalb P3.

**Regressionstest:** In SelectedContextService das Pasteboard (NSPasteboard(name: .init("test-\(UUID())"))) und den Copy-Poster als Closure injizieren. Der Poster simuliert die Ziel-App-Kopie plus eine zweite, fremde Kopie (changeCount +2). Erwartung: kein Kontext übernommen und kein Restore über die fremde Kopie, also enthält das Pasteboard danach den Fremdtext. Heute steht dort der alte Snapshot.

### LR-DIK-017 · Jeder Report-Save durchsucht das gesamte Archiv auf dem MainActor

*O3 · bestätigt → P2*

save() läuft synchron im @MainActor-RecordingCoordinator (saveRunReport, aufgerufen nach dem Paste). Bei jedem Aufruf läuft runCleanupIfNeeded → cleanup(). Das dekodiert für jedes Report-Verzeichnis (bis 500) die report.json neu und zählt per directorySize rekursiv alle Dateien. Der vorhandene Index (reports-index.json) wird dafür nicht benutzt. Dazu kommen synchrone Kopien der Attachments. Das Diktat ist zwar schon eingefügt, aber der Main Thread steht danach bei vollem Archiv spürbar (Hotkey, Overlay). Eine Blockade über 1 s ist bei typischen Reportgrößen nicht belegt, deshalb kein W5-Blocker.

**Regressionstest:** TranscriptRunReportStore bekommt einen injizierbaren reportLoader (Closure mit Zähler). In einem Temp-Verzeichnis 300 Reports anlegen und dann einen weiteren mit .productionDefault speichern, wobei kein Limit überschritten ist. Erwartung: loadReport wird höchstens einmal aufgerufen, weil der Cleanup aus dem Index arbeitet. Heute sind es 301 Aufrufe.

### LR-DIK-018 · Stop wartet bis zu einer Sekunde vor dem eigentlichen Audiostopp

*O3 · teilbestätigt → P3*

Der Ablauf stimmt: stopRecording wartet per waitForContextCapture(timeout: 1.0) vor audioRecorder.stopRecording(). Das ist aber bewusstes Design (Kommentar: kurze Diktate sollen ihren Kontext behalten, und das muss vor dem Clipboard-Sweep passieren). Im Normalfall ist das Capture längst fertig: AX braucht Millisekunden, der Clipboard-Fallback rund 240 ms, und Stops unter 0,3 s werden ohnehin ignoriert. Nennenswert warten muss Stop nur bei einer hängenden Ziel-App (AX-Timeout 2×0,5 s) oder langsamem Transcript-Volume, und dann auch nur bei sehr kurzen Diktaten. Der zusätzliche Audioanteil ist in der Regel Stille. Die Frame-Extraktion eines Screen-Clips wird ohnehin gebraucht. Ein Randfall-Budgetriss, deshalb P3.

**Regressionstest:** Den RecordingCoordinator mit einem Capture-Task-Stub testen, der 800 ms schläft. Der Stop-Pfad muss audioRecorder.stopRecording (Spy) sofort aufrufen und erst danach auf den Kontext warten. Heute liegt der Aufruf erst nach etwa 800 ms.

### LR-DIK-019 · Löschschalter lässt weitere visuelle Dateikopien bestehen

*O3 · bestätigt → P2*

VisualContextCaptureService.cleanup löscht bei aktivem Schalter nur fileURL/thumbnailURL der Originale. TranscriptRunReportStore.save kopiert vorher jedes Attachment samt separater Thumb-Kopie nach Reports/<id>/Attachments. Diese Kopien bleiben bis zu 180 Tage bzw. 500 Läufe (productionDefault). Die Delivery-Kopien unter $TMPDIR/WhisperM8Delivery räumt nirgends Code weg (nur 'WhisperM8Delivery' in VisualAttachmentDeliveryBuilder.swift:10, sonst kein Treffer). Die UI erklärt das nicht, der Privacy-Text nennt nur pauschal 'history … under Application Support'. Die Daten bleiben lokal und fließen nicht an Dritte ab, deshalb kein DoD-Blocker. Der Schalter hält aber sein Versprechen nicht.

**Regressionstest:** Den Schalter als Parameter injizieren (deleteVisualFiles: Bool). Einen Report mit Screenshot-Attachment im Temp-Verzeichnis speichern, VisualAttachmentDeliveryBuilder.build mit Temp-Root aufrufen, danach cleanup. Erwartung: Reports/<id>/Attachments und das Delivery-Run-Verzeichnis sind leer bzw. entfernt. Heute liegen dort 2 bzw. 1 Kopie.

### LR-VG-002 · VoiceGate durchsucht bis zu 96 MiB Logs pro Takt auf dem MainActor

*O3 · teilbestätigt → P2*

Der Ablauf stimmt: Der @MainActor-VoiceGateCoordinator ruft alle 10 s synchron probe.currentArmState() auf. Das sortiert bis zu 12 .log-Dateien nach mtime, liest je bis zu 8 MiB, dekodiert sie als String und splittet sie zeilenweise, alles ohne Cache auf mtime/Größe. '96 MiB pro Takt' ist der Worst Case, typische Codex-Logs sind kleiner. Bei mehreren großen Tageslogs ist das aber ein periodischer Main-Thread-Hänger, der auch das Kern-Diktat trifft, und das darf ein Labs-Feature nicht. Nebenbefund, der die Funktion selbst betrifft: readTail springt bei Dateien über 8 MiB an einen beliebigen Byte-Offset. Liegt der mitten in einem UTF-8-Mehrbytezeichen, liefert String(data:encoding:.utf8) nil, der Marker geht verloren und das Gate bleibt unscharf. Nur aktiv, wenn opt-in und Codex läuft.

**Regressionstest:** In CodexVoiceSessionProbe einen tailReader-Closure-Zähler injizieren. Zweimal lastRealtimeSessionStart() mit unveränderter 8-MiB-Logdatei im Temp-logRoot aufrufen. Erwartung: ein Lesevorgang, denn der zweite Aufruf trifft den mtime/size-Cache. Heute sind es zwei. Dazu ein Test mit einer 9-MiB-Datei, bei der ein 'ä' genau auf der 8-MiB-Grenze liegt und der Marker am Ende steht. Erwartung: Datum gefunden. Heute nil.

### LR-AK-013 · : Parallele Tool-Ergebnisse werden in Zusammenfassungen vertauscht

*O3 · teilbestätigt → P3*

Der Mechanismus stimmt: AgentChatBlock.toolUse/toolResult tragen keine tool_use_id/call_id, und TranscriptTimelineBuilder.attachToolResult hängt FIFO an openToolStepIndices.first. Das konkrete Beispiel ('swift test' parallel zu 'git commit') ist aber unrealistisch: Claude Code führt nicht-lesende Bash-Befehle seriell aus, und git commit hängt inhaltlich von den Tests ab. Vertauschte Reihenfolgen betreffen eher parallele Read-only-Aufrufe, die keine Evidenz erzeugen. Ein zusätzlicher, nicht verifizierter Verschiebungsweg: Leere Tool-Ergebnisse werden verworfen (ClaudeTranscriptReader.swift:311 'if !content.isEmpty', CodexTranscriptReader.swift:147). Schreibt eine CLI für Befehle ohne Ausgabe ein leeres Ergebnis, rutschen alle folgenden Ergebnisse der Runde um einen Aufruf. Betroffen ist nur die Summary-Karte, nicht der Verlauf.

**Regressionstest:** In AgentSessionSummarizerTests ein Transcript bauen: eine Assistant-Message mit toolUse(swift test, id A) und toolUse(git commit, id B), danach toolResult(id B, '[main abc1234] x') und toolResult(id A, 'error', isError: true). Erwartung: Der Timeline-Step 'swift test' hat isError == true und die Evidence enthält Commit abc1234. Heute bekommt der Test das Commit-Ergebnis (passed) und der Commit fehlt. Setzt voraus, dass die Blöcke eine ID tragen.

### LR-AK-014 · : Ein nur gestarteter Test wird als bestanden an das Modell gemeldet

*O3 · bestätigt → P3*

parseTestRun wertet nur isError aus und ignoriert ein fehlendes Ergebnis. Ein offener Step (result nil, isError false aus TimelineBuilder:124-131) ergibt deshalb passed=true, und evidenceLines schreibt 'TEST OK'. Auslösbar ist das, wenn der PTY endet (Kill, App-Absturz, Stop während des Tests) und noch kein tool_result im Transcript steht. noteSessionTerminated stößt genau dann die Summary an. Ein ESC-Interrupt schreibt in Claude dagegen normalerweise ein Fehler-Ergebnis. Auch der Teilstring-Match ('echo npm test', 'grep jest') ist real. Folge ist eine falsche Erfolgsangabe in der Summary-Karte. Das ist ärgerlich, aber eine Nebenfunktion, deshalb P3.

**Regressionstest:** Zwei neue Tests in TranscriptEvidenceExtractorTests mit dem vorhandenen bashStep-Helfer: bashStep("swift test", result: nil) → evidence.tests ist leer (oder passed == nil). bashStep("echo 'npm test'", result: "npm test") → evidence.tests ist leer. Beide scheitern heute (passed == true bzw. ein Eintrag).

### LR-AK-015 · : Abgebrochene Verlaufsaufbauten rechnen vollständig weiter

*O3 · bestätigt → P2*

rebuild() startet Task.detached. Wird der äußere .task(id:) abgebrochen, propagiert das nicht in den detached Task. TranscriptTextRenderer.render und TranscriptTextDocument.make prüfen nirgends Task.isCancelled (grep ohne Treffer). Die einzige Prüfung steht nach .value. Der Code-Kommentar ('verwirft den laufenden Aufbau, statt ihn zu Ende zu rechnen') und CLAUDE.md ('off-main + abbrechbar') behaupten etwas, das der Code nicht tut. Verschärfend: rebuildTaskID ändert sich mit jeder neuen Nachricht. Ein arbeitender Live-Chat startet also bei jeder Nachricht einen Vollaufbau, laut Budget rund 0,5 s für 10 MB, und die verworfenen laufen parallel weiter. Kein Main-Thread-Hänger, aber unnötige CPU- und Speicherlast, die mit der Chat-Zahl wächst.

**Regressionstest:** TranscriptTextRenderer.render(_:limits:isCancelled:) bekommt einen Abbruch-Closure, der pro Nachricht geprüft wird. Test mit der 10-MB-Fixture aus TranscriptTextRendererTests: Der Closure liefert nach 10 Nachrichten true. Erwartung: weniger als 100 Zeilen bzw. CancellationError. Heute läuft render bis zum Ende, weil es keinen solchen Parameter gibt; der Test schreibt also die Abbruchschnittstelle fest.

### LR-AK-016 · : Dauernde externe Transcript-Writes können die Erkennung endlos verschieben

*O3 · teilbestätigt → P3*

Der Debounce ist rein nachlaufend (cancel + neuer 5-s-Task) und hat keine Höchstwartezeit. Relevante FSEvents im Abstand unter 5 s, bei 2 s Stream-Latenz, verschieben requestScan also beliebig lange. Realistisch ist das nur bei dauerhaft schreibenden, nicht live beobachteten Transcripts (gefiltert werden bereits beobachtete und /subagents/). Eine externe Claude-Session schreibt pro fertiger Nachricht. Modell-Denkpausen über 5 s sind üblich, und spätestens am Turn-Ende feuert der Scan. Dazu greifen der Foreground-Scan und die manuelle Aktualisierung. Folge: eine extern gestartete Session erscheint verzögert, verloren geht sie nicht.

**Regressionstest:** In AgentDirectoryEventMonitor die Scan-Anforderung als Closure injizieren (requestScan: (Reason) -> Void) und handleEvents intern testbar machen. Mit debounceInterval 0,2 s zehnmal im 0,1-s-Takt einen relevanten Pfad melden (1 s Dauerlast). Erwartung: mindestens ein requestScan, weil die Höchstwartezeit greift. Heute keiner.

### LR-TRM-001 · [A3-15] Alle Chats stoppen blockiert den Main Thread linear pro PTY

*O3 · bestätigt → P2 · Launch-Blocker*

terminateAll() ruft für jede ID terminate(sessionID:) auf und damit AgentTerminalController.terminate() mit usleep(80_000)+usleep(180_000) auf dem MainActor. Die vorhandene Bündelvariante terminate(sessionIDs:) zahlt die Wartezeit einmal für alle, wird hier aber nicht benutzt. 'Stop all' in der Menüleiste (MenuBarView.swift:125 → AppState.stopAllForegroundSessions) friert die App bei 10 Chats mindestens 2,6 s ein, bei 20 Chats 5,2 s. Ab 4 laufenden Chats ist das mehr als 1 s und verletzt W5 ('10+ Chats, kein Hänger > 1 s') wörtlich. Die Aktion ist selten und der Hänger endlich, deshalb P2. Blocker nach W5, der Fix ist trivial (terminate(sessionIDs:) verwenden).

**Regressionstest:** In AgentTerminalController/Registry den Schlaf als Closure injizieren (sleep: (useconds_t) -> Void, Spy in AgentTestSupport.swift). Mit 5 laufenden Fake-Controllern terminateAll() aufrufen. Erwartung: sleep wird genau zweimal aufgerufen (80 ms + 180 ms). Heute sind es zehn Aufrufe.

### LR-GPT-007 · Das normale Usage-Popover fragt GPT-Profilkonten trotz ausgeschaltetem Backend ab

*O3 · teilbestätigt → P3*

Stimmt: load() prüft nur isGPTAccountProfilesEnabled, nicht claudeGPTBackendEnabled. Liegt ein Proxy-Login auf Disk, ruft das Popover bei ausgeschaltetem Backend mit diesem Token wham/usage auf. Die Einordnung als Privacy-Problem ist aber überzogen. Der Abruf passiert nur auf ausdrücklichen Klick des Nutzers auf das Codex-Icon in der Sidebar, und das Token geht an seinen eigenen Aussteller (chatgpt.com), nicht an Dritte. Übrig bleibt eine Inkonsistenz: Ein ausgeschaltetes Labs-Feature zeigt unter dem Titel 'ChatGPT · GPT-Backend' trotzdem Kontodaten und löst Requests aus.

**Regressionstest:** Die Zielauswahl aus load() in eine pure Funktion auslagern: CodexUsagePopoverModel.fetchTargets(backendEnabled:profilesEnabled:profiles:). Mit backendEnabled false und einem eingeloggten main-Profil muss das Ergebnis leer sein. Heute ist main enthalten.

### LR-ONB-009 · : Diktatprofile erhalten keinen sichtbaren automatischen Update-Hinweis

*O3 · bestätigt → P2 · Launch-Blocker*

Der Update-Status erscheint nur im SidebarUpdateBadge (eingebunden einzig in AgentChatsView.swift:1984) und in Settings → About. MenuBarView enthält keinen Update-Hinweis (grep 'pdate' ohne Treffer), und es gibt keine Benachrichtigung. Die Profile dictationRaw und dictationEnrichment laufen als .accessory ohne Agent-Chats-Fenster. Für diese Kern-Profile meldet die App ein Update also nie von sich aus. W6 ('App meldet Update') ist damit für einen ausdrücklich unterstützten Nutzerweg verletzt.

**Regressionstest:** UI-Snapshot-Fixture in UISnapshotGallery.swift: MenuBarView mit AppUpdateChecker-State .available(…) und Profil dictationRaw rendern. Erwartung: ein Update-Eintrag. Als Unit-Test über eine pure Funktion UpdateHintSurfaces.surfaces(for: .dictationRaw), die .menuBar enthalten muss. Heute gibt es diese Fläche nicht.

### LR-ONB-010 · : Der Update-Dialog endet bei einem Terminal-Befehl statt einer geführten Aktualisierung

*O3 · bestätigt → P2*

AppUpdateDetailsView zeigt nur kopierbare Befehle und den Hinweis 'Im Terminal ausführen'. Es gibt keine Ausführung, keinen Fortschritt und keine Erfolgsprüfung. Ohne Cask-Receipt steht zuerst der dann scheiternde 'brew upgrade' und erst darunter der Adopt-Befehl. Kein Blocker nach W6: Die Zielgruppe hat das Programm per brew installiert (W1), und der Befehl führt zum Ziel. Das Feature-Inventar wertet 'Befehl kopieren reicht nicht' für Laien selbst als Ausbaupunkt (F-APP-04), also eine Produktentscheidung. Nebenbei: Der Dialog kündigt erneute Rechte-Abfragen an, was W6 ('ohne neue Rechte-Abfrage') widerspricht. Das hängt aber an E4 (Signatur), nicht an diesem Befund.

**Regressionstest:** Die Befehlsauswahl in eine pure Funktion auslagern: AppUpdateChecker.primaryCommand(for: UpdateInfo). Mit isBrewInstall == false muss brewAdoptCommand herauskommen. Heute zeigt die View fest brewUpgradeCommand zuerst.

### LR-ONB-011 · : Die UI bleibt hart codiert zweisprachig statt lokalisiert

*O3 · bestätigt → P2 · Launch-Blocker*

Im Quellbaum gibt es keine .xcstrings/.strings/.lproj (find ohne Treffer). Der Onboarding-Wizard ist englisch, TranscriptionModel.description ist deutsch ('Beste Qualität …'), der Update-Dialog ist deutsch, die Info.plist-Usage-Descriptions sind nur deutsch, der GPT-Backend-Seitenrahmen ist deutsch, viele Settings sind englisch. E1 (c, Englisch als Basis mit Lokalisierung) ist nicht umgesetzt, und die DoD fordert 'Eine Sprache in der gesamten UI'. Kein Funktionsfehler, deshalb P2. Blocker nach DoD.

**Regressionstest:** Test, der für alle TranscriptionModel.allCases, AppUsageProfile.allCases und TranscriptionProvider.allCases die nutzersichtbaren Texte unter Locale en auflöst. Er prüft, dass keine deutschen Marker (Umlaute, ' bei ', 'Qualität') vorkommen und dass im Bundle eine Localizable.xcstrings mit en und de existiert. Heute schlägt er schon bei openai_gpt4o.description fehl.

### LR-ONB-012 · : Kern-Settings trennen Labs und Expertenfunktionen nicht vom normalen Setup

*O3 · bestätigt → P2*

SettingsView.pageGroups ist statisch und für alle Profile gleich, inklusive Accounts, Hooks, CLI und GPT-Backend. Die Transcription-Seite bietet ChatGPT-Abo an, sobald der Kill-Switch an ist (Default true), unabhängig vom GPT-Backend. Das Onboarding gated korrekt (OnboardingView.swift:736-737), die Settings nicht. GPT-Backend, ChatGPT-Abo und der Codex-Voice-Tab tragen keinerlei Kennzeichnung als experimentell oder inoffiziell. Das widerspricht E2 und der Klassendefinition 'Labs: hinter Experimentell, klar gekennzeichnet'. E2 ist aber kein DoD-Punkt und es gibt keinen W-Weg-Bruch, deshalb kein Blocker. Für die Launch-Vorbereitung ist es trotzdem verpflichtend.

**Regressionstest:** Die Provider-Optionen der Settings-Seite in eine pure Funktion auslagern: TranscriptionProvider.settingsOptions(killSwitch: true, backendEnabled: false, stored: .groq). Erwartung: ohne .chatgpt. Heute enthalten. Dazu SettingsView.pageGroups(for: .dictationRaw): darf .gptBackend nicht außerhalb einer Labs-Gruppe führen.

### LR-ONB-013 · : Ungültiger Key und fehlgeschlagenes Testdiktat verhindern keine Erfolgsmeldung

*O3 · bestätigt → P2*

TranscriptionCredentialGate.isSatisfied akzeptiert jeden nicht leeren String, auch '   '. canFinish prüft weder die Gültigkeit des Keys noch das Testergebnis, und es gibt nirgends eine Key-Validierung (grep ohne Treffer). TestStep zeigt bedingungslos 'All set!' mit grünem Häkchen, auch wenn darunter ein Auth-Fehler steht. Der Nutzer wird nicht blockiert, sondern bekommt falsche Sicherheit, und der Fehler zeigt sich erst beim echten Diktat. Kein W2-Bruch bei korrektem Key, deshalb kein Blocker.

**Regressionstest:** TranscriptionCredentialGate.isSatisfied(provider: .groq, typedKey: "   ", hasSavedKey: false) muss false liefern; heute true. Zusätzlich ein purer OnboardingFinishGate(lastTestError: "401 …") → canFinish bzw. Erfolgsanzeige false.

### LR-ONB-014 · : Die Modellauswahl im Onboarding ist nicht per Tastatur bedienbar

*O3 · bestätigt → P3*

Die Modellzeilen sind HStacks mit onTapGesture, ohne Button-/Picker-Semantik und ohne .accessibilityAddTraits. Per Tastatur bzw. VoiceOver sind sie nicht als Auswahl erreichbar. Der Effekt bleibt klein, weil ein Default-Modell vorausgewählt ist, das Onboarding ohne Modellwechsel durchläuft und das Modell auch in den Settings per nativem Picker wählbar ist. Barrierefreiheits-Mangel, P3.

**Regressionstest:** Kein sinnvoller Unit-Test. UI-Snapshot-Fixture für den API-Key-Schritt plus manuelle VoiceOver-/Tab-Prüfung. Alternativ die Zeile durch Picker(.radioGroup) bzw. Button ersetzen und eine Accessibility-Audit-Checkliste in der QA führen.

### LR-ONB-015 · : Nach fehlgeschlagenem Vorlagen-Speichern wird Save deaktiviert

*O3 · bestätigt → P3*

saveSelectedTemplate setzt templates[index] vor dem Schreibversuch auf die Entwurfswerte. Der catch stellt nichts zurück, isDirty wird false und Save ausgegraut. Ausgelöst wird das nur durch volle Platte oder fehlende Schreibrechte in Application Support, also durch einen manuellen bzw. seltenen Systemzustand. Die Fehlermeldung wird angezeigt, und der Text steht noch im Editor. Ein beliebiges Zeichen ändern macht Save wieder aktiv. Erst beim Wechsel der Vorlage geht der Entwurf verloren. Deshalb P3.

**Regressionstest:** TemplateEditorModel(fileURL: tempDir/templates.json): createTemplate, dann das Verzeichnis per chmod 0500 schreibgeschützt machen, editableName ändern und saveSelectedTemplate aufrufen. Erwartung: errorMessage != nil, canSave == true, templates[index].name unverändert. Heute ist canSave false.

### LR-ONB-016 · : Zentrale Hilfetexte unterschreiten den normalen Textkontrast

*O3 · bestätigt → P3*

Nachgerechnet: textTertiary (Schwarz mit 42 % auf Weiß) ergibt 3,04:1, Weiß mit 38 % auf 0,058 ergibt rund 3,55:1. Beides liegt unter WCAG AA 4,5:1 für 11,5-pt-Text, auf Panel- bzw. Surface-Flächen im Dark Mode noch etwas darunter. SettingsRow-Subtitles und SettingsHelpText nutzen diesen Token für handlungsrelevante Erklärungen. Die Zahlen stimmen, der Mangel ist aber eine Lesbarkeits- und Barrierefreiheitsfrage ohne Funktionsbruch und ohne DoD-Bezug. Deshalb P3.

**Regressionstest:** Test, der AppTheme.textTertiary und AppTheme.background über NSAppearance(.aqua/.darkAqua) zu sRGB auflöst, die Transparenz verrechnet und den WCAG-Kontrast berechnet. Erwartung ≥ 4,5. Heute 3,04 (Light) bzw. 3,55 (Dark).

### LR-DOK-001 · : Die README bewirbt weiterhin ausgeschlossene Installationswege

*O3 · bestätigt → P2 · Launch-Blocker*

README.md:65-85 bietet 'Build from Source' (make install, mit falscher Voraussetzung 'Xcode Command Line Tools', obwohl das Makefile Xcode verlangt) und 'Direct DMG download' mit manuellem xattr an. Das widerspricht direkt dem Nicht-Ziel 'kein DMG-Download als beworbener Weg, kein Build-from-Source für Endnutzer'. Setup (89-93) nennt keine Installation oder Anmeldung der Claude-/Codex-CLI für W3/W4. Brew steht zwar als 'recommended' zuerst, also nicht ganz gleichrangig. Überschneidet sich weitgehend mit LR-DOK-003 (README.md:65-84, P1) und sollte damit zusammengeführt werden. Blocker nach DoD (README im Ist-Stand) und Nicht-Ziel.

**Regressionstest:** Kein Swift-Test. Doku-Lint im CI: README.md darf weder 'xattr -dr com.apple.quarantine' noch 'make install' im Installationsabschnitt enthalten und muss 'brew install --cask rankm8/tap/whisperm8' sowie einen Abschnitt zur Claude-/Codex-Einrichtung enthalten.

### LR-SH-008 · : Fehlerhafte Transkriptionsantworten schreiben diktierte Inhalte in öffentliche Logs

*O3 · teilbestätigt → P3*

Stimmt: Im Decoder-Fehlerpfad werden die ersten 500 Zeichen der Antwort per Logger.debug mit privacy .public geloggt. Die Einordnung 'öffentliche Logs' ist aber zu hoch: os_log-.debug wird nicht persistiert, nur ein laufendes 'log stream --level debug' sieht es. Datei-Logging (isDebugFileLoggingEnabled) ist per Default aus und nur per defaults write erreichbar, also intern. Außerdem stimmt die Aussage 'Erfolgsfall nur Länge' nicht: RecordingCoordinator+Transcription.swift:62 loggt bei JEDEM erfolgreichen Diktat die ersten 100 Zeichen ('Text preview'). Das ist häufiger als der seltene Decode-Fehler und sollte im selben Fix verschwinden. Diktierter Text ist kein Secret im Sinne der DoD, deshalb kein Blocker.

**Regressionstest:** Logger bekommt einen injizierbaren Test-Sink (static var sink: ((String) -> Void)?). MultipartTranscriptionClient mit einem Session-Stub aufrufen, der 200 und '{"text":"GEHEIM' (abgeschnitten) liefert. Erwartung: Kein gesammelter Logtext enthält 'GEHEIM'. Heute enthält er ihn. Analog für den Erfolgspfad des Coordinators ('Text preview').

### LR-BR-009 · Store-Test verwechselt Scheduler-Verzögerung mit blockierendem Flush

*O3 · bestätigt → P3*

Der Test misst die Wandzeit um store.flush() mit einer harten Grenze von 0,1 s. TestTiming.swift dokumentiert genau diese Fehlerquelle unter Last (Load 30–100). Die Assertion ist zudem überflüssig: Würde flush auf den Persist warten, wäre persistStarted schon erfüllt und allowPersist würde 2 s blockieren. Dann wäre saveCount beim nachfolgenden XCTAssertEqual(…, 0) bereits 1, die Semaphor-Reihenfolge beweist das Nicht-Blockieren also schon. Reines Test-Flakiness-Risiko ohne Produktbezug.

**Regressionstest:** Kein neuer Produkttest. Die Wandzeit-Assertion in testFlushReturnsWithoutWaitingForPersistAndWritesAsynchronously streichen, alternativ auf ≥ 1,0 s anheben, deutlich unter dem 2-s-Semaphor-Timeout. Die Aussage trägt dann allein die Reihenfolge persistStarted → saveCount == 0 → signal.

### LR-DOK-002 · DMG-Anleitung verspricht einen nicht mehr unterstützten Build ohne Xcode

*O3 · bestätigt → P3*

Das Makefile setzt 'export DEVELOPER_DIR = /Applications/Xcode.app/…'. Eine Makefile-Zuweisung schlägt die Umgebungsvariable aus 'DEVELOPER_DIR=… make dmg' (ohne -e), die Anleitung funktioniert also ohne Xcode nicht. build-dmg.sh ruft intern 'make build' auf und setzt DEVELOPER_DIR nicht selbst. Zusätzlich ist der Gatekeeper-Tipp 'Rechtsklick → Öffnen' seit macOS 15 kein Umgehungsweg mehr, und der hartcodierte Pfad ~/projects/WhisperM8 ist veraltet. Betrifft nur Maintainer-Doku außerhalb des DoD-Umfangs (README, User Guide, docs/features), deshalb P3 und kein Blocker. Entfernen oder auf den Release-Workflow umschreiben.

**Regressionstest:** Kein Swift-Test. Doku-Lint im CI: docs/DMG_BAUEN.md darf kein 'DEVELOPER_DIR=/Library/Developer/CommandLineTools' enthalten, solange das Makefile DEVELOPER_DIR fest exportiert. Alternativ die Datei löschen und auf scripts/build-dmg.sh bzw. den Release-Workflow verweisen.

### LR-DOK-006 · Aktive Feature-Doku beschreibt abgelöste Transcript- und Titelpfade

*O3 · bestätigt → P3 · Launch-Blocker*

docs/features/agent-chats/ui/README.md (status: aktiv) beschreibt die Timeline-Projektion mit Rounds/Activity-Zeilen und 'AgentChatTranscriptView' als Bubble-Ansicht. Laut CLAUDE.md sind diese Views gelöscht (Views/Transcript/ enthält sie nicht mehr), heute rendert ein NSTextView (TranscriptTextView). sessions/README.md (updated 2026-07-09) beschreibt das Auto-Naming als headless CLI-Aufruf. AgentSessionAutoNamer.swift:188-196 übernimmt seit 2026-09-23 den nativen Titel ohne Modellaufruf. Kein Nutzerschaden, deshalb P3. Formal verletzt es die DoD ('docs/features/ beschreiben den Ist-Stand'), deshalb Blocker bis zur Doku-Welle.

**Regressionstest:** Kein Swift-Test. Doku-Lint: Typnamen in docs/features/**/*.md (Backticks, CamelCase-Swift-Typen) gegen 'grep -r "struct|class|enum <Name>" WhisperM8' prüfen. Aktive Doku darf keine gelöschten Typen wie AgentChatTranscriptView oder AgentTimelineView nennen.

### LR-DOK-007 · Die Datenschutzerklärung im Handbuch verschweigt dauerhaft gesicherte Abbruch-Audios

*O3 · teilbestätigt → P3 · Launch-Blocker*

Stimmt: Der Privacy-Abschnitt des User Guide sagt pauschal 'Audio … deleted after transcription'. handleTranscriptionCancelled und Fehlschläge verschieben die Aufnahme nach Application Support/WhisperM8/FailedRecordings. 'Dauerhaft' ist aber falsch: FailedRecordingsStore kappt auf 10 Aufnahmen und 7 Tage (prune). Der Guide verschweigt zusätzlich das Report-Archiv mit Transkripten und Screenshots (bis 180 Tage, siehe LR-DIK-019), das wiegt eher schwerer. Lokal und kein Abfluss an Dritte, deshalb P3. Der Blocker ergibt sich aus der DoD (User Guide im Ist-Stand) und fällt mit der Neufassung zu LR-DOK-005 zusammen.

**Regressionstest:** Kein Swift-Test. Prüfliste im Doku-Review bzw. Lint: Der Privacy-Abschnitt muss die Ablageorte FailedRecordings (10 Stück/7 Tage) und Reports (500/180 Tage/2 GB) sowie deren Löschweg nennen. Der Lint sucht 'FailedRecordings' und 'Reports' in docs/USER_GUIDE.md.

### LR-DOK-008 · Automatisch geladene Projektregeln sind ein widersprüchliches Feature- und Vorfallarchiv

*O3 · bestätigt → P2 · Launch-Blocker*

CLAUDE.md hat 45.907 Bytes. Es enthält lange Vorfallsgeschichten (Daten, Analyse-Zitate), obwohl die DoD ausdrücklich 'Arbeitsregeln, kein Vorfall-Logbuch' fordert. Die Widersprüche sind belegt: CLAUDE.md:158 und AGENTS.md:47 behaupten, ~/.claude und ~/.codex seien read-only. Die App schreibt dort aber (MCP-Angleich per 'claude mcp add-json', Memory-Migration, Skill-Backup nach ~/.claude/skills/.whisperm8-backup, Hauptkonto-Tausch mischt projects/). Der Voice-Gate-Abschnitt sagt 'explizit ans Gerät gebunden (nie System Default)', während docs/features/voice-gate.md:90-96 genau diese Aussage für Bluetooth als falsch korrigiert. Kein Nutzerschaden, aber fehlleitend für jede Agent-Session und teuer im Kontext. Blocker nach DoD.

**Regressionstest:** Kein Swift-Test. CI-Check: CLAUDE.md höchstens rund 15.000 Zeichen, keine Datumsangaben der Form 'Vorfall YYYY-MM-DD'/'(DD.MM.YYYY)' außerhalb eines Verweisabschnitts. Ein grep-Lint prüft, dass 'read-only' nicht ohne die Ausnahmeliste der schreibenden Integrationen steht.

