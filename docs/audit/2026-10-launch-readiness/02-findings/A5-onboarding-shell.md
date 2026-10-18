---
status: roh
updated: 2026-10-17
description: Workflow A, A5 Onboarding, Settings, App-Hülle — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A5 Onboarding, Settings, App-Hülle

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

A5 statisch geprüft: 18 Befunde, davon 2 P0, 6 P1 und 10 P2. Hauptblocker sind konkurrierend überschriebene Claude-Einstellungen, ungesicherte Diktate beim Beenden, fehlende CLI-Installation und Sackgassen im Onboarding. Datenfluss: App-Start → Berechtigungs-Gate → profilabhängiger Wizard → Preferences/Keychain → Diktat beziehungsweise echte CLI im PTY; Updates laufen bislang ausschließlich über kopierbare Brew-Befehle. Positiv: Bildschirmaufnahme ist im Setup nicht obligatorisch, die Settings behandeln verweigerten Mikrofonzugriff korrekt, API-Keys werden nicht zurück in das Eingabefeld geladen und Theme-Tokens unterstützen beide Erscheinungsbilder. Bewusst erhalten bleiben müssen Tap-/Hold-Semantik, SIGTERM-Aufräumen, stabile Popover-Größe und bestehende CLI-/Profilfunktionen. Keine Builds, Tests, App-Starts oder Produktänderungen durchgeführt. Gemäß übergeordneter Vorgabe wurden keine Markdown-Berichtsdateien geschrieben; die Befunde stehen vollständig in diesem Objekt.

## Befunde

### LR-SH-002 (A5-01) · : Theme-Synchronisation überschreibt konkurrierende Claude-Einstellungen

*P0 · Launch-Blocker · race · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-AK-017*

**Features:** F-APP-02, F-APP-03  ·  **Alt-ID:** R4-AS-01

**Beleg:** `WhisperM8/WhisperM8App.swift:276-278 — initiale Synchronisation bei jedem GUI-Start, ohne Profil-Gate.`, `WhisperM8/Support/ThemeManager.swift:80-90 — Schemawechsel und Start rufen den globalen Writer auf.`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-153 — vollständiger Read-modify-replace ohne Revalidierung; der Parse-Guard erkennt nur ungültiges JSON, keine zwischenzeitliche gültige Änderung.`

**Szenario:** WhisperM8 liest settings.json mit Theme dark. Eine parallel laufende CLI oder ein Einstellungswerkzeug speichert danach eine neue Hook-/Berechtigungs-/MCP-Einstellung als gültiges JSON. WhisperM8 ersetzt anschließend die komplette Datei durch seinen alten Snapshot plus Theme light; die neue Einstellung verschwindet. Das ist auch im reinen Diktatprofil möglich und verletzt den Datenverlustschutz aus W5.

**Fix:** Theme möglichst ausschließlich über die unterstützte sitzungsbezogene Konfiguration setzen, statt fremde globale Einstellungen zurückzuschreiben. Falls globales Schreiben unvermeidbar bleibt, braucht es einen nachweislich konfliktfesten Schreibvertrag mit dem externen Writer; ein internes NSLock oder atomarer Rename allein genügt nicht. Invarianten: passende Terminal-Farben, unveränderte fremde Einstellungen, Profilisolation und Parse-fail-safe erhalten. Deterministischen Interleaving-Test ergänzen.

### LR-ONB-001 (A5-02) · : Beenden verwirft ein laufendes Diktat ohne Sicherung

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel · Duplikat von LR-DIK-001*

**Features:** F-APP-02, F-DIK-01  ·  **Alt-ID:** N02

**Beleg:** `WhisperM8/WhisperM8App.swift:428-449 — sofortiges terminateNow; kein Recording-/Transkriptions-Gate, nur Chat-Aufräumen, Ducking und Fenster-Flush.`, `WhisperM8/Services/Dictation/AudioRecorder.swift:132-150 — Aufnahme liegt unter zufälligem Namen im temporären Verzeichnis.`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:323-353 — reguläre Finalisierung und Übergabe an die Transkription erfolgen erst beim Stop-Pfad.`, `WhisperM8/Views/MenuBarView.swift:131-134 — Quit terminiert unmittelbar.`

**Szenario:** Ein Nutzer diktiert längeren Text und beendet die App über Quit/Cmd+Q oder während eines Neustarts. Der Quit-Hook finalisiert die Aufnahme nicht und überführt sie nicht in die wiederauffindbare Fehlaufnahme-Sicherung. Beim nächsten Start existiert kein Wiederaufnahmeweg für dieses Diktat; eine eventuell verbliebene zufällige Temp-Datei ist kein verlässlicher Nutzerdatenschutz. W5/W6 verlieren gesprochenen Inhalt.

**Fix:** Gemeinsames asynchrones Termination-Gate für Aufnahme und laufende Verarbeitung einführen: Aufnahme finalisieren und dauerhaft mit Wiederherstellungsmetadaten sichern, beziehungsweise explizit zwischen Warten, Sichern und Verwerfen wählen lassen. Erst anschließend terminateNow freigeben. Invarianten: Ducking zurückstellen, SIGTERM weiterhin sauber behandeln und Store-Flushes beibehalten.

### LR-ONB-002 (A5-03) · : Fehlendes Codex wird nicht installiert; Login führt aus der App heraus

*P1 · Launch-Blocker · ux · Konfidenz hoch · Aufwand L · Risiko mittel · Duplikat von LR-DIK-015*

**Features:** F-APP-01, F-DIK-09

**Beleg:** `WhisperM8/Views/OnboardingView.swift:308-346 — Codex-Schritt bietet nur Sign in und Check Again.`, `WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift:32-58 — auch Settings haben ausschließlich Login, Status und Version.`, `WhisperM8/Services/Dictation/CodexSupport.swift:191-215 — fehlt das Binary, wird nur eine Hilfeseite geöffnet; andernfalls ein Terminal-Skript gestartet.`

**Szenario:** Frischer Mac ohne Codex, Profil Dictation + AI enrichment gewählt: Status lautet Not installed. Sign in öffnet lediglich einen Hilfetext; es gibt keinen Installationsschritt. Auch bei vorhandenem Binary muss der Nutzer den Login im Terminal abschließen. W3 und die beschlossene Entscheidung E5 werden nicht erreicht.

**Fix:** Nach Zustimmung den offiziellen Codex-Installationsweg aus der App orchestrieren, Fortschritt/Fehler/erneute Erkennung anzeigen und den offiziellen Login geführt begleiten. Danach eine echte E-Mail-Umformulierung als Funktionstest anbieten. Raw-Fallback, bestehende Installationen und das Hosting der echten CLI erhalten.

### LR-ONB-003 (A5-04) · : Das Full-Onboarding besitzt keinen Claude-Installations- oder Login-Schritt

*P1 · Launch-Blocker · ux · Konfidenz hoch · Aufwand L · Risiko mittel*

**Features:** F-APP-01, F-AC-02, F-DIK-12

**Beleg:** `WhisperM8/Views/OnboardingView.swift:9-16,38-44 — Schritte umfassen nur Diktat-Setup und optional Codex, niemals Claude.`, `WhisperM8/Views/OnboardingView.swift:134-140 — Full-Abschluss öffnet unmittelbar Agent Chats.`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:76-128 — Workspace-Setup bietet Projekt und Provider, aber keine CLI-Einrichtung.`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:481-484 — alternativer Konten-Login endet bei fehlendem Binary mit install Claude Code first.`

**Szenario:** Ein Nutzer wählt auf einem frischen Mac Full, um seinen ersten Claude-Chat zu starten. Nach dem Wizard ist Claude weiterhin weder installiert noch angemeldet. Selbst der alternative Konten-Login verweist nur auf eine externe Installation. W4 bleibt ohne Terminal-/Dokumentationsnacharbeit unerfüllbar.

**Fix:** Im Full-Pfad den gewünschten Agent-Anbieter abfragen, dessen Installation erkennen und nach Zustimmung über den offiziellen Installer durchführen. Offiziellen Login und Projektwahl geführt anschließen; einen erfolgreichen Start nachweisen. Diktat-only darf dabei keine Agent-Abhängigkeit erhalten; echte CLI im PTY und bestehende Profilzuordnungen bleiben erhalten.

### LR-ONB-004 (A5-05) · : Mikrofon-Ablehnung erzeugt im Wizard eine Sackgasse

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-APP-01, F-APP-07

**Beleg:** `WhisperM8/Views/OnboardingView.swift:150-154 — Next bleibt ohne Mikrofonrecht gesperrt.`, `WhisperM8/Views/OnboardingView.swift:436-452,498-506 — alle nicht autorisierten Zustände erhalten denselben Grant-Button; dieser ruft ausschließlich requestAccess auf.`, `WhisperM8/Views/Settings/Models/PermissionSettingsModel.swift:104-114,149-159 — die Settings unterscheiden bereits denied/restricted und öffnen die Systemeinstellungen.`

**Szenario:** Der Nutzer lehnt den ersten Mikrofon-Dialog versehentlich ab. Ein erneutes Grant fordert bei denied nicht nochmals interaktiv an; Next bleibt deaktiviert. Im Wizard gibt es weder Open Settings noch eine Erklärung zur manuellen Reparatur. W2 scheitert an einem gewöhnlichen Fehlerpfad.

**Fix:** Den bestehenden PermissionSettingsModel-Vertrag auch im Wizard verwenden: notDetermined anfragen, denied gezielt zu den Mikrofon-Einstellungen führen, restricted verständlich erklären. Rückkehr automatisch erkennen und konkrete nächste Schritte anzeigen. Keine wiederholten wirkungslosen Anfragen.

### LR-ONB-005 (A5-06) · : Nach Rechtevergabe kann ein unvollständiges Setup dauerhaft verschwinden

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-APP-01, F-DIK-01, F-DIK-02

**Beleg:** `WhisperM8/WhisperM8App.swift:204-207,385-395 — automatisches Onboarding hängt ausschließlich an Mikrofon und Accessibility.`, `WhisperM8/Views/OnboardingView.swift:38-44 — Hotkey und API-Key kommen erst nach dem Rechteschritt.`, `WhisperM8/Views/MenuBarView.swift:63-70,108-119 — bei fehlendem Hotkey nur Statushinweis; kein Wizard-Neustart.`, `WhisperM8/Views/SettingsView.swift:243-279 — Settings enthalten keinen Onboarding-Einstieg.`

**Szenario:** Der Nutzer erteilt beide Rechte und schließt anschließend das Setup vor Hotkey/API-Key, etwa um einen Key zu besorgen. Nach App-Neustart ist needsOnboarding false. Er landet ohne funktionsfähiges Diktat im normalen App-Zustand und muss die fehlenden Schritte über mehrere Settings-Seiten selbst zusammensuchen. Der dokumentierte Guard gegen unnötige Wizard-Wiederholungen verfehlt hier W2.

**Fix:** Nicht zum alten alleinigen onboardingCompleted-Flag zurückkehren. Stattdessen tatsächliche Betriebsbereitschaft pro Profil prüfen, fehlende Pflichtschritte gezielt fortsetzen und einen sichtbaren Setup-fortsetzen-Einstieg anbieten. Vollständig konfigurierte Bestandsinstallationen dürfen weiterhin nicht erneut durch den Wizard gezwungen werden.

### LR-ONB-006 (A5-07) · : Schon ein versehentlich getipptes Zeichen ersetzt den funktionierenden API-Key

*P1 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-APP-01, F-APP-03, F-DIK-02

**Beleg:** `WhisperM8/Views/OnboardingView.swift:635-640 — jeder nicht leere Zwischenstand wird sofort gespeichert; Leeren stellt nichts wieder her.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:107-113 — identisches Verhalten in Settings.`, `WhisperM8/Services/Shared/KeychainManager.swift:23-31 — SecItemUpdate ersetzt den bestehenden Wert.`, `WhisperM8/Views/TranscriptionAccountControls.swift:49-51 — das Eingabefeld enthält bewusst nicht den bisherigen Key.`

**Szenario:** Ein gültiger Key ist gespeichert. Der Nutzer klickt in das maskierte Feld, tippt versehentlich x und löscht es wieder. Bereits x hat den gültigen Key ersetzt; das anschließende leere Feld löst keinen Rollback aus. Die nächste Transkription schlägt fehl, und der zuvor funktionierende Zugang ist nicht mehr aus der App wiederherstellbar.

**Fix:** Getippten Key ausschließlich als Entwurf halten. Erst bei explizitem Save/Replace und erfolgreicher Validierung speichern; Abbrechen oder Leeren muss den bisherigen Key unverändert lassen. Maskierung und das Nicht-Zurückladen des bestehenden Secrets in die UI beibehalten. Regressionstest für Tippen→Leeren ergänzen.

### LR-ONB-007 (A5-08) · : Fehlgeschlagene Keychain-Writes werden im Setup als vorhandener Zugang behandelt

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-APP-01, F-DIK-02  ·  **Alt-ID:** N06

**Beleg:** `WhisperM8/Services/Shared/KeychainManager.swift:10-34 — save liefert Void; Fehler erscheinen ausschließlich im Log.`, `WhisperM8/Views/OnboardingView.swift:639-640 — apiKeyAvailable wird unabhängig vom Speicherausgang true.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:111-119 — gleicher falscher Erfolgszustand mit Saved-Key-Anzeige.`, `WhisperM8/Views/OnboardingView.swift:156-176 — Zugangsgates vertrauen dem lokalen Zustand.`

**Szenario:** Der Schlüsselbund ist gesperrt oder verweigert den Schreibzugriff. Ein eingegebener Key wird nicht gespeichert, das Onboarding lässt den Nutzer dennoch weiter und abschließen. Nach Leeren des Feldes kann sogar Saved Key erscheinen, obwohl kein neuer Key existiert. Der Diktatpfad lädt danach nil oder den alten ungültigen Wert; für den Nutzer fehlt eine verständliche Reparaturaktion.

**Fix:** Keychain-Schreiboperation als Result/throwing Vertrag anbieten und Erfolg erst nach bestätigtem Write beziehungsweise Readback übernehmen. Bei Fehler Entwurf erhalten, verständlichen Hinweis und Retry anbieten; vorhandenen Key nicht zerstören. Zugangsprüfung und UI müssen denselben bestätigten Speicherzustand verwenden.

### LR-ONB-008 (A5-09) · : Automatische Zusammenfassungen widersprechen der Datenschutzerklärung in den Settings

*P2 · Launch-Blocker · privacy · Konfidenz hoch · Aufwand S · Risiko niedrig · Duplikat von LR-AK-010*

**Features:** F-APP-03, F-AC-07

**Beleg:** `WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:51-54 — behauptet Nothing else leaves your machine nach Aufzählung von Diktat und Modus-Kontext.`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:69,124-127 — Zusammenfassungen standardmäßig an; Beschreibung nennt keinen weiteren Modellaufruf, Empfänger oder Kontingentverbrauch.`, `WhisperM8/Views/Transcript/SessionSummaryCard.swift:63-68 — Anzeigen kann automatisch eine Zusammenfassung auslösen.`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-39,87-113,325-340 — Chat-Auszüge und Fakten werden zu einem neuen Prompt für claude -p beziehungsweise codex exec.`

**Szenario:** Ein Nutzer versteht den Verlauf beziehungsweise seine Zusammenfassung als lokale Ansicht und verlässt sich auf Nothing else leaves your machine. Beim Anzeigen eines geeigneten beendeten Chats sendet die App automatisch einen weiteren Auszug an einen Modellanbieter und verbraucht Kontingent. Dieser Datenfluss ist weder in der Privacy-Aufzählung noch am automatischen Schalter erklärt; die DoD verlangt eine zutreffende Erklärung jedes Datenabflusses.

**Fix:** Privacy-Text vollständig korrigieren und am Zusammenfassungs-Schalter deutlich erklären: externe Modellverarbeitung, welche Auszüge/Fakten gesendet werden, tatsächlicher Empfänger/Kontobezug und möglicher Verbrauch. Vor dem ersten automatischen Lauf eine verständliche Entscheidung ermöglichen. Bestehenden Abschalter, Digest-Guard und lokale Report-Zusammenfassungen ohne Modellaufruf erhalten.

### LR-ONB-009 (A5-10) · : Diktatprofile erhalten keinen sichtbaren automatischen Update-Hinweis

*P2 · Launch-Blocker · ux · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-APP-04, F-DIK-12

**Beleg:** `WhisperM8/Services/Shared/AppUpdateChecker.swift:97-111,162-169 — Automatik setzt nur den internen available-Zustand.`, `WhisperM8/Views/AppUpdateViews.swift:9-30,123-157 — sichtbare Hinweise befinden sich im Sidebar-Badge und in About.`, `WhisperM8/Views/MenuBarView.swift:15-135 — kein Update-Status und kein Update-Eintrag.`, `WhisperM8/Models/AppUsageProfile.swift:29-37 — Diktatprofile laufen ohne reguläres Dock-Fenster.`

**Szenario:** Der Nutzer verwendet ausschließlich Dictation only und öffnet keine Agent Chats oder About-Seite. Der tägliche Check findet eine neue Version, aber in seiner normalen Oberfläche erscheint keinerlei Hinweis. W6 beginnt für dieses ausdrücklich unterstützte Profil nie mit App meldet Update.

**Fix:** Den zentralen Update-Zustand auch in der Menüleiste sichtbar machen und dort eine erreichbare Update-Aktion anbieten. Automatik aus respektieren, keine wiederholten aufdringlichen Meldungen und keine breite Reaktivitätsabhängigkeit großer Chat-Views einführen.

### LR-ONB-010 (A5-11) · : Der Update-Dialog endet bei einem Terminal-Befehl statt einer geführten Aktualisierung

*P2 · Launch-Blocker · ux · Konfidenz hoch · Aufwand L · Risiko mittel*

**Features:** F-APP-04

**Beleg:** `WhisperM8/Views/AppUpdateViews.swift:51-69 — ausschließlich CopyableCommandBox und Im Terminal ausführen; kein Ausführungs-/Fortschritts-/Ergebnisweg.`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:20-26 — Upgrade und Adopt werden als zwei unterschiedliche Befehle bereitgestellt.`

**Szenario:** Ein Laie öffnet den Update-Hinweis und kopiert den Befehl. Die App erklärt nicht geführt, wie er ausgeführt wird, prüft keinen Erfolg und bietet keine Reparatur für Brew-Fehler. Beim Adopt-Fall steht zusätzlich zuerst der ohne Receipt ungeeignete Upgrade-Befehl. Der Nutzer muss den eigentlichen W6-Ablauf selbst außerhalb der App organisieren.

**Fix:** Homebrew als einzigen Installationskanal erhalten, aber einen verständlichen geführten Update-Ablauf mit Zustimmung, korrekt gewähltem Upgrade-/Adopt-Pfad, sichtbarem Ergebnis und sicheren Neustart anbieten. Daten-/Prozessschutz und stabile signierte App-Identität vor Relaunch nachweisen; keine ungefragte Hintergrundinstallation.

### LR-ONB-011 (A5-12) · : Die UI bleibt hart codiert zweisprachig statt lokalisiert

*P2 · Launch-Blocker · ux · Konfidenz hoch · Aufwand L · Risiko mittel*

**Features:** F-APP-01, F-APP-03, F-APP-04, F-APP-07

**Beleg:** `WhisperM8/Views/OnboardingView.swift:191-203,381-403,614-620 — englischer Wizard.`, `WhisperM8/Models/TranscriptionProvider.swift:154-160 — deutsche Modellbeschreibungen innerhalb dieses Wizards.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:89-91,130-140 — englischer Seitenrahmen mit deutschen Status-/Kontotexten.`, `WhisperM8/Views/AppUpdateViews.swift:44-72 — deutscher Update-Dialog in englischem About.`, `WhisperM8/Info.plist:17-22 — ausschließlich deutsche Usage-Descriptions.`

**Szenario:** Auf einem englischen Mac durchläuft der Nutzer einen englischen Wizard, erhält aber deutsche Modellbeschreibungen, System-Begründungen und Update-Anweisungen. Auf einem deutschen Mac bleiben die meisten Settings englisch. Eine heuristische Zählung der geprüften UI-Dateien erfasste rund 390 direkt deklarierte UI-Literale, davon mindestens 25 mit deutschen Sprachmarkern; zahlreiche dynamische Texte sind darin noch nicht enthalten. Im App-Quellbaum wurden keine String-Kataloge oder Lokalisierungsressourcen gefunden. Das verletzt E1 und die DoD einer konsistenten Sprache.

**Fix:** Englisch als Basis und Deutsch als vollständige Lokalisierung über native String-Kataloge einschließlich InfoPlist-Texte einführen. Provider-/Modellmetadaten und Fehlermeldungen ebenfalls lokalisieren, nicht nur SwiftUI-Textliterale. Fachnamen und CLI-Befehle unverändert lassen; beide Sprachen über denselben Satz von Onboarding-/Settings-Fixtures prüfen.

### LR-ONB-012 (A5-13) · : Kern-Settings trennen Labs und Expertenfunktionen nicht vom normalen Setup

*P2 · Launch-Blocker · ux · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-APP-03, F-DIK-12, F-DIK-03, F-GPT-01, F-VG-01

**Beleg:** `WhisperM8/Views/SettingsView.swift:132-138,147-149 — identische ungefilterte Navigation für alle Profile; GPT-Backend steht regulär neben Accounts und Hooks.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:42,94-99 — ChatGPT-Abo wird beim standardmäßig aktiven Feature-Schalter regulär angeboten, unabhängig von eingerichtetem Backend.`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:8-24,37-38 — Codex Voice Agent ist ein normaler Tab, nicht Labs.`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:53-61 — keine Kennzeichnung als experimenteller, inoffizieller Upstream.`

**Szenario:** Ein Diktat-only-Nutzer öffnet Settings und sieht alle 13 Seiten einschließlich Accounts, Hooks, CLI/Skills und GPT-Backend. In der normalen Providerwahl wirkt ChatGPT-Abo wie eine gleichwertige Standardoption, führt bei ausgeschaltetem Backend aber zunächst in dessen Einrichtung. Die beschlossene Kern/Erweitert/Labs-Trennung und E2 werden auf der zentralen Kernoberfläche nicht umgesetzt; die Profilwahl reduziert die Komplexität nicht.

**Fix:** Kern-Setup profilgerecht priorisieren, Erweitert ausdrücklich absetzen und Labs hinter einem klar beschrifteten experimentellen Bereich anbieten. Unfertige Labs-Abhängigkeiten nicht als regulären sofort nutzbaren Transkriptionsanbieter darstellen. Alle vorhandenen Funktionen und bestehende gespeicherte Auswahlen weiterhin erreichbar halten; kein Feature-Ausbau durch Verstecken.

### LR-ONB-013 (A5-14) · : Ungültiger Key und fehlgeschlagenes Testdiktat verhindern keine Erfolgsmeldung

*P2 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko niedrig*

**Features:** F-APP-01, F-DIK-02

**Beleg:** `WhisperM8/Models/TranscriptionProvider.swift:122-125 — beliebiger nicht leerer String, auch Leerzeichen, erfüllt das Credential-Gate.`, `WhisperM8/Views/OnboardingView.swift:168-176 — canFinish prüft weder Zugangsgültigkeit noch Testergebnis.`, `WhisperM8/Views/OnboardingView.swift:783-829 — All set ist bedingungslos; Fehler wird lediglich angezeigt, externe Textzustellung nicht geprüft.`

**Szenario:** Der Nutzer fügt versehentlich einen falschen oder nur aus Leerzeichen bestehenden Key ein. Er kommt bis All set und kann Done anklicken, selbst nachdem das Testdiktat einen Authentifizierungsfehler gezeigt hat. Auch eine tatsächlich erfolgreiche Transkription beweist hier keine Zustellung in eine fremde App. Der Assistent meldet Erfolg, obwohl W2 nicht erfolgreich durchlaufen wurde.

**Fix:** Eingaben trimmen, einen expliziten Zugangstest mit verständlichem Fehler-/Korrekturweg anbieten und Setup-Status vom erfolgreichen Test abhängig benennen. Testaufnahme und externe Einfügeprüfung getrennt führen. Falls Überspringen erlaubt bleibt, eindeutig als ungetestetes Setup kennzeichnen statt All set.

### LR-ONB-014 (A5-15) · : Die Modellauswahl im Onboarding ist nicht per Tastatur bedienbar

*P2 · ux · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-APP-01, F-DIK-02

**Beleg:** `WhisperM8/Views/OnboardingView.swift:675-699 — Modellzeilen bestehen aus HStack/Text/Images und onTapGesture; keine Button-/Picker-Semantik oder Fokusaktion.`, `WhisperM8/Views/Settings/Kit/SettingsPickerRow.swift:25-34 — ein vorhandener nativer Picker-Baustein besitzt bereits Label-Semantik.`

**Szenario:** Ein Nutzer mit reiner Tastaturbedienung beziehungsweise VoiceOver möchte im API-Key-Schritt das zweite Modell auswählen. Anders als echte Buttons oder Picker sind die Zeilen keine regulär fokussierbaren Auswahlsteuerelemente; der Auswahlwechsel ist nur als Tap-Geste implementiert. Die sichtbare Auswahlmöglichkeit ist für ihn nicht gleichwertig erreichbar.

**Fix:** Nativen Picker/Radio-Group oder echte Buttons mit zugänglichem Ausgewählt-Zustand verwenden. Dekorative Kreise aus dem Accessibility-Baum entfernen und Modellname/Beschreibung sinnvoll gruppieren. Tastatur- und VoiceOver-Prüfung ergänzen; Defaults und persistierte Modellwahl erhalten.

### LR-ONB-015 (A5-16) · : Nach fehlgeschlagenem Vorlagen-Speichern wird Save deaktiviert

*P2 · robustheit · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-DIK-09, F-APP-03

**Beleg:** `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift:32-40 — canSave hängt ausschließlich am Vergleich zwischen Entwurf und templates.`, `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift:117-126 — templates wird vor dem potenziell fehlschlagenden Disk-Write auf die Entwurfswerte gesetzt; catch stellt den alten Stand nicht wieder her.`, `WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift:168-172 — Save ist danach durch canSave gesperrt.`

**Szenario:** Ein Nutzer ändert eine eigene Vorlage und klickt Save bei voller Platte oder fehlenden Schreibrechten. Der Write wirft einen Fehler, aber das In-Memory-Original entspricht bereits dem Entwurf. isDirty wird false und Save deaktiviert. Selbst nach Beheben des Speicherproblems lässt sich derselbe Entwurf nicht erneut speichern; nach Reload steht wieder die alte Datei zur Verfügung.

**Fix:** Einen separaten Kandidaten schreiben und den bestätigten Originalzustand erst nach erfolgreicher Persistenz ersetzen. Bei Fehler den Entwurf dirty und Save/Retry aktiv halten, mit verständlicher Handlungsanweisung. Test für Write-Fehler→Speicherproblem behoben→unveränderter Retry ergänzen.

### LR-ONB-016 (A5-17) · : Zentrale Hilfetexte unterschreiten den normalen Textkontrast

*P2 · ux · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-APP-03

**Beleg:** `WhisperM8/Support/AppTheme.swift:12-15,91-94 — textTertiary ist Schwarz mit 42 Prozent auf Weiß beziehungsweise Weiß mit 38 Prozent auf dunklem Hintergrund.`, `WhisperM8/Views/Settings/Kit/SettingsRow.swift:25-30 — normale erklärende Texte mit 11,5 pt verwenden textTertiary.`, `WhisperM8/Views/Settings/Kit/SettingsHelpText.swift:9-12,29-33 — derselbe Token ist Standard für Hilfetexte.`, `WhisperM8/Views/Settings/Kit/SettingsPageContainer.swift:36 — Seitenhintergrund ist AppTheme.background.`

**Szenario:** Ein Nutzer mit eingeschränkter Sehfähigkeit liest die kleinen Erklärungen zu Rechten, Profilen oder Datenschutz. Aus den deklarierten sRGB-Werten berechnet ergeben sich auf dem Seitenhintergrund ungefähr 3,04:1 im Light Mode und 3,56:1 im Dark Mode, unter 4,5:1 für normalen Text. Es handelt sich um Handlungsinformationen, nicht bloß deaktivierte Dekoration.

**Fix:** Für leserelevante Hilfetexte einen Token mit mindestens 4,5:1 in beiden Themes verwenden und den schwächeren Token auf nicht wesentliche Dekoration beschränken. Kontrastberechnung für Tokens sowie visuelle Prüfung mit Increase Contrast ergänzen; bestehende Light-/Dark-Umschaltung erhalten.

### LR-DOK-001 (A5-18) · : Die README bewirbt weiterhin ausgeschlossene Installationswege

*P2 · Launch-Blocker · doku · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-APP-01, F-APP-04

**Beleg:** `README.md:65-75 — Build from Source wird als Installationsabschnitt mit make install angeboten.`, `README.md:77-85 — Direct DMG download wird einschließlich manueller Quarantäne-Entfernung beworben.`, `README.md:89-93 — Setup beschreibt nur Rechte/Hotkey/API-Key, nicht den für W3/W4 erforderlichen CLI-Installations-/Login-Weg.`

**Szenario:** Ein neuer Nutzer folgt statt des empfohlenen Brew-Wegs einem gleichrangig dokumentierten DMG- oder Source-Installationsabschnitt. Er landet bei Terminal-Nacharbeit beziehungsweise einer nicht vom vorgesehenen Updatekanal verwalteten Kopie. Die öffentliche Anleitung widerspricht ausdrücklich dem einzigen Launch-Installationsweg und bildet die versprochenen Agent-/Enrichment-Nutzerwege nicht ab.

**Fix:** Endnutzer-Installation und Updates ausschließlich über den beschlossenen Brew-Cask dokumentieren. Build-Anleitung klar in Entwicklerdokumentation auslagern, DMG/Quarantäne-Umgehung nicht als Endnutzerweg bewerben. Geführtes Diktat-/Agent-Setup nach Umsetzung anhand der realen App-Schritte dokumentieren.

## Nicht abgedeckt

- Keine Rohbericht- oder Lagebild-Markdowndatei angelegt: Die übergeordnete Arbeitsvorgabe verbietet solche Dateien. report_path ist deshalb leer; Befunde und Kurzlage werden direkt strukturiert zurückgegeben.
- Keine Builds, Tests, App-Starts, Snapshots, TCC-Resets oder echten Installationen ausgeführt. Laufzeitverhalten unter VoiceOver, Keyboard Navigation, Increase Contrast und unterschiedlichen Displaygrößen bleibt praktisch zu prüfen.
- W1/E4: tatsächliche Developer-ID-Signatur, Notarisierung, Cask-Installationsverhalten und TCC-Erhalt beim Brew-Upgrade nicht verifiziert. Die README-Aussage zur Selbstsignierung ersetzt keine Prüfung des ausgelieferten Bundles.
- W7: vollständige Brew-Zap-/Uninstall-Prozessbereinigung und Restore fremder Konfigurationen liegen außerhalb des geprüften App-/Settings-Pfads.
- Die ausdrücklich ausgeschlossenen AgentChatsView-, Grid-, Tab-, Sidebar-, TabSwitcher-, Workspace-, AgentWindowStore-, Layout-, JarvisBoard-, ControlServer-, Chats-CLI-/Guard-/Journal- und Plugin-Ressourcendateien wurden nicht inhaltlich auditiert. Fenster-Restore-/Profilwechsel-End-to-End und tatsächliche Sidebar-Einbindung brauchen den Delta-Lauf.
- Konten-/GPT-Backend-Logik bleibt A4; Settings-Seiten dazu wurden auf Nutzerführung und mögliche Kern-Seiteneffekte gelesen, nicht als vollständiges Account-/Proxy-Sicherheitsaudit bewertet.
- Diktat- und Audio-Engine-Logik bleibt A1; zusätzlich gelesene Recorder-/Coordinator-Dateien dienten nur der Verifikation des Quit-Verlusts und der bestehenden Hotkey-Semantik.
- Keine quantifizierte Main-Thread-/CPU-/Speicherprüfung. Statische I/O-Stellen wurden nicht ohne belastbare Laufzeitkosten als Performance-Defekte hochgestuft.
- Rechte und ACLs neu angelegter Theme-Backups/Temporärdateien, Shell-Pfadquotierung bei Login-Skripten sowie Profilwechsel während laufender Hintergrundoperationen wurden nicht abschließend verifiziert.
- Die Juli-Referenz N06 beschreibt zusätzlich den Verlust der einzigen Legacy-Key-Kopie beim fehlgeschlagenen Migrations-Write. Hier wurde nur der unmittelbar zum Setup gehörige falsche Speicher-Erfolgszustand erneut gemeldet; den vollständigen Migrationsfall mit A1/shared deduplizieren.

## Gelesene Dateien

84 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/findings-matrix.md`
- `README.md`
- `WhisperM8/WhisperM8App.swift`
- `WhisperM8/Views/OnboardingView.swift`
- `WhisperM8/Views/SettingsView.swift`
- `WhisperM8/Views/MenuBarView.swift`
- `WhisperM8/Views/AppUpdateViews.swift`
- `WhisperM8/Views/VoiceGateMenuSection.swift`
- `WhisperM8/Views/ProviderIcon.swift`
- `WhisperM8/Views/FocusableTextField.swift`
- `WhisperM8/Views/AgentStatusIndicator.swift`
- `WhisperM8/Views/TranscriptionAccountControls.swift`
- `WhisperM8/Views/Transcript/SessionSummaryCard.swift`
- `WhisperM8/Services/Shared/AppProfileActivator.swift`
- `WhisperM8/Services/Shared/AppUpdateChecker.swift`
- `WhisperM8/Services/Shared/PermissionService.swift`
- `WhisperM8/Services/Shared/CLISymlinkInstaller.swift`
- `WhisperM8/Services/Shared/WindowRequestCenter.swift`
- `WhisperM8/Services/Shared/KeychainManager.swift`
- `WhisperM8/Support/AppearanceOverride.swift`
- `WhisperM8/Support/AppTheme.swift`
- `WhisperM8/Support/ThemeManager.swift`
- `WhisperM8/Models/AppUsageProfile.swift`
- `WhisperM8/Models/TranscriptionProvider.swift`
- `WhisperM8/Models/AppState.swift`
- `WhisperM8/Info.plist`
- `WhisperM8/WhisperM8.entitlements`
- `WhisperM8/Services/Dictation/CodexSupport.swift`
- `WhisperM8/Services/Dictation/RecordingCoordinator.swift`
- `WhisperM8/Services/Dictation/AudioRecorder.swift`
- `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift`
- `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift`
- `WhisperM8/Views/Settings/Kit/ClipboardClient.swift`
- `WhisperM8/Views/Settings/Kit/SettingsButtonRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsCodeBlock.swift`
- `WhisperM8/Views/Settings/Kit/SettingsCopyCommandRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsFeedbackState.swift`
- `WhisperM8/Views/Settings/Kit/SettingsHelpText.swift`
- `WhisperM8/Views/Settings/Kit/SettingsKeyRecorderRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsKitPreview.swift`
- `WhisperM8/Views/Settings/Kit/SettingsListPanel.swift`
- `WhisperM8/Views/Settings/Kit/SettingsPageContainer.swift`
- `WhisperM8/Views/Settings/Kit/SettingsPickerRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsSection.swift`
- `WhisperM8/Views/Settings/Kit/SettingsSliderRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsStatusRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsStatusTone.swift`
- `WhisperM8/Views/Settings/Kit/SettingsStepperRow.swift`
- `WhisperM8/Views/Settings/Kit/SettingsTabs.swift`
- `WhisperM8/Views/Settings/Kit/SettingsTextArea.swift`
- `WhisperM8/Views/Settings/Kit/SettingsToggleRow.swift`
- `WhisperM8/Views/Settings/Models/AgentCLIArgumentsPreview.swift`
- `WhisperM8/Views/Settings/Models/CodexConnectionModel.swift`
- `WhisperM8/Views/Settings/Models/OutputArchiveViewModel.swift`
- `WhisperM8/Views/Settings/Models/OutputModesViewModel.swift`
- `WhisperM8/Views/Settings/Models/PermissionSettingsModel.swift`
- `WhisperM8/Views/Settings/Models/SettingsRouteTarget.swift`
- `WhisperM8/Views/Settings/Models/TemplateEditorModel.swift`
- `WhisperM8/Views/Settings/Pages/AboutSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift`
- `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/AgentChatsVoiceAgentTab.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputModesTab.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputTemplatesTab.swift`
- `WhisperM8/Views/Settings/Pages/AIOutputTestLabTab.swift`
- `WhisperM8/Views/Settings/Pages/ClaudeAccountsSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/ClaudeMCPSyncSection.swift`
- `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/GeneralSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/GPTAccountsSection.swift`
- `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/GPTBackendSetupRunner.swift`
- `WhisperM8/Views/Settings/Pages/OutputWorkspacePage.swift`
- `WhisperM8/Views/Settings/Pages/PermissionsSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/RecordingSettingsPage.swift`
- `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift`
- `Tests/WhisperM8Tests/PermissionSettingsModelTests.swift`
