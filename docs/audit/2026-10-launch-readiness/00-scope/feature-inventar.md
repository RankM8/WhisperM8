---
status: beschlossen
updated: 2026-10-17
description: Produktumfang auf Feature-Ebene mit Launch-Klasse je Feature (Vorschlag, User entscheidet) — bestimmt Analysetiefe und Qualitätsmaßstab.
---

# Feature-Inventar (Produktumfang)

> **Entwurf.** Die Spalte „Vorschlag" ist meine Empfehlung, die Entscheidung
> trifft der User. Erst danach startet Workflow A — die Klasse bestimmt, wie
> tief ein Feature geprüft wird.

Stand: Commit `a8e0f35`. Quellen: `WhisperM8/Support/AppPreferences.swift`
(41 Bool-Schalter), Settings-Seiten unter `WhisperM8/Views/Settings/Pages/`,
`WhisperM8/Views/OnboardingView.swift`, CLAUDE.md, `docs/features/`. Die
Code-nahen Regressions-Inventare aus dem Juli (`AC-xx`, `DI-xx`) bleiben
gültig und werden in Spalte „Juli-Ref" verknüpft.

## Launch-Klassen

| Klasse | Bedeutung | Qualitätsmaßstab | Analysetiefe |
|---|---|---|---|
| **Kern** | Im Onboarding, Standard an | Launch-Blocker, wenn kaputt | voll, alle Dimensionen |
| **Erweitert** | In den Einstellungen sichtbar, opt-in | Launch-Blocker nur bei P0 | voll für P0/P1 |
| **Labs** | Hinter „Experimentell", klar gekennzeichnet | darf Kern, Daten und Sicherheit nicht gefährden | nur Seiteneffekte auf Kern/Daten/Security |
| **Intern** | Debug/Entwicklung, unsichtbar | darf nichts nach außen öffnen | nur Security |
| **Entfernen** | wird ausgebaut | — | nur Ausbaurisiko |

## A · Diktat

| ID | Feature | Abhängigkeiten | Default | Vorschlag | Juli-Ref / Notiz |
|---|---|---|---|---|---|
| F-DIK-01 | Hotkey-Diktat: Aufnahme, Pill-Overlay, Zwischenablage, Auto-Paste | Mikrofon, Bedienungshilfen | an | **Kern** | DI-01…DI-11, DI-33/34 |
| F-DIK-02 | Transkription über OpenAI oder Groq, Key im Schlüsselbund | API-Key (kostenpflichtig) | — | **Kern** | DI-22…24 |
| F-DIK-03 | Transkription über ChatGPT-Abo | GPT-Backend + Proxy, **inoffizieller Upstream** | aus | **Labs** (E2) | neu seit 10/2026 |
| F-DIK-04 | Audio-Ducking (andere Audioquellen leiser) | — | an | **Kern** | DI-07 |
| F-DIK-05 | Eingabegeräte-Wahl mit Fallback | — | — | **Kern** | DI-04 |
| F-DIK-06 | Kontext: markierter Text | Bedienungshilfen | an | **Kern** | DI-12/13 |
| F-DIK-07 | Visueller Kontext: Bereichs-Screenshot, Screen-Clip | Bildschirmaufnahme | an | **Kern**, Recht erst bei erster Nutzung | DI-16…21 |
| F-DIK-08 | Kontext: aktiver Agent-Chat | Agent Chats | — | **Kern** (nur Profil „full") | DI-14 |
| F-DIK-09 | Ausgabe-Modi (Umschreiben, E-Mail, Slack …) mit Vorlagen und Testlabor | **Codex-CLI + ChatGPT-Login** | — | **Kern** — Codex-Installation muss geführt werden | DI-25…32 |
| F-DIK-10 | Codex-Nachbearbeitung mit Projektzugriff / Task-Modus | Codex-CLI | aus | **Erweitert** | DI-31 |
| F-DIK-11 | `whisperm8 transcribe` (Audio/Video → Text, SRT, VTT) + Skill | optional ffmpeg | — | **Erweitert** | CLI |
| F-DIK-12 | Nutzungsprofile `dictationRaw` / `dictationEnrichment` / `full` | — | Wahl im Onboarding | **Kern** — das ist die Weiche für Laien | `AppUsageProfile.swift` |
| F-VG-01 | Voice Gate („Anna Pause/weiter" für Codex-Desktop) | Codex-Desktop + **manuelle Kürzel-Einrichtung** in Codex, Spracherkennung | aus | **Labs** | eigenes Settings-Tab |

## B · Agent Chats

| ID | Feature | Abhängigkeiten | Default | Vorschlag | Juli-Ref / Notiz |
|---|---|---|---|---|---|
| F-AC-01 | Hauptfenster: Sidebar, Projekte, Suche, Archiv | — | — | **Kern** | AC-01…09 |
| F-AC-02 | Vordergrund-Chats Claude/Codex im Terminal, Resume, Fork, Link-Klicks | **Claude-CLI** und/oder **Codex-CLI** | — | **Kern** | AC-24…29 |
| F-AC-03 | Tabs, Mehrfachauswahl, Drag, Tear-off, mehrere Fenster | — | — | **Kern** | AC-11…16 |
| F-AC-04 | Grid-Workspace, Ctrl+Tab-Switcher | — | — | **Kern** | AC-17…23 · *Delta-Lauf (Randnotizen)* |
| F-AC-05 | Erkennen extern gestarteter Sessions (Indexer, FSEvents) | `~/.claude`, `~/.codex` | an | **Kern** | AC-49 |
| F-AC-06 | Live-Status über Hooks + Transcript-Watcher, Benachrichtigungen, Stop-Sound | Claude-Hooks | an | **Kern** | AC-39…44 |
| F-AC-07 | Chat-Titel aus nativem Titel; Zusammenfassungen | — | an | **Kern** — Kosten/Datenfluss der Zusammenfassungen in A prüfen | AC-10 |
| F-AC-08 | Verlaufsansicht (ein NSTextView, TextKit 2) | — | — | **Kern** | neu seit 08/2026 |
| F-AC-09 | Wiederaufnahme laufender Chats nach Absturz | — | an | **Kern** | neu seit 09/2026 |
| F-AC-10 | Send-Guard gegen doppelt zugestellte Prompts | Claude-Hooks | an | **Kern** (unsichtbar) | |
| F-AC-11 | Background-Agents (`claude --bg`, attach, Resume→Attach) | Claude-Supervisor | — | **Erweitert** | AC-31…33 |
| F-AC-12 | Codex-Subagent-Jobs (`whisperm8 agent`), Takeover, Retention | Codex-CLI, git | an | **Erweitert** | AC-34…38 |

## C · Konten

| ID | Feature | Abhängigkeiten | Default | Vorschlag | Juli-Ref / Notiz |
|---|---|---|---|---|---|
| F-KO-01 | Mehrere Claude-Konten (`CLAUDE_CONFIG_DIR`), Chat verschieben, Hauptkonto tauschen | mehrere Claude-Abos | an | **Erweitert** (E3) — Nutzungsbedingungen prüfen | AC-45…47 |
| F-KO-02 | Kontowechsel ohne Stoppen (nach dem Turn) | F-KO-01 | an | **Erweitert** | neu 10/2026 |
| F-KO-03 | Gemeinsames Claude-Memory über Konten | F-KO-01 | an | **Erweitert** | neu 10/2026 |
| F-KO-04 | MCP-Server über Konten angleichen | F-KO-01 | Auto aus | **Erweitert** | neu 10/2026 |
| F-KO-05 | Nutzungsanzeige je Konto (Popover) | F-KO-01 | — | **Erweitert** | |

## D · GPT-Backend

| ID | Feature | Abhängigkeiten | Default | Vorschlag | Juli-Ref / Notiz |
|---|---|---|---|---|---|
| F-GPT-01 | Claude Code mit GPT-Modellen (Mix-Router, Modellwahl) | `claude-code-proxy` (Download zur Laufzeit), ChatGPT-Abo, **inoffiziell** | aus | **Labs** (E2) | Workflow 3 |
| F-GPT-02 | Mehrere ChatGPT-Konten im GPT-Backend | F-GPT-01 | an (wenn Backend an) | **Labs** (E2) | neu 09/2026 |
| F-GPT-03 | Proxy-Verwaltung: Download, Auto-Update, Waisen-Schutz | GitHub-Releases | an | **Labs** (E2) | lädt **Binärcode zur Laufzeit** nach → Security-Prüfung |

## E · Automatisierung und Jarvis

| ID | Feature | Abhängigkeiten | Default | Vorschlag | Juli-Ref / Notiz |
|---|---|---|---|---|---|
| F-AUT-01 | `whisperm8 chats` (Jarvis-CLI) + Control-Socket | — | an | **Erweitert** | *Delta-Lauf* |
| F-AUT-02 | Claude-Code-Plugin `whisperm8` (Skills, Mod) | Claude-CLI | an | **Kern-Infrastruktur** (unsichtbar) — darf fremde Claude-Setups nicht stören | *Delta-Lauf* |
| F-AUT-03 | Jarvis-Board (+ Randnotizen in Arbeit) | F-AUT-01/02 | an | **Labs** | *Delta-Lauf* |
| F-AUT-04 | Voice-Callouts (`speak`) | — | an | **Erweitert** | |
| F-AUT-05 | Claude-Hooks-Einstellungen | Claude-CLI | an | **Kern-Infrastruktur** | Basis für F-AC-06 |

## F · App-Hülle und Infrastruktur

| ID | Feature | Abhängigkeiten | Default | Vorschlag | Notiz |
|---|---|---|---|---|---|
| F-APP-01 | Onboarding (Willkommen, Profil, Rechte, Hotkey, API-Key, Codex, Test) | — | — | **Kern — Ausbau nötig** | Kein Schritt für die Installation der Claude-/Codex-CLI |
| F-APP-02 | Dock-App + Menüleiste, Profil-abhängige Fenster | — | — | **Kern** | |
| F-APP-03 | Einstellungen (13 Seiten in `SettingsPage`, mehrere mit Tabs) | — | — | **Kern** — nach Launch-Klassen neu ordnen | `SettingsView.swift` |
| F-APP-04 | Update-Hinweis mit `brew upgrade`-Befehl bzw. Adopt-Befehl für Nicht-Cask-Installationen | GitHub-API | an | **Kern** — für Laien: Befehl kopieren reicht nicht, Prüfung in A | `AppUpdateChecker.swift` |
| F-APP-05 | Start bei Anmeldung | — | — | **Kern** | |
| F-APP-06 | CLI-Symlink `whisperm8` | — | — | **Kern** (für Skills nötig) | |
| F-APP-07 | Berechtigungen: Mikrofon, Bedienungshilfen, Bildschirmaufnahme | TCC | — | **Kern** | |
| F-APP-08 | Absturzschutz (ObjC-Exceptions, SIGPIPE), Stall-Watchdog, Perf-Signposts | — | an | **Kern** (unsichtbar) | |
| F-DEV-01 | Debug-Steuerkanal, Perf-Detail, Metal-Renderer, Datei-Logging, UI-Snapshots | — | aus | **Intern** | Debug-Socket: Security prüfen |

## Verteilung (kein Feature, aber Launch-relevant)

- **Einziger Weg:** `brew install --cask rankm8/tap/whisperm8` (eigener Tap).
- **Signatur:** Das Cask entfernt im `postflight` das Quarantäne-Attribut, weil
  die App **selbst signiert und nicht notarisiert** ist
  (`scripts/update-cask.sh`). → Entscheidung **E4**.
- **README** bietet zusätzlich DMG-Download und Build-from-Source als
  Installationsweg an → widerspricht „nur Brew", wird in der Doku-Welle bereinigt.

## Offene Entscheidungen für dieses Inventar

Siehe [Launch-Definition, Abschnitt „Entscheidungen"](launch-definition.md#entscheidungen).
