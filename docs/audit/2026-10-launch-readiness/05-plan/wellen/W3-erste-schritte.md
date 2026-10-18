---
status: beschlossen
updated: 2026-10-18
description: Welle W3 des Launch-Readiness-Plans — Erste Schritte: Onboarding, CLI-Installation (E5), fremde Setups. Befunde, Abnahmekriterien, Tests zuerst.
---

# W3 · Erste Schritte: Onboarding, CLI-Installation (E5), fremde Setups

W2–W4 ohne Terminal: Das Onboarding fragt die Diktiersprache, führt durch Claude- und Codex-Installation samt Login (E5 b, mit Rückfrage, vorhandene Installationsart respektieren), fängt Fehleingaben ab und meldet nur dann Erfolg, wenn das Testdiktat klappte. Fehlt eine CLI beim Chatstart, gibt es einen geführten Weg statt eines Balkens. WhisperM8 räumt nie fremde Skills, Plugins, Statuslines oder Projektverläufe weg.

**Umfang:** 23 Befunde · P1 5, P2 12, P3 6 · 6 Launch-Blocker · Aufwand S×12, M×9, L×2

## Abnahmekriterien der Welle

- [ ] W3.0 zuerst: String Catalog (Englisch Basis, Deutsch) und Lokalisierungs-Guard stehen; alle neuen Texte dieser Welle sind lokalisiert.
- [ ] Frisches macOS-Benutzerkonto ohne claude/codex: Onboarding → Installation (offizieller Weg, Rückfrage) → Login → erster Chat und erstes Codex-Diktat, ohne Terminal (manueller Durchlauf W2–W4, protokolliert).
- [ ] Chatstart ohne CLI legt keine Session an und zeigt den geführten Leerzustand mit „Erneut prüfen“.
- [ ] Diktiersprache folgt der Systemsprache bzw. Auswahl im Onboarding; Bestandsnutzer behalten ihren Wert.
- [ ] Mikrofon-Ablehnung führt zu „Systemeinstellungen öffnen“ statt Sackgasse; ein getipptes Zeichen ersetzt keinen gespeicherten Key; Keychain-Fehler und ungültige Keys verhindern „All set“.
- [ ] Login-Shell-Abfrage blockiert den Main Thread nie dauerhaft (Timeout, off-main); Proxy-/CA-Variablen kommen per Positivliste an.
- [ ] Fremde Konfiguration bleibt unangetastet: ungestempelte Skills, fremde Plugin-Verzeichnisse, Nicht-UTF-8-Statuslines, konkurrierende Theme-Einstellungen, fremde Projektverläufe (je Test).

## Test-Infrastruktur zuerst

- String Catalog + Lokalisierungs-Guard (W3.0).
- KeychainManager-Seam (statisches enum → Protokoll mit `.live`).
- Reiner OnboardingCompletionGate statt privatem `canFinish`.

## Lückenschluss zu Beginn (Kritiker Delta-Lauf)

- Zu Beginn: End-to-End-Durchlauf als Laie auf frischem Benutzerkonto – Trust-Dialog, Login in der TUI, Ordnerzugriff Desktop/Dokumente. Funde ins Register.
- Plugin-Mod und `WhisperM8ClaudePlugin`: Verhalten bei Claude-Code-Update, kaputter Mod, zweiter App-Instanz (die Mod läuft in jedem Chat).

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/onboarding-shell.md](../../00-scope/oracle/onboarding-shell.md), [oracle/shared-infra.md](../../00-scope/oracle/shared-infra.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-AU-022 | P1 | ja | M | niedrig | geplant · unverifiziert | Fehlende Claude/Codex-CLI beim Chatstart: nur englischer Mini-Balken, kein Weg weiter, Leer-Chats sammeln sich an |
| LR-DIK-015 | P1 | ja | L | mittel | geplant · bestätigt | Fehlende Codex-CLI führt nur zu einer Hilfeseite statt Installation |
| LR-DIK-024 | P1 | ja | M | niedrig | geplant · unverifiziert | Diktiersprache ist fest auf Deutsch voreingestellt, das Onboarding fragt sie nicht ab |
| LR-ONB-003 | P1 | ja | L | mittel | geplant · bestätigt | Das Full-Onboarding besitzt keinen Claude-Installations- oder Login-Schritt |
| LR-ONB-004 | P1 | ja | S | niedrig | geplant · bestätigt | Mikrofon-Ablehnung erzeugt im Wizard eine Sackgasse |
| LR-SH-007 | P2 | ja | M | mittel | geplant · teilbestätigt | Die Login-Shell-Abfrage kann den ersten Chatstart dauerhaft auf dem Hauptthread blockieren |
| LR-AU-004 | P2 | — | S | niedrig | geplant · unverifiziert | „Neuer Chat“ startet bei nur auto-importierten Projekten in einem unsichtbaren Projekt, während die Sidebar „Noch keine Projekte“ zeigt |
| LR-AU-029 | P2 | — | S | niedrig | geplant · unverifiziert | Leerzustände ohne Anleitung; Markdown-Sternchen und widersprüchliche Begriffe |
| LR-ONB-005 | P2 | — | M | niedrig | geplant · teilbestätigt | Nach Rechtevergabe kann ein unvollständiges Setup dauerhaft verschwinden |
| LR-ONB-006 | P2 | — | M | niedrig | geplant · teilbestätigt | Schon ein versehentlich getipptes Zeichen ersetzt den funktionierenden API-Key |
| LR-ONB-007 | P2 | — | M | niedrig | geplant · teilbestätigt | Fehlgeschlagene Keychain-Writes werden im Setup als vorhandener Zugang behandelt |
| LR-ONB-013 | P2 | — | M | niedrig | geplant · bestätigt | Ungültiger Key und fehlgeschlagenes Testdiktat verhindern keine Erfolgsmeldung |
| LR-ONB-017 | P2 | — | S | niedrig | geplant · bestätigt | Das Codex-Login-Skript quotiert den aufgelösten Binary-Pfad nicht |
| LR-PJ-001 | P2 | — | S | niedrig | geplant · teilbestätigt | Die Plugin-Migration räumt fremde, ungestempelte Skills automatisch weg |
| LR-SH-003 | P2 | — | M | mittel | geplant · teilbestätigt | Fehlgeschlagene Keychain-Migration löscht die einzige persistierte API-Key-Kopie |
| LR-SH-004 | P2 | — | S | niedrig | geplant · teilbestätigt | Nicht-UTF-8-Statusline-Skripte werden ohne Fremddatei-Bestätigung überschrieben |
| LR-SH-012 | P2 | — | S | mittel | geplant · unverifiziert | Agent-Chats und Codex erben nur den PATH der Login-Shell, keine Proxy- und Zertifikats-Variablen |
| LR-AK-017 | P3 | — | M | mittel | geplant · teilbestätigt | [A3-01] Theme-Synchronisierung überschreibt konkurrierende Nutzereinstellungen |
| LR-AU-034 | P3 | — | S | niedrig | geplant · unverifiziert | Warnsymbol für gelöschtes Transcript nur per Tooltip erklärt |
| LR-KO-003 | P3 | — | S | niedrig | geplant · teilbestätigt | Usage-Ping löscht fremde Projektverläufe allein aufgrund eines Namenssuffixes |
| LR-ONB-014 | P3 | — | S | niedrig | geplant · bestätigt | Die Modellauswahl im Onboarding ist nicht per Tastatur bedienbar |
| LR-PJ-002 | P3 | — | S | mittel | geplant · bestätigt | Die Umgebungssäuberung entfernt fremde Plugin-Verzeichnisse vor deren angeblichem Erhalt |
| LR-SH-016 | P3 | — | S | niedrig | geplant · unverifiziert | Installierbare Statusline braucht jq, das macOS 14 nicht mitbringt; weder Cask noch Einstellungen prüfen das |

### LR-AU-022 · Fehlende Claude/Codex-CLI beim Chatstart: nur englischer Mini-Balken, kein Weg weiter, Leer-Chats sammeln sich an

*P1 · Launch-Blocker · agent-ui / ux · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:36`, `WhisperM8/Views/AgentSessionDetailView.swift:66-86`, `WhisperM8/Views/AgentSessionDetailView.swift:514-518`, `WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift:98` (Stand `76256ad`)

**Fehlerbild:** Laie ohne installierte Claude-CLI öffnet ein Projekt und klickt Neuer Chat. createSession legt die Session mit shouldLaunchOnOpen an, der Launch wirft commandNotFound. Sichtbar wird nur der 12-pt-Balken claude CLI is not installed. (Englisch, kein Link, keine Installationsanleitung, kein Login-Hinweis). Darunter steht der Leerzustand Klick Resume oben, obwohl Resume ohne CLI nicht funktionieren kann. Wer erneut Neuer Chat klickt, erzeugt jedes Mal einen weiteren persistierten Claude Chat. Der Balken verschwindet beim Tab-Wechsel. Verletzt W4 (App erkennt fehlende CLI und führt durch Installation und Login).

**Fix:** Vor dem Anlegen der Session (und im Fehlerpfad) die CLI per commandPath prüfen. Statt des Balkens einen Leerzustand im Detailbereich zeigen: lokalisiert, Titel Claude Code ist noch nicht installiert, offizieller Installationsweg (E5: geführte Installation mit Rückfrage), Button Erneut prüfen, Login-Hinweis. Keine Session anlegen, solange die CLI fehlt. Den Resume-Text im Leerzustand an den Fehlerzustand koppeln.

**Test zuerst:** AgentCommandBuilder/Launcher-Test mit commandResolver → nil: es wird keine Session angelegt und ein Fehlerzustand „CLI fehlt“ geliefert; Snapshot-Fixture für den Leerzustand (en + de).

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-DIK-015 · Fehlende Codex-CLI führt nur zu einer Hilfeseite statt Installation

*P1 · Launch-Blocker · diktat / ux · Aufwand L · Risiko mittel*

**Beleg:** `WhisperM8/Views/Settings/Pages/AIOutputAccountTab.swift:32-49`, `WhisperM8/Services/Dictation/CodexSupport.swift:191-204`, `WhisperM8/Services/Dictation/CodexPostProcessor.swift:25-29` (Stand `a8e0f35`)

**Fehlerbild:** Auf einem frischen Mac fehlt Codex. Die Account-Seite zeigt „Not installed“, bietet aber „Sign In“ an. Die Aktion öffnet lediglich eine externe Hilfeseite; der vorhandene Login-Skriptpfad setzt eine bereits installierte CLI voraus. Ein E-Mail-Lauf scheitert an der Bereitschaftsprüfung und fällt auf Raw zurück, statt W3 ohne Terminal-Nacharbeit zu ermöglichen.

**Fix:** Installation per offiziellem Installer nur nach ausdrücklicher Bestätigung (nie stillschweigend, kein curl/sh ohne Prüfsumme), danach Version/Login/Testlauf prüfen. Mit LR-ONB-002 zusammenlegen, damit es nicht zwei Setup-Wege gibt.

*Ursprünglicher Vorschlag:* Den Zustand notInstalled mit einem eigenen geführten Installationsschritt über einen offiziellen Installer behandeln, ausdrücklich bestätigt durch den Nutzer; danach Version, Login und Testlauf prüfen. Die echten CLIs bleiben Laufzeitbasis. Mit A5 für Onboarding und gemeinsame Setup-UX abstimmen.

**Test zuerst:** CodexStatusProbeTests: commandResolver liefert nil, Status == .notInstalled; erwartet: die UI-Aktion für diesen Zustand ist ein Installationsangebot (neue Aktion/Enum), nicht openLoginInTerminal/Hilfe-URL. Heute öffnet notInstalled genau die Hilfe-URL (NSWorkspace-Spy).

**Zusammengeführt mit:** LR-ONB-002

<details><summary>Prüfurteil</summary>

Bei fehlender Codex-CLI liefert CodexStatusProbe .notInstalled (CodexSupport.swift:173); die Settings-Seite bietet weiterhin 'Sign In' an, und openLoginInTerminal öffnet dann nur eine OpenAI-Hilfeseite (CodexSupport.swift:191-194). Der E-Mail-Lauf scheitert an der Bereitschaftsprüfung (CodexPostProcessor.swift:25-29) und fällt auf Raw zurück. Nutzerweg W3 verlangt ausdrücklich 'führt durch Installation und Login', ohne Terminal-Nacharbeit; das ist hier nicht erfüllt. Das Feature-Inventar vermerkt den Ausbau selbst als nötig. Kein Fehlerfall im Code, sondern eine fehlende Funktion, die eine Definition-of-Done-Zeile verletzt, daher P1/Blocker.

</details>

### LR-DIK-024 · Diktiersprache ist fest auf Deutsch voreingestellt, das Onboarding fragt sie nicht ab

*P1 · Launch-Blocker · diktat / ux · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Support/AppPreferences.swift:36-38`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:39`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:180-189`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:39-47` (Stand `a8e0f35`)

**Fehlerbild:** Ein englisch-, französisch- oder spanischsprachiger Nutzer installiert die App (E1 c: Englisch ist Basissprache) und macht im Onboarding das Testdiktat. AppPreferences.language fällt ohne gespeicherten Wert auf "de" zurück, und dieser Wert geht als language-Feld an OpenAI/Groq. Whisper erzwingt dann deutsche Ausgabe; englische Sprache kommt übersetzt oder phonetisch verstümmelt heraus. Auch die Nachbearbeitungs-Vorlagen bekommen Language: de. In den Einstellungen stehen nur de, en und Auto zur Wahl, für andere Sprachen bleibt nur Auto. W2 liefert für Nicht-Deutschsprachige damit falschen Text, ohne dass der Nutzer erkennt, warum.

**Fix:** Default aus Locale.preferredLanguages ableiten (unterstützte Sprache, sonst Auto) und im Onboarding vor dem Testdiktat einen Sprachschritt zeigen. Die Optionen auf die von Whisper unterstützten Sprachen erweitern. Gespeicherte Werte bestehender Nutzer nicht verändern.

**Test zuerst:** PreferencesTests: ohne gespeicherten Wert liefert language bei Locale en-US „en“, bei fr-FR „fr“ bzw. Auto, bei de-DE „de“; gespeicherter Wert bleibt unverändert. Snapshot-Fixture für den neuen Sprachschritt im Onboarding.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-ONB-003 · Das Full-Onboarding besitzt keinen Claude-Installations- oder Login-Schritt

*P1 · Launch-Blocker · onboarding / ux · Aufwand L · Risiko mittel*

**Beleg:** `WhisperM8/Views/OnboardingView.swift:9-16,38-44 — Schritte umfassen nur Diktat-Setup und optional Codex, niemals Claude.`, `WhisperM8/Views/OnboardingView.swift:134-140 — Full-Abschluss öffnet unmittelbar Agent Chats.`, `WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:76-128 — Workspace-Setup bietet Projekt und Provider, aber keine CLI-Einrichtung.`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:481-484 — alternativer Konten-Login endet bei fehlendem Binary mit install Claude Code first.` (Stand `a8e0f35`)

**Fehlerbild:** Ein Nutzer wählt auf einem frischen Mac Full, um seinen ersten Claude-Chat zu starten. Nach dem Wizard ist Claude weiterhin weder installiert noch angemeldet. Selbst der alternative Konten-Login verweist nur auf eine externe Installation. W4 bleibt ohne Terminal-/Dokumentationsnacharbeit unerfüllbar.

**Fix:** Der Fix des Finders ist grundsätzlich passend. Er muss aber den offiziellen Installer mit Rückfrage nutzen (E5 b), die echte CLI im PTY hosten und Diktat-only-Profile unberührt lassen. Der Aufwand ist L, und der Punkt ist eher ein Feature-Ausbau als ein Bug.

*Ursprünglicher Vorschlag:* Im Full-Pfad den gewünschten Agent-Anbieter abfragen, dessen Installation erkennen und nach Zustimmung über den offiziellen Installer durchführen. Offiziellen Login und Projektwahl geführt anschließen; einen erfolgreichen Start nachweisen. Diktat-only darf dabei keine Agent-Abhängigkeit erhalten; echte CLI im PTY und bestehende Profilzuordnungen bleiben erhalten.

**Test zuerst:** Die Schrittableitung aus OnboardingView in eine pure Funktion extrahieren (Profil, CLI-Verfügbarkeit per Closure) und per XCTest prüfen. Eingabe: Profil .full, commandResolver { _ in nil }. Erwartet: Die Schrittliste enthält einen CLI-Installations- und Login-Schritt. Das schlägt heute fehl. Für .dictationRaw darf er nicht erscheinen.

<details><summary>Prüfurteil</summary>

Die Schrittfolge in OnboardingView (welcome, profile, permissions, hotkey, apiKey, optional codex, test) enthält keinen Claude-Schritt. Im ganzen WhisperM8-Verzeichnis gibt es keine Installationsführung. Es existieren nur die nackten Meldungen 'Claude/Codex CLI is not installed.' (AgentCommandBuilder:35) und 'install Claude Code first' (Konten-Tab). Das ist keine Fehlfunktion, sondern eine Lücke, die W4 und Entscheidung E5 ausdrücklich verlangen ('führt durch Installation und Login'). Damit ist ein Nutzerweg der Launch-Definition für die Zielgruppe ohne Entwickler-Hintergrund verletzt. P1 passt, weil der Nutzer ohne Terminalwissen nicht weiterkommt, aber nichts abstürzt oder verloren geht.

</details>

### LR-ONB-004 · Mikrofon-Ablehnung erzeugt im Wizard eine Sackgasse

*P1 · Launch-Blocker · onboarding / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/OnboardingView.swift:150-154 — Next bleibt ohne Mikrofonrecht gesperrt.`, `WhisperM8/Views/OnboardingView.swift:436-452,498-506 — alle nicht autorisierten Zustände erhalten denselben Grant-Button; dieser ruft ausschließlich requestAccess auf.`, `WhisperM8/Views/Settings/Models/PermissionSettingsModel.swift:104-114,149-159 — die Settings unterscheiden bereits denied/restricted und öffnen die Systemeinstellungen.` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer lehnt den ersten Mikrofon-Dialog versehentlich ab. Ein erneutes Grant fordert bei denied nicht nochmals interaktiv an; Next bleibt deaktiviert. Im Wizard gibt es weder Open Settings noch eine Erklärung zur manuellen Reparatur. W2 scheitert an einem gewöhnlichen Fehlerpfad.

**Fix:** Den bestehenden PermissionSettingsModel-Vertrag auch im Wizard verwenden: notDetermined anfragen, denied gezielt zu den Mikrofon-Einstellungen führen, restricted verständlich erklären. Rückkehr automatisch erkennen und konkrete nächste Schritte anzeigen. Keine wiederholten wirkungslosen Anfragen.

**Test zuerst:** Die Aktion des Wizards in eine testbare Entscheidungsfunktion extrahieren oder PermissionSettingsModel wiederverwenden. Eingabe: microphoneStatusProvider = .denied. Erwartet: performMicrophonePrimaryAction ruft openMicrophoneSettings auf und nicht requestMicrophonePermission. Heute ruft der Wizard-Pfad immer requestAccess auf, ohne Settings-Link.

<details><summary>Prüfurteil</summary>

Bei denied oder restricted ruft der Grant-Button nur AVCaptureDevice.requestAccess auf (OnboardingView:466-470). Das zeigt bei denied keinen Dialog mehr und gibt sofort false zurück. canProceed bleibt an micGranted gekoppelt, und es gibt weder 'Open Settings' noch einen Hinweistext. Die Settings-Seite löst genau diesen Fall bereits sauber (PermissionSettingsModel:104-159), im Wizard wurde das nicht übernommen. Ein versehentliches 'Don't Allow' ist ein gewöhnlicher Fehlerpfad in W2. Beim nächsten Start öffnet sich der Wizard wieder, weil needsOnboarding am Mikrofon hängt. Der Nutzer dreht sich im Kreis, bis er Systemeinstellungen oder die Settings-Seite über die Menüleiste selbst findet.

</details>

### LR-SH-007 · Die Login-Shell-Abfrage kann den ersten Chatstart dauerhaft auf dem Hauptthread blockieren

*P2 · Launch-Blocker · shared / performance · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:59-79`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:174-193`, `WhisperM8/WhisperM8App.swift:308-317`, `WhisperM8/Views/AgentTerminalView.swift:870-879` (Stand `a8e0f35`)

**Fehlerbild:** Die Login-Konfiguration wartet auf einen nicht verfügbaren Dienst oder schreibt mehr Diagnoseausgabe als in den ungelesenen stdout-/stderr-Puffer passt. queryLoginShellPath() wartet ohne Timeout auf Prozessende und liest stdout erst danach; stderr wird nie geleert. Startet ein Chat vor Abschluss des Hintergrund-Prewarms, findet path keinen Cache und führt denselben blockierenden Loader selbst aus. Der Hauptthread kann dadurch unbegrenzt stehen; die Vorwärmung verhindert diesen Pfad nicht.

**Fix:** Timeout (z. B. 5 s) + stdin=/dev/null + stderr nach /dev/null genügt; Main-Thread-Wait zusätzlich vermeiden. Kein größerer Umbau.

*Ursprünglicher Vorschlag:* Shellabfrage mit Deadline, SIGTERM/SIGKILL-Kaskade, geschlossenem stdin und parallel geleerten, begrenzten Ausgaben ausführen. Den Hauptthread niemals auf die Auflösung warten lassen: dort sofort einen brauchbaren Cache/Fallback verwenden oder den Launch asynchron vorbereiten. Gleichzeitige Erstabfragen zusammenfassen. Tests für hängende Shell, volle Ausgabepuffer und Chatstart während des Prewarms ergänzen.

**Test zuerst:** LoginShellEnvironmentTests: queryLoginShellPath mit injizierbarem Executable/Argumenten (z. B. /bin/sh -c 'sleep 30') und Deadline-Parameter; erwartet nil nach <= Deadline statt Blockade. Zweiter Test: zwei parallele path-Aufrufe starten den Loader nur einmal (Zähler im pathLoader).

<details><summary>Prüfurteil</summary>

Code stimmt: queryLoginShellPath() wartet ohne Timeout per waitUntilExit, stderr-Pipe wird nie geleert, und path (Z. 59-80) hält den Lock nicht während des Ladens, sodass ein Chatstart vor Prewarm-Ende den Loader selbst auf dem Main Thread ausführt (AgentTerminalView.start). Allerdings ist ein Hänger nur bei pathologischen Login-Dotfiles plausibel (blockierendes Netzwerk in .zprofile); die stdout-Ausgabe ist nur der PATH, ein 64-KB-Pufferüberlauf durch Diagnoseausgabe bei `zsh -l -c` (sourct .zshrc nicht) ist praktisch unrealistisch. Typischer Fall (langsame .zprofile) kostet Sekunden, nicht unendlich. Die Prewarm-Absicherung für den Normalfall ist dokumentiert und greift. Echte Härtungslücke, aber kein Standardpfad der Zielgruppe.

</details>

### LR-AU-004 · „Neuer Chat“ startet bei nur auto-importierten Projekten in einem unsichtbaren Projekt, während die Sidebar „Noch keine Projekte“ zeigt

*P2 · agent-ui / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:427-429 (selectedProject fällt auf workspace.projects.first zurück, ohne isManuallyAdded zu prüfen)`, `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:162-168 (Sidebar und hasManualProjects zählen nur isManuallyAdded)`, `WhisperM8/Views/AgentChatsView.swift:1513-1514 (sidebarEmptyState bei !hasManualProjects)`, `WhisperM8/Views/AgentChatsView.swift:2135-2137 (Neuer-Chat-Button nur bei selectedProject == nil deaktiviert; Hinweis „Erst ein Projekt hinzufügen“ steht nur im Hover-Tooltip)` (Stand `76256ad`)

**Fehlerbild:** Nutzer hat die Claude-CLI schon im Terminal benutzt und installiert WhisperM8. Der Indexer importiert ~/.claude/projects als Projekte ohne createdManually, zum Beispiel $HOME oder ein altes Repo. Die Sidebar zeigt „Noch keine Projekte – Füge ein Projekt hinzu“, der Button „Neuer Chat“ ist aber aktiv und trägt den Namen eines unsichtbaren Projekts. Ein Klick startet Claude in diesem zufälligen Verzeichnis (erste Trust-Abfrage dort), und der Chat erscheint in der gruppierten Sidebar unter keinem Projekt. Das ist eine Sackgasse in W4 (erster Agent-Chat).

**Fix:** selectedProject und die Aktivierung des Neuer-Chat-Buttons auf manuell hinzugefügte Projekte beschränken, also manualProjects statt workspace.projects als Fallback. Ohne manuelles Projekt den Button zum „Projekt hinzufügen…“-Pfad machen, mit sichtbarem Text statt Tooltip. reconcileSelection analog anpassen (selectedProjectID und prefix(3) der expandedProjectIDs).

**Test zuerst:** Unit-Test auf einen puren selectedProject-Resolver: Workspace mit nur createdManually == nil Projekten ergibt nil. UISnapshot-Fixture „nur importierte Projekte“.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AU-029 · Leerzustände ohne Anleitung; Markdown-Sternchen und widersprüchliche Begriffe

*P2 · agent-ui / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsView.swift:2511-2513`, `WhisperM8/Views/Transcript/TranscriptEmptyStateView.swift:82-98`, `WhisperM8/Views/AgentChatsView.swift:3270-3274` (Stand `76256ad`)

**Fehlerbild:** Nach dem Schließen des letzten Tabs bei vorhandenem Projekt zeigt der Hauptbereich nur Kein Agent Chat mit Terminal-Icon, ohne Beschreibung oder Aktion. Der Leerzustand einer neuen, nie gestarteten Session sagt Klick **Resume** oben, der Button heißt aber Start. Weil Text mit einer String-Property kein Markdown rendert, erscheinen die Sternchen wörtlich. Zusätzlich steht dort eine rohe Session-ID, und enthaelt ist mit Umlaut-Ersatz geschrieben. Das Fragezeichen-Symbol in der Sidebar öffnet nur das Onboarding, keine Hilfe.

**Fix:** ContentUnavailableView mit Beschreibung und Button Neuer Chat ausstatten. Die Leerzustandstexte je nach Button-Label bilden und als LocalizedStringKey bzw. AttributedString rendern. Die Session-ID hinter ein Detail legen.

**Test zuerst:** Snapshot-Fixtures für die Leerzustände (kein Projekt, keine Chats) mit Button „Neuer Chat“; kein rohes `**` im gerenderten Text.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-ONB-005 · Nach Rechtevergabe kann ein unvollständiges Setup dauerhaft verschwinden

*P2 · onboarding / korrektheit · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/WhisperM8App.swift:204-207,385-395 — automatisches Onboarding hängt ausschließlich an Mikrofon und Accessibility.`, `WhisperM8/Views/OnboardingView.swift:38-44 — Hotkey und API-Key kommen erst nach dem Rechteschritt.`, `WhisperM8/Views/MenuBarView.swift:63-70,108-119 — bei fehlendem Hotkey nur Statushinweis; kein Wizard-Neustart.`, `WhisperM8/Views/SettingsView.swift:243-279 — Settings enthalten keinen Onboarding-Einstieg.` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer erteilt beide Rechte und schließt anschließend das Setup vor Hotkey/API-Key, etwa um einen Key zu besorgen. Nach App-Neustart ist needsOnboarding false. Er landet ohne funktionsfähiges Diktat im normalen App-Zustand und muss die fehlenden Schritte über mehrere Settings-Seiten selbst zusammensuchen. Der dokumentierte Guard gegen unnötige Wizard-Wiederholungen verfehlt hier W2.

**Fix:** Eine Rückkehr zum alleinigen onboardingCompleted-Flag wäre falsch (dokumentierter Vorfall). Ein Hinweisband oder Menüeintrag 'Setup fortsetzen' reicht. Den Wizard nicht erneut erzwingen.

*Ursprünglicher Vorschlag:* Nicht zum alten alleinigen onboardingCompleted-Flag zurückkehren. Stattdessen tatsächliche Betriebsbereitschaft pro Profil prüfen, fehlende Pflichtschritte gezielt fortsetzen und einen sichtbaren Setup-fortsetzen-Einstieg anbieten. Vollständig konfigurierte Bestandsinstallationen dürfen weiterhin nicht erneut durch den Wizard gezwungen werden.

**Test zuerst:** Eine pure Funktion setupIncompleteReason(micGranted:, axGranted:, hotkeySet:, hasKey:) mit Tests einführen. Eingabe: beide Rechte erteilt, hotkeySet == false. Erwartet: ein 'Setup fortsetzen'-Hinweis wird angezeigt. Ein vollständig konfigurierter Bestandsnutzer bekommt keinen. Heute fehlt dieser Zustand komplett.

<details><summary>Prüfurteil</summary>

Das Verhalten stimmt: needsOnboarding prüft nur Mikrofon und Accessibility (WhisperM8App:204-208). Wer den Wizard nach dem Rechteschritt schließt, bekommt beim nächsten Start keinen Wizard mehr. Es ist aber eine bewusst dokumentierte Designentscheidung, wie der Kommentar dort und CLAUDE.md zeigen, und kein Absturz oder Datenverlust. Die App landet im normalen Zustand: Das Menü zeigt 'No hotkey configured', fehlender Key erzeugt ein TranscriptionError.missingAPIKey, und Recording sowie Transcription in den Settings sind direkt erreichbar. Für Voll-Profil-Nutzer gibt es zusätzlich den Sidebar-Button 'Onboarding / Hilfe öffnen'. Schlecht ist nur, dass Diktat-only-Profile keinen Wiedereinstieg haben. Das ist ein UX-Defizit mit Workaround.

</details>

### LR-ONB-006 · Schon ein versehentlich getipptes Zeichen ersetzt den funktionierenden API-Key

*P2 · onboarding / datenintegritaet · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Views/OnboardingView.swift:635-640 — jeder nicht leere Zwischenstand wird sofort gespeichert; Leeren stellt nichts wieder her.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:107-113 — identisches Verhalten in Settings.`, `WhisperM8/Services/Shared/KeychainManager.swift:23-31 — SecItemUpdate ersetzt den bestehenden Wert.`, `WhisperM8/Views/TranscriptionAccountControls.swift:49-51 — das Eingabefeld enthält bewusst nicht den bisherigen Key.` (Stand `a8e0f35`)

**Fehlerbild:** Ein gültiger Key ist gespeichert. Der Nutzer klickt in das maskierte Feld, tippt versehentlich x und löscht es wieder. Bereits x hat den gültigen Key ersetzt; das anschließende leere Feld löst keinen Rollback aus. Die nächste Transkription schlägt fehl, und der zuvor funktionierende Zugang ist nicht mehr aus der App wiederherstellbar.

**Fix:** Getippten Key ausschließlich als Entwurf halten. Erst bei explizitem Save/Replace und erfolgreicher Validierung speichern; Abbrechen oder Leeren muss den bisherigen Key unverändert lassen. Maskierung und das Nicht-Zurückladen des bestehenden Secrets in die UI beibehalten. Regressionstest für Tippen→Leeren ergänzen.

**Test zuerst:** Das Key-Entwurf-Verhalten in ein kleines Modell mit injiziertem Speicher-Closure ziehen. Ablauf: gespeicherter Key 'good', Eingabe 'x', dann Eingabe ''. Erwartet: save wurde nie aufgerufen, und der Key bleibt 'good'. Heute wird bei 'x' sofort überschrieben.

<details><summary>Prüfurteil</summary>

Der Code stimmt: onChange speichert jeden nicht leeren Zwischenstand sofort per KeychainManager.save (OnboardingView:635-640, TranscriptionSettingsPage:107-113), und Leeren stellt nichts wieder her. Das Szenario setzt aber voraus, dass ein Nutzer mit funktionierendem Key in das Feld klickt und ein Zeichen tippt. Das Feld zeigt nur Punkte als Platzhalter, und der übliche Weg ist Einfügen eines neuen Keys. Der alte Key ist beim Anbieter (Groq/OpenAI) weiter gültig und neu abrufbar, es geht also kein unersetzlicher Zugang verloren. Im Onboarding existiert noch kein Key. Das ist ein echter Designmangel, aber unwahrscheinlich und kein Datenverlust im engeren Sinn.

</details>

### LR-ONB-007 · Fehlgeschlagene Keychain-Writes werden im Setup als vorhandener Zugang behandelt

*P2 · onboarding / robustheit · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/KeychainManager.swift:10-34 — save liefert Void; Fehler erscheinen ausschließlich im Log.`, `WhisperM8/Views/OnboardingView.swift:639-640 — apiKeyAvailable wird unabhängig vom Speicherausgang true.`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:111-119 — gleicher falscher Erfolgszustand mit Saved-Key-Anzeige.`, `WhisperM8/Views/OnboardingView.swift:156-176 — Zugangsgates vertrauen dem lokalen Zustand.` (Stand `a8e0f35`)

**Fehlerbild:** Der Schlüsselbund ist gesperrt oder verweigert den Schreibzugriff. Ein eingegebener Key wird nicht gespeichert, das Onboarding lässt den Nutzer dennoch weiter und abschließen. Nach Leeren des Feldes kann sogar Saved Key erscheinen, obwohl kein neuer Key existiert. Der Diktatpfad lädt danach nil oder den alten ungültigen Wert; für den Nutzer fehlt eine verständliche Reparaturaktion.

**Fix:** Keychain-Schreiboperation als Result/throwing Vertrag anbieten und Erfolg erst nach bestätigtem Write beziehungsweise Readback übernehmen. Bei Fehler Entwurf erhalten, verständlichen Hinweis und Retry anbieten; vorhandenen Key nicht zerstören. Zugangsprüfung und UI müssen denselben bestätigten Speicherzustand verwenden.

**Test zuerst:** KeychainManager.save um eine throwing- oder Result-Variante mit injizierbarem SecItem-Backend ergänzen. Test: Backend liefert errSecAuthFailed. Erwartet: Die Aufrufer setzen apiKeyAvailable nicht auf true und zeigen einen Fehler. Heute ist das nicht abbildbar, weil save Void zurückgibt.

<details><summary>Prüfurteil</summary>

KeychainManager.save gibt Void zurück und loggt Fehler nur (KeychainManager:10-34). Die UI setzt apiKeyAvailable = true unabhängig davon, ob der Write gelang. Der Code-Befund ist korrekt. Ein fehlschlagender SecItemUpdate/SecItemAdd bei einem normalen Login-Keychain-Zugriff ist aber ungewöhnlich (gesperrter Schlüsselbund, verweigerter ACL-Prompt nach Re-Signierung). Beim Diktat tritt kein stiller Fehler auf: Der Coordinator lädt den Key, bekommt nil und wirft TranscriptionError.missingAPIKey mit einer sichtbaren Meldung. Die Auswirkung ist verwirrend, aber kein Absturz und kein Datenverlust. Der Fall ist als Altlast N06 bekannt.

</details>

### LR-ONB-013 · Ungültiger Key und fehlgeschlagenes Testdiktat verhindern keine Erfolgsmeldung

*P2 · onboarding / korrektheit · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/Models/TranscriptionProvider.swift:122-125 — beliebiger nicht leerer String, auch Leerzeichen, erfüllt das Credential-Gate.`, `WhisperM8/Views/OnboardingView.swift:168-176 — canFinish prüft weder Zugangsgültigkeit noch Testergebnis.`, `WhisperM8/Views/OnboardingView.swift:783-829 — All set ist bedingungslos; Fehler wird lediglich angezeigt, externe Textzustellung nicht geprüft.` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer fügt versehentlich einen falschen oder nur aus Leerzeichen bestehenden Key ein. Er kommt bis All set und kann Done anklicken, selbst nachdem das Testdiktat einen Authentifizierungsfehler gezeigt hat. Auch eine tatsächlich erfolgreiche Transkription beweist hier keine Zustellung in eine fremde App. Der Assistent meldet Erfolg, obwohl W2 nicht erfolgreich durchlaufen wurde.

**Fix:** Eingaben trimmen, einen expliziten Zugangstest mit verständlichem Fehler-/Korrekturweg anbieten und Setup-Status vom erfolgreichen Test abhängig benennen. Testaufnahme und externe Einfügeprüfung getrennt führen. Falls Überspringen erlaubt bleibt, eindeutig als ungetestetes Setup kennzeichnen statt All set.

**Test zuerst:** TranscriptionCredentialGate.isSatisfied(provider: .groq, typedKey: "   ", hasSavedKey: false) muss false liefern; heute true. Zusätzlich ein purer OnboardingFinishGate(lastTestError: "401 …") → canFinish bzw. Erfolgsanzeige false.

### LR-ONB-017 · Das Codex-Login-Skript quotiert den aufgelösten Binary-Pfad nicht

*P2 · onboarding / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Dictation/CodexSupport.swift:191-205`, `WhisperM8/Services/Dictation/CodexSupport.swift:223-230`, `WhisperM8/Views/OnboardingView.swift:335-337` (Stand `a8e0f35`)

**Fehlerbild:** Codex ist ausführbar unter einem gültigen PATH-Verzeichnis mit Leerzeichen installiert, beispielsweise /Volumes/Tools Suite/bin/codex. Die Auflösung findet den vollständigen Pfad, das erzeugte .command-Skript enthält ihn jedoch unquotiert vor login. Die Shell versucht /Volumes/Tools auszuführen statt Codex. Der angebotene Anmeldeweg funktioniert nicht und der Nutzer kann W3 darüber nicht abschließen.

**Fix:** Bestehenden shellEscape-Helfer wiederverwenden bzw. Single-Quote-Escaper; die echte CLI im Terminal beibehalten (Finder-Vorschlag ist korrekt).

*Ursprünglicher Vorschlag:* Binary-Pfad über einen zentralen Shell-Literal-Escaper einfügen, der Leerzeichen, Apostrophe und Metazeichen korrekt behandelt. Die echte CLI und deren interaktiven Login im Terminal beibehalten. Skriptgenerierung als pure Funktion testen, mindestens mit Leerzeichen und Apostroph im Pfad.

**Test zuerst:** Skriptgenerierung als pure Funktion extrahieren (z. B. CodexStatusProbe.loginScript(codexPath:)) und testen: Pfad '/Volumes/Tools Suite/bin/codex' und "/Users/o'brien/bin/codex" -> Skriptzeile enthält korrekt gequoteten Pfad (z. B. '/Volumes/Tools Suite/bin/codex' login bzw. mit '\'' für Apostroph); heute unquotiert und der Test schlägt fehl.

<details><summary>Prüfurteil</summary>

openLoginInTerminal() interpoliert codexPath unquotiert in das .command-Skript (CodexSupport.swift:~198); ein Pfad mit Leerzeichen oder Metazeichen bricht den Login. Der Fehler ist real und trivial zu beheben. Die Reichweite ist aber klein: Standardorte (/Applications/Codex.app/Contents/Resources/codex, /opt/homebrew/bin, ~/.local/bin, npm-global) enthalten normalerweise keine Leerzeichen; relevant nur bei Home-/Volume-Pfaden mit Leerzeichen. Der Codex-Login ist im Onboarding ausdrücklich optional ('you can skip it'), und AI-Enrichment ist erweitert, nicht Kernpfad W2. W3 scheitert nur für diese seltene Pfadkonstellation, und der Nutzer kann `codex login` manuell im Terminal ausführen.

</details>

### LR-PJ-001 · Die Plugin-Migration räumt fremde, ungestempelte Skills automatisch weg

*P2 · plugin-jarvis / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/CLISkillExporter.swift:314-326`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:309-325`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:363-379`, `WhisperM8/Support/AppPreferences.swift:524-534` (Stand `a8e0f35`)

**Fehlerbild:** Ein neuer Nutzer besitzt bereits einen eigenen ~/.claude/skills/codex-subagent/SKILL.md, der nicht aus WhisperM8 stammt und keinen Install-Stempel hat. installState() liefert unknownDrift. Die standardmäßig aktive Erststart-Migration schützt nur modifiedLocally und Symlink-Verzeichnisse und verschiebt den fremden Skill deshalb ungefragt in den versteckten Backup-Ordner. Der eigene Slash-Befehl fehlt danach auch in außerhalb der App gestarteten CLIs. Ein Backup verhindert den Funktionsausfall nicht.

**Fix:** Der vorgeschlagene Fix (nur nachweislich eigene Installationen) würde die dokumentierte Migration alter, ungestempelter WhisperM8-Installs und der nie gestempelten jarvis-Kopie brechen. Besser: unknownDrift nur verschieben, wenn Inhalt einen WhisperM8-Marker trägt oder dem gebündelten Stand entspricht.

*Ursprünglicher Vorschlag:* Automatischen Umzug auf nachweislich eigene, unveränderte Installationen beschränken. Unbekannte oder ungestempelte Abweichungen unverändert lassen und bei Bedarf einen ausdrücklich bestätigten Umzug anbieten. Die versionierte Plugin-Ablage, Symlink-Schutz und Sicherung bestätigter Umzüge erhalten. Einen Test mit fremdem, ungestempeltem Nicht-Jarvis-Skill ergänzen.

**Test zuerst:** WhisperM8ClaudePluginTests: Home mit ~/.claude/skills/codex-subagent/SKILL.md fremden Inhalts ohne Stempel; ClaudePluginSkillMigration.run() soll ihn in outcome.kept führen und nicht verschieben (heute: moved). jarvis-Sonderfall dabei beachten, damit alte Jarvis-Kopien weiterhin migriert werden.

<details><summary>Prüfurteil</summary>

Technisch korrekt: Die einmalige Migration verschiebt jeden Plugin-Skill-Ordner in ~/.claude/skills außer Symlinks und .modifiedLocally, auch ungestempelte (unknownDrift). Das ist aber beabsichtigt (Kommentar: ältere WhisperM8-Installs hatten keinen Stempel, jarvis nie) und betrifft nur exakt WhisperM8-eigene Skill-Namen (transcription, codex-subagent, whisperm8-chats, gpt-*, jarvis, callout). Dass ein Neu-Nutzer einen eigenen, gleichnamigen Skill besitzt, ist extrem unwahrscheinlich; verschoben wird in ein Backup, nichts gelöscht, und der Skill steht in App-Sessions als /whisperm8:<name> zur Verfügung. Kein Datenverlust, kein Kern-Nutzerweg betroffen.

</details>

### LR-SH-003 · Fehlgeschlagene Keychain-Migration löscht die einzige persistierte API-Key-Kopie

*P2 · shared / datenintegritaet · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/Shared/KeychainManager.swift:23-34`, `WhisperM8/Services/Shared/KeychainManager.swift:61-66`, `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:107-112`, `WhisperM8/Views/OnboardingView.swift:635-640` (Stand `a8e0f35`)

**Fehlerbild:** Nach einem Update liegt der API-Key nur in UserDefaults. Der Schlüsselbund ist gesperrt oder verweigert den Schreibzugriff. load() ruft save() auf; dieses protokolliert den Fehler lediglich. Trotzdem wird der UserDefaults-Wert gelöscht. Der aktuelle Aufruf liefert den Key noch zurück, spätere Aufrufe finden keine persistierte Kopie mehr. Derselbe fehlende Erfolgsvertrag lässt Onboarding und Einstellungen nach erfolglosem Speichern apiKeyAvailable=true anzeigen.

**Fix:** Kleiner Fix reicht: save() gibt Bool zurück, Legacy-Wert nur bei true entfernen. Kein Journal/Readback-Aufwand nötig.

*Ursprünglicher Vorschlag:* Speichern als throwing/Result-Vertrag mit injizierbaren Security-Aufrufen ausführen. Legacy-Wert erst nach bestätigtem Schreiben und geeignetem Readback entfernen; bei Fehler erhalten und eine verständliche Wiederholungsmöglichkeit anzeigen. Cache und UI dürfen nur bestätigten Zustand übernehmen. Regressionstests für gesperrten Schlüsselbund, verweigerten Zugriff und erfolgreiche Wiederholung ergänzen.

**Test zuerst:** KeychainManager mit injizierbaren SecItem-Closures (oder kleinem Protokoll) testbar machen; Test: UserDefaults enthält Legacy-Key, SecItemUpdate/Add liefern errSecInteractionNotAllowed -> nach load() muss UserDefaults-Wert weiterhin vorhanden sein. Zweiter Test: save-Fehler darf apiKeyAvailable nicht auf true setzen (save als Bool/throws).

**Zusammengeführt mit:** LR-SH-009

<details><summary>Prüfurteil</summary>

Der Code-Pfad stimmt: KeychainManager.load() ruft save() auf, save() loggt bei Fehlschlag nur, danach wird der UserDefaults-Wert trotzdem entfernt (Z. 61-66). Auslöser ist aber eng: der Key muss noch als Legacy-Wert in UserDefaults liegen (nur Nutzer sehr alter Versionen, nicht die Launch-Zielgruppe) UND der Keychain-Schreibzugriff muss gleichzeitig scheitern (selten). Verloren geht ein neu eingebbarer API-Key, kein Nutzerinhalt. Das Onboarding/Settings-Teil (apiKeyAvailable=true nach fehlgeschlagenem save) ist real, aber nur UI-Schönheit bei ohnehin seltenem Keychain-Fehler. P0 ist klar überhöht.

</details>

### LR-SH-004 · Nicht-UTF-8-Statusline-Skripte werden ohne Fremddatei-Bestätigung überschrieben

*P2 · shared / datenintegritaet · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/Shared/StatuslineInstaller.swift:167-172`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:215-220`, `WhisperM8/Services/Shared/StatuslineInstaller.swift:266-278`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:553-562` (Stand `a8e0f35`)

**Fehlerbild:** Unter ~/.claude/statusline-command.sh liegt ein eigenes, ausführbares Shellskript mit einem Latin-1-kodierten Umlaut im Kommentar. String(contentsOf:encoding:.utf8) scheitert. status() und foreignScriptURL() behandeln dies nicht als vorhandene Fremddatei. Der normale Install-Klick überschreibt das Skript atomar, ohne die vorgesehene Fremddatei-Bestätigung und ohne Backup. Der ursprüngliche Dateiinhalt geht verloren.

**Fix:** Fix ist klein: Existenz (fileExists) getrennt von Dekodierbarkeit prüfen; nicht dekodierbar = foreign. Kein Backup-System nötig.

*Ursprünglicher Vorschlag:* Existenz, Lesbarkeit, Dekodierbarkeit und Ownership getrennt prüfen. Eine vorhandene, nicht lesbare oder nicht dekodierbare Datei muss Installation und Update ohne ausdrückliche Konfliktbehandlung stoppen. Vor bestätigtem Ersetzen bytegenau sichern; Tests mit nicht-UTF-8-Dateien und Lesefehlern ergänzen.

**Test zuerst:** StatuslineInstallerTests: Temp-Home, ~/.claude/statusline-command.sh mit Bytes 0xE4 (Latin-1 ä) schreiben; install() ohne replaceForeignScript muss InstallError.foreignScript werfen und die Datei bytegleich lassen; status() muss .foreign liefern. Heute: status()==.missing, Datei überschrieben.

<details><summary>Prüfurteil</summary>

Mechanik stimmt: status()/foreignScriptURL() nutzen try? String(contentsOf:.utf8); ein nicht-UTF-8-Skript ergibt nil, wird als .missing behandelt und install() überschreibt ohne Fremddatei-Bestätigung. Der Auslöser ist jedoch sehr schmal: Es muss ein eigenes Skript genau unter ~/.claude/statusline-command.sh bzw. dem Subagent-Pendant liegen, in einer Nicht-UTF-8-Kodierung, und der Nutzer muss in Einstellungen (CLISkillsSettingsPage, einziger Aufrufer, kein Auto-Install) bewusst auf Install klicken. UTF-8-Fremdskripte werden korrekt abgefangen (Marker-Prüfung + Bestätigungsdialog). Datenverlust einer Nutzerdatei ist real, aber extrem selten; kein P0.

</details>

### LR-SH-012 · Agent-Chats und Codex erben nur den PATH der Login-Shell, keine Proxy- und Zertifikats-Variablen

*P2 · shared / robustheit · Aufwand S · Risiko mittel*

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:129`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:174-193`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:465` (Stand `a8e0f35`)

**Fehlerbild:** In einer Firmenumgebung mit Pflicht-Proxy oder TLS-Inspektion setzt der Nutzer bzw. die IT HTTPS_PROXY, NO_PROXY, NODE_EXTRA_CA_CERTS oder SSL_CERT_FILE in ~/.zprofile/~/.zshrc. Im Terminal funktionieren claude und codex. WhisperM8 fragt aus der Login-Shell nur echo $PATH ab und startet claude/codex direkt (nicht über eine Shell) mit der launchd-Umgebung der GUI-App. Die Proxy- und CA-Variablen fehlen, die CLIs ignorieren die macOS-Systemproxy-Einstellung. Ergebnis: Chats und Codex-Nachbearbeitung brechen mit Verbindungs- oder Zertifikatsfehlern ab, obwohl dieselbe CLI im Terminal läuft. Dasselbe gilt für ANTHROPIC_API_KEY/OPENAI_API_KEY-Nutzer ohne Abo-Login.

**Fix:** Aus der Login-Shell zusätzlich eine kleine Positivliste übernehmen (HTTPS_PROXY/HTTP_PROXY/ALL_PROXY/NO_PROXY in beiden Schreibweisen, NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, REQUESTS_CA_BUNDLE), z. B. per env -0 statt echo $PATH. Keine Secrets übernehmen. Diagnose-Hinweis bei Verbindungsfehlern.

**Test zuerst:** LoginShellEnvironmentTests: Shell-Fake liefert `env -0` mit HTTPS_PROXY, NODE_EXTRA_CA_CERTS und einem Secret; Ergebnis enthält die Positivliste, aber nicht das Secret.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AK-017 · [A3-01] Theme-Synchronisierung überschreibt konkurrierende Nutzereinstellungen

*P3 · agent-kern / datenintegritaet · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-119`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:132-153`, `WhisperM8/Support/ThemeManager.swift:80-90` (Stand `a8e0f35`)

**Fehlerbild:** Der Theme-Writer liest settings.json. Danach speichert die laufende CLI eine neue Einstellung, etwa eine Permission-Regel. Anschließend ersetzt der Writer die komplette Datei mit seinem älteren Snapshot plus theme. Die neue Nutzereinstellung verschwindet; atomarer Dateiersatz verhindert diesen Lost Update nicht.

**Fix:** Der Vorschlag, das Theme als session-spezifisches Settings-Fragment über --settings zu transportieren, ist sinnvoll, weil er auch Fremdänderungen in ~/.claude vermeidet. Er muss aber prüfen, dass Claude das theme-Feld aus Flag-Settings tatsächlich auswertet. Eine billigere Zwischenlösung ist, direkt vor dem Replace mtime und Größe erneut zu prüfen und bei Abweichung neu zu lesen.

*Ursprünglicher Vorschlag:* Theme möglichst als sessionspezifisches Settings-Fragment transportieren statt die globale Fremddatei umzuschreiben. Native CLI, bestehende Nutzereinstellungen und Terminal-Palettenwechsel erhalten; konkurrierende externe Writes gezielt testen.

**Test zuerst:** ClaudeThemeWriterTests mit tmp-URL: Hook zwischen Read und Replace (Test-Seam) schreibt zusätzlich einen permissions-Key; erwartet, dass nach performWrite beide Keys vorhanden sind. Heute schlägt das fehl, ein Seam existiert aber nicht und müsste ergänzt werden.

**Zusammengeführt mit:** LR-SH-002, LR-SH-005, LR-SH-011

<details><summary>Prüfurteil</summary>

Der Read-Modify-Write auf ~/.claude/settings.json ist real nicht transaktional, aber das Fenster liegt zwischen Data(contentsOf:) und replaceItemAt, also Millisekunden. Es wird nur bei einem Theme-Wechsel (debounced, 0,5 s) oder beim Start geöffnet und auch nur, wenn die CLI exakt in diesem Fenster settings.json schreibt. Parse-Fehler (Mid-Write) werden abgefangen, und es gibt ein Einmal-Backup. Das Risiko ist bekannt und im Dateikopf dokumentiert, Datenverlust ist theoretisch und selten. Ein Launch-Blocker ist es nicht. Das eigentliche Launch-Thema ist eher, dass die App überhaupt in die globale Fremddatei schreibt (W7, keine Fremdänderungen in ~/.claude), nicht dieses Rennen.

</details>

### LR-AU-034 · Warnsymbol für gelöschtes Transcript nur per Tooltip erklärt

*P3 · agent-ui / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/AgentChatsSidebarViews.swift:895-899`, `WhisperM8/Views/AgentChatsSidebarViews.swift:1112-1116` (Stand `76256ad`)

**Fehlerbild:** Chats ohne Transcript zeigen in der Sidebar ein graues Fragezeichen; die Erklärung (Transkript von Claude gelöscht, nicht mehr resumebar) steht nur im Hover-Tooltip. Der Titel wird abgeblendet. Der Laie versteht nicht, was zu tun ist. Ein Klick führt zu dem technischen Fehlerbalken.

**Fix:** Im Detailbereich einen dauerhaften Hinweis mit Aktion Neuen Chat im selben Projekt starten bzw. Chat archivieren zeigen. Das Symbol mit accessibilityLabel versehen.

**Test zuerst:** Snapshot-Fixture: Chat mit gelöschtem Transcript zeigt einen dauerhaften Hinweis mit Aktion; Symbol hat ein accessibilityLabel.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-KO-003 · Usage-Ping löscht fremde Projektverläufe allein aufgrund eines Namenssuffixes

*P3 · konten / datenintegritaet · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:35-43`, `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:119-129`, `WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:166-172`, `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:327-328` (Stand `a8e0f35`)

**Fehlerbild:** Der Nutzer hat reguläre Chats in einem Projekt /Users/x/repos/whisperm8-limit-ping. Dessen encodierter projects-Ordner endet ebenfalls auf -whisperm8-limit-ping. Nach einem manuellen Usage-Update mit abgelaufenem Token löscht cleanupPingArtifacts diesen gesamten Ordner einschließlich aller echten Transcripts und Memory-Dateien ohne Backup. Das funktioniert auch mit genau einem Konto.

**Fix:** Der Fix des Finders ist richtig und billig (genauen encodierten Ping-Ordnernamen aus encodeClaudeCwd(workDirectory.path) berechnen und nur diesen löschen). Das Suffix muss im Indexer-Skip aber bleiben bzw. gleich mit umgestellt werden.

*Ursprünglicher Vorschlag:* Ausschließlich den aus dem tatsächlichen Ping-Arbeitsverzeichnis berechneten Projektpfad und vorzugsweise die konkret erzeugte Session-ID bereinigen; vor rekursiver Löschung Ownership und cwd prüfen. Fremde gleichnamige Projekte müssen unberührt bleiben. Die gewünschte Unterdrückung importierter Ping-Sessions erhalten.

**Test zuerst:** ClaudeAccountLimitPingerTests: Fixture-configDir mit projects/<encode(echter Ping-cwd)> und projects/-Users-x-repos-whisperm8-limit-ping (Dummy-Transcript); cleanupPingArtifacts aufrufen; erwarten, dass der fremde Ordner bestehen bleibt (heute wird er gelöscht).

<details><summary>Prüfurteil</summary>

Der Mechanismus stimmt: isPingProjectsDirectory prüft nur hasSuffix("-whisperm8-limit-ping") und cleanupPingArtifacts löscht jeden Treffer rekursiv ohne Backup. Der Auslöser ist aber praktisch nicht erreichbar: Ein fremdes Projekt müsste mit der Komponente 'whisperm8-limit-ping' enden (oder 'x-whisperm8-limit-ping'). Das ist ein interner Hilfsordnername, und der Indexer überspringt solche Ordner ohnehin (dasselbe Suffix), das Projekt wäre also schon vorher unsichtbar. Das Löschen betrifft außerdem nur das projects-Verzeichnis des gepingten Profils und läuft nur auf einen manuellen Klick. Das Szenario ist eine Härtungslücke, kein realistischer Datenverlust. 'Funktioniert mit einem Konto' stimmt formal, ändert aber nichts an der Seltenheit.

</details>

### LR-ONB-014 · Die Modellauswahl im Onboarding ist nicht per Tastatur bedienbar

*P3 · onboarding / ux · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/OnboardingView.swift:675-699 — Modellzeilen bestehen aus HStack/Text/Images und onTapGesture; keine Button-/Picker-Semantik oder Fokusaktion.`, `WhisperM8/Views/Settings/Kit/SettingsPickerRow.swift:25-34 — ein vorhandener nativer Picker-Baustein besitzt bereits Label-Semantik.` (Stand `a8e0f35`)

**Fehlerbild:** Ein Nutzer mit reiner Tastaturbedienung beziehungsweise VoiceOver möchte im API-Key-Schritt das zweite Modell auswählen. Anders als echte Buttons oder Picker sind die Zeilen keine regulär fokussierbaren Auswahlsteuerelemente; der Auswahlwechsel ist nur als Tap-Geste implementiert. Die sichtbare Auswahlmöglichkeit ist für ihn nicht gleichwertig erreichbar.

**Fix:** Nativen Picker/Radio-Group oder echte Buttons mit zugänglichem Ausgewählt-Zustand verwenden. Dekorative Kreise aus dem Accessibility-Baum entfernen und Modellname/Beschreibung sinnvoll gruppieren. Tastatur- und VoiceOver-Prüfung ergänzen; Defaults und persistierte Modellwahl erhalten.

**Test zuerst:** Kein sinnvoller Unit-Test. UI-Snapshot-Fixture für den API-Key-Schritt plus manuelle VoiceOver-/Tab-Prüfung. Alternativ die Zeile durch Picker(.radioGroup) bzw. Button ersetzen und eine Accessibility-Audit-Checkliste in der QA führen.

### LR-PJ-002 · Die Umgebungssäuberung entfernt fremde Plugin-Verzeichnisse vor deren angeblichem Erhalt

*P3 · plugin-jarvis / korrektheit · Aufwand S · Risiko mittel*

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:106-108`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:236-250`, `WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:385-391`, `WhisperM8/Views/AgentTerminalView.swift:879-885` (Stand `a8e0f35`)

**Fehlerbild:** Die App erbt CLAUDE_CODE_PLUGIN_DIRS mit einem bewusst konfigurierten eigenen Plugin-Pfad. processEnvironment() entfernt jedoch sämtliche CLAUDE_CODE_*-Variablen, einschließlich genau dieser Variable. Bootstrap.launchEnvironment() liest den angeblich zu erhaltenden Wert erst aus dieser bereinigten Umgebung und bekommt immer nil. Neue Chats erhalten dadurch nur das WhisperM8-Plugin; eigene Plugin-Tools und Befehle fehlen. Bei ausgeschaltetem WhisperM8-Plugin wird der fremde Wert ebenfalls nicht wiederhergestellt.

**Fix:** Fix: PLUGIN_DIRS aus dem rohen Environment lesen (nicht aus processEnvironment()), den CLAUDE_CODE_*-Strip aber für alle anderen Variablen unverändert lassen; den Strip nicht per Ausnahme aufweichen, das ist eine dokumentierte Invariante.

*Ursprünglicher Vorschlag:* Die gewollte Plugin-Pfadliste vor der Kontextbereinigung erfassen oder gezielt von deren Entfernung ausnehmen. Nur verschachtelte Session-/Routing-Variablen entfernen; fremde Plugin-Pfade in ursprünglicher Reihenfolge erhalten, den eigenen Pfad dedupliziert ergänzen und beim Kill-Switch ausschließlich das eigene Plugin weglassen. Einen Integrationstest über Resolver und Bootstrap ergänzen, nicht nur über launchEnvironment() mit direkt übergebenem inherited-Wert.

**Test zuerst:** Integrationstest: base-Env mit CLAUDE_CODE_PLUGIN_DIRS=/foo und CLAUDE_CODE_SESSION_ID=x durch Resolver+Bootstrap-Logik (z. B. launchEnvironment-Parameter inherited aus dem rohen ProcessInfo-Env statt aus processEnvironment()); erwartet '/foo:<ours>', CLAUDE_CODE_SESSION_ID bleibt entfernt. Heute liefert Bootstrap nur '<ours>'.

<details><summary>Prüfurteil</summary>

Der Widerspruch im Code ist real: processEnvironment() entfernt alle CLAUDE_CODE_*-Variablen (LoginShellEnvironment.swift:106-108), ClaudePluginBootstrap.launchEnvironment liest 'inherited' aus genau diesem bereinigten Env und bekommt daher nie einen fremden CLAUDE_CODE_PLUGIN_DIRS-Wert; der Erhalt in WhisperM8ClaudePlugin.launchEnvironment ist im Produktivpfad totes Verhalten (nur der Unit-Test mit direktem inherited-Wert besteht). Die Reichweite ist aber winzig: CLAUDE_CODE_PLUGIN_DIRS ist ein Entwickler-/Debug-Mechanismus, den eine per Dock gestartete GUI-App gar nicht erbt (nur via launchctl setenv oder Start aus einem Terminal), und die Zielgruppe richtet Plugins über 'claude plugin' ein, das nicht betroffen ist. Der Entfernungs-Guard selbst ist ein dokumentierter, wichtiger Workaround (Vorfall verschachtelte Child-Session). Konsistenzfehler mit sehr niedriger Wirkung.

</details>

### LR-SH-016 · Installierbare Statusline braucht jq, das macOS 14 nicht mitbringt; weder Cask noch Einstellungen prüfen das

*P3 · shared / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Resources/whisperm8-statusline.sh:12-16`, `WhisperM8/Resources/whisperm8-subagent-statusline.sh:6-13`, `scripts/update-cask.sh:38`, `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:528-600` (Stand `a8e0f35`)

**Fehlerbild:** Auf einem frischen macOS 14 installiert der Nutzer in den Einstellungen die Statusline. Die Einstellungsseite meldet Erfolg, Claude Code zeigt danach aber nur noch die Zeile "whisperm8-statusline: jq fehlt (brew install jq)". Der Cask deklariert kein depends_on formula: "jq", die Settings-Seite prüft jq nicht.

**Fix:** Im Cask depends_on formula: "jq" ergänzen oder vor der Installation jq prüfen und einen geführten Hinweis zeigen.

**Test zuerst:** Cask-Generierungstest prüft `depends_on formula: "jq"` – oder StatuslineInstaller-Test: ohne jq erscheint ein geführter Hinweis statt einer stummen Statuszeile.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.
