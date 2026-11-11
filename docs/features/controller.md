---
status: aktiv
updated: 2026-11-11
description: Controller-Steuerung — WhisperM8 mit einem Gamepad (PS5 DualSense) bedienen; Belegung, Aufbau, Schalter, Prüfwege und Grenzen.
---

# Controller-Steuerung

WhisperM8 lässt sich mit einem Gamepad bedienen: durch die Liste links gehen, Chats, Workspaces und
Projekte öffnen, diktieren, Rückfragen der Agenten beantworten und den Zwischenablage-Verlauf nutzen.
Referenzgerät ist der PS5-Controller (DualSense) über Bluetooth; andere Gamepads laufen über das
allgemeine Profil (`GCExtendedGamepad`) mit.

Der Controller löst **Aktionen** aus, keine Tastendrücke an das Fenster im Vordergrund. Er schreibt
gezielt in das Terminal des Ziel-Chats und braucht dafür keine Bedienungshilfen-Berechtigung.

Plan mit Entscheidungen und Prüfprotokoll: [`../plans/controller-steuerung.md`](../plans/controller-steuerung.md).
Entwurf: [`../design/controller-steuerung.html`](../design/controller-steuerung.html).

## Einschalten

Einstellungen › Controller (Gruppe Labs). Ab Werk aus. Wird zum ersten Mal ein Gamepad erkannt,
während die Steuerung aus ist, erscheint einmal eine Mitteilung.

| Schalter | Standard | Wirkung |
|---|---|---|
| Controller-Steuerung | aus | liest Gamepads, zeigt Legende und Markierung |
| Legende am unteren Rand | an | Leiste mit Ziel und Tastenbelegung |
| Vibration | an | Impulse bei Aufnahme und wartenden Chats |
| Lichtleiste | an | Farbe nach Zustand |
| Auch wenn ein anderes Programm vorne ist | aus | Diktat und Verlauf überall; in Spielen ist R2 meist Gas oder Schuss |

Notbremse: `defaults write com.whisperm8.app controllerFeatureEnabled -bool NO` — kein Zugriff auf
das GameController-Framework, der Schalter wirkt nicht.

## Belegung

Grundregeln: Links navigieren, rechts sprechen und handeln. Ein Fokus (die Auswahl, die die App schon
hat), dazu eine Markierung in der Liste. Die Legende zeigt immer nur die Tasten, die gerade etwas tun.

**Kern**

| Taste | Wirkung |
|---|---|
| Linker Stick | Liste hoch/runter, nach rechts in den Inhalt, nach links zurück in die Liste, im Raster von Kachel zu Kachel |
| Kreuz | in der Liste öffnen (Chat, Workspace, Projekt als Workspace); im Chat Enter |
| Kreis | zurück; im Chat Escape (nur wenn er ruht oder fragt); halten (0,4 s): arbeitenden Chat unterbrechen |
| R2 | Diktat an und aus (Umschalter wie der Hotkey, kein Halten) |
| Dreieck | nächster Chat, der wartet (wie ⌃⌥Tab); aus anderen Fenstern: Agent Chats nach vorn |
| L1 / R1 | Tabs; in der Liste der Filter Aktiv / Zuletzt / Alle |
| Steuerkreuz | Pfeiltasten in den Chat (Rückfragen); in der Liste wie der Stick |
| Rechter Stick | Verlauf scrollen (im Alternate-Puffer als Mausrad an die TUI) |

**Zusatz**

| Taste | Wirkung |
|---|---|
| Viereck | Eingabefeld leeren — nur Claude, Chat ruht, Entwurf erkannt (Ctrl+C) |
| Create | neuer Chat im aktuellen bzw. markierten Projekt |
| Touchpad-Klick | Zwischenablage-Verlauf auf und zu |
| L3 | Kachel groß / zurück zum Raster |
| Options | Menü: „Weiter“, Befehle (`/`), Modus wechseln, `/compact`, Tab schließen, Belegung, Pause |
| L2 tippen / halten | letzter Chat / Chat-Auswahl (der Ctrl+Tab-Umschalter), loslassen wechselt |
| L2 halten, dann R2 | zum markierten Chat wechseln und diktieren |
| L1 + R1 halten (1 s) | Controller pausieren und fortsetzen |

Nicht belegt: PlayStation-Taste (gehört macOS), R3, Create doppelt oder lang (macOS: Screenshot bzw.
Bildschirmaufnahme). Zwei schnelle Create-Drücke ergeben deshalb einen Screenshot.

**Während der Aufnahme:** R2 beendet (Text ins Eingabefeld), Kreuz beendet und sendet (nur bei einem
Chat als Ziel), Kreis verwirft bzw. bricht Transkription oder Nacharbeit ab, Steuerkreuz links/rechts
wechselt den Ausgabemodus nur für diese Aufnahme. Die Pill zeigt Ziel und Modus ohne Hover.

**Zwischenablage-Verlauf:** Stick/Steuerkreuz wählt, Kreuz fügt ein, Kreis schließt, Dreieck heftet
an, Viereck halten (0,6 s) löscht.

**Dialoge, Sheets, Popover, Textfelder, andere WhisperM8-Fenster:** Tastatur-Brücke — Steuerkreuz =
Pfeile, Kreuz = Return, Kreis = Escape, L1/R1 = Shift+Tab/Tab. R2 diktiert dort in das Feld mit dem
Fokus.

## Schutzregeln

- In eine offene Rückfrage läuft nie Text: Ein Diktat bleibt in der Zwischenablage (Hinweis), Einträge
  des Menüs, die etwas in den Chat schicken, sind aus — auch „Modus wechseln“, denn Shift+Tab heißt in
  Claudes Freigabe-Dialog „alle Änderungen erlauben“. `sendKey` verweigert dort Tab und Shift+Tab.
- „Weiter“ aus dem Menü wird nicht an einen vorhandenen Entwurf gehängt.
- Kreuz während der Aufnahme sendet nur bei Claude und Codex; in einer Shell wäre der Text ein Befehl.
- Solange das Mikrofon verbindet, zählt das als Aufnahme: R2 beendet (sobald sie läuft), Kreis verwirft.
- Kreuz ist 0,5 s nach Erscheinen einer Rückfrage ohne Wirkung.
- Ein zweites Escape innerhalb 1 s wird verschluckt (Claude öffnet sonst das Zurückspulen).
- Escape per Tippen nur bei ruhendem oder fragendem Chat; „gerade gesendet“ (3 s nach jedem
  programmatischen Versand: Enter vom Controller, Diktat mit Senden, `chats send`) und unbekannter Status
  zählen als arbeitend.
- Pause (L1 + R1, Sperre, Ruhezustand, Spiel), Trennung und Ausschalten schließen Auswahl, Menü und Liste.
  Ein per Tastatur geöffneter Ctrl+Tab-Umschalter schließt erst, wenn der Controller wirklich etwas
  ausführt.
- Viereck nur bei Claude, ruhendem Chat und erkanntem Entwurf (ein zweites Ctrl+C beendet Claude).
- Return geht nie an fremde Programme: Kreuz während der Aufnahme sendet nur bei einem Chat als Ziel.
- Leeres Diktat in einen Chat: nichts wird kopiert, geschrieben oder gesendet.
- R2 löst erst ab halbem Hub aus (ein bei 0,5, frei bei 0,3); das Framework meldet schon ab 0,02.

## Aufbau

```
GameControllerInputSource ──┐  eigene serielle Queue
debug.controller (Skript) ──┤
                            ▼
                ControllerGesturePump → ControllerGestureRecognizer (pur)
                            ▼  nur diskrete Gesten zum Main Thread
                ControllerManager → ControllerContextResolver + ControllerBindingResolver (pur)
                            ▼
                ControllerActionDispatcher → AgentChatsCommandCenter, AgentTerminalController,
                                             AppState (Diktat), ClipboardHistoryController
```

| Teil | Datei | Aufgabe |
|---|---|---|
| Kern | `Services/Controller/Core/` | Tasten, Gesten, Zusammenhang, Belegung, Legende, Listen- und Menü-Modell, Regeln für Licht, Warte-Signal und Spiele — nur Foundation, ein Quelltext-Test erzwingt das |
| Quelle | `GameControllerInputSource` | Verdrahtung des Frameworks, Lichtleiste, Haptik (eine Engine je Controller, Neuaufbau nach Fehler) |
| Pumpe | `ControllerGesturePump` | Erkennung auf eigener Queue; `DispatchSourceTimer(.strict)` nur, solange etwas gedrückt ist, dann auch Aktivität gegen App Nap |
| Manager | `ControllerManager` | Ein/Aus nach Schaltern, Pause, Hintergrund-Zustand (Systemwert wird zurückgelesen), Zähler je Taste |
| Ausführer | `ControllerActionDispatcher` | Schnappschuss der App je Eingabe, Ausführung über Schnittstellen (`ControllerTerminalControlling`, `ControllerDictationControlling`, `ControllerAppEnvironment`) |
| Rückmeldung | `ControllerFeedback` | Lichtleiste, Warte-Signal, automatische Pause, Maus/Tastatur geben Liste und Menü ab |
| Katalog | `AgentChatsCommandCenter` | Befehle an das Key-Fenster (Token-Anmeldung je Fenster); Tastaturkürzel nutzen dieselben Funktionen |
| Terminal | `TerminalControlKey`, `AgentTerminalController.sendKey` | feste Tastenliste; Entwurfs-Tracker und Abbruch-Verdacht wie bei der Tastatur |
| Diktat-Ziel | `DictationDelivery`, `RecordingCoordinator+ChatDelivery` | Text als ein Block direkt ins Terminal; der Hotkey-Weg ins vordere Programm ist unverändert |
| Ansicht | `Views/Controller/` | Legende, Menü, Listen-Markierung, Texte und Symbole |

Leistung: Im Ruhezustand läuft nichts. Legende, Menü und Markierung sind eigene kleine Ansichten mit
eigenem Beobachtungswert (`ControllerUIModel`); der Body von `AgentChatsView` und die Sidebar-Zeilen
lesen ihn nicht. Die Zeilen der Liste werden nur im Ereignis-Pfad berechnet.

## Prüfen

- `swift test --filter Controller` — Kern, Ausführer, Manager, Debug-Kanal.
- `make snapshots ONLY=controller` — Einstellungsseite, Legende in sechs Zuständen, Menü.
- `whisperm8 debug controller state` — Verbindung, Schalter, Zähler je Taste (App vorne / im
  Hintergrund), zuletzt aufgelöste Gesten.
- `whisperm8 debug controller press <taste>` und `sequence "<schritte>"` — künstliche Eingaben durch
  dieselbe Kette; ohne `--execute` ein Trockenlauf. Ausführen geht nur in der Test-Instanz, mit
  `--window <id>` und `--frontmost` (die Test-Instanz hat nie ein aktives Fenster). Ein Skript muss
  alles wieder loslassen; Läufe schließen sich aus, und die Kette wird vor dem Ende geleert — so wirkt
  nach einem Trockenlauf nichts nach.

## Grenzen

- **Tasten im Hintergrund** hängen an `GCController.shouldMonitorBackgroundEvents`. Unter macOS 15.4
  war das defekt; die Einstellungsseite zeigt „funktioniert / nicht verfügbar / noch nichts empfangen“.
- Ein Diktat per Controller in einen Chat liefert nur Text, keine Bild-Anhänge.
- Die Stumm-Taste meldet das Framework nicht. Akkustand kommt über Bluetooth oft nicht an („nicht
  gemeldet“).
- Spiele über Wine (Whisky, CrossOver) und Cloud-Gaming im Browser erkennt die automatische Pause nicht
  sicher; dafür gibt es L1 + R1.
- Die Tastatur-Brücke sichert Bestätigen und Abbrechen zu. Mehr als zwei Knöpfe in einem Dialog
  erreicht sie nur mit eingeschalteter Tastaturnavigation des Systems.
- Was eine Projektgruppe per „N weitere anzeigen“ zusätzlich aufgeklappt hat, erreicht die
  Listen-Navigation nicht; sie reicht bis zum Startlimit der Gruppe und immer bis zum gewählten Chat.
- Umbelegen gibt es noch nicht; die Belegung ist eine pure Tabelle, auf die das später aufsetzen kann.
