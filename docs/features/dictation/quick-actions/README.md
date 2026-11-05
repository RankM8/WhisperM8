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
  (`QuickActionShortcuts.resolveCorrectDefault`). Bestehende Nutzer bekommen ⇧⌘K ebenso, solange
  sie für Korrigieren nichts anderes gespeichert haben. Wer ihn entfernt,
  bekommt ihn nicht ungefragt zurück; einen Vorschlag-Knopf gibt es für
  Korrigieren nicht, man nimmt ihn im Recorder neu auf. Besser formulieren und
  alle anderen Modi sind ab Werk leer; für Besser formulieren steht ⌃⌥R als
  Vorschlag mit „übernehmen“ daneben. Belegt ein
  Kurzbefehl schon einen anderen WhisperM8-Kurzbefehl, steht eine Warnung
  darunter (der Recorder prüft selbst nur System und Hauptmenü). Das gilt
  auch umgekehrt: Die Recorder für Aufnahme-Hotkey, Zwischenablage-Verlauf und
  Notch (`SettingsKeyRecorderRow`) und der Hotkey-Schritt im Onboarding warnen,
  wenn eine Schnellaktion dieselbe Taste hat (`QuickActionShortcuts.quickActionUsing`),
  etwa wer dort ⇧⌘K aufnimmt.
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
  - Weitergearbeitet, während die Nacharbeit lief: Ist eine andere App vorn
    oder (bei Feldern mit Accessibility) etwas anderes markiert, wird nicht
    eingefügt. Das Ergebnis liegt dann in der Zwischenablage, mit Hinweis im
    Overlay. Bei Text aus dem Cmd+C-Rückfall lässt sich die Markierung nicht
    nachlesen, dort zählt nur die vordere App. Antwortet die App beim
    Nachlesen nicht (Zeitlimit 0,25 s, dann noch einmal 0,5 s), ist das
    unklar, nicht „geändert“: Sie ist noch vorn, also wird eingefügt. Sonst
    verlöre der Nutzer bei einer ausgelasteten App (großes Dokument) seine
    Zwischenablage, ohne etwas angefasst zu haben. Ein anderer Text oder ein
    Fokus ohne Markierung bleibt „geändert“.
  - Esc oder ✕ brechen ab, das Overlay geht sofort weg, nichts wird ersetzt.
    Die Sperre gegen Diktat und zweite Schnellaktion ist sofort frei, auch
    wenn der abgebrochene Weg noch ausläuft (Codex bis 3 s); sein spätes
    Ergebnis wird verworfen und fasst weder Overlay noch Esc an.
    Esc ist nur während der Nacharbeit belegt, beim Einfügen schon wieder frei.
  - Ohne Bedienungshilfen-Recht: Systemabfrage und Hinweis „Erst
    Bedienungshilfen für WhisperM8 erlauben“.
  - Ergebnis gleich der Markierung: Hinweis „Nichts zu ändern“, kein Einfügen.
  - Nach dem Ersetzen kommt der alte Inhalt der Zwischenablage zurück, aber
    nur, wenn das sicher ist (Abschnitt „Zurücklegen der Zwischenablage“).
    Sonst bleibt das Ergebnis dort, mit Hinweis „Das Ergebnis liegt auch in
    der Zwischenablage“. Ergebnis und Original stehen zusätzlich im
    Zwischenablage-Verlauf, gekennzeichnet als Schnellaktion, nicht als Diktat.
  - Fehler (beide Wege gescheitert, leeres Ergebnis, nicht eingefügt): Hinweis
    im Overlay (4 s) und zusätzlich eine Mitteilung mit Details. Die Mitteilung
    allein ginge unter Fokus oder ohne Erlaubnis still verloren. Die Markierung
    bleibt.
  - Während ein Diktat läuft, wird eine Schnellaktion mit dem Busy-Ton
    abgewiesen und umgekehrt.
  - Im Umfang „Nur Diktat“ gibt es keine Nacharbeit, also auch keine
    Schnellaktion: Die Kurzbefehle sind dann systemweit abgemeldet (⇧⌘K
    gehört wieder Slack, Xcode, Finder), gespeichert bleiben sie; beim Wechsel
    des Umfangs meldet `QuickActionHotkeys.applyScope` sie wieder an. Das
    läuft nur beim echten Wechsel, nicht bei jeder anderen Einstellung. Einen
    frisch aufgenommenen Kurzbefehl meldet die Bibliothek sofort an; die App
    hört auf ihre Meldung (`KeyboardShortcuts_shortcutByNameDidChange`) und
    meldet bei „Nur Diktat“ genau diesen wieder ab. Kein Menüeintrag.

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
| `SelectedContextService.captureForQuickAction` | Markierung per Accessibility, sonst Cmd+C-Rückfall mit Zurücklegen. Vor dem Cmd+C wartet sie bis 0,5 s, bis ⇧, ⌘, ⌥ und ⌃ des Kurzbefehls losgelassen sind (`waitForModifierRelease`), sonst käme womöglich ⇧⌘C an. Ist WhisperM8 selbst vorn, liest sie das `NSTextView` direkt (`ownTextSelection`): eine AX-Anfrage an sich selbst müsste der wartende Main Thread beantworten und lief ins Zeitlimit. Anders als der Diktat-Kontext unabhängig vom Schalter „markierten Text als Kontext“: der Nutzer übergibt die Markierung hier ausdrücklich. Der Text bleibt unverändert. |
| `SelectionWritability` | Nur wenn das fokussierte Element die Markierung selbst liefert, zählt sein Urteil: `writable`, wenn `AXSelectedText` oder `AXValue` setzbar ist, sonst `readOnly`. Kam der Text über den Cmd+C-Rückfall (Electron ohne volle Accessibility: Slack, Notion), ist es `unknown`, und es wird eingefügt. Das Element bekommt wie die App 0,5 s Zeitlimit. |
| `QuickActionTargetCheck` (über `RecordingCoordinator.isQuickActionTargetUnchanged`) | Vor dem Einfügen: vordere App noch dieselbe, bei `writable` dieselbe Markierung (fremde Apps abseits des Main Threads gefragt, 0,25 s, ohne Antwort noch einmal 0,5 s; `SelectionReadout` trennt „keine Antwort“ von „nichts markierbar“). |
| `QuickActionReplacer` | Snapshot der Zwischenablage (bis 8 MB, off-main), Cmd+V über `PasteService`, dann den alten Inhalt zurück nach `QuickActionRestoreRule`, geklammert mit `ClipboardInternalWrites.begin/end` und `claim`. Nie zurück, wenn inzwischen jemand anderes kopiert hat oder der Inhalt ein Passwort war. Ergebnis `QuickActionPasteResult`: `pasted`, `pastedResultKept`, `notPasted`. |
| `QuickActionShortcuts`, `QuickActionHotkeys` | Name je Modus `quickAction.<modeID>`, Vorschläge, Konfliktprüfung in beide Richtungen; meldet beim Start und bei neuen Modi je einen Handler an und folgt dem Umfang (`applyScope`). Löschen eines eigenen Modus gibt seinen Kurzbefehl frei. |
| `OverlayController.showQuickActionWorking/Hint` | Eigene Pill-Ansicht: Kern im Improve-Puls, sichtbarer Text, ✕. Der Hinweis verschwindet nach 2 bis 4 s. |

## Zurücklegen der Zwischenablage

Cmd+V legt das Ergebnis in die Zwischenablage. Ob die Ziel-App es gelesen
hat, sagt einem niemand. Liest sie spät (Remote Desktop, VM, ausgelastetes
Electron) und der alte Inhalt ist schon zurück, landet er statt des
Ergebnisses in der Markierung. Darum kommt der alte Inhalt nur zurück, wenn
das sicher ist (`QuickActionRestoreRule`):

- **Feld mit Accessibility (`writable`):** WhisperM8 liest die Markierung bis
  zu 2 s lang alle 100 ms nach. Ist sie nicht mehr der ursprüngliche Text, hat
  die App eingefügt und die Zwischenablage gelesen: zurücklegen. Bleibt sie
  gleich oder unlesbar, bleibt das Ergebnis in der Zwischenablage.
- **Text aus dem Cmd+C-Rückfall (`unknown`) und „Korrigieren & einfügen“:**
  nicht prüfbar. Nach 800 ms zurücklegen nur, wenn das Ergebnis im Verlauf
  steht (Verlauf an, nicht pausiert, App nicht ausgeschlossen); dann sind
  Ergebnis und Original dort sicher. Sonst bleibt das Ergebnis in der
  Zwischenablage und geht nicht verloren, falls Cmd+V ins Leere ging.

Bleibt das Ergebnis in der Zwischenablage, zeigt das Overlay „Das Ergebnis
liegt auch in der Zwischenablage“. Die vorherige Kopie steht dann (bei
eingeschaltetem Verlauf) im Verlauf.

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
dasselbe. Beim Diktat gilt dasselbe für Korrigieren und Besser formulieren mit
Markierung (dort ist die Markierung der Text); in allen anderen Fällen läuft
der Filter (Regeln: [AI Output](../ai-output/README.md)).

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
    Auch der Klick (und ⇧⌘K in WhisperM8) liest dann direkt aus dem Textfeld,
    ohne Accessibility-Anfrage an den eigenen Prozess.

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
  Änderung; das Ergebnis steht dann im Zwischenablage-Verlauf (⇧⌘C) oder, bei
  ausgeschaltetem Verlauf, in der Zwischenablage.
- Editoren, in denen Cmd+C ohne Auswahl die ganze Zeile kopiert (VS Code,
  Cursor, Windsurf, JetBrains, Sublime, Zed; `ClipboardCopyFallbackPolicy`),
  haben keinen Cmd+C-Rückfall. Dort klappt die Schnellaktion nur, wenn die App
  die Markierung per Accessibility herausgibt, sonst kommt „Erst Text
  markieren“. In VS Code verdeckt ⇧⌘K außerdem „Zeile löschen“.
- Ob ein gehaltenes ⇧ ein Cmd+C wirklich zu ⇧⌘C macht, ist nicht bewiesen;
  das Warten auf losgelassene Tasten ist Vorsorge (Handtest unten).

## Handtests

- Slack oder Notion: Text markieren, ⇧⌘K etwas länger gedrückt halten. Erwartet:
  die Markierung wird korrigiert, der Zwischenablage-Verlauf öffnet sich nicht.
- Mail: Absatz markieren, ⇧⌘K, während „Korrigiere…“ einen anderen Satz
  markieren. Erwartet: nichts wird ersetzt, Hinweis „Die Markierung hat sich
  geändert“, Ergebnis mit Cmd+V einfügbar.
- Umfang „Nur Diktat“: ⇧⌘K in Slack öffnet wieder „Alle Direktnachrichten“.
  Zurück auf „Mit KI“: ⇧⌘K korrigiert wieder.
- ⇧⌘K, sofort Esc, direkt danach diktieren: Aufnahme startet ohne Busy-Ton.
- Verlauf aus, Text in Slack markieren, ⇧⌘K: danach liegt das Ergebnis in der
  Zwischenablage (Hinweis im Overlay).
- In VS Code: ⇧⌘K auf markiertem Text prüfen (AX-Markierung oder „Erst Text
  markieren“), und dass „Zeile löschen“ dort verdeckt ist.

Tests: `QuickActionRunnerTests`, `QuickActionModesTests`, `ClipboardQuickActionTests`,
`QuickActionReplacerTests`, `QuickActionHotkeyReviewTests`, `QuickActionModifierWaitTests`, `QuickActionTargetCheckTests`,
`ClipboardQuickActionEntryTests`.
