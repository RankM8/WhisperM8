# claudecodeui

## Scope und Projektüberblick

Analysiert wurde ausschließlich der lokale Klon. Der Fokus liegt auf Claude-Sessions: Auffinden lokaler Transkripte sowie Setzen und Wechseln von UI- und Provider-ID. Forking, allgemeine PTY-Robustheit und die übrigen Provider sind bewusst ausgeklammert.

claudecodeui heißt im Paket inzwischen **CloudCLI** und ist eine React/Vite-Web-UI mit Node/Express-Backend und optionalem Electron-Host (`package.json:2-7`, `package.json:30-48`). Sessions werden in SQLite (`better-sqlite3`) indiziert, lokale Dateien mit Chokidar beobachtet und Claude über das Agent SDK ausgeführt (`package.json:136-160`). Das ist **nicht** WhisperM8s Zielarchitektur: CloudCLI besitzt eine eigene Chat-UI und SDK-Runtime; WhisperM8 muss Host der echten Claude-Code-CLI im PTY bleiben.

Relevante Stellen:

| Pfad | Relevanz |
|---|---|
| `server/modules/providers/list/claude/claude-session-synchronizer.provider.ts:24-157` | Scan von `~/.claude/projects`, JSONL-Metadaten und Ausschluss von Subagent-Dateien |
| `server/modules/providers/services/sessions-watcher.service.ts:15-32,224-278` | Initialer Scan sowie laufende Add/Change-Beobachtung |
| `server/modules/database/schema.ts:99-115` | Trennung von stabiler App-ID und nativer Provider-ID |
| `server/modules/database/repositories/sessions.db.ts:61-212` | Disk-Upsert, vorab angelegte UI-Session und transaktionales ID-Mapping |
| `server/modules/websocket/services/chat-session-writer.service.ts:30-138` | Abfangen der SDK-ID; Provider-ID bleibt vor der UI verborgen |
| `server/claude-sdk.js:229-231,460-490,628-667` | Resume mit nativer ID und Erfassung der ersten `session_id` des SDK |
| `src/hooks/useProjectsState.ts:487-554,739-767,786-873` | Optimistische UI-Auswahl, Alias-Normalisierung und Session-Wechsel |

## 1. Lokale Session-Discovery

Beim Serverstart läuft zuerst ein providerweiter Abgleich; der Scan-Cursor wird nur weitergesetzt, wenn kein Provider-Scan fehlschlägt (`server/modules/providers/services/session-synchronizer.service.ts:17-51`, `server/modules/providers/services/sessions-watcher.service.ts:254-264`). Für Claude wird `~/.claude/projects` rekursiv nach `.jsonl` durchsucht (`server/modules/providers/list/claude/claude-session-synchronizer.provider.ts:43-52`). Der Parser liest die erste passende JSONL-Zeile und verlangt `sessionId` plus `cwd`; daraus entstehen native Claude-ID und Projektzuordnung (`server/modules/providers/list/claude/claude-session-synchronizer.provider.ts:110-130`). Titel kommen zuerst aus `~/.claude/history.jsonl`, ersatzweise aus rückwärts gelesenen `ai-title`, `last-prompt` oder `custom-title`-Events (`server/modules/providers/list/claude/claude-session-synchronizer.provider.ts:47,148-155,159-199`).

Subagent-Transkripte unter einem Pfadsegment `subagents` werden ausdrücklich ignoriert. Sie wiederholen die Eltern-ID und würden sonst den `jsonl_path` der Hauptsession überschreiben (`server/modules/providers/list/claude/claude-session-synchronizer.provider.ts:28-40,54-58,84-90`). Das ist ein wichtiger Schutz vor falscher Session-Zuordnung.

Nach dem Start beobachtet Chokidar `~/.claude/projects`; `add` und `change` werden dateiweise synchronisiert (`server/modules/providers/services/sessions-watcher.service.ts:15-19,221-243`). Der Watcher pollt alle sechs Sekunden, ignoriert Initialereignisse und folgt keinen Symlinks (`server/modules/providers/services/sessions-watcher.service.ts:266-278`). Änderungen werden als kanonische `session_upserted`-Deltas mit der App-ID ausgesendet, nicht als komplette Projektliste (`server/modules/providers/services/sessions-watcher.service.ts:126-168,187-207`).

Persistenz und Wiederfinden erfolgen über SQLite. Eine extern entdeckte Session erhält zunächst für beide Spalten die native Claude-ID. Existiert bereits eine Zeile mit derselben `provider_session_id`, wird sie aktualisiert statt dupliziert (`server/modules/database/repositories/sessions.db.ts:61-143`). Für einen Neustart ist damit nicht der alte Prozess, sondern die DB-Zeile plus das Claude-JSONL maßgeblich.

Grenzen: Der inkrementelle Startscan filtert nach `birthtime`, nicht nach `mtime` (`server/shared/utils.ts:1123-1165`). Änderungen an bereits existierenden JSONLs während CloudCLI beendet war können daher beim nächsten inkrementellen Scan als Metadaten-Update ausbleiben. Außerdem ist der Claude-Pfad fest an `os.homedir()` gebunden und die Session-Tabelle enthält keine Account-/User-Spalte (`server/modules/providers/list/claude/claude-session-synchronizer.provider.ts:24-27`, `server/modules/database/schema.ts:99-115`); eine belastbare Multi-Account-Isolation ist in diesem Pfad nicht auffindbar.

## 2. Wann UI-ID und SDK-ID gesetzt oder gewechselt werden

CloudCLI modelliert zwei Identitäten:

- `session_id`: stabile, app-seitige Thread-ID für URL, UI-State, WebSocket und Run-Registry.
- `provider_session_id`: native Claude-ID aus SDK und JSONL; nur für Resume und Transkriptzugriff.

Diese Trennung ist im Schema ausdrücklich dokumentiert (`server/modules/database/schema.ts:100-108`). Der Ablauf ist:

1. **Extern entdeckte Session:** Beim reinen Disk-Import sind beide IDs identisch, weil noch keine app-seitige Identität existiert (`server/modules/database/repositories/sessions.db.ts:118-143`).
2. **In der UI gestartete Session:** Vor dem ersten Send erzeugt `POST /api/providers/sessions` eine UUID und persistiert sie mit `provider_session_id = NULL` (`server/modules/providers/provider.routes.ts:525-540`, `server/modules/providers/services/sessions.service.ts:120-139`, `server/modules/database/repositories/sessions.db.ts:146-165`). Die UI legt diese ID sofort optimistisch in Projektliste und Auswahl ab (`src/hooks/useProjectsState.ts:487-554`) und navigiert zu `/session/<app-id>` (`src/components/chat/view/ChatInterface.tsx:137-144`).
3. **Erste SDK-Antwort:** Der Claude-Adapter übernimmt die erste `message.session_id`, registriert damit den laufenden SDK-Query und ruft `writer.setSessionId(...)` auf (`server/claude-sdk.js:628-650`).
4. **Persistentes Mapping:** Der Gateway-Writer interpretiert sowohl `setSessionId` als auch `session_created` als native Provider-ID. Er speichert sie, verschluckt aber `session_created`; die UI sieht keinen ID-Handoff (`server/modules/websocket/services/chat-session-writer.service.ts:30-44,81-94,123-138`). Die Run-Registry schreibt anschließend App-ID → Provider-ID in die DB (`server/modules/websocket/services/chat-run-registry.service.ts:163-197,236-247`).
5. **Race-Auflösung:** Hat der Datei-Watcher die JSONL bereits als eigene, native-ID-basierte Zeile angelegt, löscht `assignProviderSessionId` diese Dublette und übernimmt Pfad und Namen transaktional in die App-Zeile (`server/modules/database/repositories/sessions.db.ts:168-212`). Die Sidebar kann dadurch nicht beide Zeilen gleichzeitig beobachten.
6. **Späteres Resume:** Der Client sendet weiterhin nur die App-ID. Das Backend lädt daraus die native ID und reicht ausschließlich diese als `sessionId`/`resume` an die Runtime (`server/modules/websocket/services/chat-websocket.service.ts:136-205`); der SDK-Adapter setzt daraus `sdkOptions.resume` (`server/claude-sdk.js:229-231`).

Im Normalpfad **wechselt die UI-ID nie**. Es gibt lediglich einen defensiven Alias-Fallback: Falls ein älterer oder durch ein Race entstandener UI-Eintrag noch unter der Provider-ID ausgewählt beziehungsweise geroutet ist, normalisiert ein `session_upserted` ihn auf die App-ID und ersetzt die URL (`src/hooks/useProjectsState.ts:739-767`). Die normale aktive Session wechselt dagegen nur durch UI-Auswahl: `selectedSession` wird gesetzt und die URL auf deren App-ID navigiert (`src/hooks/useProjectsState.ts:849-873`).

Eine getrennte Fork-Identität oder Claude-Fork-Option ist im untersuchten Claude-Pfad nicht auffindbar. Es gibt nur Start-neu und Resume; daraus lässt sich kein belastbares Fork-Muster ableiten.

## Direkter Vergleich zu WhisperM8

**Besser als eine prozess- oder PTY-zentrierte Identität:** Die App-ID bleibt über Prozessende, Reconnect und Neustart stabil. Ein spät eintreffender Hook oder eine JSONL-Datei kann die UI nicht versehentlich auf einen anderen Thread umhängen. Das transaktionale Alias-Merge schließt außerdem das typische Rennen „JSONL zuerst, Runtime-ID danach“.

**Nicht direkt übernehmbar:** CloudCLI erreicht dies in einer eigenen Chat-UI vor einer Agent-SDK-Runtime. Genau dieser Teil wäre für WhisperM8 schlechter und verletzt den harten Constraint. WhisperM8 sollte dieselbe Identitätstrennung im Wrapper um die echte CLI abbilden: UI-/Workspace-Thread bleibt kanonisch; `--session-id`, `--resume` und später gegebenenfalls `--fork-session` erhalten ausschließlich die gebundene Claude-ID.

**Schwächer für WhisperM8s Anforderungen:** Es gibt hier keinen Beleg für Fork/Resume als getrennte Übergänge, keine PTY-Wiederherstellung und keine Multi-Account-Dimension in der Session-Zuordnung. Diese Lücken dürfen nicht aus der CloudCLI-Implementierung übernommen werden.

## Priorisierte übertragbare Muster

1. **P0 – Unveränderliche Wrapper-ID mit explizitem CLI-Binding.** Persistiere je WhisperM8-Thread mindestens `uiThreadID`, `claudeSessionID`, Workspace und Account-Kontext. UI-Auswahl, PTY-Zuordnung und Events bleiben auf `uiThreadID`; nur der Command Builder verwendet die Claude-ID für `--session-id`/`--resume`. Ein Fork muss eine neue Wrapper-ID **und** eine neue Claude-Ziel-ID erzeugen, nie die Parent-Bindung überschreiben.
2. **P0 – Transaktionale Reconciliation statt ID-Handoff.** Wenn Hook, CLI-Ausgabe oder JSONL die native ID zuerst liefert, atomar an den bestehenden Wrapper-Thread binden. Eine eventuell schon disk-entdeckte Dublette nach `claudeSessionID` zusammenführen; niemals den aktuell ausgewählten Thread oder dessen URL/Store-Key umbenennen.
3. **P1 – Startscan plus laufender JSONL-Watcher mit Subagent-Filter.** `~/.claude/projects` read-only initial und fortlaufend indizieren, `sessionId` und `cwd` aus JSONL validieren und `subagents/` nicht als Top-Level-Sessions aufnehmen. Für WhisperM8 sollte der Neustartscan nach `mtime` oder eigener Dateisignatur arbeiten, damit Offline-Änderungen nicht durch CloudCLIs `birthtime`-Grenze fallen.
