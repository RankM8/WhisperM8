---
status: umgesetzt, wartet auf make-dev-QA; vereinte Pille neu (12.11.2026, Kill-Switch unifiedPillEnabled)
stand: 2026-11-12
feature: Statusanzeige an der Notch und vereinte Pille
---

# Statusanzeige an der Notch

Eine kleine Anzeige an der MacBook-Notch (auf einem Bildschirm ohne Notch eine
dunkle Pille, die immer dasteht) zeigt, wie es den Agent Chats geht: wie viele arbeiten,
wie viele auf dich warten, wie viele gerade fertig wurden. Wer woanders
arbeitet, sieht auf einen Blick, ob er gebraucht wird, und springt mit einem
Klick in den passenden Chat. Prototyp der Zustände:
[`../design/notch-prototype.html`](../design/notch-prototype.html).

Standardmäßig **an** (seit 05.11.2026, vorher aus).

## Vereinte Pille (Standard seit 12.11.2026)

Diktat-Pille und Status-Pille sind eine Pille. Entwurf mit allen Zuständen und
den 13 beantworteten Fragen: Branch `docs/pille-vereint-entwurf`,
`docs/design/pille-vereint.html`. Abweichung von Frage 13: Ein Klick auf den
ruhenden Kern startet ein Diktat (derselbe Weg wie der Hotkey), ein Klick auf
die Zähler oder den Rest der Pille öffnet die Liste.

**Was sie zeigt, immer nur eins** (`UnifiedPillPriority`): Insel vor Diktat vor
offener Liste vor Hinweis „braucht dich“ vor Ruhe mit Zählern.

| Zustand | Ohne Notch | Mit Notch |
|---|---|---|
| Ruhe | Pille oben mittig: Kern als stille graue Linie, rechts die Zähler | wie bisher: Zähler unter der Notch, nichts los = nichts zu sehen |
| Hinweis | Kern, Punkt, Chat-Name, Wort, „+ n“, einmal ca. 4 s | wie bisher |
| Liste | wächst aus der Pille, Pillen-Zeile bleibt stehen; unten „Status in der Pille ausblenden“ | wie bisher |
| Diktat | die Diktat-Pille an der Stelle der Pille, links Raute bzw. Ring für wartende Chats und Fehler | die Diktat-Zeile hängt schwarz unter der Notch, Raute links |
| Insel | wächst aus der Pille | wächst aus der Notch |

**Aussehen:** Die Pille in Ruhe, beim Hinweis und mit Liste ist gezeichnet wie
die Diktat-Pille: 40 pt hoch, Kapsel, `PillGlassBackground` (dünnes Material,
Tönung `OverlayPalette.glassTint`, 0,5-pt-Rand Weiß 14 %), im Fenster
gezeichneter Schatten (`pillGlassShadow`, Schwarz 30 %, Radius 12, 3 pt nach
unten), Schrift 12,5 pt. Kein Fensterschatten mehr (der brachte den hellen
Rand und die weiche Kante, die die Diktat-Pille nicht hat). Dafür hat das
Fenster wie die Diktat-Pille einen Rand von 24 pt für den Schatten; nur die
Pille selbst nimmt Klicks an (`NotchHostingView.hitTest`), der Rand ist
durchsichtig. Wie bei der Diktat-Pille fängt der Schattenhof dicht an der
Pille Klicks ab (die Fensterverwaltung reicht nur völlig durchsichtige Pixel
weiter). Der ruhende Kern (`PillRestCoreView`) hat die Maße des Diktat-Kerns
(28 pt hoch, mindestens 46 pt breit, fünf Balken), grau und flach.

**Wo sie steht:**

- Ohne Notch auf dem Bildschirm des Agent-Chats-Fensters (ohne Fenster auf
  dem Hauptbildschirm), oben mittig unter der Menüleiste oder an der
  gemerkten Lage dieses Bildschirms (`notchPillPositions`, Display-UUID).
  Die Einstellung „Bildschirm“ (`notchStatusScreen`) gilt nicht mehr.
- Ein Diktat erscheint dort, wo du tippst: Bildschirm des vorderen Fensters
  (Fensterliste abseits des Main Threads, `FrontWindowLocator`, höchstens
  80 ms, sonst die Maus). Mit Notch an der Notch, sonst an der gemerkten Lage
  dieses Bildschirms, nur bis das Diktat fertig ist. Auf diesem Bildschirm
  tritt die Status-Pille so lange zurück (`UnifiedPillHub.dictationDisplayID`).
- Gemerkt wird nur echtes Ziehen (linke Maustaste gedrückt). Wird der
  Bildschirm des Diktats abgesteckt oder ändert er seine Maße, baut die
  Pille an neuer Stelle neu auf (Maus-Bildschirm, dort Notch oder gemerkte
  Lage), damit ✓ und ✕ sichtbar bleiben; das Diktat läuft weiter.
- An der Notch nimmt nur der Körper unter der Menüleiste Klicks und
  Darüberfahren an, nicht das Band über der Aussparung.
- Die alte Lage der Diktat-Pille (`overlayAnchor…`, unten mittig) bleibt
  gespeichert, wird aber nicht benutzt; mit dem Kill-Switch gilt sie wieder.

**Bewegung:** Zustandswechsel wachsen um die Mitte (eine Kurve, 0,35 s). Nur
das Darüberfahren beim Diktat (Mini) klappt nach links auf, die rechte Kante
bleibt (`UnifiedPillGeometry.centerGuide`, über eine Ausrichtungslinie im
selben Layout-Durchgang, ohne Fensterbewegung). Am Bildschirmrand wird zur
Mitte hin verschoben. Wächst die Pille beim Darüberfahren weiter (Kontext
kommt dazu), bleibt sie ganz im Fenster. An der Notch ist nichts verschiebbar (kein Griff),
alles wächst um die Mitte der Notch.

**Bedienung:** Klick auf den grauen Kern startet ein Diktat
(`AppState.startRecording()`, wie der Hotkey), Klick auf den Rest öffnet die
Liste, ab 4 pt Bewegung wird gezogen. Doppelklick auf die Fläche außerhalb
des Kerns setzt oben mittig zurück; ein Doppelklick auf den Kern startet nur
das Diktat (der erste Klick), der zweite Klick tut dann nichts mehr, auch
nicht an der Diktat-Pille, die inzwischen erscheint. Beim Diktat bleibt
alles wie bei der Diktat-Pille mit der Maus bedienbar (✓, ✕, Modus, Kontext).
Hotkey „Statusliste öffnen“ (`openNotchStatusList`, ab Werk ohne Belegung):
Liste mit Tastaturfokus, Pfeile wählen, Return springt in den Chat, Esc
schließt.

**Hinweis beim Diktat:** Kommt währenddessen ein „braucht dich“, verbreitert
sich die Pille dort nicht, die Raute erscheint links. Wartet der Chat nach dem
Diktat noch, kommt die Verbreiterung einmal nach (`alertDuringDictation`).

**Menüs und Listen:** In der oberen Bildschirmhälfte nach unten, in der
unteren nach oben (Statusliste, Insel, Liste der Ausgabemodi am Controller;
die Menüs von Modus und Kontext legt macOS selbst passend).

**Vollbild:** In Ruhe ausgeblendet, Diktat und Insel erscheinen trotzdem.
**Aus Bildschirmfotos ausblenden** gilt für die ganze Pille, auch das Diktat.
**Status aus:** Die Pille erscheint nur beim Diktat und für die Insel.

**Technik:** Die Diktat-Logik ist unberührt (Coordinator, Aufnahme,
Auslieferung). `OverlayController` entscheidet nur, wo die Diktat-Pille steht
und wie sie aussieht (`OverlayPresentation`: `classic`, `pill`, `notch`,
`RecordingPanel+UnifiedPill.swift`). Die Status-Seite hängt in
`NotchStatusController+UnifiedPill.swift`. Beide treffen sich in
`UnifiedPillHub` (Bildschirm des Diktats, Raute); der Status übernimmt den
Bildschirm aus dem gemeldeten Wert, er liest den Hub dabei nicht erneut
(`@Published` meldet im willSet, dort stünde noch der alte Wert). Es bleiben getrennte
Fenster, von denen je Bildschirm immer nur eins sichtbar ist; so läuft das
Diktat weiter durch sein bewährtes Fenster.

### Kill-Switch der vereinten Pille

```bash
defaults write com.whisperm8.app unifiedPillEnabled -bool NO
```

Getrennte Diktat-Pille (unten mittig, eine Lage für alle Bildschirme) und
Status-Pille (Fensterschatten, Bildschirmwahl) wie vor dem 12.11.2026, die
Einstellungen stehen wieder an den alten Stellen. Wirkt für die Status-Pille
sofort, für das Diktat beim nächsten Erscheinen.

## Bedienung

| Zustand | Aussehen | Wie man hinkommt |
|---|---|---|
| Ruhe | Die Notch wird ein Stück länger, darunter grüner Punkt mit Zahl (arbeitet), Amber-Raute (wartet), roter Ring (Fehler), Häkchen (frisch fertig) | Mindestens ein Chat arbeitet, wartet, hat einen Fehler oder wurde frisch fertig |
| Braucht dich | Die Zeile unter der Notch verbreitert sich einmal kurz (ca. 4 s) und zeigt den Chat-Titel mit „wartet", „Fehler" oder „fertig", bei mehreren „+n" | Ein bekannter Chat wechselt nach `awaitingInput` oder `errored`, oder von `working` nach `idle` |
| Aufgeklappt | Liste nach Aufmerksamkeit: Braucht dich, Frisch fertig, Arbeitet, Bereit | Klick auf den Streifen (optional Darüberfahren) |
| Ausgeblendet | nichts | An der Notch: nur bereite Chats, nichts Aktives. Überall: Funktion aus oder Vollbild-App im Vordergrund. Die Pille ohne Notch bleibt sonst immer stehen (siehe unten) |

- Eine Zeile zeigt Status-Punkt (gleiche Formen wie `AgentStatusIndicator`:
  Scheibe, Raute, Ring), Titel, Stand-Zeile („› Edit Store.swift"), Projekt
  und Dauer („arbeitet · 2 min"). Wörter und Dauer kommen aus
  `TabSwitcherTileModel`, also dieselben wie im Tab-Switcher.
- Klick auf eine Zeile bringt das WhisperM8-Fenster nach vorn und öffnet genau
  diesen Chat (`WindowRequestCenter.requestSessionFocus`, derselbe Weg wie der
  Klick auf eine Benachrichtigung).
- Zuklappen: Esc, Klick daneben (auch in anderen Apps), Klick auf den Kopf,
  Fenster verliert den Fokus. Alles ist auch ohne Hover erreichbar; Hover
  öffnet höchstens zusätzlich. Ein Klick auf eine per Darüberfahren geöffnete
  Liste klappt sie nicht zu, sondern hält sie fest wie nach einem Klick
  (Wegfahren schließt dann nicht mehr, Esc wirkt); der nächste Klick schließt.
- „Amber bleibt": Der Zähler für wartende Chats steht, bis der Chat wieder
  arbeitet. Nur die Verbreiterung ist einmalig.
- Frisch fertig gilt 15 Minuten (`AttentionModelBuilder.freshDoneWindow`,
  dieselbe Grenze wie `whisperm8 chats`). Danach wird der Chat „bereit".
- Die Verbreiterung für „fertig" bleibt aus, solange WhisperM8 die aktive App
  ist (man sieht den Status dort ohnehin). „Wartet" und „Fehler" melden sich
  immer.
- Die Verbreiterung endet vorzeitig, sobald ihr Anlass weg ist: der Chat
  arbeitet wieder, wurde gelöscht oder archiviert.

### Lage an der Notch: Menüleiste bleibt frei

In der Menüleiste belegt die Anzeige nur die Aussparung selbst: ein schwarzes
Band genau in Notch-Breite (sie ist ohnehin schwarz). Zähler, Chat-Name und
Liste hängen darunter (`NotchGeometry.layout`, Teile `band` und `body`).
Menüs links und Statussymbole rechts der Notch werden nie verdeckt, auch nicht
beim Alarm oder in der Liste. Im Ruhezustand ist das ganze Fenster genau so
breit wie die Notch, es berührt die Menüleiste daneben also gar nicht. Beim
Alarm und in der Liste ist der Körper breiter; dann liegt das Fenster zwar über
einem Stück Menüleiste, dort ist es aber vollständig transparent: Der Window-Server reicht Klicks auf transparente Pixel eines nicht
deckenden Fensters an das Fenster darunter weiter. Deshalb wird
`ignoresMouseEvents` nie gesetzt (ein ausdrückliches `false` ließe das
Fenster auch dort Klicks annehmen).
Band und Körper gehen mit kleinen Hohlkehlen ineinander über
(`NotchHangingShape`).

### Ohne Notch: die Pille

Auf einem Bildschirm ohne Notch steht die Anzeige als Pille da, und zwar
**immer**, wie die Notch am MacBook: auch wenn gerade nichts los ist (dann nur
ein ruhiger grauer Punkt). Sie sieht genauso aus wie die Diktat-Pille: gleiche
Höhe (40 pt), Kapsel, dunkles Glas mit feinem hellem Rand (`PillGlassBackground`,
aus der Diktat-Pille herausgezogen, deren Aussehen unverändert blieb), Schrift
12,5 pt, immer dunkel, egal ob hell oder dunkel eingestellt ist. Aufgeklappt
wird daraus ein abgerundetes Rechteck mit halber Pillenhöhe als Radius.

Welcher Bildschirm (`NotchPillPlacement.placements`, Entscheidung vom 12.11.2026):

- An der Notch bleibt alles wie bisher: Der gewählte Bildschirm
  (Einstellung „Bildschirm“) zeigt die Anzeige an der Notch, wenn er eine hat.
- Die Pille steht auf dem Bildschirm des Agent-Chats-Fensters (das zuletzt
  aktive), wenn der keine Notch hat. Zieht man das Fenster auf einen anderen
  Bildschirm, wandert die Pille mit.
- Gibt es kein Agent-Chats-Fenster (oder liegt es an der Notch) und hat der
  gewählte Bildschirm keine Notch, steht die Pille dort.
- Also höchstens zwei Stellen: MacBook mit externem Bildschirm und Agent Chats
  auf dem externen zeigt die Notch am MacBook und die Pille auf dem externen.
  Nie zwei Pillen.

Die Liste öffnet sich immer nur an einer Stelle; ein Klick auf die andere
klappt sie dort zu und hier auf. Der „braucht dich“-Hinweis erscheint an beiden.

**Verschieben:** Wie die Diktat-Pille lässt sich die Pille mit der Maus an jede
Stelle ihres Bildschirms ziehen; die ganze Pille ist Zieh-Fläche. Unter 4 pt
Bewegung zählt es als Klick (Liste auf und zu), ab 4 pt wird gezogen. Sie
bleibt im sichtbaren Bereich des Bildschirms (ohne Menüleiste und Dock, wie die
Diktat-Pille). Die Stelle merkt sich jeder Bildschirm einzeln, über seine feste
Display-UUID (`CGDisplayCreateUUIDFromDisplayID`), nicht über die Nummer, und
als Anteil am Bildschirm, damit sie nach einem Auflösungswechsel passt. Ein
Doppelklick auf die Pille setzt sie oben mittig zurück (eine Liste, die der
erste Klick geöffnet hat, klappt dabei zu). Zurückgesetzt wird nur, wenn die
Pille vor dem ersten Klick zu war; zwei schnelle Klicks auf eine offene Liste
sind Zu und wieder Auf, die gemerkte Stelle bleibt. Ob ein Klick im Kopf liegt,
wird aus der Fensterhöhe im Moment des Klicks bestimmt
(`NotchPillPlacement.isInHeader`), damit der zweite Klick auch während der
Aufklapp-Animation ankommt. Bei offener Liste wird nicht gezogen: Ein Klick
auf den Kopf klappt sie zu, die Zeilen bleiben Knöpfe. Eine offene Liste an
der Notch des anderen Bildschirms hindert das Ziehen nicht. Sitzt die Pille in der unteren
Bildschirmhälfte, wächst die Liste nach oben und der Kopf bleibt unten, wo die
Pille war; oben wächst sie nach unten. Alles bleibt ganz auf dem Bildschirm.

Unterschieden werden Klick, Ziehen und Doppelklick am Event-Einstieg der
Hosting-View (`NotchHostingView.pillMouse`), wie bei der Diktat-Pille
(`PillHitTestHostingView`). Die Diktat-Pille zieht über
`isMovableByWindowBackground` und nur auf freier Fläche; hier ist die ganze
Pille zugleich Knopf (Liste auf und zu), deshalb führt die Hosting-View das
Fenster selbst mit der Maus mit und meldet einen Klick nur ohne Bewegung.

Die Controller-Insel wächst ohne Notch aus genau dieser Pille (siehe
[controller.md](controller.md)).

**Ausschalten direkt in der Notch:** Unten links in der aufgeklappten Liste
steht „Turn off notch“. Das setzt denselben Schalter wie die Einstellungen
(`notchStatusEnabled`). Wieder an über Einstellungen oder Menüleiste (oder
einen selbst belegten Hotkey; ab Werk hat er keine Belegung).

## Einstellungen

Vereinte Pille: Einstellungen, General, Abschnitt „Pille und Notch“
(`PillSettingsSection`), mit Verweisen aus Recording und Agent Chats. Dort:
Chat-Status in der Pille zeigen, Ausblenden aus Bildschirmfotos (ganze
Pille), Fertige Chats, Liste beim Darüberfahren, Lage zurücksetzen, Hotkeys
„Statusliste öffnen“ und Ein-/Ausblenden. Die Bildschirmwahl fällt weg.
Recording behält Voll/Mini (nur beim Diktat) und „Ausgabemodus beim Diktat
immer zeigen“ (`showModePickerInMiniOverlay`). Menüleiste: „Chat-Status in
der Pille“.

Mit Kill-Switch (getrennte Pillen): Einstellungen, Agent Chats, Tab Workspace,
Abschnitt „Notch Status" (`NotchSettingsSection`):

| Einstellung | Schlüssel | Standard |
|---|---|---|
| Chat-Status an der Notch anzeigen | `notchStatusEnabled` | an |
| Bildschirm: Automatisch, Eingebaut, Hauptbildschirm | `notchStatusScreen` | automatisch |
| In Screenshots und Bildschirmfreigabe ausblenden | `notchStatusHideFromCapture` | an |
| Fertige Chats anzeigen | `notchStatusShowFreshDone` | an |
| Liste beim Darüberfahren öffnen | `notchStatusExpandOnHover` | aus |
| Lage der Pille: „Zurücksetzen“ (alle Bildschirme oben mittig) | `notchPillPositions` | leer (oben mittig) |
| Hotkey zum Ein- und Ausblenden | `KeyboardShortcuts` `toggleNotchStatus` | ohne Belegung |

Auch im Menüleisten-Menü: „Chat Status at the Notch" (Schalter).

Bildschirmwahl „Automatisch": eingebauter Bildschirm mit Notch, sonst der
Hauptbildschirm. Sie gilt für die Anzeige an der Notch; die Pille folgt dem
Agent-Chats-Fenster, wenn dessen Bildschirm keine Notch hat (siehe oben). Hauptbildschirm heißt der mit der Menüleiste
(`CGMainDisplayID`), nicht `NSScreen.main` (das folgt dem Fokus). Die Anzeige
folgt Bildschirmwechseln (`NSApplication.didChangeScreenParametersNotification`),
die Wahl wird bis dahin zwischengespeichert.

Das Aufnahme-Verbergen setzt `NSWindow.sharingType = .none`. Das bittet macOS,
das Fenster aus Screenshots und Bildschirmfreigaben herauszuhalten. Klassische
Aufnahmen (`CGWindowList`, Bildschirmfoto) halten sich daran. Ob Apps auf
ScreenCaptureKit-Basis (Zoom, Teams, Meet, QuickTime) es unter macOS 15 und
neuer in jedem Fall tun, ist nicht belegt; Berichte sagen, nicht immer.
Untertitel und Doku versprechen deshalb nichts Absolutes. Handtest offen:
Bildschirm in Zoom oder Meet teilen, einen Chat auf „wartet“ bringen und auf
der Gegenseite prüfen, ob Streifen oder Titel sichtbar sind.

### Kill-Switch

```bash
defaults write com.whisperm8.app notchStatusFeatureEnabled -bool NO
```

Nimmt die Funktion komplett aus dem Betrieb: kein Fenster, keine Beobachter,
der Schalter in den Einstellungen und der Menüeintrag verschwinden, der Hotkey
tut nichts. Der Schlüssel steht als Notbremse in `PreferenceBedienweg.swift`.

## Datenfluss

```
AgentSessionRuntimeStatusStore.$statuses ──(throttle 300 ms)──┐
AgentWorkspaceUIModel.workspace (Titel, Projekt) ─────────────┤
AgentSessionActivityStore (statusSince; Stand-Zeile nur       │
  solange aufgeklappt) ───────────────────────────────────────┤
                                                              ▼
                          NotchInputBuilder  →  [NotchChatInput]
                                                              │
        NotchStatusModel (Zeilen, Rang, Zähler, Abschnitte) ◄─┤
        NotchAlertTracker (Auslöser, Abkühlzeit)            ◄─┘
                                                              │
                                   NotchStatusController ─────┘
                                     NotchPanel (NSPanel) + NotchStatusView
```

| Datei | Rolle |
|---|---|
| `Services/AgentChats/Notch/NotchStatusModel.swift` | Rein: Zeilen, Sortierung, Zähler, Abschnitte, Sichtbarkeit, `NotchAlertTracker` |
| `Services/AgentChats/Notch/NotchGeometry.swift` | Rein: Bildschirmwahl, Notch-Maße, Fenster-Rahmen je Zustand, Vollbild-Erkennung |
| `Services/AgentChats/Notch/NotchPillPlacement.swift` | Rein: Stellen der Anzeige (Notch, Pille), gemerkte Lage, Öffnungsrichtung, Begrenzung auf den Bildschirm; auch für die Controller-Insel |
| `Services/AgentChats/Notch/NotchStatusController.swift` | AppKit-Seite: Beobachter, Klick-daneben, Hotkey, Einstellungen, Aufklappen |
| `Services/AgentChats/Notch/NotchStatusController+Placements.swift` | Je Stelle ein Fenster (`NotchSlot`), Bildschirm des Agent-Chats-Fensters, Vollbild, Ziehen und Zurücksetzen der Pille |
| `Windows/NotchPanel.swift` | Nicht aktivierendes `NSPanel`, Hosting-View mit erstem Klick und Klick/Ziehen/Doppelklick der Pille |
| `Views/PillGlass.swift` | Dunkles Glas, Höhe und Schatten der Diktat-Pille, geteilt mit Pille und Insel |
| `Views/NotchStatusView.swift` | Darstellung aus einem fertigen `NotchDisplay`-Wert |
| `Services/Shared/UnifiedPill/UnifiedPillModel.swift` | Rein: Priorität, Ort des Diktats, Raute, Geometrie (Mitte, Rechts-Anker beim Darüberfahren, Fenster mit Schattenrand), Klickziel, Aufklapprichtung |
| `Services/Shared/UnifiedPill/UnifiedPillHub.swift` | Treffpunkt Diktat und Status: Bildschirm des Diktats, Raute |
| `Services/AgentChats/Notch/NotchStatusController+UnifiedPill.swift` | Status-Pille vereint: Fenster mit Schattenrand, Platz fürs Diktat, Klick auf den Kern, Tastatur, nachgeholter Hinweis |
| `Windows/RecordingPanel+UnifiedPill.swift` | Diktat-Pille vereint: Bildschirm des vorderen Fensters, Lage je Bildschirm, an der Notch, Raute |
| `Views/UnifiedStatusPillView.swift` | Ruhe, Hinweis und Liste im Aussehen der Diktat-Pille; `PillRestCoreView`, Raute `DictationStatusBadgeView` |
| `Views/Settings/Pages/PillSettingsSection.swift` | Abschnitt „Pille und Notch“ auf General, Verweis-Zeile für Recording und Agent Chats |
| `Views/Settings/Pages/NotchSettingsSection.swift` | Einstellungen |
| `CLI/ChatsAttentionModel.swift` | `AttentionModelBuilder.classify(status:lastTurnAt:since:now:)` ist die geteilte Rang-Logik, das CLI-Verhalten blieb gleich |

Aufmerksamkeits-Reihenfolge: braucht dich (wartet vor Fehler), frisch fertig,
arbeitet, bereit; innerhalb eines Rangs der jüngste Statuswechsel zuerst.
Gestoppte Chats, archivierte Chats und Subagent-Jobs erscheinen nicht.

### Auslöser für „braucht dich"

`NotchAlertTracker` vergleicht Status-Schnappschüsse:

- Ausgelöst wird nur bei einem echten Wechsel eines schon bekannten Chats:
  nach `awaitingInput`, nach `errored` und bei `working → idle`.
- Ein Chat, der zum ersten Mal auftaucht, ist Ausgangslage. Beim App-Start
  füllt sich der Status-Store nach und nach; schon wartende Chats blitzen
  deshalb nicht auf. Dasselbe gilt für neue Chats.
- Mehrere Auslöser im selben Takt: der dringendste gewinnt (Fehler vor Warten
  vor Fertig), die übrigen zählen als „+n".
- Derselbe Chat mit derselben Art löst höchstens alle 20 s erneut aus
  (Status, der zwischen Warten und Arbeiten flattert).
- Der Tracker merkt sich außerdem jedes gesehene `working → idle`
  (`observedTurnEnds`). Der Workspace schreibt `lastTurnAt` erst, wenn das
  Transkript das Turn-Ende zeigt, das kann nach dem Statuswechsel kommen.
  `NotchStatusModel.applyingObservedTurnEnds` ergänzt den Wert, sonst stünde
  ein gerade fertiger Chat als „bereit" da. Die Einteilung selbst bleibt
  `AttentionModelBuilder.classify`.

## Fenster-Technik

- `NSPanel` mit `.borderless` und `.nonactivatingPanel`: stiehlt keinen Fokus.
  Key-Status gibt es nur im aufgeklappten Zustand, damit Esc ankommt;
  beim Zuklappen wird er zurückgegeben.
- Ebene `mainMenu + 3` (über der Menüleiste), `collectionBehavior`
  `canJoinAllSpaces`, `stationary`, `ignoresCycle`.
- `constrainFrameRect` gibt den Rahmen unverändert zurück, sonst schöbe AppKit
  das Fenster unter die Menüleiste.
- Hosting-View ohne Safe-Area-Regionen (sonst verschöbe die Notch den Inhalt)
  und mit `acceptsFirstMouse`.
- Fenstergröße wechselt je Zustand einmalig über `animator().setFrame`
  (blockiert den Main Thread nicht, anders als `setFrame(_:display:animate:)`),
  bei „Bewegung reduzieren" ohne Animation. Keine `repeatForever`-Animation.
- Ohne Notch trägt das Fenster einen Fensterschatten (`hasShadow`) statt des
  in der Diktat-Pille gezeichneten. Ein gezeichneter Schatten bräuchte einen
  Rand im Fenster, und bei einer dauerhaft sichtbaren Pille finge dieser Rand
  Klicks in die Fenster darunter ab. So bleibt es beim Klick-Durchlass oben:
  Nur die Pille selbst nimmt Klicks an, ihre transparenten Ecken nicht.
- Beide Stellen, auch die an der Notch, haben das dunkle Erscheinungsbild
  (`darkAqua` an der Hosting-View, `colorScheme` dunkel in der Ansicht). An der
  Notch änderte das nichts Sichtbares, die Farben dort waren schon fest dunkel;
  es betrifft nur Systemfarben und Materialien.
- Den Bildschirm des Agent-Chats-Fensters fragt die Anzeige nur bei
  Fenster-Ereignissen ab (`NSWindow.didChangeScreenNotification`,
  `didBecomeKey`, `willClose`, entprellt auf 250 ms), über
  `AgentChatsCommandCenter.windowDisplayID(preferring:)`. Gezeichnet wird nur,
  wenn sich die Stellen dadurch ändern. Schließt man das letzte
  Agent-Chats-Fenster, hat es sich beim `willClose` schon abgemeldet; nach der
  Entprellung zählt es nicht mehr, und die Pille verschwindet bzw. geht auf den
  gewählten Bildschirm, falls der keine Notch hat.
- Notch-Erkennung: `safeAreaInsets.top > 0` und beide `auxiliaryTop…Area`.
  Notch-Breite = Bildschirmbreite minus die beiden freien Bereiche.
- Vollbild: Über Vollbild-Apps wird die Anzeige ausgeblendet, je Stelle für
  ihren Bildschirm geprüft (eine Fensterliste für beide). Erkannt wird ein
  fremdes Fenster der Ebene 0, das den Bildschirm samt Menüleistenbereich exakt
  deckt (`CGWindowListCopyWindowInfo`, braucht keine Aufnahmerechte). Auf
  Notch-Bildschirmen legt macOS Vollbild-Apps meist unter die Kamera; ein
  Fenster, das an der Unterkante der Notch beginnt und bis unten reicht, zählt
  deshalb auch, aber nur wenn `NSApp.currentSystemPresentationOptions`
  `.fullScreen` meldet oder das Fenster selbst per Accessibility
  (`AXFullScreen`, gleiche Maße) im Vollbild ist; sonst wäre es ein
  maximiertes Fenster bei ausgeblendetem Dock. Das System meldet nur die
  aktive App: Läuft das Video im Vollbild auf dem MacBook und man arbeitet am
  externen Bildschirm, entscheidet die Accessibility-Abfrage. Gefragt wird
  nur für Fenster mit genau diesen Maßen, mit 0,25 s Zeitlimit je
  Accessibility-Abfrage (an der App und an jedem ihrer Fenster gesetzt,
  abgeleitete Elemente erben es nicht); ohne
  Bedienungshilfen-Recht bleibt es beim Systemsignal. Geprüft bei Space- und
  App-Wechsel und 0,9 s danach, nie in einer Schleife; Fensterliste und
  Accessibility laufen abseits des Main Threads.
- Klick daneben: ein globaler und ein lokaler Monitor auf Mausklicks, nur
  solange die Liste offen ist. Beide schlucken nichts (der globale kann es
  nicht, der lokale gibt das Ereignis immer zurück).
- Keine Dateideskriptoren, keine Subprozesse.
- Controller-Insel: Hält man am Controller L1, R1 oder L2, legt sich die Insel
  (eigenes Fenster, `mainMenu + 4`, dieselbe Band-Geometrie an der Notch,
  ohne Notch an der Stelle der Pille) über diese Anzeige und zeigt ihre Zähler
  im Kopf. Die Anzeige selbst ändert sich dafür
  nicht; sie gibt nur über `visibleSummary(onDisplay:)` lesend ihre Zähler her,
  und eine offene Liste klappt zu. Details in [controller.md](controller.md).

## Performance-Regeln

- Ruhezustand: nur ein Beobachter auf `AgentSessionRuntimeStatusStore`,
  gedrosselt auf 300 ms (`throttle`, `latest: true`). Die Ansicht bekommt nur
  dann einen neuen Wert, wenn sich `NotchDisplay` ändert (Equatable), und das
  Fenster nur dann einen neuen Rahmen, wenn sich der Rahmen ändert.
- Den `AgentSessionActivityStore` liest die Anzeige im Ruhezustand nie. Er
  ändert sich bei arbeitenden Chats mit fast jeder Transcript-Zeile. Nur
  solange die Liste offen ist, hört der Controller darauf (gedrosselt auf
  500 ms), und die Dauer-Angaben werden alle 30 s aufgefrischt.
- Kein I/O und kein `loadWorkspace()`: Titel kommen aus
  `AgentWorkspaceUIModel`.
- „Frisch fertig" läuft über einen einzigen geplanten Neuaufbau zum frühesten
  Ablauf, nicht über einen Timer im Takt.
- Ausgeschaltet kostet die Funktion einen `UserDefaults`-Beobachter
  (entprellt, vergleicht einen kleinen Wert).

## Tests

- `NotchStatusModelTests`: Sortierung, Zähler, Abschnitte, Sichtbarkeit,
  Gleichheit mit der CLI-Rang-Logik, Eingaben aus dem Workspace.
- `NotchStatusModelTests` vergleicht die Reihenfolge außerdem direkt mit
  `AttentionModelBuilder.build` (CLI), prüft die Alarm-Gültigkeit, die
  ergänzten Turn-Enden und die Wahl der Darstellungsart.
- `NotchAlertTrackerTests`: Ausgangslage beim Start und bei neu auftauchenden
  Chats, Auslöser, Unterdrückung, Priorität bei mehreren gleichzeitigen,
  Abkühlzeit, beobachtete Turn-Enden.
- `NotchGeometryTests`, `NotchFullscreenDetectorTests`: Notch mit und ohne,
  Bildschirmwahl, Rahmen je Zustand, Menüleiste neben der Notch bleibt in
  jedem Zustand und auf mehreren Bildschirmgrößen frei, Vollbild-Erkennung
  inklusive Vollbild unter der Kamera (auch wenn nur das Fenster selbst
  Vollbild meldet).
- `NotchStatusModelTests.testClickOnHoverOpenedListPinsItInsteadOfClosing`:
  Klick auf den Kopf je nach Zustand auf, zu oder festhalten.
- `NotchConfigTests`: Standardwerte, Schalter und Kill-Switch.
- `NotchPillPlacementTests`: welche Stellen bei Notch, externem Bildschirm und
  Agent-Chats-Fenster, gemerkte Lage hin und zurück, Begrenzung auf den
  sichtbaren Bereich, nach oben in der unteren Hälfte, Insel an derselben
  Stelle, Schlüssel ist die Display-UUID, Speichern und Zurücksetzen.
- `UnifiedPillModelTests`: Priorität (Insel, Diktat, Liste, Hinweis, Ruhe;
  Status aus, Vollbild), Ort des Diktats (vorderes Fenster, Maus,
  Hauptbildschirm, Notch, gemerkte Lage), Raute, Rechts-Anker beim
  Darüberfahren, Fenster mit Schattenrand, Liste nach oben und unten,
  Begrenzung am Rand, Klickziel Kern oder Liste.
- `UnifiedPillControllerTests`: Kill-Switch und Bildschirmwahl, Klick auf den
  Kern startet das Diktat (Spy), Raute nur vereint, Diktat blendet den Status
  nur auf seinem Bildschirm aus, nachgeholter Hinweis, Pfeile und Return,
  Abmelden beim Hub, vorderes Fenster aus der Fensterliste, Liste der
  Ausgabemodi nach unten.
- Snapshots vereint: `make snapshots ONLY=vereint` (Ruhe leer und mit
  Zählern, Hinweis, Fehler, Liste nach unten und oben, Diktat mit Raute,
  Diktat an der Notch, Vergleich Diktat-Pille und ruhende Pille Seite an
  Seite). `ONLY=diktatpille` zeigt die Diktat-Pille in allen Zuständen.
- Snapshots: `make snapshots ONLY=notch` (Ruhe, Ruhe mit allen Zählern,
  braucht dich, Fehler, aufgeklappt, jeweils an der Notch und als Pille; dazu
  die leere Pille und die Pille unten mit Liste nach oben; hell und dunkel).
  `make snapshots ONLY=pill-` zeigt die Diktat-Pille zum Vergleich. Die Attrappe zeigt Menüs und Statussymbole bis dicht an die
  Notch, damit man sieht, dass nichts verdeckt wird.

## Grenzen

- Der Streifen kennt nur Chats, die die App gerade beobachtet (Status im
  `AgentSessionRuntimeStatusStore`). Chats ohne laufenden Prozess fehlen.
- Die Anzeige erscheint an höchstens zwei Stellen: an der Notch des gewählten
  Bildschirms und als Pille auf dem Bildschirm des Agent-Chats-Fensters ohne
  Notch. Weitere Bildschirme zeigen nichts.
- Die Pille lässt sich nur innerhalb ihres Bildschirms ziehen, nicht auf einen
  anderen.
- Ob man einen bestimmten Chat gerade ansieht, weiß sie nicht: die
  Fertig-Verbreiterung wird nur unterdrückt, solange WhisperM8 aktive App ist.
- Unter der Notch verdeckt die Anzeige ein kleines Stück oben in der
  Bildschirmmitte (Notch-Breite mal 24 pt, beim Alarm kurz 340 pt breit).
- Titeländerungen erscheinen erst mit dem nächsten Statuswechsel (oder sofort
  bei offener Liste); die Anzeige beobachtet den Workspace nicht.
- „In Screenshots und Bildschirmfreigabe ausblenden“ ist kein sicherer Schutz:
  manche Aufnahme- und Meeting-Apps können den Streifen trotzdem zeigen (siehe
  oben, Handtest offen).
- „Esc closes" wirkt nur, wenn die Liste per Klick geöffnet oder nach dem
  Darüberfahren per Klick festgehalten wurde. Beim bloßen Öffnen per
  Darüberfahren nimmt sie keinen Tastaturfokus.

## Keywords

Notch, MacBook, Dynamic Island, Statusanzeige, Streifen, Pille, verschieben, braucht dich,
frisch fertig, `NotchStatusController`, `NotchStatusModel`, `NotchGeometry`,
`NotchAlertTracker`, `NotchPanel`, `NotchPillPlacement`, `notchPillPositions`, `notchStatusEnabled`,
`notchStatusFeatureEnabled`, `toggleNotchStatus`, `sharingType`.
