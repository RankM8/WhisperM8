---
status: umgesetzt, Review-Fixes drin, wartet auf make-dev-QA
stand: 2026-11-04
feature: Statusanzeige an der Notch
---

# Statusanzeige an der Notch

Eine kleine Anzeige an der MacBook-Notch (ohne Notch eine Pille oben mittig
unter der Menüleiste) zeigt, wie es den Agent Chats geht: wie viele arbeiten,
wie viele auf dich warten, wie viele gerade fertig wurden. Wer woanders
arbeitet, sieht auf einen Blick, ob er gebraucht wird, und springt mit einem
Klick in den passenden Chat. Prototyp der Zustände:
[`../design/notch-prototype.html`](../design/notch-prototype.html).

Standardmäßig **an** (seit 05.11.2026, vorher aus).

## Bedienung

| Zustand | Aussehen | Wie man hinkommt |
|---|---|---|
| Ruhe | Die Notch wird ein Stück länger, darunter grüner Punkt mit Zahl (arbeitet), Amber-Raute (wartet), roter Ring (Fehler), Häkchen (frisch fertig) | Mindestens ein Chat arbeitet, wartet, hat einen Fehler oder wurde frisch fertig |
| Braucht dich | Die Zeile unter der Notch verbreitert sich einmal kurz (ca. 4 s) und zeigt den Chat-Titel mit „wartet", „Fehler" oder „fertig", bei mehreren „+n" | Ein bekannter Chat wechselt nach `awaitingInput` oder `errored`, oder von `working` nach `idle` |
| Aufgeklappt | Liste nach Aufmerksamkeit: Braucht dich, Frisch fertig, Arbeitet, Bereit | Klick auf den Streifen (optional Darüberfahren) |
| Ausgeblendet | nichts | Nur bereite Chats, nichts Aktives, Funktion aus oder Vollbild-App im Vordergrund |

- Eine Zeile zeigt Status-Punkt (gleiche Formen wie `AgentStatusIndicator`:
  Scheibe, Raute, Ring), Titel, Stand-Zeile („› Edit Store.swift"), Projekt
  und Dauer („arbeitet · 2 min"). Wörter und Dauer kommen aus
  `TabSwitcherTileModel`, also dieselben wie im Tab-Switcher.
- Klick auf eine Zeile bringt das WhisperM8-Fenster nach vorn und öffnet genau
  diesen Chat (`WindowRequestCenter.requestSessionFocus`, derselbe Weg wie der
  Klick auf eine Benachrichtigung).
- Zuklappen: Esc, Klick daneben (auch in anderen Apps), Klick auf den Kopf,
  Fenster verliert den Fokus. Alles ist auch ohne Hover erreichbar; Hover
  öffnet höchstens zusätzlich.
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

Ohne Notch ist es eine Pille unter der Menüleiste, die hell und dunkel mitgeht.

## Einstellungen

Einstellungen, Agent Chats, Tab Workspace, Abschnitt „Notch Status"
(`NotchSettingsSection`):

| Einstellung | Schlüssel | Standard |
|---|---|---|
| Chat-Status an der Notch anzeigen | `notchStatusEnabled` | an |
| Bildschirm: Automatisch, Eingebaut, Hauptbildschirm | `notchStatusScreen` | automatisch |
| In Screenshots und Bildschirmfreigabe ausblenden | `notchStatusHideFromCapture` | an |
| Fertige Chats anzeigen | `notchStatusShowFreshDone` | an |
| Liste beim Darüberfahren öffnen | `notchStatusExpandOnHover` | aus |
| Hotkey zum Ein- und Ausblenden | `KeyboardShortcuts` `toggleNotchStatus` | ohne Belegung |

Auch im Menüleisten-Menü: „Chat Status at the Notch" (Schalter).

Bildschirmwahl „Automatisch": eingebauter Bildschirm mit Notch, sonst der
Hauptbildschirm. Hauptbildschirm heißt der mit der Menüleiste
(`CGMainDisplayID`), nicht `NSScreen.main` (das folgt dem Fokus). Die Anzeige
folgt Bildschirmwechseln (`NSApplication.didChangeScreenParametersNotification`),
die Wahl wird bis dahin zwischengespeichert.

Das Aufnahme-Verbergen setzt `NSWindow.sharingType = .none`: Titel erscheinen
weder in Screenshots noch in Screen-Sharing.

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
| `Services/AgentChats/Notch/NotchStatusController.swift` | AppKit-Seite: Beobachter, Fenster, Klick-daneben, Hotkey, Einstellungen |
| `Windows/NotchPanel.swift` | Nicht aktivierendes `NSPanel`, Hosting-View mit erstem Klick |
| `Views/NotchStatusView.swift` | Darstellung aus einem fertigen `NotchDisplay`-Wert |
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
- Notch-Erkennung: `safeAreaInsets.top > 0` und beide `auxiliaryTop…Area`.
  Notch-Breite = Bildschirmbreite minus die beiden freien Bereiche.
- Vollbild: Über Vollbild-Apps wird die Anzeige ausgeblendet. Erkannt wird ein
  fremdes Fenster der Ebene 0, das den Bildschirm samt Menüleistenbereich exakt
  deckt (`CGWindowListCopyWindowInfo`, braucht keine Aufnahmerechte). Auf
  Notch-Bildschirmen legt macOS Vollbild-Apps meist unter die Kamera; ein
  Fenster, das an der Unterkante der Notch beginnt und bis unten reicht, zählt
  deshalb auch, aber nur wenn `NSApp.currentSystemPresentationOptions`
  `.fullScreen` meldet (sonst wäre es ein maximiertes Fenster bei
  ausgeblendetem Dock). Geprüft bei Space- und App-Wechsel und 0,9 s danach,
  nie in einer Schleife; die Fensterliste wird abseits des Main Threads gelesen.
- Klick daneben: ein globaler und ein lokaler Monitor auf Mausklicks, nur
  solange die Liste offen ist. Beide schlucken nichts (der globale kann es
  nicht, der lokale gibt das Ereignis immer zurück).
- Keine Dateideskriptoren, keine Subprozesse.

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
  inklusive Vollbild unter der Kamera.
- `NotchConfigTests`: Standardwerte, Schalter und Kill-Switch.
- Snapshots: `make snapshots ONLY=notch` (Ruhe, Ruhe mit allen Zählern,
  braucht dich, Fehler, aufgeklappt, jeweils an der Notch und als Pille, hell
  und dunkel). Die Attrappe zeigt Menüs und Statussymbole bis dicht an die
  Notch, damit man sieht, dass nichts verdeckt wird.

## Grenzen

- Der Streifen kennt nur Chats, die die App gerade beobachtet (Status im
  `AgentSessionRuntimeStatusStore`). Chats ohne laufenden Prozess fehlen.
- Die Anzeige erscheint nur auf einem Bildschirm (der gewählte).
- Ob man einen bestimmten Chat gerade ansieht, weiß sie nicht: die
  Fertig-Verbreiterung wird nur unterdrückt, solange WhisperM8 aktive App ist.
- Unter der Notch verdeckt die Anzeige ein kleines Stück oben in der
  Bildschirmmitte (Notch-Breite mal 24 pt, beim Alarm kurz 340 pt breit).
- Titeländerungen erscheinen erst mit dem nächsten Statuswechsel (oder sofort
  bei offener Liste); die Anzeige beobachtet den Workspace nicht.
- „Esc closes" wirkt nur, wenn die Liste per Klick geöffnet wurde. Beim
  Öffnen per Darüberfahren nimmt sie keinen Tastaturfokus.

## Keywords

Notch, MacBook, Dynamic Island, Statusanzeige, Streifen, Pille, braucht dich,
frisch fertig, `NotchStatusController`, `NotchStatusModel`, `NotchGeometry`,
`NotchAlertTracker`, `NotchPanel`, `notchStatusEnabled`,
`notchStatusFeatureEnabled`, `toggleNotchStatus`, `sharingType`.
