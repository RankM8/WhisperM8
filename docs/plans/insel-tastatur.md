---
status: Plan (2026-11-13), Entscheidung durch Giuliano offen; kein Swift
stand: 2026-11-13
feature: Dynamic Island per Tastatur — Wohin, Schnellbefehle und Diktat ohne Controller
branch: design/insel-tastatur
---

# Dynamic Island per Tastatur

Wunsch von Giuliano (13.11.2026): Die Dynamic Island soll auch per Tastatur gehen, damit die
Pillen-Mechanik ein fester Teil der App wird, auch ohne Controller. Seine Ideen: „Ctrl + Tab könnte
z. B. wie L2 Halten funktionieren“, dann „Option Tab ist ja eigentlich auch frei oder? Das wäre
vielleicht das bessere L2.“ Dieser Plan prüft das und schlägt eine Belegung für alle drei Ebenen vor.
Entwurf zum Durchklicken: [`../design/insel-tastatur.html`](../design/insel-tastatur.html).

## Befund: Ist ⌥Tab frei?

| Wo | Ergebnis | Beleg |
|---|---|---|
| WhisperM8 selbst | frei. Belegt sind nur ⌃Tab/⌃⇧Tab (Umschalter) und ⌃⌥Tab (nächster wartender Chat); `TabSwitcherShortcut.direction` schließt Option aus | `Views/TabSwitcherShortcut.swift`, `AgentChatsView+Shortcuts.swift` |
| Terminal (SwiftTerm) | kommt heute **nirgends an**. Wir setzen `optionAsMetaKey = false`; dann geht ⌥Tab über `interpretKeyEvents` an die macOS-Bindung `~\t` = `insertTabIgnoringFieldEditor:`. Diesen Befehl kennt SwiftTerms `doCommand` nicht (auch nicht im Kitty-Modus) und schickt nichts. Claude Code und Codex sehen ⌥Tab in WhisperM8 also nie, egal ob sie es binden | `AgentTerminalView.swift:993`, SwiftTerm `MacTerminalView.swift` `keyDown`/`doCommand`, `StandardKeyBinding.dict` |
| macOS | kein System-Kürzel auf ⌥Tab (nur ⌘Tab ist der App-Umschalter); in `com.apple.symbolichotkeys` nichts | `defaults read com.apple.symbolichotkeys` |
| Andere Apps | in Textfeldern fügt ⌥Tab einen echten Tab ein (Tabellen, Code-Editoren), Safari springt damit zu Links. Selten genutzt | Cocoa-Standardbindung |
| AltTab (installiert, läuft) | Standard wäre ⌥Tab — Giuliano hat es auf **⌘Tab** umgestellt, ⌥Tab ist deshalb frei. Achtung: Setzt AltTab je seine Einstellungen zurück, kollidiert es. AltTabs zweites Kürzel ist nach meiner Erinnerung ab Werk ⌥\` (nicht geprüft) — deshalb kein ⌥\` in diesem Plan | `defaults read com.lwouis.alt-tab-macos` (`holdShortcut = ⌘`) |
| Diktat-Hotkey | ⌥Leertaste ist heute „Aufnahme an/aus“ (global, Carbon). Das passt: Mit gehaltenem ⌥ wird Leertaste in der Insel zu „hin und diktieren“ (R2) | `KeyboardShortcuts_toggleRecording` = keyCode 49, Option |

**Ergebnis:** ⌥Tab ist in der App, im Terminal und systemweit frei. Wir verlieren nichts. Nebenbei
passt ⌥ gut, weil ⌥Leertaste schon das Diktat ist.

## Warum nicht ⌃Tab?

⌃Tab ist der Umschalter mit Kacheln und hat drei Dinge, die die Insel nicht hat:

1. **Stand-Kacheln:** Jede Kachel zeigt, was der Chat gerade tut („Bash: swift test“, die offene Frage).
   Die Insel zeigt nur Status-Wort und Dauer.
2. **Räumliche Navigation:** Im Raster markiert ⌃Tab die echten Kacheln und läuft mit den Pfeilen
   räumlich (Situation A und B). Die Insel ist eine Liste.
3. **Drei Umfänge:** ⌃Tab wechselt nur zwischen den Chats, mit denen man gerade arbeitet (Raster,
   Workspace, Projekt). Die Insel zeigt alle Chats der Liste plus Workspaces und Projekte.

Dazu kommt Muskelgedächtnis aus Browsern und Editoren. Empfehlung: **⌃Tab bleibt der Kachel-Umschalter,
die Insel kommt auf ⌥Tab daneben.** Beide haben eine klare Rolle: ⌃Tab „im Raster springen“, ⌥Tab
„überall hin, wie L2“. Eine Einstellung „Insel statt Kacheln auf ⌃Tab“ wäre möglich, lohnt aber erst,
wenn sich ⌥Tab im Alltag bewährt hat.

## Der Kern: Tastatur braucht keine Ebenen

Der Controller braucht Ebenen, weil er wenige Tasten hat: Viereck heißt unter L1 „Zeile löschen“ und
unter R1 „Befehle“. Die Tastatur hat genug Tasten. Deshalb schlage ich **eine** Insel vor, die mit ⌥Tab
aufgeht und solange ⌥ gehalten ist alles kann: wohin wechseln, Schnellbefehle mit Buchstaben, Diktat mit
Leertaste.

### L2 Wohin → ⌥Tab

| Taste (⌥ gehalten) | Wirkung | wie am Controller |
|---|---|---|
| ⌥Tab kurz (Loslassen unter 0,2 s) | zum vorigen Ort, ohne dass die Insel aufblitzt | L2 getippt |
| ⌥Tab halten | Insel geht auf, **Markierung auf „vorher“** (eine Zeile unter dem aktuellen) | L2 halten |
| Tab / ⇧Tab, ↓ / ↑ | Markierung weiter / zurück, ohne Umlauf | Stick hoch/runter |
| ← / → | Reiter „Chats“ / „Workspaces & Projekte“, Markierung auf „vorher“ bzw. auf dem aktuellen | Steuerkreuz links/rechts |
| ⌥ loslassen, Return | dorthin wechseln (steht die Markierung auf dem aktuellen Eintrag: nichts) | Loslassen, Kreuz |
| Esc | abbrechen, nichts passiert; erreicht nie das Terminal und beendet nie eine Aufnahme | Kreis |
| Leertaste | hin und diktieren (Wechsel, dann Aufnahme ins Ziel) | R2 |
| W | nächster wartender Chat, reihum (wie ⌃⌥Tab) | Dreieck |
| R | zuletzt geschlossenen Chat wieder öffnen | Viereck |

**Warum die Markierung auf „vorher“ startet:** Beim Controller ist das Halten die Geste, die Markierung
wartet deshalb auf dem aktuellen Ort. Bei der Tastatur ist der Druck auf Tab schon ein Schritt —
genau wie bei ⌘Tab. Der erste Tab landet auf „vorher“; kurz getippt ist das dasselbe wie L2 getippt.
„vorher“ steht wie heute immer gleich unter dem aktuellen Eintrag, also ist es immer genau ein Schritt.

### R1 Schnellbefehle → Buchstaben in derselben Insel

Unter der Liste steht eine Tastenzeile. Buchstaben statt Steuerkreuz, gewählt nach dem Anfangsbuchstaben
und ohne Y/Z (QWERTZ/QWERTY tauschen sie). Erkannt per keyCode, nicht per Zeichen; die Legende zeigt den
Buchstaben des aktuellen Layouts.

| Taste | Wirkung | Bisher am Controller |
|---|---|---|
| S | Jetzt senden (Claude: Ctrl+X Ctrl+S; Codex: Enter bzw. „Weiter“) | R1 + Kreuz |
| M | Modus wechseln (Shift+Tab) | R1 + Dreieck |
| O | ausführliches Transkript an/aus (Ctrl+O), nur Claude | R1 + L3 |
| B | Befehle › (Options-Menü auf dieser Seite) | R1 + Viereck |
| K | Konto wechseln › | R1 + Kreis |
| L | Limits-Karte, solange ⌥ gehalten | R1 + ▲ |
| N | Mitteilungen eine Stufe weiter | R1 + ◀ |
| A | Wach bleiben eine Stufe weiter („awake“, W ist schon „wartet“) | R1 + ▶ |
| C | Zwischenablage-Verlauf (schließt die Insel) | R1 + ▼ |

S, M, O, B und K wirken wie am Controller auf den aktuellen Chat (Kopf der Insel), nicht auf die
markierte Zeile; die ist nur das Wechselziel. Damit das nicht verwechselt wird, heißt die Tastenzeile
sichtbar „für ‹aktueller Chat›“.

Schalter (N, A) lassen die Insel offen wie am Controller; alle anderen schließen sie.

### L1 Schreiben → keine Ebene, Spickzettel

Alles aus L1 hat auf der Tastatur schon eine eigene Taste:

| L1 am Controller | Tastatur heute |
|---|---|
| bis Zeilenanfang löschen | ⌘⌫ (wird zu Ctrl+U) |
| Zeilenumbruch ohne Senden | ⇧Return |
| Wort zurück/vor | ⌥← / ⌥→ |
| Zeile hoch/runter | ↑ ↓ im mehrzeiligen Entwurf |
| neuesten Eintrag einfügen | ⌘V |
| Escape | Esc |
| Rückgängig | Ctrl+_ |

Eine Ebene dafür wäre doppelt. Vorschlag: In der Insel zeigt **?** (⌥ halten, ? drücken) diese Tabelle als
Spickzettel, damit die Mechanik eine Stelle hat, an der man nachsehen kann. Optional, siehe Frage 7.

## Verhalten an den Rändern

- **Außerhalb der App:** Stufe 1 nur, wenn ein Agent-Chats-Fenster vorne ist (lokaler Monitor wie ⌃Tab).
  Stufe 2 auf Wunsch global: ⌥Tab als Carbon-Hotkey, während des Haltens werden ⌥⇧Tab, Pfeile, Esc,
  Return und die Buchstaben kurz mit belegt (dasselbe Muster wie die globale Esc-Taste der Nacharbeit,
  `cleanUpCancelKey`), das Loslassen von ⌥ erkennt ein kurzer Abgleich von `NSEvent.modifierFlags`, nur
  solange die Insel offen ist. Ein Wechsel holt Agent Chats nach vorn. Kosten: ⌥Tab fehlt dann allen
  anderen Apps (Tab in Tabellen, Safari-Links). Darum ein eigener Schalter, Standard aus.
- **Dialoge, Sheets, Menüs:** Die Insel geht nicht auf; ⌥Tab bleibt beim Dialog. Geht während des
  Haltens ein Dialog auf, schließt die Insel ohne Wechsel (wie am Controller).
- **Laufendes Diktat:** Wohin geht, Wechsel samt Ziel wie am Controller (das Diktat bleibt an seinem
  Ziel). Die Chat-Befehle (S, M, O, B, K) sind ausgegraut, App-Befehle (L, N, A, C) gehen. Leertaste heißt
  „stopp“. Esc schließt nur die Insel, die Aufnahme läuft weiter — das steht in der Fußzeile.
- **⌃Tab-Umschalter offen:** ⌥Tab tut nichts, bis er zu ist (nur eine Auswahl gleichzeitig).
- **Controller hält gerade eine Ebene:** Tastatur schließt die Insel wie heute („Maus oder Tastatur
  schließen sie“); ⌥Tab öffnet sie danach neu.
- **Kein Hover-only:** Die Insel hat keine Maus-Ziele; ein Klick irgendwo schließt sie ohne Wechsel.
  Alles Wichtige steht als Text: Ziel, „vorher“, Tastenzeile, Fußzeile.
- **Wiederholung:** Tab und Pfeile wiederholen beim Halten wie gewohnt (Systemrate), ohne Umlauf am Ende.
- **Bildschirm:** wie am Controller der Bildschirm des Agent-Chats-Fensters, an der Notch oder aus der Pille.

## Legende

Ohne Controller zeigt die Legende unten im Fenster künftig Tastatur: „⌥Tab Wohin · ⌥Leertaste
Diktieren · ⌃Tab Raster“. Mit verbundenem Controller bleibt sie, wie sie ist. In der Insel stehen
Tastenkappen statt Controller-Zeichen (⌥, ⇥, ⇧⇥, ←→, ␣, esc, Buchstaben).

## Varianten im Entwurf

- **A Eins zu eins:** ⌥Tab = L2 Wohin wie oben; R1 auf eigener Taste, ⌥ + Taste über Tab (^ bzw. \`),
  mit derselben Raute wie am Controller, Pfeile statt Steuerkreuz. Kein L1. Vertraut für Controller-
  Nutzer, aber zwei Kürzel zum Merken, und genau diese Taste ist vermutlich AltTabs zweites Kürzel.
- **B Eine Insel (Empfehlung):** ⌥Tab öffnet Wohin, Buchstaben für die Schnellbefehle in derselben Insel,
  Leertaste diktiert, ? zeigt den Spickzettel.
- **C Insel statt Kacheln:** ⌃Tab öffnet die Insel, die Kacheln fallen weg; die markierte Zeile zeigt
  die Stand-Zeile der Kachel als zweite Zeile. Ein Kürzel weniger, aber Raster-Navigation und
  Muskelgedächtnis gehen verloren.

## Aufwand (grob, nur zur Einordnung)

Der Inhalt der Insel ist da (`ControllerIslandPresenter`, Wohin-Modell, Rauten-Aktionen). Neu wären:
eine Tastatur-Quelle, die dieselben Gesten-Ereignisse liefert wie der Controller (⌥ halten/loslassen,
Schritt, Reiter, Bestätigen, Abbrechen, Befehl X), eine Tastenzeile statt Raute in der Ansicht, die
Tastatur-Legende und — für Stufe 2 — die globalen Hotkeys. Etwa so groß wie das Insel-Paket ohne
Limits-Karte; Stufe 2 ein eigenes kleines Paket.

## Entscheidungen für Giuliano

Siehe Abschnitt am Ende des Entwurfs; dieselbe Liste geht als Chat-Antwort an Giuliano.
