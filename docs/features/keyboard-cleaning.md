---
status: aktiv
stand: 2026-11-05
---

# Tastatur reinigen (Tastatursperre)

Sperrt per Mausklick die ganze Tastatur, damit man sie abwischen kann, ohne dass
irgendwo Text, Kürzel oder Medientasten ankommen. Maus und Trackpad bleiben frei.

## Bedienung

- **Einstellungen → Allgemein → Tastatur reinigen:** „Tastatur sperren“.
- **Menüleiste:** „Tastatur zum Reinigen sperren“ bzw. „Tastatur entsperren“.
- Während der Sperre liegt ein schwebendes Panel über allen Fenstern und Spaces
  (auch über Vollbild-Apps) mit Countdown, „Tastatur entsperren“ und „+1 Minute“.
  Es erscheint auf dem Bildschirm unter dem Mauszeiger, nimmt schon den ersten
  Klick an, aktiviert die App nicht und wird nie Key-Fenster — der Tastaturfokus
  bleibt also in der App, in der man gerade war.

## Was gesperrt wird

Ein aktiver `CGEventTap` auf HID-Ebene (`.cghidEventTap`, `headInsert`) verwirft:

- `keyDown`, `keyUp`, `flagsChanged` (also auch ⌘-Tab, Systemkürzel und die
  Diktat-Hotkeys, die als Carbon-Hotkeys erst hinter dem Tap ausgewertet werden),
- Systemereignisse vom Untertyp 8 (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`): Helligkeit,
  Lautstärke, Play/Pause, Tastaturlicht.

Andere Systemereignis-Untertypen (7 = Maustasten) gehen durch, sonst hakt die Maus.
Tasten, die beim Sperren schon gedrückt waren, dürfen genau einmal loslassen —
sonst hielte das System sie nach dem Entsperren für gedrückt. Die Feststelltaste
(Keycode 57) zählt dabei nie mit, weil `CGEventSource.keyState` für sie je nach
System den Schaltzustand meldet; sonst ginge ihr erstes Drücken durch.

## Tap-Thread und Lebenszeichen

Der Tap läuft auf einem eigenen Thread mit eigenem Runloop
(`KeyboardTapSession`), nicht auf dem Main Thread. Früher saß er auf dem
Main-Runloop: Stockte WhisperM8 nur kurz länger als die Zeitgrenze von macOS für
Taps, schaltete macOS den Tap ab, und Tasten, die man beim Wischen gerade
drückte, landeten in der App vorn (Review K1, 05.11.2026).

Damit ein echter Hänger die Tastatur trotzdem freigibt, stempelt der Main Thread
im sekündlichen `tick()` ein Lebenszeichen (`KeyboardLockGate.heartbeat`).
Gesperrt wird nur, solange es höchstens 5 s alt ist
(`KeyboardLockPolicy.heartbeatTimeout`):

| Lage | Verhalten |
|---|---|
| Normalbetrieb (Lebenszeichen ≤ gut 1 s alt) | gesperrt |
| Main Thread stockt bis knapp 5 s | weiter gesperrt, nichts rutscht durch |
| Main Thread hängt länger als 5 s | alle Tasten gehen durch (z. B. für ⌥⌘⎋); Log `keyboard_lock_heartbeat_stale` |
| Main Thread wieder frei | nächster `tick()` sperrt wieder, Log `keyboard_lock_heartbeat_recovered passed_events=…`; ist die Frist inzwischen um, endet die Sperre |

Die 5 s: Im Normalbetrieb ist das Lebenszeichen höchstens gut 1 s alt (Takt
plus 0,2 s Timer-Toleranz). Stocker von einigen Sekunden sollen weiter sperren;
ein Hänger darüber ist am Beachball sichtbar, dann braucht man die Tastatur.
Tasten, die während des Hängers gedrückt wurden, dürfen danach noch einmal
loslassen (wie beim Sperrbeginn). Solange gesperrt ist, hält eine
`ProcessInfo`-Aktivität App Nap fern, damit der Timer nicht gedrosselt wird und
die Sperre nicht fälschlich aufgeht.

Geteilter Zustand: `KeyboardLockGate` hält die Policy unter einem
`OSAllocatedUnfairLock`; der Callback auf dem Tap-Thread fasst keinen
Main-Actor-Zustand an (die Anzeige „Feststelltaste an“ geht per
`DispatchQueue.main.async` zurück). Abbau: `unlock` schaltet erst das Gate ab
(alles geht durch, kein Wiedereinschalten mehr), dann schaltet `stop()` den Tap
sofort aus und hält den Runloop an; Quelle entfernen und Port ungültig machen
passiert auf dem Tap-Thread selbst, danach endet er. Ein Mach-Port ist kein
Dateideskriptor und wird bei `execve` nicht vererbt.

## Wege aus der Sperre

| Auslöser | Mechanik |
|---|---|
| Knopf im Panel, in den Einstellungen oder im Menü | `unlock(reason: .user)` |
| Frist (2 Minuten, „+1 Minute“ bis höchstens 10 Minuten ab Start) | sekündlicher `tick()`, gemessen an `ProcessInfo.systemUptime` — ein Sprung der Wanduhr verschiebt sie nicht; nur der Countdown im Panel rechnet in Uhrzeit um |
| Bildschirmsperre | `com.apple.screenIsLocked` über das Selector-API mit `.deliverImmediately` (sonst hält AppKit verteilte Benachrichtigungen zurück, solange die App inaktiv ist); zusätzlich fragt `tick()` `CGSSessionScreenIsLocked` aus `CGSessionCopyCurrentDictionary()` ab |
| Ruhezustand, Bildschirm schläft, Benutzerwechsel | `NSWorkspace.willSleep`/`screensDidSleep`/`sessionDidResignActive` |
| App wird beendet | `NSApplication.willTerminate` |
| Absturz | Der Tap gehört zum Prozess und verschwindet mit ihm |
| Hängender Main Thread | Kein Lebenszeichen seit über 5 s: der Tap lässt alles durch, bis der Main Thread wieder tickt (siehe oben) |

Schaltet macOS den Tap während einer gewollten Sperre ab (`tapDisabledByTimeout`,
`tapDisabledByUserInput`), schaltet ihn der Tap-Thread sofort wieder ein (Log
`keyboard_lock_tap_reenabled`). Nach dem Entsperren nicht mehr.

## Grenzen

- **Ein-/Ausschalter und Touch ID** laufen nicht als Tastatur-Ereignis und lassen
  sich nicht sperren. Ein Druck schickt den Mac schlafen bzw. sperrt ihn — und hebt
  damit auch die Sperre auf.
- **Secure Event Input** (Passwortfeld, „Sichere Tastatureingabe“ im Terminal):
  macOS gibt die Tasten dann an keinen Tap. Das Panel warnt, solange das aktiv ist.
- **Caps Lock:** Die Hardware kann den Zustand trotzdem umschalten; das Panel zeigt
  „Feststelltaste an“, solange sie an ist.

## Berechtigung

Ein aktiver (nicht nur lauschender) Tap braucht die Bedienungshilfen-Freigabe —
dieselbe wie Auto-Paste. Verweigert macOS den Tap, bleibt die Tastatur frei; die
Einstellungen zeigen dann den Weg zur Freigabe. Das Menü fragt sie an und öffnet
zusätzlich Systemeinstellungen → Bedienungshilfen, weil der Systemdialog nur beim
ersten Mal kommt (steht WhisperM8 deaktiviert in der Liste, etwa nach einem
Neusignieren, passiert sonst sichtbar nichts).

## Schlüsseldateien

- `WhisperM8/Services/Shared/KeyboardLock/KeyboardLockPolicy.swift` — reine Logik: Ereignis → verwerfen/durchlassen, Lebenszeichen frisch?, Fristen.
- `WhisperM8/Services/Shared/KeyboardLock/KeyboardLockGate.swift` — threadsicherer Zustand zwischen Main Thread und Tap-Thread.
- `WhisperM8/Services/Shared/KeyboardLock/KeyboardEventTap.swift` — der echte `CGEventTap` auf eigenem Thread (`KeyboardTapSession`) hinter `KeyboardEventTapping`.
- `WhisperM8/Services/Shared/KeyboardLock/KeyboardLockController.swift` — Zustand, Frist, Auslöser fürs Entsperren, Log (`category == "keyboard.lock"`).
- `WhisperM8/Windows/KeyboardLockPanel.swift` — schwebendes Entsperr-Panel.
- `WhisperM8/Views/Settings/Pages/KeyboardCleaningSettingsSection.swift` — Abschnitt in „Allgemein“.
- Tests: `KeyboardLockTests.swift` (je Ausstieg ein Test über injizierte `NotificationCenter`, Uptime-Frist, Sperrbildschirm-Rückfall, Lebenszeichen mit injizierter Uhr: kurzes Stocken sperrt, Hänger gibt frei, Loslassen bleibt ausgeglichen); Snapshots `tastatursperre-panel*`. Der echte Tap-Thread ist nicht automatisch getestet (ein Tap im Testlauf würde die Tastatur sperren).

## Nur von Hand prüfbar

Caps Lock und `CGEventSource.keyState`, Globe/fn und Helligkeitstasten auf Apple Silicon, Klick
auf den Knopf im nie-Key-Panel, Panel-Position bei mehreren Bildschirmen, Verhalten des
Tap-Threads bei echtem Hängen. Ein Einfrieren des ganzen Prozesses lässt sich
nachstellen: im Terminal `sleep 15; kill -STOP $(pgrep -x WhisperM8); sleep 15; kill -CONT $(pgrep -x WhisperM8)`
starten, dann per Maus sperren. Während WhisperM8 steht, schaltet macOS den Tap
ab und die Tastatur geht; nach `-CONT` sperrt sie wieder. Ein Hänger nur des
Main Threads ist ohne Debugger nicht nachstellbar und nur über die Logik-Tests
abgedeckt.

## Keywords

Tastatur reinigen, Tastatursperre, Tastatur sperren, Tastatur putzen, keyboard lock,
keyboard cleaning, CGEventTap, Event-Tap, `KeyboardLockController`, `KeyboardLockPolicy`.
