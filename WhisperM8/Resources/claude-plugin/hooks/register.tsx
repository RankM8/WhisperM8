import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { BoardEntry, BoardView } from '../types'
import { registerTasks, startTasks } from './tasks'

// Jarvis-Board: Übersicht der Chats, die Jarvis aktiv betreut, als Band über
// dem Prompt. Die Wahrheit liegt in der App (`whisperm8 chats board`), die Mod
// zeigt nur an, hört per `chats watch` auf Änderungen und weckt Jarvis.
// Plan und Messwerte: docs/plans/whisperm8-plugin.md (Prototyp 08.10.2026).
//
// Ausgeschaltet (kein aktives Board dieser Session) zeichnet die Mod nichts und
// startet keinen Prozess; das Tool steht dann nur hinter ToolSearch.
//
// Zweiter Teil (MARK: Voice-Callouts): Claude spricht am Turn-Ende eine kurze
// Ansage über die App (`whisperm8 speak`). Eigentlich als callout.tsx geplant,
// aber die Engine folgt `$` und `on` nie über einen Import und erlaubt je
// Plugin nur einen `session.start` ohne Matcher — deshalb in dieser Datei.

const board = atom({ plugin: 'whisperm8', key: 'board' } as const, null as BoardView | null)
const folded = atom({ plugin: 'whisperm8', key: 'folded' } as const, false)
const woken = atom({ plugin: 'whisperm8', key: 'woken' } as const, [] as string[])
const callout = atom({ plugin: 'whisperm8', key: 'callout' } as const, false)

const TOOL = 'mcp__whisperm8__board'
const JARVIS_SKILL = 'whisperm8:jarvis'
const SPEAK_TOOL = 'mcp__whisperm8__speak'
const CALLOUT_SKILL = 'whisperm8:callout'
const CLIPBOARD_TOOL = 'mcp__whisperm8__clipboard'
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
/**
 * Jüngster Cursor aus `chats board --json`. Steht bewusst nicht im Atom
 * `board`: Er ändert sich mit jedem Statuswechsel irgendeines Chats, und jede
 * Änderung am Atom zeichnet das Band neu (WM8-87).
 */
let latestCursor: string | null = null
/** Zeitpunkt des letzten vollständigen Lesens (für das seltene Nachlesen von Titeln). */
let lastRefreshAt = 0
/** Statuswechsel lesen Titel, Projekt und Mitbesitzer höchstens so oft nach. */
const SLOW_REFRESH_MS = 5 * MIN
let toolDeferred: boolean | null = null
let speakToolDeferred: boolean | null = null
let clipboardToolDeferred: boolean | null = null
let wakeQueue: string[] = []
let wakeTimerArmed = false
let lastWakeAt = 0


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
  if (!ran.ok) {
    // Kein geprüfter Besitzer (Hintergrund-Agent ohne eigenen Chat): kein
    // Board, auch nicht das des Chats, dessen Umgebung geerbt wurde.
    if (ran.message.includes('@self')) {
      sessionID = null
      stopWatch()
      await update($, board, () => null)
    }
    return
  }
  const next = parseBoard(ran.stdout)
  if (next === null) return
  // Die CLI prüft die Identität gegen Claudes Registry: Ein Hintergrund-Agent
  // erbt die Umgebung des Chats, der den Daemon gestartet hat. Ihr Besitzer
  // gilt, nicht WHISPERM8_SESSION_ID (Befund 11.11.2026).
  if (sessionID !== null && !sameID(next.owner, sessionID)) sessionID = next.owner
  latestCursor = next.cursor
  lastRefreshAt = await $.clock.now()
  // Nur schreiben, was sich geändert hat: jedes Schreiben zeichnet den
  // Kasten neu (WM8-87).
  if (!sameBoard(await read($, board), next)) await update($, board, () => next)
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

/** Generation eines Cursors `<generation>:<seq>`. */
const generationOf = (cursor: string | null) => (cursor === null ? null : cursor.slice(0, Math.max(0, cursor.lastIndexOf(':'))))

/**
 * Ansatz nach einer Lücke: Ist die Generation gewechselt, ab ihrem Anfang
 * (`<neu>:0`), sonst ab dem frisch gelesenen Stand.
 */
export const nextGenerationStart = (previous: string | null, fresh: string | null): string | null => {
  const gen = generationOf(fresh)
  if (gen === null || gen === '' || gen === generationOf(previous)) return fresh
  return `${gen}:0`
}

/** Gleiches Board ohne den Cursor (der zählt nur für `chats watch`). */
export const sameBoard = (a: BoardView | null, b: BoardView | null) =>
  a !== null && b !== null && JSON.stringify({ ...a, cursor: null }) === JSON.stringify({ ...b, cursor: null })

/** Liegt `at` vor `since`? Fehlt eines, nein. */
export const isBefore = (at: string | undefined, since: string | null | undefined) => {
  if (!at || !since) return false
  const a = Date.parse(at)
  const b = Date.parse(since)
  return !Number.isNaN(a) && !Number.isNaN(b) && a < b
}

/** Statuswechsel aus `chats watch` direkt ins Board, ohne neuen Prozess. */
export const withStatus = (view: BoardView, sessionID: string, status: string, since: string | null) => ({
  ...view,
  entries: view.entries.map(e => (sameID(e.sessionID, sessionID) ? { ...e, status, statusSince: since ?? e.statusSince } : e)),
})


/** Aktiv: Schema ab Turn 1 in der Liste. Sonst nur der Name (ToolSearch). */
const syncTool = async ($: EngineInterface, active: boolean) => {
  const deferred = !active
  if (toolDeferred === deferred) return
  toolDeferred = null
  await $.tool.register({
    name: 'board',
    description:
      'Jarvis-Board pflegen: die Chats, die du gerade aktiv betreust. Die App zeigt daraus auch die Notiz-Karte am Kachelkopf. set: Ampel (needsYou | running | done | parked), mission (Ziel), work (Arbeitspaket), needs (Eingriff des Users), blocker. milestone: ein erreichtes Ergebnis anhängen (text). Nur bei echten Änderungen schreiben, nie Einzelschritte. action: set | milestone | remove | clear | activate | deactivate | read. ref = Kurz-Ref des Chats wie in whisperm8 chats list.',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['set', 'milestone', 'remove', 'clear', 'activate', 'deactivate', 'read'] },
        ref: { type: 'string', description: 'Chat-Ref (für set, milestone und remove)' },
        light: { type: 'string', enum: ['needsYou', 'running', 'done', 'parked'] },
        mission: { type: 'string', description: 'Ziel: der Auftrag des Chats in einem Satz' },
        work: {
          type: 'string',
          description: 'Arbeitspaket: woran der Chat arbeitet, ein Ergebnis für die nächsten 30 min bis wenige Stunden — kein Einzelschritt',
        },
        needs: { type: 'string', description: 'Eingriff: Frage oder Entscheidung an den User (bei needsYou), sonst leer' },
        blocker: { type: 'string', description: 'Was den Chat aufhält, ohne dass der User gefragt ist; leer = keine' },
        text: { type: 'string', description: 'Meilenstein (milestone): Commit, Tests grün, Entscheidung gefallen, übergeben' },
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
  at?: string
  cursor?: string | null
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
    /** Wo der nächste Strom ansetzt: nach dem zuletzt gelieferten Ereignis. */
    let resume: string | null = null
    let sawGap = false
    while (generation === watchGeneration && !sessionEnded) {
      const cursor = resume ?? latestCursor ?? (await read($, board))?.cursor ?? null
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
              const ev = JSON.parse(line) as WatchEvent
              if (ev.gap === true || ev.event === 'gap') sawGap = true
              else if (typeof ev.cursor === 'string') resume = ev.cursor
              await handleEvent($, ev)
              // Nur ein echtes Ereignis setzt die Wartezeit zurück, nicht
              // „started“ oder „gap“: Sonst startet ein sofort endender
              // Strom alle zwei Sekunden neu (WM8-87).
              if (ev.event === undefined && ev.gap !== true) delay = 2_000
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
      // Frischer Stand samt Cursor, bevor der nächste Strom ansetzt. Das ist
      // das einzige Lesen je Runde; eine Lücke liest nicht zusätzlich.
      await refresh($).catch(() => undefined)
      // Nach einer Lücke ab dem Anfang der neuen Generation, damit kein
      // Weck-Grund aus der Wartezeit verloren geht; ältere Ereignisse als der
      // frisch gelesene Stand fallen in handleEvent weg. Ohne Lücke weiter
      // ab dem letzten gelieferten Ereignis.
      if (sawGap) {
        sawGap = false
        resume = nextGenerationStart(resume, latestCursor)
      }
    }
  })()
    .catch(() => undefined)
    .finally(() => {
      if (generation === watchGeneration) watchRunning = false
    })
}

const handleEvent = async ($: EngineInterface, ev: WatchEvent) => {
  // Nach einer Lücke endet `chats watch`; die Schleife liest dann einmal neu.
  if (ev.gap === true || ev.event !== undefined) return
  if (ev.kind === 'board') {
    // Nur eine Änderung am eigenen Board liest das Board ganz neu.
    if (sameID(ev.owner, sessionID ?? undefined)) scheduleRefresh($)
    return
  }
  const view = await read($, board)
  const entry = view?.entries.find(e => sameID(e.sessionID, ev.sessionID))
  if (view === null || entry === undefined || ev.sessionID === undefined) return
  // Älter als der gelesene Stand (nach einer Lücke nachgeliefert): weder
  // anzeigen noch wecken.
  if (isBefore(ev.at, entry.statusSince)) return
  // Titel, Projekt und Mitbesitzer ändern sich selten; sie liest ein
  // Statuswechsel höchstens alle fünf Minuten mit nach.
  if ((await $.clock.now()) - lastRefreshAt > SLOW_REFRESH_MS) scheduleRefresh($)
  // Statuswechsel eines Board-Chats: direkt in die Anzeige, ohne Prozess.
  if (typeof ev.to === 'string' && ev.to !== entry.status) {
    const to = ev.to
    const sid = ev.sessionID
    await update($, board, current => (current === null ? current : withStatus(current, sid, to, ev.at ?? null)))
  }
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
  // Der Titel stammt aus einem fremden Chat (ai-title, erster Prompt) — als Daten
  // gekennzeichnet und ohne Steuerzeichen, nie als Anweisung lesbar (LR-PJ-004).
  wakeQueue.push(`[Board] „${asData(entry.title)}“ (${asData(entry.ref)}): ${reason}`)
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
  if (wakeMode !== 'turn') return
  await $.prompt.submit({ text: `${lines.join('\n')}\nStand prüfen und das Board nachführen.` })
}

// MARK: Anzeige

/** Arbeitspaket; CLIs von vor dem Feld liefern es nur unter `next`. */
const workOf = (e: BoardEntry) => e.work || e.next

/** Beim Warten das Anliegen, sonst Blockade oder Arbeitspaket (Rückfall: Auftrag). */
export const say = (e: BoardEntry) => {
  const work = workOf(e) || e.mission
  if (e.light === 'needsYou') return e.needs || work
  if (e.light === 'done') return work ? `fertig · ${work}` : 'fertig'
  if (e.blocker) return `hängt · ${e.blocker}`
  return work
}

/** Rufname, Ticket und Thema aus dem Chat-Titel („WM8-65 Kai · Umzug DealSupply“). */
export type TitleParts = { name: string; ticket: string | null; topic: string }

/**
 * Bekannte Ticket-Schlüssel (Linear WM8, DealSupply und Akquise). Nur diese
 * gelten als Ticket, sonst läse „GPT-5 Router · Fix“ sich als Ticket GPT-5.
 */
const TICKET = /^((?:WM8|DS|DEAL|DEA|AKQ|PRB|LISTM8)-\d+)\s+/
const NAME_WIDTH = 24

/**
 * Titel der Form „<Ticket> <Rufname> · <Thema>“, Ticket optional. Ohne
 * Trennpunkt ist der ganze Titel der Name, ohne Thema. Namen sind gekürzt;
 * ein leerer Name fällt auf `fallback` (die Kurz-Kennung) zurück.
 */
export const titleParts = (title: string, fallback = '?'): TitleParts => {
  let rest = clean(title)
  let ticket: string | null = null
  const match = TICKET.exec(rest)
  if (match) {
    ticket = match[1]!
    rest = rest.slice(match[0].length).trim()
  }
  const split = /^(.*?)\s*·\s+(.*)$/.exec(rest)
  const name = (split ? split[1]! : rest).trim()
  const topic = split ? split[2]!.trim() : ''
  return { name: clip(name || fallback, NAME_WIDTH), ticket, topic }
}

/** Steuerzeichen (C0, DEL, C1) zu Leerzeichen, Weißraum zusammengezogen, eine Zeile. */
export const clean = (text: string) =>
  String(text ?? '').replace(/[\u0000-\u001f\u007f-\u009f]+/g, ' ').replace(/\s+/g, ' ').trim()

/** Zeilen, die `text` bei Wortumbruch in `width` Spalten braucht (mindestens 1). */
export const wrapRows = (text: string, width: number) => wrapLines(text, width).length

/** Wortumbruch wie im Terminal; überlange Wörter werden hart geteilt. */
const wrapLines = (text: string, width: number): string[] => {
  const w = Math.max(1, width)
  const lines: string[] = []
  let line = ''
  for (const word of clean(text).split(' ')) {
    let rest = word
    while (rest.length > w) {
      if (line !== '') {
        lines.push(line)
        line = ''
      }
      lines.push(rest.slice(0, w))
      rest = rest.slice(w)
    }
    if (rest === '') continue
    if (line === '') line = rest
    else if (line.length + 1 + rest.length <= w) line = `${line} ${rest}`
    else {
      lines.push(line)
      line = rest
    }
  }
  if (line !== '' || lines.length === 0) lines.push(line)
  return lines
}

/** `text` auf höchstens `rows` umbrochene Zeilen gekürzt, mit „…“ am Ende. */
export const clipToRows = (text: string, width: number, rows: number) => {
  const lines = wrapLines(text, width)
  if (lines.length <= rows) return clean(text)
  const kept = lines.slice(0, Math.max(1, rows))
  const last = kept[kept.length - 1]!
  kept[kept.length - 1] = last.length >= width ? `${last.slice(0, Math.max(0, width - 1))}…` : `${last}…`
  return kept.join(' ')
}

/** Ein Wartender im Kasten: Eintrag und der Satz, wie er gezeigt wird. */
export type WaitingRow = { entry: BoardEntry; sentence: string }

/**
 * Welche Wartenden in `maxRows` Zeilen passen. Je Wartendem: Abstand,
 * Kopfzeile und der umbrochene Satz. `fixed` = Zeilen außerhalb (Kopf,
 * Abstand, Sammelzeilen). Der erste Wartende steht immer da, sein Satz wird
 * notfalls gekürzt; wer danach nicht mehr passt, zählt in `hidden`.
 */
export const layoutWaiting = (waiting: readonly BoardEntry[], cols: number, maxRows: number, fixed: number) => {
  const textWidth = Math.max(10, cols - 2)
  let budget = Math.max(0, maxRows - fixed)
  const rows: WaitingRow[] = []
  for (const entry of waiting) {
    const sentence = clean(say(entry))
    const need = 2 + wrapRows(sentence, textWidth)
    if (need <= budget) {
      rows.push({ entry, sentence })
      budget -= need
      continue
    }
    if (rows.length === 0) {
      // Der Erste immer, notfalls mit gekürztem Satz.
      const room = Math.max(1, budget - 2)
      rows.push({ entry, sentence: clipToRows(sentence, textWidth, room) })
      budget = 0
    }
    break
  }
  return { rows, hidden: waiting.length - rows.length, textWidth }
}

/** Fortschritt „4/7“, sobald die Quelle ihn liefert; bis dahin nichts. */
export const progressOf = (e: BoardEntry) => {
  const p = e.progress
  if (!p || !Number.isFinite(p.done) || !Number.isFinite(p.total) || p.total <= 0) return ''
  return `${Math.max(0, Math.floor(p.done))}/${Math.floor(p.total)}`
}

/**
 * Namen hintereinander („Gus 4/7 · Jon · Noa“), so viele wie in `room`
 * Spalten passen; der Rest als „+n“. Eine Zeile, damit der Kasten niedrig
 * bleibt.
 */
export const fitNames = (names: readonly string[], room: number) => {
  let line = ''
  for (let i = 0; i < names.length; i++) {
    const next = line === '' ? names[i]! : `${line} · ${names[i]}`
    const rest = names.length - i - 1
    const tail = rest > 0 ? ` +${rest}` : ''
    if (next.length + tail.length > room) {
      const left = names.length - i
      // Schon der erste Name passt nicht: gekürzt statt verschwunden.
      if (line === '') {
        const more = rest > 0 ? ` +${rest}` : ''
        return `${clip(names[i]!, Math.max(1, room - more.length))}${more}`
      }
      return `${line} +${left}`
    }
    line = next
  }
  return line
}

/** Wer wartet (Ampel needsYou), wer läuft, wer ruht (fertig oder geparkt). */
export const groups = (entries: readonly BoardEntry[]) => {
  const byAge = [...entries].sort((a, b) => Date.parse(a.updatedAt) - Date.parse(b.updatedAt))
  return {
    waiting: byAge.filter(e => e.light === 'needsYou'),
    running: byAge.filter(e => e.light === 'running'),
    // Fertige zuerst: sie warten auf Abnahme, Geparkte nicht.
    resting: [...byAge.filter(e => e.light === 'done'), ...byAge.filter(e => e.light === 'parked')],
  }
}

/** Name in einer Sammelzeile: ⚑ bei Rückfrage im Chat, ✓ bei fertig (Abnahme offen), dazu der Fortschritt. */
export const shortName = (e: BoardEntry) => {
  const flag = e.status === 'awaitingInput' ? '⚑ ' : e.light === 'done' ? '✓ ' : ''
  const progress = progressOf(e)
  return `${flag}${titleParts(e.title, e.ref).name}${progress ? ` ${progress}` : ''}`
}

/** „1 läuft“ / „2 laufen“, „1 ruht“ / „2 ruhen“ für die eingeklappte Zeile. */
export const countWord = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`

/** Kopf: „Jarvis · 1 wartet auf dich“ bzw. „2 warten auf dich“. */
export const waitingHead = (count: number) => (count === 1 ? '1 wartet auf dich' : `${count} warten auf dich`)

// Steuerzeichen (C0, DEL, C1) und Anführungszeichen raus, auf eine Zeile, gekürzt.
const asData = (text: string) => clip(String(text ?? '').replace(/[\u0000-\u001f\u007f-\u009f]+/g, ' ').replace(/[„“"]/g, "'").trim(), 120)

const clip = (text: string, width: number) => (text.length > width ? `${text.slice(0, Math.max(0, width - 1))}…` : text)

// MARK: Voice-Callouts

/** Bei aktivem Modus steht `speak` direkt in der Liste, sonst hinter ToolSearch. */
const syncSpeakTool = async ($: EngineInterface, active: boolean) => {
  const deferred = !active
  if (speakToolDeferred === deferred) return
  speakToolDeferred = null
  await $.tool.register({
    name: 'speak',
    description:
      'Kurze gesprochene Ansage an den User am Ende des Turns (Skill whisperm8:callout): nur wenn der Turn auf ihn wartet, eine längere Aufgabe fertig ist oder du festhängst. text = höchstens zwei Sätze Deutsch, ohne Pfade, Code, IDs oder Markdown; den Namen des Chats stellt die App voran.',
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'Höchstens zwei kurze Sätze, gesprochene Sprache' },
      },
      required: ['text'],
    },
    isDeferred: deferred,
  })
  speakToolDeferred = deferred
}

const setCallout = async ($: EngineInterface, active: boolean) => {
  await update($, callout, () => active)
  await syncSpeakTool($, active).catch(() => undefined)
}

/** Skill geladen: Modus an, Hinweis für das Modell an den Skill-Text. */
const calloutOnSkill = async ($: EngineInterface, text: string): Promise<string> => {
  if (sessionID === null) return text
  await setCallout($, true)
  return `${text}\n\n[whisperm8] Ansagen sind in dieser Session an: am Turn-Ende bei Bedarf ${SPEAK_TOOL} (Regeln im Skill ${CALLOUT_SKILL}). /callout aus schaltet sie ab.`
}

type SpeakReply = { status?: string }

/** Die App antwortet, sobald die Ansage in der Warteschlange steht: der Turn blockiert nicht. */
const speak = async ($: EngineInterface, text: string): Promise<string> => {
  const ran = await cli($, ['speak', text], 10_000)
  if (!ran.ok) return `FEHLER: ${ran.message}`
  let reply: SpeakReply = {}
  try {
    reply = JSON.parse(ran.stdout) as SpeakReply
  } catch {
    // Ohne lesbare Antwort gilt die Ansage als angenommen (Exit 0).
  }
  switch (reply.status) {
    case 'muted':
      $.ui.toast('🔇 stumm, nicht vorgelesen')
      return 'muted: Der User hat Ansagen stumm geschaltet. Nicht erneut versuchen.'
    case 'debounced':
      return 'debounced: Dieser Chat hat eben erst gesprochen. Nicht erneut versuchen.'
    default:
      $.ui.toast('🔊 vorgelesen')
      return `${reply.status ?? 'queued'}: wird vorgelesen.`
  }
}

// MARK: Zwischenablage-Verlauf

/**
 * Tool `clipboard`: liest den Zwischenablage-Verlauf des Users über
 * `whisperm8 clipboard`. Ist der Verlauf an und für Agents freigegeben, steht
 * das Tool direkt in der Liste (sonst übersieht Claude es bei „der Fehler, den
 * ich kopiert habe“); andernfalls nur hinter ToolSearch, ohne Kontext zu kosten.
 */
const syncClipboardTool = async ($: EngineInterface, active: boolean) => {
  const deferred = !active
  if (clipboardToolDeferred === deferred) return
  clipboardToolDeferred = null
  await $.tool.register({
    name: 'clipboard',
    description:
      'Clipboard history of the user (Zwischenablage-Verlauf, WhisperM8 replaces Maccy). Use it whenever the user refers to something they copied instead of asking them to paste it: "what I copied", "the error I copied earlier", "from my clipboard", "the link from before", "the screenshot I copied", "was ich kopiert habe", "aus der Zwischenablage", "den Fehler von vorhin", "der Link von eben". action: list (newest first, number 1 = newest), search (query: words, case-insensitive, searches full text), get (nr = ID or number; text in chunks of 50000 chars, continue with from; images return an absolute PNG path to open with Read, files return paths). Numbers shift as soon as something new is copied or dictated: for follow-up calls pass the id from list/search; use a number only when the user names one. Finished dictations are in the history too (dictationMode); for "what I dictated/said earlier" use search or list. If hasOriginal is true, get with original: true returns the raw transcript, what the user actually said before the mode rewrote it. Quick actions (e.g. ⇧⌘K Correct on selected text) are not dictations: they carry quickActionMode, and their original is the selected text before the rework. Typical secrets are masked as [REDACTED:…]; do not try to work around that. If the history is off or agent access is blocked, tell the user: WhisperM8 Settings > Clipboard.',
    inputSchema: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: ['list', 'search', 'get'], description: 'list | search | get' },
        query: { type: 'string', description: 'Search words (search)' },
        nr: { type: 'string', description: 'ID from list/search (preferred) or number (1 = newest; shifts with every new copy, only when the user names it) (get)' },
        limit: { type: 'number', description: 'Max entries (list and search, default 20)' },
        from: { type: 'number', description: 'Character offset for long texts (get, default 0; use nextFrom from the previous answer)' },
        maxChars: { type: 'number', description: 'Max characters per answer (get, default 50000)' },
        original: { type: 'boolean', description: 'Raw transcript of a rewritten dictation, or the text before a quick action, instead of the result (get, only when hasOriginal)' },
      },
      required: ['action'],
    },
    isDeferred: deferred,
  })
  clipboardToolDeferred = deferred
}

type ClipboardStatus = { enabled?: boolean; agentAccess?: boolean }

/** Nach dem Start: Schalter lesen und das Tool bei freigegebenem Verlauf nach vorn holen. */
const refreshClipboardTool = async ($: EngineInterface) => {
  const ran = await cli($, ['clipboard', 'status', '--json'], 10_000)
  if (!ran.ok) return
  let status: ClipboardStatus = {}
  try {
    status = JSON.parse(ran.stdout) as ClipboardStatus
  } catch {
    return
  }
  await syncClipboardTool($, status.enabled === true && status.agentAccess === true)
}

type ClipboardInput = {
  action?: string
  query?: string
  nr?: string | number
  limit?: number
  from?: number
  maxChars?: number
  original?: boolean
}

const wholeNumber = (value: unknown, min: number): string | null =>
  typeof value === 'number' && Number.isFinite(value) && value >= min ? String(Math.floor(value)) : null

/** Baut die CLI-Argumente; bei unvollständiger Eingabe steht die Meldung in `error`. */
const clipboardArgs = (input: ClipboardInput): { args: string[] } | { error: string } => {
  const action = input.action ?? 'list'
  const limitValue = wholeNumber(input.limit, 1)
  const limit = limitValue === null ? [] : ['--limit', limitValue]
  switch (action) {
    case 'list':
      return { args: ['clipboard', 'list', ...limit, '--json'] }
    case 'search': {
      const query = (input.query ?? '').trim()
      if (query === '') return { error: 'FEHLER: search braucht query.' }
      return { args: ['clipboard', 'search', ...limit, '--json', '--', query] }
    }
    case 'get': {
      const nr = String(input.nr ?? '').trim()
      if (nr === '') return { error: 'FEHLER: get braucht nr (Nummer oder ID).' }
      const from = wholeNumber(input.from, 0)
      const maxChars = wholeNumber(input.maxChars, 1)
      return {
        args: [
          'clipboard', 'get', '--json',
          ...(input.original === true ? ['--original'] : []),
          ...(from === null ? [] : ['--from', from]),
          ...(maxChars === null ? [] : ['--max-chars', maxChars]),
          '--', nr,
        ],
      }
    }
    default:
      return { error: `FEHLER: unbekannte action ${action}. list | search | get` }
  }
}

// MARK: Hooks

export const register: Register = (on, options) => {
  wakeMode = typeof options.wecken === 'string' ? options.wecken : 'turn'
  // Task-Zähler und Link-Hinweis (tasks.tsx).
  registerTasks(on, options)

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    sessionEnded = false
    sessionID = (await $.env.get('WHISPERM8_SESSION_ID')) ?? null
    // Der Task-Zähler gilt in jeder Session, auch außerhalb von WhisperM8.
    await startTasks($).catch(() => undefined)
    // Außerhalb eines WhisperM8-Chats gibt es weder Board noch Ansagen.
    if (sessionID === null) return started
    try {
      await $.command.register({ name: 'board', description: 'Jarvis-Board ein-/ausklappen; an | aus | zu | auf' })
      await $.command.register({ name: 'callout', description: 'Gesprochene Ansagen am Turn-Ende: an | aus' })
    } catch {
      // Ohne Befehl bleiben Band und Tool.
    }
    // Callout-Modus nach Neustart oder Reload: er steht in $.state und bleibt.
    await syncSpeakTool($, await read($, callout)).catch(() => undefined)
    try {
      await syncTool($, false)
    } catch {
      // Ohne Tool pflegt Jarvis das Board per CLI.
    }
    // Zwischenablage-Verlauf: Lesetool erst hinter ToolSearch; ist der
    // Verlauf freigegeben, holt der Status-Abruf es nach vorn (nicht awaiten,
    // der CLI-Prozess soll den Chatstart nicht bremsen).
    await syncClipboardTool($, false).catch(() => undefined)
    void refreshClipboardTool($).catch(() => undefined)
    // Nach Neustart oder Reload: ein aktives Board ist sofort wieder da.
    // Nicht awaiten: das Lesen startet einen CLI-Prozess (App-Binary im
    // CLI-Modus), der den Chatstart sonst bremst — das Band erscheint, sobald
    // die Antwort da ist (Atom-Update).
    void refresh($).catch(() => undefined)
    return started
  })

  on('session.end', async ($, e, next) => {
    sessionEnded = true
    stopWatch()
    return next(e)
  })

  // Jarvis startet: Board einschalten, unabhängig davon, ob das Modell daran denkt.
  // Jarvis spricht außerdem immer: Callout-Modus mit an.
  on('skill.prompt', { skill: JARVIS_SKILL }, async ($, e, next) => {
    const result = await next(e)
    if (sessionID === null) return result
    const text = await calloutOnSkill($, result.text).catch(() => result.text)
    const ran = await cli($, ['chats', 'board', 'activate', '--json'])
    if (!ran.ok) return { text }
    await refresh($).catch(() => undefined)
    return {
      text: `${text}\n\n[whisperm8] Das Jarvis-Board dieser Session ist aktiv. Pflege es mit dem Tool ${TOOL} (oder whisperm8 chats board …).`,
    }
  })

  on('skill.prompt', { skill: CALLOUT_SKILL }, async ($, e, next) => {
    const result = await next(e)
    return { text: await calloutOnSkill($, result.text) }
  })

  on('tool.call', { tool: SPEAK_TOOL }, async ($, e) => {
    const input = e as unknown as { text?: string }
    if (!(await read($, callout))) return { result: 'aus: Ansagen sind in dieser Session aus (/callout an).' }
    const text = (input.text ?? '').trim()
    if (text === '') return { result: 'FEHLER: text fehlt.' }
    return { result: await speak($, text) }
  })

  on('tool.call', { tool: CLIPBOARD_TOOL }, async ($, e) => {
    const built = clipboardArgs(e as unknown as ClipboardInput)
    if ('error' in built) return { result: built.error }
    const ran = await cli($, built.args)
    return { result: ran.ok ? ran.stdout.trim() || '[]' : `FEHLER: ${ran.message}` }
  })

  on('command.run', { command: 'callout' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'an' || arg === 'aus') {
      await setCallout($, arg === 'an')
      return { text: arg === 'an' ? 'Ansagen an.' : 'Ansagen aus.' }
    }
    return { text: `Ansagen sind ${(await read($, callout)) ? 'an' : 'aus'}. /callout an | aus` }
  })

  on('tool.call', { tool: TOOL }, async ($, e) => {
    const input = e as unknown as {
      action?: string
      ref?: string
      light?: string
      mission?: string
      work?: string
      next?: string
      needs?: string
      blocker?: string
      text?: string
    }
    const action = input.action ?? 'read'
    let args: string[]
    switch (action) {
      case 'set': {
        if (!input.ref) return { result: 'FEHLER: set braucht ref.' }
        args = ['chats', 'board', 'set', input.ref]
        if (input.light) args.push('--light', input.light)
        if (input.mission !== undefined) args.push('--mission', input.mission)
        // `next` ist der frühere Name von `work` (ältere Jarvis-Turns).
        const work = input.work ?? input.next
        if (work !== undefined) args.push('--work', work)
        if (input.needs !== undefined) args.push('--needs', input.needs)
        if (input.blocker !== undefined) args.push('--blocker', input.blocker)
        break
      }
      case 'milestone':
        if (!input.ref || !input.text?.trim()) return { result: 'FEHLER: milestone braucht ref und text.' }
        args = ['chats', 'board', 'milestone', input.ref, input.text]
        break
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

  // Kein Detail-Panel: In App-Sessions setzt Claude ein Pane als zweiten Kasten
  // über das Band, die Chats stehen dann doppelt da. Details zeigt die
  // Notiz-Karte am Kachelkopf.
  on('command.run', { command: 'board' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === '' || arg === 'zu' || arg === 'auf') {
      const fold = arg === '' ? !(await read($, folded)) : arg === 'zu'
      await update($, folded, () => fold)
      return { text: fold ? 'Board eingeklappt.' : 'Board ausgeklappt.' }
    }
    if (arg === 'an' || arg === 'aus') {
      const ran = await cli($, ['chats', 'board', arg === 'an' ? 'activate' : 'deactivate', '--json'])
      await refresh($).catch(() => undefined)
      if (!ran.ok) return { text: `Board nicht umgeschaltet: ${ran.message}` }
      return { text: arg === 'an' ? 'Board an.' : 'Board aus.' }
    }
    return { text: 'Unbekannt. /board klappt das Band ein und aus, dazu gibt es an, aus, zu und auf.' }
  })

  // WM8-88: oben, was den User braucht (Rufname, Ticket, ganzer Satz mit
  // Umbruch), darunter je eine Sammelzeile für laufende und ruhende Chats.
  // Keine Ziffern zum Springen, keine Kennung, kein Alter: niedrig und
  // selten geändert, weil der Hauptbildschirm den Bereich bei jeder Änderung
  // neu zeichnet.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const view = await read($, board)
    if (view === null || !view.isActive || view.entries.length === 0) return next(e)
    const isFolded = await read($, folded)
    const { Box, Text } = $.ui.resolve(e)
    const cols = e.props.bodyColumns
    const { waiting, running, resting } = groups(view.entries)

    if (isFolded) {
      const parts = [
        waiting.length > 0 ? waitingHead(waiting.length) : '',
        running.length > 0 ? countWord(running.length, 'läuft', 'laufen') : '',
        resting.length > 0 ? countWord(resting.length, 'ruht', 'ruhen') : '',
      ].filter(Boolean)
      return (
        <Box flexDirection="row" width={cols}>
          <Text color="claude" bold>
            ▸ Jarvis
          </Text>
          <Text color={waiting.length > 0 ? 'error' : undefined} dimColor={waiting.length === 0} wrap="truncate-end">
            {' · '}
            {parts.join(' · ')}
          </Text>
        </Box>
      )
    }

    const LABEL_WIDTH = 7
    const room = Math.max(10, cols - LABEL_WIDTH)
    const summary = (label: string, entries: readonly BoardEntry[]) =>
      entries.length === 0 ? null : (
        <Box key={label} flexDirection="row" width={cols}>
          <Box width={LABEL_WIDTH} flexShrink={0}>
            <Text dimColor>{label}</Text>
          </Box>
          <Text dimColor wrap="truncate-end">
            {fitNames(entries.map(shortName), room)}
          </Text>
        </Box>
      )

    // Höhe begrenzen: Kopf, Abstand vor den Sammelzeilen, Sammelzeilen; der
    // Rest gehört den Wartenden. Was nicht passt, zählt der Kopf mit.
    const summaries = (running.length > 0 ? 1 : 0) + (resting.length > 0 ? 1 : 0)
    const fixed = waiting.length > 0 ? 1 + (summaries > 0 ? 1 + summaries : 0) : summaries
    const { rows: shown, hidden } = layoutWaiting(waiting, cols, e.props.maxRows, fixed)

    return (
      <Box flexDirection="column" width={cols}>
        {waiting.length > 0 && (
          <Box flexDirection="row">
            <Text color="claude" bold>
              Jarvis
            </Text>
            <Text color="error" bold>
              {' · '}
              {waitingHead(waiting.length)}
            </Text>
            {hidden > 0 && <Text dimColor>{`  (+${hidden} nicht gezeigt)`}</Text>}
          </Box>
        )}
        {shown.map(({ entry, sentence }) => {
          const t = titleParts(entry.title, entry.ref)
          return (
            <Box key={entry.sessionID} flexDirection="column" marginTop={1}>
              <Box flexDirection="row">
                <Text color="error">● </Text>
                <Text bold>{t.name}</Text>
                {t.ticket !== null && <Text dimColor>{` · ${t.ticket}`}</Text>}
                {t.topic !== '' && (
                  <Text dimColor wrap="truncate-end">
                    {'  '}
                    {t.topic}
                  </Text>
                )}
              </Box>
              <Box paddingLeft={2} width={cols}>
                <Text wrap="wrap">{sentence}</Text>
              </Box>
            </Box>
          )
        })}
        {waiting.length > 0 && (running.length > 0 || resting.length > 0) && <Box height={1} />}
        {summary('läuft', running)}
        {summary('ruht', resting)}
      </Box>
    )
  })
}
