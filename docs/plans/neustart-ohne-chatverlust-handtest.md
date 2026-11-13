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
