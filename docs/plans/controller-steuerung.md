---
status: in Arbeit
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

- **Einzelchat:** Stick links geht in die Liste. Steuerkreuz, Kreuz, Kreis und R2 wirken auf den Chat.
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

### 6.2 Handtest nach `make dev`

Wird in Etappe 13 vervollständigt. Feste Punkte:

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

**Controller:**

- Jede Taste des Kerns und des Zusatzes in Einzelchat, Raster und Liste.
- Diktat: in einen Chat, mit Senden, in ein anderes Programm (Hintergrund an), bei offener Rückfrage.
- Tasten im Hintergrund in beiden Profilen (Dock und Menüleiste), auch nach Ruhezustand.
- Lichtleiste, Vibration, Akkuanzeige.
- Trennen und Neuverbinden, Bildschirmsperre, Pause.
- PlayStation-Taste und Create (einfach, doppelt).

### 6.3 Sonderfälle und wo sie geprüft sind

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
| Kein wartender Chat bei Dreieck | `ControllerActionDispatcherTests.testFailedJumpGivesRejectFeedback` |
| Chat beendet oder nur Verlauf | `ControllerBindingResolverTests.testEndedChatKeepsNavigationButNoTerminalKeys`, `ControllerActionDispatcherTests.testChatWithoutTerminalCountsAsEnded` |
| Kein Chat offen | `ControllerContextResolverTests.testContentWithoutChatFallsBackToList`, `ControllerBindingResolverTests.testList` |
| Zwei Controller | `GameControllerInputSource.deliver` löst beim Quellenwechsel alles Gehaltene — Handtest |
| Diktat ohne erkannten Text | `DictationDeliveryRouterTests` (leerer Text → `nothing`), `RecordingCoordinatorDeliveryTests` |
| Create zweimal schnell | Vermerk in `docs/features/controller.md` (Systemgeste von macOS) |

## 7. Fortschritt

| Etappe | Stand | Commit | Notiz |
|---|---|---|---|
| 0 Vorbereitung | erledigt | 13847432 | Arbeitsordner, Branch, Ausgangswert 4.039 Tests grün, Plan und README-Eintrag committet |
| 1 Entwurf im HTML-Zwilling | erledigt | 307e04b9 | `docs/design/controller-steuerung.html`: sechs Zustände der Legende, Listen-Markierung, Menü (normal und bei Rückfrage), Einstellungsseite; hell und dunkel gerendert und angesehen |
| 2 Aktions-Katalog | erledigt | 42424701 | `AgentChatsCommandCenter` mit Token-Anmeldung und Routing nur zum Key-Fenster, `ChatSelectionHistory`, `AgentChatsView+Commands.swift`; drei Rümpfe aus `+Shortcuts.swift` als gemeinsame Funktionen; 159 Tests rund um Tabs, Umschalter und Katalog grün; `AgentChatsView.swift` bei 3.821 von 3.842 Zeilen |
| 3 Controller-Kern | erledigt | (dieser Commit) | Elf Dateien unter `Services/Controller/Core/`, nur Foundation; 98 neue Tests (Erkenner, Sticks, Belegung, Matrix, Zusammenhang, Legende, Listen- und Menü-Modell, Import-Wächter). Abweichung: Viereck ist Tippen-oder-Halten (0,6 s), damit „halten löscht“ im Verlauf ohne Gedächtnis in der Belegung geht; `reset` meldet `holdCancelled`, damit eine Trennung die Chat-Auswahl ohne Wechsel schließt |
| 4 Hardware, Schalter, Debug-Kanal | offen | | |
| 5 Navigation im Inhalt | offen | | |
| 6 Listen-Navigation | offen | | |
| 7 Legende | offen | | |
| 8 Diktat | offen | | |
| 9 Verlauf, Brücke, Menü | offen | | |
| 10 Chat-Auswahl mit L2 | offen | | |
| 11 Rückmeldung und Schutz | offen | | |
| 12 Einstellungsseite | offen | | |
| 13 Doku und Übergabe | offen | | |
