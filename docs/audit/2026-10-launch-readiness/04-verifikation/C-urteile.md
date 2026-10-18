---
status: aktiv
updated: 2026-10-17
description: Urteile von Workflow C (10 Sonnet-Gegenprüfer) zu den 80 eigenständigen P0/P1-Befunden aus Workflow A.
---

# Verifikation C: Urteile

Geprüft: 80 Befunde. Ergebnis: teilbestätigt 56, bestätigt 23, widerlegt 1.

Nach der Prüfung: **0 P0**, **12 P1**, 67 herabgestuft auf P2/P3; **11 Launch-Blocker**.

## Schwere vorher → nachher (ohne widerlegte)

| Finder | Prüfer | Anzahl |
|---|---|---|
| P0 | P1 | 4 |
| P0 | P2 | 15 |
| P0 | P3 | 1 |
| P1 | P1 | 8 |
| P1 | P2 | 43 |
| P1 | P3 | 8 |

## Launch-Blocker nach Prüfung

| ID | Schwere | Titel | Urteil |
|---|---|---|---|
| LR-DIK-015 | P1 | Fehlende Codex-CLI führt nur zu einer Hilfeseite statt Installation | bestätigt |
| LR-DIK-008 | P1 | Entfernen des Chat-Kontexts lässt den Gesprächsverlauf im Prompt | bestätigt |
| LR-KO-001 | P1 | OAuth- und Refresh-Tokens stehen beim Umbenennen und Hochstufen im Prozess-argv | teilbestätigt |
| LR-AK-001 | P1 | : Ungültige Summary-Ausgabe kann die gesamte App beenden | bestätigt |
| LR-AK-006 | P1 | : Der Codex-Statusparser versteht das verwendete Rollout-Format nicht | bestätigt |
| LR-BR-003 | P1 | Öffentliche Releases umgehen Gatekeeper statt E4 umzusetzen | bestätigt |
| LR-BR-005 | P1 | Cask-Deinstallation besitzt keinen Prozess- und Integrationsabbau | teilbestätigt |
| LR-ONB-003 | P1 | : Das Full-Onboarding besitzt keinen Claude-Installations- oder Login-Schritt | bestätigt |
| LR-ONB-004 | P1 | : Mikrofon-Ablehnung erzeugt im Wizard eine Sackgasse | bestätigt |
| LR-DOK-004 | P2 | Das Handbuch empfiehlt vollständige Datenlöschung als normale Fehlerbehebung | teilbestätigt |
| LR-DOK-005 | P2 | Das Anwenderhandbuch führt zu nicht mehr vorhandenen Einstellungsseiten | bestätigt |

## Alle Urteile

### LR-AK-001 · : Ungültige Summary-Ausgabe kann die gesamte App beenden

*bestätigt · Finder P0! → Prüfer P1 · Launch-Blocker*

Der Defekt ist real: parseOutput bildet text[start...end] ohne start<=end zu prüfen; bei Ausgabe wie `}{` (letztes `}` vor erstem `{`) trappt die ClosedRange-Vorbedingung auch im Release, kein do/catch fängt das. Der Auslöser ist aber eine ungewöhnliche Modellausgabe (nur wenn ein `}` vor dem ersten `{` steht, nicht bei normalem Prosatext oder JSON), daher P1 statt P0. Auto-Läufe laufen bei jedem Anzeigen eines beendeten Chats, die DoD-Zeile 'kein bekannter Weg, auf dem die App still beendet wird' ist literal verletzt. Der Fix ist S und trivial, deshalb Blocker.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:57 — nur firstIndex/lastIndex-Guard auf nil; Tests (AgentSessionSummarizerTests.swift:67-70) prüfen nur 'kein json' und leere Headline, nie vertauschte Klammern.

**Regressionstest:** AgentSummaryGeneratorTests: XCTAssertNil(AgentSummaryGenerator.parseOutput("}{")) sowie "} text {" und "{ unvollständig"; heute Trap (Testprozess stürzt ab), erwartet nil.

**Zum Fix:** Fix: start <= end prüfen (oder text[start...].firstIndex(of:"}")-Suche ab start). Ein strukturierter Extractor ist nicht nötig.

### LR-AK-006 · : Der Codex-Statusparser versteht das verwendete Rollout-Format nicht

*bestätigt · Finder P1! → Prüfer P1 · Launch-Blocker*

parseCodexLine kennt nur die Formate type=event/subtype=turn.completed und type=item; die echten Rollouts (CodexRolloutFixtures) liefern type=event_msg/response_item/session_meta mit payload.type=task_complete usw. Jede echte Codex-Zeile landet bei .other. Der Status eines Codex-Chats fällt auf die reine mtime-Heuristik zurück (working bis 30 s nach dem letzten Write, danach idle, auch bei langem stillem Tool-Lauf), und turnFinished kommt nie, weshalb auch Fertig-Notification, Stop-Sound und die turn-end-getriebene Titelübernahme für Codex ausbleiben (Codex hat keine Hooks als Gegenpol). Es ist ein degradierter, kein totaler Ausfall, daher P1; Codex gehört zu F-AC-02/06 (Kern), W4 nennt allerdings Claude.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:283-292 — .other fällt auf die 30-s-Heuristik, die Anzeige bleibt dadurch grob brauchbar; Tests (AgentTranscriptStatusTests.swift:43-56) bilden nur das alte erfundene Format ab.

**Regressionstest:** AgentTranscriptStatusTests: parseLine(CodexRolloutFixtures.taskComplete, .codex) == .assistantMessageStopped; taskStarted/userMessage(event_msg) -> .userMessage bzw. working; tokenCount -> .meta. Danach decide(lastEvent: ...) liefert .idle + turnFinished. Heute .other.

**Zum Fix:** Alte Formate als Kompatibilität behalten ist ok; wichtig: token_count und turn_context als .meta behandeln, nicht als Aktivität, sonst bleibt 'working' nach task_complete hängen.

### LR-BR-003 · Öffentliche Releases umgehen Gatekeeper statt E4 umzusetzen

*bestätigt · Finder P1! → Prüfer P1 · Launch-Blocker*

Die Release-Pipeline baut ad-hoc, ohne Developer ID und ohne Notarisierung. Der Cask entfernt die Quarantäne per postflight (update-cask.sh:42-47). Die Entscheidung E4 (b: Developer ID plus Notarisierung) ist beschlossen, der Ist-Zustand erfüllt sie nicht. Für das bloße Starten genügt der xattr-Workaround, den Gatekeeper-Teil von W1 umgeht er also funktional. Der stärkere Grund für den Blocker: Ad-hoc-Signaturen sind an den cdhash gebunden, deshalb fragt macOS nach jedem Update erneut TCC-Rechte ab. Das verletzt W6 ('ohne neue Rechte-Abfrage'). Kein Bug, sondern eine bekannte, beschlossene Lücke. Sie hängt an einem Apple-Developer-Konto (organisatorische Voraussetzung).

**Gegenstelle:** .github/workflows/release.yml:5-9 und scripts/update-cask.sh:8-10 dokumentieren das Self-Signed-Verhalten als bewusst. Das ist aber die alte Entscheidung, E4 vom 17.10.2026 überstimmt sie.

**Regressionstest:** Kein Unit-Test. Release-Gate im CI: nach dem Build 'codesign -dv' muss eine Authority=Developer ID Application zeigen, 'spctl -a -vv -t install' muss 'accepted, source=Notarized Developer ID' liefern, 'xcrun stapler validate' muss ok sein. Der Check schlägt heute fehl.

**Zum Fix:** Der Fix hängt direkt an LR-BR-004: Solange der Developer-ID-Zweig im Skript abbricht, lässt sich E4 nicht umsetzen. Zertifikat in einer temporären Keychain im CI bereitstellen. Die Bundle-ID com.whisperm8.app muss stabil bleiben, sonst gehen TCC-Rechte verloren. Den Cask-postflight erst nach dem ersten notarisierten Release entfernen.

### LR-BR-005 · Cask-Deinstallation besitzt keinen Prozess- und Integrationsabbau

*teilbestätigt · Finder P1! → Prüfer P1 · Launch-Blocker*

Der generierte Cask hat nur app, postflight und zap trash, aber keine uninstall-Stanza (update-cask.sh:28-54). Eine laufende App wird bei 'brew uninstall --zap' nicht beendet, ihr Bundle wird nur entfernt. Zusammen mit ihren Hilfsprozessen (Proxy, Control-Socket) und den Daten läuft sie weiter. Genau das schließt W7 aus ('hinterlässt keine laufenden Prozesse'). Außerdem bleiben ~/.local/bin/whisperm8 (dangling), die Statusline-Dateien samt Stempel in ~/.claude und das Plugin-Setup übrig. W7 ist explizit definiert und nicht erfüllt, daher Blocker. Der Aufwand L stimmt aber nur für die vollständige Integrationsbereinigung. Der Kern (Prozess beenden) ist mit 'uninstall quit: "com.whisperm8.app"' eine Zeile. Die Warnung vor pauschalem Löschen in ~/.claude ist richtig.

**Gegenstelle:** Der Cask hat zap trash (update-cask.sh:49-53) für App Support, Caches und Prefs. Das deckt die Daten ab, aber nicht den Prozess und nicht die Integrationen.

**Regressionstest:** Kein Unit-Test. Skript-Test auf update-cask.sh: Die erzeugte whisperm8.rb muss eine uninstall-Stanza mit quit: 'com.whisperm8.app' enthalten ('brew audit --cask' plus grep). Heute schlägt das fehl. Dazu ein manueller W7-Lauf auf einer frischen Brew-Installation.

**Zum Fix:** Sofortmaßnahme: 'uninstall quit: "com.whisperm8.app"' (graceful, damit die gedebouncten Stores geflusht werden) plus optional 'launchctl'/'signal' nur für eigene Helfer. Die Bereinigung von ~/.claude (Statusline-Dateien mit dem Marker 'managed-by: whisperm8-statusline', Stempel) nur über Marker-Prüfung, nie pauschal. Für 'brew uninstall' ohne Rückfrage ist ein Cask-uninstall-script riskant, besser ein In-App-Menüpunkt 'Integrationen entfernen' vor dem Deinstallieren.

### LR-BR-006 · Cask akzeptiert beide Mac-Architekturen, das DMG enthält nur die Build-Architektur

*bestätigt · Finder P1! → Prüfer P1*

Der Build läuft ohne --arch und damit nativ arm64 (macos-26-Runner und der dokumentierte Apple-Silicon-Rechner in DMG_BAUEN.md:5). Der Cask hat nur 'depends_on macos: :sonoma', keine Architekturprüfung. Ein Intel-Mac mit macOS 14 bis 26 installiert den Cask erfolgreich, die App startet aber nicht ('bad CPU type', Rosetta übersetzt kein arm64). Eine Produktentscheidung zur Architektur existiert nirgends (grep Intel/arm64/universal: nur DMG_BAUEN). Das ist ein reales, aber kleines Segment mit billigem Fix. Für Apple-Silicon-only reicht 'depends_on arch: :arm64' im Cask. Als Blocker taugt es nicht, weil es nach einer Entscheidung eine Einzeiler-Korrektur ist und keinen W-Weg für die Zielgruppe bricht.

**Gegenstelle:** docs/DMG_BAUEN.md:5 verlangt ausdrücklich Apple Silicon als Build-Voraussetzung. Das ist aber eine Build-, keine Nutzer-Aussage.

**Regressionstest:** Test auf die generierte whisperm8.rb: enthält 'depends_on arch: :arm64' (oder passende Mach-O-Archs). Alternativ ein CI-Schritt 'lipo -archs WhisperM8.app/Contents/MacOS/WhisperM8' muss mit der im Cask deklarierten Architektur übereinstimmen. Heute: Cask ohne arch-Angabe, Binary nur arm64.

**Zum Fix:** Der schnellste und sicherste Weg ist die Entscheidung 'Apple-Silicon-only' mit 'depends_on arch: :arm64' im Cask und einem Hinweis im README. Ein Universal-Build (swift build --arch arm64 --arch x86_64) ändert die Build-Ausgabepfade (.build/apple/Products/Release statt .build/release). Das würde Makefile BUILD_DIR, patch-resource-accessors.sh und die Resource-Bundle-Schleife in _bundle brechen, weshalb dort ein eigener Test nötig wäre.

### LR-DIK-003 · CLI-Batchausgabe überschreibt vorhandene Dateien ungefragt

*bestätigt · Finder P0! → Prüfer P1*

emit() (CLITranscribe.swift:254-258) schreibt bei mehreren Eingaben nach <basename>.<format> neben der Quelle, mit rendered.write(atomically:) ohne Existenz- oder Kollisionsprüfung. Eine vorhandene, handbearbeitete meeting.txt wird also still ersetzt; meeting.mp3 und meeting.wav im selben Aufruf überschreiben sich gegenseitig. Das Ziel-neben-Quelle ist dokumentiertes Verhalten (CLITranscribe.swift:47), die fehlende Kollisionsprüfung nicht. Es ist ein echter, aber enger Datenverlust-Pfad (nur Batch-Modus, nur Erweitert-Feature F-DIK-11, kein Nutzerweg W1–W7), daher P1 statt P0 und kein Launch-Blocker.

**Gegenstelle:** WhisperM8/CLI/CLITranscribe.swift:47: Ausgabe 'neben den Quelldateien' ist bewusst so gewollt; Wiederholungsläufe überschreiben eigene Ergebnisse absichtlich.

**Regressionstest:** CLITranscriptionTests: emit() (bzw. ein extrahierter Pfad-Planer) mit temporärem Verzeichnis, in dem meeting.mp3, meeting.wav und eine vorhandene meeting.txt liegen, inputs.count == 2; erwartet: Abbruch oder eindeutige Namen vor dem ersten Schreiben, bestehende meeting.txt unverändert. Schlägt heute fehl.

**Zum Fix:** Fix des Finders (Vorab-Prüfung aller Zielpfade, Standard abbrechen, --force zum Überschreiben) ist vernünftig. Bei Wiederholungsläufen darf das nicht den üblichen Re-Run blockieren, daher --force oder --overwrite anbieten.

### LR-DIK-008 · Entfernen des Chat-Kontexts lässt den Gesprächsverlauf im Prompt

*bestätigt · Finder P1! → Prüfer P1 · Launch-Blocker*

removeAgentChatFromContext() setzt nur contextBundle.agentChat=nil, agentChatTail bleibt unverändert. PostProcessingTemplate.render ersetzt {agentChatTail} direkt aus contextBundle.agentChatTail ohne Prüfung auf agentChat. Die Fast-Prompt-, Prompt-, Ultra- und Task-Footer enthalten den Platzhalter (Zeilen 146 und 334). ContextCaptureMerge schützt nur das Nachreichen des Tails, nicht das Rendern eines bereits geladenen. Der Nutzer entfernt den Chat-Kontext ausdrücklich, und der letzte User- und Assistenten-Turn geht trotzdem an Codex. Das verletzt die DoD-Zeile zum abschaltbaren Datenabfluss. Die Auswirkung begrenzt sich auf Nutzer mit Profil full, Chat-Kontext und Template-Modi. Der Fix ist klein.

**Gegenstelle:** WhisperM8/Services/Dictation/PromptPackageBuilder.swift:292 sperrt den Tail über das Guard auf agentChat korrekt. Nur der Template-Renderpfad hat diese Absicherung nicht. clearContextBundle() baut das Bundle komplett neu und ist nicht betroffen.

**Regressionstest:** Test auf TranscriptContextBundle/PostProcessingTemplate: Bundle mit agentChat und agentChatTail="SECRET" bauen, agentChat=nil setzen (wie removeAgentChatFromContext), dann PostProcessingTemplate-Prompt.render(..., contextBundle:) aufrufen. Erwartet: Output enthält "SECRET" nicht. Heute enthält er es.

**Zum Fix:** Beides machen: Tail beim Entfernen mitlöschen und in render() nur ausgeben, wenn agentChat != nil. Das Merge-Verhalten für vorzeitig entfernte Referenzen bleibt unverändert.

### LR-DIK-015 · Fehlende Codex-CLI führt nur zu einer Hilfeseite statt Installation

*bestätigt · Finder P1! → Prüfer P1 · Launch-Blocker*

Bei fehlender Codex-CLI liefert CodexStatusProbe .notInstalled (CodexSupport.swift:173); die Settings-Seite bietet weiterhin 'Sign In' an, und openLoginInTerminal öffnet dann nur eine OpenAI-Hilfeseite (CodexSupport.swift:191-194). Der E-Mail-Lauf scheitert an der Bereitschaftsprüfung (CodexPostProcessor.swift:25-29) und fällt auf Raw zurück. Nutzerweg W3 verlangt ausdrücklich 'führt durch Installation und Login', ohne Terminal-Nacharbeit; das ist hier nicht erfüllt. Das Feature-Inventar vermerkt den Ausbau selbst als nötig. Kein Fehlerfall im Code, sondern eine fehlende Funktion, die eine Definition-of-Done-Zeile verletzt, daher P1/Blocker.

**Gegenstelle:** WhisperM8/Views/OnboardingView.swift verweist ebenfalls auf CodexStatusProbe; ein Installationsschritt wurde im Code nicht gefunden. Raw-Fallback verhindert Datenverlust, verfehlt aber W3.

**Regressionstest:** CodexStatusProbeTests: commandResolver liefert nil, Status == .notInstalled; erwartet: die UI-Aktion für diesen Zustand ist ein Installationsangebot (neue Aktion/Enum), nicht openLoginInTerminal/Hilfe-URL. Heute öffnet notInstalled genau die Hilfe-URL (NSWorkspace-Spy).

**Zum Fix:** Installation per offiziellem Installer nur nach ausdrücklicher Bestätigung (nie stillschweigend, kein curl|sh ohne Prüfsumme), danach Version/Login/Testlauf prüfen. Mit LR-ONB-002 zusammenlegen, damit es nicht zwei Setup-Wege gibt.

### LR-KO-001 · OAuth- und Refresh-Tokens stehen beim Umbenennen und Hochstufen im Prozess-argv

*teilbestätigt · Finder P0! → Prüfer P1 · Launch-Blocker*

Der Code-Pfad ist real: renameProfile (ClaudeAccountProfiles.swift:468-471) und writeMainSecret (+Promote.swift:218-222) übergeben das volle Keychain-Secret als `-w <secret>` an /usr/bin/security, also in argv. Abmilderung: Fenster von Millisekunden, nur bei Umbenennen/Hochstufen (seltene Admin-Aktion in der Klasse Erweitert), macOS zeigt argv fremder Benutzer nicht, und Claude Code legt seinen eigenen Login auf dieselbe Weise ab. Ein Angreifer mit gleicher UID kann das Item voraussichtlich ohnehin per `security find-generic-password -w` lesen. Der Punkt 'Keine Secrets in argv' steht aber wörtlich in der Definition of Done, deshalb P1 und Blocker. Das Gewicht liegt am DoD-Wortlaut, nicht an der Praxis-Ausnutzbarkeit; das P0 ist überhöht.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:468 – Fenster nur während des security-Aufrufs, nur gleicher Benutzer; Claude CLI verhält sich identisch.

**Regressionstest:** Test in ClaudeAccountProfilesTests: securityRunner so ersetzen, dass es die übergebenen Argumente protokolliert; renameProfile bzw. promoteToMain mit Fake-Secret 'sk-ant-SECRET' ausführen und erwarten, dass kein Argument das Secret enthält (heute schlägt der Test fehl, weil `-w secret` übergeben wird). Dazu muss die Runner-Signatur um einen stdin-Parameter erweitert werden.

**Zum Fix:** Der Vorschlag 'Security.framework statt security-CLI' ist riskant: Ein per SecItemAdd angelegtes Item hat eine ACL nur für WhisperM8, und die Claude-CLI liest es per `security find-generic-password` – das löst dann Keychain-Passwortdialoge aus oder scheitert still. Sicherer ist `security -i` mit den Befehlen über stdin (kein argv, gleiche ACL/Ersteller wie bisher), plus sauberes Quoting des Secrets.

### LR-KO-002 · MCP-Angleich veröffentlicht Header-Tokens und andere Server-Secrets in argv

*teilbestätigt · Finder P0! → Prüfer P1*

Der Code übergibt die komplette Definition (inkl. headers.Authorization/env) tatsächlich als argv an `claude mcp add-json` (ClaudeMCPSync.swift:131-136); das Kommentarversprechen 'nie geloggt' deckt argv nicht ab. Die DoD-Zeile 'Keine Secrets in argv' wird formal berührt. Das Szenario ist aber stark entschärft: Auto-Angleich ist Default aus, 'Copy' braucht einen Klick, das Fenster ist je Aufruf <=30 s, dieselben Tokens liegen ohnehin im Klartext in ~/.claude.json, und gleichnamige Prozesse desselben Users können sie sowieso lesen. Nur andere lokale macOS-Benutzer (Multi-User-Mac, selten) könnten per ps mitlesen. Kein realistischer P0-Secret-Leak, aber eine billig behebbare Policy-Verletzung.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeMCPSync.swift:75-79 und 160-166: Plan ist rein ergänzend, Auto-Sync Default aus (AppPreferences.isMCPAutoSyncEnabled); claude mcp add-json kennt (soweit bekannt) keinen stdin-Kanal, der Finder-Fix 'sicherer Kanal' ist mit der echten CLI evtl. gar nicht machbar.

**Regressionstest:** ClaudeMCPSyncTests: Snapshot mit Server, dessen Definition {"type":"http","headers":{"Authorization":"Bearer SECRET123"}} ist, Spy-ProcessRunner mit Argument-Capture; Auto-Pfad (runAtLaunchIfEnabled) bzw. plan() muss diesen Server als 'secret-haltig/manuell' markieren, und kein captured argv darf 'SECRET123' enthalten. Schlägt heute fehl, da addition.definitionJSON unverändert in arguments landet.

**Zum Fix:** Finder-Fix 'nachweislich unterstützter Secret-Kanal' ist nur machbar, wenn die echte Claude-CLI einen anbietet (add-json nimmt JSON nur als Argument). Pragmatisch: Definitionen mit Header-/Env-Werten erkennen (headers, env, Authorization-ähnliche Schlüssel) und nicht automatisch verteilen, sondern im Sheet 'manuell je Konto einrichten' anbieten oder explizit bestätigen lassen. Kein Direktschreiben in .claude.json (bricht die dokumentierte Invariante).

### LR-ONB-003 · : Das Full-Onboarding besitzt keinen Claude-Installations- oder Login-Schritt

*bestätigt · Finder P1! → Prüfer P1 · Launch-Blocker*

Die Schrittfolge in OnboardingView (welcome, profile, permissions, hotkey, apiKey, optional codex, test) enthält keinen Claude-Schritt. Im ganzen WhisperM8-Verzeichnis gibt es keine Installationsführung. Es existieren nur die nackten Meldungen 'Claude/Codex CLI is not installed.' (AgentCommandBuilder:35) und 'install Claude Code first' (Konten-Tab). Das ist keine Fehlfunktion, sondern eine Lücke, die W4 und Entscheidung E5 ausdrücklich verlangen ('führt durch Installation und Login'). Damit ist ein Nutzerweg der Launch-Definition für die Zielgruppe ohne Entwickler-Hintergrund verletzt. P1 passt, weil der Nutzer ohne Terminalwissen nicht weiterkommt, aber nichts abstürzt oder verloren geht.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:35 liefert immerhin eine Fehlermeldung beim Chat-Start. Sie enthält aber keine Anleitung und keinen Installer.

**Regressionstest:** Die Schrittableitung aus OnboardingView in eine pure Funktion extrahieren (Profil, CLI-Verfügbarkeit per Closure) und per XCTest prüfen. Eingabe: Profil .full, commandResolver { _ in nil }. Erwartet: Die Schrittliste enthält einen CLI-Installations- und Login-Schritt. Das schlägt heute fehl. Für .dictationRaw darf er nicht erscheinen.

**Zum Fix:** Der Fix des Finders ist grundsätzlich passend. Er muss aber den offiziellen Installer mit Rückfrage nutzen (E5 b), die echte CLI im PTY hosten und Diktat-only-Profile unberührt lassen. Der Aufwand ist L, und der Punkt ist eher ein Feature-Ausbau als ein Bug.

### LR-ONB-004 · : Mikrofon-Ablehnung erzeugt im Wizard eine Sackgasse

*bestätigt · Finder P1! → Prüfer P1 · Launch-Blocker*

Bei denied oder restricted ruft der Grant-Button nur AVCaptureDevice.requestAccess auf (OnboardingView:466-470). Das zeigt bei denied keinen Dialog mehr und gibt sofort false zurück. canProceed bleibt an micGranted gekoppelt, und es gibt weder 'Open Settings' noch einen Hinweistext. Die Settings-Seite löst genau diesen Fall bereits sauber (PermissionSettingsModel:104-159), im Wizard wurde das nicht übernommen. Ein versehentliches 'Don't Allow' ist ein gewöhnlicher Fehlerpfad in W2. Beim nächsten Start öffnet sich der Wizard wieder, weil needsOnboarding am Mikrofon hängt. Der Nutzer dreht sich im Kreis, bis er Systemeinstellungen oder die Settings-Seite über die Menüleiste selbst findet.

**Gegenstelle:** Über die Menüleiste ist Settings, Permissions, 'Open Settings' erreichbar (PermissionSettingsModel:104-114). Der Weg ist aber nicht angezeigt. Der Wizard pollt alle 0,5 s und erkennt eine nachträgliche Freigabe automatisch (OnboardingView:468-480).

**Regressionstest:** Die Aktion des Wizards in eine testbare Entscheidungsfunktion extrahieren oder PermissionSettingsModel wiederverwenden. Eingabe: microphoneStatusProvider = .denied. Erwartet: performMicrophonePrimaryAction ruft openMicrophoneSettings auf und nicht requestMicrophonePermission. Heute ruft der Wizard-Pfad immer requestAccess auf, ohne Settings-Link.

### LR-AK-002 · : Downgrade überschreibt ein neueres Workspace-Schema

*teilbestätigt · Finder P0! → Prüfer P2*

Mechanik stimmt: migratedWorkspace setzt schemaVersion bedingungslos auf currentSchemaVersion (=1), Codable ignoriert unbekannte Felder, Load speichert zurück. Aber es gibt im Feld keine Schema-2-Datei: currentSchemaVersion ist 1, W6 (Update) geht nur vorwärts. Betroffen wäre nur ein Downgrade nach Nutzung einer künftigen Version, und vor dem Überschreiben wird ein pre-migration-Backup geschrieben plus 3 rotierende Generationen. Das ist Zukunftssicherung, kein Launch-Datenverlust.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:54-64 — backup(reason: "pre-migration") vor dem save; rotierende .bak.1-3 in save().

**Regressionstest:** AgentWorkspaceRepositoryTests: Datei mit schemaVersion 2 + unbekanntem Zusatzfeld laden; nach load(migrate:) muss die Datei bytegleich bleiben bzw. der Store schreibgesperrt sein. Heute wird sie auf 1 überschrieben.

**Zum Fix:** Future-Version-Guard jetzt einbauen ist billig (vor dem ersten Schema-2-Release), aber nicht launch-kritisch.

### LR-AK-003 · : Zusammenfassungen legen vertraulichen Chat-Inhalt in argv offen

*teilbestätigt · Finder P0! → Prüfer P2*

Der Prompt (je User-Runde max. 280 Zeichen, je Agent-Antwort 500 Zeichen, insgesamt 6000) steht tatsächlich im argv von `claude -p`/`codex exec`. Sichtbar ist das aber nur für denselben Benutzer (macOS zeigt argv fremder Benutzer nicht), und dieselben Chat-Inhalte liegen ohnehin im Klartext in ~/.claude und ~/.codex. Es entsteht keine Grenzüberschreitung; ein Secret müsste zudem in den ersten Zeichen einer Nachricht stehen. Das Muster (Prompt in argv) gilt für alle Headless-Helfer des Repos. Die DoD 'keine Secrets in argv' ist eher als Härtungsziel verletzt, nicht als Sicherheitslücke.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift:48 setzt stdin auf /dev/null; Transcript-Dateien selbst liegen im Klartext im Home des Nutzers, argv fügt keinen neuen Leser hinzu.

**Regressionstest:** AgentSummaryGenerator mit Spy-Runner: Prompt mit Marker 'SECRET-123' erzeugen; args darf den Marker nicht enthalten, stdin-Payload schon. Heute fehlschlagend, setzt aber stdin-Erweiterung von AgentHeadlessCLI voraus.

**Zum Fix:** stdin-Fix ist sinnvoll, setzt voraus, dass claude -p und codex exec - den Prompt zuverlässig von stdin lesen (vorher verifizieren); nicht die echte CLI ersetzen.

### LR-AK-004 · : Skalare Tool-Payloads passieren eine NSException-gefährdete JSON-Serialisierung

*teilbestätigt · Finder P0! → Prüfer P2*

API-Vertrag stimmt: JSONSerialization.data(withJSONObject:) mit skalarem Top-Level wirft unter Darwin eine NSException, try? fängt sie nicht; der Search-Extractor prüft isValidJSONObject, die Display-Reader nicht. Der Auslöser ist aber ein malformierter Transcript: Claude-tool_use.input ist laut API immer ein Objekt, und die echte Codex-Fixture hat arguments als Dictionary. Ein skalarer Wert kommt aus keinem bekannten Erzeuger. Bei manuell beschädigten oder künftig geänderten Dateien wäre der Absturz aber deterministisch bei jedem Öffnen.

**Gegenstelle:** Tests/WhisperM8Tests/AgentTestSupport.swift:58 — echtes tool_search_call mit arguments als Objekt; Claude-API-Schema für tool_use.input ist ein Objekt. Eine Absicherung existiert bereits in ChatSearchContentExtractor.swift:209.

**Regressionstest:** ClaudeTranscriptReader.parseEntry mit tool_use input 1, true, null, "x" und Array; CodexTranscriptReader mit tool_search_call arguments 1. Erwartung: kein Crash, input als String. Heute ObjC-Exception-Abbruch des Testprozesses.

**Zum Fix:** isValidJSONObject-Guard (wie im Extractor) reicht; fragmentsAllowed ist nicht nötig.

### LR-AK-005 · : Fehlgeschlagene Workspace-Writes bleiben unsichtbar und ohne eigenen Retry

*teilbestätigt · Finder P1! → Prüfer P2*

Die Beschreibung des Codes stimmt: drain setzt bei Fehler dirty=true, plant aber keinen Retry und zeigt keinen Fehler. Die Lücke ist in der Praxis klein: jede weitere Mutation (laufend durch Status-/Aktivitätsänderungen) plant über persistLocked einen neuen Flush, didResignActive flusht bei jedem App-Wechsel, und willTerminate flusht synchron nochmal. Verlust bräuchte also anhaltende Schreibfehler bis zum Absturz ohne eine einzige weitere Mutation oder einen Fokuswechsel. Stille Fehler ohne UI-Hinweis sind ein Qualitätsmangel, aber kein P1.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:93-98 (resign-Flush) und :342-355 (persistLocked rearmiert bei jeder Mutation); :233-247 flushSync beim Terminate.

**Regressionstest:** AgentWorkspaceStoreTests: debounced Store mit PersistSpy, erster Persist schlägt fehl; ohne weiteren Aufruf muss innerhalb von Backoff-Zeit (injizierbarer Timer) ein zweiter Versuch erfolgen. Heute kommt keiner.

**Zum Fix:** Begrenzter Backoff-Retry in drain ist harmlos; der geforderte Nutzerhinweis ist optional.

### LR-AK-007 · : Ein großes letztes JSONL-Event macht den gesamten Verlauf unerreichbar

*teilbestätigt · Finder P1! → Prüfer P2*

Logik stimmt: TranscriptTailReader verwirft die angeschnittene erste Zeile; ist die letzte JSONL-Zeile größer als das 512-KiB-Fenster (AgentSessionDetailView.initialTailBytes), bleibt messages=[] bei hasTruncatedHead=true, der Container nimmt dann nur den Empty-State ohne Nachladen-Button. Voraussetzung ist, dass die Datei genau mit einer >512 KiB großen Zeile endet (z. B. Bild-/Riesen-Tool-Result direkt vor Abbruch); normalerweise folgt eine Assistant-Zeile. Seltener Randfall, aber ohne Ausweg für den Nutzer, und nur die Verlaufsansicht, kein Datenverlust.

**Gegenstelle:** WhisperM8/Views/AgentSessionDetailView.swift:51,56 — Fenster 512 KiB, bis 32 MiB nachladbar; im Normalfall liegt ≥1 vollständige Zeile im Fenster.

**Regressionstest:** TranscriptTailReader/ClaudeTranscriptReader: Datei = kleine gültige Zeilen + zuletzt eine Zeile > tailBytes; readTail muss entweder frühere Zeilen liefern oder (messages leer, hasTruncatedHead true) so markiert sein, dass der Container den Nachladen-Button zeigt (ViewInspector/Logiktest auf showsHistorySection).

**Zum Fix:** Einfachster Fix: im Container den Nachladen-Pfad auch bei leerem, aber kopfgekürztem Transcript zeigen; kein unbeschränkter Rückwärts-Read.

### LR-AK-008 · : Eine UTF-8-Schnittkante verhindert dauerhaft den Import einer gültigen Session

*bestätigt · Finder P1! → Prüfer P2*

BoundedJSONLReader.lines liest exakt 1 MiB und dekodiert den ganzen Prefix mit String(data:encoding:.utf8), das bei einem abgeschnittenen Multibyte-Zeichen nil liefert; parseSessionFile gibt nil zurück und der Indexer cached nil für Größe+mtime. Eine beendete Datei bleibt so dauerhaft ungescannt. Betroffen sind externe, nicht in WhisperM8 gestartete Sessions >1 MiB mit Zeichen genau an der Grenze (einige Prozent der großen Dateien, bei Umlauten/Emoji); in der App gestartete Sessions sind im Workspace und unberührt. Fehlender Import externer Chats, kein Datenverlust.

**Gegenstelle:** Chats, die in WhisperM8 gestartet wurden, stehen bereits im Workspace; Datei wird bei jedem Wachstum neu gelesen (Cache-Key Größe+mtime), nur beendete Dateien bleiben unsichtbar.

**Regressionstest:** BoundedJSONLReaderTests: Datei >1 MiB, bei der Byte 1.048.576 mitten in einem 'ä' oder Emoji liegt; lines(from:maxLines:maxBytes:) muss die vollständigen Zeilen davor liefern (heute nil). Zusätzlich ClaudeSessionIndexer-Test: Session wird importiert.

**Zum Fix:** Prefix an der letzten vollständigen Zeilengrenze (letztes 0x0A) kürzen, oder String(decoding:) pro Zeile verwenden.

### LR-AK-009 · : Summary-Hilfsläufe verlieren das Konto und Backend des Chats

*teilbestätigt · Finder P1! → Prüfer P2*

Stimmt: generate bekommt nur Provider+Prompt, das Environment kommt aus processEnvironment(), das CLAUDE_CONFIG_DIR und GPT-Header entfernt; Summaries laufen daher immer unter main. Das ist aber ein dokumentierter Zustand (Analyse 11.10.2026): bei abgemeldetem main scheitert der Lauf, wird mit 30-Minuten-/2-Stunden-Backoff gedrosselt, der Startup-Lauf ist standardmäßig aus, und die Karte zeigt weiter 'keine Zusammenfassung'. Betrifft nur Mehrkonto-Nutzer (Erweitert) und GPT-Labs-Chats; die Kern-Zielgruppe mit einem Konto ist nicht betroffen. Kein Absturz/Datenverlust, nur fehlende Zusammenfassung bzw. Quotenverbrauch auf main.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:123-150 (failureBackoff) und AppPreferences.swift:225-232 (Startup-Abgleich seit 11.10.2026 aus); Einkonto-Nutzer unbetroffen.

**Regressionstest:** AgentSessionSummarizer mit Spy-Generator: Session mit claudeProfileName='ai2'; erwartet, dass der Runner ein Environment mit CLAUDE_CONFIG_DIR=<ai2-Root> erhält (heute fehlt es).

**Zum Fix:** Einfachster Weg: ClaudeAccountProfiles.environmentOverrides(für Session-Profil) in den Runner-Aufruf geben; bei GPT-Sessions bewusst Claude/main belassen oder Summary überspringen, statt ein GPT-Backend in einen Hilfslauf zu ziehen.

### LR-AK-010 · : Automatische Zusammenfassungen erklären ihren zusätzlichen Datenabfluss nicht

*teilbestätigt · Finder P1! → Prüfer P2*

Fakten stimmen: Auto-Summary ist Default an, löst beim Anzeigen beendeter Chats einen zusätzlichen `claude -p`/`codex exec` mit Gesprächsauszug aus, und die Einstellungsbeschreibung nennt weder den Modellaufruf noch Kosten. Der Datenempfänger ist aber derselbe Anbieter, an den der Nutzer den Chat ohnehin schickt (das eigene Abo über die eigene CLI), also kein neuer Dritter; abschaltbar ist es per Toggle. Verletzt wird die DoD-Zeile 'erklärt' formal, nicht der Kern des Datenabfluss-Gedankens. Fix ist ein Textänderungs-/Default-Entscheid.

**Gegenstelle:** WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:124-127 — Toggle vorhanden; Empfänger = der Provider der Session (Claude→Anthropic, Codex→OpenAI).

**Regressionstest:** Kein sinnvoller Unit-Test; allenfalls Snapshot/Textprüfung der Settings-Zeile auf die Begriffe 'model call' und 'account'.

**Zum Fix:** Text anpassen genügt; Opt-in-Default ist eine Produktentscheidung (Kosten auf Abo), nicht zwingend.

### LR-AK-011 · : resumeScans umgeht Single-Flight und kann Account-Stempel zurücksetzen

*teilbestätigt · Finder P1! → Prüfer P2*

Der Code stimmt: resumeScans ruft startScan direkt auf, auch bei inFlight=true; danach setzt der ältere Scan inFlight=false, während der neue noch läuft, und beide mergen/speichern den Index-Cache. Für den Stempel-Rollback muss Scan A (früher gestartet, alte Roots) NACH Scan B committen, was bei gleichem Arbeitsumfang unwahrscheinlich ist; zudem ist die Stempel-Selbstheilung im Merge selbst die Korrektur, und der nächste Foreground-/FS-Scan stellt den Stempel nach spätestens ~30 s wieder her. Betrifft nur Kontoumzug (Erweitert) im Fenster eines laufenden Scans; kein Datenverlust, das Transcript liegt an der richtigen Stelle.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentSessionStore.swift:1127-1135 — Selbstheilung nimmt den von der Platte beobachteten Ablageort; AgentScanCoordinator.swift:71-76 dokumentiert, dass der abschließende accountMove-Scan das Ergebnis eines laufenden Scans korrigiert.

**Regressionstest:** AgentScanCoordinator-Test mit injizierbarem Scan-Runner: requestScan(.launch) hält Scan A offen, dann suspend/resume; erwartet genau einen laufenden Scan und danach einen Nachholscan. Heute starten zwei parallel.

**Zum Fix:** resumeScans über requestScan-Pfad (ohne Cooldown) führen ist einfach; Scan-Generation zum Verwerfen alter Snapshots ist größer als nötig.

### LR-AK-017 · [A3-01] Theme-Synchronisierung überschreibt konkurrierende Nutzereinstellungen

*teilbestätigt · Finder P0! → Prüfer P2*

Der Read-Modify-Write auf ~/.claude/settings.json ist real nicht transaktional, aber das Fenster liegt zwischen Data(contentsOf:) und replaceItemAt, also Millisekunden. Es wird nur bei einem Theme-Wechsel (debounced, 0,5 s) oder beim Start geöffnet und auch nur, wenn die CLI exakt in diesem Fenster settings.json schreibt. Parse-Fehler (Mid-Write) werden abgefangen, und es gibt ein Einmal-Backup. Das Risiko ist bekannt und im Dateikopf dokumentiert, Datenverlust ist theoretisch und selten. Ein Launch-Blocker ist es nicht. Das eigentliche Launch-Thema ist eher, dass die App überhaupt in die globale Fremddatei schreibt (W7, keine Fremdänderungen in ~/.claude), nicht dieses Rennen.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:100-111 (Parse-Fehler-Guard, Idempotenz-Check, Backup) und Dateikopf Zeile 12-17 dokumentieren das fehlende Claude-Locking ausdrücklich.

**Regressionstest:** ClaudeThemeWriterTests mit tmp-URL: Hook zwischen Read und Replace (Test-Seam) schreibt zusätzlich einen permissions-Key; erwartet, dass nach performWrite beide Keys vorhanden sind. Heute schlägt das fehl, ein Seam existiert aber nicht und müsste ergänzt werden.

**Zum Fix:** Der Vorschlag, das Theme als session-spezifisches Settings-Fragment über --settings zu transportieren, ist sinnvoll, weil er auch Fremdänderungen in ~/.claude vermeidet. Er muss aber prüfen, dass Claude das theme-Feld aus Flag-Settings tatsächlich auswertet. Eine billigere Zwischenlösung ist, direkt vor dem Replace mtime und Größe erneut zu prüfen und bei Abweichung neu zu lesen.

### LR-AK-018 · [A3-02] Queue bestätigt Aufträge und Reservierungen trotz fehlgeschlagener Persistenz

*teilbestätigt · Finder P0! → Prüfer P2*

Code-Befund stimmt: persist() und read() verschlucken alle Fehler (try?), enqueue/reserveNext melden trotzdem Erfolg. Auslöser sind aber nur volle Platte oder nicht beschreibbares Application-Support-Verzeichnis (dann ist die ganze App, inkl. Workspace-Persistenz, ohnehin kaputt) bzw. eine korrupte Queue-Datei. Korruption ist durch atomare Writes unwahrscheinlich, und QueuedPrompt hat einen toleranten Decode (fehlende Felder älterer Fassungen). Das Doppelzustell-Szenario braucht zusätzlich einen Absturz: markDelivered folgt synchron im selben MainActor-Block auf sendPrompt, das delivering-Fenster ist winzig, und scheitert delivering-Persist, scheitert auch markDelivered. Kein realistischer Datenverlust-Pfad in normalem Betrieb, kein P0 und kein Nutzerweg W1–W7 verletzt.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentPromptQueue.swift:60 (toleranter Decode verhindert Verwerfen der Queue bei Schemaänderung); AgentPromptQueueDelivery.swift:78-80 (markDelivered unmittelbar nach sendPrompt)

**Regressionstest:** AgentPromptQueueTests: Store mit fileURL in nicht beschreibbarem Verzeichnis (chmod 0500 temp dir) anlegen; enqueue darf nicht stillschweigend Erfolg melden (Rückgabe/Fehlerzustand). Zweiter Test: Queue-Datei mit ungültigem JSON, reconcileOnLaunch darf die Datei nicht mit [] überschreiben (Backup vorhanden).

**Zum Fix:** Fix des Finders ist vertretbar, aber niedrige Priorität; bei Decode-Fehler Original sichern statt [] zurückzuschreiben ist der einzige Teil mit echtem Datenverlust-Potenzial.

### LR-AK-019 · [A3-04] Nach externer ID-Umbindung beobachtet der Watcher weiterhin das alte Transcript

*bestätigt · Finder P1! → Prüfer P2*

Der Mechanismus ist real: watch() behält bei vorhandener transcriptURL die alte URL und ruft bei geänderter externer ID weder Cache-Reset noch Event-Source-Rebind auf; der saubere Pfad setExternalSessionID im Watcher hat keinen Aufrufer (nur Definition). Der Coordinator ruft nach /clear bzw. /resume-Rebind attachWatch -> watch. Folge: Fallback-Status, Aktivitätszeile, Abort-mtime und Heilung lesen die alte Datei. Die primäre Statusquelle sind aber Hooks (hook-live), das Transcript ist Fallback; relevant wird es vor allem beim stillen Netz (Decider-idle der alten Datei + working + >180 s ohne Hook-Event -> falsches turnAborted bei langem stillen Tool-Lauf) und bei veralteter Stand-Zeile. Das ist eine echte Korrektheitslücke nach /clear, aber ein Sekundärpfad ohne Datenverlust; P2 statt P1, kein Launch-Blocker.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:405 (Hook-Status hat Vorrang, Transcript nur Fallback)

**Regressionstest:** AgentSessionRuntimeWatcherTests mit injiziertem urlResolver/statProvider: watch(local, extID A) -> URL A aufgelöst; erneut watch(local, extID B) mit Resolver, der für B eine andere URL liefert; erwartet: Watcher-Eintrag zeigt URL B und gelöschte Caches. Heute bleibt URL A.

**Zum Fix:** Fix ist klein und passt: in watch() bei geänderter externalSessionID die Rebind-Logik von setExternalSessionID nutzen (URL neu auflösen, lastStat/cachedLastEvent/cachedActivity nullen, Event-Source neu anhängen, generation erhöhen).

### LR-AK-020 · [A3-05] Ignorierte Background-Forks verändern trotzdem den Vordergrundstatus

*teilbestätigt · Finder P1! → Prüfer P2*

Technisch korrekt: Bei .ignoreFork wird die ID nur nicht gebunden. Direkt danach läuft handleHookEvent weiter bis apply(signal, to: localID) ohne ID-Filter, und der Test in AgentSessionStatusCoordinatorTests:173-181 sendet Fork-Prompt und Fork-Stop durch, prüft aber nur die Bindung, nicht den Status. Ein Fork-Stop kann also turnCompleted auslösen (Sound, Notification, Queue-Zustellung an die PTY des Vordergrunds). Der Normalfall ist aber /background: Dort wird der Vordergrund gerade zur leeren Session, und der Fork-Turn kann den Status nur flackern lassen, nicht einen echten laufenden Turn überschreiben. Betroffen ist das Erweiterte Feature F-AC-11, es führt zu einer falschen Statusanzeige und im ungünstigen Fall zu einer verfrühten Queue-Zustellung. Das ist kein Datenverlust und kein Kern-Hänger, und es greift nur mit parallelem bg-Fork und Vordergrund. Kein Launch-Blocker.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:729-735 merkt sich Fork-IDs bereits in forkExternalIDs, der Status-Pfad (Zeile 330-355) nutzt diese Menge aber nicht. Ein Fremd-ID-Filter fehlt, aber die Status-Heilung nach 180 s (CLAUDE.md, working-Stau-Heilung) fängt hängende Fehlzustände ab.

**Regressionstest:** AgentSessionStatusCoordinatorTests: Vordergrund-ID 'A' gebunden, Status working per userPromptSubmit(A). sessionStart('F', source: fork) dann hookEvent(.stop, sessionID: 'F'). Erwartet: states[sessionID] bleibt working, kein Sound/Notification und kein AgentPromptQueueDelivery-Aufruf. Heute geht der Status auf idle und der Effekt feuert.

**Zum Fix:** Der Filter darf nur Events ignorierter Fork-IDs (forkExternalIDs[localID]) verwerfen. Events mit unbekannter oder nil-Session-ID müssen weiter durchgehen (Pending-Neubindung, Codex ohne ID), und der Fork-Status darf nicht verloren gehen, wenn der bg-Fork selbst als Session getrackt wird (isBackgroundSession).

### LR-AK-021 · [A3-06] Bereits gestarteter Chat ohne Bindung wird still als neuer Chat gestartet

*teilbestätigt · Finder P1! → Prüfer P2*

Der Zustand hasLaunchedInitialPrompt=true bei externalSessionID=nil führt tatsächlich ohne --resume zu einem frischen Start (Builder und Repair lassen ihn durch). Er ist aber auch der legitime Normalfall für einen Chat, der gestartet, aber nie beschrieben wurde: Claude legt vor dem ersten Prompt kein Transcript an, es gibt nichts zum Fortsetzen. Der vom Finder geforderte Abbruch würde diese Fälle fälschlich blockieren. Für den echten Fehlerfall (Hook-Bindung fällt aus) existiert zusätzlich der Indexer-basierte Fallback bindExternalSessionIDWhenAvailable sowie ClaudeExternalIDRecovery; ein Verlust erfordert, dass beides versagt. Damit selten, ohne harten Datenverlust (Transcript bleibt auf Disk), kein Nutzerweg verletzt.

**Gegenstelle:** WhisperM8/Views/AgentSessionDetailView.swift:632-640 (markLaunched ruft bindExternalSessionIDWhenAvailable als Zweitbindung); nie beschriebener Chat hat legitim keine ID

**Regressionstest:** AgentCommandBuilderTests: Session mit hasLaunchedInitialPrompt=true, externalSessionID=nil, aber vorhandenem Hook-Event-File mit SessionStart-ID und Transcript: Erwartung Binding-Reparatur bzw. --resume statt Frischstart; Gegentest ohne jedes Transcript bleibt Frischstart.

**Zum Fix:** Der vorgeschlagene harte Abbruch bei hasLaunched && ID nil ist riskant: er bricht den Normalfall 'Chat geöffnet, nie benutzt' und würde dort ständig Fehlermeldungen erzeugen. Nur abbrechen/warnen, wenn nachweislich ein Transcript zum Chat existiert (z. B. Event-File/Indexer-Treffer im ±Fenster) und die Bindung fehlt.

### LR-AK-022 · [A3-07] Background-Logs können den Prozessrunner am vollen Pipe-Puffer blockieren

*bestätigt · Finder P1 → Prüfer P2*

Der DefaultProcessRunner liest stdout/stderr erst im terminationHandler. Schreibt das Kind mehr als die Pipe-Kapazität (ca. 64 KiB), blockiert es und terminiert nie, bis der Timeout greift. Das ist ein echter Klassiker. Betroffen sind aber nur `claude logs` und eventuell stop/rm mit sehr viel Ausgabe, spawn schreibt nur eine Zeile. Folgen: Die Log-Ansicht eines langlaufenden Background-Agents schlägt mit Timeout fehl, und der Start-Health-Check (10 s) meldet .error. Der Health-Check lässt die Session bei .error bewusst in Ruhe, es gibt also keinen Folgeschaden. Das Feature ist Erweitert (F-AC-11), der Nutzer kommt nicht in Kern-Wege nicht weiter. P2, weil es kein Kern-Feature ist, aber echt reproduzierbar.

**Gegenstelle:** WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:131-160 klassifiziert Timeout/.error im Health-Check ohne Aufräumen der Session. Ob `claude logs` die volle Historie oder nur einen Tail ausgibt, konnte statisch nicht geklärt werden.

**Regressionstest:** BackgroundAgentSpawnerTests oder neuer DefaultProcessRunnerTests: run(executable: /bin/sh, arguments: [-c, 'head -c 300000 /dev/zero | tr \\0 a'], timeout: 5). Erwartet exitCode 0 und stdout.count == 300000. Heute läuft der Test in SpawnError.timedOut.

**Zum Fix:** Statt eines neuen Runners die vorhandene Drain-Technik aus AgentHeadlessCLI wiederverwenden (readabilityHandler oder asynchrones Lesen ab Start). Das Timeout mit terminate() muss erhalten bleiben und die echten claude-Kommandos dürfen nicht ersetzt werden.

### LR-AK-023 · [A3-08] Frühes Stop-Signal verhindert den späteren Codex-Start nicht

*teilbestätigt · Finder P1 → Prüfer P2*

Die Lücke existiert: requestStop setzt nur den Latch und runner.terminate ist No-op ohne Prozess; superviseCurrentTurn prüft den Latch vor dem Start nicht erneut, und zwischen process.run() und dem Setzen von self.process (lock) gibt es ein Mikrofenster. Das Zeitfenster (Preflight, Schema-Write, Git-Root-Auflösung, Prozessstart) liegt aber nur im Bereich weniger hundert Millisekunden nach dem Supervisor-Start, ein Stop müsste genau dann ankommen. Betrifft die Erweitert-Funktion Codex-Subagents (CLI whisperm8 agent), keine Kern-Nutzerwege; Folge ist ein ungewollt gelaufener Turn, kein Datenverlust im Kern.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-49 (requestStop terminiert, wenn Prozess läuft; nur sehr kleines Startfenster ungeschützt)

**Regressionstest:** AgentJobSupervisorTests mit Spy-Runner: requestStop() vor superviseCurrentTurn aufrufen; erwartet: Runner.run wird nie gestartet und Job endet als stopped. Heute läuft der Turn und endet done.

**Zum Fix:** Fix ist sinnvoll und klein (Latch vor runner.run prüfen und nach Prozess-Registrierung erneut prüfen); Report-Toleranz und echte CLI unverändert lassen.

### LR-AK-025 · [A3-11] Background-Task-Cache verwirft gültige Resets auf kleinere Transcripts

*bestätigt · Finder P1 → Prüfer P2*

updatedTracker verwirft einen frisch zurückgesetzten Tracker, sobald der gecachte einen größeren Offset hat (Zeile 'current.offset > tracker.offset'), ohne die Dateiidentität zu vergleichen. Nach /clear zeigt die Session auf ein neues, kleineres Transcript, der Tracker erkennt den Wechsel korrekt, wird aber verworfen. Der gecachte alte Tracker bleibt im Dictionary, das Problem bleibt bestehen, bis das neue Transcript den alten Offset überholt. Folge: neue Background-Tasks bleiben für den Kontowechsel unsichtbar, der Wechsel könnte einen Chat mit laufenden Tasks anhalten. Betroffen ist aber nur Erweitert (F-KO-02), es erfordert /clear (oder Transcript-Wechsel) bei großem Vorgänger-Transcript plus Background-Tasks plus Kontowechsel in diesem Zustand. Der Schaden ist ein beendeter Task, kein Datenverlust.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift:44-48 setzt bei Identitätswechsel oder size < offset korrekt zurück, der Fehler liegt allein im Merge im Monitor (Zeile 159-181). Tasks früherer Prozesse werden über startedAfter ausgeblendet, das mildert den Fall alter offener Tasks.

**Regressionstest:** ClaudeBackgroundTasksTests: gleiche sessionID, Datei A (groß, ohne Tasks) -> openTaskCount; danach Datei B (neue Inode, klein, mit einem offenen Task-Start-Marker) -> openTaskCount. Erwartet 1, heute 0 wegen des alten Trackers.

**Zum Fix:** Tracker um eine Generation/fileIdentity erweitern: parallelen Gewinner nur dann bevorzugen, wenn dieselbe fileIdentity vorliegt. Bei abweichender Identität gewinnt der neuere Tracker (der aktuelle Aufruf), nicht der größere Offset.

### LR-AK-026 · [A3-12] Send-Guard blockiert Erstzustellungen bei Token-I/O-Fehlern

*teilbestätigt · Finder P1! → Prüfer P2*

Der Code verhält sich wie beschrieben: stage loggt Fehler nur, consume liefert bei Verzeichnis-/Lesefehler false, ChatsPromptGuard.decide blockt dann einen Marker-Prompt mit Exit 2. Auslöser sind jedoch volle Platte oder defekte Verzeichnisrechte im Application-Support-Pfad, also ein Zustand, in dem die App ohnehin an vielen Stellen scheitert. Der Block ist harmlos behebbar (Hinweistext nennt 'chats send' erneut) und betrifft nur Prompts mit [via whisperm8 chats]-Marker (Jarvis/CLI-Send, Erweitert), nie normale Eingaben. Die kommentierte Designentscheidung 'Guard failt Richtung Block' ist beabsichtigt; der Widerspruch zur fail-open-Doku ist ein Dokumentations-/Randfall-Thema.

**Gegenstelle:** WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:80-82 (Kommentar: Fehler bewusst still, Guard failt Richtung Block der späteren Wiedervorlage)

**Regressionstest:** SendDeliveryTokenStoreTests: Store mit nicht lesbarem Token-Verzeichnis (chmod 000) -> consume muss einen unterscheidbaren I/O-Fehlerzustand liefern; ChatsPromptGuard.decide mit consumeToken-Fehler darf Erstzustellung nicht als Duplikat blocken (Verdict .allow).

**Zum Fix:** Dreistufiges Token-Lookup ist korrekt; bei I/O-Fehler fail-open wiegt aber gegen das Ziel des Guards (Doppel-Ausführung verhindern). Besser: stage-Fehler an Sender zurückgeben und Zustellung melden statt blind fail-open.

### LR-AK-028 · [A3-14] Codex-Exit 0 gilt auch ohne nachgewiesenes Turn-Ende als Erfolg

*teilbestätigt · Finder P1 → Prüfer P2*

mapOutcome liefert bei exitCode 0 ohne turn.failed, threadID und lastMessage tatsächlich .done; ein expliziter Beleg für turn.completed wird nicht verlangt. Das Szenario setzt aber einen Wrapper bzw. inkompatiblen Codex-Lauf voraus, der mit Exit 0 endet, ohne irgendein Event zu erzeugen; die echte codex-CLI liefert bei Fehlern Exit != 0 oder turn.failed, was beides abgefangen wird. Die Toleranz bei nicht parsebarem Report ist dokumentiert beabsichtigt. Hardening-Punkt für Erweitert-Funktion (Subagents), kein realer Auslöser mit der unterstützten CLI.

**Gegenstelle:** WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:109-111 (Kommentar: Report-Toleranz bewusst, Turn war erfolgreich)

**Regressionstest:** CodexTurnExecutorTests: mapOutcome(result: CodexTurnResult(exitCode: 0, threadID: nil, lastMessage: nil, stderrTail: "", turnFailedMessage: nil, stalled: false)) erwartet .failed (heute .done).

**Zum Fix:** Fix sinnvoll, aber vorsichtig: Completion-Nachweis nur verlangen, wenn die Eventstream überhaupt Events lieferte oder threadID/lastMessage fehlen; ältere codex-Versionen ohne turn.completed-Event sonst nicht fälschlich als failed einstufen (Kompatibilität prüfen).

### LR-AK-031 · Job-State-Korrektur und PID-Nachtrag überschreiben neuere Zustände

*teilbestätigt · Finder P1 → Prüfer P2*

Beide Lücken existieren. correctIfOrphaned schreibt per writeState ohne Re-Read oder Lock ein 'failed' zurück (AgentJobStore:285-305), und der PID-Nachtrag in SubagentJobDetailView:491-496 läuft per mutateState außerhalb von withExclusiveLock. Die Zeitfenster sind aber sehr klein. Beim Korrekturpfad liegen nur readState, Liveness-Probe und Write dazwischen, der Supervisor müsste exakt dort 'done' schreiben und exiten. Beim PID-Nachtrag gewinnt normalerweise der Parent, weil der Kindprozess zuerst exec'en, Codex auflösen und den Lock nehmen muss. Folge wäre ein falsch angezeigter Jobstatus, kein Verlust von Daten oder des Reports. Subagent-Jobs sind 'Erweitert' (F-AC-12). P1 ist überhöht.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:77-87 nimmt den Lock für den running-Übergang mit der Begründung, den Parent-Nachtrag zu schützen. Der Parent-Nachtrag selbst ist aber ungelockt, also nur teilweise abgesichert.

**Regressionstest:** AgentJobStoreTests mit injiziertem livenessProbe: Zustand running mit toter PID anlegen. Die Probe-Closure schreibt als Nebeneffekt 'done' in state.json, danach ruft der Test readCorrected auf. Erwartet: Der Zustand bleibt done, weil die Korrektur unter Lock neu liest. Heute wird er zu failed überschrieben.

### LR-AU-001 · [A3-10] UI-Composer umgeht die gehärtete Supervisor-PID-Transaktion

*teilbestätigt · Finder P1 → Prüfer P2*

Der Unterschied ist belegt: die UI macht nach launchDetached ein ungelocktes mutateState mit supervisorPid, der CLI-Pfad (launchDetachedSupervisor) nimmt den Job-Lock und setzt die PID nur im State spawning. Ein Lost-Update ist theoretisch möglich, wenn der gerade gestartete Supervisor zwischen UI-Read und UI-Write seinen running-Übergang schreibt. Das Fenster ist winzig (Mikrosekunden des Read-Modify-Write direkt nach dem Rückkehr von launchDetached, während der Swift-Supervisor-Prozess erst hochfahren, Prompt konsumieren und Codex-Pfad auflösen muss, bevor er schreibt). Betrifft nur den Composer der Subagent-Detailansicht (Erweitert), die Folge wäre ein fälschlich als failed angezeigter Job.

**Gegenstelle:** Zeitreihenfolge: UI-mutateState läuft unmittelbar nach launchDetached-Rückkehr und gewinnt praktisch immer gegen den noch startenden Supervisor

**Regressionstest:** Statisch statt Race-Test: Refactoring-Test, dass UI und CLI denselben Helfer nutzen; funktional AgentJobStoreTests: job.state == .running, supervisorPid gesetzt -> die PID-Nachtragsfunktion darf state nicht auf spawning zurücksetzen.

**Zum Fix:** Fix (gemeinsamer launchDetachedSupervisor) ist richtig und risikoarm; Composer-Inhalt bei Fehler beibehalten.

### LR-BR-001 · : Brew-Zap lässt installierte Statuslines und fremde Konfigurationsänderungen zurück

*teilbestätigt · Finder P1! → Prüfer P2*

Der Cask-zap (update-cask.sh:46-50) löscht nur Application Support, Caches und Preferences; der automatisch angelegte Symlink ~/.local/bin/whisperm8 (CLISymlinkInstaller beim Start, für jeden Nutzer) bleibt als toter Link zurück, ebenso ggf. Statusline-Skripte/-Einträge, die nur nach bewusstem Klick in den Einstellungen existieren, und verschobene lose Skills (im Backup, der Nutzer kann sie dort zurückholen). Das verletzt formal W7 (keine Fremdänderungen in ~/.claude), ist aber nicht schadenträchtig: ein toter Symlink und weiterlaufende Nutzer-Statusline-Skripte, die der Nutzer selbst installiert hat. Kein Datenverlust, keine Sicherheitslücke. Das vorgeschlagene Ownership-/Restore-Journal (Aufwand L, Risiko hoch) steht in keinem Verhältnis.

**Gegenstelle:** scripts/update-cask.sh:46-50 (zap-Liste, kein Eintrag für ~/.local/bin/whisperm8); Statusline-Install nur manuell (CLISkillsSettingsPage.swift:553)

**Regressionstest:** Kein Swift-Test sinnvoll; Skript-/Cask-Test: generierte Cask-Datei per grep auf zap-Eintrag ~/.local/bin/whisperm8 (shell-Test in scripts/ oder CI-Lint). Manuell: brew install, App starten, brew uninstall --zap, danach ls -l ~/.local/bin/whisperm8 muss fehlen.

**Zum Fix:** Schlanke Lösung: ~/.local/bin/whisperm8 in die zap-trash-Liste (oder uninstall delete:) aufnehmen, ggf. W7-Formulierung auf 'ohne vom Nutzer nicht bewusst eingerichtete Änderungen' präzisieren und die Statusline-Reste in der Doku als bewusste Opt-in-Installation nennen. Kein Journal-System bauen; brew zap kann settings.json-Einträge ohnehin nicht sauber rückbauen.

### LR-BR-002 · Apple-App-Passwort wird als Prozessargument offengelegt

*teilbestätigt · Finder P0! → Prüfer P2*

Die Zeilen 109-115 in scripts/build-dmg.sh übergeben das App-Passwort tatsächlich per --password in argv, und ps zeigt argv auf macOS allen lokalen Nutzern. Der Pfad ist aber nur ein Fallback hinter --keychain-profile. Er läuft nur auf dem Maintainer-Rechner und nie in CI, und release.yml setzt weder DEVELOPER_ID_APPLICATION noch APPLE_*. Es gibt keinen Endnutzer-Datenabfluss und keine App-Laufzeit. Die DoD-Zeile 'Keine Secrets in argv' zielt auf die App und ihre Kindprozesse, nicht auf ein lokales Maintainer-Skript. Der Fix ist trivial: notarytool akzeptiert --password '@env:APPLE_APP_SPECIFIC_PASSWORD' oder @keychain:, ohne dass der Wert in argv landet. Die Einstufung P0 und Blocker ist stark überhöht.

**Gegenstelle:** scripts/build-dmg.sh:103-108 bietet --keychain-profile als bevorzugten Weg. .github/workflows/release.yml:55-56 ruft make dmg ohne jede Apple-Credential-Env auf.

**Zum Fix:** Kein Entfernen des Pfads nötig. Es reicht, --password auf '@env:APPLE_APP_SPECIFIC_PASSWORD' umzustellen (S). Ein erzwungenes Keychain-Profil ist die strengere Alternative, aber nicht zwingend.

### LR-BR-004 · Developer-ID-Build bricht am fehlenden Frameworks-Ordner ab

*bestätigt · Finder P1! → Prüfer P2*

Mit bash und 'set -euo pipefail' habe ich es nachgestellt: find auf einem fehlenden Verzeichnis liefert Status 1, und die Pipeline find | while bricht das Skript ab, sodass 'survived' nie erscheint. Das Makefile-_bundle legt kein Contents/Frameworks an, und SwiftPM bettet statisch ein. Der Developer-ID-Zweig würde also zuverlässig vor dem App-Signing abbrechen. Heute läuft der Zweig aber nirgends, weil weder CI noch ein dokumentierter Weg DEVELOPER_ID_APPLICATION setzt. Der Defekt ist ein Teilschritt von LR-BR-003 und kein eigener Nutzerweg-Bruch. Er fällt beim ersten Versuch sofort auf und lässt sich mit einem Einzeiler beheben. Ein Blocker ist er nur über BR-003.

**Gegenstelle:** scripts/build-dmg.sh:32 betritt den Zweig nur bei gesetztem DEVELOPER_ID_APPLICATION, das nirgends gesetzt wird.

**Regressionstest:** Shell-Test (bats oder XCTest mit Process): Eine Fake-.app ohne Contents/Frameworks, ein codesign-Stub im PATH und DEVELOPER_ID_APPLICATION=X. build-dmg.sh bis zum Signing laufen lassen (make build per Stub ersetzen). Erwartet: Exit 0 und genau ein codesign-Aufruf für das Bundle. Heute bricht es mit Exit 1 vor dem Aufruf ab.

**Zum Fix:** Fix des Finders passt ('[[ -d ... ]] &&' vor find oder 'find ... || true' nur für den Nicht-Existenz-Fall). '2>/dev/null' darf echte codesign-Fehler nicht verschlucken. Wenn man 'set +o pipefail' lokal setzt, werden Signierfehler in der while-Schleife sonst nicht mehr gemeldet. Die Fehlerprüfung deshalb in die Schleife legen.

### LR-BR-007 · Tag-Releases werden ohne Test-Gate veröffentlicht

*teilbestätigt · Finder P1! → Prüfer P2*

Die Lücke ist real. release.yml läuft nur bei Tag-Push, hat kein 'needs' und keinen Testschritt (nur make dmg, also swift build -c release), und ci.yml läuft nicht auf Tags. Ein Tag auf einem Commit mit kaputten Tests oder einem Fehler im Testtarget würde ausgeliefert. Der übliche Ablauf ist aber merge nach main, CI grün, dann Tag (frühere Releases liefen laut Notizen mit grünem CI). Ein Release-Bug entsteht erst durch den Prozessfehler 'taggen ohne CI'. Die DoD-Zeile 'swift test grün in CI' ist über main erfüllt. Das ist Release-Hygiene und kein Nutzerweg-Bruch. Die Kompilierung des Produkts wird im Tag-Job immerhin geprüft.

**Gegenstelle:** .github/workflows/ci.yml:10-13 läuft bei jedem Push auf main und bei PRs. Tags werden in der Praxis auf grünem main gesetzt, das aber nicht erzwungen wird.

**Regressionstest:** Kein Unit-Test. Workflow-Lint (actionlint) plus Prüfung: release.yml enthält einen Job mit 'swift test' oder 'uses: ./.github/workflows/ci.yml', und der Release-Job hat 'needs:' darauf.

**Zum Fix:** Vorschlag des Finders (Tests desselben SHA als Voraussetzung) ist richtig. Einfachste Variante: ci.yml mit 'workflow_call' versehen und im Release-Job per 'needs' einbinden. Die Tests laufen dann im Tag-Lauf doppelt (~Laufzeit), was bei seltenen Releases vertretbar ist.

### LR-BR-008 · Clean-Install beendet fremde Prozesse und kann sich selbst töten

*teilbestätigt · Finder P1 → Prüfer P2*

clean-install.sh:16-17 nutzt pkill -9 -f mit 'WhisperM8' und 'whisperm8' über alle argv. Bei absolutem Aufruf eines Pfads mit 'whisperm8' (z. B. /Users/.../repos/whisperm8/scripts/clean-install.sh) trifft das auch den eigenen bash-Elternprozess, pkill schließt nur sich selbst aus. Der Reset bricht dann bei Zeile 16 ab, bevor irgendetwas gelöscht wurde, was harmlos ist. Über 'make clean-install' (relatives ./scripts/...) greift der Selbsttreffer nicht, und der Make-Target hat _guard_chat. Realer Kollateralschaden: Es trifft Fremdprozesse mit dem Text in argv (Compiler, Editoren, whisperm8-agent-supervise-Jobs, Chat-CLI) mit SIGKILL ohne Flush, ohne Warnung. Das Skript ist aber ausdrücklich ein destruktiver Voll-Reset (Zeile 11) und wird vom Maintainer genutzt. Das Skript liegt nicht im Brew-Cask-Weg, der Hinweis in 'LIES MICH.txt' (build-dmg.sh:80) zeigt Endnutzern auf ein Skript, das sie gar nicht haben (ein separater Doku-Fehler).

**Gegenstelle:** Makefile:252-272 und 321 zeigen, dass 'make clean-install' vorab _guard_chat ausführt und das Skript relativ startet (./scripts/clean-install.sh). Der Selbsttreffer tritt nur beim Direktaufruf mit absolutem Pfad auf.

**Regressionstest:** Shell-Test: Ein Dummy-Prozess 'sleep 60 # whisperm8-testmarker' starten, das Skript mit absolutem Pfad in ein Verzeichnis mit 'whisperm8' im Namen kopieren und ausführen (rm/tccutil per PATH-Stubs). Erwartet: Der Dummy bleibt am Leben und das Skript läuft bis zum Ende durch. Heute wird der Dummy getötet und das Skript endet vorzeitig.

**Zum Fix:** Der Fix des Finders (präzise GUI_PIDS-Auswahl plus SIGTERM-Wartepfad aus dem Makefile) ist sinnvoll. Besser noch: zuerst 'make kill' bzw. dieselbe awk-Auswahl nutzen. Wichtig bleibt, dass supervisor-Prozesse (agent-supervise) ausgenommen werden, wie im Makefile. Die LIES-MICH-Zeile ersatzlos streichen oder auf 'brew reinstall' ändern.

### LR-DIK-001 · Beenden rettet laufende Diktate nicht

*teilbestätigt · Finder P0! → Prüfer P2*

Der Befund stimmt im Kern: applicationShouldTerminate (WhisperM8App.swift:428-441) antwortet sofort mit .terminateNow und tut nichts für eine laufende Aufnahme oder Transkription. Die M4A bleibt im temporaryDirectory (AudioRecorder.swift:133). Der Fall ist aber vom Nutzer selbst ausgelöst (Cmd+Q mitten im Diktat), keine stille Datenvernichtung. Beim Upload ist die Datei bereits fertig geschrieben und liegt noch einige Tage im tmp-Ordner; nur beim Beenden WÄHREND der Aufnahme ist sie wohl unvollständig. Der Datenverlust-Pfad für Fehler (preserveRecording) funktioniert wie dokumentiert. Ein Quit-Gate wäre eine sinnvolle Härtung, aber kein P0 und kein W1–W7-Verstoß.

**Gegenstelle:** WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:12-14 und FailedRecordingsStore.swift:23: Fehler- und Abbruchpfade sichern die Aufnahme bereits dauerhaft; nur der harte Quit ist nicht abgedeckt.

**Regressionstest:** RecordingCoordinator-Test mit injiziertem FailedRecordingsStore: Aufnahme/Transkription im Zustand 'in flight' simulieren, dann die neue Quit-Vorbereitung (z. B. coordinator.prepareForTermination()) aufrufen; erwartet: Audio liegt im FailedRecordings-Ordner mit Sidecar. Heute existiert dieser Einstieg nicht.

**Zum Fix:** Ein asynchrones .terminateLater-Gate ist riskant (verzögert Quit, SIGTERM von make dev, Crash-Marker-Reihenfolge). Besser schlank: beim Quit nur synchron die laufende Datei finalisieren und in den Store verschieben, kein Warten auf Netzwerk.

### LR-DIK-002 · Ein inkompatibler Modus führt zum Überschreiben aller Custom-Modi

*teilbestätigt · Finder P0! → Prüfer P2*

Mechanik stimmt: loadModes() dekodiert [OutputMode] kollektiv, ein einziger nicht dekodierbarer Eintrag liefert [] (nur Logger.debug), modes fällt auf Built-ins zurück, und jedes spätere saveModes (addMode, updateMode, setDefault) überschreibt die Originaldatei ohne Backup. Der Auslöser ist aber eng: nötig ist ein unbekannter Enum-Wert (Kind, ContextCapturePolicy, ProjectAccessPolicy) oder ein fehlendes Pflichtfeld, also Downgrade oder Handedit. W6 (Update) läuft vorwärts und Migrationen sind additiv per decodeIfPresent. Custom-Modi sind Erweitert. Das ist eine reale Fragilität mit billigem Fix, aber kein realistischer P0 und keine W1–W7-Verletzung.

**Gegenstelle:** WhisperM8/Models/OutputMode.swift:98-117: Optionale Felder werden per decodeIfPresent mit Defaults migriert. Nur Pflichtfelder und Enum-Werte können den Decode scheitern lassen.

**Regressionstest:** OutputModeCompatTests: temporäre OutputModes.json mit zwei gültigen Custom-Modi und einem Eintrag mit kind="futureKind" schreiben, OutputModeStore(fileURL:).modes laden, dann saveModes(modes) aufrufen. Erwartet: die zwei Custom-Modi bleiben erhalten oder die Originaldatei wird vorher als Backup gesichert. Heute schlägt das fehl, weil nur Built-ins zurückkommen und die Datei überschrieben wird.

**Zum Fix:** Einträge einzeln und tolerant dekodieren (unbekannte Einträge als Rohdaten durchreichen) und vor dem ersten Überschreiben nach einem Ladefehler ein .bak anlegen. Normalisierung und Built-in-Migrationen nicht aufweichen.

### LR-DIK-004 · Recorderfehler beim Gerätewechsel umgehen die Aufnahmerettung

*teilbestätigt · Finder P1! → Prüfer P2*

Der Code-Pfad ist echt: handleConfigurationChange setzt bei ungültigem Format nach 5x100 ms und bei Engine-Restart-Fehler isRecording=false, während AppState.isRecording true bleibt. stopRecording() liefert dann wegen des Guards nil, der Coordinator zeigt „No audio file was created“, und die bereits geschriebene Teilaufnahme liegt unerreichbar im tmp-Verzeichnis. Beim Tap-Reinstall-Fehler bleibt isRecording true, aber ohne Tap. Auslöser ist ein Gerätewechsel mit dauerhaft ungültigem Format (Gerät abgezogen, Bluetooth-Profilwechsel scheitert) und damit seltener Randfall. Der Nutzer verliert ein Diktat und kann es neu sprechen. Das ist kein Absturz, kein stiller Datenverlust über Neustarts und blockiert keinen Nutzerweg. Die Meldung ist irreführend, deshalb P2 statt P3.

**Gegenstelle:** WhisperM8/Services/Dictation/AudioRecorder.swift:271-272 und :346-371: Der Pfad fängt den Fall als Log und sauberen Stopp ab, nur ohne Rückmeldung an den Coordinator.

**Regressionstest:** AudioRecorder hat keine DI für die Engine, daher Extraktion nötig. Unit-Test auf einer Zustandsmaschine mit Closure-Hooks: nach simuliertem Format-Fehler muss stopRecording() die Teil-URL liefern oder ein Coordinator-Callback feuern. Heute liefert stopRecording() nil.

**Zum Fix:** Fix des Finders ist sinnvoll. ObjC-Tap-Schutz (ObjCException.catching) und die Bluetooth-Stabilisierung beibehalten.

### LR-DIK-005 · Veraltete Gerätewechsel-Tasks starten nach Stop erneut

*teilbestätigt · Finder P1! → Prüfer P2*

handleConfigurationChange (AudioRecorder.swift:~268-374) hält die lokale Engine über den 300-ms-Sleep (und die Format-Retries) und prüft danach weder isRecording noch die Engine-Identität. Stoppt der Nutzer in dem Fenster, installiert und startet die alte Engine trotzdem; da stopRecording audioFile/converter schon auf nil gesetzt hat, schreibt sie nichts. Die lokale Engine wird nach Funktionsende freigegeben und damit gestoppt, der Effekt ist also kurz. Schädlich ist nur Stop plus sofortiger Neustart innerhalb dieses Fensters (Converter/Flags des neuen Laufs werden überschrieben). Das braucht einen Gerätewechsel (Bluetooth) und exakt getimtes Stoppen. Echte Race, aber schmal und ohne Absturz oder Verlust.

**Gegenstelle:** WhisperM8/Services/Dictation/AudioRecorder.swift:~330: der Guard am Funktionsanfang greift nur VOR dem Sleep. Gegenstelle ist, dass nach stopRecording audioFile == nil ist und die alte Engine ins Leere schreibt.

**Regressionstest:** AudioRecorder-Test mit injizierbarem Engine-/Sleep-Seam: handleConfigurationChange starten, während des Sleeps stopRecording (und ggf. startRecording) aufrufen; erwartet: kein installTap/start auf der alten Engine und keine Änderung an converter/isRestarting des neuen Laufs. Der Recorder ist heute nicht injizierbar, der Test setzt einen kleinen Seam voraus.

**Zum Fix:** Task speichern und bei Stop abbrechen, plus Generationszähler nach jedem await prüfen, ist richtig und risikoarm.

### LR-DIK-006 · Schreibfehler während der Aufnahme bleiben unsichtbar

*teilbestätigt · Finder P1! → Prüfer P2*

Der Catch in writeBuffer loggt nach dem ersten erfolgreichen Buffer nichts mehr und meldet nie an den Coordinator; auch Converter-Statusfehler werden still verworfen. Auslöser ist aber ein volles Laufwerk oder ein Schreibfehler mitten in der Aufnahme. M4A mit 16 kHz mono ist winzig (etwa 1 MB pro Minute), ein realistischer Auslöser fehlt also fast völlig. Folge wäre ein verkürztes Diktat ohne Hinweis, kein Absturz und kein Verlust bestehender Daten.

**Gegenstelle:** WhisperM8/Services/Dictation/AudioRecorder.swift:531-535: Der Catch loggt bei buffersWritten==0, der Startfehler ist also abgedeckt. Für den Mid-Recording-Fall gibt es nur keine Eskalation.

**Regressionstest:** Nur mit einer Writer-Abstraktion testbar: AudioRecorder bekommt einen injizierbaren Schreib-Closure, der nach N Buffern wirft. Erwartet: ein onWriteFailure-Callback feuert genau einmal. Heute gibt es den Callback nicht.

**Zum Fix:** Der Audio-Callback darf nur ein Flag setzen und die UI-Eskalation asynchron auf Main auslösen, wie der Finder schon schreibt.

### LR-DIK-007 · Auto-Paste prüft weder Ziel-Fenster noch erfolgreichen Fokuswechsel

*teilbestätigt · Finder P1! → Prüfer P2*

Der Code stimmt mit der Beschreibung überein: PasteService merkt nur NSRunningApplication (RecordingPanel.swift:442-444), aktiviert sie, wartet höchstens 1 s und pastet danach 'anyway' (PasteService.swift:126-143). Das ist aber die bewusste Diktat-Semantik (Text kommt in die vorher aktive App), und der Text liegt zusätzlich immer in der Zwischenablage (RecordingCoordinator+Transcription.swift: copyToClipboard vor dem Paste). Ein Fenster-/Gesprächswechsel innerhalb derselben App während der Verarbeitung ist ein Randfall, bei dem der Text eher dort landet, wo der Nutzer gerade ist. Echtes Restrisiko: scheitert die Aktivierung (App beendet, Fokus anderswo), geht Cmd+V an die zufällige Frontmost-App. Das ist ein Korrektheits-/UX-Thema, kein Datenverlust.

**Gegenstelle:** WhisperM8/Services/Dictation/PasteService.swift:110-143: Aktivierung der Ziel-App plus Timeout-Fallback ist bewusstes Verhalten; Text bleibt per copyToClipboard in der Zwischenablage (Transcription.swift ~Z.103).

**Regressionstest:** PasteService mit injizierbarem frontmost-Provider: Aktivierung scheitert (frontmost != targetApp nach Timeout); erwartet: kein postPasteEvent, onMissingTarget wird gerufen, Text nur in der Zwischenablage. Heute wird trotzdem gepastet.

**Zum Fix:** Die Fix-Variante 'Fenster/Eingabeelement erfassen und vor jedem Paste validieren' (Schwere L) ist überdimensioniert und riskant (AX-Zugriff, Apps ohne AX). Sinnvoll ist nur: nach Aktivierungs-Timeout nicht pasten, sondern per Hinweis auf die Zwischenablage verweisen.

### LR-DIK-009 · Entfernte Screen-Clips behalten ihre versendbaren Einzelbilder

*bestätigt · Finder P1! → Prüfer P2*

removeAttachmentFromContext(id:) entfernt nur das eine Element mit dieser ID. Beim Entfernen eines Screen-Clips bleiben die aus ihm erzeugten visualFrames im Bundle (Context.swift:198-210; Clipboard.swift:34-36 hängt sie getrennt an). visualAttachments schließt visualFrames ein (TranscriptContextBundle.swift:106) und CodexVisualInputSelection/VisualAttachmentDeliveryBuilder liefern sie weiter aus. Das Chip-Segment zeigt Frames bewusst nicht (OverlayPhase.swift:142), kann also 'No Ctx' anzeigen, obwohl Bilder rausgehen. Mildernd: Das Overlay-Menü 'Visuals (N)' listet jeden Frame einzeln und erlaubt das Entfernen (RecordingOverlayView.swift:126-131), und die Frames sind keine versteckten Daten. Es bleibt aber eine Diskrepanz zwischen Anzeige und Datenabfluss, weshalb es Privacy-relevant ist; P2 wegen der sichtbaren Umgehung.

**Gegenstelle:** WhisperM8/Views/RecordingOverlayView.swift:126-131: alle Frames erscheinen einzeln im Menü 'Visuals (N)' und sind separat entfernbar.

**Regressionstest:** RecordingCoordinatorClipboardTests: Bundle mit einem Clip und 3 visualFrames (Clip-ID verknüpft) aufbauen, removeAttachmentFromContext(id: clip.id) aufrufen; erwartet: visualFrames leer und visualAttachments leer. Heute bleiben die 3 Frames. Setzt eine Clip-ID-Verknüpfung in ContextAttachment voraus.

**Zum Fix:** Verknüpfung per Clip-ID ist richtig; unabhängige Screenshots dürfen nicht mitgelöscht werden. Alternativ den Chip ehrlich machen (Frames mitzählen).

### LR-DIK-010 · Ein startender Screen-Clip kann den Diktatabbruch überleben

*teilbestätigt · Finder P1! → Prüfer P2*

Die Lücke existiert: startScreenClip setzt activeClipSession erst nach den awaits makeCaptureTarget und ManualScreenClipSession.start. cancelRecording() ruft cancelActiveClip() als Task und findet in diesem Fenster nichts. Danach wird die Session gespeichert und isScreenClipRecording=true gesetzt, obwohl isRecording false ist. Das Zeitlimit prüft appState.isRecording und tut nichts. Das Fenster ist nur der Start von ScreenCaptureKit (grob 100–500 ms), und der Nutzer muss genau dann abbrechen oder stoppen. macOS zeigt zudem den Aufnahme-Indikator, es ist also nicht völlig unsichtbar. Folge: Aufnahme läuft bis App-Ende, nächster Clip scheitert mit alreadyRecording. Enger Zeitfehler, daher P2.

**Gegenstelle:** WhisperM8/Services/Dictation/VisualContextCaptureService.swift:136-139: Ohne Screen-Recording-Berechtigung bricht der Start sofort ab (vor allen awaits), ein langes Wartefenster durch den Rechtedialog entfällt.

**Regressionstest:** VisualContextCaptureService mit Fake-ScreenClipCapturing und verzögertem Start-Closure (Seam fehlt noch). startScreenClip als Task starten, währenddessen cancelActiveClip() aufrufen, dann den Start freigeben. Erwartet: Session gestoppt und activeClipSession nil. Heute bleibt sie aktiv.

**Zum Fix:** Eine Generationszahl pro Aufnahme einführen, nach dem await prüfen, ob sie noch gilt, sonst session.cancel(). Das harte Zeitlimit zusätzlich unabhängig von appState.isRecording machen.

### LR-DIK-011 · Später Kontext wird verarbeitet, aber nicht zugestellt oder archiviert

*teilbestätigt · Finder P1! → Prüfer P2*

Die Asymmetrie ist real: processTranscriptIfNeeded liest bewusst das Live-Bundle (Transcription.swift:168-175, Kommentar nennt das als Absicht), Anhangszustellung (deliveryAttachments aus dem eingefrorenen contextBundle, Z.77-82), Report und cleanup (Z.124-151) nutzen weiter das eingefrorene. Ein während der Transkription kopierter Screenshot fließt in den Prompt, wird aber nicht mitgepastet, nicht im Report geführt und nicht per cleanup entfernt (Temp-Datei bleibt liegen). Das betrifft nur Nachbearbeitungs-Modi und nur Kopien WÄHREND der Verarbeitung. Folge: abweichende Zustellung/Report und ein Temp-Leck, aber kein Absturz, Verlust oder P1-Funktionsausfall.

**Gegenstelle:** WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:168-175: Die Verwendung des Live-Bundles im Prompt ist dokumentierte Absicht ('Kopien WÄHREND der Transkription fließen noch in den Prompt ein').

**Regressionstest:** RecordingCoordinatorTranscriptionTests: appState.contextBundle während der (gefakten) Transkription um einen Screenshot erweitern, Output-Modus mit Nachbearbeitung und Auto-Paste; erwartet: deliveryAttachments, Report-Attachments und cleanup enthalten denselben effektiven Snapshot wie der Prompt. Heute fehlt der späte Screenshot in allen drei.

**Zum Fix:** Ein einziger effektiver Snapshot vor dem Modellaufruf, durchgereicht an Zustellung/Report/Cleanup, ist korrekt.

### LR-DIK-012 · Gesicherte Aufnahmen haben keinen später erreichbaren Retry-Weg

*teilbestätigt · Finder P1! → Prüfer P2*

Stimmt faktisch: pendingRetry ist reiner Coordinator-Speicher, retryPendingTranscription wird nur aus dem NSAlert-Button aufgerufen, und es gibt keine UI zum Listen oder Wiederholen von FailedRecordings. Die Aufnahme wird aber nie gelöscht und liegt in Application Support, der Datenverlust-Schutz greift also. Nach dem ESC-Abbruch ist sie absichtlich still gesichert. Es fehlt eine Komfortfunktion, kein Defekt. Der Nutzer diktiert im schlechtesten Fall neu. Der Alert bietet Retry sofort an. P1/Blocker nicht haltbar, eher Feature-Wunsch.

**Gegenstelle:** WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:31-38,97-109: Der Alert bietet Retry sofort an, die Aufnahme wird in jedem Fall zuerst gesichert (preserveRecording).

**Regressionstest:** Kein Regressionstest, da fehlende Funktion. Falls umgesetzt: Test, dass FailedRecordingsStore Sidecar-Metadaten (Modus, Sprache) persistiert und nach Neuinstanziierung eine Liste mit Retry-Eintrag liefert.

**Zum Fix:** Vorschlag vertretbar, aber Scope-Erweiterung statt Bugfix. Zunächst reicht ein Menüleisten-Eintrag Letzte Aufnahme erneut transkribieren.

### LR-DIK-013 · Hängende Codex-Nachbearbeitung hat keine Abschlussgarantie

*teilbestätigt · Finder P1! → Prüfer P2*

performCodexRun (CodexPostProcessor.swift:~98-134) ruft process.waitUntilExit() ohne Deadline; CodexProcessRegistry.cancel() (CodexSupport.swift:30-39) sendet nur terminate() ohne KILL-Eskalation. Der Befund über das fehlende Zeitlimit stimmt. Das Szenario setzt aber einen Codex-Prozess voraus, der SIGTERM ignoriert; ein normal hängender Codex (z. B. Netzproblem) wird vom Cancel-Button per SIGTERM beendet, danach fällt der Coordinator auf Raw zurück. Der Nutzer ist also nicht dauerhaft blockiert, solange er abbricht; ein Timeout wäre eine sinnvolle Härtung, aber der beschriebene Dauer-Blocker ist unwahrscheinlich.

**Gegenstelle:** WhisperM8/Services/Dictation/RecordingCoordinator.swift:~358: cancelPostProcessing() terminiert den Prozess; die Raw-Fallback-Logik greift danach.

**Regressionstest:** CodexPostProcessor-Test mit injiziertem Prozess-Runner/Fake-Skript (sleep 600, ignoriert SIGTERM) und kurzer Deadline; erwartet: Fehler 'timeout' nach Deadline, Prozess beendet (KILL), isProcessing frei. Heute hängt der Lauf unbegrenzt.

**Zum Fix:** Deadline plus TERM→KILL ist richtig; Deadline großzügig wählen (Task-Modus mit Projektzugriff läuft legitim lange), sonst bricht man gültige lange Läufe ab.

### LR-DIK-020 · Doppelte Output-Mode-IDs beenden die App weiterhin per Trap

*teilbestätigt · Finder P0! → Prüfer P2*

Der Trap ist real: normalized() baut Dictionary(uniqueKeysWithValues:) über die geladenen Modi (OutputModeStore:162), und doppelte IDs lösen eine Precondition aus. Die App selbst erzeugt aber keine doppelten IDs: Custom-Modi haben UUID-IDs (createCustomMode), saveModes läuft ebenfalls durch normalized, und die Datei wird atomar geschrieben. Auslösen kann das nur eine handbearbeitete, synchronisierte oder fremd zusammengeführte OutputModes.json. Das ist ein unplausibler Auslöser für die Zielgruppe. Die Auswirkung wäre allerdings ein Crash-Loop bei jedem Start, deshalb liegt die Schwere über P3. P0 ist nicht haltbar, weil kein realistischer Auslöser existiert. Billiger Fix, deshalb unbedingt mitnehmen.

**Gegenstelle:** WhisperM8/Services/Dictation/OutputModeStore.swift:97-107 erzeugt per UUID eindeutige IDs. WhisperM8/Services/Dictation/OutputModeStore.swift:128-136 fängt Decode-Fehler ab, aber keine Duplikate nach erfolgreichem Decode.

**Regressionstest:** OutputModeStoreTests mit temporärer Datei: JSON mit zwei Einträgen derselben Custom-ID und zwei mit derselben Built-in-ID schreiben. Erwartet: store.modes liefert deterministisch dedupliziert ohne Crash, und die Built-in-Reihenfolge bleibt erhalten. Heute beendet der Test den Prozess per Precondition.

### LR-DOK-004 · Das Handbuch empfiehlt vollständige Datenlöschung als normale Fehlerbehebung

*teilbestätigt · Finder P1! → Prüfer P2 · Launch-Blocker*

Die Aussage stimmt: USER_GUIDE.md und docs/README.md empfehlen als Quick Start git clone und make install und bei Problemen make clean-install. clean-install.sh löscht Keychain, Application Support (inklusive Workspace) und Einstellungen (scripts/clean-install.sh:55-75). Die Nennung der verlorenen Daten ist unvollständig. Der Schaden trifft aber nur, wer ein geklontes Repo hat. Die Zielgruppe installiert über Brew und hat kein Makefile. Der README im Repo-Root nennt Brew korrekt. Die eigentliche Schwere ist daher ein veralteter, widersprüchlicher Guide (W1 sagt Brew) und nicht ein realistischer Datenverlust. Als Datenverlust-Risiko P2, aber die Definition of Done verlangt einen Guide im Ist-Stand, und der ist hier verletzt. Der Blocker bleibt deshalb bestehen, gemeinsam mit LR-DOK-005 über eine Neufassung zu beheben.

**Gegenstelle:** README.md:45-59 beschreibt Brew als empfohlenen Weg. Der gefährliche Befehl setzt ein geklontes Repo mit Makefile voraus (docs/USER_GUIDE.md:16-22).

**Regressionstest:** Kein Swift-Test. Ein Doku-Lint im CI: Der USER_GUIDE darf weder 'make clean-install' noch 'git clone' im Quick-Start enthalten und muss 'brew install --cask rankm8/tap/whisperm8' nennen. Alternativ eine Prüfliste im Review.

**Zum Fix:** Der destruktive Entwickler-Reset selbst soll bleiben und nur als getrennte letzte Option im Handbuch erscheinen. Das ist im Vorschlag des Finders schon so gedacht.

### LR-DOK-005 · Das Anwenderhandbuch führt zu nicht mehr vorhandenen Einstellungsseiten

*bestätigt · Finder P1! → Prüfer P2 · Launch-Blocker*

SettingsPage kennt Recording, Transcription, AI Output, Context, Agent Chats, GPT-Backend, Accounts, Hooks, CLI, General, Permissions, About und Output (SettingsView:3-16). Der Guide verweist dagegen auf die Tabs API, Hotkey, Behavior und Audio (USER_GUIDE:88-105,150-180), die es nicht mehr gibt. Dazu fehlen Nutzungsprofile, Codex-Login und der erste Agent-Chat. Die Zeilen stimmen. Das ist reines Doku-Defizit ohne Funktionsfehler, die Wege W2 bis W4 sollen laut Definition ohne Doku funktionieren. Deshalb P2. Blocker bleibt, weil die Definition of Done ausdrücklich fordert, dass der User Guide den Ist-Stand beschreibt (Zeile 74-75).

**Gegenstelle:** Keine Gegenstelle. Der Guide trägt selbst das Datum 2026-07-09, und die Dokumentationslandkarte in docs/README.md verweist auf die Neuordnung, hat den Guide aber nicht angepasst.

**Regressionstest:** Kein Swift-Test. Ein CI-Skript vergleicht die in USER_GUIDE.md genannten Tab-Titel mit SettingsPage.title und schlägt bei unbekannten Namen fehl. Heute schlägt es für API, Hotkey, Behavior und Audio an.

**Zum Fix:** Das Handbuch soll geführte CLI-Installation erst beschreiben, wenn LR-ONB-003 umgesetzt ist, wie der Finder schon schreibt.

### LR-GPT-001 · Jeder lokale Benutzer kann GPT-Konten über den Router ohne Authentisierung benutzen

*teilbestätigt · Finder P0! → Prüfer P2*

Der Router bindet nur 127.0.0.1 und hat keine Client-Authentisierung, das stimmt. Der Angriff verlangt aber einen anderen lokalen macOS-Benutzer bzw. einen beliebigen Prozess; Prozesse desselben Users liegen ohnehin innerhalb der Vertrauensgrenze (sie lesen auch ~/.gpt-profiles). Es ist ein Labs-Feature, Default aus (claudeGPTBackendEnabled=false), und der Schaden ist Kontingentverbrauch, kein Secret-Leak: Tokens werden nicht ausgegeben. Der dokumentierte Upstream-Proxy (raine/claude-code-proxy) ist selbst ebenfalls ein unauthentisierter Loopback-Dienst, ein Bypass über die Direktports bliebe bestehen. Für Single-User-Macs der Zielgruppe nicht realistisch.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:250-254 (requiredLocalEndpoint 127.0.0.1) und AppPreferences claudeGPTBackendEnabled Default false (AppPreferences.swift ~266-270).

**Regressionstest:** Nur falls umgesetzt: MixRouter-Test mit Request ohne/mit falschem X-WhisperM8-Token erwartet 401 und ruft profileInstanceStarter nicht auf.

**Zum Fix:** Fix des Finders (Client-Auth vor Routing) würde alle bestehenden Claude-CLIs brechen, die nur ANTHROPIC_BASE_URL kennen, und die Proxy-Direktports bleiben offen; eher als bekannte Einschränkung dokumentieren (Labs, Single-User-Annahme) und höchstens per ANTHROPIC_CUSTOM_HEADERS-Token (Launch-zeitlich injiziert) nachrüsten.

### LR-GPT-002 · Eine nachgeahmte Health-Antwort genügt zur Übernahme sämtlicher GPT-Prompts

*teilbestätigt · Finder P0! → Prüfer P2*

Die Lücke existiert: isHealthyProbeResponse prüft nur 200 + JSON + {ok:true}, und ensureRunning überspringt den Start, sobald irgendein Listener das liefert. Voraussetzung ist ein feindlicher Prozess, der den konfigurierten Loopback-Port vor dem Proxy belegt – das ist ein anderer lokaler Benutzer auf einem Mehrbenutzer-Mac, oder Malware mit gleicher UID, die ohnehin ~/.claude und die Keychain erreicht. Es ist ein Labs-Feature (GPT-Backend, Opt-in); die Transkription ist ebenfalls Opt-in. Das bewusst im Terminal gestartete Proxys ('bleibt') erlaubte Verhalten verträgt sich nicht mit strikter Identitätsprüfung. Ein echtes Härtungsthema, aber weder P0 noch Launch-Blocker.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:1298-1301 – der Kommentar zeigt, dass die Probe schon von 'beliebiger Listener' auf eine spezifische /healthz-Signatur gehärtet wurde; das Vertrauensmodell ist 'lokaler Loopback gehört dem Benutzer'.

**Regressionstest:** ClaudeCodeProxyManagerTests: reachabilityResolver mit Fake-Listener, der {ok:true} liefert, aber eine fremde UID/ein anderes Programm hat; erwarten, dass ensureRunning ihn nicht als eigenen Proxy übernimmt (heute .success ohne Start). Setzt eine injizierbare Listener-Identitätsprüfung voraus.

**Zum Fix:** Der Fix (Prozessidentität/Benutzer + authentisierter Kanal) ist L und riskant: Extern gestartete Proxys müssen weiter funktionieren. Pragmatisch: PID/UID des Listeners per lsof mit der eigenen UID abgleichen und zusätzlich ein Instanz-Secret als Header oder Env prüfen, nur für selbst gestartete Instanzen.

### LR-GPT-003 · Hohe konfigurierte Proxyports bringen die gesamte App beim Profilstart zum Absturz

*bestätigt · Finder P0! → Prüfer P2*

Der Overflow ist real: AppPreferences.claudeGPTBackendPort akzeptiert jeden Wert > 0 (AppPreferences.swift:273-278), das Textfeld validiert nichts (GPTBackendSettingsPage:271), allocateProfilePort addiert +10 und isPortFree ruft UInt16(port) (ClaudeCodeProxyManager.swift:727-752) - bei Port >= 65526 ergibt sich >= 65536 und die App trappt. Auslöser ist aber, dass ein Nutzer bewusst einen Port nahe 65535 einträgt (Standard 18765) und zusätzlich GPT-Backend plus angemeldetes Zusatzprofil aktiviert; Labs, Default aus. Absturz ist grundsätzlich P0-Klasse, die Erreichbarkeit rechtfertigt aber nur P2; Fix ist trivial.

**Gegenstelle:** Kein Guard gefunden; einzig Erreichbarkeit schwach (nur selbst gewählte Extrem-Ports).

**Regressionstest:** ClaudeCodeProxyManagerTests: mainPortResolver = { 65530 }, portAvailabilityResolver NICHT überschreiben (Default isPortFree) und ensureRunning(profile:) bzw. allocateProfilePort aufrufen; erwartet Failure statt Trap. Zusätzlich direkt ClaudeCodeProxyManager.isPortFree(65536), (Int.max) -> false. Heute: Prozessabbruch.

**Zum Fix:** Fix des Finders ist richtig und klein (UInt16(exactly:), Obergrenze 65535 begrenzen, Eingabe auf 1024...65535 clampen). Auch der Router-/Main-Port ebenso validieren.

### LR-GPT-004 · Ein paralleler Start kann den Proxy nach Stop oder App-Quit weiterlaufen lassen

*teilbestätigt · Finder P1! → Prüfer P2*

Der Ablauf stimmt: stopIfSelfStarted liest selfStartedProcess ohne ensureLock. Ist ensureRunning noch vor dem Veröffentlichen des Handles (Binary-Installation, Launch) und wartet das abschließende stopAllProfileInstances auf ensureLock, dann veröffentlicht ensureRunning anschließend den main-Prozess, und stopAllProfileInstances stoppt nur Profilinstanzen. Der main-Proxy kann den Quit überleben. Das Fenster ist eng: Der Quit muss in den ersten Sekunden des ersten GPT-Starts fallen, oder während eines Binary-Downloads. Danach räumt der Waisen-Schutz die Waise beim nächsten App-Start auf (Binary älter/anderer Pfad), und das Feature ist Labs und standardmäßig aus. Der Proxy läuft dann ohne Nutzerdaten-Risiko weiter. W7 (zap-Deinstallation direkt nach so einem Quit) ist nur theoretisch verletzt. P2, kein Blocker.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:430 – replaceSelfStartedProcess(with: process) setzt den Handle direkt nach dem Launch; das Fenster liegt nur vor dem Launch (Binary-Auflösung/-Download) und bis dahin.

**Regressionstest:** ClaudeCodeProxyManagerTests: processLauncher blockiert über Semaphore; in einem zweiten Thread stopIfSelfStarted() aufrufen, dann den Launcher freigeben. Erwartet: der gestartete Fake-Handle wird terminiert (isRunning == false) und der Router gestoppt. Heute bleibt der Handle laufen.

**Zum Fix:** Der Fix des Finders (gemeinsame Lifecycle-Serialisierung mit Stop-Generation) ist größer als nötig. Minimal: stopIfSelfStarted/willTerminate nehmen zuerst ensureLock und stoppen danach den main-Handle und den Router. Achtung: willTerminate blockiert dann bis zum Ende eines laufenden Starts (max. einige Sekunden, bei Download länger), deshalb mit Timeout bzw. Abbruch-Flag für den Start.

### LR-GPT-005 · GPT-Hauptkonto wird auch bei weiterhin lebenden alten Proxys ausgetauscht

*teilbestätigt · Finder P1 → Prüfer P2*

Die Schleife in replaceMainGrant (ClaudeCodeProxyManager.swift:662-681) wartet höchstens retryAttempts*retryDelay (30*0.1 s = 3 s) und ruft danach unbedingt moveGrant, ohne isRunning erneut zu prüfen; das Finder-Szenario ist im Code korrekt beschrieben. Praktisch beendet sich ein Rust-Proxy auf SIGTERM in Millisekunden, hängende Prozesse sind eine seltene Ausnahme. Außerdem ist es Labs (GPT-Hauptkonto tauschen, Default aus) und ein Nutzer-ausgelöster, seltener Admin-Vorgang. Falls es eintritt, ist das Ergebnis eine Konto-Inkonsistenz, kein Verlust von Nutzerdaten.

**Gegenstelle:** Tests ClaudeCodeProxyManagerTests.swift:1180-1248 decken Reihenfolge und Fehlerpfade des Promote ab, aber keinen überlebenden Prozess.

**Regressionstest:** ClaudeCodeProxyManagerTests: Fake-ProcessHandle, dessen terminate() isRunning nie auf false setzt; replaceMainGrant(withProfile:) mit moveGrant-Closure; erwartet Failure und moved == false. Heute wird moveGrant nach 30 Sleeps trotzdem ausgeführt.

**Zum Fix:** Fix passt: nach der Schleife erneut isRunning prüfen, bei Timeout vor moveGrant mit einer klaren Fehlermeldung abbrechen (ggf. begrenzte SIGKILL-Eskalation nur für eigene Prozesse). Zu beachten: stopInstanceLocked/replaceSelfStartedProcess haben das Profil bereits aus der Registry entfernt, beim Abbruch sollte der Handle für spätere Bereinigung erhalten bleiben.

### LR-KO-004 · Vorgemerkte Kontowechsel können zwischenzeitlich eingegebene Entwürfe verwerfen

*teilbestätigt · Finder P0! → Prüfer P2*

Die Reentranz-Lücke ist im Code real: recheckPending sammelt ready je Zielkonto und entnimmt sie aus pending. Danach führt es switchRunning je Gruppe sequenziell aus, mit await waitForExit dazwischen. Status, Entwurf und Hintergrundaufgaben werden vor dem terminate der zweiten Gruppe nicht neu geprüft. Das Fenster öffnet sich aber nur, wenn gleichzeitig Vormerkungen zu zwei verschiedenen Zielkonten bestehen und beide im selben 2-s-Tick bereit werden, und der Nutzer in genau den Sekunden des ersten waitForExit im zweiten Chat tippt. Folge: der Prozess endet, der Chat wird per scheduleResume fortgesetzt, ein ungesendeter Composer-Entwurf (heuristisch erkannt) oder ein gerade begonnener Turn geht verloren. Das ist kein Transcript-Verlust. P2 statt P0, Erweitert-Feature, kein Nutzerweg W1-W7 verletzt.

**Gegenstelle:** WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:176-215 – innerhalb EINER Gruppe laufen Prüfung und terminate ohne await, nur der Mehr-Gruppen-Fall hat die Lücke.

**Regressionstest:** AccountSwitchCoordinatorTests: Zwei vorgemerkte Chats mit verschiedenen Zielkonten, beide idle. waitForExit des ersten Chats als Closure, die erst nach dem Setzen von mayHaveUnsentInput(chat2)=true zurückkehrt. recheckPending ausführen und erwarten, dass terminate für chat2 NICHT aufgerufen wird und chat2 wieder in pending steht (heute wird er beendet).

**Zum Fix:** Der Finder-Fix (Re-Check direkt vor terminate auf dem MainActor, bei Beschäftigung wieder vormerken) ist richtig, klein und unkritisch.

### LR-KO-005 · Ein laufendes inaktives Claude-Profil lässt sich ohne Prozessschutz entfernen

*bestätigt · Finder P1 → Prüfer P2*

removeProfile prüft Plugin-Referenzen, aber anders als renameProfile (AgentChatsClaudeAccountsTab.swift:~519-526) keine laufenden Sessions; nur das aktive Profil ist gesperrt (.disabled(isActive), :234). Ein laufender Chat unter einem inaktiven Profil ist leicht erreichbar. Die Folge ist aber begrenzt: Aktion ist bewusst vom Nutzer gewählt, mit Warndialog, und der Ordner geht in den Papierkorb (rettbar); der laufende Claude kann weiter schreiben und einen neuen Root anlegen (Verlaufssplitt), kein Totalverlust. Inkonsistenz zu Rename/Promote ist ein klarer Mangel, aber unter P1.

**Gegenstelle:** AgentChatsClaudeAccountsTab.swift:628 trashItem statt Löschen, Dialogtext warnt vor nicht mehr fortsetzbaren Sessions.

**Regressionstest:** Guard in eine pure Funktion (z. B. ClaudeProfileRunningGuard.hasRunningSession(profile:sessions:runningIDs:)) ziehen und testen: Session mit claudeProfileName == 'a' und ID in runningIDs -> true, Remove abgelehnt. View-Code selbst nicht unit-testbar.

**Zum Fix:** Fix passt; gleiche Guard-Logik wie renameProfile (AgentTerminalRegistry.shared.activeSessionIDs) in removeProfile und Disable-Zustand nach der Bestätigung erneut prüfen.

### LR-KO-006 · Profil-Rename bricht profilgebundene Plugin-Registrierungen für alle Konten

*bestätigt · Finder P1 → Prüfer P2*

renameProfile (ClaudeAccountProfiles.swift:449-478) hat keinen pluginRegistryReferences-Guard, während Promote ihn bei Zeile 81-84 und Remove ihn haben. Wird ein Profil umbenannt, dessen Ordner in installed_plugins.json/known_marketplaces.json als installPath steht (Claude schreibt den Pfad der installierenden Session), zeigen diese Einträge ins Leere. Die Plugins sind dann in main und allen Konten nicht ladbar, bis sie neu installiert werden. Das ist ein echter Fehler mit stillem Ausfall, aber ohne Datenverlust, behebbar per Neuinstallation und nur nach einer seltenen Umbenennung. Die Vorbedingung 'Plugin aus Zusatzprofil heraus installiert' ist plausibel. Daher P2 statt P1.

**Gegenstelle:** keine – kein Guard und kein Test für Rename gefunden.

**Regressionstest:** ClaudeSharedConfigTests/ClaudeAccountProfilesTests: main/plugins/installed_plugins.json mit installPath unter <profiles>/alt/ anlegen; renameProfile(from:alt,to:neu) muss einen Fehler mit pluginsRegisteredViaProfile werfen und alt unverändert lassen (heute wird umbenannt).

**Zum Fix:** Der Guard (Rename mit demselben Fehlertext wie Remove ablehnen) ist trivial und sicher. Ein eigener Registry-Umzug wäre riskant, weil die Registry Claudes Datei ist und die Claude-CLI sie nicht dafür vorsieht.

### LR-KO-007 · Ein Keychain-Lesefehler wird beim Rename als fehlender Login behandelt

*bestätigt · Finder P1 → Prüfer P2*

renameProfile behandelt jeden Nicht-0-Status von `security find-generic-password` als 'kein Login' (ClaudeAccountProfiles.swift:457-477), der Test testRenameProfileWithoutLoginSkipsKeychainOps (Status 44) zementiert nur den echten ItemNotFound-Fall. Bei verweigertem ACL-Zugriff/gesperrtem Schlüsselbund wird der Ordner trotzdem umbenannt, der pfadabhängige Keychain-Service passt dann nicht mehr und der Login wirkt weg. Es ist aber kein Datenverlust: das Item bleibt unter dem alten Service-Namen erhalten, Zurück-Umbenennen oder neuer Login behebt es; Auslöser ist ein selten verweigerter Prompt.

**Gegenstelle:** Keychain-Item bleibt unangetastet (kein delete im Fehlerpfad); Rename-Rückweg stellt Login wieder her.

**Regressionstest:** ClaudeAccountProfilesTests: securityRunner liefert für find-generic-password (36 bzw. 128/51, 'user canceled') -> renameProfile muss werfen und configDir(alt) bleibt bestehen, neu existiert nicht. Heute: Rename gelingt, Ordner verschoben.

**Zum Fix:** Fix korrekt: nur Status 44 (errSecItemNotFound) als loginlos werten, alles andere vor dem moveItem abbrechen. Exit-Codes von `security` sind nicht die OSStatus-Rohwerte (44 für not found); die Finder-Idee 'Security.framework statt CLI' ist optional und nicht nötig.

### LR-KO-008 · Transcript-Kollisionen werden beim Umzug nach main als erfolgreicher No-op verschleiert

*teilbestätigt · Finder P1 → Prüfer P2*

Die Logik-Lücke ist im Code nachvollziehbar: locateTranscript sucht über claudeProjectsRoots() mit main zuerst. Liegt dieselbe Session-ID alt unter main und aktuell unter Profil A, hält transcriptConflictExists die main-Datei für die Quelle (source.path == targetFile.path → kein Konflikt). moveTranscript liefert false, der Umzug stempelt trotzdem nach main, und Resume nimmt die veraltete Kopie. Die Vorbedingung ist aber eine doppelt vorhandene ID in zwei Roots. WhisperM8 verschiebt sonst nur (kopiert nie), und Claude schreibt eine ID normalerweise nur in den Root des laufenden Profils. Das kann nach Pfad-/Hochstufungs-Mischungen oder manuellem Kopieren vorkommen, ist aber selten. Das aktuelle Transcript geht nicht verloren, es bleibt in A liegen. Kontext-Rückfall, kein Löschen: P2.

**Gegenstelle:** WhisperM8/Services/AgentChats/AccountMoveService.swift:76-84 – erst Datei, dann Stempel; nur der Fall 'zwei Kopien' fällt durch.

**Regressionstest:** ClaudeAccountProfilesTests: Fixture mit <main>/projects/<enc>/<id>.jsonl (alt, klein) und <A>/projects/<enc>/<id>.jsonl (neu). transcriptConflictExists(toProfile:nil) muss true liefern bzw. moveTranscript muss werfen statt false zurückzugeben (heute false/No-op und danach Umstempeln).

**Zum Fix:** Der Fix ist richtig (bekannten Herkunftsaccount als Quell-Root nutzen). Vorsicht: die Glob-Stufe für abweichende cwd-Kodierung muss erhalten bleiben, und bei zwei Kopien soll gemeldet statt ausgewählt werden.

### LR-KO-009 · Teilweise fehlgeschlagenes Rückgängig löscht auch die noch offenen Journal-Einträge

*bestätigt · Finder P1 → Prüfer P2*

undoLastBatch löscht bei outcome.moved nicht leer den ganzen Batch bis auf laufende Chats (AccountMoveService.swift:137-169); fehlgeschlagene und wegen cwdResolver==nil verworfene Einträge verlieren ihre Undo-Information. Das ist ein echter Logikfehler, aber die Auswirkung ist klein: nur Teilerfolg-Undo mit einem zweiten Fehler, die Chats selbst bleiben intakt und lassen sich manuell über das Kontextmenü 'Zu Account verschieben' zurückbewegen. Kein Datenverlust, Zusatzfunktion.

**Gegenstelle:** AccountMoveService.swift:153-155: Teilerfolg-Verhalten mit keeping: runningIDs ist dokumentiert, Fehlschläge werden im Outcome.failed gemeldet, Nutzer sieht sie.

**Regressionstest:** AccountMoveServiceTests: Batch mit zwei Einträgen (A->C, B->C), Herkunftsprofil von B fehlt (targetProfileMissing); undoLastBatch -> moved=[A], failed=[B]; danach journal.lastBatch() muss B noch enthalten. Heute leer.

**Zum Fix:** Fix passt: keeping = runningIDs plus Session-IDs aus outcome.failed plus nicht auflösbare (cwd nil); Pendelschleife bleibt vermieden, da recordInJournal false.

### LR-ONB-005 · : Nach Rechtevergabe kann ein unvollständiges Setup dauerhaft verschwinden

*teilbestätigt · Finder P1! → Prüfer P2*

Das Verhalten stimmt: needsOnboarding prüft nur Mikrofon und Accessibility (WhisperM8App:204-208). Wer den Wizard nach dem Rechteschritt schließt, bekommt beim nächsten Start keinen Wizard mehr. Es ist aber eine bewusst dokumentierte Designentscheidung, wie der Kommentar dort und CLAUDE.md zeigen, und kein Absturz oder Datenverlust. Die App landet im normalen Zustand: Das Menü zeigt 'No hotkey configured', fehlender Key erzeugt ein TranscriptionError.missingAPIKey, und Recording sowie Transcription in den Settings sind direkt erreichbar. Für Voll-Profil-Nutzer gibt es zusätzlich den Sidebar-Button 'Onboarding / Hilfe öffnen'. Schlecht ist nur, dass Diktat-only-Profile keinen Wiedereinstieg haben. Das ist ein UX-Defizit mit Workaround.

**Gegenstelle:** WhisperM8/Views/AgentChatsView.swift:2008-2018 hat einen Button, der den Wizard jederzeit erneut öffnet (nur im Agent-Chats-Fenster). WhisperM8/Views/MenuBarView.swift:63-70 zeigt 'No hotkey configured'.

**Regressionstest:** Eine pure Funktion setupIncompleteReason(micGranted:, axGranted:, hotkeySet:, hasKey:) mit Tests einführen. Eingabe: beide Rechte erteilt, hotkeySet == false. Erwartet: ein 'Setup fortsetzen'-Hinweis wird angezeigt. Ein vollständig konfigurierter Bestandsnutzer bekommt keinen. Heute fehlt dieser Zustand komplett.

**Zum Fix:** Eine Rückkehr zum alleinigen onboardingCompleted-Flag wäre falsch (dokumentierter Vorfall). Ein Hinweisband oder Menüeintrag 'Setup fortsetzen' reicht. Den Wizard nicht erneut erzwingen.

### LR-ONB-006 · : Schon ein versehentlich getipptes Zeichen ersetzt den funktionierenden API-Key

*teilbestätigt · Finder P1! → Prüfer P2*

Der Code stimmt: onChange speichert jeden nicht leeren Zwischenstand sofort per KeychainManager.save (OnboardingView:635-640, TranscriptionSettingsPage:107-113), und Leeren stellt nichts wieder her. Das Szenario setzt aber voraus, dass ein Nutzer mit funktionierendem Key in das Feld klickt und ein Zeichen tippt. Das Feld zeigt nur Punkte als Platzhalter, und der übliche Weg ist Einfügen eines neuen Keys. Der alte Key ist beim Anbieter (Groq/OpenAI) weiter gültig und neu abrufbar, es geht also kein unersetzlicher Zugang verloren. Im Onboarding existiert noch kein Key. Das ist ein echter Designmangel, aber unwahrscheinlich und kein Datenverlust im engeren Sinn.

**Gegenstelle:** WhisperM8/Views/TranscriptionAccountControls.swift:49-51 hält den bestehenden Key bewusst aus dem Feld. Der Nutzer wird dadurch nicht zum Editieren des alten Werts verleitet. 'Remove Key…' und Neueingabe sind vorhanden.

**Regressionstest:** Das Key-Entwurf-Verhalten in ein kleines Modell mit injiziertem Speicher-Closure ziehen. Ablauf: gespeicherter Key 'good', Eingabe 'x', dann Eingabe ''. Erwartet: save wurde nie aufgerufen, und der Key bleibt 'good'. Heute wird bei 'x' sofort überschrieben.

### LR-ONB-007 · : Fehlgeschlagene Keychain-Writes werden im Setup als vorhandener Zugang behandelt

*teilbestätigt · Finder P1! → Prüfer P2*

KeychainManager.save gibt Void zurück und loggt Fehler nur (KeychainManager:10-34). Die UI setzt apiKeyAvailable = true unabhängig davon, ob der Write gelang. Der Code-Befund ist korrekt. Ein fehlschlagender SecItemUpdate/SecItemAdd bei einem normalen Login-Keychain-Zugriff ist aber ungewöhnlich (gesperrter Schlüsselbund, verweigerter ACL-Prompt nach Re-Signierung). Beim Diktat tritt kein stiller Fehler auf: Der Coordinator lädt den Key, bekommt nil und wirft TranscriptionError.missingAPIKey mit einer sichtbaren Meldung. Die Auswirkung ist verwirrend, aber kein Absturz und kein Datenverlust. Der Fall ist als Altlast N06 bekannt.

**Gegenstelle:** WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:26-33 fängt den fehlenden Key beim Diktat mit missingAPIKey ab. Der Fehler wird also bei der ersten Nutzung sichtbar.

**Regressionstest:** KeychainManager.save um eine throwing- oder Result-Variante mit injizierbarem SecItem-Backend ergänzen. Test: Backend liefert errSecAuthFailed. Erwartet: Die Aufrufer setzen apiKeyAvailable nicht auf true und zeigen einen Fehler. Heute ist das nicht abbildbar, weil save Void zurückgibt.

### LR-ONB-017 · : Das Codex-Login-Skript quotiert den aufgelösten Binary-Pfad nicht

*bestätigt · Finder P1! → Prüfer P2*

openLoginInTerminal() interpoliert codexPath unquotiert in das .command-Skript (CodexSupport.swift:~198); ein Pfad mit Leerzeichen oder Metazeichen bricht den Login. Der Fehler ist real und trivial zu beheben. Die Reichweite ist aber klein: Standardorte (/Applications/Codex.app/Contents/Resources/codex, /opt/homebrew/bin, ~/.local/bin, npm-global) enthalten normalerweise keine Leerzeichen; relevant nur bei Home-/Volume-Pfaden mit Leerzeichen. Der Codex-Login ist im Onboarding ausdrücklich optional ('you can skip it'), und AI-Enrichment ist erweitert, nicht Kernpfad W2. W3 scheitert nur für diese seltene Pfadkonstellation, und der Nutzer kann `codex login` manuell im Terminal ausführen.

**Gegenstelle:** WhisperM8/Views/OnboardingView.swift:320-337 (Codex-Schritt ausdrücklich optional/überspringbar); Standard-Auflösungspfade ohne Leerzeichen (CodexSupport.swift:~215 und AgentCommandBuilder.commandPath)

**Regressionstest:** Skriptgenerierung als pure Funktion extrahieren (z. B. CodexStatusProbe.loginScript(codexPath:)) und testen: Pfad '/Volumes/Tools Suite/bin/codex' und "/Users/o'brien/bin/codex" -> Skriptzeile enthält korrekt gequoteten Pfad (z. B. '/Volumes/Tools Suite/bin/codex' login bzw. mit '\'' für Apostroph); heute unquotiert und der Test schlägt fehl.

**Zum Fix:** Bestehenden shellEscape-Helfer wiederverwenden bzw. Single-Quote-Escaper; die echte CLI im Terminal beibehalten (Finder-Vorschlag ist korrekt).

### LR-SH-003 · : Fehlgeschlagene Keychain-Migration löscht die einzige persistierte API-Key-Kopie

*teilbestätigt · Finder P0! → Prüfer P2*

Der Code-Pfad stimmt: KeychainManager.load() ruft save() auf, save() loggt bei Fehlschlag nur, danach wird der UserDefaults-Wert trotzdem entfernt (Z. 61-66). Auslöser ist aber eng: der Key muss noch als Legacy-Wert in UserDefaults liegen (nur Nutzer sehr alter Versionen, nicht die Launch-Zielgruppe) UND der Keychain-Schreibzugriff muss gleichzeitig scheitern (selten). Verloren geht ein neu eingebbarer API-Key, kein Nutzerinhalt. Das Onboarding/Settings-Teil (apiKeyAvailable=true nach fehlgeschlagenem save) ist real, aber nur UI-Schönheit bei ohnehin seltenem Keychain-Fehler. P0 ist klar überhöht.

**Gegenstelle:** WhisperM8/Services/Shared/KeychainManager.swift:61-66 (Migration läuft nur für Legacy-Werte; load() gibt den Wert im selben Aufruf noch zurück)

**Regressionstest:** KeychainManager mit injizierbaren SecItem-Closures (oder kleinem Protokoll) testbar machen; Test: UserDefaults enthält Legacy-Key, SecItemUpdate/Add liefern errSecInteractionNotAllowed -> nach load() muss UserDefaults-Wert weiterhin vorhanden sein. Zweiter Test: save-Fehler darf apiKeyAvailable nicht auf true setzen (save als Bool/throws).

**Zum Fix:** Kleiner Fix reicht: save() gibt Bool zurück, Legacy-Wert nur bei true entfernen. Kein Journal/Readback-Aufwand nötig.

### LR-SH-004 · : Nicht-UTF-8-Statusline-Skripte werden ohne Fremddatei-Bestätigung überschrieben

*teilbestätigt · Finder P0! → Prüfer P2*

Mechanik stimmt: status()/foreignScriptURL() nutzen try? String(contentsOf:.utf8); ein nicht-UTF-8-Skript ergibt nil, wird als .missing behandelt und install() überschreibt ohne Fremddatei-Bestätigung. Der Auslöser ist jedoch sehr schmal: Es muss ein eigenes Skript genau unter ~/.claude/statusline-command.sh bzw. dem Subagent-Pendant liegen, in einer Nicht-UTF-8-Kodierung, und der Nutzer muss in Einstellungen (CLISkillsSettingsPage, einziger Aufrufer, kein Auto-Install) bewusst auf Install klicken. UTF-8-Fremdskripte werden korrekt abgefangen (Marker-Prüfung + Bestätigungsdialog). Datenverlust einer Nutzerdatei ist real, aber extrem selten; kein P0.

**Gegenstelle:** WhisperM8/Services/Shared/StatuslineInstaller.swift:262-264 (Fremddatei-Guard greift für alle lesbaren UTF-8-Skripte); Aufruf nur manuell aus CLISkillsSettingsPage.swift:553

**Regressionstest:** StatuslineInstallerTests: Temp-Home, ~/.claude/statusline-command.sh mit Bytes 0xE4 (Latin-1 ä) schreiben; install() ohne replaceForeignScript muss InstallError.foreignScript werfen und die Datei bytegleich lassen; status() muss .foreign liefern. Heute: status()==.missing, Datei überschrieben.

**Zum Fix:** Fix ist klein: Existenz (fileExists) getrennt von Dekodierbarkeit prüfen; nicht dekodierbar = foreign. Kein Backup-System nötig.

### LR-SH-007 · : Die Login-Shell-Abfrage kann den ersten Chatstart dauerhaft auf dem Hauptthread blockieren

*teilbestätigt · Finder P1! → Prüfer P2*

Code stimmt: queryLoginShellPath() wartet ohne Timeout per waitUntilExit, stderr-Pipe wird nie geleert, und path (Z. 59-80) hält den Lock nicht während des Ladens, sodass ein Chatstart vor Prewarm-Ende den Loader selbst auf dem Main Thread ausführt (AgentTerminalView.start). Allerdings ist ein Hänger nur bei pathologischen Login-Dotfiles plausibel (blockierendes Netzwerk in .zprofile); die stdout-Ausgabe ist nur der PATH, ein 64-KB-Pufferüberlauf durch Diagnoseausgabe bei `zsh -l -c` (sourct .zshrc nicht) ist praktisch unrealistisch. Typischer Fall (langsame .zprofile) kostet Sekunden, nicht unendlich. Die Prewarm-Absicherung für den Normalfall ist dokumentiert und greift. Echte Härtungslücke, aber kein Standardpfad der Zielgruppe.

**Gegenstelle:** WhisperM8/WhisperM8App.swift:308-317 (Prewarm off-main beim Start fängt den Normalfall ab)

**Regressionstest:** LoginShellEnvironmentTests: queryLoginShellPath mit injizierbarem Executable/Argumenten (z. B. /bin/sh -c 'sleep 30') und Deadline-Parameter; erwartet nil nach <= Deadline statt Blockade. Zweiter Test: zwei parallele path-Aufrufe starten den Loader nur einmal (Zähler im pathLoader).

**Zum Fix:** Timeout (z. B. 5 s) + stdin=/dev/null + stderr nach /dev/null genügt; Main-Thread-Wait zusätzlich vermeiden. Kein größerer Umbau.

### LR-AK-012 · : Retention löscht Sessions anhand eines nach await veralteten Schutz-Snapshots

*teilbestätigt · Finder P1! → Prüfer P3*

Technisch stimmt es: die Kandidatenliste und protectedSessionIDs werden vor dem await berechnet, nach dem Archivieren löscht deleteSessions alle ursprünglichen IDs ohne erneute Prüfung. Betroffen wären nur Subagent-Spiegel, deren Job-Verzeichnis weg ist und die >7 Tage inaktiv sind; der Nutzer müsste genau diesen Chat im Zeitfenster der Archivierung (Millisekunden bis wenige Sekunden, Intervall-gesteuert) öffnen. Das Transcript wird verschoben, nicht gelöscht (Archiv in Application Support), der Eintrag ist zudem ohne lebendes Job-Verzeichnis ohnehin Karteileiche. Praktisch irrelevant für den Launch.

**Gegenstelle:** WhisperM8/Services/AgentChats/SubagentJobRetention.swift:77-107 — Transcript wird nach agent-jobs-archive verschoben, nie gelöscht; Kandidaten sind nur ≥7 Tage inaktive, terminale Mirrors ohne Job-Verzeichnis.

**Regressionstest:** Optional: AgentJobWorkspaceSync-Test mit Archiver-Spy, der während archive() die Session in protectedSessionIDs aufnimmt; deleteSessions darf diese ID nicht entfernen. Heute entfernt.

**Zum Fix:** Billiger Fix: nach dem await die Kandidaten gegen aktuelle protectedSessionIDs/Sessionstatus erneut filtern, kein Claim-System nötig.

### LR-AK-024 · [A3-09] Orphan-Korrektur kann einen neueren Jobzustand überschreiben

*teilbestätigt · Finder P1 → Prüfer P3*

Der Ablauf ist statisch möglich: correctIfOrphaned liest ohne Lock und schreibt per writeState einen Snapshot failed zurück. Es gibt aber einen engen Auslöser: Der Snapshot muss spawning ohne PID und älter als 30 s sein, während der Supervisor genau in dieser Millisekunden-Spanne seinen Übergang nach running schreibt. Normalerweise startet der Supervisor binnen Sekunden, ein 30-s-Rückstand heißt ohnehin 'Spawn gescheitert'. Die Wahrscheinlichkeit ist sehr klein, das Feature ist Erweitert (Codex-Subagent-Jobs), und ein falsches failed zeigt sich dem Nutzer als einzelner kaputter Job. Kein Kern-Weg verletzt.

**Gegenstelle:** WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:83-87 setzt running und PID unter dem exklusiven Job-Lock, correctIfOrphaned (AgentJobStore.swift:264-305) nimmt diesen Lock nicht. Das Fenster bleibt dadurch offen, ist aber nur nach >30 s Spawn-Verzögerung erreichbar.

**Regressionstest:** AgentJobStoreTests mit injizierbarem now/livenessProbe: Job spawning ohne PID mit updatedAt vor 31 s. Test-Seam zwischen readState und writeState, der den Zustand auf running+PID umschreibt. Erwartet nach correctIfOrphaned weiterhin running. Heute wird failed geschrieben.

**Zum Fix:** Die Korrektur unter withExclusiveLock fresh neu lesen und nur schreiben, wenn state/PID unverändert sind. Vorsicht: readAllCorrected wird häufig gepollt, eine Sperre darf dort nicht blockieren (best-effort, Nicht-Blocking-Lock, bei Konflikt unkorrigiert zurückgeben).

### LR-AK-027 · [A3-13] Zustell-Token kann mehrfach erfolgreich konsumiert werden

*teilbestätigt · Finder P1! → Prüfer P3*

consume() ignoriert das Ergebnis von removeItem, daher kann ein Token statisch mehrfach 'true' liefern. Der konkrete Schaden ist aber winzig. Zwei gleichzeitige Hook-Prozesse mit gleichem Prompt-Hash lesen nur dann dasselbe Token, wenn dieselbe Nachricht zeitgleich zweimal submittet wird. Bei Zustellung an zwei Ziele existieren zwei Tokens, und beide Submissions sind legitim. Das unverbrauchte zweite Token ist dann nur ein einzelner zusätzlicher Freipass bis zum TTL (30 min) für denselben Marker-Text. removeItem schlägt nur bei Rechte- oder Dateisystemproblemen fehl, und der Guard ist laut Konzept fail-open. Betroffen ist das unsichtbare Zusatz-Sicherheitsnetz F-AC-10, nicht der Nutzerweg. Kein Launch-Blocker, kein Race mit plausibler Wirkung.

**Gegenstelle:** WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:30-35 und 58-62: Der Kernschutz hängt laut Kommentar nicht an der Frist, und 'gleicher Prompt an zwei Ziele = zwei Tokens, jede Submission konsumiert genau eines'. Fail-open ist absichtlich.

**Regressionstest:** SendGuardTests: stage() einmal, dann consume() zweimal mit einem Verzeichnis, in dem removeItem fehlschlägt (z. B. Verzeichnis read-only via chmod 0o500 nach dem Stage). Erwartet: zweiter consume liefert false. Heute true. Der Zwei-Prozess-Fall braucht einen Claim per rename(2) in ein Unterverzeichnis.

**Zum Fix:** Atomaren Claim per rename(2) der Token-Datei (z. B. in .claimed/) nutzen. Ein Fehlschlag beim Claim muss der Fail-open-Politik folgen und darf keinen Block auslösen. Ein Lock wäre teurer und fehleranfälliger als rename.

### LR-DIK-014 · Parallele Codex-Läufe teilen sich einen falschen Cancel-Slot

*teilbestätigt · Finder P1! → Prüfer P3*

Das Singleton CodexProcessRegistry hält nur einen current-Slot und ein globales cancelledByUser; register() überschreibt beides, resetCancelFlag() setzt es zurück. Eine Test-Lab-Vorschau parallel zu laufendem Diktat-Post-Processing würde das Overlay-Cancel auf den falschen Prozess lenken. Dafür muss der Nutzer gleichzeitig in den Einstellungen eine Vorschau starten, während ein Diktat nachbearbeitet wird (wenige Sekunden). Der Diktat-Pfad serialisiert sich über isProcessing. Die Folge ist ein falscher Abbruch oder Fallback auf Raw, kein Datenverlust. Eher theoretisch als P1.

**Gegenstelle:** WhisperM8/Services/Dictation/RecordingCoordinator.swift:370-373: Cancel wirkt nur bei appState.isPostProcessing, was nur der Diktat-Lauf setzt. Test Lab hat eigenen previewGeneration-Guard (AIOutputTestLabTab.swift:100-118).

**Regressionstest:** CodexProcessRegistry-Test: zwei Dummy-Process (sleep) nacheinander registrieren, cancel() aufrufen. Erwartet: nur der Lauf, der die Run-ID hält, wird abgebrochen. Heute wird der zuletzt registrierte beendet.

**Zum Fix:** Run-ID-Handle ist ok. Parallele Läufe nicht stillschweigend verbieten.

### LR-GPT-006 · Waisen-Schutz beendet auch bewusst extern gestartete Hintergrund-Proxys

*teilbestätigt · Finder P1 → Prüfer P3*

Das beschriebene Verhalten ist beabsichtigt und getestet: testReplacesOrphanRunningADifferentBinary erwartet ausdrücklich das Beenden einer Waise (PPID 1) mit anderem Binary-Pfad, weil genau das der Befund vom 23.09.2026 war (make kill hinterließ veralteten Proxy). Betroffen ist nur, wer einen eigenen claude-code-proxy per launchd oder nohup auf exakt dem von WhisperM8 konfigurierten Port laufen lässt, und das bei aktiviertem GPT-Backend. Das ist ein Labs-Randfall, und der User hat sich mit der gleichen Port-Konfiguration ohnehin für WhisperM8s Verwaltung entschieden. Die PPID-1-Heuristik kann tatsächlich nicht zwischen 'meine Waise' und 'launchd-Dienst' unterscheiden, daher teilbestätigt, aber nur als P3-Härtung.

**Gegenstelle:** Tests/WhisperM8Tests/ClaudeCodeProxyOrphanGuardTests.swift:13-17 – das Beenden einer Waise mit anderem Binary ist als Soll-Verhalten getestet.

**Regressionstest:** ClaudeCodeProxyOrphanGuardTests: Listener mit PPID 1 und Pfad /opt/homebrew/bin/claude-code-proxy, resolved = verwaltetes Binary; erwarten, dass shouldReplace false liefert, sobald die Ownership-Prüfung 'nicht von uns gestartet' meldet (heute true). Ändert damit auch den bestehenden Test testReplacesOrphanRunningADifferentBinary.

**Zum Fix:** Persistierte Ownership (PID+Startzeit) ist für ein Labs-Randthema überdimensioniert. Eine einfache Variante: Waise nur beenden, wenn das Binary im verwalteten bin-Ordner oder an einem früher von WhisperM8 aufgelösten Pfad liegt, und sonst nur Warnung/Konfliktmeldung.

### LR-KO-003 · Usage-Ping löscht fremde Projektverläufe allein aufgrund eines Namenssuffixes

*teilbestätigt · Finder P0! → Prüfer P3*

Der Mechanismus stimmt: isPingProjectsDirectory prüft nur hasSuffix("-whisperm8-limit-ping") und cleanupPingArtifacts löscht jeden Treffer rekursiv ohne Backup. Der Auslöser ist aber praktisch nicht erreichbar: Ein fremdes Projekt müsste mit der Komponente 'whisperm8-limit-ping' enden (oder 'x-whisperm8-limit-ping'). Das ist ein interner Hilfsordnername, und der Indexer überspringt solche Ordner ohnehin (dasselbe Suffix), das Projekt wäre also schon vorher unsichtbar. Das Löschen betrifft außerdem nur das projects-Verzeichnis des gepingten Profils und läuft nur auf einen manuellen Klick. Das Szenario ist eine Härtungslücke, kein realistischer Datenverlust. 'Funktioniert mit einem Konto' stimmt formal, ändert aber nichts an der Seltenheit.

**Gegenstelle:** WhisperM8/Services/AgentChats/ClaudeAccountLimitPinger.swift:35-43 – der Docstring benennt das Suffix bewusst als Erkennung; ein realer Ordnername mit diesem Suffix außerhalb des Pings ist nicht plausibel.

**Regressionstest:** ClaudeAccountLimitPingerTests: Fixture-configDir mit projects/<encode(echter Ping-cwd)> und projects/-Users-x-repos-whisperm8-limit-ping (Dummy-Transcript); cleanupPingArtifacts aufrufen; erwarten, dass der fremde Ordner bestehen bleibt (heute wird er gelöscht).

**Zum Fix:** Der Fix des Finders ist richtig und billig (genauen encodierten Ping-Ordnernamen aus encodeClaudeCwd(workDirectory.path) berechnen und nur diesen löschen). Das Suffix muss im Indexer-Skip aber bleiben bzw. gleich mit umgestellt werden.

### LR-PJ-001 · : Die Plugin-Migration räumt fremde, ungestempelte Skills automatisch weg

*teilbestätigt · Finder P1! → Prüfer P3*

Technisch korrekt: Die einmalige Migration verschiebt jeden Plugin-Skill-Ordner in ~/.claude/skills außer Symlinks und .modifiedLocally, auch ungestempelte (unknownDrift). Das ist aber beabsichtigt (Kommentar: ältere WhisperM8-Installs hatten keinen Stempel, jarvis nie) und betrifft nur exakt WhisperM8-eigene Skill-Namen (transcription, codex-subagent, whisperm8-chats, gpt-*, jarvis, callout). Dass ein Neu-Nutzer einen eigenen, gleichnamigen Skill besitzt, ist extrem unwahrscheinlich; verschoben wird in ein Backup, nichts gelöscht, und der Skill steht in App-Sessions als /whisperm8:<name> zur Verfügung. Kein Datenverlust, kein Kern-Nutzerweg betroffen.

**Gegenstelle:** WhisperM8/Services/Shared/WhisperM8ClaudePlugin.swift:309-325 (Backup statt Löschen, Symlinks und lokal geänderte Stempel-Installationen werden geschützt)

**Regressionstest:** WhisperM8ClaudePluginTests: Home mit ~/.claude/skills/codex-subagent/SKILL.md fremden Inhalts ohne Stempel; ClaudePluginSkillMigration.run() soll ihn in outcome.kept führen und nicht verschieben (heute: moved). jarvis-Sonderfall dabei beachten, damit alte Jarvis-Kopien weiterhin migriert werden.

**Zum Fix:** Der vorgeschlagene Fix (nur nachweislich eigene Installationen) würde die dokumentierte Migration alter, ungestempelter WhisperM8-Installs und der nie gestempelten jarvis-Kopie brechen. Besser: unknownDrift nur verschieben, wenn Inhalt einen WhisperM8-Marker trägt oder dem gebündelten Stand entspricht.

### LR-PJ-002 · : Die Umgebungssäuberung entfernt fremde Plugin-Verzeichnisse vor deren angeblichem Erhalt

*bestätigt · Finder P1! → Prüfer P3*

Der Widerspruch im Code ist real: processEnvironment() entfernt alle CLAUDE_CODE_*-Variablen (LoginShellEnvironment.swift:106-108), ClaudePluginBootstrap.launchEnvironment liest 'inherited' aus genau diesem bereinigten Env und bekommt daher nie einen fremden CLAUDE_CODE_PLUGIN_DIRS-Wert; der Erhalt in WhisperM8ClaudePlugin.launchEnvironment ist im Produktivpfad totes Verhalten (nur der Unit-Test mit direktem inherited-Wert besteht). Die Reichweite ist aber winzig: CLAUDE_CODE_PLUGIN_DIRS ist ein Entwickler-/Debug-Mechanismus, den eine per Dock gestartete GUI-App gar nicht erbt (nur via launchctl setenv oder Start aus einem Terminal), und die Zielgruppe richtet Plugins über 'claude plugin' ein, das nicht betroffen ist. Der Entfernungs-Guard selbst ist ein dokumentierter, wichtiger Workaround (Vorfall verschachtelte Child-Session). Konsistenzfehler mit sehr niedriger Wirkung.

**Gegenstelle:** WhisperM8/Services/Shared/LoginShellEnvironment.swift:94-108 (CLAUDE_CODE_*-Strip ist ein bewusster, in CLAUDE.md dokumentierter Guard und darf nicht gelockert werden)

**Regressionstest:** Integrationstest: base-Env mit CLAUDE_CODE_PLUGIN_DIRS=/foo und CLAUDE_CODE_SESSION_ID=x durch Resolver+Bootstrap-Logik (z. B. launchEnvironment-Parameter inherited aus dem rohen ProcessInfo-Env statt aus processEnvironment()); erwartet '/foo:<ours>', CLAUDE_CODE_SESSION_ID bleibt entfernt. Heute liefert Bootstrap nur '<ours>'.

**Zum Fix:** Fix: PLUGIN_DIRS aus dem rohen Environment lesen (nicht aus processEnvironment()), den CLAUDE_CODE_*-Strip aber für alle anderen Variablen unverändert lassen; den Strip nicht per Ausnahme aufweichen, das ist eine dokumentierte Invariante.

### LR-VG-001 · VoiceGate sperrt Auswertung bei Diktat oder Abschalten nicht sofort

*teilbestätigt · Finder P1! → Prüfer P3*

refreshArmState läuft nur im 10-s-Takt, ein Diktatstart pausiert den Listener also erst beim nächsten Tick. Auch handle() und performPress prüfen weder isEnabled noch Diktatzustand erneut. Technisch richtig. Voraussetzungen sind aber: Feature opt-in (Default aus, Labs), Codex-Desktop mit scharfer Sprachsitzung, manuelle Kürzel-Einrichtung, und der Nutzer sagt genau im Diktat das Codewort. Folge ist ein ungewollter Mute-Toggle in Codex, kein Datenverlust und keine Sicherheitslücke. Labs-Regel: nur relevant bei Gefährdung von Kern, Daten oder Sicherheit, das ist hier nicht der Fall.

**Gegenstelle:** WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift:124-130: stop() beendet Listener und Timer synchron. Nach Aus kommt höchstens eine bereits eingeplante Hypothese durch; der Dry-Run-Schalter ist Default-Sicherung.

**Regressionstest:** Gate-Coordinator-Test mit Fake-Probe und Fake-Toggler: isEnabled=false setzen, danach handle() mit passender Hypothese. Erwartet: toggler.toggle() wird nicht aufgerufen. Für den Diktat-Fall AppState.isRecording=true plus passende Hypothese: erwartet kein Press. Heute nur durch Listener-Stopp-Reihenfolge abgedeckt, nicht durch einen Guard.

**Zum Fix:** Billiger Fix: Guard auf isEnabled und AppState.shared.isRecording in handle() und performPress. Default-aus und on-device-Erkennung unverändert lassen.

### LR-SH-001 · [A3-03] Unbeteiligte Parent-Secrets gelangen ungefiltert in Kindprozesse

*widerlegt · Finder P0! → Prüfer P3*

processEnvironment ist das Environment-Merge für Terminal-Emulator-Kinder. Dass ein Chat die Umgebung erbt, mit der der Nutzer die App gestartet hat, ist erwartetes Verhalten, und ein Allowlist-Filter würde Nutzer-Setups brechen (AWS_PROFILE, Proxy-Variablen, API-Keys für die CLI). Bei Dock-/Brew-Start (Zielgruppe) hat launchd ohnehin kaum Variablen. Die App selbst injiziert ihre Keychain-Keys nicht in Kind-Environments (grep: OPENAI_API_KEY/GROQ_API_KEY werden nur im CLI-Transkript-Pfad gelesen, nie gesetzt). Die Kinder laufen als derselbe Nutzer und können ~/.aws usw. ohnehin lesen, es entsteht also keine Rechteausweitung. Die DoD-Zeile 'keine Secrets in vererbter Umgebung' meint die eigenen Secrets der App, und die werden nicht weitergereicht.

**Gegenstelle:** WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-151 filtert gezielt CLAUDE_CODE_*, CLAUDE_CONFIG_DIR, ANTHROPIC_CUSTOM_HEADERS und CCP_CONFIG_DIR und lässt den Rest bewusst durch. Eigene WhisperM8-Secrets werden nirgends ins Env geschrieben.

**Regressionstest:** Nur falls eine Härtung gewünscht ist (Defense-in-depth): LoginShellEnvironmentTests.testDoesNotLeakKeychainSecrets prüft, dass processEnvironment keine WhisperM8-eigenen Key-Variablen enthält. Das ist heute bereits grün. Eine Allowlist wird nicht empfohlen.

