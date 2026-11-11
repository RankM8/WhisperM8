# Kernfeatures: was wir nachziehen und wo wir besser sein können

**Stand:** 10.11.2026 · **Status:** Empfehlung, noch nichts entschieden außer den markierten Punkten, kein App-Code geändert
**Gehört zu:** [README.md](README.md) · Grundlage: [vergleich.md](vergleich.md), [architektur.md](architektur.md)

Aufwand in vier Größen: **klein** (eine abgegrenzte Ergänzung), **mittel** (ein eigenes Feature), **groß** (greift in mehrere Teile der App), **sehr groß** (neue Plattform oder dauerhafter Betrieb). Das sind Größenordnungen, keine Termine.

## Übersicht

| Nr. | Feature | Nutzen | Aufwand | Herkunft |
|---|---|---|---|---|
| 1 | Arbeitskopie je Chat, mit Liste der Änderungen | hoch | mittel (voller Diff: groß) | beide |
| 2 | Terminals in eigenem Dienst: Chats überleben Neustart | hoch | groß | Orca |
| 3 | Browser, Playwright zuerst, mit Anmerkungen | hoch | mittel bis groß | beide, Wunsch |
| 4 | Status aus dem Terminalstrom (OSC 7501) | mittel, Voraussetzung für 5 | klein bis mittel | Orca |
| 5 | Chat auf anderem Rechner per SSH | mittel | mittel | beide, Wunsch |
| 6 | Jira: Tickets spiegeln, Chats daraus starten | mittel | mittel | Orca, Wunsch |
| 7 | Übergabe an anderen Agent oder anderes Modell | mittel | mittel | beide |
| 8 | „Neu“-Menü als Suche und Startfläche | mittel | klein bis mittel | Orca, Wunsch |
| 9 | Ressourcenansicht ausbauen | mittel | klein bis mittel | Orca, Wunsch |
| 10 | Fertige Chats schlafen legen | niedrig bis mittel | klein bis mittel | Orca |
| 11 | Auftragsvertrag für Jarvis | mittel | mittel | Orca |
| 12 | PR-Beobachtung, die den Chat weckt | mittel | mittel | T3 Code |
| 13 | Angespartes Reset-Guthaben einlösen | niedrig bis mittel | klein | beide |

## 1. Arbeitskopie je Chat, mit Liste der Änderungen

**Was:** Beim Start eines Chats wählbar, ob er im Projektordner arbeitet oder in einer eigenen Arbeitskopie (Git-Worktree) mit eigenem Branch. Rechts neben dem Chat eine Liste der geänderten Dateien mit Zeilenzahlen.

**Warum zuerst:** Beide Konkurrenten machen das zum Normalfall, und es trifft einen Schmerz, den wir schon hatten: Im Juli haben parallele Chats sich gegenseitig laufende Änderungen zerstört. Für jemanden, der nicht selbst entwickelt, ist „jeder Chat hat seinen eigenen Ordner und Branch“ die wirksamste Absicherung.

**Was schon da ist:** `AgentWorktreeManager` legt Worktrees für Codex-Subagent-Jobs an und räumt sie ab, mit Schutz vor dem Löschen ungesicherter Änderungen. Der Branch steht schon im Kopf des Chats.

**Worauf es ankommt:**

- Eine frische Arbeitskopie ist nicht lauffähig: Es fehlen installierte Pakete, `.env`, oft eine Datenbank. Orca löst das mit einer Projektdatei (`orca.yaml`: Einrichtungs-Skript, Liste der Dateien, die mitkommen). Ohne so etwas ist das Feature für Projekte wie ListM8 wertlos. Dort gibt es mit den Dev-Slots schon den passenden Mechanismus; die Arbeitskopie sollte ihn aufrufen können.
- Opt-in, wie bei den Subagent-Jobs bereits beschlossen. Kleine Fragen brauchen keinen eigenen Branch.
- Aufräumen muss sichtbar sein: welche Arbeitskopien es gibt, wie viel Platz sie belegen, welche verwaist sind.

**Besser als die anderen:** Arbeitskopie, Konto und Modell (Claude oder GPT) in einem Start-Dialog. Das kann keiner von beiden.

**Ausbaustufe:** Diff-Ansicht je Datei und Anmerkung an einer Zeile, die an den Chat geht. Das ist groß und kommt erst, wenn die Liste sich bewährt hat.

## 2. Terminals in eigenem Dienst

**Was:** Ein kleiner eigener Prozess hält die Terminals und ihre Agents. Die App hängt sich an. Beenden, Update oder Absturz der App beenden keine Chats mehr.

**Warum:** Das ist Orcas größter Vorsprung und bei uns eine tägliche Reibung: `make dev` beendet alle Chats, Updates mitten in der Arbeit ebenso. Die Regel „kein Chat darf die App neu starten“ und die Wiederaufnahme nach Absturz sind beides Pflaster für dieses eine Problem.

**Zweiter Nutzen:** Es ist die Grenze, an der später ein entfernter Rechner oder eine Handy-Ansicht andocken würde.

**Risiko:** Orca hat an genau dieser Stelle nach eigener Notiz 23 Fehler in sieben Review-Runden gefunden. Schwierig sind: Wem gehört ein Terminal, wenn alte und neue App-Version gleichzeitig leben; den Bildschirm einer Vollbild-Oberfläche wie Claude Code beim Anhängen richtig wiederherstellen; den Dienst selbst aktualisieren, ohne die Chats zu verlieren.

**Wie klein anfangen:** Erste Stufe nur „Chat überlebt den Neustart der App“, lokal, ohne Netz. Der Dienst hält die Terminal-Verbindung und einen begrenzten Puffer der letzten Ausgabe; die App spielt ihn beim Anhängen ab und bittet Claude, neu zu zeichnen. Hinter einem Schalter, ab Werk aus, mit dem alten Weg als Rückfall.

**Einordnung:** Eigenes Vorhaben mit eigenem Plan und Vorversuch, nicht nebenbei.

## 3. Browser, Playwright zuerst, mit Anmerkungen

Eigene Seite: [browser.md](browser.md). Entschieden ist die Bedingung „Playwright-first“. Empfohlen ist, dass Playwright den Browser besitzt und die App ihn als Live-Bild zeigt, mit einer Anmerkungs-Schicht und Senden an einen wählbaren Chat. Vorher ein kleiner Vorversuch.

**Besser als die anderen:** Die Agents brauchen keine neuen Befehle zu lernen. Diktat in die Anmerkung. Senden über die sichere Strecke, die nicht in einen arbeitenden Chat hineinschreibt.

## 4. Status aus dem Terminalstrom (OSC 7501)

**Was:** Claude Code (seit 2.1.295) und Codex (seit 0.163) schreiben ihren Zustand selbst in den Terminalstrom: arbeitet, wartet auf Freigabe, fragt etwas, fertig, Fehler; bei Claude dazu eine Textzeile und die Subagents. Das Terminal antwortet einmal auf eine Abfrage, danach sendet der Agent. Orca nutzt das als Rückfall, wenn seine Hooks schweigen.

**Stand bei uns:** In der hier installierten Version 2.1.322 ist der Kanal vorhanden (im Programm nachgesehen: `PROGRAM_STATUS:7501`, Abfrage `?`). WhisperM8 wertet ihn nicht aus.

**Warum:** Er braucht keine Hooks und keine Dateien auf der Platte. Damit funktioniert er auch dort, wo unsere heutige Statusquelle (Claudes Registry auf dem lokalen Mac) nicht hinreicht: über SSH. Lokal wäre er ein zweiter, unabhängiger Kanal für Codex, das heute über Verlaufs-Beobachtung läuft.

**Grenzen:** Keine Sitzungs-ID, kein Prompt. Die Registry bleibt lokal die reichere Quelle und hat Vorrang. Die Invariante „Status für Claude-Chats kommt aus Claudes Registry“ bleibt, der neue Kanal kommt als benannte Ergänzung dazu.

**Vorher prüfen:** Laut Orcas Notiz zeigt Claude sein Zeichen im Fenstertitel nicht mehr, sobald das Terminal die Abfrage beantwortet. Klären, ob wir den Titel irgendwo auswerten.

## 5. Chat auf anderem Rechner per SSH

**Was:** Im Start-Dialog ein Feld „Ausführen auf“ mit „dieser Mac“ und gespeicherten SSH-Zielen. Der Chat läuft auf dem Zielrechner, bei uns steht das gewohnte Terminal.

**Wie die anderen es machen:** Beide installieren einen eigenen Server auf dem Zielrechner (Orca per SSH beim ersten Verbinden, T3 als Dienst mit Kopplung). Volle Gleichheit damit ist sehr groß.

**Der kleine Weg für uns:** Unser Terminal startet `ssh` zum Ziel, dort läuft die echte CLI in einer `tmux`-Sitzung, damit sie eine getrennte Verbindung übersteht und man sich wieder anhängen kann. Der Status kommt über OSC 7501 (Punkt 4). Auf dem Zielrechner wird nichts von uns installiert.

**Ehrliche Grenzen der ersten Stufe:**

- Kein Verlauf in der App, wenn das Terminal zu ist; die Verlaufsdateien liegen auf dem anderen Rechner.
- Konten und Logins sind die des Zielrechners. Wir kopieren keine Logins dorthin; das wäre auch gefährlich, weil sich derselbe Login auf zwei Rechnern gegenseitig entwertet.
- Kein GPT-Backend auf dem Zielrechner, solange dort kein Proxy läuft.
- Bilder per Drag und Zwischenablage kommen nicht an.
- Der Chat wird in der App klar als „entfernt“ gekennzeichnet, mit Rechnername.

**Zweite Stufe, falls es sich bewährt:** ein kleiner Helfer auf dem Zielrechner, der Verlauf und Sitzungsliste liefert. Dritte Stufe: der Dienst aus Punkt 2, auf dem Zielrechner gestartet.

**Nicht bauen:** eigenen Cloud-Tunnel, Relay, Cloud-VMs. Für Erreichbarkeit von unterwegs reicht Tailscale.

## 6. Jira

Eigene Seite: [jira.md](jira.md). Entschieden: Zuweisung an einen Chat standardmäßig lokal, sichtbare Marke in Jira zuschaltbar, mehrere Projekte und Boards.

## 7. Übergabe an anderen Agent oder anderes Modell

**Was:** Aus einem Chat heraus „Übergeben an…“: Ziel wählen (Claude, GPT in Claude Code, Codex), Kontext wählen (gezielt: letzter Stand und Arbeitsordner, älteres nur bei Bedarf nachlesen; oder der ganze Verlauf), neue Sitzung startet daneben, die alte bleibt unverändert.

**Was schon da ist:** Wir können Chats starten, ihnen einen ersten Auftrag mitgeben und den Verlauf einer Sitzung lesen (`chats show --recap`). Es fehlen der Dialog und die fertige Übergabe-Anweisung.

**Besser als die anderen:** Bei uns kann das Ziel „dasselbe Claude Code, anderes Modell“ sein, weil GPT im selben Terminal läuft. Der Dialog sollte zeigen, welches Limit das Ziel belastet, und bei erreichtem Limit von selbst die Übergabe anbieten. Das verbindet sich mit dem Kontowechsel, den wir schon haben: erst anderes Konto anbieten, dann anderes Modell.

## 8. „Neu“-Menü als Suche und Startfläche

**Was:** Das Plus an der Tab-Leiste öffnet ein Menü mit Suchfeld. Oben, was man in einen Tab legen kann (Chat je Anbieter und Konto, Terminal, später Browser und Ticket), darunter Treffer aus offenen Tabs, Verlauf und Archiv. Was nicht eingerichtet ist, steht grau mit Hinweis da, statt zu fehlen.

**Dazu gehört** der Start-Dialog für einen neuen Chat, der die Auswahlen an einer Stelle sammelt: Projekt, Ausführen auf, Arbeitskopie (aus Branch, Ticket oder Name), Konto, Modell, erster Auftrag. Heute sind diese Entscheidungen über Sidebar-Knopf, Plus-Menü, Konto-Menü und Hintergrund-Dialog verteilt.

**Regel:** Kein Hover-only. Alles im Menü ist per Tastatur erreichbar.

## 9. Ressourcenansicht ausbauen

**Was schon da ist:** Knopf mit Anzahl, CPU und Speicher, Popover mit Projekt → Chat → Prozess, Messwert wie in der Aktivitätsanzeige, Messung nur bei aktivem Fenster. In der Sache sind wir hier gleichauf mit Orca und klarer als T3 Code.

**Was fehlt:**

- Verlaufslinie je Zeile, damit man sieht, ob etwas gerade ansteigt
- eine Zeile für die App selbst
- Chat oder Prozess aus der Ansicht beenden, mit Nachfrage und der Prüfung „gehört die Prozessnummer noch demselben Prozess“ (Nummer plus Startzeit)
- verwaiste Prozesse erkennen: Entwicklungsserver und Builds, deren Chat schon zu ist
- Plattenbelegung der Arbeitskopien, sobald es sie gibt (Punkt 1)

## 10. Fertige Chats schlafen legen

**Was:** Ein Chat, der fertig, nicht sichtbar und seit einer einstellbaren Zeit unberührt ist, wird beendet. Der Tab bleibt. Beim Öffnen wird die Sitzung mit denselben Einstellungen fortgesetzt.

**Warum:** Jeder offene Chat hält Speicher, auch wenn er seit Stunden fertig ist. Wie viel, zeigt unsere Ressourcenansicht je Chat; vor dem Bau einmal an einem normalen Arbeitstag ablesen, ob es sich lohnt.

**Was schon da ist:** Fortsetzen beim Öffnen können wir.

**Ausnahmen:** Chats mit laufenden Subagents, Board-Chats, die auf den Nutzer warten, Chats mit vorgemerktem Kontowechsel. Ab Werk aus, wie bei Orca.

## 11. Auftragsvertrag für Jarvis

**Was:** Wenn Jarvis einen Chat mit einem Auftrag startet, gilt ein fester Vertrag: genau eine Fertig-Meldung mit Bezug auf den Auftrag, Rückfragen als eigene Nachricht an Jarvis statt als Frage im Terminal des Arbeiters, die App weckt Jarvis, Nachfragen in Schleife sind nicht nötig. Je Arbeiter wählbar: Arbeitskopie, Konto, Modell.

**Stand:** Beim Beobachten sind wir weiter als Orca (Momentaufnahme, Änderungen seit, Zustandsachsen, sicheres Senden, Board mit Weckruf). Beim festen Vertrag für abgegebene Arbeit ist Orca weiter.

**Nicht übernehmen:** Orcas Aufgaben-Graph mit Abhängigkeiten und die Verteilung über mehrere Rechner.

## 12. PR-Beobachtung, die den Chat weckt

**Was:** Ein Chat kennt seinen PR. Schlägt ein Check fehl, kommt ein Review-Kommentar oder entsteht ein Konflikt, bekommt der Chat (oder Jarvis) eine gezielte Nachricht.

**Warum:** Das schließt die Lücke zwischen „Agent hat den PR geöffnet“ und „PR ist gemergt“, ohne dass wir eine Review-Oberfläche bauen. Nur GitHub, über `gh`.

## 13. Angespartes Reset-Guthaben einlösen

**Was:** Anthropic und OpenAI schreiben Konten gelegentlich Guthaben gut, mit dem sich ein Limit vorzeitig zurücksetzen lässt. Orca zeigt das für Codex („3 Zurücksetzungen verfügbar, nächste läuft in 3 Tagen ab“, Knopf „Jetzt zurücksetzen“), T3 Code für Codex und Claude.

**Für uns:** Bei sieben Claude-Konten und mehreren ChatGPT-Konten wäre eine Zeile „Guthaben verfügbar, läuft ab am…“ in der Limit-Anzeige nützlich.

**Vorher prüfen:** Ob das für unsere Konten überhaupt angeboten wird und ob die Schnittstellen stabil sind. Beides sind nicht dokumentierte Endpunkte der Anbieter.

## Vorgeschlagene Reihenfolge

Nicht nach Nutzen sortiert, sondern so, dass frühe Schritte spätere leichter machen:

| Schritt | Inhalt | Warum an dieser Stelle |
|---|---|---|
| A | 4 (Status aus dem Strom), 9 (Ressourcen), 13 (Guthaben prüfen) | klein, sofort spürbar, 4 ist Voraussetzung für 5 |
| B | 1 (Arbeitskopie mit Änderungsliste) und 8 (Start-Dialog) zusammen | der Start-Dialog ist der Ort, an dem Arbeitskopie, Konto, Modell und später der Rechner gewählt werden |
| C | Vorversuch zu 3, dann Browser | der Vorversuch entscheidet den Weg |
| D | 5 (SSH) | braucht 4 und den Start-Dialog aus B |
| E | 6 (Jira) | braucht den Start-Dialog aus B für „Chat aus Ticket“ |
| F | 7 (Übergabe), 10 (Schlafen), 11 (Vertrag), 12 (PR-Beobachtung) | unabhängig voneinander, je nach Bedarf |
| parallel | 2 (Terminal-Dienst) | eigenes Vorhaben mit eigenem Plan; früh mit einem Vorversuch beginnen, weil es am längsten dauert |

## Was wir nicht bauen

| Was | Warum nicht |
|---|---|
| Eigene Chat-Oberfläche als Ersatz für das Terminal | Bei Orca allein rund 87.000 Zeilen für die Chat-Darstellung, dazu die Anbindungen je Anbieter. Neue Claude-Funktionen müssen dort immer erst nachgebaut werden. Lohnt sich frühestens mit einer Handy-App. |
| Handy-App, Web-Oberfläche | Sehr groß, setzt den Dienst aus Punkt 2 und einen betriebenen Cloud-Dienst voraus. |
| Eigener Cloud-Tunnel, Relay, Cloud-VMs | Laufender Betrieb, Kosten, Verantwortung für fremde Daten. |
| Katalog weiterer Agents | Jeder Agent bringt eigene Anmeldung, Limits, Statuserkennung. Unser Schwerpunkt ist Claude Code, mit Codex daneben. |
| Editor, Notebooks, Plugin-Katalog | Dafür gibt es die IDE. Wir öffnen das Projekt dort. |
| Emulator, Steuerung von Desktop-Apps | Kein Bedarf im heutigen Einsatz. |
| Eingebettetes Chromium als erster Schritt | Siehe [browser.md](browser.md). |
| Vollzugriff ab Werk, Status-Hooks in den Einstellungen des Nutzers | Bewusst anders, siehe [architektur.md](architektur.md). |
| Wechsel auf ein anderes Terminal (Ghostty) nur weil T3 es nutzt | Erst messen, dann entscheiden. |
