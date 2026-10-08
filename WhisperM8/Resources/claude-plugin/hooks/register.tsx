import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BoardEntry, BoardLight, BoardView } from '../types'

// Jarvis-Board: Übersicht der Chats, die Jarvis aktiv betreut, als Band über
// dem Prompt. Die Wahrheit liegt in der App (`whisperm8 chats board`), die Mod
// zeigt nur an, hört per `chats watch` auf Änderungen und weckt Jarvis.
// Plan und Messwerte: docs/plans/whisperm8-plugin.md (Prototyp 08.10.2026).
//
// Ausgeschaltet (kein aktives Board dieser Session) zeichnet die Mod nichts und
// startet keinen Prozess; das Tool steht dann nur hinter ToolSearch.

const board = atom({ plugin: 'whisperm8', key: 'board' } as const, null as BoardView | null)
const folded = atom({ plugin: 'whisperm8', key: 'folded' } as const, false)
const now = atom({ plugin: 'whisperm8', key: 'now' } as const, 0)
const woken = atom({ plugin: 'whisperm8', key: 'woken' } as const, [] as string[])

const TOOL = 'mcp__whisperm8__board'
const PANE = 'whisperm8-board'
const JARVIS_SKILL = 'whisperm8:jarvis'
const MIN = 60_000
/** Mehrere Weck-Gründe kurz hintereinander werden zu einem Prompt gebündelt. */
const WAKE_COALESCE_MS = 5_000
/** Höchstens ein Weck-Prompt je Minute: Jeder ist ein Turn von Jarvis. */
const WAKE_MIN_GAP_MS = 60_000

// Modul-Zustand: lebt nur bis zum nächsten Reload, deshalb nur Steuerung,
// nie Anzeige (die steht in den Atomen oben).
let sessionID: string | null = null
let binary = 'whisperm8'
let watchGeneration = 0
let watchStream: { return?: (value?: undefined) => unknown } | null = null
/** Läuft eine watch-Schleife (auch während ihrer Backoff-Pause)? */
let watchRunning = false
let sessionEnded = false
let refreshPending = false
let toolDeferred: boolean | null = null
let wakeQueue: string[] = []
let wakeTimerArmed = false
let lastWakeAt = 0

const ORDER: Record<BoardLight, number> = { needsYou: 0, done: 1, running: 2, parked: 3 }
const COLOR: Record<BoardLight, string> = { needsYou: 'error', running: 'warning', done: 'success', parked: 'inactive' }
const GLYPH: Record<BoardLight, string> = { needsYou: '●', running: '●', done: '●', parked: '○' }
const LABEL: Record<BoardLight, string> = { needsYou: 'wartet', running: 'läuft', done: 'fertig', parked: 'geparkt' }

// MARK: CLI

type CLIResult = { ok: boolean; stdout: string; message: string }

const cli = async ($: EngineInterface, args: string[], timeoutMs = 15_000): Promise<CLIResult> => {
  const run = (bin: string) => $.process.run([bin, ...args], { timeoutMs })
  let result
  try {
    result = await run(binary)
  } catch {
    // PATH ohne ~/.local/bin (Session außerhalb einer Login-Shell): absolut.
    const home = await $.env.get('HOME')
    binary = `${home ?? ''}/.local/bin/whisperm8`
    try {
      result = await run(binary)
    } catch (error) {
      return { ok: false, stdout: '', message: `whisperm8 nicht ausführbar: ${String(error)}` }
    }
  }
  const message = (result.stderr.trim() || result.stdout.trim()).split('\n')[0] ?? ''
  return { ok: result.exitCode === 0, stdout: result.stdout, message }
}

const parseBoard = (stdout: string): BoardView | null => {
  try {
    const raw = JSON.parse(stdout) as Partial<BoardView>
    if (typeof raw.owner !== 'string' || !Array.isArray(raw.entries)) return null
    return {
      owner: raw.owner,
      ownerRef: raw.ownerRef ?? raw.owner.slice(0, 8).toLowerCase(),
      isActive: raw.isActive === true,
      cursor: typeof raw.cursor === 'string' ? raw.cursor : null,
      entries: raw.entries as BoardEntry[],
    }
  } catch {
    return null
  }
}

// MARK: Board lesen

const refresh = async ($: EngineInterface) => {
  const ran = await cli($, ['chats', 'board', '--json'])
  if (!ran.ok) return
  const next = parseBoard(ran.stdout)
  if (next === null) return
  await update($, board, () => next)
  const at = await $.clock.now()
  await update($, now, () => at)
  // Bewusst keine Statuszeile: Claude Code setzt „⚠“ davor, sie sah nach
  // einer Warnung aus und wiederholte nur die Zahlen aus dem Band.
  // Scheitert die Tool-Anmeldung, laufen Band und Wecken trotzdem.
  await syncTool($, next.isActive).catch(() => undefined)
  if (next.isActive) {
    if (!watchRunning) startWatch($)
  } else {
    stopWatch()
  }
}

/** Mehrere Ereignisse kurz hintereinander lösen EIN Lesen aus. */
const scheduleRefresh = ($: EngineInterface) => {
  if (refreshPending) return
  refreshPending = true
  $.clock.after(400, () => {
    refreshPending = false
    void refresh($).catch(() => undefined)
  })
}

const counts = (entries: readonly BoardEntry[]) => {
  const c: Record<BoardLight, number> = { needsYou: 0, running: 0, done: 0, parked: 0 }
  for (const entry of entries) c[entry.light] = (c[entry.light] ?? 0) + 1
  return c
}

/**
 * Kopfzeile so ausführlich, wie sie in `room` Spalten passt: erst fällt
 * „· Board“ weg, dann die Wörter außer „wartet“, das ist die Zahl, die zählt.
 * Feste Breitenstufen reichten nicht: Bei 67 Spalten brach der Kopf um.
 */
const fitHeader = (c: Record<BoardLight, number>, room: number, title: string, withBoard: boolean) => {
  const parts = (words: boolean) =>
    (['needsYou', 'running', 'done', 'parked'] as const)
      .filter(l => c[l] > 0)
      .map(l => ({ light: l, text: `${GLYPH[l]} ${c[l]}${words || l === 'needsYou' ? ` ${LABEL[l]}` : ''}  ` }))
  const candidates: [string, boolean][] = [[title, true], [title, false]]
  if (withBoard) candidates.unshift([`${title} · Board`, true])
  for (const [head, words] of candidates) {
    const fitted = parts(words)
    if (head.length + 2 + fitted.reduce((n, p) => n + p.text.length, 0) <= room) return { head, parts: fitted }
  }
  return { head: title, parts: parts(false) }
}


/** Aktiv: Schema ab Turn 1 in der Liste. Sonst nur der Name (ToolSearch). */
const syncTool = async ($: EngineInterface, active: boolean) => {
  const deferred = !active
  if (toolDeferred === deferred) return
  toolDeferred = null
  await $.tool.register({
    name: 'board',
    description:
      'Jarvis-Board pflegen: die Chats, die du gerade aktiv betreust, mit Ampel (needsYou | running | done | parked), Auftrag (mission), was der Chat vom User braucht (needs) und nächstem Schritt (next). action: set | remove | clear | activate | deactivate | read. ref = Kurz-Ref des Chats wie in whisperm8 chats list.',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['set', 'remove', 'clear', 'activate', 'deactivate', 'read'] },
        ref: { type: 'string', description: 'Chat-Ref (für set und remove)' },
        light: { type: 'string', enum: ['needsYou', 'running', 'done', 'parked'] },
        mission: { type: 'string', description: 'Eine Zeile: was der Chat tut' },
        needs: { type: 'string', description: 'Was der Chat vom User braucht (bei needsYou)' },
        next: { type: 'string', description: 'Nächster Schritt' },
      },
      required: ['action'],
    },
    isDeferred: deferred,
  })
  toolDeferred = deferred
}

// MARK: Live über `chats watch`

type WatchEvent = {
  event?: string
  gap?: boolean
  kind?: string
  owner?: string
  sessionID?: string
  from?: string | null
  to?: string | null
}

const sameID = (a: string | undefined, b: string | undefined) =>
  a !== undefined && b !== undefined && a.toUpperCase() === b.toUpperCase()

const stopWatch = () => {
  watchGeneration += 1
  watchRunning = false
  const stream = watchStream
  watchStream = null
  void stream?.return?.(undefined)
}

const sleep = ($: EngineInterface, ms: number) => new Promise<void>(resolve => void $.clock.after(ms, resolve))

/** Ein Kind für die Session; endet es, mit Backoff und frischem Cursor neu. */
const startWatch = ($: EngineInterface) => {
  const generation = ++watchGeneration
  watchRunning = true
  void (async () => {
    let delay = 2_000
    while (generation === watchGeneration && !sessionEnded) {
      const cursor = (await read($, board))?.cursor ?? null
      const argv = [binary, 'chats', 'watch', '--interval', '2']
      if (cursor !== null) argv.push('--cursor', cursor)
      const iterator = $.process.spawn({ argv })[Symbol.asyncIterator]()
      watchStream = iterator
      let buffer = ''
      try {
        for (;;) {
          const step = await iterator.next()
          if (step.done || generation !== watchGeneration) break
          const chunk = step.value
          if (chunk.stream !== 'stdout') continue
          buffer += chunk.text
          const lines = buffer.split('\n')
          buffer = lines.pop() ?? ''
          for (const line of lines) {
            if (line.trim() === '') continue
            try {
              await handleEvent($, JSON.parse(line) as WatchEvent)
              delay = 2_000
            } catch {
              // Eine kaputte Zeile beendet den Strom nicht.
            }
          }
        }
      } catch {
        // Start gescheitert oder Kind gestorben: unten neu ansetzen.
      }
      if (generation !== watchGeneration || sessionEnded) break
      watchStream = null
      await sleep($, delay)
      delay = Math.min(delay * 2, 60_000)
      // Frischer Stand samt Cursor, bevor der nächste Strom ansetzt.
      await refresh($).catch(() => undefined)
    }
  })()
    .catch(() => undefined)
    .finally(() => {
      if (generation === watchGeneration) watchRunning = false
    })
}

const handleEvent = async ($: EngineInterface, ev: WatchEvent) => {
  if (ev.gap === true || ev.event === 'gap') {
    scheduleRefresh($)
    return
  }
  if (ev.event !== undefined) return
  if (ev.kind === 'board') {
    if (sameID(ev.owner, sessionID ?? undefined)) scheduleRefresh($)
    return
  }
  const view = await read($, board)
  const entry = view?.entries.find(e => sameID(e.sessionID, ev.sessionID))
  if (entry === undefined) return
  scheduleRefresh($)
  await considerWake($, entry, ev)
}

// MARK: Wecken

/** Wartet auf den User oder hat den Turn beendet: dann lohnt ein Blick. */
const wakeReason = (ev: WatchEvent): string | null => {
  if (ev.to === 'awaitingInput') return 'wartet auf dich'
  if (ev.from === 'working' && ev.to === 'idle') return 'fertig – prüfen'
  return null
}

let wakeMode = 'turn'

const considerWake = async ($: EngineInterface, entry: BoardEntry, ev: WatchEvent) => {
  const id = entry.sessionID.toUpperCase()
  if (ev.to === 'working') {
    // Arbeitet wieder: derselbe Zustand darf später erneut wecken.
    await update($, woken, list => (list ?? []).filter(key => !key.startsWith(`${id}:`)))
    return
  }
  const reason = wakeReason(ev)
  if (reason === null || entry.light === 'parked' || wakeMode === 'aus') return
  const key = `${id}:${ev.to}`
  if ((await read($, woken)).includes(key)) return
  await update($, woken, list => [...(list ?? []), key].slice(-200))
  wakeQueue.push(`[Board] ${entry.title} (${entry.ref}): ${reason}`)
  armWake($)
}

const armWake = ($: EngineInterface) => {
  if (wakeTimerArmed) return
  wakeTimerArmed = true
  const wait = Math.max(WAKE_COALESCE_MS, lastWakeAt + WAKE_MIN_GAP_MS - Date.now())
  $.clock.after(wait, () => void flushWake($).catch(() => undefined))
}

const flushWake = async ($: EngineInterface) => {
  wakeTimerArmed = false
  const lines = wakeQueue
  wakeQueue = []
  if (lines.length === 0) return
  lastWakeAt = Date.now()
  $.ui.toast(lines.length === 1 ? lines[0]! : `${lines[0]} (+${lines.length - 1})`)
  void $.audio.play({ asset: 'sounds/board.wav' }).catch(() => undefined)
  if (wakeMode !== 'turn') return
  await $.prompt.submit({ text: `${lines.join('\n')}\nStand prüfen und das Board nachführen.` })
}

// MARK: Anzeige

const age = (iso: string, at: number, short: boolean) => {
  const since = Date.parse(iso)
  const m = Number.isNaN(since) ? 0 : Math.max(0, Math.floor((at - since) / MIN))
  if (m < 1) return 'jetzt'
  if (m < 60) return short ? `${m}m` : `${m} min`
  const h = Math.floor(m / 60)
  if (h < 24) return short ? `${h}h` : `${h} h`
  return short ? `${Math.floor(h / 24)}d` : `${Math.floor(h / 24)} d`
}

/** Beim Warten das Anliegen, sonst der nächste Schritt (Rückfall: Auftrag). */
const say = (e: BoardEntry) => {
  const next = e.next || e.mission
  if (e.light === 'needsYou') return e.needs || next
  if (e.light === 'done') return next ? `fertig · ${next}` : 'fertig'
  return next
}

const sorted = (entries: readonly BoardEntry[]) =>
  [...entries].sort((a, b) => ORDER[a.light] - ORDER[b.light] || Date.parse(a.updatedAt) - Date.parse(b.updatedAt))

// MARK: Hooks

export const register: Register = (on, options) => {
  wakeMode = typeof options.wecken === 'string' ? options.wecken : 'turn'

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    sessionEnded = false
    sessionID = (await $.env.get('WHISPERM8_SESSION_ID')) ?? null
    // Außerhalb eines WhisperM8-Chats gibt es kein Board.
    if (sessionID === null) return started
    try {
      await $.command.register({ name: 'board', description: 'Jarvis-Board: Details anzeigen; an | aus | zu | auf' })
    } catch {
      // Ohne Befehl bleiben Band und Tool.
    }
    try {
      await syncTool($, false)
    } catch {
      // Ohne Tool pflegt Jarvis das Board per CLI.
    }
    // Nach Neustart oder Reload: ein aktives Board ist sofort wieder da.
    await refresh($).catch(() => undefined)
    $.clock.every(30_000, () => void $.clock.now().then(at => update($, now, () => at)).catch(() => undefined))
    return started
  })

  on('session.end', async ($, e, next) => {
    sessionEnded = true
    stopWatch()
    return next(e)
  })

  // Jarvis startet: Board einschalten, unabhängig davon, ob das Modell daran denkt.
  on('skill.prompt', { skill: JARVIS_SKILL }, async ($, e, next) => {
    const result = await next(e)
    if (sessionID === null) return result
    const ran = await cli($, ['chats', 'board', 'activate', '--json'])
    if (!ran.ok) return result
    await refresh($).catch(() => undefined)
    return {
      text: `${result.text}\n\n[whisperm8] Das Jarvis-Board dieser Session ist aktiv. Pflege es mit dem Tool ${TOOL} (oder whisperm8 chats board …).`,
    }
  })

  on('tool.call', { tool: TOOL }, async ($, e) => {
    const input = e as unknown as { action?: string; ref?: string; light?: string; mission?: string; needs?: string; next?: string }
    const action = input.action ?? 'read'
    let args: string[]
    switch (action) {
      case 'set': {
        if (!input.ref) return { result: 'FEHLER: set braucht ref.' }
        args = ['chats', 'board', 'set', input.ref]
        if (input.light) args.push('--light', input.light)
        if (input.mission !== undefined) args.push('--mission', input.mission)
        if (input.needs !== undefined) args.push('--needs', input.needs)
        if (input.next !== undefined) args.push('--next', input.next)
        break
      }
      case 'remove':
        if (!input.ref) return { result: 'FEHLER: remove braucht ref.' }
        args = ['chats', 'board', 'remove', input.ref]
        break
      case 'clear':
      case 'activate':
      case 'deactivate':
        args = ['chats', 'board', action]
        break
      default:
        args = ['chats', 'board']
    }
    const ran = await cli($, [...args, '--json'])
    await refresh($).catch(() => undefined)
    return { result: ran.ok ? ran.stdout.trim() || 'ok' : `FEHLER: ${ran.message}` }
  })

  on('command.run', { command: 'board' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'zu' || arg === 'auf') {
      await update($, folded, () => arg === 'zu')
      return { text: arg === 'zu' ? 'Board eingeklappt.' : 'Board ausgeklappt.' }
    }
    if (arg === 'an' || arg === 'aus') {
      const ran = await cli($, ['chats', 'board', arg === 'an' ? 'activate' : 'deactivate', '--json'])
      await refresh($).catch(() => undefined)
      if (!ran.ok) return { text: `Board nicht umgeschaltet: ${ran.message}` }
      return { text: arg === 'an' ? 'Board an.' : 'Board aus.' }
    }
    await refresh($).catch(() => undefined)
    const view = await read($, board)
    if (view === null || !view.isActive) return { text: 'Kein aktives Board in dieser Session. /board an schaltet es ein.' }
    await $.ui.open({ id: PANE, title: 'Jarvis-Board' })
    return { text: `Board: ${view.entries.length} Chats.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const view = await read($, board)
    if (view === null || !view.isActive) return next(e)
    const t = await read($, now)
    const isFolded = await read($, folded)
    const { Box, Text, Button } = $.ui.resolve(e)
    const cols = e.props.bodyColumns
    const list = sorted(view.entries)
    const c = counts(list)
    const wide = cols >= 90
    const narrow = cols < 64
    // Platz für Titel und Zahlen: ohne Knopf („z: zu“ / „a: auf“) und Abstand,
    // offen zusätzlich ohne Rahmen und Innenabstand.
    const header = isFolded ? fitHeader(c, cols - 7, '▸ Jarvis', false) : fitHeader(c, cols - 10, 'Jarvis', true)
    const summary = header.parts.map(p => (
      <Text color={COLOR[p.light]} bold={p.light === 'needsYou'}>
        {p.text}
      </Text>
    ))

    if (list.length === 0) {
      return (
        <Box flexDirection="row" width={cols}>
          <Text color="claude" bold>
            Jarvis{'  '}
          </Text>
          <Text dimColor>Board aktiv, noch keine Chats</Text>
        </Box>
      )
    }

    if (isFolded) {
      return (
        <Box flexDirection="row" width={cols}>
          <Text color="claude" bold>
            {header.head}
            {'  '}
          </Text>
          <Box flexDirection="row" flexGrow={1}>
            {summary}
          </Box>
          <Button key="open" label="auf" hotkey="a" plain dimColor onPress={() => update($, folded, () => false)} />
        </Box>
      )
    }

    // Rahmen + Kopf = 3 Zeilen; der Rest gehört den Chats.
    const room = Math.max(1, e.props.maxRows - 3)
    const shown = list.length > room ? list.slice(0, room - 1) : list
    const hidden = list.length - shown.length
    const nameWidth = wide ? 22 : narrow ? 15 : 18
    const ageWidth = wide ? 8 : 4
    const border = c.needsYou > 0 ? 'error' : c.done > 0 ? 'success' : 'inactive'

    return (
      <Box flexDirection="column" borderStyle="round" borderColor={border} paddingX={1} width={cols}>
        <Box flexDirection="row">
          <Text color="claude" bold>
            {header.head}
            {'  '}
          </Text>
          <Box flexDirection="row" flexGrow={1}>
            {summary}
          </Box>
          <Button key="fold" label="zu" hotkey="z" plain dimColor onPress={() => update($, folded, () => true)} />
        </Box>
        {shown.map(entry => (
          <Box key={entry.sessionID} flexDirection="row" columnGap={1}>
            <Box width={1} flexShrink={0}>
              <Text color={COLOR[entry.light]}>{GLYPH[entry.light]}</Text>
            </Box>
            <Box width={nameWidth} flexShrink={0}>
              <Text bold={entry.light === 'needsYou'} dimColor={entry.light === 'parked'} wrap="truncate-end">
                {entry.title}
              </Text>
            </Box>
            {wide && (
              <Box width={8} flexShrink={0}>
                <Text dimColor>{entry.ref}</Text>
              </Box>
            )}
            <Box flexGrow={1} flexShrink={1}>
              <Text
                color={entry.light === 'needsYou' ? 'error' : undefined}
                dimColor={entry.light !== 'needsYou'}
                italic={entry.light === 'parked'}
                wrap="truncate-end"
              >
                {entry.status === 'awaitingInput' && entry.light !== 'needsYou' ? '⚑ ' : ''}
                {say(entry)}
              </Text>
            </Box>
            <Box width={ageWidth} flexShrink={0} justifyContent="flex-end">
              <Text dimColor>{age(entry.updatedAt, t, !wide)}</Text>
            </Box>
          </Box>
        ))}
        {hidden > 0 && <Text dimColor>+{hidden} weitere · /board</Text>}
      </Box>
    )
  })

  // Details auf Zuruf (`/board`): alle Felder, je Chat zwei Knöpfe, die Jarvis
  // den nächsten Schritt in den Prompt legen. Das Umräumen des Workspaces
  // bleibt bei Jarvis, der seine Slot-Regeln kennt.
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const view = await read($, board)
    const t = await read($, now)
    const list = view === null ? [] : sorted(view.entries)
    if (list.length === 0) return <Text dimColor>Keine Chats auf dem Board.</Text>
    return (
      <Box flexDirection="column" rowGap={1}>
        {list.map(entry => (
          <Box key={entry.sessionID} flexDirection="column">
            <Text>
              <Text color={COLOR[entry.light]}>{GLYPH[entry.light]} </Text>
              <Text bold>{entry.title}</Text>
              <Text dimColor>
                {' '}
                {entry.ref} · {entry.project} · {LABEL[entry.light]} · Status {entry.status} · {age(entry.updatedAt, t, false)}
              </Text>
            </Text>
            {entry.mission !== '' && <Text>  Auftrag: {entry.mission}</Text>}
            {entry.needs !== '' && <Text color="error">  Braucht: {entry.needs}</Text>}
            {entry.next !== '' && <Text dimColor>  Weiter: {entry.next}</Text>}
            {entry.otherOwners.length > 0 && <Text dimColor>  Auch auf dem Board von {entry.otherOwners.join(', ')}</Text>}
            <Box flexDirection="row" columnGap={2}>
              <Button
                key={`ask-${entry.sessionID}`}
                label="Stand fragen"
                onPress={() => $.prompt.fill({ text: `Stand zu ${entry.title} (${entry.ref})?` })}
              />
              <Button
                key={`ws-${entry.sessionID}`}
                label="In den Workspace holen"
                onPress={() => $.prompt.fill({ text: `Hol ${entry.title} (${entry.ref}) in den Aktiv-Workspace.` })}
              />
            </Box>
          </Box>
        ))}
      </Box>
    )
  })
}
