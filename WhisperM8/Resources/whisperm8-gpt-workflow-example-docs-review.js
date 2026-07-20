export const meta = {
  name: 'gpt-docs-review',
  description: 'GPT-only Doku-Verifikation gegen den Code mit gezielter Aktualisierung',
  phases: [
    { title: 'Prüfen', detail: 'GPT-Prüfer verifizieren Behauptungen gegen den Code' },
    { title: 'Fixen', detail: 'GPT-Fixer aktualisieren Pakete mit bestätigten Abweichungen' },
  ],
}

const REPO = args?.repo
const UPDATED_AT = args?.updatedAt
if (!REPO || !UPDATED_AT) {
  throw new Error('Workflow benötigt args.repo und args.updatedAt')
}

const ISSUES_SCHEMA = {
  type: 'object',
  properties: {
    issues: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          claim: { type: 'string' },
          problem: { type: 'string' },
          evidence: { type: 'string' },
          suggested_fix: { type: 'string' },
          severity: { type: 'string', enum: ['falsch', 'veraltet', 'unvollstaendig'] },
        },
        required: ['file', 'claim', 'problem', 'evidence', 'suggested_fix', 'severity'],
        additionalProperties: false,
      },
    },
    checkedFiles: { type: 'integer' },
  },
  required: ['issues', 'checkedFiles'],
  additionalProperties: false,
}

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    fixedFiles: { type: 'array', items: { type: 'string' } },
    skipped: {
      type: 'array',
      items: {
        type: 'object',
        properties: { file: { type: 'string' }, reason: { type: 'string' } },
        required: ['file', 'reason'],
        additionalProperties: false,
      },
    },
  },
  required: ['fixedFiles', 'skipped'],
  additionalProperties: false,
}

const PACKS = [
  { key: 'feat-mcp-a', desc: 'MCP/Automatisierung Teil 1', glob: 'docs/features/automatisierung-mcp', filter: 'Dateien alphabetisch bis einschließlich Buchstabe m (README immer dazu)' },
  { key: 'feat-mcp-b', desc: 'MCP/Automatisierung Teil 2', glob: 'docs/features/automatisierung-mcp', filter: 'Dateien alphabetisch ab Buchstabe n' },
  { key: 'feat-kampagnen-a', desc: 'Kampagnen-Docs Teil 1 (README, Lifecycle, Akquise-Import, overview, settings)', glob: 'docs/features/kampagnen', filter: 'README.md, akquise-import.md, campaign-lifecycle-uebersicht.md, ai-generierung.md, ARCHITECTURE.md sowie die Unterordner overview/ und settings/' },
  { key: 'feat-kampagnen-b', desc: 'Kampagnen-Docs Teil 2 (sequences, onboarding, feedback, review, leads)', glob: 'docs/features/kampagnen', filter: 'die Unterordner sequences/, onboarding/, feedback/, review/ und leads/' },
  { key: 'feat-plattform', desc: 'Plattform-Verwaltung', glob: 'docs/features/plattform-verwaltung', filter: 'alle' },
  { key: 'feat-ai', desc: 'AI-Anreicherung', glob: 'docs/features/ai-anreicherung', filter: 'alle' },
  { key: 'feat-leads', desc: 'Leads-Docs + features-README', glob: 'docs/features/leads docs/features/README.md', filter: 'alle' },
  { key: 'feat-erste-schritte', desc: 'Erste Schritte / Dashboard', glob: 'docs/features/erste-schritte', filter: 'alle' },
  { key: 'feat-export-wl', desc: 'Export-Integrationen + White-Label (features)', glob: 'docs/features/export-integrationen docs/features/white-label', filter: 'alle' },
  { key: 'ops-infra-a', desc: 'Operations/Infrastructure Teil 1', glob: 'docs/operations/infrastructure', filter: 'Dateien/Unterordner alphabetisch bis einschließlich f (z.B. auto-scaling, fair-scheduler)' },
  { key: 'ops-infra-b', desc: 'Operations/Infrastructure Teil 2', glob: 'docs/operations/infrastructure', filter: 'Dateien/Unterordner alphabetisch ab g' },
  { key: 'ops-rest', desc: 'Operations Rest (white-label, testing, stripe, Runbooks, JOB-QUEUE, cli-diagnose)', glob: 'docs/operations', filter: 'alles AUSSER dem Unterordner infrastructure/' },
  { key: 'plans', desc: 'Plans (nur Status-Check: erledigt/historisch korrekt markiert? Widerspricht ein als offen markierter Plan dem umgesetzten Code?)', glob: 'docs/plans', filter: 'alle — aber NUR Frontmatter/Status und grobe Übereinstimmung prüfen, keine Detail-Verifikation historischer Pläne' },
  { key: 'referenz', desc: 'Referenz', glob: 'docs/referenz', filter: 'alle' },
  { key: 'guides', desc: 'Guides', glob: 'docs/guides', filter: 'alle' },
  { key: 'architecture', desc: 'Architektur (FRONTEND.md ist nach dem Redesign besonders verdächtig)', glob: 'docs/architecture', filter: 'alle' },
  { key: 'database-root', desc: 'Database-Docs + docs/README.md + doc-system.config.md', glob: 'docs/database docs/README.md docs/doc-system.config.md', filter: 'alle' },
]

const CHECK_COMMON = `Du bist Doku-Auditor im Repo ${REPO}. Der Branch redesign (großes Frontend-Redesign: neue Leads-Workbench, Kampagnenfluss-Liste statt CampaignListTab, TanStack Query v5, SSE-Job-Tracking statt Polling, Dark Mode deaktiviert, shadcn-Komponenten, Research-Prompt vom User in Agenten-Profile migriert) steht kurz vor dem PR nach develop. Die Doku unter docs/ muss zum CODE DIESES BRANCHES passen.

Auftrag: Verifiziere in deinem Paket jede prüfbare Behauptung gegen den aktuellen Code:
- Datei-/Komponenten-/Klassen-Pfade (existieren sie? Read/Glob/Grep benutzen)
- Routen, Statuswerte, Enum-Namen, Feldnamen, Query-/Command-Namen
- Konsolen-Befehle (bin/console-Commands existieren? Flags korrekt?)
- Architekturaussagen (Polling vs. SSE, Theme/Dark-Mode, Komponenten-Struktur)
- interne Links auf andere docs-Dateien (Ziel existiert?)

Melde NUR belegbare Abweichungen (severity: falsch = Aussage stimmt nicht; veraltet = stimmte früher, Code ist weiter; unvollstaendig = neues Verhalten fehlt komplett, wo die Datei es abdecken müsste). evidence = konkreter Code-Beleg (Pfad, ggf. Zeile). KEINE Stil-/Formulierungskritik, keine Wünsche. Ignoriere docs/archive und docs/leadgen vollständig. Antworte NUR über das StructuredOutput-Tool, alle Texte auf Deutsch.`

phase('Prüfen')
log(`Starte ${PACKS.length} Doku-Prüfer (GPT)`)

const results = await pipeline(
  PACKS,
  (p) =>
    agent(
      `${CHECK_COMMON}\n\nDein Paket: ${p.key} — ${p.desc}\nBasis: ${p.glob}\nAbgrenzung: ${p.filter}\nErmittle die Dateiliste selbst (Glob/ls) und setze checkedFiles auf die Anzahl geprüfter Dateien.`,
      { label: `check:${p.key}`, phase: 'Prüfen', schema: ISSUES_SCHEMA, agentType: 'gpt' }
    ),
  (checkResult, p) => {
    if (!checkResult) {
      return { pack: p.key, checkedFiles: 0, issues: [], fix: null, failed: true }
    }
    const issues = checkResult.issues ?? []
    if (!issues.length) return { pack: p.key, checkedFiles: checkResult.checkedFiles ?? 0, issues: [], fix: null, failed: false }
    const issueList = issues
      .map((i, n) => `${n + 1}. [${i.severity}] ${i.file}\n   Behauptung: ${i.claim}\n   Problem: ${i.problem}\n   Beleg: ${i.evidence}\n   Vorschlag: ${i.suggested_fix}`)
      .join('\n')
    return agent(
      `Du bist Doku-Redakteur im Repo ${REPO}. Ein Auditor hat im Doku-Paket „${p.key}" (${p.glob}) folgende Abweichungen zum Code gemeldet:\n\n${issueList}\n\nAuftrag:\n1. Verifiziere JEDE Abweichung selbst am Code (Read/Grep), bevor du sie fixst. Nicht nachvollziehbare Meldungen NICHT anwenden, sondern unter skipped mit Begründung melden.\n2. Fixe bestätigte Abweichungen minimal-invasiv per Edit direkt in den Doku-Dateien: nur die falschen/veralteten Aussagen korrigieren, Stil und Struktur der Datei beibehalten, deutsche Umlaute korrekt (nie ae/ue/oe). Bei geänderten Dateien mit Frontmatter das Feld updated auf ${UPDATED_AT} setzen.\n3. Du darfst AUSSCHLIESSLICH Markdown-Dateien innerhalb von ${p.glob} ändern. NIEMALS Code-Dateien, docs/archive, docs/leadgen oder Dateien anderer Pakete anfassen. NIEMALS git-Befehle ausführen, die den Zustand ändern (kein add/commit/checkout).\n4. Melde am Ende über StructuredOutput: fixedFiles (geänderte Dateien) und skipped (nicht angewendete Meldungen mit Grund).`,
      { label: `fix:${p.key}`, phase: 'Fixen', schema: FIX_SCHEMA, agentType: 'gpt' }
    ).then((fix) => ({
      pack: p.key,
      checkedFiles: checkResult.checkedFiles ?? 0,
      issues,
      fix,
      failed: !fix,
    }))
  }
)

const ok = results.filter(Boolean)
const failedPacks = ok.filter((result) => result.failed).map((result) => result.pack)
const totalIssues = ok.reduce((s, r) => s + r.issues.length, 0)
const totalFixed = ok.reduce((s, r) => s + (r.fix?.fixedFiles?.length ?? 0), 0)
if (failedPacks.length) log(`ACHTUNG: ${failedPacks.length} Pakete unvollständig: ${failedPacks.join(', ')}`)
log(`Fertig: ${ok.reduce((s, r) => s + r.checkedFiles, 0)} Dateien geprüft, ${totalIssues} Abweichungen, ${totalFixed} Dateien aktualisiert`)

return {
  packs: ok,
  failedPacks,
  incomplete: failedPacks.length > 0 || results.some((result) => !result),
  totals: { issues: totalIssues, fixedFiles: totalFixed, droppedPacks: results.filter((result) => !result).length },
}
