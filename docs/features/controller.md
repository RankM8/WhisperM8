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
| Linker Stick | Liste hoch/runter; nach rechts in den Inhalt, nach links zurück in die Liste; in der Einzelansicht springt die Markierung mit hoch/runter in die Liste (Start beim aktuellen Chat, sofort ein Schritt, der offene Chat bleibt); im Raster von Kachel zu Kachel; während Aufnahme, Transkription und Nacharbeit ohne Wirkung |
| Kreuz | in der Liste öffnen (Chat, Workspace, Projekt als Workspace) und hinein — ein Chat unter einem Workspace, der nicht sichtbar ist, öffnet diesen Workspace mit dem Chat als Kachel-Fokus; im Chat Enter; gestoppter Chat: starten |
| Kreis | zurück (aus der Liste ohne Wechsel in den bisherigen Chat); im Chat Escape (nur wenn er ruht oder fragt); halten (0,4 s): arbeitenden Chat unterbrechen |
| R2 | Diktat an und aus (Umschalter wie der Hotkey, kein Halten) |
| Dreieck | nächster Chat, der wartet (wie ⌃⌥Tab); aus anderen Fenstern: Agent Chats nach vorn |
| L1 / R1 | voriger / nächster Chat in der Reihenfolge der Liste (auch im Raster, kein Umlauf); in der Liste der Filter Aktiv / Zuletzt / Alle. Die Tastatur (⌘⌥←/→) bleibt bei den Tabs |
| Steuerkreuz | Pfeiltasten in den Chat nur, solange der Agent eine Rückfrage stellt; sonst wie der linke Stick (hoch/runter markieren in der Liste, links in die Liste, rechts nichts, im Raster Kachel zu Kachel); in der Liste wie der Stick |
| Rechter Stick | Verlauf scrollen (im Alternate-Puffer als Mausrad an die TUI), auch während Aufnahme, Transkription und Nacharbeit |

**Zusatz**

| Taste | Wirkung |
|---|---|
| Viereck | im Chat Rücktaste (ein Zeichen); halten: weiter löschen wie eine gehaltene Taste (nach 0,6 s alle 60 ms, nach 1 s alle 25 ms); in der Liste halten: Zeile schließen wie ihr „−“/„×“ |
| Create | Projekt-Auswahl „Neuer Chat“ (wie ⌘N), aktuelles bzw. markiertes Projekt vorausgewählt — „Create, Kreuz“ startet dort |
| Touchpad-Klick | Zwischenablage-Verlauf auf und zu |
| L3 | Kachel groß / zurück zum Raster |
| R3 | gestoppten Chat starten (im Chat und auf der markierten Zeile der Liste); sonst ohne Wirkung, auch ohne Vibration |
| Options | das eine Menü, siehe unten |
| L2 tippen / halten | letzter Chat / Chat-Auswahl (der Ctrl+Tab-Umschalter); Kreuz oder Loslassen wechselt. Im Raster öffnet halten die Workspace-Auswahl, siehe unten |
| L2 halten, dann R2 | zum markierten Chat wechseln und diktieren |
| L1 + R1 halten (1 s) | Controller pausieren und fortsetzen |

Nicht belegt: PlayStation-Taste (gehört macOS), Create doppelt oder lang (macOS: Screenshot bzw.
Bildschirmaufnahme). Zwei schnelle Create-Drücke ergeben deshalb einen Screenshot.

**Menü (Options):** drei Gruppen. Eingaben in den Chat: „Weiter“, „Befehle ›“ (zweite Ebene mit den
festen Befehlen der CLI, Tabelle `ControllerSlashCommands`; „/ eintippen“ bleibt ungesendet, alle
anderen werden gesendet), „Modus wechseln“ (Shift+Tab). Aktionen am Chat, dieselben Wege wie sein
Kontextmenü: „Konto wechseln ›“ (Claude-Konten wie „Zu Account verschieben“, bei GPT-Chats auch die
GPT-Konten), „Umbenennen…“, „Forken“, „Anheften/Lösen“, „Archivieren“, „Chat schließen“ (wie „−“/„×“
in der Seitenleiste). Dazu „Belegung anzeigen“ und „Controller pausieren“. In der Liste wirken die
Aktionen auf die markierte Chat-Zeile. Kreis geht eine Ebene zurück, Options schließt alles.

**Workspace-Auswahl (L2 halten im Raster):** kleines Panel im Stil des Menüs mit den angelegten
Workspaces (ohne versteckte Projekt-Ansichten) in der Reihenfolge der Seitenleiste. Je Zeile Farbe,
Name, Zahl der Chats und der Status-Punkt „wartet“, wenn dort ein Chat auf dich wartet (derselbe Status
wie in der Seitenleiste); der aktuelle Workspace trägt „current“ und ist der Startpunkt. Stick oder
Steuerkreuz bewegt (kein Umlauf), Loslassen von L2 oder Kreuz wechselt — derselbe Weg wie der Klick auf
den Kopf in der Seitenleiste, Konflikte inklusive —, Kreis bricht ab, R2 tut nichts. Nach dem Wechsel hat
die Kachel den Fokus, auf der du in diesem Workspace zuletzt warst, sonst die erste. Gemerkt wird das
beim Verlassen eines Workspace, nur für den laufenden App-Start. In der Einzelansicht bleibt L2 die
Chat-Auswahl; Ctrl+Tab zeigt auch im Raster weiter die Chats.

**Während der Aufnahme:** R2 beendet (Text ins Eingabefeld), Kreuz beendet und sendet (nur bei einem
Chat als Ziel), Kreis verwirft bzw. bricht Transkription oder Nacharbeit ab, Steuerkreuz wechselt den
Ausgabemodus nur für diese Aufnahme (links/rechts ein Schritt pro Druck, hoch/runter mit Wiederholung).
Bei jedem Wechsel steht über der Pill kurz die Liste aller Modi, der aktuelle markiert (eigenes kleines
Panel, `OutputModeListPresenter`; weg 1,5 s nach dem letzten Wechsel und sofort mit dem Ende der
Aufnahme). Der rechte Stick scrollt weiter; der linke ruht, ohne Vibration — ein Stoß beim Greifen nach R2
oder Kreis soll die Ansicht nicht verschieben. Die Pill zeigt Ziel und Modus ohne Hover.

**Zwischenablage-Verlauf:** Stick/Steuerkreuz wählt, Kreuz fügt ein, Dreieck korrigiert und fügt ein
(nur wenn verfügbar), Viereck halten (0,6 s) löscht, L1/R1 Filter Alle/Diktate (nicht in der großen
Bildansicht), L3 Bild groß und zurück, Kreis schließt (in der Bildansicht und bei der Rückfrage
„Verlauf leeren?“ erst dort zurück), Options öffnet ein Menü im Verlauf (Anheften/Lösen, Als reinen
Text einfügen, Markierung korrigieren, Verlauf leeren…, Einstellungen…). Bei „Verlauf leeren?“
bestätigt Kreuz. R2 diktiert hier nicht: Das Fenster ist nicht aktivierend, und der Hotkey-Weg legte
über Zwischenablage und ⌘V einen neuen Eintrag in genau diesen Verlauf. Ist ein Controller verbunden,
zeigt die Fußzeile seine Tasten statt der Tastenkürzel (aus derselben Tabelle wie die Legende).
Eingaben kommen nur an, wenn WhisperM8 vorne ist oder „Auch wenn ein anderes Programm vorne ist“ an ist.

**Dialoge, Sheets, Popover, Textfelder, andere WhisperM8-Fenster:** Tastatur-Brücke — Steuerkreuz =
Pfeile, Kreuz = Return, Kreis = Escape, L1/R1 = Shift+Tab/Tab. R2 diktiert dort in das Feld mit dem
Fokus. In Dialogen des Agent-Chats-Fensters bewegt auch der linke Stick hoch/runter. Die Projekt-Auswahl
„Neuer Chat“ und die Rückfragen „Chat beenden?“/„Chat archivieren?“ melden sich im Schnappschuss
(`isNewChatPickerOpen`, `isConfirmationOpen`); das Fenster bleibt Ziel, auch wenn das Popover selbst Key
wird. In beiden Rückfragen bestätigt Return (auch mit der Tastatur).

## Schutzregeln

- In eine offene Rückfrage läuft nie Text: Ein Diktat bleibt in der Zwischenablage (Hinweis), Einträge
  des Menüs, die etwas in den Chat schicken, sind aus — auch „Modus wechseln“, denn Shift+Tab heißt in
  Claudes Freigabe-Dialog „alle Änderungen erlauben“. `sendKey` verweigert dort Tab und Shift+Tab.
- Pfeiltasten gehen nur in eine offene Rückfrage. Sonst holte hoch den letzten Prompt zurück (Kreuz
  schickte ihn erneut, in einer Shell den letzten Befehl), und links schickt Claude im leeren
  Eingabefeld in den Hintergrund. Dieselbe Regel sichert `AgentTerminalController.sendKey` ab
  (`TerminalControlKey.controllerAllows`, nur der Weg des Controllers, nie die Tastatur).
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
- Viereck schickt nur die Rücktaste (0x7F), nie Ctrl+C — Ctrl+C hätte eine laufende Antwort abgebrochen.
- Befehle und „Weiter“ aus dem Menü werden nie an einen vermuteten Entwurf gehängt.
- R3 auf einem lebenden Chat tut nichts (er wird beim Scrollen leicht gedrückt).
- Schließen und Archivieren laufen über dieselben Funktionen wie die Seitenleiste, mit ihren Rückfragen.
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
- `make snapshots ONLY=controller` — Einstellungsseite, Legende in acht Zuständen (mit Raster),
  Menü mit beiden Ebenen, Workspace-Auswahl, Liste der Ausgabemodi an der Pill; `ONLY=clipboard-verlauf-controller` die Fußzeile und das
  Menü im Verlauf.
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
