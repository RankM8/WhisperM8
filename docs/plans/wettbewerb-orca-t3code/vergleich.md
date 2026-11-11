# Vergleich: Orca, T3 Code, WhisperM8

**Stand:** 10.11.2026 · **Gehört zu:** [README.md](README.md) · Einzelheiten je Produkt in [orca.md](orca.md) und [t3code.md](t3code.md)

Lesehilfe: **ja** heißt vorhanden und im Code oder in der Doku des Produkts belegt, **teils** heißt vorhanden mit einer genannten Einschränkung, **nein** heißt nach gezielter Suche nicht gefunden. Die Spalte WhisperM8 beschreibt den Stand von `main`.

## Grundlage

| | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Technik | Electron, TypeScript | Electron, TypeScript, eigener Server | Swift, SwiftUI, nativ |
| Umfang | rund 4,3 Mio. Zeilen | rund 1,6 Mio. Zeilen | rund 130.000 Zeilen plus 69.000 Tests |
| Plattformen | macOS, Windows, Linux, Web, iOS, Android | macOS, Windows, Linux, Web, iOS, Android | macOS |
| Agents | rund 40 CLIs | 11 Anbieter plus offenes Protokoll | Claude Code, Codex |
| Claude läuft als | echte CLI im Terminal, wahlweise Chat | SDK, eigene Chat-Oberfläche | echte CLI im Terminal |
| Claudes eigene Oberfläche (Statuszeile, Mods, `/model`) | ja | nein | ja |
| Chats überleben das Beenden der App | ja (eigener Dienst) | nur mit eingerichtetem Hintergrunddienst | nein |
| Freigaben ab Werk | Vollzugriff | Vollzugriff | wie Claude Code selbst |

## Chats und Arbeitsfläche

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Projekte mit Chat-Liste | ja | ja | ja |
| Eigene Arbeitskopie (Worktree) je Chat | ja, Normalfall | ja, wählbar | teils: nur für Codex-Subagent-Jobs |
| Tabs und geteilte Flächen | ja | ja | ja (Raster, Workspace) |
| Mehrere Fenster | nicht geprüft | nicht geprüft | ja |
| Plus-Menü mit Suche und allen Tab-Arten | ja | – | teils: Chats und Terminals, ohne Suche |
| Archiv, Pinnen, Suche | ja | ja | ja |
| Verlauf ohne laufendes Terminal lesen | ja | ja | ja (eine Textansicht) |
| Fremde, außerhalb gestartete Sitzungen finden | ja | ja (Import mit Grenzen) | ja |
| Übergabe an anderen Agent mit Kontext | ja, Dialog | ja | nein |
| Sitzung abzweigen | ja | ja | nein (nur über Claude selbst) |
| Derselbe Auftrag an mehrere Modelle parallel | über Orchestrierung | ja, eingebaut | über Jarvis oder Subagents |
| Warteschlange für Nachrichten | – | ja | teils: `chats send` mit Zurücklegen |
| Dateibaum neben dem Chat | ja | ja | nein |
| Dateien und Markdown in der App öffnen | ja, mit Editor | ja, Vorschau | nein |

## Git und Review

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Branch am Chat sichtbar | ja | ja | ja |
| Liste der Änderungen | ja | ja | nein |
| Diff-Ansicht | ja | ja | nein |
| Anmerkung an einer Diff-Zeile an den Agent | ja | ja | nein |
| Commit- und PR-Text vorschlagen, PR erstellen | ja | ja | nein (macht der Agent im Terminal) |
| Checks und PR-Kommentare zurück an den Agent | ja | ja, als Beobachtung, die den Agent weckt | nein |
| Review eines PR in der App | teils | ja, umfangreich | nein |
| Checkpoints und Zurückspulen | ja | ja, Gespräch und Dateien gemeinsam | nur Claudes eigenes Zurückspulen |

## Überblick und Steuerung

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Status je Chat (arbeitet, wartet, fertig) | ja | ja | ja |
| Sicht „was braucht mich“ über alle Chats | ja, Kanban | ja, Eingang | ja: Jarvis-Board, Notch, Statuspunkte |
| Statusanzeige außerhalb des Fensters | Benachrichtigungen | Benachrichtigungen, Widgets | Notch, Sprachansagen, Benachrichtigungen |
| CLI, mit der Agents andere Chats steuern | ja (`orca`) | ja (MCP und CLI) | ja (`whisperm8 chats`) |
| Supervisor-Skill | ja | ja | ja (Jarvis) |
| Fertig-Meldung genau einmal, Rückfrage als Nachricht | ja | ja | teils: Wecken über das Board, kein fester Vertrag |
| Worker auf anderem Rechner | ja | ja | nein |
| Hintergrund-Agents | über den Dienst | über den Server | ja (`claude --bg`), Codex-Jobs |
| Geplante Läufe | ja | ja, auch per Webhook | nein in der App; Claudes eigene Routinen laufen in unseren Chats |
| Aufgaben aus Jira, Linear, GitHub | ja | teils (PRs und Issues der Git-Plattform) | nein |

## Konten, Modelle, Verbrauch

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Mehrere Claude-Konten | ja | ja | ja |
| Laufenden Chat auf anderes Konto umziehen | Neustart der Sitzung | nur bei gleichem Konfigurationsordner | ja, nach dem Turn, mit Verlauf, MCP und Memory |
| Mehrere ChatGPT- oder Codex-Konten | ja | ja | ja |
| GPT-Modelle in Claude Code über das eigene ChatGPT-Abo | nein | nein | **ja**, eingebaut |
| Fremde Modelle in Claude über eigenen Router | Adresse wird durchgereicht | ja, von Hand einzutragen | ja, über das GPT-Backend |
| Limit-Anzeige Sitzung und Woche | ja, über zehn Anbieter | ja | ja, je Konto |
| Angespartes Reset-Guthaben einlösen („Jetzt zurücksetzen“) | ja, für Codex | ja, für Codex und Claude | nein |
| Kosten und Token | ja, je Worktree | ja, über Rechner hinweg | ja, dazu aktive Zeit, Diktate, Gegenwert in Euro |
| Ablauf des Claude-Logins anzeigen und erneuern | nicht gefunden | nicht gefunden | gebaut, noch nicht in `main` |

## Sprache

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Diktat in das Eingabefeld der App | ja | ja | ja |
| Diktat systemweit in jede App | nein | nein | **ja** |
| Nachbearbeitung mit Modi (E-Mail, Slack, umschreiben) | nein | Glättung | **ja** |
| Kontext aus Auswahl und Bildschirm | nein | Bildschirmfoto als Chat-Kontext | **ja** |
| Offline-Modelle | ja | ja | nein |
| Sprachansagen, Codewort-Steuerung | nein | nein | **ja** |

## Browser und Prüfen

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Browser in der App | ja | ja | nein |
| Agent steuert den sichtbaren Browser | ja, über `orca`-Befehle | ja | nein in der App; Agents nutzen Playwright außerhalb |
| Element greifen und anmerken, an Chat senden | ja | ja | nein |
| Simulator und Emulator | ja | ja | nein |
| Steuerung von Desktop-Apps | ja | nein | nein |

## Rechner und Geräte

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| Chat auf anderem Rechner per SSH | ja | ja | nein |
| Eigener Server auf dem Zielrechner | ja | ja | – |
| Cloud-VM je Aufgabe | ja, experimentell | nein | nein |
| Zugriff ohne VPN über Cloud-Tunnel | ja, eigenes Relay | ja | nein |
| Handy-App | ja | ja | nein |
| Web-Oberfläche | ja | ja | nein |

## Ressourcen und Betrieb

| Funktion | Orca | T3 Code | WhisperM8 |
|---|---|---|---|
| CPU und Speicher je Projekt, Chat, Prozess | ja | Prozessbaum ohne Chat-Namen | ja |
| Messwert wie in der Aktivitätsanzeige | ja | nein (RSS) | ja |
| Verlaufslinie | ja | ja | nein |
| Verbrauch der App selbst | ja | ja | nein |
| Prozess oder Sitzung aus der Ansicht beenden | ja | ja | nein |
| Verwaiste Terminals erkennen | ja | – | nein |
| Fertige Chats schlafen legen | ja, experimentell | automatisches Abhängen | nein |
| Wachhalten | ja, drei Stufen | – | ja, auch zugeklappt |
| Plattenbelegung der Arbeitskopien | ja, Beta | – | – |

## Nur WhisperM8

Nach Gegenprüfung in beiden Quelltexten:

1. **GPT in Claude Code über das eigene ChatGPT-Abo**, mit eingebautem Proxy, mehreren GPT-Konten, Modellauswahl aus dem Codex-Katalog und GPT-Subagents. Orca hat nichts Vergleichbares. T3 erlaubt einen fremden Router, den man selbst betreiben und von Hand eintragen muss.
2. **Systemweites Diktat** mit Hotkey, Kontext aus Auswahl und Bildschirm, Ausgabemodi und Einfügen in die aktive App. Beide Konkurrenten diktieren nur in die eigene App.
3. **Kontowechsel für laufende Chats:** nach dem Turn, mit Prüfung des Ordner-Vertrauens, Umzug des Verlaufs, Angleich von MCP und gemeinsamem Memory.
4. **Mac-Cockpit:** Notch-Anzeige, Sprachansagen, Codewort-Steuerung, Zwischenablage-Verlauf, Tastatursperre, Wachhalten bei zugeklapptem Gerät.
5. **Jarvis-Board im Prompt** der Supervisor-Sitzung. Bei T3 technisch nicht möglich, weil es Claudes Oberfläche nicht zeigt.
6. **Statistik zur eigenen Arbeit:** aktive Zeit, Agenten-Zeit, Diktate, Gegenwert des Abos.
7. **Zurückhaltung:** keine Einträge in den Claude-Einstellungen für den Status, kein Vollzugriff ab Werk. Beide Konkurrenten starten neue Chats ab Werk ohne Freigabe-Nachfragen (`agentPermissionDefault: 'full-access'` bei Orca, „The initial default is Full access“ in T3s `docs/user/permission-modes.md`).

## Vermutete Alleinstellungsmerkmale, die keine sind

| Vermutung | Befund |
|---|---|
| Mehrere Konten | haben beide |
| Verbrauch und Limits | haben beide, über mehr Anbieter |
| Supervisor über mehrere Chats | haben beide; T3 mit dem breiteren Werkzeugsatz, Orca mit dem festeren Auftragsvertrag |
| Diktat | haben beide, innerhalb der App |
| Echte CLI im Terminal | hat Orca ebenfalls |
| Ressourcenansicht | hat Orca ebenfalls, mit mehr Aktionen |
| Wachhalten | hat Orca ebenfalls, ohne zugeklappten Betrieb |

## Was uns fehlt, nach Gewicht

| Lücke | Wer hat es | Gewicht für uns |
|---|---|---|
| Chats überleben Neustart, Update, Absturz | Orca | hoch |
| Arbeitskopie je Chat mit Liste der Änderungen | beide | hoch |
| Browser mit Anmerkungen, vom Agent steuerbar | beide | hoch (ausdrücklicher Wunsch) |
| Chat auf anderem Rechner | beide | mittel (ausdrücklicher Wunsch), als SSH-Schritt klein |
| Aufgaben aus Jira | Orca | mittel (ausdrücklicher Wunsch) |
| Übergabe an anderen Agent | beide | mittel |
| Diff und PR in der App | beide | mittel |
| PR-Beobachtung, die den Chat weckt | T3 | mittel |
| Geplante Läufe in der App | beide | niedrig bis mittel |
| Fertige Chats schlafen legen | Orca | niedrig bis mittel |
| Handy-App | beide | niedrig heute, Aufwand sehr groß |
| Viele weitere Agents | beide | niedrig |
| Editor, Notebooks, Emulator | Orca | niedrig |
