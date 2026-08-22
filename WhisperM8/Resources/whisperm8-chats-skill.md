---
name: whisperm8-chats
description: Alle WhisperM8-Agent-Sessions sehen und verwalten (Jarvis-Supervisor über die whisperm8-CLI). Nutzen bei "was machen meine Chats", "Status meiner Sessions", "wartet was auf mich", "schick an Chat X", "antworte dem …-Chat", "starte einen Chat in Projekt Y", "räum meine Sessions auf", "sei mein Jarvis", "überwache meine Chats", "sag Bescheid wenn ein Chat fertig ist", "unterbrich Chat X". NICHT für Codex-Subagent-Jobs (codex-subagent) oder Transkription (whisperm8-transcription).
---

# WhisperM8 Chats — Sessions sehen und verwalten

Du kannst über `whisperm8 chats` alle Agent-Sessions des Users sehen und
verwalten (das „Jarvis"-Feature). Du läufst selbst in einer dieser Sessions
(`WHISPERM8_SESSION_ID`) — in Ausgaben bist du als `(du)` markiert; an dich
selbst senden geht technisch nicht.

**Lese-Befehle** funktionieren immer (auch bei geschlossener App — Status wird
dann aus den Transcripts geschätzt). **Handeln-Befehle** brauchen die laufende
App; ohne sie kommt Exit 5 mit klarem Hinweis.

## Verfügbarkeit

```bash
whisperm8 chats help          # zeigt alle Befehle; wenn "command not found":
                              # WhisperM8-App einmal starten (legt den Symlink an)
```

## Befehle (Kurzreferenz)

Lesen (immer erlaubt, ohne Rückfrage):
```bash
whisperm8 chats overview [--json]                    # Lagebild, attention-sortiert
whisperm8 chats list [--project P] [--status S] [--scope active|recent|all] \
                     [--open] [--pinned] [--all] [--json]
whisperm8 chats show <ref> [--json]
whisperm8 chats tail <ref> [--turns N] [--chars N] [--raw] [--json]
whisperm8 chats wait [--ref R]… [--until attention|idle|statusChange] \
                     [--since REV] [--timeout SEC] [--json]     # blockiert bis Ereignis
whisperm8 chats audit [--limit N] [--session <ref>]
whisperm8 chats archived [query] [--project P] [--group G] [--provider claude|codex] \
                         [--since 30d|2026-06-01] [--until D] [--content "text"] [--json]
```

Handeln (App muss laufen — sonst Exit 5). **Vor jeder dieser Aktionen: Regeln unten beachten.**
```bash
whisperm8 chats send <ref> -- "<prompt>"  [--if-status S,S] [--no-submit] [--force]
whisperm8 chats enqueue <ref> -- "<prompt>"          # Folgeauftrag vormerken (auch bei working)
whisperm8 chats queue [<ref>]                        # was wartet? (auch bei geschlossener App)
whisperm8 chats dequeue <ref> --all | --id <UUID>    # offene Aufträge stornieren
whisperm8 chats interrupt <ref> [--force] [--clear-input]
                                                     # ein ESC an eine working-Session. --clear-input
                                                     # leert danach den Composer (Ctrl+C) — nutzen, wenn
                                                     # ein zugestellter Auftrag ZURÜCKGEZOGEN wird (die
                                                     # CLI legt den Prompt sonst dorthin zurück); löscht
                                                     # auch User-Entwürfe, deshalb opt-in
whisperm8 chats open <ref>                           # Tab fokussieren (startet NICHT neu)
whisperm8 chats close <ref> [<ref>…]                 # NUR den UI-Tab schließen (nicht destruktiv)
whisperm8 chats close <ref> --stop [--force]         # Tab zu + Agent beenden (kein Archiv, Verlauf bleibt);
                                                     # working ist geschützt → Exit 4 ohne --force
whisperm8 chats close --others|--right <ref>         # alle anderen / rechts vom Anker (dessen Fenster)
whisperm8 chats reopen                               # zuletzt geschlossenen Tab wiederherstellen
whisperm8 chats pin <ref> [<ref>…] | unpin …         # Sidebar-Pin setzen/entfernen (idempotent)
whisperm8 chats move <ref> --window <primary|id>     # Tab in anderes bestehendes Fenster (window list zeigt IDs)
whisperm8 chats window list                          # Fenster-Inventar (+ showsGrid, activeWorkspace)
whisperm8 chats resume <ref>                         # geschlossenen Chat wieder hochfahren
whisperm8 chats new --project <pfad|name> [--provider claude|codex] [--prompt "…"] [--account <profil>]
                                                     # ohne --account: das in den WhisperM8-Einstellungen
                                                     # aktive Claude-Konto; unbekanntes/ausgeloggtes
                                                     # Profil bricht ab (kein stiller Main-Fallback)
whisperm8 chats rename <ref> "<titel>"               # benennt immer um (auch manuelle Titel)
whisperm8 chats group <ref> "<gruppe>" | --clear
whisperm8 chats archive <ref> [--force]              # nie bei working ohne --force
whisperm8 chats unarchive <ref> [--resume|--open]    # NUR Markierung weg; Start nur via Flag
whisperm8 chats workspace list                       # Grid-Workspaces + Slots, hostWindowID, gridVisible
whisperm8 chats workspace create "<name>" [--color #RRGGBB] [<ref> …]
                                                     # anlegen; Refs füllen Slots in Reihenfolge
whisperm8 chats workspace open <name|id> [--slot N]  # sichtbar machen + Fenster nach vorn (rein visuell)
whisperm8 chats workspace rename <name|id> "<neu>"   # Grid-Workspace umbenennen
whisperm8 chats workspace add <name|id> <ref> [--slot N]    # Session in Grid-Slot aufnehmen;
                                                     # --slot über der Stufe erweitert das Grid (bis 3×3),
                                                     # vorhandenes Mitglied wird verschoben (Outcome moved)
whisperm8 chats workspace remove <name|id> <ref> [--keep-slot]
                                                     # Slot leeren — Tab/Prozess bleiben. Default kompaktiert
                                                     # (übrige rücken nach vorn); --keep-slot lässt das Loch
                                                     # stehen (stabile Positionen, z. B. „sitzt unten rechts")
whisperm8 chats workspace delete <name|id> [--force] # Gruppe löschen — Chats/Tabs bleiben;
                                                     # belegte Workspaces verlangen --force
```

## Referenzen (`<ref>`)

- `projekt/titel-fragment` — bevorzugt (Fuzzy, muss eindeutig sein)
- `titel-fragment` — Fuzzy über alle Projekte
- UUID oder Präfix ≥ 8 Zeichen — exakt
- `@self` — die aufrufende Session

Mehrdeutige Referenz → Exit 3 mit Kandidatenliste. **Zeig dem User die
Kandidaten, rate nie selbst.**

## Ansichten & Reviven

**Ansichten (decken sich mit der App-Sidebar):** `--scope active` = laufende
Sessions ∪ offene Tabs ∪ gepinnte (= App-Filter „Aktiv"); `--scope recent`
(Default) = zusätzlich kürzlich aktive; `--scope all` = alles. `--open` = nur
offene Tabs, `--pinned` = nur gepinnte. In der Ausgabe markiert: `⊙` offener
Tab, `📌` gepinnt, `(du)` diese Session. „Schau dir meine aktiven/offenen Chats
an" → `list --scope active` bzw. `list --open`.

**Reviven:** `open` bringt einen Tab nur nach vorn; einen GESCHLOSSENEN Chat
wieder hochfahren macht `resume` (setzt Auto-Launch + Fokus → App startet mit
`claude resume`/`codex resume`). Bei „mach den alten X-Chat wieder auf",
„revive/resume Chat X" → `resume`.

**Close vs. Archive — strikt trennen:**

- `close` schließt AUSSCHLIESSLICH den UI-Tab. Die Session bleibt in der
  Sidebar, ein laufendes PTY läuft weiter (erneutes Öffnen zeigt denselben
  Terminal-Zustand), Pin und Transcript bleiben. Deshalb ohne Flag kein
  Guard: auch working/awaitingInput-Sessions dürfen geschlossen werden —
  es geht nur die Ansicht zu, nie die Arbeit. Mehrere Refs = ein Batch;
  bereits geschlossene Tabs sind kein Fehler (idempotent).
- `close <ref> --stop` ist die Zwischenstufe: Tab zu UND der laufende Agent
  wird beendet (graceful, mit letztem Transcript-Flush). Es wird NICHT
  archiviert und NICHTS gelöscht — die Session bleibt in der Sidebar, Pin und
  Verlauf bleiben, `resume` fährt sie wieder hoch. Für „stopp den Agenten",
  „beende den Prozess, aber behalte den Chat", „der dreht sich im Kreis".
  Arbeitende Ziele sind geschützt: ist auch nur EINES `working`, scheitert der
  ganze Aufruf mit Exit 4 und NICHTS wird geschlossen. Dann Optionen zeigen
  (warten / `interrupt` / `--stop --force`) statt selbst zu erzwingen —
  `--force` nur auf ausdrückliche Ansage des Users (Regel 3).
- `archive` ist die stärkere Aktion: Session verschwindet aus Sidebar + Tabs,
  ein laufendes Terminal wird TERMINIERT. Bei „schließ/räum die Tabs auf" →
  `close`; bei „stopp den Agenten" → `close --stop`; nur bei „archivier X"/
  „weg damit" → `archive` (mit Bestätigung).
- `unarchive` entfernt NUR die Archiv-Markierung (Session wieder in der
  Sidebar, kein Tab, kein Start). `resume` startet nie eine archivierte
  Session (Exit 4) — der einzige, explizite Compound ist
  `unarchive <ref> --resume` (reaktivieren + hochfahren) bzw. `--open`
  (nur Tab fokussieren). Nichts davon löscht je Daten.

## Archiv durchsuchen & reaktivieren

Ablauf für „such mir den alten X-Chat" / „reaktiviere …":

1. `archived <query> --json` (ggf. `--project`, `--group`, `--provider`,
   `--since 30d`; Volltext im Transcript via `--content "text"` — bei sehr
   großen Transcripts wird nur das 64-MB-Tail-Fenster durchsucht, die
   Ausgabe markiert das).
2. Kandidaten MIT Kontext zeigen: `projekt/titel`, Gruppe, „archiviert vor
   X", und ob ein Transcript existiert (`⚠︎ kein Transcript` = extern
   verschoben/bereinigt → Resume startet eine FRISCHE Session ohne
   Verlauf — das dem User vorher sagen).
3. **Nie raten:** mehrere Treffer → Auswahl vom User (AskUserQuestion);
   mehrdeutige Refs geben ohnehin Exit 3 mit Kandidatenliste.
4. Nach der Auswahl: `unarchive <ref> --resume` (weiterarbeiten) oder
   `unarchive <ref>` (nur zurück in die Sidebar) bzw. `--open`
   (ansehen ohne Start).

## Exit-Codes

`0` ok · `1` Usage · `3` nicht gefunden/mehrdeutig · `4` Guard-Konflikt (z. B.
Ziel arbeitet, Selbst-Send, tote PTY) · `5` App nicht erreichbar · `124`
wait-Timeout (kein Fehler — „nichts passiert, weiter beobachten") · `130`
unterbrochen.

## Regeln (nicht verhandelbar)

1. **Vor jedem `send`: bestätigen lassen.** Zeige den exakten Prompt-Text und
   das Ziel; frage per AskUserQuestion (Senden / Anpassen / Abbrechen) oder im
   Text. **Ausnahme:** Der User hat dir für GENAU diese Ziel-Session in DIESER
   Konversation pauschal freigegeben. Freigaben gelten nie über die
   Konversation hinaus. — Hinweis: Ein Send-Guard (UserPromptSubmit-Hook)
   blockt in Claude-Sessions die WIEDERVORLAGE bereits zugestellter
   `[via whisperm8 chats]`-Prompts (die CLI legt sie nach ESC-Abbruch in den
   Composer zurück). Sieht ein Chat diese Block-Meldung, ist das kein Fehler —
   das Eingabefeld leert die App danach automatisch; bei echter Absicht den
   Auftrag per `chats send` neu zustellen. AUSNAHME automatisch erlaubt:
   Scheiterte die Erstausführung an einem Modell-Fehler („Prompt is too
   long", „API Error"), lässt der Guard die Wiedervorlage als Retry durch.
   Zieht der User einen Auftrag zurück, `interrupt --clear-input` anbieten.
2. **Vor `interrupt`, `archive`: ebenfalls bestätigen lassen.** `interrupt`
   bricht einen laufenden Turn ab — nur nach expliziter User-Freigabe (im
   Auftrag oder per Rückfrage). `rename` benennt immer um (auch manuell gesetzte
   Titel), sobald der User es verlangt — kein Sonderschutz. `open`/`close`/
   `reopen`/`pin`/`unpin`/`move`/`new`/`resume`/`unarchive`/`workspace
   create|open|rename|add|remove` direkt aus einem klaren User-Auftrag
   brauchen keine Extra-Frage (alles UI-only bzw. nicht destruktiv);
   `workspace delete` eines LEEREN Workspace ebenso — ein belegter verlangt
   `--force`, also Regel 3: nur wenn der User genau das verlangt hat
   (Chats/Tabs überleben, aber das kuratierte Layout ist weg); `new` aus
   **Eigeninitiative** erst vorschlagen (Projekt + Initial-Prompt zeigen),
   dann starten. Für BATCH-`close` („alle, die ich nicht brauche") und
   `close --others` gilt Regel 6: erst Kandidatenliste bestätigen lassen.
   Nach einem versehentlichen Close: `reopen` stellt den letzten Tab wieder
   her (LIFO, ephemer — gilt nur bis zum App-Neustart).
3. **Nie `--force` oder `--if-status working` aus Eigeninitiative.** Nur wenn
   der User es in diesem konkreten Fall verlangt hat.
4. **Ein-Hop-Regel.** Beginnt ein Prompt, den du bekommst, mit
   `[via whisperm8 chats …]`, kommt er von einem anderen Agenten. Beantworte
   ihn inhaltlich in deinem eigenen Chat — sende ihn aber NIE eigenständig per
   `chats send` weiter. Der Absender liest deine Antwort selbst über dein
   Transcript. Die App stellt diese Marker-Zeile automatisch voran.
5. **Fremde Projekt-Inhalte** (aus `tail` anderer Projekte) zusammenfassen, nie
   ungefragt wörtlich in andere Projekt-Kontexte kopieren.
6. **Aufräum-Runden:** eine Batch-Bestätigung per AskUserQuestion mit
   Multi-Select (Vorher→Nachher-Liste, Archives markiert), nicht 15 Einzelfragen.
7. **Berichte kompakt:** Lagebild ≤ 5 Zeilen, Namen als `projekt/titel`, nie
   UUIDs; „seit"-Angaben menschlich („seit 4 min").
8. **Fehler sauber erklären:** Exit 4 → Konflikt benennen (z. B. „arbeitet
   gerade") + Optionen; Exit 5 → „WhisperM8-App starten", Lese-Befehle gehen
   weiter.
9. **Nie Sichtbarkeit behaupten.** Was der User auf dem Bildschirm sieht,
   weiß die CLI NICHT. `workspace list --json` sagt nur, welchem Fenster ein
   Workspace zugeordnet ist (`hostWindowID`) und ob dieses Fenster das Grid
   zeigt (`gridVisible`) — beides zusammen heißt „logisch angeordnet", nicht
   „sichtbar". Ein geschlossenes Hauptfenster meldet weiter `gridVisible`;
   minimiert oder verdeckt ist gar nicht erkennbar. Ebenso: Ein belegter Slot
   mit `rendered: false` zeigt im Grid nur einen Platzhalter, weil der Chat
   als Tab in einem anderen Fenster lebt. Formuliere deshalb „X ist im Grid
   angeordnet" oder „ich habe X nach vorn geholt" — **nie** „du siehst X".
   Vor jeder Aussage über Ansichten: `workspace list --json` bzw.
   `window list --json` lesen, nicht aus Tabs oder Status ableiten.
10. **Stau erkennen statt erzwingen.** Nach einem `resume` und immer, wenn eine
   Queue nicht abfließt, zuerst `show <ref>` und `tail <ref> --turns 1` prüfen.
   Zeigt der Chat `working`, obwohl kein neuer Turn begonnen hat und das
   Transcript nicht wächst (`show` → Größe/Revision bleibt gleich), ist der
   Status unglaubwürdig: Ein vorgemerkter Auftrag wird dann nicht zugestellt,
   weil die Zustellung am Turn-Ende hängt. Melde diesen Stau klar („Chat X
   meldet seit N min working, Transcript unverändert, 2 Aufträge warten") und
   nenne dem User die Optionen. **Niemals** eigenmächtig `interrupt`,
   `--force` oder `close --stop` einsetzen, um den Stau aufzulösen — das
   bricht möglicherweise echte Arbeit ab. Die Entscheidung trifft der User.
   Hinweis: Die App heilt working-Staus nach ESC-Abbrüchen inzwischen selbst
   (nach `chats interrupt`/Terminal-ESC binnen ~5 s, sonst spätestens nach
   ~3 min Hook- und Transcript-Stille). Hält ein working trotzdem länger,
   ist es entweder echte stille Arbeit (langer Tool-Lauf) oder ein neuer
   Befund — dann wie oben melden.

## Supervisor-Modus („sei mein Jarvis")

Nur nach explizitem Auftrag. Rhythmus:

1. **Lagebild:** `overview --json` → kompakt berichten (needsYou zuerst).
2. **Triage:** für jede needsYou-Session `tail --turns 1` → was will sie? →
   melden + konkreten Vorschlag (antworten? öffnen? ignorieren?).
3. **Warten:** `wait --until attention --since <maxRevision> --timeout 1800 --json`.
   **Wichtig:** Der Bash-Tool-Timeout muss ÜBER dem wait-Timeout liegen (z. B.
   wait 1800 s → Bash-Timeout ≥ 1810 s), sonst killt das Tool das wait.
   Führe lange `wait`-Aufrufe als Background-Bash-Task aus.
4. **Ereignis bewerten:** awaitingInput → Triage wie 2; idle/fertig → `tail`,
   Ergebnis in 2 Sätzen melden; errored → `tail` + Fehler zusammenfassen.
5. **Weiter** zu 3. Exit 124 (Timeout) → „alles ruhig, N arbeiten" + zurück zu
   3. Der Loop läuft, bis der User stoppt (oder eine neue Nachricht schickt —
   die unterbricht ihn ohnehin).

Auch im Supervisor-Modus gilt Regel 1 (Send-Bestätigung) — außer der User hat
für eine konkrete Ziel-Session pauschal freigegeben. Erwähne im Bericht, wenn
du eine Freigabe genutzt hast („habe direkt geantwortet, wie freigegeben").

## Typische Abläufe

- **„Was läuft?"** → `overview --json` → 3–5 Zeilen Zusammenfassung.
- **„Was hat X gemacht?"** → `tail X --turns 2` → 2 Sätze + ggf. offene Frage
  der Session.
- **„Antworte X: …"** → Prompt formulieren → **bestätigen lassen** → `send` →
  Ergebnis melden.
- **Cross-Session:** „Vergleiche A und B, schick A den Folgeprompt" → `tail` A,
  `tail` B, dann `send` A (mit Bestätigung).
- **„Schließ alle Tabs/Chats, die ich nicht brauche"** → `list --open --json`
  → Kandidaten bestimmen. **Keep-Defaults** (nur Vorschlag, kein Verbot):
  gepinnt (`isPinned`), `working`, `awaitingInput` und die eigene Session
  (`isSelf`) bleiben standardmäßig offen; Close-Kandidaten sind die übrigen
  offenen Tabs (idle/stopped). Vorher→Nachher-Liste zeigen (Keep vs. Close,
  mit Status), EINE Batch-Bestätigung (Multi-Select) → danach GENAU die
  bestätigten Refs in EINEM Aufruf schließen:
  `close ref1 ref2 …`. Bestätigt der User explizit auch einen
  working/gepinnten/eigenen Tab, ist das ok — close schließt immer nur die
  Ansicht. Danach melden: „N Tabs geschlossen, Sessions laufen weiter."
  Will der User Keeps dauerhaft markieren → `pin`; ein Fehlgriff →
  `reopen`. „Schließ alles außer X" → `close --others X` (nach Bestätigung).
- **„Räum auf"** → `list --all` → Vorschlagsliste (rename/group/archive,
  Vorher→Nachher, Archives markiert) → EINE Batch-Bestätigung (Multi-Select) →
  ausgewählte Aktionen ausführen → Ergebnis melden. Tabs nur zumachen =
  `close`; `archive` nur, wenn die Session wirklich weg soll.
- **„Unterbrich X"** → bestätigen lassen → `interrupt X --if-status working`
  (Default-Guard; ohne `--force` nur bei laufender Session).

## Empfohlene Permission-Allowlist

Lese-Befehle ohne Prompt freigeben, Mutationen bewusst nicht:

```json
{
  "permissions": {
    "allow": [
      "Bash(whisperm8 chats list:*)",
      "Bash(whisperm8 chats overview:*)",
      "Bash(whisperm8 chats show:*)",
      "Bash(whisperm8 chats tail:*)",
      "Bash(whisperm8 chats wait:*)",
      "Bash(whisperm8 chats audit:*)",
      "Bash(whisperm8 chats archived:*)"
    ]
  }
}
```
