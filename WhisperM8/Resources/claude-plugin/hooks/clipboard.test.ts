import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// Tests des Tools `clipboard` (Zwischenablage-Verlauf). Werden nicht ausgeliefert.

const SID = '6C7DAE08-C4DE-4397-A881-A569D9C1BB9F'
const TOOL = 'mcp__whisperm8__clipboard'

type Calls = { argv: string[][]; registered: { name: string; isDeferred?: boolean }[] }

/** Engine unter der Mod: Session und `whisperm8 clipboard` gespielt. */
const world = (
  on: On,
  opts: { stdout?: string; exitCode?: number; stderr?: string; status?: { enabled: boolean; agentAccess: boolean } } = {},
): Calls => {
  const calls: Calls = { argv: [], registered: [] }
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('skill.prompt', (_$, e) => ({ text: e.text }))
  mock.env(on, { WHISPERM8_SESSION_ID: SID, HOME: '/home' })
  on('process.run', (_$, e) => {
    calls.argv.push([...e.argv])
    const isClipboard = e.argv[1] === 'clipboard'
    const isStatus = isClipboard && e.argv[2] === 'status'
    const stdout = isStatus
      ? JSON.stringify(opts.status ?? { enabled: false, agentAccess: true })
      : isClipboard
        ? (opts.stdout ?? '[]')
        : JSON.stringify({ owner: SID, isActive: false, cursor: null, entries: [] })
    return {
      value: { exitCode: isClipboard && !isStatus ? (opts.exitCode ?? 0) : 0, stdout, stderr: opts.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('process.spawn', async function* () {
    return { value: { code: 0, signal: null } } as never
  })
  on('tool.register', (_$, e) => {
    calls.registered.push({ name: (e as { name: string }).name, isDeferred: (e as { isDeferred?: boolean }).isDeferred })
    return { value: undefined } as never
  })
  return calls
}

const clipboardCalls = (calls: Calls) => calls.argv.filter(argv => argv[1] === 'clipboard' && argv[2] !== 'status')
const settle = () => new Promise(resolve => setTimeout(resolve, 0))
const callTool = ($: Parameters<Parameters<typeof test>[1]>[0], input: Record<string, unknown>) =>
  $.tool.call({ tool: TOOL, ...input } as unknown as Parameters<typeof $.tool.call>[0]) as Promise<{ result: string }>

describe('Clipboard', () => {
  test('bei abgeschaltetem Verlauf bleibt das Tool hinter ToolSearch', async ($, on) => {
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await settle()
    const entries = calls.registered.filter(r => r.name === 'clipboard')
    expect(entries.length).toBe(1)
    expect(entries[0]?.isDeferred).toBe(true)
  })

  test('bei freigegebenem Verlauf steht das Tool direkt in der Liste', async ($, on) => {
    const calls = world(on, { status: { enabled: true, agentAccess: true } })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await settle()
    const entries = calls.registered.filter(r => r.name === 'clipboard')
    expect(entries.at(-1)?.isDeferred).toBe(false)
  })

  test('gesperrter Agent-Zugriff holt das Tool nicht nach vorn', async ($, on) => {
    const calls = world(on, { status: { enabled: true, agentAccess: false } })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await settle()
    expect(calls.registered.filter(r => r.name === 'clipboard').every(r => r.isDeferred === true)).toBe(true)
  })

  test('list ruft die CLI mit Limit und --json', async ($, on) => {
    const calls = world(on, { stdout: '[{"number":1}]' })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const out = await callTool($, { action: 'list', limit: 5 })
    expect(clipboardCalls(calls)).toEqual([['whisperm8', 'clipboard', 'list', '--limit', '5', '--json']])
    expect(out.result).toBe('[{"number":1}]')
  })

  test('search reicht den Suchtext nach -- durch', async ($, on) => {
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await callTool($, { action: 'search', query: '-v fehler' })
    expect(clipboardCalls(calls)).toEqual([['whisperm8', 'clipboard', 'search', '--json', '--', '-v fehler']])
  })

  test('get nimmt Nummer oder ID', async ($, on) => {
    const calls = world(on, { stdout: '{"text":"Fehler"}' })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const out = await callTool($, { action: 'get', nr: 2 })
    expect(clipboardCalls(calls)).toEqual([['whisperm8', 'clipboard', 'get', '--json', '--', '2']])
    expect(out.result).toContain('Fehler')
  })

  test('get mit original holt das Roh-Transkript eines Diktats', async ($, on) => {
    const calls = world(on, { stdout: '{"text":"gesagt","source":"original"}' })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await callTool($, { action: 'get', nr: 1, original: true })
    expect(clipboardCalls(calls)).toEqual([['whisperm8', 'clipboard', 'get', '--json', '--original', '--', '1']])
  })

  test('get reicht Stücke langer Texte weiter (from, maxChars)', async ($, on) => {
    const calls = world(on, { stdout: '{"text":"…","nextFrom":100}' })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await callTool($, { action: 'get', nr: '1', from: 50000, maxChars: 20000 })
    expect(clipboardCalls(calls)).toEqual([
      ['whisperm8', 'clipboard', 'get', '--json', '--from', '50000', '--max-chars', '20000', '--', '1'],
    ])
  })

  test('fehlende Eingaben ergeben eine Meldung ohne CLI-Aufruf', async ($, on) => {
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    expect((await callTool($, { action: 'search' })).result).toContain('query')
    expect((await callTool($, { action: 'get' })).result).toContain('nr')
    expect((await callTool($, { action: 'frob' })).result).toContain('unbekannte')
    expect(clipboardCalls(calls)).toEqual([])
  })

  test('verweigert die CLI (Verlauf aus), steht ihre Meldung im Ergebnis', async ($, on) => {
    world(on, { exitCode: 1, stdout: '', stderr: 'Der Zwischenablage-Verlauf ist aus.' })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const out = await callTool($, { action: 'list' })
    expect(out.result).toBe('FEHLER: Der Zwischenablage-Verlauf ist aus.')
  })
})
