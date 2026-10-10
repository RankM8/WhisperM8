---
name: callout
description: Gesprochene Ansagen am Turn-Ende — die WhisperM8-App liest eine kurze Zusammenfassung laut vor, wenn der Turn auf den User wartet, eine längere Aufgabe fertig ist oder du festhängst. Nutzen bei "sag Bescheid, wenn du fertig bist", "Ansagen an", "lies vor", "Callout-Modus", "sprich mit mir". Jarvis lädt ihn automatisch. Heißt bewusst nicht "voice" — /voice ist das Diktat von Claude Code.
---

# Callout — gesprochene Ansagen am Turn-Ende

Der User arbeitet oft woanders und schaut nicht auf diesen Chat. Eine Ansage
holt ihn zurück, wenn es sich lohnt. Die WhisperM8-App spricht sie mit der
Systemstimme, stellt den Namen dieses Chats voran („Jarvis: …“), spricht nie
zwei Ansagen gleichzeitig und nie während der User diktiert.

## Wie

- **Tool `mcp__whisperm8__speak`** mit `text`, als letzter Schritt des Turns,
  NACH der schriftlichen Antwort. Ist das Tool nicht da (Codex, Session
  außerhalb des Plugins): `whisperm8 speak "<text>"` per Bash.
- Höchstens **eine Ansage pro Turn**. Die App entprellt ohnehin (20 s je
  Chat), eine zweite ginge verloren.

## Wann sprechen

- Der Turn **wartet auf den User**: Entscheidung, Freigabe, Rückfrage, die
  ohne ihn nicht weitergeht.
- Eine **längere Aufgabe ist fertig** (mehrere Minuten Arbeit, Tests,
  Build, Delegation): Ergebnis in einem Satz.
- Du **hängst fest**: Fehler, den du nicht selbst lösen kannst, fehlende
  Rechte, widersprüchliche Vorgaben.

## Wann schweigen

- Kurze Antworten im laufenden Dialog — der User liest ohnehin mit.
- Zwischenstände, Fortschritt, „ich mache jetzt X“.
- Wenn der Turn ohne den User weitergeht.

Im Zweifel schweigen: Eine Ansage zu viel nervt mehr als eine zu wenig.

## Text

- **Höchstens zwei kurze Sätze**, Deutsch, gesprochene Sprache.
- Erst das Ergebnis oder die Frage, dann (falls nötig) was der User tun soll:
  „Die Tests sind grün, der Commit wartet auf deine Freigabe.“
- **Keine** Pfade, Dateinamen, Code, Befehle, IDs, Hashes, URLs, Markdown,
  Aufzählungen — das klingt vorgelesen unverständlich.
- **Nicht** den eigenen Chat-Namen nennen — den stellt die App voran.
- Zahlen nur, wenn sie zählen („drei Tests rot“), gerundet.

## Antwort des Tools

| `status` | Bedeutung | Was tun |
|---|---|---|
| `queued` / `replaced` | Wird gesprochen | nichts |
| `muted` | User hat Ansagen in der Menüleiste stumm geschaltet | nichts, nicht erneut versuchen |
| `debounced` | Dieser Chat hat eben erst gesprochen | nichts, nicht erneut versuchen |
| `aus` | Callout-Modus der Session ist aus (`/callout an`) | nichts |
| Fehler „abgeschaltet“ | Kill-Switch in der App | nichts |

Die schriftliche Antwort bleibt immer vollständig — die Ansage ist nur der
Hinweis, dass es sie gibt.
