---
status: abgeschlossen
updated: 2026-07-18
description: Adversariale Vollverifikation aller fünf Runde-3-Findings zu GPT-Agent-Definition, Backend-Settings, Account-Profilen und gebündelten Skill-Ressourcen gegen Aufrufer, Task-Kontexte, Locks, Tests und Commit-Entscheidungen.
---

# Runde 3: Verifikation GPT-Definition und Settings

## Auftrag, Methode und Bewertungsmaßstab

Geprüft wurden **alle fünf** Findings aus
`02-findings/runde3-gpt-backend-definition-settings.md` gegen den aktuellen Code
auf `main`. Für jedes Finding wurden die zitierten Implementierungen, sämtliche
produktiven Aufrufer, Task-/Thread-Grenzen, Lock-Reichweiten, Tests und die
Commit-Messages `21506b2`, `67a2eeb` und `feac0c0` gelesen. Es wurden keine
Builds, Tests oder Produktprozesse ausgeführt und keine Produktdateien geändert.

Urteile:

- **BESTAETIGT:** Das konkrete Auslöseszenario ist aus dem aktuellen Code ableitbar und wird durch vorhandene Guards nicht ausgeschlossen.
- **WIDERLEGT:** Abschnittshierarchie, Guard, Aufrufervertrag oder Implementierungsdetail verhindert beziehungsweise entkräftet das behauptete Szenario.
- **UNKLAR:** Der Repository-Code reicht nicht aus, um Auslösung oder Verhinderung belastbar zu entscheiden.

**Gesamturteil:** Vier Findings sind bestätigt, eines ist widerlegt. G03 ist enger
als sein Titel: Der Race kann den Dateilifecycle des deaktivierten Backends
verletzen und Roots mischen, schaltet aber für sich allein das Router-Environment
eines neuen Launches nicht wieder ein. G05 liest zwei ausdrücklich getrennte Wege
als Widerspruch; das spätere Workflow-Kapitel steht jedoch unter dem expliziten
CLI-Kapitel und beschreibt ausschließlich Codex-/`whisperm8`-Aufrufe.

## G01 — Skill-Installation überschreibt gleichnamige User-Dateien und besitzt keinen reversiblen Ownership-Lifecycle

**Urteil:** **BESTAETIGT**

**Eigener Schweregrad:** **hoch**

### Exakte Ausführung

1. Der Zielpfad wird ausschließlich aus Home-Verzeichnis und dem generischen
   Skill-Namen gebildet: `.claude/skills/<name>/SKILL.md`. `SkillDefinition`
   enthält nur Name, Bundle-Ressource und Reference-Liste; weder Owner-ID noch
   Installationsmanifest oder Hash-Metadaten existieren
   (`WhisperM8/Services/Shared/CLISkillExporter.swift:18-24,58-69,102-119`).
2. Jede existierende Datei an genau diesem Pfad macht
   `isInstalledForClaudeCode == true`. Der Current-Check unterscheidet nur
   bytegleich versus abweichend; Herkunft und lokale Änderung werden nicht
   unterschieden
   (`WhisperM8/Services/Shared/CLISkillExporter.swift:121-143`).
3. `installForClaudeCode()` lädt den Bundle-Inhalt und schreibt anschließend
   `SKILL.md` sowie jede verwaltete Reference bedingungslos mit
   `atomically: true` auf die namensgleichen Ziele. Nur zusätzliche, nicht in
   `definition.references` gelistete Dateien werden mangels Verzeichnis-Cleanup
   erhalten
   (`WhisperM8/Services/Shared/CLISkillExporter.swift:145-174`).
4. Die Settings übersetzen jeden abweichenden Inhalt in denselben Buttontext
   „Update Skill“. Ein Klick ruft unmittelbar den überschreibenden Exporter auf;
   es gibt davor weder Diff, Backup, Konfliktanzeige noch zweite Bestätigung
   (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:198-220,255-280`).
5. Der Test simuliert genau einen beliebigen abweichenden Inhalt (`"old content"`)
   und erwartet nach erneutem Installieren den Bundle-Stand. Ein separater Test
   schützt lediglich **zusätzliche** fremde Reference-Dateien, nicht
   `SKILL.md` oder die drei namensgleichen verwalteten References
   (`Tests/WhisperM8Tests/CLISkillExporterTests.swift:89-122,147-157`).
6. Der Exporter endet nach `installForClaudeCode()` ohne Remove-/Restore-API;
   die Karte bietet nur Install/Update, Save, Copy und View
   (`WhisperM8/Services/Shared/CLISkillExporter.swift:145-176`;
   `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:198-220`).

Damit läuft das Finding-Szenario exakt: Eine fremde `codex-subagent/SKILL.md`
oder fremde Datei mit einem der drei verwalteten Reference-Namen wird als
„installiert, nicht aktuell“ dargestellt und nach dem ausdrücklich angebotenen
„Update“ irreversibel ersetzt. Die App kann diese Dateien später nicht
ownership-sicher zurückbauen.

### Aktiv gesuchte Gegenbelege

- Der Schreibvorgang ist pro Datei atomar. Das schützt vor halben **Dateiinhalten**,
  nicht vor dem Verlust des vorherigen Inhalts oder einem partiellen Satz aus
  neuer `SKILL.md` und alten References
  (`WhisperM8/Services/Shared/CLISkillExporter.swift:151-170`).
- Zusätzliche lokale Reference-Dateien bleiben tatsächlich erhalten und dieser
  positive Vertrag ist getestet
  (`Tests/WhisperM8Tests/CLISkillExporterTests.swift:108-123`). Er schützt aber
  gerade nicht die kollidierenden Zieldateien.
- Schreibfehler erreichen den Settings-Alert
  (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:273-280`). Das ist
  Fehlertransparenz nach dem Versuch, keine Ownership-Prüfung vor dem Überschreiben.
- Der User muss den „Update Skill“-Button anklicken; es ist kein stiller
  Auto-Update-Pfad. Der Button benennt den entscheidenden Unterschied zwischen
  „veraltete WhisperM8-Kopie“ und „fremder gleichnamiger Skill“ jedoch nicht
  (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:255-280`).

### Schluss

Das Finding ist vollständig bestätigt. **Hoch** ist angemessen, weil ein normaler,
als Update formulierter UI-Pfad user-eigene Dateien ohne Backup zerstören kann und
mangels Marker/Manifest keine sichere Wiederherstellung oder Deinstallation
möglich ist.

## G02 — Skill-Propagation deckt `CLAUDE_CONFIG_DIR`-Profile nicht zuverlässig ab

**Urteil:** **BESTAETIGT**

**Eigener Schweregrad:** **mittel**

### Exakte Ausführung

Der Exporter besitzt genau ein `homeDirectory` und leitet daraus ausschließlich
`<home>/.claude/skills/<name>/...` ab. Er kennt weder
`ClaudeAccountProfiles` noch eine Liste von Config-Roots
(`WhisperM8/Services/Shared/CLISkillExporter.swift:58-69,102-119`). Die Anzeige
misst folglich nur diese eine Main-Datei und behauptet bei deren Existenz global
„Installed“
(`WhisperM8/Services/Shared/CLISkillExporter.swift:121-143`;
`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:189-203,255-267`).

Zusatzprofile werden dagegen mit einem eigenen `CLAUDE_CONFIG_DIR` gestartet;
nur `main` verwendet implizit `~/.claude`
(`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:190-204`). Der Code
bestätigt außerdem ausdrücklich, dass User-Level-Agents je Profil-Root gesucht
werden und deshalb `gpt.md` in **alle** Roots geschrieben werden muss
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:26-35`).

Für app-eigene Profile soll ein `skills`-Symlink den Unterschied überbrücken.
`skills` steht in `sharedItems`, aber `createProfile` erzeugt den Symlink nur,
wenn die Main-Quelle in diesem Moment bereits existiert; Fehler werden mit
`try?` verworfen. Es gibt in diesem Service keinen späteren Reparaturlauf für
diese Shared-Symlinks
(`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:225-233,255-275`).
Der vorhandene Profiltest legt nur `settings.json` **vor** der Profilerstellung
an und prüft genau diesen positiven Fall; „Profil vor Skills-Ordner“ ist nicht
abgedeckt
(`Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:139-152`).

Damit ist das konkrete Szenario deterministisch aus dem Code ableitbar:
Profilverzeichnis zuerst, Main-`skills` später. Beim Profilbau wird `skills`
übersprungen; die spätere Skill-Installation erstellt nur den Main-Pfad. Der
Profil-Launch verwendet weiterhin seinen separaten Config-Root und der globale
Status bleibt dennoch „Installed“.

### Aktiv gesuchte Gegenbelege

- Existiert `~/.claude/skills` bereits beim Erstellen eines app-eigenen Profils,
  legt `createProfile` den Shared-Symlink an. In diesem Normalfall propagiert ein
  späteres Main-Update über den Symlink korrekt
  (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:230-233,265-272`).
  Auch die Commit-Message `67a2eeb` dokumentiert genau diese beabsichtigte
  Shared-Ordner-Architektur. Der Existenz-Guard lässt den im Finding beschriebenen
  umgekehrten Erstellungszeitpunkt aber offen.
- `profiles()` entdeckt alle nicht versteckten Profil-Unterordner
  (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:54-68`). Das hilft
  Indexer und `gpt.md`-Installer, der Skill-Exporter ruft diese Enumeration jedoch
  nirgends auf
  (`WhisperM8/Services/Shared/CLISkillExporter.swift:58-69,102-119`).
- Extern angelegte Profile dürfen absichtlich getrennte Skills haben. Das widerlegt
  nicht den app-eigenen Missing-Source-Fall und macht einen einzigen globalen
  Installed-Status für solche Roots erst recht unvollständig.

### Schluss

Das Finding ist bestätigt. **Mittel** ist angemessen: Der Fehler löscht keine Daten,
macht den Skill aber in einem real unterstützten Account-Profil unsichtbar und
meldet zugleich fälschlich einen vollständigen Installationszustand.

## G03 — Multi-Root-Sync der `gpt.md` ist nicht serialisiert und kann den Definition-Lifecycle des Kill-Switches überholen

**Urteil:** **BESTAETIGT**

**Eigener Schweregrad:** **mittel**

### Exakte Ausführung und Task-Kontext

Der Installer ist ein synchroner, zustandsloser Value-Type. Ein Batch läuft als
sequenzielles `fileURLs.map`; die Bool-/Modellwerte sind Parameter-Snapshots. Es
gibt weder statischen Lock noch Queue, Actor, Generation oder Cancellation-Prüfung
zwischen zwei Roots
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:12-20,26-35,50-60`).
Jeder einzelne Write ist atomar, der Root-Satz nicht
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:79-94`).

Der belastbare konkurrierende Pfad ist nicht auf zwei Settings-Callbacks
angewiesen:

1. Ein Chat-Launch startet `ensureRunning` in `Task.detached`, also außerhalb des
   MainActor
   (`WhisperM8/Views/AgentSessionDetailView.swift:387-405`).
2. Der Manager hält `ensureLock` zwar über seine gesamte Startsequenz und ruft
   nach Router-Erfolg den `agentDefinitionSyncer` auf
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:155-156,218-223,272-277`).
   Der Default-Syncer erstellt einen eigenständigen Installer
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:169-174`).
3. `syncFromPreferences()` liest Backend-Schalter und Modell genau einmal und
   übergibt beide Werte anschließend an den nicht abbrechbaren Multi-Root-Batch
   (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:97-103`).
4. Parallel ruft die Settings-Seite denselben Installer direkt beim Toggle und
   bei Modelländerung auf. Diese Aufrufe erwerben den `ensureLock` des Managers
   nicht
   (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-85`).

Bei Roots `[main, profil]` ist deshalb das behauptete Interleaving möglich:
Ein Detached-Ensure liest noch `enabled=true`, schreibt Main und wird zwischen
den `map`-Elementen verdrängt. Der Settings-Disable-Batch entfernt Main und
Profil. Danach schreibt der alte Detached-Batch Profil erneut. Analog kann ein
älterer Modellbatch nach dem neueren Batch nur den letzten Root zurücksetzen.
`ensureLock` serialisiert lediglich mehrere Manager-Ensures; der direkte
Settings-Pfad teilt diesen Lock nicht
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-223,272-277`;
`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-85`).

### Aktiv gesuchte Gegenbelege und Eingrenzung

- Zwei reine Settings-Ereignisse müssen nicht als parallele Ursache unterstellt
  werden. Der produktive Detached-Manager-Pfad liefert bereits einen zweiten
  Executor und umgeht den Manager-Lock über den direkten Settings-Aufruf
  (`WhisperM8/Views/AgentSessionDetailView.swift:393-405`;
  `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-85`).
- `syncFromPreferences()` liest die Preferences erst unmittelbar vor seinem
  Batch. Das verkleinert das stale Fenster gegenüber einem Snapshot am Anfang
  von `ensureRunning`, beseitigt aber den Wechsel **nach** Zeile 100 und während
  des `map` nicht
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:53-55,97-103`).
- Die Multi-Root-Tests prüfen nur sequenzielle vollständige Enable- und
  Disable-Batches. Barrieren, parallele Installer oder Modellgenerationen kommen
  nicht vor
  (`Tests/WhisperM8Tests/ClaudeGPTAgentDefinitionTests.swift:40-76`).
- Der Titel des Ursprungsfindings ist zu weit, wenn „Kill-Switch rückgängig“ als
  vollständiges Wiederaktivieren des Routers gelesen wird: Bei ausgeschaltetem
  Backend soll ein neuer Launch ohne Proxy-Argumente und -Environment starten
  (`WhisperM8/Support/AppPreferences.swift:257-262`). Eine stale `gpt.md` allein
  setzt dieses Environment nicht. Bestätigt sind der gebrochene Dateilifecycle
  „deaktiviert → entfernen“, ein weiterhin sichtbarer, dann nicht routbarer
  Agent-Typ in einzelnen Profilen und gemischte Modellstände
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:3-11,73-94`).

### Schluss

Der Race und der finale Mischzustand sind bestätigt; die Wirkung ist enger als
eine komplette Reaktivierung des Backends. Deshalb **mittel** statt des
ursprünglichen „hoch“: Der Defekt kann Agent-Typen beziehungsweise Modelle pro
Profil inkonsistent machen und fehlerhafte GPT-Spawns provozieren, umgeht aber
allein nicht den Router-Kill-Switch eines neuen Launches.

## G04 — Dateifehler und fremde `gpt`-Konflikte bleiben für den User unsichtbar; Remove kann fälschlich Erfolg melden

**Urteil:** **BESTAETIGT**

**Eigener Schweregrad:** **mittel**

### Exakte Ausführung

Der Read wird mit `try?` auf `String?` reduziert. Ein Lesefehler ist dadurch
nicht von „Datei fehlt“ unterscheidbar
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:60-65`). Beim
Disable gilt:

- `existing == nil` führt direkt zu `.nothingToDo`, auch wenn die Datei nur
  nicht lesbar war;
- bei lesbarem Managed-Inhalt wird `removeItem` mit `try?` ausgeführt und danach
  ohne Ist-Prüfung immer `.removed` zurückgegeben.

Beide Pfade stehen unmittelbar im Code
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:66-76`). Ein
fehlgeschlagener Enable-/Update-Write wird zwar geloggt, aber als
`.nothingToDo` zurückgegeben, also derselbe Outcome wie ein legitimer No-op
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:79-94`).

Der Foreign-File-Guard selbst ist korrekt und liefert
`.leftForeignFileAlone`
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:64-70`). Die
beiden Settings-Aufrufer ignorieren jedoch das gesamte Outcome-Array und setzen
keinen sichtbaren Fehler-/Konfliktzustand
(`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-85`). Beim
Manager ist die Abstraktion sogar `() -> Void`; nach Router-Erfolg wird der Sync
aufgerufen und anschließend unabhängig von dessen Dateiergebnissen `.success`
zurückgegeben
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:138-153,169-174,272-277`).
Der Manager-Test prüft entsprechend nur, dass die Void-Closure einmal ausgeführt
wird, nicht ob alle Roots geschrieben wurden
(`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:211-220`).

Damit sind alle drei Szenarien belegt: fremde Definition bleibt ohne UI-Hinweis,
Write-Fehler wird zum No-op, und ein Remove-Fehler kann als `.removed` erscheinen.
Der Manager kann gleichzeitig Router-Readiness melden, obwohl der native
Agent-Typ im relevanten Config-Root fehlt.

### Aktiv gesuchte Gegenbelege

- Foreign Files werden nicht überschrieben oder entfernt; der Test belegt Enable
  und Disable
  (`Tests/WhisperM8Tests/ClaudeGPTAgentDefinitionTests.swift:78-99`). Das ist ein
  wichtiger Datenintegritäts-Guard, aber keine User-Transparenz.
- Foreign- und Write-Probleme landen im Logger
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:66-70,88-92`).
  Das widerlegt „völlig unsichtbar“ im diagnostischen Log, nicht die Behauptung
  über Settings und Manager-Readiness.
- Der Erfolgsfall „Disable entfernt wirklich“ ist getestet
  (`Tests/WhisperM8Tests/ClaudeGPTAgentDefinitionTests.swift:49-54`). Der Test
  injiziert keinen FileManager-Fehler und kann den verschluckten Remove-Fehler
  daher nicht entkräften.

### Schluss

Das Finding ist bestätigt. **Mittel** ist angemessen: Es droht wegen des
Foreign-Guards kein User-Dateiverlust, aber die UI kann einen partiellen oder
fehlgeschlagenen Agent-Definitionszustand als gesund erscheinen lassen und der
Outcome-Vertrag kann nach Remove sogar objektiv falsch sein.

## G05 — Behaupteter Dokumentationswiderspruch; App-Updates propagieren Skill-Korrekturen nur manuell

**Urteil:** **WIDERLEGT**

### Gegenbeleg: Die Dokumentation trennt die Wege ausdrücklich

Der Wegweiser definiert den nativen `gpt`-Agent-Typ als Standard und grenzt den
CLI-Weg auf Codex-spezifische Fähigkeiten ein. Für Dynamic Workflows nennt er
explizit `agent(..., {agentType: "gpt", schema})`; CLI/`codex-runner` bleibt für
Bilder und detachte Jobs
(`WhisperM8/Resources/whisperm8-agent-skill.md:6-25`).

Der angeblich widersprechende spätere Abschnitt steht nicht auf derselben
semantischen Ebene:

1. Bereits in Zeile 57 beginnt das übergeordnete Kapitel
   `# CLI-Weg (explizit): Codex-Subagents via whisperm8 agent`
   (`WhisperM8/Resources/whisperm8-agent-skill.md:57-66`).
2. `## Einsatz in Claude Dynamic Workflows` ist ein Unterkapitel genau dieses
   CLI-Wegs. Sein Text sagt präzise „Codex-Jobs“ und „jeder Codex-Aufruf“; er
   behauptet nicht, jeder GPT-Workflow-Step müsse über den Wrapper laufen
   (`WhisperM8/Resources/whisperm8-agent-skill.md:307-319`).
3. Die Reference heißt `Codex-Subagents in Claude Dynamic Workflows`. Ihr
   „Weg führt immer über einen Claude-Subagenten“ begründet sie damit, dass das
   Workflow-Skript selbst `whisperm8` nicht aufrufen kann; das Diagramm endet
   ausdrücklich in `whisperm8 agent run` und `codex exec`
   (`WhisperM8/Resources/whisperm8-agent-skill-ref-claude-workflows.md:1-24`).
   `codex-runner` und manuelle Wrapper werden folgerichtig als bequemer und
   generischer **CLI-Wrapper** beschrieben
   (`WhisperM8/Resources/whisperm8-agent-skill-ref-claude-workflows.md:26-45`).

Die Aussagen sind daher kompatibel: Native GPT-Workflow-Steps verwenden
`agentType: "gpt"`; ein bewusst gewählter Codex-CLI-Step braucht wegen des
fehlenden Shellzugriffs des Workflow-Skripts einen Claude-Wrapper. Das im
Finding beschriebene Szenario „zwei Agenten erhalten gegensätzliche
Architekturvorgaben“ entsteht nur, wenn die Überschriften `CLI-Weg
(explizit)` und `Codex-Subagents` aus ihrem Geltungsbereich entfernt werden.
Die Commit-Message `feac0c0` bestätigt diese beabsichtigte Trennung zusätzlich:
nativ ist Standard, `codex-runner` bleibt für Codex-Spezifisches.

### Bestätigter Teilfakt, der das Finding nicht rettet

Die Update-Propagation ist tatsächlich user-initiiert. `onAppear` ruft nur
`refresh()` auf; dieser liest Bundle-Inhalt und Current-Status, schreibt aber
nichts. Erst der Install-/Update-Button ruft `installForClaudeCode()` auf
(`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:238-243,255-280`).
Der bytegenaue Vergleich erkennt veraltete Installationen korrekt
(`WhisperM8/Services/Shared/CLISkillExporter.swift:125-143`).

Das ist jedoch kein Beleg für den behaupteten **inhaltlichen Widerspruch** und
wegen G01 zugleich die sichere derzeitige Voreinstellung: Ohne Ownership-Marker
darf ein App-Update einen möglicherweise fremden gleichnamigen Skill gerade
nicht automatisch überschreiben
(`WhisperM8/Services/Shared/CLISkillExporter.swift:121-170`). Der reale Mangel ist
damit G01s fehlende Herkunfts-/Update-Differenzierung, nicht eine sich
widersprechende aktuelle Skill-Anleitung.

### Schluss

G05 wird als Finding widerlegt. Der sekundäre Fakt „kein automatisches
Propagieren nach App-Update“ stimmt, aber die aktuelle Ressource enthält zwei
bewusst getrennte und semantisch kompatible Ausführungspfade. Ohne sicheren
Ownership-Lifecycle wäre automatisches Überschreiben zudem keine zulässige
Gegenmaßnahme.

## Ergebnistabelle

| ID | Kurzfassung | Urteil | Eigener Schweregrad | Wichtigste Verifikationsstelle |
|---|---|---|---|---|
| G01 | Generischer Zielname, overwrite ohne Ownership/Restore | **BESTAETIGT** | hoch | `WhisperM8/Services/Shared/CLISkillExporter.swift:102-176` |
| G02 | Profil vor Main-`skills` erhält keinen später reparierten Symlink | **BESTAETIGT** | mittel | `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:225-275` |
| G03 | Detached-Manager-Sync und Settings-Sync teilen keinen Batch-Lock | **BESTAETIGT** | mittel | `WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:50-103`; `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-277` |
| G04 | Read/Write/Remove-Fehler werden verschluckt oder falsch klassifiziert | **BESTAETIGT** | mittel | `WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:60-94` |
| G05 | Native GPT- und explizite Codex-CLI-Workflow-Doku widersprechen sich | **WIDERLEGT** | — | `WhisperM8/Resources/whisperm8-agent-skill.md:6-25,57-66,307-319` |

**Bilanz:** 4× BESTAETIGT, 1× WIDERLEGT, 0× UNKLAR; davon nach eigener
Einordnung 1× hoch und 3× mittel.

## Die drei wichtigsten bestätigten Findings

1. **G01 — Der Update-Button kann fremde Skill-Dateien irreversibel ersetzen.**
   Der globale Name ist die einzige Identität; Byte-Abweichung wird als Update
   behandelt, und es gibt weder Marker/Manifest noch Backup oder Remove-Pfad
   (`WhisperM8/Services/Shared/CLISkillExporter.swift:102-176`;
   `WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:255-280`).
2. **G03 — Der Multi-Root-Batch ist nicht gegen den parallelen Detached-Launch
   serialisiert.** Ein alter Preference-Snapshot kann nach einem Disable-/Modell-
   Sync den letzten Profil-Root zurückschreiben; atomare Einzeldateien verhindern
   den gemischten Endzustand nicht
   (`WhisperM8/Views/AgentSessionDetailView.swift:387-405`;
   `WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:50-103`).
3. **G04 — Router-Erfolg und Agent-Definitions-Erfolg sind nicht gekoppelt.**
   Remove- und Read-Fehler werden verschluckt, Write-Fehler als No-op kodiert,
   Settings verwerfen Outcomes und der Manager abstrahiert den Sync zu Void
   (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:60-94`;
   `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:138-153,272-277`).
