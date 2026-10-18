---
status: beschlossen
updated: 2026-10-17
description: Was „launch-ready" für WhisperM8 heißt — Zielgruppe, Nutzerwege, messbare Definition of Done, Nicht-Ziele und offene Entscheidungen.
---

# Launch-Definition

> **Beschlossen am 17.10.2026:** Der User hat alle Vorschläge in
> [Entscheidungen](#entscheidungen) übernommen (E1 c, E2 b, E3 a, E4 b, E5 b,
> E6 a). Die Zahlen in der Definition of Done, die als „Vorschlag" markiert
> sind, werden in Schritt 4 gegen Messwerte bestätigt.

## Zielgruppe

Mac-Nutzer ohne Entwickler-Hintergrund, die

1. **diktieren** wollen (Hotkey → Text an der Cursorposition), optional mit
   KI-Umformulierung — Profil `dictationRaw` / `dictationEnrichment`;
2. **Claude Code bzw. Codex** nutzen wollen, ohne sich mit Terminal, CLI-
   Installation, Pfaden und Konfigurationsdateien zu beschäftigen — Profil
   `full`.

Power-User-Funktionen (mehrere Konten, GPT-Backend, Jarvis, Subagents) bleiben
erhalten, stehen aber nicht im Weg (Klassen „Erweitert" / „Labs" im
[Feature-Inventar](feature-inventar.md)).

## Nutzerwege, die fehlerfrei funktionieren müssen

| # | Weg | Startzustand | Erfolg |
|---|---|---|---|
| W1 | Installation | Frischer Mac mit Homebrew, kein WhisperM8 | `brew install --cask rankm8/tap/whisperm8` → App startet ohne Gatekeeper-Warnung und ohne Terminal-Nacharbeit |
| W2 | Erstes Diktat | nach W1 | Onboarding → Rechte erteilt → Key eingegeben → Testdiktat → Text erscheint in einer fremden App. Ohne Doku, ohne Terminal |
| W3 | KI-Umformulierung | nach W2, Codex fehlt | Onboarding/Settings erkennt fehlende Codex-CLI, **führt durch Installation und Login**, Modus „E-Mail" liefert Ergebnis |
| W4 | Erster Agent-Chat | nach W1, Claude-CLI fehlt | App erkennt fehlende Claude-CLI, **führt durch Installation und Login**, Projektordner wählen, Chat läuft, Status stimmt |
| W5 | Alltag | laufende App, 10+ Chats | Kein Hänger > 1 s auf dem Main Thread, kein Datenverlust bei Absturz oder Neustart, Tabs/Chats nach Neustart wieder da |
| W6 | Update | ältere Version installiert | App meldet Update, Update gelingt ohne Datenverlust und ohne neue Rechte-Abfrage |
| W7 | Deinstallation | installiert | `brew uninstall --zap` hinterlässt keine laufenden Prozesse (Proxy, Socket) und keine Fremdänderungen in `~/.claude` |

## Definition of Done

**Stabilität**
- Keine offenen P0-Befunde (Absturz, Datenverlust, Sicherheitslücke) in Kern
  und Erweitert.
- Keine offenen P1-Befunde in Kern.
- Kein bekannter Weg, auf dem die App still beendet wird (Signal, NSException)
  oder dauerhaft einfriert.

**Performance** (gemessen mit `make dev-release`, Budgets aus
`PerformanceSignposts.swift`)
- Hotkey → Aufnahme ≤ 400 ms, Stop → Transkriptionsstart ≤ 300 ms.
- Kein `main_thread_blocked_ongoing` im Lastlauf (`scripts/perf-load.sh`) mit
  6 Grid-Panes und 20 offenen Tabs.
- Leerlauf-CPU der App unter einem noch festzulegenden Wert (Vorschlag: < 2 %).

**Sicherheit und Datenschutz**
- Keine Secrets in argv, Logs oder vererbter Umgebung von Kindprozessen.
- Nur nachgeladener Binärcode mit Prüfsumme/Signatur (Proxy).
- Control- und Debug-Socket nur für den eigenen Benutzer erreichbar.
- Jeder Datenabfluss an Dritte (Screenshots, Audio, Kontext) ist in der UI
  erklärt und abschaltbar.

**Bedienbarkeit**
- Jede Fehlermeldung sagt, was passiert ist und was der Nutzer tun kann — keine
  rohen Fehlercodes, kein „siehe Log".
- Eine Sprache in der gesamten UI (siehe E1).
- Kein Feature setzt `defaults write` voraus; Kill-Switches bleiben als
  Notbremse, sind aber nie der vorgesehene Bedienweg.

**Code und Doku**
- `swift test` grün in CI; neue Fixes mit Test.
- Keine Datei > 1.500 Zeilen in den Kern-Subsystemen (Vorschlag, in Schritt 4
  bestätigen).
- README, User Guide und `docs/features/` beschreiben den Ist-Stand;
  CLAUDE.md enthält Arbeitsregeln, kein Vorfall-Logbuch.

## Nicht-Ziele

- Kein anderer Installationsweg als der Brew-Cask (kein Mac App Store, kein
  DMG-Download als beworbener Weg, kein Build-from-Source für Endnutzer).
- Kein Stack-Wechsel ([ADR 0001](../../../adr/0001-kein-stack-wechsel.md)).
- Kein Ersatz der Claude-/Codex-CLI durch eigene UI oder SDK — WhisperM8 hostet
  die echten CLIs.
- Keine Windows-/Linux-Version.

## Entscheidungen

| # | Frage | Optionen | Vorschlag |
|---|---|---|---|
| **E1** | UI-Sprache | (a) Englisch, (b) Deutsch, (c) beides mit Lokalisierung | **(c)**, mit Englisch als Basis: heute gemischt (Onboarding englisch, Agent-Chats-UI großteils deutsch, keine `Localizable`-Ressourcen) |
| **E2** | Funktionen mit inoffiziellem Upstream: GPT-Backend (F-GPT-*), ChatGPT-Abo-Transkription (F-DIK-03) | (a) Kern, (b) Labs, (c) für Launch entfernen | **(b) Labs**: bleibt für dich nutzbar, aber nicht im Onboarding, klar gekennzeichnet, Analyse nur auf Seiteneffekte |
| **E3** | Mehrere Claude-Konten (F-KO-*) | (a) Erweitert, (b) Labs | **(a) Erweitert**, vorher prüfen, was Anthropics Nutzungsbedingungen zum Kontowechsel sagen |
| **E4** | Signatur | (a) wie heute selbst signiert + Quarantäne entfernen, (b) Apple Developer ID + Notarisierung | **(b)**: Entfernen der Quarantäne ist für eine öffentliche App ein Vertrauens- und Sicherheitsproblem; Developer ID kostet 99 $/Jahr |
| **E5** | Geführte Installation der Claude-/Codex-CLI | (a) App erklärt und verlinkt, (b) App installiert selbst (offizielle Installer), (c) Cask-Abhängigkeit | **(b)** mit Rückfrage, sofern die offiziellen Installer das sauber erlauben; (c) prüfen wir in Workflow B |
| **E6** | Zielmarke | (a) erst stabil, dann bewerben, (b) fester Termin | **(a)**: Launch, wenn die Definition of Done erfüllt ist |
