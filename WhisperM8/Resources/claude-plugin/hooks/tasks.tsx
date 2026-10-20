import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, PluginOptions } from 'claude-code'

import type { BoardView, TaskItem, TaskLink, TaskMode, TaskStatus } from '../types'

// Task-Anzeige: die ganze Task-Liste der Session (TaskCreate/TaskUpdate),
// auch erledigte und mit vollen Titeln. Claude Codes eigene Liste (ctrl+t)
// kürzt („… +8 completed“) und kennt nur auf/zu; sie hat keinen ui.render-Ort,
// und ctrl+t (app:toggleTodos) lässt sich nicht übernehmen, solange der
// Engine-Handler gemountet ist. Deshalb eine eigene Anzeige daneben.
//
// Wahrheit: Claude Codes Dateien `<config-dir>/tasks/<liste>/<id>.json`. Die Mod
// liest sie nach jedem TaskCreate/TaskUpdate und alle 5 s (Teammates anderer
// Prozesse schreiben ohne tool.call hier). Ort: im Vollbild-Terminal ein Pane
// (rechts ab 110 Spalten, schmaler über dem Prompt), sonst — App-Sessions laufen
// im Main-Screen — ein Band über dem Prompt.
//
// Eigene Datei, von register.tsx nur eingebunden: Hooks und `$` folgt die
// Engine über einen Import nur in Funktions-Deklarationen, und `session.start`
// darf je Plugin nur einmal ohne Matcher stehen (dort ruft register.tsx
// `startTasks`). `registerTasks` muss vor den Board-Hooks stehen: der zuerst
// registrierte AbovePrompt-Hook läuft außen und legt das Board-Band unter seins.

const taskMode = atom({ plugin: 'whisperm8', key: 'taskMode' } as const, 'off' as TaskMode)
const taskItems = atom({ plugin: 'whisperm8', key: 'taskItems' } as const, [] as TaskItem[])
const taskDir = atom({ plugin: 'whisperm8', key: 'taskDir' } as const, '')
const board = atom({ plugin: 'whisperm8', key: 'board' } as const, null as BoardView | null)
const folded = atom({ plugin: 'whisperm8', key: 'folded' } as const, false)

const PANE = 'whisperm8-tasks'
const STORE_MODE = 'taskMode'
/** Ob /t zuletzt im Vollbild lief: dann öffnet ein Neustart das Pane wieder. */
const STORE_FULLSCREEN = 'taskFullscreen'
/** Gefundene Ordner der Task-Listen je Session-ID (für Resume), höchstens 30. */
const STORE_DIRS = 'taskDirs'
const POLL_MS = 5_000

const LINKS_HINT =
  '\n\nLinks: when a task has something the user should open (the running app, a site, a design, a PR, a document), pass metadata.links as [{ "label": "App", "url": "http://localhost:3000" }] — label one or two words, http(s) or file URLs. The user sees them as clickable links under the task in the WhisperM8 task view; put them on the task instead of repeating them in replies. With TaskUpdate the links key is replaced as a whole.'

const MODES: readonly TaskMode[] = ['off', 'normal', 'all']
const MODE_LABEL: Record<TaskMode, string> = { off: 'Aus', normal: 'Normal', all: 'Alle' }
const MODE_ARG: Record<string, TaskMode> = {
  '1': 'off',
  aus: 'off',
  off: 'off',
  '2': 'normal',
  normal: 'normal',
  '3': 'all',
  alle: 'all',
  all: 'all',
}
const GLYPH: Record<TaskStatus, string> = { in_progress: '◼', pending: '◻', completed: '✔' }
const COLOR: Record<TaskStatus, string> = { in_progress: 'warning', pending: 'inactive', completed: 'success' }

// Modul-Zustand: nur Steuerung, die Anzeige steht in den Atomen.
let enabled = true
let counterEnabled = true
let pollStarted = false
let refreshPending = false
/** Name → mtime/Größe und gelesener Task: nur geänderte Dateien neu lesen. */
let cache = new Map<string, { stamp: string; item: TaskItem | null }>()
let cacheDir = ''

// MARK: Lesen

const STATUSES: readonly string[] = ['pending', 'in_progress', 'completed']
const MAX_LINKS = 6
const URL_IN_TEXT = /\b(?:https?|file):\/\/[^\s<>"'`)\]]+/g

/** Kurzname eines Links aus dem Text: Host, bei file:// der Dateiname. */
function linkLabel(url: string) {
  const file = /^file:\/\/.*\/([^/]+)\/?$/.exec(url)
  if (file?.[1]) return file[1]
  const host = /^[a-z]+:\/\/([^/:?#]+)/i.exec(url)
  return (host?.[1] ?? url).replace(/^www\./, '')
}

/**
 * Links eines Tasks: `metadata.links` (vom Modell gesetzt, siehe tool.describe)
 * als `[{ label, url }]`, `{ label: url }` oder Liste von URLs; dazu URLs aus
 * Titel und Beschreibung. Doppelte fallen weg, höchstens sechs.
 */
export function taskLinks(raw: { subject?: unknown; description?: unknown; metadata?: unknown }): TaskLink[] {
  const found: TaskLink[] = []
  const add = (label: unknown, url: unknown) => {
    if (typeof url !== 'string' || !/^(?:https?|file):\/\//.test(url.trim())) return
    const href = url.trim()
    if (found.some(l => l.url === href)) return
    const text = typeof label === 'string' && label.trim() !== '' ? label.trim() : linkLabel(href)
    found.push({ label: text.slice(0, 40), url: href })
  }
  const meta = raw.metadata
  const links = meta !== null && typeof meta === 'object' ? (meta as { links?: unknown }).links : undefined
  if (Array.isArray(links)) {
    for (const link of links) {
      if (typeof link === 'string') add(undefined, link)
      else if (link !== null && typeof link === 'object') {
        const l = link as { label?: unknown; title?: unknown; url?: unknown; href?: unknown }
        add(l.label ?? l.title, l.url ?? l.href)
      }
    }
  } else if (links !== null && typeof links === 'object') {
    for (const [label, url] of Object.entries(links as Record<string, unknown>)) add(label, url)
  }
  for (const text of [raw.subject, raw.description]) {
    if (typeof text === 'string') for (const url of text.match(URL_IN_TEXT) ?? []) add(undefined, url.replace(/[.,;:!?]+$/, ''))
  }
  return found.slice(0, MAX_LINKS)
}

export function parseTask(text: string): TaskItem | null {
  try {
    const raw = JSON.parse(text) as Partial<TaskItem> & { status?: string; metadata?: unknown }
    if (typeof raw.id !== 'string' || typeof raw.subject !== 'string') return null
    if (!STATUSES.includes(raw.status ?? '')) return null
    return {
      id: raw.id,
      subject: raw.subject,
      description: typeof raw.description === 'string' ? raw.description : '',
      activeForm: typeof raw.activeForm === 'string' && raw.activeForm !== '' ? raw.activeForm : undefined,
      status: raw.status as TaskStatus,
      owner: typeof raw.owner === 'string' && raw.owner !== '' ? raw.owner : undefined,
      blockedBy: Array.isArray(raw.blockedBy) ? raw.blockedBy.filter(id => typeof id === 'string') : [],
      links: taskLinks(raw),
    }
  } catch {
    return null
  }
}

/** Numerische IDs numerisch („2“ vor „10“), sonst alphabetisch. */
export function byID(a: TaskItem, b: TaskItem) {
  const x = Number(a.id)
  const y = Number(b.id)
  if (Number.isFinite(x) && Number.isFinite(y)) return x - y
  return a.id.localeCompare(b.id)
}

/** Claude Codes Dateiname der Liste: Sonderzeichen werden zu „-“. */
function sanitize(name: string) {
  return name.replace(/[^a-zA-Z0-9_-]/g, '-')
}

async function tasksRoot($: EngineInterface) {
  const configDir = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${(await $.env.get('HOME')) ?? ''}/.claude`
  return `${configDir.replace(/\/$/, '')}/tasks`
}

/**
 * Ordner der Task-Liste. Claude Code nimmt CLAUDE_CODE_TASK_LIST_ID, sonst den
 * Teamnamen der Session — der ist über die API nicht lesbar und folgt nicht
 * immer der Session-ID (mit --session-id gestartet: ein anderer). Deshalb der
 * Reihe nach: Umgebung, der beim ersten TaskCreate gefundene Ordner (Session
 * bzw. $.store je Session-ID, für Resume), zuletzt die Vermutung
 * `session-<erste 8 Zeichen>`.
 */
async function taskDirs($: EngineInterface): Promise<string[]> {
  const root = await tasksRoot($)
  const listID = await $.env.get('CLAUDE_CODE_TASK_LIST_ID')
  if (listID) return [`${root}/${sanitize(listID)}`]
  const sessionID = await $.session.id()
  const learned = await read($, taskDir)
  const stored = ((await $.store.get(STORE_DIRS).catch(() => undefined)) ?? {}) as Record<string, string>
  return [learned, stored[sessionID] ?? '', `${root}/session-${sanitize(sessionID.slice(0, 8))}`, `${root}/${sanitize(sessionID)}`].filter(
    (dir, index, all) => dir !== '' && all.indexOf(dir) === index,
  )
}

/**
 * Nach einem TaskCreate: den Ordner suchen, in dem `<id>.json` mit genau diesem
 * Titel liegt, und ihn merken. Erst die Kandidaten, dann alle Listen — das
 * einmalige Durchsuchen kostet ein Lesen je Liste, danach nichts mehr.
 */
async function learnDir($: EngineInterface, id: string, subject: string) {
  const matches = async (dir: string) => {
    const text = await $.fs.read(`${dir}/${sanitize(id)}.json`).catch(() => null)
    return typeof text === 'string' && parseTask(text)?.subject === subject
  }
  if ((await $.env.get('CLAUDE_CODE_TASK_LIST_ID')) || (await read($, taskDir)) !== '') return
  let found = ''
  for (const dir of await taskDirs($)) {
    if (await matches(dir)) {
      found = dir
      break
    }
  }
  if (found === '') {
    const root = await tasksRoot($)
    const lists = (await $.fs.list(root).catch(() => [])).filter(entry => entry.kind === 'dir').slice(0, 400)
    for (const entry of lists) {
      if (await matches(`${root}/${entry.name}`)) {
        found = `${root}/${entry.name}`
        break
      }
    }
  }
  if (found === '') return
  await update($, taskDir, () => found)
  const sessionID = await $.session.id()
  const stored = ((await $.store.get(STORE_DIRS).catch(() => undefined)) ?? {}) as Record<string, string>
  const kept = Object.entries({ ...stored, [sessionID]: found }).slice(-30)
  await $.store.set(STORE_DIRS, Object.fromEntries(kept)).catch(() => undefined)
}

async function refreshTasks($: EngineInterface) {
  let dir = ''
  let entries: Awaited<ReturnType<EngineInterface['fs']['list']>> = []
  for (const candidate of await taskDirs($)) {
    const listed = await $.fs.list(candidate).catch(() => null)
    if (listed !== null) {
      dir = candidate
      entries = listed
      break
    }
  }
  if (dir !== cacheDir) {
    cache = new Map()
    cacheDir = dir
  }
  const next = new Map<string, { stamp: string; item: TaskItem | null }>()
  let changed = false
  for (const entry of entries) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.json') || entry.name.startsWith('.')) continue
    const stamp = `${entry.mtimeMs}:${entry.size}`
    const known = cache.get(entry.name)
    if (known !== undefined && known.stamp === stamp) {
      next.set(entry.name, known)
      continue
    }
    const text = await $.fs.read(`${dir}/${entry.name}`).catch(() => null)
    next.set(entry.name, { stamp, item: typeof text === 'string' ? parseTask(text) : null })
    changed = true
  }
  if (!changed && next.size === cache.size) return
  cache = next
  const items = [...next.values()].flatMap(v => (v.item === null ? [] : [v.item])).sort(byID)
  await update($, taskItems, () => items)
}

/** Mehrere Änderungen kurz hintereinander lösen EIN Lesen aus. */
function scheduleRefresh($: EngineInterface) {
  if (refreshPending) return
  refreshPending = true
  $.clock.after(150, () => {
    refreshPending = false
    void refreshTasks($).catch(() => undefined)
  })
}

// MARK: Modus

export function nextMode(mode: TaskMode): TaskMode {
  return MODES[(MODES.indexOf(mode) + 1) % MODES.length] ?? 'off'
}

export function counterText(items: readonly TaskItem[]): string {
  const active = items.filter(t => t.status === 'in_progress').length
  const open = items.filter(t => t.status === 'pending').length
  if (active + open === 0) return ''
  const parts: string[] = []
  if (active > 0) parts.push(`${active} aktiv`)
  if (open > 0) parts.push(`${open} offen`)
  return parts.join(' · ')
}

/** Normal: laufende und offene; Alle: dazu die erledigten. */
export function visible(items: readonly TaskItem[], mode: TaskMode): TaskItem[] {
  if (mode === 'off') return []
  return mode === 'all' ? [...items] : items.filter(t => t.status !== 'completed')
}

async function setMode($: EngineInterface, mode: TaskMode) {
  await update($, taskMode, () => mode)
  await $.store.set(STORE_MODE, mode).catch(() => undefined)
  if (mode === 'off') await closePane($)
  else scheduleRefresh($)
}

async function closePane($: EngineInterface) {
  const panes = await $.ui.panes().catch(() => [])
  if (panes.some(p => p.id === PANE)) await $.ui.close({ id: PANE }).catch(() => undefined)
}

// MARK: Anzeige

type Elements = ReturnType<EngineInterface['ui']['resolve']>

function counts(items: readonly TaskItem[]) {
  const c: Record<TaskStatus, number> = { in_progress: 0, pending: 0, completed: 0 }
  for (const t of items) c[t.status] += 1
  return c
}

/** Kopf: Zähler, bei Platz mit Wörtern. */
function summaryParts(items: readonly TaskItem[], words: boolean) {
  const c = counts(items)
  const label: Record<TaskStatus, string> = { in_progress: 'aktiv', pending: 'offen', completed: 'erledigt' }
  return (['in_progress', 'pending', 'completed'] as const)
    .filter(s => c[s] > 0)
    .map(s => ({ status: s, text: `${GLYPH[s]} ${c[s]}${words ? ` ${label[s]}` : ''}  ` }))
}

/** Ein Task: Symbol, #ID, Titel, @Besitzer; laufend dazu die Tätigkeit, blockiert die Blocker. */
function taskRow(ui: Elements, task: TaskItem, mode: TaskMode, openIDs: ReadonlySet<string>) {
  const { Box, Text, Link } = ui
  const done = task.status === 'completed'
  const blockers = task.blockedBy.filter(id => openIDs.has(id))
  return (
    <Box key={`task-${task.id}`} flexDirection="row" columnGap={1}>
      <Box width={1} flexShrink={0}>
        <Text color={COLOR[task.status]}>{GLYPH[task.status]}</Text>
      </Box>
      <Box flexDirection="column" flexGrow={1} flexShrink={1}>
        <Text wrap={mode === 'all' ? 'wrap' : 'truncate-end'} dimColor={done} bold={task.status === 'in_progress'}>
          <Text dimColor>#{task.id} </Text>
          {task.subject}
          {task.owner !== undefined && <Text color="claude"> @{task.owner}</Text>}
        </Text>
        {task.status === 'in_progress' && task.activeForm !== undefined && (
          <Text dimColor italic wrap={mode === 'all' ? 'wrap' : 'truncate-end'}>
            {'↳ '}
            {task.activeForm}
          </Text>
        )}
        {!done && blockers.length > 0 && (
          <Text dimColor wrap="truncate-end">
            {'⊘ wartet auf '}
            {blockers.map(id => `#${id}`).join(', ')}
          </Text>
        )}
        {/* Klick (im WhisperM8-Terminal cmd+Klick) öffnet den Link. */}
        {task.links.length > 0 && (
          <Text wrap="wrap" dimColor={done}>
            {task.links.map((link, index) => (
              <Text key={`task-${task.id}-link-${index}`}>
                {index > 0 ? '  ' : ''}
                <Text color="claude">↗ </Text>
                <Link href={link.url} label={link.label} />
              </Text>
            ))}
          </Text>
        )}
      </Box>
    </Box>
  )
}

/** Knöpfe 1/2/3; der aktuelle Modus fett. Ohne Hotkeys, wo das Board die Ziffern hält. */
function modeButtons(ui: Elements, mode: TaskMode, $: EngineInterface, hotkeys: boolean) {
  const { Button, Text } = ui
  return MODES.map((m, index) => (
    <Button
      key={`task-mode-${m}`}
      plain
      hotkey={hotkeys ? String(index + 1) : undefined}
      onPress={() => setMode($, m)}
    >
      {m === mode ? <Text bold color="claude">{MODE_LABEL[m]}</Text> : <Text dimColor>{MODE_LABEL[m]}</Text>}
    </Button>
  ))
}

function taskList(ui: Elements, items: readonly TaskItem[], mode: TaskMode) {
  const { Box, Text } = ui
  const shown = visible(items, mode)
  const openIDs = new Set(items.filter(t => t.status !== 'completed').map(t => t.id))
  const hiddenDone = items.length - shown.length
  return (
    <Box flexDirection="column">
      {shown.map(task => taskRow(ui, task, mode, openIDs))}
      {shown.length === 0 && items.length > 0 && <Text dimColor>Alles erledigt.</Text>}
      {hiddenDone > 0 && (
        <Text dimColor>
          +{hiddenDone} erledigt · 3 = Alle
        </Text>
      )}
    </Box>
  )
}

// MARK: Hooks

/** Aus session.start (register.tsx): Modus aus dem Store, Befehl, Takt, erstes Lesen. */
export async function startTasks($: EngineInterface) {
  if (!enabled) return
  const stored = await $.store.get(STORE_MODE).catch(() => undefined)
  const mode: TaskMode = MODES.includes(stored as TaskMode) ? (stored as TaskMode) : 'off'
  await update($, taskMode, () => mode)
  try {
    await $.command.register({
      name: 't',
      description: 'Task-Liste: Aus → Normal → Alle (jeder Aufruf ein Modus weiter); /t aus | normal | alle',
    })
  } catch {
    // Ohne Befehl bleiben Anzeige und Hotkeys.
  }
  // Lesen nicht awaiten: der Chatstart wartet nicht auf Dateien.
  void refreshTasks($).catch(() => undefined)
  // Nach Neustart im Vollbild: das Pane wieder auf (unaufgefordert: erst ab 110
  // Spalten, sonst wartet es, und das Band springt ein).
  if (mode !== 'off' && (await $.store.get(STORE_FULLSCREEN).catch(() => false)) === true) {
    void $.ui.open({ id: PANE, title: 'Tasks' }).catch(() => undefined)
  }
  if (!pollStarted) {
    pollStarted = true
    poll($)
  }
}

/**
 * 5-s-Takt als Kette aus `clock.after` (läuft einmal je Mod-Instanz; ein Reload
 * bricht die Kette mit der alten Umgebung ab). Liest nur, wenn etwas angezeigt
 * wird: Liste an oder Zähler an.
 */
function poll($: EngineInterface) {
  $.clock.after(POLL_MS, () => {
    void (async () => {
      if ((await read($, taskMode)) !== 'off' || counterEnabled) await refreshTasks($)
    })()
      .catch(() => undefined)
      .finally(() => poll($))
  })
}

export function registerTasks(on: On, options: PluginOptions) {
  enabled = options.taskliste !== false
  counterEnabled = options.taskzaehler !== false
  if (!enabled) return

  on('tool.call', { tool: ['TaskCreate', 'TaskUpdate'] }, async ($, e, next) => {
    const ran = await next(e)
    const created = 'result' in ran ? (ran.result as { task?: { id?: unknown; subject?: unknown } } | undefined)?.task : undefined
    if (typeof created?.id === 'string' && typeof created.subject === 'string') {
      await learnDir($, created.id, created.subject).catch(() => undefined)
    }
    scheduleRefresh($)
    return ran
  })

  // Das Modell erfährt, wie es Links an einen Task hängt (Task-Anzeige zeigt sie klickbar).
  on('tool.describe', { tool: ['TaskCreate', 'TaskUpdate'] }, async ($, e, next) => {
    const described = await next(e)
    return { ...described, description: `${described.description}${LINKS_HINT}` }
  })

  on('command.run', { command: 't' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    const current = await read($, taskMode)
    const mode = arg === '' ? nextMode(current) : MODE_ARG[arg]
    if (mode === undefined) return { text: `Tasks: ${MODE_LABEL[current]}. /t schaltet weiter; /t aus | normal | alle` }
    await setMode($, mode)
    // Ohne Angabe (headless, Befehl aus einem Plugin) gilt Main-Screen.
    const fullscreen = e.presentation?.isFullscreen === true
    await $.store.set(STORE_FULLSCREEN, fullscreen).catch(() => undefined)
    // Vollbild: Pane (rechts ab 110 Spalten). Main-Screen: das Band über dem Prompt.
    if (mode !== 'off' && fullscreen) await $.ui.open({ id: PANE, title: 'Tasks' })
    if (mode !== 'off' && !fullscreen) await closePane($)
    await refreshTasks($).catch(() => undefined)
    const items = await read($, taskItems)
    const what = mode === 'off' ? 'ausgeblendet' : mode === 'normal' ? 'aktive und offene' : 'alle, auch erledigte'
    const count = items.length === 0 ? 'noch keine Tasks' : counterText(items) || `${items.length} erledigt`
    return { text: `Tasks: ${MODE_LABEL[mode]} (${what}; ${count}). /t schaltet weiter.` }
  })

  // Pane von Hand geschlossen (Esc-Marke, ctrl+x x): heißt „Aus“.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const closed = await next(e)
    if (e.origin.kind === 'person') {
      await update($, taskMode, () => 'off' as TaskMode)
      await $.store.set(STORE_MODE, 'off').catch(() => undefined)
    }
    return closed
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Text } = ui
    const mode = await read($, taskMode)
    const items = await read($, taskItems)
    const words = e.props.bodyColumns >= 34
    return (
      <Box flexDirection="column" rowGap={1}>
        <Box flexDirection="row" columnGap={2} flexWrap="wrap">
          {modeButtons(ui, mode, $, true)}
        </Box>
        {items.length === 0 ? (
          <Text dimColor>Noch keine Tasks in dieser Session.</Text>
        ) : (
          <Box flexDirection="column">
            <Box flexDirection="row" flexWrap="wrap">
              {summaryParts(items, words).map(p => (
                <Text key={`task-sum-${p.status}`} color={COLOR[p.status]}>
                  {p.text}
                </Text>
              ))}
            </Box>
            {taskList(ui, items, mode)}
          </Box>
        )}
      </Box>
    )
  })

  // Band über dem Prompt, wo kein Pane steht. Liegt außen um das Board-Band.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    if (e.props.hasSurvey) return below
    const mode = await read($, taskMode)
    if (mode === 'off') return below
    const items = await read($, taskItems)
    if (visible(items, mode).length === 0 && (mode === 'normal' || items.length === 0)) return below
    if (e.viewport?.isFullscreen === true) {
      const panes = await $.ui.panes().catch(() => [])
      if (panes.some(p => p.id === PANE && p.isPlaced)) return below
    }
    const ui = $.ui.resolve(e)
    const { Box, Text } = ui
    const cols = e.props.bodyColumns
    // Die Ziffern des offenen Board-Bands öffnen Chats: dann ohne Hotkeys.
    const view = await read($, board)
    const boardDigits = view !== null && view.isActive && view.entries.length > 0 && !(await read($, folded))
    const withButtons = cols >= 56
    const band = (
      <Box flexDirection="column" width={cols}>
        <Box flexDirection="row" columnGap={1}>
          <Text color="claude" bold>
            Tasks
          </Text>
          <Box flexDirection="row" flexGrow={1}>
            {summaryParts(items, cols >= 72).map(p => (
              <Text key={`task-sum-${p.status}`} color={COLOR[p.status]}>
                {p.text}
              </Text>
            ))}
          </Box>
          {withButtons ? modeButtons(ui, mode, $, !boardDigits) : <Text dimColor>/t</Text>}
        </Box>
        {taskList(ui, items, mode)}
      </Box>
    )
    return (
      <Box flexDirection="column">
        {band}
        {below}
      </Box>
    )
  })

  // Zähler am Ende der Hinweiszeile unter dem Prompt („3 aktiv · 2 offen“).
  // Nicht $.ui.status: davor setzt Claude Code „⚠“, das las sich als Warnung.
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    if (!counterEnabled) return next(e)
    const text = counterText(await read($, taskItems))
    if (text === '') return next(e)
    const tail = `Tasks ${text}`
    return next({ ...e, props: { ...e.props, tail: e.props.tail ? `${e.props.tail} · ${tail}` : tail } })
  })
}
