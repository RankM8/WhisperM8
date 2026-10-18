---
status: aktiv
updated: 2026-10-17
description: Schema und Status-Lebenszyklus des Befund-Registers findings.jsonl.
---

# Befund-Register: Schema

`findings.jsonl` enthält eine JSON-Zeile pro Befund. Finder schreiben nur
Rohberichte nach `02-findings/`; ins Register überträgt die Synthese
(dedupliziert, mit fester ID).

## Felder

| Feld | Typ | Pflicht | Bedeutung |
|---|---|:-:|---|
| `id` | string | ✓ | `LR-<SUBSYS>-<NNN>`, z. B. `LR-DIK-004`. Nie neu vergeben. |
| `subsystem` | enum | ✓ | `diktat`, `voicegate`, `agent-kern`, `agent-ui`, `terminal`, `gpt-backend`, `konten`, `cli-control`, `plugin-jarvis`, `shared`, `build-release`, `onboarding`, `doku` |
| `dimension` | enum | ✓ | `korrektheit`, `race`, `performance`, `security`, `privacy`, `datenintegritaet`, `robustheit`, `architektur`, `ux`, `infra`, `doku` |
| `severity` | `P0`–`P3` | ✓ | P0 Absturz/Datenverlust/Sicherheitslücke · P1 Feature kaputt oder Hänger · P2 spürbarer Mangel · P3 Schönheit |
| `launch_blocker` | bool | ✓ | Verletzt die Launch-Definition |
| `title` | string | ✓ | Ein Satz, die Behauptung |
| `evidence` | string[] | ✓ | `pfad:zeile` auf dem Analyse-Commit |
| `failure_scenario` | string | ✓ | Konkrete Eingabe/Zustand → falsches Ergebnis |
| `repro` | string | | Reproduktionsweg, falls vorhanden |
| `fix` | string | | Lösungsvorschlag |
| `effort` | `S`/`M`/`L`/`XL` | | Aufwand |
| `risk` | `niedrig`/`mittel`/`hoch` | | Risiko, beim Fix etwas zu brechen |
| `feature_ids` | string[] | | Betroffene Features aus `00-scope/feature-inventar.md` |
| `legacy_ref` | string[] | | IDs aus alten Audits (`C04`, `N12`, `R4-AS-11`, …) |
| `sources` | string[] | ✓ | Rohberichte in `02-findings/`, die ihn melden |
| `status` | enum | ✓ | siehe unten |
| `verdict` | object | | `{by, result, note}` aus `04-verifikation/` |
| `wave` | string | | Zugeordnete Umsetzungswelle |
| `commit` | string | | Fix-Commit |

## Status-Lebenszyklus

```
neu → bestätigt | teilbestätigt | widerlegt
bestätigt → geplant → umgesetzt → verifiziert
```

`widerlegt` bleibt im Register (mit Begründung im `verdict`), damit derselbe
Fehlbefund nicht wieder auftaucht.
