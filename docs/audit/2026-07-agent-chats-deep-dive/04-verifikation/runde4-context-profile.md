---
status: abgeschlossen
updated: 2026-07-19
description: Adversariale Verifikation der vier hohen und zweier mittlerer Context-Profile-Findings aus Runde 4 gegen den Code-Stand HEAD.
---

# Verifikation Runde 4: Context-Profile

## Prüfrahmen

Der Ausgangsbericht enthält **7 Findings: 0 kritisch, 4 hoch, 3 mittel, 0 niedrig**. Vollständig geprüft wurden alle vier hohen Findings. Von den drei mittleren Findings wurden gemäß Prüfauftrag zwei adversarial stichprobenartig geprüft; R4-CP-06 wurde nur gezählt. Es wurden weder Builds noch Tests ausgeführt.

**Bilanz der sechs geprüften Findings:** fünf BESTAETIGT, eines für den behaupteten Produktpfad WIDERLEGT. R4-CP-06 erhält bewusst kein Sachurteil.

## Vollprüfung der hohen Findings

### R4-CP-01 — Background-Agenten verlieren das aktive Account-Profil

**Urteil: BESTAETIGT. Eigene Schwere: mittel statt hoch.**

Normale neue Claude-Sessions stempeln das aktive Account-Profil als `claudeProfileName` (`WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:58-77`). Der Background-Dispatch erstellt seine Session dagegen ohne diesen Parameter; dessen Store-Default ist `nil` und wird unverändert persistiert (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:43-64`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:522-568`). Auch der Spawn repariert das nicht: `BackgroundAgentSpawner.spawn` und `ProcessRunner.run` besitzen keinen Environment-Parameter, und der echte Runner verwendet nur das Login-Environment (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-112,223-258`). Dieses entfernt geerbtes `CLAUDE_CONFIG_DIR` ausdrücklich (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:110-119`). Attach leitet das Account-Environment ausschließlich aus dem damit `nil` gebliebenen Session-Stempel ab (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:280-294,372-388`).

**Gegenbeleg/Abwertung:** Die Settings kommunizieren ausdrücklich, dass Background-Agenten derzeit immer den Main-Account verwenden (`WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:24-30`). Der Datenfluss ist damit bestätigt, aber als transparente v1-Grenze kein hochschwerer stiller Account-Wechsel.

### R4-CP-02 — Settings-Schreibfehler fällt bei Restriktionsprofil offen aus

**Urteil: BESTAETIGT. Eigene Schwere: hoch.**

MCP-Denies, deaktivierte `.mcp.json`-Server und Plugin-Overrides existieren ausschließlich im Settings-Fragment; nur das Profil-Environment besitzt zusätzlich einen Prozesskanal (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:26-42,56-62`). `ClaudeHookBridge` fängt jeden Erzeugungs-/Schreibfehler und liefert `nil` (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:86-118`). Der Coordinator bildet dieses `nil` ohne Fehlerzustand auf leere Settings-Argumente ab (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:102-135`). Der interaktive Pfad baut und startet den Prozess danach trotzdem (`WhisperM8/Views/AgentSessionDetailView.swift:512-532`); der Background-Pfad dokumentiert denselben Spawn ohne Settings bei I/O-Fehler (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:73-95`).

**Gegenbeleg:** Erfolgreiche Writes sind atomisch und versuchen anschließend Dateirechte `0600` zu setzen (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:75-92`). Das schützt Integrität und Vertraulichkeit des Erfolgsfalls, schließt den belegten Fail-open-Pfad aber nicht.

### R4-CP-03 — Background-Respawn behält das alte Context-Overlay

**Urteil: BESTAETIGT. Eigene Schwere: hoch.**

Beim initialen Dispatch wird das Projektprofil einmal aufgelöst und in die Settings-Datei geschrieben; der dortige Kommentar verspricht Wirkung von Profiländerungen „ab Respawn“ (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:43-83`). Der Dateipfad ist stabil aus der lokalen Session-UUID abgeleitet (`WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:129-158`). Der reale Respawn-Pfad reicht anschließend ausschließlich die Short-ID weiter (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:171-199`); der Lifecycle erzeugt daraus nur `claude respawn <short-id>` und liest weder Profil noch Settings neu (`WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:99-106,150-172`). Die Suche nach `prepareLaunchSettings`-Aufrufern zeigt keinen Respawn-Aufrufer; produktive Aufrufe liegen beim initialen Background-Dispatch und bei interaktiven Starts (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:120-135`; `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:79-82`; `WhisperM8/Views/AgentChatsView+Grid.swift:926`).

**Gegenbeleg:** Der Profileditor formuliert nur „Applies to the next chat launch“ (`WhisperM8/Views/Settings/Pages/AgentChatsContextProfilesTab.swift:317-321`). Das relativiert eine allgemeine Sofortwirkung, widerlegt aber nicht die speziellere Respawn-Zusage im Background-Code.

### R4-CP-05 — Env-Filter reintroduziert `CLAUDE_CODE_*`-Prozessidentität

**Urteil: BESTAETIGT. Eigene Schwere: hoch.**

Das Basis-Environment entfernt bewusst jeden Schlüssel mit Prefix `CLAUDE_CODE_`, weil geerbte Child-/Session-Identität neue Top-Level-Transcripts verhindern kann (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:94-108`). Der Profilfilter verwendet dagegen nur sieben exakte reservierte Namen; aus dieser Familie ist allein `CLAUDE_CODE_SUBAGENT_MODEL` enthalten (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:13-24,65-67`). Der Settings-Editor prüft exakt dieselbe unvollständige Menge (`WhisperM8/Views/Settings/Pages/AgentChatsContextProfilesTab.swift:294-306`). Damit passieren etwa `CLAUDE_CODE_CHILD_SESSION` und `CLAUDE_CODE_SESSION_ID` den Filter.

Die zulässigen Werte werden als Prozess-Overlay ausgegeben (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:56-67`). Beim PTY-Start werden Command-Overrides nach dem bereinigten Basis-Environment eingesetzt und gewinnen bei Kollisionen (`WhisperM8/Views/AgentTerminalView.swift:787-799`). Die gefährliche Reihenfolge ist daher belegt: Prefix-Familie entfernen, anschließend denselben Schlüssel aus dem Profil wieder hinzufügen.

**Gegenbeleg:** Account-/Credential-Schlüssel wie `CLAUDE_CONFIG_DIR`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` und `ANTHROPIC_AUTH_TOKEN` werden exakt gesperrt (`WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:13-24`), und der vorhandene Test deckt solche exakten Fälle ab (`Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:170-187`). Er enthält aber keinen beliebigen `CLAUDE_CODE_*`-Schlüssel und widerlegt die Prefix-Lücke nicht.

## Stichproben der mittleren Findings

### R4-CP-04 — `nil`-Sessions erben beim Resume einen späteren Projekt-Default

**Urteil: BESTAETIGT. Eigene Schwere: mittel.**

Das Modell beschreibt `contextProfileID` als stabilen Erstellungsstempel (`WhisperM8/Models/AgentChat.swift:315-320`), dekodiert ein fehlendes Legacy-Feld jedoch zu `nil` (`WhisperM8/Models/AgentChat.swift:428-466`). `resolvedProfile` interpretiert genau dieses `nil` als Fallback auf den aktuellen Projekt-Default (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:109-122`), und der interaktive Start/Resume verwendet diese Auflösung (`WhisperM8/Views/AgentSessionDetailView.swift:513-525`). Der Guard für einen vorhandenen, inzwischen gelöschten Stempel verhindert nur den Fallback bei einer konkreten UUID, nicht beim mehrdeutigen `nil` (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:109-122`).

### R4-CP-07 — Lost Updates zwischen Store-Instanzen

**Urteil: WIDERLEGT für den behaupteten Produktpfad.**

Isoliert ist die Store-Klasse Last-writer-wins: Jede Instanz lädt ihren eigenen Snapshot, mutiert ihn und schreibt den Gesamtbestand atomisch ohne Revision oder Lock (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:56-98,147-156`). Der Ausgangsbericht belegt damit aber noch keinen erreichbaren Produktfehler. Im Produktionscode wird ausschließlich `ClaudeContextProfileStore.shared` konstruiert; zusätzliche `fileURL`-Instanzen existieren nur in Tests (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:12-17`; `Tests/WhisperM8Tests/ClaudeContextProfileTests.swift:37-139`). Zudem terminiert `WhisperM8App.init` eine zweite GUI-Instanz derselben Bundle-ID (`WhisperM8/WhisperM8App.swift:15-25`). Das konkrete Szenario zweier per `open -n` parallel mutierender Produkt-Stores ist daher abgeschnitten. Die fehlende Multiwriter-Härtung bleibt ein latentes Klassendesign-Risiko, aber kein belegter aktueller Produktpfad.

## Nur gezähltes mittleres Finding

- **R4-CP-06 — Env-Secrets in zwei Klartextdateien:** nicht einzeln geprüft; daher bewusst **kein Urteil** und keine eigene Schweregrad-Einordnung.

## Abgleich der benannten Review-Fix-Commits

- `9e4b9f4` ergänzt im Profilstore elementweises Decode, Quarantäne und Rollback bei Persistenzfehler (`WhisperM8/Services/AgentChats/ClaudeContextProfileStore.swift:23-53,69-98,127-143`). Diese Guards lösen weder die `nil`-Semantik von R4-CP-04 noch Multiwriter-Synchronisation.
- `c6ac557` betrifft im Command-Builder die GPT-Kontextfenster-Injektion bei einem expliziten Nicht-GPT-Modell (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:329-344`) und schließt keines der vier hohen Findings.
- `f50847e`, `e445b65` und `1bd655f` ändern laut ihren dateibezogenen Commit-Pfaden keine der hier geprüften Context-Profile-, Background-, Hook- oder Environment-Stellen.

## Urteilstabelle

| Finding | Ausgangsschwere | Prüfumfang | Urteil | Eigene Schwere |
|---|---:|---|---|---:|
| R4-CP-01 | hoch | vollständig | BESTAETIGT | mittel |
| R4-CP-02 | hoch | vollständig | BESTAETIGT | hoch |
| R4-CP-03 | hoch | vollständig | BESTAETIGT | hoch |
| R4-CP-04 | mittel | Stichprobe | BESTAETIGT | mittel |
| R4-CP-05 | hoch | vollständig | BESTAETIGT | hoch |
| R4-CP-06 | mittel | nur gezählt | kein Urteil | — |
| R4-CP-07 | mittel | Stichprobe | WIDERLEGT (Produktpfad) | — |

## Die drei wichtigsten bestätigten Punkte

1. **R4-CP-02:** Ein Fehler beim Erzeugen des Restriktions-Overlays ist vom Zustand „keine Settings“ nicht unterscheidbar; interaktive und Background-Launches laufen ohne MCP-/Plugin-Denies weiter (`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:86-118`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:120-135`).
2. **R4-CP-05:** Die Pipeline entfernt `CLAUDE_CODE_*` zunächst korrekt und fügt nicht exakt reservierte Schlüssel über das Profil-Overlay danach wieder ein (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:94-108`; `WhisperM8/Services/AgentChats/ClaudeContextSettingsBuilder.swift:13-24,56-67`; `WhisperM8/Views/AgentTerminalView.swift:787-799`).
3. **R4-CP-03:** Background-Respawn regeneriert das app-interne Context-Overlay nicht; verschärfte MCP-/Plugin-Regeln erreichen den respawnten Job nicht (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:171-199`; `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:99-106,150-172`).
