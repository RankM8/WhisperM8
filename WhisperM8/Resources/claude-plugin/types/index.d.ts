// Vertrag der Werte, die die Mods des Plugins `whisperm8` in $.state halten.
// Nur Anzeige-Zustand: die Wahrheit des Boards liegt in der App
// (`whisperm8 chats board`).

export type BoardLight = 'needsYou' | 'running' | 'done' | 'parked'

/** Ein Eintrag, wie `whisperm8 chats board --json` ihn liefert. */
export type BoardEntry = {
  ref: string
  sessionID: string
  title: string
  project: string
  light: BoardLight
  mission: string
  needs: string
  next: string
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
    }
  }
}
