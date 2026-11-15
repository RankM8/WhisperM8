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

**Stand:** gebaut in drei Paketen: Wohin (1), Schnellbefehle, Spickzettel und Options-Menü per
Tastatur (2), Legende (3). Global außerhalb der App ist ein späteres eigenes Paket.

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
ohne ⌥ an, ist uns das Loslassen entgangen (Menü-Tracking, Mission Control mit gehaltenem ⌥): Die Insel
schließt ohne Wechsel, die Taste läuft normal weiter. Return und Esc schließen nur und werden
verschluckt: Ein durchgereichtes Return bestätigte womöglich eine offene Freigabe im Chat. Ein ⌥-Loslassen, das wir nicht gesehen haben, schließt ebenso ohne Wechsel.

**Geht nicht** (W ohne wartenden Chat, R ohne geschlossenen Chat, Leertaste auf einem Workspace,
gescheiterter Wechsel): macOS-Warnton, die Insel bleibt offen (Entscheidung Giuliano, 15.11.2026).

## Schnellbefehle (Paket 2)

Unter der Liste steht im Reiter „Chats“ die Tastenzeile, jeder Buchstabe sichtbar am Eintrag. Oben
„für ‹aktueller Chat›“: S, M, O, B und K wirken wie am Controller auf den aktuellen Chat (Kopf der
Insel), nicht auf die markierte Zeile. Darunter „App“.

| Taste | Wirkung | am Controller |
|---|---|---|
| S | Jetzt senden (Claude: Ctrl+X Ctrl+S; Codex: Enter bzw. „Weiter“), Beschriftung wie unter R1 | R1 + Kreuz |
| M | Modus wechseln (Shift+Tab) | R1 + Dreieck |
| O | ausführliches Transkript an/aus (Ctrl+O), nur Claude | R1 + L3 |
| B | Befehle › — Options-Menü direkt auf dieser Unterseite | R1 + Viereck |
| K | Konto wechseln › | R1 + Kreis |
| L | Limits-Karte statt der Liste; ↑/↓ blättern, Return holt frisch, L zurück zur Liste | R1 + ▲ |
| N | Mitteilungen eine Stufe weiter, Insel bleibt, Stand und nächste Stufe stehen da | R1 + ◀ |
| A | Wach bleiben eine Stufe weiter, ebenso; fehlt die Freigabe, Hinweis und Warnton | R1 + ▶ |
| C | Zwischenablage-Verlauf (schließt die Insel) | R1 + ▼ |
| ? | Spickzettel der Schreib-Tasten statt der Liste; noch mal ? zurück | — |

- **Codex-Freigabe:** Steht bei Codex eine Freigabe am Bildschirm offen (auch hochgescrollt), schicken
  S, R1 + Kreuz und das Paddle nichts (Warnton bzw. „geht nicht“): Enter oder „Weiter“ bestätigte sie
  sonst. Geprüft in `quickCross` und zuletzt noch einmal in `sendOrContinue`.
- **Regeln:** dieselben wie bei den R1-Rauten (`ControllerQuickDrawSlots`, `ControllerMenuModel`):
  Rückfrage offen, Chat arbeitet, Shell. Was nicht geht, steht ausgegraut da und gibt den Warnton.
  Befehle schließen die Insel nach einer kurzen Markierung, N und A lassen sie offen.
- **Diktat:** Während eines Diktats sind S M O B K aus („aus, solange das Diktat läuft“), L N A C gehen.
- **Loslassen nach einem Befehl:** Nach N, A, L oder ? wechselt ⌥ loslassen nicht, bis sich die
  Markierung wieder bewegt; die Fußzeile sagt dann „⌥ loslassen: nichts wechselt (Markierung
  unbewegt)“. Bei offener Karte oder offenem Spickzettel schließt das Loslassen nur.
- **Reiter „Workspaces & Projekte“:** Dort fehlt die Tastenzeile (wie im Entwurf), und die Buchstaben, W
  und R wirken dort nicht (Warnton). Was nicht zu sehen ist, geht auch nicht.
- **Layout:** Erkannt über den keyCode (ANSI-Lage, auf QWERTZ und QWERTY gleich). Die Tastenzeile zeigt
  den Buchstaben des aktuellen Layouts, wenn er abweicht (`KeyboardLayoutLetters`, AZERTY: Q statt A),
  gelesen beim Öffnen auf dem Main Thread. „?“ wird am Zeichen erkannt (US ⇧/, DE ⇧ß).
- **Options-Menü per Tastatur:** B und K öffnen dieselbe Menü-Karte wie am Controller. Per Tastatur gehen
  ↑/↓ (und Tab), Return oder → wählen, Esc oder ← eine Ebene zurück bzw. schließen; jede andere Taste
  schließt das Menü und läuft normal weiter, ein Klick schließt es. Die Fußzeile der Karte zeigt dann
  Tastenkappen (`controllerMenuByKeyboard`, `ControllerUIModel.menuByKeyboard`).

## Legende

Die Leiste unten im Fenster folgt dem zuletzt benutzten Gerät, aber nur mit eingeschalteter
Controller-Steuerung (Entscheidung Giuliano, 15.11.2026; `KeyboardLegend.mode`):

| Controller-Steuerung | Controller verbunden | zuletzt benutzt | Leiste |
|---|---|---|---|
| aus | – | – | keine, wie bisher (die Kürzel stehen in der Insel) |
| an | ja | Controller | Controller-Tasten wie bisher |
| an | ja | Tastatur (⌥Tab) | „⌥⇥ Wohin · ⌥␣ Diktat · ⌃⇥ Raster“ |
| an | nein | – | Tastatur-Kürzel statt nichts |

„Zuletzt benutzt“ merkt `ControllerUIModel.lastInput`: ⌥Tab setzt „Tastatur“, jede ausgeführte
Controller-Aktion „Controller“; das Options-Menü per Tastatur zählt als Tastatur. Ist die Insel per
Tastatur ausgeschaltet, nennt die Leiste keine Tastatur-Kürzel. Der Diktat-Eintrag zeigt den eingestellten
Hotkey (ab Werk ⌥Leertaste), gelesen beim Erscheinen der Leiste; ohne Hotkey fehlt er. Der Schalter
„Legende am unteren Rand“ (Einstellungen › Controller) gilt für beide.

## Diktat

- **⌥Leertaste** ist der Diktat-Hotkey (global über Carbon) und kommt nie als Tastendruck an. Ist die
  Insel offen, heißt er dort „hin und diktieren“ bzw. „stopp“ wie die Leertaste; sein Loslassen beendet
  die gerade gestartete Aufnahme nicht (`KeyboardIslandMonitor.consumeDictationHotkeyDown/Up`). Ohne
  offene Insel bleibt ⌥Leertaste unverändert; ein gewöhnlicher Druck löscht einen liegengebliebenen
  Merker, damit ein verlorenes Loslassen nie das Ende eines späteren Diktats verschluckt.
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
| Ansicht | `Views/Controller/ControllerIslandView+Keyboard.swift` | Tastenkappen in Kopf und Fußzeile (`KeyboardIslandFooter` pur), Tastenzeile, Spickzettel |
| Schnellbefehle | `Core/ControllerIslandKeyboard.swift`, `ControllerActionDispatcher+KeyboardCommands.swift` | Buchstaben und Stand der Tastenzeile (pur); Ausführung über dieselben Wege wie R1 (`sendOrContinue`, `perform(_:setup:)`, `openLimitsCard`, App-Schalter); Options-Menü per Tastatur |
| Legende | `Views/Controller/KeyboardLegend.swift`, `ControllerLegendHost` | Entscheidung Controller/Tastatur/keine (pur), Tastenkappen in der Leiste |
| Layout | `KeyboardIsland/KeyboardLayoutLetters.swift` | Buchstabe je keyCode im aktuellen Layout (`UCKeyTranslate`, nur Main Thread) |

Leistung: Der Monitor prüft bei geschlossener Insel nur keyCode und Modifier; Einstellungen und
Schnappschuss liest er erst bei ⌥Tab. ⌥Tab baut nur die Liste; Menü-Angaben, Schalterstände und die
Layout-Abfrage der Tastenzeile entstehen erst, wenn die Insel nach 0,2 s erscheint oder ein Buchstabe
kommt (`ensureKeyboardCommands`), ⌥Tab kurz getippt braucht sie nie. Beide Schritte misst dasselbe
Signpost wie am Controller (`controller.islandShow`, Budget 33 ms).

## Prüfen

- `swift test --filter KeyboardLegend` — wann die Leiste was zeigt und der Merker des Geräts.
- `swift test --filter KeyboardIsland` — Tastenregeln, Markierung im Modell, Fußzeile und der Ablauf
  durch Monitor und Ausführer (kurz getippt, halten, Esc, Return, Dialog, Diktat, Hotkey, Controller).
- `make snapshots ONLY=insel-tastatur` — Chats mit Tastenzeile und Markierung auf „vorher“, ohne
  Tastenzeile (Paket 1), Workspaces im Raster, während eines Diktats, nach N (Bestätigung), Spickzettel,
  Limits-Karte, als Pille, Options-Menü per Tastatur, Legende hell und dunkel.
- Von Hand nach `make dev`: ⌥Tab kurz und gehalten in Einzelansicht und Raster; im Terminal mit Fokus
  (nichts kommt in der CLI an); mit offenem Einstellungsfenster vorne (⌥Tab läuft durch); ⌥Leertaste bei
  offener Insel; S, O und M an Claude und Codex; B und K mit Pfeilen und Return; N und A mehrfach.
