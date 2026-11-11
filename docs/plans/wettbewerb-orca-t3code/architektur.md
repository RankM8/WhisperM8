# Bauweise: Swift nativ gegen Electron mit Dienst oder Server

**Stand:** 10.11.2026 · **Gehört zu:** [README.md](README.md) · [orca.md](orca.md) · [t3code.md](t3code.md)

Die Frage hinter dieser Seite: Haben die beiden es grundsätzlich besser gebaut als wir, und müssten wir etwas an unserem Fundament ändern?

## Kurze Antwort

Nein, WhisperM8 muss nicht neu gebaut werden, und Swift ist nicht der Fehler. Aber beide Konkurrenten haben eine Entscheidung getroffen, die uns fehlt und die mit der Programmiersprache nichts zu tun hat: **Die Agents laufen bei ihnen nicht im Prozess der Oberfläche.** Bei Orca in einem eigenen Dienst, bei T3 Code in einem eigenen Server. Fast alles, was die beiden uns voraushaben (Chats überleben einen Neustart, andere Rechner, Handy), folgt aus dieser einen Trennung. Fast alles, was wir ihnen voraushaben (Diktat, Notch, Zwischenablage, Wachhalten), folgt daraus, dass wir eine echte Mac-App sind.

## Drei Bauweisen

```
WhisperM8                    Orca                          T3 Code

┌──────────────────┐        ┌──────────────────┐          ┌─────────┐ ┌─────┐ ┌───────┐
│ App              │        │ App (Electron)   │          │ Desktop │ │ Web │ │ Handy │
│  Oberfläche      │        │  Oberfläche      │          └────┬────┘ └──┬──┘ └───┬───┘
│  Terminals ──────┼─ CLI   └────────┬─────────┘               └─────────┼────────┘
│  Zustand         │                 │ Socket                            │ Netz
└──────────────────┘        ┌────────┴─────────┐          ┌──────────────┴───────────┐
                            │ Dienst           │          │ Server je Rechner        │
 App beendet                │  Terminals ── CLI│          │  Agents über SDK         │
 = Chats beendet            └──────────────────┘          │  Zustand, Git, Terminals │
                                                          └──────────────────────────┘
                             App beendet                   Oberfläche beendet
                             = Chats laufen weiter         = Arbeit läuft weiter
```

| | WhisperM8 | Orca | T3 Code |
|---|---|---|---|
| Wem gehören die Agent-Prozesse | der App | einem Dienst neben der App | einem Server |
| Was zeigt der Chat | Claudes eigene Oberfläche | Claudes eigene Oberfläche, wahlweise eigener Chat | eigener Chat |
| Wo liegt der Zustand | in Dateien der App | in App und Dienst | in der Datenbank des Servers |
| Zweite Oberfläche (Handy, Web) möglich | nein | ja | ja, darauf ausgelegt |

## Electron und TypeScript: was es ihnen bringt

- **Ein Code für alles.** Desktop auf drei Betriebssystemen, Web und große Teile der Handy-App teilen sich dieselbe Sprache und oft dieselben Bausteine. Deshalb können beide so breit sein.
- **Chromium ist geschenkt.** Der eingebaute Browser, der Design-Modus, die Vorschau von HTML und PDF kosten in Electron fast nichts, weil die App selbst schon ein Browser ist. Bei uns ist ein eingebetteter Browser eine eigene große Anschaffung, siehe [browser.md](browser.md).
- **Fertige Bausteine.** xterm.js als Terminal, Monaco als Editor, fertige Diff-Ansichten. Unser Terminal ist ein selbst gepflegter Fork von SwiftTerm mit eigenen Korrekturen.
- **Tempo.** Orca veröffentlicht mehrmals täglich. Mit einem großen Team und dieser Bauweise wächst der Umfang schneller, als eine einzelne Swift-App folgen kann.

## Was es sie kostet

- **Umfang.** 4,3 Millionen Zeilen bei Orca, 1,6 Millionen bei T3 Code. Orcas eigene Entwicklernotiz nennt 23 Fehler in sieben Review-Runden allein am Protokoll zwischen App und Dienst. Viele Funktionen sind als experimentell oder Beta markiert.
- **Mehrere Prozesse.** App, Oberfläche, Dienst, Hilfsprozesse. Wie viel Speicher das im Betrieb kostet, haben wir nicht gemessen. Eine Aussage „wir sind schneller“ oder „wir brauchen halb so viel Speicher“ wäre ohne Messung nicht gedeckt.
- **Wenig Tiefe im Betriebssystem.** Kein systemweites Diktat, kein Einfügen in andere Apps, keine Notch, kein Wachhalten bei zugeklapptem Gerät. Das sind genau die Dinge, die eine native App leicht kann.
- **Bei T3 Code zusätzlich: eine zweite Welt neben der CLI.** Jede Funktion, die Claude Code in seiner Oberfläche neu bringt, muss T3 nachbauen oder weglassen.

## Was Swift uns bringt und was es uns kostet

**Bringt:** direkten Zugriff auf alles, was den Mac ausmacht (globaler Hotkey, Bedienungshilfen, Zwischenablage, Notch, Energieverwaltung, Schlüsselbund), eine einzige App ohne mitgelieferten Browser, und einen Umfang, den ein kleines Team versteht.

**Kostet:**

- Nur macOS. Eine Handy-App wäre ein zweites Produkt, kein weiterer Bildschirm.
- Kein geschenkter Browser, kein geschenkter Editor, keine geschenkte Diff-Ansicht.
- Das Terminal pflegen wir selbst.
- Auch ohne eigene Chat-Oberfläche haben wir Arbeit mit der Kompatibilität: Statuserkennung aus Claudes Registry, Hook-Brücke, Verlaufs-Leser, Kontopfade, Modellkatalog des Proxys. „Echte CLI hosten“ heißt weniger Nachbau, nicht keiner.

## Zur These „echtes Terminal statt eigener Chat-Oberfläche“

Sie hält, mit zwei Präzisierungen.

**Erstens:** Der Unterschied ist nicht „echter Agent gegen nachgebauter Agent“. T3 Code und Orcas Chat-Modus lassen das originale Claude Code laufen. Der Unterschied ist die Oberfläche. Wir zeigen Claudes eigene, die anderen bauen eine neue. Unser Argument lautet deshalb: Bei uns ist jede neue Funktion von Claude Code am ersten Tag da, ohne dass wir etwas tun, samt Statuszeile, Mods, Bändern und Dialogen.

**Zweitens:** Eine eigene, strukturierte Darstellung hat echten Nutzen, nicht nur auf dem Handy. Freigaben als Knopf statt als Terminal-Dialog, eine verlässliche Warteschlange, lesbare Werkzeugausgaben, Diffs im Gespräch. Der Preis lässt sich bei Orca ablesen: allein die Chat-Darstellung umfasst rund 87.000 Zeilen, mit den Anbindungen je Anbieter über 100.000, also fast so viel wie unsere ganze App. Der Wechsel zwischen Chat und Terminal geht dort trotzdem nur per Kopie.

Der Mittelweg, den wir schon gehen und ausbauen können: Das Terminal bleibt die Arbeitsfläche, und drumherum entstehen strukturierte Begleiter. Verlauf als Textansicht, Statuspunkte, Jarvis-Board, Notch haben wir. Liste der Änderungen, Browser, Ticket-Ansicht wären die nächsten. Eine vollständige Chat-Oberfläche lohnt sich erst mit einer Handy-App, und auch dort kann der Anfang eine Leseansicht mit wenigen bestätigten Aktionen sein.

## Die eine Sache, die wir am Fundament ändern sollten

**Die Terminals aus der App herauslösen.** Ein kleiner eigener Prozess hält die Terminals und ihre Agents, die App hängt sich daran an.

Was das löst:

- `make dev`, ein Update oder ein Absturz beenden keine Chats mehr. Heute ist das der Grund für die Regel, dass kein Chat die App neu bauen und starten darf, und für die ganze Wiederaufnahme nach Absturz.
- Updates lassen sich jederzeit einspielen.
- Es ist dieselbe Grenze, an der später ein Chat auf einem anderen Rechner oder eine Handy-Ansicht andocken würde. Wer sie einmal sauber zieht, hat den schweren Teil für beides erledigt.

Was es kostet: ein eigenes kleines Protokoll zwischen App und Dienst (starten, anhängen, Größe ändern, Eingabe, Ausgabe nachspielen), die Frage, wem ein Terminal gehört, wenn zwei Fenster oder eine alte und eine neue App-Version gleichzeitig laufen, und die Wiederherstellung des Bildschirms beim Anhängen. Orcas Erfahrung zeigt, dass genau dort die Fehler sitzen. Der Aufwand ist groß, aber er lässt sich klein beginnen: zuerst nur „Chats überleben den Neustart der App“, ohne Netz, ohne zweite Oberfläche.

Das ist eine Erweiterung, kein Neubau. SwiftTerm, die Oberfläche, der Workspace-Speicher und die Statuserkennung bleiben.

## Was wir an Prinzipien übernehmen können, ohne umzubauen

| Prinzip | Von | Bedeutung für uns |
|---|---|---|
| Ausführung gehört dem Rechner mit dem Projekt | T3 Code | Bei SSH-Chats nie lokale Logins oder Dateien auf den Zielrechner kopieren; der Zielrechner hat seine eigenen. |
| „Angenommen“ ist nicht „ausgeführt“ | T3 Code | Start-, Sende- und Übergabe-Befehle der CLI bekommen eine Quittung, damit ein wiederholter Befehl nichts doppelt startet. |
| Fähigkeiten je Anbieter erklären | T3 Code | Was Codex nicht kann, wird bei Codex nicht angeboten, statt zu scheitern. |
| Der Agent meldet seinen Zustand selbst | Orca | OSC 7501 als zweiter Statuskanal, der auch über SSH funktioniert. |
| Messen nur bei offener Ansicht | beide | Entspricht unserer Regel, kein Polling bei inaktivem Fenster. |
| Prozessnummer plus Startzeit | T3 Code | Vor dem Beenden eines Prozesses prüfen, ob die Nummer noch demselben Prozess gehört. |
| Doppelte Grenze für Terminal-Verlauf | T3 Code | Zeilen und Bytes begrenzen, damit eine einzelne Riesenzeile die Grenze nicht umgeht. |
| Fremde Texte sind Daten | Orca | Ticket-Texte, Seiteninhalte und Kommentare nie als Anweisung an den Agent durchreichen. |

## Was wir bewusst anders lassen

- **Kein Vollzugriff ab Werk.** Beide starten neue Chats ohne Freigabe-Nachfragen. Wir übernehmen das Verhalten von Claude Code.
- **Keine Status-Hooks in den Einstellungen des Nutzers.** Orca schreibt Hooks und eine Statuszeile nach `~/.claude/settings.json`. Unsere Hook-Einstellungen liegen im eigenen Ordner, und für normale Chats sind wir auf dem Weg zu null Hooks.
- **Kein eigener Cloud-Dienst.** Relay, Push und Tunnel bedeuten laufenden Betrieb, Kosten und Verantwortung für fremde Daten.
- **Keine Telemetrie ab Werk.**

## Wo wir stehen

Beim Kern „mehrere Agents parallel, sauber getrennt, mit Prüfung des Ergebnisses“ sind beide weiter: Arbeitskopie je Aufgabe, Diff, PR, Browser. Als persönliches Cockpit auf dem Mac ist WhisperM8 tiefer als beide, und das GPT-Backend hat keiner von ihnen. Die Frage ist deshalb nicht Gleichstand bei den Funktionen. Mit einem Dreißigstel des Codes wäre das auch nicht zu erreichen. Die Frage ist, welche wenigen Lücken unseren Kern schwächen. Das sind vier: Chats überleben keinen Neustart, keine Trennung paralleler Arbeit, kein Blick auf das Ergebnis im Browser, kein Blick auf die Änderungen. Die Reihenfolge steht in [kernfeatures.md](kernfeatures.md).
