---
status: aktiv
updated: 2026-11-15
description: Dynamic Island per Tastatur (⌥Tab, WM8-104) — Wohin, Tasten in der Insel, Schalter, Verhalten an den Rändern und Aufbau.
---

# Dynamic Island per Tastatur

Dieselbe Dynamic Island wie am Controller (L2 „Wohin“), bedient mit der Tastatur. Entwurf und Plan:
[`../design/insel-tastatur.html`](../design/insel-tastatur.html),
[`../plans/insel-tastatur.md`](../plans/insel-tastatur.md). Abgenommen ist Variante B (eine Insel,
Schnellbefehle als Buchstaben); Ticket WM8-104. Die Insel selbst beschreibt
[controller.md](controller.md#ebenen-und-dynamic-island).

**Stand:** Paket 1 (Wohin). Schnellbefehle als Buchstaben, Spickzettel und die Tastatur-Legende folgen.

## Einschalten

Einstellungen › Agent Chats › „Dynamic Island per Tastatur (⌥Tab)“, ab Werk **an**, unabhängig von
der Controller-Steuerung (Entscheidung Giuliano, 15.11.2026). Aus: ⌥Tab verhält sich wie vorher.
Schlüssel `keyboardIslandEnabled`.

## Tasten

| Taste (⌥ gehalten) | Wirkung | wie am Controller |
|---|---|---|
| ⌥Tab kurz | zum vorigen Ort, ohne dass die Insel aufblitzt | L2 getippt |
| ⌥Tab halten | nach 0,2 s steht die Insel, Markierung auf „vorher“ | L2 halten |
| Tab / ⇧Tab, ↓ / ↑ | Markierung weiter / zurück, ohne Umlauf; Wiederholung beim Halten | Stick hoch/runter |
| ← / → | Reiter „Chats“ / „Workspaces & Projekte“; Markierung dort auf „vorher“, wenn der Reiter den vorigen Ort führt, sonst auf dem aktuellen | Steuerkreuz links/rechts |
| ⌥ loslassen, Return | zum markierten Eintrag (auf dem aktuellen: nichts) | Loslassen, Kreuz |
| Esc | abbrechen; erreicht nie das Terminal und beendet nie eine Aufnahme | Kreis |
| Leertaste | hin und diktieren; während eines Diktats „stopp“ | R2 |
| W | nächster wartender Chat, reihum (wie ⌃⌥Tab) | Dreieck |
| R | zuletzt geschlossenen Chat wieder öffnen | Viereck |

**Start auf „vorher“:** Wie bei ⌘Tab ist der Druck auf Tab schon ein Schritt. Die Markierung steht auf
dem vorigen Ort, in dem Reiter, der ihn führt (im Raster also auch im Reiter „Chats“, wenn der vorige
Ort ein Chat war). So führt ⌥Tab kurz getippt genau dorthin, wo L2 getippt hinführt, auf demselben Weg
(`lastChat`). Ohne vorigen Ort steht die Markierung eine Zeile unter dem aktuellen Eintrag.

Erkannt wird über den keyCode, nicht über das Zeichen: Mit ⌥ liefert das Layout andere Zeichen. Andere
Tasten bei gehaltenem ⌥ schluckt die Insel, damit kein ⌥-Zeichen ins Terminal rutscht. Kommt eine Taste
ohne ⌥ an, ist uns das Loslassen entgangen (Menü-Tracking): Die Insel schließt ohne Wechsel, die Taste
läuft normal weiter. Dasselbe gilt für ein ⌥-Loslassen, das wir nicht gesehen haben.

**Geht nicht** (W ohne wartenden Chat, R ohne geschlossenen Chat, Leertaste auf einem Workspace,
gescheiterter Wechsel): macOS-Warnton, die Insel bleibt offen (Entscheidung Giuliano, 15.11.2026).

## Diktat

- **⌥Leertaste** ist der Diktat-Hotkey (global über Carbon) und kommt nie als Tastendruck an. Ist die
  Insel offen, heißt er dort „hin und diktieren“ bzw. „stopp“ wie die Leertaste; sein Loslassen beendet
  die gerade gestartete Aufnahme nicht (`KeyboardIslandMonitor.consumeDictationHotkeyDown/Up`). Ohne
  offene Insel bleibt ⌥Leertaste unverändert.
- **Während eines Diktats** geht die Insel nur auf, wenn das Diktat an einen Chat gebunden ist. Bei einem
  Diktat ins Programm vorne (Hotkey) bleibt ⌥Tab zu: Ein Wechsel brächte den Text woanders hin.
  Gebunden: Wohin geht, das Diktat bleibt an seinem Ziel, der Kopf nennt es („→ Chat“). Leertaste heißt
  „stopp“ (Text ins Feld), Esc schließt nur die Insel — das steht in der Fußzeile.

## Ränder

- **Fenster nicht vorn:** Die Insel geht nur auf, wenn WhisperM8 vorne ist und ein Agent-Chats-Fenster
  die Tastatur hat (lokaler Monitor wie ⌃Tab). Ist ein anderes Programm vorne, erreicht ⌥Tab WhisperM8
  gar nicht und tut dort, was es dort tut. Steht ein anderes WhisperM8-Fenster vorn (Einstellungen),
  läuft ⌥Tab dorthin durch. Global außerhalb der App ist später ein eigener Schalter, ab Werk aus.
- **Dialoge, Sheets, Controller-Menü:** Die Insel geht nicht auf, ⌥Tab bleibt beim Dialog. Geht während
  des Haltens ein Dialog auf, schließt das Loslassen nur die Insel.
- **⌃Tab-Umschalter offen:** ⌥Tab tut nichts, bis er zu ist.
- **Controller:** Hält der Controller gerade eine Ebene, schließt ⌥Tab dessen Insel und öffnet sie für
  die Tastatur neu; die Controller-Ebene bleibt bis zum Loslassen zu. Umgekehrt schließt jede
  Controller-Eingabe die Insel per Tastatur ohne Wechsel.
- **Maus, App-Wechsel:** Ein Klick irgendwo oder das Verlieren des Fokus schließt die Insel ohne Wechsel.
- **Terminal:** Der Monitor läuft vor SwiftTerms `keyDown`. ⌥Tab erreichte die CLI auch vorher nie
  (`optionAsMetaKey = false`; macOS macht daraus `insertTabIgnoringFieldEditor:`, das SwiftTerm nicht
  kennt). Claude Code und Codex verlieren also keine Eingabe. Bei offener Insel geht keine Taste ins
  Terminal; ⌃Tab, ⌃⌥Tab und alle Tasten ohne ⌥ bleiben unberührt.
- **Ohne Hover:** Die Insel hat keine Maus-Ziele. Kopf (⌥ + ⇥) und Fußzeile nennen die Tasten als
  Tastenkappen; R steht ausgegraut da, wenn nichts geschlossen ist.

## Aufbau

| Teil | Datei | Aufgabe |
|---|---|---|
| Regeln | `Services/Controller/KeyboardIsland/KeyboardIslandKeys.swift` | pur: wann ⌥Tab öffnet, was eine Taste bei offener Insel tut, wann ⌥-Loslassen wechselt |
| Quelle | `KeyboardIslandMonitor.swift` | lokaler Monitor (keyDown, flagsChanged, Klick), Erscheinen nach 0,2 s, Diktat-Hotkey |
| Ausführer | `ControllerActionDispatcher+Keyboard.swift` | dieselbe Insel (`makeIsland(.whereTo, input: .keyboard)`) und dieselben Wege wie L2 (`go(to:previous:)`); kein `spentLayer` |
| Modell | `Core/ControllerIsland.swift` | `ControllerIslandInput`, `markPreviousForKeyboard`, `switchTabForKeyboard` |
| Ansicht | `Views/Controller/ControllerIslandView+Keyboard.swift` | Tastenkappen in Kopf und Fußzeile (`KeyboardIslandFooter` pur) |

Leistung: Der Monitor prüft bei geschlossener Insel nur keyCode und Modifier; Einstellungen und
Schnappschuss liest er erst bei ⌥Tab. Das Erscheinen misst dasselbe Signpost wie am Controller
(`controller.islandShow`).

## Prüfen

- `swift test --filter KeyboardIsland` — Tastenregeln, Markierung im Modell, Fußzeile und der Ablauf
  durch Monitor und Ausführer (kurz getippt, halten, Esc, Return, Dialog, Diktat, Hotkey, Controller).
- `make snapshots ONLY=insel-tastatur` — Chats mit Markierung auf „vorher“, Workspaces im Raster,
  während eines Diktats, als Pille.
- Von Hand nach `make dev`: ⌥Tab kurz und gehalten in Einzelansicht und Raster; im Terminal mit Fokus
  (nichts kommt in der CLI an); mit offenem Einstellungsfenster vorne (⌥Tab läuft durch); ⌥Leertaste bei
  offener Insel.
