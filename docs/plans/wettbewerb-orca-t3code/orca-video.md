# Orca im Video: Rundgang Bild für Bild

**Stand:** 10.11.2026 · **Quelle:** „Die beste Agent IDE die ich bisher genutzt habe (Orca)“, Alex Sprogis, 06.11.2026, 13:42 min, <https://www.youtube.com/watch?v=ZEM3TbDp3t0>
**Gehört zu:** [README.md](README.md) (Urteil und Empfehlungen), [vergleich.md](vergleich.md) (Feature-Vergleich)

Diese Seite hält fest, was im Video tatsächlich zu sehen ist, und stellt daneben, was WhisperM8 an derselben Stelle heute zeigt. Die Zeitmarken sind Sprungziele ins Video.

## Aufbau des Fensters ([02:54](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=174))

Orca hat drei Spalten.

**Links** stehen oben fünf feste Einträge: Suchen, Aufgaben, Automatisierungen, Agenten-Dashboard, Orca Mobile. Darunter die Projekte. Ein Projekt klappt in **Worktrees** auf (im Video „main · Primär“, „Test“, „Signal SaaS“), und unter jedem Worktree hängen die Agents, die darin laufen, mit Logo, Titel, Modell und Alter. Die Ebene dazwischen ist der entscheidende Unterschied zu uns: Bei Orca gehört ein Chat zu einer Arbeitskopie, bei WhisperM8 direkt zum Projekt.

**In der Mitte** läuft das Terminal mit der echten Claude-Code-Oberfläche. Man sieht die normale Claude-Statuszeile (`main | Opus 5.5 | ctx … | $6.53`, „auto mode on“). Orca ersetzt die CLI also nicht, es hostet sie, genau wie wir.

**Rechts** liegt eine Seitenleiste mit vier Reitern: Dateibaum des Worktrees (mit Markierung M/U für geänderte und neue Dateien, Umschalter „Namen/Inhalte“ für die Suche), eine zweite Ansicht, Quellcodeverwaltung und Checks.

**Unten** in der Fußzeile steht der Verbrauch: „Verbraucht · Claude 13 % 8h 52m · Codex 58 % 22h 47m · 0 % Cursor Models“. Rechts daneben kleine Symbole für den Wach-Schalter, den Arbeitsspeicher (4,42 GB) und offene Terminals.

| Stelle | Orca | WhisperM8 heute |
|---|---|---|
| Linke Leiste | Projekt → Worktree → Agents | Projekt → Chats, dazu gepinnte Chats, Archiv, Suche |
| Mitte | echte CLI im Terminal, wahlweise Chat-Ansicht | echte CLI im Terminal, Verlauf als Textansicht |
| Rechte Leiste | Dateibaum, Änderungen, PR, Checks | Projekt-Inspector (Projektkontext, neue Chats, in PhpStorm öffnen) |
| Fußzeile | Verbrauch je Anbieter, Wach-Schalter, RAM | Verbrauch in Popovern, Wach-Knopf und Ressourcen-Knopf in der Sidebar |

## Rechte Leiste: Quellcodeverwaltung ([03:30](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=210))

Der dritte Reiter zeigt den Branch mit seinem Gegenstück (`main → origin/main`), ein Feld für die Commit-Nachricht mit einem Knopf, der sie aus dem Diff vorschlägt, „Alle vormerken“, die Liste der 67 geänderten Dateien mit Zeilenzahlen (+40 −2) und darunter die Commits. Oben sitzt der Knopf „PR erstellen“. Ein Klick auf eine Datei öffnet den Diff als Tab.

Das ist der Teil, den WhisperM8 gar nicht hat. Wir zeigen den Branch im Kopf des Chats, mehr nicht.

## Plus-Menü an der Tab-Leiste ([03:50](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=230))

Ein Klick auf das Plus öffnet ein Menü mit Suchfeld („Offene Tabs, Verlauf, Dateien, URLs und Agenten“) und zwei Blöcken:

1. **Arbeitsflächen:** Neues Terminal öffnen (⌘T), Neuen Browser-Tab öffnen (⌘⇧B), Neue Markdown-Datei erstellen (⌘⇧M), Neuen Mobilgeräte-Emulator erstellen. Unter dem Emulator steht ein kleiner Hinweis, was das ist, mit „Beibehalten“ und „Ausblenden“.
2. **Agents:** Claude (⌘⌥T), Codex, Grok, OpenCode 2, OpenCode, Pi, OMP, Antigravity. Nicht installierte stehen grau mit „Nicht installiert“ in der Liste. Jeder Eintrag hat einen Pfeil nach rechts für ein Untermenü. Ganz unten „Agenten-Einstellungen…“.

Was das Menü gut macht: Es ist zugleich Suche und Startfläche, es zeigt alles, was man in einen Tab legen kann, an einer Stelle, und es versteckt nichts, was fehlt, sondern sagt, dass es fehlt.

Unser Plus-Menü startet Codex, Claude, Terminal, den Hintergrund-Auftrag, die Agent View und die Subagent-Bibliothek. Es hat kein Suchfeld und kennt nur Chats und Terminals als Tab-Arten.

## Tabs teilen ([04:10](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=250))

Ein Tab lässt sich auf einen anderen ziehen, dann liegen beide untereinander. Per Rechtsklick ins Terminal gibt es „Terminal nach rechts teilen“ (⌘D) und „Terminal nach unten teilen“ (⌘⇧D). Jede Teilfläche hat ihre eigene kleine Tab-Leiste mit eigenem Plus.

Dasselbe Kontextmenü enthält außerdem: Kopieren, Alles auswählen, Einfügen, Schnellbefehle, **An einen anderen Agenten übergeben**, **Agentensitzung abzweigen…**, Kontext kopieren, **In der Chat-Oberfläche fortfahren**, Titel festlegen, Sitzungs-ID kopieren, Terminal-ID kopieren, Bereichs-ID kopieren, Tab schließen, Bildschirm leeren, Terminal zurücksetzen.

WhisperM8 hat das Raster mit Drag-Zonen und den Workspace-Umschalter. Teilen per Tastenkürzel aus dem Terminal heraus und „abzweigen“ haben wir nicht in dieser Form.

## Chat-Ansicht statt Terminal ([04:40](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=280))

In den Einstellungen unter „Agenten“ lässt sich umstellen, ob ein neuer Agent als Terminal oder als Chat aufgeht. Im Video öffnet der nächste Claude-Agent danach als „Claude Chat“-Tab. Aus dem Terminal heraus gibt es „In der Chat-Oberfläche fortfahren“, die Sitzung wandert also mit.

## Übergabe an einen anderen Agenten ([05:00](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=300))

Rechtsklick → „An einen anderen Agenten übergeben“ öffnet einen Dialog:

- **Aktuelle Sitzung:** „Ursprünglicher Agent: Claude“
- **Agent:** Auswahl, im Video Codex
- **Kontext:** „Gezielte Übergabe (empfohlen)“ mit dem Hinweis „Verwendet den neuesten Status und den aktuellen Arbeitsbereich. Ältere Protokolldetails werden nur bei Bedarf gelesen.“ Die Alternative ist das ganze Sitzungsprotokoll.
- **Startet in:** der Projektpfad
- Knopf „Neue Sitzung starten“

Danach läuft Codex in einer geteilten Fläche neben Claude, bekommt eine Standardanweisung samt Verweis auf den bisherigen Verlauf, und unten rechts erscheint „Der Sitzungskontext wurde an Codex gesendet“ mit „Zum Arbeitsbereich“. Die ursprüngliche Sitzung bleibt unverändert.

Bei uns gibt es dafür keinen Dialog. Der Weg führt heute über einen neuen Chat und eine Nachricht von Hand oder über `whisperm8 chats`.

## Markdown-Dateien ([05:40](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=340))

Eine `spec.md` aus dem Dateibaum öffnet als eigener Tab, fertig gesetzt, mit Werkzeugleiste (Überschriften, fett, Listen, Tabelle, Link, Bild). Man schreibt direkt hinein, schaltet auf Rohtext um oder lässt sich die noch nicht committeten Änderungen an der Datei anzeigen.

## Verbrauch ([06:05](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=365))

Klick auf die Fußzeile öffnet „Nutzung“ mit den Ansichten „Detailliert“ und „Kompakt“. Je Anbieter (Codex, Claude, Cursor) eine Zeile mit Restzeit und Prozent. Das Untermenü für Codex zeigt:

- Sitzung: 2 % verbraucht, Reset in 4h 55m
- Wöchentlich: 58 % verbraucht, Reset in 22h 39m
- „3 Ratenlimit-Zurücksetzungen verfügbar · Nächste läuft in 3d 12h ab“ mit dem Knopf **Jetzt zurücksetzen**
- Codex-Konto: „Systemstandard“ mit Untermenü, „Konten verwalten…“

Dazu „Nutzungsdetails und Verlauf“ und „Konten verwalten…“ für alle Anbieter.

WhisperM8 zeigt Sitzungs- und Wochenlimit ebenfalls, je Konto, und kann Chats zwischen Konten umziehen. Den Knopf „Jetzt zurücksetzen“ für die Codex-Limits haben wir nicht.

## Plugins ([06:20](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=380))

Unten rechts öffnet ein Symbol den Plugin-Katalog: Erweiterungen aus der Community und von Orca selbst, per Klick installiert (Themes, Editoren, Sprachen, Panels).

## Computer wach halten ([06:30](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=390))

Ein kleines Menü mit drei Stufen: **Ein** (Computer bleibt wach), **Agent** (wach bleiben, solange Agents arbeiten), **Aus**.

Das entspricht unserem Wach-Knopf (Aus, bei Arbeit am Strom, Immer). Unserer geht weiter, weil er auch das Zuklappen übersteht.

## Ressourcenverwaltung ([06:40](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=400))

Ein Popover mit zwei Reitern, **Ressourcen** und **PTYs**. Oben die Summe (4,3 % CPU, 4,42 GB Arbeitsspeicher), darunter eine Baumtabelle mit den Spalten Name, CPU, Speicher und einer kleinen Verlaufslinie je Zeile: Projekt (SIGNAL 3,30 GB) → Worktree (main 2,09 GB) → Terminal 1, Terminal 2. Ein eigener Eintrag „ORCA“ zeigt, was die App selbst verbraucht. Ganz unten „Speicherplatz (Beta): Die Speicherplatzbelegung der Arbeitsbereiche …“.

WhisperM8 hat dasselbe Prinzip seit Längerem: Knopf oben in der Sidebar mit Anzahl, CPU und RAM, Popover mit Projekt → Chat → Prozess. Uns fehlen die Verlaufslinie, die Zeile für die App selbst, der PTY-Reiter und die Plattenbelegung.

## Neuer Worktree mit „Ausführen auf“ ([06:50](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=410))

Das Plus neben einem Projekt öffnet „Worktree erstellen“:

- **Projekt:** Auswahl
- **Ausführen auf:** „Local Mac“ mit Pfad, darunter **„Host hinzufügen“** mit Untermenü. Im Video ist nur der eigene Mac eingerichtet.
- **Erstellen aus (optional):** vier Reiter. *Intelligent* (ein Feld für „Namen, #1234, Branch oder URL von GitHub, GitLab oder J…“), *GitHub* (Issue oder PR), *Branch* (durchsuchbare Liste: `refs/heads/…/Test`, `main`, `origin/main`), *Name*.
- **Agent (optional):** Auswahl, im Video Claude
- **Erweitert** zum Aufklappen
- Schalter „Weitere erstellen“ und der Knopf „Worktree erstellen“ (⌘↵)

Das ist die Stelle, nach der du gefragt hast: Der Rechner ist eine Eigenschaft des Worktrees, gewählt in dem Moment, in dem man die Arbeit beginnt. Was dahinter technisch steckt, steht in [architektur.md](architektur.md).

## Orchestrierung ([07:23](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=443))

Einstellungen → Orchestrierung:

- **Orchestrierungs-Skill** mit Marke „Auf dem neuesten Stand“ und „Erneut prüfen“. Darunter „Agentenabdeckung: Alle 4 erkannten Agenten verfügen über den Skill.“
- **Verschachtelungstiefe der Arbeitsagenten:** Zahl, Standard 1 (ein Koordinator beauftragt Arbeiter, die selbst niemanden beauftragen).
- **Abgeschlossene Worker automatisch schließen:** nach zwei Minuten, außer man wählt „Offen halten“.
- **Verwendung:** Kacheln mit den Fällen, für die der Skill gedacht ist: eine aktive Aufgabe übergeben, an einen anderen Worktree übergeben, einen Ablauf in mehreren Phasen ausführen, unabhängige Arbeiten parallel verteilen, eine große Änderung in kleinere PRs aufteilen.

Im Test bittet er einen Claude-Agent, drei Arbeiter zu starten (Opus, Sonnet, Codex). Claude lädt den Skill und ruft `orca orchestration worker-start --spec-file … --task-title "Linktree Opus 5.5" --worktree current --agent …` auf. Die Arbeiter erscheinen als eigene Tabs und in der Seitenleiste, einer fragt nach einer Freigabe, der Koordinator meldet am Ende, wer fertig ist, und schließt die Arbeiter wieder.

Das ist dieselbe Idee wie `whisperm8 chats` mit dem Jarvis-Skill. Orca verpackt sie als einen Schalter in den Einstellungen mit einer Erklärung, wofür man sie nimmt.

## Agenten-Dashboard ([09:00](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=540))

Drei Spalten: **Aktion erforderlich**, **In Arbeit**, **Erledigt**, darüber Suche („Worktree, Projekt oder Agenten suchen…“) und Filter. Jede Karte zeigt Agent, Titel, den Anfang des Auftrags, Projekt und Alter. Am Menüeintrag „Agenten-Dashboard“ in der Seitenleiste sitzen farbige Zähler.

Bei uns übernehmen das Jarvis-Board, die Notch-Anzeige („braucht dich“) und die Statuspunkte. Eine Kanban-Sicht über alle Chats nach Zustand haben wir nicht.

## Design-Modus im eingebauten Browser ([11:13](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=673))

Die erzeugte HTML-Datei öffnet in einem Browser-Tab innerhalb von Orca. Zwei Werkzeuge in der Adressleiste:

1. **Element greifen:** „Ein Element anklicken oder mit dem Mauszeiger darauf zeigen, dann C zum Kopieren oder S für einen Screenshot drücken.“ Das Element bekommt einen Rahmen mit Maßen (`a "Kontakt & Kooperationen" 216×43`). In der Zwischenablage landen Datei, HTML-Element mit Umgebung und der Schnipsel selbst.
2. **Anmerken:** Element anklicken, Kommentar schreiben, zwischen „Änderung“ und „Frage“ wählen, „Hinzufügen“ und „Senden“. Ein Menü fragt, an welchen laufenden Agent die Notiz geht, oder startet einen neuen. Im Terminal kommt das als fertige Anweisung „Design feedback … Feedback: …“ mit Dateiverweis an.

WhisperM8 hat keinen eingebauten Browser. Dazu liegt eine eigene Beratung vor (Playwright-Live-Ansicht rechts statt eingebettetem Chromium).

## Aufgaben ([12:48](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=768))

Die Ansicht „Aufgaben“ zeigt Issues, PRs und Projekte aus GitHub (Reiter oben, Filter „Offen“ / „Mir zugewiesen“, Suchfeld `is:issue is:open`). Linear und Jira lassen sich ebenfalls verbinden. Aus einer Aufgabe startet man einen Worktree mit Agent.

## Automatisierungen ([13:00](https://www.youtube.com/watch?v=ZEM3TbDp3t0&t=780))

„Automatisierung erstellen“ mit Vorlagen. Felder: Titel, Prompt (kann Skills, Dateipfade und Befehle wie `/goal` enthalten), Terminal oder Chat, **Host** („Local Mac — von Local Mac gespeichert und zeitlich geplant“), Projekt, Arbeitsbereich (vorhandener Worktree oder neue Ausführung), Sitzung (neu oder wiederverwenden), Zeitplan (Montag bis Freitag, 9:00), Nachholfrist (12 Stunden), **Vorabprüfung** mit Zeitlimit: ein Shell-Befehl wie `gh pr list --json number -q '.[0].number'`, der entscheidet, ob der Lauf überhaupt startet.

WhisperM8 hat keine geplanten Läufe in der App. Claude Code bringt eigene Routinen mit, die in unseren Chats schon funktionieren.

## Was im Video nicht vorkommt

Mobile-App, SSH-Hosts im Einsatz, Cloud-VMs, Emulator, Computersteuerung und die `orca`-CLI außerhalb der Orchestrierung werden nur genannt, nicht gezeigt. Dazu steht mehr in [vergleich.md](vergleich.md) und [architektur.md](architektur.md).
