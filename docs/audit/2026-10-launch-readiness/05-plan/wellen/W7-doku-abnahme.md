---
status: beschlossen
updated: 2026-10-18
description: Welle W7 des Launch-Readiness-Plans — Doku und Launch-Abnahme. Befunde, Abnahmekriterien, Tests zuerst.
---

# W7 · Doku und Launch-Abnahme

README, User Guide und Feature-Doku beschreiben den Ist-Stand und nur den Brew-Weg; CLAUDE.md enthält Arbeitsregeln statt Vorfall-Logbuch. Danach Abnahme gegen die Definition of Done.

**Umfang:** 7 Befunde · P2 5, P3 2 · 6 Launch-Blocker · Aufwand S×4, M×3

## Abnahmekriterien der Welle

- [ ] DocsLint grün: kein `make install`/`clean-install`/`xattr` als Nutzerweg, Seitennamen wie in der App, Agent-Chats-Kapitel vorhanden.
- [ ] CLAUDE.md auf Regeln gekürzt, Vorfälle in `docs/` verschoben.
- [ ] DoD-Messungen: Hotkey → Aufnahme ≤ 400 ms, Stop → Transkription ≤ 300 ms, `perf-load.sh` mit 6 Panes/20 Tabs ohne `main_thread_blocked_ongoing`, Leerlauf-CPU unter dem Wert aus D2 – alles mit `make dev-release`.
- [ ] SourceSizeGuard: keine Datei > 1.500 Zeilen in Kern-Subsystemen (Ausnahmeliste nur schrumpfend).
- [ ] W1–W7 auf einem frischen Benutzerkonto bzw. Mac durchlaufen, manuelle QA-Liste vollständig abgehakt, keine offenen P0 und keine offenen Kern-P1.

## Test-Infrastruktur zuerst

- DocsLintTests, SourceSizeGuardTests.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-DOK-001 | P2 | ja | S | niedrig | geplant · bestätigt | Die README bewirbt weiterhin ausgeschlossene Installationswege |
| LR-DOK-004 | P2 | ja | S | niedrig | geplant · teilbestätigt | Das Handbuch empfiehlt vollständige Datenlöschung als normale Fehlerbehebung |
| LR-DOK-005 | P2 | ja | M | niedrig | geplant · bestätigt | Das Anwenderhandbuch führt zu nicht mehr vorhandenen Einstellungsseiten |
| LR-DOK-008 | P2 | ja | M | niedrig | geplant · bestätigt | Automatisch geladene Projektregeln sind ein widersprüchliches Feature- und Vorfallarchiv |
| LR-DOK-009 | P2 | — | M | niedrig | geplant · unverifiziert | USER_GUIDE ohne Agent-Chats-Kapitel; Hooks-Seite beschreibt veralteten Statusweg |
| LR-DOK-006 | P3 | ja | S | niedrig | geplant · bestätigt | Aktive Feature-Doku beschreibt abgelöste Transcript- und Titelpfade |
| LR-DOK-007 | P3 | ja | S | niedrig | geplant · teilbestätigt | Die Datenschutzerklärung im Handbuch verschweigt dauerhaft gesicherte Abbruch-Audios |

### LR-DOK-001 · Die README bewirbt weiterhin ausgeschlossene Installationswege

*P2 · Launch-Blocker · doku / doku · Aufwand S · Risiko niedrig*

**Beleg:** `README.md:65-75 — Build from Source wird als Installationsabschnitt mit make install angeboten.`, `README.md:77-85 — Direct DMG download wird einschließlich manueller Quarantäne-Entfernung beworben.`, `README.md:89-93 — Setup beschreibt nur Rechte/Hotkey/API-Key, nicht den für W3/W4 erforderlichen CLI-Installations-/Login-Weg.` (Stand `a8e0f35`)

**Fehlerbild:** Ein neuer Nutzer folgt statt des empfohlenen Brew-Wegs einem gleichrangig dokumentierten DMG- oder Source-Installationsabschnitt. Er landet bei Terminal-Nacharbeit beziehungsweise einer nicht vom vorgesehenen Updatekanal verwalteten Kopie. Die öffentliche Anleitung widerspricht ausdrücklich dem einzigen Launch-Installationsweg und bildet die versprochenen Agent-/Enrichment-Nutzerwege nicht ab.

**Fix:** Endnutzer-Installation und Updates ausschließlich über den beschlossenen Brew-Cask dokumentieren. Build-Anleitung klar in Entwicklerdokumentation auslagern, DMG/Quarantäne-Umgehung nicht als Endnutzerweg bewerben. Geführtes Diktat-/Agent-Setup nach Umsetzung anhand der realen App-Schritte dokumentieren.

**Test zuerst:** Kein Swift-Test. Doku-Lint im CI: README.md darf weder 'xattr -dr com.apple.quarantine' noch 'make install' im Installationsabschnitt enthalten und muss 'brew install --cask rankm8/tap/whisperm8' sowie einen Abschnitt zur Claude-/Codex-Einrichtung enthalten.

**Zusammengeführt mit:** LR-DOK-003

### LR-DOK-004 · Das Handbuch empfiehlt vollständige Datenlöschung als normale Fehlerbehebung

*P2 · Launch-Blocker · doku / doku · Aufwand S · Risiko niedrig*

**Beleg:** `docs/USER_GUIDE.md:20-22`, `docs/USER_GUIDE.md:56-64`, `docs/USER_GUIDE.md:200-207`, `scripts/clean-install.sh:68-71` (Stand `a8e0f35`)

**Fehlerbild:** Ein Nutzer mit vorhandenen Chats und Custom-Modi folgt bei einem gewöhnlichen Startproblem oder einer bereits vorhandenen älteren Installation der hervorgehobenen Empfehlung make clean-install. Das Skript löscht den gesamten Application-Support-Ordner einschließlich Workspace, Reports und Custom-Konfiguration. Die unmittelbar betreffende Handbuchstelle nennt nur Rechte, Cache und Einstellungen; eine Sicherung wird nicht angeleitet.

**Fix:** Der destruktive Entwickler-Reset selbst soll bleiben und nur als getrennte letzte Option im Handbuch erscheinen. Das ist im Vorschlag des Finders schon so gedacht.

*Ursprünglicher Vorschlag:* Nichtdestruktive Fehlerbehebung und Brew-Update zuerst beschreiben. Vollreset nur als getrennte letzte Option mit konkreter Liste verlorener Daten, Sicherungs-/Wiederherstellungsanleitung und ausdrücklicher Entscheidung dokumentieren. Den absichtlich destruktiven Entwickler-Reset selbst nicht still umdefinieren.

**Test zuerst:** Kein Swift-Test. Ein Doku-Lint im CI: Der USER_GUIDE darf weder 'make clean-install' noch 'git clone' im Quick-Start enthalten und muss 'brew install --cask rankm8/tap/whisperm8' nennen. Alternativ eine Prüfliste im Review.

<details><summary>Prüfurteil</summary>

Die Aussage stimmt: USER_GUIDE.md und docs/README.md empfehlen als Quick Start git clone und make install und bei Problemen make clean-install. clean-install.sh löscht Keychain, Application Support (inklusive Workspace) und Einstellungen (scripts/clean-install.sh:55-75). Die Nennung der verlorenen Daten ist unvollständig. Der Schaden trifft aber nur, wer ein geklontes Repo hat. Die Zielgruppe installiert über Brew und hat kein Makefile. Der README im Repo-Root nennt Brew korrekt. Die eigentliche Schwere ist daher ein veralteter, widersprüchlicher Guide (W1 sagt Brew) und nicht ein realistischer Datenverlust. Als Datenverlust-Risiko P2, aber die Definition of Done verlangt einen Guide im Ist-Stand, und der ist hier verletzt. Der Blocker bleibt deshalb bestehen, gemeinsam mit LR-DOK-005 über eine Neufassung zu beheben.

</details>

### LR-DOK-005 · Das Anwenderhandbuch führt zu nicht mehr vorhandenen Einstellungsseiten

*P2 · Launch-Blocker · doku / doku · Aufwand M · Risiko niedrig*

**Beleg:** `docs/USER_GUIDE.md:88-105`, `docs/USER_GUIDE.md:150-180`, `WhisperM8/Views/SettingsView.swift:3-16`, `WhisperM8/Views/SettingsView.swift:24-49` (Stand `a8e0f35`)

**Fehlerbild:** Ein Erstnutzer sucht nach der Anleitung die Tabs API, Hotkey, Behavior oder Audio. Die App besitzt stattdessen Transcription, Recording und General. Für Nutzungsprofile, die erforderliche Codex-Anmeldung zur Umformulierung und den ersten Agent-Chat fehlen entsprechende Nutzerwege im Handbuch ganz.

**Fix:** Das Handbuch soll geführte CLI-Installation erst beschreiben, wenn LR-ONB-003 umgesetzt ist, wie der Finder schon schreibt.

*Ursprünglicher Vorschlag:* Handbuch entlang W2–W4 mit den tatsächlichen Seitennamen und Profilen neu strukturieren: Key unter Transcription, Hotkey/Audio unter Recording, Profil unter General und KI-Verbindung unter AI Output. Geführte CLI-Installation erst nach ihrer Implementierung als vorhandene Funktion beschreiben.

**Test zuerst:** Kein Swift-Test. Ein CI-Skript vergleicht die in USER_GUIDE.md genannten Tab-Titel mit SettingsPage.title und schlägt bei unbekannten Namen fehl. Heute schlägt es für API, Hotkey, Behavior und Audio an.

<details><summary>Prüfurteil</summary>

SettingsPage kennt Recording, Transcription, AI Output, Context, Agent Chats, GPT-Backend, Accounts, Hooks, CLI, General, Permissions, About und Output (SettingsView:3-16). Der Guide verweist dagegen auf die Tabs API, Hotkey, Behavior und Audio (USER_GUIDE:88-105,150-180), die es nicht mehr gibt. Dazu fehlen Nutzungsprofile, Codex-Login und der erste Agent-Chat. Die Zeilen stimmen. Das ist reines Doku-Defizit ohne Funktionsfehler, die Wege W2 bis W4 sollen laut Definition ohne Doku funktionieren. Deshalb P2. Blocker bleibt, weil die Definition of Done ausdrücklich fordert, dass der User Guide den Ist-Stand beschreibt (Zeile 74-75).

</details>

### LR-DOK-008 · Automatisch geladene Projektregeln sind ein widersprüchliches Feature- und Vorfallarchiv

*P2 · Launch-Blocker · doku / doku · Aufwand M · Risiko niedrig*

**Beleg:** `CLAUDE.md:135-156`, `CLAUDE.md:158`, `CLAUDE.md:169-178`, `AGENTS.md:43-49` (Stand `a8e0f35`)

**Fehlerbild:** Jede neue Session bekommt 45.324 Zeichen Projektregeln, geschätzt 11.300–15.100 Tokens allein für diese Datei. Neben Arbeitsregeln stehen lange Vorfallgeschichten und inzwischen widersprüchliche Behauptungen: generell read-only für externe Roots trotz dokumentierter Integrationswrites sowie explizite Gerätebindung ohne System-Default trotz der in der Voice-Gate-Doku erklärten Bluetooth-Ausnahme. Wartende können daraus falsche Änderungsgrenzen oder Hardwareannahmen ableiten.

**Fix:** Kurze verbindliche Arbeitsregeln und Guard-Invarianten behalten, Historie verlinken statt injizieren. Zielorte: Runtime/Binding nach docs/features/agent-chats/sessions/ARCHITECTURE.md; Terminal/Verlauf nach docs/features/agent-chats/ui/terminal.md und UI-Architektur; Konten/Memory/MCP in eine Konten-Feature-Doku; GPT-Lifecycle in eine GPT-Backend-Feature-Doku; Absturzschutz in App-Shell-Architektur/ADR; Voice Gate, Board und Callouts in ihre bestehenden Feature-Dateien. AGENTS.md auf dieselben aktuellen Regeln verweisen lassen. Tokenschätzung ist keine Tokenizer-Messung.

**Test zuerst:** Kein Swift-Test. CI-Check: CLAUDE.md höchstens rund 15.000 Zeichen, keine Datumsangaben der Form 'Vorfall YYYY-MM-DD'/'(DD.MM.YYYY)' außerhalb eines Verweisabschnitts. Ein grep-Lint prüft, dass 'read-only' nicht ohne die Ausnahmeliste der schreibenden Integrationen steht.

### LR-DOK-009 · USER_GUIDE ohne Agent-Chats-Kapitel; Hooks-Seite beschreibt veralteten Statusweg

*P2 · doku / doku · Aufwand M · Risiko niedrig*

**Beleg:** `docs/USER_GUIDE.md:10-293`, `WhisperM8/Views/Settings/Pages/ClaudeHooksSettingsPage.swift:12-30` (Stand `76256ad`)

**Fehlerbild:** Das Handbuch hat Kapitel zu Installation, Diktat, Settings-Tabs, Troubleshooting und Make-Befehlen, aber keines zu Agent Chats (Projekt hinzufügen, Chat starten, Status verstehen, Tab schließen vs. beenden vs. archivieren, Resume nach Neustart). Die Hooks-Seite (Use session hooks: ohne Hooks komme der Status only from the transcript) entspricht nicht mehr dem Registry-Modell vom 17.10., bei dem der Status aus Claudes eigener Registry kommt. Der Schalter ist ein reiner Jargon-Schalter, der Chat-Status und Benachrichtigungen verschlechtern kann.

**Fix:** Kapitel Agent Chats im USER_GUIDE ergänzen. Hooks-Seite an den Registry-Ist-Stand anpassen oder aus dem Standard-UI in Erweitert verschieben.

**Test zuerst:** DocsLint: USER_GUIDE enthält ein Kapitel „Agent Chats“; Hooks-Seite erwähnt den Registry-Status.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-DOK-006 · Aktive Feature-Doku beschreibt abgelöste Transcript- und Titelpfade

*P3 · Launch-Blocker · doku / doku · Aufwand S · Risiko niedrig*

**Beleg:** `docs/features/agent-chats/ui/README.md:180-192`, `docs/features/agent-chats/sessions/README.md:138-150`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:5-19`, `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:69` (Stand `a8e0f35`)

**Fehlerbild:** Nutzer oder Wartende suchen anhand der als aktiv markierten Doku eine Timeline-/Bubble-Ansicht beziehungsweise einen headless Titelgenerierungsaufruf. Die genannten Views sind entfernt; tatsächlich rendert ein NSTextView den Verlauf und Titel werden nativ übernommen. Die Doku vermittelt damit auch falsche Erwartungen an Titel-Kosten und Zeitpunkt.

**Fix:** UI-README und zugehörige Architekturabschnitte auf TranscriptTextRenderer/TranscriptTextView umstellen; TimelineBuilder nur dort dokumentieren, wo er weiterhin für Summary-/Datenprojektionen verwendet wird. Titelübernahme bei Turn-Ende, Priorität nativer Titel und Vorrang manueller Namen beschreiben; keine entfernten UI-Deckel wieder einführen.

**Test zuerst:** Kein Swift-Test. Doku-Lint: Typnamen in docs/features/**/*.md (Backticks, CamelCase-Swift-Typen) gegen 'grep -r "struct/class/enum <Name>" WhisperM8' prüfen. Aktive Doku darf keine gelöschten Typen wie AgentChatTranscriptView oder AgentTimelineView nennen.

### LR-DOK-007 · Die Datenschutzerklärung im Handbuch verschweigt dauerhaft gesicherte Abbruch-Audios

*P3 · Launch-Blocker · doku / doku · Aufwand S · Risiko niedrig*

**Beleg:** `docs/USER_GUIDE.md:273-278`, `WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift:42-59`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:42-54`, `WhisperM8/Services/Dictation/FailedRecordingsStore.swift:63-111` (Stand `a8e0f35`)

**Fehlerbild:** Ein Nutzer bricht eine laufende Transkription vertraulicher Sprache ab. Anders als die pauschale Aussage über temporäre Audiodaten erwarten lässt, wird auch dieser Abbruch ohne Fehlerdialog nach Application Support/WhisperM8/FailedRecordings verschoben. Das Handbuch erklärt weder diesen Ort noch die Aufbewahrungs-/Löschmöglichkeiten.

**Fix:** Erfolgs-, Fehler- und Abbruchfall ausdrücklich unterscheiden; lokale Rettungskopien, Ort und tatsächliche Aufräumpolitik erklären. Die sinnvolle Datenrettung nicht entfernen. Maximalalter nicht als garantierte zeitgesteuerte Löschung bewerben, wenn nur preserve/prune die Bereinigung anstoßen.

**Test zuerst:** Kein Swift-Test. Prüfliste im Doku-Review bzw. Lint: Der Privacy-Abschnitt muss die Ablageorte FailedRecordings (10 Stück/7 Tage) und Reports (500/180 Tage/2 GB) sowie deren Löschweg nennen. Der Lint sucht 'FailedRecordings' und 'Reports' in docs/USER_GUIDE.md.
