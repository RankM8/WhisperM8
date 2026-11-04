---
status: umgesetzt, wartet auf make-dev-QA
stand: 2026-11-04
feature: Statusanzeige an der Notch
---

# Statusanzeige an der Notch

Ein schmaler Streifen an der MacBook-Notch (ohne Notch eine Pille oben mittig
unter der Menüleiste) zeigt, wie es den Agent Chats geht: wie viele arbeiten,
wie viele auf dich warten, wie viele gerade fertig wurden. Wer woanders
arbeitet, sieht auf einen Blick, ob er gebraucht wird, und springt mit einem
Klick in den passenden Chat. Prototyp der Zustände:
[`../design/notch-prototype.html`](../design/notch-prototype.html).

Standardmäßig **aus**.

## Bedienung

| Zustand | Aussehen | Wie man hinkommt |
|---|---|---|
| Ruhe | Links grüner Punkt mit Zahl (arbeitet), rechts Amber-Raute (wartet), roter Ring (Fehler), Häkchen (frisch fertig) | Mindestens ein Chat arbeitet, wartet, hat einen Fehler oder wurde frisch fertig |
| Braucht dich | Streifen verbreitert sich einmal kurz (ca. 4 s) und zeigt den Chat-Titel mit „wartet", „Fehler" oder „fertig", bei mehreren „+n" | Ein Chat wechselt nach `awaitingInput` oder `errored`, oder von `working` nach `idle` |
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

Mit Notch hängt der Streifen bündig an der Oberkante, ist immer schwarz (die
Hardware ist es) und wächst links und rechts um die Aussparung. Ohne Notch ist
es eine Pille unter der Menüleiste, die hell und dunkel mitgeht.

## Einstellungen

Einstellungen, Agent Chats, Tab Workspace, Abschnitt „Notch Status"
(`NotchSettingsSection`):

| Einstellung | Schlüssel | Standard |
|---|---|---|
| Chat-Status an der Notch anzeigen | `notchStatusEnabled` | aus |
| Bildschirm: Automatisch, Eingebaut, Hauptbildschirm | `notchStatusScreen` | automatisch |
| In Screenshots und Bildschirmfreigabe ausblenden | `notchStatusHideFromCapture` | an |
| Fertige Chats anzeigen | `notchStatusShowFreshDone` | an |
| Liste beim Darüberfahren öffnen | `notchStatusExpandOnHover` | aus |
| Hotkey zum Ein- und Ausblenden | `KeyboardShortcuts` `toggleNotchStatus` | ohne Belegung |

Auch im Menüleisten-Menü: „Chat Status at the Notch" (Schalter).

Bildschirmwahl „Automatisch": eingebauter Bildschirm mit Notch, sonst der
Hauptbildschirm. Die Anzeige folgt Bildschirmwechseln
(`NSApplication.didChangeScreenParametersNotification`).

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

- Der erste Schnappschuss ist nur die Ausgangslage. Ein beim Start schon
  wartender Chat blitzt nicht auf.
- Ausgelöst wird beim Wechsel nach `awaitingInput`, nach `errored` und bei
  `working → idle`.
- Mehrere Auslöser im selben Takt: der dringendste gewinnt (Fehler vor Warten
  vor Fertig), die übrigen zählen als „+n".
- Derselbe Chat mit derselben Art löst höchstens alle 20 s erneut aus
  (Status, der zwischen Warten und Arbeiten flattert).

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
- Fenstergröße wechselt je Zustand einmalig (animiert, bei „Bewegung
  reduzieren" ohne Animation). Keine `repeatForever`-Animation.
- Notch-Erkennung: `safeAreaInsets.top > 0` und beide `auxiliaryTop…Area`.
  Notch-Breite = Bildschirmbreite minus die beiden freien Bereiche.
- Vollbild: Über Vollbild-Apps wird die Anzeige ausgeblendet. Erkannt wird ein
  fremdes Fenster der Ebene 0, das den Bildschirm samt Menüleistenbereich exakt
  deckt (`CGWindowListCopyWindowInfo`, braucht keine Aufnahmerechte). Geprüft bei
  Space- und App-Wechsel und 0,9 s danach, nie in einer Schleife.
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
- `NotchAlertTrackerTests`: Ausgangslage, Auslöser, Unterdrückung,
  Priorität, Abkühlzeit.
- `NotchGeometryTests`, `NotchFullscreenDetectorTests`: Notch mit und ohne,
  Bildschirmwahl, Rahmen je Zustand, Vollbild-Erkennung.
- `NotchConfigTests`: Standardwerte, Schalter und Kill-Switch.
- Snapshots: `make snapshots ONLY=notch` (Ruhe, braucht dich, Fehler,
  aufgeklappt, jeweils an der Notch und als Pille, hell und dunkel).

## Grenzen

- Der Streifen kennt nur Chats, die die App gerade beobachtet (Status im
  `AgentSessionRuntimeStatusStore`). Chats ohne laufenden Prozess fehlen.
- Die Anzeige erscheint nur auf einem Bildschirm (der gewählte).
- Ob man einen bestimmten Chat gerade ansieht, weiß sie nicht: die
  Fertig-Verbreiterung wird nur unterdrückt, solange WhisperM8 aktive App ist.
- Eine genaue Prüfung gegen Menüleisten-Programme, die den Platz neben der
  Notch belegen, fehlt. Die Anzeige liegt darüber.

## Keywords

Notch, MacBook, Dynamic Island, Statusanzeige, Streifen, Pille, braucht dich,
frisch fertig, `NotchStatusController`, `NotchStatusModel`, `NotchGeometry`,
`NotchAlertTracker`, `NotchPanel`, `notchStatusEnabled`,
`notchStatusFeatureEnabled`, `toggleNotchStatus`, `sharingType`.
