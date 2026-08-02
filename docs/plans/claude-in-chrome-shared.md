# Plan: Ein Chrome-Profil für alle Claude-Accounts (`cic-shared`)

**Stand:** 2026-07-25 · **Status:** umgesetzt und live verifiziert · **Scope:** lokales Werkzeug, kein WhisperM8-Code · **Verwandt:** [claude-account-switcher.md](claude-account-switcher.md)

**Abnahme (2026-07-25):** Echte Claude-Code-Session mit Account `ai@heartbeat-consulting.com` hat über das Chrome-Profil 21 gearbeitet, dessen claude.ai-Login `admin@360Web-manager.com` ist — zwei verschiedene Accounts, über die Bridge unmöglich.

Live gegen den echten Browser verifiziert: `tabs_context_mcp`, `tabs_create_mcp`, `tabs_close_mcp`, `navigate`, `get_page_text`, `read_page`, `find`, `computer` (Screenshot), `javascript_tool`, `browser_batch`, `read_console_messages`, `read_network_requests`, `resize_window`, `shortcuts_list` — 14 von 19. Nicht einzeln getestet: `form_input`, `gif_creator`, `upload_image`, `file_upload`, `shortcuts_execute` (identischer Pfad, aber ungeprüft).

Ohne Tool-Nennung und ohne `--allowedTools` verifiziert: Prompt „Schau im Browser nach, welche Seite offen ist" führte auf Modell `haiku` selbstständig zum korrekten Ergebnis.

**Dabei gefundener und behobener Bug:** Die Extension liefert Bilder im Anthropic-API-Format (`{type:"image",source:{type:"base64",media_type,data}}`), MCP erwartet sie flach (`{type:"image",data,mimeType}`). Ohne Umschreibung kam der Screenshot als **leerer** Bild-Block an — mit `isError:false`, also stiller Datenverlust. `normalizeBlock()` in `cic-local-mcp.mjs` konvertiert jetzt (auch `audio`, und URL-Quellen werden als Text gemeldet statt zu verschwinden).

## Ziel

Claude-in-Chrome mit **allen** Claude-Accounts (`ccs`-Profilen) aus **einem einzigen Chrome-Profil** nutzen — statt pro Account ein eigenes Chrome-Profil mit eigener Extension-Installation und eigener Autorisierung zu pflegen.

Ausgangslage: 7 Accounts (`main`, `Claude2`, `PowerUser`, `PowerUser2`, `RankM8`, `ai`, `ai2`), die Extension war in 5 Chrome-Profilen installiert. Profil-Wechsel bei jedem Account-Wechsel ist der Kernschmerz.

## Ursache (verifiziert)

Reverse Engineering von claude v2.1.220 und Extension v1.0.81 (macOS, 2026-07-25):

**Es gibt zwei Transportwege zwischen Claude Code und der Extension — die Extension startet beide parallel.**

| | Cloud-Bridge | Native Messaging |
|---|---|---|
| Endpunkt | `wss://bridge.claudeusercontent.com` | `/tmp/claude-mcp-browser-bridge-<UNIX-USER>/<pid>.sock` |
| Identität | `account_uuid` aus `oauthAccount` + OAuth-Token | **keine** — Pfad hängt nur am Unix-Username |
| Mehrere Clients | über Geräte-Registry (`pairedDeviceId`) | Native Host multiplext beliebig viele MCP-Clients |
| Extension-Seite | `O()` im Service Worker | `oe()` im Service Worker |

Der **Account-Zwang kommt allein von der Bridge**. Belege:

- `createChromeContext` setzt `bridgeConfig` **hardcoded** immer; die Transportwahl lautet `bridgeConfig ? Bridge : SocketPool`. Der Socket-Weg ist im Claude-Code-Pfad damit toter Code.
- `bridgeConfig.getUserId` löst `oauthAccount.accountUuid` bzw. das Token via `/oauth/…` auf; bei Abweichung feuert `tengu_chrome_bridge_account_mismatch`.
- Original-Fehlertext der CLI: *„…and that you are logged into claude.ai with the same account as Claude Code."*
- Der Native-Messaging-Handler der Extension ruft denselben Tool-Dispatcher wie die Bridge, nur mit `source:"native-messaging"` — **ohne jede Account-Prüfung**.
- Der Native Host (`claude --chrome-native-host`) hält `mcpClients` als Map und broadcastet Antworten an alle. Socket-Verzeichnis: `/tmp/claude-mcp-browser-bridge-${os.userInfo().username}`.

**Warum ein Chrome-Profil genau einen Account bedeutet** (präzisiert, Extension-Bundle v1.0.81): Nicht der claude.ai-Cookie ist die Bindung, sondern ein **extension-eigener OAuth-Token-Satz** in `chrome.storage.local` — `accessToken`, `refreshToken`, `tokenExpiry`, `accountUuid` sind **skalare** Keys, und es gibt genau eine globale WebSocket-Variable (`eN`) und im ganzen Bundle nur eine `new WebSocket(...)`-Stelle. Die Socket-URL lautet `/chrome/<accountUuid>`, gesendet wird `{type:"connect",client_type:"chrome-extension",device_id,oauth_token}`. Der claude.ai-Cookie ermöglicht lediglich den Authorize-Flow (`https://claude.ai/oauth/authorize`, PKCE, Scopes `user:profile user:inference user:chat`). Bei Accountwechsel werden die alten Keys bereinigt und die Verbindung neu aufgebaut — **mehrere Bridge-Accounts pro Chrome-Profil sind nicht implementiert**, nicht bloß nicht vorgesehen.

Die `bridgeDeviceId` ist dagegen **lokal** erzeugt (`crypto.randomUUID()`) und in `chrome.storage.local` persistiert, also stabil pro Chrome-Profil und **account-unabhängig**; Logout löscht sie nicht. Die unterschiedlichen `pairedDeviceId`-Werte in den Profil-`.claude.json` stammen also von verschiedenen Chrome-Profilen, nicht von einer accountweisen Neuvergabe.

Deshalb N Profile bei N Accounts — **über die Bridge**. Über Native Messaging entfällt das vollständig: dieser Pfad liest und sendet weder Token noch `accountUuid` noch Cookies.

### Verworfen: lokale Bridge

Die CLI kennt `LOCAL_BRIDGE`/`USE_LOCAL_OAUTH` → `ws://localhost:8765` samt festem `devUserId:"dev_user_local"`, was den Account-Scope elegant umgehen würde. **Nicht nutzbar:** Im ausgelieferten Extension-Bundle ist `localBridge:!1` fest eingebaut, es gibt keinen Storage-Key, keine Policy und keinen Options-Schalter dafür. Nur ein gepatchtes Bundle würde den lokalen Socket wählen — kein tragfähiger Weg.

## Stand der Welt (recherchiert 2026-07-25)

**Offiziell ist Multi-Account nicht unterstützt.** Die Doku ([code.claude.com/docs/en/chrome](https://code.claude.com/docs/en/chrome)) verlangt Anmeldung via `/login`; API-Key und `claude setup-token` funktionieren ausdrücklich nicht, „because the browser extension can't authenticate with those credentials". Die [Admin-Controls](https://support.claude.com/en/articles/13065128-claude-in-chrome-admin-controls) führen `wss://bridge.claudeusercontent.com` in der Allowlist — die unterstützte Architektur hat also bewusst eine account-/org-gebundene Cloud-Komponente. Kein Wort zu mehreren Accounts oder Pairings. Die Doku bestätigt allerdings ausdrücklich, dass das Manifest nach einem Wechsel von Config-Verzeichnissen umgeschrieben wird — genau der `CLAUDE_CONFIG_DIR`-Effekt.

| Issue | Inhalt | Status |
|---|---|---|
| [#69208](https://github.com/anthropics/claude-code/issues/69208) | Account-Selector fehlt; Extension erbt Browser-Session; Workaround = separates Chrome-Profil | closed as duplicate, ohne Ziel-Issue |
| [#15125](https://github.com/anthropics/claude-code/issues/15125) | Gezielte Auswahl von Chrome-Instanz/-Profil gefordert (`--chrome-profile`) | **open**, keine PR |
| [#20341](https://github.com/anthropics/claude-code/issues/20341) | Desktop-/Code-Native-Host-Konflikt, manueller Manifest-Umbau als Workaround | closed not planned |
| [#41013](https://github.com/anthropics/claude-code/issues/41013) | 5 Chrome-Profile; ping/pong und Socket funktionieren, CLI verbindet dennoch nicht; kein Fallback vom Desktop- auf den Code-Hostnamen | closed as duplicate |
| [#40494](https://github.com/anthropics/claude-code/issues/40494) | Socket erreichbar, CLI verbindet nicht; Fehlertext verlangt denselben Account | closed not planned |

Der Host-Konflikt (#20341, #41013) und die Account-Bindung (#69208, #40494) sind also gemeldet, aber ungelöst — beides ist genau das, was `cic-shared` umgeht.

**Learnings aus Open Source:**

| Projekt | Ansatz | Was wir übernehmen / anders machen |
|---|---|---|
| [claude-in-chrome-local-mcp](https://github.com/claude-in-chrome-local-mcp/claude-in-chrome-local-mcp) | **Dieselbe Architektur**: MCP-Server → Unix-Socket → offizieller `chrome-native-host`; wirbt mit „multiple simultaneous client connections" | ✅ Unabhängige Bestätigung des Ansatzes. ❌ Gegen v2.1.42 reverse-engineered (wir sind auf 2.1.220), kein Multi-Claude-Account-Ziel, und **keine Antwort-Serialisierung** — den Broadcast-ohne-Request-ID-Fallstrick lösen wir selbst (siehe unten) |
| [chrome-discord-bridge](https://github.com/p00ya/chrome-discord-bridge) | Minimales stdio↔Unix-Socket-Bridge-Muster | Referenz für das Framing, nicht Claude-spezifisch |
| 1Password `BrowserSupport` | Dünner Broker, mehrere `allowed_origins` | Bestätigt: Transport-Multiplexing ist normal. Aber `allowed_origins` adressiert Extension-**IDs**, nicht Profile oder Accounts — löst Account-Multipairing nicht |

Chrome-seitig ist die Lage klar ([Native-Messaging-Doku](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)): mehrere Hosts unter verschiedenen Namen sind erlaubt, aber die Extension wählt den Namen **fest im Code** — eigene Zusatz-Manifeste helfen nicht. `connectNative()` startet **pro Port einen eigenen Prozess**, es gibt keinen geteilten Singleton. Chrome übergibt dem Host die Extension-Origin, aber **keine Profil-ID** — deshalb ist ein Router, der nach Chrome-Profil unterscheidet, ohne Application-Layer-Handshake nicht baubar. Genau darum setzt `cic-shared` auf ein Profil statt auf Routing.

## Architektur

```
Claude Code (Profil 1..7)          ← jedes Profil, jeder Account
   │  stdio, MCP (JSON-RPC)
   ▼
cic-local-mcp.mjs                  ← ein Prozess pro Session, 19 Tools
   │  Unix-Socket, 4-Byte-LE-Länge + JSON
   │  {"method":"execute_tool","params":{client_id,tool,args}}
   ▼
claude --chrome-native-host        ← von Chrome gespawnt, multiplext alle Sessions
   │  Chrome Native Messaging
   ▼
Claude-Extension in EINEM Chrome-Profil
```

Der eingebaute Cloud-Weg wird pro Profil über `claudeInChromeDefaultEnabled:false` abgeschaltet, damit es die Tools nicht doppelt gibt.

**Servername `chrome` → Tools heißen `mcp__chrome__navigate` usw.** Der naheliegende Name `claude-in-chrome` (der die alten Tool-Namen erhalten hätte) ist **nicht nutzbar**: Claude Code führt ihn als reservierten Namen und ignoriert den Eintrag mit der Warnung `"claude-in-chrome" is a reserved MCP server name and was not loaded` — sichtbar nur in den MCP-Diagnostics von `claude mcp list`, die Session hat einfach keine Chrome-Tools. Verifiziert an v2.1.220. Folge: Alles, was die alten Tool-Namen erwartet (u. a. der Anthropic-Skill `claude-in-chrome`), greift nicht mehr.

### Protokoll-Fallstrick: Broadcast ohne Request-ID

Der Native Host schickt **jede** Antwort an **alle** verbundenen MCP-Clients, und die Antwort der Extension (`{type:"tool_response",result|error}`) enthält **keine** Korrelations-ID — der `clientId` wird nicht zurückgeschrieben. Anthropics eigener Socket-Transport hat deshalb nur einen einzigen `responseCallback`.

Gegenmaßnahmen in `cic-local-mcp.mjs`:

1. **Prozessübergreifende Sperre** (`cic-local-mcp.lock` im Socket-Verzeichnis, mit Stale-Erkennung über PID und Alter): nie mehr als ein Tool-Call gleichzeitig offen — über alle Sessions hinweg.
2. **Broadcast-Filter**: Antworten ohne eigenen offenen Call werden verworfen.
3. **Stale-Zähler**: Läuft ein Call ins Timeout, wird die eine nachträglich eintreffende Antwort gezielt verworfen, statt dem nächsten Call zugeordnet zu werden.

End-to-End getestet mit echtem Native Host in der Mitte, inklusive zwei parallelen Sessions — Zuordnung korrekt, Fehler- und Array-Content werden richtig durchgereicht.

## Einschränkungen (bewusst in Kauf genommen)

| Punkt | Auswirkung |
|---|---|
| **Permission-Prompts** | Über Native Messaging gibt es **kein** `skip_all_permission_checks`. Der Handler nutzt `permissionManager: new WN(()=>!1,{})` — Skip ist fest `false`, und `permission_mode`/`allowed_domains` werden nur im Bridge-Pfad ausgewertet. Freigaben kommen als 600×600-Popup (`sidepanel.html?…mcpPermissionOnly=true`), Timeout 30 s = Ablehnung. Bereits erteilte Site-Freigaben greifen weiter, es ist also einmal pro Domain. |
| **3 Tools fehlen** | `list_connected_browsers`, `select_browser`, `switch_browser` sind Bridge-Features (Geräte-Registry pro Account). Lokal gibt es genau einen Browser; die Tools werden nicht angeboten und mit klarer Meldung abgewiesen. |
| **Nur ein Chrome-Profil gleichzeitig** | Laufen mehrere Chrome-Profile mit der Extension, spawnt Chrome pro Extension-Instanz einen eigenen Native Host → mehrere Sockets, willkürliche Zuordnung (der Server nimmt den neuesten). Extension in den übrigen Profilen deaktivieren. |
| **Claude-Desktop-Host** | Die Extension probiert `com.anthropic.claude_browser_extension` (Desktop) **zuerst** und nimmt den ersten Host, der auf `ping` antwortet — beide antworten. Deshalb wird das Desktop-Manifest beiseitegeschoben (`.disabled-by-cic-shared`). Die Claude-**Desktop-App** verliert damit ihre Chrome-Anbindung. |
| **Keine Serialisierung in der Extension** | Die Extension hat keine transportübergreifende Tool-Queue (`ID`/`AD` sind nur Request-Register pro Tab). Die Sperre oben deckt alle Claude-Code-Sessions ab; da der Cloud-Weg abgeschaltet ist, bleibt kein zweiter Erzeuger übrig. |
| **Geteilter Browserzustand** | Alle 7 Accounts steuern dasselbe Chrome-Profil und damit dieselben Cookies und eingeloggten Sitzungen. Das ist der Zweck der Übung, aber es hebt die Trennung auf, die 7 Profile nebenbei mitbrachten: eine Session in Account `ai2` kann auf alles zugreifen, was in diesem Profil eingeloggt ist. Sensible Logins gehören in ein Chrome-Profil **ohne** die Extension. |
| **Nicht unterstützt** | Der Weg ist reverse-engineered. Ein Claude-Code- oder Extension-Update kann Protokoll, Tool-Schemas oder die Host-Auswahl ändern. `cic-shared status` zeigt Abweichungen; `uninstall` stellt den offiziellen Weg jederzeit wieder her. |

## Betrieb

```bash
cic-shared install        # alle Profile umstellen, Manifeste setzen, Desktop-Host beiseite
cic-shared status         # Wrapper, Manifeste, laufender Socket, Zustand pro Profil
cic-shared refresh-tools  # Tool-Katalog neu vom eingebauten MCP-Server dumpen
cic-shared uninstall      # vollständig zurück auf den Cloud-Weg
```

### Damit es „nativ" wirkt (ohne Extra-Prompt)

Mit `claudeInChromeDefaultEnabled:false` entfällt auch der **Systemprompt**, den Claude Code sonst injiziert (`# Claude in Chrome browser automation` — Tab-Handling, Dialog-Verbot, Abbruchregeln). Ohne Ersatz kennt das Modell die Betriebsregeln nicht. Ersetzt durch drei Bausteine:

| Baustein | Ort | Wirkung |
|---|---|---|
| Namens-Hinweis | globale `CLAUDE.md` | immer geladen; sagt nur, dass die Tools `mcp__chrome__*` heißen und wo die Regeln stehen |
| Betriebsregeln | Skill `chrome` (`~/.claude/skills/chrome/`) | lädt nur bei Browser-Aufgaben — adaptiert aus Anthropics Original-Systemprompt, plus die Besonderheiten dieses Wegs |
| Freigabe | `permissions.allow: ["mcp__chrome"]` | keine Rückfrage pro Tool. Die eigentliche Schutzschicht bleibt Chrome selbst (Popup pro Domain) |

Bewusst zweistufig: Die vollständigen Regeln in der `CLAUDE.md` würden in **jeder** Session Tokens kosten, auch ohne Browser-Bezug.

Nach `install` **Chrome vollständig neu starten** — der Service Worker wählt den Native Host nur beim Start (`oe()` im Top-Level-Code und bei `onStartup`). Die offizielle Reconnect-URL `https://clau.de/chrome/reconnect` ist dafür **nicht** brauchbar: sie ruft `chrome.permissions.remove({permissions:["nativeMessaging"]})`, was bei einer Pflicht-Permission scheitert, sodass der alte Port bestehen bleibt.

### Robustheitsdetails

- **Versionsunabhängiger Wrapper:** Claude Code generiert `chrome-native-host` mit hartem Versionspfad (`…/versions/2.1.220`). `cic-shared` schreibt stattdessen einen Wrapper auf `~/.local/bin/claude`, der Updates übersteht.
- **Manifest-Rückschreiben:** Solange `claudeInChromeDefaultEnabled:false` gilt, ruft Claude Code `installChromeNativeHostManifest` nicht auf und überschreibt das Manifest nicht. Wird der Cloud-Weg irgendwo reaktiviert, zeigt `cic-shared status` den fremden Pfad an — dann `install` wiederholen.
- **Alle Chromium-Browser:** Manifeste werden in Chrome, Chrome Beta/Dev/Canary, Edge, Brave, Arc und Vivaldi geschrieben, sofern vorhanden.
- **Backups:** `.claude.json.bak-cic-shared` pro Profil, `…json.disabled-by-cic-shared` für den Desktop-Host.

## Edge Cases im Betrieb

| Fall | Symptom | Umgang |
|---|---|---|
| **Nicht getrusteter Workspace** | Claude Code meldet „Ignoring N permissions.allow entries: this workspace has not been trusted" → `mcp__chrome` greift nicht, es wird pro Tool gefragt | Einmal interaktiv im Verzeichnis starten und den Trust-Dialog bestätigen. Betrifft jedes Profil separat (`projects[<pfad>].hasTrustDialogAccepted`). |
| **Zweites Chrome-Profil mit Extension** | Zwei Sockets, Tool-Calls landen im falschen Browser | Extension in allen Profilen außer dem gewählten deaktivieren. `cic-shared status` listet aktive Sockets. |
| **Native Host beendet** | „nicht über den lokalen Native-Messaging-Weg verbunden" | Chrome vollständig neu starten. Der Host lebt nur, solange die Extension den Port hält; der Service Worker verbindet nur beim Start. |
| **Claude Code aktiviert CFC wieder** | `status` zeigt einen fremden Manifest-Pfad | `cic-shared install` wiederholen. Tritt auf, wenn irgendein Profil `claudeInChromeDefaultEnabled` verliert. |
| **Claude-Code-Update ändert Tools** | Tool fehlt oder Schema passt nicht | `cic-shared refresh-tools`, dann Sessions neu starten. |
| **Extension-Update ändert Formate** | Inhalte kommen leer an, oft **ohne** Fehler | Genau die Klasse des Screenshot-Bugs oben. Bei leeren Ergebnissen die Rohantwort am Socket prüfen, nicht dem `isError:false` vertrauen. |
| **Modaler Dialog offen** | Extension antwortet auf nichts mehr | User muss den Dialog im Browser manuell schließen. Deshalb im Skill das Dialog-Verbot. |
| **Langer Call blockiert andere** | Zweite Session wartet | Folge der globalen Serialisierung. `gif_creator` hat 180 s Timeout, `navigate`/`browser_batch` 90 s, sonst 60 s. |
| **Tab-IDs veraltet** | „No tab available" / „tab doesn't exist" | `tabs_context_mcp` neu aufrufen. IDs sind nicht sessionübergreifend gültig. |
| **Freigabe-Popup übersehen** | Call läuft 30 s und endet mit „Permission denied by user" | Im Chrome-Fenster nach dem Popup sehen; danach ist die Domain gespeichert. |

## Dateien

| Pfad | Zweck |
|---|---|
| `~/.claude-profiles/chrome-shared/cic-shared` | Verwaltung (install/status/uninstall) |
| `~/.claude-profiles/chrome-shared/cic-local-mcp.mjs` | MCP-Server, Node ohne Dependencies |
| `~/.claude-profiles/chrome-shared/chrome-tools.json` | Tool-Katalog, aus dem echten MCP-Server per `tools/list` gedumpt |
| `~/.claude-profiles/chrome-shared/chrome-native-host` | versionsunabhängiger Native-Host-Wrapper |

Der Tool-Katalog ist ein Snapshot. Nach Claude-Code-Updates, die Chrome-Tools ändern, neu dumpen (`--claude-in-chrome-mcp` starten, `tools/list` abfragen).
