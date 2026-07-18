---
status: aktiv
updated: 2026-07-18
description: Runde-3-Audit der GPT-Agent-Definition, Backend-Settings und gebündelten GPT-/Codex-Skill-Ressourcen mit Fokus auf Ownership, Multi-Profil-Propagation, Kill-Switch-Races, Fehlertransparenz und Ressourcendrift.
---

# Runde 3: GPT-Backend — Definition, Settings und Skill-Ressourcen

## Umfang und Methode

Statisch geprüft wurden `ClaudeGPTAgentDefinition.swift`,
`GPTBackendSettingsPage.swift`, die GPT-Erweiterungen in `AppPreferences.swift`,
`CLISkillsSettingsPage.swift`, `CLISkillExporter.swift`, die vier gebündelten
`whisperm8-agent-skill*.md`-Ressourcen sowie die Account-Profil- und
Launch-Aufrufer. Zusätzlich wurden die Commits `21506b2`, `67a2eeb` und
`feac0c0` read-only verglichen. Es wurden keine Builds oder Tests ausgeführt und
keine Produktdateien geändert.

**Bilanz:** fünf Findings — zwei hoch, drei mittel. Der Marker-Schutz der
`gpt.md` ist grundsätzlich richtig: eine fremde, unmarkierte Agent-Definition
wird weder überschrieben noch beim Deaktivieren entfernt
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:64-76`;
`Tests/WhisperM8Tests/ClaudeGPTAgentDefinitionTests.swift:78-99`). Auch der
Multi-Root-Fix aus `21506b2` adressiert den ursprünglichen Profilfehler korrekt,
indem er Main und alle aktuell entdeckten Profil-Roots enumeriert
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:26-35`).

Read-only-Negativchecks am Audit-Rechner: Die eingecheckte
`.claude/skills/codex-subagent/`-Kopie, alle vier gebündelten Ressourcen und die
aktuell unter `~/.claude/skills/codex-subagent/` installierten Dateien waren
bytegleich. Es liegt also **heute keine Datei-Drift** dieser Kopien vor. Das
unten beschriebene Update- und Konsistenzproblem bleibt trotzdem im Codepfad
vorhanden; außerdem widerspricht sich bereits der aktuelle gebündelte Inhalt.

## G01 — Skill-Installation überschreibt gleichnamige User-Dateien und besitzt keinen reversiblen Ownership-Lifecycle

**Schweregrad:** hoch

### Beleg

- Das Ziel ist allein durch den globalen Namen bestimmt:
  `~/.claude/skills/<name>/SKILL.md`; eine Owner-ID, ein Managed-Marker oder ein
  Installationsmanifest existiert nicht
  (`WhisperM8/Services/Shared/CLISkillExporter.swift:18-24,102-119`).
- Bereits das Vorhandensein irgendeiner Datei an diesem Pfad gilt als
  „installiert“. Abweichender Inhalt wird lediglich als „nicht aktuell“
  klassifiziert (`WhisperM8/Services/Shared/CLISkillExporter.swift:121-143`).
- `installForClaudeCode()` schreibt `SKILL.md` und alle drei bekannten
  Reference-Dateinamen bedingungslos atomar neu. Nur **zusätzliche** fremde
  Dateien im Reference-Ordner bleiben erhalten
  (`WhisperM8/Services/Shared/CLISkillExporter.swift:145-174`).
- Die UI nennt eine beliebige abweichende Installation nur „Update Skill“ und
  führt den überschreibenden Pfad ohne Diff, Backup oder Konfliktbestätigung aus
  (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:255-280`). Das
  Testmodell kodifiziert dieses Verhalten ausdrücklich mit beliebigem
  `"old content"`, das beim Update ersetzt wird
  (`Tests/WhisperM8Tests/CLISkillExporterTests.swift:147-157`).
- Dieselbe Karte bietet Installieren/Aktualisieren, Speichern, Kopieren und
  Anzeigen, aber kein Deinstallieren oder Wiederherstellen
  (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:198-220`). Auch
  der Exporter endet nach dem Installationspfad ohne Remove-API
  (`WhisperM8/Services/Shared/CLISkillExporter.swift:145-176`).

### Szenario

Der User hat bereits einen eigenen oder von einem anderen Tool installierten
Skill namens `codex-subagent` und lokale Inhalte in `SKILL.md` oder etwa
`references/claude-workflows.md`. WhisperM8 zeigt lediglich „Update Skill“.
Ein Klick ersetzt diese Dateien ohne Warnung und ohne Backup. Umgekehrt bleiben
WhisperM8s Skill und seine Referenzen nach Entfernen der App dauerhaft unter
`~/.claude/skills/`; sie verweisen weiter auf das dann gegebenenfalls nicht mehr
vorhandene `whisperm8`-CLI und auf das GPT-Backend. Es gibt weder eine sichere
Zuordnung „von WhisperM8 verwaltet“ noch einen UI-Pfad zum sauberen Rückbau.

### Fix-Skizze

Einen WhisperM8-spezifischen Ownership-Marker plus Manifest mit Hashes und
installierter Ressourcenversion einführen. Fremde oder seit der Installation
manuell veränderte Dateien als echten Konflikt anzeigen und nur nach Diff,
Backup und expliziter Bestätigung ersetzen; alternativ einen kollisionsarmen
Skill-Namen verwenden. Eine Deinstallationsaktion darf ausschließlich Dateien
entfernen, deren Marker und letzter installierter Hash passen, und muss lokale
Zusatzdateien unangetastet lassen.

## G02 — Skill-Propagation deckt `CLAUDE_CONFIG_DIR`-Profile nicht zuverlässig ab

**Schweregrad:** mittel

### Beleg

- Der Skill-Exporter kennt genau ein Ziel unter
  `homeDirectory/.claude/skills`; im Gegensatz zum Agent-Definition-Installer
  enumeriert er keine `ClaudeAccountProfiles`
  (`WhisperM8/Services/Shared/CLISkillExporter.swift:58-69,102-119`). Die UI
  behauptet entsprechend nur, Claude Code lese aus `~/.claude/skills`
  (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:189-196`).
- Profil-Sessions erhalten jedoch explizit ihr eigenes `CLAUDE_CONFIG_DIR`
  (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:190-204`). Dass
  User-Level-Konfiguration dort und nicht automatisch in `~/.claude` gesucht
  wird, ist bereits die Begründung für den Multi-Root-Fix der `gpt.md`
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:26-35`).
- Neue Profile verlinken `skills` zwar in den Main-Root, aber nur wenn die Quelle
  **zum Erstellungszeitpunkt bereits existiert**; fehlt sie, wird der Eintrag
  still übersprungen und später nicht repariert
  (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:225-233,259-272`).

### Szenario

Ein User legt zuerst ein Claude-Account-Profil an, während
`~/.claude/skills` noch nicht existiert. `createProfile` erstellt deshalb keinen
`skills`-Symlink. Später installiert er in „CLI & Skills“ den GPT-/Codex-Skill.
Der Exporter schreibt nur in den Main-Root. Claude-Sessions des Zusatzprofils
laufen mit dessen `CLAUDE_CONFIG_DIR` und sehen den Skill nicht, obwohl die UI
„Installed“ meldet. Dasselbe gilt für extern angelegte Profile mit bewusst
separatem `skills`-Ordner. Der Status ist global und kann die Teilinstallation
nicht darstellen.

### Fix-Skizze

Wie bei `ClaudeGPTAgentDefinitionInstaller` alle aktuellen Config-Roots
inventarisieren und einen Status pro Root anzeigen. Für app-eigene Profile die
Shared-Symlinks bei jeder Profil-/Settings-Aktualisierung idempotent reparieren;
bei absichtlich eigenständigen Profilordnern nur nach Ownership-/Konfliktprüfung
installieren. Tests brauchen mindestens: Profil vor Skill-Installation, externes
Profil ohne Symlink, fremde gleichnamige Datei in nur einem Root und partieller
Schreibfehler.

## G03 — Multi-Root-Sync der `gpt.md` ist nicht serialisiert und kann den Kill-Switch rückgängig machen

**Schweregrad:** hoch

### Beleg

- Ein Sync erfasst `backendEnabled` und Modell als Werte und schreibt danach die
  Roots sequenziell über `fileURLs.map`; es gibt weder Lock noch Generation oder
  erneute Sollwertprüfung zwischen den Roots
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:50-60`).
- Die Settings starten eigene Syncs sowohl beim Umschalten des Backends als auch
  bei jeder Modelländerung
  (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-85`).
- Gleichzeitig kann ein Chat-Launch `ensureRunning` in einem Detached Task
  ausführen (`WhisperM8/Views/AgentSessionDetailView.swift:393-405`). Nach
  erfolgreichem Proxy-/Router-Start ruft der Manager einen weiteren
  `syncFromPreferences`-Pfad auf
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:149-150,169-174,272-277`).
  Der `ensureLock` des Managers schützt nur dessen Startsequenz, nicht die
  Settings-Aufrufe des eigenständigen Installers.
- Die einzelnen Writes sind atomar, der **Batch über alle Roots** ist es nicht
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:79-94`).

### Szenario

Bei mehreren Account-Profilen läuft noch ein älterer Enable-Sync mit
`backendEnabled == true`. Er hat Main geschrieben und pausiert vor Profil B.
Der User deaktiviert das Backend; der Settings-Sync entfernt die bisher
sichtbaren Definitionen. Danach setzt der ältere Sync seine Schleife fort und
legt `Profil-B/agents/gpt.md` wieder an. Der Schalter steht auf „aus“, aber ein
Profil behält den nativen GPT-Agent-Typ. Analog können zwei Modell-Syncs
unterschiedlicher Generationen Main und Profile auf verschiedene Modellnamen
setzen. Atomare Einzeldateien verhindern diesen finalen Mischzustand nicht.

### Fix-Skizze

Definition-Sync als einen serialisierten Actor beziehungsweise eine dedizierte
Queue mit monotoner Preference-Generation ausführen. Jede Operation muss vor
jedem Commit prüfen, ob ihre Generation noch aktuell ist; Disable invalidiert
alle älteren Enable-/Modell-Syncs. Das Ergebnis soll den final verifizierten
Zustand **aller** Roots enthalten. Deterministische Race-Tests mit Barrieren
zwischen Root A und Root B müssen Enable↔Disable und Modell A↔B abdecken.

## G04 — Dateifehler und fremde `gpt`-Konflikte bleiben unsichtbar; Remove meldet sogar fälschlich Erfolg

**Schweregrad:** mittel

### Beleg

- Beim Deaktivieren wird `removeItem` mit `try?` ausgeführt und anschließend
  bedingungslos `.removed` zurückgegeben. Ob die Datei wirklich verschwunden
  ist, wird nicht geprüft
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:73-76`).
- Ein fehlgeschlagener Write wird zwar geloggt, aber als `.nothingToDo`
  zurückgegeben — derselbe Wert wie ein legitimer No-op
  (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:79-94`).
- Eine fremde gleichnamige Definition erzeugt den aussagekräftigen Outcome
  `.leftForeignFileAlone` (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:64-70`),
  doch beide Settings-Aufrufer verwerfen das komplette Outcome-Array
  (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-85`).
- Auch der Manager abstrahiert den Syncer zu `() -> Void` und meldet nach
  erfolgreichem Router-Start `.success`, unabhängig davon, ob der für native
  GPT-Subagents benötigte aktuelle Profil-Root geschrieben werden konnte
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:149-150,169-174,272-277`).

### Szenario

`~/.claude/agents/gpt.md` ist user-eigen und unmarkiert, oder ein Profil-Root
ist wegen ACL, immutable flag oder defektem Symlink nicht schreibbar. Der User
aktiviert das Backend. Proxy und Router werden grün, die Settings zeigen keinen
Konflikt, aber der Agent-Typ fehlt oder zeigt weiterhin auf eine fremde
Definition. Beim Deaktivieren kann derselbe Dateifehler die verwaltete Datei auf
Platte lassen, während der Installer `.removed` behauptet und die Settings den
Status ohnehin verwerfen. Das widerspricht dem dokumentierten Lifecycle
„deaktiviert → entfernen“
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:9-11`).

### Fix-Skizze

`sync` soll ein strukturiertes, nicht verschlucktes Ergebnis pro Root liefern:
`written`, `removed`, `foreignConflict`, `readFailed`, `writeFailed`,
`removeFailed`, jeweils mit Pfad und Fehler. Nach Write/Remove den Ist-Zustand
verifizieren. Settings müssen Konflikte und partielle Installation sichtbar
anzeigen. Für einen Launch, der den nativen `gpt`-Typ benötigt, darf ein Fehler
im relevanten Profil-Root nicht als vollständiges Ready gelten; bei reinem
Claude-Launch kann der Router separat ready sein, der Agent-Definitionsstatus
muss aber ehrlich getrennt bleiben.

## G05 — Die gebündelte Skill-Dokumentation widerspricht sich; App-Updates propagieren Korrekturen nur manuell

**Schweregrad:** mittel

### Beleg

- Der aktuelle Wegweiser erklärt Dynamic-Workflow-Steps ausdrücklich zum
  nativen GPT-Pfad via `agentType: "gpt"`
  (`WhisperM8/Resources/whisperm8-agent-skill.md:12-25`).
- Dieselbe aktuelle `SKILL.md` behauptet später weiterhin, jeder Codex-Aufruf im
  Workflow müsse über einen Claude-Wrapper-Subagenten laufen, und verweist dafür
  auf die alte Reference-Datei
  (`WhisperM8/Resources/whisperm8-agent-skill.md:307-319`).
- Die gebündelte Reference formuliert sogar „Der Weg führt immer über einen
  Claude-Subagenten“ und empfiehlt anschließend `codex-runner` beziehungsweise
  manuelle Sonnet-/Haiku-Wrapper
  (`WhisperM8/Resources/whisperm8-agent-skill-ref-claude-workflows.md:9-23,26-45`).
  Das steht direkt gegen den neuen nativen Standard im Wegweiser.
- Der Update-Check vergleicht zwar Bundle und Installation bytegenau
  (`WhisperM8/Services/Shared/CLISkillExporter.swift:125-143`), aber die
  Aktualisierung geschieht nur beim manuellen Install-/Update-Button. `onAppear`
  aktualisiert lediglich die Anzeige
  (`WhisperM8/Views/Settings/Pages/CLISkillsSettingsPage.swift:238-243,255-280`).

### Szenario

Ein Agent lädt nur den Wegweiser und nutzt den schnellen nativen
`agentType: "gpt"`; ein anderer folgt dem späteren Workflow-Kapitel oder der
Reference und baut weiterhin die verschachtelte Kette
`Claude-Wrapper → whisperm8 agent → codex exec`. Beide handeln nach derselben
aktuellen Ressource, aber mit gegensätzlicher Architektur, Kosten- und
Lifecycle-Wirkung. Bei einem User mit einer vor `feac0c0` installierten Kopie
bleibt zusätzlich selbst der Wegweiser alt, bis er die Settings-Seite öffnet und
bewusst „Update Skill“ klickt. Ein App-Update allein propagiert die korrigierte
Ressource nicht.

### Fix-Skizze

Eine kanonische, strukturierte Quelle für Routingregeln und Workflow-Beispiele
verwenden und daraus Bundle-Ressource, Repository-Skill und References erzeugen
oder per CI auf semantische Schlüsselregeln prüfen. Das komplette
Dynamic-Workflow-Kapitel samt Reference auf „nativ standardmäßig, CLI nur für
Codex-spezifische Fähigkeiten“ umstellen. Managed-Installationen mit
Ressourcenversion versehen und nach App-Update sichtbar als „Update verfügbar“
melden; automatische Updates nur für unveränderte, eindeutig WhisperM8-eigene
Dateien, niemals für G01-Konflikte.

## Priorität und positive Befunde

1. **Sofort:** G01 und G03 — potenzieller User-Dateiverlust beziehungsweise ein
   Kill-Switch, den ein älterer Multi-Root-Sync wieder überholen kann.
2. **Danach:** G04 — Definition und Router brauchen getrennte, ehrliche
   Readiness sowie sichtbare Fehler pro Profil.
3. **Anschließend:** G02 und G05 — Profilpropagation und Skill-Quellen auf einen
   versionierten, ownership-sicheren Lifecycle vereinheitlichen.

Beibehalten werden sollten der Foreign-File-Schutz der `gpt.md`, atomare
Einzeldatei-Writes, der in `21506b2` ergänzte Multi-Root-Grundansatz und der
bytegenaue Current-Check für `SKILL.md` plus References
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:64-94`;
`WhisperM8/Services/Shared/CLISkillExporter.swift:125-143`). Sie lösen die
Ownership-, Batch- und Propagationsprobleme noch nicht, sind aber die richtige
Basis für deren Korrektur.
