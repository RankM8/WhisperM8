import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// Tests der Callout-Mod (Voice-Callouts). Werden nicht ausgeliefert.

const SID = '6C7DAE08-C4DE-4397-A881-A569D9C1BB9F'
const TOOL = 'mcp__whisperm8__speak'

type Calls = { argv: string[][]; toasts: string[] }

/** Engine unter der Mod: Session und `whisperm8 speak` gespielt. */
const world = (on: On, opts: { reply?: unknown; sid?: string | null } = {}): Calls => {
  const calls: Calls = { argv: [], toasts: [] }
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('skill.prompt', (_$, e) => ({ text: e.text }))
  mock.env(on, opts.sid === null ? { HOME: '/home' } : { WHISPERM8_SESSION_ID: opts.sid ?? SID, HOME: '/home' })
  on('process.run', (_$, e) => {
    calls.argv.push([...e.argv])
    // Board-Lesen der anderen Mod: kein aktives Board.
    const stdout = e.argv.includes('speak')
      ? JSON.stringify(opts.reply ?? { status: 'queued', position: 1 })
      : JSON.stringify({ owner: SID, isActive: false, cursor: null, entries: [] })
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('process.spawn', async function* () {
    return { value: { code: 0, signal: null } } as never
  })
  on('ui.toast', (_$, e) => {
    calls.toasts.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined } as never
  })
  return calls
}

const speakCalls = (calls: Calls) => calls.argv.filter(argv => argv[1] === 'speak')
const callTool = ($: Parameters<Parameters<typeof test>[1]>[0], text: string) =>
  $.tool.call({ tool: TOOL, text } as unknown as Parameters<typeof $.tool.call>[0]) as Promise<{ result: string }>

describe('Callout', () => {
  test('ohne Skill ist der Modus aus: das Tool spricht nicht', async ($, on) => {
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const out = await callTool($, 'Fertig.')
    expect(out.result).toContain('aus')
    expect(speakCalls(calls)).toEqual([])
  })

  test('der Skill whisperm8:callout schaltet ein, das Tool reicht den Text an die App', async ($, on) => {
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const loaded = await $.skill.prompt({ skill: 'whisperm8:callout', text: 'Callout' })
    expect(loaded.text).toContain(TOOL)
    const out = await callTool($, 'Die Tests sind grün.')
    expect(speakCalls(calls)).toEqual([['whisperm8', 'speak', 'Die Tests sind grün.']])
    expect(out.result).toContain('queued')
    expect(calls.toasts).toEqual(['🔊 vorgelesen'])
  })

  test('Jarvis spricht immer: sein Skill schaltet den Modus mit ein', async ($, on) => {
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await $.skill.prompt({ skill: 'whisperm8:jarvis', text: 'Jarvis' })
    await callTool($, 'Der Outreach-Chat wartet.')
    expect(speakCalls(calls).length).toBe(1)
  })

  test('stumm geschaltet: Hinweis statt „vorgelesen“, kein zweiter Versuch', async ($, on) => {
    const calls = world(on, { reply: { status: 'muted' } })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await $.skill.prompt({ skill: 'whisperm8:callout', text: 'Callout' })
    const out = await callTool($, 'Fertig.')
    expect(out.result).toContain('Nicht erneut versuchen')
    expect(calls.toasts).toEqual(['🔇 stumm, nicht vorgelesen'])
  })

  test('/callout aus schaltet ab, /callout an wieder ein', async ($, on) => {
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await $.skill.prompt({ skill: 'whisperm8:callout', text: 'Callout' })
    await $.command.run({ command: 'callout', args: 'aus' })
    await callTool($, 'Eins.')
    expect(speakCalls(calls)).toEqual([])
    await $.command.run({ command: 'callout', args: 'an' })
    await callTool($, 'Zwei.')
    expect(speakCalls(calls).length).toBe(1)
  })

  test('außerhalb einer WhisperM8-Session bleibt der Skill-Text unverändert', async ($, on) => {
    const calls = world(on, { sid: null })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const loaded = await $.skill.prompt({ skill: 'whisperm8:callout', text: 'Callout' })
    expect(loaded.text).toBe('Callout')
    expect(calls.argv).toEqual([])
  })
})
