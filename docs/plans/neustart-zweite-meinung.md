# Zweite Meinung: Neustart ohne Chatverlust

**Stand:** 13.11.2026 · **Auftrag:** unabhängige Beratung, nur gelesen, nichts gebaut
**Plan dazu:** [neustart-ohne-chatverlust.md](neustart-ohne-chatverlust.md) · **Aufbewahrer:** [neustart-aufbewahrer.md](../features/agent-chats/neustart-aufbewahrer.md)

Gelesen habe ich: den Plan samt Vorversuch, die Doku des Aufbewahrers, den Code der Pakete 0, 2, 3 und 6 auf main (5607df5b), den Fork-Branch `whisperm8-handover` (bis 4c3b0fa), den App-Branch `feat/handover-app` (bis a29756a8) und die noch nicht committete Arbeit in dessen Arbeitsordner. Gebaut oder getestet habe ich nichts; alle Aussagen zum Verhalten stammen aus dem Lesen, nicht aus einem Lauf.

## Empfehlung in einem Satz

Weiterbauen wie geplant, weil die Architektur richtig ist und es keinen deutlich einfacheren Weg zum selben Ziel gibt, aber den Rest als eine Kette unter einem Verantwortlichen fahren, drei Prüfungen an der Wirklichkeit vorziehen und alles Bedien-Beiwerk hinter den Feldtest schieben.

**Option (a) mit Auflagen.** Die Auflagen stehen unten unter „Was ich ändern würde“.

## Kurzurteil

| Frage | Urteil |
|---|---|
| Trägt die Architektur? | Ja. Sie ist nicht die kleinste denkbare, aber die kleinste, die das Ziel wirklich erreicht. |
| Ist der Rest überschaubar? | Ja, etwa eine Woche Bauzeit bis zum Einschalten, danach zwei Wochen Feldtest. Aber: Der schwierigste Teil liegt noch vor euch, nicht hinter euch. |
| Regressionen im Alltag? | Die größte Gefahr ist nicht die Übergabe selbst, sondern zwei Umbauten, die auch bei ausgeschaltetem Schalter jeden Chat treffen. |
| Angriffsfläche beherrschbar? | Ja. Sie ist inzwischen strenger gesichert als die Tür, die die App schon lange hat. Das Wettrüsten sollte jetzt enden. |
| Gibt es einen einfacheren Weg? | Nein, keinen, der „mitten in der Antwort“ und „Bild samt Verlauf“ hält. Die einfacheren Wege sind im Vorversuch praktisch schon gemessen worden und fallen genau dort durch. |

## Wo das Projekt wirklich steht

Der Stand ist etwas weiter als gemeldet, und an einer Stelle weniger weit, als die Zeilenzahl vermuten lässt.

- **Paket 1 ist gebaut und reviewt**, nicht mehr „in Arbeit“. Der Fork-Branch endet mit `4c3b0fa` („fixes from review“), der Pin liegt auf `feat/handover-swiftterm` (c2b51013). Es fehlt nur der Merge nach main; dort zeigt `Package.swift:40` noch auf den Stand von Paket 0.
- **Paket 4 ist zu etwa einem Fünftel da.** Das Fundament (Schnitt 4a) ist committet: Entscheidungstabellen, Schlüsselbund-Ablage, dritter Marker-Zustand, 1.042 Zeilen. Die Abgabe (4b) ist angefangen und liegt uncommittet in Oles Ordner. Die Übernahme (4c) gibt es noch nicht.
- **Was bisher gebaut wurde, war absichtlich der leichtere Teil.** Die Pakete 1 bis 3 ließen sich ohne die App bauen und testen. Das war klug, heißt aber auch: Bisher hat noch nie ein echter Chat in einem echten Fenster eine echte Übergabe erlebt. Nach Zeilen sind gut 60 Prozent fertig, nach Risiko eher die Hälfte.

## 1. Trägt die Architektur?

Ja. Drei Gründe, warum ich das nicht nur höflich sage.

**Die zwei teuren Bausteine sind unvermeidbar.** Der Vorversuch hat zwei Dinge gemessen, an denen jeder andere Entwurf genauso hängt:

- Ohne gesichertes Bild fehlen nach der Übernahme der Verlauf (292 von 352 Zeilen) und die Schalter für Tastatur und Maus (Plan Zeile 464). Man braucht also ein Terminal ohne Fenster, das mitliest, und einen Serialisierer. Beides ist gebaut.
- Reißt der Router mitten in einer Antwort ab, ist der Turn verloren, und „mach weiter“ fängt von vorn an (Plan Zeile 425). Auf diesem Mac laufen alle Claude-Chats über den Router (Plan Zeile 139). Der Router muss also den Neustart überleben. Auch das ist gebaut.

**Die Rückfälle sind sauber gedacht.** Jeder Fehler endet im heutigen Verhalten plus Fortsetzen, und die Regel „nie zwei Prozesse auf einer Sitzung“ ist als reine, getestete Entscheidungstabelle festgehalten (`HandoverPlanning.swift` auf dem Branch, Funktion `chatAction`). Das ist die richtige Stelle für so eine Regel.

**Die Trennung per Schalter ist echt.** Ist `restartKeepsChatsEnabled` aus, läuft der Router wie bisher in der App mit dem alten Netzwerk-Code (`ClaudeGPTRouterHost.swift:10-19`, `ClaudeGPTMixRouter.swift:305`). Der neue Dienst wird gar nicht gestartet.

Was die Architektur kostet, sollte aber offen auf dem Tisch liegen:

- **Dauerhafte Pflege.** Am Ende stehen rund 10.000 Zeilen App-Code für dieses Feature, dazu ein SwiftTerm-Fork, der um 1.200 Zeilen von Upstream abweicht. Jedes künftige SwiftTerm-Update wird dadurch aufwendiger.
- **Eine neue Dauerregel.** Alles, was die App je Chat nur im Speicher hält, geht bei einer Übergabe verloren, wenn es nicht im Manifest steht. Heute sind das Token, Hook-Cursor, Entwurf, vorgemerkter Kontowechsel und „arbeitet seit“. Jedes neue Feature, das so einen Zustand einführt, muss künftig daran denken. Das gehört nach dem Einschalten als Invariante in die `CLAUDE.md`, sonst entsteht in drei Monaten ein Fehler, den niemand mit dem Neustart verbindet.
- **Zwei Router-Varianten** bis zum Ende des Feldtests. Das ist gewollt (Entscheidung 6) und richtig, aber die Zeit dazwischen sollte kurz bleiben.

## 2. Ist der Rest überschaubar?

Ja. Hier ist, was fehlt, mit meiner Einschätzung.

| Rest | Inhalt | Größe | Risiko |
|---|---|---|---|
| Paket 1 mergen | Fork-Pin nach main | klein | mittel, trifft jeden Chat (siehe Abschnitt 3) |
| 4b Abgabe | Controller gibt ab, Koordinator, Befehl `app handover`, Beenden-Weg, Makefile, Test-Instanz | mittel | mittel |
| 4c Übernahme | Controller ohne Ansicht, Ende-Meldung aus der Ansicht lösen, Token, Hooks ab Cursor, Status, Warteschlange, Entwurf, Kontowechsel, Start-Reihenfolge | groß | **hoch** |
| 4d Bedienung | nur der Labs-Schalter (Rest später, siehe unten) | klein | gering |
| 4e Messpunkte | CLI-Ergänzungen für den Dauerlauf | klein bis mittel | gering |
| 4f Abnahme | Dauerlauf grün, Schlüsselbund-Prüfung, fünfmal `make dev` | mittel | hier zeigt sich, was Tests nicht sehen |
| Gus | Leerlauf-Frist des Router-Dienstes | klein | gering |

**Aufwand, ehrlich geschätzt** (Schätzung aus dem Lesen, nicht gemessen):

- bis „Dauerlauf in der Test-Instanz grün“: 3 bis 5 Arbeitstage. Darin stecken zwei Review-Runden, denn bisher hat jede Review etwas Ernstes gefunden, und das wird bei 4c nicht anders sein.
- bis „fünfmal `make dev` bestanden“: 1 bis 2 Tage dazu. Die ersten echten Läufe decken erfahrungsgemäß auf, was kein Test sieht.
- Feldtest: zwei Wochen Kalenderzeit mit wenig Arbeit. Ich rechne mit drei bis sechs Nachbesserungen.
- An Code kommen noch etwa 2.500 bis 4.000 Zeilen samt Tests dazu.

Zusammen also rund **eine Woche Bauen und zwei Wochen Beobachten**. Das ist überschaubar. Unüberschaubar würde es nur, wenn 4c auf mehrere Chats verteilt wird oder wenn während des Baus weitere Wünsche dazukommen.

## 3. Wo drohen Regressionen im Alltag?

Ich trenne nach „trifft jeden, auch mit Schalter aus“ und „trifft nur mit Schalter an“. Die erste Gruppe ist die wichtigere, weil sie ohne Vorwarnung kommt.

### Auch bei ausgeschaltetem Schalter

1. **Der Fork ändert die Leseschleife jedes Terminals.** Paket 1 baut um, wie SwiftTerm vom Chat liest (`issueRead`, `readFinished`, Prüfung auf den aktuellen Kanal in `LocalProcess.swift` des Forks), und das Kind schließt vor dem Start alle geerbten Leitungen (`Pty.swift`). Das läuft bei jedem Tastendruck und jeder Ausgabe, mit oder ohne Schalter. Die Terminal-Schicht war in diesem Projekt schon mehrfach die Quelle schwer findbarer Fehler (eingefrorenes Bild, Scroll-Ausfall). Ein Fehler hier sähe aus wie „Chat hängt“ oder „Ausgabe fehlt“.
2. **Die Ende-Meldung eines Chats sitzt heute in der Ansicht.** Wenn ein Chat endet, läuft das über Closures der Ansicht: `AgentSessionDetailView.swift:563-567` übergibt sie, `:741` (`markTerminated`) setzt den Status, stößt den Rückweg für gescheitertes Andocken an und gibt den Start wieder frei. Ein übernommener Chat hat anfangs keine Ansicht. Der Plan löst das, indem die Meldung in Registry und Koordinator umzieht. Das ist richtig, aber es ist ein Umbau am Alltagsweg aller Chats: Start, Ende, Andocken, ID-Bindung. Geht dabei etwas schief, bleibt ein Tab auf „läuft“ stehen oder ein beendeter Chat startet nicht neu.
3. **Die Sperre gegen Doppelstarts** aus Paket 0 gilt schon heute für jedes Fortsetzen (`ClaudeSessionRunningGuard.swift:21-31`). Sie verschont Prozesse, denen die App gerade das Ende geschickt hat, 30 Sekunden lang. Braucht ein Chat beim Kontowechsel oder beim Neustart eines Tabs länger zum Sterben, lehnt die App das Fortsetzen ab (`AgentCommandBuilder.swift:820-824`). Das ist richtig so und dürfte selten sein, aber es ist neues Verhalten im Alltag und seit dem Merge für jeden aktiv.
4. **Die Start-Reihenfolge.** Die Übernahme muss vor Absturz-Wiederaufnahme, vor dem Schließen verwaister Sitzungen und vor dem Aufräumen alter Event-Dateien laufen. Dafür wird `applicationDidFinishLaunching` umsortiert. Mit Schalter aus soll das nichts ändern, aber Umsortieren am Start ist die klassische Stelle für einen Fehler, der nur nach einem Absturz auftritt.

### Nur bei eingeschaltetem Schalter

| Bereich | Was schiefgehen kann | Woran man es merkt |
|---|---|---|
| Beenden | Die Abgabe blockiert den Hauptthread: je Chat bis zu 2 s Warten auf den letzten Lesevorgang (`detachForHandover`), dazu bis zu zweimal 2 s Schlüsselbund. Bei vielen Chats kann die eigene Frist von 8 s reißen. | `make dev` fällt auf den alten Weg zurück, Chats werden fortgesetzt statt übergeben |
| Fortsetzen | Scheitert eine Übernahme, wird ein noch lebender Chat erst beendet und dann fortgesetzt. Das ist richtig (nie zwei Prozesse), kostet aber den laufenden Turn. | genau das „Chaos“, das du nicht willst, nur seltener |
| Kontowechsel | Der vorgemerkte Wechsel reist im Manifest. Ein übernommener Chat ist kein Kind der App mehr; Stoppen und Neustarten laufen dann über Signale an einen fremden Prozess. | Wechsel greift nicht oder der alte Prozess bleibt kurz stehen |
| Absturz-Wiederaufnahme | Stürzt die neue App mitten in der Übernahme ab, hängt der Rest im Aufbewahrer. Wird das Geheimnis schon nach dem Lesen gelöscht statt erst nach dem Ende der Übernahme, kann der nächste Start die übrigen Chats nicht mehr holen und beendet sie. | nach einem Absturz kommen nur manche Chats nahtlos zurück |
| Hooks | Ereignisse aus der Lücke werden ab dem Cursor nachgelesen, aber ohne Ansage. Dafür braucht es einen stillen Modus im Statusweg. Fehlt er oder greift er zu breit, gibt es doppelte Fertig-Meldungen oder ein Chat bleibt grün. | Ansage kommt doppelt oder der Punkt bleibt auf „arbeitet“ |
| Warteschlange | Nach der Übernahme wird jeder ruhende Chat einmal auf ausstehende Aufträge geprüft. Ist der Status dann noch nicht eingeschwungen, geht ein Auftrag in einen arbeitenden Chat oder in einen halb getippten Text. | Auftrag landet mitten in einer Antwort |
| GPT-Chats | Der Dienst wird über einen Steuer-Socket bedient; Stop-Knopf und Beenden warten bis zu 2 s darauf (im Plan als „später“ notiert). | Stop-Knopf fühlt sich träge an |
| Codex | Codex hat keine Hooks, der Status kommt aus dem Verlauf. Nach der Übernahme muss diese Beobachtung neu angehängt werden, ohne den Zustand „startet gerade“ zu setzen. | Codex-Chat zeigt nach dem Neustart falschen Status |

## 4. Ist die neue Angriffsfläche dauerhaft beherrschbar?

Ja, und ich würde hier ausdrücklich bremsen statt weiter nachzurüsten.

**Die Beobachtung „jede Review fand eine ernste Lücke“ hat zwei Seiten.** Sie zeigt, dass die Reviews funktionieren. Sie zeigt aber auch, dass nie aufgeschrieben wurde, wovor genau geschützt wird. Jede Review hat die Latte deshalb ein Stück höher gelegt.

**Wo die Latte jetzt liegt:** Der Aufbewahrer verlangt ein Einmal-Geheimnis aus dem Schlüsselbund, prüft bei jeder einzelnen Nachricht die Code-Signatur des Absenders und bindet die Verbindung an den ersten Absender. Der Gegner in diesem Modell ist ein fremdes Programm, das unter deinem Benutzer läuft.

**Wo die Latte beim Rest der App liegt:** Der Steuer-Socket, über den `whisperm8 chats send` läuft, prüft nur, ob der Aufrufer derselbe Benutzer ist (`AgentControlServer.swift:359`). Aufrufe ohne Sitzungs-Kennung sind ausdrücklich erlaubt und gelten als „extern“ (`AgentControlRequestHandler.swift:36-45`). Nach meinem Lesen kann also jedes Programm unter deinem Benutzer schon heute Text in jeden Chat schicken. Das ist kein Vorwurf, sondern Absicht: So funktionieren Skripte und Jarvis.

**Was daraus folgt:**

- Die neue Tür ist inzwischen deutlich stärker gesichert als die alte. Ein Angreifer, der so weit ist, nimmt die alte. Weitere Härtung am Aufbewahrer bringt deshalb keinen echten Schutz mehr, wohl aber Komplexität.
- Die Fläche ist klein und zeitlich begrenzt. Der Aufbewahrer lebt Sekunden, höchstens zehn Minuten. Dauerhaft offen ist nur der Steuer-Socket des Router-Dienstes, und der gibt seinen lauschenden Socket nur an dasselbe signierte Programm.
- **Der Preis der Härtung ist Zuverlässigkeit.** Das Geheimnis läuft über den Schlüsselbund, und der liegt damit auf dem Pflichtweg jeder Übernahme. Liefert er nicht (anders signierter Build, Dialog, Frist), gilt der Rückfall auf Fortsetzen. Der Code ist dafür sorgfältig gebaut (kein Dialog, 2 s Frist, `HandoverSecretStore.swift` auf dem Branch), aber er ist die Stelle, an der Sicherheit gegen dein eigentliches Ziel arbeitet.

**Empfehlung:** Fünf Zeilen „Wovor schützen wir, wovor nicht“ in die Doku des Aufbewahrers schreiben und Reviews künftig dagegen urteilen lassen. Mein Vorschlag für den Inhalt: Ein fremdes Programm unter demselben Benutzer bekommt keine Terminals und keinen Router-Socket. Stören oder Beenden durch denselben Benutzer ist kein Schutzziel. Was über den vorhandenen Steuer-Socket ohnehin geht, ist kein Schutzziel dieses Features.

## 5. Gibt es einen deutlich einfacheren Weg?

Ich habe vier geprüft. Keiner hält das Ziel, zwei davon wären sogar teurer.

### Dauer-Halter je Terminal (dtach-Art)

Idee: Jeder Chat läuft von Anfang an unter einem kleinen Halter-Prozess, die App hängt sich nur an. Neustart heißt dann abhängen und wieder anhängen, ganz ohne Übergabe-Moment. Als Bonus wäre auch ein Absturz der App abgedeckt.

Warum nicht jetzt:

- **Er spart nur die kleinere Hälfte.** Weg fiele das Abgabe-Protokoll (`DEPOSIT`, `COMMIT`) und `detachForHandover`. Bleiben müssten das Terminal ohne Fenster, der Serialisierer, die Übernahme in der App mit allem aus Paket 4c und der Router-Dienst. Denn ein reiner Durchreicher ohne Bild ist genau der Fall „D“ aus dem Vorversuch: Verlauf weg, Schalter weg (Plan Zeile 464).
- **Er macht den Sonderfall zum Alltag.** Heute berührt die Übergabe einen Chat nur in den Sekunden des Neustarts. Ein Dauer-Halter sitzt bei jedem Tastendruck dazwischen. Jeder Fehler darin trifft jeden Chat immer.
- **Er lebt länger als die App-Version.** Ein Halter, der Tage läuft, muss mit jeder künftigen App sprechen können. Der Aufbewahrer lebt Sekunden und darf sich mit jeder Version ändern.
- **Seine Tür steht immer offen**, die des Aufbewahrers nur beim Neustart.

Der Plan nennt den Dauer-Halter selbst als spätere Stufe (Zeile 195) und hält die Bausteine dafür wiederverwendbar. Das ist die richtige Reihenfolge: erst der Aufbewahrer, und nur wenn Abstürze der App wirklich wehtun, der Dauer-Halter.

### Fertiges Werkzeug wie tmux

Das wäre tatsächlich einfacher zu bauen: tmux hält Terminals, merkt sich das Bild und beantwortet Rückfragen. Aber tmux ist selbst ein Terminal zwischen Chat und App. Der Verlauf läge dann in tmux statt in SwiftTerm, also wären das native Scrollen und Markieren weg, an denen in diesem Projekt viel Arbeit hängt. Dazu käme Ärger mit dem erweiterten Tastaturprotokoll, das Claude und Codex beim Start aushandeln (Shift+Enter). Man würde den Alltag aller Chats dauerhaft verschlechtern, um den Neustart zu verbessern. Kein guter Tausch.

### Claudes eigener Hintergrund-Dienst

Du hast das am 12.11. als Hauptweg ausgeschlossen. Ich komme zum selben Ergebnis, aus drei Gründen:

- Er deckt nur Claude ab. Codex-Chats und Terminal-Tabs bräuchten trotzdem einen eigenen Weg.
- Er löst das Router-Problem nicht. Auch ein Hintergrund-Chat spricht über den Router in der App und verliert seine laufende Antwort, wenn sie neu startet. Paket 3 wäre trotzdem nötig.
- Er macht den Kern der App von einer Claude-Funktion abhängig, die sich oft ändert. Dass das schon heute wacklig ist, sieht man am Code: Für angedockte Chats gibt es eine eigene Rettungslogik für schnell gescheitertes Andocken und für Abzweige mit neuer ID (`AgentSessionDetailView.swift:741-763` und die Funktion danach).

### Umfang verkleinern: Router-Dienst weglassen

Das klingt verlockend, spart aber nichts mehr und kostet das Ziel:

- Der Dienst ist gebaut, reviewt und in main. Weglassen hieße Code löschen, nicht Arbeit sparen.
- Er betrifft nicht nur GPT-Chats. Bei eingeschaltetem GPT-Backend laufen alle Claude-Chats über den Router. Ohne den Dienst reißt bei jedem Neustart jede gerade laufende Antwort ab, und das ist der Fall, den du ausdrücklich nicht willst.

**Wo sich wirklich etwas streichen lässt**, ist am Rand, und dort würde ich es tun:

- Paket 5 (Menüpunkt „Neu starten, Chats laufen weiter“, Hinweis nach `brew upgrade`) erst nach dem Feldtest. Für den Feldtest reichen der Labs-Schalter und `make dev`.
- Aus 4d die Sperrmeldung mit „Zum Chat wechseln“ ebenfalls später.

Das sind zusammen vielleicht ein bis zwei Tage. Mehr ist nicht zu holen, ohne das Ziel anzutasten.

## 6. Was ich ändern würde (die Auflagen zu Option a)

**1. Eine Kette, ein Verantwortlicher.** Paket 4 ist Zusammensetz-Arbeit quer durch die App. Das ist nichts für drei parallele Chats; das Risiko gegenseitig zerstörter Änderungen kennt ihr. Vorschlag:

- **Ole** baut 4b, 4c und 4e allein und nacheinander.
- **Dex** ist die Abnahme: Dauerlauf fahren, das Skript um die Lücke unten erweitern, Befunde an Ole.
- **Gus** stellt die Leerlauf-Frist fertig und ist dann fertig. Sein Chat kann danach zu.

**2. Paket 1 allein und zuerst nach main.** Der Fork ändert die Leseschleife jedes Terminals. Wenn er zusammen mit Paket 4 kommt und danach ein Chat hängt, weiß niemand, woran es lag. Also: Pin mergen, einmal `make dev`, ein bis zwei Tage normal arbeiten, dann weiter.

**3. Die Ende-Meldung als eigenen Schritt aus der Ansicht lösen.** Erst ein Umbau, der nachweislich nichts am Verhalten ändert (mit Tests für Start, Ende, gescheitertes Andocken), eigener Merge, kurz im Alltag laufen lassen. Erst danach die Übernahme darauf bauen.

**4. Drei Prüfungen an der Wirklichkeit vorziehen.** Alle drei testet derzeit nichts, bevor es an deine echte App geht:

- **Ersetztes Programm.** Bei `make dev` läuft der Aufbewahrer aus dem alten Programm weiter, während `rsync` die Datei darunter ersetzt. Der Dauerlauf startet die Test-Instanz aber nur neu, ohne das Programm zu tauschen (`handover-soak.sh:365-371`, `test-instance.sh:132`). Damit bleibt ungeprüft, ob die Signatur-Prüfung eines Prozesses noch gelingt, dessen Datei inzwischen ausgetauscht wurde (`HandoverConnection.swift:375`), und ob der Router-Dienst seine Übergabe an eine neue Generation in echt schafft. Ob das ein Problem ist, weiß ich nicht; genau deshalb gehört es in den Dauerlauf. Nötig ist ein Durchgang, der zwischen den Runden wirklich neu baut und das Bundle ersetzt.
- **Schlüsselbund zwischen zwei Dev-Builds.** Steht im Plan unter 4f. Ich würde es an den Anfang ziehen, sobald 4b steht. Scheitert es, ist das eine Grundsatzfrage und kein Feinschliff.
- **Bild im echten Fenster.** Der Vorversuch hat nur den Puffer verglichen, nicht die Darstellung (Plan, „Nicht gemessen“ unter Frage 2).

**5. Der erste echte `make dev` nur mit Chats, die du verlieren darfst.** Erst danach der Pflichttest mit allem.

**6. Bedrohungsmodell aufschreiben** (Abschnitt 4), damit die nächste Review nicht wieder die Latte verschiebt.

**7. Nach dem Einschalten eine Invariante in die `CLAUDE.md`:** Neuer Zustand je Chat, der nur im Speicher liegt, braucht einen Platz im Manifest.

### Warum nicht (b) oder (c)

- **(b) Umbauen oder verkleinern:** Die Teile, die man streichen könnte, sind fertig. Ein Umbau auf einen Dauer-Halter würde die Hälfte wegwerfen und den Alltag riskanter machen. Was sich lohnt, ist der kleine Schnitt am Rand, und der steckt in den Auflagen.
- **(c) Ich übernehme die Führung:** Ole hat den Zusammenhang für Paket 4 im Kopf, ich nicht. Eine zusätzliche Ebene zwischen Jarvis und den drei Chats macht es langsamer, nicht sicherer. Sinnvoll wäre etwas Kleineres: Ich lese 4b und 4c unabhängig gegen, bevor sie nach main gehen, mit Blick auf genau die Stellen aus Abschnitt 3.

## Die drei größten Risiken

1. **Der Umbau der Start- und Ende-Meldung trifft den Alltag aller Chats**, auch bei ausgeschaltetem Schalter. Ein Fehler dort ist kein Fehler des neuen Features, sondern einer, der sofort jeden betrifft. Dagegen helfen die Auflagen 2 und 3.
2. **Der erste Kontakt mit der Wirklichkeit.** Ersetztes Programm, Schlüsselbund und echtes Fenster sind bisher ungeprüft. Wenn dort etwas klemmt, sieht es für dich aus wie „es geht doch nicht“, weil jeder Fehler auf Fortsetzen zurückfällt, also auf genau das, was du abgelehnt hast. Dagegen hilft Auflage 4.
3. **Die Rückfall-Wege sind die am wenigsten geübten und die gefährlichsten.** Sie laufen selten, beenden lebende Chats und sind die einzige Stelle, an der zwei Prozesse auf einer Sitzung entstehen könnten. Die Entscheidung dazu ist sauber getestet, die Ausführung noch nicht gebaut. Der Dauerlauf sollte deshalb absichtlich Fehler auslösen (Aufbewahrer mitten in der Übernahme beenden, Geheimnis entfernen) und nicht nur den guten Fall fünfmal wiederholen.

## Was ich nicht geprüft habe

- Ich habe nichts gebaut und keinen Test laufen lassen; die Test-Instanz war belegt, der Mac ausgelastet.
- Den Code von Aufbewahrer und Router-Dienst habe ich im Aufbau und an den Sicherheitsstellen gelesen, nicht Zeile für Zeile.
- Ob die Signatur-Prüfung an einem Prozess mit ersetzter Datei scheitert, ist eine offene Frage, kein Befund.
- Die Aufwandszahlen sind Schätzungen aus dem bisherigen Tempo und dem Umfang von 4c.
