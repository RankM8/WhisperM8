---
status: abgeschlossen
updated: 2026-07-19
description: Finalrunden-Audit der session-scoped Context-Profile mit Fokus auf Account-Profil-Propagation, Settings-Lifecycle, Environment-Overlays, Persistenz und Migration.
---

# Runde 4: Context-Profile — Profilgrenzen, Lifecycle und Persistenz

## Gegenstand und Methode

Statisch geprüft wurden das Modell und der Store der Context-Profile, die Komposition der `--settings`-Datei, der interaktive und der Background-Launch, Account-Profile (`CLAUDE_CONFIG_DIR`), Resume/Fork, Background-Respawn, Retention und die vorhandenen Context-Profil-Tests. Es wurden keine Builds, Tests oder Prozesse ausgeführt.

**Bilanz:** sieben Findings — vier hoch, drei mittel. Die schwersten Fehler liegen nicht im JSON-Shape, sondern an den Integrationsgrenzen: Background-Agenten verlieren das aktive Account-Profil, Settings-I/O fällt trotz eines wirksamen Restriktionsprofils offen aus, Background-Respawn übernimmt Profiländerungen nicht, und der Env-Filter lässt genau jene `CLAUDE_CODE_*`-Variablen wieder zu, die der Basis-Environment-Code zur Vermeidung kaputter Transcripts entfernt.

## R4-CP-01 — Background-Agenten verlieren das aktive Claude-Account-Profil

**Schweregrad:** hoch

### Beleg

- Normale neue Claude-Sessions stempeln das aktuell aktive Account-Profil explizit als `claudeProfileName` (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:58-76`).
- Der Background-Dispatch erzeugt seine Session dagegen ohne `claudeProfileName`; der Store-Parameter hat den Default `nil` und wird so in die Session übernommen (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:48-64`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:541-568`).
- Der Spawn übergibt weder Account-Profil noch Environment-Overrides (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:85-95`; `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-112`). Sein Default-Runner verwendet ausschließlich `LoginShellEnvironment` (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:247-258`), das geerbtes `CLAUDE_CONFIG_DIR` ausdrücklich entfernt (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:110-119`).
- Auch der spätere Attach leitet das Account-Environment ausschließlich aus `session.claudeProfileName` ab; bei dem Background-Stempel `nil` bleibt es Main (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:280-294,372-388`).

### Auslöse-Szenario

Der User aktiviert Account-Profil `kunde-b` und dispatcht aus einem Projekt einen Background-Agenten mit Context-Profil. Anders als ein normaler neuer Chat startet `claude --bg` ohne `CLAUDE_CONFIG_DIR`, nutzt daher den Main-Account und speichert auch lokal `claudeProfileName = nil`. Requests, Supervisor-Job, Attach sowie spätere Lifecycle-Kommandos laufen damit im falschen Account-Kontext. Das kann Kosten, Berechtigungen und erreichbare Connector-Daten dem falschen Account zuordnen.

### Fix-Skizze

Beim Dispatch das aktive `claudeProfileName` genauso wie im normalen Create-Pfad stempeln. `BackgroundAgentSpawner` und `ProcessRunner` müssen explizite Environment-Overrides akzeptieren und `ClaudeAccountProfiles.environmentOverrides(forProfile:)` auf den bereinigten Login-Env mergen. Dasselbe Profil muss an `logs`/`stop`/`respawn`/`rm` und Health-Checks weitergereicht werden; die Short-ID allein ist keine accountübergreifend ausreichende Identität. Einen Integrationstest ergänzen, der für ein sekundäres Profil sowohl Spawn-Env als auch gespeicherten Stempel und Lifecycle-Env prüft.

**Nicht durch Tests abgedeckt:** `ClaudeContextProfileTests` testet weder Background-Dispatch noch Account-Profile; die Spawner-Tests prüfen Argumente/Parsing, aber die `ProcessRunner`-Schnittstelle besitzt gar keinen Environment-Parameter (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:4-6`; `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:223-230`).

## R4-CP-02 — Ein Settings-Schreibfehler startet trotz Restriktionsprofil uneingeschränkt

**Schweregrad:** hoch

### Beleg

- MCP-Denies, deaktivierte `.mcp.json`-Server und Plugin-Overrides existieren nur im Settings-Fragment (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:26-42`).
- Schlägt das Erzeugen oder Schreiben der Datei fehl, fängt `ClaudeHookBridge` den Fehler ab, loggt nur und liefert `nil` (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:86-118`).
- Der Coordinator transportiert keinen Fehlerzustand, sondern bildet `nil` auf leere Settings-Argumente ab (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:102-135`). Der interaktive Launch baut und startet danach trotzdem den Command (`WhisperM8/Views/AgentSessionDetailView.swift:512-527`).
- Beim Background-Dispatch ist der Fail-open sogar dokumentierter Ablauf: kein Pfad beziehungsweise I/O-Fehler führt zu einem Spawn ohne Settings (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:73-95`).

### Auslöse-Szenario

Ein Profil sperrt Gmail, deaktiviert einen lokalen Browser-MCP und schaltet ein Plugin ab. Das App-Support-Verzeichnis ist vorübergehend nicht beschreibbar, voll oder die Zieldatei kollidiert mit einem Verzeichnis. Der Settings-Write scheitert. WhisperM8 startet den Chat beziehungsweise Background-Agenten trotzdem; beim interaktiven Launch können zwar die separat gesetzten Env-Werte wirken, die MCP-/Plugin-Restriktionen fehlen jedoch vollständig. Der User erhält keine Fehlermeldung und arbeitet im Glauben an ein wirksames Restriktionsprofil.

### Fix-Skizze

`prepareLaunchSettings` muss zwischen „kein Overlay nötig“ und „Overlay gefordert, aber Erzeugung fehlgeschlagen“ unterscheiden. Bei einem nichtleeren Context-Fragment fail-closed: Launch blockieren und einen handlungsfähigen UI-Fehler zeigen. Nur ein reiner optionaler Hook-Fehler darf nach expliziter Produktentscheidung degradiert werden. Für Background-Spawns denselben Gate anwenden. Tests mit nicht beschreibbarem Settings-Root für interaktiv und Background ergänzen und sicherstellen, dass kein Prozessstart erfolgt.

**Nicht durch Tests abgedeckt:** Die Coordinator-Tests prüfen nur die vier erfolgreichen Matrixfälle Hooks × Profil (`Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift:227-254`). Der einzige Unwritable-Test betrifft die Profilliste, nicht die Launch-Settings (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:106-115`).

## R4-CP-03 — Background-Respawn verwendet ein dauerhaft altes Context-Overlay

**Schweregrad:** hoch

### Beleg

- Beim initialen Dispatch wird das aktuelle Projektprofil genau einmal aufgelöst und in die session-spezifische Settings-Datei geschrieben; der Kommentar verspricht, Profiländerungen würden „ab Respawn“ wirken (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:43-48,73-83`).
- Die Settings-Datei ist stabil an die lokale Session-UUID gebunden (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:145-158`).
- Der UI-Respawn ruft jedoch ausschließlich `claude respawn <short-id>` auf. Er löst weder `session.contextProfileID` neu auf noch ruft er `prepareLaunchSettings` erneut auf (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:171-199`; `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:99-106`).

### Auslöse-Szenario

Ein Background-Agent wurde mit `ENABLE_TOOL_SEARCH=auto` und ohne Gmail-Deny gestartet. Danach ändert der User dasselbe Profil auf einen Gmail-Deny und einen neuen Env-Wert, stoppt den Agenten und klickt „Respawn“. Die per Session gespeicherte Settings-Datei bleibt unverändert; kein Codepfad bringt die neuen Profilwerte in den Supervisor-Job. Der respawnte Agent läuft deshalb mit dem alten Overlay, obwohl UI-Kommentar und Session-Stempel Aktualisierung ab Respawn erwarten. Besonders kritisch ist das bei nachträglich verschärften Connector-/MCP-Sperren.

### Fix-Skizze

Vor `respawn` das anhand von `session.contextProfileID` aufgelöste Profil erneut in die bestehende session-spezifische Settings-Datei schreiben und erst danach den Supervisor anstoßen. Falls der Supervisor Settings beim Respawn nicht erneut liest, ist ein echter Remove-und-Neuspawn mit atomarer Short-ID-Umbindung nötig; das Verhalten darf nicht nur angenommen werden. Settings-Generation und Respawn als eine fehlerschließende Operation behandeln. Test: Profil v1 schreiben, zu v2 mutieren, Respawn auslösen und v2 im tatsächlich konsumierten Job-Setup nachweisen.

**Nicht durch Tests abgedeckt:** Die Context-Profil-Suite testet Fragmentform und Store-Auflösung, aber keinen Background-Lifecycle (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:147-196`).

## R4-CP-04 — Legacy- und „ohne Profil“-Sessions erben beim Resume nachträglich den Projekt-Default

**Schweregrad:** mittel

### Beleg

- Das Session-Modell beschreibt `contextProfileID` als stabilen Startstempel, dessen Werte erst beim Launch frisch aufgelöst werden (`WhisperM8/Models/AgentChat.swift:315-320`).
- Alte Sessions dekodieren ein fehlendes Feld zu `nil` (`WhisperM8/Models/AgentChat.swift:428-466`); der Test bestätigt nur dieses Decode-Ergebnis (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:201-226`).
- `resolvedProfile` interpretiert `nil` jedoch nicht als „damals ohne Profil“, sondern fällt auf den aktuellen Projekt-Default zurück (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:103-123`). Genau diese Auflösung wird bei jedem interaktiven Start/Resume verwendet (`WhisperM8/Views/AgentSessionDetailView.swift:513-525`).

### Auslöse-Szenario

Eine Session existiert bereits vor Commit `0ecc26a` oder wurde zu einem Zeitpunkt ohne Projektprofil erstellt. Später weist der User dem Projekt ein Context-Profil zu und resumiert die alte Session. Obwohl sie keinen Startstempel besitzt, erhält sie plötzlich neue MCP-, Plugin- und Env-Regeln. Damit ist `nil` gleichzeitig „Legacy/ausdrücklich keines“ und „Projekt-Default jetzt erben“; die behauptete Session-Stabilität gilt nicht für den gesamten Altbestand.

### Fix-Skizze

Das Persistenzmodell braucht drei Zustände: nicht migriert, explizit ohne Profil, konkrete Profil-ID. Bei der Migration bestehende Sessions deterministisch auf „explizit keines“ setzen; nur beim Erstellen neuer Sessions darf der damalige Projekt-Default einmalig in einen konkreten Stempel aufgelöst werden. Alternativ eine `contextProfileStampVersion` beziehungsweise ein `usesProjectContextProfile`-Flag einführen. Tests müssen Decode plus anschließende Auflösung unter einem später gesetzten Projekt-Default abdecken.

**Nicht durch Tests abgedeckt:** `testProjectAndSessionDecodeWithoutContextProfileID` endet bei `XCTAssertNil`; es kombiniert die Legacy-Session nicht mit einem Projekt-Default und einem Resume (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:201-227`).

## R4-CP-05 — Der Env-Blacklist-Filter reintroduziert verbotene Claude-Prozessidentität

**Schweregrad:** hoch

### Beleg

- `LoginShellEnvironment` entfernt bewusst **alle** `CLAUDE_CODE_*`-Variablen, weil insbesondere `CLAUDE_CODE_CHILD_SESSION` und `CLAUDE_CODE_SESSION_ID` neue Launches als verschachtelte Child-Session markieren und dadurch das eigene Transcript ausbleiben kann (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:94-107`).
- Das Context-Profil sperrt dagegen nur sieben exakte Namen; aus der gesamten `CLAUDE_CODE_*`-Familie ist allein `CLAUDE_CODE_SUBAGENT_MODEL` reserviert (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:13-24`). Die Filterung ist ein exakter Set-Lookup (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:65-67`).
- Zulässige Profilwerte werden sowohl als Settings-`env` als auch als Prozess-Override ausgegeben (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:38-41,56-63`). Diese Overrides werden nach dem bereinigten Basis-Env in den Launch eingesetzt (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:178-183,286-294`; `WhisperM8/Views/AgentTerminalView.swift:787-815`).
- Der Editor prüft lediglich denselben unvollständigen Set-Lookup (`WhisperM8/Views/Settings/Pages/AgentChatsContextProfilesTab.swift:294-306`). Auch weitere Routing-/Credential-Familien wie nicht explizit gelistete `ANTHROPIC_*`, `WHISPERM8_*`, Proxy- oder Provider-Variablen passieren den Filter.

### Auslöse-Szenario

Ein importiertes, hand-editiertes oder versehentlich kopiertes Profil enthält `CLAUDE_CODE_CHILD_SESSION=1` und `CLAUDE_CODE_SESSION_ID=<alt>`. Der Basis-Environment-Code entfernt die Werte zunächst korrekt; das Context-Overlay setzt sie danach wieder ein. Der neue Chat kann sich als Child verhalten, kein eigenes Transcript schreiben und beim späteren Resume mit „No conversation found“ scheitern. Analog kann ein nicht gelistetes `ANTHROPIC_*`- oder Provider-Routing-Flag die Account-/Backend-Annahmen des Launches verändern, obwohl der Builder-Kommentar verspricht, das Profil könne Account-Routing, Router und Credentials nicht kapern (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:178-182`).

### Fix-Skizze

Kein wachsendes Exact-Key-Blacklist-Modell verwenden. Mindestens Prefix-Verbote für `CLAUDE_CODE_`, `CLAUDE_CONFIG_DIR`, interne `WHISPERM8_`-Identität und credential-/routingwirksame `ANTHROPIC_*`-/Provider-/Proxy-Familien zentral definieren; besser eine Allowlist der tatsächlich vorgesehenen Context-Schalter (`ENABLE_CLAUDEAI_MCP_SERVERS`, `ENABLE_TOOL_SEARCH` usw.) plus bewusst gekennzeichneten Advanced-Modus. Dieselbe Policy muss Editor, Decode/Store und beide Ausgabekanäle schützen. Regressionstest mit `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID` und mehreren nicht exakt gelisteten `ANTHROPIC_*`-Keys ergänzen.

**Nicht durch Tests abgedeckt:** Der Reserved-Key-Test prüft nur vier gesperrte Exact-Keys und einen erlaubten Key; Prefix-Familien und die Reintroduction nach `LoginShellEnvironment` fehlen (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:170-187`).

## R4-CP-06 — Env-Secrets liegen in zwei Klartextdateien und bleiben für archivierte Sessions erhalten

**Schweregrad:** mittel

### Beleg

- Profile persistieren beliebige Environment-Werte direkt als `[String: String]` (`WhisperM8/Models/ClaudeContextProfile.swift:21-24,50-59`). Der Profilstore serialisiert den vollständigen Bestand als JSON und schreibt atomisch, setzt aber keine expliziten POSIX-Rechte (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:147-156`).
- Für jeden Launch wird dasselbe Env zusätzlich in die session-spezifische Settings-Datei kopiert (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:38-41`). Diese zweite Datei wird zwar auf `0600` gesetzt (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:75-92`).
- Beim Stop werden Settings und Event-Datei ausdrücklich nicht gelöscht (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:201-205`). Die Retention läuft nur beim App-Start und betrachtet **jede** Workspace-Session als live, ohne `archivedAt` oder Status auszufiltern (`WhisperM8/WhisperM8App.swift:255-260`). Der Pruner behält deshalb Dateien aller noch gespeicherten, auch archivierten Sessions (`WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift:18-29,38-54`).
- Sind Hooks aus und Profil/Fragment inzwischen leer, liefert die Vorbereitung sofort `.none`, ohne eine alte Settings-Datei derselben Session zu entfernen (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:114-135`).

### Auslöse-Szenario

Ein User legt etwa `DATABASE_URL`, einen projektspezifischen Token oder Cloud-Credentials als Env-Overlay ab. Der Wert liegt dauerhaft in `claude-context-profiles.json` und nach einem Launch zusätzlich in `<session-uuid>.json`. Später löscht er das Profil, archiviert den Chat oder deaktiviert Hooks. Die alte session-spezifische Datei kann weiterhin erhalten bleiben; weil archivierte Sessions zum Keep-Set zählen, entfernt auch ein Neustart sie nicht. Das Overlay wird dann nicht zwingend erneut angewendet, das Secret bleibt aber als Klartextartefakt zurück.

### Fix-Skizze

Secret-Werte nicht als normale Profilfelder behandeln: Keychain-Referenzen beziehungsweise redigierte Secret-Slots verwenden. Bis dahin Profildatei und Verzeichnis explizit auf `0600`/`0700` härten, im UI klar vor Secrets warnen und sensible Key-Familien ablehnen. Beim Übergang zu `.none`, bei Profillöschung, Session-Archivierung/-Löschung und nach Prozessende unbenötigte Settings-Dateien sicher entfernen oder ohne Env neu schreiben. Retention nach Status/TTL ausrichten und nicht alle historischen Workspace-IDs unendlich behalten.

**Nicht durch Tests abgedeckt:** Store-Tests prüfen Roundtrip und Rollback, aber keine Dateirechte oder Secret-Redaction (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:34-65,106-115`). Die vorhandene Retention-Abdeckung prüft verwaiste IDs, nicht archivierte Keep-IDs oder das Leeren einer zuvor secret-haltigen Settings-Datei (`Tests/WhisperM8Tests/AgentTranscriptReaderTests.swift:249-266`).

## R4-CP-07 — Atomische Writes verhindern keine Lost Updates zwischen Store-Instanzen

**Schweregrad:** mittel

### Beleg

- Jede Store-Instanz lädt die komplette Datei einmalig in ihr eigenes `profiles`-Array (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:19-21,56-59`).
- `upsert` und `delete` mutieren diesen Snapshot und persistieren anschließend stets den kompletten Bestand (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:69-98,147-156`). Es gibt weder File-Lock noch Reload-before-write, Revision/CAS oder Registry pro `fileURL`.
- `@MainActor` und `.shared` serialisieren nur Zugriffe innerhalb **eines** App-Prozesses (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:12-17`); `.atomic` schützt lediglich vor einer teilweise geschriebenen Datei, nicht vor Last-writer-wins mit einem veralteten Snapshot (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:155-156`).

### Auslöse-Szenario

Zwei App-Instanzen werden parallel gestartet, etwa explizit per `open -n`. Beide laden `[A]`. Instanz 1 ergänzt Profil B und schreibt `[A,B]`. Instanz 2 ergänzt aus ihrem alten Snapshot Profil C und schreibt `[A,C]`; B ist ohne Konflikt oder Warnung verloren. Dasselbe gilt für Delete-versus-Edit. Die Datei bleibt syntaktisch korrekt, weshalb Quarantäne und Rollback den Verlust nicht erkennen.

### Fix-Skizze

Für die Profildatei dieselbe Single-Writer-Disziplin wie beim Workspace erzwingen: pro kanonischer URL eine Registry innerhalb des Prozesses und für Mehrprozess-Sicherheit File-Lock plus Revision/CAS beziehungsweise Read-merge-write unter Lock. Bei Revisionskonflikt nicht still überschreiben, sondern neu laden und die ID-basierte Mutation erneut anwenden. Test mit zwei Store-Instanzen auf derselben URL, interleavten Upserts sowie Delete-versus-Update ergänzen.

**Nicht durch Tests abgedeckt:** Die Suite erzeugt zwar zum Reload eine zweite Store-Instanz, mutiert aber nie zwei bereits geladene Instanzen gegeneinander (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:36-64`).

## Positive Befunde

- Session-Stempel schlagen vorhandene Projekt-Defaults; ein gelöschter konkreter Stempel fällt bewusst nicht still auf ein anderes Profil zurück (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:109-123`).
- Die Settings-Datei kombiniert Hooks und Context-Fragment deterministisch in genau ein `--settings`-Dokument und setzt dieses Dokument auf `0600` (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:80-114`; `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:75-92`).
- Store-Mutationen rollen In-Memory-Änderungen bei Persistenzfehlern zurück; die Tests decken diesen lokalen Fehlerpfad ab (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:69-98`; `Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:106-115`).
- Die Decode-Migration ist feldweise lenient und ein einzelnes unlesbares Profil verwirft nicht den gesamten restlichen Bestand (`WhisperM8/Models/ClaudeContextProfile.swift:48-59`; `WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:23-54`).

## Priorität

1. **Sofort:** R4-CP-01, R4-CP-02 und R4-CP-05 — falscher Account, Fail-open von Restriktionen und erneute Child-Session-Identität gefährden die Launch-Wahrheit.
2. **Danach:** R4-CP-03 — Background-Respawn muss verschärfte Profile zuverlässig übernehmen.
3. **Migration und Datenhygiene:** R4-CP-04 und R4-CP-06 gemeinsam lösen, damit Alt-Sessions nicht semantisch umkippen und alte Klartext-Overlays verschwinden.
4. **Persistenzhärtung:** R4-CP-07 mit revisionsgesicherter Single-Writer-Strategie schließen.
