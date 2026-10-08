import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// Tests der Board-Mod (`claude plugin test` auf den abgelegten Plugin-Ordner
// oder diesen Ressourcen-Ordner samt Manifest). Werden nicht ausgeliefert.

const NOW = Date.parse('2026-10-08T15:00:00Z')
const SID = '6C7DAE08-C4DE-4397-A881-A569D9C1BB9F'
const minutesAgo = (m: number) => new Date(NOW - m * 60_000).toISOString()

const entry = (over: Record<string, unknown>) => ({
  ref: 'a3f2c1d0',
  sessionID: 'A3F2C1D0-0000-0000-0000-000000000001',
  title: 'Outreach Copy-Review',
  project: 'outreach',
  light: 'running',
  mission: 'Copy für Kampagne 12',
  needs: '',
  next: 'Sequenz finalisieren',
  updatedAt: minutesAgo(4),
  status: 'working',
  statusSince: minutesAgo(4),
  otherOwners: [],
  ...over,
})

const BOARD = {
  schema: 'wm8.board/1',
  owner: SID,
  ownerRef: '6c7dae08',
  isActive: true,
  cursor: '1:10',
  entries: [
    entry({ light: 'needsYou', needs: 'Entscheidung: Opener-Schluss A oder B' }),
    entry({ ref: '7c1e0000', sessionID: 'B7C1E000-0000-0000-0000-000000000002', title: 'Akquise Import', light: 'done', next: 'Ergebnis prüfen', updatedAt: minutesAgo(12) }),
    entry({ ref: 'e45d0000', sessionID: 'CE45D000-0000-0000-0000-000000000003', title: 'ListM8 Lead-Run', next: 'Qualifizierung 40/150', updatedAt: minutesAgo(18) }),
  ],
}

const band = (bodyColumns: number, maxRows = 12) => ({
  plugin: 'whisperm8',
  component: 'AbovePrompt' as const,
  props: { hasSurvey: false, isWorking: false, maxRows, bodyColumns, scroll: { offset: 0, bodyRows: maxRows }, view: {} },
})

type Calls = { argv: string[][]; prompts: string[]; toasts: string[] }

/** Engine unter der Mod: Session, CLI (`whisperm8 …`) und watch-Strom gespielt. */
const world = (on: On, opts: { board?: unknown; watch?: unknown[]; sid?: string | null } = {}): Calls => {
  const calls: Calls = { argv: [], prompts: [], toasts: [] }
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['engine'] }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('skill.prompt', (_$, e) => ({ text: e.text }))
  mock.env(on, opts.sid === null ? { HOME: '/home' } : { WHISPERM8_SESSION_ID: opts.sid ?? SID, HOME: '/home' })
  on('process.run', (_$, e) => {
    calls.argv.push([...e.argv])
    const stdout = e.argv.includes('board') && e.argv.length <= 4 ? JSON.stringify(opts.board ?? BOARD) : '{"ok":true}'
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  const lines = (opts.watch ?? []).map(ev => `${JSON.stringify(ev)}\n`)
  on('process.spawn', async function* () {
    for (const text of lines) yield { stream: 'stdout' as const, text }
    lines.length = 0
    return { value: { code: 0, signal: null } } as never
  })
  on('prompt.submit', (_$, e) => {
    calls.prompts.push(e.text)
    return { text: e.text } as never
  })
  on('ui.toast', (_$, e) => {
    calls.toasts.push(String((e as { text?: string }).text ?? ''))
    return { value: undefined } as never
  })
  on('audio.play', () => ({ value: undefined }) as never)
  on('ui.status', () => ({ value: undefined }) as never)
  return calls
}

const SURFACES = ['terminal', 'desktop'] as const

describe('Band', () => {
  test('zeigt wartende Chats zuerst, breit mit Wörtern, im Slot knapp', async ($, on) => {
    mock.clock(on, { now: NOW })
    world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    for (const surface of SURFACES) {
      const wide = await $.ui.mount({ ...band(179), surface })
      expect(await wide.find({ text: /1 wartet/ })).toBeDefined()
      expect(await wide.find({ text: /Opener-Schluss A oder B/ })).toBeDefined()
      expect(await wide.find({ text: '4 min' })).toBeDefined()
      expect(await wide.find({ text: /fertig · Ergebnis prüfen/ })).toBeDefined()
      await wide.unmount()

      // Der Kopf kürzt nach Platz, nicht nach fester Stufe: erst „· Board“ weg …
      const mid = await $.ui.mount({ ...band(55), surface })
      expect(await mid.find({ text: /Jarvis · Board/ })).toBeUndefined()
      expect(await mid.find({ text: /1 läuft/ })).toBeDefined()
      expect(await mid.find({ text: '18m' })).toBeDefined()
      await mid.unmount()

      // … dann die Wörter außer „wartet“.
      const slot = await $.ui.mount({ ...band(45), surface })
      expect(await slot.find({ text: /1 wartet/ })).toBeDefined()
      expect(await slot.find({ text: /\d läuft/ })).toBeUndefined()
      await slot.unmount()
    }
  })

  test('ohne WhisperM8-Session und bei inaktivem Board zeichnet die Engine', async ($, on) => {
    mock.clock(on, { now: NOW })
    const calls = world(on, { sid: null })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await ui.find({ text: 'engine' })).toBeDefined()
    await ui.unmount()
    expect(calls.argv).toEqual([])
  })

  test('inaktives Board: kein Band, kein watch', async ($, on) => {
    mock.clock(on, { now: NOW })
    world(on, { board: { ...BOARD, isActive: false } })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await ui.find({ text: 'engine' })).toBeDefined()
    await ui.unmount()
  })

  test('zu klappt auf die Summenzeile ein', async ($, on) => {
    mock.clock(on, { now: NOW })
    world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    await ui.press({ key: 'fold' })
    expect(await ui.find({ text: /Opener-Schluss/ })).toBeUndefined()
    expect(await ui.find({ text: /1 wartet/ })).toBeDefined()
    await ui.press({ key: 'open' })
    expect(await ui.find({ text: /Opener-Schluss/ })).toBeDefined()
    await ui.unmount()
  })
})

describe('Steuerung', () => {
  test('der Skill whisperm8:jarvis schaltet das Board ein', async ($, on) => {
    mock.clock(on, { now: NOW })
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const ours = await $.skill.prompt({ skill: 'whisperm8:jarvis', text: 'Jarvis' })
    expect(calls.argv.some(argv => argv.join(' ').endsWith('chats board activate --json'))).toBe(true)
    expect(ours.text).toContain('mcp__whisperm8__board')
    const before = calls.argv.length
    const other = await $.skill.prompt({ skill: 'jarvis', text: 'lose Kopie' })
    expect(other.text).toBe('lose Kopie')
    expect(calls.argv.length).toBe(before)
  })

  test('das Tool reicht set als CLI-Aufruf weiter', async ($, on) => {
    mock.clock(on, { now: NOW })
    const calls = world(on)
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await $.tool.call({
      tool: 'mcp__whisperm8__board', action: 'set', ref: 'a3f2', light: 'needsYou', needs: 'Freigabe',
    } as unknown as Parameters<typeof $.tool.call>[0])
    expect(calls.argv).toContainEqual(['whisperm8', 'chats', 'board', 'set', 'a3f2', '--light', 'needsYou', '--needs', 'Freigabe', '--json'])
  })
})

describe('Wecken', () => {
  test('ein Board-Chat wartet: ein gebündelter Prompt an Jarvis, nur einmal je Zustand', async ($, on) => {
    const clock = mock.clock(on, { now: NOW })
    const waits = { kind: 'conversation', sessionID: 'CE45D000-0000-0000-0000-000000000003', from: 'working', to: 'awaitingInput', schema: 'wm8.changes/1' }
    const calls = world(on, { watch: [{ event: 'started', cursor: '1:10' }, waits, waits] })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    await clock.settle()
    await clock.advance(6_000)
    await clock.settle()
    expect(calls.toasts).toEqual(['[Board] ListM8 Lead-Run (e45d0000): wartet auf dich'])
    expect(calls.prompts.length).toBe(1)
    expect(calls.prompts[0]).toContain('[Board] ListM8 Lead-Run (e45d0000): wartet auf dich')
  })
})
