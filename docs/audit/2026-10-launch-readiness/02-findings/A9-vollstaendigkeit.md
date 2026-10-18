---
status: roh
updated: 2026-10-17
description: Workflow A, Vollständigkeits-Kritiker — Abdeckung, Lücken, ungeprüfte Nutzerwege, Duplikate.
---

# A9 Vollständigkeits-Kritiker

## Abdeckung

311 von 326 Dateien im Umfang gelesen. Ungelesen:

- `WhisperM8/Views/OutputReportComponents.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateCommandMatcher.swift`
- `WhisperM8/Views/AgentMoveToAccountSheet.swift`
- `WhisperM8/Views/AgentResourceSummaryButton.swift`
- `WhisperM8/Views/TranscriptReportDetailView.swift`
- `WhisperM8/Windows/OverlayFrameResolver.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateStateMachine.swift`
- `WhisperM8/Views/AgentSessionAmbiguousRebindPicker.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateWatchdogPolicy.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateListenerHealth.swift`
- `WhisperM8/Services/VoiceGate/VoiceGateLocaleResolver.swift`
- `WhisperM8/Views/InspectorWidthResolver.swift`
- `WhisperM8/Views/Settings/Kit/SettingsStatusTone.swift`
- `WhisperM8/Views/ProjectPickerKeyboard.swift`
- `WhisperM8/Views/AmbiguousRebindRequest.swift`

## Lücken

### Kern: Diktat-Ausgabe, Archivdetail und Overlay — vier ungelesene Dateien, 790 Zeilen

*Priorität hoch*

OutputReportComponents: 338 Zeilen; TranscriptReportDetailView: 245; OverlayFrameResolver: 173; SettingsStatusTone: 34. F-DIK-01/09 und F-APP-03, damit W2/W3/W5. Stichproben zeigen Ausgabe-, Kopier-, Anhangs-, Lösch- und Promptdarstellung sowie persistierte Bildschirmkoordinaten. Diese Nutzeroberfläche wurde durch die Prüfung ihrer Stores nicht mitgeprüft. Es werden daraus keine neuen Produktbefunde behauptet.

**Vorgeschlagener Nachlauf-Prompt:** Lies die vier genannten Typen vollständig und gleiche ihre Verträge mit OutputWorkspacePage, OutputArchiveViewModel, TranscriptRunReportStore und RecordingPanel ab. Prüfe große/fehlende Anhänge, Kopieren, Löschwirkung, Fehlermeldungen und sichtbare Roh-/Endausgabe. Prüfe Overlay-Geometrie bei negativen Bildschirmkoordinaten, Display-Abziehen, schmalen Displays und bestehenden Ankern. Ordne jeden belegten Defekt W2/W3/W5 und der Kern-Klasse zu. Keine Builds oder UI-Starts; benenne nötige spätere Interaktionsnachweise separat.

### Kern: Auswahl bei mehrdeutiger Resume-Zuordnung — zwei ungelesene Dateien, 138 Zeilen

*Priorität hoch*

AgentSessionAmbiguousRebindPicker: 121 Zeilen; AmbiguousRebindRequest: 17. F-AC-02, W4/W5. Die Stichprobe bestätigt eine ausdrückliche Wahl zwischen existierender Conversation und neuer Session. Die Laufzeit-Finder prüften die Erkennung, aber nicht diese Entscheidungsoberfläche; insbesondere darf eine reine View-Prüfung keine Aussage über die ausgeschlossene Caller-Verdrahtung vortäuschen.

**Vorgeschlagener Nachlauf-Prompt:** Prüfe Picker und Request vollständig auf eindeutige Kandidatendarstellung, sichere Abbruch-/Neustart-Semantik und Tastaturbedienung. Vergleiche den Datenvertrag mit ClaudeActiveSessionTracker und ClaudeExternalIDRecovery. Grenze View-Vertrag und tatsächliche Mutation klar ab; die AgentChatsView-Callbacks bleiben ein konkret benannter Delta-Handoff. Keine neuen Behauptungen über ausgeschlossene Callbacks.

### Erweitert: Konto-Umzugsdialog — eine ungelesene Datei, 304 Zeilen

*Priorität hoch*

AgentMoveToAccountSheet gehört zu F-KO-01/02. Die Stichprobe zeigt Vorschau, Trust-/MCP-Hinweise, Abbruch, Vormerkungen und Rückgängig. A4 prüfte die Dienste, nicht diese Datei. Wegen möglicher P0-Auswirkungen eines missverstandenen Stop-/Umzugsvorgangs ist die Lücke trotz Klasse Erweitert wichtig; sie ist noch kein weiterer Befund zu A4-07 oder A4-12.

**Vorgeschlagener Nachlauf-Prompt:** Lies AgentMoveToAccountSheet vollständig und gleiche jede Phase mit AccountSwitchPlanner.Decision, PendingAccountMove und AccountMoveService.Outcome ab. Prüfe ausschließlich P0/P1-relevante Differenzen zwischen bestätigter Wirkung und angezeigtem Ergebnis: Teilfehler, Abbruch, nur vorgemerkte Chats, fehlender Trust, laufende Chats und Undo. Benenne ausgeschlossene Handler als Delta-Handoff statt deren Verhalten anzunehmen.

### DoD Performance: keine aktuellen Messnachweise

*Priorität hoch*

Alle acht Finder arbeiteten statisch. Für 400 ms Hotkey→Aufnahme, 300 ms Stop→Transkriptionsstart, Main-Thread-Stalls und das noch zu beschließende Idle-CPU-Ziel existiert in ihren Ergebnissen kein aktueller Laufzeitnachweis. A1-18/19/21, A3-15 und A6-06 liefern Prüfziele, ersetzen aber keine Messung. Ausgeklammerte Grid-/Tab-Implementierungen sind keine zusätzliche Lücke; der später geforderte Gesamtlastlauf bleibt trotzdem offen.

**Vorgeschlagener Nachlauf-Prompt:** Erstelle jetzt nur eine Messfallmatrix aus den vorhandenen Signposts und statischen Befunden: Startzustand, Messpunkt, Hardware, Release-Konfiguration, Dauer, Grenzwert, Auswertungsregel. Trenne Diktat, Store, Ressourcenpolling, VoiceGate-aus/an und Idle. Weise den 6-Panes-/20-Tabs-Gesamtlastlauf dem späteren Delta-/Integrationsabschluss zu. Ausführung erst in einem separat freigegebenen Messfenster, ohne laufende Chats zu beenden.

### W1/W6/W7: ausgeliefertes Artefakt und Integrationslebenszyklus nicht verifiziert

*Priorität hoch*

A7 prüfte Pipeline und Cask-Generator, nicht das tatsächlich veröffentlichte Cask/Binary. A5/A6/A7 benennen fehlende Nachweise zu Developer ID, Notarisierung, Zielarchitektur, TCC-Erhalt und Prozess-/Fremdkonfigurationsbereinigung. Eine statisch richtige Pipeline würde W1/W6/W7 noch nicht beweisen. Externe Integrationen benötigen zudem eine Ownership-/Restore-Matrix vor Löschmaßnahmen.

**Vorgeschlagener Nachlauf-Prompt:** Ergänze lesend eine Eigentums- und Lebenszyklusmatrix für CLI-Symlink, Statusline, Skills/Plugin, Theme-Änderungen, Profile, Proxy, Login-Items und lokale Zustandsdateien: Erzeuger, Updateverhalten, Beendigung, Wiederherstellung, behalten versus zap. Gleiche die tatsächliche Tap-Datei und Release-Metadaten in einem gesonderten Read-only-Nachlauf mit dem Generator ab. Formuliere isolierte spätere W1/W6/W7-Abnahmen auf frischem und aktualisiertem Benutzerkonto; jetzt keine Installation, kein Brew, kein Prozessstopp.

### Sicherheits-/Datenintegritätsverträge: Dateisystemfehler und externer Proxy nur teilweise abgesichert

*Priorität hoch*

A4 nennt ungeprüfte ACL-/Symlink-/Mehrprozess- und Absturzfenster bei Promote, Migration und Shared Config. Der nachgeladene Proxy wurde nicht selbst untersucht; Bind-Adresse, Auth-Fallbacks, Logging und Credential-Rückschreiben sind externe Annahmen. SHA-Prüfung allein bestätigt diese Laufzeitverträge nicht. Es geht um verbleibende Nachweistiefe neben bereits gemeldeten Defekten, nicht um neue P0-Behauptungen.

**Vorgeschlagener Nachlauf-Prompt:** Erstelle getrennte Vertragsprüfungen: erstens Besitz, Rechte, Symlinks, konkurrierende Schreiber, fehlender Speicherplatz und Abbruch zwischen jedem destruktiven Konten-/Migrationsschritt; zweitens für die konkret gepinnte Proxy-Version Bind-Adresse, Authentisierung, HOME/CCP_CONFIG_DIR-Isolation, Grant-Rückschreiben und Traffic-Logs. Bestätige oder widerlege Annahmen anhand versionsgebundener Quellen und vorhandener Fixtures. Keine echten Credentials lesen oder ausgeben und keinen Proxy starten. Control-/Debug-Transport bleibt ausschließlich Delta; E3/E5-Rahmenbedingungen an B4 übergeben.

### DoD Tests und Code: Stichprobe statt Anforderungs-/Regressionsmatrix

*Priorität hoch*

Die Testdateien wurden nur teilweise und überwiegend exemplarisch gelesen; keiner der Finder führte die Suite aus. Damit sind weder aktuelle CI-Güte noch die W1–W7-Abdeckung oder deterministische Regressionen für die gemeldeten Rennen bewiesen. Der vorgeschlagene 1.500-Zeilen-Grenzwert ist ebenfalls nicht abgenommen; im verbleibenden Umfang liegt AgentSessionStore bei 1.604 Zeilen. Das ist ein offenes DoD-Kriterium, kein zusätzlicher Architekturdefekt.

**Vorgeschlagener Nachlauf-Prompt:** Inventarisiere vorhandene Tests lesend gegen W1–W7 und jedes zusammengeführte P0/P1: echte Assertion, injizierter Fehler, Interleaving, Prozessisolation für Crash-Szenarien und nicht geprüfter Integrationsrest. Priorisiere fehlende Regressionen statt Testanzahl. Ordne zukünftige Suite-/CI-Nachweise und UI-Abnahmen ausdrücklich zu. Bestätige den vorgeschlagenen Dateigrößen-Grenzwert erst in Schritt 4; fordere keinen rein kosmetischen Split der Store-Invarianten.

### Abdeckungsnachweis und Lesetiefe

*Priorität mittel*

425 versionierte Quellen ermittelt; 99 dem Delta zugeordnet; 326 im Umfang. Die Vereinigung der acht Leselisten nennt 311 davon (95,4 %). 15 Dateien mit zusammen 2.194 Zeilen fehlen; Gesamtumfang 70.533 Zeilen. Das ist eine Berührungsquote, keine vollständige Auditquote: files_read enthält ausdrücklich auch Ausschnitte. A9-Stichproben wurden nicht nachträglich als Finder-Abdeckung gezählt. Delta umfasst hier auch unmittelbar zugehörige Drag-, Menü- und Fenster-Helfer; daraus werden keine Lücken abgeleitet. Reproduzierbare Eingaben und Berechnung liegen ausschließlich temporär unter /private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/b2631fe4-cc2e-47fe-a074-88ecaa1a826c/scratchpad/a9-coverage.py und /private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/b2631fe4-cc2e-47fe-a074-88ecaa1a826c/scratchpad/a9-read-names.txt. Keine Berichtsdatei angelegt, keine Builds, Tests oder App-Starts ausgeführt.

**Vorgeschlagener Nachlauf-Prompt:** Ergänze den bestehenden Audit-Nachweis ausschließlich lesend um eine dateigenaue Zuordnung vollständig gelesen / Ausschnitt / nur durchsucht / Delta. Prüfe insbesondere große Integrationsdateien gegen die Selbstauskünfte mehrerer Finder; ein vollständiger Read durch einen Finder genügt. Übernimm keine Vollständigkeitsbehauptung allein aus files_read. Behalte die Delta-Ausnahmen bei und dokumentiere die Zuständigkeit ihrer unmittelbaren UI-Helfer ausdrücklich.

### W5: Ressourcenanzeige als ungeprüfter Polling-Caller — 246 Zeilen

*Priorität mittel*

AgentResourceSummaryButton wurde von keinem Finder genannt. Die Stichprobe zeigt zeitgesteuerte Ressourcenabfragen, Aktivitäts-Gating und einen Detached-Task; AgentResourceMonitor allein deckt den Lebenszyklus dieses Callers nicht ab. Das ist eine Querschnittslücke beim Kern-Budget W5, keine gemessene Performanceverletzung.

**Vorgeschlagener Nachlauf-Prompt:** Prüfe AgentResourceSummaryButton vollständig zusammen mit dem bereits auditierten AgentResourceMonitor: Task-Abbruch, Single-Flight, veraltete Ergebnisse, wechselnde Descriptoren, View-Abbau und aktives/inaktives Fenster. Dokumentiere pro Zustand die ausgelöste Arbeit und Grenzen der statischen Aussage. Wiederhole keine generische MainActor-Rüge, wenn die Arbeit bereits off-main ausgeführt wird. Messungen nur als späteren Prüfauftrag formulieren.

### Labs: fünf ungelesene VoiceGate-Helfer — 647 Zeilen

*Priorität mittel*

CommandMatcher: 308 Zeilen; StateMachine: 139; WatchdogPolicy: 82; ListenerHealth: 71; LocaleResolver: 47. A1 benennt diese Lücke selbst. Stichproben bestätigen Zustandsannahmen und Gesundheitsentscheidungen. Nach F-VG-01 ist nicht perfekte Erkennungsqualität zu auditieren, sondern insbesondere ein möglicher Einfluss auf Diktat, Mikrofon, Fokus und Prozessstabilität.

**Vorgeschlagener Nachlauf-Prompt:** Lies die fünf Helfer und ihre vorhandenen Tests ausschließlich unter Labs-Seiteneffekt-Gesichtspunkten. Verfolge Match-/Health-/Watchdog-Entscheidungen bis zu Start, Stop, Rebind und Toggle im bereits geprüften Coordinator. Prüfe Begrenzung wiederholter Aktionen, Deaktivierung, Wechsel der Audioquelle und Diktat-Vorrang. Melde keine reine Erkennungsqualitäts- oder Komfortlücke als Launch-Blocker; keine echten Mikrofon-/Fokusversuche ausführen.

### DoD Bedienbarkeit und Datenschutz: keine flächendeckende Profil-/Schalter-/Fehlermatrix

*Priorität mittel*

A5 belegt Sprachmischung, Kontrast- und einzelne Tastaturprobleme; A1/A2/A6 belegen konkrete Datenschutzpfade. Nicht nachgewiesen sind vollständige Abdeckung sämtlicher Fehlermeldungen, DE/EN-Lokalisierung, Bedienwege ohne defaults write, Datenabfluss-Erklärungen pro Provider und das Verhalten aller drei Nutzungsprofile. Automatische Nebenwirkungen von Erweitert/Labs sind dabei relevanter als deren Komfort.

**Vorgeschlagener Nachlauf-Prompt:** Baue lesend für jedes Feature des Inventars eine Matrix aus Profil, Default, sichtbarem Schalter, nötigen Rechten, Netzwerkempfänger, gespeicherten Daten und erklärtem Fehler-/Recovery-Weg. Berücksichtige Summary-Hilfsläufe, Rettungsaufnahmen, visuelle Dateikopien, Usage-Pings und Labs-deaktiviert. Prüfe neue ungelesene Oberflächen mit; Agent-Chats-/Plugin-UI bleibt Delta. E1 bedeutet DE und EN lokalisiert mit Englisch als Basis, nicht bloß eine einzige fest codierte Sprache. Kennzeichne VoiceOver-, Kontrast- und Tastatur-Laufzeitabnahmen als ausstehend.

### Altlasten und Dokumentation: A8 ausdrücklich nicht vollständig

*Priorität mittel*

A8 hat weder alle 41 hoch priorisierten Juni-Einträge und 26 Quick Wins noch sämtliche historischen IDs gegen heutigen Code abgeglichen. Von 40 Feature-Dokumenten wurde nur eine Auswahl gelesen. Ein historischer Offen-Status oder das Entfernen einer alten Implementierung bescheinigt nicht automatisch die Sicherheit ihrer heutigen Ersatzpfade.

**Vorgeschlagener Nachlauf-Prompt:** Vervollständige A8 lesend mit einer Matrix historischer Eintrag → heutiger Symbol-/Featurepfad → bestätigt, behoben, ersetzt, nicht mehr relevant oder Delta. Bearbeite insbesondere die von A8 ausdrücklich offengelassenen C-/N-/R4-IDs, ohne bestehende Finder-Befunde erneut zu zählen. Prüfe aktive Feature-Dokumente vollständig auf Produktstand und Links; trenne archivierte Pläne von Anwenderanleitungen. Neue Ersatzimplementierungen benötigen eigene Belege. Delta-IDs bleiben Handoff, keine Abdeckungslücke.

### Kern: kleine Geometrie-/Tastaturhelfer — zwei ungelesene Dateien, 69 Zeilen

*Priorität niedrig*

InspectorWidthResolver: 43 Zeilen; ProjectPickerKeyboard: 26. Kern-Nutzerführung W4/W5. Pure kleine Helfer haben gegenüber Daten-/Prozesspfaden geringeres Risiko, fehlen aber im Abdeckungsnachweis. Die Stichprobe beschreibt Breiten-Clamping beziehungsweise die Ordnerauswahl per Tastatur.

**Vorgeschlagener Nachlauf-Prompt:** Prüfe beide puren Resolver einschließlich vorhandener Tests lesend auf leere Listen, ungültige Auswahlindizes, Grenzbewegungen, nichtfinite/persistierte Breiten und sehr schmale Fenster. Unterscheide Logikabdeckung von tatsächlicher Event-Verdrahtung; ausgeschlossene Agent-Chats-Views bleiben Delta. Keine neue UI implementieren.

## Ungeprüfte Nutzerwege

- W1: Frischer Mac/Benutzer mit Homebrew → tatsächlich veröffentlichtes Cask → erster Start ohne Gatekeeper-Nacharbeit. Pipeline statisch geprüft, echte Installation und Vertrauenskette nicht abgenommen.
- W2: Profilwahl → TCC-Erteilung beziehungsweise Ablehnung und spätere Korrektur → persistierter Key → erfolgreiches Testdiktat → Text in fremder App. Kein durchgängiger Laufzeitnachweis, einschließlich Gerätewechsel und Fokuswechsel.
- W3: Codex fehlt → geführte Installation und Login mit Rückfrage → E-Mail-Modus → Ergebnis. Fehlender Installationsweg bereits gemeldet; der gesamte Nutzerweg wurde nicht ausgeführt.
- W4: Claude fehlt → geführte Installation und Login → Ordnerwahl/Trust → erster Chat mit korrektem Status. Installer-/Onboarding-Prüfung unvollständig; ausgeschlossene UI-Integration gehört zum Delta, nicht zu einer zusätzlichen A9-Lücke.
- W5: 10+ Chats im Alltag, abruptes Prozessende und Wiederstart ohne Datenverlust sowie definierter Lastlauf. Persistenz-/Recovery-Logik statisch geprüft, keine reale Crash-/Durabilitäts- oder Latenzabnahme. Tab-/Fenster-/Grid-Restore bleibt ausdrücklich Delta.
- W6: Ältere Cask-Version mit Daten, Rechten und Integrationen → sichtbarer Updatehinweis → Upgrade → unveränderte Daten und TCC-Freigaben. Kein praktischer Nachweis am ausgelieferten Artefakt.
- W7: Brew-Uninstall mit zap → keine weiterlaufenden app-eigenen Prozesse und keine zurückgelassenen Fremdänderungen; fremde CLI-Daten bleiben erhalten. Generator statisch geprüft, Ownership-/Restore-Inventar und isolierte Uninstall-Abnahme fehlen.

## Vermutete Duplikate

- A1-01 ↔ A5-02: derselbe Verlust laufender Diktate beim sofortigen Beenden.
- A1-02 ↔ A8, Befund 2: derselbe destruktive OutputMode-Fallback; A8-Befund 1 betrifft dagegen einen separaten Duplicate-ID-Trap.
- A1-07 ↔ A8, Befund 8: Auto-Paste trotz fehlgeschlagener Aktivierung beziehungsweise ohne verlässliche Zielprüfung.
- A1-15 ↔ A5-03: fehlender geführter Codex-Installationsweg; A5 ergänzt den Onboarding-Kontext.
- A2-02 ↔ A8, Befund 6: fehlende Schreibsperre für zukünftige Workspace-Schemata.
- A2-10 ↔ A5-09: zusätzlicher Summary-Datenabfluss wird nicht zutreffend erklärt; unterschiedliche Schweregrade vor Zusammenführung klären.
- A3-01 ↔ A5-01 ↔ A6-04 ↔ A8, Befund 7: verlorene konkurrierende settings.json-Änderungen. A6/A8 umfassen zusätzlich den Statusline-Schreiber; diesen Teil nicht durch reines Theme-Deduplizieren verlieren.
- A3-03 ↔ A6-05 ↔ A8, Befund 5: derselbe ungefilterte Parent-Secret-Umgebungsfluss.
- A3-08 ↔ A8, Befund 11: Stop vor Registrierung verhindert den späteren Codex-Prozessstart nicht.
- A3-09 ↔ A8, Befund 10, Orphan-Teil: veraltete Jobkorrektur überschreibt neueren Zustand.
- A3-10 ↔ A8, Befund 10, PID-Teil: UI-PID-Nachtrag umgeht die gehärtete Transaktion. Nicht mit dem separaten Orphan-Rennen zu einem unpräzisen Befund verschmelzen.
- A3-14 ↔ A8, Befund 9: Exit 0 ohne nachgewiesenen Turn-Abschluss gilt als Erfolg.
- A4-01 ↔ A6-02 ↔ A8, Befund 4: OAuth-Grant in argv beim Profil-Rename; A4 umfasst zusätzlich Promote.
- A6-01 ↔ A8, Befund 3: Verlust der einzigen Legacy-Key-Kopie nach gescheiterter Migration. A5-08 hat denselben fehlerhaften Speichervertrag, aber ein anderes Setup-Szenario; nicht ersatzlos deduplizieren.
- A5-18 ↔ A8, Befund 12: öffentliche Installationsdokumentation widerspricht Brew-only; A8 erweitert den Umfang auf das Handbuch.
- A6-08 ↔ A7-04: überlappende Uninstall-/Zap-Lücke. A6 fokussiert Fremdkonfigurationsreste, A7 zusätzlich Prozesse und Integrationen; gemeinsame Maßnahme, aber getrennte Abnahmekriterien.
- Nicht allein wegen gleicher Kategorie zusammenführen: A2-03, A4-01, A4-02 und A7-01 sind unterschiedliche argv-Expositionspfade; A1-12 und A8-Befund 16 behandeln Retry-Erreichbarkeit beziehungsweise Datenschutzerklärung, nicht denselben Defekt.
