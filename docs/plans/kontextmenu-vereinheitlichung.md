# Kontextmenü-Vereinheitlichung in Agent Chats

**Stand:** 2026-07-15 · **Status:** UMGESETZT (2026-07-15) — `SessionMenuPolicy.swift` (pur, getestet in `AgentSessionMenuPolicyTests`), `AgentChatsView+SessionMenus.swift` (Kompositions-Einstieg `sessionContextMenu(_:context:removalWorkspace:)`), alle 8 Call-Sites migriert inkl. neuem Grid-Pane-Kontextmenü; Konsistenz-Politur (Workspace-Farbmenü, archiveLabel, Grid-A11y) enthalten. Manuelle QA-Punkte siehe Abschnitt 7.
**Quellen:** Code-Audit durch 3 parallele Codex-Subagents (read-only, Jobs `75066ccd`, `d6baa1a8`, `5cd0fbd7`) + manuelle Verifikation der tragenden Stellen. Alle Datei:Zeile-Angaben gegen `main @ 63b6efa` geprüft.

## Problem

Dieselbe Chat-Session hat je nach UI-Ort ein anderes (oder gar kein) Rechtsklick-Menü. Ein neuer universeller Menüpunkt müsste heute an **bis zu 8 Stellen** eingebaut werden. Konkret sichtbar (Screenshots 2026-07-15): Tab-Rechtsklick = Vollmenü, Workspace-Chat-Zeile = nur 3 Workspace-Aktionen, Projekt-Chat-Zeile = Mittelding ohne Account/Fenster/Workspace, Grid-Pane-Header = gar kein Kontextmenü.

## 1. Ist-Matrix (belegt aus Code)

Menü-Quellen und ihre Einträge. ✅ = vorhanden, ➖ = fehlt, (B) = Bulk-fähig („N …"-Label bei Mehrfachauswahl).

| Aktion | Tab-Leiste | Einzelansicht „…" | Gepinnte Zeile | Flache Zeile | Projekt-Chat-Zeile | Subagent-Kind | Workspace-Chat-Zeile | Grid-Pane |
|---|---|---|---|---|---|---|---|---|
| Quelle (Datei:Zeile) | `AgentChatsView.swift:2142` → `sessionManagementMenu` 2794 | `AgentChatsView.swift:2688` | `AgentChatsView.swift:1389` | `AgentChatsView.swift:1457` | `AgentChatsSidebarViews.swift:354` | `AgentChatsSidebarViews.swift:287` | `AgentChatsView+Workspaces.swift:236` | **kein `.contextMenu`** (`+Grid.swift:726-842`) |
| Tab schließen | ✅ (B) | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ |
| Umbenennen… | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ➖ | ➖ |
| Titel automatisch generieren | ✅ | ✅ | ✅ | ✅ | ✅ | ➖ | ➖ | ➖ |
| Forken | ✅ | ✅ | ✅ | ✅ | ✅ | ➖ | ➖ | ➖ |
| Zu Account verschieben | ✅ | ➖ | ✅ | ✅ | ➖ | ➖ | ➖ | ➖ |
| In neues Fenster verschieben | ✅ (B) | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ |
| Zu Workspace hinzufügen / platzieren | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ | ✅ | ➖ |
| Aus Workspace entfernen | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ | ✅ | ✅ *(als Button `minus`)* |
| Neuer Workspace mit diesem Chat | ✅ (B) | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ |
| Anpinnen / Loslösen | ✅ (B) | ✅ | ✅ (B) | ✅ (B) | ✅ (B) | ➖ | ➖ | ➖ |
| Tab-Farbe | ✅ (B) | ✅ (B!) | ✅ (B) | ✅ (B) | ✅ (B) | ➖ | ➖ | ➖ |
| Background-Lifecycle (Logs/Stop/Respawn/rm) | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ |
| Archivieren / Terminal schließen | ✅ (B) | ✅ | ✅ (B) | ✅ (B) | ✅ (B) | ✅ | ➖ | ➖ |
| Start / Resume / Restart | ➖ | ✅ | ➖ | ➖ | ➖ | ➖ | ➖ | ✅ *(als Button)* |
| Projekt im Editor öffnen | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | ✅ *(als Button)* |
| Maximieren | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | ➖ | ✅ *(Button + Doppelklick)* |

Nicht-Session-Menüs (eigene Kategorie, nicht Teil der Vereinheitlichung, nur Konsistenz-Politur):
- **Projektgruppen-Header** (`AgentChatsSidebarViews.swift:481`): Umbenennen, Farbe, Icon wählen/Auto/entfernen, Projekt löschen.
- **Workspace-Gruppe** (`+Workspaces.swift:194/267`): Als Grid öffnen, Umbenennen, Farbe, Löschen.

## 2. Aktionsliste mit Handlern (vollständig)

| Aktion | Handler | Bedingungen |
|---|---|---|
| Tab schließen | `closeTabsInSelection(session)` bzw. Einzelansicht direkt `closeTab(session)` | — |
| Umbenennen… | `beginRename(session)` / Sidebar-Closure `onRenameRequest` | — |
| Titel automatisch generieren | `forceAutoNameSession(session)` / `onAutoNameRequest` | disabled wenn `externalSessionID == nil` |
| Forken | `forkMenuItem(session)` → `forkSession` (`+SessionLifecycle.swift:122-131`) | nur `session.isForkable` |
| Zu Account verschieben | `moveToAccountMenu(session)` (`+SessionLifecycle.swift:135-175`) | nur Claude + `effectiveKind == .chat`; disabled bei laufendem Terminal; nicht eingeloggte Ziele disabled |
| In neues Fenster | `moveSelectionToNewWindow(session)` (`+Tabs.swift:199-215`) | — |
| Workspace hinzufügen/platzieren/entfernen | `workspaceMembershipMenu(for:includeRemoval:)` (`+Grid.swift:61-123`) | nur wenn Workspaces existieren; „Platzieren" nur bei aktivem Grid |
| Neuer Workspace | `newWorkspaceFromSelectionButton` → `createWorkspaceFromSelection` (`+Workspaces.swift:358-367`) | — |
| Anpinnen/Loslösen | `togglePinSelection(session)` bzw. Einzelansicht direkt `togglePin(id)`; Labels via `pinLabel` (`+BulkActions.swift:24-32,52-64`) | — |
| Tab-Farbe | `tabColorMenu(for:)` → `setColorForSelection` (`+SessionLifecycle.swift:236-255`) | — |
| Background-Lifecycle | `backgroundLifecycleMenuItems(session)` (`AgentChatsView.swift:2839-2862`) | nur `isBackgroundChat`; disabled ohne Short-ID oder bei pending |
| Archivieren/Terminal schließen | `archiveSelection(session)` bzw. direkt `requestArchive([session])`; Labels via `archiveLabel/archiveIcon` (`+BulkActions.swift:77-89`) | — |
| Start/Resume/Restart | `sessionActionRequest = …(.start/.restart)` (Einzelansicht 2688-2694; Grid-Button `+Grid.swift:768-793`) | Grid: versteckt für nicht übernommene Subagent-Jobs |
| Editor öffnen | `openProject(project, in: projectOpenTarget)` (`+Grid.swift:750-767`) | nur wenn `project != nil` |
| Maximieren | `maximizePane(session.id)` (`+Grid.swift:794-806`) | nur Grid |
| Aus Workspace (direkt) | `removeSessionFromWorkspace(id, workspaceID:)` (Workspace-Zeile 237-239; Grid-Button 807-821) | — |

**Bulk-Mechanik** (`+BulkActions.swift:13-21`): Kein separates Bulk-Menü — dieselben Menüs wechseln Labels/Zielgruppe, wenn die angeklickte Session Teil einer Mehrfachauswahl ≥ 2 ist. Bulk-fähig: Schließen, Fenster, Neuer Workspace, Pin, Farbe, Archivieren. Bewusst singulär: Umbenennen, Auto-Titel, Forken, Account, Workspace-Mitgliedschaft, Background.

## 3. Gap- und Inkonsistenz-Liste

**Lücken (hoher Nutzerimpact):**
1. **Grid-Pane-Header ohne Kontextmenü** — für jede Session-Aktion muss man zum Tab hoch. Verifiziert: kein `.contextMenu` in ganz `+Grid.swift`.
2. **Workspace-Chat-Zeile nur mit Workspace-Aktionen** — kein Umbenennen/Forken/Farbe/Archivieren (Screenshot 2 + Code 236-243).
3. **Projekt-Chat-Zeile ohne** Account-Verschieben, Fenster- und Workspace-Aktionen (Screenshot 3).
4. **Subagent-Kind-Zeile:** nur Umbenennen + Archivieren.
5. **Einzelansicht-„…"** ohne Account/Fenster/Workspace/Background — dafür als Einziges mit Start/Resume/Restart im Menü.

**Inkonsistenzen (Detail):**
- Einzelansicht ist strikt singulär, nutzt aber `tabColorMenu` → allein die Farbaktion kann dort Bulk-wirken („Farbe für N Tabs"). Überraschende Semantik.
- Pin-Icons hart codiert: gepinnte Zeile immer `pin.slash`, flache immer `pin` — Bulk-Label kann dem Icon widersprechen („N anpinnen" mit `pin.slash`).
- `archiveLabel` sagt bei Bulk immer „N Chats archivieren", auch wenn Terminals enthalten sind (die geschlossen, nicht archiviert werden; Aufteilung erst in `requestArchive`, `+Tabs.swift:98-117`).
- Workspace-Gruppen-Farbmenü zeigt rohe Hex-Strings + `circle.fill` statt `AgentChatColorName.label(for:)` + Farbswatch wie Tab-/Projekt-Farbmenüs (`+Workspaces.swift:278-283`).
- Entfernen-Icon: Workspace-Zeile `minus.circle`, Grid-Button `minus` — gleicher Handler.
- Label-Drift: Einzelansicht-Menü „Start Terminal"/„Resume Terminal" vs. Header-Button daneben „Start"/„Resume"; Grid-Accessibility sagt immer „fortsetzen", auch ohne `externalSessionID`.
- `AgentChatsSidebarViews` ist ein eigener View-Baum mit Closure-API (`onRenameRequest`, `onSetColor`, …) und dupliziert Fork-/Farbmenü inline statt die `+SessionLifecycle`-Bausteine zu nutzen (kein Zugriff auf `AgentChatsView`-State).

## 4. Ziel-Matrix (Vorschlag)

Prinzip: **Eine Session hat überall dasselbe Menü** — zusammengesetzt aus festen Sektionen; der Kontext blendet nur Sektionen ein/aus, die dort keinen Sinn ergeben. Reihenfolge überall identisch:

| Sektion | Einträge | Tab | Einzelansicht „…" | Sidebar-Zeilen (gepinnt/flach/Projekt) | Workspace-Zeile | Grid-Pane | Subagent-Kind |
|---|---|---|---|---|---|---|---|
| **Kontext-Kopf** | Tab schließen (B) | ✅ | ✅ | ✅ *(nur wenn Tab offen)* | ✅ *(nur wenn Tab offen)* | ➖ | ➖ |
| | Aus Workspace „X" entfernen | ➖ | ➖ | ➖ | ✅ (erster Eintrag) | ✅ | ➖ |
| | Maximieren | ➖ | ➖ | ➖ | ➖ | ✅ | ➖ |
| **Benennen** | Umbenennen…, Titel automatisch generieren | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (nur Umbenennen) |
| **Laufzeit** | Start/Resume/Restart | ✅ *(neu)* | ✅ | ✅ *(neu)* | ✅ *(neu)* | ✅ | ➖ |
| **Verwalten** | Forken, Zu Account verschieben | ✅ | ✅ *(Account neu)* | ✅ *(Projekt-Zeile: neu)* | ✅ *(neu)* | ✅ *(neu)* | ➖ |
| **Fenster/Workspace** | In neues Fenster (B), Zu Workspace hinzufügen, Im Workspace platzieren, Aus Workspace entfernen, Neuer Workspace (B) | ✅ | ✅ *(neu)* | ✅ *(neu)* | ✅ (ohne doppeltes Entfernen) | ✅ *(neu)* | ➖ |
| **Darstellung** | Anpinnen/Loslösen (B), Tab-Farbe (B) | ✅ | ✅ | ✅ | ✅ *(neu)* | ✅ *(neu)* | ➖ |
| **Background** | Logs, Stoppen, Respawn, Vom Supervisor entfernen | ✅ | ✅ *(neu)* | ✅ *(neu)* | ✅ *(neu)* | ✅ *(neu)* | ✅ *(neu, entschieden)* |
| **Ende** | Archivieren / Terminal schließen (B) | ✅ | ✅ | ✅ | ✅ *(neu)* | ✅ *(neu)* | ✅ |

Sichtbarkeitsbedingungen der Einträge (isForkable, Claude-only, isBackgroundChat, Workspaces vorhanden, …) bleiben unverändert — die Sektion erscheint nur, wenn mindestens ein Eintrag sichtbar ist (keine hängenden Divider).

## 5. Architektur: wiederverwendbare Bausteine statt 8 Kopien

**Heute schon geteilt:** `forkMenuItem`, `moveToAccountMenu`, `tabColorMenu` (`+SessionLifecycle.swift`), `workspaceMembershipMenu` (`+Grid.swift`), Bulk-Helper (`+BulkActions.swift`). **Inline dupliziert:** Umbenennen, Auto-Titel, Pin, Archivieren, Divider-Logik — plus Komplett-Duplikate in `AgentChatsSidebarViews` (Closure-Welt).

**Vorschlag (Hybrid, Schwerpunkt thematische Bausteine + pure Policy):**

1. **`SessionMenuContext`-Enum** (pur): `.tab, .headerMenu, .sidebarRow, .workspaceRow, .gridPane, .subagentChild`.
2. **`SessionMenuPolicy`** (pure, testbare Funktion): `(context, sessionEigenschaften) → sichtbare Sektionen/Einträge`. Kapselt alle Sichtbarkeitsregeln an EINER Stelle; unit-testbar ohne SwiftUI.
3. **Neue Datei `Views/AgentChatsView+SessionMenus.swift`** (Repo-Konvention extension-per-concern): kleine `@ViewBuilder`-Sektionen (`namingSection`, `runtimeSection`, `managementSection`, `windowWorkspaceSection`, `appearanceSection`, `backgroundSection`, `archiveSection`) plus ein Kompositions-Einstieg `sessionContextMenu(_ session:, context:)`, der die Policy befragt. Bestehende Bausteine (`forkMenuItem` etc.) ziehen logisch dort ein bzw. werden von dort aufgerufen.
4. **`AgentChatsSidebarViews`-Anbindung:** Statt die Closure-API um ~8 weitere Closures zu erweitern, übergibt die Call-Site (die ohnehin in `AgentChatsView` liegt) das fertige Menü als `@ViewBuilder`-Parameter an die Row-Views. Die Rows bleiben dumm; die Menü-Definition wandert an eine Stelle. (Alternative: kleines `SessionMenuActions`-Closure-Struct — mehr Boilerplate, dafür Rows unabhängiger testbar. Entscheidung bei Umsetzung.)
5. **Grid-Pane:** `.contextMenu { sessionContextMenu(session, context: .gridPane) }` am `gridPaneHeader`-HStack (nicht am Terminal — sonst kollidiert Rechtsklick mit dem PTY). Die bestehenden Header-Buttons bleiben unverändert als Schnellzugriff.

## 6. Optionen mit Trade-offs

| Option | Beschreibung | Pro | Contra |
|---|---|---|---|
| **A: Zentraler Mega-Builder** | Ein `SessionContextMenu`-View mit Kontext-Parameter, alle Aktionen als großes Actions-Objekt/Environment | Eine einzige Definitionsstelle, maximale Konsistenz | Überladener Builder; viele Closures oder breite State-Kopplung; großes Migrations-Diff auf einmal; SwiftUI-Verdrahtung (Environment/Generics) fummelig |
| **B: Thematische Sektionen + pure Policy** *(empfohlen)* | 7 kleine `@ViewBuilder`-Sektionen in `+SessionMenus`, Sichtbarkeit zentral in purer `SessionMenuPolicy`, Call-Sites komponieren via `sessionContextMenu(session, context:)` | Passt zu Repo-Konventionen (extension-per-concern, pure Helper, Closure-DI); schrittweise Migration pro Call-Site; Policy unit-testbar; mittleres Diff | Reihenfolge/Komposition ohne Disziplin theoretisch weiter driftbar — dagegen hilft der eine Kompositions-Einstieg + Policy-Test |
| **C: Status quo + Lücken schließen** | Nur Grid-Kontextmenü ergänzen und Workspace-/Projekt-Zeilen-Menüs manuell erweitern | Kleinstes Diff, geringstes Risiko | Konserviert 8 Duplikate; jede künftige globale Aktion kostet wieder 6-8 Edits; Label-/Icon-Drift bleibt |

**Empfehlung: Option B.** Sie löst beides — die Lücken UND die Drift-Ursache — und entspricht exakt dem Muster, mit dem das Repo schon `RecordingCoordinator` und `AgentChatsView` zerlegt hat (pure, testbare Logik + dünne SwiftUI-Schicht). Option A widerspricht der Closure-DI-Konvention, Option C behandelt nur Symptome.

## 7. Umsetzungsplan (für spätere Implementierung)

Jeder Schritt einzeln shipbar; nach jedem Schritt `swift build && swift test`.

1. **Policy + Tests (reine Logik, kein UI-Risiko):** `SessionMenuContext` + `SessionMenuPolicy` als pure Typen (z. B. `Views/SessionMenuPolicy.swift` neben `TerminalLinkResolver`-Muster) inkl. Unit-Tests: Sektions-Sichtbarkeit je Kontext, Disabled-Gründe (kein `externalSessionID`, nicht forkable, kein Background-Chat), Divider-Regel „keine leere Sektion". Neue Testdatei `AgentSessionMenuPolicyTests.swift`.
2. **`+SessionMenus.swift` anlegen:** Sektions-Builder extrahieren; `sessionManagementMenu` intern darauf umstellen (Tab-Leiste = erste Migrations-Call-Site, Verhalten identisch — reine Refaktor-Prüfung).
3. **Einzelansicht-„…" migrieren:** auf `sessionContextMenu(session, context: .headerMenu)`. Dabei bewusste Fixes: Account/Fenster/Workspace/Background ergänzen, Farb-Bulk-Überraschung beseitigen (Entscheidung: `.headerMenu` ist strikt singulär — Policy erzwingt Einzel-Labels/-Wirkung), Labels „Start/Resume" an Header-Button angleichen.
4. **Gepinnte + flache Zeile migrieren** (gleiche Datei): löst nebenbei die Pin-Icon-Hardcodes über gemeinsames `pinLabel`/Icon-Paar.
5. **Grid-Pane-Kontextmenü ergänzen** (`context: .gridPane`, Buttons bleiben): größter Nutzergewinn, kleiner Eingriff.
6. **Workspace-Chat-Zeile migrieren:** „Aus Workspace „X" entfernen" als Kontext-Kopf, danach Vollmenü (`context: .workspaceRow`, Membership-Menü mit `includeRemoval: false` wie heute).
7. **`AgentChatsSidebarViews` anbinden** (Projekt-Chat-Zeile, Subagent-Kind) via `@ViewBuilder`-Menü-Parameter; Inline-Fork-/Farbmenü-Duplikate dort löschen.
8. **Konsistenz-Politur:** Workspace-Gruppen-Farbmenü auf `AgentChatColorName` + Swatches, Entfernen-Icon vereinheitlichen (`minus.circle`), `archiveLabel` bei gemischter Bulk-Auswahl („N schließen/archivieren"), Grid-Accessibility-Label „Start" vs. „fortsetzen".

**Test-/QA-Punkte:**
- Unit (neu): `SessionMenuPolicy` (Schritt 1), Label-Helfer aus `+BulkActions` falls noch ungetestet.
- Bestehende Suiten müssen grün bleiben: `AgentSidebarTests`, `AgentGridWorkspaceTests`, `AgentChatsViewModelTests` (decken Rename-/Farb-Mutationen, Workspace-Slots, Sidebar-Gruppierung — nicht die Menüs selbst).
- Manuelle QA (SwiftUI-Menüs sind nicht unit-testbar, vgl. Tabs/Drag-Drop-Konvention in CLAUDE.md): Rechtsklick an allen 8 Orten mit (a) Einzel-Session, (b) Bulk-Auswahl ≥ 2, (c) Background-Chat, (d) Codex-Session (kein Account-Menü), (e) Terminal (Label „Terminal schließen"), (f) Subagent-Kind; Grid: Rechtsklick am Header vs. Terminal-Fläche (PTY darf Rechtsklick behalten), Doppelklick-Maximieren weiterhin intakt.

## 8. Getroffene Produktentscheidungen (User, 2026-07-15)

1. **Subagent-Kind-Zeile → „Reduziert erweitert":** Umbenennen + Background-Sektion (Logs/Stoppen/Respawn/Vom Supervisor entfernen) + Archivieren. Fork/Pin/Farbe erst, wenn Subagent-Kinder echte Tabs werden können.
2. **Bulk-Anzeige singulärer Aktionen → „Anzeigen, wirkt einzeln":** Umbenennen/Forken/Account bleiben bei Mehrfachauswahl sichtbar und wirken nur auf die angeklickte Session (wie heute). Verhalten wird in der `SessionMenuPolicy` dokumentiert/getestet.
3. **Start/Resume/Restart → „Ja, überall":** Laufzeit-Sektion in allen Session-Kontextmenüs (Tab, Sidebar-Zeilen, Workspace-Zeile, Grid-Pane). Grid-Buttons bleiben als Schnellzugriff.
4. **Einzelansicht-„…" → „Strikt singulär":** Policy erzwingt in `.headerMenu` Einzel-Labels und Einzel-Wirkung — auch für die Tab-Farbe (behebt die heutige Farb-Bulk-Überraschung).
5. **„Tab schließen" in Sidebar-Kontexten → „Ja, wenn Tab offen":** Der Eintrag erscheint in Sidebar-/Workspace-Zeilen-Menüs nur, wenn die Session gerade als Tab offen ist (kontextabhängig via Policy, kein toter/ausgegrauter Eintrag).

## Anhang: Belege

- Kein `.contextMenu` in `AgentChatsView+Grid.swift` (repo-weite Suche, verifiziert 2026-07-15).
- Workspace-Zeile nur Workspace-Aktionen: `AgentChatsView+Workspaces.swift:236-243` (Kommentar dort erklärt bereits das bewusst unterdrückte Doppel-Entfernen — Review-Finding).
- `workspaceMembershipMenu`-Call-Sites: genau 2 (`AgentChatsView.swift:2818`, `+Workspaces.swift:242`) + Definition `+Grid.swift:61-123`.
- Vollständige Menü-Inventare mit allen Labels/Bedingungen: Codex-Job-Reports `75066ccd` (Tab/Einzelansicht/Bulk), `d6baa1a8` (Sidebar/Workspace/Grid), `5cd0fbd7` (Architektur).
