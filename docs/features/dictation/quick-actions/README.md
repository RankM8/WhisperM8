---
status: aktiv
updated: 2026-11-05
---

# Schnellaktionen: Markierung ohne Diktat umarbeiten

Text in einer beliebigen App markieren, Kurzbefehl drücken, fertig. WhisperM8
arbeitet die Markierung mit einem Modus um und ersetzt sie, ohne Aufnahme.
⌘Z in der Ziel-App macht es rückgängig, weil das Ersetzen ein normales Cmd+V
ist.

Entschieden von Giuliano am 05.11.2026. Das Zwischenablage-Fenster (⇧⌘C)
nutzt denselben Ablauf (Abschnitt unten). Noch offen als eigener Schritt: das
stille Diktat (Diktat starten, nichts sagen, ✓ korrigiert die Markierung).

## Für Nutzer

- **Kurzbefehl je Modus:** KI-Ausgabe → Modi → Abschnitt „Kurzbefehl ohne
  Diktat“. Gilt für jeden Modus mit Nacharbeit, auch E-Mail, Slack und eigene
  Modi; nicht für „Fast“ (der arbeitet nichts nach). Ab Werk belegt ist nur
  Korrigieren mit **⇧⌘K** (Entscheidung Giuliano, 05.11.2026). Weder macOS
  noch WhisperM8 nutzen ⇧⌘K; als globaler Kurzbefehl überdeckt er aber
  gleichnamige Befehle einzelner Apps (Xcode „Clean Build Folder“, VS Code
  „Zeile löschen“). Ist ⇧⌘K beim ersten Start schon anders vergeben
  (Aufnahme-Hotkey, anderer Modus), setzt die App den Standard nicht
  (`QuickActionShortcuts.resolveCorrectDefault`). Wer ihn entfernt, bekommt ihn nicht ungefragt zurück; dann
  steht ⇧⌘K als Vorschlag mit „übernehmen“ daneben. Für Besser formulieren
  wird ⌃⌥R vorgeschlagen, alle anderen Modi sind leer. Belegt ein
  Kurzbefehl schon einen anderen WhisperM8-Kurzbefehl, steht eine Warnung
  darunter (der Recorder prüft selbst nur System und Hauptmenü).
- **Menüleiste:** „Markierung korrigieren“ (Modus Korrigieren), mit dem
  Kurzbefehl in Klammern, falls einer gesetzt ist.
- **Zwei neue feste Modi:**
  - *Korrigieren* (`correct`): nur Rechtschreibung, Grammatik, Zeichensetzung.
    Wortwahl, Ton und Sprache bleiben.
  - *Besser formulieren* (`rephrase`): klarer und flüssiger, gleiche Aussage,
    gleiche Sprache, etwa gleiche Länge.

  Beide stehen auch beim Diktat in der Modusauswahl. Ist dabei Text markiert,
  ist die Markierung der Text und das Gesprochene eine Zusatzanweisung
  („und etwas förmlicher“). Ohne Markierung arbeiten sie das Gesprochene um.
- **Verhalten:**
  - Nichts markiert: kurzer Hinweis „Erst Text markieren“ im Overlay.
  - Feld nicht beschreibbar (Webseite, PDF): Ergebnis in die Zwischenablage,
    Hinweis im Overlay.
  - Esc oder ✕ brechen ab, das Overlay geht sofort weg, nichts wird ersetzt.
    Esc ist nur während der Nacharbeit belegt, beim Einfügen schon wieder frei.
  - Ohne Bedienungshilfen-Recht: Systemabfrage und Hinweis „Erst
    Bedienungshilfen für WhisperM8 erlauben“.
  - Ergebnis gleich der Markierung: Hinweis „Nichts zu ändern“, kein Einfügen.
  - Nach dem Ersetzen liegt wieder der alte Inhalt in der Zwischenablage.
    Ergebnis und Original stehen zusätzlich im Zwischenablage-Verlauf.
  - Fehler (beide Wege gescheitert): Mitteilung, die Markierung bleibt.
  - Während ein Diktat läuft, wird eine Schnellaktion mit dem Busy-Ton
    abgewiesen und umgekehrt.
  - Im Umfang „Nur Diktat“ gibt es keine Nacharbeit, also auch keine
    Schnellaktion (Hinweis im Overlay, kein Menüeintrag).

## Ablauf

```text
Kurzbefehl / Menüleiste
  → AppState.runQuickAction(modeID:)
  → QuickActionRunner.run
      Markierung lesen (SelectedContextService.captureForQuickAction)
      Overlay „Korrigiere…“ + Esc anmelden
      PostProcessingService.processRun   (GPT-Backend, Rückfall Codex)
      Ersetzen (QuickActionReplacer) oder Zwischenablage
```

| Baustein | Aufgabe |
|---|---|
| `QuickActionRunner` | Ablauf, Abbruch, Entscheidungen. Alle Systemzugriffe über `QuickActionEnvironment` (Closures), Anzeige über `QuickActionPresenting`. Kennt keine Kurzbefehle; Menüleiste und Zwischenablage-Fenster rufen ihn genauso auf. Eingang `QuickActionInput`: Markierung oder vorgegebener Text. |
| `RecordingCoordinator+QuickAction` | Verdrahtet den Runner mit den echten Diensten und dem Overlay. Gemeinsame Sperre mit dem Diktat (`isDictationBusy`, `quickActionRunner.isRunning`). |
| `SelectedContextService.captureForQuickAction` | Markierung per Accessibility, sonst Cmd+C-Rückfall mit Zurücklegen. Anders als der Diktat-Kontext unabhängig vom Schalter „markierten Text als Kontext“: der Nutzer übergibt die Markierung hier ausdrücklich. Der Text bleibt unverändert. |
| `SelectionWritability` | Nur wenn das fokussierte Element die Markierung selbst liefert, zählt sein Urteil: `writable`, wenn `AXSelectedText` oder `AXValue` setzbar ist, sonst `readOnly`. Kam der Text über den Cmd+C-Rückfall (Electron ohne volle Accessibility: Slack, VS Code, Notion), ist es `unknown`, und es wird eingefügt. Das Element bekommt wie die App 0,5 s Zeitlimit. |
| `QuickActionReplacer` | Snapshot der Zwischenablage (bis 8 MB, off-main), Cmd+V über `PasteService`, nach 800 ms den alten Inhalt zurück, geklammert mit `ClipboardInternalWrites.begin/end` und `claim`. Nicht zurück, wenn inzwischen jemand anderes kopiert hat oder der Inhalt ein Passwort war. |
| `QuickActionShortcuts`, `QuickActionHotkeys` | Name je Modus `quickAction.<modeID>`, Vorschläge, Konfliktprüfung; meldet beim Start und bei neuen Modi je einen Handler an. Löschen eines eigenen Modus gibt seinen Kurzbefehl frei. |
| `OverlayController.showQuickActionWorking/Hint` | Eigene Pill-Ansicht: Kern im Improve-Puls, sichtbarer Text, ✕. Der Hinweis verschwindet nach 2 bis 4 s. |

## Prompt

Die Markierung geht als `rawText` in denselben Weg wie ein Transkript, ohne
Kontextbündel und mit leerer Sprache („auto“), damit sie ihre Sprache behält.
`PostProcessingInputSource.current = .selection` (Task-Local) lässt
`PromptPackageBuilder` einen Abschnitt „Input Source“ einfügen: der Text ist
markiert, nicht gesprochen, und das Ergebnis ersetzt die Markierung. So gilt
der Hinweis auf beiden Wegen, ohne dass sich die `PostProcessing`-Schnittstelle
ändert. Codex- und Backend-Läufe laufen unter `CodexRunOwner.quickAction`;
Esc und ✕ brechen nur diese ab.

Der Rückfall auf Codex und die Fehlerregeln kommen unverändert aus
`PostProcessingEngineRouter` (siehe [AI Output](../ai-output/README.md)).
Leerzeichen und Zeilenumbrüche am Rand der Markierung setzt
`QuickActionText.replacement` wieder an, weil Modelle sie abschneiden.
Gedankenstriche, die schon in der Markierung standen, bleiben: der
`DashFilter` läuft bei der Schnellaktion nur, wenn die Markierung selbst keine
hatte (`PostProcessingService.keepsDashes`), und der Prompt sagt dem Modell
dasselbe. Beim Diktat gilt der Filter wie bisher.

## Im Zwischenablage-Fenster (⇧⌘C)

Beides nutzt immer den Modus Korrigieren (Entscheidung Giuliano, 05.11.2026:
kein Modus-Menü) und erscheint nur, wenn der Umfang Nacharbeit erlaubt.

- **Kopfzeile „Markierung korrigieren“** unter dem Suchfeld. Beim Öffnen
  fragt das Fenster die App davor per Accessibility nach ihrer Markierung
  (`SelectedContextService.probeSelection`, abseits des Main Threads, 0,25 s
  Zeitlimit, nie Cmd+C). Ergebnis `SelectionProbe`:
  - `selected`: Kopfzeile mit dem Anfang der Markierung („Markiert in Mail“).
  - `unknown` (Electron ohne volle Accessibility, kein Fokus-Element): Kopfzeile
    ohne Vorschau („Text markiert in Slack?“). Ein Klick liest dann per
    Cmd+C-Rückfall. Nur, wenn der Rückfall dort auch geht (Bedienungshilfen
    erlaubt, kein Editor aus `ClipboardCopyFallbackPolicy`), und nicht bei
    Listen und Dateiansichten wie dem Finder (`textLikeRoles`).
  - `none` (App meldet ausdrücklich: nichts markiert): keine Kopfzeile.
  - Ist WhisperM8 selbst die App davor, liest das Fenster die Markierung des
    Textfelds direkt, bevor es Key wird; im Chat-Terminal gibt es keine Kopfzeile.

  Der Knopf schließt das Fenster und startet nach 150 ms denselben Ablauf wie
  ⇧⌘K. Auch ⇧⌘K bei offenem Fenster schließt es erst
  (`AppState.runQuickAction`).
- **„Korrigieren & einfügen“** am gewählten Text-Eintrag (Knopf in der
  Vorschau oder ⌘↩): Fenster zu, vollen Text laden (lange Texte liegen in einer
  Datei), korrigieren und an der Schreibmarke der App davor einfügen
  (`QuickActionInput.text`). Anders als bei einer Markierung wird auch ein
  schon richtiger Text eingefügt, dann ohne zweiten Verlaufseintrag. Klappt das
  Einfügen nicht, liegt das Ergebnis in der Zwischenablage. Bilder und Dateien
  haben den Knopf nicht.
- Wird das Fenster während der Nacharbeit wieder geöffnet, schließt die App es
  vor dem Einfügen, sonst landete Cmd+V in seinem Suchfeld.

Verdrahtung: `ClipboardHistoryController.quickActions` (gesetzt in
`WhisperM8App`), Zustand im `ClipboardHistoryViewModel`
(`quickActionsAvailable`, `selectionProbe`, `canCorrect`).

## Bewusste Grenzen

- Kein Diktat-Bericht (Run-Report) für Schnellaktionen, nur die Logzeile
  `quick_action mode=… outcome=…`.
- Modi mit „Kontext erforderlich“ scheitern bei der Schnellaktion mit einer
  Meldung, weil sie ohne Kontextbündel laufen.
- Bei `unknown` und einem Feld, das Cmd+V still ignoriert, sieht man keine
  Änderung; das Ergebnis steht dann im Zwischenablage-Verlauf (⇧⌘C).

Tests: `QuickActionRunnerTests`, `QuickActionModesTests`, `ClipboardQuickActionTests`.
