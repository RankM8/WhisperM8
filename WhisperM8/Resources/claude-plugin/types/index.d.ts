// Vertrag der Werte, die die Mods des Plugins `whisperm8` in $.state halten.
// Nur Anzeige-Zustand: die Wahrheit des Boards liegt in der App
// (`whisperm8 chats board`).

export type BoardLight = 'needsYou' | 'running' | 'done' | 'parked'

/** Ein Eintrag, wie `whisperm8 chats board --json` ihn liefert. */
export type BoardMilestone = {
  at: string
  text: string
}

export type BoardEntry = {
  ref: string
  sessionID: string
  title: string
  project: string
  light: BoardLight
  /** Ziel: der Auftrag des Chats. */
  mission: string
  /** Eingriff: was der Chat vom User braucht (bei needsYou). */
  needs: string
  /** Arbeitspaket. Fehlt bei CLIs von vor dem Feld — dann steht es in `next`. */
  work?: string
  /** Früherer Name von `work`; die App schreibt beide gleich. */
  next: string
  /** Was den Chat aufhält, ohne dass der User gefragt ist. */
  blocker?: string
  /** Neueste zuerst. */
  milestones?: BoardMilestone[]
  updatedAt: string
  /** Laufzeitstatus des Chats (working, awaitingInput, idle, stopped …). */
  status: string
  statusSince: string | null
  otherOwners: string[]
}

export type BoardView = {
  owner: string
  ownerRef: string
  isActive: boolean
  cursor: string | null
  entries: BoardEntry[]
}

// MARK: Tasks (hooks/tasks.tsx)
// Nur Anzeige-Zustand: die Wahrheit liegt in Claude Codes Task-Dateien
// (`<config-dir>/tasks/<liste>/<id>.json`), der Modus zusätzlich in $.store.

/** Aus · Normal (aktive und offene) · Alle (auch erledigte). */
export type TaskMode = 'off' | 'normal' | 'all'

export type TaskStatus = 'pending' | 'in_progress' | 'completed'

/** Ein anklickbarer Link unter einem Task (aus `metadata.links` oder einer URL im Text). */
export type TaskLink = {
  label: string
  url: string
}

/** Ein Task, wie Claude Code ihn als `<id>.json` ablegt (nur die angezeigten Felder). */
export type TaskItem = {
  id: string
  subject: string
  description: string
  /** Tätigkeit im Verlauf („Running tests“), nur bei laufenden sinnvoll. */
  activeForm?: string
  status: TaskStatus
  /** Agent oder Teammate, der den Task übernommen hat. */
  owner?: string
  blockedBy: string[]
  links: TaskLink[]
}

declare module 'claude-code' {
  interface PluginState {
    whisperm8: {
      /** Letzter gelesener Stand des eigenen Boards; null = noch nie gelesen. */
      board: BoardView | null
      /** Band auf eine Zeile eingeklappt. */
      folded: boolean
      /** Uhr fürs Alter der Einträge, tickt im 30-s-Raster. */
      now: number
      /** Schon geweckte Zustände je Chat (`<sessionID>:<zustand>`), gegen Doppel-Wecken. */
      woken: string[]
      /** Callout-Modus der Session: Claude darf am Turn-Ende sprechen. */
      callout: boolean
      /** Anzeige-Modus der Task-Liste; über Neustarts in $.store `taskMode`. */
      taskMode: TaskMode
      /** Tasks der laufenden Session, nach ID sortiert. */
      taskItems: TaskItem[]
      /** Ordner der Task-Liste, beim ersten TaskCreate gefunden; '' = noch unbekannt. */
      taskDir: string
    }
  }
}
