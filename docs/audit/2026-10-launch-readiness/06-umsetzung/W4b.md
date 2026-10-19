---
status: bereit-fuer-qa
updated: 2026-10-19
description: Umsetzungsprotokoll der Welle W4b (Agent Chats: Status und Zustellung) — Pakete, Review, offene Punkte, QA; dazu der sanfte Status-Puls.
---

# W4b · Umsetzungsprotokoll

**Start:** 19.10.2026, Branch `launch/W4b` aus `launch/W4b-zustellung` (Orchestrator), `launch/W4b-status` (Agent)
und zwei Nachbesserungs-Branches; per Fast-Forward nach `launch/integration`. Plan: [W4b](../05-plan/wellen/W4b-chats-status.md).

## Ergebnis

| Befund | Stand |
|---|---|
| LR-AK-006 (Blocker) | umgesetzt — Codex-Rollouts 0.142 und 0.16x, neue Typen statusneutral; Fixtures synthetisch |
| LR-AK-035 | umgesetzt — voller Hook-Satz unter Claude 2.1.302 oder unbekannter Version; Versionsprobe blockiert nie |
| LR-AK-036, -038, -019, -011, -016, -020 | umgesetzt |
| LR-AK-021 | umgesetzt (eng): `--resume` nur mit Beleg aus dem Event-File-Ende |
| LR-AK-039 | umgesetzt — Byte-Index statt String-Scan (synthetisch 300 MB: 0,52 s statt 22,7 s), Negativ-Cache, Budget |
| LR-AK-026, -027 | umgesetzt — Token-Claim per rename, dreistufig, Stage-Fehler verhindert den Paste |
| LR-AK-034 | umgesetzt — Abbruch-Merker nur mit Transcript-Marker, Guard-Block vorab bestätigt |
| LR-CLI-002, -003, -008, -012 | umgesetzt — kein Anhängen an Entwürfe, keine Zustellung während `launching`, längere Fristen, 0600 |
| **LR-AK-037** | **offen** — Claudes Registry hat kein Feld für delegierte Arbeit; braucht Live-Messung mit eingeloggtem Claude |

## Review

Ein Blocker (Guard-Block löste wieder „fertig“ aus) und vier „sollte“ (aktuelle Codex-Events, Entwurfs-Fehlalarme,
Main-Thread-Versionsprobe, Fork-ID-Freigabe) — alle nachgebessert. Offen als Live-Test: Reihenfolge von
Abbruch-Marker und Registry-idle bei ESC (LR-AK-034).

## Sanfter Status-Puls (Wunsch des Users, 19.10.2026)

Der grüne Puls ist als `CAAnimation` zurück (`SoftPulseRing`, Render-Server, ≤ 15 fps, pausiert verdeckt und bei
„Bewegung reduzieren“). Gemessen in der Test-Instanz, drei Punkte, sichtbares Fenster: App-CPU ~0,2 % (statisch ~0,2 %,
alter SwiftUI-Puls ~12 %). Kill-Switch `agentStatusSoftPulseEnabled`.

## Tests

Volle Suite auf `launch/W4b`: **3235 Tests, 1 übersprungen, 0 Fehler**.

## Manuelle QA (nach `make dev`)

- CPU in den ersten zwei Minuten nach dem Start (LR-AK-039).
- Codex-Chat: Status während eines stillen Tool-Laufs und Fertig-Meldung.
- ESC mitten im Claude-Turn: keine Fertig-Meldung; ESC kurz vor dem Turn-Ende: Fertig-Meldung kommt.
- `chats send` an einen Chat mit getipptem Entwurf → Konflikt mit Ausweg; nach Abschicken wieder frei.
- `chats resume` + sofort `chats enqueue` → Auftrag kommt an, sobald der Chat bereit ist.
- Status-Punkte pulsieren sanft; CPU im Leerlauf mit mehreren arbeitenden Chats.
