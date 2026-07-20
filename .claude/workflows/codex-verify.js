export const meta = {
  name: 'codex-verify',
  description: 'Verifiziert Code ausschließlich mit nativen GPT-Subagents: mehrere Finder-Perspektiven, jedes Finding von zwei adversarischen Refutern gegengeprüft',
  whenToUse: 'Vor einem Merge oder nach einer heiklen Änderung. Bringt echte Modell-Diversität (GPT statt Claude) und verwirft Fehlbefunde durch adversarische Gegenprüfung. Läuft ausschließlich über den nativen Agent-Typ `gpt` des WhisperM8-GPT-Backends; für explizite Codex-CLI-Jobs stattdessen `/codex-subagent --cli` verwenden. Args: {scope, effort, repo, dimensions} — alles optional.',
  phases: [
    { title: 'Find', detail: 'Native GPT-Finder pro Perspektive, read-only' },
    { title: 'Verify', detail: 'pro Finding 2 native GPT-Refuter (Faktenlage + Reproduzierbarkeit)' },
  ],
}

// ---------------------------------------------------------------- Parameter

// args kann ein Objekt, ein Freitext-Scope oder (versehentlich) ein
// JSON-String sein — letzteres tolerant parsen, sonst landet die ganze
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
if (cfg.runner !== undefined || cfg.agentType !== undefined) {
  throw new Error(
    'codex-verify unterstützt keinen CLI-Runner mehr. Entferne `runner`/`agentType`; ' +
    'für explizite Codex-CLI-Jobs verwende `/codex-subagent --cli`.'
  )
}

const SCOPE = cfg.scope || 'die zuletzt geänderten Dateien (git diff HEAD~1) und den Code, den sie berühren'
// `high` ist der Default aus gutem Grund: Bei `low` haben Refuter
// nachweislich Code halluziniert und damit echte Findings fälschlich widerlegt.
// `low` nur für Smoke-Tests der Mechanik, nie für ein belastbares Urteil.
const EFFORT = cfg.effort || 'high'
const ALLOWED_EFFORTS = new Set(['low', 'medium', 'high', 'xhigh', 'max'])
if (!ALLOWED_EFFORTS.has(EFFORT)) {
  throw new Error(`Ungültiger effort-Wert "${EFFORT}". Erlaubt: low, medium, high, xhigh, max.`)
}
const REPO = cfg.repo || null   // null = cwd (= Projekt-Root)

// ---------------------------------------------------------------- Schemata

const FINDINGS = {
  type: 'object', additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          title: { type: 'string' },
          claim: { type: 'string' },
          failureScenario: { type: 'string' },
        },
        required: ['file', 'severity', 'title', 'claim', 'failureScenario'],
      },
    },
    notes: { type: 'string' },
  },
  required: ['findings', 'notes'],
}

const VERDICT = {
  type: 'object', additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'unverified'] },
    reasoning: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['verdict', 'reasoning'],
}

// ---------------------------------------------------------------- Prompts

/** Repo-Kontext für native Agents; sie starten im Session-cwd. */
const REPO_HINT = REPO ? `Arbeite im Repo ${REPO}. ` : ''
const READ_ONLY = 'Nur Analyse — keine Edits, keine Commits, keine Writes. '
const FINAL_ANSWER = ' Melde dein vollständiges Ergebnis immer in deiner finalen Antwort.'

const FINDER_AUFTRAG = d =>
  `${REPO_HINT}${READ_ONLY}Code-Review mit maximaler Sorgfalt. ` +
  `Untersuchungsgegenstand: ${SCOPE}. Perspektive "${d.key}": ${d.frage} ` +
  'Melde nur echte Defekte mit konkretem Fehlerszenario — keine Stilfragen, keine Spekulation.' +
  FINAL_ANSWER

const REFUTER_AUFTRAG = (beschreibung, lens) =>
  `${REPO_HINT}${READ_ONLY}Adversarische Gegenprüfung eines Code-Review-Findings. ` +
  'Deine primäre Aufgabe ist es, das Finding anhand des Codes zu WIDERLEGEN. ' +
  'Unterscheide aber strikt zwischen einer belegten Widerlegung und fehlender Prüfbarkeit.\n\n' +
  beschreibung + '\n\n' +
  `Prüfauftrag (${lens.key}): ${lens.frage}` + FINAL_ANSWER

const FINDER_SCHEMA_HINT =
  ' Fülle das Schema direkt: pro Defekt ein findings-Eintrag (file, line, severity ' +
  'critical|high|medium|low, title, claim = was genau falsch ist, failureScenario = ' +
  'konkretes Szenario Eingabe/Zustand → falsches Verhalten). Nichts Substanzielles ' +
  'gefunden → leeres findings-Array. notes = "ok" oder kurze Einschränkungen.'

const REFUTER_SCHEMA_HINT =
  '\n\nFülle das Schema direkt: verdict="refuted" nur bei konkreten Code-Belegen, ' +
  'die das behauptete Fehlerszenario widerlegen; verdict="confirmed" bei konkreten ' +
  'Belegen dafür; verdict="unverified" bei fehlendem Dateizugriff, unzureichenden ' +
  'Belegen oder anderer mangelnder Prüfbarkeit. reasoning = Begründung mit ' +
  'Code-Belegen (Datei:Zeile) beziehungsweise die genaue Ursache der fehlenden Prüfbarkeit.'

function finderCall(d) {
  return agent(FINDER_AUFTRAG(d) + FINDER_SCHEMA_HINT, {
    label: `find:${d.key}`, phase: 'Find', schema: FINDINGS,
    agentType: 'gpt', effort: EFFORT,
  })
}

function refuterCall(beschreibung, lens, label) {
  return agent(REFUTER_AUFTRAG(beschreibung, lens) + REFUTER_SCHEMA_HINT, {
    label, phase: 'Verify', schema: VERDICT,
    agentType: 'gpt', effort: EFFORT,
  })
}

const DEFAULT_DIMENSIONS = [
  { key: 'correctness', frage: 'Logikfehler, falsche Randfälle, verletzte Invarianten, Off-by-one, falsch behandelte Fehlerpfade.' },
  { key: 'concurrency', frage: 'Races, Deadlocks, ungeschützte read-modify-write-Zyklen, Zustände ohne Ausweg, Lifetime-Probleme von Timern und Prozessen.' },
  { key: 'io-process', frage: 'Prozess- und Stream-Handling: Deadlocks bei großen Ausgaben, verlorene Events, Puffergrenzen einschließlich UTF-8-Schnitten, Signal- und Exit-Behandlung.' },
  { key: 'api-contract', frage: 'Verletzte öffentliche Verträge: Exit-Codes, JSON-Felder, Flag-Semantik, argv-Layout, Persistenz-Kompatibilität alter Datenstände.' },
  { key: 'tests', frage: 'Welche Logik ist nicht oder nur scheinbar abgedeckt? Welche Tests bleiben grün, obwohl sie das Falsche prüfen, etwa Substring-Matches statt Struktur? Nur konkrete Fehlerszenarien melden.' },
  { key: 'docs', frage: 'Behauptungen in Doku oder Hilfetexten, die der Code nicht einlöst: Flags, Exit-Codes, zugesicherte Verhaltensweisen oder fehlende Optionen.' },
]

const LENSES = [
  { key: 'reality', frage: 'Lies den betroffenen Code vollständig und prüfe, ob die Behauptung faktisch stimmt. Achte darauf, ob der Kritiker Code übersehen hat, der das Problem bereits verhindert.' },
  { key: 'repro', frage: 'Konstruiere das konkrete Fehlerszenario. Kann es unter realistischen Bedingungen eintreten: erreichbarer Zustand, tatsächliche Aufrufer, vorhandene Guards? Ist es nicht erreichbar, gilt das Finding als widerlegt.' },
]

// ---------------------------------------------------------------- Ausführung

const DIMENSIONS = cfg.dimensions || DEFAULT_DIMENSIONS
if (!Array.isArray(DIMENSIONS) || DIMENSIONS.length === 0) {
  throw new Error('`dimensions` muss ein nicht leeres Array sein.')
}

log(`Scope: ${SCOPE} · Effort: ${EFFORT} · ${DIMENSIONS.length} Finder · Runner: gpt (nativ)`)
if (EFFORT === 'low') {
  log('WARNUNG: effort=low — Refuter halluzinieren auf dieser Stufe Code. Urteile sind unbrauchbar; nur als Smoke-Test verwenden.')
}

phase('Find')
const batches = await pipeline(
  DIMENSIONS,
  d => finderCall(d).then(result => ({ result })),
  (finderRun, d) => {
    const res = finderRun.result
    if (!res) {
      log(`FEHLER: find:${d.key} ist ohne Ergebnis fehlgeschlagen`)
      return {
        dimension: d.key,
        finderFailure: 'Nativer GPT-Finder lieferte kein Ergebnis.',
        findings: [],
      }
    }
    if (res.findings.length === 0) {
      const grund = res.notes && res.notes !== 'ok' ? ` (${res.notes})` : ''
      log(`find:${d.key} → keine Findings${grund}`)
      return { dimension: d.key, finderFailure: null, findings: [] }
    }
    log(`find:${d.key} → ${res.findings.length} Findings → Verify`)

    const findings = res.findings.map(finding => ({ finding, verdicts: [] }))
    const jobs = []
    const jobContexts = []
    res.findings.forEach((f, findingIndex) => {
      const beschreibung =
        `Datei: ${f.file}${f.line ? ':' + f.line : ''}\n` +
        `Titel: ${f.title}\n` +
        `Behauptung: ${f.claim}\n` +
        `Behauptetes Fehlerszenario: ${f.failureScenario}`
      LENSES.forEach(lens => {
        jobs.push(() =>
          refuterCall(beschreibung, lens, `verify:${d.key}-${findingIndex + 1}:${lens.key}`))
        jobContexts.push({ findingIndex, lens: lens.key })
      })
    })

    return parallel(jobs).then(verdictResults => {
      jobContexts.forEach((context, index) => {
        findings[context.findingIndex].verdicts.push({
          lens: context.lens,
          verdict: verdictResults[index] || null,
        })
      })
      return { dimension: d.key, finderFailure: null, findings }
    })
  }
)

// ---------------------------------------------------------------- Auswertung

const failedFinders = []
const reviewedFindings = []
for (let index = 0; index < DIMENSIONS.length; index++) {
  const batch = batches[index]
  if (!batch) {
    failedFinders.push({
      dimension: DIMENSIONS[index].key,
      reason: 'Finder-Pipeline wurde ohne Ergebnis beendet.',
    })
    continue
  }
  if (batch.finderFailure) {
    failedFinders.push({ dimension: batch.dimension, reason: batch.finderFailure })
    continue
  }
  batch.findings.forEach(entry => reviewedFindings.push({
    dimension: batch.dimension,
    finding: entry.finding,
    verdicts: entry.verdicts,
  }))
}

if (failedFinders.length === DIMENSIONS.length) {
  throw new Error(
    'Alle nativen GPT-Finder sind fehlgeschlagen. Prüfe, ob das WhisperM8-GPT-Backend ' +
    'aktiv ist und starte bei einer alten Agent-Registry eine neue Chat-Session.'
  )
}

const confirmed = [], plausible = [], dropped = [], failedRefuters = []
for (const entry of reviewedFindings) {
  for (const lens of LENSES) {
    if (!entry.verdicts.some(v => v.lens === lens.key)) {
      entry.verdicts.push({ lens: lens.key, verdict: null })
    }
  }

  entry.verdicts = entry.verdicts.map(v => ({
    lens: v.lens,
    status: v.verdict ? 'completed' : 'failed',
    verdict: v.verdict ? v.verdict.verdict : null,
    reasoning: v.verdict ? v.verdict.reasoning : 'Nativer GPT-Refuter lieferte kein Urteil.',
  }))

  const failures = entry.verdicts.filter(v => v.status === 'failed')
  const confirmedCount = entry.verdicts.filter(v => v.verdict === 'confirmed').length
  const refutedCount = entry.verdicts.filter(v => v.verdict === 'refuted').length

  failures.forEach(v => failedRefuters.push({
    dimension: entry.dimension,
    file: entry.finding.file,
    title: entry.finding.title,
    lens: v.lens,
    reason: v.reasoning,
  }))

  if (failures.length === 0 && confirmedCount === LENSES.length) confirmed.push(entry)
  else if (failures.length === 0 && refutedCount === LENSES.length) dropped.push(entry)
  else plausible.push(entry)
}

const complete = failedFinders.length === 0 && failedRefuters.length === 0
log(`Verify fertig: ${confirmed.length} bestätigt · ${plausible.length} strittig · ${dropped.length} widerlegt`)
if (!complete) {
  log(`UNVOLLSTÄNDIG: ${failedFinders.length} Finder und ${failedRefuters.length} Refuter ohne belastbares Ergebnis`)
} else if (confirmed.length === 0 && plausible.length === 0) {
  log('Keine überlebenden Findings — das heißt „nichts gefunden“, nicht „nichts da“.')
}

return {
  scope: SCOPE,
  effort: EFFORT,
  runner: 'gpt',
  complete,
  failedFinders,
  failedRefuters,
  confirmed,
  plausible,
  dropped,
}
