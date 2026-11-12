---
status: Plan, Bau nach der vereinten Pille (feat/pille-vereint) und zusammen mit bzw. nach Runde 5 (feat/controller-runde5)
stand: 2026-11-12
feature: Xbox-Controller mit eigenen Tastennamen, Paddles des Xbox Elite als frei belegbare Tasten
branch: feat/controller-xbox
---

# Xbox-Controller und Paddles: Bauplan

Freigegeben vom Nutzer („Go“, 12.11.2026): Xbox-Controller sollen mit ihren eigenen Tastennamen erscheinen,
und die vier Paddles des Xbox Elite Series 2 werden eigene Tasten mit Standardbelegung, umstellbar in
Einstellungen › Controller. Dieser Plan sagt, wo was gebaut wird, wie die doppelt gemeldete Taste eines
Paddles sicher verschluckt wird, welche puren Typen Tests bekommen und in welcher Reihenfolge committet wird.

Feature-Doku: [`../features/controller.md`](../features/controller.md). Bauplan Runde 5:
`docs/plans/controller-runde5-bau.md` auf `feat/controller-runde5`. Pille:
[`../design/pille-vereint.html`](../design/pille-vereint.html).

## Ausgangslage

- **main (`ea01e11a`):** Der Controller kennt nur logische Tasten mit DualSense-Namen (`ControllerButton`,
  gemeint ist die Position: Kreuz = untere Taste). Alle sichtbaren Zeichen kommen aus
  `ControllerButton.glyph`/`displayName` in `Views/Controller/ControllerLabels.swift`, gezeichnet von
  `ControllerGlyphView`/`ControllerInputGlyphs` (Legende, Einstellungen, Fußzeile des Verlaufs) und
  `IslandGlyph` (Insel). Dazu stehen PlayStation-Zeichen und -Namen fest in 14 Texten des Katalogs („Hold L1, then □: …“) und
  im Pairing-Text.
- **`feat/controller-runde5`** (Stand 12.11., drei Bau-Commits bis `7b612c39`): R1 + ✕ „Jetzt senden“ ist
  gebaut (`ControllerQuickDrawSlots.crossAction`, `ControllerActionDispatcher.quickCross(_:)`,
  `ClaudeQueueScan.pendingOwnPrompts`, `TerminalControlKey.sendNow`), ebenso L1 + ✕ „Einfügen“
  (`.pasteNewest`), L1 + L3 „Rückgängig“ (`.chatKey(.undo)`, nur Claude) und L2 + □. Offen sind dort noch
  unter anderem die Befehle `/tasks` und `/workflows` im Menü (Runde-5-Schritt 12, R5) und die Aufteilung der
  `ControllerIslandView`.
- **`feat/pille-vereint`** (Stand 12.11.): bisher nur Snapshots der Diktat-Pille. Die Insel wächst danach aus
  der vereinten Pille; `ControllerIslandView` und `ControllerIslandPresenter` ändern sich dort.
- **Folge:** Dieser Bau fasst `ControllerIslandView` nur für die Tastenzeichen an und setzt darum auf den Stand
  nach der Pille auf. Die Paddle-Aktionen nutzen Runde-5-Bausteine und kommen erst nach deren Merge.

## Gemessene Fakten (12.11.2026, Gerät des Nutzers)

- Xbox Elite Wireless Controller Series 2, Bluetooth LE, VendorID `0x045E`, ProductID `0x0B22`, Firmware
  5.21.3242.0. GameController: `vendorName` „Xbox Wireless Controller“, `productCategory` „Xbox One“,
  Profil `GCXboxGamepad`; `paddleButton1`–`4` sind `nil`, `buttonShare` ist `nil`, kein Licht, Haptik ja.
- Rohes HID über `IOHIDManager` (Testwerkzeug `xboxdiag/listen.swift` im Scratchpad, Protokoll `probe2.txt`):
  Jedes Paddle sendet auf Seite `0x0C` (Consumer), Usage `0x81`, eine Bitmaske: 1, 2, 4, 8, je ein Bit pro
  Paddle; gleichzeitig gedrückte addieren sich (gesehen: 3, 5, 10, 12, 14), Loslassen gibt 0.
- **Im selben Bericht** (gleicher Zeitstempel) kommt eine gewöhnliche Taste auf Seite `0x09` mit: Bit 1 ↔
  Usage 2 (B), Bit 2 ↔ Usage 5 (Y), Bit 4 ↔ Usage 1 (A), Bit 8 ↔ Usage 4 (X). Das ist das Profil im
  Controller, das die Paddles auf Gesichtstasten legt. GameController meldet diese Taste dann als
  gewöhnliches A, B, X oder Y.
- Ein direkter Druck auf A schickt nur Seite `0x09` Usage 1, ohne Änderung an `0x81`. **HID sieht also jede
  Gesichtstaste**, und für jeden Druck lässt sich am Bericht ablesen, ob ein Paddle ihn ausgelöst hat.
- **Reihenfolge:** Im Testwerkzeug liefen HID und GameController beide auf dem Main-Runloop. HID kam in allen
  22 Fällen zuerst, GameController 0 bis 3 ms danach. Das ist ein Hinweis, keine Garantie; der Plan verlässt
  sich nicht darauf (siehe „Weiche“).
- Nicht gemessen: welches Bit zu welchem Paddle gehört. Die Elite-Zählung ist P1 oben rechts, P2 unten
  rechts, P3 oben links, P4 unten links; vermutlich Bit 1, 2, 4, 8 in dieser Reihenfolge. Geprüft wird das
  über den Tasten-Test der Einstellungen (Handtest H2).
- Nicht gemessen: GameController-Loslassen (das Werkzeug protokollierte nur Drücken) und ob das Öffnen aus der
  signierten App eine Rückfrage nach „Eingabeüberwachung“ auslöst (siehe Risiken).

## Entscheidungen

1. **Tastennamen folgen dem Controller der letzten Eingabe.** Familie `playStation`, `xbox` oder `generic`.
   Bei Xbox: A B X Y, LB RB LT RT, LS RS, View, Menu; Steuerkreuz und Sticks wie bisher. Belegung nach Lage
   unverändert (A = Kreuz, B = Kreis, X = Viereck, Y = Dreieck, View = Create, Menu = Options). `generic`
   behält die PlayStation-Zeichen wie heute.
2. **Xbox hat kein Touchpad.** Legende, Insel und Belegungsübersicht zeigen bei Xbox keine Touchpad-Einträge
   (auch nicht L2 + Touchpad). Der Verlauf bleibt über das Options-Menü erreichbar und neu über ein Paddle
   („Verlauf öffnen“). Die Xbox-Taste gehört wie die PlayStation-Taste macOS und bleibt frei.
3. **Paddles sind eigene logische Tasten** (`paddleUpperLeft`, `paddleLowerLeft`, `paddleUpperRight`,
   `paddleLowerRight`), Sofort-Tasten ohne Halten und ohne Wiederholung: ein Druck, eine Aktion.
4. **Standardbelegung:** oben links „Nächster wartender Chat“, unten links „Antworten“, oben rechts
   „Jetzt senden / Weiter“, unten rechts „Modus wechseln“.
5. **Paddles wirken nur in der App**, im Agent-Chats-Fenster (Liste oder Chat, auch Raster). Außerhalb der App
   tun sie nichts und wecken auch nicht; das steht in der Doku. Grund: Ein Paddle drückt man gezielt für eine
   bestimmte Aktion, ein Wecken ohne diese Aktion wäre eine Überraschung, und „Antworten“ aus einem Spiel
   heraus soll nicht passieren. Ausnahme: „Pause“ wirkt überall, wo L1 + R1 wirkt, sonst käme man aus der
   Pause nicht mit dem Paddle heraus.
6. **Die mitgeschickte Gesichtstaste wird verschluckt**, beim Drücken und beim Loslassen, nach HID-Bericht und
   nicht nach Zeitfenster allein (siehe „Weiche“). Wo HID nicht lesbar ist, bleibt alles wie heute: Das
   Paddle wirkt als die Gesichtstaste, auf die es das Controller-Profil legt.
7. **In einer Ebene** (L1, R1, L2 gehalten) tun Paddles nichts, ohne Vibration. Sie verbrauchen die Ebene
   wie jede andere Taste (kein Tippen beim Loslassen). So bleibt das Ebenen-Modell unverändert.
8. **Während Aufnahme, Transkription und Nacharbeit** tun Paddles nichts, ohne Vibration (wie der linke
   Stick): Ein Paddle streift man beim Greifen leicht.
9. **Die Legende zeigt keine Paddles.** Sie sind persönliche Abkürzungen; die Einstellungsseite listet sie mit
   ihrer Belegung. Siehe offene Frage 4.
10. **IOHID liegt nicht im Kern.** Der Kern bleibt Foundation-only (`ControllerCoreImportGuardTests`). Die
    Entscheidung, welche Taste verschluckt wird, ist eine pure Zustandsmaschine im Kern mit Tests; die
    HID-Anbindung ist eine dünne Quelle daneben.

## Aufbau

```
GameControllerInputSource ──┐ (Ereignis + Herkunft)
XboxPaddleHIDSource ────────┤ (HID-Bericht: Paddle-Maske, Tastenwechsel)     alles auf pump.queue
debug.controller (Skript) ──┤
                            ▼
              ControllerGesturePump
                 ├─ ControllerPaddleGate (pur, neu): verschluckt Paddle-Doppel, macht aus Maske Tasten
                 └─ ControllerGestureRecognizer (pur): Paddles sind Sofort-Tasten → .press(.paddleX)
                            ▼  nur diskrete Gesten zum Main Thread
              ControllerManager → ControllerBindingResolver(paddles: Belegung) (pur)
                            ▼
              ControllerActionDispatcher (+Paddles) → nächster wartender Chat, Diktat, Jetzt senden, …
```

| Teil | Datei | Aufgabe |
|---|---|---|
| Familie | `Core/ControllerFamily.swift` (neu) | `enum ControllerFamily { playStation, xbox, generic }`, `classify(productCategory:)` als Rückfall für Debug und Tests; Eigenschaften je Familie (`hasTouchpad`) |
| Paddles | `Core/ControllerPaddles.swift` (neu) | `ControllerPaddle` (vier Lagen), `XboxPaddleBits` (Bit ↔ Lage, eine Tabelle), `ControllerPaddleBinding` (die feste Auswahlliste), `ControllerPaddleBindings` (Belegung aller vier, Standard) |
| Weiche | `Core/ControllerPaddleGate.swift` (neu) | pure Zustandsmaschine, siehe unten |
| HID-Quelle | `Services/Controller/XboxPaddleHIDSource.swift` (neu, `import IOKit.hid`) | Manager, Abgleich, Bericht bündeln, Zugriffsprüfung, Status |
| Quelle GC | `GameControllerInputSource` | Familie bestimmen (`pad is GCXboxGamepad` usw.), Herkunft je Ereignis mitgeben, Gerät der letzten Eingabe melden; falls ein künftiges Profil `paddleButton1`–`4` liefert, diese verdrahten (gleiche Weiche) |
| Pumpe | `ControllerGesturePump` | Weiche vor dem Erkenner, gemeinsamer Zeitgeber (Frist = Minimum beider) |
| Belegung | `Core/ControllerBindingResolver+Paddles.swift` (neu) | Paddle-Druck je Zusammenhang → Aktion |
| Ausführer | `ControllerActionDispatcher+Paddles.swift` (neu) | die neuen Aktionen; gemeinsamer Weg mit R1 + ✕ |
| Texte | `Views/Controller/ControllerLabels+Family.swift` (neu) | Zeichen und Namen je Familie, Paddle-Namen, Umgebungswert `controllerFamily` |
| Einstellungen | `ControllerSettingsPage` + `ControllerPaddleSection.swift` (neu) | Auswahl je Paddle, Zustand der Paddles, Tasten-Test |

`ControllerActionDispatcher.swift` hat 714 Zeilen, `ControllerLabels.swift` 227, `ControllerIslandView.swift`
661; neue Logik kommt deshalb in eigene `+…`-Dateien (Grenze 1.500 Zeilen, `SourceSizeGuardTests`).

## Tastennamen für Xbox und PlayStation

**Woher die Familie kommt.** `GameControllerInputSource` bestimmt sie beim Verdrahten aus der Profilklasse:
`GCXboxGamepad` → `xbox`, `GCDualSenseGamepad`/`GCDualShockGamepad` → `playStation`, sonst `generic`.
`ControllerDeviceInfo` bekommt `family` und `paddles: ControllerPaddleSupport` (`none`, `hid`, `unavailable(reason)`).

**Letzte Eingabe gewinnt.** `deliver(_:from:)` merkt heute schon `lastSource` auf der Eingabe-Queue. Wechselt
sie, meldet die Quelle das Gerät dieser Eingabe an den Main Thread (`onDeviceChange` mit dessen Info).
`GCControllerDidBecomeCurrent` bleibt als zweiter Weg. `ControllerStatus.device` ist damit immer der
Controller, von dem zuletzt etwas kam; Lichtleiste und Haptik nutzen schon `GCController.current`, das dem
zuletzt benutzten folgt. Ein Paddle-Druck kommt über die mitgeschickte Gesichtstaste auch bei
GameController an, schaltet also mit um.

**Zeichen.** `ControllerButton.glyph` und `displayName` werden zu Funktionen `glyph(_ family:)` und
`displayName(_ family:)`; die alten Eigenschaften fallen weg, damit der Compiler jede Stelle findet (heute
elf: Legende, Einstellungen, Verlauf, Insel). Gezeichnet wird über einen SwiftUI-Umgebungswert
`\.controllerFamily` (Standard `playStation`), den `ControllerGlyphView`, `ControllerInputGlyphs` und
`IslandGlyph` lesen. Gesetzt wird er an den Wurzeln, die `ControllerStatus` ohnehin beobachten:
`ControllerLegendBar`, `ClipboardControllerHints`, die Einstellungsseite, die Wurzel der Insel im
Presenter und das Menü-Overlay. Kein großer Body liest dadurch zusätzlich etwas.

| Lage | PlayStation | Xbox | Xbox-Name im Tasten-Test |
|---|---|---|---|
| unten, rechts, links, oben | ✕ ○ □ △ | A B X Y (rund) | „A button“ usw. |
| Schultern | L1 R1 | LB RB | „Left bumper“, „Right bumper“ |
| Trigger | L2 R2 | LT RT | „Left trigger“, „Right trigger“ |
| Stick-Klick | L3 R3 | LS RS | „Left stick click“ (gibt es schon) |
| Create / Options | Create, Options | View, Menu | „View button“, „Menu button“ |
| Touchpad | Touchpad | – | – |
| Paddles | – | P3 P4 P1 P2 (Elite-Zählung) | „Upper left paddle (P3)“ usw. |

Buchstaben bleiben einfarbig wie heute die PlayStation-Zeichen (Legende und Insel sind bewusst ruhig).

**Texte mit Zeichen.** Die 14 Texte (Runde 5 bringt weitere) mit festen Zeichen werden zu Texten mit Platzhaltern, etwa
`String(localized: "Hold \(l1), then \(square): delete to the start of the line …")` mit den Zeichen der
Familie. Neue Schlüssel (`Hold %@, then %@: …`), deutsche Übersetzung mit denselben Platzhaltern, alte
Schlüssel raus. Ebenso der Abschnittstitel „Hold L1, R1 or L2: layers“, der Text zu „Also when another app
is in front“ (L1 + R1) und zum Aufwecken (R2, Touchpad). Bei Xbox fällt im Aufweck-Text das Touchpad weg.

**Was je Familie fehlt.** `ControllerLegend.entries(for:)` und `allBindings()` bekommen einen Parameter
`traits: ControllerFamily` und lassen Einträge weg, deren Eingaben das Gerät nicht hat (bei Xbox Touchpad und
L2 + Touchpad). Die Insel lässt in „Wohin“ die Touchpad-Fußzeile weg. Die Belegung selbst bleibt gleich; eine
Touchpad-Geste kommt bei Xbox nur nie an.

**Pairing.** Der Abschnitt bekommt einen zweiten Absatz: „Xbox controller: hold the pair button on the top
edge until the Xbox button flashes quickly, then connect it under Bluetooth in System Settings. The Elite
Series 2 needs a current firmware for Bluetooth LE.“ (deutsch übersetzt).

## Paddles im Kern

- `ControllerButton` bekommt die vier Paddle-Fälle. Der Erkenner braucht keine Änderung: Ohne Halteschwelle
  und Ebenen-Rolle liefert `digital(_:pressed:at:)` schon `.press(button)`; in einer Ebene wird daraus
  `.inLayer(layer, .press(paddle))` und die Ebene gilt als benutzt. Ein Test sichert genau das ab.
- `ControllerPaddleBinding` (Rohwert als String, gespeichert in den Einstellungen):

| Fall | Text (englisch) | Wirkung |
|---|---|---|
| `nextWaiting` | Next waiting chat | derselbe Weg wie L2 + △ und ⌃⌥Tab (`nextWaitingChat`), aber ohne Insel |
| `answer` | Answer | Sprung wie oben, danach Diktat im Ziel-Chat, siehe unten und offene Frage 1 |
| `sendNow` | Send now / Continue | dieselbe Entscheidung wie R1 + ✕ (`crossAction`), siehe unten |
| `cycleMode` | Switch mode | Shift+Tab, Regeln des Menü-Eintrags „Modus wechseln“ |
| `lastChat` | Back to previous place | `.lastChat` wie L2 getippt |
| `pasteNewest` | Paste from clipboard | `.pasteNewest` wie L1 + ✕ (Runde 5) |
| `undo` | Undo | `.chatKey(.undo)` wie L1 + L3 (Runde 5, nur Claude) |
| `clipboardHistory` | Open clipboard history | `.clipboardToggle` wie das Touchpad |
| `pause` | Pause controller | `.pauseToggle` wie L1 + R1 |
| `claudeWorkflows` | Claude: /workflows | Befehl `/workflows` wie aus „Befehle ›“ |
| `claudeTasks` | Claude: /tasks | Befehl `/tasks` wie aus „Befehle ›“ |
| `none` | Nothing | nichts, auch keine Vibration |

  Ein unbekannter gespeicherter Wert gilt als Standard dieses Paddles (vorwärtsverträglich).
- `ControllerBindingResolver.action(for:in:paddles:)` bekommt die Belegung als dritten Parameter (Standard
  `.standard`); Legende und Tests rufen weiter ohne ihn. Der Manager hält die Belegung zwischengespeichert
  und liest sie in `applyPreferences()` neu; die Einstellungsseite ruft das bei jeder Änderung auf. Kein
  Lesen der Einstellungen je Geste.
- **Wo ein Paddle wirkt** (`ControllerBindingResolver+Paddles.swift`):

| Zusammenhang | Wirkung |
|---|---|
| `.chat` (auch Raster, fokussierte Kachel) | jede Belegung; ob sie gerade geht, prüft der Ausführer frisch |
| `.list` | `nextWaiting`, `answer`, `lastChat`, `clipboardHistory`, `pause`; Eingaben in einen Chat (`sendNow`, `cycleMode`, `pasteNewest`, `undo`, `/workflows`, `/tasks`) → „geht nicht“ |
| `.clipboardPanel` | `clipboardHistory` schließt, `pause`; sonst „geht nicht“ |
| `.menu`, `.modal`, `.otherWindow` | `pause`; sonst „geht nicht“ |
| `.recording`, `.quickAction` | nichts, ohne Vibration |
| `.paused` | nur `pause` (sonst bliebe man in der Pause gefangen) |
| `.outsideApp`, `.noWindow` | nichts; `pause` nur, wo L1 + R1 wirkt (`chordAllowed`) |
| in einer Ebene | nichts |

  `wakes(_:)` gibt für Paddles `false` zurück.
- Neue `ControllerAction`-Fälle: `.nextWaitingChat` (der Inselweg `.islandNextWaiting` bleibt für die Insel),
  `.answerNextWaiting`, `.sendNowOrContinue`, `.cycleMode`, `.slashCommand(String)`. Die übrigen Belegungen
  nutzen bestehende Aktionen.

## Paddle-Aktionen im Ausführer

`ControllerActionDispatcher+Paddles.swift`. Gemeinsame Regel: Ziel ist der ausgewählte Chat beim Druck;
geprüft wird beim Ausführen frisch aus `terminals.state(of:)`; wo nichts passt, „geht nicht“ (drei Ticks).

- **Nächster wartender Chat:** `command(.nextWaitingChat, orReject: true)`. Kein wartender Chat oder nur der
  aktuelle → „geht nicht“.
- **Antworten:** Ziel wählen, wechseln wie `commitWhereTo(dictate: true)` (dieselbe Prüfung: nach dem Wechsel
  muss `selectedSessionID` das Ziel sein und `chatTarget()` existieren, sonst „geht nicht“, kein Diktat).
  Steht im Ziel eine Rückfrage (`status == .awaitingInput`), nur springen, nie diktieren. Die bestehende
  Schutzregel des Diktats („in eine offene Rückfrage läuft nie Text“) bleibt als zweite Sicherung. Hinweis:
  „wartet“ heißt in WhisperM8 genau „ein Dialog wartet“ (Claudes Registry `waiting` → `.awaitingInput`).
  Wörtlich umgesetzt würde „Antworten“ deshalb nie diktieren. Siehe offene Frage 1.
- **Jetzt senden / Weiter:** Der Teil von `performQuickDraw(.continueWork)` aus Runde 5, der
  `quickCross(terminal)` auswertet und Enter bzw. `sendNow` schickt oder „Weiter“ über
  `perform(.continueWork, setup:)` sendet, zieht in eine Funktion `sendOrContinue(setup:)`, die die R1-Raute
  und das Paddle teilen. Die Raute behält davor ihr kurzes Aufleuchten (`flashQuickDrawHit`). Für das Paddle
  gilt zusätzlich: Shell → „geht nicht“ (bei R1 + ✕ läuft dort heute „Weiter“ nach den alten Regeln). Damit
  entspricht es der Tabelle des Auftrags: Claude mit Text oder eigenem wartendem Prompt bei arbeitendem Chat →
  Ctrl+X Ctrl+S; Claude mit Text im Ruhezustand → Enter; Codex mit Text → Enter; leer und ruhend → „Weiter“;
  leer, nichts wartet, arbeitet → „geht nicht“; offene Rückfrage oder erkannte Ansicht → „geht nicht“.
- **Modus wechseln:** `ControllerMenuModel.isEnabled(.cycleMode, setup:)` mit frischem `menuSetup`, dann
  `perform(.cycleMode, setup:)`. Damit gelten die Regeln von Menü und Raute (nicht in Rückfragen, nur wenn der
  Chat ruht; `sendKey` verweigert Shift+Tab in einer Rückfrage ohnehin).
- **/workflows, /tasks:** `sendCommand(ControllerSlashCommand(text:), setup:)` mit den Regeln von „Befehle ›“,
  nur in Claude-Chats (Codex und Shell → „geht nicht“). Setzt „Auswahl offen“ nur, wenn Runde 5 die Befehle so
  in `ControllerSlashCommands` einträgt.
- **Einfügen, Rückgängig, Zurück, Verlauf, Pause:** die vorhandenen Wege von Runde 5 bzw. heute, mit deren
  Regeln.

## Weiche gegen die doppelte Taste

**Problem.** Ein Paddle kommt auf zwei Wegen an: als Bit in HID-Seite `0x0C`/`0x81` und, über das Profil im
Controller, als gewöhnliche Taste bei GameController. Ohne Weiche schickte das Paddle „Jetzt senden“ und
zusätzlich A, also Enter.

**Ein Takt für beide Wege.** `XboxPaddleHIDSource` hängt den `IOHIDManager` per
`IOHIDManagerSetDispatchQueue(manager, pump.queue)` an dieselbe serielle Queue, auf der GameController seine
Handler aufruft (`handlerQueue = queue`), dann `IOHIDManagerActivate`. Beide Wege kommen damit in einer
festen Reihenfolge in der Pumpe an; welcher zuerst kommt, bleibt offen.

**HID-Bericht bündeln.** Die Werte eines Berichts kommen als einzelne Rückrufe mit gleichem Zeitstempel
(`IOHIDValueGetTimeStamp`) hintereinander im selben Block der Queue. Die Quelle sammelt sie und schickt sie
mit einem `queue.async` am Ende als einen `ControllerHIDReport` weiter: neue Paddle-Maske (falls `0x81`
dabei war) und die Tastenwechsel auf Seite `0x09`, übersetzt nach `XboxHIDButtons` (gemessen: Usage 1 = A,
2 = B, 4 = X, 5 = Y; LB, RB, View, Menu, LS, RS werden im Gerätetest H1 nachgemessen; unbekannte Usages
werden ignoriert).

**Die Weiche** (`ControllerPaddleGate`, pur, im Kern, mit Uhr als Parameter):

- Eingaben: `hid(report, at:)`, `gameController(event, origin, at:)`, `tick(at:)`, `reset()`,
  `setPaddleSource(available:)`. Ausgabe: Ereignisse für den Erkenner und `nextDeadline`.
- Aus einer Änderung der Maske werden `.button(.paddleX, pressed:)` (Bit ↔ Lage aus `XboxPaddleBits`),
  mehrere Bits in einem Bericht ergeben mehrere Ereignisse.
- Jeder Tastendruck im HID-Bericht wird zu einem **Urteil** für genau diese Taste: „vom Paddle“, wenn im selben
  Bericht ein Paddle-Bit dazukam, sonst „direkt“. Urteile verfallen nach 100 ms.
- **Druck von GameController**, Herkunft Xbox und HID-Paddles verfügbar:
  - Urteil „vom Paddle“ liegt vor → verschlucken, Taste als „gehört dem Paddle“ merken.
  - Urteil „direkt“ liegt vor → sofort durchlassen.
  - Noch kein Urteil (GameController war schneller) → zurückhalten, bis das Urteil kommt; spätestens nach
    40 ms durchlassen. Solange etwas zurückgehalten wird, warten alle späteren Ereignisse von GameController
    dahinter, damit die Reihenfolge stimmt (ein Stick-Ausschlag überholt nie einen Tastendruck).
- **Loslassen von GameController:** Gehört die Taste dem Paddle, verschlucken und den Merker löschen; sonst
  durchlassen. Nur was beim Drücken verschluckt wurde, wird beim Loslassen verschluckt; so bleibt keine Taste
  im Erkenner hängen. Beispiel: A von Hand gehalten, dann das A-Paddle gedrückt und wieder losgelassen —
  GameController meldet dabei gar nichts, und das spätere Loslassen von A geht normal durch.
- **Mehrere Paddles:** Urteile gelten je Taste, also stimmen auch 0 → 3 (zwei Paddles in einem Bericht) und
  der gemessene Fall „Paddle-Bit 4 los, Bit 2 dazu, A los, Y gedrückt“ im selben Bericht.
- **Ohne HID-Paddles** (kein Elite, keine Berechtigung, USB, Notbremse aus) ist die Weiche ein Durchgang:
  kein Zurückhalten, keine Verzögerung. Ereignisse vom DualSense oder einem anderen Gerät laufen immer direkt
  durch (`origin.family != .xbox`).
- `reset()` (Trennung, Ruhezustand, Pause des Systems, Ausschalten) löscht Merker, Urteile und Zurückgehaltenes.
- Zeit: Was zurückgehalten war, geht mit der Uhrzeit des Durchlassens in den Erkenner, nie mit einer älteren
  (der Erkenner verträgt keine rückwärts laufende Zeit). Die Verzögerung liegt nach der Messung bei 0 bis
  3 ms, schlimmstenfalls 40 ms, und nur bei Xbox-Controllern mit lesbaren Paddles.
- Trigger und Sticks hält die Weiche nie zurück. Legt jemand im Controller-Profil ein Paddle auf einen
  Trigger oder Stick, wirkt das wie heute zusätzlich; die Doku rät, Paddles auf Gesichtstasten oder auf
  „nicht belegt“ zu lassen.

Warum nicht nur ein Zeitfenster: Ein reines „Taste innerhalb von x ms nach einem Paddle-Bit verschlucken“
müsste raten, welche Taste gemeint ist, und verschluckte einen echten Druck, der zufällig zugleich kommt. Das
HID-Urteil nennt die Taste genau. Warum nicht alle Tasten aus HID lesen: Dann hinge die ganze Belegung an
einer selbst gepflegten HID-Tabelle je Modell und Firmware; GameController bleibt die eine Quelle für die
Bedienung, HID liefert nur Paddles und Urteile.

**Debug-Kanal.** `whisperm8 debug controller state` zeigt zusätzlich: Familie, Paddle-Quelle (Zustand,
Grund), letzte Maske, Zahl der verschluckten Tasten, Zahl der Zurückhaltungen und deren längste Dauer.
`press paddleUpperLeft` usw. geht ohne Änderung über `ControllerButton.allCases`. Neu im Skript:
`hid:<maske>[+<taste>]` speist einen HID-Bericht ein, damit die Weiche in der Test-Instanz durchgespielt werden
kann.

## HID-Quelle und Berechtigung

- **Abgleich nur auf Gamepads:** `IOHIDManagerSetDeviceMatchingMultiple` mit VendorID `0x045E` **und**
  `DeviceUsagePage` 1 / `DeviceUsage` 5 (GamePad), zusätzlich 4 (Joystick). Nie nur nach VendorID wie im
  Testwerkzeug: Microsoft baut auch Tastaturen und Mäuse, und das Öffnen einer Tastatur löst die Rückfrage
  nach „Eingabeüberwachung“ aus. SDL filtert aus genau diesem Grund nur Joystick, GamePad und
  MultiAxisController.
- **Paddles erkannt**, wenn das Gerät ein Element Seite `0x0C` Usage `0x81` hat
  (`IOHIDDeviceCopyMatchingElements`). Series X|S (PID `0x0B12` USB, `0x0B13` BLE) und andere Modelle ohne
  dieses Element: Quelle bleibt still, Zustand „keine Paddles“. Elite Series 2 über Bluetooth Classic (PID
  `0x0B05`, ältere Firmware) und USB (`0x0B00`): wird nach Element erkannt, nicht nach PID. Über USB spricht
  der Controller vermutlich GIP über Apples eigenen Treiber und erscheint gar nicht als HID-Gerät; dann
  „Paddles nicht lesbar“ und Rückfall. Elite Series 1 hat Paddles ohne Bluetooth; gleiches Vorgehen.
- **Öffnen ohne Vereinnahmen:** `kIOHIDOptionsTypeNone`, nie `SeizeDevice` (sonst sähe GameController nichts
  mehr). Nur gelesen, nichts gesendet. Keine Dateideskriptoren (Mach-Ports), die Close-on-exec-Regel betrifft
  die Quelle also nicht; geprüft wird das im Bau trotzdem mit `lsof` an einer laufenden Test-Instanz.
- **Berechtigung.** Tastaturen über IOHID brauchen ab macOS 10.15 „Eingabeüberwachung“ (TCC
  `ListenEvent`), reine Gamepads nicht. Ein Unity-Mitarbeiter berichtet allerdings, dass gerade der Elite als
  Gamepad **und** Tastatur auftritt und dann die Berechtigung braucht. Der Messlauf heute ist kein Gegenbeweis:
  Das Werkzeug lief in einem WhisperM8-Chat, verantwortlicher Prozess war also vermutlich WhisperM8 selbst, und
  ob WhisperM8 die Berechtigung schon hat (Tastatursperre mit Event-Tap), ist unklar. Deshalb:
  - Beim Start `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` lesen und loggen; **nie** von selbst
    `IOHIDRequestAccess` aufrufen (keine Rückfrage aus dem Nichts).
  - `IOHIDManagerOpen` mit `kIOReturnNotPermitted` oder ein Elite ohne jeden `0x81`-Wert nach einem erkannten
    Paddle-Doppel (Weiche sieht Gesichtstasten ohne Urteil) → Zustand „Paddles nicht lesbar“.
  - Rückfall: Die Weiche wird zum Durchgang, Paddles wirken als die Gesichtstasten ihres Profils (wie heute).
  - Einstellungsseite: Zeile „Paddles: not readable“ mit Knopf „Allow in System Settings…“, der auf Klick
    `IOHIDRequestAccess` aufruft bzw. `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`
    öffnet. Erst nach einem Neustart der App wirksam; das sagt der Text.
- **Notbremse** `controllerPaddleHIDEnabled` (Standard an): aus heißt kein `IOHIDManager`, Rückfall wie oben.
  Eintrag in `PreferenceBedienweg.killSwitches` und in der Kill-Switch-Liste der `CLAUDE.md`.
- Läuft nur, solange die Controller-Steuerung läuft und ein Xbox-Controller verbunden ist (Start beim
  Verbinden, Stopp beim Trennen und Ausschalten). Im Ruhezustand kein Zeitgeber, kein Abfragen.
- Signposts nur für Start und Öffnen (`controller.hidOpen`), nicht je Bericht; Zähler (`PerformanceCounters`)
  für Berichte, Urteile, Zurückhaltungen.

## Einstellungen › Controller

Neuer Abschnitt **„Paddles“** zwischen „Behavior“ und der Belegung:

- Zustandszeile (aus `ControllerStatus.device.paddles`): „Paddles detected“ (grün) / „No controller with
  paddles connected“ (aus) / „Paddles not readable — they act as the buttons of the controller profile“ (gelb,
  mit Knopf zur Freigabe, siehe oben).
- Vier Zeilen „Upper left“, „Lower left“, „Upper right“, „Lower right“, je ein `Picker` mit der festen Liste,
  gebunden per `@AppStorage(PreferenceKeys.controllerPaddleUpperLeft)` usw.; `onChange` ruft
  `applyPreferences()`.
- „Reset to defaults“.
- Hilfetext: „Paddles act only in WhisperM8, with a single press. Leave them on A, B, X, Y in the controller
  profile — WhisperM8 ignores that button when it knows the paddle.“
- Der Abschnitt steht immer da (Labs-Seite, kein zusätzlicher Merker); siehe offene Frage 3.

**Tasten-Test:** `noteButton` meldet `.press(.paddleX)` wie jede Taste; die Zeile zeigt „P3 · Upper left
paddle“. Weil die Gesichtstaste verschluckt wird, erscheint dort das Paddle und nicht A. Im Rückfall erscheint
A — der Test zeigt also zugleich, ob HID wirkt. Mit Xbox heißt die Zeile „A button“ statt „Cross“.

**PreferenceKeys** (in `AppPreferences.swift`): `controllerPaddleUpperLeft`, `controllerPaddleLowerLeft`,
`controllerPaddleUpperRight`, `controllerPaddleLowerRight` (String, Rohwert von `ControllerPaddleBinding`),
`controllerPaddleHIDEnabled` (Bool, Notbremse). Zugriff über `AppPreferences.paddleBindings`
(`ControllerPaddleBindings`, fehlende oder unbekannte Werte → Standard). `PreferenceBedienwegGuardTests` findet
die vier Belegungen über die `@AppStorage`-Bindungen der neuen Settings-Datei; nur die Notbremse kommt in die
Liste.

## Lokalisierung

Neue UI-Texte englisch, deutsch in `Localizable.xcstrings` (`LocalizationCatalogTests`): Abschnitt und
Zeilen der Paddles, die zwölf Belegungen, Zustände, Freigabe-Knopf, Hilfetext, Xbox-Pairing, Tasten-Namen
(„A button“, „Left bumper“, „Upper left paddle (P3)“ …), die umgebauten Erklärtexte mit Platzhaltern.
Unübersetzt bleiben A, B, X, Y, LB, RB, LT, RT, LS, RS, View, Menu, P1–P4, `/workflows`, `/tasks`. Keine
Ternär-Literale in `Text(…)`; Picker-Titel über `String(localized:)`.

## Tests

- `ControllerFamilyTests`: Einordnung nach Kategorie-Text, `hasTouchpad`.
- `ControllerPaddleGateTests` (Kern der Arbeit): HID vor GameController; GameController vor HID (Zurückhalten,
  Urteil löst sofort); Urteil bleibt aus (40-ms-Frist, Durchlassen mit Frist-Zeit); direkter A-Druck ohne
  Paddle bei Elite (keine Verzögerung über das Urteil hinaus); zwei Paddles in einem Bericht; Wechsel
  Paddle → Paddle in einem Bericht (gemessene Folge aus `probe2.txt` als Tabelle nachgespielt); A von Hand
  gehalten plus A-Paddle; Loslassen nur, was beim Drücken verschluckt wurde; Reihenfolge Stick hinter
  zurückgehaltenem Druck; DualSense-Ereignisse nie zurückgehalten; ohne HID reiner Durchgang; `reset` mitten
  im Zurückhalten; Urteile verfallen; `nextDeadline`.
- `XboxPaddleBitsTests`: Bit ↔ Lage, Maske → Ereignisse bei Kombinationen.
- `ControllerGestureRecognizerTests`: Paddle = `.press`, kein Halten, in der Ebene `.inLayer` und Ebene benutzt.
- `ControllerBindingResolverPaddleTests`: Matrix Belegung × Zusammenhang (Tabelle oben), `wakes` false,
  Pause aus `.paused`, Ebene → nil, Aufnahme → nil.
- `ControllerActionDispatcherPaddleTests` (Spies aus `ControllerDispatcherTestSupport`): nächster wartender
  Chat; Antworten mit Rückfrage (nur Sprung, kein Diktat), ohne Rückfrage (Sprung + Diktat), Wechsel
  gescheitert (kein Diktat); Jetzt senden je Zeile der Tabelle inklusive Shell und Rückfrage; Modus wechseln
  arbeitend/Rückfrage; `/workflows` in Codex abgelehnt; gemeinsame Funktion mit R1 + ✕ (bestehende
  Runde-5-Tests bleiben grün).
- `ControllerLegendTests`: Xbox ohne Touchpad-Einträge; Belegungsübersicht je Familie.
- `ControllerManagerTests`: Belegung aus den Einstellungen zwischengespeichert, nach `applyPreferences` neu.
- `ControllerDebugScriptTests`: `hid:`-Schritt.
- Quelltext-Guard: kein `IOKit` in `Services/Controller/Core` (`ControllerCoreImportGuardTests` deckt das schon
  ab, weil nur Foundation erlaubt ist).
- `PreferenceBedienwegGuardTests`, `LocalizationCatalogTests`, `SourceSizeGuardTests`,
  `ChatsFontSizeGuardTests` laufen mit.

## Snapshots

`make snapshots ONLY=controller` bekommt Xbox-Fassungen (Umgebungswert `controllerFamily` im Fixture):
Einstellungsseite mit Xbox Elite (Paddles erkannt; nicht lesbar mit Freigabe-Knopf; ohne Paddle-Controller),
Legende im Chat und in der Liste mit A B X Y, Menü. `ONLY=controller-insel`: R1-Raute mit A B X Y, L2 „Wohin“
ohne Touchpad-Fußzeile, L1, je einmal als Pille. `ONLY=clipboard-verlauf-controller`: Fußzeile mit Xbox. Nach
jeder Ansichtsänderung rendern und ansehen, hell und dunkel.

## Doku

`docs/features/controller.md`: Einleitung (Referenzgeräte DualSense und Xbox Elite), Abschnitt „Xbox“
(Namen, kein Touchpad, Pairing), Abschnitt „Paddles“ (Standardbelegung, Auswahl, nur in der App, nicht in
Ebenen und Aufnahme, Weiche, Rückfall, Berechtigung, Notbremse), Aufbau-Tabelle (HID-Quelle, Weiche),
Prüfen (neue Filter, Snapshots, Debug), Grenzen (USB ohne Paddles, Profil auf Trigger/Stick, zwei Xbox
gleichzeitig, DualSense Edge). Danach den Satz „Umbelegen gibt es noch nicht“ auf „nur die Paddles sind
umbelegbar“ ändern. Nutzer-Doku der Einstellungsseite, falls `testUserGuideSettingsPagesExist` das verlangt.
`docs/plans/README.md` führt diesen Plan.

## Handtests (nach `make dev` durch den Nutzer)

- **H1 Gerätetest vor dem Feinbau** (nach Commit 5, Debug-Ausgabe): Elite verbinden; `debug controller state`
  zeigt Familie xbox, Paddles erkannt, Zugriffsstatus. Jede Gesichtstaste, LB, RB, View, Menu, LS, RS drücken
  und die HID-Usages ablesen (Tabelle `XboxHIDButtons`). Reihenfolge HID/GameController und längste
  Zurückhaltung ablesen.
- **H2 Paddle-Lage:** Tasten-Test der Einstellungen, jedes Paddle einzeln: zeigt „Upper left paddle“ usw.
  an der richtigen Stelle, nie zusätzlich A/B/X/Y. Bei Abweichung nur `XboxPaddleBits` ändern.
- **H3 Kein Enter durch das Paddle:** Im ruhenden Claude-Chat mit Text im Feld das Paddle „Modus wechseln“
  (liegt auf A oder einer anderen Gesichtstaste): Modus wechselt, nichts wird gesendet.
- **H4 Standardbelegung:** zwei Chats wartend → oben links springt reihum; unten links springt, diktiert nicht
  in die Rückfrage; oben rechts in allen Zeilen der Tabelle (arbeitend mit Text → Jetzt senden, ruhend leer →
  „Weiter“, arbeitend leer → drei Ticks, Rückfrage → drei Ticks, Shell → drei Ticks); unten rechts im
  ruhenden Chat und in einer Rückfrage.
- **H5 Umbelegen:** jede Auswahl einmal, „Nothing“, „Reset to defaults“; Änderung wirkt sofort.
- **H6 Außerhalb der App:** Paddle mit Hintergrund-Empfang an: nichts passiert, WhisperM8 kommt nicht nach
  vorn, auch die Gesichtstaste weckt nicht. Pause-Paddle wirkt.
- **H7 Zwei Controller:** DualSense und Elite verbunden; abwechselnd eine Taste: Legende, Insel und
  Einstellungen wechseln die Namen; DualSense-Eingaben ohne Verzögerung.
- **H8 Berechtigung:** Ist WhisperM8 unter Datenschutz › Eingabeüberwachung eingetragen, Eintrag
  ausschalten, App neu starten: Zustand „nicht lesbar“, Paddles wirken als A/B/X/Y, keine Rückfrage beim
  Start. Wieder einschalten: Paddles erkannt. Zusätzlich das Testwerkzeug einmal aus Terminal.app starten
  (anderer verantwortlicher Prozess) und `IOHIDCheckAccess` notieren.
- **H9 Trennen mitten im Druck:** Paddle halten, Controller ausschalten: keine hängende Taste.
- **H10 Series X|S** (falls vorhanden): Namen Xbox, kein Paddle-Abschnitt aktiv, keine Verzögerung.

## Risiken

| Risiko | Folge | Gegenmittel |
|---|---|---|
| Elite meldet sich auch als Tastatur, signierte App braucht „Eingabeüberwachung“ | Paddles nicht lesbar | Rückfall auf Gesichtstasten, Zustandszeile mit Freigabe-Knopf auf Klick, nie automatische Rückfrage; H8 |
| Reihenfolge HID/GameController in der App anders als im Werkzeug | sonst verrutschte Taste | Weiche entscheidet nach Urteil, nicht nach Reihenfolge; Zurückhalten mit 40-ms-Frist |
| Urteil kommt nie (HID-Bericht verloren) | Paddle-Taste ginge nach 40 ms als A durch | Zähler im Debug-Kanal; selten; dieselbe Wirkung wie heute |
| HID-Usages für LB/RB/… anders als angenommen | Paddle auf Schultertaste wird nicht verschluckt | H1 misst nach; unbekannte Usages ergeben kein Urteil, dann gilt die Frist |
| Firmware-Update ändert `0x81`-Bericht | Paddles weg | Erkennung nach Element, Rückfall automatisch |
| Profil legt Paddle auf Trigger/Stick | zusätzliche Wirkung | dokumentiert, Empfehlung Gesichtstasten |
| Zwei Xbox-Controller gleichzeitig | Urteile lassen sich nicht sicher einem Gerät zuordnen | dokumentierte Grenze; Paddles nur am ersten Elite |
| macOS-Gesten auf Xbox-Taste/Share | Konflikt | beide bleiben unbelegt |
| Konflikte mit Pille und Runde 5 in `ControllerIslandView`, `ControllerLabels`, Dispatcher | Merge-Aufwand | Reihenfolge unten; Zeichen-Umbau erst nach der Pille |

## Reihenfolge der Commits

Basis: `feat/controller-xbox` von `main`. Vor Schritt 2 `git merge main` mit der gemergten Pille, vor Schritt 4
mit dem gemergten Runde-5-Stand (mindestens bis „Jetzt senden“ und Befehle-Menü). Nach jedem Schritt
`swift build` und `swift test --filter Controller`, vor dem letzten die volle Suite. Kein `make dev` aus dem
Chat; Commits per Pfadangabe.

1. `docs(controller): Bauplan für Xbox-Namen und Paddles` — dieser Plan.
2. `feat(controller): Xbox-Controller mit eigenen Tastennamen` — Familie, Gerät der letzten Eingabe,
   `glyph(_:)`/`displayName(_:)`, Umgebungswert, Legende ohne Touchpad bei Xbox, Texte mit Platzhaltern,
   Pairing; Snapshots Xbox.
3. `feat(controller): Paddles als eigene Tasten im Kern` — `ControllerButton`-Fälle, Belegungsliste,
   Resolver mit Paddle-Matrix, neue Aktionen (Ausführer noch „geht nicht“), Debug `press paddle…`.
4. `feat(controller): Paddle-Aktionen ausführen` — `+Paddles` im Ausführer, `sendOrContinue` mit der R1-Raute
   geteilt, Antworten, Modus, Befehle.
5. `feat(controller): Weiche gegen die doppelte Taste der Paddles` — `ControllerPaddleGate` mit Tests,
   Pumpe, Herkunft der Ereignisse.
6. `feat(controller): Paddles des Xbox Elite über IOHID lesen` — `XboxPaddleHIDSource`, Notbremse,
   Zugriffsprüfung, Debug-Zustand und `hid:`-Schritt. **Halt: H1 und H2 durch den Nutzer**, danach
   `XboxHIDButtons`/`XboxPaddleBits` nachziehen.
7. `feat(controller): Paddles in den Einstellungen belegen` — Abschnitt, Picker, Zustandszeile, Freigabe-Knopf,
   PreferenceKeys, Tasten-Test; Snapshots.
8. `docs(controller): Xbox und Paddles beschrieben` — Feature-Doku, `CLAUDE.md`-Notbremse, Plan-Index.

Danach „bereit für make dev“ mit Branch und Commit, dann H1–H10.

## Offene Fragen

1. **Was heißt „Antworten“?** „Wartet“ bedeutet in WhisperM8 immer „ein Dialog ist offen“. Wörtlich
   genommen springt „Antworten“ deshalb nur und diktiert nie, wäre also dasselbe wie das Paddle oben links.
   **Empfehlung:** „Antworten“ geht zuerst zum nächsten Chat, der frisch fertig ist (ruht, Turn in den
   letzten 15 min beendet, nicht der aktuelle; dieselbe Einteilung wie Notch und `chats`-Board,
   `AttentionModelBuilder`) und diktiert dort. Gibt es keinen, springt es zum nächsten wartenden Chat, nur
   springen. Ist der aktuelle Chat der einzige Kandidat und ruht er, diktiert es hier.
2. **Share-Taste der Xbox Series X|S** (beim Elite nicht vorhanden): als Touchpad-Ersatz für den Verlauf
   belegen? **Empfehlung:** nein, frei lassen wie Create doppelt/lang; macOS nutzt sie für Bildschirmfotos.
   Der Verlauf ist über Menü und Paddle erreichbar.
3. **Paddle-Abschnitt immer zeigen?** **Empfehlung:** ja, auf der Labs-Seite stört er nicht, und die
   Zustandszeile erklärt sich selbst; ein Merker „Paddles je gesehen“ wäre ein weiterer Schlüssel ohne Nutzen.
4. **Paddles in der Legende?** **Empfehlung:** nein (Entscheidung 9). Wer die Belegung vergisst, findet sie in
   den Einstellungen; die Legende bleibt kurz. Alternative: ein Eintrag „P1–P4: Paddles“ ohne Einzelheiten.
5. **`generic`-Controller** (8BitDo, Switch Pro): bleiben bei PlayStation-Zeichen. **Empfehlung:** so lassen,
   bis ein solches Gerät wirklich benutzt wird.
6. **DualSense Edge:** zwei Rücktasten (und zwei Fn-Tasten) liefert GameController über
   `physicalInputProfile` (`GCInputLeftPaddle`, `GCInputRightPaddle`). **Empfehlung:** nicht in diesem Bau;
   die Paddle-Belegung ist so gebaut, dass zwei weitere Lagen später ohne Weiche dazukommen (GameController
   meldet dort keine doppelte Taste, das wäre zu messen).

## Quellen

- SDL, „hidapi/mac: Only enumerate IOHIDDevices that are likely to be joysticks“ (Tastatur-Usages lösen ab
  macOS 11 die Rückfrage aus; Filter auf Joystick, GamePad, MultiAxis):
  https://discourse.libsdl.org/t/sdl-hidapi-mac-only-enumerate-iohiddevices-that-are-likely-to-be-joysticks/43964
- Unity Discussions, „Xbox Controller not working on macOS“ (Elite als Gamepad und Tastatur, braucht dann
  Eingabeüberwachung): https://discussions.unity.com/t/xbox-controller-not-working-on-macos/932929
- OpenEmu Wiki, „Troubleshooting: Input problems“ (Eingabeüberwachung betrifft auch Controller):
  https://github.com/OpenEmu/OpenEmu/wiki/Troubleshooting:-Input-problems

## Nachtrag 12.11.2026: Xbox-Knopf = Zwischenablage-Verlauf

Gemessen am Elite 2 (BLE, Firmware 5.21): Der runde Xbox-Knopf kommt über GameController nicht an,
auch nicht mit `preferredSystemGestureState = .disabled` („Button Home“ ist im Profil vorhanden, meldet aber
keinen Druck). In den rohen HID-Daten erscheint er als Tastenseite 0x09, Usage 0x0D (Druck 1, Loslassen 0).
macOS tut mit dem Knopf sonst nichts. Der kleine Profil-Knopf darunter meldet Consumer 0x0C/0x85 (Profil 0–3)
und gehört dem Controller; er wird nicht belegt.

Freigegeben vom User: Der Xbox-Knopf öffnet und schließt den Zwischenablage-Verlauf, wie das Touchpad am
DualSense. Er läuft über denselben HID-Leser wie die Paddles (nur Microsoft-Gamepads). Ohne HID-Zugriff hat er
keine Wirkung; die Einstellungen sagen das in der Zustandszeile. View (Create) und Menu (Options) bleiben, wie sie sind.
