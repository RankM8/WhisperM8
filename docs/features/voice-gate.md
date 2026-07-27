---
status: in Review — offene Blocker, siehe „Bekannte Probleme"
stand: 2026-07-27
feature: Voice Gate / Codex Voice Agent
---

# Voice Gate — Codewort-Steuerung der Codex-Sprachsitzung

Ein kurzes Codewort schaltet das Mikrofon der laufenden **Codex-Desktop-Sprachsitzung**
stumm und wieder frei, ohne dass jemand einen Shortcut drückt.

- **„Jarvis Pause"** → stumm
- **„Jarvis weiter"** → wieder frei

WhisperM8 transkribiert dabei nichts für Codex und übernimmt keine parallele
Aufnahme — es löst ausschließlich Codex' **eigenen** Mute-Umschalter aus.

## Stand: Phase 2 (scharf schaltbar)

Erkennung **und** Tastendruck sind gebaut. Welcher von beiden Modi läuft,
entscheidet ein Schalter, der **zur Laufzeit** gelesen wird — kein Rebuild,
kein Neustart:

```bash
defaults write com.whisperm8.app codexVoiceGateDryRun -bool NO    # scharf
defaults write com.whisperm8.app codexVoiceGateDryRun -bool YES   # nur Ton
```

Im Trockenlauf (Default) endet der Pfad bei Log, Zähler und einem kurzen Ton.
Scharf folgt der Fokus-Roundtrip: Vordergrund-App merken → Codex aktivieren →
**0,35 s Nachlauf** → `Ctrl+Shift+U` als `CGEvent` → zurück zur vorherigen App.
Gemessene Dauer steht als `durationMs` im Log (rund 480 ms).

Der Nachlauf ist nicht willkürlich: Chromium meldet die App als frontmost,
**bevor** das Key-Window steht. Mit 0,08 s ging am 27.07.2026 ein Druck durch
und der nächste unter identischen Bedingungen verpuffte; ein Handtest mit 0,8 s
war zuverlässig.

### Bestätigung und Fehlerfälle

Nach dem Druck sucht der `CodexCommandExecutionProbe` bis zu 1,5 s nach der
`response_routed … conversationId=null`-Signatur im Codex-Log. Sie ist eine
undokumentierte Interna und darf nichts blockieren:

- **Signatur da** → `confirmed=true`, Annahme übernommen.
- **Signatur fehlt, aber sie hat in dieser Sitzung schon einmal getragen** →
  genau **ein** Nachfass-Druck (`press.retry`), dann erneute Prüfung. Bleibt
  auch der unbestätigt, geht der Zustand auf `unknown` — keine Schleife.
- **Signatur fehlt und hat noch nie getragen** → nur eine Notiz, kein
  Nachfassen. Fällt die Signatur mit einem Codex-Update weg, bleibt das
  Verhalten dadurch unverändert, statt blind doppelt zu drücken.
- **Mechanisches Scheitern** (Codex kam nicht in den Vordergrund, kein
  `CGEvent`) → echter Beleg, Zustand auf `unknown`, der nächste Befehl drückt
  in jedem Fall.

In der Praxis ist die Signatur **unzuverlässig**: Im Feldtest am 27.07.2026
standen mehrere nachweislich erfolgreiche Umschaltungen mit `confirmed=false`
im Log. Sie taugt deshalb als Zusatzsicherung, nicht als Wahrheit — genau
darum die Bedingung „hat schon einmal getragen".

## Warum es so gebaut ist (Messungen vom 26.07.2026)

Ein Live-Spike gegen eine laufende Codex-Sitzung hat vier Dinge belegt:

| Frage | Ergebnis |
|---|---|
| Bleibt die Sitzung bei Mute verbunden? | **Ja** — kein Session-Event im Messfenster |
| Bekommt Codex im Mute-Zustand Audio? | **Nein** — 6 gesprochene Zahlen fehlten im Transkript |
| Hört ein paralleler Listener weiter? | **Ja** — Aufnahme am selben AirPods-Mikro, transkribierbar |
| Reicht ein Tastendruck ohne Fokus? | **Nein** — `CGEventPostToPid` blieb wirkungslos |

### Sitzungserkennung und ihre Grenze

Das Codex-Log schreibt `realtime_session_started`, aber **weder einen
Ende-Marker noch ein Lebenszeichen** während der Sitzung — zwischen Start
(06:17) und laufendem Gespräch (06:55) stand am 27.07.2026 nichts
Realtime-Bezogenes darin. Ein Sitzungsende ist damit nicht erkennbar.

Folge: `CodexVoiceSessionProbe.maxSessionAge` steht auf **8 Stunden**. Eine
kürzere Frist ließ die Schärfe mitten im Gespräch verfallen (mit 30 Minuten
passiert). Der Preis ist, dass das Gate scharf bleibt, solange Codex läuft und
heute eine Sprachsitzung begonnen hat — auch nach deren Ende. Verlässlich
geschlossen wird es durch: Codex beenden, oder den Schalter in den
Einstellungen. **Der Schalter ist die eigentliche Kontrolle.**

Daraus folgen die tragenden Entwurfsentscheidungen:

- **Kein Mute auf Geräte- oder Systemebene.** Das würde den Listener mit-taub
  machen. Gemutet wird ausschließlich in Codex selbst.
- **Der Listener bindet sein Eingabegerät explizit** (nie „System Default") und
  ist damit unabhängig von allem, was Codex mit seinem Eingang tut.
- **Der Fokus-Roundtrip ist unvermeidbar**, weil `realtimeVoice.toggleMicrophoneMute`
  in Codex `shortcutScope: app` hat.

## Zustandslogik

Der Codex-Shortcut ist ein **blinder Toggle** — er schaltet um, verrät aber
nicht wohin, und der wahre Zustand ist von außen nicht lesbar. Die
Zustandsmaschine führt deshalb eine *Annahme* und macht sie dreifach robust:

1. **Absicht statt Toggle** — „Jarvis Pause" mutet nur, wenn wir offen glauben.
2. **Wiederholung überstimmt** — wurde ein Befehl als „schon im Zielzustand"
   **übersprungen** und kommt dieselbe Phrase binnen 4 s erneut, wird trotzdem
   gedrückt. Damit ist die Selbstkorrektur des Toggles zurück, ohne dessen
   Richtungs-Blindheit.

   Entscheidend ist die Einschränkung auf *übersprungene* Befehle. Zuvor griff
   die Übersteuerung nach jeder Erkennung — dadurch wurde eine Doppelerkennung
   derselben Äußerung 3 s nach einem erfolgreichen Druck als Widerspruch
   gewertet und hob ihn wieder auf (gemessen 27.07.2026, 09:18). Die Annahme
   lief danach dauerhaft gegen die Realität. Drei Regressionstests halten das
   fest.
3. **Manuelle Korrektur** — läuft die Annahme dennoch auseinander, etwa weil im
   Codex-Overlay von Hand geklickt wurde, wird sie im Einstellungs-Tab oder im
   Menüleisten-Menü richtiggestellt.

Ein *passiver* Abgleich über Codex' Thread-Transkript ist in
`VoiceGateStateMachine.observeCodexReceivedAudio()` vorbereitet und getestet,
aber **bewusst noch nicht verdrahtet**: Die Zustellung der `user_message`-
Einträge ist an Turn-Grenzen gebunden und damit bis zu eine Minute verzögert —
zu träge, um eine Sekundenentscheidung zu tragen.

## Fehlalarm-Schutz

Gestaffelt, weil kein einzelnes Kriterium reicht:

- Trägerwort **und** Kommando, benachbart innerhalb 1,5 s
- mindestens 0,3 s Stille vor dem Trägerwort (kein Treffer mitten im Satz)
- Kommandowörter **exakt** — schon Editierdistanz 1 macht „Wetter" zu „weiter"
  und „Hause" zu „Pause" (von einem Unit-Test gefunden)
- Trägerwort **längenabhängig**: ab 6 Zeichen wird ein verhörter Buchstabe
  verziehen, darunter muss es exakt sitzen. Bei „anna" (4 Zeichen) lägen sonst
  „Anne", „Hanna", „Manna" und „wanna" alle in Distanz 1
- Entprellung 2,0 s je Absicht, Cooldown 2,5 s nach jeder Auslösung
- Gate: nur bei laufendem Codex mit plausibel aktiver Sprachsitzung
- pausiert, solange WhisperM8 selbst diktiert

Das Trägerwort allein löst nie aus — „sei mein Jarvis" fällt im Alltag beiläufig.

### Verschmolzene Form

Der On-Device-Erkenner klebt benachbarte Wörter unregelmäßig zusammen: „anna
pause" kam im Feldtest mal als zwei Segmente und mal als ein Token `annapause`
an (im selben Log auch „aufjeden fall ein traum auto"). Der Matcher prüft
deshalb **beide** Formen — zuerst die verschmolzene, dann die getrennte, beide
mit derselben Äußerungsgrenze davor.

Ohne diesen Pfad wirkt das Feature zufällig: Es greift oder greift nicht, je
nachdem wie der Erkenner gerade segmentiert — nicht abhängig von der
Aussprache. Genau so ist es am 27.07.2026 aufgefallen.

## Eigene Codewörter

Trägerwort und beide Kommandowörter sind in den Einstellungen frei setzbar und
wirken sofort — der Matcher wird bei jeder Erkennung frisch aus den Preferences
gebaut. Leere Felder fallen auf die Defaults zurück.

Die Oberfläche warnt bei den drei Mustern, die erfahrungsgemäß Fehlalarme
erzeugen: Wörter unter vier Buchstaben, doppelt vergebene Wörter, und ein
Kommandopaar mit Editierdistanz ≤ 1 (eine Verwechslung würde dann das Gegenteil
des Gewollten tun — der Grund, warum „an"/„aus" eine schlechte Wahl wäre).

## Erkennungssprache

On-Device-Modelle sind **pro Region** installiert, nicht pro Sprache. Auf
diesem Mac lag am 26.07.2026 nur `de_CH` vor — `de_DE` und `de_AT` nicht.
Der `VoiceGateLocaleResolver` nimmt deshalb die erste Variante derselben
Sprache, für die ein Modell bereitsteht (`de_DE` → `de_CH` → `de_AT`). Für
zwei feste Kommandophrasen ist die Regionalvariante unerheblich; ein
fehlendes Modell wäre dagegen ein harter Stopp.

Die gewählte Locale steht beim Start im Log: `gate.locale=de_CH`. Fehlt jede
Variante, meldet die Menüleiste, welche geprüft wurden.

## Berechtigungen

Drei Stück, und zwei davon fehlen einer frischen Installation:

| Berechtigung | Wofür | Wann |
|---|---|---|
| Mikrofon | Listener-Tap | immer |
| **Spracherkennung** | `SFSpeechRecognizer` | beim ersten Scharfschalten |
| **Bedienungshilfen** | `CGEvent` an Codex senden | nur im scharfen Modus |

Ohne Bedienungshilfen scheitert **jeder** Tastendruck (`CodexMuteToggler` wirft
`accessibilityPermissionMissing`) — im Trockenlauf fällt das nicht auf, weil dort
nie gedrückt wird.

Dazu die lokalen Diktat-Sprachdaten: ohne sie startet der Listener nicht.

## Datenschutz

Erkennung strikt **on-device** (`requiresOnDeviceRecognition`). Fehlen die
lokalen Sprachdaten, **startet die Funktion gar nicht** — ein stiller Fallback
auf Apples Server wäre ein Bruch des Versprechens. Kein Audio auf Platte, keine
Transkripte im Log (nur Klassifikation, Konfidenz, Entscheidung). Der Listener
läuft nur, solange das Gate scharf ist, nicht rund um die Uhr.

## Einschalten und beobachten

**In den Einstellungen:** Agent Chats → **Codex Voice Agent**. Der eigene Tab
führt durch Voraussetzung, Schalter, Codewörter, Verhalten und Diagnose.

Der Haupt-Toggle wirkt **sofort** — „aus" beendet den Listener, gibt das
Mikrofon frei (die Aufnahme-Anzeige in der Menüleiste verschwindet) und
blockiert damit auch die Codewörter. Kein Neustart nötig.

### Voraussetzung, die WhisperM8 nicht herstellen kann

Codex' Kommando „Toggle Voice Chat microphone" wird **ohne Default-Kürzel**
ausgeliefert. Es muss einmalig von Hand belegt werden:

> Codex → Settings → Keyboard shortcuts → „Toggle Voice Chat microphone" →
> Control-Shift-U

Ohne diese Belegung ist der ganze Rest wirkungslos — deshalb steht der Hinweis
als erste Sektion im Tab.

Gleichwertig per Kommandozeile:

```bash
defaults write com.whisperm8.app codexVoiceGateEnabled -bool YES   # Default: aus
# App neu starten (make dev), dann:
log stream --predicate 'subsystem == "com.whisperm8.app" && category == "voice.gate"' --level debug
```

Ereignisse: `gate.arm_state`, `gate.locale`, `listener.started`,
`candidate.match intent=… final=…`, `candidate.rejected reason=…`,
`would_press …` (Trockenlauf) bzw. `pressed … durationMs=… confirmed=…`,
`press.retry` und `press.retry_result`. Die **Beinahe-Treffer** sind der
eigentliche Ertrag — sie zeigen datenbasiert, ob die Schwellen sitzen.

### Wenn ein Codewort nicht greift

Der Schalter **„Log recognized words"** (Diagnostics-Abschnitt, Default aus,
Schlüssel `codexVoiceGateVerboseLogging`) schreibt zusätzlich, **was** der
Erkenner verstanden hat:

```
heard="anna pause" final=false vocabulary="anna/pause/weiter"
```

Damit ist in einer Zeile unterscheidbar, ob das Modell etwas anderes verstanden
hat oder ob eine Regel gegriffen hat. Ausgewertet werden auch Teilergebnisse
(gedrosselt auf eine Zeile alle 2 s) — nur auf finale zu warten war nutzlos,
weil die Phrase dort praktisch nie steht.

Der Schalter protokolliert Gesprochenes. Nach der Fehlersuche wieder ausschalten.

Sichtbar außerdem im Menüleisten-Menü: Schärfe, angenommener Mikrofon-Zustand,
Zähler, letztes Ereignis und eine manuelle Zustandskorrektur. Bei jedem
`would_press` ertönt ein kurzer Ton — nur so fällt im Moment des Geschehens auf,
dass es ausgelöst hätte.

## Abnahme vor Phase 2

- **Trefferquote:** 20 bewusste Versuche → ≥19 erkannt
- **Fehlalarm-Soak:** ≥2 h normaler Betrieb ohne absichtliches Codewort →
  **0** `would_press`-Ereignisse

Die zwei Blöcke werden getrennt gefahren; dadurch ist jede Auslösung im Soak
per Definition ein Fehlalarm und braucht keine Interpretation.

## Bekannte Probleme (Stand 2026-07-27, vor Freigabe zu klären)

Drei unabhängige Reviews haben übereinstimmend Blocker gefunden. Sie sind
**noch nicht behoben** — wer das Feature scharf schaltet, sollte sie kennen.

1. **Eine einzige Äußerung hebt ihren eigenen Mute auf.** Teilergebnisse
   wiederholen die Phrase, bis die Erkennungs-Task erneuert wird. Der zweite
   Treffer wird übersprungen, der dritte gilt als Widerspruch und drückt erneut
   — nach ~6 s ist das Mikrofon wieder offen, die Anzeige sagt „stumm".
   Entprellt wird auf Wanduhrzeit statt auf der äußerungsrelativen Position,
   die `VoiceGateMatch.at` bereits liefert. `VoiceGateCoordinator.swift:232`
2. **Der verschmolzene Erkennungspfad umgeht beide Toleranzregeln.** Feste
   `maxDistance: 1` über das Gesamttoken — damit greifen `hannapause`,
   `annepause`, `annapausen` und `annawetter`, also genau die Fälle, die für
   die getrennte Form per Test ausgeschlossen sind.
   `VoiceGateCommandMatcher.swift:162`
3. **Verwaister Listener.** `start()` läuft nicht auf dem MainActor und setzt
   `isRunning` erst am Ende; ein Stop im falschen Moment verpufft, und das
   Mikrofon bleibt belegt — entgegen der Zusage im Einstellungs-Tab.
   `VoiceGateListener.swift:107/127/132`
4. **Der Beobachter für Gerätewechsel überlebt nur einen.** Er filtert auf die
   alte Engine, die beim Neubinden ersetzt wird. Ab dem zweiten Wechsel ist der
   Listener stumm, ohne Fehler und ohne Log. `VoiceGateListener.swift:212-240`
5. **Der Nachfass-Druck kann einen erfolgreichen Druck aufheben** und meldet
   trotzdem Erfolg. Die Signatur ist nachweislich unzuverlässig; ihr Ausbleiben
   als Beweis zu werten widerspricht dem eigenen Vorsatz in
   `CodexCommandExecutionProbe.swift:14-16`.

Kleinere, ebenfalls offen: Datenrennen auf `engine`/`recognizer`/`isRunning`
(die Sperre deckt nur `request`/`task`), Mitternachtswechsel im Log-Ordner,
`readTail` verwirft bei zerschnittenem UTF-8 den ganzen Puffer, Diktat-Pause
hängt am 10-s-Poll.

## Kill-Switch

```bash
defaults write com.whisperm8.app codexVoiceGateEnabled -bool NO
```

**Achtung:** Das Flag wird nur beim App-Start gelesen — eine *laufende* Instanz
stoppt es nicht. Sofort wirkt allein der Schalter im Einstellungs-Tab
(`VoiceGateCoordinator.setEnabled`).

## Dateien

- `WhisperM8/Services/VoiceGate/VoiceGateCommandMatcher.swift` — Phrasenerkennung (pur)
- `WhisperM8/Services/VoiceGate/VoiceGateStateMachine.swift` — Zustandslogik (pur)
- `WhisperM8/Services/VoiceGate/CodexVoiceSessionProbe.swift` — Gate
- `WhisperM8/Services/VoiceGate/VoiceGateListener.swift` — Audio + On-Device-Erkennung
- `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift` — Verdrahtung
- `WhisperM8/Views/VoiceGateMenuSection.swift` — Menüleiste
- `WhisperM8/Services/VoiceGate/CodexMuteToggler.swift` — Fokus-Roundtrip + CGEvent
- `WhisperM8/Services/VoiceGate/CodexCommandExecutionProbe.swift` — Ausführungs-Bestätigung
- `WhisperM8/Services/VoiceGate/VoiceGateLocaleResolver.swift` — Regionalvarianten
- `WhisperM8/Views/Settings/Pages/AgentChatsVoiceAgentTab.swift` — Einstellungs-Tab
- `Tests/WhisperM8Tests/CodexVoiceGateTests.swift` — 47 Tests der reinen Logik
