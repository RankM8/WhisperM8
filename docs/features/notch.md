---
status: umgesetzt, wartet auf make-dev-QA; vereinte Pille neu (12.11.2026, Kill-Switch unifiedPillEnabled), Übergang ins Diktat ohne Sprung; Kamera-Insel (Dynamic Island) seit 18.11.2026, aufgeklappt als große Form seit 19.11.2026
stand: 2026-11-20
feature: Statusanzeige an der Notch und vereinte Pille
---

# Statusanzeige an der Notch

Eine kleine Anzeige an der MacBook-Notch (an einer Kamera-Insel wird die Insel selbst
seitlich breiter, wie bei Apple, auf einem Bildschirm ohne Notch ist sie eine dunkle
Pille, die immer dasteht) zeigt, wie es den Agent Chats geht: wie viele arbeiten,
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

**Was sie zeigt, immer nur eins** (`UnifiedPillPriority`): Dynamic Island vor Diktat vor
offener Liste vor Hinweis „braucht dich“ vor Ruhe mit Zählern.

| Zustand | Ohne Notch | Mit Notch |
|---|---|---|
| Ruhe | Pille oben mittig: Kern als stille graue Linie, rechts die Zähler | wie bisher: Zähler unter der Notch, nichts los = nichts zu sehen |
| Hinweis | Kern, Punkt, Chat-Name, Wort, „+ n“, einmal ca. 4 s | wie bisher |
| Liste | wächst aus der Pille, Pillen-Zeile bleibt stehen; unten „Status in der Pille ausblenden“ | wie bisher |
| Diktat | die Pille wächst in die Diktat-Pille hinein (Breite um die Mitte), links Raute bzw. Ring für wartende Chats und Fehler | das schwarze Band wächst nach unten in die Diktat-Zeile, Raute links |
| Dynamic Island (Controller) | wächst aus der Pille, mit zwei Rauten unter R1 rund 700 pt breit, immer ganz auf dem Bildschirm | wächst aus der Notch |

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

**Tiefschwarz statt Glas** (Einstellung „Solid black background“,
`pillSolidBlackEnabled`, Standard aus): Die Pille ist dann auch ohne Notch
deckend schwarz wie an der Notch, in jedem Zustand (Ruhe, Hinweis, Liste,
Diktat, Insel samt Limits-Karte, Rauten und Reitern). Haarstrich und Schatten bleiben, damit die Pille auf einem
dunklen Schreibtisch ihren Umriss behält. Entschieden wird an einer Stelle
(`PillSurface` in `PillGlass.swift`); den Wert hält `PillAppearance`, das bei
Änderungen der Preferences neu liest, deshalb wirkt der Schalter sofort auf
sichtbare Pillen. Dazu gehört auch die Liste der Ausgabemodi, die beim
Moduswechsel per Controller an der Diktat-Pille aufklappt, und zwar ohne
Notch und an der Notch (dort passt sie dann zur ohnehin schwarzen Pille; mit
Option aus bleibt sie auch an der Notch Glas). Nur mit vereinter
Pille: Die getrennte Diktat-Pille (Kill-Switch) bleibt samt ihrer Liste Glas,
ebenso die Menükarte des Controllers am Chat. Die Menüs von Modus und Kontext
(mit den Vorschaubildern) sind Menüs von macOS und bleiben, wie sie sind.

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

**Übergang ins Diktat:** Startet ein Diktat auf dem
Bildschirm, auf dem die Pille steht, wird die Pille selbst zur Diktat-Pille:
Sie wächst aus ihrer Mitte in der Breite (dieselbe Kurve, 0,35 s), der graue
Kern bleibt derselbe Kern, gleitet mit und färbt sich zum Aufnahme-Kern. Kein
Versatz, kein Aus- und Einblenden der ganzen Pille. Am Ende zieht sie sich
genau so in die ruhende Pille zurück, mit den Zählern von jetzt (auch einem
nachgeholten Hinweis). An der Notch wächst das schwarze Band bzw. die Zeile
mit den Zählern nach unten in die Diktat-Zeile und schrumpft danach zurück;
ist an der Notch nichts los, wächst die Zeile aus dem Band in der
Aussparung. Ein Diktat auf einem anderen Bildschirm erscheint dort wie bisher
direkt, die ruhende Pille auf dem anderen Bildschirm bleibt stehen. Ohne
Notch erscheint das Diktat auch bei offener Liste, im Vollbild und mit
ausgeschaltetem Status direkt; an der Notch wächst es in diesen Fällen aus dem
Band.
Die Aufnahme wartet nie auf die Animation: Sie startet und endet sofort, nur
das Bild folgt.

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
unteren nach oben (Statusliste, Dynamic Island, Liste der Ausgabemodi am Controller;
die Menüs von Modus und Kontext legt macOS selbst passend).

**Vollbild:** In Ruhe ausgeblendet, Diktat und Dynamic Island erscheinen trotzdem.
**Aus Bildschirmfotos ausblenden** gilt für die ganze Pille, auch das Diktat.
**Status aus:** Die Pille erscheint nur beim Diktat und für die Dynamic Island.

**Technik:** Die Diktat-Logik ist unberührt (Coordinator, Aufnahme,
Auslieferung). `OverlayController` entscheidet nur, wo die Diktat-Pille steht
und wie sie aussieht (`OverlayPresentation`: `classic`, `pill`, `notch`,
`RecordingPanel+UnifiedPill.swift`). Die Status-Seite hängt in
`NotchStatusController+UnifiedPill.swift`. Beide treffen sich in
`UnifiedPillHub` (Bildschirm des Diktats, Raute, Ruhebild); der Status übernimmt den
Bildschirm aus dem gemeldeten Wert, er liest den Hub dabei nicht erneut
(`@Published` meldet im willSet, dort stünde noch der alte Wert). Es bleiben getrennte
Fenster, von denen je Bildschirm immer nur eins sichtbar ist; so läuft das
Diktat weiter durch sein bewährtes Fenster (nicht aktivierend, nie Key, über
Vollbild-Apps).

**Technik des Übergangs:** Das Diktat-Fenster zeigt zuerst das Ruhebild der
Pille (`UnifiedPillRestLook`: Kern und Zähler bzw. Hinweis, an der Notch die
Zeile unter der Aussparung oder nur das Band), genau an deren Stelle. Dafür
darf AppKit das Diktat-Fenster nicht unter die Menüleiste schieben
(`RecordingPanel.allowsAboveMenuBar`, auch ohne Notch): Sein Schattenrand
ragt oben in die Leiste, sonst stünde die Pille bis zu 24 pt zu tief und
spränge beim Start nach unten. Das
Ruhebild liefert die Status-Seite über den Hub
(`NotchStatusController.restSnapshot`), aus ihrem Zustand gerechnet, nicht
aus dem Fenster. Es wird aus denselben Bausteinen gezeichnet wie die
Status-Pille (`PillRestCoreView`, `UnifiedPillRestStatus`, `NotchHeaderRow`);
ein Pixeltest hält beide gleich (drei Farbstufen Toleranz). Dazu ist die
Diktat-Pille der vereinten Pille gebaut wie die Status-Pille: erst auf die
Kapsel zugeschnitten, dann ein Schatten. Vorher warf jede Ebene einen
eigenen Schatten unter das durchscheinende Glas, die Pille war im Fenster
sichtbar dunkler (Körper 82 statt 91 von 255) und sprang beim Übergang im
Ton. Die getrennte Diktat-Pille (Kill-Switch) bleibt, wie sie war.

Das Diktat-Fenster erscheint zuerst **unsichtbar** über der Status-Pille
(Inhalt mit Deckkraft 0). Hat der Main Thread dieses Bild abgegeben
(Beobachter direkt nach der CATransaction am Ende des Run-Loop-Durchlaufs,
`OverlayController.afterNextCommit`) und sind danach 50 ms vergangen, steht
es sicher auf dem Bildschirm (gemessen: ein neues Fenster erscheint 18 bis
33 ms nach dem Abgeben). Dann tauschen beide in **einer** CATransaction ihre
Sichtbarkeit: Diktat-Inhalt sichtbar, Inhalt der Status-Pille unsichtbar
(`UnifiedPillHub.setStatusContentHidden`). Im selben Durchlauf beginnt die
Pille in einer SwiftUI-Animation ins Diktat zu wachsen (`showsRestLook`, Kern
über `matchedGeometryEffect`); die Status-Pille geht erst aus dem Weg, wenn
der Tausch auf dem Bildschirm ist, auch wenn das Wachsen schon durch ist.
Läuft der Beobachter nie (anderer Run-Loop-Modus), geht es nach 300 ms über
einen Ersatzweg weiter, damit das Diktat nicht unsichtbar bleibt. Wird die
Pille im Diktat auf einen anderen Bildschirm gezogen, wandert die
Unsichtbarkeit der Status-Pille mit (`UnifiedPillHub.dictationMoved`). Am Ende umgekehrt: zurück ins Ruhebild,
die Status-Pille erscheint unsichtbar wieder (ohne Animation, mit dem
aktuellen Wert), nach ihrem Bild der Rücktausch, danach schließt das
Diktat-Fenster. So steht in jedem Bild genau eine Pille: keine Lücke, und
keine zwei Glas-Pillen übereinander (die wären dunkler; vorher drei Bilder
lang so, Körper 60 statt 91). Ein beschäftigter Main Thread verschiebt den
Tausch nur nach hinten, vorher lief ein fester Zeitgeber ab dem Aufbau und
konnte vor dem ersten Bild ablaufen. Der Ablauf ist rein und getestet
(`UnifiedPillMorph`: Ruhe, Übergabe, Wachsen, Diktat, Zurückziehen,
Übergabe, Schließen; Unterbrechungen über eine Generation), ausgeführt in
`RecordingPanel+PillMorph.swift`. Stopp im Wachsen zieht sich aus dem
jetzigen Stand zurück. Ein neues Diktat im Zurückziehen übernimmt dasselbe
Fenster und wächst wieder, aber nur, wenn es auf genau diesen Bildschirm
gehört (Bildschirmsuche wie sonst, `UnifiedPillMorph.canAdopt`; nur `show`
direkt nach `hide` im selben Lauf übernimmt sofort). Sonst schließt die alte
Pille sofort und das Diktat baut an seiner Stelle auf. Ändern sich die
Bildschirme während des Zurückziehens, schließt die Pille ebenfalls sofort.
Beim Zurückziehen fängt das Fenster Klicks selbst ab, statt sie an die App
darunter durchzulassen (das Einfüge-Ziel behält den Fokus); ein Klick auf den
Kern startet ein Diktat (über den Hub, derselbe Weg wie an der ruhenden
Pille), alles andere wird geschluckt, gezogen wird nicht. Kommt die
Status-Pille aus dem Diktat zurück, zeigt sie ihren Wert ohne Animation;
andere Wiedererscheinen bleiben animiert. Messpunkt `pill.morph` (Detail-Stufe, Budget 450 ms) meldet, wenn der
Main Thread den Übergang aufhält. Verschiebt AppKit das Diktat-Fenster beim
Einblenden doch (Menüleiste), steht im Log `unified_pill_moved_on_order_front`.

**Prüfen ohne Hinsehen:** `whisperm8 debug pill [--busy <ms>]` spielt den
Übergang ohne Aufnahme durch und schneidet die Fensterliste mit (Lücke,
Versatz, Verschiebung beim Einblenden, Reihenfolge von Tausch und Fenstern),
Doku in [ui-testing.md](ui-testing.md).

**Messung vom 13.11.2026** (Aufnahme nur der Fenster der Test-Instanz, 60 Bilder
je Sekunde, je Lage zwei Läufe hin und zurück: oben mittig, ganz oben unter der
Menüleiste, frei in der Mitte, dazu 150 ms bzw. 60 ms beschäftigter Main
Thread beim Start; MacBook-Bildschirm als Bildschirm ohne Notch über
`WHISPERM8_TEST_NO_NOTCH`, ein Kontrolllauf oben mittig am 5120×1440-Bildschirm
mit demselben Ergebnis):

| | vorher | nachher |
|---|---|---|
| Bilder ohne Pille | 0 | 0 |
| Versatz der Oberkante | 0 pt (Sprung nach unten schon behoben) | 0 pt |
| zwei Pillen übereinander (dunkler) | 100 bis 717 ms je Lauf | 0 ms |
| Ruhebild im anderen Ton | 167 bis 217 ms je Lauf | 0 ms |
| größter Breitenschritt je Bild | 47 bis 150 pt | 31 bis 46 pt |
| Abstand Diktat steht → Status weg | 4 bis 35 ms (beschäftigt: 4 und 9) | Tausch ≥ 49 ms danach |
| Aufbau → Wachsen beginnt | 31 bis 43 ms | 65 bis 75 ms |

Ohne die Ausnahme an der Menüleiste zeigt dieselbe Messung den alten Sprung:
18 pt oben mittig, 24 pt ganz oben (`orderFrontShift` ebenso).

### Kill-Switch der vereinten Pille

```bash
defaults write com.whisperm8.app unifiedPillEnabled -bool NO
```

Getrennte Diktat-Pille (unten mittig, eine Lage für alle Bildschirme) und
Status-Pille (Fensterschatten, Bildschirmwahl) wie vor dem 12.11.2026, die
Einstellungen stehen wieder an den alten Stellen. Wirkt für die Status-Pille
sofort, für das Diktat beim nächsten Erscheinen.

## Kamera-Insel (Dynamic Island) am MacBook Pro

Neuere MacBook Pro haben statt der Notch eine Kamera-Insel: eine kleine
schwarze Kapsel, die frei in der Menüleiste schwebt. Die Anzeige verhält sich
dort wie Apples eigene Insel und folgt deren drei Darstellungen der Live
Activities (kompakt, minimal, expandiert): In Ruhe wird die Insel nur seitlich
breiter. Erst auf einen Klick oder kurz bei einem Hinweis wird die ganze Insel
groß: eine schwarze Fläche um die Kamera, ohne Hals und ohne Kasten darunter.

| Stufe | An der Insel |
|---|---|
| Kompakt (Ruhe, etwas los) | Die schwarze Kapsel wird auf einer Seite der Kamera 40 pt breiter (102 pt gesamt), gleiche Höhe, gleiche Oberkante, nichts unter der Menüleiste. Dort stehen zusammen ein Zeichen für den wichtigsten Zustand und seine Zahl: gelbe Raute, wenn ein Chat wartet; sonst roter Ring bei einem Fehler; sonst grüner Punkt, wenn einer arbeitet; sonst ein Haken für frisch fertig. Mit zweistelliger Zahl 8 pt mehr. Links der Kamera; reichen die Menüs heran, rechts |
| Minimal | Passen Zeichen und Zahl auf keiner Seite neben Menüs und Statussymbole, steht nur das Zeichen auf der Seite mit Platz (Flügel 26 pt). Zeigt Apples Insel gerade selbst etwas (Mikrofon, Kamera, Live Activity), steht das Zeichen als eigener kleiner Kreis mit 6 pt Abstand neben ihr, so hoch wie sie |
| Nichts | Nichts los, auf keiner Seite Platz oder keine Messung möglich: Von der Anzeige ist nichts zu sehen, nur Apples Insel |
| Expandiert: Hinweis | „Braucht dich“ klappt von selbst rund vier Sekunden zur großen Form auf (380 × 108 pt): oben die Zähler links und rechts der Kamera, darunter Chat-Name, die Art des Wartens (Freigabe mit Werkzeugname, Frage, Plan; sonst das Projekt) und das Wort (wartet, Fehler, fertig). Danach zurück auf kompakt; steht der Mauszeiger auf der Form, bleibt sie so lange stehen (höchstens 20 s). Ein Klick darauf öffnet die Liste |
| Expandiert: Liste | Ein Klick auf die Kapsel (oder der Hotkey) macht die Insel zur großen Form mit der Liste (420 pt breit): große Zeilen (56 pt, Titel 15 pt), oben die Zähler. Klick daneben, Klick auf die Kopfzeile oder Esc schließt |
| Diktat, kompakt | Die laufende Aufnahme steht als eigene kleine Kapsel in der Menüleiste links neben der Insel: Wellenform (Bewegung und Farbe tragen den Zustand: Aufnahme, Transkription, Nachbearbeitung) und Zeit, gleiche Höhe wie die Insel, 96 pt breit. Warten Chats oder gibt es Fehler, steht davor ein kleines Zeichen. Reichen die Menüs heran, steht die Kapsel rechts; ist es für die Zeit zu eng, zeigt sie nur die Wellenform (48 pt) |
| Diktat, aufgeklappt | Ein Klick auf die Kapsel lässt sie selbst zur großen Form um die Kamera wachsen (420 × 178 pt); eine zweite Wellenform daneben gibt es nicht. Oben wartende Chats mit Zahl und der Zustand in Worten, darunter breite Wellenform, Zeit, Bildschirmfoto und Clip, dann Ausgabemodus, Kontext, abbrechen und fertig, alle Knöpfe 44 pt groß. Ein Klick auf Kopfzeile oder Wellenform oder ein Klick daneben klappt sie zu. Fertig und Abbrechen gehen wie immer auch per Hotkey und Esc |
| Aufnahme per Controller | Steht von selbst in der großen Form (420 × 206 pt): Ziel-Chat („→ Chat“) und Ausgabemodus müssen ohne Klick sichtbar sein. Sonst wie das aufgeklappte Diktat: Ein Klick auf Kopfzeile oder Wellenform, ein Bildschirmfoto oder der Start eines Clips klappt sie zur Kapsel zu, ein Klick auf die Kapsel öffnet sie wieder |
| Schnellaktion | Eigene Kapsel in der Menüleiste neben der Insel: Zeichen im Puls der Nachbearbeitung, die Beschriftung („Korrigiere…“) und ✕ zum Abbrechen; als Hinweis („Erst Text markieren“) ein ruhiges Symbol ohne ✕. So breit wie ihr Text, links der Insel, sonst rechts. Sie klappt nicht auf |
| Dynamic Island des Controllers | Die große Form um die Kamera (mindestens 460 pt breit, so hoch wie ihr Inhalt), solange L1, R1 oder L2 gehalten ist: Kopfzeile mit Taste und Ebene links, Ziel rechts; „Wohin“ als Kacheln in zwei Spalten, „Schreiben“ als große Felder. Zu ist sie nur die Kapsel um die Kamera. Einzelheiten: [controller.md](controller.md) |

Im Vollbild ist die Anzeige wie bisher ausgeblendet, Diktat und Controller
erscheinen trotzdem.

**In Ruhe wird kein Menü verdeckt.** Links und rechts der Kamera gehört die
Leiste den Menüs und Statussymbolen (`auxiliaryTop…Area` reicht bis an die
Kamera). Die Kapsel wird deshalb nur dort breiter, wo eine Messung freien
Platz belegt, und hält 6 pt Abstand zum nächsten Menü oder Symbol (siehe „Was
neben der Kamera steht“). Die offene große Form dagegen darf Menüs und
Statussymbole neben der Kamera verdecken, solange sie offen ist, wie Apples
eigene aufgeklappte Insel (Entscheidung 19.11.2026): Sie geht nur auf einen
Klick auf bzw. beim Hinweis für rund vier Sekunden. Die Einstellung „Liste
beim Darüberfahren öffnen“ wirkt an der Kamera-Insel deshalb nicht; wer nach
einem Menü neben der Kapsel greift, hätte sonst plötzlich die Form darüber.
Steht ein Hinweis als große Form da und beginnt ein Diktat, geht er sofort weg
und wird nach dem Diktat einmal nachgeholt, wenn der Chat noch wartet.

**Diktat neben Apples Insel.** Beim Diktat läuft das Mikrofon, und macOS
zeigt das in der Insel selbst an: Sie wird breiter (orangefarbener Punkt,
anfangs mit Mikrofon-Zeichen), und ihr Fenster liegt über unserem. Die
Diktat-Kapsel steht deshalb nicht an der Kamera, sondern mit 6 pt Abstand
neben dem Platz, den Apples Hinweis braucht (links 36,5, rechts 47,5 pt neben
der Aussparung, gemessen). Sie steht dort von Anfang an, damit sie nicht
springt, wenn der Hinweis erscheint; nach außen rückt sie nur, wenn die
Messung eine noch breitere Insel zeigt, und bleibt dann für dieses Diktat dort.

**Ein Diktat geht an der Kamera-Insel nie unter die Menüleiste.** Mit Messung
steht die Kapsel dort, wo Platz ist. Ist auf keiner Seite Platz, oder gibt es
keine Messung (keine Berechtigung für Bedienungshilfen, Messung gescheitert
oder noch nicht da), steht trotzdem die schmalste Form neben der Insel (nur
die Wellenform; die Zeit steht in der aufgeklappten großen Form): ohne Messung
links, ohne Platz auf der Seite mit mehr Platz. In diesen Fällen kann die
Kapsel einen Menütitel oder ein Statussymbol verdecken und dort Klicks
abfangen. Das ist gewollt: Der Nutzer hat das Diktat selbst ausgelöst, es
dauert Sekunden, und die Aufnahme soll dort stehen, wo er sie erwartet.

Fällt eine Nachmessung aus (die vordere App antwortet nicht), bleibt die
Kapsel, wo die letzte gültige Messung sie hingestellt hat. Während des Diktats
wird bei jedem App- und Space-Wechsel neu gemessen, auch wenn die
Statusanzeige ausgeschaltet ist. Je Diktat schreibt die App einmal (0,6 s
nach dem Beginn, also mit der frischen Messung) eine Zeile
`island_dictation form=… reason=…` ins Log: in welcher Form es steht und
warum (`form=compact`, `minimal`, bei einer Schnellaktion `label`, per
Controller `large`; `measured`, `no_room`, `no_accessibility_permission`,
`no_measurement(Grund)`), dazu den freien Platz je Seite.

Die große Form geht nur per Klick auf, nie von selbst, auch nicht bei einem
Bildschirm-Clip: Wer einen Clip startet oder ein Bildschirmfoto macht, will
den Bildschirm zeigen, die Form geht dafür zu. Die Kapsel zeigt den laufenden Clip (roter Ring), ein Klick
öffnet sie wieder zum Stoppen. „Fertig“ steht aufgeklappt immer da, auch wenn
die Einstellung es in der Pille ausblendet.

**Nichts hängt an der Kamera-Insel mehr unter der Menüleiste** (seit
20.11.2026). Früher taten das zwei Fälle, weil sie Text zeigen bzw. ohne Maus
bedient werden:

- **Schnellaktion** (Korrigieren ohne Diktat, Hinweise): eine Kapsel mit
  Zeichen und Beschriftung neben der Insel, nicht die große Form. Nach Apples
  Muster für Live Activities ist ein kurzer Vorgang, der läuft und nichts von
  einem will, die kompakte Darstellung; aufgeklappt wird nur, was jemand
  bedienen will oder was kurz Aufmerksamkeit braucht. Eine Schnellaktion
  dauert ein, zwei Sekunden und hat genau einen Knopf (✕), der in die Kapsel
  passt; eine 420 pt breite Form über den Menüs wäre dafür zu viel. Ist auf
  keiner Seite Platz für die Beschriftung oder gibt es keine Messung, steht
  die Kapsel trotzdem da (ohne Messung links, sonst auf der Seite mit mehr
  Platz) und kann einen Menütitel verdecken: Die Beschriftung muss lesbar
  sein, der Nutzer hat die Aktion selbst ausgelöst (dieselbe Abwägung wie
  beim Diktat). Das Mikrofon läuft dabei nicht; die Kapsel hält nur Abstand
  zu dem, was Apples Insel gerade zeigt. Eine sehr lange Beschriftung (etwa
  der Hinweis, dass ein Feld nicht beschreibbar ist) macht die Kapsel
  höchstens so breit, wie das Fenster des Diktats reicht (rund 480 pt neben
  der Kamera); was darüber hinausgeht, wird gekürzt, der ganze Text steht im
  Tooltip. Das Fenster ist an der Insel dafür 1.100 pt breit statt 608.
- **Aufnahme per Controller:** die große Form des Diktats, von selbst offen,
  mit einer Zeile für den Ziel-Chat. Was der Controller öffnet, darf wie ein
  Klick Menüs neben der Kamera verdecken, solange es offen ist.

Frühere Fassungen: alle Zähler fest neben der Kamera ohne Messung, das
verdeckte Menüs; danach nur ein Hals um die Kamera mit den Zählern in einer
Zeile unter der Menüleiste, das hing in Ruhe wie ein schwarzes Stück unter der
Kamera; dann Zeichen links und Zahl rechts der Kamera, das las sich
schlechter als beides nebeneinander und brauchte auf beiden Seiten Platz;
zuletzt Hinweis, Liste und Diktat-Knöpfe an einem Hals mit Kasten unter der
Menüleiste, das sah aus wie ein Strich nach unten statt wie eine Insel, die
groß wird.

### Aufgeklappt: eine große Form (seit 19.11.2026)

Hinweis, Liste und aufgeklapptes Diktat sind EINE schwarze Fläche ohne Hals,
wie Apples aufgeklappte Insel: Sie wächst aus der Insel in Breite und Höhe,
ist auf die Kamera zentriert und beginnt auf Höhe der Insel
(`NotchIslandLargeGeometry`, `NotchIslandLargeStatusView`,
`IslandDictationView`). Seit 20.11.2026 ist auch die Dynamic Island des
Controllers dort diese Form (`ControllerIslandView+Large.swift`,
[controller.md](controller.md)).

Apples aufgeklappte Insel auf einem MacBook Pro mit Kamera-Insel (macOS 27.2.1):

| Wert | Ergebnis | Quelle |
|---|---|---|
| Aufgeklappt („Now Playing“) | 286 × 152 pt, 6 pt unter der Oberkante | Bildschirmfoto, ausgemessen |
| Ecken | rund 36 pt, weich auslaufend | Bildschirmfoto |
| Innenabstand | 16 pt seitlich und unten; der Inhalt beginnt rund 27 pt unter der Oberkante, unter der Zeile mit der Kamera | Bildschirmfoto |
| Schrift und Knöpfe | Titel rund 15 pt halbfett, Unterzeile 15 pt, Zeiten 12 pt, Bedienzeichen rund 30 pt | Bildschirmfoto |
| Kompakt mit Musik | 143 × 34 pt (802 bis 945), 6 pt unter der Oberkante: Cover links, Wellenform rechts der Kamera | Accessibility (`AXLiveActivity`) |

So ist es gebaut:

- **Form:** abgerundetes Rechteck mit 36 pt Ecken, auf die Kamera zentriert.
  Die Oberkante liegt dort, wo Apples Insel mit Inhalt beginnt (6 von 40 pt
  Sicherheitsrand, 2 pt über der Kapsel in Ruhe); so ragt Apples Insel nie
  oben über unsere Form. Hinweis 380 × 108 pt, Liste 420 pt breit, Diktat
  420 × 178 pt (Apples „Now Playing“: 286). Die Liste scrollt ab 420 pt Höhe
  und bevor sie unten aus dem Bildschirm ragt; auf einem schmalen Bildschirm
  wird die Form schmaler statt über den Rand zu reichen.
- **Kopfzeile (42 pt):** Apples Insel liegt immer über unseren Fenstern. Was
  sie zeigt (Musik, Mikrofon-Hinweis), steht deshalb oben in der Mitte der
  Form; die Kopfzeile lässt ihr so viel Platz, wie die Messung zeigt (in Ruhe
  ihre 65 pt, beim Diktat von Anfang an den Platz des Mikrofon-Hinweises).
  Links davon stehen wartende Chats, Fehler und arbeitende Chats mit Zahl,
  rechts frisch Fertiges bzw. beim Diktat der Zustand in Worten. Jede Seite
  behält ihre Breite, auch wenn die andere leer ist.
- **Liste:** Zeilen 56 pt hoch, Titel 15 pt halbfett, zweite Zeile 12,5 pt,
  Felder mit 16 pt Ecken; wartende Zeilen gelb, Fehler rot hinterlegt, die mit
  der Tastatur markierte Zeile umrandet. Dieselbe Liste wie an Notch und
  Pille (`NotchChatList`), nur mit größeren Maßen (`NotchListMetrics`).
- **Hinweis:** Chat-Name 16 pt, darunter die Art des Wartens („Approval:
  Bash“, „Question“, „Plan awaiting approval“; sonst das Projekt), rechts das
  Wort. Der Hinweis geht von selbst auf, auch bei einer Bildschirmfreigabe:
  Befehle, Dateinamen, Fragetext und Antworttext eines Chats stehen deshalb
  nie darin (`AgentSessionActivity.awaitingKindLine`), nur in der Liste. Nach
  vier Sekunden geht er zu; steht der Mauszeiger gerade auf der Form, wartet
  er, bis der weg ist (alle 0,4 s nachgesehen, höchstens 20 s), damit ein
  später Klick nicht das Menü darunter trifft.
- **Diktat:** erste Zeile breite Wellenform, Zeit (24 pt), Bildschirmfoto und
  Clip; zweite Zeile Ausgabemodus, Kontext, abbrechen, fertig. Alle Knöpfe
  44 pt. Die Wellenform folgt bei der Aufnahme allein dem Pegel (grau ohne
  Signal, grün beim Sprechen, gelb zu laut, wie der Kern der Pille); bei
  Transkription und Nachbearbeitung steht dort der Kern der Pille mit seiner
  Bewegung. Gegenüber dem Entwurf stehen Bildschirmfoto und Clip in der ersten
  Zeile: Mit beiden in der zweiten hätten Ausgabemodus und Kontext bei
  längeren Namen keinen Platz.
- **Bewegung:** EINE Federbewegung des Umrisses (Breite, Höhe, Lage und Ecken
  zusammen, rund 0,4 s) aus dem, was in Ruhe dasteht: der Kapsel mit Zeichen
  und Zahl, dem abgesetzten Kreis, der Diktat-Kapsel, oder Apples Insel selbst,
  wenn von uns nichts in der Menüleiste stand. Der Inhalt blendet erst ein,
  wenn die Form fast steht (0,18 s), und vor dem Schließen aus (0,1 s); die
  Form zieht sich in dieselbe Kapsel zurück. Mit „Bewegung reduzieren“ steht
  die Form sofort, nur der Inhalt blendet.
- **Fenster:** Die Anzeige bewegt nie Fenster und Form zugleich. Ihr Fenster
  ist in Ruhe genau die Kapsel; für die große Form wird es in einem Schritt
  ohne Animation so groß wie die Form (plus 16 pt Rand, damit die Feder
  überschwingen kann) und zeigt dabei noch die Kapsel, im nächsten Bild
  gleitet die Form. Beim Schließen umgekehrt, danach wird das Fenster wieder
  die Kapsel. Das Fenster des Diktats beginnt von vornherein auf Höhe der
  großen Form und fasst sie; es wechselt nie die Größe.
- **Klicks:** Das Fenster nimmt Klicks nur auf der Form an
  (`NotchHostingView.islandHitFrame`, beim Diktat `islandInteractiveParts`),
  nicht im Rand. Beim Schließen gilt sofort wieder nur die Kapsel, auch
  während die Form noch schrumpft: Die Menüleiste daneben ist gleich wieder
  bedienbar.
- **Verdecken:** Solange die Form offen ist, verdeckt sie Menüs und
  Statussymbole neben der Kamera (bei 420 pt Breite je 180 pt links und
  rechts der Kamera), wie Apples Insel. Kompakt und minimal bleiben, wie sie
  sind.

### Was Apple vorgibt

Quellen, Stand 18.11.2026:

- [HIG, Layout](https://developer.apple.com/design/human-interface-guidelines/layout):
  Den Sicherheitsbereich einhalten, damit Hardware und System wie die Dynamic
  Island keine Inhalte verdecken. Für macOS: keine Inhalte hinter dem
  Kameragehäuse am oberen Rand.
- [HIG, Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities):
  Die Insel ist deckend schwarz. Inhalte stehen dicht an der Kamera, links und
  rechts ähnlich breit, so schmal wie möglich; reicht eine Seite, bleibt die
  andere leer. Nichts bis an den Rand zeichnen, Ränder konzentrisch zur
  Außenform. Die große Form ist eine vergrößerte kleine: Elemente behalten
  ihren Platz. Bewegung nur als Wachsen und Schrumpfen, höchstens zwei
  Sekunden. Für den Mac gelten die Maße des iPhone (Inhalte passen notfalls in
  einen Kreis von 28 pt). Apps sollen nichts einbauen, das auf die Insel
  aufmerksam macht.
- [`NSScreen`](https://developer.apple.com/documentation/appkit/nsscreen):
  Öffentlich gibt es nur
  [`safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)
  (der vom Kameragehäuse verdeckte Rand) und `auxiliaryTopLeftArea` /
  `auxiliaryTopRightArea` (die freien Bereiche daneben), beide seit macOS 12.
  Eine öffentliche Angabe zu Form, Höhe oder Inhalt der Insel gibt es nicht,
  auch nicht in den
  [Release Notes zu macOS 27](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes).
- [ActivityKit](https://developer.apple.com/documentation/activitykit) und
  [`DynamicIsland`](https://developer.apple.com/documentation/widgetkit/dynamicisland):
  Der offizielle Weg in die Insel selbst sind Live Activities. Für Mac-Apps
  gibt es sie erst ab macOS 27.3 (zum Stand Beta), über eine Widget-Erweiterung.
  Das System bestimmt dort Form und Platz; eine Liste, ein Diktat mit Knöpfen
  oder die Controller-Insel lassen sich so nicht zeigen.
- [Apple Support 120684](https://support.apple.com/en-us/120684): Live
  Activities erscheinen in der Insel um die Kamera, ein Klick zeigt mehr,
  Wischen oder Control-Klick blendet aus.
- [`NSPrefersDisplaySafeAreaCompatibilityMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsprefersdisplaysafeareacompatibilitymode):
  betrifft nur Vollbild-Fenster einer App, nicht diese Anzeige.

Die drei Darstellungen einer Live Activity nach den HIG, an denen sich die
Anzeige ausrichtet:

- **Kompakt:** ein Element links, eines rechts der Kamera, zusammen eine
  Aussage, so schmal wie möglich; reicht eine Seite, bleibt die andere leer.
  Die Anzeige nutzt eine Seite und lässt die Kapsel nur dorthin wachsen.
- **Minimal:** Sind zwei Activities aktiv, zeigt jede nur noch ein Zeichen;
  eine hängt an der Insel, die andere steht abgesetzt daneben.
- **Expandiert:** auf eine Geste hin, und kurz von selbst, wenn sich etwas
  Wichtiges ändert.

Daraus folgt für die Anzeige: schwarz und deckend, in Ruhe nur seitlich
breiter, nach unten erst auf Klick oder kurz beim Hinweis, nichts liegt auf
der Insel selbst. Anders als eine Live Activity bekommt ein eigenes Fenster
den Platz neben der Kamera nicht vom System zugeteilt; es nimmt ihn nur, wenn
er nachweislich frei ist.

### Messung auf einem MacBook Pro mit Insel (18.11.2026)

macOS 27.2.1, eingebauter Bildschirm 3472 × 2266 Pixel, Standard-Skalierung
(1736 × 1133 pt, Faktor 2), gebaut mit dem SDK von Xcode 26.2:

| Wert | Ergebnis |
|---|---|
| `frame` | 1736 × 1133 |
| `visibleFrame` | 1736 × 1088, die Menüleiste ist 45 pt hoch |
| `safeAreaInsets.top` | 40 |
| `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` | je 838,5 × 40, dazwischen 59 pt Aussparung |
| Insel im Bildschirmfoto | schwarze Kapsel 59 × 32 pt, 8 pt unter der Oberkante, Unterkante bei 40 pt |
| Reihenfolge der Fenster | Das Fenster der System-Insel (Prozess `MenuBarAgent`, bildschirmfüllend) liegt vor einem eigenen Fenster auf Ebene `mainMenu + 3` und auch `mainMenu + 6` |
| Vollbild-Fenster | beginnt bei 45 pt (unter der Menüleiste), nicht bei 40 pt |
| Apples Insel mit Mikrofon | 111,5 pt breit, um die Kamera zentriert, oranger Punkt rechts; in den ersten Sekunden mit Mikrofon-Zeichen 143 pt |
| Apples Insel mit Kamera (Videoanruf) | 143 × 34 pt, von 802 bis 945 pt, 6 pt unter der Oberkante: links 36,5, rechts 47,5 pt über die Aussparung hinaus |
| Statussymbole | keine eigenen Fenster mehr; alle liegen als Kinder im Fenster der Menüleiste desselben Prozesses, der auch die Insel führt |

Zwei Folgen:

- **Die System-Insel liegt immer über unseren Fenstern.** Ein rotes
  Testfenster über der Inselgegend zeigt im Bildschirmfoto die schwarze Kapsel
  obenauf. Die Anzeige kann Apples Insel und alles, was das System darin zeigt
  (Mikrofon-Anzeige, Live Activities), nicht verdecken. Sie zeichnet deshalb
  nur Schwarz um die Insel herum.
- **Höhe der Insel und Höhe einer ausgeblendeten Menüleiste meldet das System
  nicht**, nur die Unterkante der Insel (`safeAreaInsets.top`) und ihre
  Breite. Dafür nimmt die Anzeige zwei gemessene Verhältnisse, als Anteile am
  Sicherheitsrand, damit sie bei jeder Skalierung stimmen: Die Insel beginnt
  ein Fünftel darunter (8 von 40 pt), die Menüleiste ist ein Achtel höher
  (45 zu 40 pt). So schließt der Hals oben bündig mit der Insel ab und ragt
  nicht über sie hinaus, und der Körper beginnt auch bei ausgeblendeter Leiste
  dort, wo sie beim Einfahren endet. Ein drittes Verhältnis stammt aus der
  Messung vom 19.11.2026: Mit Inhalt beginnt Apples Insel bei 6 von 40 pt;
  dort liegt die Oberkante der großen Form.

### Was neben der Kamera steht

`NotchIslandProbe` fragt über die Bedienungshilfen (öffentliche
Accessibility-Aufrufe) drei Dinge ab:

- **Menüs der vorderen App:** die Rahmen der Einträge ihrer Menüleiste
  (`NSWorkspace.menuBarOwningApplication`), auch wenn sie rechts der Kamera
  weiterlaufen. Ist WhisperM8 selbst vorn, geht das nicht über diese
  Schnittstelle: Ein Prozess bekommt seine eigene Menüleiste so nicht
  gemeldet. Die eigenen Menüs kommen dann aus dem Prozess selbst
  (`NotchIslandMonitor.ownMenuFrames`): die Rahmen, die AppKit für
  Bedienungshilfen führt, und wenn die nicht brauchbar sind, aus den Titeln
  geschätzt (Apple-Menü 34 pt, je Titel 22 pt Rand). Damit steht die
  Ruhe-Anzeige auch dann in der Menüleiste, wenn WhisperM8 selbst vorn ist.
- **Statussymbole:** Die Fensterliste (`CGWindowListCopyWindowInfo`) nennt
  den Prozess, dem die Insel gehört: Besitzer des obersten bildschirmbreiten
  Fensters an der Kamera. Dessen Fenster in Höhe der Menüleiste enthält die
  Statussymbole aller Apps mit ihren Rahmen.
- **Apples Insel:** Zeigt sie etwas, hat ihr bildschirmgroßes Fenster ein Kind
  mit genau dem Rahmen ihrer Kapsel; in Ruhe hat es keins.

Kein Prozessname, kein festes Maß. Das systemweite Accessibility-Element
fasst die Messung nicht an: Ein Zeitlimit daran gälte für alle Aufrufe der
App, auch für den Diktat-Kontext. Jede Anfrage hat ihr eigenes Zeitlimit
(0,25 s je Element), die ganze Messung eine Frist von 0,5 s, und es läuft nie
mehr als eine zugleich. Die Aufrufe liegen hinter einer austauschbaren Schicht
(`NotchIslandAX`), damit Tests sie ersetzen können.
`NotchIslandGeometry.presentation` wählt
daraus die Stufe, `band` die Breite. Ohne Berechtigung für Bedienungshilfen
oder wenn einer der drei Teile nicht zu ermitteln ist (anderer Aufbau in einer
späteren macOS-Version), gibt es keine Messung: Die Anzeige zeigt in Ruhe
nichts. Hinweis und Liste gehen trotzdem als große Form auf (aus Apples Insel
heraus, die Kopfzeile lässt ihr dann den Platz in Ruhe), das Diktat steht als
schmalste Kapsel neben der Insel.

Gemessen wird nicht laufend, sondern zu Ereignissen, die es ohnehin gibt
(`NotchIslandMonitor`, kein eigener Beobachter): bei App- und Space-Wechsel
zusammen mit der Vollbild-Prüfung (und 0,9 s später noch einmal), wenn sich
Zeichen oder Zahl ändern, alle 30 s, solange kompakt oder minimal etwas in der
Menüleiste steht, beim Klick auf die Kapsel vor dem Aufklappen, und wenn das
Diktat erscheint oder geht (dann einige Male nachgemessen, weil Apples Insel
ihre Breite erst nach und nach ändert).

### Wie die Insel erkannt wird

`NotchScreenInfo.cutout` unterscheidet nur aus diesen öffentlichen Werten, ohne
Modellnamen und ohne feste Maße:

- keine Aussparung: kein Sicherheitsrand oder keine freien Bereiche,
- Kamera-Insel: Die Aussparung ist weniger als dreimal so breit, wie sie tief
  reicht (hier 59 zu 40, also 1,5),
- Notch: alles Breitere (eine Notch liegt bei 5 bis 6).

Das Verhältnis bleibt bei jeder Skalierung gleich. Alle Maße der Anzeige
(`NotchIslandGeometry`) leiten sich aus Sicherheitsrand, Breite der Aussparung
und Höhe der Menüleiste ab; ein Modellname oder feste Punktwerte je Gerät
kommen nicht vor. Hat ein späteres Gerät eine anders proportionierte Insel,
stimmen die beiden gemessenen Verhältnisse nicht mehr genau: Der Hals säße
dann wenige Punkte zu hoch oder zu tief, schwarz auf schwarz. MacBooks mit
Notch und Bildschirme ohne Aussparung laufen durch denselben Code wie vorher;
Tests halten deren Rahmen und Form fest.

Mehrere Bildschirme: Die Wahl des Bildschirms ist unverändert, die Insel zählt
dabei wie eine Notch (`hasNotch`). Ein externer Bildschirm zeigt weiter die
Pille. Bei Bildschirmwechsel, anderer Auflösung und Menüleiste ein oder aus
wird neu gerechnet (`didChangeScreenParametersNotification`).

Vollbild: Unter der Insel beginnt ein Vollbild-Fenster unter der Menüleiste
(45 pt), bei ausgeblendeter Leiste an der Unterkante der Kamera (40 pt). Die
Vollbild-Erkennung lässt dort beide Kanten gelten
(`NotchScreenInfo.fullscreenTopInsets`), an der Notch wie bisher genau den
Sicherheitsrand.

### Kosten

Keine neuen Beobachter des Systems, keine zusätzlichen Fenster. Ein Takt
läuft nur, solange an einer Kamera-Insel etwas in der Menüleiste steht: alle
30 s eine Messung. Die Insel-Geometrie ist reine Rechnung beim Zeichnen
eines neuen Zustands, wie an der Notch.

Neu ist die Messung: rund 60 kurze Accessibility-Anfragen an die vordere App
und an den Prozess der Insel, gemessen 5 bis 27 ms, abseits des Main Threads
mit niedriger Priorität und 0,25 s Zeitlimit je Anfrage. Sie läuft nur auf
Bildschirmen mit Kamera-Insel und nur zu den oben genannten Ereignissen, also
bei jedem App-Wechsel zweimal und sonst höchstens alle 30 s; dazu liest sie
einmal die Fensterliste (einige Millisekunden). Die Form (`NotchHangingShape`) hat vier
animierte Werte statt einem (unterer Radius, Höhe, Breite und Lage des
Bands); das wirkt nur während der 0,2 bis 0,35 s eines Zustandswechsels.

Die große Form kostet nur beim Auf- und Zuklappen: eine einmalige
Federbewegung von rund 0,4 s (`NotchIslandLargeShape`, fünf animierte Werte,
rund 25 Bilder Layout), keine Dauerbewegung, kein Takt, kein neuer
Beobachter. Im Ereignispfad kommt je Auf- oder Zuklappen ein Fensterwechsel
ohne Animation dazu und eine einmalige Aufgabe, die das Fenster nach der
Bewegung wieder klein macht (0,42 s nach dem Schließen, 0,56 s nach einem
Wechsel von Form zu Form). Für die zweite Zeile des Hinweises liest die
Anzeige beim Neuaufbau den Stand des einen betroffenen Chats aus dem Speicher
(kein Beobachter des Activity-Stores, kein I/O). Nach den vier Sekunden des
Hinweises sieht sie alle 0,4 s nach, ob der Zeiger noch auf der Form steht,
nur solange er das tut und höchstens 20 s. Die offene Liste baut wie
bisher alle 500 ms neu, solange Chats arbeiten. Beim Diktat hängt die breite
Wellenform am Pegel (10 Hz) und zeichnet dann 22 Balken neu, nur solange die
große Form offen ist; zugeklappt zeichnet wie bisher nur der kleine Kern.
Solange die große Form des Diktats offen ist, hört ein Beobachter auf
Mausklicks neben ihr (zum Schließen); er wird beim Zuklappen entfernt. Das
Fenster des Diktats ist an der Insel höher als bisher (194 statt 101 pt,
durchsichtig) und seit 20.11.2026 breiter (1.100 statt 608 pt, für lange
Beschriftungen einer Schnellaktion); Klicks nimmt es weiter nur auf dem Sichtbaren an, und dem
Mauszeiger folgt es nur über der Kapsel bzw. der offenen Form (nicht über der
ganzen Ansicht um die Kamera, sonst wertete jede Fahrt durch die Menüleiste
die Pille neu aus).

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

Die Dynamic Island des Controllers (früher „Insel“) wächst ohne Notch aus genau
dieser Pille (siehe [controller.md](controller.md)).

**Ausschalten direkt in der Notch:** Unten links in der aufgeklappten Liste
steht „Turn off notch“. Das setzt denselben Schalter wie die Einstellungen
(`notchStatusEnabled`). Wieder an über Einstellungen oder Menüleiste (oder
einen selbst belegten Hotkey; ab Werk hat er keine Belegung).

## Einstellungen

Vereinte Pille: Einstellungen, General, Abschnitt „Pille und Notch“
(`PillSettingsSection`), mit Verweisen aus Recording und Agent Chats. Dort:
Chat-Status in der Pille zeigen, Ausblenden aus Bildschirmfotos (ganze
Pille), Tiefschwarzer Hintergrund (`pillSolidBlackEnabled`, aus), Fertige
Chats, Liste beim Darüberfahren, Lage zurücksetzen, Hotkeys
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
| Liste beim Darüberfahren öffnen (nicht an einer Kamera-Insel) | `notchStatusExpandOnHover` | aus |
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
| `Services/AgentChats/Notch/NotchIslandGeometry.swift` | Rein: Notch oder Kamera-Insel (`cutout`), Zeichen und Zahl (`NotchIslandSignal`), Stufe aus der Messung (`presentation`), Band und Rahmen je Zustand |
| `Services/AgentChats/Notch/NotchIslandLargeGeometry.swift` | Rein: die aufgeklappte große Form an der Kamera-Insel (Maße je Inhalt, Kopfzeile um Apples Insel, Umrisse der Bewegung, Fenster und Klickfläche) |
| `Services/AgentChats/Notch/NotchStatusController+IslandLarge.swift` | Hinweis und Liste als große Form: Fenster in zwei Schritten auf und zu, Klickfläche |
| `Views/NotchIslandLargeView.swift` | Große Form der Status-Anzeige (`NotchIslandLargeStatusView`), Umriss (`NotchIslandLargeShape`), Kopfzeile, Bewegung, Maße der großen Liste (`NotchListMetrics`) |
| `Views/IslandDictationView.swift` | Diktat an der Kamera-Insel: Kapsel in der Menüleiste und aufgeklappte große Form mit allen Knöpfen |
| `Services/AgentChats/Notch/NotchIslandProbe.swift` | Messung der Menüleiste über die Bedienungshilfen (`NotchIslandProbe`, Aufrufe hinter `NotchIslandAX`) und letzter Stand je Bildschirm (`NotchIslandMonitor`) |
| `Services/AgentChats/Notch/NotchPillPlacement.swift` | Rein: Stellen der Anzeige (Notch, Pille), gemerkte Lage, Öffnungsrichtung, Begrenzung auf den Bildschirm; auch für die Dynamic Island des Controllers |
| `Services/AgentChats/Notch/NotchStatusController.swift` | AppKit-Seite: Beobachter, Klick-daneben, Hotkey, Einstellungen, Aufklappen |
| `Services/AgentChats/Notch/NotchStatusController+Placements.swift` | Je Stelle ein Fenster (`NotchSlot`), Bildschirm des Agent-Chats-Fensters, Vollbild, Ziehen und Zurücksetzen der Pille |
| `Windows/NotchPanel.swift` | Nicht aktivierendes `NSPanel`, Hosting-View mit erstem Klick und Klick/Ziehen/Doppelklick der Pille |
| `Views/PillGlass.swift` | Dunkles Glas, Höhe und Schatten der Diktat-Pille, geteilt mit Pille und Dynamic Island |
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
  Notch-Breite = Bildschirmbreite minus die beiden freien Bereiche. Ist die
  Aussparung schmaler als das Dreifache ihrer Tiefe, ist es eine Kamera-Insel
  (Abschnitt oben).
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
- Dynamic Island: Hält man am Controller L1, R1 oder L2, legt sich die Dynamic Island
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
- `NotchIslandGeometryTests`: Insel, Notch und kein Ausschnitt aus den
  öffentlichen Werten, auch bei anderer Skalierung und mit echten Notch-Maßen;
  ohne Messung in der Menüleiste nur der Hals (Aussparung plus 3 pt); Zeichen
  und Zahl nach Wichtigkeit; kompakt nur auf einer Seite breiter und nichts
  unter der Menüleiste; Stufe und Seite je nach gemessenem Platz; kompakt und minimal schneiden
  bei keiner Lage von Menüs und Statussymbolen einen gemessenen Rahmen, auch
  nicht mit Hinweis oder Liste; neben Apples aktiver Insel ein abgesetzter
  Kreis und ein Hals in ihrer Breite; Hinweis und Liste als eine Form um die
  Kamera; Diktat-Fenster auf Höhe der großen Form, Controller-Insel als große Form;
  Kapsel der Schnellaktion (Seite, Abstand zu Apples Insel, schneidet nicht erzwungen keinen gemessenen Rahmen); Vollbild mit
  beiden Kanten; Form als Kapsel bzw. Hals mit Körper; Notch-Rahmen,
  Notch-Form und Vollbild an der Notch unverändert.
- `NotchIslandLargeGeometryTests`: große Form je Inhalt (zentriert auf die
  Kamera, Oberkante bei 6 pt, abgenommene Maße), Liste begrenzt und im
  Bildschirm, schmaler Bildschirm, andere Auflösung; Kopfzeile lässt Apples
  Insel Platz (Ruhe, Musik, Mikrofon-Hinweis); Ausgangsform je Lage (Kapsel,
  abgesetzter Kreis, Apples Insel) und dass sie in der offenen Form liegt;
  Umriss gleitet zwischen Kapsel und Form; Fenster fasst Form samt Rand und
  hält die Kamera oben in der Mitte; Klicks nur auf der Form, beim Schließen
  sofort nur auf der Kapsel (Geometrie und `NotchHostingView`); zweite Zeile
  des Hinweises nennt die Art, nie den Inhalt; Hinweis hält unter dem
  Zeiger; kein Öffnen per Darüberfahren an der Insel; Notch und
  Bildschirm ohne Aussparung unverändert (Rahmen, Listen-Maße, Fenster des
  Diktats).
  `NotchIslandLargePixelTests` (gezeichnetes Bild): offen eine Fläche ohne
  Hals mit runden Ecken und leerem Rand; zu nur die Kapsel; Kopfzeile behält
  beide Seiten, auch wenn eine leer ist; aufgeklapptes Diktat ohne zweite
  Kapsel daneben.
- `NotchIslandGeometryTests` (Diktat): Kapsel neben der Insel mit Platz für
  Apples Mikrofon-Hinweis; Stufen je nach Platz; schneidet bei keiner Lage
  einen gemessenen Rahmen und liegt nie über der Kamera; ohne Messung
  höchstens die Mindestbreite; rückt nur nach außen.
  `IslandDictationCompactTests`: ohne Messung und ohne Platz trotzdem die
  schmalste Kapsel, nie die Form unter der Menüleiste; Schnellaktion als
  Kapsel in der Breite ihrer Beschriftung, Aufnahme per Controller von selbst
  in der großen Form (auch wenn das Ziel erst nach dem Fenster kommt); ein
  Diktat per Hotkey zeigt die große Form nur auf Klick, und sie geht
  zu, wenn ein Clip startet, ein Bildschirmfoto beginnt oder das Diktat endet;
  Fläche fürs Darüberfahren nur Kapsel bzw. Form; ihre Kopfzeile folgt der
  Messung; ausgefallene Messung verschiebt nichts; Log-Zeile zur Entscheidung;
  Klicks zugeklappt nur auf der Kapsel, aufgeklappt nur auf der Form
  (Geometrie und Fenster-Ansicht).
- `NotchIslandProbeTests`: Messung mit einer Attrappe der
  Accessibility-Schicht: Menüs und Statussymbole als Rahmen, was Apples Insel
  zeigt, Prozess der Insel aus der Fensterliste (Mauszeiger und eigenes Fenster
  zählen nicht), kein Ergebnis ohne Berechtigung oder ohne einen der Teile
  (mit Grund), eigene Menüs aus dem Prozess statt über die Schnittstelle,
  Schätzung aus den Titeln, Frist; die Messung erzeugt kein systemweites
  Accessibility-Element.
- `NotchConfigTests`: Standardwerte, Schalter und Kill-Switch.
- `NotchPillPlacementTests`: welche Stellen bei Notch, externem Bildschirm und
  Agent-Chats-Fenster, gemerkte Lage hin und zurück, Begrenzung auf den
  sichtbaren Bereich, nach oben in der unteren Hälfte, Dynamic Island an derselben
  Stelle, Schlüssel ist die Display-UUID, Speichern und Zurücksetzen.
- `UnifiedPillModelTests`: Priorität (Dynamic Island, Diktat, Liste, Hinweis, Ruhe;
  Status aus, Vollbild), Ort des Diktats (vorderes Fenster, Maus,
  Hauptbildschirm, Notch, gemerkte Lage), Raute, Rechts-Anker beim
  Darüberfahren, Fenster mit Schattenrand, Liste nach oben und unten,
  Begrenzung am Rand, Klickziel Kern oder Liste.
- `UnifiedPillMorphTests`: Ablauf des Übergangs (Ruhe, Übergabe, Wachsen,
  Diktat, Zurückziehen, Übergabe), Stopp vor dem ersten Bild und im
  Wachsen, Start im Zurückziehen, Bildschirmwechsel, Abbruch beim
  Kill-Switch, ohne ruhende Pille direkt.
- `UnifiedPillRestSnapshotTests`: Ruhebild je Bildschirm (Zähler, Mittelpunkt,
  gemerkte Lage, Notch nur mit Anzeige, nachgeholter Hinweis), kein Übergang
  bei offener Liste, Vollbild, Status aus, Kill-Switch.
- `UnifiedPillRestLookPixelTests`: Ruhebild der Diktat-Pille Pixel für Pixel
  wie die Status-Pille bzw. die Notch-Zeile, mit und ohne Hinweis, ohne Notch
  auch in Tiefschwarz.
- `PillSolidBlackTests`: Tiefschwarz standardmäßig aus, nur mit vereinter
  Pille, Entscheidung `PillSurface`, Live-Wert meldet nur echte Wechsel; im
  Bild schwarz bei Ruhe, Liste, Diktat, Insel und Liste der Ausgabemodi, die
  getrennte Diktat-Pille samt Liste unverändert.
- `UnifiedPillControllerTests`: Kill-Switch und Bildschirmwahl, Klick auf den
  Kern startet das Diktat (Spy), Raute nur vereint, Diktat blendet den Status
  nur auf seinem Bildschirm aus, nachgeholter Hinweis, Pfeile und Return,
  Abmelden beim Hub, vorderes Fenster aus der Fensterliste, Liste der
  Ausgabemodi nach unten.
- Snapshots vereint: `make snapshots ONLY=vereint` (Ruhe leer und mit
  Zählern, Hinweis, Fehler, Liste nach unten und oben, Diktat mit Raute,
  Diktat an der Notch, Vergleich Diktat-Pille und ruhende Pille Seite an
  Seite). `ONLY=diktatpille` zeigt die Diktat-Pille in allen Zuständen.
  `ONLY=uebergang` zeigt den Übergang: Ruhe, Mitte, Diktat ohne Notch und an
  der Notch (aus dem Band und aus der Zeile mit Zählern).
  `ONLY=vereint-schwarz` zeigt dieselben Zustände ohne Notch in Tiefschwarz,
  dazu alle Insel-Fixtures als Pille (Limits-Karte, Rauten, Reiter, Listen),
  die Liste der Ausgabemodi und den Schalter in den Einstellungen.
- Snapshots: `make snapshots ONLY=notch` (Ruhe, Ruhe mit allen Zählern,
  braucht dich, Fehler, aufgeklappt, jeweils an der Notch und als Pille; dazu
  die leere Pille und die Pille unten mit Liste nach oben; hell und dunkel).
  `make snapshots ONLY=kamera-insel` zeigt die Anzeige an der Kamera-Insel
  (kompakt je Zustand, zweistellig und rechts der Kamera, minimal bei wenig
  Platz und neben Apples Insel mit Mikrofon; Hinweis, Fehler und Liste als
  große Form, auch mit Musik in Apples Insel, mit Tastatur-Auswahl, lang und
  leer, dazu die Bewegung in drei Standbildern; Diktat kompakt je Zustand,
  rechts, minimal, ohne Messung, ohne Platz, aufgeklappt als große Form (auch
  laut, bei der Transkription und mit laufendem Clip), per Controller mit
  Ziel-Chat, und die Schnellaktion als Kapsel (läuft, Hinweis, rechts, ohne
  Messung); Übergang; die Controller-Insel als große Form je Ebene
  (`kamera-insel-controller-…`: Wohin mit Kacheln je Reiter, bewegt, weiter
  unten, mit Zählern, mit Musik, per Tastatur; Schreiben; Schnellbefehle;
  Limits; zu)); die Attrappe legt die Kamera-Kapsel wie macOS
  über alles und zeigt Menüs und Statussymbole der Leiste.
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
- An der Kamera-Insel braucht die Anzeige in Ruhe die Berechtigung für
  Bedienungshilfen (die das Einfügen nach dem Diktat ohnehin verlangt). Ohne
  sie steht in der Menüleiste nichts; Hinweis und Liste (Hotkey) erscheinen
  trotzdem.
- Die offene große Form verdeckt Menüs und Statussymbole neben der Kamera und
  nimmt dort Klicks an, solange sie offen ist (Hinweis: rund vier Sekunden).
- Apples Insel liegt über der großen Form. Ein Klick in die Mitte der
  Kopfzeile trifft deshalb Apples Insel, nicht uns; klappt Apple die eigene
  Insel auf (etwa „Now Playing“), liegt sie über unserer Form. Wie Apples
  Inhalt in unserer Kopfzeile sitzt, zeigen nur Attrappen; an der echten
  Insel ist es nicht geprüft.
- Die Reihenfolge am Fenster (erst groß, dann gleitet die Form; beim
  Schließen umgekehrt) läuft nur an der echten App und ist durch Tests nicht
  abgedeckt (Tests öffnen keine Fenster).
- Die große Form des Diktats schließt per Klick, nicht per Esc: Esc bricht
  wie immer das Diktat ab.
- Zieht sich die große Form zurück, während ein Diktat beginnt, verschwindet
  sie ohne Bewegung; das Diktat beginnt an der Kapsel.
- Endet ein Diktat bei offener großer Form, blendet sie ins Ruhebild über,
  statt sich in die Kapsel zurückzuziehen.
- Gemessen wird zu Ereignissen und alle 30 s, nicht laufend. Bekommt die
  vordere App ein Menü dazu, erscheint ein Statussymbol oder beginnt Apples
  Insel etwas zu zeigen, ohne dass App oder Space wechseln, gilt der alte
  Stand bis zu 30 s weiter. Apples Insel liegt dann über unserer Kapsel und
  verdeckt Zeichen und Zahl so lange.
- Die Messung stützt sich auf den Aufbau der Menüleiste unter macOS 27 (ein
  Prozess führt Insel und Statussymbole). Ändert Apple das, liefert sie
  nichts und die Anzeige bleibt aus der Menüleiste heraus, bis der Code
  nachzieht.
- Die Kapsel reagiert auf Klicks nur im Flügel neben der Kamera: Über der
  Kamera selbst liegt Apples Fenster.
- Neben Apples aktiver Insel zeigt die Anzeige nur das Zeichen, keine Zahl.
- Die Diktat-Kapsel steht mit Abstand neben der Insel, nicht an ihr: Solange
  das Mikrofon noch nicht läuft oder schon wieder aus ist (Transkription),
  bleibt zwischen Kapsel und Insel eine Lücke von rund 40 pt.
- Das Diktat-Fenster reicht an der Insel über die Menüleiste um die Kamera
  und 194 pt nach unten (durchsichtig); Klicks nimmt es nur auf der Kapsel
  bzw. der offenen großen Form an.
- Ohne Messung oder ohne Platz steht die Diktat-Kapsel trotzdem neben der
  Insel und kann dann einen Menütitel oder ein Statussymbol verdecken.
- Die Kapsel um die Kamera ist je Seite 3 pt breiter als die Kamera-Insel.
  Auf heller Menüleiste sieht man diesen Rand.
- Die Kapsel einer Schnellaktion kann ohne Platz oder ohne Messung einen
  Menütitel verdecken (ein, zwei Sekunden).
- Bei einer Aufnahme per Controller steht die große Form offen und verdeckt
  so lange Menüs neben der Kamera, bis sie per Klick zugeklappt wird oder die
  Aufnahme endet. Ein Klick daneben schließt sie nur, wenn sie per Klick
  geöffnet wurde.
- Titeländerungen erscheinen erst mit dem nächsten Statuswechsel (oder sofort
  bei offener Liste); die Anzeige beobachtet den Workspace nicht.
- „In Screenshots und Bildschirmfreigabe ausblenden“ ist kein sicherer Schutz:
  manche Aufnahme- und Meeting-Apps können den Streifen trotzdem zeigen (siehe
  oben, Handtest offen).
- „Esc closes" wirkt nur, wenn die Liste per Klick geöffnet oder nach dem
  Darüberfahren per Klick festgehalten wurde. Beim bloßen Öffnen per
  Darüberfahren nimmt sie keinen Tastaturfokus.

## Keywords

Notch, MacBook, Dynamic Island, Kamera-Insel, kompakt, minimal, expandiert, `NotchIslandGeometry`, `NotchIslandProbe`, `NotchIslandMonitor`, `NotchCutoutKind`, Statusanzeige, Streifen, Pille, verschieben, braucht dich,
frisch fertig, `NotchStatusController`, `NotchStatusModel`, `NotchGeometry`,
`NotchAlertTracker`, `NotchPanel`, `NotchPillPlacement`, `notchPillPositions`, `notchStatusEnabled`,
`notchStatusFeatureEnabled`, `toggleNotchStatus`, `sharingType`.
