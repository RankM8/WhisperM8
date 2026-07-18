export const meta = {
  name: 'gpt-native-e2e',
  description: 'E2E-Test: native GPT-Subagents (Agent-Typ gpt) als Dynamic-Workflow-Steps',
  phases: [
    { title: 'Fanout', detail: '3 parallele GPT-Agents mit Structured Output' },
    { title: 'Verify', detail: 'GPT-Verifier prüft die Ergebnisse' },
  ],
}

const TASKS = [
  { id: 'alpha', a: 37, b: 41, erwartet: 1517 },
  { id: 'beta', a: 53, b: 47, erwartet: 2491 },
  { id: 'gamma', a: 29, b: 31, erwartet: 899 },
]

const RESULT = {
  type: 'object',
  properties: {
    id: { type: 'string' },
    ergebnis: { type: 'number' },
    baseURL: { type: 'string', description: 'Wert von ANTHROPIC_BASE_URL aus der Shell' },
  },
  required: ['id', 'ergebnis', 'baseURL'],
}

const VERDICT = {
  type: 'object',
  properties: {
    korrekt: { type: 'number' },
    falsch: { type: 'array', items: { type: 'string' } },
    fazit: { type: 'string' },
  },
  required: ['korrekt', 'falsch', 'fazit'],
}

phase('Fanout')
const results = await parallel(TASKS.map(t => () =>
  agent(
    `E2E-Workflow-Funktionstest, Aufgabe "${t.id}": Berechne ${t.a} * ${t.b}. ` +
    `Führe ausserdem in der Shell \`echo $ANTHROPIC_BASE_URL\` aus und melde den Wert. ` +
    `Gib id="${t.id}", das numerische Ergebnis und die baseURL zurück. Keine weiteren Aktionen.`,
    { label: `gpt:${t.id}`, phase: 'Fanout', agentType: 'gpt', schema: RESULT }
  )
))

const valid = results.filter(Boolean)
log(`Fanout fertig: ${valid.length}/${TASKS.length} Agents haben geliefert`)

phase('Verify')
const verdict = await agent(
  `Prüfe die Ergebnisse dieses Workflow-Tests: ${JSON.stringify(valid)}. ` +
  `Erwartet: alpha=1517, beta=2491, gamma=899, und jede baseURL muss auf http://127.0.0.1:18766 zeigen. ` +
  `Zähle korrekte Ergebnisse, liste falsche (id + Grund) und gib ein Ein-Satz-Fazit.`,
  { label: 'gpt:verify', phase: 'Verify', agentType: 'gpt', schema: VERDICT }
)

return { results: valid, verdict }