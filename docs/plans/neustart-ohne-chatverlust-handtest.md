# Neustart ohne Chatverlust: Handtest für den ersten echten Lauf

Für Giuliano. Ziel: Nach einem `make dev` laufen deine Chats einfach weiter, ohne Neustart und ohne verlorene Antwort. Nimm für diesen ersten Lauf nur Chats, deren Verlust nicht schlimm wäre. Jarvis bereitet den Stand vor (Sammel-Branch mit Option A) und nennt dir den Ordner für `make dev`. Hintergrund: [neustart-ohne-chatverlust-review.md](neustart-ohne-chatverlust-review.md).

## Ablauf

1. **Schalter einschalten.** Im Terminal: `defaults write com.whisperm8.app restartKeepsChatsEnabled -bool YES`. Sehen: keine Ausgabe, das ist richtig. (Die Seite in den Einstellungen kommt erst nach diesem Test.)
2. **Einmal klassisch neu starten.** Im Terminal im Ordner, den Jarvis dir nennt: `make dev`. Sehen: Die App beendet sich, deine Chats enden wie bisher und kommen nach dem Start über „Starten“ zurück. Dieser eine Neustart läuft noch wie bisher; er ist nötig, damit die neue App läuft und der Schalter überall wirkt.
3. **Testchats anlegen.** Drei Chats, die du opfern kannst: einen Claude-Chat, dem du eine lange Aufgabe gibst (z. B. „schreibe 300 nummerierte Zeilen“), einen Codex-Chat mit einer kleinen Aufgabe, einen Terminal-Tab mit einem Zähler (`for i in $(seq 1 500); do echo $i; sleep 1; done`). Sehen: alle drei arbeiten.
4. **Neustart mit Übergabe.** Während die drei arbeiten, im Terminal: `make dev`. Sehen: eine Zeile „Übergeben: 3 Chats … Die App beendet sich.“, danach baut und startet die App wie gewohnt.
5. **Zurück in der App.** Sehen: dieselben Tabs, in jedem Chat das Bild von vorher. Die lange Antwort schreibt einfach weiter, der Zähler zählt ohne Lücke weiter, nirgends „Starten“ oder ein neu begonnener Chat.
6. **Ein Chat antwortet noch.** Schreib dem Claude-Chat eine kurze Frage. Sehen: Er antwortet normal, im selben Verlauf.
7. **Gleich noch einmal.** Wiederhole Schritt 4 und 5 zweimal hintereinander. Sehen: jedes Mal dasselbe Bild, keine doppelten Chats, keine Fehlermeldung „API Error“.
8. **Notiz für Jarvis.** Sag Jarvis kurz: wie oft es geklappt hat, ob ein Chat neu begonnen hat, ob irgendwo ein gelber Hinweis stand und was darin stand.

## Wenn etwas hängt

9. **Die App kommt nicht wieder.** Öffne sie von Hand aus dem Programme-Ordner. Sehen: Deine Chats stehen in den Tabs; wo „Starten“ steht, klick darauf, der Chat setzt an seiner Stelle fort. Ein Hilfsprozess hält die Chats höchstens 10 Minuten und beendet sie danach von selbst. Der Verlauf jedes Chats liegt auf der Platte und geht nicht verloren; ein Terminal-Tab endet dagegen mit seinem laufenden Befehl.
10. **Zurück zum alten Verhalten.** Im Terminal: `defaults write com.whisperm8.app restartKeepsChatsEnabled -bool NO`, dann `make dev` wie gewohnt. Sehen: Alles verhält sich wie vor dem Test. Schick Jarvis, was du gesehen hast; er liest die Logs.
