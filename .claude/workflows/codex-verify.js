export const meta = {
  name: 'codex-verify',
  description: 'Verifiziert Code mit Codex-Subagents: mehrere Finder-Perspektiven, jedes Finding von zwei adversarischen Refutern gegengeprüft',
  whenToUse: 'Vor einem Merge oder nach einer heiklen Änderung. Bringt echte Modell-Diversität (Codex statt Claude) und killt Fehlbefunde durch adversarische Gegenprüfung. Args: {scope, effort, repo, dimensions} — alles optional.',
  phases: [
    { title: 'Find', detail: 'Codex-Finder pro Perspektive, read-only' },
    { title: 'Verify', detail: 'pro Finding 2 Codex-Refuter (Faktenlage + Reproduzierbarkeit)' },
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
const REPO = cfg.repo || null   // null = cwd des Wrappers (= Projekt-Root)
// Der Subagent-Typ `codex-runner` (.claude/agents/) trägt den Wrapper-Kontrakt.
// Er ist erst NACH einem Session-Neustart registriert — bis dahin (oder in
// fremden Repos) `agentType: null` übergeben: dann wird der Kontrakt inline
// in den Prompt gelegt und ein Sonnet-Agent genutzt.
const AGENT_TYPE = cfg.agentType === null ? null : (cfg.agentType || 'codex-runner')

// ---------------------------------------------------------------- Schemata

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
  required: ['exitCode', 'findings', 'notes'],
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
  required: ['exitCode', 'refuted', 'reasoning'],
}

// ---------------------------------------------------------------- Bausteine

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
  const kopf = AGENT_TYPE ? '' : INLINE_KONTRAKT
  return `${kopf}Führe genau diesen Befehl aus:\n\n${cmd}\n\n${relay}`
}

/** agent()-Optionen: Agent-Typ ODER günstiges Modell + inline-Kontrakt. */
function runnerOpts(label, phaseName, schema) {
  const base = { label, phase: phaseName, schema }
  return AGENT_TYPE ? { ...base, agentType: AGENT_TYPE } : { ...base, model: 'sonnet', effort: 'low' }
}

const RELAY_FINDINGS =
  'Fülle das Schema aus dem stdout-JSON: exitCode, state, reportStatus (= report.status), ' +
  'und zerlege report.summary in das findings-Array (je FINDING-Block: file, line, severity, ' +
  'title, claim, failureScenario). Steht dort "KEINE FINDINGS", gib ein leeres Array zurück.'

const RELAY_VERDICT =
  'Fülle das Schema aus dem stdout-JSON: exitCode, state, refuted (true = Codex hat das Finding ' +
  'widerlegt bzw. mit WIDERLEGT geantwortet; false = BESTAETIGT), reasoning (= report.summary). ' +
  'Bei Fehler oder fehlendem Report: refuted=true und Ursache in notes.'

/** Report-Vertrag für die Finder — ohne den ist summary unparsbar. */
const FORMAT =
  ' Formatiere JEDES Finding im Report-summary exakt so, mehrere durch Leerzeile getrennt: ' +
  '"FINDING: <datei>:<zeile> | <critical|high|medium|low> | <titel> | <was genau falsch ist> | ' +
  '<konkretes Fehlerszenario: Eingabe/Zustand -> falsches Verhalten>". Findest du nichts ' +
  'Substanzielles, schreibe genau "KEINE FINDINGS" ins summary. Melde nur echte Defekte mit ' +
  'konkretem Fehlerszenario — keine Stilfragen, keine Spekulation. Nur Analyse, keine Edits.'

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
log(`Scope: ${SCOPE} · Effort: ${EFFORT} · ${DIMENSIONS.length} Finder · Runner: ${AGENT_TYPE || 'sonnet (inline)'}`)
if (EFFORT === 'low') {
  log('WARNUNG: effort=low — Refuter halluzinieren auf dieser Stufe Code. Urteile sind unbrauchbar; nur als Smoke-Test verwenden.')
}

phase('Find')
const results = await pipeline(
  DIMENSIONS,
  d => agent(
    wrap(codexRun(
      `Code-Review mit maximaler Sorgfalt. Untersuchungsgegenstand: ${SCOPE}. ` +
      `Perspektive "${d.key}": ${d.frage}${FORMAT}`
    ), RELAY_FINDINGS),
    runnerOpts(`find:${d.key}`, 'Find', FINDINGS)
  ),
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
        jobs.push(() => agent(
          wrap(codexRun(
            'Adversarische Gegenpruefung eines Code-Review-Findings. Deine Aufgabe ist es, das Finding zu ' +
            'WIDERLEGEN. Sei streng: kannst du es nicht klar bestaetigen, gilt es als widerlegt.\n\n' +
            beschreibung + '\n\n' +
            `Pruefauftrag (${lens.key}): ${lens.frage}\n\n` +
            'Nur Analyse, keine Edits. Schreibe ins Report-summary zuerst genau eines der Woerter ' +
            'WIDERLEGT oder BESTAETIGT, danach die Begruendung mit Code-Belegen (Datei:Zeile).'
          ), RELAY_VERDICT),
          runnerOpts(`verify:${d.key}-${i + 1}:${lens.key}`, 'Verify', VERDICT)
        ).then(v => ({ dimension: d.key, finding: f, lens: lens.key, verdict: v })))
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

return { scope: SCOPE, effort: EFFORT, confirmed, plausible, dropped }
