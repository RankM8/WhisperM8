---
status: aktiv
updated: 2026-11-13
description: Controller-Steuerung — WhisperM8 mit einem Gamepad (PS5 DualSense, Xbox-Controller samt Paddles des Elite) bedienen; Belegung, Aufbau, Schalter, Prüfwege und Grenzen.
---

# Controller-Steuerung

WhisperM8 lässt sich mit einem Gamepad bedienen: durch die Liste links gehen, Chats, Workspaces und
Projekte öffnen, diktieren, Rückfragen der Agenten beantworten und den Zwischenablage-Verlauf nutzen.
Referenzgeräte sind der PS5-Controller (DualSense) und der Xbox Elite Wireless Controller Series 2,
beide über Bluetooth; andere Gamepads laufen über das allgemeine Profil (`GCExtendedGamepad`) mit.
Xbox-Controller zeigen ihre eigenen Tastennamen, die Paddles des Elite sind eigene, belegbare Tasten
(siehe „Xbox-Controller und Paddles“).

Der Controller löst **Aktionen** aus, keine Tastendrücke an das Fenster im Vordergrund. Er schreibt
gezielt in das Terminal des Ziel-Chats und braucht dafür keine Bedienungshilfen-Berechtigung.

Plan mit Entscheidungen und Prüfprotokoll: [`../plans/controller-steuerung.md`](../plans/controller-steuerung.md).
Entwürfe: [`../design/controller-steuerung.html`](../design/controller-steuerung.html), für die Dynamic Island
[`../design/controller-insel.html`](../design/controller-insel.html) und
[`../design/controller-runde5.html`](../design/controller-runde5.html) (zwei Rauten, Limits-Karte).

**Name:** Die Anzeige, die beim Halten von L1, R1 oder L2 an der Notch bzw. aus der Pille wächst, heißt
in Texten und Doku **Dynamic Island** (früher „Insel“). Im Code heißen die Typen weiter `ControllerIsland…`.

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

Nach vorn kommt das zuletzt aktive Agent-Chats-Fenster (`ControllerWakeFocus`, WM8-92): Es wird nach der
Aktivierung ausdrücklich zum Schlüsselfenster. Vorher holte macOS beim Aktivieren das zuletzt aktive
Fenster der App nach vorn — lag dort ein offenes Einstellungsfenster, sah der Controller „anderes
Fenster“, schickte Brücken-Tasten dorthin, und jede Taste piepte bis zu einem Mausklick. Gibt es das
Fenster nicht mehr, öffnet der Weg wie bisher das Primärfenster.

Notbremse: `defaults write com.whisperm8.app controllerFeatureEnabled -bool NO` — kein Zugriff auf
das GameController-Framework, der Schalter wirkt nicht. Für das rohe HID der Xbox-Controller (Paddles,
Xbox-Knopf) gibt es eine eigene: `controllerPaddleHIDEnabled -bool NO`.

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
| L1 / R1 tippen | voriger / nächster Chat in der Reihenfolge der Liste (auch im Raster, kein Umlauf); in der Liste der Filter Aktiv / Zuletzt / Alle. Die Tastatur (⌘⌥←/→) bleibt bei den Tabs. Gehalten sind sie Ebenen (siehe „Ebenen und Dynamic Island“), ein Durchlaufen beim Halten gibt es nicht |
| Steuerkreuz | in jedem lebenden Chat Pfeiltasten ins Terminal (Claude, Codex, Shell; ruhend, arbeitend oder fragend, auch im Raster), mit Wiederholung beim Halten. So erreicht man Subagenten-, Workflow- und Aufgabenansichten von Claude und jede Auswahlliste der CLI. Rechts übernimmt in Claude den grauen Vorschlag, Kreuz schickt ihn dann ab. **Ausnahme links:** Im vermutlich leeren Claude-Feld (direkt nach dem Absenden, seither nichts im Feld, keine Rückfrage, keine offene Auswahl) „geht nicht“, denn dort schickt ← die ganze Sitzung in Claudes Agent-Ansicht. Hoch holt den letzten Prompt zurück; er gilt dann als Rückleger, den „Weiter“, Menü-Befehle und `chats send` vorher leeren. In der App (Liste, Kacheln) bewegt nur der linke Stick. Ohne lebendes Terminal (beendeter Chat) wie der Stick. Entscheidung vom 12.11.2026; vorher gab es Pfeile nur in Rückfragen, offenen Listen und Codex |
| Rechter Stick | Verlauf scrollen (im Alternate-Puffer als Mausrad an die TUI), auch während Aufnahme, Transkription und Nacharbeit |

**Zusatz**

| Taste | Wirkung |
|---|---|
| Viereck | im Chat Rücktaste (ein Zeichen); halten: weiter löschen wie beim iPhone — ab 0,6 s Zeichen alle 60 ms, nach einer weiteren Sekunde ganze Wörter alle 150 ms (Ctrl+W; in Shells weiter Zeichen); in der Liste halten: Zeile schließen wie ihr „−“/„×“ |
| Create | Projekt-Auswahl „Neuer Chat“ (wie ⌘N), aktuelles bzw. markiertes Projekt vorausgewählt — „Create, Kreuz“ startet dort |
| Touchpad-Klick | Zwischenablage-Verlauf auf und zu; ebenso L2 + Touchpad (überall), R1 + ▼ und „Zwischenablage-Verlauf“ im Options-Menü |
| L3 | Kachel groß / zurück zum Raster |
| R3 | tippen: gestoppten Chat starten (im Chat und auf der markierten Zeile der Liste), sonst ohne Wirkung, auch ohne Vibration; halten (0,6 s): ganze Eingabe leeren, mit kurzer Vibration — Claude und Codex, nicht während einer Rückfrage; in einer Shell nur an der Eingabezeile (nicht in nano, vim und anderen Vollbild-Programmen) |
| Options | das eine Menü, siehe unten |
| L2 tippen | zurück dorthin, wo du vorher warst — voriger Chat oder voriger Workspace als Raster (siehe „Zurück mit L2“); gehalten die Ebene „Wohin“ (Markierung auf dem aktuellen Ort, Loslassen ohne Bewegung tut nichts) |
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

**Menü (Options):** eine dunkle Karte am Chat, für den sie gilt (Runde 5): in der Einzelansicht rechts
direkt unter dem Chat-Kopf (beim „…“-Knopf), im Raster am Kopf der fokussierten Kachel, in der Liste rechts
neben der markierten Zeile. Sie sieht aus wie die Dynamic Island und die Diktat-Pille (dunkles Glas, heller Rand, Markierung
in Indigo) und zeigt jede Gruppe mit Überschrift; darunter steht, was ✕, ○ und Options tun. Am Rand kippt
sie über den Anker (Kachel unten im Raster) oder rückt nach links bzw. oben; ist das Fenster zu klein,
zeigt die Karte nur ganze Zeilen rund um die Markierung und rückt mit ihr (`ControllerMenuWindow`); an der
Kante, an der es weitergeht, ist der nächste Eintrag nur als verblassender Rand zu sehen. Ohne Anker (kein Chat sichtbar) steht sie
unten mittig über der Legende. Platzierung pur in `ControllerMenuPlacement`, Anker über
`ControllerMenuAnchorKey` (`ControllerMenuCard.swift`): Die Anker melden nur bei offenem Menü einen Rahmen.
Neben einer Zeile der Liste steht die Karte nur, wenn das Menü dieser Zeile gilt; ist eine Projekt- oder
Workspace-Zeile markiert, gilt es dem ausgewählten Chat und hängt an dessen Kopf bzw. Kachel. „Aus diesem
Workspace nehmen“ wirkt nur auf den Workspace, den das Menü beim Öffnen gezeigt hat.

Gruppen in fester Reihenfolge: Eingaben · Chat · Projekt · Workspace · Lebenszyklus · Steuerung. Ein Eintrag
erscheint nur, wenn er für diesen Chat passt; ausgegraut ist nur, was passt, aber gerade nicht geht (etwa
„Weiter“, während der Chat arbeitet). Alle Aktionen nehmen dieselben Wege wie Kopf, Kachelkopf und
Kontextmenü des Chats bzw. Seitenleiste und Workspace-Kopf (je ein `AgentChatsCommand`).

| Gruppe | Einträge |
|---|---|
| Eingaben | „Weiter“, „Befehle ›“ (feste Befehle der CLI, Tabelle `ControllerSlashCommands`, bei Claude auch `/tasks`, `/workflows`, `/rewind`; „/ eintippen“ bleibt ungesendet, alle anderen werden gesendet; Befehle mit Liste setzen „Auswahl offen“), „Modus wechseln“ (Shift+Tab), „Neu zeichnen“ (nur Claude, Ctrl+L) |
| Chat | „Konto wechseln ›“, „Umbenennen…“, „Titel neu lesen“, „Forken“, „Anheften/Lösen“, „Archivieren“, „Chat schließen“ (wie „−“/„×“ in der Seitenleiste); außerhalb eines Workspace auch „Zu Workspace hinzufügen ›“ und „In neues Fenster verschieben“ |
| Projekt | „In PhpStorm öffnen“ (bzw. das gemerkte Ziel des Kopf-Knopfs), „Im Finder zeigen“ |
| Workspace „Name“ | nur, wenn der Chat in einem Workspace gezeigt wird (sichtbares Raster, auch für eine markierte Zeile der Liste, oder eine groß gemachte Kachel). Erst der Chat: „Aus diesem Workspace nehmen“, „Zu anderem Workspace hinzufügen ›“, „Notiz dieser Kachel zeigen/ausblenden“ (Kachel mit Notiz), „In neues Fenster verschieben“; dann der Workspace: „Workspace umbenennen…“ (dasselbe Sheet wie in der Seitenleiste), „Rastergröße ›“. Die Notiz der Kachel nur im sichtbaren Raster; Umbenennen, Rastergröße und Herausnehmen nur bei angelegten Workspaces (keine Projekt-Ansicht) |
| Lebenszyklus | „Neu starten“ (laufender Chat, mit der bestehenden Rückfrage, Kreuz bestätigt sie), bei Hintergrund-Chats „Logs“, „Stoppen“ (mit Rückfrage), „Respawn“, bei Subagent-Jobs „Job stoppen“ (mit Rückfrage, `ControllerConfirmationDialog`) |
| Steuerung | „Notizen überall an/aus“ (wie ⌥⌘N, gilt app-weit, nur bei sichtbarem Raster), „Archiv zeigen“ bzw. „Archiv verlassen“ (wie der Archiv-Knopf unten in der Seitenleiste; seit dem Insel-Paket hier statt auf R1 + ▼; ist die Seitenleiste zu, geht sie dafür auf), „Zwischenablage-Verlauf“, „Belegung anzeigen“, „Controller pausieren“ |

**Konto wechseln ›** zeigt rechts den Verbrauch „5 Std. · Woche“ wie das Limits-Popover (Ampel: unter 50 %
grün, ab 50 gelb, ab 80 rot) und markiert je Gruppe (Claude, GPT) das wählbare Konto mit dem kleinsten
Verbrauch im knapperen Fenster als „am meisten frei“. Die Reihenfolge bleibt; die Markierung beginnt auf
dem eigenen Konto (Kreuz dort geht nicht), der erste Schritt führt zum nächsten wählbaren. Darunter, nur
wenn zutreffend, „Kontowechsel zu … abbrechen“ und „Letzten Kontowechsel rückgängig (alle betroffenen
Chats)“ — das wirkt auf den ganzen letzten Wechsel, nicht nur auf diesen Chat. Die Zahlen kommen
aus `AccountLimitsStore`: Die Popovers tragen ihre Ergebnisse ein, und erst beim Öffnen der Konto-Ebene
stößt der Controller denselben passiven Abruf an (nie Tokens erneuern), höchstens einmal je Minute — auch
nach einem gescheiterten Versuch; ein offenes Menü zieht nach. Nicht im Menü: Tab-Farbe, Inspector.

**Rastergröße ›** zeigt dieselben Stufen wie der Stufenwähler im Workspace-Kopf (die aktuelle und alle, die
in die zuletzt gemessene Rasterfläche passen); die Markierung beginnt auf der aktuellen. Wachsen geht
immer, Verkleinern nur, wenn alle Chats nach dem Zusammenrücken noch Platz haben. Bräuchte das Verkleinern
die Auswahl „wer bleibt“ an den Kacheln, ist die Stufe aus („nur mit der Maus“) und der Befehl
`setWorkspaceCapacity` lehnt ab — der Controller öffnet diesen Auswahlmodus nie, damit kein Chat aus Versehen
das Raster verlässt. Läuft die Auswahl gerade, ist „Rastergröße“ aus.

In der Liste wirken die Aktionen auf die markierte Chat-Zeile. Kreis geht eine Ebene zurück, Options
schließt alles.

## Ebenen und Dynamic Island

L1, R1 und L2 sind **Ebenen-Tasten** (Runde 4). Tippen (kürzer als 0,3 s und ohne zweite Taste
dazwischen, auch ohne Stoß von Stick oder Steuerkreuz und ohne Scrollen mit dem rechten Stick) löst beim Loslassen aus, was die Taste schon
immer tat. Gehalten wird sie zur Ebene: Kombinationen wirken sofort beim Druck der zweiten Taste, die
0,3 s bestimmen nur, wann die **Dynamic Island** erscheint. Loslassen nach Halten ohne Kombination tut nichts,
außer bei L2: Dort wechselt Loslassen nach einer Bewegung zum markierten Eintrag (siehe „Wohin“). Es gilt immer nur eine Ebene; eine zweite Ebenen-Taste ist darin eine
gewöhnliche Taste. Ebenen wirken im Chat und im Raster (auf den Chat der fokussierten Kachel). In der
Liste, im Zwischenablage-Verlauf, im Menü, in Dialogen und während der Aufnahme wirken die Tasten wie
ohne Ebene. R2 diktiert auf jeder Ebene (unter L2 heißt R2 „hin und diktieren“).

| Ebene | Taste | Wirkung |
|---|---|---|
| L1 Schreiben | Viereck | bis Zeilenanfang löschen (Ctrl+U, wie ⌘ + Rücktaste); gehalten nach 0,4 s Zeile für Zeile alle 150 ms |
| | Dreieck | Zeilenumbruch ohne Senden (Ctrl+J, siehe Schutzregeln) |
| | Steuerkreuz ◀ ▶ | Wort zurück/vor (Ctrl+←/→ als vollständige CSI-Sequenz), mit Wiederholung — Claude und Codex |
| | Steuerkreuz ▲ ▼ | Zeile hoch/runter, nur im sichtbar mehrzeiligen Entwurf und nicht aus der ersten (▲) bzw. letzten (▼) Zeile; dort holte Claude den Verlauf. Ist das Feld oder die Cursorzeile nicht ablesbar, „geht nicht“ |
| | Kreuz | neuesten Eintrag der Zwischenablage einfügen: Text als ein Block ohne Senden, Bild wie ⌘V (in die Zwischenablage, dann Ctrl+V; nur Claude und Codex). In Shells nur Text, nur an der Eingabezeile und nur mit eingeschaltetem Bracketed Paste. Nicht in einer Rückfrage, auch nicht, wenn sie erscheint, während der Text noch lädt — außer in Claudes erkannter Frage mit freiem Textfeld (siehe Schutzregeln): Dort geht Text ins Feld, ohne Enter, kein Bild. Die Dynamic Island zeigt vorher, was es ist |
| | Kreis | genau ein Escape, unabhängig vom Status und ohne 1-s-Sperre. Arbeitet der Chat und ist keine Ansicht erkannt, warnt die Dynamic Island: es unterbricht |
| | L3 | Rückgängig (Ctrl+_), nur Claude; Codex hat im Standard-Editor kein Undo |
| R1 Schnellbefehle | Kreuz | Claude: immer „Jetzt senden“ (Ctrl+X Ctrl+S, wie Ctrl+Enter), ohne Erkennung des Feldinhalts; schickt den Entwurf sofort ab bzw. die Warteschlange, bei leerem Feld passiert nichts (seit 13.11.2026, vorher konnte eine falsche Erkennung „Weiter“ in einen fertigen Prompt tippen). Codex: mit Text im ruhenden Chat Enter, leeres Feld „Weiter“, arbeitend oder nur mit ↑ zurückgeholter Prompt „geht nicht“. Nie in einer Rückfrage oder offenen Ansicht, in Shells wie bisher |
| | L3 | ausführliches Transkript an/aus (Ctrl+O), nur Claude |
| | Dreieck | Modus wechseln (Shift+Tab) |
| | Viereck | Befehle › — öffnet das Options-Menü direkt auf dieser Unterseite |
| | Kreis | Konto wechseln › — ebenso |
| | Steuerkreuz ▲ | Limits-Karte aller Konten, solange R1 gehalten ist (siehe „Limits-Karte“) |
| | Steuerkreuz ◀ | Mitteilungen eine Stufe weiter, wie die Glocke in der Seitenleiste: alles an → Ton aus → alles aus („Ton aus“ fällt weg, wenn es nichts stumm zu schalten gibt) |
| | Steuerkreuz ▶ | Wach bleiben eine Stufe weiter, wie der Wach-Knopf: aus → bei Arbeit am Strom → immer → aus. Fehlt die einmalige Admin-Freigabe, öffnet sich kein Dialog: Die Dynamic Island sagt „Erst in der Seitenleiste freigeben“, der Controller vibriert „geht nicht“ |
| | Steuerkreuz ▼ | Zwischenablage-Verlauf auf und zu (schließt die Dynamic Island) |
| L2 Wohin | (halten) | die Liste steht sofort da, die Markierung auf dem aktuellen Eintrag; der vorige Ort trägt „vorher“ (siehe unten) |
| | Stick/Steuerkreuz hoch/runter | Markierung bewegen (mit Wiederholung) |
| | links/rechts | Reiter „Chats“ / „Workspaces & Projekte“; die Markierung beginnt dort wieder auf dem aktuellen Eintrag |
| | Loslassen, Kreuz | nach einer Bewegung zum markierten Eintrag wechseln. Ohne Bewegung (Markierung auf dem aktuellen Eintrag) passiert nichts. Loslassen wechselt nur, solange der Chat die Eingaben hat; startet währenddessen eine Aufnahme per Hotkey oder geht ein Dialog oder Sheet auf, schließt es nur die Dynamic Island |
| | Kreis | abbrechen, nichts passiert |
| | Dreieck | zum nächsten wartenden Chat, reihum (derselbe Weg wie ⌃⌥Tab); schließt die Dynamic Island |
| | Viereck | zuletzt geschlossenen Chat dieses App-Starts wieder öffnen (wie `chats reopen`), an seine alte Stelle; noch mal für den davor. Die Fußzeile nennt ihn; ohne geschlossenen Chat „nichts geschlossen“ und „geht nicht“ |
| | R2 | zum markierten Chat wechseln und diktieren; steht die Markierung auf dem aktuellen Chat, Workspace oder Projekt, in den aktuellen Chat; ein anderer Workspace oder ein Projekt „geht nicht“. Scheitert der Wechsel, wird nicht diktiert („geht nicht“). Ohne Bewegung diktiert L2 halten + R2 also in den aktuellen Chat (die Fußzeile sagt im Reiter „Workspaces & Projekte“ „hier diktieren“) |
| | Touchpad drücken | Zwischenablage-Verlauf auf und zu; schließt die Dynamic Island. Gilt überall, auch außerhalb des Chats, im Verlauf selbst und außerhalb der App (mit Hintergrund-Empfang) — dort über die Belegung ohne Ebene |

Ein Schnellbefehl oder Wechsel schließt die Dynamic Island; bis zum Loslassen der Taste kommt sie nicht
wieder. Ein Schnellbefehl, der gerade nicht geht, vibriert und lässt sie offen. **Ausnahme Schalter**
(R1 + ◀ und ▶): Sie lassen die Dynamic Island offen, damit man mit mehreren Drücken bis zur gewünschten
Stufe kommt. Das Feld wird kurz markiert, sein Stand wechselt, und unter den Rauten steht ausgeschrieben,
was jetzt gilt, rechts daneben, was der nächste Druck bringt („Ton aus, Mitteilungen an · ◀ noch mal:
alles aus“). Dazu ein kurzer, leichter Impuls (`ControllerHapticPattern.toggled`). Jeder Druck ist eine
Stufe; gehaltenes Steuerkreuz schaltet nicht weiter.

**R1: zwei Rauten** (Insel-Paket, Entwurf `controller-runde5.html`, Zustände 1–5): links „App ·
Steuerkreuz“ mit Limits, Mitteilungen, Wach bleiben und Zwischenablage, rechts „Chat · Tasten“ wie
bisher. Beide Rauten sind verschränkt (vier halbe Spalten à 76 pt, Zeilen 44 pt), die Dynamic Island ist
damit rund 700 pt breit (`ControllerIslandDisplay.bodyWidth`). Unter Mitteilungen und Wach bleiben steht
ihr Stand, Symbole wie in der Seitenleiste. Die App-Raute hängt nicht am Chat und geht immer, auch bei
offener Rückfrage und **während eines Diktats**; dann ist nur die Chat-Raute ausgegraut (Regel seit
Runde 5). Glocke und Wach-Knopf teilen sich ihren Weg mit der Seitenleiste
(`AgentAlertLevel.advance()`, `StayAwakeController.cycle()`), der Wach-Schalter prüft vorher
`nextStepNeedsPermission`. War die Seitenleiste seit dem App-Start verborgen, kennt die App die Freigabe
noch nicht: Der erste Druck holt das still nach (`whenPermissionKnown`, `sudo -n`, nie ein Dialog) und
schaltet danach bzw. meldet „Erst in der Seitenleiste freigeben“ nur, wenn sie wirklich fehlt. Das Archiv (im Entwurf noch auf ▼) steht jetzt im Options-Menü.

**Kopf mit Konto:** Neben dem Ziel-Chat steht sein Konto mit dem 5-Stunden-Stand, etwa „main · 5 h 42 %“,
verbraucht und in der Ampel des Limits-Popovers (unter 50 % grün, ab 50 gelb, ab 80 rot). GPT-Chats
(GPT-Backend) zeigen ihr GPT-Konto, Claude-Chats ihr Claude-Konto, Codex und Shells keins
(`ControllerUsageAccount.of`). Dabei gelten dieselben Schalter wie beim Start: Ist das GPT-Backend aus,
zählt ein GPT-Stempel nicht (der Chat läuft als Claude), sind GPT-Konten aus, gilt das GPT-Hauptkonto. Das
Konto wird beim Öffnen der Dynamic Island einmal bestimmt (während eines Diktats das seines Ziels) und
bleibt, auch wenn neue Zahlen kommen. Die Zahl kommt aus dem letzten Stand im `AccountLimitsStore`;
der Kopf löst nie einen Abruf aus, ohne Stand steht „—“.

**Limits-Karte** (R1 + ▲, Zustände 6 und 7): Statt der Rauten alle angemeldeten Claude-Konten, darunter
die Konten des GPT-Backends — dieselben wie in den beiden Popovers unten links, ohne das Codex-CLI-Konto
des Diktats, ohne Plan-Kürzel und ohne Wochenlimit je Modell. Je Konto 5-Stunden- und Wochenfenster mit
Balken, Prozent verbraucht und Rücksetzzeit (unter einem Tag als Dauer „in 2 h 10 min“, sonst Wochentag
und Uhrzeit). Das Konto des Chats ist markiert („dieser Chat“). Login beendet oder kein Token: Text aus dem
Popover statt der Balken. Bei anderen Problemen (offline, Token wird gleich erneuert, GPT-Abruf
gescheitert) bleiben die letzten Zahlen samt Rücksetzzeit stehen, mit Hinweis; nur ein Konto ganz ohne
Zahlen zeigt den Text. Ein gescheiterter GPT-Abruf nennt keinen Grund („Live-Abruf fehlgeschlagen“), weil
der Abruf keinen kennt. Der Stand-Zeitpunkt rückt nur mit echten, live abgerufenen Zahlen vor. Die
Konten liest die Karte einmal beim Öffnen; neue Zahlen ordnen sich danach nur noch zu (kein erneutes
Lesen der Profile im Main Thread). Höchstens sechs Konten sind zu sehen; der linke Stick und ▲ ▼
scrollen, ein schmaler Balken rechts zeigt, dass es weitergeht. Kopf „Stand vor 1 min“ bzw. „aktualisiere
…“. Kreuz holt die Zahlen frisch über denselben Weg wie ↻ im Popover (`AccountLimitsStore.refresh()`:
Claude über den Update-Flow mit CLI-Ping für abgelaufene Tokens, GPT neu abgefragt); läuft schon ein
Abruf, „geht nicht“. △ □ ○ und L3 (Ctrl+O) gehen bei offener Karte nicht, ◀ ▶ auch nicht. Während eines
Diktats ist ✕ unter R1 „geht nicht“; die Fußzeile bietet „aktualisieren“ dann nicht an. Loslassen von R1
schließt.
Abrufe: Das Halten von R1 lädt nie etwas. Erst das Öffnen der Karte stößt den passiven Abruf an, und nur,
wenn der Stand älter als eine Minute ist; der Zeitpunkt des letzten Versuchs zählt unabhängig vom
Ergebnis (Drosselung aus Runde 5). Neue Zahlen ziehen Karte und Kopf nach (`onChange`).

**Wohin** (Insel-Paket, 13.11.2026; kehrt die Cmd-Tab-Regel vom 12.11. um): Tippen (unter 0,3 s) führt
wie bisher an den vorigen Ort. Halten zeigt sofort die Liste mit der Markierung auf dem **aktuellen**
Eintrag; Loslassen ohne Bewegung tut deshalb nichts. Der vorige Ort (`ControllerBackTarget` mit ID, aus
`AgentWindowStore+PlaceHistory`) trägt rechts „vorher“ und steht in beiden Reitern immer gleich unter dem
aktuellen Eintrag (ohne aktuellen ganz oben), also einen Schritt entfernt — auch wenn die Seitenleiste ihn
weiter unten führt; die übrigen Zeilen behalten ihre Reihenfolge. Erst nach einer Bewegung wechseln Loslassen und Kreuz. Start-Reiter: im
Raster „Workspaces & Projekte“, in der Einzelansicht „Chats“, jeweils auf dem aktuellen Eintrag (ohne
Workspace und Projekt im Reiter nur die Chats). Hat ein Reiter keinen aktuellen Eintrag (Workspaces in der
Einzelansicht), gibt es dort zunächst keine Markierung; der erste Stoß markiert die erste Zeile. Ist das
Ziel der vorige Ort, geht der Wechsel denselben Weg wie L2 getippt (`lastChat`). Die Chats stehen in der
Reihenfolge der Liste links, jeder einmal; der vorige Chat steht immer darin, gleich hinter dem aktuellen,
auch wenn die Seitenleiste ihn weiter unten oder gerade nicht zeigt (Filter, Suche, eingeklappte Gruppe, Archiv-Ansicht);
rechts Wort und Dauer wie Tab-Switcher und Notch („wartet · 2 min“, „bereit“, beim aktuellen „jetzt“).

Der Reiter **„Workspaces & Projekte“** zeigt oben die angelegten Workspaces (ohne versteckte
Projekt-Ansichten) in der Reihenfolge der Seitenleiste, mit Farbe, Name, Raute „wartet“ und Zahl der
Chats, darunter durch eine Linie abgesetzt die Projekte in der Reihenfolge der Seitenleiste — nur die mit
aktiven Chats (laufend oder als Tab offen, dieselbe Ableitung wie der ⊞ am Projektkopf) und das, dessen
Raster gerade zu sehen ist; mit Ordner in der Projektfarbe und „n aktiv“. Nur der vorige Ort steht außer
der Reihe gleich unter dem aktuellen (ein voriges Projekt also auch zwischen den Workspaces); die Linie
bleibt dort, wo die Projekte beginnen. Höchstens sechs Zeilen, die
Liste rückt mit der Markierung, darunter „+ n weitere“. Ein Chat wechselt wie der Klick in der
Seitenleiste, ein Workspace wie der Klick auf seinen Kopf, ein Projekt wie der ⊞ am Projektkopf (Raster
seiner aktiven Chats) — beides still: Gehört die Ansicht einem anderen Fenster oder laufen ihre Chats
dort, kommt kein Fenster nach vorn und kein Dialog, der Controller vibriert „geht nicht“
(`switchToWorkspace`, `switchToProject`). Eine Projekt-Ansicht, die als voriger Ort gemerkt ist, trägt
„vorher“ an ihrer Projekt-Zeile (`ControllerWorkspaceChoice.viewWorkspaceID`). Danach hat die Kachel den
Fokus, auf der du dort zuletzt warst (gemerkt beim Verlassen, nur für den laufenden App-Start).

**Die Dynamic Island** ist ein eigenes, nicht aktivierendes Fenster ohne Maus (`ControllerIslandPresenter`),
einmal aufgebaut, danach nur ein- und ausgeblendet. Sie erscheint auf dem Bildschirm des
Agent-Chats-Fensters, auf dem der Controller wirkt — unabhängig von der Bildschirmwahl der
Notch-Anzeige. Mit Notch wächst sie als schwarzes Band in Notch-Breite mit Körper darunter
(`NotchHangingShape`). Ohne Notch wächst sie aus der Pille der Notch-Anzeige, die dort immer steht
(siehe [notch.md](notch.md)): genau an ihrer Stelle (ist sie sichtbar, zählt ihr tatsächlicher
Mittelpunkt, auch bei automatisch ausgeblendeter Menüleiste), im dunklen Glas der Diktat-Pille
(`PillGlassBackground`, gleicher Rand und Schatten), immer dunkel. Sitzt die Pille in der oberen
Bildschirmhälfte, öffnet die Dynamic Island nach unten (gemeinsame Oberkante), in der unteren nach oben
(gemeinsame Unterkante); sie bleibt immer ganz auf dem Bildschirm (`NotchPillPlacement.frame`), an
der Notch ebenso (mittig unter der Notch, am Rand begrenzt). Sie
liegt eine Ebene über der Notch-Anzeige (`mainMenu + 4`): Steht die Notch-Anzeige auf diesem
Bildschirm, überdeckt die Dynamic Island sie und zeigt rechts im Kopf deren Zähler (arbeitet/wartet) — nur bei
„Wohin“; bei Schreiben und Schnellbefehlen steht dort immer der Ziel-Chat. Eine aufgeklappte
Notch-Liste klappt zu. Auch über einem Vollbild-Fenster erscheint die Dynamic Island (`fullScreenAuxiliary`,
nur sie, nicht die Notch-Anzeige): an der Notch in der Aussparung, sonst an der gemerkten Stelle der
Pille (ohne Menüleiste oben am Bildschirmrand). Eine Bewegung beim Öffnen, eine beim Schließen
(0,25 s, bei „Bewegung reduzieren“ keine), sonst nichts in Bewegung. Maus oder Tastatur schließen sie
für das laufende Halten.

Mit der vereinten Pille (siehe [notch.md](notch.md)) ist die Pille, aus der die Dynamic Island wächst,
dieselbe wie die Diktat-Pille; die Dynamic Island hat dort Vorrang vor allem anderen. Ihr Aussehen (Glas,
Rand, Schatten der Diktat-Pille) blieb gleich.

Die Dynamic Island ersetzt am Controller den Ctrl+Tab-Umschalter (der Tastatur bleibt er) und die frühere
Workspace-Auswahl unten im Fenster. Die Legende schaltet beim Halten nicht um; sie nennt die Ebenen in
einem Eintrag („L1 R1 L2 Halten: Ebenen“).

**Während der Aufnahme:** R2 beendet (Text ins Eingabefeld), Kreuz beendet und sendet (nur bei einem
Chat als Ziel), Kreis verwirft bzw. bricht Transkription oder Nacharbeit ab, Steuerkreuz wechselt den
Ausgabemodus nur für diese Aufnahme (links/rechts ein Schritt pro Druck, hoch/runter mit Wiederholung).
Bei jedem Wechsel steht über der Pill kurz die Liste aller Modi, der aktuelle markiert (eigenes kleines
Panel, `OutputModeListPresenter`; weg 1,5 s nach dem letzten Wechsel und sofort mit dem Ende der
Aufnahme). Der rechte Stick scrollt weiter. Die Pill zeigt Ziel und Modus ohne Hover.

Ist das Diktat an einen Chat gebunden (per Controller in Chat oder Liste gestartet), geht die Steuerung
weiter (Runde 5): Der linke Stick navigiert wie sonst (Liste, Kacheln, Markierung), L1/R1 tippen wechseln
den Chat, L2 „Wohin“ geht samt Wechsel (Kreuz und Loslassen nach einer Bewegung, das Diktat bleibt an
seinem Ziel), R1 zeigt beide Rauten: Die App-Raute (Limits, Mitteilungen, Wach
bleiben, Zwischenablage) geht, die Chat-Raute ist ausgegraut (Hinweis „Diktat läuft“). L1 bleibt aus; R2 ist in jeder Ebene „stopp“, Kreuz, Kreis, Steuerkreuz und
rechter Stick bleiben wie oben. Der Text geht in den Chat, in dem das Diktat begann
(`RecordingCoordinator.pendingDeliveryTarget`, beim Start gesetzt); Legende und Dynamic Island nennen ihn
(„→ Chat“). Dasselbe gilt in Transkription und Nacharbeit, außer was die Aufnahme steuert; das Ziel
kommt dann aus `RecordingCoordinator.inFlightDeliveryTarget` (beim Stopp eingefroren, nur zur Anzeige). Bei einem
Diktat ins Programm vorne (Hotkey) ruht der linke Stick wie bisher: Der Text ginge per ⌘V dorthin, wo
beim Stopp der Fokus liegt. Der Pause-Akkord bleibt während der Aufnahme aus.

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

## Xbox-Controller und Paddles

Plan und Entscheidungen: [`../plans/controller-xbox-paddles.md`](../plans/controller-xbox-paddles.md).

**Tastennamen.** Sie folgen dem Controller der letzten Eingabe (Familie `playStation`, `xbox`,
`generic`; bestimmt aus der Profilklasse, `GCXboxGamepad` usw.). Die Belegung bleibt nach Lage gleich:
A = Kreuz, B = Kreis, X = Viereck, Y = Dreieck, LB/RB = L1/R1, LT/RT = L2/R2, LS/RS = L3/R3,
View = Create, Menu = Options. Legende, Dynamic Island, Menü-Karte, Fußzeile des Verlaufs und die
Einstellungen lesen die Familie über den Umgebungswert `controllerFamily`; die Erklärtexte nutzen
Platzhalter. Allgemeine Gamepads behalten die PlayStation-Zeichen. Wer zwei Controller verbunden hat,
sieht die Namen dessen, von dem zuletzt etwas kam.

**Touchpad und Xbox-Knopf.** Xbox-Controller haben kein Touchpad. Der runde Xbox-Knopf übernimmt dessen
Rolle (Zwischenablage-Verlauf auf und zu, auch mit LT gehalten). GameController meldet ihn nicht; er
kommt über denselben HID-Leser wie die Paddles (Tastenseite 0x09, Usage 0x0D). Ist HID nicht lesbar,
hat er keine Wirkung, und Legende und Einstellungen zeigen keine Touchpad-Einträge. Der kleine
Profil-Knopf darunter gehört dem Controller und bleibt unbelegt.

**Paddles (Elite).** Die vier Paddles sind eigene Sofort-Tasten (`paddleUpperLeft` usw.): ein Druck,
eine Aktion, kein Halten. Standard: oben links (P3) „Nächster wartender Chat“, unten links (P4)
„Antworten“, oben rechts (P1) „Jetzt senden / Weiter“, unten rechts (P2) „Modus wechseln“. In
Einstellungen › Controller › Paddles wählt man je Paddle aus einer festen Liste (dazu „Zurück zum
vorigen Ort“, „Aus der Zwischenablage einfügen“, „Rückgängig“, „Zwischenablage-Verlauf öffnen“,
„Controller pausieren“, `/workflows`, `/tasks`, „Nichts“); die Belegung liest der Manager nur beim
Abgleich der Schalter.

| Paddle-Aktion | Wirkung |
|---|---|
| Nächster wartender Chat | derselbe Weg wie ⌃⌥Tab, ohne Dynamic Island; ohne wartenden Chat „geht nicht“ |
| Antworten | zum jüngsten frisch fertigen Chat (ruht, Turn vor höchstens 15 min beendet, nicht der aktuelle; Einteilung wie Notch und `chats`-Board) und dort diktieren. Gibt es keinen, zum nächsten wartenden Chat, nur springen. Ist der aktuelle Chat der einzige Kandidat und ruht er, diktiert es hier. Scheitert der Wechsel, wird nicht diktiert; in eine Rückfrage läuft nie ein Diktat |
| Jetzt senden / Weiter | dieselbe Entscheidung wie R1 + Kreuz (`sendOrContinue`): im Claude-Chat immer „Jetzt senden“, in Codex Enter oder „Weiter“; in Shells „geht nicht“ |
| Modus wechseln | Shift+Tab mit den Regeln des Menüs (nur ruhend, nicht in einer Rückfrage) |
| `/workflows`, `/tasks` | wie aus „Befehle ›“, nur in Claude-Chats |

**Wo Paddles wirken:** nur in der App. Im Chat (auch im Raster) jede Belegung; in der Liste alles außer
Eingaben in einen Chat; im Verlauf nur Verlauf und Pause; in Menü, Dialogen und anderen Fenstern nur
Pause. Nichts — auch ohne Vibration — in einer Ebene (L1, R1, L2 gehalten; die Ebene gilt als benutzt),
während Aufnahme, Transkription und Nacharbeit und außerhalb der App. Paddles wecken WhisperM8 nie.
Ausnahme: „Pause“ wirkt überall, wo L1 + R1 wirkt, auch in der Pause selbst und in der Schnellaktion (dort
gilt sonst die Regel des Menüs).

**Weiche gegen die doppelte Taste.** Das Profil im Controller legt jedes Paddle zusätzlich auf eine
Gesichtstaste; GameController meldet dann ein gewöhnliches A, B, X oder Y. HID meldet im selben Bericht
das Paddle-Bit (Consumer 0x0C, Usage 0x81) und die Taste. `ControllerPaddleGate` (pur, im Kern) macht
aus der Maske Paddle-Tasten und fällt für jeden Tastendruck im Bericht ein Urteil: „vom Paddle“, wenn
im selben Bericht ein Paddle-Bit dazukam, sonst „direkt“ (gültig 100 ms). Ein Druck von GameController
mit Urteil „vom Paddle“ wird verschluckt, samt seinem Loslassen; „direkt“ geht sofort durch; ohne Urteil
hält die Weiche ihn zurück, bis es kommt, höchstens 40 ms, und alles Spätere wartet dahinter. Das gilt
nur für Tasten, die HID beurteilen kann (`XboxHIDButtons.judgeable`: A, B, X, Y, LB, RB, View, Menu, LS,
RS); Steuerkreuz, Trigger und Sticks hält sie nie zurück. Kommen in einem Bericht mehr Tastendrücke als
neue Paddle-Bits, entscheidet das gelernte Profil (Bit → Taste, aus eindeutigen Berichten gelernt), welche
Taste zum Paddle gehört; die übrigen gelten als echter Druck. **Grenze:** Bevor die Weiche ein Paddle
einmal allein gesehen hat, wird ein echter Druck im selben Bericht mitverschluckt (das trifft nur einen
Druck, der genau mit dem Paddle in denselben HID-Bericht fällt). `reset()` behält die Maske, damit ein noch gehaltenes
Paddle keinen Phantom-Druck erzeugt; fällt die Paddle-Quelle weg, werden gedrückte Paddles losgelassen. DualSense-Ereignisse und Xbox-Controller ohne lesbare Paddles laufen
ohne Verzögerung durch. Paddles im Controller-Profil darum auf A, B, X oder Y lassen; auf Trigger oder
Stick gelegt, wirken sie zusätzlich.

**HID und Berechtigung.** `XboxPaddleHIDSource` findet nur Microsoft-Geräte, deren Haupt-Usage ein
Gamepad ist (Generic Desktop: GamePad, Joystick, MultiAxis), über einen Manager, der nie geöffnet wird.
Jedes Gerät wird einzeln geprüft und als eigenes `IOHIDDevice` geöffnet, ohne es zu vereinnahmen, auf der
Queue der Pumpe. Tritt ein Gerät zusätzlich als Tastatur oder Ziffernblock auf (`DeviceUsagePairs` mit
Generic Desktop 6 oder 7 — der Elite über Bluetooth LE tut das), öffnet sie es nur bei erteilter
„Eingabeüberwachung“, sonst gilt es als „nicht lesbar“. Jeder Lauf ist ein eigenes Sitzungsobjekt; ein
später Abbruch-Handler räumt nie einen neuen Lauf ab. Paddles erkennt sie am Element 0x0C/0x81, nicht an
der Produkt-ID. „Eingabeüberwachung“ wird nur gelesen (`IOHIDCheckAccess`, im Log), nie von selbst
angefragt. Fehlt sie oder scheitert das Öffnen, zeigt die Einstellungsseite „nicht lesbar“ mit dem Knopf „In den Systemeinstellungen
erlauben…“ (wirkt nach einem Neustart der App); die Paddles wirken dann als die Gesichtstasten ihres
Profils. Die Tabellen `XboxHIDButtons` (Usages der Tastenseite) und `XboxPaddleBits` (Bit ↔ Lage) stehen
zentral in `Core/XboxHIDLayout.swift` und `Core/ControllerPaddles.swift`. Gemessen sind A = 1, B = 2,
X = 4, Y = 5, Xbox-Knopf = 0x0D und die Bits 1, 2, 4, 8; gemessen 13.11.2026 sind LB = 7, RB = 8,
View = 0x0B, Menu = 0x0C, LS = 0x0E, RS = 0x0F und die Zuordnung Bit 1 = P1 (oben rechts), 2 = P2
(unten rechts), 4 = P3 (oben links), 8 = P4 (unten links). Profile dürfen Paddles auch auf LS oder RS
legen (so ist es beim Nutzer); die Weiche beurteilt diese Tasten wie die Gesichtstasten.

## Schutzregeln

- In eine offene Rückfrage läuft kein Text: Ein Diktat bleibt in der Zwischenablage (Hinweis als
  Mitteilung und kurz in der Pille: „In der Zwischenablage“; liegt der Text aus einem anderen Grund nur
  dort, etwa weil der Chat noch startet, mit „· ⌘V fügt ein“), Einträge des Menüs, die
  etwas in den Chat schicken, sind aus — auch „Modus wechseln“, denn Shift+Tab heißt in Claudes
  Freigabe-Dialog „alle Änderungen erlauben“. `sendKey` verweigert dort Tab und Shift+Tab.
- **Kein Enter in eine gerade aufgehende Freigabe (WM8-75, 14.11.2026):** Text mit Senden (Diktat, Kreuz
  während der Aufnahme, `chats send`, Warteschlange) geht als Einfüge-Block raus, das Enter 80 ms später
  (`AgentTerminalController.pastePrompt`). Direkt davor prüft `DelayedEnterGuard` neu: Kam die
  Rückfrage erst nach dem Einfügen, oder steht bei Claude unten statt des Eingabefelds ein Dialog
  (`ControllerScreenSnapshot.dialogVisible`, unterste 8 Zeilen), bleibt das Enter aus, und die Pille sagt
  „Nicht gesendet: Der Chat fragt nach einer Entscheidung“ (nicht während einer Aufnahme). Der Text steht
  dann meist noch im Feld; war der Dialog beim Einfügen schon gezeichnet, hat Claude ihn ignoriert — ein
  Diktat liegt dann nur in der Zwischenablage. Beginnt der eigene Text wie eine Auswahlzeile („1. …“),
  zählt eine solche Zeile nicht als Dialog. Nachgestellt an Claude Code 2.1.325: Einfügen plus Enter
  80 ms später bestätigte eine offene Bash-Freigabe. War beim Einfügen schon eine FRAGE offen (`chats send`
  beantwortet bewusst), bleibt das Enter wie bisher; eine schon offene Freigabe oder Plan-Freigabe
  bekommt nie ein Enter, und `chats send` lehnt sie vorher mit `approvalPending` ab
  ([agent-chats-cli.md](agent-chats-cli.md)). Grenzen: Prüfen und Enter sind nicht atomar
  gegenüber Claudes Neuzeichnen — ein Restfenster von wenigen Millisekunden bleibt; hochgescrollt ist der
  Bildschirm nicht ablesbar, dann zählt nur der Status. Kosten: ein Lesen der untersten 16 Zeilen je Senden (gemessen rund 5 ms im
  Debug-Build). Codex-Freigaben erkennt das nicht (keine Rückfragen, Feld-Erkennung nur für Claude; WM8-67).
- **Ausnahme Frage mit Textfeld (WM8-66, 14.11.2026):** In Claudes Frage-Dialog (AskUserQuestion) gehen
  Diktat und L1 + Kreuz (nur Text, kein Bild) als ein Einfüge-Block ins Feld „Type something“, nie mit
  Enter — bestätigen tut der Nutzer (bei Mehrfachauswahl nähme Enter den Haken wieder weg). Doppelt
  erkannt (`ClaudeQuestionTextGate`):
  - **Werkzeug:** Der Chat wartet auf eine Frage, und das jüngste Werkzeug im Transcript ist
    AskUserQuestion. Im Registry-Betrieb zählt dazu Claudes eigene Meldung: gemessen an 2.1.325 meldet
    eine Frage `input needed`, eine Freigabe `permission prompt`; ein stehen gebliebenes Frage-Detail
    im Transcript macht eine Freigabe nie zur Frage (`registryAwaitingKind`). Die Warte-Art allein reicht
    nicht: `input needed` kommt auch, wenn ein MCP-Werkzeug wartet.
  - **Bildschirm:** Unten stehen nummerierte Optionen, ein fester Anker (die Option „Chat about this“
    oder die Kopfzeile mit Kästchen ☐/☒) und die Hinweiszeile „Enter to select · … to navigate“. Kein
    Wort aus Freigaben („Do you want to …“, „Tab to amend“, „don't ask again“, „allow all“,
    „shift+tab“, „Yes, and“) darf dort stehen (`ControllerScreenReading.isQuestionDialog`). Bewusste
    Grenze: Eine Frage, die selbst „Do you want to …“ (oder ein anderes dieser Wörter) enthält, gilt
    nicht als Frage — der Text bleibt dann in der Zwischenablage. Bei englischen Fragen kommt das
    öfter vor; sicherer, als die Suche auf Teile des Dialogs zu beschränken, deren Lage nicht gemessen
    ist.

  Direkt vor dem Schreiben wird noch einmal geprüft, und nur mit eingeschaltetem Bracketed Paste
  (sonst kämen die Zeichen einzeln an). Gemessen an Claude Code 2.1.325: Ein Einfüge-Block springt dort
  ins Textfeld, Ziffern darin wählen nichts aus, mehrzeiliger Text bleibt im Feld; in einer Freigabe
  wird er ignoriert, eine einzeln getippte „1“ gäbe sie dagegen frei — deshalb nie einzelne Tasten.
  Steht schon Text im Feld, hängt der neue ohne Leerzeichen an. Ist der Bildschirm nicht ablesbar
  (hochgescrollt) oder fehlt die Hinweiszeile, bleibt es bei der Zwischenablage. Codex meldet keine
  Rückfragen (WM8-67).

  **Grenzen der Messung:** Dass Ziffern im Einfüge-Block in der Frage nichts auswählen, gilt für
  Claude Code 2.1.325; nichts im Code merkt, wenn eine spätere Version das ändert (dann könnte ein
  Diktat wie „2 Minuten“ eine Option wählen). Dass eine Freigabe den Einfüge-Block ignoriert, ist nur für
  eine Bash-Freigabe gemessen; Bearbeiten, MCP und Plan sind nur über die Erkennung abgedeckt. Bei jeder
  neuen Claude-Code-Version einmal `scripts/claude-question-paste-check.sh` fahren (Wegwerf-Sitzungen
  in tmux außerhalb der App, zwei kurze Anfragen).
- **Ansichten am Bildschirm (Runde 5):** Bei einer Controller-Eingabe in einen Claude-Chat liest
  `controllerScreenSnapshot` die unteren 16 Zeilen des Terminals, nur wenn die Ansicht ganz unten steht
  (Zähler `controller.screen.read`), in drei Fassungen (`ControllerScreenCapture`): voller Text für
  Trennlinien und das abgeblendete Prompt-Zeichen „❯“, Text ohne Abgeblendetes für „Feld leer?“ und nur
  das Abgeblendete für die Hinweise. Claude zeichnet seine Hinweise abgeblendet (SGR 2); gesucht wird nur
  dort, mit sichtbarem Eingabefeld nur in den Zeilen darunter, ohne Feld nur in den zwei untersten nicht
  leeren Zeilen. Jede Ansicht braucht mehrere Teile ihres Hinweises (Claude Code 2.1.322): Transkript
  („Showing detailed transcript“ + „ctrl+o to toggle“), `/workflows` („x to stop“ + „s to save“ + „Esc to
  close“), `/tasks` („Enter to view“ + „x to stop“ + „Esc to close“ bzw. „x to stop“ + „Esc to go back“),
  Dialoge wie Zurückspulen („Enter to continue“ + „Esc to cancel“) und die Auswahl in der Fußzeile („Esc
  to collapse“ + „to stop all agents“), jeweils auch im knappen Stil. Normale Ausgabe mit denselben
  Wörtern zählt nie. In einer erkannten Ansicht schließt Kreis auch bei „arbeitet“, mit nur 0,3 s Sperre
  statt 1 s (ein zweites ○ vor dem Neuzeichnen träfe sonst den Hauptchat), ← ist frei, und Pfeile machen
  Kreuz scharf. Die Subagent-Ansicht wird bewusst nicht erkannt (dort steht „esc to interrupt“).
- Pfeiltasten gehen in jedem lebenden Chat ins Terminal (seit 12.11.2026, siehe Steuerkreuz), mit drei
  Absicherungen:
  1. Links nie ins leere Claude-Feld. Ist das Feld ablesbar, entscheidet der Bildschirm (sichtbar leer
     sperrt, sicher Text gibt frei); sonst die Schätzung unten. Erlaubt in einer Rückfrage, in einer offenen Auswahl
     im Ruhezustand und sobald irgendetwas im Feld stehen kann: getippt, diktiert, Rückleger nach einem
     Abbruch, mit ↑ zurückgeholt oder mit → als Vorschlag übernommen (`fieldMayHaveText`). Gesperrt nur
     direkt nach dem Absenden, solange seither nichts ins Feld kam. Dort schickt ← die Sitzung in
     Claudes Agent-Ansicht, so gingen am 12.11.2026 zwei Sitzungen verloren. Geprüft in der Belegung (`leftArrowAllowed`) und in
     `AgentTerminalController.sendKey` (`TerminalControlKey.controllerAllows` mit dem Entwurfs-Tracker).
  2. Hoch vom Controller (ohne Rückfrage und offene Auswahl) holt den letzten Prompt zurück. Bei Claude
     gilt er als Rückleger: „Weiter“, Menü-Befehle und `chats send` leeren das Feld vorher; bei Codex
     und Shell gilt er als Entwurf. Und ↑ als erster Pfeil macht Kreuz bei arbeitendem Chat nicht scharf.
  3. Ein Pfeil macht Kreuz bei Claude nur in einer erkannten Ansicht, einer Rückfrage oder einer
     offenen Auswahl scharf (Runde 5): Im Hauptfeld holte ↑ den letzten Prompt, und Kreuz schickte ihn
     bei „arbeitet“ erneut. Ohne sichtbares Eingabefeld (siehe unten) Kreuz bei arbeitendem Claude-Chat nur bis 5 s nach einem scharfen Pfeil (`arrowArmWindow`, ↓/←/→
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
- Arbeitet ein Claude-Chat oder ist sein Zustand unklar, schickt Kreuz Enter, sobald Claudes
  Eingabefeld sichtbar unten am Bildschirm steht (Entscheidung 13.11.2026, `claudePromptVisible`).
  Abgelesen wird beim Druck selbst, nicht beim Pfeil davor. Ein Freigabe-Dialog ersetzt das Feld; ist
  es zu sehen, ist also keiner offen. Enter schickt dann den Text ab oder reiht ihn ein (auch getippt
  oder per Hotkey diktiert), öffnet den gewählten Agenten in der Fußzeile oder tut im leeren Feld
  nichts. Steht unter dem vermeintlichen Feld ein Dialog (nummerierte Auswahl wie „❯ 1. Yes“ oder
  „Do you want to proceed“), gilt es nicht als Feld, ebenso, wenn seine erste Zeile selbst eine
  Auswahl ist (Dialog im Rahmen). Hinweise wie „esc to cancel“ oder „esc cancel“ zählen dafür nicht:
  Sie stehen auch in der Fußzeile unter dem echten Feld („opening… · esc to cancel“, „enter save ·
  esc cancel“), und Dialoge zeigen ihre Hinweiszeile nicht immer (2.1.323). Grenze: Ein Entwurf, der
  mit „1. “ beginnt, gilt nicht als Feld; Kreuz folgt dann der vorsichtigen Regel. Steht nur ein mit
  ↑ zurückgeholter oder nach einem Abbruch zurückgelegter Prompt im Feld, gilt ebenfalls die
  vorsichtige Regel, sonst schickte ↑ + Kreuz den letzten Prompt noch einmal ab (in der
  Fußzeilen-Auswahl nicht: dort öffnet Enter den Agenten). Vorher wirkte Kreuz bei arbeitendem Chat
  kaum: Getippter Text zählte nicht, und der erste ▼ in die Fußzeile machte Kreuz nicht scharf, weil
  der Bildschirm gelesen wurde, bevor Claude neu gezeichnet hatte.
- Hängt Kreuz bei „arbeitet“ allein am sichtbaren Feld (keine frische Eingabe, kein scharfer Pfeil,
  keine offene Auswahl), geht Enter erst nach einer Nachprüfung raus: 0,1 s nach dem Druck wird der
  Bildschirm noch einmal gelesen (`confirmSettleDelay`). Steht das Feld dann noch da und ist derselbe
  Chat ausgewählt, kommt Enter; ist inzwischen ein Dialog im Bild, „geht nicht“. Grund: Zwischen dem
  Moment, in dem Claude auf einen Dialog umschaltet, und seinem ersten Bild steht noch das Feld da,
  und das betrifft jeden Druck bei sichtbarem Feld. Claude zeichnet während eines Turns etwa alle
  50 ms neu (Schimmer am Spinner, 2.1.323), danach ist der Dialog sicher im Bild. Eine Bedingung
  „seit 150 ms keine Ausgabe“ ginge nicht, sie wäre während eines Turns nie erfüllt. Vor jedem
  Ablesen leert der Controller den Puffer einer gedrosselten Pane (Raster ohne Fokus, Chat in zwei
  Workspaces), sonst sähe er bis zu 80 ms alte Bytes.
- Ist das Feld nicht zu sehen oder nicht ablesbar (Dialog, Transkript und andere Ansichten,
  hochgescrollt, Codex, Shell), gilt die vorsichtige Regel: Kreuz schickt Enter nur, wenn in den
  letzten 30 s per Controller getippt, gelöscht oder diktiert wurde und seitdem nichts abgeschickt
  wurde — auf keinem Weg: Kreuz auch in einer Rückfrage, Enter der Tastatur, `chats send`, Diktat mit
  Senden, Befehle aus dem Menü. Zwischen dem Erscheinen eines Freigabe-Dialogs und dem Status
  „wartet“ liegt eine Lücke, in der Enter sonst die Vorauswahl bestätigte. Der Entwurfs-Verdacht
  zählt dafür nicht, und Tippen auf der Tastatur auch nicht.
- Restrisiko der Feld-Regel: Ist Claude so beschäftigt, dass das erste Bild eines Dialogs länger als
  0,1 s ausbleibt, sieht die Nachprüfung noch das Feld, und Enter bestätigte die Vorauswahl. Die
  vorsichtige Regel hat dieselbe Lücke, solange eine Eingabe per Controller frisch ist (30 s); dort
  gibt es keine Nachprüfung.
- Ein zweites Escape innerhalb 1 s wird verschluckt (Claude öffnet sonst das Zurückspulen).
- Escape per Tippen nur bei ruhendem oder fragendem Chat; „gerade gesendet“ (3 s nach jedem
  Versand: Enter vom Controller oder der Tastatur, Diktat mit Senden, `chats send`) und unbekannter
  Status zählen als arbeitend — außer bei offener Auswahl des Menüs.
- Pause (L1 + R1, Sperre, Ruhezustand, Spiel), Trennung und Ausschalten schließen Dynamic Island, Menü und Liste.
  Ein per Tastatur geöffneter Ctrl+Tab-Umschalter schließt erst, wenn der Controller wirklich etwas
  ausführt (das bloße Loslassen einer Ebene ohne offene Dynamic Island zählt nicht).
- Die R1-Raute folgt den Regeln des Options-Menüs (`ControllerMenuModel.isEnabled`): Bei offener
  Rückfrage sind „Weiter“, „Modus wechseln“ und „Befehle“ aus, „Konto wechseln“ geht. Die Rückfrage wird
  beim Drücken frisch gelesen.
- „Weiter“ und „Modus wechseln“ — in der Raute und im Options-Menü — nur, wenn der Chat ruht: nicht bei
  „arbeitet“, unbekanntem Status oder 3 s nach einem Absenden. Zwischen dem Erscheinen eines
  Freigabe-Dialogs und dem Status „wartet“ bestätigte „Weiter“ mit Enter die Vorauswahl, und Shift+Tab
  heißt dort „alle Änderungen erlauben“; Codex meldet nie „wartet“. Ausgegraut mit Hinweis in der Dynamic Island,
  ein Druck vibriert „geht nicht“; geprüft wird beim Auslösen frisch (`perform(_:setup:)`). Eingaben gehen an den Chat, der beim Öffnen der Dynamic Island ausgewählt war;
  sonst „geht nicht“.
- L1-Ebene: Bis Zeilenanfang löschen (Ctrl+U, 0x15) und Zeilenumbruch (Ctrl+J, 0x0A) nur bei Claude und
  Codex und nicht in einer Rückfrage — dieselben Regeln wie „Eingabe leeren“, auch in der Absicherung
  `controllerAllows`. In einer Shell zeigt die Dynamic Island den Hinweis, und es passiert nichts außer „geht
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
GameControllerInputSource ──┐  (Ereignis + Familie)       eigene serielle Queue
XboxPaddleHIDSource ────────┤  (HID-Bericht: Paddle-Maske, Tasten, Xbox-Knopf)
debug.controller (Skript) ──┤
                            ▼
                ControllerGesturePump → ControllerPaddleGate (pur) → ControllerGestureRecognizer (pur)
                            ▼  nur diskrete Gesten zum Main Thread
                ControllerManager → ControllerContextResolver + ControllerBindingResolver (pur)
                            ▼
                ControllerActionDispatcher → AgentChatsCommandCenter, AgentTerminalController,
                                             AppState (Diktat), ClipboardHistoryController
```

| Teil | Datei | Aufgabe |
|---|---|---|
| Kern | `Services/Controller/Core/` | Tasten, Gesten, Zusammenhang, Belegung, Legende, Listen- und Menü-Modell, Regeln für Licht, Warte-Signal und Spiele — nur Foundation, ein Quelltext-Test erzwingt das |
| Quelle | `GameControllerInputSource` | Verdrahtung des Frameworks, Familie je Controller, Gerät der letzten Eingabe, Lichtleiste, Haptik (eine Engine je Controller, Neuaufbau nach Fehler) |
| HID-Quelle | `XboxPaddleHIDSource`, `Core/XboxHIDLayout.swift` | Paddles und Xbox-Knopf über `IOHIDManager` (nur Microsoft-Gamepads), Bericht bündeln, Zustand (`ControllerPaddleSupport`), Notbremse `controllerPaddleHIDEnabled` |
| Weiche | `Core/ControllerPaddleGate.swift` | Paddle-Maske → Paddle-Tasten, mitgeschickte Gesichtstaste verschlucken, Zurückhalten bis zum Urteil (40 ms) |
| Pumpe | `ControllerGesturePump` | Weiche und Erkennung auf eigener Queue; `DispatchSourceTimer(.strict)` nur, solange etwas gedrückt ist oder die Weiche zurückhält, dann auch Aktivität gegen App Nap |
| Manager | `ControllerManager` | Ein/Aus nach Schaltern, Pause, Hintergrund-Zustand (Systemwert wird zurückgelesen), Zähler je Taste |
| Ausführer | `ControllerActionDispatcher` | Schnappschuss der App je Eingabe, Ausführung über Schnittstellen (`ControllerTerminalControlling`, `ControllerDictationControlling`, `ControllerAppEnvironment`) |
| Rückmeldung | `ControllerFeedback` | Lichtleiste, Warte-Signal, automatische Pause, Maus/Tastatur geben Liste, Menü und Dynamic Island ab |
| Dynamic Island | `Core/ControllerIsland.swift`, `Core/ControllerIslandApp.swift` (App-Raute, Schalter, Konto im Kopf), `Core/ControllerLimits.swift` (Limits-Karte), `ControllerActionDispatcher+Island.swift`, `+AppDiamond.swift`, `ControllerIslandPresenter`, `Views/Controller/ControllerIslandView.swift` mit `+QuickDraw` und `+Limits` | Modell pur im Kern, gebaut im Ereignis-Pfad (`ControllerIslandRows` für die Chat-Zeilen, `ControllerLimitRows` für die Karte, `AgentChatsView+ControllerIsland` für Projekte und Konto); Fenster an der Notch bzw. als Pille; Signpost `controller.islandShow` (Budget 33 ms) |
| Limits | `Services/Shared/AccountLimitsStore.swift` | letzter Stand je Konto (Prozent, Rücksetzzeit, Problem), passiver Abruf höchstens einmal je Minute, `refresh()` wie ↻; die Popovers tragen ein |
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
  Markierung von „Wohin“ (Start auf dem aktuellen Eintrag, „vorher“, Projekte, Reiterwechsel);
  `--filter ControllerLimits` Limits-Karte, App-Raute und Konto eines Chats im Kern sowie den
  `AccountLimitsStore` (Fehlschläge behalten den letzten Stand); `--filter StayAwake` auch die stille
  Prüfung der Freigabe ohne Seitenleiste;
  `--filter NotchPillPlacement` die Lage von Pille und Dynamic Island ohne Notch.
- `swift test --filter ControllerPaddle` — Paddles im Kern, Weiche (`ControllerPaddleGateTests`) und
  Ausführer; `--filter ControllerFamily` Tastennamen und Legende ohne Touchpad; `--filter XboxHID` das
  Bündeln der HID-Berichte und den Debug-Schritt `hid:`; `--filter ControllerManagerHID` HID-Quelle,
  Notbremse und Belegung im Manager.
- `swift test --filter Controller` — Kern, Ausführer, Manager, Debug-Kanal; die Ebenen in
  `ControllerGestureRecognizerLayerTests`, `ControllerBindingResolverLayerTests` und
  `ControllerActionDispatcherIslandTests`.
- `make snapshots ONLY=controller` — Einstellungsseite, Legende in zehn Zuständen (mit Raster samt Ziel von L2, offener Auswahl und Shell),
  Menü mit beiden Ebenen, Liste der Ausgabemodi an der Pill; `ONLY=controller-menue-karte` die Menü-Karte am
  Chat (Einzelansicht, Raster mit Gruppe Workspace, Rastergröße, Liste, große Kachel, kleines Fenster mit
  Scrollen); `ONLY=controller-insel` die Dynamic Island (Wohin:
  Chats mit Markierung auf dem aktuellen Chat und „vorher“ gleich darunter, nach zwei Schritten, ohne
  vorigen Ort, Workspaces, mit
  Notch-Zählern; Schreiben, Schreiben in der Shell; Schnellbefehle, bei Rückfrage, wenn der Chat
  arbeitet; als Pille Chats, Schnellbefehle, Shell; Pille oben mit Dynamic Island nach unten, Pille unten
  mit Dynamic Island nach oben); `ONLY=controller-insel-paket` das Insel-Paket (zwei Rauten an der Notch und als
  Pille, Chat arbeitet, Diktat, Bestätigung von Glocke und Wach bleiben, fehlende Freigabe, Limits-Karte (auch während eines Diktats ohne „✕ aktualisieren“)
  und viele Konten mit Fehlerzeilen als Pille, „Wohin“ mit Markierung auf dem aktuellen Chat und „vorher“,
  Reiter „Workspaces & Projekte“ mit der Markierung auf dem vorigen Projekt gleich unter dem aktuellen
  Workspace, an der Notch und als Pille);
  `ONLY=clipboard-verlauf-controller` die Fußzeile und das Menü im Verlauf (auch mit Xbox);
  `ONLY=controller-xbox` Legende, Menü-Karte, Dynamic Island und Einstellungen mit Xbox-Zeichen, die
  Einstellungen mit lesbaren, nicht lesbaren und ohne Paddles.
- `whisperm8 debug controller state` — Verbindung (mit `family`), Schalter, Zähler je Taste (App vorne /
  im Hintergrund), zuletzt aufgelöste Gesten; unter `paddles` der HID-Zustand (`source`: none,
  disabled, noPaddles, readable, notReadable), `hidEnabled`, `listenAccess`, die Belegung, `lastMask`
  und die Zahlen der Weiche (`reports`, `swallowed`, `holds`, `holdsExpired`, `longestHoldMs`).
- `whisperm8 debug controller sequence "hid:4+cross,down:cross,up:cross,hid:0-cross"` — spielt die
  Weiche ohne Gerät durch: HID-Bericht mit Paddle-Maske 4 und A, danach A von GameController (wird
  verschluckt); `hid:+home` drückt den Xbox-Knopf.
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
- Durch das Archiv führt der Controller nicht: „Archiv zeigen“ im Options-Menü öffnet es in der
  Seitenleiste (die dafür aufgeht), die Listen-Navigation bleibt dort leer. Wiederherstellen geht mit der
  Maus, zurück über „Archiv verlassen“. Grund: Archiv-Zeilen stellen beim Klick wieder her, statt einen
  Chat zu öffnen, und ihre Gruppen klappen nur in der Ansicht auf und zu.
- Was eine Projektgruppe per „N weitere anzeigen“ zusätzlich aufgeklappt hat, erreicht die
  Listen-Navigation nicht; sie reicht bis zum Startlimit der Gruppe und immer bis zum gewählten Chat.
- Zurück mit L2 folgt dem Workspace, den das Fenster referenziert, auch wenn der Bezug veraltet ist:
  Raster W, dann Chat Y (nicht in W), dann Chat X (in W) aus der Seitenleiste — X in der Einzelansicht
  zählt als Workspace W, nicht als eigener Chat.
- Umbelegen geht nur bei den Paddles; die übrige Belegung ist eine pure Tabelle, auf die das später
  aufsetzen kann.
- **Xbox:** Über USB spricht der Elite vermutlich GIP über Apples Treiber und erscheint nicht als
  HID-Gerät — dann „nicht lesbar“ und Rückfall. Zwei Xbox-Controller gleichzeitig: Paddles nur am
  ersten Elite. Ein Elite, der zwar geöffnet wird, aber nie 0x81-Werte liefert, wird nicht als „nicht
  lesbar“ erkannt; die Paddles wirken dann nach 40 ms als ihre Gesichtstasten (sichtbar an
  `holdsExpired` im Debug-Kanal). DualSense Edge (Rücktasten über `physicalInputProfile`) ist nicht
  angebunden. Die Share-Taste der Series X|S bleibt frei (macOS nutzt sie für Bildschirmfotos).
- **Runde 5, Bildschirm-Lesen:** Die Hinweistexte gelten für Claude Code 2.1.322; ändert Claude sie,
  erkennt der Controller die Ansicht nicht mehr (dann gilt die alte Regel, nichts wird gefährlicher).
  Kreuz bei „arbeitet“ verlässt sich darauf, dass Claudes Dialoge das Eingabefeld ersetzen und nicht
  darunter erscheinen; ändert sich das in einer neuen Version, die Regel neu prüfen.
  Ob SwiftTerms Cursor im eingebetteten PTY an der Schreibmarke steht (Grundlage für L1 ▲▼ und
  „sicher Text“), ist am Gerät zu bestätigen. Ein grauer Platzhalter, der nicht als abgeblendet markiert
  ist, zählt nicht als Text.
- Schaltet man in Claude die Sprachfunktion ein (`voiceEnabled`), wird Leertaste zum Sprechknopf — dann
  auch Dreieck.
- Ctrl+L zeichnet in Claude Code 2.1.322 nur neu (`chat:clearInput` und `chat:clearScreen` teilen den
  Handler `forceRedraw`); in Codex leert Ctrl+L die Oberfläche, deshalb „Neu zeichnen“ nur für Claude.
- Ein mit ↑ zurückgeholter Prompt zählt nur, wenn der Controller das ↑ geschickt hat; ein ↑ auf der
  Tastatur sieht der Entwurfs-Tracker nicht als Zurückholen. Bei „arbeitet“ schickt Kreuz einen so
  geholten Prompt deshalb ab, sobald das Feld sichtbar ist (offen, Entscheidung beim User).
- „Jetzt senden“ hängt an Claudes Warteschlange im Transcript (`queue-operation`); 2.1.322 nimmt
  Wartendes meist schon an der nächsten Tool-Grenze auf.
