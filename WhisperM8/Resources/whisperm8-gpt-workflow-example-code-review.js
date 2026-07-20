export const meta = {
  name: 'gpt-code-review',
  description: 'GPT-only Code-Review mit Find- und adversarialer Verify-Stufe',
  phases: [
    { title: 'Find', detail: 'Chunk-Reviewer + Querschnitts-Angles (GPT)' },
    { title: 'Verify', detail: 'adversariale GPT-Verifikation pro Finding' },
  ],
}

const REPO = args?.repo
const RANGE = args?.range
if (!REPO || !RANGE) {
  throw new Error('Workflow benötigt args.repo und args.range')
}

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      maxItems: 8,
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          summary: { type: 'string' },
          failure_scenario: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
        },
        required: ['file', 'line', 'summary', 'failure_scenario', 'severity'],
        additionalProperties: false,
      },
    },
  },
  required: ['findings'],
  additionalProperties: false,
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'PLAUSIBLE', 'REFUTED'] },
    reasoning: { type: 'string' },
  },
  required: ['verdict', 'reasoning'],
  additionalProperties: false,
}

const COMMON = `Du bist ein akribischer Code-Reviewer für einen großen Redesign-PR (Branch redesign → develop) im Repo ${REPO} (Symfony 7.4 API + React 19 + TypeScript + TanStack Query v5 + Vite + Ant Design/shadcn-Mix). Arbeite im Repo-Verzeichnis.

Vorgehen:
1. Hole den Diff deines Pakets: git -C ${REPO} diff ${RANGE} -- <pfade>
2. Lies jeden Hunk Zeile für Zeile. Lies zusätzlich die umgebenden Funktionen/Dateien im aktuellen Arbeitsstand (Read-Tool), nicht nur den Diff.
3. Frage bei jeder Zeile: welcher Input, State, Timing- oder Edge-Case macht sie falsch? Suche: invertierte/falsche Bedingungen, Off-by-one, null/undefined-Zugriffe, fehlendes await, falsy-0-Checks, Copy-Paste-Fehler, verschluckte Fehler in catch, Race-Conditions, stale Closures, falsche useEffect/useMemo-Dependency-Arrays, kaputte oder fehlende Query-Invalidierung, Memory-Leaks (nicht abgeräumte Subscriptions/Timer), kaputte i18n/Umlaute.
4. Bugs in UNVERÄNDERTEN Zeilen einer angefassten Funktion zählen ebenfalls.

Melde bis zu 8 Kandidaten. Jedes Finding braucht ein konkretes failure_scenario (Input/State → falsches Verhalten). Kein Stil-Nörgeln, keine reinen Geschmacksfragen. Lass aber keinen halb-geglaubten Kandidaten weg — eine zweite Stufe verifiziert adversarial; dein Job ist Recall. Antworte NUR über das StructuredOutput-Tool. summary und failure_scenario auf Deutsch.`

const CHUNKS = [
  { key: 'api-core', focus: 'Symfony-Backend: Research-Prompt-Entfernung (User-Entity, Handler, Services), DuplicateCampaign, Lead-Listing-Queries, Repositories. Prüfe besonders: bleibt Verhalten für Bestandsdaten korrekt, DQL/SQL-Korrektheit, CQRS-Konventionen.', paths: ['api/src', 'api/migrations'] },
  { key: 'api-tests-i18n', focus: 'PHP-Tests (decken sie das geänderte Verhalten noch ab? wurden Assertions abgeschwächt?) und api/translations/messages.de.yaml (Platzhalter, Umlaute, verwaiste/fehlende Keys — gleiche Keys wie im Client-Code verwendet?).', paths: ['api/tests', 'api/translations/messages.de.yaml'] },
  { key: 'query-hooks', focus: 'TanStack-Query-Hooks und Job-Tracking: Query-Key-Konsistenz, Invalidierungspfade, optimistische Patches, SSE-Subscription-Lifecycle (Cleanup!), Debounce-Logik, stale Closures.', paths: ['client/src/hooks/leads', 'client/src/hooks/useJobQueryInvalidation.ts', 'client/src/hooks/useJobStatusUpdates.ts', 'client/src/hooks/useLeadFilters.ts', 'client/src/hooks/useLeadListLogic.ts', 'client/src/hooks/useSavedViews.ts', 'client/src/hooks/useLeadColumns.ts', 'client/src/lib/queryClient.ts'] },
  { key: 'leads-tabs', focus: 'LeadsTab, LaunchTab (Review-Queue mit useInfiniteQuery, approve/reject mit optimistischen Cache-Patches über InfiniteData-Pages), AllLeads-Seiten, Campaign-Routen. Prüfe besonders die Cache-Patch-Logik (patchReviewCache), Auswahl-Effekte, Zähler (statusCounts/exportCounts), Contact-Gate-Notice.', paths: ['client/src/pages/campaigns/tabs/LeadsTab.tsx', 'client/src/pages/campaigns/tabs/LaunchTab.tsx', 'client/src/pages/leads', 'client/src/pages/campaigns/routes'] },
  { key: 'leads-detail', focus: 'Lead-Detail-Ansicht: DetailRail, LeadDetailView, MarkdownReport und leadDetailView.css (Token-Aliase auf Brand-Tokens, Verdict-Kanten, keine Dark-Mode-Reste, keine hartkodierten Farben die dem Token-System widersprechen).', paths: ['client/src/components/leads/detail'] },
  { key: 'leads-widgets', focus: 'Leads-Tabelle, Toolbar/ContextBand, FilterRail, LeadStageFlow, ReviewQueue: gelöschte Komponenten (Toolbar, LeadStatusDots, SelectAllBanner, QuickFilterChips) — ist deren Verhalten ersetzt oder ersatzlos verloren? Prop-Verträge der neuen Komponenten, Filter-Chips-Logik.', paths: ['client/src/components/leads/table', 'client/src/components/leads/toolbar', 'client/src/components/leads/filter-rail', 'client/src/components/leads/status', 'client/src/components/leads/review', 'client/src/components/leads/lead-tip.css'] },
  { key: 'leads-profile', focus: 'LeadProfileModal, OverviewTab, Sidebar: Datenfluss, null-Sicherheit bei fehlenden Lead-Feldern, i18n.', paths: ['client/src/components/leads/profile'] },
  { key: 'campaign-list', focus: 'Neue Kampagnenfluss-Liste: Campaigns.tsx, CampaignFlowRow/Controls/CreateInline/DuplicateDialog/stages, useCampaignList, campaign-flow.css, dateFormat. Prüfe: Header-Effekt-Dependencies, Akquise-Import-Integration (isAkquiseTenant), Statusfilter/Suche/Sortierung, Duplikat-Guards.', paths: ['client/src/pages/Campaigns.tsx', 'client/src/components/campaigns/list', 'client/src/hooks/useCampaignList.ts', 'client/src/styles/campaign-flow.css', 'client/src/utils/dateFormat.ts'] },
  { key: 'campaign-detail', focus: 'CampaignDetail, SequencesTab, AgentsTab, SequenceComposer/StepRail/VariablesSidebar, AIVariableModal, gelöschte ResearchPromptModal (Referenzen übrig?), FeedbackInputInline.', paths: ['client/src/pages/campaigns/CampaignDetail.tsx', 'client/src/pages/campaigns/tabs/SequencesTab.tsx', 'client/src/pages/campaigns/tabs/AgentsTab.tsx', 'client/src/components/campaigns/sequences', 'client/src/components/campaigns/variables', 'client/src/components/campaigns/feedback'] },
  { key: 'auth', focus: 'OIDC-Auth nach develop-Merge: UserContext (login/logout/changePassword, SigninState/returnTo), oidcConfig, Register.tsx, models/User (tenantKey), userApi (verifyApiKey; updateResearchPrompt entfernt — Aufrufer übrig?), gelöschte ResearchSettings. Open-Redirect-Sicherheit von returnTo.', paths: ['client/src/auth', 'client/src/components/security/Register.tsx', 'client/src/models/User.ts', 'client/src/api/userApi.ts', 'client/src/components/settings'] },
  { key: 'app-shell', focus: 'App.tsx (16 lazy-Routen — jede Route erreichbar? Named-Export-Mapping korrekt?), main.jsx (Import-Reihenfolge fonts.css), MainLayout (useJobQueryInvalidation gemountet), PageHeader-Context, ShellTabs, ThemeContext (Dark Mode tot — kein Runtime-Pfad zu dark?), BrandContext, brandBootstrap, index.html, vite.config, tsconfig, package.json.', paths: ['client/src/App.tsx', 'client/src/main.jsx', 'client/src/components/layout/MainLayout.tsx', 'client/src/context', 'client/src/components/ui/ShellTabs.tsx', 'client/src/config', 'client/index.html', 'client/vite.config.js', 'client/tsconfig.json', 'client/package.json', 'client/components.json'] },
  { key: 'ui-kit', focus: 'shadcn-UI-Komponenten (button, dialog, select, table, tooltip, …), lib/utils, globals.css, fonts.css (@font-face-Pfade existieren im node_modules-Paket?), antdTheme, tokens.ts. Prüfe: Accessibility-Grundlagen, CSS-Spezifitätskonflikte mit Bestand, tote ThemeToggle-Referenzen.', paths: ['client/src/components/ui', 'client/src/lib/utils.ts', 'client/src/styles'] },
  { key: 'dashboard-misc', focus: 'Dashboard (gelöschte ActionInbox/CampaignsOverviewTable/Charts — Referenzen übrig? Ersatz vorhanden?), Onboarding-Chat-Komponenten, tourSteps (referenzierte DOM-Anker existieren noch?), McpInfo, StyleGuide, TenantForm.', paths: ['client/src/components/dashboard', 'client/src/components/campaigns/onboarding/chat', 'client/src/components/tour', 'client/src/pages/McpInfo', 'client/src/pages/StyleGuide.tsx', 'client/src/pages/styleguide', 'client/src/components/admin/tenants'] },
  { key: 'api-client-models', focus: 'Axios-API-Clients (admin*, campaignApi, leadApi, leadCsvApi, paymentApi) und Models (ApiResponse-Generics, Campaign, Lead): passen die Typen zu den tatsächlichen Symfony-Responses? ApiResponse<X> vs ApiResponse<X[]>-Korrekturen konsistent?', paths: ['client/src/api', 'client/src/models'] },
  { key: 'admin-designs-a', focus: 'Design-Prototypen (statische Mockups unter /admin/designs): NUR schwere Fehler melden — Build-/Import-Bruch, Crashes beim Rendern, kaputte Registrierung in types.ts/AdminDesigns. Keine Detailkritik an Mockup-Inhalten.', paths: ['client/src/pages/admin/designs/campaigns-almanach', 'client/src/pages/admin/designs/campaigns-archiv', 'client/src/pages/admin/designs/campaigns-fluss', 'client/src/pages/admin/designs/campaigns-karten', 'client/src/pages/admin/designs/campaigns-ledger', 'client/src/pages/admin/designs/campaigns-leitstand', 'client/src/pages/admin/designs/campaigns-register', 'client/src/pages/admin/designs/campaigns-workdesk', 'client/src/pages/admin/designs/brand-guide', 'client/src/pages/admin/designs/_shared'] },
  { key: 'admin-designs-b', focus: 'Design-Prototypen Teil 2 + Registry: NUR schwere Fehler melden — Build-/Import-Bruch, Crashes, kaputte Registrierung (types.ts, AdminDesigns.tsx, AdminDesignDetail.tsx). Keine Detailkritik an Mockup-Inhalten.', paths: ['client/src/pages/admin/designs/dashboard-agenda', 'client/src/pages/admin/designs/dashboard-briefing', 'client/src/pages/admin/designs/dashboard-cockpit', 'client/src/pages/admin/designs/dashboard-ledger', 'client/src/pages/admin/designs/dashboard-afterfold', 'client/src/pages/admin/designs/dashboard-ops-compact', 'client/src/pages/admin/designs/dashboard-split-view', 'client/src/pages/admin/designs/lead-detail-f-header', 'client/src/pages/admin/designs/lead-detail-scroll', 'client/src/pages/admin/designs/lead-status', 'client/src/pages/admin/designs/leads-final', 'client/src/pages/admin/designs/leads-subheader', 'client/src/pages/admin/designs/leads-workbench', 'client/src/pages/admin/designs/shell-header', 'client/src/pages/admin/designs/types.ts', 'client/src/pages/admin/AdminDesigns.tsx', 'client/src/pages/admin/AdminDesignDetail.tsx'] },
  { key: 'docs-rules-diff', focus: 'Im Diff geänderte Doku und Rules: FRONTEND.md, features-Docs, plans, .claude/rules — stimmen die Aussagen mit dem Code auf diesem Branch überein? (Nur die im Diff enthaltenen Dateien.)', paths: ['docs/architecture/FRONTEND.md', 'docs/features/erste-schritte/dashboard/README.md', 'docs/features/kampagnen/README.md', 'docs/plans/app-redesign', 'docs/plans/frontend-shadcn-migration', '.claude/rules', '.claude/skills/admin-design'] },
]

const ANGLES = [
  { key: 'removed-behavior', prompt: `${COMMON}\n\nDein Spezialauftrag: REMOVED-BEHAVIOR-AUDIT. Der Diff (git -C ${REPO} diff ${RANGE} -- ':!docs/leadgen' ':!client/package-lock.json' ':!.agents') löscht ~7100 Zeilen, darunter ganze Dateien (CampaignListTab, Toolbar, LeadStatusDots, SelectAllBanner, QuickFilterChips, ActionInbox, CampaignsOverviewTable, PipelineLadder, ThemeToggle, ResearchPromptModal, ResearchSettings, UpdateResearchPrompt-Backend). Für jede gelöschte oder ersetzte Zeile/Datei: Welche Invariante, welches Feature oder welchen Guard hat sie durchgesetzt — und wo lebt das im neuen Code weiter? Grep im aktuellen Stand nach der Re-Etablierung. Findest du sie nicht, ist das ein Kandidat (Feature-Verlust, entfernter Guard, gelöschter Test der einen echten Fall abdeckte, verwaiste Referenzen auf Gelöschtes).` },
  { key: 'merge-audit', prompt: `${COMMON}\n\nDein Spezialauftrag: MERGE-AUDIT von Commit e42cd0f16 (Merge origin/develop in redesign, 9 manuell gelöste Konflikte). Ermittle beide Eltern (git log --merges, git show e42cd0f16). Für jede Konfliktdatei (git show e42cd0f16 --name-only; besonders Campaigns.tsx, App.tsx, AuthProvider/UserContext/AxiosTokenSync/oidcConfig, brandBootstrap, models/User, userApi, package.json): vergleiche das Merge-Ergebnis mit BEIDEN Elternseiten (git show <parent1>:<pfad> / <parent2>:<pfad>). Ging develop-Verhalten verloren (z.B. Akquise-Import-Details, returnTo-Flows, verifyApiKey) oder redesign-Verhalten? Melde jede Stelle, wo das Merge-Ergebnis eine Seite stillschweigend verliert.` },
  { key: 'cross-file-tracer', prompt: `${COMMON}\n\nDein Spezialauftrag: CROSS-FILE-TRACING. Für jede im Diff geänderte exportierte Funktion/Hook-Signatur/Komponenten-Props (git -C ${REPO} diff ${RANGE} --name-only -- client/src api/src): Grep alle Call-Sites im aktuellen Stand und prüfe, ob die Änderung eine Aufrufstelle bricht — neue Precondition, geänderte Return-Shape (z.B. Hooks useLeadData/useAllLeadsData/useJobPolling), neue Pflicht-Props, entfernte Exports, geänderte Query-Key-Formate zwischen Producer und Invalidierer. Auch API-Verträge Client↔Symfony (Response-Shapes) prüfen, wo der Diff eine Seite ändert.` },
  { key: 'query-cache', prompt: `${COMMON}\n\nDein Spezialauftrag: QUERY-CACHE-KONSISTENZ. Sammle ALLE queryKey-Definitionen und ALLE invalidateQueries/setQueryData-Aufrufe im Client (Grep nach queryKey, invalidateQueries, setQueryData, useQuery, useInfiniteQuery). Prüfe: (1) trifft jede Invalidierung per Prefix wirklich die Keys, die sie treffen soll — und keine zu wenig? (2) patchen optimistische setQueryData-Updates exakt die Datenform (InfiniteData-Pages vs. flache Records)? (3) Races: SSE-Invalidierung (useJobQueryInvalidation, 1,5s-Debounce) vs. optimistische Patches vs. keepPreviousData — kann ein stale Overwrite entstehen? (4) filterKey-Serialisierung stabil (JSON.stringify-Reihenfolge)?` },
  { key: 'security-auth', prompt: `${COMMON}\n\nDein Spezialauftrag: SECURITY/AUTH-REVIEW des Diffs. Schwerpunkte: returnTo/Redirect-Handling (client/src/auth/returnTo.ts, oidcConfig, UserContext, AxiosTokenSync) — Open-Redirect möglich? sessionStorage-Nutzung (POST_LOGOUT_REDIRECT_KEY) manipulierbar? Token-Handling im Query-Layer (landen Bearer-Tokens in Query-Keys/Logs?), dangerouslySetInnerHTML/Markdown-Rendering (MarkdownReport — XSS über Lead-Recherche-Inhalte?), CSV-Import/Export-Injection, Backend: Research-Prompt-Migration-Command (SQL-Injection, Mandantentrennung), neue Lead-Listing-Query-Parameter (Autorisierung pro User?).` },
  { key: 'conventions', prompt: `${COMMON}\n\nDein Spezialauftrag: KONVENTIONS-CHECK. Lies ${REPO}/CLAUDE.md und die relevanten Rules unter ${REPO}/.claude/rules/ (frontend/, api/, php/). Prüfe den Diff (git -C ${REPO} diff ${RANGE} -- client/src api/src ':!client/package-lock.json') auf klare Verstöße: CQRS-Muster im Backend, EntityMapper-Konventionen, React-Patterns-Rule, header-tabs-Rule, deutsche UI-Texte mit korrekten Umlauten (nie ae/ue/oe als Ersatz), hartkodierte deutsche Strings wo t()-i18n üblich ist, console.log-Reste, auskommentierter Code. Nur Verstöße melden, bei denen du die exakte Regel zitieren kannst (Regelpfad in summary nennen).` },
]

phase('Find')
log(`Starte ${CHUNKS.length} Chunk-Reviewer + ${ANGLES.length} Querschnitts-Angles (alle GPT)`)

const chunkThunks = CHUNKS.map((c) => () =>
  agent(
    `${COMMON}\n\nDein Review-Paket: ${c.key}\nFokus: ${c.focus}\nPfade (für git diff und Reads): ${c.paths.join(' ')}\nDiff-Befehl: git -C ${REPO} diff ${RANGE} -- ${c.paths.map((p) => `'${p}'`).join(' ')}`,
    { label: `find:${c.key}`, phase: 'Find', schema: FINDINGS_SCHEMA, agentType: 'gpt' }
  ).then((r) => ({
    source: c.key,
    failed: !r,
    findings: (r?.findings ?? []).map((f) => ({ ...f, source: c.key })),
  }))
)
const angleThunks = ANGLES.map((a) => () =>
  agent(a.prompt, { label: `angle:${a.key}`, phase: 'Find', schema: FINDINGS_SCHEMA, agentType: 'gpt' })
    .then((r) => ({
      source: a.key,
      failed: !r,
      findings: (r?.findings ?? []).map((f) => ({ ...f, source: a.key })),
    }))
)

// Barrier ist hier gewollt: Dedup braucht alle Kandidaten auf einmal.
const finderSources = [...CHUNKS.map((c) => c.key), ...ANGLES.map((a) => a.key)]
const finderResults = await parallel([...chunkThunks, ...angleThunks])
const failedFinders = finderResults
  .map((result, index) => (!result || result.failed ? finderSources[index] : null))
  .filter(Boolean)
const raw = finderResults.filter(Boolean).flatMap((result) => result.findings)
if (failedFinders.length) log(`ACHTUNG: ${failedFinders.length} Finder ausgefallen: ${failedFinders.join(', ')}`)
log(`${raw.length} Kandidaten gesammelt`)

const seen = new Map()
for (const f of raw) {
  const key = `${f.file}:${f.line}`
  const prev = seen.get(key)
  const rank = { critical: 3, major: 2, minor: 1 }
  if (!prev || (rank[f.severity] ?? 0) > (rank[prev.severity] ?? 0)) seen.set(key, f)
}
const deduped = [...seen.values()]
const rank = { critical: 3, major: 2, minor: 1 }
deduped.sort((a, b) => (rank[b.severity] ?? 0) - (rank[a.severity] ?? 0))

const CAP = 45
const toVerify = deduped.slice(0, CAP)
if (deduped.length > CAP) log(`ACHTUNG: ${deduped.length - CAP} Kandidaten (niedrigste Severity) nicht verifiziert — im Ergebnis als unverified gelistet`)
log(`${deduped.length} nach Dedup, ${toVerify.length} gehen in die Verifikation`)

phase('Verify')
const verificationResults = await parallel(
  toVerify.map((f) => () =>
    agent(
      `Du bist ein adversarialer Verifier im Repo ${REPO}. Prüfe dieses Code-Review-Finding und versuche aktiv, es zu WIDERLEGEN.\n\nFinding:\n- Datei: ${f.file}\n- Zeile: ${f.line}\n- Behauptung: ${f.summary}\n- Failure-Szenario: ${f.failure_scenario}\n- Quelle: ${f.source}\n\nVorgehen: Lies die Datei (aktueller Arbeitsstand) und den relevanten Diff (git -C ${REPO} diff ${RANGE} -- '${f.file}'). Verfolge bei Bedarf Call-Sites per Grep.\n\nUrteil:\n- CONFIRMED: du kannst das Failure-Szenario am Code konkret nachvollziehen.\n- REFUTED: NUR mit Beweis — zitiere die Zeile/den Guard/die Invariante, die das Szenario unmöglich macht, oder zeige, dass die Behauptung faktisch falsch ist. \n- PLAUSIBLE: alles andere. Realistische Race-Conditions, seltene-aber-erreichbare Pfade, Boundary-Fälle sind PLAUSIBLE, nicht REFUTED — „spekulativ" ist KEIN Widerlegungsgrund.\n\nreasoning auf Deutsch, mit Zeilenzitaten. Antworte NUR über das StructuredOutput-Tool.`,
      { label: `verify:${f.file.split('/').pop()}:${f.line}`, phase: 'Verify', schema: VERDICT_SCHEMA, agentType: 'gpt' }
    ).then((v) => ({ ...f, verdict: v?.verdict ?? 'UNVERIFIED', reasoning: v?.reasoning ?? 'Verifier lieferte kein Ergebnis.' }))
  )
)
const verified = verificationResults.map((result, index) => result ?? ({
  ...toVerify[index],
  verdict: 'UNVERIFIED',
  reasoning: 'Verifier ist fehlgeschlagen.',
}))

const kept = verified.filter((f) => f.verdict === 'CONFIRMED' || f.verdict === 'PLAUSIBLE')
const unverified = [
  ...verified.filter((f) => f.verdict === 'UNVERIFIED'),
  ...deduped.slice(CAP),
]
kept.sort((a, b) => (rank[b.severity] ?? 0) - (rank[a.severity] ?? 0))
log(`Fertig: ${kept.length} Findings überleben, ${unverified.length} bleiben unverifiziert`)

return {
  confirmed: kept.filter((f) => f.verdict === 'CONFIRMED'),
  plausible: kept.filter((f) => f.verdict === 'PLAUSIBLE'),
  unverified,
  failedFinders,
  incomplete: failedFinders.length > 0 || unverified.length > 0,
  refutedCount: verified.filter((f) => f.verdict === 'REFUTED').length,
  rawCount: raw.length,
}
