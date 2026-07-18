---
status: abgeschlossen
updated: 2026-07-18
description: Security- und Secrets-Audit der neuen GPT-Backend-Integration mit Proxy-Identität, lokaler Authentisierung, Payload-Logging und Deaktivierungs-Lifecycle.
---

# Runde 3: GPT-Backend — Security, Secrets und lokale Vertrauensgrenzen

## Umfang und Quellenstand

Statische Prüfung der neuen Integration aus `30c4661..feac0c0`, insbesondere
`ClaudeCodeProxyManager`, `ClaudeGPTMixRouter`, `AgentCommandBuilder`,
`GPTBackendSettingsPage`, `AppPreferences`, `LoginShellEnvironment` und
`KeychainManager`. Kein Build und keine Tests. Zusätzlich wurde die auf dem Audit-Rechner
installierte, von WhisperM8 erwartete Upstream-Implementierung
`claude-code-proxy 0.1.21` gegen den Quellstand
[`raine/claude-code-proxy@52c5501`](https://github.com/raine/claude-code-proxy/tree/52c5501ad909d614c594d0b81aac6714c2d4c390)
geprüft; Upstream-Belege sind deshalb mit Repository, Commit, Datei und Zeile angegeben.

Angreifermodell: ein fremder lokaler Prozess, insbesondere ein Prozess eines anderen
macOS-Accounts, der die Keychain-Credentials des angemeldeten WhisperM8-Users nicht selbst
lesen darf, aber Loopback-TCP erreichen und unprivilegierte Ports belegen kann. Bei
same-UID-Prozessen ist die Isolation grundsätzlich schwächer; relevant bleiben hier dennoch
zusätzliche Capability-Grenzen wie Keychain-Zugriff und eine von WhisperM8 gestartete,
credential-bearing Netzwerk-Bridge.

## Ergebnis

- kritisch: 0
- hoch: 2
- mittel: 2
- niedrig: 0

Die Loopback-Bindung ist für selbst gestartete Prozesse korrekt erzwungen, aber Loopback ist
keine Client-Authentisierung. Der schwerste Befund ist ein Identitäts-Bypass: Ein fremder
Listener kann die konstante `/healthz`-Antwort imitieren und wird anschließend als GPT-
Backend akzeptiert. Unabhängig davon stellen sowohl Mix-Router als auch Upstream-Proxy die
ChatGPT-OAuth-Capability ohne Client-Token allen lokalen Prozessen zur Verfügung.

## G01 — Fremder Listener kann `/healthz` imitieren und den vollständigen GPT-Datenstrom übernehmen

**Schweregrad:** hoch

### Beleg

- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-270`: Ist der Port
  erreichbar, wird kein eigener Prozess gestartet. Nach einem Start gilt allein eine
  erfolgreiche Reachability-Probe als Übernahmebeleg.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`: Die komplette
  „Signatur“ besteht aus `GET /healthz`, Status 200, Content-Type `application/json` und
  dem öffentlichen konstanten JSON-Feld `{ "ok": true }`. Es gibt weder Challenge-Nonce
  noch PID-/Binary-/Prozess-Ancestry-Bindung.
- `raine/claude-code-proxy@52c5501:src/server.rs:102-127`: Der echte Proxy implementiert
  genau die öffentlich reproduzierbare Route; `healthz()` liefert konstant
  `{ "ok": true }`.
- `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:85-93` und
  `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`: Der Router verwendet
  anschließend den konfigurierten Port als GPT-Upstream und überträgt den vollständigen
  Request-Body dorthin.
- `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:317-323`: Claude-OAuth-/API-
  Header werden vor dem GPT-Upstream richtigerweise entfernt. Ein Port-Hijacker erhält
  daher nach aktuellem Code Chat-/Tool-Inhalte, aber nicht den Claude-Auth-Header.

### Konkretes Szenario

Ein fremder lokaler Prozess bindet vor dem ersten GPT-Start den vorhersehbaren Port 18765
und beantwortet `/healthz` exakt wie oben. Der User startet danach einen GPT-gestempelten
Claude-Chat. `ensureRunning` akzeptiert den fremden Listener, startet keinen echten Proxy
und startet den Mix-Router trotzdem. Jeder GPT-Request mit Systemprompt, Gesprächsverlauf,
Tooldefinitionen, Toolresultaten und eingeblendeten Codeinhalten geht an den Angreifer. Er
kann die Inhalte ausleiten und beliebige syntaktisch gültige Modellantworten zurückgeben;
diese erscheinen in der echten Claude-Code-Session als GPT-Ergebnis. Das ist sowohl
Vertraulichkeitsbruch als auch eine Antwort-/Tool-Steuerungsgrenze. Derselbe Race ist auch
möglich, wenn der fremde Prozess zwischen erster Negativprobe und dem Bind des gestarteten
Proxy-Prozesses den Port gewinnt.

### Fix-Skizze

Einen bereits belegten Backend-Port standardmäßig als Konflikt behandeln und **fail closed**
statt einen fremden Prozess automatisch zu übernehmen. Externe Proxy-Übernahme nur als
separates, explizites Feature mit starker Authentisierung anbieten. Für den selbst gestarteten
Pfad eine echte Ownership-Garantie einführen, bevorzugt durch vom Parent vorgebundenen und
an das Kind übergebenen Socket; alternativ durch einen pro Start zufälligen Challenge-/Client-
Token, den nur der erwartete Child-Prozess besitzt und den die Health-Probe nachweisen muss.
Zusätzlich vor Router-Start prüfen, dass der gestartete Handle noch läuft; ein bloß passender
HTTP-Body darf nie Prozessidentität ersetzen. Regressionstest: Fake-Listener mit echter
`/healthz`-Antwort muss zum Abbruch führen und darf keinen Router-Start auslösen.

**Konfidenz:** hoch

## G02 — Mix-Router und Codex-Proxy exportieren die Keychain-OAuth-Capability ohne lokale Client-Authentisierung

**Schweregrad:** hoch

### Beleg

- `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:127-134`: Der Mix-Router bindet
  explizit an `127.0.0.1`; das verhindert LAN-Zugriff, identifiziert aber keinen lokalen
  Client.
- `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403-423`: Jede angenommene
  TCP-Verbindung wird ohne Peer-UID/PID, Launch-Nonce oder Tokenprüfung als
  `ClientConnection` gestartet.
- `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:534-575`: Jeder parsebare Request
  wird anhand des vom Client gelieferten `model` zum Upstream weitergereicht.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:237-249`: Auch der eigentliche
  Proxy wird als normaler unauthentisierter Loopback-HTTP-Dienst gestartet; gesetzt werden
  Bind-Adresse, Port und `--no-monitor`, aber kein Client-Credential.
- `raine/claude-code-proxy@52c5501:src/server.rs:102-127`: Die `/v1/messages`- und
  `/v1/messages/count_tokens`-Routen besitzen keine Auth-Middleware.
- `raine/claude-code-proxy@52c5501:src/providers/codex/auth/token_store.rs:6-7,49-67`:
  Unter macOS lädt der Proxy den Codex-/ChatGPT-OAuth-Satz aus seinem eigenen Keychain-
  Service `claude-code-proxy.codex`.
- `raine/claude-code-proxy@52c5501:src/providers/codex/client.rs:95-113`: Aus dem geladenen
  `access`-Token baut der Proxy selbst den Upstream-Header `Authorization: Bearer ...`.
  Der aufrufende lokale Client muss dieses Secret gerade nicht kennen.

### Konkretes Szenario

WhisperM8 startet Proxy und Router unter dem eingeloggten User. Ein Prozess eines anderen
lokalen macOS-Accounts sendet danach direkt an `127.0.0.1:18765/v1/messages` oder über den
Router-Port einen gültigen Anthropic-Messages-Body mit einem GPT-Modell. Der Proxy liest die
OAuth-Tokens aus der Keychain des WhisperM8-Users und führt die Anfrage unter dessen
ChatGPT-Abo aus; der fremde Prozess liest die komplette Modellantwort über seinen eigenen
Socket. Er hat damit eine credential-backed Capability über eine Account-/Keychain-Grenze
hinweg erhalten, ohne das Token selbst auslesen zu können. Das ist kein bloßes
Rate-Limit-Thema, sondern ein lokaler Authentisierungs-Bypass für den bezahlten Account.

### Fix-Skizze

Der Upstream-Proxy braucht eine verpflichtende lokale Client-Authentisierung, zum Beispiel
einen von WhisperM8 pro Proxy-Start zufällig erzeugten Bearer-Token. Der Mix-Router muss ein
separates per-Launch-Credential von Claude Code verlangen, vor der Weiterleitung entfernen
und seinerseits authentisiert mit dem Backend sprechen. Das Credential darf nicht in argv,
UserDefaults, Settings-JSON oder Logs landen; Übergabe nur über einen geschützten
Prozesskanal beziehungsweise eine kurzlebige, restriktive Launch-Umgebung. Wo technisch
möglich zusätzlich Peer-Credentials/PID-Ancestry prüfen. Ohne Upstream-Support ist die
saubere Zwischenlösung: den Proxy nicht automatisch als credential-bearing Dauerlistener
starten und die Einschränkung sichtbar blockierend melden, statt Loopback als Sicherheits-
grenze zu behandeln.

**Konfidenz:** hoch

## G03 — Geerbtes `CCP_TRAFFIC_LOG` persistiert Chat-, Tool- und Antwortinhalte ohne WhisperM8-Hinweis

**Schweregrad:** mittel

### Beleg

- `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`: Der Helper kopiert das
  vollständige Parent-Environment und entfernt nur Claude-spezifische Variablen;
  `CCP_TRAFFIC_LOG`, `CCP_LOG_VERBOSE` und weitere Proxy-Diagnostikvariablen bleiben erhalten.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:175-177,237-249`: Genau dieses
  Environment wird für den langlebigen Proxy übernommen; der Manager überschreibt nur
  `CCP_BIND_ADDRESS`.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:545-552`: stdout und stderr
  des Proxy-Prozesses gehen auf `/dev/null`; ein Diagnosehinweis des Child-Prozesses ist in
  WhisperM8 deshalb nicht sichtbar.
- `raine/claude-code-proxy@52c5501:src/traffic.rs:32-50,68-103`: Bereits der geerbte Wert
  `CCP_TRAFFIC_LOG=1|true|yes` aktiviert persistente Traffic-Captures.
- `raine/claude-code-proxy@52c5501:src/server.rs:393-424`: Der Proxy schreibt dabei Header
  und den kompletten Anthropic-Request einschließlich Messages/System-/Tool-Inhalten.
- `raine/claude-code-proxy@52c5501:src/providers/codex/client.rs:951,981-1008` und
  `raine/claude-code-proxy@52c5501:src/traffic.rs:276-296`: Übersetzter Upstream-Request,
  SSE-Antwort und Up-/Downstream-Events werden ebenfalls persistiert. Credential-Felder
  werden redigiert, Prompt- und Tool-Inhalte aber nicht.

### Konkretes Szenario

Der User hat für eine frühere Proxy-Diagnose `CCP_TRAFFIC_LOG=1` in der Shell gesetzt und
startet WhisperM8 aus derselben Shell, etwa über den normalen Entwicklungsstart. Später
arbeitet er in vertraulichen Agent-Chats. WhisperM8 übernimmt die Variable unbemerkt in den
von ihm gestarteten Proxy, dessen stdout/stderr verborgen sind. Vollständige Prompts,
Codeausschnitte, Toolaufrufe, Toolresultate und Modellantworten werden unter dem Proxy-
State-Verzeichnis dauerhaft abgelegt. Sie liegen damit zusätzlich zu den erwarteten Claude-
Transcripts in einer zweiten, in der GPT-Backend-UI nicht genannten Persistenz.

### Fix-Skizze

Für den verwalteten Proxy ein minimales, explizites Environment bauen und mindestens alle
`CCP_*`-Diagnostik-/Pfad-Overrides standardmäßig entfernen beziehungsweise
`CCP_TRAFFIC_LOG=0` erzwingen. Traffic-Capture nur über einen eigenen WhisperM8-Schalter mit
klarer Inhaltswarnung, sichtbarem Aktivstatus, Zielpfad, Ablaufzeit und „Jetzt löschen“-
Aktion erlauben. Ein Test muss mit `CCP_TRAFFIC_LOG=1` im Parent belegen, dass der verwaltete
Child-Prozess die Variable ohne explizites Opt-in nicht erhält. Dieser Befund ist die neue
GPT-spezifische Konsequenz der bereits in Runde 2 beschriebenen vollständigen Environment-
Vererbung.

**Konfidenz:** hoch

## G04 — Der Kill-Switch deaktiviert Launch-Routing, lässt die unauthentisierten Listener aber weiterlaufen

**Schweregrad:** mittel

### Beleg

- `WhisperM8/Support/AppPreferences.swift:257-262`: Die Preference ist ausdrücklich als
  zentraler Kill-Switch beschrieben.
- `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:27-32`: Die UI verspricht im
  Aus-Zustand, dass Claude-Chats sich wieder direkt mit Anthropic verbinden.
- `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-78`: Beim Umschalten auf
  `false` werden nur UI-Status und Agent-Definition bereinigt. Weder
  `stopIfSelfStarted()` noch `ClaudeGPTMixRouter.stop()` wird aufgerufen.
- `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:47-63`: Stoppen existiert
  ausschließlich als separate Button-Aktion.
- `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`: Selbst der Button
  stoppt den Router nur, wenn der Manager einen selbst gestarteten Proxy-Handle hält;
  bei einem als extern eingestuften Proxy bleibt der Router absichtlich aktiv.
- `WhisperM8/Views/AgentSessionDetailView.swift:399-416,478-503`: Der Kill-Switch wirkt
  damit nur beim Bau zukünftiger Launches: Der Guard fällt auf Direktbetrieb zurück, räumt
  bestehende Netzwerk-Capabilities aber nicht ab.

### Konkretes Szenario

Der User aktiviert das Backend, startet mindestens einen Chat und deaktiviert danach den
„GPT-Backend aktivieren“-Schalter, weil er die Integration beziehungsweise deren lokale
Angriffsfläche abschalten will. Neue Sessions erhalten zwar keine Router-Umgebung mehr, aber
der bereits laufende Proxy und Mix-Router lauschen weiter. Ein fremder lokaler Prozess kann
die in G02 beschriebene ChatGPT-Capability weiterhin verwenden. Die UI blendet den Status
beim Deaktivieren aus (`clearStatus`), wodurch der Restzustand nicht einmal sichtbar bleibt.
Bei einem vorher extern erkannten Proxy beendet auch der separate Stop-Button den Router
nicht.

### Fix-Skizze

Kill-Switch und Prozess-Lifecycle als explizite Zustandsmaschine modellieren. Beim
Deaktivieren keine neuen Verbindungen mehr annehmen und den selbst gestarteten Proxy
beenden. Bereits laufende PTYs benötigen eine definierte Policy: entweder sichtbarer
„Deaktivierung ausstehend, N Sessions nutzen den Router“-Zustand mit Connection-Refcount und
Shutdown nach dem letzten Client oder eine explizit bestätigte sofortige Trennung. Externen
Proxy und in-process Router getrennt verwalten; auch wenn WhisperM8 einen externen Proxy
nicht beenden darf, muss es seinen eigenen Router stoppen können. Der Settings-Status muss
Listenerzustand und ausstehenden Shutdown weiterhin anzeigen.

**Konfidenz:** hoch

## Secrets- und Payload-Datenfluss: verifizierte Negativbefunde

### Kein OpenAI-API-Key-Pfad in der neuen Integration

Die neue GPT-Backend-Seite speichert ausschließlich Enable-Flag, Port und Modellnamen in
`@AppStorage` (`GPTBackendSettingsPage.swift:4-20`; `AppPreferences.swift:257-295`). Der
Login startet `claude-code-proxy codex auth device` ohne Secret in argv
(`ClaudeCodeProxyManager.swift:326-352`). `WhisperM8/Services/Shared/KeychainManager.swift`
wird von diesem GPT-Pfad nicht aufgerufen. Der bestehende WhisperM8-Keychain-Service
`com.whisperm8.app` für Diktat-API-Keys ist deshalb nicht Teil der Kette.

Die tatsächliche Kette in Version 0.1.21 ist:

1. Device-Code erscheint nur im gepufferten Prozess-output und transient in der Settings-UI
   (`ClaudeCodeProxyManager.swift:338-372`; `GPTBackendSettingsPage.swift:138-163`).
2. Der externe Proxy speichert Access-/Refresh-Token unter seinem eigenen macOS-Keychain-
   Service `claude-code-proxy.codex`
   (`raine/claude-code-proxy@52c5501:src/providers/codex/auth/token_store.rs:6-7,49-67`).
3. WhisperM8 setzt für Claude lediglich die nicht geheime lokale
   `ANTHROPIC_BASE_URL` sowie Modell-/Effort-Variablen
   (`AgentCommandBuilder.swift:270-295`). Es gibt keinen GPT-Key in argv oder
   `AppPreferences`.
4. Für GPT entfernt der Router eingehende Claude-`Authorization`-, `x-api-key`- und
   `anthropic-*`-Header (`ClaudeGPTMixRouter.swift:310-339`). Der externe Proxy liest sein
   eigenes OAuth-Token und setzt es erst für die HTTPS-Anfrage als Bearer-Header
   (`raine/claude-code-proxy@52c5501:src/providers/codex/client.rs:95-113`).

Damit liegt **kein N09/N10-Klartext-Key-in-argv-Finding** im neuen GPT-Pfad vor. Das Secret
liegt weder in WhisperM8-UserDefaults noch in dessen Settings-JSON und wird nicht von
WhisperM8 geloggt. Das zentrale Problem ist stattdessen G02: Die durch dieses Secret
autorisierte Fähigkeit wird über unauthentisierte Loopback-Ports exportiert.

### Bindung und Logging

- Selbst gestarteter Proxy: WhisperM8 überschreibt `CCP_BIND_ADDRESS` auf `127.0.0.1`
  (`ClaudeCodeProxyManager.swift:237-249`); Upstream priorisiert diese Environment-
  Variable vor der Konfigurationsdatei
  (`raine/claude-code-proxy@52c5501:src/config.rs:118-134`). Der Mix-Router setzt ebenfalls
  einen festen `127.0.0.1`-Endpoint (`ClaudeGPTMixRouter.swift:127-134`). Die Bindung ist
  damit im selbst verwalteten Pfad strikt loopback-only. Sie verhindert G01/G02 nicht.
- Der In-Process-Router loggt nur Modell, Ziel-Upstream und Status, nicht Request- oder
  Response-Body (`ClaudeGPTMixRouter.swift:578-593,654-657`).
- Der Upstream-Proxy schreibt regulär Request-Metadaten und bei Fehlern redigierte
  Upstream-Response-Captures
  (`raine/claude-code-proxy@52c5501:src/server.rs:130-156,545-613`). Vollständige Chat-
  Payloads werden im verifizierten Quellstand erst durch `CCP_TRAFFIC_LOG` persistiert;
  wegen der ungefilterten Vererbung ist das dennoch der konkrete Befund G03.
