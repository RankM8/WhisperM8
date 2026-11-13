# Neustart ohne Chatverlust: Handtest für den ersten echten Lauf

Für Giuliano. Ziel: Nach einem `make dev` laufen deine Chats einfach weiter, ohne Neustart und ohne verlorene Antwort. Jarvis bereitet den Stand vor (Sammel-Branch mit Option A) und nennt dir den Ordner für `make dev`. Hintergrund: [neustart-ohne-chatverlust-review.md](neustart-ohne-chatverlust-review.md).

**Wichtig vorab:** Eine Übergabe nimmt ALLE laufenden Chats mit, nicht nur die Testchats. Deshalb laufen während des Tests nur die drei Testchats. Echte Chats vor Schritt 2 **schließen**, nicht nur anhalten: Der klassische Neustart in Schritt 2 merkt laufende Chats zum Fortsetzen vor, und ein nur angehaltener Chat startet danach von selbst wieder, sobald sein Tab gezeigt wird (Jarvis hilft beim Schließen). Welche Chats gerade einen laufenden Prozess haben, zeigt dieser eine Befehl:

```
whisperm8 chats list --scope all --limit 0 --json | python3 -c 'import json,sys; [print(s["shortID"], s["title"]) for s in json.load(sys.stdin)["sessions"] if s["capabilities"]["isAttachedPTY"]]'
```

Läuft doch ein echter Chat mit, passiert im schlimmsten Fall dasselbe wie bei jedem `make dev` heute: Sein laufender Turn ist weg und der Chat wird fortgesetzt. Befehle in Terminal-Tabs enden. Die Verläufe der Chats fasst der Übergabe-Code nie an.

## Ablauf

1. **Schalter einschalten.** Im Terminal: `defaults write com.whisperm8.app restartKeepsChatsEnabled -bool YES`. Sehen: keine Ausgabe, das ist richtig. (Die Seite in den Einstellungen kommt erst nach diesem Test.)
2. **Einmal klassisch neu starten.** Im Terminal im Ordner, den Jarvis dir nennt: `make dev`. Sehen: Die App beendet sich wie bisher; falls schon der neue Stand lief, steht dabei die Zeile „Keine Übergabe: … wirkt erst ab diesem Neustart“. Geschlossene Chats bleiben zu; ein Chat, der noch lief, wird fortgesetzt, sobald sein Tab gezeigt wird. Erst nach diesem Neustart wirkt der Schalter.
3. **Nur die Testchats starten.** Drei Chats, die du opfern kannst: einen Claude-Chat mit einer langen Aufgabe (z. B. „schreibe 300 nummerierte Zeilen“), einen Codex-Chat mit einer kleinen Aufgabe, einen Terminal-Tab mit einem Zähler (`for i in $(seq 1 500); do echo $i; sleep 1; done`). Alle anderen Chats bleiben zu. Sehen: die drei arbeiten, und der Befehl von oben zeigt genau diese drei (die Chats, aus denen Jarvis gerade mit dir spricht, zählen mit; schließe sie für den Test oder rechne sie ein).
4. **Neustart mit Übergabe.** Während die drei arbeiten, im Terminal: `make dev`. Sehen: eine Zeile „Übergeben: 3 Chats … Die App beendet sich.“, danach baut und startet die App wie gewohnt. Die Zahl ist die Probe: Steht dort eine größere, liefen echte Chats mit.
5. **Zurück in der App.** Sehen: dieselben Tabs, in jedem Chat das Bild von vorher. Die lange Antwort schreibt einfach weiter, der Zähler zählt ohne Lücke weiter, nirgends „Starten“ oder ein neu begonnener Chat.
6. **Ein Chat antwortet noch.** Schreib dem Claude-Chat eine kurze Frage. Sehen: Er antwortet normal, im selben Verlauf.
7. **Gleich noch einmal.** Wiederhole Schritt 4 und 5 zweimal hintereinander. Sehen: jedes Mal dasselbe Bild, keine doppelten Chats, keine Fehlermeldung „API Error“.
8. **Notiz für Jarvis.** Sag Jarvis kurz: wie oft es geklappt hat, ob ein Chat neu begonnen hat, ob irgendwo ein gelber Hinweis stand und was darin stand.

## Notausgänge

9. **Die App kommt nicht wieder oder stürzt beim Start immer wieder ab.** Im Terminal: `whisperm8 app handover-status`. Steht dort „Aufbewahrer aktiv: PID 12345 …“, beende ihn mit `kill 12345` (deine Zahl statt 12345). Dann die App von Hand aus dem Programme-Ordner öffnen. Sehen: Die Chats stehen in den Tabs; wo „Starten“ steht, klick darauf, der Chat setzt an seiner Stelle fort. Ohne `kill` beendet der Hilfsprozess die Chats nach höchstens 10 Minuten von selbst. Ein Terminal-Tab endet dabei mit seinem Befehl.
10. **Ein Chat sieht kaputt aus** (verschobenes oder leeres Bild, reagiert nicht auf Eingaben). Im Kopf des Chats auf den Kreispfeil „Neu starten“ klicken. Sehen: Der Chat startet neu und setzt seinen Verlauf fort.

**Zurück zum alten Verhalten:** Im Terminal `defaults write com.whisperm8.app restartKeepsChatsEnabled -bool NO`, dann `make dev` wie gewohnt. Alles verhält sich danach wie vor dem Test. Schick Jarvis, was du gesehen hast; er liest die Logs.

## Phase 2: Ablauf für den Testpiloten

Stand 13.11.2026, nach dem ersten echten Lauf (3 von 3 Übergaben mit einem Claude- und einem Codex-Testchat). Phase 2 prüft, was dort fehlte, in der Reihenfolge von Vic. Erst wenn alle Schritte grün sind, kommen echte Chats dazu, zuerst ein entbehrlicher.

> **Zuerst lesen: Schalter erst NACH dem Schließen der echten Chats einschalten.** Ob ein `make dev` übergibt, entscheidet der Schalter zum Zeitpunkt des Neustarts, nicht beim Start der App. Läuft die App schon mit Router als Dienst (sie wurde mit Schalter an gestartet, wie nach Lauf 1), übergibt der nächste `make dev` sofort ALLE laufenden Chats, sobald der Schalter auf YES steht. Die Zeile „wirkt erst ab diesem Neustart“ schützt dann nicht. Reihenfolge deshalb immer: echte Chats schließen, prüfen (Befehl oben unter „Wichtig vorab“), erst dann `defaults write com.whisperm8.app restartKeepsChatsEnabled -bool YES`. Nicht voraussetzen, dass der erste `make dev` klassisch ist.

### Abbruchregel und Aufräumen

- **Beim ersten Fehlschlag anhalten**, kein weiterer `make dev`. Belege sichern (Log der letzten 15 Minuten mit `/usr/bin/log show --last 15m --predicate 'subsystem == "com.whisperm8.app"' > …`, `keeper.log`, Messung je Chat, Fotos), Jarvis Bescheid geben, auf seine Antwort warten.
- **Kein `make dev`, solange ein Schlüsselbund-Dialog offen ist.** Ein blockierter Main Thread beantwortet `app handover` nicht (Frist 30 s); `make dev` fiele auf den klassischen Weg zurück, und die Runde sähe aus wie ein Übergabe-Fehler.
- **Aufräumen am Ende** (wie in Lauf 1): Schalter wieder so wie vorher, Testchats mit `chats close <ref> --stop` schließen und archivieren, Test-Grid löschen, Wegwerf-Ordner und Wegwerf-Branch löschen, `/tmp/wm8-zaehler.txt` löschen, Freigabe-Datei umbenennen. Vor jedem `close --stop` eines Codex-Chats selbst hinsehen, ob er noch schreibt: Sein Status kann `idle` zeigen, während er arbeitet (Befund 2 aus Lauf 1, bis Gus' Fix da ist).

### Vorab auf dem Teststand (fährt Dex, ohne Login)

Sobald Oles CLI-Paket (Terminal-Tab per `chats new --provider terminal --command`, `debug terminal <ref> --text`, wenn möglich `runtime.pid` und `chats send` an den Terminal-Tab) im Sammel-Branch ist, fährt Dex auf der Test-Instanz `scripts/handover-soak-faults.sh run` (dev und ad hoc) und `scripts/handover-soak.sh run --rounds 5`. Was das abdeckt, muss an der echten App nicht mehr einzeln bewiesen werden, nur noch einmal im Zusammenspiel:

| Punkt | Teststand (Skript) | Nur an der echten App |
|---|---|---|
| Terminal-Tab mit Zähler: Lücke, doppelte Zahlen, Befehl überlebt | ja (`zaehler`, `eingabe`), braucht Oles Paket | Augenschein im Fenster |
| Übergabe über zwei verschiedene Builds | ja (`binary-swap`, dev auf dev und ad hoc auf ad hoc) | mit echtem `make dev` aus zwei Ständen |
| „Retrying“ oder „API Error“ im Terminal | ja (`retrying`), braucht `debug terminal --text` | Inhalt mit Login |
| Codex: gleiche PID | ja, braucht `runtime.pid` | Text über mehrere Runden |
| Kein Kind erbt den Socket, Token aus dem Chat | ja (`kein-erbe`, `token`) | – |
| Schalter aus, klassischer Neustart | Modus ja (`router-switch`), echter Router nein | Router-Dienst endet, Router in der App |
| Notausgang 9 (Aufbewahrer weg) | ja (`kill-mid-take`, `hold-deadline`) | Bedienung durch den User |
| GPT-Chat, Kontowechsel, Rückfrage beantworten, Bash-Schritte mit Inhalt | nein (kein Login, kein GPT) | ja |
| Hintergrund-Chat | nein (`--background` fehlt im CLI) | ja, von Hand angelegt |
| Fertig-Meldung genau einmal | erst mit Logzeile `session_notification_posted` (Ole) | ja |
| Schlüsselbund-Dialog beim Diktat | nein (Test-Instanz hat eigenen Schlüsselbund-Dienst) | ja, per Hotkey |
| Scrollback, Fenstergröße, `/exit` | nein | ja |

### Vor dem Start (Lehren aus Lauf 1)

- Der Skill `whisperm8:whisperm8-chats` kann in der Sitzung des Testpiloten fehlen: Dann gilt die Hilfe der CLI (`whisperm8 chats help`, `whisperm8 debug help`).
- `whisperm8` liegt nicht immer im Suchpfad: dann `~/.local/bin/whisperm8` aufrufen.
- In zsh ist `log` ein eingebauter Befehl: immer `/usr/bin/log show …` schreiben.
- Der Testpilot läuft außerhalb der App (eigenes Terminal), weil er `make dev` auslöst. Echte Chats sind geschlossen, nicht nur angehalten.
- Vor jedem Schritt: `whisperm8 app handover-status` zeigt „Kein Aufbewahrer aktiv“.
- Belege je Schritt in einen eigenen Ordner, Namen wie in Lauf 1 (`r<n>-vor.json`, `r<n>-nach.json`, Log, Foto).

### Messung je Runde

Reihenfolge in jeder Runde fest: **erst die Übergabe messen, dann diktieren, dann der nächste `make dev`.**

1. **Vor `make dev`:** je Chat `whisperm8 chats show <ref> --json` (Status, externe ID) und die PID. Die PID steht dort noch nicht; bis `runtime.pid` da ist, wie in Lauf 1 über die Prozessumgebung: `ps -E -ww -axo pid=,ppid=,command= | grep "WHISPERM8_SESSION_ID=<lokale Chat-UUID>" | grep -v grep` (der oberste Prozess, also der, dessen `ppid` nicht selbst in der Liste steht). Startzeit dazu: `ps -o lstart= -p <pid>`.
2. **Nach `make dev`:** dieselbe Messung, sobald im Log `handover_take_finished` steht. **Erfolg:** „Übergeben: N Chats“ mit dem erwarteten N, je Chat gleiche PID und gleiche Startzeit, `handover_take_finished adopted=N ended=0 fallback=0`, in `keeper.log` je Chat `dropped_bytes=0`, kein „Starten“ im Tab, kein Schlüsselbund-Dialog ohne Diktat (`pgrep -x SecurityAgent` direkt nach dem Start leer). **Fehlschlag:** neue PID, „Starten“, kleineres N, „Keine Übergabe“ oder „Übergabe gescheitert“, `fallback` größer 0, ein Dialog, bevor diktiert wurde.
3. **Dann diktieren (Vic, fester Messpunkt).** Lauf 1 hat „kein Dialog“ nur direkt nach dem Start gemessen. Der Schlüsselbund fragt aber erst beim ersten Diktat nach einem neuen Build nach dem API-Schlüssel, und bis Fins Fix hält das den Main Thread an (Lauf 1: `main_thread_freeze durationMs=5011` um 20:21:49).
   - **Wer:** Das Diktat macht der User von Hand per Hotkey in ein leeres Textfeld außerhalb der App (etwa TextEdit). Den Dialog bestätigt nur der User, „Immer erlauben“ verlangt sein Mac-Passwort; der Testpilot fasst den Schlüsselbund nicht an. `whisperm8 debug dictate` taugt hier nicht: Es liest den Schlüssel schon in `Task.detached` (DebugControl, Zeile 254) und nimmt einen anderen Weg als der Hotkey, misst den Hänger also nicht.
   - **Erwarteter Eintrag:** Der Dialog nennt den Schlüsselbund-Eintrag „com.whisperm8.app“ (Konto `openai_apikey` oder `groq_apikey`, je nach Anbieter; mit ChatGPT-Abo gibt es keinen Schlüssel und keinen Dialog).
   - **Messen:** Dialog ja oder nein (Foto mit dem Text), Sekunden bis zum Klick, danach `/usr/bin/log show --last 2m --predicate 'eventMessage CONTAINS "main_thread"'`.
   - **Fins Fix:** In der Notiz steht, ob `fix/diktat-schluesselbund-main-thread` im gebauten Stand ist (`git -C <ordner> merge-base --is-ancestor <fix-commit> HEAD`, den Commit nennt Jarvis).

   | Fins Fix im Build | Dialog beim Diktat | Freeze | Bewertung |
   |---|---|---|---|
   | nein | ja, Eintrag „com.whisperm8.app“ | ja, so lange der Dialog offen ist | bekannt, kein Übergabe-Befund |
   | ja | ja, Eintrag „com.whisperm8.app“ | nein | erwartet: Der Dialog bleibt, bis die App eine Team-ID hat |
   | ja | ja | ja | Befund an Fin: Der Fix greift nicht |
   | egal | Dialog für einen anderen Eintrag, oder schon vor dem Diktat | – | Befund, Foto an Jarvis |
   | egal | kein Dialog, obwohl neuer Build | nein | kein Befund, nur notieren |
   | egal | kein Dialog bei gleichem Build | nein | erwartet |

4. **Erst wenn kein Dialog mehr offen ist:** nächster `make dev`.

### Schritt 1: Terminal-Tab mit Zähler

- **Tun:** `/tmp/wm8-zaehler.txt` vorher löschen. Ein Terminal-Tab mit einem Zähler, der in eine Datei UND ins Terminal schreibt. Mit Oles Befehl: `whisperm8 chats new --provider terminal --project <testordner> --title "Zaehler" --command "/bin/sh -c 'i=0; while :; do i=\$((i+1)); echo \$i | tee -a /tmp/wm8-zaehler.txt; sleep 0.2; done'" --json`. Fehlt der Befehl noch: Terminal-Tab von Hand öffnen und dieselbe Schleife eintippen. Dann dreimal `make dev` wie oben.
- **Die Datei allein beweist nur, dass der Prozess lief** (sie schreibt `tee`, nicht das Terminal). Hart wird die Prüfung am Terminaltext: Zählerstand direkt vor `make dev` notieren (z1, letzte Zeile der Datei) und direkt nach `handover_take_finished` (z2). Dann im Terminaltext jede Zahl von z1−20 bis z2+20 genau einmal und in Reihenfolge verlangen. Bei fünf Zahlen je Sekunde ist die Übergabe-Stelle nach zehn Sekunden aus dem sichtbaren Bild gelaufen: `whisperm8 debug terminal <ref> --text` muss dafür den Scrollback liefern, oder die Prüfung läuft sofort nach `handover_take_finished`.
- **Erfolg:** Alle Zahlen von z1−20 bis z2+20 stehen genau einmal und in Reihenfolge im Terminal. Die Datei hat keine Lücke und keine doppelte Zahl (`awk 'NR>1 && $1!=p+1 {print "Lücke nach", p} {p=$1}' /tmp/wm8-zaehler.txt` gibt nichts aus). Gleiche PID, `dropped_bytes=0`.
- **Eingabe danach:** Einen Echo-Tab (`--command "/bin/sh -c 'while read l; do echo got:\$l; done'"`) mit `whisperm8 chats send <ref> -- probe-1` füttern. Erfolg: genau eine Zeile `got:probe-1`.
- **Beleg:** z1 und z2 je Runde, Terminaltext je Runde, `/tmp/wm8-zaehler.txt`, `keeper.log`.

### Schritt 2: Übergabe über zwei verschiedene Builds, mindestens zweimal

- **Tun:** Jarvis legt zwei Ordner an: A auf dem Sammel-Branch und B auf einem Wegwerf-Branch mit einem eigenen Commit über A (eine harmlose Code-Änderung, etwa ein geänderter Logtext, damit der Build sich wirklich unterscheidet; ohne Commit schlägt die Prüfung „Arbeitsbaum sauber, Hash aus der Freigabe“ an). Die Freigabe nennt beide Hashes. Der Testpilot wechselt A → B → A → B, jedes Mal `make dev` im jeweiligen Ordner, während Claude-, Codex- und Terminal-Testchat arbeiten.
- **Befehl vor und nach jedem `make dev`:** `codesign -dvvv /Applications/WhisperM8.app 2>&1 | grep CDHash`.
- **Erfolg:** Der CDHash wechselt bei jeder Runde, trotzdem gilt alles aus „Messung je Runde“, Punkt 2. Seit Option A hängt die Übergabe an keiner Signatur mehr.
- **Fehlschlag:** wie in „Messung je Runde“; dazu: gleicher CDHash heißt, der Build war nicht verschieden, die Runde zählt nicht.
- **Diktat:** Hier zählt der Messpunkt besonders. Je Wechsel A ↔ B ist beim Diktat ein Dialog für „com.whisperm8.app“ zu erwarten (neuer CDHash); ob dabei der Main Thread hängt, hängt an Fins Fix. Ein Dialog OHNE Diktat, direkt nach dem Start, ist dagegen ein Fehlschlag.
- **Beleg:** CDHash je Runde, `make dev`-Ausgabe, Messung je Chat, Foto jedes Dialogs, `main_thread`-Zeilen aus dem Log.

### Schritt 3: Die anderen Chat-Arten

Jede Art einzeln dazunehmen, je zwei Runden `make dev`, dann wieder schließen.

- **GPT-Chat:** Über „Neuer GPT-Chat“ in der App, Aufgabe „schreibe 300 nummerierte Zeilen“. Der Router-Dienst wird bei jedem `make dev` durch eine neue Generation ersetzt, weil sich der Build-Stempel ändert (Lauf 1: PIDs 74166, 80342, 83589, 84231). Eine neue Router-PID ist deshalb KEIN Fehlschlag. **Erfolg:** gleicher Port; im Log des Router-Dienstes (`/usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS "gpt_router_service"'`) `took_over … generation=<alte+1>` und `handover_done … active=1`; die alte Generation endet mit `exit code=0` erst NACH dem Ende der laufenden Antwort; die Antwort läuft ohne Sprung weiter; kein `401`, kein `API Error`. **Fehlschlag:** abgerissene Antwort, `exit` der alten Generation vor dem Antwortende, `401`.
- **Angedockter Hintergrund-Chat:** Von Hand einen Hintergrund-Chat (`claude --bg`) in der App starten und andocken; `--background` gibt es im CLI noch nicht. **Erfolg:** nach der Übergabe derselbe Hintergrund-Agent (gleiche Sitzungs-ID in `chats show`), Andocken klappt weiter, nur ein Prozess je Sitzung. **Fehlschlag:** zweiter Agent oder „Starten“.
- **Offene Rückfrage:** Claude-Chat bis zu einer offenen Rückfrage bringen (etwa „Frag mich mit AskUserQuestion, welche Farbe ich will, und warte“). Übergabe, dann die Frage beantworten. **Erfolg:** Die Frage steht nach der Übergabe noch da, die Antwort kommt genau einmal an, der Chat arbeitet weiter.
- **Claude mit Bash-Schritten:** „führe nacheinander 20× `echo n; sleep 3` aus“. Übergabe mitten in den Schritten. **Erfolg:** Die Zahlen laufen ohne Lücke und ohne doppelten Schritt weiter, kein „Retrying“.
- **Codex-Text über mehrere Runden:** In Lauf 1 unbelegt, weil die Antwort unterbrochen wurde. Codex eine lange nummerierte Antwort geben („schreibe 600 nummerierte Zeilen“), zwei Runden `make dev` mitten darin, die Antwort NICHT unterbrechen und zu Ende laufen lassen. **Erfolg:** Im Verlauf (Rollout unter `~/.codex/sessions`, nur lesen) stehen alle Zahlen von 1 bis 600 genau einmal und in Reihenfolge. **Fehlschlag:** Lücke, Doppel, abgebrochene Antwort.
- **Vorgemerkter Kontowechsel:** Hat das Zielkonto den Testordner nie freigegeben, wird ein arbeitender Chat nicht vorgemerkt, und der Schritt scheitert aus fremdem Grund. Deshalb vorher einmal einen Chat des Zielkontos in diesem Ordner öffnen und „Trust“ bestätigen. Dann während ein Claude-Chat arbeitet: erst `whisperm8 chats move-account <ref> --to <zweites-profil> --stop-and-resume --dry-run` (muss `wouldSchedule` zeigen), dann ohne `--dry-run` (zeigt `scheduled`). Dann `make dev`, Turn zu Ende laufen lassen. **Erfolg:** Der Wechsel passiert genau einmal nach dem Turn, `chats show` nennt danach das neue Konto, der Verlauf ist vollständig. **Fehlschlag:** Wechsel verloren, doppelt oder mitten im Turn.
- **Fertig-Meldung:** Sobald Oles Logzeile `session_notification_posted` im Build ist, nach jedem Turnende zählen: genau eine Zeile je Chat und Turn (`/usr/bin/log show --last 10m --predicate 'eventMessage CONTAINS "session_notification_posted"'`). Bis dahin: sichtbare Mitteilungen zählen.
- **Beleg:** Messung je Chat, Log, Foto.

### Schritt 4: Notausgänge, Schalter aus, und was nach der Übernahme noch gehen muss

- **Notausgang 9:** Statt `make dev` nur `whisperm8 app handover` aufrufen: Die App gibt die Chats ab und beendet sich, eine neue startet nicht. Dann wie in Notausgang 9 beschrieben: `whisperm8 app handover-status`, `kill <pid>` des Aufbewahrers, App von Hand aus dem Programme-Ordner öffnen. Nach dem `kill` sind die Chat-Prozesse tot; die App setzt fortsetzbare Chats dann **von selbst** fort, mit gelbem Hinweis (Log: `handover_take_plan plan=keeperGone` und `handover_fallback_resume count=N`). Nur der Terminal-Tab bleibt beendet. **Erfolg:** je Chat neue PID, gleiche externe ID, alte PID vorher tot, ein Prozess je Sitzung; danach `handover-status` „Kein Aufbewahrer aktiv“, im Ordner `…/WhisperM8/handover/` kein `take-secret`, kein Socket. **Gegenprobe ohne `kill`:** noch einmal `whisperm8 app handover`, dann die App von Hand öffnen. Sie muss normal übernehmen (gleiche PIDs).
- **Notausgang 10:** In einem übernommenen Chat auf den Kreispfeil „Neu starten“ klicken. **Erfolg:** Der Chat startet neu (neue PID) und setzt seinen Verlauf fort, nur ein Prozess je Sitzung.
- **Schalter aus, klassischer Neustart:** `defaults write com.whisperm8.app restartKeepsChatsEnabled -bool NO`, dann `make dev`. **Erfolg:** keine Zeile „Übergeben“, die Chats enden wie früher. Danach läuft **kein** `WhisperM8 gpt-router` mehr (`pgrep -fl "WhisperM8 gpt-router"` leer), und der Router lauscht wieder in der App (`lsof -nP -iTCP -sTCP:LISTEN | grep WhisperM8`). War noch ein alter Dienst da, steht im Log `gpt_router_service_retired_for_in_app_router`. Ein GPT-Chat antwortet danach normal. Danach Schalter erst wieder an, wenn keine echten Chats laufen (siehe Kasten oben), und einmal klassisch `make dev`.
- **Scrollback (Vic):** Nach drei Übergaben im Claude-Chat ganz nach oben scrollen. **Erfolg:** Der Verlauf von vor der ersten Übergabe ist da, ohne Lücke an den Übergabe-Stellen.
- **Fenstergröße (Vic):** Nach einer Übergabe das Fenster deutlich kleiner und wieder größer ziehen und einen Chat im Grid vergrößern. **Erfolg:** Die Programme zeichnen sauber neu (keine verschobenen Zeilen, kein Rest alter Zeichen), Eingaben gehen weiter.
- **`/exit` eines übernommenen Chats (Vic):** In einem übernommenen Claude-Chat `/exit` eingeben. **Erfolg:** Der Prozess endet, der Tab zeigt den Chat als beendet, kein Neustart von selbst, kein verwaister Prozess (`ps -E -ww -axo pid=,command= | grep "WHISPERM8_SESSION_ID=<lokale Chat-UUID>" | grep -v grep` gibt nichts aus), der nächste `make dev` meldet einen Chat weniger.
- **Beleg:** Fotos vor und nach, `ps`- und `lsof`-Ausgaben, Log.

### Schritt 5: Acht bis zehn Chats gleichzeitig

- **Tun:** Acht bis zehn Testchats aller Arten aus Schritt 1 bis 3, die meisten arbeiten gerade, mehrere im Grid sichtbar. Zwei Runden `make dev`.
- **Erfolg:** „Übergeben: N Chats“ mit N gleich der Zahl laufender Chats, alle mit gleicher PID, `handover_take_finished adopted=N ended=0 fallback=0`. Von `committed` in `keeper.log` bis `handover_take_finished` im Log höchstens **5 s** (Lauf 1: 1,7 s mit zwei Chats). Kein `main_thread_blocked_ongoing` und kein `main_thread_freeze` zwischen Start und einer Minute danach.
- **Fehlschlag:** kleineres N, `fallback` größer 0, mehr als 5 s, App hängt, ein Chat zweimal.
- **Beleg:** Zeitstempel `committed` und `handover_take_finished`, Log mit `main_thread`- und `perf_budget`-Zeilen.

### Danach: echte Chats

Erst wenn Schritt 1 bis 5 grün sind. Zuerst ein einziger entbehrlicher echter Chat mit den Testchats zusammen, zwei Runden. Dann schrittweise mehr. Jeder echte Chat, der übergeben wird, steht in der Notiz an Jarvis.
