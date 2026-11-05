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
sonst hielte das System sie nach dem Entsperren für gedrückt.

## Wege aus der Sperre

| Auslöser | Mechanik |
|---|---|
| Knopf im Panel, in den Einstellungen oder im Menü | `unlock(reason: .user)` |
| Frist (2 Minuten, „+1 Minute“ bis höchstens 10 Minuten ab Start) | sekündlicher `tick()`, gemessen an `ProcessInfo.systemUptime` — ein Sprung der Wanduhr verschiebt sie nicht; nur der Countdown im Panel rechnet in Uhrzeit um |
| Bildschirmsperre | `com.apple.screenIsLocked` über das Selector-API mit `.deliverImmediately` (sonst hält AppKit verteilte Benachrichtigungen zurück, solange die App inaktiv ist); zusätzlich fragt `tick()` `CGSSessionScreenIsLocked` aus `CGSessionCopyCurrentDictionary()` ab |
| Ruhezustand, Bildschirm schläft, Benutzerwechsel | `NSWorkspace.willSleep`/`screensDidSleep`/`sessionDidResignActive` |
| App wird beendet | `NSApplication.willTerminate` |
| Absturz | Der Tap gehört zum Prozess und verschwindet mit ihm |
| Hängender Main Thread | Der Tap läuft auf dem Main-Runloop; macOS schaltet ihn nach Zeitüberschreitung ab |

Schaltet macOS den Tap während einer gewollten Sperre ab (`tapDisabledByTimeout`,
`tapDisabledByUserInput`), wird er sofort wieder eingeschaltet.

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
Einstellungen zeigen dann den Weg zur Freigabe, das Menü fragt sie an.

## Schlüsseldateien

- `WhisperM8/Services/Shared/KeyboardLock/KeyboardLockPolicy.swift` — reine Logik: Ereignis → verwerfen/durchlassen, Fristen.
- `WhisperM8/Services/Shared/KeyboardLock/KeyboardEventTap.swift` — der echte `CGEventTap` hinter `KeyboardEventTapping`.
- `WhisperM8/Services/Shared/KeyboardLock/KeyboardLockController.swift` — Zustand, Frist, Auslöser fürs Entsperren, Log (`category == "keyboard.lock"`).
- `WhisperM8/Windows/KeyboardLockPanel.swift` — schwebendes Entsperr-Panel.
- `WhisperM8/Views/Settings/Pages/KeyboardCleaningSettingsSection.swift` — Abschnitt in „Allgemein“.
- Tests: `KeyboardLockTests.swift` (je Ausstieg ein Test über injizierte `NotificationCenter`, Uptime-Frist, Sperrbildschirm-Rückfall); Snapshots `tastatursperre-panel*`.

## Nur von Hand prüfbar

Caps Lock und `CGEventSource.keyState`, Globe/fn und Helligkeitstasten auf Apple Silicon, Klick
auf den Knopf im nie-Key-Panel, Panel-Position bei mehreren Bildschirmen.

## Keywords

Tastatur reinigen, Tastatursperre, Tastatur sperren, Tastatur putzen, keyboard lock,
keyboard cleaning, CGEventTap, Event-Tap, `KeyboardLockController`, `KeyboardLockPolicy`.
