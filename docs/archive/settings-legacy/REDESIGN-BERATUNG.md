---
description: Redesign-Beratung für das Settings-Fenster — Befunde, Varianten, Empfehlung
description_long: |
  Synthese aus den 15 validierten Settings-Referenzdokumenten: übergreifende
  Befunde (Redundanzen, Fehlplatzierungen, echte Code-Inkonsistenzen),
  drei Neustruktur-Varianten mit Bewertung und eine klare Empfehlung
  inklusive Quick Wins, die unabhängig von der Varianten-Wahl sinnvoll sind.
updated: 2026-07-06 10:20
status: 📋 Beratungsgrundlage — Entscheidung ausstehend
---

# Settings-Redesign: Beratung

Grundlage: die 15 validierten Referenz-Docs in diesem Ordner (Erstellung durch
Codex-Subagents, Gegenprüfung durch Opus-Validatoren, alle Befunde mit
Datei:Zeile belegt). Diese Beratung fasst die übergreifenden Probleme zusammen
und schlägt drei Umbau-Varianten vor.

## 1. Ist-Zustand in Zahlen

| Seite | Controls | Kernproblem |
|---|---|---|
| Transcription API | 10 | Language wirkt weit über die Seite hinaus; kein Key-Löschen-Flow |
| Codex / ChatGPT | 16 | Status-Redundanz (3 Orte), Global-vs-Override unklar |
| Output Overview | 14 | Dashboard, keine Settings-Seite; vergisst History nach Neustart |
| History | 11 | Archiv/Nutzdaten, keine Settings-Seite; Delete ohne Bestätigung |
| Modes | 21 | Dichtester Editor; überschneidet Templates + Codex-Seite |
| Templates | 10 | Nutzung liegt auf Modes; Platzhalter unvollständig sichtbar |
| Test Lab | 7 | Felder ohne Labels; testet Kontext-Modi nur textbasiert |
| Agent Chats | 6 | Winzige Seite fürs größte Feature; viele Prefs ohne UI |
| Claude Code | 13 | Dicht; Abgrenzung zu Agent Chats nur einseitig erklärt |
| Permissions | 5 | Header-Text irreführend; Onboarding dupliziert Logik |
| Hotkey | 1 | Verwandte Optionen (Confirm-Button) liegen auf Behavior |
| Audio | 1 | Fast leer; Ducking liegt auf Behavior |
| Behavior | 15 | Sammelbecken: Profil, Theme, Paste, Kontext, Ducking, Overlay, Login |
| CLI & Skill | 18 | In „App", gehört fachlich halb zu „Agents" |
| About | 6 | updateCheckEnabled existiert ohne UI; lastCheckedAt unsichtbar |

**Gesamt: ~154 dokumentierte Controls auf 15 Seiten in 4 Gruppen.**

## 2. Übergreifende Befunde

### B1 — Gruppierung nach Code-Herkunft statt Nutzer-Aufgabe
„Behavior" bündelt 8 Themen, während „Audio" und „Hotkey" je 1 Control haben.
Der Nutzer-Flow „Aufnahme konfigurieren" berührt heute 4 Seiten (Hotkey,
Audio, Behavior, Permissions); der Flow „KI-Ausgabe konfigurieren" berührt 3
(Codex, Modes, Templates).

### B2 — Zwei Seiten sind gar keine Settings
Output Overview (Dashboard) und History (Archiv mit Suche/Löschen) verwalten
Nutzdaten, keine Konfiguration. Sie blähen die Sidebar auf und verwässern die
Erwartung „hier stelle ich etwas ein".

### B3 — Echte Redundanzen (gleicher Key, mehrere Orte)
- `defaultOutputModeID`: schreibbar in Overview **und** Modes — mit
  **inkonsistentem Fallback** (`cleanID` in Overview/AppPreferences vs.
  `rawID` in OutputModesView) → faktischer Bug, von zwei Validatoren
  unabhängig bestätigt.
- `showModePickerInMiniOverlay`: Toggle doppelt in Modes („Show mode chip…")
  und Behavior („Show mode picker…") — unterschiedliche Labels, gleicher Key.
- Codex-Status + „Check Again": dreifach (Codex-Seite, Overview, Onboarding).
- Permissions-Logik: Settings nutzt `PermissionService`, Onboarding
  implementiert TCC-Aufrufe selbst (eigene Timer, 0,5 s vs. 1,0 s).

### B4 — Fehlplatzierte Einzeloptionen
- Audio-Ducking (Systemlautstärke) → liegt auf Behavior statt Audio.
- Confirm-Button (= alternativer Hotkey-Stop, laut Hilfetext „same as the
  hotkey") → Behavior statt Hotkey/Aufnahme.
- Language → auf der Transcription-API-Seite, wirkt aber auch auf Codex-
  Post-Processing und Test Lab.
- Fallback-to-Fast-Toggle → auf Modes, beeinflusst aber Test Lab und die
  Privacy-Erklärung der Codex-Seite.

### B5 — Unsichtbare/verwaiste Einstellungen
In `AppPreferences` existieren persistierte Werte ohne Settings-UI:
`updateCheckEnabled`, Auto-Summary, Event-driven Watch, Metal-Renderer,
Sidebar-Drag u.a. — teils bewusste Kill-Switches, aber nirgends gesammelt
sichtbar (nur `defaults write`).

### B6 — Sprachmix DE/EN
Durch alle 15 Docs bestätigt: englische Seiten (Codex, Overview, History,
Audio, Hotkey), deutsche Abschnitte (Claude Code, Agent Chats teilweise),
gemischte Seiten (Behavior: „Erscheinungsbild" neben „Usage"). Onboarding und
Settings benennen denselben Hotkey verschieden („Recording key" vs.
„Recording Hotkey").

### B7 — Irreführende Mikro-Texte
- Permissions-Header „All system permissions are active", obwohl Screen
  Recording nicht in `allGranted` zählt.
- Codex-Picker „Video", obwohl technisch Frames als `--image` gesendet werden.
- Preiszeile ($0.002/min) hart codiert, ohne Quelle/Stand.

## 3. Varianten

### Variante A — „Aufgaben-Struktur" (Empfehlung)

Sidebar neu nach Nutzer-Aufgaben, 15 → 10 Seiten:

```
Diktat
  1. Aufnahme          ← Hotkey + Confirm-Button + Input Device + Ducking
                          + Overlay (Stil, Position, Mode-Chip)
  2. Transkription     ← Provider, Model, API-Key; Language hier, mit
                          Hinweis „gilt auch für KI-Ausgabe"
  3. KI-Ausgabe        ← Codex-Login/Status + globale Defaults + MODES
                          (Master-Detail) + Templates als Unterbereich/Tab
                          + Fallback-Toggle; Test Lab als Tab „Testen"
  4. Kontext & Datenschutz ← Selected Context, Visual Context (Screenshots/
                          Clips, Limits, Löschen), Privacy-Erklärung
Agents
  5. Agent Chats       ← heutige Seite + Benachrichtigungen/Töne ALLER
                          Provider + Claude-Hooks als Abschnitt (heutige
                          „Claude Code"-Seite wird DisclosureGroup/Abschnitt)
  6. CLI & Skills      ← unverändert, zieht von „App" zu Agents
App
  7. Allgemein         ← Profil, Theme, Auto-Paste, Start at Login,
                          Update-Check-Toggle
  8. Berechtigungen    ← unverändert + Header-Fix
  9. Über              ← + lastCheckedAt sichtbar
Arbeitsbereich (kein Settings-Charakter mehr)
 10. Output            ← Overview + History fusioniert: letzter Run oben,
                          Archivliste darunter (eine Seite, ein mentales
                          Modell); optional später eigenes Fenster
```

**Pro:** Jeder Nutzer-Flow ist eine Seite; Sammelbecken Behavior verschwindet;
Modes/Templates/Codex-Konzeptbruch aufgelöst; Redundanzen strukturell beseitigt.
**Contra:** Größter Umbau; Migrationsaufwand bei Deep-Links
(`WindowRequestCenter`-Routen, Onboarding-Verweise); Nutzer müssen sich neu
orientieren.

### Variante B — „Minimalinvasive Bereinigung"

Seitenstruktur bleibt, nur Umzüge und Merges, 15 → 12:

- Ducking → Audio; Confirm-Button + Overlay-Sections → Hotkey (umbenannt
  „Aufnahme"); Behavior schrumpft auf Profil/Theme/Paste/Kontext/Login.
- Overview + History → eine Seite „Output".
- Claude Code → Abschnitt innerhalb Agent Chats.
- Mode-Chip-Toggle nur noch in Modes; `defaultOutputModeID` nur noch in Modes.

**Pro:** Wenig Code-Risiko, jede Änderung einzeln shipbar, schnelle spürbare
Verbesserung.
**Contra:** Modes/Templates/Codex-Fragmentierung bleibt; „Behavior" bleibt als
diffuser Name; löst B1 nur teilweise.

### Variante C — „Settings sind nur Settings" (radikal)

Wie A, aber Output-Dashboard, History und Test Lab verlassen das
Settings-Fenster komplett und werden ein Bereich im Hauptfenster (neben Agent
Chats, z.B. als „Output"-Tab). Settings schrumpfen auf 7–8 reine
Konfigurationsseiten.

**Pro:** Konzeptionell am saubersten; History/Reports bekommen den Platz, den
ein Arbeitsbereich verdient (Timeline-Ansicht wie bei Transcripts denkbar).
**Contra:** Berührt Fenster-Architektur (Scenes, WindowRequestCenter);
deutlich größerer Scope; sollte eher Folge-Projekt nach A sein.

## 4. Empfehlung

**Variante A, umgesetzt in zwei Stufen:**

1. **Stufe 1 = Quick Wins (sofort, unabhängig von allem):**
   - `defaultOutputModeID`-Fallback vereinheitlichen (ein Ort der Wahrheit:
     `AppPreferences`; Views lesen nur noch darüber) — Bugfix.
   - Doppelten Mini-Overlay-Toggle entfernen (nur Overlay-/Aufnahme-Kontext).
   - Permissions-Header-Text korrigieren.
   - Onboarding auf `PermissionService` umstellen (eine Statusquelle).
   - Sprachentscheidung treffen (eine UI-Sprache konsequent — Empfehlung:
     Englisch als Basis, da >80 % der Labels schon englisch sind; Deutsch
     später via Lokalisierung statt Mischtexte).
   - `updateCheckEnabled` als Toggle + lastCheckedAt auf About.
2. **Stufe 2 = Struktur-Umbau nach Variante A**, beginnend mit der
   Diktat-Gruppe (Aufnahme + KI-Ausgabe sind die größten Schmerzpunkte),
   danach Agents-Merge, zuletzt Output-Fusion.

Variante C als optionaler dritter Schritt, wenn sich die Output-Seite als
Arbeitsbereich bewährt.

## 5. Offene Produktentscheidungen

1. UI-Sprache: konsequent Englisch, konsequent Deutsch, oder Lokalisierung?
2. Soll „Output" (Overview+History) mittelfristig aus den Settings raus
   (Variante C)?
3. Sollen versteckte Kill-Switches (Event-Watch, Metal-Renderer, …) eine
   „Erweitert"-Seite bekommen oder bewusst unsichtbar bleiben?
4. Test Lab: als Tab in „KI-Ausgabe" integrieren oder eigenständig lassen?
