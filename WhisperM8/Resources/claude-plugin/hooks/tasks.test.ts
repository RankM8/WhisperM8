import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import { byID, counterText, parseTask } from './tasks'

// Tests des Task-Zählers (tasks.tsx). Werden nicht ausgeliefert.

const SID = '5323b40e-8163-4ab0-940e-e39678f091b2'
const ROOT = '/home/.claude/tasks'
const DIR = `${ROOT}/session-5323b40e`
const task = (id: string, status: string, extra: Record<string, unknown> = {}) =>
  JSON.stringify({ id, subject: `Task ${id}`, description: '', status, blocks: [], blockedBy: [], ...extra })

const FILES: Record<string, string> = {
  '1.json': task('1', 'completed'),
  '2.json': task('2', 'in_progress', { activeForm: 'Baut die Sequenz-Seite' }),
  '3.json': task('3', 'pending', { blockedBy: ['2'] }),
  '10.json': task('10', 'pending'),
  '.lock': '',
}

type World = {
  clock: { advance: (ms: number) => Promise<void> }
  files: Record<string, string>
  store: Record<string, unknown>
  mtime: number
  commands: string[]
}

/** Engine unter der Mod: Dateien, Session und Store gespielt. */
const world = (on: On, opts: { store?: Record<string, unknown>; files?: Record<string, string>; dir?: string } = {}) => {
  const dir = opts.dir ?? DIR
  const clock = mock.clock(on, { now: Date.parse('2026-10-20T12:00:00Z') })
  const w: World = {
    clock,
    files: { ...(opts.files ?? FILES) },
    store: { ...(opts.store ?? {}) },
    mtime: 1,
    commands: [],
  }
  // Die Engine zeichnet die Hinweiszeile samt `tail`, alles andere als „engine“.
  on('ui.render', (_$, e) => {
    const props = e.props as { hint?: string; tail?: string }
    const text = e.component === 'PromptHint' ? `${props.hint ?? ''} ${props.tail ?? ''}` : 'engine'
    return { type: 'Text', props: {}, children: [text] }
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: SID }))
  mock.env(on, { HOME: '/home', WHISPERM8_SESSION_ID: 'A3F2C1D0-0000-0000-0000-000000000009' })
  on('store.get', (_$, e) => ({ value: w.store[e.key] }))
  on('store.set', (_$, e) => {
    w.store[e.key] = e.value
    return { value: undefined } as never
  })
  on('command.register', (_$, e) => {
    const name = (e as { name: string }).name
    w.commands.push(name)
    return { value: { command: name } } as never
  })
  on('fs.list', (_$, e) => {
    if (e.path === ROOT) {
      const names = ['session-aaaaaaaa', dir.slice(ROOT.length + 1)]
      return { value: names.map(name => ({ name, kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false })) }
    }
    if (e.path !== dir) throw new Error('ENOENT')
    return { value: Object.keys(w.files).map(name => ({ name, kind: 'file' as const, size: w.files[name]!.length, mtimeMs: w.mtime, isLink: false })) }
  })
  on('fs.read', (_$, e) => {
    if (!e.path.startsWith(`${dir}/`)) throw new Error('ENOENT')
    return { value: w.files[e.path.slice(dir.length + 1)] ?? '' }
  })
  on('process.run', () => {
    const stdout = JSON.stringify({
      owner: 'A3F2C1D0-0000-0000-0000-000000000009',
      isActive: false,
      cursor: null,
      entries: [],
    })
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('process.spawn', async function* () {
    return { value: { code: 0, signal: null } } as never
  })
  on('tool.register', () => ({ value: undefined }) as never)
  // TaskCreate antwortet wie Claude Code mit { task: { id, subject } }.
  on('tool.call', (_$, e) => {
    const input = e as unknown as { tool: string; subject?: string }
    if (input.tool !== 'TaskCreate') return { result: {} } as never
    w.files['11.json'] = task('11', 'pending', { subject: input.subject })
    w.mtime += 1
    return { result: { task: { id: '11', subject: input.subject } } } as never
  })
  return w
}

// Die Testumgebung hat setTimeout, die lib es2023 kennt es nicht.
declare const setTimeout: (fn: () => void, ms: number) => unknown

/** Einmal die Ereignisschleife drehen: das nicht awaitete Lesen landet. */
const settle = () => new Promise<void>(resolve => setTimeout(resolve, 0))

const start = async ($: Engine) => {
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
  await settle()
}

const band = {
  plugin: 'whisperm8',
  component: 'AbovePrompt',
  viewport: { columns: 125, rows: 50, isFullscreen: false },
  props: { hasSurvey: false, isWorking: false, maxRows: 40, bodyColumns: 120, scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

const HINT = {
  plugin: 'whisperm8',
  component: 'PromptHint',
  props: { isDraft: false, isWorking: false, hint: '? for shortcuts' },
} as const

const hint = async ($: Engine) => {
  const ui = await $.ui.mount({ ...HINT, surface: 'terminal' })
  const found = await ui.find({ text: /Tasks/ })
  await ui.unmount()
  return found?.text
}

describe('Lesen (rein)', () => {
  test('parseTask liest Claude Codes Datei und verwirft Kaputtes', async () => {
    expect(parseTask(FILES['2.json']!)).toEqual({ id: '2', subject: 'Task 2', status: 'in_progress' })
    expect(parseTask('{')).toBeNull()
    expect(parseTask(task('9', 'deleted'))).toBeNull()
  })

  test('IDs numerisch sortiert, Zähler nur mit laufenden oder offenen', async () => {
    const items = ['10.json', '2.json', '1.json'].map(n => parseTask(FILES[n]!)!).sort(byID)
    expect(items.map(t => t.id)).toEqual(['1', '2', '10'])
    expect(counterText(items)).toBe('1 aktiv · 1 offen')
    expect(counterText(items.filter(t => t.status === 'completed'))).toBe('')
  })
})

describe('Task-Zähler', () => {
  test('der Zähler hängt sich an die Hinweiszeile', async ($, on) => {
    world(on)
    await start($)
    expect(await hint($)).toContain('Tasks 1 aktiv · 2 offen')
  })

  test('keine eigene Liste: kein /t, über dem Prompt zeichnet die Engine', async ($, on) => {
    // Ein alter Modus im Store (bis 22.10.2026: /t) zeichnet nichts mehr.
    const w = world(on, { store: { taskMode: 'all', taskFullscreen: true } })
    await start($)
    expect(w.commands).not.toContain('t')
    const ui = await $.ui.mount({ ...band, surface: 'terminal' })
    expect(await ui.find({ text: 'engine' })).toBeDefined()
    expect(await ui.find({ text: /Task 2/ })).toBeUndefined()
    await ui.unmount()
  })

  test('Zähler abgeschaltet: Hinweiszeile wie von der Engine', { options: { taskzaehler: false } }, async ($, on) => {
    world(on)
    await start($)
    expect(await hint($)).toBeUndefined()
  })

  test('Ordner mit fremdem Teamnamen: das erste TaskCreate findet ihn und merkt ihn je Session', async ($, on) => {
    const w = world(on, { dir: `${ROOT}/session-412eed50` })
    await start($)
    expect(await hint($)).toBeUndefined()
    await $.tool.call({ tool: 'TaskCreate', subject: 'Doku nachziehen', description: '' } as never)
    await w.clock.advance(200)
    await settle()
    expect((w.store.taskDirs as Record<string, string>)[SID]).toBe(`${ROOT}/session-412eed50`)
    expect(await hint($)).toContain('Tasks 1 aktiv · 3 offen')
  })

  test('die Beschreibung von TaskCreate erklärt metadata.links', async ($, on) => {
    world(on)
    on('tool.describe', () => ({ description: 'Create a task.' }) as never)
    await start($)
    const described = (await $.tool.describe({ tool: 'TaskCreate', description: 'Create a task.' } as never)) as { description: string }
    expect(described.description).toContain('metadata.links')
  })

  test('TaskUpdate liest die Liste neu', async ($, on) => {
    const w = world(on)
    await start($)
    w.files['10.json'] = task('10', 'in_progress')
    // Neue mtime, damit der Cache die Datei neu liest.
    w.mtime = 2
    await $.tool.call({ tool: 'TaskUpdate', taskId: '10', status: 'in_progress' } as never)
    await w.clock.advance(200)
    await settle()
    expect(await hint($)).toContain('Tasks 2 aktiv · 1 offen')
  })

  test('der 5-s-Takt liest Änderungen anderer Prozesse', async ($, on) => {
    const w = world(on)
    await start($)
    w.files['3.json'] = task('3', 'completed')
    w.mtime = 2
    await w.clock.advance(5_100)
    await settle()
    expect(await hint($)).toContain('Tasks 1 aktiv · 1 offen')
  })
})
