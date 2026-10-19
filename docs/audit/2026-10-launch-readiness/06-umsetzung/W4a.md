---
status: bereit-fuer-qa
updated: 2026-10-19
description: Umsetzungsprotokoll der Welle W4a (Agent Chats: Lebenszyklus, Persistenz, Bedienung) — Pakete, Review, Tests, QA.
---

# W4a · Umsetzungsprotokoll

**Start:** 19.10.2026. Branch `launch/W4a` aus `launch/W4a-klein` (Orchestrator: Cmd+Q-Dialog, UI-State-Backup,
Profil-Schutz, CLI-Aktivierung) und `launch/W4a-rest` (Agent: Persistenz, Dialoge, Grid-Performance), danach
`launch/integration` eingemischt, Katalog übersetzt, Review-Nachbesserungen vom Orchestrator; per Fast-Forward
übernommen. Plan: [W4a](../05-plan/wellen/W4a-chats-lebenszyklus.md).

## Ergebnis

17 Befunde umgesetzt, keiner widerlegt (LR-AK-039 lief bereits mit W4b). Kern:
- **Cmd+Q (D4, LR-KO-005):** Arbeitet oder wartet ein Chat, fragt Cmd+Q nach — „Beenden und später wieder öffnen“,
  „Abbrechen“, „Trotzdem beenden“. Die Wiederöffnen-Wahl lässt den Absturz-Marker mit den Chats stehen, die nach dem
  Dialog noch laufen (`keepForResume`). SIGTERM (`make dev`) nie mit Dialog.
- **Persistenz:** Fehlgeschlagene Workspace-Writes werden mit Backoff wiederholt und als Banner mit „Jetzt erneut
  versuchen“ gezeigt (AK-005); die Queue bestätigt nichts ohne gesicherten Write und schreibt eine undekodierbare
  Datei nicht leer zurück (AK-015); das Jarvis-Board überschreibt bei Lesefehlern nichts, Quarantäne behält jede
  Sicherung, defekte Einträge werden einzeln übersprungen und geloggt (AK-018, AU-017); UI-State wird vor dem
  Überschreiben gesichert.
- **Dialoge bei laufender Arbeit:** Terminal schließen, Restart, Hintergrund-Agent entfernen und Projekt löschen
  fragen nach (AU-005/-007); Tab schließen weist einmalig darauf hin, dass der Chat weiterläuft (AU-011).
- **Bedienung:** Wisch-Tabwechsel abschaltbar und nach Tastenanschlag unterdrückt (AU-012); ⌘⇧←/→ markiert nur in
  bearbeitbaren Feldern Text (AU-010); Esc bricht den Verkleinern-Modus ab (AU-019); Bulk-Aktionen in
  Anzeige-Reihenfolge (AU-024); CLI-Fortsetzen holt die App nicht mehr nach vorn, `unarchive --open` schon (CLI-004).
- **Konten (KO-008):** Transcript-Kollision beim Umzug nach main wird über das Herkunftskonto erkannt statt als
  No-op verschleiert; Profil-Schutz, solange ein Chat des Profils läuft.
- **Performance:** PTY-Resizes beim Divider-Drag und Fenster-Resize gebündelt (erste und letzte Größe, AU-015);
  Grid-Panes und Sidebar-Workspaces lösen Fokus/Projekt/Session einmal je Body auf (AU-018); abgebrochene
  Verlaufsaufbauten rechnen nicht weiter.

## Review

Unabhängiges Review (Sonnet, read-only): kein Blocker. Nachgebessert: Banner war an keine Ansicht gebunden (der
Agent hatte die Datei nicht committet), Cmd+Q merkte den Stand vor statt nach dem Dialog vor und versprach
„fortsetzen“, obwohl der laufende Turn endet, ⌘⇧←/→ blockierte auch die read-only Verlaufsansicht,
`unarchive --open` reichte `wantsOpen` nicht durch, verworfene Board-Einträge verschwanden still, Esc im
Verkleinern-Modus landete im Terminal.

**Bewusste Entscheidung (D-H):** Abmelden/Neustart/Ausschalten (`kAEQuitReason`) zeigt keinen Dialog, merkt aber
alle laufenden Chats zum Wiederöffnen vor — wie nach einem Absturz. In CLAUDE.md festgehalten.

## Tests

Volle Suite auf `launch/W4a`: **3358 Tests, 1 übersprungen, 0 Fehler**.

## Manuelle QA (nach `make dev`)

- Cmd+Q mit einem arbeitenden Chat: alle drei Wahlen; nach „später wieder öffnen“ startet der Chat beim nächsten
  Start im Tab. Cmd+Q ohne Arbeit: kein Dialog. (Der Dialog lief nie E2E — die Test-Instanz parkt ihre Fenster.)
- Divider-Drag mit 6–9 Panes: flüssig, Terminals am Ende in richtiger Größe.
- Wisch-Tabwechsel gegen Tippen; Schalter aus.
- Neue Dialoge: Terminal schließen, Restart, Hintergrund-Agent entfernen, Projekt löschen — je mit laufendem und ruhendem Chat.
- Banner: Workspace-Datei schreibgeschützt machen (`chmod 444`), Banner erscheint, nach `chmod 644` + „Jetzt erneut versuchen“ verschwindet es.
- KO-008: Profil-Chat nach main verschieben, dessen Transcript auch in main liegt.
- Esc im Verkleinern-Modus; ⌘⇧←/→ in der Verlaufsansicht wechselt Tabs.
