---
status: aktiv
updated: 2026-11-05
description: Zwischenablage-Verlauf (Maccy-Ersatz) mit Hotkey-Fenster, Datenschutz-Regeln, CLI und Plugin-Tool für Claude.
---

# Zwischenablage-Verlauf

WhisperM8 führt ab Werk einen durchsuchbaren Verlauf dessen, was der User
kopiert, und ersetzt damit Maccy. Claude kann den Verlauf lesen
(`whisperm8 clipboard`, Tool `clipboard`), damit „der Fehler, den ich vorhin
kopiert hatte“ ohne erneutes Einfügen funktioniert.

Standardmäßig **an** (seit 05.11.2026, vorher aus). Ausschalten: Einstellungen,
Seite „Clipboard“. Solange der Schalter aus ist, liest die App beim Start
nichts vom Verlauf, pollt nicht und belegt keinen Hotkey.

## Bedienung

| Aktion | Wie |
|---|---|
| Fenster öffnen | Hotkey (Standard ⇧⌘C, umbelegbar) oder Menüleiste „Clipboard History...“ |
| Suchen | einfach tippen: Groß/Klein und Akzente egal, jedes Wort muss vorkommen, durchsucht den vollen Text |
| Wählen | ↑ und ↓ |
| Einfügen | Enter, in die App davor (Cmd+V simuliert, braucht Bedienungshilfen), auch in WhisperM8 selbst |
| Als reinen Text einfügen | ⌥Enter |
| Korrigieren & einfügen | ⌘Enter oder Schaltfläche in der Vorschau (nur Text): Rechtschreibung und Grammatik korrigieren, dann einfügen |
| Markierung korrigieren | Kopfzeile unter dem Suchfeld, wenn in der App davor Text markiert ist (auch ⇧⌘K); Details in [Schnellaktionen](dictation/quick-actions/README.md#im-zwischenablage-fenster-c) |
| Schnellwahl | ⌘1 bis ⌘9, genau wie die Liste nummeriert ist |
| Anpinnen und lösen | ⌘P oder die Pin-Schaltfläche am Eintrag |
| Löschen | ⌘⌫ oder Schaltfläche in der Vorschau |
| Bild groß ansehen | Klick aufs Vorschaubild, „View Large“ oder ⌘Y. Das Bild füllt das Fenster, Enter fügt genau dieses Bild ein, ↑/↓ blättern, Leertaste, Esc oder ⌘Y gehen zurück. Tippen geht in dieser Ansicht nicht an die Suche |
| Nur Diktate zeigen | ⌘D oder Umschalter „All / Dictations“ neben dem Suchfeld (kombinierbar mit der Suche) |
| Original eines Diktats einfügen | Schaltfläche „Paste original“ in der Vorschau |
| Verlauf leeren | Fußzeile „Clear History…“, mit Rückfrage in der Fußzeile; Angepinnte und ihre Dateien bleiben. Alles samt Pins löscht nur „Clear history…“ in den Einstellungen (siehe [Speicherort](#speicherort)) |
| Einstellungen | Fußzeile „Settings…“ öffnet die Seite Clipboard |
| Schließen | Esc oder Klick daneben (Esc bricht zuerst eine offene Rückfrage ab) |
| Pausieren | Menüleiste „Pause clipboard history“ oder Einstellungen |

Ohne Suche stehen Angepinnte als eigene Gruppe oben; mit Suche gilt die
Trefferreihenfolge. Nummern, Pfeiltasten und Anzeige folgen in beiden Fällen
derselben Liste (`ClipboardHistoryViewModel.visible`).

Alle Aktionen sind auch per Maus erreichbar (Schaltflächen am Eintrag und in
der Vorschau, Doppelklick fügt ein). Das Fenster ist ein nicht aktivierendes
Panel (`ClipboardPanel`): es nimmt Tastatur an, die App davor bleibt aktiv.
Schließen beim Klick daneben läuft über `resignKey`, nicht über globale
Event-Monitore.

Mit einem Gamepad (Controller-Steuerung an und verbunden) ist der Verlauf ganz
ohne Tastatur bedienbar; die Fußzeile zeigt dann die Controller-Tasten statt der
Tastenkürzel. Belegung: [controller.md](controller.md#belegung).

Position: nahe dem Mauszeiger (Standard, auf dem Bildschirm unter dem Zeiger)
oder Bildschirmmitte. „Paste automatically“ aus: Enter legt den Eintrag nur in
die Zwischenablage.

## Was erfasst wird

- Text, mit RTF und HTML.
- Alle weiteren Typen der Kopie, wenn es welche gibt (Tabellen aus Excel oder
  Numbers mit Bild, App-eigene Formate, mehrere Einträge): als Archiv
  `<id>.pasteboard`, bis 16 MB je Kopie. Normales Einfügen schreibt das Archiv
  vollständig zurück, ⌥Enter nur den Text.
- Bilder (PNG; TIFF wird nach PNG gewandelt, Limit 12 MB als PNG). Beim
  Einfügen ohne Archiv kommen PNG und TIFF in die Zwischenablage.
- Vorrang: Dateien vor Text vor Bild. Liegt neben dem Text ein Bild (etwa
  Dateiname oder Alt-Text plus PNG), wird es ein Text-Eintrag, der immer ein
  Archiv bekommt; so kommt das Bild beim Einfügen mit.
- Datei-URLs (nur die Pfade, die Dateien selbst werden nicht kopiert).
- Herkunfts-App (`frontmostApplication` beim Kopieren), Zeitpunkt, Kopierzähler,
  Zeichenzahl. Ausnahme: Kopiert das Verlaufsfenster selbst (⌘C oder „Copy“
  in der Vorschau), zählt genau dieser Stand als WhisperM8; das Fenster
  aktiviert die App nicht, vorn bliebe sonst die App davor. Erkannt wird das
  am `changeCount`, der sich während eines Tasten- oder Klick-Ereignisses im
  Panel ändert. Was andere Apps schreiben, während das Fenster offen ist
  (Hintergrund-Apps, Universal Clipboard), behält die vordere App als
  Herkunft, die Ausschlussliste greift also weiter.
- Duplikate: derselbe Inhalt erneut kopiert wandert nach oben, Pin und ID bleiben.
  Erkannt wird am reinen Text; RTF, HTML und Archiv kommen von der neuesten
  Kopie. Die alten Dateien werden erst gelöscht, wenn der Index ohne sie auf
  der Platte steht (die CLI liest bis dahin noch den alten Index; ein Absturz
  davor ließe sonst nur die Vorschau übrig).

Gelesen wird die Zwischenablage im Hintergrund mit Zeitlimit von 3 s
(`ClipboardPasteboardReader`), weil große Bilder und lazy gelieferte Formate
die Quell-App sonst auf unserem Main Thread warten ließen. Hat sich die
Zwischenablage während des Lesens schon wieder geändert, wird verworfen; den
neuen Stand liest der nächste Takt.

Was beim Einschalten schon in der Zwischenablage liegt, wird bewusst nicht
nachträglich erfasst: seine Herkunft ist unbekannt, die Ausschlussliste
könnte nicht greifen.

## Suche

Der Store hält je Eintrag einen gefalteten Suchtext als UTF-8 im Speicher
(`ClipboardSearchIndex`), gebaut beim Aufnehmen und einmal beim Laden, beides
abseits des Main Threads. Beim Tippen läuft nur `memmem` über diese Bytes,
kein Dateizugriff und kein Falten langer Texte.

- Texte bis 512 KB (UTF-8) sind komplett durchsuchbar, längere über Anfang und
  Ende je 256 KB (bei Logs steht das Wichtige meist am Ende).
- Gesamtbudget 64 MB: wird es überschritten, bekommen die ältesten langen
  Einträge nur noch Anfang und Ende je 32 KB.
- Gesucht wird auch im Namen der Herkunfts-App und in Dateipfaden.
- Die CLI-Suche (`whisperm8 clipboard search`) nimmt dieselben Grenzen
  (Anfang und Ende je 256 KB), geschnitten an einem Trennzeichen, damit kein
  halber Schlüssel an der Schnittkante der Maskierung entgeht. Erst danach
  wird maskiert; vorher lief die Maskierung bei jedem Aufruf über jeden vollen
  Text und konnte das Zeitlimit des Plugins (15 s) reißen.

## Diktate im Verlauf

Jedes fertige Diktat (alle Modi, auch Fast und Retry) kommt genau einmal in
den Verlauf, mit Mikrofon-Symbol und Modus („Dictation (Slack) · Safari“).
Herkunft ist die App, in die diktiert wurde. Der Weg führt nicht über den
Monitor, sondern direkt aus dem Diktat-Ablauf
(`RecordingCoordinator.dictationHistoryRecorder` →
`ClipboardHistoryController.recordDictation`), denn die Schreibvorgänge des
Diktats sind beansprucht. So landen Bild-Anhänge und das Zurücklegen nach dem
Einfügen nicht als Extra-Einträge im Verlauf. Es gelten dieselben Regeln wie
für Kopien: Verlauf aus oder pausiert, oder Diktat in eine ausgeschlossene
App, dann kein Eintrag (`ClipboardHistoryCore.dictationCapture`). Den
Kontext, den das Diktat per Cmd+C einsammelt, erfasst der Verlauf nicht. Die
CLI zeigt das Feld `dictationMode`.

**Original-Transkript:** Hat ein Modus nachbearbeitet (alles außer Fast),
bleibt das Roh-Transkript am Eintrag (`dictationOriginal`), sofern es sich vom
Ergebnis unterscheidet und höchstens 100.000 Zeichen hat
(`ClipboardHistoryCore.keptOriginal`). Die Vorschau zeigt es unter dem
Ergebnis („Original transcript“), „Paste original“ fügt es als reinen Text
ein. Die Suche findet auch Wörter, die nur im Original stehen. CLI:
`hasOriginal` in `list`, `get <nr> --original`; Plugin-Tool: `original: true`.

**Schnellaktionen sind keine Diktate:** Das Ergebnis einer
[Schnellaktion](dictation/quick-actions/README.md) (⇧⌘K, Kopfzeile oder
„Correct & Paste“ im Fenster) läuft über denselben Weg, trägt aber
`fromQuickAction` am Eintrag (`ClipboardEntry.isQuickActionResult`). Das
Original ist dann der markierte Text vor der Nacharbeit, nichts Gesagtes.
Das Fenster zeigt einen Zauberstab statt des Mikrofons, „Quick action
(Correct)“ statt „Dictation (…)“ und „Before“ statt „Original transcript“;
der Filter ⌘D lässt solche Einträge weg. Die CLI nennt den Modus
`quickActionMode` statt `dictationMode` (Textliste „Aktion Correct“),
`hasOriginal` und `--original` bleiben. Ältere Indexdateien ohne das Feld
laden unverändert; ihre Einträge gelten als Diktate. Diktiert man denselben
Text später, wird der Eintrag beim Zusammenführen wieder ein Diktat.

## Datenschutz-Regeln

1. **Nie gespeichert:** Inhalte mit `org.nspasteboard.ConcealedType`,
   `TransientType` oder `AutoGeneratedType` (Passwort-Manager markieren so,
   dieselbe Prüfung nutzt die Diktat-Kontext-Erfassung über
   `PasteboardPrivacy`) sowie die Typen aus `ClipboardHistoryCore.ignoredTypes`
   (ältere 1Password-Versionen, KeeWeb, TypeIt4Me, Transient-Marker, dieselbe
   Liste wie bei Maccy).
2. **Ausgeschlossene Apps** (Bundle-IDs, in den Einstellungen bearbeitbar).
   Mitgeliefert: 1Password (drei Versionen), Bitwarden, Schlüsselbundverwaltung,
   Passwörter-App, KeePassXC, KeePassX, LastPass, Dashlane, Enpass, NordPass,
   Proton Pass. Die Einstellungen zeigen sie als eine aufklappbare Zeile,
   selbst ergänzte Apps einzeln.
3. **Eigene Schreibvorgänge der App** landen nicht über den Monitor im Verlauf:
   Diktat-Paste (Anhänge, Zurücklegen nach dem Einfügen), Kontext-Erfassung per Cmd+C mit Zurückschreiben und das
   Einfügen aus dem Verlauf. Technik: Wer schreibt, beansprucht danach genau
   den neuen `changeCount` (`ClipboardInternalWrites.claim`), zusätzlich trägt
   der Inhalt den Marker-Typ `com.whisperm8.app.clipboard-internal`. Der
   Monitor übergeht nur beanspruchte Stände; eine echte Kopie des Users direkt
   daneben wird erfasst. Die Kontext-Erfassung lässt eine fremde App schreiben
   (ihr Cmd+C) und klammert deshalb zusätzlich mit `begin()`/`end()`: solange
   die Klammer offen ist, wartet der Monitor, bis die Stände beansprucht sind.
4. **Agents:** Schalter „Let agents read the history“ (Standard an). Aus: CLI
   und Tool verweigern mit klarer Meldung. „Mask secrets for agents“ (Standard
   an) ersetzt vor der Ausgabe durch `[REDACTED:<art>]`: private
   Schlüsselblöcke, JWTs, GitHub-, Slack-, AWS-, Google- und Stripe-Schlüssel,
   `sk-…` (OpenAI, Anthropic), `Bearer` und `Basic`, Passwörter in URLs,
   `.env`-Zeilen (`OPENAI_API_KEY=…`, `DB_PASSWORD=…`), Zuweisungen und
   JSON-Felder wie `password=…` oder `"client_secret": "…"` sowie lange
   zufällige Base64-Ketten. Reine Hex-Ketten (Git-Hashes, SHA-256, MD5),
   UUIDs, Platzhalter (`<your-key>`, `${TOKEN}`) und reine Zahlen bleiben
   stehen. Die Suche der CLI läuft über den maskierten Text, damit niemand ein
   Geheimnis per Suche Zeichen für Zeichen erraten kann; `get` maskiert vor dem
   Zerteilen in Stücke. Die Oberfläche der App zeigt die Originale (das ist die
   eigene Zwischenablage des Users). **Bilder werden nicht maskiert:** `get`
   auf ein Bild liefert den PNG-Pfad, und der Agent sieht das ganze Bild, auch
   einen Schlüssel auf einem Screenshot. Der Untertitel des Schalters sagt das.
5. **Grenze:** Schalter und Maskierung wirken auf CLI und Tool. Die Dateien
   selbst gehören dem User (0600) und sind für jeden Prozess unter seinem Konto
   lesbar, also auch für einen Agent mit Shell-Zugriff, der gezielt
   `index.json` öffnet. Wer das ausschließen will, schaltet den Verlauf aus.
6. Der Verlauf liegt nur lokal. Optional „Clear when WhisperM8 quits“ (Pins
   bleiben). Logs enthalten nie Inhalte, nur Ereignisse.
   Die Maskierung kennt auch gesprochene Angaben aus Diktaten („das Passwort
   ist …“, „Kennwort lautet …“, „meine PIN ist …“). Die Vorschau in `list`
   und `search` entsteht aus dem maskierten Text und wird erst danach gekürzt.
   **Keine Sicherheitsgrenze:** Maskierung und Agent-Sperre wirken nur auf
   CLI und Tool. Ein Agent mit Shell kann die Zwischenablage (`pbpaste`) oder
   `index.json` direkt lesen; beides gehört demselben Benutzer.

## Speicherort

`~/Library/Application Support/WhisperM8/clipboard-history/` (über
`AppInstance.applicationSupport`, also auch in der Test-Instanz isoliert).
Ordner 0700, Dateien 0600 ab dem Anlegen (`open(…, 0600)`, dann `rename`).

| Datei | Inhalt |
|---|---|
| `index.json` | Schema `wm8.clipboard/1`, alle Einträge |
| `<id>.png` | Bild |
| `<id>.txt` | Text über 16.000 Zeichen |
| `<id>.rtf`, `<id>.html` | RTF und HTML, wenn es kein Archiv gibt |
| `<id>.pasteboard` | Archiv aller Typen (binäre Property-List) |
| `index.broken-<zeit>.json` | beiseitegelegter, unlesbarer Index |

Die App ist einziger Schreiber. Schreiben läuft auf einer seriellen Queue
(`ClipboardHistoryStore`), der Index wird gebündelt (Debounce 0,6 s) und
atomar geschrieben. Die CLI liest den Index direkt von Disk und sieht immer
einen vollständigen Stand.

Robustheit:

- Ein einzelner kaputter Eintrag im Index kostet nur sich selbst
  (nachsichtiges Lesen), nicht den ganzen Verlauf.
- Ist der Index gar nicht lesbar, wird er beiseitegelegt statt überschrieben;
  solange er da liegt, räumt die App keine Dateien weg.
- Dateien ohne Eintrag (Absturz zwischen Datei und Index) und Temp-Reste
  entfernt der Store beim Laden.
- Löschen eines Eintrags löscht alle seine Dateien.
- Zwei Knöpfe zum Leeren mit verschiedener Wirkung: „Clear history…“ in den
  **Einstellungen** löscht alles samt Pins und leert den ganzen Ordner, auch
  Reste und einen beiseitegelegten Index (`clear(keepPinned: false)`).
  „Clear History…“ in der **Fußzeile des Fensters** (und „Clear when WhisperM8
  quits“) löscht nur nicht angepinnte Einträge; Pins, ihre Dateien, Reste und
  ein beiseitegelegter Index bleiben (`clear(keepPinned: true)`).

Platz: Dateien nicht angepinnter Einträge (Bilder, Archive, lange Texte)
dürfen zusammen höchstens 512 MB belegen (`Limits.maxUnpinnedBlobBytes`); darüber
fallen die ältesten weg, der neueste bleibt immer.

Aufbewahrung: Standard 200 Einträge (20 bis 2000). Angepinnte zählen nicht
mit und werden nie gekürzt.

## CLI

```bash
whisperm8 clipboard status [--json]
whisperm8 clipboard list [--limit N] [--json]
whisperm8 clipboard search <text> [--limit N] [--json]
whisperm8 clipboard get <nr|id> [--json] [--max-chars N] [--from N] [--original]
whisperm8 clipboard copy <nr|id>
```

- Nummer 1 ist der neueste Eintrag (Zeitreihe; Angepinnte stehen dort, wo sie
  zeitlich hingehören, anders als im Fenster). Statt der Nummer geht eine ID
  oder ein eindeutiges Präfix ab 4 Zeichen. Nach `--` ist alles Text
  (`search -- -v fehler`).
- `status` zeigt Hauptschalter, Pause, Agent-Zugriff, Maskierung und Anzahl.
  Es verrät keinen Inhalt und geht deshalb auch bei gesperrtem Zugriff.
- `get`: Text in Stücken von 50.000 Zeichen (`--from N` liest weiter,
  `--max-chars 0` liefert alles); bei Bildern der **absolute Pfad der
  PNG-Datei** (der Agent liest sie mit seinem Datei-Werkzeug); bei Dateien die
  Pfade. Hinweise (gekürzt, maskiert) gehen auf stderr.
- `copy` ändert die Zwischenablage und geht deshalb über den Control-Socket
  (`clipboard.copy`, `AgentControlRequestHandler+Clipboard.swift`). Läuft die
  App nicht, meldet die CLI das (Exit 5) und verweist auf `get`.
- Lesen braucht die App nicht.

Exit: 0 ok, 1 Aufruf falsch, Verlauf aus oder Agent-Zugriff verweigert,
3 Eintrag nicht gefunden, 4 Kopieren fehlgeschlagen, 5 App nicht erreichbar
(4 und 5 nur bei `copy`).

### JSON

`list` und `search` liefern ein Array von Objekten mit `number`, `id`, `kind`
(`text`, `image`, `files`), `pinned`, `copiedAt` (ISO 8601), `preview`
(maskiert), `sourceApp` und `sourceBundleID` (wenn bekannt), dazu bei Text
`chars`, bei Bildern `imagePath`, `width`, `height`, bei Dateien `files`.

`get --json` ergänzt bei Text `text`, `totalChars`, `from`, `truncated`,
`nextFrom` (nur wenn gekürzt) und `secretsMasked`. `status --json` liefert
`enabled`, `paused`, `agentAccess`, `maskSecrets` und bei eingeschaltetem
Verlauf `entries`. Felder werden nur ergänzt, nicht umbenannt.

Quellen: `CLI/ClipboardCLICommand.swift` (Parser `ClipboardCLIArguments`,
Ausgabe `ClipboardCLIFormatter`, Ausführung `ClipboardCLIRunner` mit
injizierbarer Umgebung).

## Plugin-Tool und Skill

`WhisperM8/Resources/claude-plugin/hooks/register.tsx` registriert beim
Sessionstart eines WhisperM8-Chats das Tool `clipboard`
(`mcp__whisperm8__clipboard`), zunächst hinter ToolSearch. Danach fragt es
ohne zu warten `whisperm8 clipboard status --json` ab: sind Verlauf und
Agent-Zugriff an, steht das Tool direkt in der Liste, damit Claude es bei „was
ich kopiert habe“, „den Fehler von vorhin“ oder „aus der Zwischenablage“
sicher findet. Sonst kostet es keinen Kontext. Aktionen `list`, `search`
(`query`), `get` (`nr`, `from`, `maxChars`), jeweils über
`whisperm8 clipboard … --json`. Tests: `hooks/clipboard.test.ts`
(`make plugin-test`).

Dazu gehört der Plugin-Skill `whisperm8:clipboard`
(`Resources/whisperm8-clipboard-skill.md`): Claude lädt ihn, wenn du dich auf
Kopiertes oder Diktiertes beziehst, und du kannst ihn direkt aufrufen
(`/whisperm8:clipboard`, `/whisperm8:clipboard stripe webhook`,
`/whisperm8:clipboard 3`, `/whisperm8:clipboard diktate`). Wie `callout` und
`jarvis` gibt es ihn nur im Plugin, nicht als losen Skill unter
`~/.claude/skills`; ohne Plugin (Codex, Skripte) bleibt die CLI.

## Einstellungen

Seite „Clipboard“ (`SettingsPage.clipboard`, Gruppe App): Hauptschalter, Pause,
Hotkey (`SettingsKeyRecorderRow`), Position, automatisch einfügen, Anzahl,
beim Beenden leeren, Verlauf leeren, ausgeschlossene Apps (mitgelieferte
Passwort-Manager als aufklappbare Zeile, eigene einzeln mit Entfernen,
Hinzufügen per Bundle-ID oder aus laufenden Apps, Zurücksetzen), Agents-Zugriff,
Geheimnisse maskieren, Hinweis zu Maccy.

Die Zahl gespeicherter Einträge zählt die Seite abseits des Main Threads:
bei laufendem Verlauf über die Store-Queue (nach allen wartenden Änderungen),
bei abgeschaltetem nur den Index auf der Platte. Der Verlauf wird dafür nicht
in den Speicher geladen.

Die Schlüssel stehen in `ClipboardPreferenceKeys` (nicht in `PreferenceKeys`):
`clipboardHistoryEnabled`, `…Paused`, `…MaxItems`, `…AutoPaste`,
`…WindowPosition`, `…ExcludedApps` (JSON-Liste), `…AgentAccess`,
`…MaskSecrets`, `…ClearOnQuit`. Gelesen wird über
`ClipboardSettings.read`/`readLive` (auch aus der CLI über die App-Domain).
`PreferenceBedienwegGuardTests` prüft auch diese Schlüssel auf einen UI-Weg.

## Kill-Switch und Maccy

`defaults write com.whisperm8.app clipboardHistoryEnabled -bool NO` schaltet
Monitor und Hotkey ab (es ist zugleich der UI-Schalter). Aus: kein Polling, der
Hotkey ist freigegeben (`KeyboardShortcuts.disable`), der Menüeintrag ist weg,
CLI und Tool verweigern.

**Maccy:** Beide nutzen standardmäßig ⇧⌘C. Wer Maccy nutzt, beendet es
und aus den Anmeldeobjekten nehmen, sonst gewinnt eine der beiden Apps den
Hotkey zufällig. Der alte Maccy-Verlauf wird nicht übernommen.

## Performance

Der Monitor ist ein Timer (0,5 s, Toleranz 0,2 s) auf `changeCount`: im
Leerlauf ein Zahlenvergleich. Bei einer Änderung prüft der Main Thread nur
Typen und Herkunft; Lesen, Bildumwandlung, Hashen, Suchindex und Schreiben
laufen im Hintergrund bzw. auf der Store-Queue. Das Fenster liest keine
Dateien in Bodys: Miniaturen (verkleinert auf 96 px über `CGImageSource`) und
Vorschau (1200 px, bei langen Texten der Anfang aus der Datei) lädt das
ViewModel abseits des Main Threads und nur bei offenem Fenster; die Liste wird nur bei geänderter Suche oder geänderten
Einträgen neu berechnet. Keine Dauerbewegung, kein Hover-only-UI.

## Zentrale Dateien

| Datei | Rolle |
|---|---|
| `Services/Clipboard/ClipboardHistoryCore.swift` | pure Entscheidungen: Erfassen, Duplikate, Kürzen, Reihenfolge, Nummern, Suche |
| `Services/Clipboard/ClipboardSearchIndex.swift` | Suchtext je Eintrag im Speicher, Budget |
| `Services/Clipboard/ClipboardSecretMasker.swift` | pure Maskierung |
| `Services/Clipboard/ClipboardHistoryStore.swift` | Persistenz (Index, Dateien, Rechte, Aufräumen) |
| `Services/Clipboard/ClipboardMonitor.swift` | Polling, `ClipboardInternalWrites`, Lesen im Hintergrund |
| `Services/Clipboard/ClipboardRestore.swift` | Eintrag zurück in die Zwischenablage |
| `Services/Clipboard/ClipboardHistoryController.swift` | Lebenszyklus, Hotkey, Panel, Einfügen |
| `Services/Clipboard/ClipboardSettings.swift` | Schlüssel, Standardwerte, Lesen |
| `Services/Clipboard/ClipboardKeyCommand.swift` | Hotkey-Name, Tasten im Fenster |
| `Views/Clipboard/` | Fenster und ViewModel |
| `Windows/ClipboardPanel.swift` | nicht aktivierendes Panel |
| `Views/Settings/Pages/ClipboardSettingsPage.swift` | Einstellungsseite |
| `CLI/ClipboardCLICommand.swift` | CLI |
| `Services/AgentChats/AgentControlRequestHandler+Clipboard.swift` | `clipboard.copy` |

## Keywords

Zwischenablage, Clipboard, Maccy, Verlauf, Pin, ConcealedType, Passwort-Manager,
`ClipboardHistoryController`, `ClipboardInternalWrites`, `ClipboardSearchIndex`,
`whisperm8 clipboard`, `clipboard.copy`.
