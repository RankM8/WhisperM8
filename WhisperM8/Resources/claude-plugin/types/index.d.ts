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
// Nur für den Zähler: die Wahrheit liegt in Claude Codes Task-Dateien
// (`<config-dir>/tasks/<liste>/<id>.json`).

export type TaskStatus = 'pending' | 'in_progress' | 'completed'

/** Ein Task, wie Claude Code ihn als `<id>.json` ablegt (nur die gelesenen Felder). */
export type TaskItem = {
  id: string
  subject: string
  status: TaskStatus
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
      /** Tasks der laufenden Session, nach ID sortiert. */
      taskItems: TaskItem[]
      /** Ordner der Task-Liste, beim ersten TaskCreate gefunden; '' = noch unbekannt. */
      taskDir: string
    }
  }
}
