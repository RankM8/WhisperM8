import { atom, read, update } from 'claude-code'
import type { EngineInterface, On, PluginOptions } from 'claude-code'

import type { TaskItem, TaskStatus } from '../types'

// Tasks im Chat: Claude Codes eigene Liste (ctrl+t) bleibt die einzige Liste im
// Terminal. Die Mod hängt nur einen Zähler an die Hinweiszeile unter dem Prompt
// und erklärt dem Modell `metadata.links`. Die volle Liste mit Links zeigt die
// Notiz-Karte der App (`AgentChatTasksStore` liest dieselben Dateien).
//
// Bis 22.10.2026 stand hier eine eigene Liste (/t, Pane und Band über dem
// Prompt). In App-Sessions (Main-Screen) zeichnet Claude den Bereich über dem
// Prompt ständig neu; die hohe Liste hinterließ dabei Reste im Verlauf. Claudes
// Liste hält sich klein und hat das Problem nicht.
//
// Wahrheit: Claude Codes Dateien `<config-dir>/tasks/<liste>/<id>.json`. Die Mod
// liest sie nach jedem TaskCreate/TaskUpdate und alle 5 s (Teammates anderer
// Prozesse schreiben ohne tool.call hier).
//
// Eigene Datei, von register.tsx nur eingebunden: Hooks und `$` folgt die
// Engine über einen Import nur in Funktions-Deklarationen, und `session.start`
// darf je Plugin nur einmal ohne Matcher stehen (dort ruft register.tsx
// `startTasks`).

const taskItems = atom({ plugin: 'whisperm8', key: 'taskItems' } as const, [] as TaskItem[])
const taskDir = atom({ plugin: 'whisperm8', key: 'taskDir' } as const, '')

/** Gefundene Ordner der Task-Listen je Session-ID (für Resume), höchstens 30. */
const STORE_DIRS = 'taskDirs'
const POLL_MS = 5_000

const LINKS_HINT =
  '\n\nLinks: when a task has something the user should open (the running app, a site, a design, a PR, a document), pass metadata.links as [{ "label": "App", "url": "http://localhost:3000" }] — label one or two words, http(s) or file URLs. The user sees them as clickable links under the task in the WhisperM8 app; put them on the task instead of repeating them in replies. With TaskUpdate the links key is replaced as a whole.'

// Modul-Zustand: nur Steuerung, die Tasks stehen im Atom.
let counterEnabled = true
let pollStarted = false
let refreshPending = false
/** Name → mtime/Größe und gelesener Task: nur geänderte Dateien neu lesen. */
let cache = new Map<string, { stamp: string; item: TaskItem | null }>()
let cacheDir = ''

// MARK: Lesen

const STATUSES: readonly string[] = ['pending', 'in_progress', 'completed']

/** Claude Codes Task-Datei, nur was Zähler und Ordnersuche brauchen. */
export function parseTask(text: string): TaskItem | null {
  try {
    const raw = JSON.parse(text) as { id?: unknown; subject?: unknown; status?: unknown }
    if (typeof raw.id !== 'string' || typeof raw.subject !== 'string') return null
    if (typeof raw.status !== 'string' || !STATUSES.includes(raw.status)) return null
    return { id: raw.id, subject: raw.subject, status: raw.status as TaskStatus }
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

// MARK: Zähler

export function counterText(items: readonly TaskItem[]): string {
  const active = items.filter(t => t.status === 'in_progress').length
  const open = items.filter(t => t.status === 'pending').length
  if (active + open === 0) return ''
  const parts: string[] = []
  if (active > 0) parts.push(`${active} aktiv`)
  if (open > 0) parts.push(`${open} offen`)
  return parts.join(' · ')
}

// MARK: Hooks

/** Aus session.start (register.tsx): erstes Lesen und Takt, nur mit Zähler. */
export async function startTasks($: EngineInterface) {
  if (!counterEnabled) return
  // Lesen nicht awaiten: der Chatstart wartet nicht auf Dateien.
  void refreshTasks($).catch(() => undefined)
  if (!pollStarted) {
    pollStarted = true
    poll($)
  }
}

/**
 * 5-s-Takt als Kette aus `clock.after` (läuft einmal je Mod-Instanz; ein Reload
 * bricht die Kette mit der alten Umgebung ab).
 */
function poll($: EngineInterface) {
  $.clock.after(POLL_MS, () => {
    void refreshTasks($)
      .catch(() => undefined)
      .finally(() => poll($))
  })
}

export function registerTasks(on: On, options: PluginOptions) {
  counterEnabled = options.taskzaehler !== false

  // Das Modell erfährt, wie es Links an einen Task hängt (die Notiz-Karte der App zeigt sie klickbar).
  on('tool.describe', { tool: ['TaskCreate', 'TaskUpdate'] }, async ($, e, next) => {
    const described = await next(e)
    return { ...described, description: `${described.description}${LINKS_HINT}` }
  })

  if (!counterEnabled) return

  on('tool.call', { tool: ['TaskCreate', 'TaskUpdate'] }, async ($, e, next) => {
    const ran = await next(e)
    const created = 'result' in ran ? (ran.result as { task?: { id?: unknown; subject?: unknown } } | undefined)?.task : undefined
    if (typeof created?.id === 'string' && typeof created.subject === 'string') {
      await learnDir($, created.id, created.subject).catch(() => undefined)
    }
    scheduleRefresh($)
    return ran
  })

  // Zähler am Ende der Hinweiszeile unter dem Prompt („3 aktiv · 2 offen“).
  // Nicht $.ui.status: davor setzt Claude Code „⚠“, das las sich als Warnung.
  // Eine Zeile mit fester Höhe: hinterlässt im Main-Screen keine Reste.
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const text = counterText(await read($, taskItems))
    if (text === '') return next(e)
    const tail = `Tasks ${text}`
    return next({ ...e, props: { ...e.props, tail: e.props.tail ? `${e.props.tail} · ${tail}` : tail } })
  })
}
