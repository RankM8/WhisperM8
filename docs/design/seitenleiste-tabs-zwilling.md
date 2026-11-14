# Seitenleiste und Tab-Leiste: Zwilling und Feinschliff (WM8-76)

Stand 14.11.2026, Grundlage main `5143152e`. Nur Entwurf, kein Swift.

**Zwilling:** [seitenleiste-tabs-zwilling.html](seitenleiste-tabs-zwilling.html). Öffnen über einen lokalen
Server (zum Beispiel `python3 -m http.server` in `docs/design/`). Oben schaltet man Seitenleiste
(Heute, A, B, C), Tabs (Heute, 1, 2), Kleinkram, Lage, Fensterbreite und hell/dunkel um. Startzustand per
Adresse: `?sb=a&tab=1&x=1&scn=all&w=1100&theme=light&scope=recent`.

Bilder: `seitenleiste-tabs-zwilling/` (Bildschirmfoto des Ist-Stands vom 14.11., Zwilling heute,
Zwilling mit Empfehlung).

## Ergebnis in Kürze

- **Warum laufende Chats mittendrin stehen:** Innerhalb eines Projekts sortiert die App nach der
  Handreihenfolge (`sortIndex`, gesetzt über Ziehen oder `chats order`) und sonst nach letzter Aktivität
  (`AgentSessionStore.sortedSessions`). Der Status spielt keine Rolle. Im Foto steht „Ole · vor 1 Std.“
  vor drei arbeitenden Chats.
- **Warum die Seitenleiste voll wirkt:** Chats aus einem Workspace stehen ein zweites Mal im Projekt.
  Im Foto sind 6 von 18 Zeilen doppelt. Gepinnte Chats stehen dagegen nur einmal.
- **Warum die Tabs nicht schmaler werden:** Jeder Tab hat feste Grenzen 100–190 pt
  (`ChatTabButton`, `.frame(minWidth: 100, maxWidth: 190)`) und steht in einer waagerechten
  `ScrollView`. Darin bekommt jeder Tab seine Wunschbreite; es gibt nie Druck zum Schrumpfen.
- **Empfehlung:** Seitenleiste **A · Sortiert** + Tabs **1 · Schrumpfen** + **Kleinkram (c)**,
  zusammen etwa zweieinhalb Tage Bau. Anheften (Tabs 2) erst danach.

## 1. Bestandsaufnahme der Entwürfe

| Entwurf | Datum | Thema | Stand |
|---|---|---|---|
| sidebar-redesign-varianten.html | 23.07. | Seitenleiste A Zonen, B Statusboard, C Rail, D dichte Liste | A gebaut (Gepinnt, Workspaces, Chats); B, C, D nie gebaut, keine Entscheidung festgehalten |
| sidebar-zonen-varianten.html | 23.07. | A1 Spine, A2 Tint-Block, **A3 Dedup**, A4 Mini-Raster, Status-Modus | offen; A3 ist die Idee hinter „keine Doppelungen“ in Variante A |
| agent-chats-tabs-mockup.html | 20.07. | Tab-Leiste | gebaut, **ohne** die schrumpfenden Tabs des Entwurfs (`flex:0 1 auto; max-width:190px`) |
| tab-gruppen-mockup.html | 23.07. | Tab-Gruppen | gebaut 1:1 (`AgentTabGrouping.swift`) |
| agent-chats-master-redesign.html | 23.–25.07. | Fenster mit vier Tab-Stilen | Chrome-Stil gebaut, die anderen drei verworfen |
| agent-chats-layout-engine.html | 25.07.–01.08. | bisheriger „Zwilling“ | veraltet, siehe Abschnitt 4 |
| agent-chats-v3.html, agent-chats-v3/ (nicht eingecheckt) | 11.10. | Design-System v3, Ansichtsmenü, Tab-Breiten nach Chrome (aktiv ≥ 140, andere ≥ 40, Gruppen klappen selbst zu) | offen; Variante Tabs 1 greift die Breitenregel auf |
| projekt-workspaces-skizze.html | 02.08. | Projekt als Raster über ⊞ | gebaut |
| subagent-*.html | 09.–10.07. | Subagent-Gruppe und Chip | gebaut (Variante D, Chip „Straße“) |
| imagegen-sidebar/, imagegen-fullapp/ | 23.07. | generierte Bilder | nur Anregung |
| tab-geometry-check.mjs | 26.07. | Maßabgleich Zwilling gegen Swift | veraltet (Gruppen-Chip 10/9 statt 11/11 pt) |
| einstellungen-*.html (nicht eingecheckt) | 05.11. | Einstellungen neu ordnen | offen, nicht Teil dieses Tickets |
| übrige (Transcript, Pille, Notch, Zwischenablage, Statistik, Controller, Randnotizen, Ticket-Board) | Juli–Nov. | andere Bereiche | gebaut bzw. im Bau |

**Noch offene Ideen zu Seitenleiste und Tabs:** Status-Modus als zweite Ansicht (mehrere Entwürfe,
nie gebaut), Dedup (A3), ⊞ dauerhaft sichtbar bei aktiven Chats (v3), Ansichtsmenü mit Gruppieren und
Sortieren (v3), Chrome-Breitenverteilung mit selbst zuklappenden Gruppen (v3), Gruppen nach Neustart
zugeklappt (v3). Angeheftete Tabs gab es in keinem Entwurf. Rail-Spalte und dichte IDE-Liste sind nicht
weiter verfolgt worden.

## 2. Was der Zwilling abbildet

Farben 1:1 aus `AppTheme.swift` (alle Tokens, hell und dunkel). Maße aus `AgentChatsSidebarViews.swift`,
`AgentChatsView.swift` (Kopf 28, Befehlszeilen 30, Umschalter 22/26, Abschnittstitel 11 pt fett),
`AgentChatsView+Workspaces.swift` (Workspace-Kopf und -Zeile 28, Slot-Marke S1–S4),
`AgentChatChromeViews.swift` (Tab 28 hoch, 100–190 breit, Ecken 7, Fußkurven 7, Gruppen-Chip 19 hoch)
und `AgentStatusIndicator.swift`. Zustände: arbeitet, wartet auf dich, bereit, Fehler, gestoppt (Zeit),
am Limit (nur als Zustand gezeigt, kein Code aus dem Branch `feat/WM8-69-chat-am-limit`, der noch nicht in main ist), gepinnt, Workspaces, Projekte, Arbeitskopie-Marke aus WM8-60 (in main: Zeile und Tab nur Symbol und nur bei Arbeitskopie oder anderem Branch, Chat-Kopf immer grau „Hauptordner“ oder lila mit Branch),
Subagent-Chip, 4, 18 und 32 offene Tabs.

### Abweichungen zum Bildschirmfoto

- Projekt-Symbole sind farbige Kacheln mit Buchstaben statt der echten Logos.
- Browser-Schrift statt SF Pro: Titel laufen 1–3 px anders ab.
- Der Status-Puls steht still (Ruhebild); in der App atmet der Ring gedrosselt.
- Im Foto zeigen drei Zeilen rechts gar nichts (akquise-ai „Versionsstand …“, Jarvis in ListM8,
  „Claude Chat“). Laut Code steht dort immer Punkt oder Zeit. Im Zwilling stehen sie als „bereit“.
  **In der App prüfen**, ob der Status dort fehlt (siehe Abschnitt 6).
- Kopfzeile, Fußleiste und Inhalt rechts sind nur Kulisse.

### Abgleich mit `make snapshots`

Für die ganze Seitenleiste und die ganze Tab-Leiste gibt es kein Fixture. Verglichen habe ich die
vorhandenen Teile: `status-punkte` (Formen und Größen stimmen; der Hof um „wartet“ ist im Snapshot gefüllt,
der Zwilling ist darauf angepasst), `arbeitsordner-tab-seitenleiste` (Marke: Ordner-Stapel für
Arbeitskopie, Zweig für anderen Branch im Hauptordner, Farbe #9E73F2 – stimmt), `sidebar-ohne-verlauf`
und `sidebar-wach-stufen` (Fußleiste, nur Kulisse). Für den Bau lohnt ein neues Fixture
„seitenleiste-tableiste“ mit den Daten dieses Zwillings.

## 3. Varianten

### Seitenleiste

| | Alltag | Kosten | Risiko |
|---|---|---|---|
| **A · Sortiert** (Empfehlung) | Im Projekt laufende vor gestoppten, Handreihenfolge innerhalb der Blöcke. Gestoppte unter „N gestoppt“ (unter Aktiv zu). Workspace-Chats nur noch als Zeile „↑ 4 im Workspace …“ mit Status-Punkten. Projekte mit Laufendem zuerst. | `AgentSidebarModelBuilder.swift` ~70, `ProjectChatGroup` ~80, Tests ~80, 3 Texte. `AgentChatsView.swift` hat nur noch 8 Zeilen Luft (3.712/3.720). Etwa 1 Tag. | `chats order` wirkt nur noch innerhalb der Blöcke; Ablegeregel beim Ziehen; Workspace-Chats im Projekt nur über den Hinweis. |
| **B · Läuft oben** | Neuer Abschnitt „Laufende Chats“ quer über alle Projekte, darunter Workspaces, darunter Projekte nur mit Gestoppten. | eigene Datei für den Abschnitt ~120, Builder ~60, Tests ~90. Etwa 1,5 Tage. | Drei Orte für Laufendes (Gepinnt, Workspaces, Laufende); Chats wandern beim Start/Stopp zwischen Abschnitten; Projektbezug nur am Symbol. |
| **C · Nach Status** | Flache Liste in Bändern: Braucht dich, Arbeitet, Bereit, Gestoppt. | fast alles da (flache Ansicht), ~160 Zeilen. Etwa 0,5 Tage. | Zeilen springen bei jedem Wechsel arbeitet ↔ bereit; Projektordnung geht verloren. |

### Tab-Leiste

| | Alltag | Kosten | Risiko |
|---|---|---|---|
| **1 · Schrumpfen** (Empfehlung) | Gleiche Breiten bis 100 pt; dann klappen Gruppen ohne den aktiven Tab selbst zu (größte zuerst, Klick öffnet sie dauerhaft); dann bis 64 pt mit Kurztitel („Gus“ statt „WM8-6…“); erst danach Scrollen. Aktiver Tab ≥ 140 pt mit Titel, Status, Schließen. | Tab-Leiste aus `AgentChatsView.swift` in eigene Datei (~330 Zeilen verschieben, Pflicht), `TabWidthResolver` ~80 + Tests ~100, eigenes Layout ~80, `ChatTabButton` ~50. Etwa 1 Tag. | Tab-Ziehen rechnet mit Rahmen; Mausrad-Wächter (`TabStripBand`) nicht anfassen; Breiten in einem Layout-Durchlauf setzen, kein GeometryReader-Kreislauf (vgl. grid.build). |
| **2 · + Anheften** | Wie 1, dazu angeheftete Tabs links (nur Symbol und Status, scrollen nie weg), Anheften gilt für Seitenleiste und Tab zugleich; Chips schrumpfen auf Buchstabe und Zahl; Menü „Alle Tabs“ nach Gruppen. | zusätzlich `AgentWindowStore.swift` ~40, Mini-Tab ~50, Menüs ~50, Chip ~30, Tests ~80. Etwa 2 Tage. | Ändert, was „Pin“ heißt (auch `chats pin`); ⌘1–9 muss klären, ob Angeheftete mitzählen. |

Ehrliche Einschränkung: Bei 18 Tabs auf rund 1.000 pt Leiste zeigt keine Breitenregel allein lesbare Titel.
Den Platz schafft erst das Zuklappen der Gruppen. Variante 1 macht das automatisch, ohne dass man eine
Gruppe von Hand zuklappen muss.

### Kleinkram (c)

1. Zähler in den Umschalter („Aktiv 18 · Zuletzt 26 · Alle 315“), die Zeile „18 von 315 Chats“ fällt weg.
2. „+“ am Projektkopf immer sichtbar (Regel „kein Hover-only“); ⊞ bleibt beim Überfahren und im Kontextmenü.
3. Trefferfläche des „+“ neben „Workspaces“ 20 statt 14 pt.
4. Ein Tab-Menü statt zwei Knöpfen (Gruppen-Schalter wandert ins Menü „Alle Tabs“, das immer da ist).
5. Ein Zeilenmaß: Workspace- und Gepinnt-Zeilen 26 statt 28, Slot-Marke grau statt Akzentfarbe.

Jeweils unter 30 Zeilen, zusammen etwa ein halber Tag.

### Neue Texte (Englisch als Basis, Deutsch übersetzt)

| Englisch | Deutsch | Variante |
|---|---|---|
| `%lld stopped` | `%lld gestoppt` | A |
| `%lld in workspace “%@”` | `%lld im Workspace „%@“` | A |
| `No running chats` | `Ohne laufende Chats` | A |
| `Running chats` | `Laufende Chats` | B |
| `Stopped by project` | `Gestoppt nach Projekt` | B |
| `Needs you` / `Stopped` | `Braucht dich` / `Gestoppt` | C |
| `%lld more in the workspaces above` | `%lld weitere stehen oben in den Workspaces` | C |
| `Collapsed for space – click to open the group` | `Wegen Platzmangel zugeklappt – Klick öffnet die Gruppe` | Tabs 1/2 |
| `Pin tab` / `Unpin tab` | `Tab anheften` / `Tab lösen` | Tabs 2 |
| `Tab groups` | `Tab-Gruppen` | Kleinkram 4 |

## 4. Verhältnis zum bisherigen Zwilling

`agent-chats-layout-engine.html` ist auf dem Stand vom 01.08.: Er zeigt Panes und Stapel (P1, ⌷1), die am
02.08. zurückgenommen wurden, eine 268 pt breite Seitenleiste, ein Segment Struktur/Status und einen immer
sichtbaren Überlauf-Knopf. Es fehlen S1–S4, der Umschalter gruppiert/flach, die Arbeitskopie-Marke, der
heutige Subagent-Chip und die Fußleiste. Farben und Tab-Geometrie stimmen noch.

**Dieser Zwilling löst ihn für Seitenleiste und Tab-Leiste ab.** Für das Raster (Grid, Projekt-Ansicht)
bleibt der alte die einzige Vorlage, ist dort aber ebenfalls veraltet. Die Regel „zuerst im Zwilling“
sollte künftig auf diese Datei zeigen.

## 5. Entscheidung

**Giuliano hat am 14.11.2026 gewählt:** Seitenleiste **A · Sortiert**, Tabs **1 · Schrumpfen** und alle vier
Kleinkram-Punkte (Zähler im Umschalter, „+“ am Projekt sichtbar, ein Tab-Menü, ruhigere Zeilen inklusive
größerem Workspace-Plus). Der Bau ist ein eigenes Ticket. Vor dem Bau: Tab-Leiste aus `AgentChatsView.swift` herausziehen
(Größengrenze), dann Variante bauen, dann Fixture „seitenleiste-tableiste“ ergänzen.

## 6. Weitere Schwächen (nicht Teil dieses Tickets, nicht gebaut)

1. `AgentChatsView.swift` steht bei 3.712 von 3.720 erlaubten Zeilen. Jede weitere Änderung an der
   Chat-Oberfläche muss vorher etwas auslagern.
2. Zeilen ohne Status-Anzeige im Foto (siehe Abschnitt 2). Entweder fehlt der Status oder die Zeit wird
   verdrängt; in der laufenden App mit `whisperm8 debug …` prüfen.
3. Hover-only in der Seitenleiste und an inaktiven Tabs: Schließen-Zeichen und Projektkopf-Aktionen
   erscheinen nur beim Überfahren (Kontextmenü gibt es). Kleinkram 2 behebt den wichtigsten Fall.
4. Unter „Alle“ zeigt jedes Projekt nur 5 Zeilen, weil die Liste nicht lazy ist (gemessen 01.10.,
   2,5 s Hänger). Eine echte Lösung wäre eine lazy Liste ohne den damaligen Drag-Freeze.
5. ⌘1–9 erreicht nur die ersten neun Tabs, unabhängig von Gruppen.
6. Die Regel „zuerst im Zwilling“ wurde seit August nicht eingehalten (Arbeitskopie-Marke, Live-Projekt-
   Ansicht, anpassendes Raster kamen ohne Zwilling).
7. Drei Memory-Notizen verweisen auf Dateien, die es in `docs/design/` nicht mehr gibt
   (`agent-chats-sidebar-model-d.html`, `agent-chats-sidebar-varianten.html`,
   `agent-chats-linear-redesign.html`); `tab-geometry-check.mjs` misst gegen alte Werte.
8. Die Juli-Entwürfe nutzen ein anderes Farbsystem (#4F46E5, Orange für „arbeitet“) als App und Zwilling;
   wer sie öffnet, sieht falsche Farben.
9. Im Hauptordner liegen unter `docs/design/` nicht eingecheckt `.playwright-cli/`, `agent-chats-v3*` und
   `einstellungen-*.html`. v3 und die Einstellungs-Entwürfe sollten eingecheckt oder bewusst verworfen werden.
