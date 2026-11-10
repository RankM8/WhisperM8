# Wettbewerb: Orca und T3 Code gegen WhisperM8

**Stand:** 10.11.2026 · **Status:** Analyse und Empfehlung, kein App-Code geändert
**Anlass:** Vergleich mit den beiden Open-Source-Projekten, die WhisperM8 am nächsten kommen, und die Frage, was wir nachziehen sollten.

## Seiten

| Seite | Inhalt |
|---|---|
| [kernfeatures.md](kernfeatures.md) | 13 Features, die wir nachziehen oder besser machen sollten, mit Nutzen, Aufwand und Reihenfolge; dazu, was wir nicht bauen |
| [vergleich.md](vergleich.md) | Funktion für Funktion: Orca, T3 Code, WhisperM8; was nur wir haben; was uns fehlt |
| [architektur.md](architektur.md) | Swift nativ gegen Electron mit Dienst oder Server; was wir am Fundament ändern sollten |
| [orca.md](orca.md) | Orca: Bauweise und Funktionsumfang |
| [orca-video.md](orca-video.md) | Orcas Oberfläche Bild für Bild aus dem Vorstellungsvideo, je mit unserem Stand daneben |
| [t3code.md](t3code.md) | T3 Code: Bauweise und Funktionsumfang |
| [browser.md](browser.md) | Wunsch: Browser in der App, Playwright zuerst, Anmerkungen an den Chat |
| [jira.md](jira.md) | Wunsch: Jira-Tickets spiegeln, Chats daraus starten |

## Die drei Produkte in je einem Satz

- **Orca** (121.000 Sterne, 4,3 Mio. Zeilen): hostet wie wir die echte CLI im Terminal, legt aber jede Aufgabe in eine eigene Arbeitskopie, hält die Terminals in einem eigenen Dienst und baut eine ganze Arbeitsumgebung darum.
- **T3 Code** (55.000 Sterne, 1,6 Mio. Zeilen): ein Server je Rechner, der die Agents über deren Programmierschnittstelle ausführt, mit selbst gebauter Chat-Oberfläche für Desktop, Web und Handy.
- **WhisperM8** (130.000 Zeilen): native Mac-App, hostet die echte CLI im Terminal, dazu Diktat, GPT-Backend, Konten, Jarvis.

## Urteil

**Wo wir stehen.** Beim Kern „mehrere Agents parallel, sauber getrennt, mit Prüfung des Ergebnisses“ sind beide weiter als wir. Als persönliches Cockpit auf dem Mac sind wir tiefer als beide. Das GPT-Backend hat keiner von ihnen.

**Zur Bauweise.** Swift ist nicht der Fehler, und ein Neubau wäre falsch. Den beiden gibt Electron drei Dinge fast umsonst: mehrere Plattformen, einen eingebauten Browser und fertige Bausteine für Terminal, Editor und Diff. Uns gibt die native App, was sie nicht können: systemweites Diktat, Notch, Zwischenablage, Wachhalten. Eine Entscheidung der beiden fehlt uns aber, und sie hat mit der Sprache nichts zu tun: Bei ihnen laufen die Agents nicht im Prozess der Oberfläche. Daraus folgt bei Orca, dass Chats einen Neustart der App überleben. Das sollten wir nachziehen.

**Zur These „echtes Terminal statt eigener Chat-Oberfläche“.** Sie hält. Orca sieht es im Kern genauso und bietet den Chat nur zusätzlich an; T3 Code geht den anderen Weg und zeigt deshalb Claudes Statuszeile, Mods und Dialoge nicht. Das genaue Argument ist allerdings nicht „bei uns läuft der echte Agent“, das tut er bei den anderen auch. Es lautet: Bei uns ist jede neue Funktion von Claude Code am ersten Tag da, ohne Nachbau. Eine eigene Chat-Oberfläche lohnt sich für uns frühestens mit einer Handy-App.

**Zur These „wir haben den besseren Anwendungsfall“.** Für jemanden, der auf dem Mac mit Claude Code im Mittelpunkt arbeitet, mehrere Konten und Modelle mischt und viel diktiert: ja. Für jemanden, der zehn Agents parallel an einem Repository arbeiten lässt und deren Ergebnisse prüfen will: heute nein, dort fehlen uns Arbeitskopien, Änderungsliste und Browser.

## Was nur wir haben

Nach Gegenprüfung in beiden Quelltexten ([vergleich.md](vergleich.md)):

1. GPT in Claude Code über das eigene ChatGPT-Abo, eingebaut, mit mehreren Konten
2. Systemweites Diktat mit Kontext, Ausgabemodi und Einfügen in jede App
3. Kontowechsel für laufende Chats nach dem Turn, mit Verlauf, MCP und Memory
4. Mac-Cockpit: Notch, Sprachansagen, Zwischenablage-Verlauf, Wachhalten bei zugeklapptem Gerät
5. Jarvis-Board direkt im Prompt
6. Statistik zur eigenen Arbeit mit Gegenwert des Abos
7. Zurückhaltung: Beide Konkurrenten starten Agents ab Werk ohne Freigabe-Nachfragen, Orca schreibt zudem Hooks in die Claude-Einstellungen des Nutzers

Keine Alleinstellungsmerkmale, obwohl wir es angenommen hatten: mehrere Konten, Verbrauchsanzeige, Supervisor über mehrere Chats, Diktat in der App, Ressourcenansicht.

## Was uns am meisten fehlt

| Lücke | Wer hat es |
|---|---|
| Chats überleben Neustart, Update und Absturz der App | Orca |
| Eigene Arbeitskopie je Chat, mit Liste der Änderungen | beide |
| Browser in der App, vom Agent steuerbar, mit Anmerkungen an den Chat | beide |
| Chat auf einem anderen Rechner | beide |
| Aufgaben aus Jira | Orca |
| Übergabe eines Chats an einen anderen Agent | beide |

Die vollständige Liste mit Aufwand und Reihenfolge steht in [kernfeatures.md](kernfeatures.md).

## Die drei Wünsche aus dem Gespräch

| Wunsch | Einschätzung | Seite |
|---|---|---|
| **Chats auf anderen Rechnern starten** | Als SSH-Chat mittelgroß und ohne Umbau machbar: unser Terminal verbindet sich, auf dem Zielrechner läuft die echte CLI. Was beide Konkurrenten bauen (eigener Server auf dem Zielrechner) ist sehr groß und nicht der erste Schritt. | [kernfeatures.md](kernfeatures.md), Punkt 5 |
| **Browser mit Anmerkungen, Playwright zuerst** | Machbar und an einer Stelle besser als Orca, weil die Agents Playwright schon kennen. Empfohlen: Playwright besitzt den Browser, die App zeigt ihn. Vorher ein kleiner Vorversuch. | [browser.md](browser.md) |
| **Jira in der App** | Mittelgroß. Entschieden: Zuweisung lokal, Marke in Jira zuschaltbar, mehrere Projekte und Boards. | [jira.md](jira.md) |

Ressourcen- und Terminal-Verwaltung sowie das „Neu“-Menü mit seinen Optionen stehen als Punkte 8 und 9 in [kernfeatures.md](kernfeatures.md). Bei der Ressourcenansicht sind wir in der Sache schon gleichauf; es fehlen Verlaufslinie, Beenden aus der Ansicht und das Erkennen verwaister Prozesse.

## Ein Fund außer der Reihe

Claude Code meldet seinen Zustand seit Version 2.1.295 selbst im Terminalstrom (OSC 7501), Codex ebenfalls. WhisperM8 wertet das nicht aus. Der Kanal braucht keine Hooks und funktioniert auch über SSH. Er ist klein zu bauen und die Voraussetzung dafür, dass ein Chat auf einem anderen Rechner bei uns einen Status hat. Siehe [kernfeatures.md](kernfeatures.md), Punkt 4.

## Offene Entscheidungen

1. **Reihenfolge:** Passt der Vorschlag in [kernfeatures.md](kernfeatures.md) (klein anfangen mit Status-Kanal und Ressourcen, dann Arbeitskopie mit Start-Dialog, dann Browser, SSH, Jira), oder soll ein Wunsch vorgezogen werden?
2. **Terminal-Dienst:** Als eigenes Vorhaben mit Vorversuch starten, ja oder nein? Es ist das größte Stück und das mit dem größten Gewinn.
3. **Browser:** Reicht ein Live-Bild zum Zuschauen und gelegentlichen Eingreifen, oder soll man im Bereich richtig surfen können? Davon hängt der Weg ab.
4. **Jira:** Label oder Kommentar als Marke; Ort der Ticket-Ansicht.
5. **Arbeitskopie:** Opt-in je Chat (Empfehlung) oder Normalfall wie bei Orca?

## Methode und Grenzen

- Beide Repositories am 10.11.2026 geklont und gelesen: Doku, Aufbau, gezielt Quelltext. Nichts installiert, nichts gestartet.
- Das Orca-Video (13:42 min) mit Transkript und rund 30 Standbildern ausgewertet.
- Jedes Produkt zusätzlich von einem zweiten, unabhängigen Durchgang im Quelltext geprüft, mit dem Auftrag, unsere vermuteten Alleinstellungsmerkmale zu widerlegen. Mehrere Annahmen fielen dabei, siehe oben. Die tragenden Aussagen sind danach noch einmal stichprobenartig am Code nachgesehen.
- Nicht gemessen: Tempo, Speicherverbrauch und Stabilität der beiden im Betrieb. Aussagen dazu fehlen deshalb bewusst.
- Beide Projekte ändern sich täglich. Der Stand gilt für den genannten Tag.
