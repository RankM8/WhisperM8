---
status: beschlossen
updated: 2026-10-18
description: Welle W4a des Launch-Readiness-Plans — Agent Chats: Lebenszyklus und Datensicherheit. Befunde, Abnahmekriterien, Tests zuerst.
---

# W4a · Agent Chats: Lebenszyklus und Datensicherheit

Kein laufender Chat endet ohne Rückfrage, kein Zustand geht still verloren: Cmd+Q, Schließen, Restart, Entfernen und Löschen fragen nach, Persistenzfehler werden sichtbar und wiederholt, defekte UI-State-Dateien werden gesichert statt ersetzt.

**Umfang:** 17 Befunde · P2 10, P3 7 · 0 Launch-Blocker · Aufwand S×10, M×7

## Abnahmekriterien der Welle

- [ ] Cmd+Q mit arbeitenden oder wartenden Chats zeigt einen Dialog (Beenden / Abbrechen); laufende Chats setzen nach dem Neustart fort, wenn der User das wählt (Entscheidung D4).
- [ ] Terminal schließen, Restart, Background-Agent entfernen, Projekt löschen und Bulk-Archivieren beenden Prozesse erst nach Bestätigung.
- [ ] Defekte `agent-ui-state.json` wird als Backup abgelegt, bevor die Migration greift; fehlgeschlagene Workspace-/Queue-Writes erscheinen in der UI und werden wiederholt.
- [ ] Steuerbefehle stehlen nicht den Fokus, während der User tippt.
- [ ] Divider-Drag erzeugt PTY-Resizes nur am Ende bzw. gedrosselt (Messung vorher/nachher).

## Lückenschluss zu Beginn (Kritiker Delta-Lauf)

- Zu Beginn lesen: Schreibpfade AgentWorkspaceStore/Repository (Platte voll, Rechte, Absturz während Debounce, Backup-Rotation).
- Zu Beginn lesen: Grid-Mutationen in `AgentWindowStore` Zeilen 330–1000 (Slot-Move, Swap, Kapazität, Detach, Mehrfenster) auf Index-Traps wie D2-01.
- Mehrfenster-Lebenszyklus mit Crash-Recovery-Marker; Drag-and-Drop mit Sonderzeichen-Pfaden.

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/agent-daten.md](../../00-scope/oracle/agent-daten.md), [oracle/agent-laufzeit.md](../../00-scope/oracle/agent-laufzeit.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-AK-005 | P2 | — | M | mittel | geplant · teilbestätigt | Fehlgeschlagene Workspace-Writes bleiben unsichtbar und ohne eigenen Retry |
| LR-AK-015 | P2 | — | M | niedrig | geplant · bestätigt | Abgebrochene Verlaufsaufbauten rechnen vollständig weiter |
| LR-AU-005 | P2 | — | M | niedrig | geplant · unverifiziert | Terminal schließen, Restart, Hintergrund-Agent entfernen und Projekt löschen beenden laufende Prozesse ohne Rückfrage; im Bulk-Archivieren sind Terminals schon weg, bevor der Chat-Dialog beantwortet ist |
| LR-AU-006 | P2 | — | M | mittel | geplant · unverifiziert | Cmd+Q beendet alle laufenden Chats ohne Warnung und markiert den Lauf als sauber, sodass kein Chat automatisch wieder anläuft |
| LR-AU-007 | P2 | — | S | niedrig | geplant · unverifiziert | Defekter oder nicht dekodierbarer agent-ui-state.json wird stillschweigend durch die Erst-Migration ersetzt, ohne Backup |
| LR-AU-015 | P2 | — | M | mittel | geplant · unverifiziert | Divider-Drag und Fenster-Resize erzeugen PTY-Resizes mit ~30 Hz je betroffener Pane (Dehn-Technik nur im ungenutzten Layout-Paket) |
| LR-AU-024 | P2 | — | S | niedrig | geplant · unverifiziert | Tab schließen (X, ⌘W, Mittelklick) lässt den Chat unsichtbar weiterlaufen, ohne Hinweis |
| LR-CLI-004 | P2 | — | S | niedrig | geplant · unverifiziert | Steuerbefehle (open, resume, unarchive --open/--resume) holen die App per NSApp.activate in den Vordergrund und stehlen den Fokus waehrend der User tippt |
| LR-KO-005 | P2 | — | S | mittel | geplant · bestätigt | Ein laufendes inaktives Claude-Profil lässt sich ohne Prozessschutz entfernen |
| LR-KO-008 | P2 | — | M | mittel | geplant · teilbestätigt | Transcript-Kollisionen werden beim Umzug nach main als erfolgreicher No-op verschleiert |
| LR-AK-018 | P3 | — | M | mittel | geplant · teilbestätigt | [A3-02] Queue bestätigt Aufträge und Reservierungen trotz fehlgeschlagener Persistenz |
| LR-AU-010 | P3 | — | S | niedrig | geplant · unverifiziert | ⌘⇧←/→ wird im ganzen Agent-Fenster als Tab-Wechsel konsumiert, auch bei Fokus in Textfeldern des Fensters (Sidebar-Filter, Archiv-Suche) |
| LR-AU-011 | P3 | — | S | niedrig | geplant · unverifiziert | Zwei-Finger-Horizontal-Swipe wechselt im ganzen Fenster den Tab, ist nicht abschaltbar und wird konsumiert |
| LR-AU-012 | P3 | — | S | niedrig | geplant · unverifiziert | Bulk-Pin und Bulk-Aktionen arbeiten in zufälliger Set-Reihenfolge; die Reihenfolge angepinnter Chats wird beim Mehrfach-Anpinnen vertauscht |
| LR-AU-017 | P3 | — | S | niedrig | geplant · unverifiziert | Jarvis-Board-Store: Lesefehler gilt als „keine Datei“ und überschreibt das Board; Quarantäne löscht vorherige Beweise; ein defekter Eintrag zerstört das ganze Board |
| LR-AU-018 | P3 | — | S | niedrig | geplant · unverifiziert | Pro Grid-Pane und Sidebar-Slot O(Sessions)-Lookups im Body (selectedSession, projects.first, sessions.first), im Fallback sogar headerTabs über alle Sessions |
| LR-AU-019 | P3 | — | S | niedrig | geplant · unverifiziert | Shrink-Auswahlmodus ist nur per Maus abbrechbar (kein Esc) und nur per Maus bedienbar |

### LR-AK-005 · Fehlgeschlagene Workspace-Writes bleiben unsichtbar und ohne eigenen Retry

*P2 · agent-kern / datenintegritaet · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:261-285`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:298-317`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:144-154`, `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift:363-391` (Stand `a8e0f35`)

**Fehlerbild:** Ein Flush scheitert kurzzeitig, etwa wegen voller Platte. drain setzt dirty wieder auf true, plant aber keinen neuen Versuch und veröffentlicht keinen Fehlerzustand. Wird anschließend Speicher freigegeben und weder mutiert noch ein Lifecycle-Flush ausgelöst, bleibt der neue Stand beliebig lange nur im RAM. Ein späterer Absturz verliert die Änderungen trotz längst wieder beschreibbarer Platte. Der vorhandene Test erzwingt den Retry selbst mit einem zweiten flush und deckt gerade keinen automatischen Retry ab.

**Fix:** Begrenzter Backoff-Retry in drain ist harmlos; der geforderte Nutzerhinweis ist optional.

*Ursprünglicher Vorschlag:* Fehlerzustand beobachtbar machen und mit begrenztem Backoff eigenständig erneut flushen. Bei dauerhaftem Fehler eine verständliche Warnung samt Handlungsoption anzeigen; sauberes Beenden darf fehlgeschlagene Persistenz nicht als gesichert behandeln. Serialisierte Writes und Utility-Queue beibehalten.

**Test zuerst:** AgentWorkspaceStoreTests: debounced Store mit PersistSpy, erster Persist schlägt fehl; ohne weiteren Aufruf muss innerhalb von Backoff-Zeit (injizierbarer Timer) ein zweiter Versuch erfolgen. Heute kommt keiner.

<details><summary>Prüfurteil</summary>

Die Beschreibung des Codes stimmt: drain setzt bei Fehler dirty=true, plant aber keinen Retry und zeigt keinen Fehler. Die Lücke ist in der Praxis klein: jede weitere Mutation (laufend durch Status-/Aktivitätsänderungen) plant über persistLocked einen neuen Flush, didResignActive flusht bei jedem App-Wechsel, und willTerminate flusht synchron nochmal. Verlust bräuchte also anhaltende Schreibfehler bis zum Absturz ohne eine einzige weitere Mutation oder einen Fokuswechsel. Stille Fehler ohne UI-Hinweis sind ein Qualitätsmangel, aber kein P1.

</details>

### LR-AK-015 · Abgebrochene Verlaufsaufbauten rechnen vollständig weiter

*P2 · agent-kern / performance · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:78-80`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:98-109`, `WhisperM8/Services/AgentChats/TranscriptTextRenderer.swift:67-82`, `WhisperM8/Views/Transcript/TranscriptTextView.swift:34-65` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer lädt große Verlaufsfenster und wechselt rasch zwischen Chats. SwiftUI cancelt zwar den äußeren .task, dessen Task.detached wird aber nicht mit abgebrochen. Renderer und Attributierungsloop prüfen ebenfalls keine Cancellation. Jeder verworfene Aufbau rendert und attributiert somit den kompletten Inhalt weiter; mehrere solche Aufgaben laufen parallel und halten Transcript, Zeilenarray und Dokument gleichzeitig im Speicher. Die Prüfung nach .value verhindert nur das Anzeigen, nicht CPU- und Speicherkosten.

**Fix:** Den Render-Task explizit bei Cancellation abbrechen und Renderer/Attributierung in begrenzten Abständen kooperativ abbrechen lassen; optional global begrenzte Render-Parallelität. Vollständige Prompts, Antworten und Thinking sowie die einzelne TextKit-Ansicht erhalten. Kosten im Nachlauf messen, nicht pauschal neue Inhaltskürzungen einführen.

**Test zuerst:** TranscriptTextRenderer.render(_:limits:isCancelled:) bekommt einen Abbruch-Closure, der pro Nachricht geprüft wird. Test mit der 10-MB-Fixture aus TranscriptTextRendererTests: Der Closure liefert nach 10 Nachrichten true. Erwartung: weniger als 100 Zeilen bzw. CancellationError. Heute läuft render bis zum Ende, weil es keinen solchen Parameter gibt; der Test schreibt also die Abbruchschnittstelle fest.

### LR-AU-005 · Terminal schließen, Restart, Hintergrund-Agent entfernen und Projekt löschen beenden laufende Prozesse ohne Rückfrage; im Bulk-Archivieren sind Terminals schon weg, bevor der Chat-Dialog beantwortet ist

*P2 · agent-ui / datenintegritaet · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView+Tabs.swift:129 (requestArchive schließt isTerminal-Sessions sofort)`, `WhisperM8/Views/AgentChatsView+Tabs.swift:171-176 (requestEndSession: Terminals vor jeder Bestätigung geschlossen)`, `WhisperM8/Views/AgentChatsView+Tabs.swift:216-229 (closeTerminalSession: terminate + deleteSession, Scrollback nicht wiederherstellbar)`, `WhisperM8/Views/AgentSessionDetailView.swift:346-347 und 608-611 (Restart = terminate + Neustart ohne Dialog)` (Stand `76256ad`)

**Fehlerbild:** (a) Nutzer markiert 3 Chats (1 laufend) und 2 Terminals mit einem laufenden Dev-Server und wählt „5 schließen/archivieren“. Die Terminals werden sofort beendet und gelöscht. Danach fragt der Dialog nach den Chats, und „Abbrechen“ stellt die Terminals nicht wieder her. (b) Ein Klick auf „Restart“ bei einem Chat mitten im Turn, oder mit Entwurf im Composer, bricht den Turn ab und verwirft den Entwurf, ohne Warnung. Das Label ist für Laien unklar. (c) „Projekt löschen“ beendet laufende Chats, der Dialog nennt nur die Anzahl der Chats. (d) „Vom Supervisor entfernen“ löscht einen laufenden Hintergrund-Agent ohne Rückfrage.

**Fix:** Terminals nach demselben Muster wie Chats behandeln: Rückfrage nur, wenn die Shell ein Kindprozess hat oder der Chat working oder awaitingInput ist. Die Terminal-Schließung erst im Commit-Pfad ausführen, damit „Abbrechen“ alles unangetastet lässt. Restart nur mit confirmationDialog, wenn Status ≠ idle. In den Dialogtext von „Projekt löschen“ die Zahl laufender Chats aufnehmen. Für .rm eine Bestätigung ergänzen.

**Test zuerst:** Pure Entscheidungsfunktion (needsConfirmation(session, status, hasChildProcess)) mit Tests; Test, dass requestArchive bei Abbruch keine Terminal-Session löscht.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

**Zusammengeführt mit:** LR-AU-025

### LR-AU-006 · Cmd+Q beendet alle laufenden Chats ohne Warnung und markiert den Lauf als sauber, sodass kein Chat automatisch wieder anläuft

*P2 · agent-ui / ux · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/WhisperM8App.swift:440-455 (applicationShouldTerminate sendet allen laufenden Terminals zweimal Ctrl-C, schläft 80+180 ms und gibt .terminateNow zurück, ohne Dialog)`, `WhisperM8/WhisperM8App.swift:446 (AgentCrashRecoveryMarker.endRunCleanly entfernt den Wiederaufnahme-Marker)`, `WhisperM8/Views/AgentTerminalView.swift:448-456 (captureAllSnapshotsForAppQuit blockiert den Main Thread per usleep)` (Stand `76256ad`)

**Fehlerbild:** Nutzer hat 8 Chats, 3 davon arbeiten gerade an langen Aufgaben, und drückt Cmd+Q (oder tippt das Q versehentlich). Die App sendet Ctrl-C an alle Chats, bricht die laufenden Turns ab und beendet sich ohne Rückfrage. Beim nächsten Start stehen die Tabs da, aber kein Chat läuft. Der Recovery-Marker gilt nur für Abstürze, jeder Chat muss einzeln wieder aufgenommen werden. Das verletzt W5 („kein Datenverlust bei Neustart“) für laufende Arbeit. Das Anhalten der Turns ist zudem für den Nutzer unsichtbar.

**Fix:** Vor .terminateNow prüfen, ob Sessions working oder awaitingInput sind. Wenn ja, NSAlert „N Chats arbeiten noch – trotzdem beenden?“ mit Option „Beenden“ oder „Abbrechen“. Optional beim sauberen Beenden die zuletzt laufenden Chats für „beim nächsten Start fortsetzen“ vormerken, mit Einstellung. SIGTERM von make dev muss den Dialog umgehen, also nur den Cmd+Q- oder Menüpfad abfangen.

**Test zuerst:** Pure Funktion quitNeedsConfirmation(statuses) testen. Manuelle QA mit 2 working Chats.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

**Zusammengeführt mit:** LR-AU-023

### LR-AU-007 · Defekter oder nicht dekodierbarer agent-ui-state.json wird stillschweigend durch die Erst-Migration ersetzt, ohne Backup

*P2 · agent-ui / datenintegritaet · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:65-78 (Dekodierfehler → AgentUIState.initialMigration(from: workspace), needsPersist = true, nur Logger.debug)`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:127-137 (Repair-Save überschreibt die Datei sofort)`, `WhisperM8/Models/AgentUIState.swift:291 (höheres schemaVersion wird nicht migriert, die Datei danach kanonisch neu kodiert; unbekannte Felder gehen verloren)`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:58-70 (der Workspace selbst legt vor dem Verwerfen ein Backup an, der UI-State nicht)` (Stand `76256ad`)

**Fehlerbild:** agent-ui-state.json enthält einen Typfehler (Teilschreiben, manuelle Änderung, Downgrade auf eine Version mit anderem Schema). Beim Start schlägt der Decode fehl. Die App baut die Tabs aus dem Workspace neu auf und überschreibt die Datei sofort. Pins, benannte Grid-Workspaces samt Slot-Layout, Sekundärfenster, Tab-Reihenfolge und Gruppen-Einklappzustand sind unwiederbringlich weg, und das Log zeigt nur eine Debug-Zeile (nicht persistiert). Bei W5 und W6 (Update ohne Datenverlust) ist das ein stiller Verlust von Nutzerzustand.

**Fix:** Vor dem Überschreiben die defekte Datei nach agent-ui-state.json.decode-failed-<zeit> kopieren (Muster AgentWorkspaceRepository.backup) und per Logger.notice loggen. Bei schemaVersion > current die Datei nicht anfassen, sondern in-memory arbeiten oder ebenfalls ein Backup anlegen.

**Test zuerst:** Test mit absichtlich kaputtem JSON: es entsteht eine .decode-failed-Kopie, und der Inhalt der Kopie entspricht dem Original.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

**Zusammengeführt mit:** LR-AU-014

### LR-AU-015 · Divider-Drag und Fenster-Resize erzeugen PTY-Resizes mit ~30 Hz je betroffener Pane (Dehn-Technik nur im ungenutzten Layout-Paket)

*P2 · agent-ui / performance · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Views/AgentGridSplitContainer.swift:285-317 (Sampler wendet alle 33 ms neue Fractions an, die Pane-Frames ändern sich real)`, `WhisperM8/Views/AgentGridSplitContainer.swift:94-114 (gridBody setzt .frame je Block aus colSizes/rowSizes)`, `WhisperM8/Services/AgentChats/Layout/LayoutDividerDrag.swift:5-14 (gemessen 02.08.2026: ~24 ms je Größenänderung bei 9 Flächen, davon SIGWINCH-Neuaufbau der TUI)`, `docs/plans/workspace-umbau/HANDOFF.md:54 (Dehn-Technik per scaleEffect, nur für WorkspaceLayoutView gebaut)` (Stand `76256ad`)

**Fehlerbild:** 3×3-Workspace mit neun laufenden Claude-TUIs, Trenner ziehen: jeder 33-ms-Tick ändert die Breite von bis zu sechs Panes, jede Pane schickt ioctl(TIOCSWINSZ) und die TUI baut ihr Bild komplett neu auf. Gemessene ~24 ms pro Tick bei 33 ms Budget heißt: Main Thread zu über zwei Dritteln belegt, ruckelnder Trenner, Flackern und Scrollback-Reflow in den Terminals. Beim Ziehen am Fenster oder an der Sidebar passiert dasselbe ungedrosselt.

**Fix:** Das fertige Konzept aus dem Layout-Paket auf den aktiven Container übertragen: während des Drags die Panes nur per scaleEffect/Transform strecken und die echte Größe (und damit SIGWINCH) erst bei onDragEnded setzen. Alternativ die PTY-Größe im AgentTerminalContainerView um ~150 ms entprellen. Vorher mit `make dev-release` und scripts/perf-load.sh bei 6 Panes messen.

**Test zuerst:** Messlauf mit PerformanceCounters (.layoutSolved) und os_signpost grid.divider.layoutTick: Anzahl TIOCSWINSZ je Drag-Sekunde vor und nach der Änderung.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-024 · Tab schließen (X, ⌘W, Mittelklick) lässt den Chat unsichtbar weiterlaufen, ohne Hinweis

*P2 · agent-ui / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView+Tabs.swift:93-98`, `WhisperM8/Views/AgentChatsView+Shortcuts.swift:105-116`, `WhisperM8/Views/AgentChatChromeViews.swift:370-379`, `WhisperM8/Views/AgentChatsView.swift:2704-2708` (Stand `76256ad`)

**Fehlerbild:** Laie schließt wie im Browser einen Tab mit ⌘W oder dem X, während Claude arbeitet. closeTab entfernt nur den Tab, das PTY läuft weiter (kostet Tokens/CPU, darf ggf. Dateien ändern). Es gibt keine Rückfrage und keine Anzeige am Tab. Nur die Sidebar-Zeile zeigt noch einen Punkt. Das Modell Tab zu = Chat beendet gilt nicht. Das Beenden steht an anderer Stelle (Sidebar Beenden/Archivieren) und hat dort eine Bestätigung.

**Fix:** Beim Schließen eines Tabs mit laufendem Prozess dasselbe Muster wie Chat beenden anbieten (weiterlaufen lassen oder beenden), mindestens einen einmaligen Hinweis beim ersten Mal. Die Aktion im Tooltip benennen (Tab schließen, Chat läuft im Hintergrund weiter).

**Test zuerst:** Reiner Close-Entscheider: Tab mit laufendem Prozess liefert „nachfragen/hinweisen“, ohne Prozess „schließen“; Hinweis erscheint nur beim ersten Mal (Preference-Fake).

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-CLI-004 · Steuerbefehle (open, resume, unarchive --open/--resume) holen die App per NSApp.activate in den Vordergrund und stehlen den Fokus waehrend der User tippt

*P2 · cli-control / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:318-319`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1266`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1467-1471` (Stand `76256ad`)

**Fehlerbild:** Jarvis oder ein Skript fuehrt waehrend einer Ueberwachungsrunde `chats resume <ref>` aus, der User tippt gerade in einer anderen App (Mail, Browser). NSApp.activate(ignoringOtherApps: true) holt WhisperM8 nach vorn. Die restlichen Tastenanschlaege, auch ein Enter, landen im Terminal eines Claude-Chats. Steht dort ein Permission-Dialog, kann ein getipptes 1/y/Enter eine Freigabe erteilen, die der User nie gesehen hat. Ein Aufruf aus der Mod (openChat) geschieht dagegen auf ausdruecklichen Klick des Users.

**Fix:** Fuer maschinell ausgeloeste Befehle (resume, unarchive --resume, new) nicht aktivieren, nur das Fenster ordnen und die Session fokussieren. Aktivierung nur fuer ausdrueckliches `open` oder per `--focus`. Alternativ eine Notification statt Aktivierung, wenn eine andere App im Vordergrund ist.

**Test zuerst:** Pure Entscheidung shouldActivate(method:, flags:). Tests: resume ergibt false, open ergibt true, open --background ergibt false.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-KO-005 · Ein laufendes inaktives Claude-Profil lässt sich ohne Prozessschutz entfernen

*P2 · konten / datenintegritaet · Aufwand S · Risiko mittel*

**Beleg:** `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:231-234`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:523-531`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:612-635` (Stand `a8e0f35`)

**Fehlerbild:** Ein Chat unter Profil A läuft weiter, während B zum aktiven Profil für neue Chats wird. Remove ist für A dadurch freigeschaltet. Anders als Rename und Promote prüft removeProfile keine laufenden Sessions und verschiebt unmittelbar den gesamten Config-Root samt Transcripts in den Papierkorb. Der laufende Prozess behält seinen alten CLAUDE_CONFIG_DIR, dessen Verlauf dort nicht mehr liegt; weitere Verlaufsschreibvorgänge können scheitern oder einen getrennten neuen Root erzeugen.

**Fix:** Fix passt; gleiche Guard-Logik wie renameProfile (AgentTerminalRegistry.shared.activeSessionIDs) in removeProfile und Disable-Zustand nach der Bestätigung erneut prüfen.

*Ursprünglicher Vorschlag:* Entfernen bei laufenden Profil-Chats sperren oder einen ausdrücklichen Stop-and-wait-Ablauf vor dem Verschieben anbieten. Nach einer Bestätigung frisch prüfen, nicht nur vor dem Dialog. Papierkorb-Rettbarkeit und Plugin-Registry-Schutz erhalten.

**Test zuerst:** Guard in eine pure Funktion (z. B. ClaudeProfileRunningGuard.hasRunningSession(profile:sessions:runningIDs:)) ziehen und testen: Session mit claudeProfileName == 'a' und ID in runningIDs -> true, Remove abgelehnt. View-Code selbst nicht unit-testbar.

<details><summary>Prüfurteil</summary>

removeProfile prüft Plugin-Referenzen, aber anders als renameProfile (AgentChatsClaudeAccountsTab.swift:~519-526) keine laufenden Sessions; nur das aktive Profil ist gesperrt (.disabled(isActive), :234). Ein laufender Chat unter einem inaktiven Profil ist leicht erreichbar. Die Folge ist aber begrenzt: Aktion ist bewusst vom Nutzer gewählt, mit Warndialog, und der Ordner geht in den Papierkorb (rettbar); der laufende Claude kann weiter schreiben und einen neuen Root anlegen (Verlaufssplitt), kein Totalverlust. Inkonsistenz zu Rename/Promote ist ein klarer Mangel, aber unter P1.

</details>

### LR-KO-008 · Transcript-Kollisionen werden beim Umzug nach main als erfolgreicher No-op verschleiert

*P2 · konten / datenintegritaet · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:295-296`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:527-539`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:570-579`, `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:364-372` (Stand `a8e0f35`)

**Fehlerbild:** Ein Chat ist auf Zusatzprofil A gestempelt und hat dort den aktuellen Verlauf; unter main liegt noch eine ältere Kopie derselben ID und desselben cwd. Beim Umzug nach main sucht der Locator global mit main zuerst. Dadurch hält bereits die Konfliktvorschau die alte Zieldatei für die Quelle, meldet keinen Konflikt und moveTranscript liefert No-op. Der Service stempelt den Chat dennoch nach main: Resume setzt die alte Kopie fort, während der aktuelle Verlauf in A zurückbleibt.

**Fix:** Der Fix ist richtig (bekannten Herkunftsaccount als Quell-Root nutzen). Vorsicht: die Glob-Stufe für abweichende cwd-Kodierung muss erhalten bleiben, und bei zwei Kopien soll gemeldet statt ausgewählt werden.

*Ursprünglicher Vorschlag:* Den bekannten Herkunftsaccount in Vorschau und Ausführung als verbindlichen Quell-Root verwenden. Bei mehreren vorhandenen Kopien außerhalb dieses Roots einen Konflikt melden, statt eine davon still auszuwählen. Glob-Fallback für abweichende cwd-Kodierung, Subagent-Mitnahme und Nichtüberschreiben erhalten; beide Kollisionsrichtungen testen.

**Test zuerst:** ClaudeAccountProfilesTests: Fixture mit <main>/projects/<enc>/<id>.jsonl (alt, klein) und <A>/projects/<enc>/<id>.jsonl (neu). transcriptConflictExists(toProfile:nil) muss true liefern bzw. moveTranscript muss werfen statt false zurückzugeben (heute false/No-op und danach Umstempeln).

<details><summary>Prüfurteil</summary>

Die Logik-Lücke ist im Code nachvollziehbar: locateTranscript sucht über claudeProjectsRoots() mit main zuerst. Liegt dieselbe Session-ID alt unter main und aktuell unter Profil A, hält transcriptConflictExists die main-Datei für die Quelle (source.path == targetFile.path → kein Konflikt). moveTranscript liefert false, der Umzug stempelt trotzdem nach main, und Resume nimmt die veraltete Kopie. Die Vorbedingung ist aber eine doppelt vorhandene ID in zwei Roots. WhisperM8 verschiebt sonst nur (kopiert nie), und Claude schreibt eine ID normalerweise nur in den Root des laufenden Profils. Das kann nach Pfad-/Hochstufungs-Mischungen oder manuellem Kopieren vorkommen, ist aber selten. Das aktuelle Transcript geht nicht verloren, es bleibt in A liegen. Kontext-Rückfall, kein Löschen: P2.

</details>

### LR-AK-018 · [A3-02] Queue bestätigt Aufträge und Reservierungen trotz fehlgeschlagener Persistenz

*P3 · agent-kern / datenintegritaet · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift:49-60`, `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift:68-78`, `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift:149-166`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:41-71` (Stand `a8e0f35`)

**Fehlerbild:** Bei voller Platte oder nicht beschreibbarem Queue-Verzeichnis meldet enqueue trotzdem Erfolg; nach Neustart fehlt der Auftrag. Scheitert stattdessen das Speichern von delivering, wird der Prompt dennoch gesendet, während auf Disk pending bleibt: Nach Absturz kann derselbe Auftrag erneut ausgeführt werden. Zusätzlich wird ein Decode-Fehler als leere Queue behandelt, die reconcileOnLaunch anschließend zurückschreibt.

**Fix:** Fix des Finders ist vertretbar, aber niedrige Priorität; bei Decode-Fehler Original sichern statt [] zurückzuschreiben ist der einzige Teil mit echtem Datenverlust-Potenzial.

*Ursprünglicher Vorschlag:* Lesen und Speichern mit explizitem Fehlerzustand versehen. Reservierung erst nach erfolgreichem durable Write zurückgeben, sonst nicht senden. Bei Decode-Fehler Original sichern und Schreibzugriffe sperren statt [] zurückzuschreiben. FIFO und die bewusste unknown-statt-Auto-Retry-Semantik erhalten.

**Test zuerst:** AgentPromptQueueTests: Store mit fileURL in nicht beschreibbarem Verzeichnis (chmod 0500 temp dir) anlegen; enqueue darf nicht stillschweigend Erfolg melden (Rückgabe/Fehlerzustand). Zweiter Test: Queue-Datei mit ungültigem JSON, reconcileOnLaunch darf die Datei nicht mit [] überschreiben (Backup vorhanden).

<details><summary>Prüfurteil</summary>

Code-Befund stimmt: persist() und read() verschlucken alle Fehler (try?), enqueue/reserveNext melden trotzdem Erfolg. Auslöser sind aber nur volle Platte oder nicht beschreibbares Application-Support-Verzeichnis (dann ist die ganze App, inkl. Workspace-Persistenz, ohnehin kaputt) bzw. eine korrupte Queue-Datei. Korruption ist durch atomare Writes unwahrscheinlich, und QueuedPrompt hat einen toleranten Decode (fehlende Felder älterer Fassungen). Das Doppelzustell-Szenario braucht zusätzlich einen Absturz: markDelivered folgt synchron im selben MainActor-Block auf sendPrompt, das delivering-Fenster ist winzig, und scheitert delivering-Persist, scheitert auch markDelivered. Kein realistischer Datenverlust-Pfad in normalem Betrieb, kein P0 und kein Nutzerweg W1–W7 verletzt.

</details>

### LR-AU-010 · ⌘⇧←/→ wird im ganzen Agent-Fenster als Tab-Wechsel konsumiert, auch bei Fokus in Textfeldern des Fensters (Sidebar-Filter, Archiv-Suche)

*P3 · agent-ui / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/TabNavShortcut.swift:19-22 (⌘⌥ und ⌘⇧ als Chords, nur Fenster-Gating)`, `WhisperM8/Views/AgentChatsView+Shortcuts.swift:155-162 (handleTabNavShortcut prüft nur event.window === hostWindow und prüft die firstResponder-Klasse nicht)`, `WhisperM8/Views/AgentChatsView.swift:2059 (TextField „Filter…“ im Hauptfenster)` (Stand `76256ad`)

**Fehlerbild:** Nutzer tippt im Sidebar-Filter und drückt ⌘⇧← („bis Zeilenanfang markieren“, macOS-Standard). Statt der Textmarkierung wechselt der aktive Chat, und der Filtertext bleibt unmarkiert. Dasselbe gilt für ⌘⌥←/→ im Archiv-Suchfeld.

**Fix:** In handleTabNavShortcut bei firstResponder als NSText oder NSTextView (Feldeditor) das Event durchreichen. Der Terminal-Responder bleibt ausgenommen, damit die Chords dort weiter wirken.

**Test zuerst:** Reine Funktion shouldHandleTabNav(firstResponder:) testen; manuelle QA mit fokussiertem Filterfeld.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-011 · Zwei-Finger-Horizontal-Swipe wechselt im ganzen Fenster den Tab, ist nicht abschaltbar und wird konsumiert

*P3 · agent-ui / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView+Shortcuts.swift:517-545 (handleTabSwipeScroll nur auf Fenster, Trackpad und außerhalb des Strip-Bandes gegated)`, `WhisperM8/Views/TabScrollSwipeRecognizer.swift:36-41 (Schwelle 60 pt, Dominanz 1.5, kein Opt-out)`, `Support/AppPreferences.swift: kein Schalter für den Swipe (grep tabSwipe: keine Treffer)` (Stand `76256ad`)

**Fehlerbild:** Beim Tippen berührt der Handballen das Trackpad mit horizontalem Versatz > 60 pt, oder der Nutzer scrollt horizontal über breiten Inhalt der Verlaufsansicht. Der aktive Chat wechselt, die restlichen Tastenanschläge und das Enter landen im anderen Chat. Das ist selten, aber ein Fehlrouting ohne Rückfrage, und es gibt keinen Schalter dagegen.

**Fix:** Einstellung „Tab-Wechsel per Wischgeste“ (Default aus oder an, entscheiden) ergänzen. Den Trigger unterdrücken, wenn in den letzten ~500 ms eine Taste getippt wurde.

**Test zuerst:** TabScrollSwipeRecognizer-Test mit Tipp-Sperrzeit.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-012 · Bulk-Pin und Bulk-Aktionen arbeiten in zufälliger Set-Reihenfolge; die Reihenfolge angepinnter Chats wird beim Mehrfach-Anpinnen vertauscht

*P3 · agent-ui / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView+BulkActions.swift:14-16 (actionGroup liefert Array(multiSelection), ein Set ohne Ordnung)`, `WhisperM8/Views/AgentChatsView+BulkActions.swift:71-82 (togglePinSelection iteriert group und hängt per pinSession an)`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:238-241 (pinSession hängt ans Ende an)` (Stand `76256ad`)

**Fehlerbild:** Nutzer markiert die Tabs A, B, C in dieser Reihenfolge und wählt „3 anpinnen“. pinnedSessionIDs bekommt sie in der Set-Reihenfolge (pro Prozesslauf zufällig), zum Beispiel C, A, B. Die Pin-Reihenfolge in Sidebar und Tabs ist nicht die sichtbare Reihenfolge und wechselt zwischen Starts.

**Fix:** actionGroup in sichtbarer Reihenfolge zurückgeben (visualTabOrderIDs oder die Sidebar-Reihenfolge gefiltert auf die Auswahl), IDs ohne Tab hinten anhängen. Dasselbe in togglePinSelection nutzen.

**Test zuerst:** Test mit 5 Auswahl-IDs: die Pin-Reihenfolge entspricht der Anzeige-Reihenfolge.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-017 · Jarvis-Board-Store: Lesefehler gilt als „keine Datei“ und überschreibt das Board; Quarantäne löscht vorherige Beweise; ein defekter Eintrag zerstört das ganze Board

*P3 · agent-ui / datenintegritaet · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:402-410 (loadForWriting: try? Data(contentsOf:) → leeres JarvisBoardFile bei JEDEM Lesefehler, danach write)`, `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:405-407 (removeItem(quarantine) vor moveItem: zweite Korruption überschreibt die erste Sicherung)`, `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:75 (sessionID streng, Teilfehler eines Eintrags macht JarvisBoardFile unlesbar)`, `WhisperM8/Services/AgentChats/JarvisBoardStore.swift:117-119 (schema wird nie geprüft)` (Stand `76256ad`)

**Fehlerbild:** Ein transienter Lesefehler (z. B. EPERM durch Backup-/Sync-Tool, I/O-Fehler) trifft jarvis-board.json genau beim nächsten board.set: loadForWriting liefert ein leeres File, die App schreibt ein Board mit einem Eintrag und ersetzt damit alle Notizen und Meilensteine. Eine Datei mit einem einzigen Eintrag ohne gültige sessionID wird komplett in .corrupt verschoben, ein späterer zweiter Defekt löscht auch diese Sicherung.

**Fix:** Fehlt die Datei (ENOENT) → leeres Board; anderer Lesefehler → mutate wirft StoreError statt zu überschreiben. Quarantäne mit Zeitstempel im Namen statt removeItem. Entries/Boards einzeln tolerant dekodieren (kaputte überspringen).

**Test zuerst:** JarvisBoardTests: nicht lesbare Datei (chmod 000) → mutate wirft und lässt die Datei unverändert; zweimal korrupt → zwei .corrupt-Dateien.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-018 · Pro Grid-Pane und Sidebar-Slot O(Sessions)-Lookups im Body (selectedSession, projects.first, sessions.first), im Fallback sogar headerTabs über alle Sessions

*P3 · agent-ui / performance · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView+Grid.swift:811-812 (gridPane: selectedSession?.id und workspace.projects.first je Pane und Body-Eval)`, `WhisperM8/Views/AgentChatsView.swift:672-676 (selectedSession: sessions.first, Rückfall headerTabs.first baut ein Dictionary über alle Sessions)`, `WhisperM8/Views/AgentChatsView+Workspaces.swift:109 (workspace.sessions.first(where:) je Slot je Workspace)`, `WhisperM8/Views/AgentChatsView+Grid.swift:257-261 (gridWorkspaceContent baut sessionsByID bereits EINMAL, nutzt es aber nicht für isFocused/Projekt)` (Stand `76256ad`)

**Fehlerbild:** 9 Panes plus mehrere Workspaces in der Sidebar bei einigen tausend Sessions: jede Body-Auswertung (Status-Churn, Fokuswechsel) macht ~9 + 9·W lineare Suchen; zeigt selectedSessionID auf einen archivierten Chat, baut jede Pane zusätzlich das headerTabs-Dictionary über alle Sessions. Im Einzelnen klein (Sub-ms bis wenige ms), summiert sich aber im Hot-Path, den die Performance-Regeln aus CLAUDE.md schützen sollen.

**Fix:** selectedSession-ID und projectsByID einmal in gridWorkspaceContent berechnen und an gridSlot/gridPane durchreichen (sessionsByID liegt schon vor); in workspaceGroup eine einmal je Sektion gebaute ID→Session-Map verwenden.

**Test zuerst:** PerformanceCounters-Zähler oder signpost um gridWorkspaceContent; Vergleich der Body-Zeit bei 3000 Sessions und 9 Panes.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-019 · Shrink-Auswahlmodus ist nur per Maus abbrechbar (kein Esc) und nur per Maus bedienbar

*P3 · agent-ui / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/GridShrinkSelectionViews.swift:134-146 (Abbrechen-Button ohne .keyboardShortcut(.cancelAction))`, `WhisperM8/Views/GridShrinkSelectionViews.swift:15-60 (PaneClickCaptureNSView, Auswahl nur per mouseUp; VoiceOver-Action existiert, Tastatur nicht)`, `WhisperM8/Views/AgentChatsView+Grid.swift:309,380 (einzige Abbruchwege)`, `WhisperM8/Views/GridSplitHandle.swift:37-80 (Trenner ohne Accessibility-Element, nur Maus-Drag und Doppelklick)` (Stand `76256ad`)

**Fehlerbild:** User wählt versehentlich eine kleinere Stufe, drückt Esc, nichts passiert. Esc geht weiter an das fokussierte Terminal und bricht dort ggf. die laufende Claude-Generation ab. Tastatur-Nutzer können weder Chats für das Verkleinern markieren noch Trenner verschieben.

**Fix:** Esc im Modus per lokalem Monitor oder .onExitCommand abfangen (konsumieren, Modus beenden). Auswahl per Leertaste/Pfeile ergänzen und den GridSplitHandle mit accessibilityAdjustableAction (Pfeile verschieben um 5 %) versehen.

**Test zuerst:** UI-Smoke: Shrink-Modus öffnen, Esc senden, gridShrinkSelection == nil und keine Eingabe im PTY.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.
