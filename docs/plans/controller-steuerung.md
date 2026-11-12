---
status: umgesetzt, Handtest nach make dev offen
stand: 2026-11-11
feature: Controller-Steuerung (PS5 DualSense und andere Gamepads)
branch: feat/controller-steuerung
---

# Controller-Steuerung

WhisperM8 soll sich mit einem Gamepad bedienen lassen: durch die Liste links gehen, Chats, Workspaces
und Projekte öffnen, diktieren, Rückfragen der Agenten beantworten, den Zwischenablage-Verlauf nutzen.
Referenzgerät ist der PS5-Controller (DualSense) über Bluetooth. Andere Gamepads laufen über das
allgemeine Profil mit.

**Ziel Nummer 1 ist Einfachheit.** Die Steuerung ist ein Arbeitswerkzeug und soll schnell zum Ziel
führen. Ein kleiner Kern, den man in einer Minute kann, dazu wenig Zusatz.

Dieses Dokument ist der Arbeitsplan. Jede Etappe hat feste Schritte, Tests und ein Abnahmekriterium.
Der Stand wird in Abschnitt 7 geführt. Der Plan ist am 11.11.2026 von drei unabhängigen Durchsichten
geprüft worden (Bedienkonzept, Architektur gegen den Code, Technik und Tests); ihre Befunde sind
eingearbeitet.

## 1. Ausgangslage

### Gemessen (11.11.2026, macOS 26.6, DualSense über Bluetooth)

- macOS meldet den Controller als `GCDualSenseGamepad`. Lichtleiste, Haptik und Bewegungssensor sind da.
- In einem Fenster im Vordergrund kamen 16 Tasten an: Kreuz, Kreis, Viereck, Dreieck, Steuerkreuz (4),
  L1, R1, L2, R2, L3, R3, Create (`Button Options`), Options (`Button Menu`).
- Die Stumm-Taste gibt es im Framework nicht.
- PlayStation-Taste und Touchpad-Klick sind als Elemente vorhanden, im Test aber nicht gedrückt worden.
  Die PlayStation-Taste öffnet unter macOS 26 das Spiele-Overlay und wird nicht belegt.
- Akkustand kam über Bluetooth nicht an (Standardwert 0 %, Zustand unbekannt). Anzeige dann
  „nicht gemeldet“, nie „0 %“.
- L2 und R2 gelten im Framework schon ab einem Wert von 0,02 als gedrückt. Ein aufliegender Finger
  würde auslösen. Die Trigger brauchen eine eigene Schwelle.
- Create ist an eine Systemgeste gebunden (`isBoundToSystemGesture`): Doppeldruck macht einen
  Screenshot, langer Druck eine Bildschirmaufnahme, ein Einzeldruck kommt leicht verzögert.
- **Offen: Tasten im Hintergrund.** `GCController.shouldMonitorBackgroundEvents` ist dafür da, war
  unter macOS 15.4 defekt (behoben in 15.5) und hält auf 26.6 den Wert `true`. Bewiesen ist der Empfang
  damit nicht. Die Test-Instanz liefert nur einen Hinweis, weil sie anders läuft als die echte App.
  Der gültige Beweis kommt nach `make dev` mit der echten App.

### Vergleichsprodukte

VibePad, ClaudeGamepad, Padcode, Helm, JoyCoding, Ultragrip, ClaudePad und Stream-Deck-Plugins
übersetzen fast alle Tasten in Tastendrücke für das Fenster im Vordergrund. Keins zeigt dauerhaft, was
jede Taste gerade tut. WhisperM8 besitzt die Terminals selbst und kann gezielt in einen bestimmten Chat
schreiben. Darauf baut der Plan auf: Der Controller löst Aktionen aus, keine Tastendrücke.

### Stand im Code

- Kein zentraler Aktions-Katalog. Tab-Wechsel, nächster wartender Chat, Kachel-Fokus und Umschalter
  sind private Funktionen in `AgentChatsView+Shortcuts.swift`, gebunden an `NSEvent`. Die Logik dahinter
  ist pur und getestet (`adjacentTabID`, `NextWaitingChatResolver`, `GridFocusNavigator`,
  `TabSwitcherModel`, `TabSwitcherScope`).
- Die Seitenleiste hat keine Tastatur-Bedienung. Reihenfolge der Zeilen und Markierung sind neu zu bauen.
- `AgentTerminalController` kennt `sendPrompt`, `sendUserText`, `sendInterrupt`, `sendComposerClear`.
  Einzelne Tasten (Pfeile, Enter) fehlen. `composerDraft` ist `private(set)`.
- Das Diktat hat einen Umschalt-Hotkey. Die Zustellung läuft über die Zwischenablage und Cmd+V
  (`PasteService`), hängt an der Auto-Paste-Einstellung und an der Bedienungshilfen-Berechtigung. Für
  die Zustellung gibt es keine Tests mit Spies; `pasteService` wird fest im `init` erzeugt.
- Zeilen- und Zeichenbudgets: `AgentChatsView.swift` 3.817 von 3.842, `AgentControlRequestHandler.swift`
  1.765 von 1.765 (kein Platz), `AgentTerminalView.swift` rund 94 Zeilen Luft, `CLAUDE.md` rund
  1.000 Zeichen Luft.
- Ausgangswert der Suite: 4.039 Tests, alle grün, einer übersprungen.

## 2. Bedienkonzept

### Grundregeln

1. **Einfach vor vollständig.** Was die Bedienung nicht schneller macht, bleibt bei Maus und Tastatur.
2. **Ein Fokus.** Der Controller bewegt die Auswahl, die die App schon hat: den aktiven Chat, die
   aktive Kachel (violetter Rahmen), dazu eine Markierung in der Liste links. Kein zweiter Cursor.
3. **Zwei Bereiche:** die Liste links und der Inhalt rechts. Der linke Stick wechselt dazwischen.
4. **Immer sichtbar, was jede Taste tut:** Legende am unteren Rand des Fensters, mit dem Ziel-Chat.
5. **Parallelen zur Tastatur.** Diktat ist ein Umschalter wie der Hotkey. Dreieck entspricht ⌃⌥Tab,
   L2 dem Ctrl+Tab-Umschalter.
6. **Nichts Riskantes durch einen einzelnen Tastendruck.** Unterbrechen braucht Halten. In einen
   offenen Rückfrage-Dialog läuft nie Text.

Als Eselsbrücke taugt der Shooter: L2 zielt (Chat anvisieren), R2 drückt ab (Diktat), Dreieck wechselt
die Waffe (nächster Chat), Kreuz bestätigt, Kreis geht zurück.

### Der Kern

| Taste | Wirkung |
|---|---|
| Linker Stick | bewegen: in der Liste hoch und runter, nach rechts in den Inhalt, nach links zurück in die Liste, im Raster von Kachel zu Kachel |
| Kreuz | auswählen und bestätigen: in der Liste Chat, Workspace oder Projekt öffnen; im Chat Enter (senden, bestätigen) |
| Kreis | zurück und abbrechen; halten (0,4 s): arbeitenden Chat unterbrechen |
| R2 | Diktat an und aus (Umschalter) |
| Dreieck | zum nächsten Chat, der auf Eingabe wartet |
| L1 / R1 | Reiter blättern im aktuellen Bereich: im Inhalt die Tabs, in der Liste „Aktiv / Zuletzt / Alle“ |
| Steuerkreuz | im Chat: Pfeiltasten (Rückfragen); in der Liste: wie der linke Stick |
| Rechter Stick | Verlauf scrollen |

### Der Zusatz

| Taste | Wirkung |
|---|---|
| Viereck | Eingabefeld leeren (nur wenn sicher ist, dass dort ein Entwurf steht) |
| Create | neuer Chat im aktuellen Projekt |
| Touchpad-Klick | Zwischenablage-Verlauf auf und zu |
| L3 (linker Stick gedrückt) | Kachel groß / zurück zum Raster |
| Options | Menü: Kurzantworten und Aktionen zum Chat |
| L2 tippen | zurück zum zuletzt aktiven Chat |
| L2 halten | Chat-Auswahl (der vorhandene Umschalter); loslassen wechselt |
| L2 halten, dann R2 | zum anvisierten Chat wechseln und sofort diktieren |
| L1 + R1 halten (1 s) | Controller pausieren und fortsetzen |

Nicht belegt: PlayStation-Taste (System), R3 (wird beim Scrollen leicht versehentlich gedrückt),
Create doppelt oder lang (macOS: Screenshot, Bildschirmaufnahme).

Bei der Maus bleiben: Layout-Auswahl des Rasters, „Notizen zu“, die Knöpfe im Chat-Kopf, Kontextmenüs,
Drag-and-drop, die Einstellungsseiten.

### In der Liste links

Die Markierung läuft über alle sichtbaren Zeilen in der angezeigten Reihenfolge: Workspaces mit ihren
Chats, dann Projekte mit ihren Chats.

| Taste | Wirkung |
|---|---|
| Stick / Steuerkreuz hoch, runter | Markierung bewegen, wiederholt beim Halten, Liste scrollt mit |
| Kreuz auf einem Chat | Chat öffnen, Bereich wechselt in den Inhalt |
| Kreuz auf einem Workspace | Workspace mit seinem Raster öffnen |
| Kreuz auf einem Projekt | Projekt als Workspace öffnen (alle aktiven Chats nebeneinander) |
| Stick rechts / Kreis | zurück in den Inhalt, ohne etwas zu öffnen |
| L1 / R1 | Filter „Aktiv / Zuletzt / Alle“ |
| Create | neuer Chat im markierten Projekt (bei Chat-Zeile: in dessen Projekt) |

Ist die Seitenleiste ausgeblendet, blendet Stick links sie ein. Maus oder Tastatur blenden die
Markierung aus.

### Im Inhalt

- **Einzelchat:** Stick links geht in die Liste; hoch/runter springen mit der Markierung in die Liste
  (Start beim aktuellen Chat, ein Schritt, Runde 3). Steuerkreuz, Kreuz, Kreis und R2 wirken auf den Chat.
- **Raster:** Der Stick bewegt den Rahmen von Kachel zu Kachel (dieselbe Logik wie ⌃⌘-Pfeile). Am
  linken Rand führt Stick links in die Liste. Die Kachel mit dem Rahmen ist das Ziel für alles.
- **Dreieck:** erst wartende Kacheln, dann wartende Chats außerhalb (Reihenfolge wie ⌃⌥Tab). Aus jedem
  WhisperM8-Fenster und ohne offenes Fenster holt Dreieck das Agent-Chats-Fenster nach vorn.

### Kreuz, Kreis und Viereck im Chat

Der Zustand des Ziel-Chats entscheidet. „Rückfrage“ heißt: Der Chat wartet auf eine Entscheidung
(Status `awaitingInput`, Freigabe, Plan oder Frage).

| Zustand | Kreuz | Kreis tippen | Kreis halten | Viereck |
|---|---|---|---|---|
| ruht | Enter | Escape | – | leert, wenn Entwurf erkannt und Claude-Profil |
| Rückfrage offen | Enter (bestätigt die markierte Option) | Escape (lehnt ab) | – | – |
| arbeitet | Enter | – | Escape (unterbricht) | – |
| unbekannt, oder gerade gesendet | Enter | – | Escape | – |
| beendet / nur Verlauf | – | – | – | – |

Schutzregeln:

- **Kreuz nach neuer Rückfrage:** 0,5 s lang ohne Wirkung, damit ein Reflex-Druck keine Freigabe erteilt.
- **Kreis:** Ein zweites Escape innerhalb 1 s wird verschluckt (zweimal Escape öffnet in Claude das
  Zurückspulen). „Gerade gesendet“ bestimmt der vorhandene Tracker (`countsAsInterrupt`).
- **Viereck:** sendet Ctrl+C und ist deshalb nur bei Claude-Profil, Status „ruht“ und erkanntem
  Entwurf aktiv. Sonst zeigt die Legende die Taste nicht.
- **Rückfrage offen:** Es läuft kein Text in den Chat. Ein Diktat bleibt in der Zwischenablage, mit
  Hinweis. Kurzantworten mit Text sind im Menü ausgegraut.

### Diktat

R2 ist ein Umschalter: einmal drücken startet, noch einmal drücken beendet. Halten ist nicht nötig,
Loslassen hat keine Wirkung. Ausgelöst wird erst ab halbem Hub (ein bei 0,5, wieder frei bei 0,3).

| Während die Aufnahme läuft | Wirkung |
|---|---|
| R2 | beenden, Text ins Eingabefeld des Ziel-Chats |
| Kreuz | beenden und danach senden (nur bei einem Chat als Ziel) |
| Kreis | verwerfen; in Transkription oder Nacharbeit: abbrechen |
| Steuerkreuz links / rechts | Ausgabemodus zurück / weiter, der Name steht groß in der Pill |
| alle anderen Tasten | keine Wirkung |

Ziel:

- **Agent-Chats-Fenster ist aktiv:** der ausgewählte Chat. Der Text wird direkt ins Terminal
  geschrieben (ein Block, ohne Enter). Das braucht weder Auto-Paste noch Bedienungshilfen und hängt
  nicht am Tastaturfokus. Die Pill nennt das Ziel („→ Titel des Chats“).
- **Ein anderes Programm ist vorne** und „Auch im Hintergrund“ ist eingeschaltet: wie beim Hotkey in
  dieses Programm. Kreuz hat dort keine Wirkung; Return geht nie an fremde Programme.
- **Zustellung prüft neu:** Hat der Ziel-Chat inzwischen eine Rückfrage offen oder ist beendet, bleibt
  der Text in der Zwischenablage und ein Hinweis erscheint. Leerer Text: nichts wird eingefügt oder
  gesendet.

Grenze dieser Runde: Per Controller gestartete Diktate in einen Chat liefern nur Text. Bild-Anhänge
über das Einfügen gibt es dort nicht. Der Hotkey-Weg bleibt unverändert.

### Zwischenablage-Verlauf

Touchpad-Klick öffnet und schließt. Im Verlauf: Stick oder Steuerkreuz wählt, Kreuz fügt ein, Kreis
schließt, Dreieck heftet an, Viereck halten (0,6 s) löscht. Angebunden wird direkt an das vorhandene
`ClipboardKeyCommand`. Ist ein anderes Programm vorne, braucht das Tasten im Hintergrund.

### Menü (Options)

Eine Liste, bedient mit Stick oder Steuerkreuz, Kreuz wählt, Kreis oder Options schließt:

- „Weiter“ senden
- Befehlsliste öffnen („/“ ins Eingabefeld, nicht gesendet)
- Modus wechseln (Shift+Tab)
- `/compact` ins Eingabefeld (nicht gesendet)
- Tab schließen
- Belegung anzeigen
- Controller pausieren

Einträge, die Text senden, sind bei offener Rückfrage ausgegraut. Die Felder sind fest.

### Chat-Auswahl (L2)

L2 halten (ab 0,3 s) öffnet den vorhandenen Umschalter mit der Markierung auf dem aktuellen Chat.
Stick oder Steuerkreuz bewegt, Loslassen wechselt, Kreis bricht ab. R2 bei gehaltenem L2 wechselt zum
markierten Chat und startet die Aufnahme. L2 kurz tippen springt zum zuletzt aktiven Chat. Gibt es
weniger als zwei Ziele, kommt die Vibration „geht nicht“.

### Rückmeldung am Controller

- **Lichtleiste:** rot bei Aufnahme, grün wenn der Ziel-Chat arbeitet, bernsteinfarben bei offener
  Rückfrage, sonst gedimmtes Weiß. Farben aus derselben Zuordnung wie `AgentStatusIndicator`.
  In der Pause wird nichts geschrieben.
- **Vibration:** Aufnahme-Start ein kräftiger Impuls, Stopp ein weicher; ein anderer Chat wartet neu:
  Doppelimpuls (höchstens einer alle 5 s, keiner während der Aufnahme, keiner für den sichtbaren
  Ziel-Chat); „geht nicht“: drei kleine Ticks.
- Beides einzeln abschaltbar.

### Sonderfälle

| Fall | Verhalten |
|---|---|
| Controller trennt sich während der Aufnahme | Aufnahme läuft weiter (Umschalter); Stopp über Tastatur, Pill oder nach dem Neuverbinden. Nichts wird gesendet. |
| Controller trennt sich bei offener Auswahl oder offenem Menü | schließt ohne Wirkung; alle gehaltenen Tasten gelten als losgelassen |
| App verliert den Fokus bei offener Auswahl | schließt ohne Wechsel |
| Bildschirm gesperrt, Bildschirmschoner, Ruhezustand | Controller pausiert, bis entsperrt ist |
| Ein Spiel ist vorne | „Auch im Hintergrund“ ist ab Werk aus; ist es an, pausiert die Erkennung bei bekannten Spielen und Steam; sicherer Weg ist L1 + R1 |
| Tastatur wird während einer Controller-Auswahl benutzt | Auswahl bricht ab, die Taste läuft normal weiter |
| Dialog, Sheet, Popover oder Menü offen | Tastatur-Brücke: Steuerkreuz = Pfeile, Kreuz = Return, Kreis = Escape. Nichts geht an das Terminal dahinter. |
| Textfeld hat den Fokus (Filter, Suche, Sheet) | Brücke wie oben; Diktat geht in dieses Feld (Weg „vorderes Programm“) |
| Mehrfachauswahl in der Liste aktiv | jede Controller-Aktion hebt sie zuerst auf |
| Tastatur-Umschalter (Ctrl+Tab) offen | jede Controller-Eingabe bricht ihn ab |
| Aufnahme läuft schon (Tastatur) | R2 beendet sie; der vorhandene Schutz verhindert eine zweite Aufnahme |
| Schnellaktion läuft | Kreis bricht ab, R2 meldet „geht nicht“ |
| Viereck ohne erkannten Entwurf | keine Wirkung |
| Kein wartender Chat bei Dreieck | keine Wirkung, „geht nicht“ |
| Chat beendet oder nur Verlauf sichtbar | rechter Stick scrollt den Verlauf; Navigation bleibt möglich; Kreuz ohne Wirkung |
| Kein Chat offen | Liste und Create funktionieren; Legende zeigt nur diese |
| Zwei Controller | beide werden gelesen; beim Wechsel der Quelle werden gehaltene Tasten gelöst |
| Diktat ohne erkannten Text | nichts wird eingefügt, nichts gesendet |
| Create zweimal schnell | macOS macht einen Screenshot; in der Doku vermerkt |

## 3. Architektur

Neuer Ordner `WhisperM8/Services/Controller/`. Alles Entscheidende ist pur und ohne Hardware testbar.

```
GameController (Hardware)                 debug.controller (künstliche Eingaben)
        │  eigene serielle Queue                   │
        └──────────────┬───────────────────────────┘
                       ▼
            ControllerInputEvent             Taste runter/hoch, Trigger-Wert, Stick, eigene Zeit
                       ▼
          ControllerGestureRecognizer        pur, ohne App-Zustand: Tippen, Halten, Wiederholen
                       ▼  (nur diskrete Gesten gehen zum MainActor)
            ControllerGesture
                       ▼
          ControllerContextResolver          pur: Schnappschuss der App → Zusammenhang
          ControllerBindingResolver          pur: (Geste, Zusammenhang) → Aktion
                       ▼
          ControllerActionDispatcher         MainActor: führt aus
              │            │            │              │
          AppState    AgentChats    AgentTerminal   ClipboardKey
          (Diktat)   CommandCenter   Controller      Command
```

### 3.1 Kern

- `ControllerButton`: logische Tasten, unabhängig vom Hersteller.
- `ControllerInputEvent`: `.button(_, pressed:)`, `.trigger(_, value:)`, `.stick(side, x, y)`. Die Zeit
  wird beim Empfang selbst gemessen (`ProcessInfo.systemUptime`), nicht vom Framework übernommen.
- `ControllerGestureRecognizer`: Zustandsmaschine ohne Uhr und ohne App-Zustand. Verhalten je Taste fest:
  - `immediate`: löst beim Drücken aus (Kreuz, Dreieck, L3, Create, Options, Touchpad, R2). L1 und R1
    lösen nach dem Akkord-Fenster von 150 ms aus, oder beim Loslassen, wenn das früher kommt.
  - `tapOrHold`: Tippen beim Loslassen vor der Schwelle, sonst `holdBegan` / `holdEnded` (L2 mit 0,3 s,
    Kreis mit 0,4 s, Viereck mit 0,6 s für „halten löscht“ im Verlauf). Tippen oder Halten wird aus den Zeitstempeln entschieden, nicht daraus, ob der
    Zeitgeber gefeuert hat.
  - Akkord L1 + R1: beide innerhalb 150 ms gedrückt und 1 s gehalten; dann kein Tab-Wechsel.
  - Steuerkreuz und Stick-Richtungen mit Wiederholung nach `NSEvent.keyRepeatDelay` und
    `keyRepeatInterval` (dem Kern als Werte übergeben).
  - Trigger: Schwelle mit Hysterese (ein 0,5, aus 0,3). Stick: radiale Totzone 0,25, Richtung ein bei
    0,6, aus bei 0,4, Winkel-Hysterese an den Diagonalen.
  - `reset()` löst alles Gehaltene und meldet es als losgelassen.
- `ControllerContext`: `paused`, `outsideApp`, `recording(phase)`, `quickAction`, `clipboardPanel`,
  `menu`, `chatPicker`, `modal`, `list`, `chat(status, profil, entwurfVermutet, rasterAktiv)`,
  `otherWindow`, `noWindow`. Vorrang in dieser Reihenfolge; `recording` und `clipboardPanel` gehen vor
  `outsideApp`.
- `ControllerContextResolver`: bekommt einen Schnappschuss (`ControllerAppSnapshot`) und liefert den
  Zusammenhang. Der Schnappschuss wird beim Eintreffen einer Geste auf dem MainActor gezogen, nicht
  dauernd gespiegelt.
- `ControllerBindingResolver`: die gesamte Belegung als pure Funktion. Jede Kombination aus Taste und
  Zusammenhang hat einen festen Ausgang, auch „keine Wirkung“.
- `ControllerLegend`: liest dieselbe Tabelle und liefert die Einträge für Legende und Einstellungsseite.
- `ControllerAction`: fachliche Aktionen.

Ein Quelltext-Test stellt sicher, dass diese Dateien weder `AppKit` noch `GameController` importieren.

### 3.2 Aktions-Katalog für Agent Chats

`AgentChatsCommand` und `AgentChatsCommandCenter` (MainActor, Singleton).

- Jedes Agent-Chats-Fenster meldet beim Erscheinen einen Handler an und bekommt ein Token. Abgemeldet
  wird nur mit passendem Token (`onDisappear` und `onWillClose`), damit ein Neuaufbau der View den
  neuen Handler nicht entfernt.
- Der Handler hat zwei Funktionen: `perform(_ command:) -> Bool` und `snapshot() -> AgentChatsWindowSnapshot`
  (Raster aktiv, Umschalter offen, ausgewählter Chat, Sheet offen, Seitenleiste sichtbar, Mehrfachauswahl).
- Befehle gehen **nur an das Fenster, das gerade Key ist**. Der Handler prüft `hostWindow?.isKeyWindow`.
  `dictationWindowID` dient ausschließlich als Diktat-Ziel, nie für Navigation.
- Veränderlicher Zustand der Controller-Führung liegt in einem Klassen-Objekt (`ControllerFocusModel`,
  `@Observable`) je Fenster. In `AgentChatsView.swift` kommt dafür eine `@State`-Zeile dazu.
- Die Tastatur-Handler bleiben stehen. Drei Inline-Rümpfe (nächster wartender Chat, Umschalter-Start,
  Umschalter-Schritt) wandern in Funktionen, die Tastatur und Controller gemeinsam nutzen.
- Umschalter per Controller: `switcherBegin` setzt `tabSwitcherRun.lastModifiers = []` und markiert den
  Lauf als Controller-Lauf. Der `.flagsChanged`-Monitor committet dann nicht.

### 3.3 Tasten ins Terminal

`TerminalControlKey` (Enter, Escape, Pfeile, Tab, Shift+Tab) und
`AgentTerminalController.sendKey(_:)`.

- Pfeil-Bytes nach `getTerminal().applicationCursor`. Sind Kitty-Tastatur-Flags aktiv
  (`keyboardEnhancementFlags`), werden die passenden CSI-u-Sequenzen gesendet; rohes ESC und CR
  funktionieren heute schon in beiden Modi.
- Nebenwirkungen der Tastatur werden nachgebildet: Escape an einen arbeitenden Chat meldet
  `suspectTurnAborted`; der Draft-Tracker erfährt Enter, Escape und Text über einen kleinen Mutator in
  `AgentTerminalView.swift` (wegen `private(set)`); Enter stempelt `lastProgrammaticSubmitAt`.
- Scrollen mit dem rechten Stick: im normalen Puffer `scrollUp/scrollDown(lines:)`, im Alternate-Puffer
  Mausrad-Bytes wie der vorhandene Scroll-Code. Höchstens 30 Schritte pro Sekunde.
- Künstliche Eingaben aus dem Debug-Kanal dürfen nur in der Test-Instanz ins Terminal schreiben.

### 3.4 Diktat-Zustellung

- `DictationDeliveryTarget`: `.frontApp` oder `.agentChat(sessionID)`, dazu `submitAfterDelivery`.
  Das Ziel wird beim Start gemerkt, `submit` beim angenommenen Stopp eingefroren (neben
  `frozenOutputMode`). `PendingTranscriptionRetry` und `InFlightTranscription` tragen das Ziel mit.
- `DictationDeliveryRouter` (pur): Ziel, Zustand des Ziel-Chats, Text → Entscheidung
  (`pasteToFrontApp`, `writeToChat(submit:)`, `clipboardOnly(grund)`, `nothing`).
- `DictationDeliveryExecuting` (Protokoll, injizierbar): führt aus. Live-Fassung nutzt `PasteService`
  und die Terminal-Registry. Erst damit sind Tests der Zustellung möglich.
- Schreiben in den Chat: Bracketed Paste über den Weg von `sendPrompt`. `PromptDeliveryGate` gilt nur
  bei `submit`; ohne Senden gilt nur die Bereitschaftsprüfung (Chat startet noch). So kann ein zweites
  Diktat an den Entwurf anhängen.
- Neuer Schutz: leerer Text führt zu `nothing`.
- Der Chat-Kontext für die Nacharbeit wird aus der Ziel-Session gebaut.
- `cancelTranscription` bekommt einen Zugang über `AppState`.

### 3.5 Listen-Navigation

- `SidebarNavigationRow`: `.workspace(id)`, `.workspaceChat(sessionID, workspaceID)`, `.project(id)`,
  `.chat(sessionID)`.
- `SidebarNavigationModel` (pur): bekommt die sichtbaren Zeilen in Anzeige-Reihenfolge, bewegt die
  Markierung, hält sie stabil, wenn Zeilen verschwinden (nächster Nachbar), und liefert die Startzeile
  (Zeile des aktuellen Chats).
- Die Zeilen werden im Ereignis-Pfad aus denselben Hilfsfunktionen gebaut, die die Seitenleiste zum
  Zeichnen nutzt. Kein Scan in einem Body.
- Die Markierung ist ein kleines eigenes View-Stück, das `ControllerFocusModel` liest. Die Zeilen der
  Seitenleiste selbst beobachten es nicht (Muster wie die Grid-Markierung des Umschalters).
- Mitscrollen über den vorhandenen Scroll-Mechanismus der Seitenleiste.

### 3.6 Tastatur-Brücke

Für `modal` und `otherWindow`: Steuerkreuz, Kreuz, Kreis und L1/R1 werden zu Pfeilen, Return, Escape
und Shift+Tab/Tab. Die Ereignisse entstehen als `CGEvent` mit einer Markierung in
`eventSourceUserData`, werden zu `NSEvent` und gehen über `NSApp.postEvent` an die eigene App.

- Die eigenen Monitore („Tastatur bricht die Auswahl ab“) ignorieren markierte Ereignisse.
- `keyCode`, Zeichen und Flags passen zusammen (Pfeile mit `[.function, .numericPad]`, Shift+Tab als
  Backtab), immer `keyDown` und `keyUp`.
- Aus, wenn WhisperM8 nicht vorne ist. Der Zwischenablage-Verlauf nutzt die Brücke nicht.
- Verlässlich sind Bestätigen und Abbrechen. Mehr als zwei Knöpfe in einem Dialog erreicht die Brücke
  nur bei eingeschalteter Tastaturnavigation des Systems.

### 3.7 Hardware-Anbindung

- `ControllerManager` (MainActor) mit einer Quelle hinter einem Protokoll. Die Live-Quelle setzt je
  Controller zuerst `handlerQueue` (eigene serielle Queue), dann die Handler; nach einem Neuverbinden
  wird neu verdrahtet. Digitale Tasten über `pressedChangedHandler`, Trigger und Sticks über
  `valueChangedHandler`.
- Start nur im GUI-Pfad, nie in der CLI und nie unter `swift test`.
- `shouldMonitorBackgroundEvents` wird nur auf `true` gesetzt, wenn „Auch im Hintergrund“ an ist, und
  zwar nach dem ersten Verbinden. Der Wert wird zurückgelesen; `false` heißt „auf diesem System nicht
  verfügbar“.
- Zurücksetzen des Recognizers bei: Trennung, Wechsel der Quelle, Ruhezustand, Bildschirmsperre,
  Ausschalten der Funktion, Fokusverlust (wenn ohne Hintergrund-Empfang). Das Zurücksetzen läuft auf
  der Handler-Queue.
- Zeitgeber für Halten und Wiederholen: `DispatchSourceTimer` mit `.strict` auf der eigenen Queue, nur
  solange etwas gedrückt oder ausgelenkt ist. Solange gilt eine `ProcessInfo`-Aktivität gegen App Nap.
  Nie `DispatchQueue.global()`.
- `preferredSystemGestureState` wird nicht verändert. `GCKeyboard` und `GCMouse` werden nicht angefasst.
- Symbole der Tasten über `sfSymbolsName`, mit fester Ersatztabelle für Snapshots.
- Haptik: einfacher `CHHapticPatternPlayer`, eine Engine je Controller mit `stoppedHandler` und
  `resetHandler`, Neuaufbau bei Bedarf.

### 3.8 Schalter

| Schlüssel | Art | Standard |
|---|---|---|
| `controllerFeatureEnabled` | Notbremse | an |
| `controllerEnabled` | Nutzer-Schalter | aus |
| `controllerBackgroundEnabled` | Nutzer-Schalter „Auch wenn ein anderes Programm vorne ist“ | aus |
| `controllerHapticsEnabled` | Nutzer-Schalter | an |
| `controllerLightEnabled` | Nutzer-Schalter | an |
| `controllerLegendEnabled` | Nutzer-Schalter | an |

Seite „Controller“ in den Einstellungen, Gruppe Labs. Die Schalter haben ihren Weg dort von Anfang an
(Etappe 4), es gibt keine vorläufigen Ausnahmen in `PreferenceBedienweg`.

### 3.9 Leistung

- Im Ruhezustand läuft nichts: kein Zeitgeber, kein Abfragen.
- Zum MainActor gehen nur diskrete Gesten. Dort werden Zusammenhang und Aktion bestimmt.
- Die Legende ist eine eigene View mit eigenem kleinem Modell. Der große Body von `AgentChatsView`
  liest dieses Modell nicht. Sie belegt eine feste Zeile und erscheint, solange ein Controller
  verbunden und die Funktion an ist; die Terminalgröße ändert sich nur beim Verbinden und Trennen.
- Halte-Fortschritt als eine endliche Animation mit bekannter Dauer, kein Wert pro Frame.
- Keine Signposts pro Ereignis; Zähler über `PerformanceCounters`.
- „Chat wartet neu“ kommt aus einem eigenen Abo auf den Status-Store mit Drossel (wie die Notch), ohne
  neuen SwiftUI-Beobachter. Lichtleiste und Haptik werden nur bei Zustandswechsel angesteuert.

## 4. Etappen

Regeln für jede Etappe:

- Arbeitsordner `/Users/giulianocosta/repos/whisperm8/.claude/worktrees/controller-steuerung`,
  Branch `feat/controller-steuerung`. Der Hauptordner wird nicht angefasst.
- Abschluss: `swift build` ohne Fehler, die genannten Tests grün, volle Suite grün, ein lokaler Commit,
  Zeile in Abschnitt 7 aktualisiert. Kein Push, kein Merge.
- Nie `make dev`, `make run`, `make install`, `make kill`, `make clean-install`, nie `swift run` ohne
  Argument. Die Test-Instanz (`scripts/test-instance.sh`) ist erlaubt.
- Neue UI-Texte englisch, deutsche Übersetzung im Katalog. Kommentare deutsch, wie im Bestand.
- Neue Dateien, die Texte oder Schriftgrößen tragen, in die Listen von `LocalizationCatalogTests` und
  `ChatsFontSizeGuardTests` eintragen.
- Zeilenbudgets aus Abschnitt 1 beachten: neuer Code in eigenen Dateien.

### Etappe 0 – Vorbereitung

1. Arbeitsordner und Branch (erledigt).
2. Ausgangswert: Build sauber, 4.039 Tests grün (erledigt).
3. Plan committen, Eintrag in `docs/plans/README.md`.

Abnahme: Plan und README-Eintrag sind committet.

### Etappe 1 – Entwurf im HTML-Zwilling

1. `docs/design/controller-steuerung.html`: Legende (Chat, Rückfrage, Liste, Aufnahme, Pause),
   Markierung in der Liste, Menü (Options), Halte-Fortschritt, Einstellungsseite. Hell und dunkel, mit
   echten Maßen der App.
2. Im Browser ansehen (Screenshots), Lesbarkeit prüfen (Schrift mindestens 11 pt).

Abnahme: Die Datei zeigt alle fünf Zustände der Legende und die Seite; sie ist die Vorlage für den
Swift-Code der Etappen 6, 7, 9 und 12.

### Etappe 2 – Aktions-Katalog für Agent Chats

Ziel: Chat-Aktionen sind ohne Tastatur-Ereignis aufrufbar. Am Verhalten der Tastatur ändert sich nichts.

1. Bestandstests lesen (`TabNavigationTests`, `TabNavShortcutTests`, `TabSwitcher*Tests`,
   `NextWaitingChatResolverTests`, `GridFocusNavigatorTests`).
2. `AgentChatsCommand`: `previousTab`, `nextTab`, `nextWaitingChat`, `lastChat`,
   `gridFocus(GridFocusDirection)`, `toggleMaximize`, `closeSelectedTab`, `newChatInCurrentProject`,
   `selectSession(UUID)`, `activateWorkspace(UUID)`, `openProjectAsWorkspace(UUID)`,
   `setSidebarVisible(Bool)`, `sidebarFilter(±1)`, `switcherBegin`, `switcherMove(GridFocusDirection)`,
   `switcherCommit`, `switcherCancel`, `clearMultiSelection`.
3. `AgentChatsWindowSnapshot` und `AgentChatsCommandCenter` mit Token-Anmeldung, Routing nur zum
   Key-Fenster. Tests mit Spy-Handlern: Key-Fenster, kein Key-Fenster, zwei Fenster, veraltetes Token.
4. `AgentChatsView+Commands.swift`: `performCommand(_:)` und `commandSnapshot()`. Die drei
   Inline-Rümpfe aus `+Shortcuts.swift` in gemeinsame Funktionen ziehen.
5. `lastChat`: pure `ChatSelectionHistory` (letzte zwei Auswahlen, nur noch vorhandene und nicht
   archivierte Chats), gepflegt im vorhandenen `onChange(of: selectedSessionID)`. Tests.
6. `switcherBegin` mit Richtung 0 (Markierung bleibt auf dem aktuellen Chat), Controller-Lauf markieren,
   `lastModifiers` leeren. Test für `TabSwitcherModel.begin` mit Richtung 0.
7. Anmeldung in `onAppear`, Abmeldung in `onDisappear` und `onWillClose`.
8. `SourceSizeGuardTests` prüfen.
9. Handtest-Liste der Tastaturkürzel für nach `make dev` anlegen (⌘1–9, ⌘⌥←/→, ⌘⇧←/→, ⌃Tab mit allen
   Varianten, ⌃⌥Tab, ⌃⌘-Pfeile, ⌘N, ⌥⌘N, ⌘W), abgelegt in Abschnitt 6.

Tests: `AgentChatsCommandCenterTests`, `ChatSelectionHistoryTests`, Ergänzung `TabSwitcherModelTests`.
Abnahme: volle Suite grün; die Tastatur-Handler sind bis auf die drei herausgezogenen Rümpfe unverändert.

### Etappe 3 – Controller-Kern (pur)

1. `ControllerButton`, `ControllerInputEvent`, `ControllerGesture`.
2. `ControllerGestureRecognizer`. Tests: `immediate`; Tippen und Halten bei L2 und Kreis; Loslassen
   zwischen Tipp-Grenze und Halte-Zeit; Trigger-Hysterese mit Analogwerten (0,02 löst nicht aus);
   Wiederholung; Akkord L1 + R1 gegen einzelnes L1; Stick-Totzone, Richtung, Diagonale; Zeitgeber
   feuert 5 s zu spät und die Entscheidung bleibt richtig; `reset()`.
3. `ControllerAppSnapshot`, `ControllerContext`, `ControllerContextResolver`. Tests für den Vorrang.
4. `ControllerAction`, `ControllerBindingResolver`. Matrix-Test: jede Taste in jedem Zusammenhang.
   Regel-Tests für die Tabelle „Kreuz, Kreis und Viereck im Chat“, die 0,5-s-Sperre nach neuer
   Rückfrage, das verschluckte zweite Escape und „keine Wirkung während der Aufnahme“.
5. `ControllerLegend`. Test gegen den Resolver: jede angezeigte Taste löst die genannte Aktion aus;
   Tasten ohne Wirkung erscheinen nicht.
6. `OutputModeCycler`, `SidebarNavigationModel`, `ControllerMenuModel` (Einträge, ausgegraut bei
   Rückfrage). Tests.
7. Quelltext-Test: die Kern-Dateien importieren weder `AppKit` noch `GameController`.

Abnahme: alle neuen Tests grün.

### Etappe 4 – Hardware, Schalter, erste Einstellungsseite, Debug-Kanal

1. Präferenzen aus 3.8 in `PreferenceKeys` und `AppPreferences`; Notbremse in
   `PreferenceBedienweg.killSwitches`.
2. `SettingsPage.controller` (Titel, Symbol, Untertitel, `detailView`, `launchClass` Labs, Gruppe Labs,
   Deep-Link) und eine erste `ControllerSettingsPage` mit den Schaltern und dem Verbindungsstatus.
   Abhängigkeits-Struktur mit `.live`-Default.
3. `ControllerInputSource` (Protokoll), `GameControllerInputSource` (live), `ControllerManager`.
   Test der Anbindung über `GCController.withExtendedGamepad()` und `setValue` (löst die echten
   Handler auf der eigenen Queue aus), dazu ein Fake für Touchpad und Trennung.
4. Start in `WhisperM8App` hinter beiden Schaltern; reagiert auf Umschalten zur Laufzeit.
5. Debug-Kanal in `AgentControlRequestHandler+Debug.swift`: `debug.controller` mit `state`, `press`,
   `sequence` (höchstens 8 s). Standard ist ein Trockenlauf (Geste, Zusammenhang, Aktion, ohne
   Ausführung). `--execute` führt aus und ist nur in der Test-Instanz erlaubt. `--window <id>` und
   `--assume-frontmost` ersetzen im Schnappschuss nur die beiden AppKit-Felder. Eintrag ins Audit-Log.
   `state` liefert: verbunden, Kategorie, zurückgelesenes Hintergrund-Flag, `NSApp.isActive`, vorderste
   Bundle-ID, Zähler je Taste (runter/hoch, getrennt aktiv/inaktiv), Zeit des letzten Empfangs, letzte
   Geste und Aktion.
6. CLI `whisperm8 debug controller …` in `DebugCLICommand.swift`. Tests für Parser und Handler, dazu
   ein Test, dass jede Methode in `debugMethods` einen Handler hat.
7. Test-Instanz bauen und starten, Controller dort per Defaults einschalten, `state` prüfen,
   Trockenläufe mit künstlichen Eingaben.
8. **Hinweis-Lauf mit echter Hardware** (Ablauf in Abschnitt 6.1). Ergebnis in Abschnitt 7 notieren.
   Der Lauf blockiert nicht: Fällt er negativ oder gar nicht aus, geht es weiter; der gültige Beweis
   kommt nach `make dev`.

Abnahme: Trockenläufe liefern in der Test-Instanz die erwarteten Aktionen; Guard-Tests für
Einstellungen und Präferenzen grün.

**Hier wird der Nutzer gebraucht (optional):** einmal die Tastenfolge aus 6.1 drücken.

### Etappe 5 – Navigation im Inhalt

1. `TerminalControlKey`, `sendKey`, Mutator für den Draft-Tracker, Nachbildung der Nebenwirkungen.
   Tests für Bytes (normaler und Application-Cursor, Kitty-Flags) und Tracker-Aufrufe.
2. Scrollen mit dem rechten Stick (normaler und Alternate-Puffer).
3. `ControllerActionDispatcher` für: Tabs, Dreieck (inklusive Fenster nach vorn holen), Kachel-Fokus,
   L3, Kreuz, Kreis tippen und halten, Viereck, Create, `clearMultiSelection` vor jeder Aktion.
   Tests mit Spies.
4. Schnappschuss-Erzeugung auf dem MainActor: Status und Profil des Ziel-Chats, Rückfrage offen,
   Zeitpunkt der letzten Statusänderung (für die 0,5-s-Sperre), Entwurf vermutet, Sheet/Popover/Menü
   offen (`attachedSheet`, Menü-Tracking), Textfeld als Erstantwort.
5. In der Test-Instanz mit `--window` und `--execute`: Tab-Wechsel zwischen zwei Chats per künstlicher
   Eingabe, Kontrolle über `debug state`.

Abnahme: Tests grün; Tab-Wechsel in der Test-Instanz nachgewiesen.

### Etappe 6 – Listen-Navigation

1. Aufbau der Seitenleiste lesen (`AgentChatsView+Workspaces.swift`, Projekt- und Chat-Zeilen,
   Filter „Aktiv / Zuletzt / Alle“, Einklapp-Zustände, Scroll-Mechanik). Die Zeilenquelle als Funktion
   herausziehen, die Body und Navigation gemeinsam nutzen.
2. `ControllerFocusModel` (Bereich, markierte Zeile) je Fenster.
3. Befehle anbinden: Markierung bewegen, Kreuz je Zeilenart (`selectSession`, `activateWorkspace`,
   `openProjectAsWorkspace`), Stick rechts und Kreis, L1/R1 als Filter, Create im markierten Projekt,
   Seitenleiste einblenden.
4. Markierung zeichnen (eigenes View-Stück je Zeile, kein Hover nötig), Mitscrollen.
5. Übergang aus dem Raster: linker Rand führt in die Liste; Start auf der Zeile des aktuellen Chats.
6. Maus oder Tastatur blenden die Markierung aus.
7. Fixture in `UISnapshotGallery` (Liste mit Markierung, hell und dunkel), rendern und ansehen.

Tests: `SidebarNavigationModelTests` (Reihenfolge, verschwundene Zeile, eingeklappte Gruppen, leere
Liste), Dispatcher-Tests je Zeilenart.
Abnahme: Tests grün; Snapshot zeigt die Markierung.

### Etappe 7 – Legende

1. `ControllerUIModel` (Zusammenhang, Ziel-Titel, Status, Halte-Fortschritt als Start/Dauer, pausiert).
2. `ControllerLegendBar` nach dem Entwurf aus Etappe 1: links das Ziel („Titel · Zustand“), rechts die
   Tasten mit Symbolen. Eigene Host-View, feste Zeile am unteren Rand des Agent-Chats-Fensters.
3. Halte-Fortschritt als endliche Animation (Kreis halten, L1 + R1, Viereck im Verlauf).
4. Anzeige für „pausiert“ und „Controller getrennt“.
5. Fixtures für alle fünf Zustände, rendern und ansehen. Lokalisierung.

Abnahme: Snapshots stimmen mit dem Entwurf überein; `ChatsFontSizeGuardTests` und
`LocalizationCatalogTests` grün.

### Etappe 8 – Diktat

1. `DictationDeliveryTarget`, `DictationDeliveryRouter` (pur) mit Tests: vorderes Programm, Chat ruht,
   Chat arbeitet, Rückfrage offen, Chat beendet, Chat startet noch, leerer Text, mit und ohne Senden.
2. `DictationDeliveryExecuting` einführen und `transcribeAndDeliver` darauf umstellen. Der Weg
   `.frontApp` bleibt im Verhalten unverändert; vorher einen Test schreiben, der das heutige Verhalten
   über den neuen Ausführer festhält.
3. Ziel beim Start merken, `submit` beim angenommenen Stopp einfrieren, Ziel in Retry und
   In-Flight-Daten mitführen. Chat-Kontext aus der Ziel-Session.
4. Schreiben in den Chat ohne `PromptDeliveryGate` bei „ohne Senden“; mit Senden über das Gate.
5. R2 als Umschalter: `startRecording` wenn nichts läuft, `stopRecording` wenn die Aufnahme läuft.
   Im Besetzt-Zustand das vorhandene Signal.
6. Zusammenhang `recording(phase)`: Kreis je Phase (`cancelRecording`, `cancelTranscription` über den
   neuen `AppState`-Zugang, `cancelPostProcessing`), Steuerkreuz links/rechts über `OutputModeCycler`
   und `OverlayController.setOutputMode`, Kreuz = Stopp mit `submit`.
7. Pill: Name des Ausgabemodus und Ziel („→ Titel“) ohne Hover sichtbar, wenn die Aufnahme per
   Controller läuft.
8. Hintergrund: R2 außerhalb der App nur, wenn `controllerBackgroundEnabled` an ist.
9. Künstliche Diktat-Aktionen aus dem Debug-Kanal laufen mit `captureContext: false` und enden mit
   Verwerfen.
10. In der Test-Instanz: Trockenlauf zeigt `dictationStart`; die echte Aufnahme ist Handtest.

Abnahme: Router- und Coordinator-Tests grün; Bestandstests des Diktats unverändert grün.

### Etappe 9 – Zwischenablage-Verlauf, Brücke, Menü

1. Zusammenhang `clipboardPanel`: Bindung an `ClipboardKeyCommand` (hoch, runter, einfügen, anheften,
   löschen mit Halten, schließen), Touchpad-Klick über `ClipboardHistoryController.togglePanel`.
2. `ControllerKeyboardBridge` nach 3.6, Markierung in den Ereignissen, Monitore ignorieren sie.
   Test: Ein Brücken-Ereignis bricht den eigenen Umschalter nicht ab.
3. Dialoge der App einzeln prüfen (Schließen-Hinweis, Archiv-Rückfrage, Diktat-Fehler): Return und
   Escape müssen reichen. Wo nicht, den Standard- und Abbruch-Knopf sauber setzen.
4. `ControllerMenuOverlay` nach dem Entwurf: Liste mit Markierung, Einträge aus `ControllerMenuModel`,
   Ausführung über `sendPrompt`, `sendUserText`, `sendKey`, `closeSelectedTab`, Pause.
5. Fixtures für Menü (normal, bei Rückfrage), rendern und ansehen.

Abnahme: Tests grün; Snapshots stimmen.

### Etappe 10 – Chat-Auswahl mit L2

1. L2 `tapOrHold`: Tippen = `lastChat`; Halten = `switcherBegin`; Stick und Steuerkreuz =
   `switcherMove`; Loslassen = `switcherCommit`; Kreis = `switcherCancel` (Loslassen danach ohne Wirkung).
2. R2 bei gehaltenem L2: Commit, danach Aufnahme starten.
3. Weniger als zwei Ziele: „geht nicht“.
4. Abbruch bei Fokusverlust, Trennung und Tastatur (vorhandene Mechanik prüfen, Tests ergänzen).

Abnahme: Tests grün; in der Test-Instanz per künstlicher Folge nachgewiesen (halten, bewegen, loslassen).

### Etappe 11 – Rückmeldung und Schutz

1. `ControllerFeedback`: Lichtleiste nach Zustand (Zuordnung aus `AgentStatusIndicator`), Haptik-Muster,
   Engine-Lebenszyklus, Drossel, Alarmstufe der Glocke beachten.
2. Eigenes Abo für „Chat wartet neu“ mit Drossel und eigenem Tracker.
3. Pause: Akkord L1 + R1, Menü-Eintrag, automatisch bei Bildschirmsperre, Bildschirmschoner und
   Ruhezustand.
4. Spiel-Erkennung als Zusatz, nur relevant bei eingeschaltetem Hintergrund: Kategorie `*-games`,
   `LSSupportsGameMode`, Liste bekannter Bundle-IDs (Steam, CrossOver, Whisky, GeForce NOW, OpenEmu,
   RetroArch, Dolphin, PCSX2, RPCS3). Tests für die Erkennung.
5. Zurücksetzen bei Trennung, Quellenwechsel, Ruhezustand, Ausschalten. Tests.
6. App-Nap-Schutz und strikter Zeitgeber nach 3.7.

Abnahme: Tests grün. Licht und Haptik selbst sind Handtest.

### Etappe 12 – Einstellungsseite vollständig

1. Seite nach dem Entwurf: Ein/Aus, Verbindung (Name, Akku oder „nicht gemeldet“), Anleitung zum
   Koppeln, Tasten-Test (zeigt die zuletzt empfangene Taste), Belegung (Kern und Zusatz aus
   `ControllerLegend`), Schalter für Vibration, Lichtleiste, Legende und „Auch im Hintergrund“ mit
   Hinweis zum Spielen und der Anzeige „auf diesem System verfügbar / nicht verfügbar / noch nicht
   empfangen“.
2. Einmaliger Hinweis, wenn zum ersten Mal ein Controller erkannt wird und die Funktion aus ist.
3. Lokalisierung vollständig, Fixture, rendern und ansehen.

Abnahme: `PreferenceBedienwegGuardTests`, `LocalizationCatalogTests`, `SettingsNavigationTests`,
`SettingsRouteMappingTests`, `SettingsSourceGuardTests` grün.

### Etappe 13 – Doku, Gesamtprüfung, Übergabe

1. `docs/features/controller.md` (Bedienung, Belegung, Aufbau, Schalter, Grenzen), ein kurzer Verweis in
   `CLAUDE.md` (Zeichenbudget beachten) samt Notbremse in der Liste, Eintrag in `docs/plans/README.md`
   aktualisieren.
2. Jede Zeile der Sonderfall-Tabelle hat einen Test oder einen begründeten Vermerk in der Doku.
3. Volle Suite, alle Guards, `make snapshots` für die neuen Fixtures.
4. Unabhängige Durchsicht des gesamten Diffs (Korrektheit, Regressionen an Tastatur und Diktat,
   Leistungsregeln), Befunde einarbeiten, Suite erneut.
5. Handtest-Liste (Abschnitt 6) vervollständigen.
6. Meldung „bereit für `make dev`“ mit Branch, Commit und der Handtest-Liste.

Abnahme: alles grün, Abschnitt 7 vollständig, keine offenen Befunde aus der Durchsicht.

## 5. Risiken

| Risiko | Folge | Umgang |
|---|---|---|
| Keine Tasten im Hintergrund | Diktat und Verlauf nur bei aktiver App | Schalter ab Werk aus, Flag zurücklesen, Zustand auf der Seite anzeigen, Beweis nach `make dev` |
| R2 in einem Spiel startet ein Diktat | Mikrofon offen beim Spielen | Hintergrund ab Werk aus, Spiel-Erkennung, Pause |
| Enter bestätigt eine Freigabe versehentlich | ungewollte Erlaubnis | 0,5-s-Sperre nach neuer Rückfrage, kein Text in Rückfragen |
| Ctrl+C beendet Claude oder bricht eine Antwort ab | Sitzung oder Antwort weg | Viereck nur bei Claude-Profil, Ruhe und erkanntem Entwurf |
| Escape unterbricht den gerade gestarteten Turn | Antwort verloren | „gerade gesendet“ zählt als arbeitend; Halten nötig |
| Doppeltes Escape öffnet das Zurückspulen | Gespräch zurückgesetzt | zweites Escape innerhalb 1 s verschluckt |
| Diktat landet im falschen oder unsichtbaren Ziel | Text geht verloren oder wird blind gesendet | Ziel in der Pill, L2 + R2 wechselt sichtbar, Zustellung prüft neu |
| Umbau der Diktat-Zustellung | Regression beim Hotkey-Diktat | Verhalten vorher als Test festhalten, `.frontApp` unverändert |
| Umbau der Tastatur-Handler | Regression bei Kürzeln | Handler bleiben, nur drei Rümpfe herausgezogen, Handtest-Liste |
| Hängende Taste (Trennung, Ruhezustand, verpasstes Loslassen) | Auswahl bleibt offen | `reset()` an allen Übergängen, Entscheidung aus Zeitstempeln |
| App Nap verzögert den Zeitgeber | Halten wird zu spät erkannt | Aktivität halten, strikter Zeitgeber, Entscheidung beim Loslassen |
| Künstliche `NSEvent`s wirken nicht überall | Brücke unzuverlässig | nur Bestätigen und Abbrechen zusichern, Dialoge einzeln prüfen |
| Legende ändert die Terminalgröße | Umbruch beim Ein- und Ausblenden | feste Zeile, nur bei Verbinden und Trennen |
| Create löst die Systemgeste aus | Screenshot statt neuer Chat | nur Einzeldruck belegen, Geste nicht umstellen, in der Doku erklären |
| Lichtleiste oder Haptik wirken auf macOS 26 nicht | keine Rückmeldung am Gerät | Legende und Pill tragen alles Nötige; Handtest |
| Test-Instanz und echte App lesen beide | doppelte Aktionen | Test-Instanz nach den Läufen stoppen |
| Zeilen- und Zeichenbudgets | Guard-Tests rot | neue Dateien, `+Debug.swift`, kurzer CLAUDE.md-Verweis |

## 6. Prüfen mit echter Hardware

### 6.1 Hinweis-Lauf in der Test-Instanz (Etappe 4)

0. Steam und Spiele schließen. Test-Instanz gebaut und gestartet, Controller und Hintergrund in ihrer
   Defaults-Domain eingeschaltet. Finder oder TextEdit nach vorn.
1. `debug controller state`: verbunden, Kategorie DualSense, Hintergrund-Flag `true`, App nicht aktiv,
   alle Zähler 0.
2. Der Nutzer drückt: Kreuz 5×, Steuerkreuz hoch 3×, R2 2× voll und 1× nur leicht, Touchpad-Klick 1×,
   Create 1× kurz, PlayStation 1×, danach 10 s nichts.
3. Ablesen: Kreuz 5/5 und Steuerkreuz 3/3 im Zähler „inaktiv“, gleich viele runter wie hoch; R2 leicht
   darf nicht zählen; Touchpad, Create und PlayStation notieren.
4. Bei 0: Flag zurücklesen, Verbindung prüfen, Test-Instanz bei verbundenem Controller neu starten.
   Ein negativer Befund gilt nicht für die echte App.
5. Test-Instanz stoppen.

**Ergebnis (11.11.2026, macOS 26.6, DualSense über Bluetooth):** Die Test-Instanz (nie aktiv, Menüleisten-
Betrieb) erkannte den Controller als „DualSense Wireless Controller“, Akku nicht gemeldet, Hintergrund-
Flag hielt (`waiting`). Mit dem Browser vorne löste R2 eine echte Aufnahme aus und beendete sie beim
zweiten Druck — **Tasten kommen im Hintergrund an.** Die Transkription scheiterte in der Test-Instanz
mangels Zugang; der modale Fehlerdialog (`NSAlert.runModal`, bestehendes Verhalten) blockierte sie, sodass
die Zähler nicht mehr auslesbar waren und sie hart beendet werden musste. Offen bleibt deshalb der
Einzelnachweis für Touchpad, Create und den leichten R2-Druck mit echter Hardware (künstlich belegt:
0,2 löst nicht aus) — Handtest nach `make dev`.

Lehre für künftige Läufe: Echte Tastendrücke wirken in der Test-Instanz echt (nur künstliche Eingaben
sind Trockenläufe). Hinweis-Läufe mit Hardware also ohne R2 oder mit einem Zugang in der Test-Instanz.

### 6.2 Handtest nach `make dev`

Vorher: Einstellungen › Controller › Controller-Steuerung an. Für den Hintergrund zusätzlich „Auch wenn
ein anderes Programm vorne ist“.

**Tastaturkürzel (Regression aus Etappe 2).** Jedes Kürzel einmal im Einzelchat und einmal im Raster,
jeweils mit dem Fokus im Terminal:

| Kürzel | Erwartung |
|---|---|
| ⌘1 bis ⌘9 | springt auf den n-ten Tab |
| ⌘⌥← / ⌘⌥→ und ⌘⇧← / ⌘⇧→ | vorheriger / nächster Tab, mit Umlauf; im Filterfeld der Liste markiert ⌘⇧← Text |
| ⌃Tab, ⌃⇧Tab | Umschalter öffnet mit dem Nachbarn markiert; Ctrl loslassen wechselt |
| ⌃Tab, dann Pfeile | im Raster wandert die Markierung über die Kacheln, in der Einzelansicht eines Workspace über die Mini-Map, sonst durch die Liste |
| ⌃Tab, dann Esc | schließt ohne Wechsel, die laufende Antwort im Chat wird nicht abgebrochen |
| ⌃Tab, dann Return | wechselt sofort |
| ⌃Tab, dann Klick in die Seitenleiste | Umschalter schließt, der geklickte Chat bleibt gewählt |
| ⌃⌥Tab | springt zum Chat, der am längsten wartet; ohne wartenden Chat passiert nichts |
| ⌃⌘-Pfeile | Kachel-Fokus im Raster |
| ⌘N | Projekt-Auswahl für einen neuen Chat |
| ⌥⌘N | Notizen im Raster auf und zu |
| ⌘W | schließt den Tab; ohne Tab schließt das Fenster |

**Diktat per Hotkey (Regression):** in ein anderes Programm diktieren (Text wird eingefügt), in einen
Chat diktieren (wie bisher per Cmd+V), Abbrechen mit Esc, „Erneut versuchen“ nach einem Fehler.

**Controller im Einzelchat und im Raster:**

| Schritt | Erwartung |
|---|---|
| Controller verbinden | Einstellungsseite zeigt „Verbunden“, Legende erscheint unten, Lichtleiste gedimmt weiß |
| Tasten-Test auf der Einstellungsseite | jede Taste erscheint mit Namen |
| L1 / R1 | Tab zurück / vor |
| Linker Stick im Raster | Rahmen wandert von Kachel zu Kachel; am linken Rand in die Liste |
| Stick nach links in der Einzelansicht | Liste mit Markierung auf dem aktuellen Chat; ausgeblendete Seitenleiste erscheint |
| In der Liste hoch/runter, Kreuz | Chat öffnet; auf Workspace-Zeile: Raster; auf Projekt-Zeile: Projekt als Workspace |
| In der Liste L1/R1 | Filter Aktiv / Zuletzt / Alle |
| Maus- oder Tastendruck in der Liste | Markierung verschwindet |
| Dreieck | nächster wartender Chat; ohne wartenden: drei kurze Ticks |
| L2 tippen | zurück zum vorigen Chat |
| L2 halten, Stick, loslassen | Umschalter, wechselt beim Loslassen; Kreis bricht ab |
| L3 | Kachel groß / zurück zum Raster |
| Rechter Stick | Verlauf scrollt; in einer TUI im Vollbild (Alternate-Puffer) scrollt die TUI |
| Create | neuer Chat im Projekt |
| Options | Menü; „Weiter“ sendet; „Befehle …“ legt „/“ ins Feld; Kreis schließt |
| Touchpad | Zwischenablage-Verlauf; Stick wählt, Kreuz fügt ein, Viereck halten löscht |

**Rückfragen von Claude:** Einen Chat eine Freigabe stellen lassen.

| Schritt | Erwartung |
|---|---|
| Steuerkreuz hoch/runter, Kreuz | Option wird gewählt und bestätigt |
| Kreuz sofort nach Erscheinen der Rückfrage | wirkt erst nach einer halben Sekunde |
| Kreis | lehnt ab; ein zweites Kreis innerhalb 1 s tut nichts |
| Options | „Weiter“, „Befehle …“, „Modus wechseln“, „Zusammenfassen“ sind grau |
| R2, sprechen, R2 | Text kommt NICHT in den Chat, Mitteilung „Text nicht eingefügt“, Text liegt in der Zwischenablage |

**Diktat per Controller:**

| Schritt | Erwartung |
|---|---|
| R2, sprechen, R2 | Pill zeigt „→ Titel“ und den Modus; Text steht im Eingabefeld, nicht gesendet; Lichtleiste rot während der Aufnahme, Impuls bei Start und Stopp |
| R2, sprechen, Kreuz | Text wird gesendet |
| R2 sofort nach dem ersten R2 (AirPods verbinden noch) | Aufnahme beendet sich, sobald sie läuft |
| Steuerkreuz links/rechts während der Aufnahme | Modus wechselt in der Pill; die nächste Aufnahme startet wieder mit dem Standardmodus |
| Kreis während der Aufnahme | verworfen |
| L2 halten, Chat markieren, R2 | wechselt in den Chat und nimmt auf |
| R2 im Shell-Tab, dann Kreuz | Aufnahme endet, nichts wird ausgeführt |
| R2 in einem anderen Programm (Hintergrund an) | Text landet dort; Kreuz sendet dort nie |

**Gerät und System:**

- Tasten im Hintergrund in beiden Profilen (Dock und nur Menüleiste), auch nach dem Ruhezustand. Die
  Einstellungsseite zeigt „Funktioniert“, sobald eine Taste im Hintergrund ankam.
- Lichtleiste: grün wenn der Chat arbeitet, gelb bei Rückfrage, rot bei Aufnahme.
- Doppelimpuls, wenn ein anderer Chat zu warten beginnt.
- L1 + R1 eine Sekunde halten: „Controller pausiert“, Lichtleiste bleibt, wie sie war; noch einmal setzt fort.
- Bildschirm sperren und entsperren: währenddessen keine Wirkung.
- Trennen bei offenem Menü oder offener Auswahl: beides schließt.
- Akku: Anzeige oder „nicht gemeldet“.
- PlayStation-Taste und Create (einfach, doppelt): Verhalten von macOS notieren.
- Ein Spiel oder Steam vorne (Hintergrund an): Controller pausiert automatisch.
- Steuerung aus, Controller neu verbinden: einmalige Mitteilung „Controller verbunden“.

### 6.3 Nachweis in der Test-Instanz (11.11.2026)

Test-Instanz mit dem Stand nach Etappe 12, Controller und Hintergrund in ihrer Defaults-Domain an,
künstliche Eingaben über `whisperm8 debug controller … --window <id> --frontmost --execute`, Belege per
`debug snapshot`:

- R1 wechselt sichtbar den Tab („Review Login Flow“ → „Docs Update Guide“).
- Stick links aus der Einzelansicht führt in die Liste, die Markierung steht sichtbar auf der Zeile; Kreuz
  auf der Projektzeile öffnet das Projekt als Workspace mit beiden Chats im Raster.
- L2 halten, Stick rechts, loslassen wechselt im Raster auf die rechte Kachel; Stick links vom linken Rand
  führt in die Liste, Markierung auf dem aktuellen Chat.
- R2 mit Wert 0,2 löst nichts aus, voller Hub genau einmal.
- Trockenläufe lösen auf, ohne auszuführen; Dreieck außerhalb der App wird zu „WhisperM8 nach vorn“.

### 6.4 Sonderfälle und wo sie geprüft sind

| Fall (Abschnitt 2) | Prüfung |
|---|---|
| Trennung während der Aufnahme | Umschalter, nichts ist gehalten: `ControllerBindingResolverTests.testNothingElseWorksWhileRecording`, `ControllerGestureRecognizerTests.testResetReleasesEverything` (Zurücksetzen erzeugt nur `holdCancelled`) |
| Trennung bei offener Auswahl oder offenem Menü | `ControllerBindingResolverTests.testChatPicker` (`holdCancelled(.l2)` → `pickerCancel`); Menü und Liste schließt `ControllerRuntime` bei Trennung — Handtest |
| App verliert den Fokus bei offener Auswahl | vorhandener `didResignKey`-Abbruch des Umschalters (`AgentChatsView`), unverändert — Handtest |
| Bildschirmsperre, Bildschirmschoner, Ruhezustand | `ControllerFeedback` (Systemmeldungen) setzt `setSystemPaused`; `ControllerManagerTests.testSystemPauseAndUserPauseAreIndependent`, `testPausedIgnoresEverythingButTheChord` — Auslösen durch das System ist Handtest |
| Spiel vorne | `ControllerFeedbackPolicyTests.testGameDetection`; Hintergrund ab Werk aus (`ControllerManagerTests.testBackgroundStaysOffWithoutSwitch`) |
| Tastatur während einer Controller-Auswahl | Tasten ohne Ctrl brechen den Umschalter ab und laufen durch (`TabSwitcherShortcut.activeKeyAction`, Bestandstests); Modifier-Tasten brechen ab statt zu bestätigen (`switcherOpenedWithoutModifier`); Liste und Menü gibt `ControllerFeedback` bei Maus/Tastatur ab — Handtest |
| Dialog, Sheet, Popover, Menü | `ControllerActionDispatcherTests.testSheetOrPopoverMakesItModal`, `ControllerBindingResolverTests.testBridgeInModalAndOtherWindow` |
| Textfeld mit Fokus | `ControllerActionDispatcherTests.testDictationOutsideChatGoesToFrontApp` |
| Mehrfachauswahl aktiv | `ControllerActionDispatcherTests.testMultiSelectionIsClearedFirst` |
| Tastatur-Umschalter offen | `ControllerActionDispatcherTests.testKeyboardSwitcherIsCancelledByControllerInput`, `testRefreshLeavesKeyboardSwitcherAlone` |
| Aufnahme läuft schon (Tastatur) | `ControllerActionDispatcherTests.testSecondToggleStopsWithoutSending`; zweite Aufnahme verhindert der Start-Guard des Coordinators |
| Schnellaktion läuft | `ControllerBindingResolverTests.testQuickAction` |
| Viereck ohne erkannten Entwurf | `ControllerBindingResolverTests.testSquareClearsOnlyClaudeIdleDraft` |
| Kein wartender Chat bei Dreieck | entfallen in Runde 3 (Dreieck = Leerzeichen) |
| Chat beendet oder nur Verlauf | `ControllerBindingResolverTests.testEndedChatKeepsNavigationButNoTerminalKeys`, `ControllerActionDispatcherTests.testChatWithoutTerminalCountsAsEnded` |
| Kein Chat offen | `ControllerContextResolverTests.testContentWithoutChatFallsBackToList`, `ControllerBindingResolverTests.testList` |
| Zwei Controller | `GameControllerInputSource.deliver` löst beim Quellenwechsel alles Gehaltene — Handtest |
| Diktat ohne erkannten Text | `DictationDeliveryRouterTests` (leerer Text → `nothing`), `RecordingCoordinatorDeliveryTests` |
| Create zweimal schnell | Vermerk in `docs/features/controller.md` (Systemgeste von macOS) |

### 6.5 Runde 2 nach dem Handtest (11.11.2026)

Nach dem ersten Lauf mit echter Hardware entschieden und umgesetzt:

1. **Kreuz auf einem gestoppten Chat startet ihn** — derselbe Weg wie „▶ Starten“ im Kopf
   (`AgentChatsCommand.startChat`, `sessionActionRequest`). Archivierte Chats nicht; sonst „geht nicht“.
   Legende „Start“. **R3** macht dasselbe (auch auf der markierten Zeile der Liste); auf einem lebenden
   Chat tut R3 nichts, nicht einmal eine Vibration.
2. **Kreuz in der Chat-Auswahl (L2 gehalten) wechselt sofort**; das spätere Loslassen von L2 fällt in
   den Chat und tut dort nichts.
3. **Rechter Stick scrollt auch während Aufnahme, Transkription und Nacharbeit.**
4. ~~**Einzelansicht: Stick hoch/runter = voriger/nächster Chat der Liste** (mit Wiederholung, kein
   Umlauf).~~ Ersetzt in Runde 3 (6.6, Punkt 1): Der Stick bewegt die Markierung in der Liste,
   gewechselt wird erst mit Kreuz.
5. **Viereck = Rücktaste** (0x7F, Tastencode 51 für den Entwurfs-Tracker) in jedem lebenden Zustand;
   halten löscht weiter wie eine gehaltene Taste (`ControllerGesture.holdRepeat`, nach 0,6 s alle
   60 ms, nach 1 s alle 25 ms). Kein Ctrl+C mehr: Im Handtest wollte der Nutzer Text löschen, während
   Claude arbeitete — Ctrl+C hätte die Antwort abgebrochen und war deshalb gesperrt.
6. **Create öffnet die Projekt-Auswahl „Neuer Chat“** (wie ⌘N, Seitenleiste wird vorher eingeblendet),
   aktuelles bzw. markiertes Projekt vorausgewählt. Solange sie offen ist, gilt `modal` (Feld
   `isNewChatPickerOpen` im Schnappschuss; das Fenster bleibt Ziel, auch wenn das Popover Key wird):
   Pfeile, Kreuz = Return, Kreis = Escape, R2 diktiert ins Suchfeld, der linke Stick hoch/runter gibt
   ebenfalls Pfeile.
7. **Listen-Startpunkt:** Steht der Chat auch in einem Workspace, beginnt die Markierung dort.
8. Dieselbe Bevorzugung gilt als Reihenfolge für 4 und 14: Jeder Chat zählt einmal, an seiner ersten
   Stelle (`SidebarChatOrder`).
9. **Ausgabemodus während der Aufnahme:** Steuerkreuz hoch/runter wechselt ebenfalls (mit
   Wiederholung). Jeder Wechsel zeigt über der Pill die Liste aller Modi, der aktuelle markiert; weg
   1,5 s nach dem letzten Wechsel und mit dem Ende der Aufnahme. Ein eigenes kleines Panel statt einer
   größeren Pill: Am festen Pill-Panel hängen Trefferfläche, Position und Speicherung des Ankers.
10. **Schließen per Controller wie in der Seitenleiste:** Viereck halten in der Liste = „−“/„×“ der
    Zeile (`performSidebarCloseAction` bzw. bei Workspace-Zeilen `requestEndSession(…, removingFrom:)`),
    Kopfzeilen „geht nicht“. Die Rückfragen „Chat beenden?“/„Chat archivieren?“ zählen als `modal`
    (`isConfirmationOpen`); Return bestätigt dort jetzt (`.keyboardShortcut(.defaultAction)`), auch mit
    der Tastatur.
11. **Zwischenablage-Verlauf vollständig per Controller** (Dreieck korrigieren und einfügen, L1/R1
    Filter, L3 Bild groß, Options-Menü im Verlauf, Kreuz bestätigt „Verlauf leeren?“), Fußzeile mit
    Controller-Tasten aus der Legende, wenn ein Controller verbunden ist. R2 diktiert dort nicht.
12. **Ein Menü auf Options** mit drei Gruppen: Eingaben in den Chat („Weiter“, „Befehle ›“, Modus
    wechseln), Aktionen am Chat aus seinem Kontextmenü („Konto wechseln ›“, Umbenennen, Forken,
    Anheften, Archivieren, Chat schließen), Belegung und Pause. Zwei Ebenen, Kreis geht zurück. Ein
    eigenes R3-Menü war kurz gebaut und ist in dieses Menü aufgegangen.
13. (Kreuz in der Liste bleibt in der Liste — zurückgenommen. Kreuz öffnet und geht hinein wie in
    Runde 1.)
14. **L1/R1 = voriger/nächster Chat in der Reihenfolge der Liste**, auch im Raster, ohne Umlauf. Die
    Tastatur bleibt bei den Tabs.
15. **„Befehle ›“** als zweite Ebene mit den festen Befehlen der CLI (`ControllerSlashCommands`).
    „/ eintippen“ bleibt ungesendet, alle anderen werden gesendet; nie an einen Entwurf, nie bei
    offener Rückfrage. Codex: Im Repo ist keine Befehlsliste belegt, eingetragen sind `/model`,
    `/approvals`, `/new`, `/compact`.

Handtest nach dem nächsten `make dev`: siehe Bericht der Runde (Brücke im Popover, Return in den
Rückfragen, Umbenennen-Sheet mit Diktat, Modusliste an der Pill, Fußzeile und Menü im Verlauf,
Start über R3 auf einer nicht ausgewählten Zeile).

### 6.6 Runde 3 (11.11.2026)

Nach dem zweiten Handtest vom Nutzer einzeln bestätigt:

1. **Einzelansicht: Stick hoch/runter markiert in der Liste** statt den Chat zu wechseln (ersetzt
   6.5 Punkt 4). Die Markierung springt in die Liste (Bereich `list`, wie mit Stick links), Start ist
   der aktuelle Chat (bei Workspace-Mitgliedschaft dessen Workspace-Zeile), und sie rückt sofort einen
   Schritt in die gedrückte Richtung (`ControllerAction.enterList(step:)`). Der offene Chat bleibt.
   Hält man den Stick, kommen die Wiederholungen schon im Zusammenhang `list` an (`listMove`); im Chat
   selbst sind Wiederholungen ohne Wirkung. Am Rand bleibt die Markierung stehen. Steht der Chat nicht
   in der Liste (Filter), bleibt sie auf der ersten Zeile.
2. **Kreuz auf der Markierung** öffnet und geht in den Inhalt (unverändert).
3. **Kreis oder Stick rechts in der Liste**: Markierung weg, zurück in den bisherigen Chat — `leaveList`
   wählt nichts aus (Test über die ganze Kette Stick → Wiederholung → Kreis).
4. **Raster unverändert**: Kachel zu Kachel, in die Liste über den linken Rand.
5. **Linker Stick ruht während Aufnahme, Transkription, Nacharbeit und Schnellaktion.** Das galt im
   Resolver schon (der Zusammenhang `recording` kennt nur das Steuerkreuz); jetzt steht es dort
   ausdrücklich und ist für alle Phasen getestet. Bewusst ohne „geht nicht“-Vibration: Ein Stoß beim
   Greifen nach R2 oder Kreis ist kein Wunsch, und eine Vibration mitten im Sprechen irritiert.
6. **L1/R1** wechseln weiter direkt zum vorigen/nächsten Chat der Liste (`adjacentChat`).
7. **Kreuz auf einem Chat unter einem nicht sichtbaren Workspace** wechselt das Fenster in diesen
   Workspace (Raster sichtbar) mit genau diesem Chat als Kachel-Fokus
   (`AgentChatsCommand.selectWorkspaceChat` → `openWorkspaceChat` →
   `AgentWindowStore.navigateToWorkspaceChat`). Ist der Workspace sichtbar, wie bisher Kachel-Fokus.
   Danach führt L3 aus der maximierten Einzelansicht zurück in genau diesen Workspace. Konflikte wie
   beim Workspace-Kopf (`alreadyActive` → Besitzerfenster nach vorn, `blockedByWindowOwnership` →
   Hinweis); lebt der Chat als Tab in einem anderen Fenster, wird er dort geöffnet.
8. ~~**Derselbe Weg für den Mausklick** auf eine Chat-Zeile im WORKSPACES-Abschnitt.~~ Zurückgenommen
   nach dem Review (6.7, Punkt 3): Der Mausklick folgt wieder der Klickregel, nur Kreuz wechselt. Cmd-/Shift-Klick
   bleibt Mehrfachauswahl (`handleSidebarRowClick` unverändert, nur der normale Klick ruft
   `openWorkspaceChat`). Klickregel in `docs/features/agent-chats/ui/README.md` (Abschnitt Sidebar).
   Folge, die der Nutzer kennen sollte: Auch eine Zeile des Workspace, der nur das verborgene
   Rücksprungziel einer Einzelansicht ist, zeigt das Raster wieder.

**Zusatz: Workspace-Auswahl auf L2 im Raster** (vom Nutzer bestätigt, alle sechs Punkte):

1. Im Raster öffnet L2 halten statt der Chat-Auswahl eine Workspace-Auswahl (Zusammenhang
   `workspacePicker`, Aktionen `workspacePicker…`). Stick und Steuerkreuz bewegen, Loslassen oder Kreuz
   wechselt, Kreis bricht ab, R2 tut nichts. Kein Pause-Akkord, solange L2 gehalten ist.
2. Nur angelegte Workspaces (`sourceProjectID == nil`) in der Reihenfolge der Seitenleiste
   (`ControllerWorkspaceChoice.choices`).
3. Je Zeile Name, belegte Slots und der Punkt „wartet“ aus dem Status `awaitingInput` des
   `AgentSessionRuntimeStatusStore` — dieselbe Quelle wie die Status-Punkte und ⌃⌥Tab. Die Einträge
   entstehen beim Öffnen im Ereignis-Pfad, nie in einem Body; das Panel (`ControllerWorkspacePickerPanel`)
   hängt im vorhandenen `ControllerMenuHost`, der als einziger das `ControllerUIModel` beobachtet. Der
   aktuelle Workspace trägt „current“ und ist der Startpunkt.
4. Nach dem Wechsel die zuletzt benutzte Kachel des Ziels: `gridFocusSessionID` gilt pro Fenster und
   hätte beim Wechsel A → B → A die Kachel von A nicht gekannt. `activateGridWorkspace` merkt sich deshalb
   beim Verlassen die Kachel je Workspace (flüchtig, `@ObservationIgnored`, damit ein Fokuswechsel weder
   die Seitenleiste neu zeichnet noch die Workspace-Datei schreibt) und gibt sie `repairGridFocus` als
   zweite Wahl nach dem ausgewählten Chat mit. Gilt für jeden Workspace-Wechsel, auch per Maus. Konflikte
   über `activateWorkspaceFromSidebar` wie beim Kopf der Seitenleiste.
5. Einzelansicht: L2 bleibt die Chat-Auswahl.
6. Tastatur unverändert (Ctrl+Tab zeigt im Raster die Chats).

**Zusatz: Schreibtasten im Chat** (vom Nutzer bestätigt, alle fünf Punkte):

1. **Dreieck = Leerzeichen** (0x20, `TerminalControlKey.space`, Tastencode 49) in jedem lebenden Chat,
   auch in Rückfragen (wie die Rücktaste); Halten wiederholt nicht. Der Entwurfs-Tracker wertet es als
   Text, und es zählt als Eingabe per Controller (Kreuz bei arbeitendem Chat, Befund 3). Hinweis: In
   einer Rückfrage mit Mehrfachauswahl schaltet Leerzeichen in Claude Code die markierte Option um.
2. **„Nächster wartender Chat“ entfällt** am Controller samt Aktion, Legende, Einstellungsseite und
   `AgentChatsCommand.nextWaitingChat` (die Tastatur ⌃⌥Tab ruft `selectNextWaitingChat` direkt). Aus
   anderen Fenstern holt Dreieck Agent Chats weiter nach vorn (jetzt direkt `bringAppToFront`).
3. Im Zwischenablage-Verlauf bleibt Dreieck „Korrigieren und einfügen“.
4. **Viereck halten wie beim iPhone:** ab 0,6 s Zeichen alle 60 ms, nach einer weiteren Sekunde
   `ControllerGesture.holdRepeatLong` alle 150 ms = Wort löschen mit Ctrl+W (0x17). Belegt in Claude
   Code (interactive mode: „Delete back to previous whitespace“ — löscht also bis zum Leerzeichen, ein
   Pfad fällt auf einmal) und Codex (Standard-Belegung von `delete_backward_word` in
   `codex-rs/tui/src/keymap.rs`, dort auch Alt+Backspace). Option+Rücktaste (ESC DEL) bewusst nicht:
   ESC-Präfix, und bei Claude braucht es „Option als Meta“. Kein Fallback nötig; in Shell-Chats ist
   Ctrl+W `backward-kill-word`. Die alte Beschleunigung auf 25 ms entfällt.
5. **R3 halten (0,6 s) leert die ganze Eingabe** mit kurzer Vibration (`inputCleared`). R3 ist dafür
   Tippen-oder-Halten geworden; Tippen startet weiter einen gestoppten Chat. Sequenz: Ctrl+E (ans
   Zeilenende, beide CLIs) und 128 × Ctrl+U in acht Stößen alle 15 ms über den Main-Run-Loop (nichts
   blockiert). Ctrl+U ist in Claude Code „Delete from cursor to line start … Repeat to clear across
   lines in multiline input“, in Codex `kill_line_start`, das am Zeilenanfang den Umbruch davor
   entfernt — zwei Drücke je Zeile, also 64 Zeilen. Ctrl+S (Stash) wäre ein Schritt, holt aber bei
   leerem Feld den alten Stash zurück; Doppel-ESC und Ctrl+C sind ausgeschlossen. Nicht bei
   `awaitingInput` (die Auswahl einer Rückfrage bleibt), nicht bei gestopptem Chat. Weil R3 beim
   Scrollen leicht mitgedrückt wird, verfällt ein R3-Druck, sobald der rechte Stick scrollt (kein
   Leeren, auch kein Tippen). Grenze: Steht der Cursor (per Tastatur bewegt) weiter oben in einem
   mehrzeiligen Entwurf, bleibt der Text darunter stehen.

**Befunde aus einem unabhängigen Review von 0bb54fb5** (umgesetzt):

1. **Steuerkreuz schickte Pfeile in jeden lebenden Chat** (kritisch, im Alltag passiert: links im
   leeren Eingabefeld schickt Claude in den Hintergrund; hoch holt den letzten Prompt zurück, Kreuz
   schickt ihn erneut; in einer Shell liefe der letzte Befehl nochmal). Jetzt Pfeile nur bei
   `awaitingInput` (`ControllerBindingResolver.arrowsAllowed`), sonst wirkt das Steuerkreuz wie der
   linke Stick (`navigate`): hoch/runter markieren in der Liste, links in die Liste, rechts nichts, im
   Raster Kachel zu Kachel. Nicht am Entwurfs-Verdacht festgemacht (die Rücktaste setzt ihn nie
   zurück). Während der Aufnahme bleibt es der Ausgabemodus (eigener Zusammenhang `recording`).
   Absicherung im Controller-Weg `AgentTerminalController.sendKey` über
   `TerminalControlKey.controllerAllows` (die Tastatur läuft dort nicht durch). Legende: „Pfeiltasten“
   nur bei Rückfragen, sonst steht das Steuerkreuz beim Bewegen neben dem Stick. Mitgeändert: Stick
   rechts in der Einzelansicht liefert jetzt ausdrücklich keine Aktion (vorher eine wirkungslose).
2. **Menü-Eingaben an den falschen Chat**: „Weiter“, „Modus wechseln“ und Befehle nehmen jetzt
   `setup.sessionID` wie Konten und Umbenennen; weicht die Auswahl inzwischen ab, „geht nicht“ und das
   Menü ist zu.
3. **Kreuz bestätigte Freigaben zu früh**: Bei `working`/`unknown` Enter nur, wenn in den letzten 30 s
   per Controller getippt, gelöscht oder diktiert wurde (`lastControllerDraftInputAt` am
   Terminal-Controller, gesetzt von Rücktaste, Text ohne Senden und Diktat ohne Senden, gelöscht beim
   Senden). 30 s reichen, einen diktierten Entwurf zu überfliegen; ältere Eingaben halten Kreuz nicht
   scharf. Restrisiko: Erscheint der Dialog innerhalb dieser 30 s, gilt die Lücke weiter. Tippen auf der
   Tastatur zählt bewusst nicht.
5. **Ausschalten ließ Handler stehen**: `unwire` nimmt jetzt alle Handler ab, die `wire` setzt (eine
   gemeinsame Tastenliste, dazu Trigger, Steuerkreuz, Sticks), auch an Controllern, die
   `controllers()` nicht mehr nennt.

**Später** (aus demselben Review, bewusst nicht umgesetzt):

- 4: Die Tastatur-Brücke postet ihre Ereignisse an den First Responder — ist das ein Terminal,
  landen sie dort (`ControllerLiveAdapters`, `postBridgeKey`).
- 6: `ControllerConnectHint` ruft `GCController.controllers()` auch bei ausgeschaltetem Schalter.
- 7: Zwei Schnappschüsse je Geste (Manager und Ausführer).
- 8: Stick-Drift hält die Sperre gegen App Nap (die Pumpe gilt als „gedrückt“).

### 6.7 Review-Fixes nach Runde 3 (12.11.2026)

Befunde eines Reviews von 0bb54fb5..ef7a5a98, umgesetzt:

1. **Steuerkreuz in Auswahllisten und bei Codex.** Die Regel „Pfeile nur in Rückfragen“ machte die
   Listen unbedienbar, die das Menü selbst öffnet (`/model`, `/config`, `/resume`, `/permissions`,
   `/mcp`, `/agents`, „/“) — der Chat ruht dabei —, und Codex meldet nie „wartet“.
   - (a) **Merker „Auswahl offen“** je Chat (`ControllerTerminalMarks`, gehalten vom
     `AgentTerminalController`, damit Ausführer und Absicherung im Terminal dieselbe Quelle haben).
     Gesetzt vom Menü nach Befehlen, die eine Liste zeigen (`ControllerSlashCommands.opensChoiceList`:
     Claude zusätzlich `/memory`, Codex „/“, `/model`, `/approvals`). Solange er steht: Pfeile ins
     Terminal, Kreuz = Enter auch bei „arbeitet“, Kreis = Escape auch direkt nach dem Befehl (der zählt
     als „gerade gesendet“). Er fällt mit Enter und Escape (Controller und Tastatur), Rücktaste, Wort
     löschen, Leeren, Tab/Shift+Tab, jedem Text über `sendPrompt` (`chats send`, Diktat, Menü) und nach
     2 min ohne Pfeil oder Leerzeichen. Entscheidungen: Ein Chatwechsel weg und zurück lässt ihn stehen
     (die Liste im Terminal bleibt offen; der Merker hängt am Terminal, nicht an der Auswahl). Enter
     löscht ihn immer, auch wenn die CLI danach eine weitere Liste zeigt — sicher vor Gefälligkeit:
     Steht der Merker fälschlich, schickte links Claude im leeren Feld in den Hintergrund. Eine
     verfallene Liste öffnet kein Pfeil wieder (auch nicht in einer Rückfrage).
   - (b) **Codex: Pfeile immer** (jeder lebende Zustand). Belegt: Der Status von Codex kommt aus dem
     Transkript (`AgentTranscriptStatusDecider`); während einer Freigabe ist der letzte Eintrag der
     Tool-Aufruf, also „arbeitet“, nach 2 min ohne Schreiben „ruht“. Eine Freigabe-Erkennung fehlt —
     „Pfeile nur, solange Codex nicht arbeitet“ hätte genau die Freigaben ausgeschlossen. Links im
     leeren Feld ist bei Codex harmlos (das Hintergrund-Verhalten ist Claude-eigen); hoch holt den
     letzten Prompt sichtbar ins Feld. Damit eine Freigabe bei „arbeitet“ auch bestätigt werden kann,
     zählt ein Pfeil per Controller bei Codex als Eingabe für die 30-s-Regel: erst wählen, dann Kreuz;
     ohne Pfeil bleibt Kreuz ohne Wirkung (Schutz vor dem Reflex-Druck).
   - Claude bleibt unverändert sicher: außerhalb von „wartet“ und „Auswahl offen“ ist das Steuerkreuz
     Navigation. Die Absicherung `TerminalControlKey.controllerAllows` kennt jetzt Profil und Merker.
2. **Mehrere Fenster:** `openWorkspaceChat` fällt bei `.alreadyActive`, `.blockedByWindowOwnership`
   und `.rejected` auf die Klickregel zurück (`selectedSessionID = id`) statt nur das Besitzerfenster
   nach vorn zu holen bzw. einen Hinweis zu zeigen. Regel pur in `WorkspaceChatRowRoute.fallsBackToSelect`.
3. **Mausklick wieder wie vor Runde 3** (Entscheidung des Nutzers): Klick auf eine Chat-Zeile im
   WORKSPACES-Abschnitt = `handleSidebarRowClick` + `selectedSessionID = id`. Nur Kreuz am Controller
   wechselt den Workspace (`WorkspaceChatRowRoute.route(for:)`). L3 zurück und die Workspace-Auswahl auf
   L2 bleiben. Klickregel in `docs/features/agent-chats/ui/README.md` zurückgeschrieben.
4. **Schreibtasten nur bei Claude und Codex:** Leerzeichen, Wort löschen und Eingabe leeren in Shells
   „geht nicht“ (Resolver) und gesperrt in der Absicherung (nano: Ctrl+U fügt ein, Ctrl+W sucht; vim und
   emacs anders). Entscheidung zur Rücktaste: bleibt in Shells, getippt und gehalten — 0x7F ist die
   echte Rücktaste, in jedem Programm das Erwartete. Nach 1 s Halten kommt dort aber kein Ctrl+W,
   sondern weiter Zeichen.
5. **Kreuz bei arbeitendem Chat:** `recentDraftInput` nur, wenn die Eingabe nach dem letzten Absenden
   liegt (`ControllerTerminalMarks.hasFreshDraftInput`). „Absenden“ ist jeder Weg: Kreuz/Enter vom
   Controller auch in Rückfragen, Enter der Tastatur (`noteKeyboardKeyForController`), `chats send`,
   Diktat mit Senden und Menü-Befehle (über `composerDraft.lastProgrammaticSubmitAt`). Nebenwirkung:
   Auch nach einem Enter der Tastatur gilt der Chat 3 s als „gerade gesendet“.
6. **Eingabe leeren** bindet sein Ziel beim Haltebeginn (`holdProgress(.r3)`); ist beim Auslösen ein
   anderer Chat ausgewählt, wird nichts geleert („geht nicht“), wie bei den Menü-Eingaben.

Nebenbei: `sendKey` steht jetzt kürzer in `AgentTerminalView.swift` (Merker und Tastenregeln in
`AgentTerminalController+ControllerInput.swift` und `ControllerTerminalMarks+Keys.swift`).

**Später** (aus demselben Review, bewusst nicht umgesetzt):

- 7: Leerzeichen in `/config` (schaltet um) und in Rückfragen mit Mehrfachauswahl am echten Gerät
  prüfen.
- 8: `wiredControllers` beim Trennen eines Controllers bereinigen.
- 9: `AgentTerminalView.swift` steht bei 1.459 von 1.500 Zeilen; Neues dort nur über Extensions.

**Nachreview der Fixes** (umgesetzt):

1. **Merker nur bei ruhendem Claude-Chat.** Ein `/model` an einen arbeitenden Chat setzte den Merker;
   danach gingen 2 min lang links und Kreuz ins arbeitende Terminal, und Kreuz konnte in der Lücke vor
   „wartet“ eine Freigabe bestätigen (ebenso bei einem Turn, den Claude selbst beginnt). Jetzt zählt
   der Merker bei Claude nur bei `idle` — in der Belegung (`choiceListActive`) und in
   `controllerAllows`. Gesetzt wird er nur, wenn der Chat beim Senden ruht. Weg vom Ruhezustand wird
   er beim Lesen gelöscht (`checkedChoiceListOpen`, gelesen nur im Ereignis-Pfad: Schnappschuss des
   Controllers und `sendKey`, nie in einem Body) und lebt danach nicht wieder auf. Codex unverändert.
2. **Tastatur und Höchstdauer.** Jede Taste der Tastatur außer Pfeilen und Leerzeichen löscht den
   Merker (vorher nur Enter und Escape: „/“ aus dem Menü, mit der Rücktaste gelöscht, ließ ihn stehen,
   links schickte Claude dann in den Hintergrund). Pfeile verlängern nicht mehr; es gelten feste
   2 min ab dem Setzen.

**Später** (aus dem Nachreview):

- 4: Codex: ↑ zählt als frische Eingabe und macht Kreuz scharf; ↑ + Kreuz schickt dann den letzten
  Prompt erneut. Abhilfe: ↑ nicht als Eingabe zählen oder Kreuz bei arbeitendem Codex nur per Halten.
- 5: Enter löscht den Merker auch bei verschachtelten Listen wie `/config` (Untermenüs dann wieder über
  das Menü öffnen).

### 6.8 Vorschlag übernehmen per Steuerkreuz rechts (12.11.2026)

Nach den Review-Fixes bewegte das Steuerkreuz außerhalb von Rückfragen nur noch; den grauen
Vorschlag von Claude (nächster Prompt) ließ sich so nicht mehr übernehmen. Vom User mit „alles ja“
entschieden:

1. Steuerkreuz rechts schickt in jedem lebenden Claude-Chat den Pfeil rechts, auch im Raster.
   Claude Code übernimmt damit den Vorschlag ins Eingabefeld (Doku: Tab oder Pfeil rechts). Mit Text
   im Feld rückt nur der Cursor. Hoch, runter und links bleiben Navigation; im Raster wechselt nach
   rechts nur noch der Stick die Kachel.
2. Danach schickt Kreuz den Vorschlag ab, wie bisher.
3. Die Legende zeigt bei Claude-Chats „▶ Vorschlag übernehmen“ — immer, weil die App nicht sicher
   erkennt, ob gerade ein Vorschlag da ist (das hieße, graue Schrift im Terminalbild zu suchen).
4. Kein Tab: Tab öffnet in Freigabe-Dialogen ein Kommentarfeld und nach „/“ die Befehlsliste.

Codex bekommt die Pfeile ohnehin, Shells bleiben rechts ohne Wirkung. Die Absicherung im Terminal
(`TerminalControlKey.controllerAllows`) lässt Pfeil rechts bei Claude immer durch, links bleibt gesperrt.

### 6.9 Runde 4: Controller-Insel mit drei Ebenen (12.11.2026)

Entwurf: [`../design/controller-insel.html`](../design/controller-insel.html). Vom User mit „alles ja“
bestätigt:

1. **L1, R1, L2 sind Ebenen-Tasten.** Tippen (unter 0,3 s, keine andere Taste und kein Stoß von Stick
   oder Steuerkreuz dazwischen) löst beim Loslassen aus wie bisher: voriger Chat, nächster Chat, letzter
   Chat; in Liste und Verlauf die Filter, in Dialogen Shift+Tab/Tab. Gehalten werden sie zur Ebene.
   Kombinationen wirken sofort beim Druck der zweiten Taste; die 0,3 s steuern nur, wann die Insel
   erscheint. Loslassen nach Halten ohne Kombination tut nichts (außer L2 mit offener Liste). Eine
   Wiederholung beim Halten von L1/R1 gibt es nicht. Umgesetzt im Erkenner als `.tap`,
   `.layerBegan/.layerEnded/.layerCancelled` und `.inLayer(Ebene, Geste)`; die Belegung liegt in
   `ControllerBindingResolver+Layers.swift`. Ebenen gelten nur im Zusammenhang `chat` (auch im Raster);
   anderswo wirken die Tasten darin wie ohne Ebene.
2. **L1 + R1** zusammen 1 s: Pause wie bisher, jetzt in jedem Abstand (vorher 0,15 s Fenster). Die Ebene
   endet dabei still, kein Chatwechsel, keine Ebenen-Aktion. Unter L2 gibt es keinen Akkord.
3. **L1 „Schreiben“:** Viereck = bis Zeilenanfang löschen (Ctrl+U), gehalten nach 0,4 s alle 150 ms
   Zeile für Zeile; Dreieck = Zeilenumbruch ohne Senden (Ctrl+J). Kreuz und Kreis frei. Nur Claude und
   Codex, nicht in einer Rückfrage; in Shells Hinweis in der Insel und „geht nicht“. Ctrl+J belegt in
   Claude Code („Multiline input“, Control sequence) und Codex (`editor.insert_newline` = `ctrl-j` in
   `codex-rs/tui/src/keymap.rs`, `composer.submit` nur Enter). Shift+Enter verworfen: kommt im PTY als
   CR an.
4. **R1 „Schnellbefehle“** als Raute: Kreuz „Weiter“, Dreieck „Modus wechseln“, Viereck „Befehle ›“,
   Kreis „Konto wechseln ›“. Ein Druck führt aus und schließt die Insel; „›“ öffnet das Options-Menü auf
   der Unterseite. Regeln und Wege wie die Menüeinträge (`ControllerMenuModel.isEnabled`, `perform`),
   Ziel ist der Chat beim Öffnen. Die Rückfrage wird beim Drücken frisch gelesen. Abweichung: Ein
   Eintrag, der gerade nicht geht, vibriert und lässt die Insel offen (statt sie zu schließen).
5. **L2 „Wohin“:** erst die Hinweiszeile, Stick/Steuerkreuz hoch/runter öffnet die Liste (erster Stoß ein
   Schritt vom aktuellen Eintrag), links/rechts wechselt den Reiter Chats/Workspaces, Start-Reiter im
   Raster Workspaces, sonst Chats. Loslassen oder Kreuz wechselt, Kreis bricht ab, Dreieck springt zum
   nächsten wartenden Chat reihum (`AgentChatsCommand.nextWaitingChat` → `selectNextWaitingChat`, wie
   ⌃⌥Tab), R2 wechselt und diktiert. Auf dem Reiter Workspaces ist R2 „geht nicht“ (vorher in der
   Workspace-Auswahl ohne Wirkung).
6. **Die Insel** ersetzt den Ctrl+Tab-Umschalter am Controller (`switcherBegin/Move/Commit` und
   `switcherOpenedWithoutModifier` entfernt, die Tastatur unverändert) und die Workspace-Auswahl unten
   (`ControllerWorkspacePickerPanel`, `ControllerWorkspacePickerModel`, Zusammenhänge `chatPicker` und
   `workspacePicker` entfernt). Eigenes nicht aktivierendes Fenster ohne Maus auf dem Bildschirm des
   Agent-Chats-Fensters (`AgentChatsWindowSnapshot.screenDisplayID`), eine Ebene über der Notch-Anzeige
   mit derselben Band-Geometrie. Steht die Notch-Anzeige dort, zeigt die Insel ihre Zähler im Kopf
   (`NotchStatusController.visibleSummary(onDisplay:)`, nur lesend; eine offene Notch-Liste klappt zu).
   Öffnen und Schließen je eine Bewegung von 0,25 s. Signpost `controller.islandShow`, Budget 33 ms.
7. **Legende** schaltet beim Halten nicht um; im Chat steht ein Eintrag „L1 R1 L2 Halten: Ebenen“
   (ersetzt „Halten: Workspace wechseln“ im Raster). Die Einstellungsseite nennt alle drei Ebenen in einem
   eigenen Abschnitt.

Bewusst so gelassen: In Liste, Verlauf und Brücke lösen L1/R1 jetzt beim Loslassen aus (vorher nach
0,15 s); lange gehalten passiert dort nichts. Ein Stoß mit dem Stick während des Haltens von L1 oder R1
macht aus dem Tippen kein Tippen mehr.

Handtest nach dem nächsten `make dev`: siehe Bericht der Runde (Insel an der Notch und als Pille, über
der Notch-Anzeige, auf dem zweiten Bildschirm, Zeilenumbruch in Claude und Codex, Ctrl+U über mehrere
Zeilen, Pause-Akkord, Raute bei Rückfrage, „›“ ins Menü, Workspace-Wechsel mit gemerkter Kachel).

### 6.10 Review-Fixes nach Runde 4 (12.11.2026)

1. **„Weiter“ und „Modus wechseln“ nur bei ruhendem Chat** (Raute und Options-Menü): `ControllerMenuSetup.chatBusy`
   (arbeitet, unbekannt oder 3 s nach einem Absenden) graut beide aus, die Insel sagt warum, und
   `perform(_:setup:)` prüft beim Auslösen frisch. Grund: die Lücke zwischen Freigabe-Dialog und
   „wartet“ (Enter bestätigte die Vorauswahl, Shift+Tab hieße „alle Änderungen erlauben“), Codex meldet
   nie „wartet“. Befehle bleiben, wie sie sind (eigener Entwurfs-Schutz).
2. **Vollbild:** Das Insel-Fenster hat `.fullScreenAuxiliary`; ohne sichtbare Menüleiste hängt die
   Pille oben am Rand, an der Notch liegt das Band in der Aussparung.
3. **Reiterwechsel allein wechselt nicht:** Loslassen oder Kreuz nur nach einer Bewegung im sichtbaren
   Reiter (`ControllerWhereToState.hasMovedInTab`).
4. **L2 + R2** diktiert nur, wenn der Wechsel gelang und der Chat danach ausgewählt ist, sonst „geht nicht“.
5. **Rechter Stick** über der Totzone während einer gehaltenen Ebenen-Taste macht aus ihr kein Tippen mehr.
6. **Notch-Zähler** im Kopf nur bei „Wohin“; Schreiben und Schnellbefehle zeigen immer den Ziel-Chat.
7. **Schnappschuss ohne Fenster:** Die Insel wird über `refreshContext` nachgeführt, nicht im
   Schnappschuss (Trockenläufe des Debug-Kanals öffnen nichts).

Dazu: runde Tasten-Symbole der Insel als Kreis statt kontinuierlicher Ecken (wirkten achteckig).

## 7. Fortschritt

| Etappe | Stand | Commit | Notiz |
|---|---|---|---|
| 0 Vorbereitung | erledigt | 13847432 | Arbeitsordner, Branch, Ausgangswert 4.039 Tests grün, Plan und README-Eintrag committet |
| 1 Entwurf im HTML-Zwilling | erledigt | 307e04b9 | `docs/design/controller-steuerung.html`: sechs Zustände der Legende, Listen-Markierung, Menü (normal und bei Rückfrage), Einstellungsseite; hell und dunkel gerendert und angesehen |
| 2 Aktions-Katalog | erledigt | 42424701 | `AgentChatsCommandCenter` mit Token-Anmeldung und Routing nur zum Key-Fenster, `ChatSelectionHistory`, `AgentChatsView+Commands.swift`; drei Rümpfe aus `+Shortcuts.swift` als gemeinsame Funktionen; 159 Tests rund um Tabs, Umschalter und Katalog grün; `AgentChatsView.swift` bei 3.821 von 3.842 Zeilen |
| 3 Controller-Kern | erledigt | 31751bc0 | Elf Dateien unter `Services/Controller/Core/`, nur Foundation; 98 neue Tests (Erkenner, Sticks, Belegung, Matrix, Zusammenhang, Legende, Listen- und Menü-Modell, Import-Wächter). Abweichung: Viereck ist Tippen-oder-Halten (0,6 s), damit „halten löscht“ im Verlauf ohne Gedächtnis in der Belegung geht; `reset` meldet `holdCancelled`, damit eine Trennung die Chat-Auswahl ohne Wechsel schließt |
| 4 Hardware, Schalter, Debug-Kanal | erledigt | 38ab966f | `GameControllerInputSource` (Trigger als Analogwert), `ControllerGesturePump` (eigene Queue, strikter Zeitgeber nur bei Druck, Aktivität gegen App Nap), `ControllerManager` (Schalter, Pause, Hintergrund mit zurückgelesenem Systemwert, Zähler je Taste); Schalter samt Notbremse; erste Seite „Controller“ in Labs; `whisperm8 debug controller state|press|sequence` mit Trockenlauf als Standard, `--execute` nur in der Test-Instanz. Test des virtuellen Gamepads (`GCController.withExtendedGamepad`) grün. Hinweis-Lauf mit Hardware (Abschnitt 6.1): Tasten kommen im Hintergrund an |
| 5 Navigation im Inhalt | erledigt | 526d413e | `sendKey` (Pfeile nach Cursor-Modus, Tracker und Abbruch-Verdacht wie bei der Tastatur), `scrollHistory` (auch Alternate-Puffer), `ControllerActionDispatcher` mit Schnappschuss je Eingabe; 45 Ausführer-Tests mit Attrappen. Nachweis zusätzlich in der Test-Instanz (Abschnitt 6.3) |
| 6 Listen-Navigation | erledigt | d661cecc | `AgentChatsListRowsBuilder` (pur, Reihenfolge wie die Seitenleiste), Markierung als eigenes View-Stück je Zeile, Mitscrollen über `ScrollViewReader`; Kreuz öffnet Chat, Workspace oder Projekt als Workspace. Fixture `controller-liste-markierung` hell und dunkel angesehen; dazu `controller-pill-ziel` für das Ziel in der Pill (Etappe 8). Grenze: Was eine Projektgruppe per „N weitere“ aufgeklappt hat, erreicht die Navigation nicht |
| 7 Legende | erledigt | d661cecc | `ControllerLegendBar` + Host, sechs Zustände als Fixture gerendert und angesehen; bei schmalen Fenstern gekürzt (`ViewThatFits`); Halte-Ring als endliche Animation |
| 8 Diktat | erledigt | 1531673e, 526d413e, ea5cfc40 | Zustellung direkt ins Chat-Terminal (Router pur, Ausführer injizierbar), Hotkey-Weg durch vorher geschriebene Tests festgehalten; R2 als Umschalter, Kreuz = fertig und senden nur bei Chat-Ziel; Ausgabemodus per Steuerkreuz; Pill zeigt Ziel und Modus ohne Hover. Abweichungen: kein `PromptDeliveryGate` beim Senden (der Nutzer diktiert bewusst in den sichtbaren Chat); Kontext der Nacharbeit aus der Ziel-Session nicht umgesetzt (Ziel ist immer der ausgewählte Chat, dessen Kontext die App ohnehin nimmt) |
| 9 Verlauf, Brücke, Menü | erledigt | 526d413e, d661cecc | Verlauf über `ClipboardHistoryController.perform`; Tastatur-Brücke mit markierten Ereignissen nur in die eigene App; Menü mit Fixture. Dialoge der App: Bestätigen/Abbrechen über Return/Escape sind Standard der vorhandenen Dialoge — Handtest |
| 10 Chat-Auswahl mit L2 | erledigt | 42424701, 526d413e | Umschalter ohne Ctrl öffnen (Markierung bleibt auf dem aktuellen Chat), Bewegen, Loslassen, Kreis, R2 = wechseln und diktieren; Tastatur-Umschalter wird von der ersten Controller-Eingabe geschlossen. Nachweis in `ControllerActionDispatcherTests` und in der Test-Instanz (Abschnitt 6.3) |
| 11 Rückmeldung und Schutz | erledigt | ea5cfc40, 3e596f3c | Lichtleiste aus `ControllerLightPolicy`, Warte-Signal mit `ControllerWaitingTracker`, automatische Pause (Sperre, Schoner, Ruhezustand, Spiele), Maus/Tastatur geben Liste und Menü ab, Trennung schließt beides. Licht und Haptik selbst: Handtest |
| 12 Einstellungsseite | erledigt | 38ab966f, ea5cfc40 | Ein/Aus, Verbindung, Akku oder „nicht gemeldet“, Tasten-Test, vier Schalter, Hintergrund-Zustand, Belegung aus `ControllerLegend.allBindings`, Koppeln; einmaliger Hinweis bei erkanntem Controller. Drei Fixtures hell/dunkel angesehen |
| 13 Doku und Übergabe | erledigt | (dieser Commit) | `docs/features/controller.md`, Verweis und Notbremse in `CLAUDE.md`, Test-Instanz in 6.3, Sonderfälle in 6.4, Handtest-Liste in 6.2; unabhängige Durchsicht des gesamten Diffs (Opus): keine Regression ohne Controller, 3 hohe/mittlere und 8 kleinere Befunde, alle eingearbeitet (5d3d0f1a); volle Suite danach 4.285 Tests grün |
| Runde 3 | erledigt | cde3b413, bfa95c4d, 375913ff, 87f388b4, 8877fed0, fddecdd0, 01becb6d | Stick markiert in der Liste, Workspace-Zeilen wechseln den Workspace (Klick und Kreuz), Workspace-Auswahl auf L2 im Raster, Review-Befunde 1/2/3/5, Schreibtasten (Leerzeichen, Wörter, Eingabe leeren); Abschnitt 6.6. Handtest nach dem nächsten Neustart aus main |
| Review-Fixes nach Runde 3 | erledigt | e9bab93c, 4c4c04d2 | 4.457 Tests grün; Auswahl offen, Codex-Pfeile, Konflikt-Rückfall bei mehreren Fenstern, Mausklick wie vor Runde 3, Schreibtasten nur Claude/Codex, Absenden auf jedem Weg, Leeren an den Haltebeginn gebunden; Abschnitt 6.7. Handtest nach dem nächsten Neustart |
| Runde 4: Controller-Insel | erledigt | d821977a, c35e6391 | 4.551 Tests grün; Abschnitt 6.9. Ebenen L1/R1/L2, Insel an der Notch, Ctrl+Tab und Workspace-Auswahl am Controller ersetzt; Handtest nach dem nächsten Neustart |
