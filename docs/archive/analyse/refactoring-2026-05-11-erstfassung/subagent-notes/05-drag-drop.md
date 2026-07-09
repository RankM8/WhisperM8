# Subagent 05 - Drag-and-Drop und macOS-UX

## Kurzbefund

Die Drag-and-Drop-Basis ist solide: kleine `Transferable`-Payloads, eigene UTTypes, `Info.plist`-Export und LaunchServices-Registrierung in `make dev`. Die fragilen Punkte liegen in Self-Drops, sichtbarer vs. persistierter Sortierung und doppelten UTI-Strings.

## Befunde

- `WhisperM8/Views/AgentChatsView.swift:973`: Self-drop einer Session ist nicht abgefangen. Drop auf dieselbe Row entfernt erst die ID und haengt sie danach ans Ende.
- `WhisperM8/Views/AgentChatsView.swift:970` vs. `1147`: UI zeigt nur manuell erstellte/offene Sessions, Drop-Logik sortiert aber alle nicht archivierten Sessions.
- `WhisperM8/Views/AgentChatsView.swift:1748`: Sidebar nutzt `sessions.prefix(20)`; DnD ist fuer aeltere/ausgeblendete Sessions nicht erreichbar, Drop ans Ende meint aber Ende der gesamten Liste.
- `WhisperM8/Views/AgentDragDropTypes.swift:37` und `WhisperM8/Info.plist:38`: UTI-Strings sind doppelt gepflegt.
- `Makefile:68`: `lsregister -f` laeuft bei `make dev`, aber nicht bei `make install` oder `make run`.
- `WhisperM8/Services/AgentSessionStore.swift:213`: Store ignoriert unbekannte IDs still; UI-Drop kann trotzdem `true` melden.

## No-Breaking Refactors

- Self-drop in `dropSession` als No-op guard.
- Zentrale UTI-Konstanten plus Test gegen `Info.plist`.
- Drop-Ordering als pure Helper (`makeSessionOrder`, `makeProjectOrder`) extrahieren.
- Store-Methoden perspektivisch mit Mutationsergebnis (`Bool` oder enum) ausstatten.
- `make install` ebenfalls LaunchServices re-registrieren lassen.

## Vorherige Tests

- Session-Self-drop No-op.
- Stale dropped session.
- Drop auf eigenes Projekt/Header.
- Code-UTI vs. `Info.plist`.
