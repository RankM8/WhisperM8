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
```

Handeln (App muss laufen — sonst Exit 5). **Vor jeder dieser Aktionen: Regeln unten beachten.**
```bash
whisperm8 chats send <ref> -- "<prompt>"  [--if-status S,S] [--no-submit] [--force]
whisperm8 chats interrupt <ref> [--force]            # ein ESC an eine working-Session
whisperm8 chats open <ref>                           # Tab fokussieren (startet NICHT neu)
whisperm8 chats resume <ref>                         # geschlossenen Chat wieder hochfahren
whisperm8 chats new --project <pfad|name> [--provider claude|codex] [--prompt "…"]
whisperm8 chats rename <ref> "<titel>"               # benennt immer um (auch manuelle Titel)
whisperm8 chats group <ref> "<gruppe>" | --clear
whisperm8 chats archive <ref> [--force]              # nie bei working ohne --force
whisperm8 chats workspace list                       # Grid-Workspaces (Sidebar-Sektion WORKSPACES)
whisperm8 chats workspace rename <name|id> "<neu>"   # Grid-Workspace umbenennen
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
   Konversation hinaus.
2. **Vor `interrupt`, `archive`: ebenfalls bestätigen lassen.** `interrupt`
   bricht einen laufenden Turn ab — nur nach expliziter User-Freigabe (im
   Auftrag oder per Rückfrage). `rename` benennt immer um (auch manuell gesetzte
   Titel), sobald der User es verlangt — kein Sonderschutz. `open`/`new`/
   `resume`/`workspace rename` direkt aus einem klaren User-Auftrag brauchen
   keine Extra-Frage; `new` aus **Eigeninitiative** erst vorschlagen (Projekt +
   Initial-Prompt zeigen), dann starten.
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
- **„Räum auf"** → `list --all` → Vorschlagsliste (rename/group/archive,
  Vorher→Nachher, Archives markiert) → EINE Batch-Bestätigung (Multi-Select) →
  ausgewählte Aktionen ausführen → Ergebnis melden.
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
      "Bash(whisperm8 chats audit:*)"
    ]
  }
}
```
