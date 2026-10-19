---
status: bereit-fuer-qa
updated: 2026-10-19
description: Umsetzungsprotokoll der Welle W2a (Diktat: Aufnahme retten, sicher einfügen; VoiceGate) — Pakete, Commits, Review, Tests, offene QA.
---

# W2a · Umsetzungsprotokoll

**Start:** 19.10.2026 auf `launch/integration` = `16acccf` (Test-Instanz), Branch `launch/W2a`,
per Fast-Forward nach `launch/integration` übernommen (`eeee779`). Plan: [W2a](../05-plan/wellen/W2a-diktat-aufnahme.md).

## Pakete

| Paket | Befunde | Stand |
|---|---|---|
| Recorder (Seam, Gerätewechsel, Schreibfehler, Geräteverlust) | LR-DIK-004, -005, -006, -026 | umgesetzt |
| Rettung und Zustellung | LR-DIK-012, -001, -007, -025, -018 | umgesetzt (DIK-012 schlank) |
| VoiceGate | LR-VG-001, LR-VG-002 | umgesetzt |

## Ergebnis je Befund

- **LR-DIK-004** — Recorder meldet Unterbrechungen (`onInterruption`), Teilaufnahme wird gesichert, Alert „Aufnahme unterbrochen“. Rot→grün belegt (`AudioRecorderStateTests`).
- **LR-DIK-005** — Sitzungszähler nach jedem `await`, Rekonfigurations-Task wird bei Stop abgebrochen. Rot→grün belegt.
- **LR-DIK-006** — erster Schreibfehler setzt nur ein Flag im Audio-Callback, genau eine Eskalation auf Main. Rot→grün belegt.
- **LR-DIK-026** (unverifiziert → bestätigt) — Konfigurationsbeobachter in allen Modi, Wake-Beobachter, Engine-Health-Check im Pegel-Timer; bei Geräteverlust sichtbarer Stopp mit Rettung (kein Wechsel auf System Default).
- **LR-DIK-012** — Sidecar mit Ausgabemodus; Menüeintrag „Letzte Aufnahme erneut transkribieren“, auch nach Neustart. Bewusste Abweichung: keine Liste in den Einstellungen (Prüfurteil: Menüeintrag reicht); ältere Aufnahmen weiter nur im Ordner, Kontext nach Neustart leer.
- **LR-DIK-001** — `prepareForTermination()` synchron im Quit, ohne `terminateLater`; Aufnahme, Upload und (Review) das Stop-Fenster werden gerettet.
- **LR-DIK-007** — schlanke Variante: gescheiterte Aktivierung → kein Paste, Text in der Zwischenablage, Mitteilung plus `lastError`.
- **LR-DIK-025** (unverifiziert → bestätigt) — `KeyCodeResolver` (UCKeyTranslate, Fallback US-Code) in PasteService, SelectedContextService, CodexMuteToggler.
- **LR-DIK-018** — Audiostopp und Dauer sofort beim akzeptierten Stop; `testStopStopsAudioBeforeAwaitingContext` rot→grün.
- **LR-VG-002** — inkrementeller Log-Scanner mit Cache und Inode-Prüfung, verlustfreie Dekodierung (Umlaut-Schnitt rot→grün belegt), Probe abseits des MainActors.
- **LR-VG-001** — Guard `mayAct` vor Hypothese, Tastendruck und Nachfass-Versuch.

## Review (Sonnet, nur lesend)

Kein Blocker. Nachgebessert (`eeee779`): Quit im Stop-Fenster, Alert-Titel/Doppelsatz, Paste-Hinweis ohne Mitteilungs-Erlaubnis, rotierte Logdatei. Offen als „kann“: verwaiste Teildatei bei nicht abgeholter Unterbrechung (selten), Menü-Flag nach Alters-Aufräumen.

## Tests

Volle Suite auf `launch/W2a`: **3149 Tests, 1 übersprungen, 0 Fehler**. E2E in der Test-Instanz für diese Welle nicht sinnvoll möglich (kein Mikrofon-Recht, kein API-Key im Test-Home) — die Pfade sind über Seams getestet, der Rest steht in der QA-Liste.

## Manuelle QA (nach `make dev`)

- Cmd+Q mitten in einer Aufnahme und während des Uploads → Aufnahme unter FailedRecordings, Menüeintrag erscheint.
- Auto-Paste mit beendeter Ziel-App → kein Paste, Hinweis, Text in der Zwischenablage.
- Auto-Paste unter Dvorak (QA-3).
- USB-Mikrofon bei fest gewähltem Gerät abziehen; Bluetooth-Wechsel; Deckel zu/auf während der Aufnahme (QA-4) → Hinweis, Teilaufnahme gesichert.
- ESC während Upload, danach „Letzte Aufnahme erneut transkribieren“.
