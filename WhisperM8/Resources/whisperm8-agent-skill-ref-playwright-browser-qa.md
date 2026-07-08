# Browser-QA mit Playwright-Subagents — Betriebswissen

Empirisch erarbeitete Regeln aus dem AkquiseAI-QA-Betrieb (Stand 07/2026).
Gilt für `whisperm8 agent run --playwright-storage-state <path>`.

## Auth-States: Lebensdauer und Frische

- **storageState-Dateien altern schnell.** Beobachtet: Ein frisch gecapturter
  Admin-State (AkquiseAI-Dev, Keycloak-SSO) war nach ~40 Minuten Idle tot —
  deutlich vor dem Realm-`ssoSessionIdleTimeout` (30 min ab letzter Nutzung;
  vermutlich invalidiert die App-Session-Rotation zusätzlich). Cookie-Expiry
  im JSON sagt NICHTS über die Server-Gültigkeit.
- **Regel: Capture unmittelbar vor jedem Batch** (kostet ~10 s pro Rolle).
  Niemals einen State von "vorhin" weiterverwenden, ohne ihn zu testen.
- **Ein State verträgt parallele Nutzung.** Drei gleichzeitige Browser-Kontexte
  mit derselben State-Datei inkl. Reload: getestet, funktioniert. Separate
  States pro Slot sind NICHT nötig.
- **Schnelltest vor Fan-out** (statt vollem Probe-Subagent, wenn es eilt):
  headless Playwright direkt — Seite laden, URL prüfen (kein /login-Redirect).
- **Mid-Batch-Tod ist möglich:** Auch mit sekundenfrischem State kann EIN Job
  eines Batches auf /login laufen, während die Geschwister durchgehen
  (vermutlich Race der parallelen Token-Refreshes). Recovery: betroffenes
  Ticket einfach SOLO mit frisch gecapturtem State wiederholen — kein
  Grundsatzproblem, kein Debugging nötig.
- State-Erzeugung: siehe `references/1password-cli.md` (capture-state.mjs).

## Parallelität und das Approval-Gate

- **`user cancelled MCP tool call` war ein Approval-Gate-Problem, kein
  Parallelitäts-Limit:** nicht-read-only MCP-Tools (browser_resize,
  browser_tabs, browser_evaluate) brauchten headless eine Freigabe, die
  fehlte. Das whisperm8-CLI setzt sie seit 2026-07-05 automatisch
  (`default_tools_approval_mode`). Tritt die Signatur trotzdem auf: Logs
  prüfen und per `agent send` nachsteuern (Session-Kontext bleibt), nicht
  blind neu spawnen.
- Auch nach dem Fix fehlte in einem Einzelfall `browser_evaluate` in einer
  Session — Prompts weiterhin mit Fallback formulieren (nächster Abschnitt).
- **Bewährte Betriebsgröße: 3 parallele Browser-Jobs.** Jeder Job startet
  eine eigene Chrome-Instanz; Engpass sind RAM/CPU. 3er-Batches liefen über
  viele Runden stabil; größere Mengen staffeln.
- Ein per `agent send` fortgesetzter Job behält den Playwright-MCP.
- Fan-out-Betrieb: Batch von 3 starten (je `run --wait --json` als
  Background-Task), auf alle Abschlüsse warten, Ergebnisse einsammeln,
  nächsten Batch mit FRISCHEM State starten.

## Sandbox-Grenzen (beobachtet)

- `file://`-Navigation ist im Playwright-MCP blockiert.
- Lokale Listener im Codex-Prozess scheitern (`listen EPERM`) — kein
  Transfer-Server als Workaround für Dateizugriffe.
- Browser-Traffic (auch localhost/https mit self-signed) geht OHNE
  `--allow-network` — der MCP läuft außerhalb der Codex-Sandbox.

## Werkzeug-Verfügbarkeit ist nicht garantiert

- Einzelne Jobs hatten `browser_evaluate` (getComputedStyle etc.) verfügbar,
  andere nicht — dieselbe MCP-Konfiguration, unterschiedliche Sessions.
- Prompts deshalb mit Fallback formulieren ("falls browser_evaluate fehlt:
  Pixelproben/Screenshots + dokumentieren, was nicht messbar war").
- Präzisionsmessungen im Zweifel selbst machen: headless Playwright per
  Bash-Skript mit demselben storageState ist zuverlässiger und billiger als
  ein zweiter Agent-Anlauf.

## Prompt-Pflichtbausteine (jedes Mal, ohne Ausnahme)

Codex kennt die Sicherheitsregeln des Haupt-Agenten NICHT. Ein Agent hat
sich einmal eigenmächtig mit Seed-Credentials eingeloggt, als der State nicht
lud — seither Pflicht in JEDEM Browser-QA-Prompt:

1. "NIEMALS einloggen, ausloggen oder Passwörter eingeben — bei Login-Redirect
   sofort abbrechen und VERDICT 'NICHT PRUEFBAR' dokumentieren."
2. ".qa/auth/* nie überschreiben."
3. "Nur Playwright-MCP — nicht sichtbares Chrome, kein Computer Use."
4. Erlaubte/verbotene Datenänderungen explizit benennen (inkl. Rückdreh-Pflicht).
5. "Arbeite zügig — der Auth-State altert."
6. Eindeutige Artefaktpfade: `.qa/reports/<task>.md`, `.qa/screenshots/<task>/`.
7. VERDICT sowohl in die Report-Datei als auch in die Abschlussnachricht.

## Native Dialoge hängen den MCP (window.print & Co.)

Features, die native Browser-Dialoge öffnen (PDF-Export via `window.print()`,
Datei-Picker), BLOCKIEREN den Playwright-MCP-Kontext — der Agent hängt und
liefert ein falsches NICHT BESTANDEN. Vorgehen:

- Vor dem Prüfauftrag die Implementierung ansehen (grep nach `window.print`,
  `showOpenFilePicker` …) und solche Klicks im Prompt VERBIETEN.
- Print-Layouts selbst verifizieren: headless **bundled Chromium**
  (`chromium.launch({headless: true})` OHNE channel — `page.pdf()` braucht
  headless Chromium) + `page.emulateMedia({media: 'print'})` + `page.pdf()`.
  Das rendert exakt das Print-Stylesheet und liefert ein prüfbares Artefakt.
- Detail-Seiten direkt per ID ansteuern (ID aus der DB), statt fragile
  Listen-Klicks zu skripten.

## Testdaten-Eignung pro Ticket prüfen

Vor dem Batch klären, ob der Account den benötigten ZUSTAND hat: Ein Konto
mit freigegebenen Worksheets kann Entwurfs-/Submit-/Validierungs-Flows nicht
reproduzieren; ein Bestandskonto keinen Erstlogin. Konsequenzen:

- Pro Zustand ein passendes Testkonto pflegen (z. B. „frischer Kunde im
  Entwurfszustand" zusätzlich zum voll ausgebauten Demo-Kunden).
- Nicht reproduzierbare Zustände im Prompt benennen: Agent soll den
  sichtbaren Zustand prüfen, den Rest per Code-Lektüre absichern und die
  Einschränkung EHRLICH dokumentieren — nicht raten.

## Parallel-Kollisionen bei Testdaten

Agents, die MUTIEREN, brauchen disjunkte Testobjekte. Muster: pro Agent ein
eigens angelegtes Wegwerf-Objekt (z. B. zwei separate Test-Feature-Wünsche für
Lösch-Test und Status-Test), im Prompt namentlich zugewiesen plus expliziter
Hinweis "fasse Objekt X nicht an, daran testet parallel ein anderer Agent".
Fehlende Testdaten vorab selbst anlegen (headless Playwright mit der
passenden Rolle), nicht dem Agent überlassen.

## Verdicts kalibrieren — Agent-Urteile sind Evidenz, keine Wahrheit

Beobachtete Fehlurteile und ihre Muster:

- **Falsches MÄNGEL:** Prompt gab ein Kriterium vor, das nicht aus dem Ticket
  stammt (z. B. "~150ms Tooltip-Delay" aus einer früheren Beobachtung; "Toast
  erwartet", wo die App einen ruhigen Dialog zeigt). → Nur echte
  Ticket-Kriterien in Dossiers schreiben; Abweichungen davon als Beobachtung
  werten, nicht als Fail.
- **Falsches NICHT PRÜFBAR / falsche Negativbefunde:** stale Client-Listen
  (kein Refetch nach Fehler-Toast), zu früher Snapshot (asynchron ladende
  Dialoge). → Bei überraschenden Befunden selbst nachmessen, bevor sie als
  Bug gelten.
- **Echte Funde kommen von harten Messungen:** getBoundingClientRect pro
  Zeile, computed styles, Network-Status — die Pixel-genauen Codex-Messungen
  fanden eine reale Regression, die zwei Sichtprüfungen übersehen hatten.
  Präzise Messaufträge stellen ("miss das DIREKTE Grid-Kind, dokumentiere
  outerHTML des gemessenen Elements"), sonst misst der Agent das falsche
  Element.
- **Datenabhängige Fehlurteile:** Zustände, die aus den Testdaten folgen,
  werden gern als Mangel gemeldet (zwei Calls gleichzeitig buchbar, weil beide
  Worksheets freigegeben sind; ein gestalteter Empty-State mit Erklärtext als
  „leere Box ohne Aktion"). Vor Übernahme eines Mangels fragen: Wäre das bei
  anderem Datenstand anders? Sagt die UI selbst, warum der Zustand so ist?
- **Tooling-Artefakte als Feature-Fail:** hängender MCP nach Klick =
  vermutlich nativer Dialog (siehe oben), nicht kaputtes Feature.
- Widersprechen sich zwei Läufe, entscheidet eine eigene Kontrollmessung
  plus Code-Lektüre — nie das jüngste Urteil blind übernehmen.

## Bewährter Batch-Ablauf (Kopiervorlage)

1. Ticket-Dossiers als Dateien ablegen (`.qa/tickets/AKQ-NNN.md`) — Agent
   liest sie selbst; nur ECHTE Akzeptanzkriterien hineinschreiben.
2. Fehlende Testdaten selbst anlegen (headless, passende Rolle).
3. State frisch capturen (`capture-state.mjs <rolle>`).
4. Max. 3 Jobs starten (Background-Tasks mit `--wait --json`).
5. Pro Abschluss: `report.summary` lesen, Report-Datei bei Bedarf,
   überraschende Verdicts selbst verifizieren.
6. Datenänderungen gegen die DB prüfen (Rückdrehung!).
7. Nächster Batch ab Schritt 3.
