import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import { byID, counterText, nextMode, parseTask, taskLinks, visible } from './tasks'

// Tests der Task-Anzeige (tasks.tsx). Werden nicht ausgeliefert.

const SID = '5323b40e-8163-4ab0-940e-e39678f091b2'
const ROOT = '/home/.claude/tasks'
const DIR = `${ROOT}/session-5323b40e`
const LONG =
  'RIO: Sequenzen G – Prüf-Korrekturen und Feedback (Klick auf Marke, DealBot, Suche, KI-Variablen raus) mit einem Titel, der weit über jede Zeile hinausgeht'

const task = (id: string, status: string, extra: Record<string, unknown> = {}) =>
  JSON.stringify({ id, subject: `Task ${id}`, description: '', status, blocks: [], blockedBy: [], ...extra })

const FILES: Record<string, string> = {
  '1.json': task('1', 'completed', { subject: LONG }),
  '2.json': task('2', 'in_progress', { activeForm: 'Baut die Sequenz-Seite', owner: 'bau-78-g' }),
  '3.json': task('3', 'pending', { blockedBy: ['2'] }),
  '10.json': task('10', 'pending'),
  '.lock': '',
}

type World = {
  clock: { advance: (ms: number) => Promise<void> }
  files: Record<string, string>
  store: Record<string, unknown>
  mtime: number
  opened: string[]
  closed: string[]
  placed: boolean
  boardActive: boolean
}

/** Engine unter der Mod: Dateien, Session, Store, Panes und das Board gespielt. */
const world = (
  on: On,
  opts: { store?: Record<string, unknown>; files?: Record<string, string>; board?: boolean; dir?: string } = {},
) => {
  const dir = opts.dir ?? DIR
  const clock = mock.clock(on, { now: Date.parse('2026-10-20T12:00:00Z') })
  const w: World = {
    clock,
    files: { ...(opts.files ?? FILES) },
    store: { ...(opts.store ?? {}) },
    mtime: 1,
    opened: [],
    closed: [],
    placed: false,
    boardActive: opts.board ?? false,
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
  on('command.register', (_$, e) => ({ value: { command: (e as { name: string }).name } }) as never)
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
  on('ui.open', (_$, e) => {
    w.opened.push(e.id)
    w.placed = true
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    w.closed.push(e.id)
    w.placed = false
    return { value: undefined } as never
  })
  on('ui.panes', () => ({
    value: w.placed ? [{ id: 'whisperm8-tasks', title: 'Tasks', isShown: true, isFocused: false, isPlaced: true }] : [],
  }))
  on('process.run', () => {
    const stdout = JSON.stringify({
      owner: 'A3F2C1D0-0000-0000-0000-000000000009',
      isActive: w.boardActive,
      cursor: null,
      entries: w.boardActive
        ? [{ ref: 'a3f2c1d0', sessionID: 'X1', title: 'Outreach', project: 'p', light: 'running', mission: '', needs: '', next: 'Baut', updatedAt: '2026-10-20T10:00:00Z', status: 'working', statusSince: null, otherOwners: [] }]
        : [],
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

const band = (bodyColumns: number, isFullscreen = false) =>
  ({
    plugin: 'whisperm8',
    component: 'AbovePrompt',
    viewport: { columns: bodyColumns + 5, rows: 50, isFullscreen },
    props: { hasSurvey: false, isWorking: false, maxRows: 40, bodyColumns, scroll: { offset: 0, bodyRows: 40 }, view: {} },
  }) as const

const PANE = {
  plugin: 'whisperm8',
  component: 'Pane',
  requestId: 'whisperm8-tasks',
  props: { title: 'Tasks', isFocused: true, bodyColumns: 44, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

const HINT = {
  plugin: 'whisperm8',
  component: 'PromptHint',
  props: { isDraft: false, isWorking: false, hint: '? for shortcuts' },
} as const

const SURFACES = ['terminal', 'desktop'] as const

describe('Lesen und Modus (rein)', () => {
  test('parseTask liest Claude Codes Datei und verwirft Kaputtes', async () => {
    const t = parseTask(FILES['2.json']!)
    expect(t?.activeForm).toBe('Baut die Sequenz-Seite')
    expect(t?.owner).toBe('bau-78-g')
    expect(parseTask('{')).toBeNull()
    expect(parseTask(task('9', 'deleted'))).toBeNull()
  })

  test('IDs numerisch sortiert, Modus zyklisch, Zähler', async () => {
    const items = ['10.json', '2.json', '1.json'].map(n => parseTask(FILES[n]!)!).sort(byID)
    expect(items.map(t => t.id)).toEqual(['1', '2', '10'])
    expect([nextMode('off'), nextMode('normal'), nextMode('all')]).toEqual(['normal', 'all', 'off'])
    expect(counterText(items)).toBe('1 aktiv · 1 offen')
    expect(visible(items, 'normal').map(t => t.id)).toEqual(['2', '10'])
    expect(visible(items, 'all')).toHaveLength(3)
    expect(visible(items, 'off')).toEqual([])
  })
})

describe('Links (rein)', () => {
  test('metadata.links in jeder Form, URLs aus dem Text, ohne Doppelte', async () => {
    const links = taskLinks({
      subject: 'Seite prüfen https://listm8.test/campaigns/3799/setup.',
      description: 'Design: https://www.figma.com/file/abc und nochmal https://listm8.test/campaigns/3799/setup',
      metadata: { links: [{ label: 'App', url: 'http://localhost:3000' }, 'file:///Users/g/plan.md', { title: 'PR', href: 'https://github.com/x/y/pull/7' }, { label: 'kaputt', url: 'javascript:alert(1)' }] },
    })
    expect(links).toEqual([
      { label: 'App', url: 'http://localhost:3000' },
      { label: 'plan.md', url: 'file:///Users/g/plan.md' },
      { label: 'PR', url: 'https://github.com/x/y/pull/7' },
      { label: 'listm8.test', url: 'https://listm8.test/campaigns/3799/setup' },
      { label: 'figma.com', url: 'https://www.figma.com/file/abc' },
    ])
    expect(taskLinks({ metadata: { links: { Site: 'https://rankm8.de' } } })).toEqual([{ label: 'Site', url: 'https://rankm8.de' }])
  })
})

describe('Task-Anzeige', () => {
  test('Standard ist Aus: kein Band, aber der Zähler', async ($, on) => {
    world(on)
    await start($)
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await ui.find({ text: 'engine' })).toBeDefined()
    expect(await ui.find({ text: /Tasks/ })).toBeUndefined()
    await ui.unmount()
  })

  test('/t schaltet Aus → Normal → Alle → Aus und merkt sich den Modus', async ($, on) => {
    const w = world(on)
    await start($)
    const one = (await $.command.run({ command: 't', args: '' } as never)) as { text: string }
    expect(one.text).toContain('Normal')
    expect(one.text).toContain('1 aktiv · 2 offen')
    expect(w.store.taskMode).toBe('normal')
    expect(((await $.command.run({ command: 't', args: '' } as never)) as { text: string }).text).toContain('Alle')
    expect(((await $.command.run({ command: 't', args: '' } as never)) as { text: string }).text).toContain('Aus')
    expect(w.store.taskMode).toBe('off')
    expect(((await $.command.run({ command: 't', args: 'alle' } as never)) as { text: string }).text).toContain('Alle')
    expect(((await $.command.run({ command: 't', args: 'quatsch' } as never)) as { text: string }).text).toContain('/t aus | normal | alle')
  })

  test('Normal: nur laufende und offene, mit Tätigkeit, Besitzer und Blocker', async ($, on) => {
    world(on, { store: { taskMode: 'normal' } })
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...band(120), surface })
      expect(await ui.find({ text: /Task 2/ })).toBeDefined()
      expect(await ui.find({ text: /@bau-78-g/ })).toBeDefined()
      expect(await ui.find({ text: /Baut die Sequenz-Seite/ })).toBeDefined()
      expect(await ui.find({ text: /wartet auf #2/ })).toBeDefined()
      expect(await ui.find({ text: /Task 10/ })).toBeDefined()
      expect(await ui.find({ text: /RIO/ })).toBeUndefined()
      expect(await ui.find({ text: /\+1 erledigt/ })).toBeDefined()
      expect(await ui.find({ text: /1 aktiv/ })).toBeDefined()
      await ui.unmount()
    }
  })

  test('Alle: auch erledigte, Titel ungekürzt; Hotkey 2 schaltet zurück auf Normal', async ($, on) => {
    const w = world(on, { store: { taskMode: 'all' } })
    await start($)
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    const row = await ui.find({ text: /RIO/ })
    expect(row?.text).toContain('weit über jede Zeile hinausgeht')
    await ui.press({ key: 'task-mode-normal' })
    expect(w.store.taskMode).toBe('normal')
    await ui.unmount()
  })

  test('Hotkey 1 blendet aus', async ($, on) => {
    const w = world(on, { store: { taskMode: 'normal' } })
    await start($)
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    await ui.press({ key: 'task-mode-off' })
    expect(w.store.taskMode).toBe('off')
    await ui.unmount()
  })

  test('mit offenem Board: beide Bänder, die Task-Knöpfe ohne Ziffern', async ($, on) => {
    world(on, { store: { taskMode: 'normal' }, board: true })
    await start($)
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await ui.find({ text: /Task 2/ })).toBeDefined()
    expect(await ui.find({ text: /Outreach/ })).toBeDefined()
    const button = (await ui.find({ key: 'task-mode-all' })) as { props?: { hotkey?: string } } | undefined
    expect(button?.props?.hotkey).toBeUndefined()
    await ui.unmount()
  })

  test('Vollbild mit platziertem Pane: kein Band, das Pane zeigt die Liste', async ($, on) => {
    const w = world(on, { store: { taskMode: 'all', taskFullscreen: true } })
    await start($)
    expect(w.opened).toEqual(['whisperm8-tasks'])
    const ui = await $.ui.mount({ ...band(120, true), surface: 'terminal' })
    expect(await ui.find({ text: /Task 2/ })).toBeUndefined()
    await ui.unmount()
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await pane.find({ text: /RIO/ }))?.text).toContain('hinausgeht')
    await pane.press({ key: 'task-mode-off' })
    expect(w.closed).toEqual(['whisperm8-tasks'])
    await pane.unmount()
  })

  test('/t im Vollbild öffnet das Pane, Aus schließt es', async ($, on) => {
    const w = world(on)
    await start($)
    const presentation = { isFullscreen: true, columns: 160 }
    await $.command.run({ command: 't', args: '', presentation } as never)
    expect(w.opened).toEqual(['whisperm8-tasks'])
    expect(w.store.taskFullscreen).toBe(true)
    await $.command.run({ command: 't', args: 'aus', presentation } as never)
    expect(w.closed).toEqual(['whisperm8-tasks'])
  })

  test('der Zähler hängt sich an die Hinweiszeile', async ($, on) => {
    world(on)
    await start($)
    const ui = await $.ui.mount({ ...HINT, surface: 'terminal' })
    expect(await ui.find({ text: /Tasks 1 aktiv · 2 offen/ })).toBeDefined()
    await ui.unmount()
  })

  test('Zähler abgeschaltet: Hinweiszeile wie von der Engine', { options: { taskzaehler: false } }, async ($, on) => {
    world(on)
    await start($)
    const ui = await $.ui.mount({ ...HINT, surface: 'terminal' })
    expect(await ui.find({ text: /Tasks/ })).toBeUndefined()
    await ui.unmount()
  })

  test('Task-Liste abgeschaltet: kein /t', { options: { taskliste: false } }, async ($, on) => {
    world(on, { store: { taskMode: 'all' } })
    await start($)
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await ui.find({ text: /Task 2/ })).toBeUndefined()
    await ui.unmount()
  })

  test('Links stehen klickbar unter dem Task', async ($, on) => {
    world(on, {
      store: { taskMode: 'normal' },
      files: { '1.json': task('1', 'in_progress', { metadata: { links: [{ label: 'App', url: 'http://localhost:3000' }] } }) },
    })
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...band(120), surface })
      expect(await ui.find({ type: 'Link' })).toBeDefined()
      expect(await ui.find({ text: /App/ })).toBeDefined()
      await ui.unmount()
    }
  })

  test('Ordner mit fremdem Teamnamen: das erste TaskCreate findet ihn und merkt ihn je Session', async ($, on) => {
    const w = world(on, { store: { taskMode: 'normal' }, dir: `${ROOT}/session-412eed50` })
    await start($)
    const before = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await before.find({ text: /Task 2/ })).toBeUndefined()
    await before.unmount()
    await $.tool.call({ tool: 'TaskCreate', subject: 'Doku nachziehen', description: '' } as never)
    await w.clock.advance(200)
    await settle()
    expect((w.store.taskDirs as Record<string, string>)[SID]).toBe(`${ROOT}/session-412eed50`)
    const after = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await after.find({ text: /Task 2/ })).toBeDefined()
    expect(await after.find({ text: /Doku nachziehen/ })).toBeDefined()
    await after.unmount()
  })

  test('die Beschreibung von TaskCreate erklärt metadata.links', async ($, on) => {
    world(on)
    on('tool.describe', () => ({ description: 'Create a task.' }) as never)
    await start($)
    const described = (await $.tool.describe({ tool: 'TaskCreate', description: 'Create a task.' } as never)) as { description: string }
    expect(described.description).toContain('metadata.links')
  })

  test('TaskUpdate liest die Liste neu', async ($, on) => {
    const w = world(on, { store: { taskMode: 'normal' } })
    await start($)
    w.files['10.json'] = task('10', 'in_progress', { activeForm: 'Prüft die Tests' })
    // Neue mtime, damit der Cache die Datei neu liest.
    w.mtime = 2
    await $.tool.call({ tool: 'TaskUpdate', taskId: '10', status: 'in_progress' } as never)
    await w.clock.advance(200)
    await settle()
    const ui = await $.ui.mount({ ...band(120), surface: 'terminal' })
    expect(await ui.find({ text: /Prüft die Tests/ })).toBeDefined()
    await ui.unmount()
  })
})
