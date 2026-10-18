---
status: beschlossen
updated: 2026-10-18
description: Wellenplan des Launch-Readiness-Audits (Schritt 4) — 163 offene Befunde in 11 Wellen, Reihenfolge, Arbeitsweise, Entscheidungen und Abdeckung der Definition of Done. Freigegeben am 18.10.2026.
---

# Wellenplan

> **Freigegeben am 18.10.2026**, D1–D5 wie empfohlen beschlossen. Alle 163 zugeordneten Befunde stehen auf
> `geplant` (der vorherige Prüfstand bleibt in `status_before_plan`). W0 läuft.

**Grundlage:** Register `findings.jsonl` mit 192 Einträgen. Davon sind **163 offen und eigenständig**
(20 P1, 91 P2, 52 P3, kein P0). **28 davon sind Launch-Blocker.** Belege beziehen sich auf `a8e0f35`
(Workflow A) bzw. `76256ad` (Delta-Lauf). Vor jedem Fix wird die Stelle auf dem aktuellen `main` neu verortet.

## Wellen

| Welle | Thema | Befunde | P1 | Blocker | Aufwand S/M/L | Dokument |
|---|---|---:|---:|---:|---|---|
| **W0** | Sofortfixes: Abstürze, Hänger, CPU | 19 | 4 | 3 | 17/2/0 | [W0](wellen/W0-sofortfixes.md) |
| **W1** | Sicherheit und Geheimnisse (inkl. Zusammenfassungen) | 20 | 3 | 2 | 11/7/2 | [W1](wellen/W1-sicherheit.md) |
| **W2a** | Diktat: Aufnahme retten, sicher einfügen | 11 | 2 | 2 | 0/9/2 | [W2a](wellen/W2a-diktat-aufnahme.md) |
| **W2b** | Diktat: Kontext, Datenschutz, Nachbearbeitung | 14 | 2 | 2 | 4/10/0 | [W2b](wellen/W2b-diktat-kontext.md) |
| **W3** | Erste Schritte: Onboarding, CLI-Installation (E5), fremde Setups | 23 | 5 | 6 | 12/9/2 | [W3](wellen/W3-erste-schritte.md) |
| **W4a** | Agent Chats: Lebenszyklus und Datensicherheit (inkl. LR-KO-005/-008, D3) | 17 | 0 | 0 | 10/7/0 | [W4a](wellen/W4a-chats-lebenszyklus.md) |
| **W4b** | Agent Chats: Status und Zustellung | 16 | 1 | 1 | 9/7/0 | [W4b](wellen/W4b-chats-status.md) |
| **W5** | Verteilung: Developer ID, Notarisierung, Cask, Update, Deinstallation | 12 | 3 | 5 | 4/4/4 | [W5](wellen/W5-verteilung.md) |
| **W6** | Sprache und Bedienbarkeit (E1), Barrierefreiheit | 8 | 0 | 1 | 2/4/2 | [W6](wellen/W6-sprache-bedienbarkeit.md) |
| **W7** | Doku und Launch-Abnahme | 7 | 0 | 6 | 4/3/0 | [W7](wellen/W7-doku-abnahme.md) |
| **W8** | Erweitert und Labs härten (nach dem Launch, D3) | 16 | 0 | 0 | 5/11/0 | [W8](wellen/W8-erweitert-labs.md) |

Jedes Wellendokument enthält:
- Ziel und Abnahmekriterien als Checkliste;
- die Test-Infrastruktur, die zuerst entstehen muss;
- den Lückenschluss aus der Kritik am Delta-Lauf, also Bereiche, die zu Beginn der Welle gelesen werden;
- die Oracle-Invarianten für den Feature-Erhalt;
- je Befund Beleg, Fehlerbild, Fix, „Test zuerst“ und Prüfurteil.

## Reihenfolge

Höchstens zwei Hauptstränge laufen parallel. So bleibt jede Welle reviewbar, und `make dev` und die QA durch dich stauen sich nicht.

```
W0 ──┬─ Strang A:  W2a ──► W3 (beginnt mit W3.0 Lokalisierungs-Grundlage) ──► W2b ─┐
     │                                                                             ├─► W6 ──► W7 Abnahme
     └─ Strang B:  W1 ──► W4b ──► W4a ─────────────────────────────────────────────┘
        Nebenstrang: W5, sobald das Apple-Developer-Konto steht (CI/Skripte, kaum Konflikte)
        W8: nach dem Launch (D3)
```

Warum diese Reihenfolge:
- **W0 zuerst:** Die Fixes sind klein, unabhängig und beseitigen Abstürze sowie die CPU-Last, die jeden weiteren Test verfälscht.
- **W3 vor W2b:** Mit 6 Blockern ist W3 der Kern des Laien-Erlebnisses.
- **W3 beginnt mit dem String Catalog:** Neue Onboarding-Texte entstehen gleich lokalisiert und müssen in W6 nicht noch einmal angefasst werden.
- **W4b vor W4a:** Status und Zustellung bauen auf dem frischen Registry-Weg auf. Solange der Kontext da ist, sind Folgefehler am billigsten.
- **W5 hängt an dir** (Apple-Konto, siehe unten) und berührt fast nur `scripts/`, `.github/` und den Cask. Die Welle kann jederzeit parallel laufen.
- **W7 zuletzt:** Doku beschreibt den Endstand, die Abnahme misst ihn.

## Arbeitsweise je Welle

1. **Worktree je Welle** (`launch/W<n>`), nie im Haupt-Checkout. Gestagt werden nur eigene Hunks.
2. **Lückenschluss und Oracle lesen.** Neue Funde kommen mit neuer ID ins Register, bevor gefixt wird.
3. **Tests zuerst:** Pro Befund gibt es einen Test, der vor dem Fix rot ist.
   - Gilt für die 52 Delta- und 13 Red-Team-Befunde mit Status `neu`.
   - Lässt sich so ein Befund nicht reproduzieren, wird er mit Begründung `widerlegt` geschlossen statt „vorsorglich“ gefixt.
4. **Ein Commit je Thema**, deutsche Message, kein Push. Register-Feld `fix_commit`, Status `umgesetzt`.
5. **Umsetzung:**
   - Ich setze um. Parallel laufende Pakete innerhalb einer Welle bekommen Sonnet-5.5-Subagents mit eigenem Worktree.
   - Danach prüft ein unabhängiger Review-Agent (Sonnet) den Diff gegen die Abnahmekriterien und die Oracle-Invarianten.
6. **Volle Suite plus Release-Build** in eigenem Build-Ordner. Danach meldet die Welle „bereit für `make dev`“. Neustart und QA machst du, dann geht der Status auf `verifiziert`.
7. **Protokoll** unter `06-umsetzung/W<n>.md`: Commits, Messwerte, widerlegte Befunde, neue Funde.

## Entscheidungen (beschlossen 18.10.2026)

| # | Frage | Beschluss |
|---|---|---|
| **D1** | Automatische Zusammenfassungen (LR-AK-010): Sie schicken Chat-Inhalt zusätzlich an ein Modell. | **Default aus**, mit Erklärtext und Schalter. Bestandsnutzer mit gespeichertem Wert behalten ihn. Damit ist der Blocker billig gelöst. |
| **D2** | Zahlen der DoD bestätigen: Leerlauf-CPU < 2 %, keine Kern-Datei > 1.500 Zeilen | **Bestätigen**, gemessen wird nach W0. Für Bestandsdateien über der Grenze gilt eine schrumpfende Ausnahmeliste, keine Pflicht-Refactors vor dem Launch. |
| **D3** | W8 (Erweitert/Labs) vor oder nach dem Launch? | **Nach dem Launch.** Ausnahme: LR-KO-005 und LR-KO-008 (Datenintegrität beim Profil-Entfernen bzw. Umzug), die gehen mit W4a mit. |
| **D4** | Cmd+Q mit laufenden Chats (LR-AU-006) | **Dialog nur, wenn ein Chat arbeitet oder wartet**, mit der Wahl „Beenden und beim nächsten Start fortsetzen“. Das nutzt den vorhandenen Crash-Recovery-Weg. Ruhende Chats beendet Cmd+Q still wie heute. |
| **D5** | E5: Über welchen Weg installiert die App die CLIs? | **Homebrew-Cask** (`claude-code`, `codex`) nach Rückfrage. Brew ist durch den Installationsweg ohnehin da, und es gibt kein `curl \| bash` aus der App. Eine vorhandene Installation (native, npm, Brew) wird erkannt und nie doppelt angelegt. Für Claude gibt es als Alternative den offiziellen Native-Installer (aktualisiert sich selbst). |

**Deine Aktion, wegen der Vorlaufzeit am besten jetzt:**
1. Beim Apple Developer Program anmelden (99 $/Jahr).
2. Ein Zertifikat „Developer ID Application“ anlegen.
3. Einen Notarisierungs-Zugang anlegen (App-spezifisches Passwort oder API-Key für `notarytool`).
4. Zertifikat und Zugang als GitHub-Secrets hinterlegen.

Ohne diese Schritte bleibt W5 bei LR-BR-003 stehen. Dann fehlt W1 („ohne Gatekeeper-Warnung“), und das blockiert den Launch.

## Abdeckung der Definition of Done

| DoD | Wellen | Status heute |
|---|---|---|
| Keine offenen P0 | — | erfüllt (C2: kein Finder-P0 bestätigt) |
| Keine offenen Kern-P1 | W0, W2a, W2b, W3, W4b, W5 | 15 offen, alle als Blocker markiert; dazu LR-KO-001 (Erweitert) als Sicherheits-Blocker |
| Kein stiller Exit, kein Dauer-Einfrieren | W0 (Traps, Logger, `terminateAll`), W3 (Login-Shell) | offen |
| Hotkey ≤ 400 ms, Stop ≤ 300 ms | W2a (LR-DIK-018), Messung W7 | offen |
| Kein `main_thread_blocked_ongoing` bei 6 Panes / 20 Tabs | W0 (CPU), W4a (Resize), Messung W7 | offen |
| Leerlauf-CPU < 2 % | W0, Messung W7 | Wert offen (D2) |
| Keine Secrets in argv, Logs, Umgebung | W1 | offen |
| Nachgeladener Binärcode geprüft | — | erfüllt (Proxy-Prüfsumme getestet) |
| Sockets nur eigener Benutzer | W1 | offen |
| Datenabfluss erklärt und abschaltbar | W1 (Zusammenfassungen), W2b (Kontext) | offen |
| Fehlermeldungen mit Handlungsweg | W2a, W3 | offen |
| Eine Sprache | W3.0, W6 | offen |
| Kein `defaults write` als Bedienweg | W6 | offen |
| `swift test` grün in CI, Fix mit Test | W5 (Test-Gate, Timeout), alle Wellen | teilweise |
| Keine Kern-Datei > 1.500 Zeilen | W7 (Guard mit Ausnahmeliste) | offen (D2) |
| Doku = Ist-Stand, CLAUDE.md nur Regeln | W7 | offen |
| Nutzerwege W1–W7 | W5 (W1, W6, W7), W3 (W2–W4), W4a (W5), Abnahme W7 | offen |

## Register-Bereinigung in diesem Schritt

- **Dubletten:** LR-AK-024 und LR-AU-001 werden als Dublette von LR-AK-031 geführt. Es ist derselbe ungelockte Read-Modify-Write auf `state.json`, empfohlen in Opus O2.
- **Teilaufgabe:** LR-BR-004 hängt als Teilaufgabe an LR-BR-003. Ohne den Fix bricht der Developer-ID-Build ab.
- **Herabstufung:** LR-AK-020 geht von P2 auf P3. Laut Delta-Abgleich ist der Befund im Standardpfad durch den Registry-Status entschärft und bleibt nur für Background-Agents und den Kill-Switch.
- **Neue Launch-Blocker:** LR-DIK-023, LR-AK-033 und LR-BR-006 sind Kern-P1, und die DoD verlangt „keine offenen P1 in Kern“. Bisher fehlte bei ihnen die Markierung.
- **Red-Team-Befunde:** Bei 13 Befunden wurde die Dimension auf das Schema gebracht, Aufwand und Risiko sind geschätzt.
- **Testideen:** 27 fehlende Testideen sind ergänzt, jetzt hat jeder offene Befund ein „Test zuerst“.
- **Wellen:** Jeder offene Befund hat ein Feld `wave`. Der Status bleibt bis zur Freigabe unverändert.

## Nicht im Plan

- **Neue Funktionen**, die keine Lücke der Launch-Definition schließen.
- **Stack-Wechsel** und **Ersatz der CLIs** durch Eigen-UI.
- **Pflicht-Refactors von Großdateien:** Nur die Guard-Grenze gilt, siehe D2.
