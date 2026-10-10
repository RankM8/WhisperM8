# Gesprochene Ansagen (Voice-Callouts)

Stand: 10.10.2026. Plan und Spike zur ChatGPT-Stimme:
`docs/plans/whisperm8-plugin.md` §6.

## Was es ist

Ein Chat kann am Turn-Ende eine kurze Ansage laut vorlesen lassen, zum
Beispiel: „Jarvis: Der Outreach-Chat wartet auf deine Entscheidung zum
Opener.“ Gedacht für Momente, in denen der User woanders arbeitet und
zurückgeholt werden soll: der Turn wartet auf ihn, eine längere Aufgabe ist
fertig, der Chat hängt fest.

- **Jarvis** spricht immer (sein Skill schaltet die Ansagen mit ein).
- **Andere Claude-Chats** sprechen, sobald der User den Skill
  `/whisperm8:callout` lädt.
- **Codex-Chats und Skripte** rufen `whisperm8 speak "<text>"` direkt auf.

## Bedienung

| Wer | Wie |
|---|---|
| Claude (Modell) | Tool `mcp__whisperm8__speak` mit `text` (Skill `whisperm8:callout` regelt das Wann und Wie) |
| Jeder Prozess | `whisperm8 speak "<text>"` oder `echo … \| whisperm8 speak -` |
| User | Menüleiste → „Mute Chat Callouts“ (bleibt über Neustarts), `/callout an \| aus` je Session |
| Stimme | `defaults write com.whisperm8.app speechCalloutVoiceIdentifier <kennung>`; leer = beste deutsche Stimme |

**Bessere Stimme:** Systemeinstellungen → Bedienungshilfen → Gesprochene
Inhalte → Systemstimme → Stimmen verwalten → Deutsch → „Anna (Premium)“ oder
eine andere Premium-/Erweitert-Stimme laden. Die App nimmt sie danach von
selbst (Premium vor Erweitert vor Standard, nie die Eloquence-Spaßstimmen wie
„Grandpa“, de-DE vor AT/CH, Anna bei Gleichstand).

## Wie es funktioniert

```
Skill whisperm8:callout (oder whisperm8:jarvis)
  → Mod: skill.prompt-Hook schaltet den Modus der Session an ($.state)
  → Claude ruft am Turn-Ende mcp__whisperm8__speak({ text })
  → Mod: whisperm8 speak "<text>"   (kehrt zurück, sobald die App angenommen hat)
  → App: speech.speak über den Control-Socket → SpeechCalloutCenter → Systemstimme
```

### App (`Services/Shared/SpeechCallouts.swift`)

- **`SpeechCalloutCenter`** (eine Warteschlange für alle Sessions):
  - Nie zwei Ansagen gleichzeitig.
  - **Nie während einer Diktat-Aufnahme:** Der Aufnahme-Start bricht eine
    laufende Ansage ab (`holdForRecording`), sie kommt nach der Aufnahme von
    vorn. 1,5 s Schonfrist decken den Engine-Start ab, bevor `isRecording`
    gesetzt ist. Danach prüft die App alle 0,5 s, solange etwas wartet.
  - **Entprellung:** höchstens eine Ansage je Chat in 20 s (`debounced`).
    Wartet von dem Chat noch eine, ersetzt die neuere sie (`replaced`).
  - Höchstens 4 wartende Ansagen, die ältesten fallen weg.
  - **Stumm:** Ansagen werden mit `muted` abgelehnt; Stumm-Schalten bricht die
    laufende ab und verwirft die wartenden.
- **`SpeechCalloutText`:** Markdown-Zeichen raus, Zeilenumbrüche zu
  Leerzeichen, höchstens 280 Zeichen (am Satzende gekürzt, sonst am Wort).
  Der Name kommt aus dem Chat-Titel, Teil vor dem ersten Doppelpunkt
  („Jarvis: Supervisor ListM8“ → „Jarvis“), höchstens drei Wörter.
- **Name nur mit gültigem Token:** Wie beim Board stellt die App den Namen nur
  voran, wenn `WHISPERM8_SESSION_ID` + Token stimmen. Ohne (Terminal,
  Skript) spricht sie den Text ohne Namen.
- **Datenschutz:** Kein Ansagetext im Log oder Audit-Log, nur Länge und
  Entscheidung (`log stream … category == "speech.callouts"`).
- **Stimme:** Protokoll `SpeechCalloutEngine`, heute nur
  `SystemSpeechCalloutEngine` (`AVSpeechSynthesizer`, lokal, kostenlos). Die
  ChatGPT-Abo-Stimme (S8) ist zurückgestellt, bis wörtliches Vorlesen und
  Kontingent gemessen sind.

### Mod (`Resources/claude-plugin/hooks/register.tsx`, Abschnitt Voice-Callouts)

- Ohne `WHISPERM8_SESSION_ID` tut sie nichts.
- Modus in `$.state` (`whisperm8.callout`), übersteht Reload und Neustart der
  Session. Bei aktivem Modus steht das Tool direkt in der Liste, sonst nur
  hinter ToolSearch; ein Aufruf bei inaktivem Modus antwortet `aus`.
- Rückmeldung als Hinweis: „🔊 vorgelesen“ oder „🔇 stumm, nicht vorgelesen“.
- **Warum nicht `callout.tsx`:** Die Engine folgt `$` und `on` nie über einen
  Import und erlaubt je Plugin nur einen `session.start` ohne Matcher
  (`claude plugin validate` lehnt beides ab). Deshalb steht der Teil in
  derselben Datei wie das Board.

### CLI

`whisperm8 speak` gibt JSON aus: `status` = `queued` (mit `position`),
`replaced`, `muted`, `debounced` (mit `retryAfterSeconds`). Exit 0 bei
Annahme (auch stumm oder entprellt), 1 bei leerem Text oder abgeschaltet,
5 wenn die App nicht läuft.

## Entwickeln und prüfen

```bash
swift test --filter SpeechCalloutTests
make plugin-test        # enthält hooks/callout.test.ts
whisperm8 speak "Test, eins zwei."   # gegen die laufende App (nach make dev)
```

## Kill-Switch

```bash
defaults write com.whisperm8.app speechCalloutsEnabled -bool NO
```

Die App lehnt dann jede Ansage ab, der Stumm-Schalter verschwindet aus der
Menüleiste.

## Grenzen

- Die Systemstimme klingt hörbar synthetisch, besonders die vorinstallierte
  Standard-Anna. Premium-Stimmen helfen deutlich.
- Ob das Modell sich an „nur wenn nötig“ hält, regelt allein der Skill. Die
  App bremst über Entprellung und Höchstlänge.
- Codex-Chats haben keine Mod: Sie sprechen nur, wenn ihr Prompt oder ein
  Skill sie `whisperm8 speak` aufrufen lässt.
