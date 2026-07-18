export const meta = {
  name: 'codex-verify',
  description: 'Verifiziert Code mit GPT-Subagents: mehrere Finder-Perspektiven, jedes Finding von zwei adversarischen Refutern gegengeprüft',
  whenToUse: 'Vor einem Merge oder nach einer heiklen Änderung. Bringt echte Modell-Diversität (GPT statt Claude) und killt Fehlbefunde durch adversarische Gegenprüfung. Läuft standardmäßig NATIV über den Claude-Code-Agent-Typ `gpt` (WhisperM8 GPT-Backend); `runner: "codex-cli"` erzwingt den alten headless whisperm8-CLI-Pfad. Args: {scope, effort, repo, dimensions, runner} — alles optional.',
  phases: [
    { title: 'Find', detail: 'GPT-Finder pro Perspektive, read-only' },
    { title: 'Verify', detail: 'pro Finding 2 GPT-Refuter (Faktenlage + Reproduzierbarkeit)' },
  ],
}

// ---------------------------------------------------------------- Parameter

// args kann ein Objekt, ein Freitext-Scope oder (versehentlich) ein
// JSON-STRING sein — letzteres tolerant parsen, sonst landet die ganze
// Konfiguration als `scope` im Prompt und alle Defaults greifen still.
function parseArgs(raw) {
  if (!raw) return {}
  if (typeof raw !== 'string') return raw
  const t = raw.trim()
  if (t.startsWith('{')) {
    try { return JSON.parse(t) } catch { /* Freitext */ }
  }
  return { scope: raw }
}

const cfg = parseArgs(args)
const SCOPE = cfg.scope || 'die zuletzt geänderten Dateien (git diff HEAD~1) und den Code, den sie berühren'
// `high` ist der Default aus gutem Grund: bei `--effort low` haben Refuter
// nachweislich Code HALLUZINIERT (nicht existierende Guards, erfundene
// Fehlertypen) und damit echte Findings fälschlich widerlegt. `low` nur für
// Smoke-Tests der Mechanik, nie für ein Urteil, dem man glaubt.
const EFFORT = cfg.effort || 'high'
const REPO = cfg.repo || null   // null = cwd (= Projekt-Root)

// Runner-Modus:
// - 'gpt' (Default): NATIV über den Claude-Code-Agent-Typ `gpt`
//   (.claude/agents/, WhisperM8 GPT-Backend, gpt-5.6-sol). Der Agent macht
//   das Review selbst und füllt das Schema direkt — kein CLI-Spawn, kein
//   Relay-Parsing. Voraussetzung: GPT-Backend aktiv (Settings → GPT-Backend).
// - 'codex-cli': alter Pfad über `whisperm8 agent run` (headless Codex-Job),
//   gewrappt vom mechanischen `codex-runner`-Agent. Nur noch für den Fall,
//   dass der native gpt-Agent-Typ nicht verfügbar ist (fremdes Repo ohne
//   .claude/agents/gpt, Backend aus).
const RUNNER = cfg.runner || 'gpt'
// Nur für runner=codex-cli relevant: der Wrapper-Agent-Typ. `agentType: null`
// → Kontrakt inline + Sonnet-Wrapper (wenn codex-runner nicht registriert ist).
const CLI_AGENT_TYPE = cfg.agentType === null ? null : (cfg.agentType || 'codex-runner')

// ---------------------------------------------------------------- Schemata

// exitCode/state/reportStatus sind CLI-Artefakte — nur der codex-cli-Pfad
// füllt sie; im nativen Modus bleiben sie weg. Deshalb nicht required.
const FINDINGS = {
  type: 'object', additionalProperties: false,
  properties: {
    exitCode: { type: 'integer' },
    state: { type: 'string' },
    reportStatus: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string' },
          title: { type: 'string' },
          claim: { type: 'string' },
          failureScenario: { type: 'string' },
        },
        required: ['file', 'title', 'claim', 'failureScenario'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['findings', 'notes'],
}

const VERDICT = {
  type: 'object', additionalProperties: false,
  properties: {
    exitCode: { type: 'integer' },
    state: { type: 'string' },
    refuted: { type: 'boolean' },
    reasoning: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['refuted', 'reasoning'],
}

// ---------------------------------------------------------------- Prompts

/** Repo-Kontext für native Agents (die starten im Session-cwd). */
const REPO_HINT = REPO ? `Arbeite im Repo ${REPO}. ` : ''

const READ_ONLY = 'Nur Analyse — keine Edits, keine Commits, keine Writes. '

const FINDER_AUFTRAG = d =>
  `${REPO_HINT}${READ_ONLY}Code-Review mit maximaler Sorgfalt. ` +
  `Untersuchungsgegenstand: ${SCOPE}. Perspektive "${d.key}": ${d.frage} ` +
  'Melde nur echte Defekte mit konkretem Fehlerszenario — keine Stilfragen, keine Spekulation.'

const REFUTER_AUFTRAG = (beschreibung, lens) =>
  `${REPO_HINT}${READ_ONLY}Adversarische Gegenpruefung eines Code-Review-Findings. ` +
  'Deine Aufgabe ist es, das Finding zu WIDERLEGEN. Sei streng: kannst du es nicht klar ' +
  'bestaetigen, gilt es als widerlegt.\n\n' +
  beschreibung + '\n\n' +
  `Pruefauftrag (${lens.key}): ${lens.frage}`

// -- Nativer Modus: der gpt-Agent füllt das Schema direkt aus. --------------

const NATIVE_FINDER_SCHEMA_HINT =
  ' Fülle das Schema direkt: pro Defekt ein findings-Eintrag (file, line, severity ' +
  'critical|high|medium|low, title, claim = was genau falsch ist, failureScenario = ' +
  'konkretes Szenario Eingabe/Zustand -> falsches Verhalten). Nichts Substanzielles ' +
  'gefunden → leeres findings-Array. notes = "ok" oder kurze Einschränkungen.'

const NATIVE_REFUTER_SCHEMA_HINT =
  '\n\nFülle das Schema direkt: refuted=true wenn du das Finding widerlegst (oder es nicht ' +
  'klar bestätigen kannst), refuted=false nur bei klarer Bestätigung. reasoning = Begründung ' +
  'mit Code-Belegen (Datei:Zeile).'

// -- codex-cli-Modus: CLI-Spawn + Relay-Parsing (Legacy-Pfad). --------------

/** Baut den CLI-Befehl. Ohne --cd nutzt whisperm8 das cwd des Wrappers. */
function codexRun(auftrag) {
  const prompt = auftrag.replace(/"/g, '\\"')
  const cd = REPO ? ` --cd ${REPO}` : ''
  return `whisperm8 agent run --wait --json --sandbox read-only --effort ${EFFORT}${cd} "${prompt}"`
}

/** Wrapper-Kontrakt: bei codex-runner steckt er im Agent, sonst im Prompt. */
const INLINE_KONTRAKT =
  'Du bist ein mechanischer CLI-Wrapper. Führe via Bash exakt den folgenden Befehl aus — nichts ' +
  'anderes, kein Retry, keine eigenen Analysen, kein `agent rm`/`agent stop`, Bash-Parameter ' +
  'timeout: 600000. Der Befehl blockiert mehrere Minuten; warte geduldig auf sein Ende. Hänge ' +
  '`; echo "EXIT:$?"` an. Erfinde nichts — gib ausschließlich wieder, was das CLI ausgegeben hat.\n\n'

function wrap(cmd, relay) {
  const kopf = CLI_AGENT_TYPE ? '' : INLINE_KONTRAKT
  return `${kopf}Führe genau diesen Befehl aus:\n\n${cmd}\n\n${relay}`
}

const RELAY_FINDINGS =
  'Fülle das Schema aus dem stdout-JSON: exitCode, state, reportStatus (= report.status), ' +
  'und zerlege report.summary in das findings-Array (je FINDING-Block: file, line, severity, ' +
  'title, claim, failureScenario). Steht dort "KEINE FINDINGS", gib ein leeres Array zurück.'

const RELAY_VERDICT =
  'Fülle das Schema aus dem stdout-JSON: exitCode, state, refuted (true = Codex hat das Finding ' +
  'widerlegt bzw. mit WIDERLEGT geantwortet; false = BESTAETIGT), reasoning (= report.summary). ' +
  'Bei Fehler oder fehlendem Report: refuted=true und Ursache in notes.'

/** Report-Vertrag für die CLI-Finder — ohne den ist summary unparsbar. */
const CLI_FORMAT =
  ' Formatiere JEDES Finding im Report-summary exakt so, mehrere durch Leerzeile getrennt: ' +
  '"FINDING: <datei>:<zeile> | <critical|high|medium|low> | <titel> | <was genau falsch ist> | ' +
  '<konkretes Fehlerszenario: Eingabe/Zustand -> falsches Verhalten>". Findest du nichts ' +
  'Substanzielles, schreibe genau "KEINE FINDINGS" ins summary. Nur Analyse, keine Edits.'

const CLI_REFUTER_FORMAT =
  '\n\nSchreibe ins Report-summary zuerst genau eines der Woerter WIDERLEGT oder BESTAETIGT, ' +
  'danach die Begruendung mit Code-Belegen (Datei:Zeile).'

// -- Dispatcher: ein Interface, zwei Runner. --------------------------------

function finderCall(d) {
  if (RUNNER === 'gpt') {
    return agent(FINDER_AUFTRAG(d) + NATIVE_FINDER_SCHEMA_HINT, {
      label: `find:${d.key}`, phase: 'Find', schema: FINDINGS,
      agentType: 'gpt', effort: EFFORT,
    })
  }
  return agent(
    wrap(codexRun(FINDER_AUFTRAG(d) + CLI_FORMAT), RELAY_FINDINGS),
    cliOpts(`find:${d.key}`, 'Find', FINDINGS)
  )
}

function refuterCall(beschreibung, lens, label) {
  if (RUNNER === 'gpt') {
    return agent(REFUTER_AUFTRAG(beschreibung, lens) + NATIVE_REFUTER_SCHEMA_HINT, {
      label, phase: 'Verify', schema: VERDICT,
      agentType: 'gpt', effort: EFFORT,
    })
  }
  return agent(
    wrap(codexRun(REFUTER_AUFTRAG(beschreibung, lens) + CLI_REFUTER_FORMAT), RELAY_VERDICT),
    cliOpts(label, 'Verify', VERDICT)
  )
}

/** codex-cli-Optionen: Wrapper-Agent-Typ ODER günstiges Modell + inline-Kontrakt. */
function cliOpts(label, phaseName, schema) {
  const base = { label, phase: phaseName, schema }
  return CLI_AGENT_TYPE ? { ...base, agentType: CLI_AGENT_TYPE } : { ...base, model: 'sonnet', effort: 'low' }
}

const DEFAULT_DIMENSIONS = [
  { key: 'correctness', frage: 'Logikfehler, falsche Randfälle, verletzte Invarianten, Off-by-one, falsch behandelte Fehlerpfade.' },
  { key: 'concurrency', frage: 'Races, Deadlocks, ungeschützte read-modify-write-Zyklen, Zustände, aus denen es keinen Ausweg gibt, Lifetime-Probleme von Timern/Prozessen.' },
  { key: 'io-process', frage: 'Prozess- und Stream-Handling: Deadlocks bei großen Ausgaben, verlorene Events, Puffergrenzen (auch UTF-8-Schnitte), Signal- und Exit-Behandlung.' },
  { key: 'api-contract', frage: 'Verletzte öffentliche Verträge: Exit-Codes, JSON-Felder, Flag-Semantik, argv-Layout, Persistenz-Kompatibilität alter Datenstände.' },
  { key: 'tests', frage: 'Welche Logik ist NICHT oder nur scheinbar abgedeckt? Welche Tests bleiben grün, obwohl sie das Falsche prüfen (z.B. Substring-Matches statt Struktur)? Melde nur, wenn du das Fehlerszenario konkret benennen kannst.' },
  { key: 'docs', frage: 'Behauptungen in Doku/Hilfetexten, die der Code nicht einlöst: Flags, Exit-Codes, zugesicherte Verhaltensweisen, fehlende Optionen.' },
]

const LENSES = [
  { key: 'reality', frage: 'Lies den betroffenen Code vollstaendig und pruefe, ob die Behauptung faktisch stimmt. Achte darauf, ob der Kritiker Code uebersehen hat, der das Problem bereits verhindert.' },
  { key: 'repro', frage: 'Konstruiere das konkrete Fehlerszenario. Kann es unter realistischen Bedingungen eintreten (erreichbarer Zustand, tatsaechliche Aufrufer, vorhandene Guards)? Ist es nicht erreichbar, gilt das Finding als widerlegt.' },
]

// ---------------------------------------------------------------- Ausführung

const DIMENSIONS = cfg.dimensions || DEFAULT_DIMENSIONS
log(`Scope: ${SCOPE} · Effort: ${EFFORT} · ${DIMENSIONS.length} Finder · Runner: ${RUNNER === 'gpt' ? 'gpt (nativ)' : (CLI_AGENT_TYPE || 'sonnet (inline)') + ' via whisperm8-CLI'}`)
if (EFFORT === 'low') {
  log('WARNUNG: effort=low — Refuter halluzinieren auf dieser Stufe Code. Urteile sind unbrauchbar; nur als Smoke-Test verwenden.')
}

phase('Find')
const results = await pipeline(
  DIMENSIONS,
  d => finderCall(d),
  (res, d) => {
    if (!res || !res.findings || res.findings.length === 0) {
      const grund = res && res.notes && res.notes !== 'ok' ? ` (${res.notes})` : ''
      log(`find:${d.key} → keine Findings${grund}`)
      return []
    }
    log(`find:${d.key} → ${res.findings.length} Findings → Verify`)

    const jobs = []
    res.findings.forEach((f, i) => {
      const beschreibung =
        `Datei: ${f.file}${f.line ? ':' + f.line : ''}\n` +
        `Titel: ${f.title}\n` +
        `Behauptung: ${f.claim}\n` +
        `Behauptetes Fehlerszenario: ${f.failureScenario}`
      LENSES.forEach(lens => {
        jobs.push(() =>
          refuterCall(beschreibung, lens, `verify:${d.key}-${i + 1}:${lens.key}`)
            .then(v => ({ dimension: d.key, finding: f, lens: lens.key, verdict: v })))
      })
    })
    return parallel(jobs)
  }
)

// ---------------------------------------------------------------- Auswertung

const flat = results.flat().filter(Boolean)
const byFinding = {}
for (const r of flat) {
  const key = `${r.dimension}||${r.finding.title}`
  if (!byFinding[key]) byFinding[key] = { dimension: r.dimension, finding: r.finding, verdicts: [] }
  byFinding[key].verdicts.push({
    lens: r.lens,
    refuted: r.verdict ? r.verdict.refuted : true,
    reasoning: r.verdict ? r.verdict.reasoning : 'kein Urteil (Refuter-Job fehlgeschlagen → gilt als widerlegt)',
  })
}

const confirmed = [], plausible = [], dropped = []
for (const e of Object.values(byFinding)) {
  const survived = e.verdicts.filter(v => !v.refuted).length
  if (survived === e.verdicts.length) confirmed.push(e)
  else if (survived > 0) plausible.push(e)
  else dropped.push(e)
}

log(`Verify fertig: ${confirmed.length} bestätigt · ${plausible.length} strittig · ${dropped.length} widerlegt`)
if (confirmed.length === 0 && plausible.length === 0) {
  log('Keine überlebenden Findings — das heißt "nichts gefunden", nicht "nichts da".')
}

return { scope: SCOPE, effort: EFFORT, runner: RUNNER, confirmed, plausible, dropped }
