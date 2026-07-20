---
status: blockiert
updated: 2026-07-20
description: Isolierte Live-Probe der Fork-Hook-Ereignisfolge der installierten Claude-CLI; der vorgeschaltete Auth-Gate scheiterte im separaten CLAUDE_CONFIG_DIR, daher wurden keine Fork-Arme ausgeführt.
---

# Fork-Hook-Live-Probe

## Ergebnis

**Status: blockiert.** Der zwingend vorgeschaltete Auth-Mini-Lauf wurde mit
einem ausschließlich für diese Probe angelegten `CLAUDE_CONFIG_DIR`
ausgeführt. Die CLI startete, beendete den Lauf jedoch mit Exit-Code `1` und
dem Resultat `Not logged in · Please run /login`. Gemäß Probeprotokoll wurden
danach weder Settings-Dateien angelegt noch Parent- oder Fork-Arme gestartet.
Es gab keinen Rückgriff auf `~/.claude` oder `~/.codex`.

Damit ist die positive Capability-Bedingung nicht erfüllt. Der Gate-Stand bleibt
fail-closed bei **`hostAssignedUnsupported`**. Das ist kein empirischer Beleg,
dass die installierte CLI die Kombination grundsätzlich ablehnt, sondern die
korrekte Klassifikation dieses blockierten Laufs: Ohne Exit `0` und ohne exakte
Child-ID in Hook und Result darf `hostAssignedVerified` nicht gesetzt werden.

## Laufzeitstand

- CLI-Pfad: `/Users/giulianocosta/.local/bin/claude`
- CLI-Version: `2.1.215 (Claude Code)`
- Probe-Root:
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe`
- Isolierter Config-Root:
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe/config`
- Isoliertes Arbeitsverzeichnis:
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe/cwd`

Im aufrufenden Prozess waren keine `ANTHROPIC_API_KEY`- oder
`ANTHROPIC_AUTH_TOKEN`-Variablen gesetzt. Erkannt wurden lediglich
`ANTHROPIC_BASE_URL` sowie Laufzeitvariablen mit Präfix `CLAUDE_` beziehungsweise
`CLAUDECODE`. `CLAUDECODE` wurde für den Kindprozess explizit entfernt, um nur
den Nested-Session-Guard auszuschließen; der Config-Root blieb explizit gesetzt.

## Ausgeführter Auth-Gate

Der tatsächlich ausgeführte, hier ohne Geheimnisse vollständig wiedergegebene
CLI-Aufruf war:

```bash
cd "/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe/cwd"
env -u CLAUDECODE \
  CLAUDE_CONFIG_DIR="/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe/config" \
  /Users/giulianocosta/.local/bin/claude \
  -p 'Reply OK' \
  --output-format json \
  > "/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe/results/auth-result.json" \
  2> "/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe/results/auth-stderr.txt"
```

Ergebnis:

- Exit-Code: `1`
- `stderr`: leer
- Result-JSON, auf die entscheidenden Felder gekürzt:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": true,
  "result": "Not logged in · Please run /login",
  "session_id": "cef5ba6b-e439-4a42-88cc-ffb4f3981bc6"
}
```

Die widersprüchlich wirkende Kombination `subtype: "success"` und
`is_error: true` ist wörtlich aus der CLI-Ausgabe übernommen. Für den Gate zählt
der Prozess-Exit-Code `1` zusammen mit `is_error: true` und der Login-Meldung.

## Nicht ausgeführte Fork-Arme

Wegen des fehlgeschlagenen Auth-Gates wurden die folgenden Schritte bewusst
nicht ausgeführt:

1. Parent-Session mit hostseitig erzeugter `PARENT_ID`.
2. Weg B: `--resume "$PARENT_ID" --fork-session`.
3. Weg A: `--session-id "$CHILD_ID" --resume "$PARENT_ID" --fork-session`.

Es wurden deshalb auch keine `parent.json`, `fork-b.json` oder `fork-a.json`
und keine armbezogenen Event-Dateien erzeugt. Settings-Inhalte, Result-JSONs,
Hook-Sequenzen und `source`-Werte der drei Arme liegen nicht vor; sie werden
nicht aus Dokumentation oder Annahmen ergänzt.

Der Auth-Mini-Lauf selbst erzeugte ausschließlich innerhalb des isolierten
Config-Roots eine `.claude.json`, eine Sicherung davon und ein JSONL-Transcript
für seine eigene fehlgeschlagene Session. Diese Dateien belegen die Isolation,
beantworten aber keine Fork-Frage.

## Antworten auf die Kernfragen

1. **Meldet der Fork-`SessionStart` zuerst die Parent-ID oder bereits die
   Child-ID?** Nicht bestimmbar; der Fork-Baseline-Arm wurde wegen fehlender
   isolierter Authentifizierung nicht gestartet.
2. **Akzeptiert die CLI `--session-id` zusammen mit `--resume` und
   `--fork-session`, und erscheint die vorgegebene Child-ID exakt in Hook und
   Result?** Nicht bestimmbar; der Capability-Arm wurde nicht gestartet.
3. **Welchen `source`-Wert tragen die `SessionStart`-Events je Arm?** Nicht
   bestimmbar; es existieren keine armbezogenen Hook-Events.

## Capability-Klassifikation

**Gate-Ergebnis: `hostAssignedUnsupported`.** Die einzige zulässige positive
Klassifikation wäre Exit-Code `0` im Capability-Arm sowie die exakt
vorgegebene Child-ID sowohl im `SessionStart`-Hook als auch im Result-JSON.
Keine dieser Bedingungen konnte wegen des vorgeschalteten Auth-Fehlers belegt
werden. Bis zu einer erfolgreichen Wiederholung darf das Identitätsmodell die
hostseitige Zuweisung daher nicht aktivieren.

## Entblockierung und Wiederholung

Für eine Wiederholung muss der User einmalig genau den isolierten Config-Root
authentifizieren, beispielsweise interaktiv mit:

```bash
CLAUDE_CONFIG_DIR="/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe/config" \
  /Users/giulianocosta/.local/bin/claude login
```

Falls die installierte CLI statt `claude login` nur den interaktiven
Slash-Command anbietet, ist dieselbe CLI mit exakt diesem
`CLAUDE_CONFIG_DIR` zu starten und dort `/login` auszuführen. Anschließend ist
zuerst der Auth-Mini-Lauf erneut zu prüfen; erst bei Exit `0` dürfen die drei
Probe-Arme folgen. Der echte Config-Root bleibt auch bei der Wiederholung tabu.

## Limitierungen

- Wegen der isolierten Login-Blockade gibt es keine empirische Fork-
  Ereignisfolge und keine Aussage zur grundsätzlichen Syntaxunterstützung der
  installierten CLI.
- Die Capability-Klassifikation ist absichtlich fail-closed und darf nicht als
  Nachweis einer CLI-Inkompatibilität zitiert werden.
- Die Probe gilt für CLI-Version `2.1.215`; nach erfolgreicher Authentifizierung
  ist derselbe Versionsstand zu verwenden oder eine Versionsabweichung im
  Folgereport ausdrücklich zu dokumentieren.

## Reproduktionsdaten und Aufräumen

Der Scratch-Ordner bleibt wie gefordert vollständig erhalten:

```text
/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/37e7661e-7542-4f9f-a496-d55892affcdd/scratchpad/fork-probe
```

Er enthält keine Daten aus `~/.claude` oder `~/.codex`, wohl aber den neu
angelegten isolierten Config-Root und das Transcript des fehlgeschlagenen
Auth-Laufs. Nach Abschluss einer späteren Wiederholung kann der User diesen
Scratch-Ordner manuell entfernen.
