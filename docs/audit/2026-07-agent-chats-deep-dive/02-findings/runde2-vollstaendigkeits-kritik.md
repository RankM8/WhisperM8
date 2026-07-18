---
status: aktiv
updated: 2026-07-18
description: Vollständigkeitskritik des Agent-Chats-Deep-Dive-Audits mit Abdeckungslücken, dokumentübergreifenden Widersprüchen, Belegmängeln, Methodik-Blindstellen und neuen Findings.
---

# Runde 2: Vollständigkeitskritik des Deep-Dive-Audits

## Gesamturteil

Das Audit enthält viel belastbare statische Detailarbeit, ist aber nicht als
abgeschlossenes Gesamtaudit belastbar. Die drei größten Lücken sind:

1. **Keine konsolidierte Wahrheit:** README, Verdicts und ursprüngliche Roadmap bilden
   nur die erste, selektierte C01–C16-Runde ab; zahlreiche spätere kritische und hohe
   Runde-2-Findings sind weder adversarial verifiziert noch in eine verbindliche
   Finding→Verdict→Maßnahme-Matrix übernommen.
2. **Keine Privacy-/Release-Prüfung:** Datenflüsse, Retention und Unified Logging sowie
   CI, Signierung, Notarisierung, Gatekeeper und das veröffentlichte DMG wurden nicht als
   End-to-End-Verträge geprüft; beim Gegenlesen fanden sich hier zwei hohe neue Findings.
3. **Keine Provider-Parität:** Der Claude-Pfad ist bis in Hooks, Accounts und aktuelle
   CLI-Verträge untersucht, der interaktive Codex-Pfad dagegen nicht gleichwertig bei
   Auth/Login, Konfiguration, Resume-Optionen, Statussemantik, Versionsdrift und
   extern importierten Sessions.

`05-roadmap/plan-review.md:9-24,40-49,66-88` erkennt den ersten Punkt bereits korrekt,
ändert aber weder `README.md`, `04-verifikation/verdicts.md` noch die ursprüngliche
Roadmap. Damit existiert eine gute Kritik an der Synthese, aber weiterhin keine
konsolidierte Synthese.

## P0 — Vor der Bezeichnung „Audit abgeschlossen“ zu schließen

### P0.1 · Vollständige Traceability und erneutes Synthese-Gate

`README.md:3-5` meldet „Audit abgeschlossen“, „16 von 16“ und „0 Fehlalarme“.
`04-verifikation/verdicts.md:3-9,13-30` zeigt jedoch, dass ausschließlich 16 ausgewählte
Behauptungen verifiziert wurden, alle aus fünf Fable-Finder-Dokumenten; Codex-Findings,
Runde 2 und die neuen Subsystemkarten liegen außerhalb der Stichprobe. Besonders
gravierend sind etwa die kritischen Supervisor-Befunde
`02-findings/runde2-cli-supervisor-codex.md:9-17,92-105`, die in Verdicts und
`05-roadmap/refactor-roadmap.md` nicht als eigene Maßnahmen vorkommen.

Zusätzlich behauptet `README.md:56`, `01-subsysteme/` sei leer geblieben, obwohl neun
Kartierungen existieren. `02-findings/architektur-wartbarkeit-fable.md:7-9` konserviert
denselben historischen Zwischenstand. Die README-Dokumentliste endet bei den
Erstrunden-Findings (`README.md:51-68`) und verschweigt die komplette Runde 2 sowie
`05-roadmap/plan-review.md`.

**Fehlendes Artefakt:** Eine zeilenweise Matrix mit stabiler Finding-ID, Quelle,
Schweregrad, Refuter-Status, Widerspruchsstatus, Maßnahme oder begründeter
Zurückstellung. Erst nach Abgleich aller Findings darf „abgeschlossen“ erneut gelten.

### P0.2 · Privacy- und Datenlebenszyklus-Audit fehlt

Das Security-Dokument prüft vor allem Environment, argv, Dateimodi und Link-Öffnung.
Es fehlt eine Dateninventur für Audio, selektierten Text, Screenshots, Clips,
Transkripte, Prompts, Agent-Tails, Reports, Logs, Clipboard und Benachrichtigungen mit
Quelle → Verarbeitung → externer Empfänger → lokaler Speicher → Modus → Retention →
Löschung. Ein einzelner Hinweis auf einen lokalen Provider als
„Datenschutz-Argument“ (`05-roadmap/refactor-roadmap.md:405`) ersetzt diese Prüfung nicht.

Das betrifft auch die Produktbehauptung in
`WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:51-52`, wonach History
lokal unter Application Support liege: lokal ist nicht gleich kurzlebig, verschlüsselt
oder nutzerseitig tatsächlich gelöscht.

**Erforderliche Szenarien:** Privacy-Schalter an/aus; Erfolg, Fallback und Crash;
Report-Cleanup; Deinstallation; Userwechsel; Backup/Spotlight; Debug-Logging;
Providerwechsel; minimales Agent-Environment; Export und vollständige Löschung.

### P0.3 · Release-/DMG-/Update-Prozess fehlt vollständig

`01-subsysteme/shared-infra.md:193` betrachtet nur die Logik des Update-Checkers, nicht
die Herstellung oder Vertrauenswürdigkeit des veröffentlichten Artefakts. Nicht geprüft
sind Tag-Autorisierung, Test-Gates, Reproduzierbarkeit, Dependency-/SBOM-Risiko,
Entitlements, Hardened Runtime, Developer-ID-Signierung, Notarisierung, Stapling,
Gatekeeper auf einem sauberen Mac, DMG-Inhalt, Upgrade/Downgrade, Homebrew-Cask,
Checksummen-Publikation, Rollback und TCC-Erhalt.

Das ist kein Randthema: Die App hostet Agent-CLIs, liest Screenshots und Mikrofon und
verteilt ein ausführbares Bundle. Ein Release-Artefakt muss auf einer frischen
macOS-14/15/26-Matrix installiert und geprüft werden; ein erfolgreicher SwiftPM-Build
beweist diesen Vertrag nicht.

### P0.4 · Codex-CLI-Gegenpfad ist nicht symmetrisch auditiert

Codex ist nicht völlig unberücksichtigt: Indexer, Transcript-Reader, Diktat-Tail und der
eigene `codex exec --json`-Supervisor wurden tief geprüft. Es fehlt aber das Gegenstück zu
`03-vergleich/tech-claude-cli-2026.md` und `01-subsysteme/hooks-accounts.md` für den
**interaktiven Codex-CLI-Pfad**:

- Installation, Login/Logout, Credential- und Account-/Org-Wahl;
- `config.toml`, Profile, Environment und precedence von CLI-Flags versus Sessiondaten;
- neue Session, `resume`, Fork/Branch, CWD-/Worktree-Wechsel und externe Importe;
- Approval-, Sandbox-, Netzwerk-, MCP- und Tool-Semantik;
- autoritative Zustände für working/awaitingInput/idle/failed im echten TUI;
- Versions-/Schema-Matrix, Capability-Gating und aktuelle Codex-Eventtypen;
- Abbruch, Quit, Crash-Restart, Doppel-Resume und mehrere gleichzeitige Tabs.

Die Asymmetrie ist sichtbar: Der Claude-Technikreport empfiehlt zehn aktuelle
Host-Fähigkeiten, während Codex im Ökosystemvergleich meist nur als zweiter Reader oder
Provider erwähnt wird. Gerade `02-findings/robustheit-codex.md:254-305` und
`02-findings/runde2-transcript-rendering-codex.md` zeigen bereits Schema-Drift; diese
Signale wurden nicht zu einem providerweiten Kompatibilitätsvertrag verdichtet.

## P1 — Nicht abgedeckte Subsysteme und Szenarien

### P1.1 · Accessibility im Sinn von Bedienbarkeit fehlt

„Accessibility“ bedeutet im Audit fast überall TCC-/AX-Berechtigung oder API-Zugriff,
nicht barrierefreie UI. Es fehlen VoiceOver-Namen, Rollen und Aktionen, vollständige
Tastaturbedienung, Fokusreihenfolge, Full Keyboard Access, Kontrast/Differentiate Without
Color, Reduce Motion, vergrößerte Schrift, Zoom, Terminal-Zugänglichkeit, Hover-only-
Aktionen und Statusmeldungen für Screenreader.

Die Grid-/Tab-Runde prüft Geometrie und sogar RTL, aber keine Assistive-Technology-
Matrix. Erforderlich ist manuelle macOS-QA mit VoiceOver und Tastatur; dafür sind laut
Repo-Konvention keine erfundenen UI-Tests nötig, wohl aber pure Tests für ableitbare
Labels/Aktionen und dokumentierte manuelle Oracles.

### P1.2 · UI-Mehrsprachigkeit und Locale-Verhalten fehlen

Die Diktat-**Sprache** wurde untersucht, nicht die Sprache der App. Es fehlt eine
Trennung von Transkriptionssprache, Prompt-/Modellsprache, UI-Lokalisierung, Locale-
Formatierung und RTL. Zu prüfen sind Strings-Kataloge, Info.plist-Purpose-Strings,
Menüs/Notifications/Fehler, Pluralisierung, Datums-/Zahlenformatierung, Such-/Sortier-
Semantik und gemischte deutsche/englische Oberfläche.

### P1.3 · Update, Downgrade, Backup, Restore und Supportability

Der Update-Checker und einzelne Migrationen sind geprüft, aber nicht der komplette
Lifecycle: altes Bundle → neues Bundle → erste Migration → Rollback auf alte Version;
korruptes/future Schema; Backup/Restore auf anderem Mac; Verlust externer CLI-Daten;
Keychain/TCC; Supportbundle mit Redaction; Nutzerlöschung. `runde2-settings-migration`
findet Teilprobleme, bildet aber keine Versionsmatrix über reale Releases.

### P1.4 · Ressourcen-, Energie- und Langzeitverhalten

Statische Performance- und Leak-Findings sind vorhanden, aber keine Messung mit
Instruments, Allocations, Energy Log, Time Profiler oder realen 50-MB-Transkripten und
2.000 Sessions. Nicht getestet sind 8-Stunden-Lauf, Sleep/Wake, Fast User Switching,
Netzwerkwechsel, Offline→Online, Low Disk, File-Descriptor-/Process-Limits,
Speicherdruck und große Clipboard-/Bild-/Video-Payloads.

### P1.5 · Fehler- und Wiederanlaufmatrix über Subsystemgrenzen

Einzelfindings beschreiben Fehler, aber kein systematisches Fault-Injection-Raster:
App-/CLI-/Supervisor-Kill in jeder Phase, partieller atomarer Write, Disk full,
Permission-Entzug, Gerät abziehen, Provider-Timeout/429/5xx, korrupte JSONL, fehlende
Binary, CLI-Update während Lauf, Hook-Datei löschen/rotieren, Worktree verschieben,
Doppelstart und App-Quit. Gerade die Ketten Diktat→Postprocessing→Report→Paste und
Spawn→Bind→Watch→Resume brauchen End-to-End-Oracles.

### P1.6 · Produkt- und UX-Verträge außerhalb des Happy Path

Es fehlt eine konsistente Prüfung von leeren Zuständen, Undo/Destruktivität,
Bestätigungsdialogen, Fehlermeldungstexten, Clipboard-Ownership, Notification-Klicks,
mehreren Fenstern/Displays/Spaces, Fullscreen, Mission Control, Screen Lock und
Secure Input. Onboarding und Grid wurden separat analysiert, aber nicht als gemeinsame
Journey vom Erststart bis zum ersten erfolgreichen Diktat und Agent-Resume.

## P1 — Neue Findings aus dem Gegenlesen

### NF1 · Privacy-Schalter löscht archivierte visuelle Kontexte nicht

**Schweregrad:** hoch

**Fundort:**
`WhisperM8/Views/Settings/Pages/ContextPrivacySettingsPage.swift:44-52`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:112-140`;
`WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:39-48,72-105,140-187,371-427`;
`WhisperM8/Services/Dictation/VisualContextCaptureService.swift:181-189`

Die UI verspricht „Delete visual context files after processing“. Der Erfolgsweg ruft
jedoch zuerst `saveRunReport` auf; der Report-Store kopiert alle Attachments und
Thumbnails in sein eigenes Verzeichnis und persistiert zusätzlich ausgewählten Text,
gerenderten Prompt sowie Raw-/Final-Transcript. Erst danach löscht `cleanup` ausschließlich
die ursprünglichen Attachment-URLs. Die Kopien bleiben nach Produktionspolicy bis zu
180 Tage, 500 Runs oder 2 GiB erhalten.

**Wirkung:** Ein Nutzer aktiviert eine explizite Löschoption, vertrauliche Screenshots
oder Clips bleiben trotzdem langlebig auf Disk. Der Toggle braucht eine präzise
Formulierung oder muss Reportkopien/Metadaten in denselben Löschvertrag einbeziehen.

### NF2 · Release-Tags umgehen das Test-Gate und verteilen absichtlich nicht notarisiert

**Schweregrad:** hoch

**Fundort:** `.github/workflows/release.yml:1-15,21-30,55-69`;
`.github/workflows/ci.yml:10-14,24-62`;
`scripts/build-dmg.sh:35-55`;
`scripts/update-cask.sh:8-10,28-47`

Der Release-Workflow reagiert auf jeden `v*`-Tag und baut/veröffentlicht direkt, führt
aber weder `swift test` aus noch hängt er von einem erfolgreichen CI-Lauf desselben SHA
ab. CI läuft nur für `main`-Pushes und Pull Requests. Ein Tag auf einem ungetesteten oder
nicht auf `main` liegenden Commit kann damit ein Release erzeugen.

Der Workflow dokumentiert zugleich, dass das öffentliche DMG ad hoc signiert und nicht
notarisiert wird; die Cask entfernt Quarantine per `xattr`. Direkte DMG-Installationen
werden laut `scripts/build-dmg.sh:49-52` von Gatekeeper blockiert. Das ist mindestens ein
klarer Distributions- und Vertrauensmangel; die gewünschte Release-Policy muss explizit
entschieden und getestet werden.

### NF3 · Importierte Codex-Sessions erhalten beim Resume geratene Optionen

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift:80-114`;
`WhisperM8/Services/AgentChats/AgentSessionStore.swift:869-883`;
`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:170-195`

Der Codex-Indexer liefert `reasoningEffort: nil` und gegebenenfalls auch kein Modell.
Beim Import ersetzt der Store fehlende Werte durch die **aktuellen globalen Defaults**.
Jedes spätere `codex resume` erzwingt diese gespeicherten Werte mit `-m` und
`-c model_reasoning_effort=...`.

**Wirkung:** Ein außerhalb WhisperM8s gestarteter Chat kann beim ersten Resume unbemerkt
mit anderem Modell oder anderem Reasoning-Effort fortgesetzt werden. Unbekannt muss als
unbekannt erhalten bleiben; Resume darf nur nachweislich sessioneigene oder bewusst vom
Nutzer geänderte Overrides setzen.

### NF4 · Sensible Titel und stderr werden als öffentliche Unified-Log-Daten markiert

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/Shared/Logger.swift:24-63`;
`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:47-50`;
`WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift:64-71,195-218`;
`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:193-210,340-377`

Der allgemeine Debug-Logger markiert jede Nachricht mit `.public`. Der Diktatpfad loggt
die ersten 100 Zeichen des normalisierten Transkripts; Decode- und HTTP-Fehler loggen bis
zu 500 Zeichen rohe Providerantwort beziehungsweise Fehlerbody. Auto-Naming loggt bis zu
200 Zeichen CLI-stderr und den aus Transcript-Inhalt generierten Titel ebenfalls
explizit `.public`. Damit können Diktat-, Aufgaben- und Projektinhalt, lokale Pfade und
möglicherweise Auth-/Provider-Fehler unabhängig vom optionalen File-Logging im Unified
Log landen. Ist File-Logging aktiviert, wird dieselbe Datenklasse zusätzlich ohne
erkennbare Rotation in `~/Library/Logs/WhisperM8/WhisperM8-debug.log` angehängt.

**Wirkung:** Log-Privacy ist kein reines Dateimodusproblem. Es braucht Datenklassen,
private-by-default Interpolation, Redaction-Tests und ein definiertes Support-Exportformat.

### NF5 · Reduce Motion wird im zentralen Statusindikator ignoriert

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/AgentStatusIndicator.swift:19-31,50-76`

Working und Awaiting Input starten immer eine unendliche Pulsanimation. Ein
`accessibilityReduceMotion`-Environment-Wert oder eine statische Alternative existiert
nicht. Der Zustand ist dauerhaft in vielen Sidebar-Zeilen sichtbar.

### NF6 · Sichtbare Close-Aktionen sind keine zugänglichen Controls

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/AgentChatChromeViews.swift:176-186`;
`WhisperM8/Views/AgentChatsSidebarViews.swift:802-812,1014-1024`

Mehrere Tab-/Sidebar-Close-Aktionen sind `Image(...).onTapGesture`, teilweise nur bei
Hover sichtbar. Sie sind weder eigene `Button`s noch als Accessibility-Aktion
exponiert. Mauslose und VoiceOver-Nutzer können die sichtbare Aktion deshalb nicht
zuverlässig fokussieren und auslösen.

### NF7 · Keine Lokalisierungsarchitektur, gleichzeitig gemischte UI-Sprache

**Schweregrad:** mittel

**Fundort:** `Package.swift:27-51`; `WhisperM8/Info.plist:17-20`;
`WhisperM8/Views/Settings/Pages/AgentChatsSettingsPage.swift:5-24,41-45,202-239`

Das Package enthält keine Strings-Katalog-Ressource; projektweit gibt es weder
`.strings`/`.xcstrings` noch `NSLocalizedString` oder `String(localized:)`. Purpose-
Strings sind fest deutsch, die Agent-Chats-Einstellungen fest englisch, andere
Hauptoberflächen deutsch.

**Wirkung:** Die App ist weder konsistent einsprachig noch lokalisierbar. Vor einer
Übersetzung braucht es einen String-Katalog, stabile Schlüssel, formatierte Argumente,
Pluralregeln und eine Locale-/RTL-QA-Matrix.

### NF8 · DMG verweist auf ein nicht mitgeliefertes Reparaturskript

**Schweregrad:** niedrig

**Fundort:** `scripts/build-dmg.sh:57-83`

Das DMG enthält App, Applications-Link und `LIES MICH.txt`; die Datei empfiehlt bei
Problemen `./scripts/clean-install.sh`. Dieser relative Pfad existiert im DMG und nach
normaler Installation nicht. Der Supporthinweis ist für Endnutzer daher nicht ausführbar.

## P1 — Widersprüche zwischen den Dokumenten

| Priorität | Widerspruch | Belege | Auflösung |
|---|---|---|---|
| P0 | Der Codex-Supervisor sei detacht, bleibt aber nachweislich im PPID-Baum. | Behauptung: `01-subsysteme/background-jobs.md:14,53,87`; Gegenbeweis: `02-findings/runde2-cli-supervisor-codex.md:9-17,36-72`. | Subsystemkarte korrigieren; „neue Session/Prozessgruppe“ nicht mit Ancestry-Unabhängigkeit gleichsetzen. |
| P0 | Notification-Hooks seien Statusquelle, obwohl sie absichtlich nicht registriert sind. | Falsch: `CLAUDE.md:111`, `03-vergleich/claude-session-manager.md:54,90,111`, `03-vergleich/claude-cli-oekosystem.md:68`; korrekt: `01-subsysteme/hooks-accounts.md:15`, `03-vergleich/claude-cli-oekosystem.md:86`. | Alle Architekturbeschreibungen auf die tatsächlichen acht Events und `PermissionRequest` korrigieren. |
| P0 | Der RuntimeWatcher-Generation-Guard sei „ohne Befund“, während ein konkreter Reset-Kollisionspfad belegt ist. | `02-findings/races-agentchats-fable.md:7-16` versus `02-findings/races-agentchats-codex.md:295-334`. | „Ohne Befund“ zurückziehen und Finding tracebar in Synthese/Roadmap aufnehmen. |
| P1 | Fehlender Onboarding-Completion-State sei bewusst unproblematisch, verhindert aber die Wiederaufnahme unvollständigen Setups. | `02-findings/runde2-settings-migration-codex.md:226-230` versus `02-findings/runde2-onboarding-permissions-codex.md:85-131`. | Produkterwartung entscheiden; der zweite Bericht belegt für den heutigen Startvertrag ein reales Loch. |
| P1 | Kein Konkurrent nutze selbstgewählte Session-IDs, Nimbalyst tut es produktiv. | `README.md:39-41`, `03-vergleich/claude-cli-oekosystem.md:60` versus `03-vergleich/tech-claude-cli-2026.md:137-145,169-171`. | Feldvergleich und Alleinstellungsbehauptung aktualisieren. |
| P1 | Alles unter `~/.claude`/`~/.codex` sei read-only, während Account-Umzug Transkripte verschiebt. | `CLAUDE.md:114` und `03-vergleich/workflow3-kandidaten.md:265-267` versus `01-subsysteme/hooks-accounts.md:38,94-96,124-125`. | Entweder explizite Ausnahme samt Copy+Verify-Vertrag dokumentieren oder Mutation als Architekturverletzung einstufen. |
| P1 | Codex-Livestatus wird generisch als funktionsfähig beschrieben, obwohl aktuelle Eventtypen das Turn-Ende nicht erreichen. | `01-subsysteme/runtime-status.md:9,38-42,92` versus `02-findings/robustheit-codex.md:254-305`. | Versions-/Schemaeinschränkung in die Subsystemkarte und Supportmatrix übernehmen. |
| P1 | Roadmap verspricht, ein Wrapper entschärfe auch spätere Realtime-Thread-Exceptions. | `02-findings/crash-diktat-fable.md:78,211` und `05-roadmap/refactor-roadmap.md:20-28`; zugleich braucht C02 die Generation/Revalidation in `refactor-roadmap.md:36-44`. | Trampolin-Scope präzisieren; ein Wrapper um Startaufrufe fängt keinen späteren Callback-Thread-Abort. |
| P2 | Derselbe Befund driftet im Severity-Level. | Zombie-Engine: `01-subsysteme/diktat.md:86` kritisch, `04-verifikation/verdicts.md:16` hoch; Recorder-Race: `01-subsysteme/diktat.md:88` hoch, `verdicts.md:17` mittel/eingeschränkt. | Eine zentrale Severity-Definition und letzte autoritative Bewertung je Finding einführen. |
| P2 | Persistenzdateiname in der Architekturdoku ist falsch. | `CLAUDE.md:114` nennt `agent-index-cache.json`; `01-subsysteme/indexierung.md:21` und `02-findings/runde2-settings-migration-codex.md:23` nennen `agent-session-index-cache.json`. | CLAUDE.md korrigieren und Pfadtests/Doku aus einer Quelle generieren. |

## P2 — Unbelegte oder unzureichend lokalisierte Behauptungen

Die Auditregel verlangt für jede Behauptung `Datei:Zeile` (`WORKPLAN.md:60-64`). Sie wird
nicht konsistent eingehalten:

- `02-findings/architektur-wartbarkeit-fable.md:16` und `:151` nennen im Fundort nur
  ganze Dateien plus LOC; `:215` nur ein gesamtes Dokument. Einzelbeispiele im Beweis
  reparieren nicht alle Größen-, Vollständigkeits- und Delta-Behauptungen.
- `README.md:45-49` und `03-vergleich/claude-session-manager.md:89-93` verwenden
  Superlative wie „einziges Tool“, „100 % Feature-Parität“ und „kein Vergleichsprojekt“
  ohne reproduzierbare Suchgrenze oder lokale Datei:Zeile-Belege.
- `03-vergleich/tech-claude-cli-2026.md:139-147,159-171` belegt zentrale
  Wettbewerberclaims mit absoluten `/private/tmp/.../scratchpad/...`-Pfaden. Diese
  Quellen sind nach dem Agentlauf weder portabel noch für Reviewer verfügbar.
- Empirische Werte wie 58k LOC, 1.300+ Tests, 495 Workspace-Einträge oder
  Wettbewerberaktivität haben keinen eingecheckten Abfragebefehl, Rohdatensatz und
  Zeitstempel pro Wert. Teilweise werden verschiedene Nenner nebeneinander verwendet
  (356 JSONL-Dateien versus 495 Workspace-Sessions), ohne im README die Population zu
  benennen.
- Negative Vollständigkeitsbehauptungen („kein anderes Tool“, „keine Fehlalarme“,
  „alle Findings“) brauchen Scope, Suchstrategie und Gegenbeispielkriterien. Der heutige
  Freitext erlaubt nicht zu unterscheiden zwischen „nicht gefunden“, „nicht geprüft“ und
  „nicht vorhanden“.

**Empfehlung:** Jeder Finding-Header erhält maschinenlesbar `id`, `severity`, `status`,
`code_refs`, `evidence_kind`, `verified_by`, `supersedes`; externe Klone werden per
Repository+Commit+relativem Pfad zitiert, relevante kleine Fixtures/Abfrageausgaben
werden eingecheckt oder reproduzierbar skriptiert.

## P2 — Blinde Flecken der Methodik

1. **Statisch statt empirisch:** Der Großteil lief ohne Build, Test oder Reproduktion;
   `architektur-wartbarkeit-fable.md:3-5` und `races-agentchats-fable.md:5` sagen das
   explizit. Es fehlen TSan, ASan, Instruments, Crashlogs, echte TCC- und Geräte-QA.
2. **Selektionsbias der Verifikation:** Die „16 wichtigsten“ Claims wurden nicht nach
   dokumentierter Population oder Zufalls-/Risikostichprobe ausgewählt und stammen nur
   aus der Fable-Linie. Bestätigung statischer Erreichbarkeit ist keine Häufigkeits- oder
   Runtime-Reproduktion.
3. **Keine unabhängige Severity-Kalibrierung:** Refuter prüfen Wahrheitskern, aber keine
   zentrale Impact×Likelihood-Matrix; dadurch entstehen die dokumentierten Drifts.
4. **Ein Entwicklerbestand als Beweis:** Private `~/.claude`-/`~/.codex`-Bestände sind
   realistisch, aber nicht anonymisiert, eingecheckt oder reproduzierbar. Sie können
   lokale Historie, Version und Nutzungsmuster übergewichten.
5. **Vergängliche externe Evidenz:** Live-Webstände und lokale Scratch-Klone werden ohne
   dauerhaftes Manifest/Commit-Snapshot verwendet; Sternzahlen und Produktverhalten sind
   zeitabhängig.
6. **Keine Coverage-Matrix:** 42 Dokumente erzeugen viel Umfang, aber keine Zuordnung
   Codeverzeichnis/Feature/Journey × Analyse/Test/manuelle QA. Daher konnten Privacy,
   Release, A11y, Lokalisierung und Codex-Parität unbemerkt fehlen.
7. **Keine End-to-End-Oracles:** Unit-nahe Befunde dominieren; die kritischen
   Transaktionen über Audio, Filesystem, Subprozess, Store, Hook und UI werden nicht als
   zusammenhängender Vertrag getestet.
8. **Keine Baselines für Performance/Memory:** Komplexität und Timeouts werden aus Code
   abgeleitet, aber ohne p50/p95/p99, Hardware, Datenmenge und Vorher/Nachher-Messung.
9. **Keine explizite Threat-/Privacy-Modellierung:** Assets, Trust Boundaries, Angreifer,
   Datenklassen, Retention und Redaction fehlen; Security-Findings bleiben punktuell.
10. **Synthese vor Abschluss der Finder-Runden:** README/Roadmap wurden finalisiert,
    bevor spätere Runde-2-Dokumente integriert waren. `plan-review.md` diagnostiziert
    das, aber der Workflow besitzt kein automatisches „alle Quellen verarbeitet“-Gate.

## Minimales Nachaudit vor einer neuen Abschlussmeldung

1. Finding-Register aus allen Dokumenten erzeugen, Duplikate/Widersprüche auflösen und
   alle kritischen/hohen Befunde adversarial nachprüfen.
2. Privacy-/Logging-Datenfluss und Release-/DMG-Vertrag als eigene Subsystemreports mit
   realer macOS-QA ergänzen; NF1/NF2 zuerst verifizieren.
3. Einen Codex-CLI-Paritätsreport mit Versionsmatrix, externen Importen und
   Resume-Optionen erstellen; NF3 als Golden-/Command-Builder-Testfall aufnehmen.
4. Accessibility- und Lokalisierungsbaseline erstellen; VoiceOver/Tastatur/Reduce
   Motion sowie mindestens Deutsch/Englisch und RTL manuell prüfen.
5. Fault-Injection- und Langzeitmatrix auf repräsentativen Fixtures ausführen; Ergebnisse
   mit Environment, CLI-Version, macOS-Version und Messwerten archivieren.
6. Erst dann README, Verdicts, Roadmap, CLAUDE.md und alle Subsystemkarten in einem
   finalen Konsistenzlauf aktualisieren.
