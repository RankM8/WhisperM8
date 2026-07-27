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
`Ctrl+Shift+U` als `CGEvent` → zurück zur vorherigen App. Gemessene Dauer steht
als `durationMs` im Log.

### Bestätigung und Fehlerfälle

Nach dem Druck sucht der `CodexCommandExecutionProbe` bis zu 1,5 s nach der
`response_routed … conversationId=null`-Signatur im Codex-Log. Sie ist eine
undokumentierte Interna und darf nichts blockieren:

- **Signatur da** → `confirmed=true`, Annahme übernommen.
- **Signatur fehlt** → nur eine Notiz. Der Druck gilt trotzdem als erfolgt,
  weil ein wegfallendes Log-Detail die Funktion nicht lahmlegen darf.
- **Mechanisches Scheitern** (Codex kam nicht in den Vordergrund, kein
  `CGEvent`) → echter Beleg, Zustand auf `unknown`, der nächste Befehl drückt
  in jedem Fall.

## Warum es so gebaut ist (Messungen vom 26.07.2026)

Ein Live-Spike gegen eine laufende Codex-Sitzung hat vier Dinge belegt:

| Frage | Ergebnis |
|---|---|
| Bleibt die Sitzung bei Mute verbunden? | **Ja** — kein Session-Event im Messfenster |
| Bekommt Codex im Mute-Zustand Audio? | **Nein** — 6 gesprochene Zahlen fehlten im Transkript |
| Hört ein paralleler Listener weiter? | **Ja** — Aufnahme am selben AirPods-Mikro, transkribierbar |
| Reicht ein Tastendruck ohne Fokus? | **Nein** — `CGEventPostToPid` blieb wirkungslos |

Daraus folgen die tragenden Entwurfsentscheidungen:

- **Kein Mute auf Geräte- oder Systemebene.** Das würde den Listener mit-taub
  machen. Gemutet wird ausschließlich in Codex selbst.
- **Der Listener bindet sein Eingabegerät explizit** (nie „System Default") und
  ist damit unabhängig von allem, was Codex mit seinem Eingang tut.
- **Der Fokus-Roundtrip ist unvermeidbar**, weil `realtimeVoice.toggleMicrophoneMute`
  in Codex `shortcutScope: app` hat. Ab Phase 2 relevant.

## Zustandslogik

Der Codex-Shortcut ist ein **blinder Toggle** — er schaltet um, verrät aber
nicht wohin, und der wahre Zustand ist von außen nicht lesbar. Die
Zustandsmaschine führt deshalb eine *Annahme* und macht sie dreifach robust:

1. **Absicht statt Toggle** — „Jarvis Pause" mutet nur, wenn wir offen glauben.
2. **Wiederholung überstimmt** — dieselbe Phrase binnen 4 s heißt „deine
   Annahme war falsch" und drückt trotzdem. Damit ist die Selbstkorrektur des
   Toggles zurück, ohne dessen Richtungs-Blindheit.
3. **Passiver Abgleich** — empfängt Codex nachweislich Sprache, ist die Annahme
   „stumm" widerlegt. Bewusst asymmetrisch: *ausbleibender* Empfang beweist
   nichts, der Mensch könnte einfach schweigen.

## Fehlalarm-Schutz

Gestaffelt, weil kein einzelnes Kriterium reicht:

- Trägerwort **und** Kommando, benachbart innerhalb 1,5 s
- mindestens 0,3 s Stille vor dem Trägerwort (kein Treffer mitten im Satz)
- Kommandowörter **exakt** — schon Editierdistanz 1 macht „Wetter" zu „weiter"
  und „Hause" zu „Pause" (von einem Unit-Test gefunden)
- Trägerwort mit Distanz 1, weil Erkenner den Eigennamen verbiegen
- Cooldown 2,5 s nach jeder Auslösung
- Gate: nur bei laufendem Codex mit plausibel aktiver Sprachsitzung
- pausiert, solange WhisperM8 selbst diktiert

Das Trägerwort allein löst nie aus — „sei mein Jarvis" fällt im Alltag beiläufig.

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

Ereignisse: `gate.arm_state`, `candidate.rejected reason=…`, `candidate.partial`,
`would_press intent=… reason=… confidence=…`. Die **Beinahe-Treffer** sind der
eigentliche Ertrag — sie zeigen datenbasiert, ob die Schwellen sitzen.

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

## Kill-Switch

```bash
defaults write com.whisperm8.app codexVoiceGateEnabled -bool NO
```

## Dateien

- `WhisperM8/Services/VoiceGate/VoiceGateCommandMatcher.swift` — Phrasenerkennung (pur)
- `WhisperM8/Services/VoiceGate/VoiceGateStateMachine.swift` — Zustandslogik (pur)
- `WhisperM8/Services/VoiceGate/CodexVoiceSessionProbe.swift` — Gate
- `WhisperM8/Services/VoiceGate/VoiceGateListener.swift` — Audio + On-Device-Erkennung
- `WhisperM8/Services/VoiceGate/VoiceGateCoordinator.swift` — Verdrahtung
- `WhisperM8/Views/VoiceGateMenuSection.swift` — Menüleiste
- `Tests/WhisperM8Tests/CodexVoiceGateTests.swift` — 27 Tests der reinen Logik
