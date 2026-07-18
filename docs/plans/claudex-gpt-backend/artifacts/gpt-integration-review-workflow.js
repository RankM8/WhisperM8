export const meta = {
  name: 'gpt-integration-review',
  description: 'GPT-Review der gesamten GPT-Backend-Integration (ausschliesslich native gpt-Agents)',
  phases: [
    { title: 'Review', detail: '6 GPT-Reviewer mit verschiedenen Linsen' },
    { title: 'Verify', detail: 'Adversarische GPT-Gegenprüfung pro Befund' },
  ],
}

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      maxItems: 5,
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'number' },
          summary: { type: 'string' },
          failure_scenario: { type: 'string' },
          severity: { type: 'string', enum: ['hoch', 'mittel', 'niedrig'] },
        },
        required: ['file', 'line', 'summary', 'failure_scenario', 'severity'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'PLAUSIBLE', 'REFUTED'] },
    justification: { type: 'string' },
  },
  required: ['verdict', 'justification'],
}

const COMMON = 'Du reviewst die GPT-Backend-Integration der macOS-App WhisperM8 (Swift, Repo = CWD). ' +
  'Lies die genannten Dateien VOLLSTÄNDIG mit deinen Tools (Read/Grep). ' +
  'Melde maximal 5 ECHTE Befunde mit konkretem Failure-Szenario (Input/Zustand → falsches Verhalten/Crash) und severity hoch/mittel/niedrig. ' +
  'Keine Stil-Nörgelei, keine Doku-Wünsche, keine Hypothesen ohne Codebezug. Gibt es weniger echte Befunde, melde weniger — leeres Array ist ein gültiges Ergebnis.'

const DIMENSIONS = [
  {
    key: 'router-http',
    prompt: COMMON + ' Fokus: WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift und Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift. Linse: HTTP/1.1-Protokollkorrektheit, Chunked-Streaming, Zustandsflags (didFinish/didSendResponseHead/didScheduleResponse), Buffer-/Memory-Verhalten, Header-Filterung (Hop-by-hop, Accept-/Content-Encoding), NWListener-Lifecycle/Generationen, Verhalten bei Portwechsel und Listener-Fehlern.',
  },
  {
    key: 'proxy-lifecycle',
    prompt: COMMON + ' Fokus: WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift und Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift. Linse: Lock-Disziplin (ensureLock/processLock), Prozess-Handles und Zombies, Timeouts, Device-Login-Flow, Reachability-Probe, willTerminate-Cleanup, Fehlerpfade von ensureRunning.',
  },
  {
    key: 'launch-env',
    prompt: COMMON + ' Fokus: WhisperM8/Services/AgentChats/AgentCommandBuilder.swift (claudeCommand/applyRouterEnvironment), WhisperM8/Services/AgentChats/ClaudeGPTLaunchGuard.swift, WhisperM8/Views/AgentSessionDetailView.swift (prepareCommand/Launch-Pfad), WhisperM8/Views/AgentChatsView+SessionLifecycle.swift (Session-Stamping). Linse: Env-Konsistenz über alle Launch-Pfade (Chat/Resume/Fork/Agents-View/Attach), Stempel-Logik, --model-Argumentreihenfolge, Fallback-Verhalten wenn Proxy/Router down, Guard-Entscheidung vs. tatsächliches Env.',
  },
  {
    key: 'settings-prefs',
    prompt: COMMON + ' Fokus: WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift, WhisperM8/Support/AppPreferences.swift (claudeGPT*-Teil), WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift und Tests/WhisperM8Tests/ClaudeGPTAgentDefinitionTests.swift. Linse: @AppStorage vs. AppPreferences-Defaults, Port-Validierung, Installer-Lifecycle (sync/remove, Profile-Roots, Marker-Schutz), UI-Zustandslogik der Status-Sektion.',
  },
  {
    key: 'security',
    prompt: COMMON + ' Fokus: WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift, ClaudeCodeProxyManager.swift, AgentCommandBuilder.swift, ClaudeGPTAgentDefinition.swift. Linse: Security — Loopback-Bindung (Router UND Proxy), Credential-Handling (OAuth/x-api-key-Stripping Richtung Codex-Proxy, keine Leaks Richtung Anthropic-Upstream), Header-/Request-Smuggling (Content-Length-Validierung, Target-Validierung gegen SSRF), Datei-Schreibpfade der Agent-Definition, Log-Inhalte (keine Secrets).',
  },
  {
    key: 'test-gaps',
    prompt: COMMON + ' Fokus: Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift, ClaudeCodeProxyManagerTests.swift, AgentCommandBuilderTests.swift (GPT-Abschnitt), ClaudeGPTAgentDefinitionTests.swift, PreferencesTests.swift (GPT-Keys) — gegen den Produktionscode gelesen. Linse: Test-Lücken — welches riskante Verhalten ist NICHT gepinnt (z. B. Streaming-Abbrüche, parallele Connections, Resume-Pfade, Profil-Discovery des Installers)? Ein Befund = eine konkrete ungetestete Regression mit Szenario; file/line = die Produktionsstelle, die ungeschützt ist.',
  },
]

phase('Review')
const reviewed = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: 'review:' + d.key, phase: 'Review', agentType: 'gpt', schema: FINDINGS }),
  (review, d) => {
    const findings = review && Array.isArray(review.findings) ? review.findings : []
    if (findings.length === 0) return []
    return parallel(findings.map(f => () =>
      agent(
        'Adversarische Gegenprüfung eines Review-Befunds zur WhisperM8-GPT-Integration (Repo = CWD; lies die betroffene Datei selbst und zitiere echte Codezeilen). ' +
        'Befund: ' + JSON.stringify(f) + '. ' +
        'Versuche ihn zu WIDERLEGEN. REFUTED nur, wenn konstruierbar: faktisch falsch (Zeile zitieren), beweisbar unmöglich (Invariante zeigen) oder bereits im Code abgefangen (Guard zitieren). Realistische Races und seltene-aber-erreichbare Pfade sind PLAUSIBLE, belegte Bugs CONFIRMED.',
        { label: 'verify:' + d.key, phase: 'Verify', agentType: 'gpt', schema: VERDICT }
      ).then(v => ({
        ...f,
        dimension: d.key,
        verdict: v ? v.verdict : 'UNVERIFIED',
        justification: v ? v.justification : null,
      }))
    ))
  }
)

const all = reviewed.filter(Boolean).flat().filter(Boolean)
const surviving = all.filter(f => f.verdict !== 'REFUTED')
const seen = new Set()
const deduped = []
for (const f of surviving) {
  const key = f.file + ':' + Math.round((f.line || 0) / 10)
  if (seen.has(key)) continue
  seen.add(key)
  deduped.push(f)
}
const order = { hoch: 0, mittel: 1, niedrig: 2 }
deduped.sort((a, b) => (order[a.severity] ?? 3) - (order[b.severity] ?? 3))
log('Review fertig: ' + all.length + ' Kandidaten, ' + (all.length - surviving.length) + ' widerlegt, ' + deduped.length + ' nach Dedup')
return {
  kandidaten: all.length,
  widerlegt: all.length - surviving.length,
  findings: deduped,
}