---
status: aktiv
updated: 2026-11-12
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
Entwürfe: [`../design/controller-steuerung.html`](../design/controller-steuerung.html), für die Insel
[`../design/controller-insel.html`](../design/controller-insel.html).

## Einschalten

Einstellungen › Controller (Gruppe Labs). Ab Werk aus. Wird zum ersten Mal ein Gamepad erkannt,
während die Steuerung aus ist, erscheint einmal eine Mitteilung.

| Schalter | Standard | Wirkung |
|---|---|---|
| Controller-Steuerung | aus | liest Gamepads, zeigt Legende und Markierung |
| Legende am unteren Rand | an | Leiste mit Ziel und Tastenbelegung |
| Vibration | an | Impulse bei Aufnahme, wartenden Chats und geleerter Eingabe |
| Lichtleiste | an | Farbe nach Zustand |
| Auch wenn ein anderes Programm vorne ist | aus | Diktat und Verlauf überall; in Spielen ist R2 meist Gas oder Schuss |
| Bei Eingabe WhisperM8 nach vorn holen | an | nur mit dem Schalter darüber: Ist ein anderes Programm vorne, holt fast jede Eingabe das Agent-Chats-Fenster nach vorn |

**Aufwecken:** Ist ein anderes Programm vorne und sind beide Schalter an, holt jede Taste beim
Drücken und jeder Stick- oder Steuerkreuz-Ausschlag das Agent-Chats-Fenster nach vorn. Ausnahmen: R2
diktiert weiter in das Programm vorne, das Touchpad öffnet den Verlauf. L1, R1 und L2 wecken erst beim
Tippen, denn gehalten könnten sie der Anfang der Pause L1 + R1 sein. Die weckende Eingabe tut sonst
nichts: Bis alles losgelassen ist, verwirft der Manager die restlichen Gesten. Die Pumpe meldet dazu
mit jedem Paket, ob der Erkenner danach ruhig ist. Entschieden wird in der Reihenfolge auf dem Main
Thread, damit auch schon unterwegs befindliche Gesten nicht durchrutschen. Sonst käme etwa das
Loslassen von Kreis im Chat als Escape an. Durch gehen nur L1 + R1 (Pause) und R2. Ist ein Spiel vorne,
pausiert der Controller ohnehin und weckt nicht. Spiele im Browser erkennt die Pause nicht: Dort
holt jeder Stick WhisperM8 nach vorn, bis man mit L1 + R1 pausiert oder den Schalter ausschaltet.

Notbremse: `defaults write com.whisperm8.app controllerFeatureEnabled -bool NO` — kein Zugriff auf
das GameController-Framework, der Schalter wirkt nicht.

## Belegung

Grundregeln: Links navigieren, rechts sprechen und handeln. Ein Fokus (die Auswahl, die die App schon
hat), dazu eine Markierung in der Liste. Die Legende zeigt immer nur die Tasten, die gerade etwas tun.

**Kern**

| Taste | Wirkung |
|---|---|
| Linker Stick | Liste hoch/runter; nach rechts in den Inhalt, nach links zurück in die Liste; in der Einzelansicht springt die Markierung mit hoch/runter in die Liste (Start beim aktuellen Chat, sofort ein Schritt, der offene Chat bleibt); im Raster von Kachel zu Kachel; während Aufnahme, Transkription und Nacharbeit ohne Wirkung |
| Kreuz | in der Liste öffnen (Chat, Workspace, Projekt als Workspace) und hinein — ein Chat unter einem Workspace, der nicht sichtbar ist, öffnet diesen Workspace mit dem Chat als Kachel-Fokus (nur Kreuz; der Mausklick folgt der Klickregel; besitzt ein anderes Fenster den Workspace, wird der Chat nach der Klickregel geöffnet); im Chat Enter; gestoppter Chat: starten |
| Kreis | zurück (aus der Liste ohne Wechsel in den bisherigen Chat); im Chat Escape (nur wenn er ruht oder fragt); halten (0,4 s): arbeitenden Chat unterbrechen |
| R2 | Diktat an und aus (Umschalter wie der Hotkey, kein Halten) |
| Dreieck | im Chat ein Leerzeichen (lebende Claude- und Codex-Chats, kein Wiederholen beim Halten; in Shells „geht nicht“); aus anderen Fenstern und außerhalb der App: Agent Chats nach vorn; im Zwischenablage-Verlauf korrigieren und einfügen. Den Sprung zum nächsten wartenden Chat gibt es am Controller nicht mehr (Tastatur: ⌃⌥Tab) |
| L1 / R1 tippen | voriger / nächster Chat in der Reihenfolge der Liste (auch im Raster, kein Umlauf); in der Liste der Filter Aktiv / Zuletzt / Alle. Die Tastatur (⌘⌥←/→) bleibt bei den Tabs. Gehalten sind sie Ebenen (siehe „Ebenen und Insel“), ein Durchlaufen beim Halten gibt es nicht |
| Steuerkreuz | in jedem lebenden Chat Pfeiltasten ins Terminal (Claude, Codex, Shell; ruhend, arbeitend oder fragend, auch im Raster), mit Wiederholung beim Halten. So erreicht man Subagenten-, Workflow- und Aufgabenansichten von Claude und jede Auswahlliste der CLI. Rechts übernimmt in Claude den grauen Vorschlag, Kreuz schickt ihn dann ab. **Ausnahme links:** Im vermutlich leeren Claude-Feld (direkt nach dem Absenden, seither nichts im Feld, keine Rückfrage, keine offene Auswahl) „geht nicht“, denn dort schickt ← die ganze Sitzung in Claudes Agent-Ansicht. Hoch holt den letzten Prompt zurück; er gilt dann als Rückleger, den „Weiter“, Menü-Befehle und `chats send` vorher leeren. In der App (Liste, Kacheln) bewegt nur der linke Stick. Ohne lebendes Terminal (beendeter Chat) wie der Stick. Entscheidung vom 12.11.2026; vorher gab es Pfeile nur in Rückfragen, offenen Listen und Codex |
| Rechter Stick | Verlauf scrollen (im Alternate-Puffer als Mausrad an die TUI), auch während Aufnahme, Transkription und Nacharbeit |

**Zusatz**

| Taste | Wirkung |
|---|---|
| Viereck | im Chat Rücktaste (ein Zeichen); halten: weiter löschen wie beim iPhone — ab 0,6 s Zeichen alle 60 ms, nach einer weiteren Sekunde ganze Wörter alle 150 ms (Ctrl+W; in Shells weiter Zeichen); in der Liste halten: Zeile schließen wie ihr „−“/„×“ |
| Create | Projekt-Auswahl „Neuer Chat“ (wie ⌘N), aktuelles bzw. markiertes Projekt vorausgewählt — „Create, Kreuz“ startet dort |
| Touchpad-Klick | Zwischenablage-Verlauf auf und zu; ebenso L2 + Touchpad (überall) und „Zwischenablage-Verlauf“ im Options-Menü |
| L3 | Kachel groß / zurück zum Raster |
| R3 | tippen: gestoppten Chat starten (im Chat und auf der markierten Zeile der Liste), sonst ohne Wirkung, auch ohne Vibration; halten (0,6 s): ganze Eingabe leeren, mit kurzer Vibration — Claude und Codex, nicht während einer Rückfrage; in einer Shell nur an der Eingabezeile (nicht in nano, vim und anderen Vollbild-Programmen) |
| Options | das eine Menü, siehe unten |
| L2 tippen | zurück dorthin, wo du vorher warst — voriger Chat oder voriger Workspace als Raster (siehe „Zurück mit L2“); gehalten die Ebene „Wohin“ (wie Cmd-Tab: Loslassen ohne Bewegung führt zum selben Ziel) |
| L1 + R1 halten (1 s) | Controller pausieren und fortsetzen (in jedem Abstand gedrückt; weder Chatwechsel noch Ebene) |

Nicht belegt: PlayStation-Taste (gehört macOS), Create doppelt oder lang (macOS: Screenshot bzw.
Bildschirmaufnahme). Zwei schnelle Create-Drücke ergeben deshalb einen Screenshot.

**Zurück mit L2:** L2 getippt führt an den vorigen Ort des Fensters, ein zweites Tippen wieder zurück
(wie ein kurzes Alt-Tab). Ein Ort ist ein einzelner Chat oder ein Workspace im Raster. Kachelwechsel im
selben Raster sind kein Ortswechsel; eine große Kachel (L3) und jeder Chat in der Einzelansicht, der zum
gemerkten Workspace gehört, zählen als dieser Workspace. Ein Workspace öffnet wie der Klick auf seinen
Kopf als Raster, mit der Kachel, auf der du dort zuletzt warst; ein Chat wie der Klick in der
Seitenleiste. Gibt es den vorigen Ort nicht mehr (Workspace gelöscht oder von einem anderen Fenster
gezeigt, Chat archiviert, geschlossen oder in ein anderes Fenster gewandert), vibriert der Controller
„geht nicht“ und nichts passiert — kein fremdes Fenster kommt nach vorn, kein Dialog erscheint. Ein Chat,
der im Workspace liegt, den das Fenster gerade referenziert, ist kein Ziel: Ihn zu wählen gäbe nur den
Fokus einer Kachel, L2 hinge auf der Stelle. Öffnet man aus Chat A einen Workspace mit A, bleibt das
Ziel von davor. Wer den
aktuellen Ort schließt, landet mit L2 dort, wo er davor war. Die Legende nennt das Ziel („Zurück:
Workspace Marketing“, „Zurück: Chat Login-Fix“) und fehlt ohne Ziel. Der Verlauf gilt je Fenster und
nur für den laufenden App-Start; er wird im Store nach jeder Änderung nachgeführt
(`AgentWindowStore+PlaceHistory`, pur: `ChatPlaceHistory`), zählt also Maus, Tastatur, Controller und
CLI gleich. Die Legende liest ihn im Ereignis-Pfad; nach einem Klick mit der Maus steht dort bis zur
nächsten Eingabe oder Statusänderung noch das alte Ziel.

**Menü (Options):** drei Gruppen. Eingaben in den Chat: „Weiter“, „Befehle ›“ (zweite Ebene mit den
festen Befehlen der CLI, Tabelle `ControllerSlashCommands`; „/ eintippen“ bleibt ungesendet, alle
anderen werden gesendet; Befehle, nach denen die CLI eine Liste zeigt, setzen „Auswahl offen“), „Modus
wechseln“ (Shift+Tab). Aktionen am Chat, dieselben Wege wie sein
Kontextmenü: „Konto wechseln ›“ (Claude-Konten wie „Zu Account verschieben“, bei GPT-Chats auch die
GPT-Konten), „Umbenennen…“, „Forken“, „Anheften/Lösen“, „Archivieren“, „Chat schließen“ (wie „−“/„×“
in der Seitenleiste). Dazu „Zwischenablage-Verlauf“, „Belegung anzeigen“ und „Controller pausieren“. In der Liste wirken die
Aktionen auf die markierte Chat-Zeile. Kreis geht eine Ebene zurück, Options schließt alles.

## Ebenen und Insel

L1, R1 und L2 sind **Ebenen-Tasten** (Runde 4). Tippen (kürzer als 0,3 s und ohne zweite Taste
dazwischen, auch ohne Stoß von Stick oder Steuerkreuz und ohne Scrollen mit dem rechten Stick) löst beim Loslassen aus, was die Taste schon
immer tat. Gehalten wird sie zur Ebene: Kombinationen wirken sofort beim Druck der zweiten Taste, die
0,3 s bestimmen nur, wann die **Insel** erscheint. Loslassen nach Halten ohne Kombination tut nichts,
außer bei L2: Dort wechselt Loslassen zum markierten Eintrag (siehe „Wohin“). Es gilt immer nur eine Ebene; eine zweite Ebenen-Taste ist darin eine
gewöhnliche Taste. Ebenen wirken im Chat und im Raster (auf den Chat der fokussierten Kachel). In der
Liste, im Zwischenablage-Verlauf, im Menü, in Dialogen und während der Aufnahme wirken die Tasten wie
ohne Ebene. R2 diktiert auf jeder Ebene (unter L2 heißt R2 „hin und diktieren“).

| Ebene | Taste | Wirkung |
|---|---|---|
| L1 Schreiben | Viereck | bis Zeilenanfang löschen (Ctrl+U, wie ⌘ + Rücktaste); gehalten nach 0,4 s Zeile für Zeile alle 150 ms |
| | Dreieck | Zeilenumbruch ohne Senden (Ctrl+J, siehe Schutzregeln) |
| | Kreuz, Kreis | frei (in der Insel ausgegraut) |
| R1 Schnellbefehle | Kreuz | „Weiter“ senden |
| | Dreieck | Modus wechseln (Shift+Tab) |
| | Viereck | Befehle › — öffnet das Options-Menü direkt auf dieser Unterseite |
| | Kreis | Konto wechseln › — ebenso |
| L2 Wohin | (halten) | die Liste steht sofort da, ohne Hinweiszeile davor; die Markierung steht auf dem vorigen Ort (siehe unten) |
| | Stick/Steuerkreuz hoch/runter | Markierung bewegen (mit Wiederholung) |
| | links/rechts | Reiter Chats / Workspaces; die Markierung beginnt dort wieder auf dem vorigen Ort, wenn er in diesem Reiter steht, sonst auf dem aktuellen Eintrag |
| | Loslassen, Kreuz | sofort zum markierten Eintrag wechseln, wie Cmd-Tab. Steht die Markierung auf dem aktuellen Eintrag, passiert nichts. Loslassen wechselt nur, solange der Chat die Eingaben hat; startet währenddessen eine Aufnahme per Hotkey oder geht ein Dialog oder Sheet auf, schließt es nur die Insel |
| | Kreis | abbrechen, nichts passiert |
| | Dreieck | zum nächsten wartenden Chat, reihum (derselbe Weg wie ⌃⌥Tab); schließt die Insel |
| | R2 | zum markierten Chat wechseln und diktieren; steht die Markierung auf dem aktuellen Chat oder Workspace, in den aktuellen Chat; ein anderer Workspace „geht nicht“. Scheitert der Wechsel, wird nicht diktiert („geht nicht“). Weil die Markierung auf dem vorigen Chat beginnt, diktiert L2 halten + R2 ohne Bewegung in den vorigen Chat (die Fußzeile sagt im Reiter Workspaces „hier diktieren“) |
| | Touchpad drücken | Zwischenablage-Verlauf auf und zu; schließt die Insel. Gilt überall, auch außerhalb des Chats, im Verlauf selbst und außerhalb der App (mit Hintergrund-Empfang) — dort über die Belegung ohne Ebene |

Ein Schnellbefehl oder Wechsel schließt die Insel; bis zum Loslassen der Taste kommt sie nicht wieder.
Ein Schnellbefehl, der gerade nicht geht, vibriert und lässt sie offen.

**Wohin wie Cmd-Tab** (Entscheidung vom 12.11.2026): Die Markierung beginnt auf dem vorigen Ort, also
genau dem Ziel von L2 getippt (`ControllerBackTarget` mit ID, aus `AgentWindowStore+PlaceHistory`).
Halten und Loslassen ohne Bewegung führt deshalb dorthin, wo auch Tippen hinführt; wer woanders hin
will, bewegt vorher die Markierung. Die Zeile des vorigen Orts trägt rechts „vorher“. Der Start-Reiter
folgt dem vorigen Ort: ein Workspace öffnet den Reiter Workspaces, ein Chat den Reiter Chats, auch wenn
man gerade im Raster bzw. in der Einzelansicht ist (sonst täte Loslassen etwas anderes als Tippen).
Ohne vorigen Ort gilt wie bisher: im Raster Workspaces, in der Einzelansicht Chats, und die Markierung
steht auf dem aktuellen Eintrag, damit Loslassen nichts aus Versehen wechselt. Hat ein Reiter weder
vorigen noch aktuellen Eintrag (Workspaces in der Einzelansicht ohne Workspace), gibt es dort zunächst
keine Markierung; der erste Stoß markiert die erste Zeile. Die frühere Regel „Wechsel nur nach einer
Bewegung im sichtbaren Reiter“ ist damit weg. Ist das Ziel der vorige Ort, geht der Wechsel denselben Weg
wie L2 getippt (`lastChat`); Halten und Tippen enden also gleich, auch bei einem Fehlschlag. Die Chats
stehen in der Reihenfolge der Liste links, jeder einmal; der vorige Chat steht immer darin, gleich
hinter dem aktuellen, auch wenn die Seitenleiste ihn gerade nicht zeigt (Filter, Suche, eingeklappte
Gruppe, Archiv-Ansicht); rechts Wort und Dauer wie Tab-Switcher und Notch („wartet · 2 min“, „bereit“, beim aktuellen
„jetzt“). Die Workspaces sind die angelegten (ohne versteckte Projekt-Ansichten) in der Reihenfolge der
Seitenleiste, mit Farbe, Name, Raute „wartet“ und Zahl der Chats. Höchstens sechs Zeilen, die Liste rückt
mit der Markierung, darunter „+ n weitere“. Ein Chat wechselt wie der Klick in der Seitenleiste, ein
Workspace wie der Klick auf seinen Kopf, aber still: Gehört er einem anderen Fenster oder laufen seine
Chats dort, kommt kein Fenster nach vorn und kein Dialog, der Controller vibriert „geht nicht“
(`switchToWorkspace`). Danach hat die Kachel den Fokus, auf der du dort zuletzt warst (gemerkt beim
Verlassen, nur für den laufenden App-Start).

**Die Insel** ist ein eigenes, nicht aktivierendes Fenster ohne Maus (`ControllerIslandPresenter`),
einmal aufgebaut, danach nur ein- und ausgeblendet. Sie erscheint auf dem Bildschirm des
Agent-Chats-Fensters, auf dem der Controller wirkt — unabhängig von der Bildschirmwahl der
Notch-Anzeige. Mit Notch wächst sie als schwarzes Band in Notch-Breite mit Körper darunter
(`NotchHangingShape`). Ohne Notch wächst sie aus der Pille der Notch-Anzeige, die dort immer steht
(siehe [notch.md](notch.md)): genau an ihrer Stelle (ist sie sichtbar, zählt ihr tatsächlicher
Mittelpunkt, auch bei automatisch ausgeblendeter Menüleiste), im dunklen Glas der Diktat-Pille
(`PillGlassBackground`, gleicher Rand und Schatten), immer dunkel. Sitzt die Pille in der oberen
Bildschirmhälfte, öffnet die Insel nach unten (gemeinsame Oberkante), in der unteren nach oben
(gemeinsame Unterkante); sie bleibt immer ganz auf dem Bildschirm (`NotchPillPlacement.frame`). Sie
liegt eine Ebene über der Notch-Anzeige (`mainMenu + 4`): Steht die Notch-Anzeige auf diesem
Bildschirm, überdeckt die Insel sie und zeigt rechts im Kopf deren Zähler (arbeitet/wartet) — nur bei
„Wohin“; bei Schreiben und Schnellbefehlen steht dort immer der Ziel-Chat. Eine aufgeklappte
Notch-Liste klappt zu. Auch über einem Vollbild-Fenster erscheint die Insel (`fullScreenAuxiliary`,
nur sie, nicht die Notch-Anzeige): an der Notch in der Aussparung, sonst an der gemerkten Stelle der
Pille (ohne Menüleiste oben am Bildschirmrand). Eine Bewegung beim Öffnen, eine beim Schließen
(0,25 s, bei „Bewegung reduzieren“ keine), sonst nichts in Bewegung. Maus oder Tastatur schließen sie
für das laufende Halten.

Mit der vereinten Pille (siehe [notch.md](notch.md)) ist die Pille, aus der die Insel wächst,
dieselbe wie die Diktat-Pille; die Insel hat dort Vorrang vor allem anderen. Ihr Aussehen (Glas,
Rand, Schatten der Diktat-Pille) blieb gleich.

Die Insel ersetzt am Controller den Ctrl+Tab-Umschalter (der Tastatur bleibt er) und die frühere
Workspace-Auswahl unten im Fenster. Die Legende schaltet beim Halten nicht um; sie nennt die Ebenen in
einem Eintrag („L1 R1 L2 Halten: Ebenen“).

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
- Pfeiltasten gehen in jedem lebenden Chat ins Terminal (seit 12.11.2026, siehe Steuerkreuz), mit drei
  Absicherungen:
  1. Links nie ins vermutlich leere Claude-Feld. Erlaubt in einer Rückfrage, in einer offenen Auswahl
     im Ruhezustand und sobald irgendetwas im Feld stehen kann: getippt, diktiert, Rückleger nach einem
     Abbruch, mit ↑ zurückgeholt oder mit → als Vorschlag übernommen (`fieldMayHaveText`). Gesperrt nur
     direkt nach dem Absenden, solange seither nichts ins Feld kam. Dort schickt ← die Sitzung in
     Claudes Agent-Ansicht, so gingen am 12.11.2026 zwei Sitzungen verloren. Geprüft in der Belegung (`leftArrowAllowed`) und in
     `AgentTerminalController.sendKey` (`TerminalControlKey.controllerAllows` mit dem Entwurfs-Tracker).
  2. Hoch vom Controller (ohne Rückfrage und offene Auswahl) holt den letzten Prompt zurück. Bei Claude
     gilt er als Rückleger: „Weiter“, Menü-Befehle und `chats send` leeren das Feld vorher; bei Codex
     und Shell gilt er als Entwurf. Und ↑ als erster Pfeil macht Kreuz bei arbeitendem Chat nicht scharf.
  3. Kreuz bei arbeitendem Claude-Chat nur bis 5 s nach einem scharfen Pfeil (`arrowArmWindow`, ↓/←/→
     oder ↑ nach einem scharfen Pfeil): kurz, wegen der Lücke vor einem Freigabe-Dialog, in der Enter
     die Vorauswahl bestätigte. Codex behält die 30-s-Regel (Freigaben ohne „wartet“).
     Ausnahme →: Es übernimmt den grauen Vorschlag ins Feld und zählt deshalb wie getippter Text
     (30 s). Sonst sperrte Kreuz nach 5 s, wenn der Chat noch als „arbeitet“ galt.
  In einer Shell im Ruhezustand sind ↑ und Kreuz wie an der Tastatur: der letzte Befehl läuft erneut.
- „Auswahl offen“ (`ControllerTerminalMarks`, je Chat am Terminal): gesetzt, wenn das Menü einen
  Befehl schickt, nach dem die CLI eine Liste zeigt — Claude „/“, `/model`, `/config`, `/resume`,
  `/permissions`, `/mcp`, `/agents`, `/memory`; Codex „/“, `/model`, `/approvals`. Solange er steht,
  gehen Pfeile ins Terminal, Kreuz schickt Enter, und Kreis schließt die Liste auch direkt nach dem
  Befehl. Bei Claude gilt er nur, solange der Chat ruht: Er wird nicht gesetzt, wenn der Chat beim
  Senden nicht ruht, und fällt, sobald er arbeitet oder fragt (auch bei einem Turn, den Claude selbst
  beginnt). Er fällt außerdem mit Enter und Escape vom Controller, Rücktaste, Wort löschen, Leeren,
  Tab/Shift+Tab, mit jedem Text in den Chat, mit jeder Taste der Tastatur außer Pfeilen und
  Leerzeichen und spätestens 2 min nach dem Öffnen (keine Verlängerung). Ein Chatwechsel lässt ihn
  stehen: Die Liste im Terminal bleibt ja offen. Grenze:
  Öffnet Enter in einer Liste eine weitere (Untermenü in `/config`, `/mcp`, `/agents`), ist der
  Merker trotzdem weg — dann den Befehl erneut über das Menü öffnen oder die Tastatur nehmen.
- Codex meldet keine Rückfragen (keine Hooks); seine Freigaben erscheinen, während der Status
  „arbeitet“ zeigt. Erst mit dem Steuerkreuz wählen, dann bestätigt Kreuz — ohne Pfeil bleibt Kreuz bei
  „arbeitet“ ohne Wirkung.
- „Weiter“ aus dem Menü wird nicht an einen vorhandenen Entwurf gehängt.
- Eingaben aus dem Menü („Weiter“, „Modus wechseln“, Befehle) gehen an den Chat, für den das Menü
  geöffnet wurde. Hat sich die Auswahl seither geändert, geht nichts raus („geht nicht“, Menü zu).
- Kreuz während der Aufnahme sendet nur bei Claude und Codex; in einer Shell wäre der Text ein Befehl.
- Solange das Mikrofon verbindet, zählt das als Aufnahme: R2 beendet (sobald sie läuft), Kreis verwirft.
- Kreuz ist 0,5 s nach Erscheinen einer Rückfrage ohne Wirkung.
- Arbeitet der Chat oder ist sein Zustand unklar, schickt Kreuz Enter nur, wenn in den letzten 30 s
  per Controller getippt, gelöscht oder diktiert wurde und seitdem nichts abgeschickt wurde — auf
  keinem Weg: Kreuz auch in einer Rückfrage, Enter der Tastatur, `chats send`, Diktat mit Senden,
  Befehle aus dem Menü. Zwischen dem Erscheinen eines Freigabe-Dialogs und dem Status „wartet“ liegt
  eine Lücke, in der Enter sonst die Vorauswahl bestätigte. Der Entwurfs-Verdacht zählt dafür nicht,
  und Tippen auf der Tastatur auch nicht.
- Ein zweites Escape innerhalb 1 s wird verschluckt (Claude öffnet sonst das Zurückspulen).
- Escape per Tippen nur bei ruhendem oder fragendem Chat; „gerade gesendet“ (3 s nach jedem
  Versand: Enter vom Controller oder der Tastatur, Diktat mit Senden, `chats send`) und unbekannter
  Status zählen als arbeitend — außer bei offener Auswahl des Menüs.
- Pause (L1 + R1, Sperre, Ruhezustand, Spiel), Trennung und Ausschalten schließen Insel, Menü und Liste.
  Ein per Tastatur geöffneter Ctrl+Tab-Umschalter schließt erst, wenn der Controller wirklich etwas
  ausführt (das bloße Loslassen einer Ebene ohne offene Insel zählt nicht).
- Die R1-Raute folgt den Regeln des Options-Menüs (`ControllerMenuModel.isEnabled`): Bei offener
  Rückfrage sind „Weiter“, „Modus wechseln“ und „Befehle“ aus, „Konto wechseln“ geht. Die Rückfrage wird
  beim Drücken frisch gelesen.
- „Weiter“ und „Modus wechseln“ — in der Raute und im Options-Menü — nur, wenn der Chat ruht: nicht bei
  „arbeitet“, unbekanntem Status oder 3 s nach einem Absenden. Zwischen dem Erscheinen eines
  Freigabe-Dialogs und dem Status „wartet“ bestätigte „Weiter“ mit Enter die Vorauswahl, und Shift+Tab
  heißt dort „alle Änderungen erlauben“; Codex meldet nie „wartet“. Ausgegraut mit Hinweis in der Insel,
  ein Druck vibriert „geht nicht“; geprüft wird beim Auslösen frisch (`perform(_:setup:)`). Eingaben gehen an den Chat, der beim Öffnen der Insel ausgewählt war;
  sonst „geht nicht“.
- L1-Ebene: Bis Zeilenanfang löschen (Ctrl+U, 0x15) und Zeilenumbruch (Ctrl+J, 0x0A) nur bei Claude und
  Codex und nicht in einer Rückfrage — dieselben Regeln wie „Eingabe leeren“, auch in der Absicherung
  `controllerAllows`. In einer Shell zeigt die Insel den Hinweis, und es passiert nichts außer „geht
  nicht“. Beides schließt „Auswahl offen“ und zählt als Eingabe per Controller für die 30-s-Regel.
- Zeilenumbruch ist Ctrl+J, nicht Shift+Enter (kommt ohne Kitty-Protokoll im PTY als CR an und würde
  senden). Belegt: Claude Code, interactive mode, „Multiline input“: „Control sequence `Ctrl+J`: works
  in any terminal without configuration“; Codex: Standard von `editor.insert_newline` in
  `codex-rs/tui/src/keymap.rs` ist `ctrl-j` (dazu `ctrl-m`, Shift/Alt+Enter), `composer.submit` liegt
  nur auf Enter; crossterm liest 0x0A im Raw-Modus als Ctrl+J. Für den Entwurfs-Tracker gilt er wie
  Shift+Return (Entwurf vorhanden, kein Absenden).
- Viereck schickt nur die Rücktaste (0x7F) bzw. Ctrl+W, nie Ctrl+C — Ctrl+C hätte eine laufende
  Antwort abgebrochen. Wort löschen ist bewusst Ctrl+W und nicht Option+Rücktaste (ESC DEL): Ein
  einzelnes ESC bricht einen arbeitenden Chat ab. Belegt: Claude Code („Delete back to previous
  whitespace“, also ganze Pfade auf einmal), Codex (`delete_backward_word` in
  `codex-rs/tui/src/keymap.rs`), zsh und bash (`backward-kill-word`).
- Leerzeichen, Wort löschen und Eingabe leeren nur bei Claude und Codex; in einer Shell läuft oft ein
  Programm mit eigener Belegung (nano fügt mit Ctrl+U ein, vim und emacs deuten Ctrl+W und Ctrl+E
  anders). Die Rücktaste bleibt in Shells, wie die echte Taste; gehalten löscht sie dort nur Zeichen.
- Eingabe leeren (R3 halten) wirkt auf den Chat, der beim Drücken ausgewählt war; ist beim Auslösen
  ein anderer ausgewählt, wird nichts geleert („geht nicht“).
- Eingabe leeren (R3 halten) schickt Ctrl+E und dann 128 × Ctrl+U in Stößen alle 15 ms, nie Ctrl+C
  oder ESC. Ctrl+U löscht bis zum Zeilenanfang und am Zeilenanfang den Umbruch davor (Claude Code:
  „Repeat to clear across lines“; Codex: `kill_line_start`) — reicht für 64 Zeilen. Text unter einer
  Zeile, in die der Cursor per Tastatur bewegt wurde, bleibt stehen. In einer Rückfrage wird nicht
  geleert: Dort wählt man aus. Scrollt der rechte Stick, verfällt ein R3-Druck ganz. In einer
  Shell leert R3 nur die Eingabezeile, erkannt am normalen Terminal-Puffer; Vollbild-Programme
  laufen im Alternate-Puffer, dort bedeuten Ctrl+E und Ctrl+U etwas anderes. Pager wie `less`
  (etwa der von `git log`) laufen oft im normalen Puffer; dort scrollen Ctrl+E und Ctrl+U nur, das
  ist harmlos. Danach gilt auch dort der Entwurfs-Verdacht als erledigt, und `chats send` geht
  wieder.
- Bekannte Grenze: Steht zsh oder bash im Vi-Modus, leert R3 die Zeile nicht ganz. Ctrl+E wird
  dort als Zeichen eingefügt, und Ctrl+U löscht nur bis zum Beginn des Eingabemodus. Die Zeile gilt
  danach trotzdem als leer.
- Befehle und „Weiter“ aus dem Menü werden nie an einen vermuteten Entwurf gehängt.
- R3 getippt auf einem lebenden Chat tut nichts (er wird beim Scrollen leicht gedrückt).
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
| Rückmeldung | `ControllerFeedback` | Lichtleiste, Warte-Signal, automatische Pause, Maus/Tastatur geben Liste, Menü und Insel ab |
| Insel | `Core/ControllerIsland.swift`, `ControllerActionDispatcher+Island.swift`, `ControllerIslandPresenter`, `Views/Controller/ControllerIslandView.swift` | Modell pur im Kern, gebaut im Ereignis-Pfad (`ControllerIslandRows` für die Chat-Zeilen); Fenster an der Notch bzw. als Pille; Signpost `controller.islandShow` (Budget 33 ms) |
| Katalog | `AgentChatsCommandCenter` | Befehle an das Key-Fenster (Token-Anmeldung je Fenster); Tastaturkürzel nutzen dieselben Funktionen |
| Terminal | `TerminalControlKey`, `AgentTerminalController.sendKey` | feste Tastenliste; Entwurfs-Tracker und Abbruch-Verdacht wie bei der Tastatur |
| Diktat-Ziel | `DictationDelivery`, `RecordingCoordinator+ChatDelivery` | Text als ein Block direkt ins Terminal; der Hotkey-Weg ins vordere Programm ist unverändert |
| Ansicht | `Views/Controller/` | Legende, Menü, Listen-Markierung, Texte und Symbole |

Leistung: Im Ruhezustand läuft nichts. Legende, Menü und Markierung sind eigene kleine Ansichten mit
eigenem Beobachtungswert (`ControllerUIModel`); der Body von `AgentChatsView` und die Sidebar-Zeilen
lesen ihn nicht. Die Zeilen der Liste werden nur im Ereignis-Pfad berechnet.

## Prüfen

- `swift test --filter ChatPlace` und `--filter AgentWindowStorePlaceHistory` — Zurück mit L2 (Orte,
  Kachel je Workspace, geschlossene Ziele, je Fenster); `--filter ControllerWorkspacePicker` die
  Markierung von „Wohin“ (Start auf dem vorigen Ort, Reiterwechsel, ohne vorigen Ort);
  `--filter NotchPillPlacement` die Lage von Pille und Insel ohne Notch.
- `swift test --filter Controller` — Kern, Ausführer, Manager, Debug-Kanal; die Ebenen in
  `ControllerGestureRecognizerLayerTests`, `ControllerBindingResolverLayerTests` und
  `ControllerActionDispatcherIslandTests`.
- `make snapshots ONLY=controller` — Einstellungsseite, Legende in zehn Zuständen (mit Raster samt Ziel von L2, offener Auswahl und Shell),
  Menü mit beiden Ebenen, Liste der Ausgabemodi an der Pill; `ONLY=controller-insel` die Insel (Wohin:
  Chats mit Markierung auf dem vorigen Chat, nach zwei Schritten, ohne vorigen Ort, Workspaces, mit
  Notch-Zählern; Schreiben, Schreiben in der Shell; Schnellbefehle, bei Rückfrage, wenn der Chat
  arbeitet; als Pille Chats, Schnellbefehle, Shell; Pille oben mit Insel nach unten, Pille unten mit
  Insel nach oben);
  `ONLY=clipboard-verlauf-controller` die Fußzeile und das Menü im Verlauf.
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
- Zurück mit L2 folgt dem Workspace, den das Fenster referenziert, auch wenn der Bezug veraltet ist:
  Raster W, dann Chat Y (nicht in W), dann Chat X (in W) aus der Seitenleiste — X in der Einzelansicht
  zählt als Workspace W, nicht als eigener Chat.
- Umbelegen gibt es noch nicht; die Belegung ist eine pure Tabelle, auf die das später aufsetzen kann.
