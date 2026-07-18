---
status: aktiv
updated: 2026-07-18
description: Technologievergleich zu Crash-Observability und Secrets-Hygiene fuer die direkt vertriebene macOS-App
---

# Crash-Observability und Secrets-Hygiene – Technologie-Deep-Dive (Juli 2026)

## Auftrag und Kurzurteil

Dieser Vergleich adressiert zwei bestätigte Risikogruppen des Audits: die
unfangbaren beziehungsweise asynchronen Diktat-Crashes **C01/C02** und die
Secrets-Befunde **N06/N09/N10**. WhisperM8 ist eine direkt vertriebene,
nicht im Mac App Store veröffentlichte macOS-14+-App; Datenschutz und lokale
Diagnosefähigkeit sind deshalb Teil des Architekturvertrags und keine spätere
Backend-Frage.

1. **Welle 0 sollte MetricKit als systemeigene Baseline und KSCrash nur im
   `Recording`-Modus als sofortigen lokalen Crash-Recorder kombinieren.**
   MetricKit kostet keine Drittanbieter-Runtime und liefert auf macOS 14 sogar
   strukturierte `NSException`-Gründe; KSCrash schließt die zeitliche Lücke bis
   zur späteren MetricKit-Zustellung und deckt Mach-Exceptions, Signale und
   ungefangene `NSException` direkt ab. Kein Report wird in Welle 0 automatisch
   hochgeladen. (`<MetricKit-SDK>/MXCrashDiagnostic.h:21-73`,
   `<KSCrash>/Sources/KSCrashRecording/include/KSCrashMonitorType.h:44-51,62-72`)
2. **PLCrashReporter ist solide, aber für diesen Einsatz nicht die stärkste
   Neuwahl.** Es kann BSD-Signale oder Mach-Exceptions abfangen und registriert
   optional einen `NSUncaughtExceptionHandler`; KSCrash bietet für nur moderat
   mehr Integrationsaufwand jedoch den expliziteren Monitor-, Store- und
   Privacy-Vertrag. (`<PLCrashReporter>/Source/PLCrashReporterConfig.h:41-101,147-190`,
   `<PLCrashReporter>/Source/PLCrashReporter.m:342-362`)
3. **Sentry Self-Hosted ist kein Welle-0-Crash-Recorder, sondern ein späteres
   Betriebsprodukt.** Der Cocoa-SDK-Teil kann dieselben nativen Crashklassen
   erfassen, speichert Envelopes aber als Teil einer Upload-Pipeline; der
   Self-Hosted-Stack bringt Symbolicator, Docker Compose und eine Mindestgröße
   von 14 GB Docker-RAM/4 CPU-Kernen im Vollprofil mit. Das ist für eine erste
   lokale Diagnose unverhältnismäßig. (`<sentry-cocoa>/Sources/Sentry/include/SentryCrashMonitorType.h:35-84`,
   `<sentry-cocoa>/Sources/Sentry/SentryHttpTransport.m:114-143,296-364`,
   `<sentry-self-hosted>/install/_min-requirements.sh:1-18`)
4. **N09 wird nicht durch weitere Denylists gelöst.** Der Agent-Pfad muss ein
   frisches, profilbewusstes Allowlist-Environment aufbauen; Shell-Tabs dürfen
   separat eine bewusst großzügigere Policy erhalten. OpenSSH baut seinen
   Session-Kontext ebenfalls von einem leeren Environment aus auf und fügt
   Basiswerte beziehungsweise explizit freigegebene Fähigkeiten einzeln hinzu.
   (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`,
   `<openssh>/session.c:934-1025,1054-1083`)
5. **N06/N10 brauchen einen gemeinsamen transaktionalen Security.framework-
   Pfad:** Secret im Prozess lesen, Ziel schreiben, Ziel bytegenau zurücklesen,
   erst dann die Quelle löschen. Weder Secret noch Prompt gehören in argv.
   Git belegt den stdin-/Keychain-Helper-Vertrag; KeychainAccess belegt, dass
   jeder `OSStatus` als Fehlerkanal erhalten bleiben kann. (`WhisperM8/Services/Shared/KeychainManager.swift:10-35,61-67`,
   `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:326-383`,
   `<git>/builtin/credential.c:12-50`,
   `<KeychainAccess>/Lib/KeychainAccess/Keychain.swift:658-740,808-827`)

Stand der Recherche: **18. Juli 2026**. Aufwand und Priorität sind eigene
Architektur-Schätzungen. Aussagen zu Fremdprojekten stützen sich auf die unten
benannten lokalen Quellcode-Snapshots; Webquellen ergänzen nur Apple-Verhalten,
das sich nicht aus öffentlichen Headern ableiten lässt.

## Quellenkonvention für lokale Klone

- `<MetricKit-SDK>` =
  `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/MetricKit.framework/Versions/A/Headers`
- `<KSCrash>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/KSCrash`
  (Snapshot `62039fc`)
- `<PLCrashReporter>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/PLCrashReporter`
  (Snapshot `0254f94`)
- `<sentry-cocoa>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/sentry-cocoa`
  (Snapshot `91f06a6`)
- `<sentry-self-hosted>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/sentry-self-hosted`
  (Snapshot `411a243`)
- `<openssh>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/openssh-portable`
  (Snapshot `cadefc7`)
- `<git>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/git`
  (Snapshot `41365c2`)
- `<KeychainAccess>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/KeychainAccess`
  (Snapshot `e0c7eeb`)
- `<Runic>` =
  `/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/8b93468c-4cf1-41c0-a5fc-b852563d2a8d/scratchpad/observability/Runic`
  (Snapshot `99f59a9`)
- Pfade ohne Präfix sind relativ zum WhisperM8-Repository.

## 1. Warum C01/C02 Observability und nicht nur einen Fix brauchen

C01 ist kein normaler Swift-`throw`: Zwischen der letzten Formatabfrage und
`installTap`/`engine.start` kann sich das weiterhin gültige Hardwareformat
ändern. Der aktuelle Code prüft nur, ob ein einmal gelesener Snapshot mehr als
0 Hz und 0 Kanäle hat, verwendet ihn danach aber unverändert für Tap und Start
(`WhisperM8/Services/Dictation/AudioRecorder.swift:101-120,152-170`). Die
bestätigte Folge ist eine Objective-C-/AVFoundation-Assertion, die den Prozess
außerhalb des Swift-Fehlerkanals beenden kann
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:34-44`).

C02 ist ein zweiter, unabhängiger Pfad: `handleConfigurationChange` bindet eine
Engine vor einem 300-ms-`await`, revalidiert danach weder `isRecording` noch die
Engine-Identität und installiert auf dem alten Objekt Tap/Converter neu
(`WhisperM8/Services/Dictation/AudioRecorder.swift:251-288,307-348`). Das kann
nach einem parallelen Stop bis in den Realtime-Audio-Thread reichen
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:46-55`).

Daraus folgt: Tests und Revalidierung verhindern neue Crashes; ein unabhängiger
Recorder beantwortet bei verbleibenden Feldfehlern **Crashklasse, Build,
Binary-UUID, Thread und letzte App-Phase**. Er darf aber niemals als Ersatz für
den C01/C02-Fix verkauft werden.

## 2. Vergleich der Crash-Observability-Optionen

### 2.1 Entscheidungsmatrix

| Option | `NSException` | POSIX-Signale | Mach-Crashes | Symbolication | Retention / Upload | SwiftPM-Aufwand | Urteil |
|---|---|---|---|---|---|---|---|
| **MetricKit** | Ja: `exceptionReason` ab macOS 14; außerdem allgemeiner Crash-Datensatz | Ja: `signal` | Ja: `exceptionType` + `exceptionCode` | JSON-Callstack enthält Image, UUID, Text-Offset und Adresse für Off-Device-Symbolication | System liefert Payload an Subscriber; WhisperM8 entscheidet selbst, ob JSON lokal geschrieben/exportiert wird. Keine SDK-Uploadpipeline. | **XS–S**: Systemframework + Subscriber | **Pflicht-Baseline**, aber nicht allein: Zustellung nur bei laufender App/Subscriber und laut Header mindestens täglich. |
| **KSCrash `Recording`** | Ja, eigener `NSSetUncaughtExceptionHandler` | Ja, `sigaction` + Alt-Stack | Ja, eigener Mach-Exception-Port | Schreibt Binary-UUIDs/Adressen und kann Apple-Format erzeugen; Release-dSYM bleibt für genaue Datei/Zeile nötig | Report-Store ist lokal; Sink ist optional. Pfad und Maximalanzahl konfigurierbar, Cleanup explizit. | **S–M**: natives SPM-Produkt, C/ObjC-Brücke, Startkonfiguration und Tests | **Empfohlener lokaler Recorder** hinter Feature Flag; nur `Recording`, kein Netzwerk-Sink. |
| **PLCrashReporter** | Ja, optionaler Uncaught-Exception-Handler setzt Exception und löst dann `abort()` aus | Ja, BSD-Modus | Ja, alternativer Mach-Modus auf macOS | Lokale Heuristik existiert, wird vom Projekt für Release zugunsten von DWARF ausdrücklich abgeraten | API bietet Pending-Report laden/löschen; Transport bleibt vollständig bei der App | **S**: ein SPM-Produkt, kleine API | **Gute Minimalalternative**, aber kein Zusatznutzen gegenüber KSCrash für WhisperM8. |
| **Sentry Cocoa + Self-Hosted** | Ja | Ja | Ja | Cocoa-Capture plus serverseitiger Symbolicator | Cocoa speichert Envelopes und stößt Versand an eine DSN an; Self-Hosted hält Daten in eigener Infrastruktur, bleibt aber Upload + Serverbetrieb | **M** SDK, **XL** Betrieb | **Später bei Team-Triage/Flottenbedarf**, nicht Welle 0. |

Belege zur Matrix:

- MetricKit deklariert Crash-Callstack, Termination Reason, Mach-Typ/-Code,
  Signal und auf WhisperM8s Mindestplattform macOS 14 den strukturierten
  Objective-C-Exception-Grund. (`<MetricKit-SDK>/MXCrashDiagnostic.h:21-73`)
- Der Callstack-JSON-Vertrag nennt explizit Binary-Image, UUID,
  Textsegment-Offset und Adresse für Off-Device-Symbolication.
  (`<MetricKit-SDK>/MXCallStackTree.h:13-28`)
- KSCrash listet Mach-, Signal-, C++- und NSException-Monitore explizit; sein
  Signalhandler nimmt Register/Fault-Adresse auf, schreibt alle Threads und
  re-raised danach das Signal. (`<KSCrash>/Sources/KSCrashRecording/include/KSCrashMonitorType.h:44-78`,
  `<KSCrash>/Sources/KSCrashRecording/Monitors/KSCrashMonitor_Signal.c:84-132`)
- KSCrash installiert den Foundation-Uncaught-Exception-Handler und übernimmt
  Name, Reason, `userInfo` und Exception-Callstack.
  (`<KSCrash>/Sources/KSCrashRecording/Monitors/KSCrashMonitor_NSException.m:65-91,96-150,160-176`)
- PLCrashReporter beschreibt BSD- und Mach-Modus samt Debugger-Konflikt; seine
  lokale Symbolication ist heuristisch und für Release ausdrücklich nicht
  empfohlen. (`<PLCrashReporter>/Source/PLCrashReporterConfig.h:41-101,105-145`)
- Sentry Cocoa führt dieselben vier nativen Monitorarten, während der HTTP-
  Transport Envelopes zunächst cached und danach `sendAllCachedEnvelopes`
  ausführt. (`<sentry-cocoa>/Sources/Sentry/include/SentryCrashMonitorType.h:35-84`,
  `<sentry-cocoa>/Sources/Sentry/SentryHttpTransport.m:114-143,296-364`)

### 2.2 MetricKit: native Baseline mit Zustellungsgrenze

Die Integration ist klein: einen langlebigen `MXMetricManagerSubscriber`
registrieren, `didReceiveDiagnosticPayloads` implementieren und die
`MXDiagnosticPayload.JSONRepresentation` lokal persistieren. Die SDK-Header
sagen zugleich klar, dass die Callback-Daten aus vorherigen Nutzungssessions
kommen, die App laufen und ein Subscriber vorhanden sein muss und der Callback
„at least once per day“ zu erwarten ist
(`<MetricKit-SDK>/MXMetricManager.h:63-76,105-138`). Der Payload enthält neben
Crash- auch Hang-, CPU- und Disk-Write-Diagnosen und lässt sich als JSON oder
Dictionary exportieren (`<MetricKit-SDK>/MXDiagnosticPayload.h:30-86`).

Für C01 ist macOS 14 wichtig: `exceptionReason` kann Name, Typ, Klasse,
Formatstring und Argumente einer ungefangenen `NSException` strukturiert
liefern; Apple weist darauf hin, dass Teile zum Schutz sensibler Nutzerdaten
redigiert sein können
(`<MetricKit-SDK>/MXCrashDiagnosticObjectiveCExceptionReason.h:14-53`).

**Grenze für Direct Distribution.** Die öffentliche API besitzt keine
App-Store-Bindung, und ein Apple-Developer-Forumsbericht beschreibt erfolgreiche
Crash-Zustellung beim nächsten Start einer nicht im App Store verteilten
macOS-App. Das ist nützliche Felderfahrung, aber keine formale
Distributionsgarantie. Welle 0 muss deshalb auf einer signierten/notarisierten
Direct-Build-Fixture einen echten Crash außerhalb von Xcode auslösen und die
Zustellung nach Neustart belegen. ([Apple Developer Forums: MetricKit])

### 2.3 KSCrash: lokaler Recorder, aber bewusst privacy-arm konfigurieren

KSCrash bietet genau die fehlende Sofortspur. Sein `ProductionSafeMinimal`-
Vertrag umfasst die fatalen Produktionsmonitore, während debugger-unsicherer
Mach-Capture bei angehängtem Debugger ausgeschlossen werden kann
(`<KSCrash>/Sources/KSCrashRecording/include/KSCrashMonitorType.h:93-147`). Der
Report-Store zeichnet auch ohne gesetzten Sink auf; Senden ist eine getrennte,
explizite Operation mit konfigurierbarer Cleanup-Policy
(`<KSCrash>/Sources/KSCrashRecording/include/KSCrashReportStore.h:73-114`).
Der SwiftPM-Manifest bietet ein schmales `Recording`-Produkt für macOS 10.14+
(`<KSCrash>/Package.swift:7-14,36-39,53-71`).

Gerade wegen WhisperM8s Prompts, Transkripten und Tokens muss die Konfiguration
minimal bleiben:

- `enableMemoryIntrospection = false` beibehalten; sonst würden Objective-C-
  Objekte und C-Strings nahe Stackpointer/Registern samt Inhalt in den Report
  gelangen. (`<KSCrash>/Sources/KSCrashRecording/include/KSCrashConfiguration.h:92-110`)
- Kein `userInfoJSON` mit Prompt, Transcript, Environment oder Dateiinhalten;
  höchstens Build, App-Phase (`recording.start`, `configuration.restart`) und
  nicht sensitive Audioformat-Metadaten. Das Feld wird vollständig in den
  Crashreport geschrieben. (`<KSCrash>/Sources/KSCrashRecording/include/KSCrashConfiguration.h:62-67`)
- `addConsoleLogToReport = false` und kein Netzwerk-Sink. Der Store-Pfad liegt
  unter `Application Support/WhisperM8/CrashReports`, Verzeichnis `0700`, Dateien
  `0600`, maximal fünf Reports; Export nur nach expliziter Nutzeraktion.
- Im Release Mach+Signal+NSException aktivieren; in Debug-Builds Mach deaktivieren,
  weil KSCrash ihn als debugger-unsicher klassifiziert.
  (`<KSCrash>/Sources/KSCrashRecording/include/KSCrashMonitorType.h:118-137`)

### 2.4 PLCrashReporter: kleiner, aber hier kein besserer Trade-off

PLCrashReporter kann mit einem direkten SPM-Produkt eingebunden werden
(`<PLCrashReporter>/Package.swift:5-15,17-50`). Die App aktiviert den Reporter,
prüft beim nächsten Start `hasPendingCrashReport`, lädt die Daten und löscht sie
erst nach Verarbeitung (`<PLCrashReporter>/Source/PLCrashReporter.h:92-127`).
Der Uncaught-Exception-Handler setzt Exception-Metadaten und ruft `abort()`,
sodass derselbe konfigurierte BSD-/Mach-Crashpfad den eigentlichen Dump schreibt
(`<PLCrashReporter>/Source/PLCrashReporter.m:339-362`).

Für einen reinen „ein Pending-Crashreport, eigener Upload“ ist das attraktiv.
WhisperM8 braucht aber gerade die explizite Kontrolle über Monitorarten,
lokale Mehrfachreports und privacy-sensitive Zusatzdaten. KSCrash stellt diese
Seams bereits öffentlich bereit; zwei parallele In-Process-Crashhandler wären
hingegen falsch. Daher: PLCrashReporter dokumentieren, aber nicht zusätzlich
installieren.

### 2.5 Sentry Self-Hosted: Datenschutzkontrolle gegen Betriebsaufwand

Sentry Cocoa ist technisch kein schwächerer Recorder: sein SentryCrash-Kern
führt Mach, Signal, C++ und NSException und besitzt SPM-Binary- sowie
Compile-from-source-Produkte (`<sentry-cocoa>/Sources/Sentry/include/SentryCrashMonitorType.h:35-84`,
`<sentry-cocoa>/Package.swift:19-38,91-99`). Produktsemantisch ist er jedoch eine
Telemetry-Pipeline: Envelopes werden lokal gespeichert, anschließend über die
DSN versendet und bei Netzfehlern für Retry behalten
(`<sentry-cocoa>/Sources/Sentry/SentryHttpTransport.m:123-143,387-407`).

Self-Hosting hält Triage-Daten unter eigener Kontrolle, beseitigt aber weder
Upload noch dSYM-/Retention-/Zugriffs-Policies. Das offizielle Deployment nennt
sich selbst für Low-Volume/PoC, benötigt Docker/Compose und prüft im Vollprofil
mindestens 14.000 MB Docker-RAM und vier CPUs; selbst `errors-only` verlangt
7.000 MB und zwei CPUs (`<sentry-self-hosted>/README.md:1-5`,
`<sentry-self-hosted>/install/_min-requirements.sh:1-18`). Ein eigener
`symbolicator`-Dienst samt persistentem Volume und Cleanup-Job gehört zum Stack
(`<sentry-self-hosted>/docker-compose.yml:481-507`).

**Urteil:** Erst evaluieren, wenn mehrere Installationen, automatische
Gruppierung, Release-Triage und Teamzugriff den Betrieb rechtfertigen. Dann
Opt-in/Datenschutzerklärung, Server-Retention, Zugriff, Backups und dSYM-Upload
als eigenes Projekt planen. Nicht als versteckte Nebenwirkung eines
Crash-Recorder-Fixes.

## 3. Symbolication und Artefaktvertrag

Keiner der Recorder ersetzt das Release-Artefaktmanagement:

1. Für jeden notarisierten Build `app-version`, `build-number`, Git-Commit,
   Architektur und Mach-O-UUID manifestieren.
2. Das zugehörige `.dSYM` unveränderlich und zugriffsgeschützt archivieren.
3. MetricKit-JSON beziehungsweise KSCrash-/PLCrash-Adressen gegen **genau diese
   UUID** symbolizieren; keine „ähnliche“ lokale Build verwenden.
4. Rohreport und symbolisierte Fassung getrennt halten. Rohdaten bleiben die
   forensische Quelle; Symbolication ist reproduzierbare Ableitung.
5. Welle 0 braucht einen Fixture-Crash mit mindestens einem eigenen Swift-Frame
   und einen CI-/lokalen Check, der bis Datei:Zeile symbolisiert.

Die technische Grundlage ist belegt: MetricKit liefert UUID, Textsegment-
Offset und Adresse (`<MetricKit-SDK>/MXCallStackTree.h:21-28`); KSCrash schreibt
UUID und Image-Metadaten in seine Reports
(`<KSCrash>/Sources/KSCrashRecording/KSCrashReportC.c:1140-1152`) und
PLCrashReporter warnt selbst, dass DWARF genauer ist als Runtime-Heuristik
(`<PLCrashReporter>/Source/PLCrashReporterConfig.h:105-119`).

## 4. Konkrete Welle-0-Empfehlung für Crash-Observability

### O0.1 · MetricKit-Baseline

- Beim App-Start Subscriber registrieren; Callback sofort auf eine serielle
  Utility-Queue weiterreichen.
- Nur `payload.JSONRepresentation` plus eigenes minimales Manifest speichern;
  keine Sessionprompts, Transkripte oder Environment-Dumps anreichern.
- Fünf Reports oder 30 Tage, je nachdem was zuerst erreicht wird; UI-Aktion
  „Diagnose exportieren“, keine automatische Übertragung.
- Integrationstest mit signierter Direct-Distribution-Build: echter
  `NSException`-Fixture-Crash außerhalb Xcode, Neustart, Payload-Empfang,
  Export und dSYM-Symbolication.

### O0.2 · KSCrash-Recording hinter Kill-Switch

- Nur Package-Produkt `Recording`; kein `Reporting`, keine HTTP-Installation,
  kein Sentry-Sink.
- Default `ProductionSafeMinimal`, Memory-Introspection/Console/User-Payload aus;
  in Debug Mach-Capture aus.
- Vor kritischen Übergängen nur eine kleine atomare Phase setzen:
  `audio.start.formatChecked`, `audio.tapInstalled`,
  `audio.configuration.backoff`, `audio.configuration.restart`.
- Kill-Switch über Defaults, damit ein Handlerkonflikt im Feld ohne neues Binary
  abschaltbar ist.
- Crash-Fixtures getrennt für ungefangene `NSException`, `SIGABRT` und
  Bad-Access; pro Fixture genau ein parsebarer Report und unverändertes
  Folgeverhalten des System-Crashreporters erwarten.

### O0.3 · Explizit nicht in Welle 0

- Kein automatischer Upload und keine Device-/User-ID.
- Kein Sentry-Server, keine zweite Crashhandler-Library parallel zu KSCrash.
- Kein Memory-Snapshot, Transcript-Tail, Clipboard, Environment oder Terminal-
  Scrollback im Crashreport.
- Keine Annahme, Observability behebe C01/C02: deren Revalidierungs- und
  Generation-Gates bleiben eigene P0-Maßnahmen.

## 5. Secrets-Hygiene: bestätigte Ist-Befunde

### N09 · Vollständiges Parent-Environment

`processEnvironment()` startet mit `var env = base`, entfernt nur
`CLAUDE_CODE_*`, `CLAUDECODE`, `CLAUDE_CONFIG_DIR` und `NO_COLOR` und gibt den
Rest weiter (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`).
Damit erreichen etwa `AWS_*`, `GITHUB_TOKEN`, Provider-Keys, Proxy-URLs mit
Credentials, `SSH_AUTH_SOCK` und sonstige Capability-Sockets Agenten,
MCP-Server, Builds und Projektcode. Der Befund ist hoch und bestätigt
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:60-63`).

### N10 · OAuth-Secret in argv beim Profil-Rename

Der Default-Runner reicht sein Array unverändert als `Process.arguments` an
`/usr/bin/security` (`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:326-342`).
`renameProfile` liest das alte Secret und hängt es anschließend hinter `-w` an
`add-generic-password`; erst nach Erfolg wird das alte Item gelöscht
(`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:363-383`). Das ist
keine Shell-Injection, aber eine reale Klartext-argv-Exposition.

### N06 · Delete-on-unverified-write bei Legacy-Migration

`KeychainManager.save` hat keinen Fehlerkanal: ein Fehler wird nur geloggt
(`WhisperM8/Services/Shared/KeychainManager.swift:10-35`). `load` ruft `save`
für einen Legacy-Wert auf und löscht UserDefaults danach bedingungslos, selbst
wenn `SecItemAdd`/`SecItemUpdate` fehlgeschlagen ist
(`WhisperM8/Services/Shared/KeychainManager.swift:37-69`). Damit kann die nächste
App-Generation den einzigen API-Key verlieren; N06 ist hoch und bestätigt
(`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:48-50`).

## 6. N09: frisches Allowlist-Environment statt Denylist

### 6.1 Übernehmbares OSS-Muster

OpenSSH initialisiert das Session-Environment als leeres Array und setzt
`USER`, `LOGNAME`, `HOME`, `PATH`, `SHELL`, optional `TZ`, `TERM` und weitere
explizite Sessionwerte einzeln
(`<openssh>/session.c:934-1025`). Benutzer-Environment wird nur bei aktivierter
Policy gelesen und zusätzlich über eine Allowlist gematcht
(`<openssh>/session.c:1059-1083`). Selbst `SSH_AUTH_SOCK` erscheint nicht durch
blindes Parent-Inheritance, sondern nur, wenn OpenSSH für diese Session bewusst
einen Agent-Socket erzeugt hat (`<openssh>/session.c:1049-1056`).

Das ist die richtige Richtung für WhisperM8: **Capabilities benennen und
gezielt gewähren**, nicht nach bekannten Secret-Namen suchen. Eine Denylist kann
neue Provider, private Firmennamen oder credentialtragende Proxy-URLs nie
vollständig kennen.

### 6.2 Empfohlene Policy-Seams

`LoginShellEnvironment` sollte PATH-Ermittlung und Child-Policy trennen:

```swift
enum ChildEnvironmentPolicy {
    case agent(profileOverrides: [String: String])
    case helper(extra: [String: String])
    case interactiveShell
}
```

- **`.agent`:** von leer starten. Erlaubt sind nur `HOME`, `USER`, `LOGNAME`,
  `SHELL`, `TMPDIR`, der berechnete `PATH`, `LANG`/ausgewählte `LC_*`, `TERM`,
  `COLORTERM`, `CLICOLOR` sowie WhisperM8-eigene, nicht sensitive Launch-
  Variablen. `CLAUDE_CONFIG_DIR` kommt ausschließlich aus dem gewählten
  Profil-Override.
- **`.helper`:** noch kleiner; nur Werte, die das konkrete Binary benötigt.
  Git- und Security.framework-Aufrufe brauchen kein komplettes Agent-Env.
- **`.interactiveShell`:** darf bewusst näher am Login-Shell-Environment liegen,
  weil der User hier gerade eine normale Shell erwartet. Trotzdem keine App-
  internen API-Keys injizieren.
- **Default ausgeschlossen:** `*_TOKEN`, `*_SECRET`, `*_PASSWORD`, `*_API_KEY`,
  Cloud-Credentials, `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, `GIT_ASKPASS`,
  `SSH_ASKPASS`, `DOCKER_HOST`, `KUBECONFIG`, credentialtragende Proxy-URLs und
  unbekannte Sockets/Fds. Mustererkennung bleibt Defense-in-Depth, nicht die
  primäre Policy.
- **Opt-in-Capability:** Git/SSH-Agent nur pro Session/Projekt sichtbar
  freigeben. Die UI beschreibt, dass dies Signier-/Authentisierungsfähigkeit
  und nicht bloß eine harmlose Variable ist.

Regressionstests starten mit Sentinelwerten für mindestens
`OPENAI_API_KEY`, `GROQ_API_KEY`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`,
`HTTP_PROXY=https://user:secret@…`, `SSH_AUTH_SOCK` und eine unbekannte
`ACME_PROD_CREDENTIAL`; in `.agent` darf keiner erscheinen. Gleichzeitig müssen
PATH, Locale, Farbe, per-Profil-`CLAUDE_CONFIG_DIR` und bestehende Claude-/Codex-
Resume-Pfade unverändert funktionieren.

## 7. N10 und argv-freie Secret-Übergabe

### 7.1 Kanäle nach Priorität

1. **Kein Child-Prozess:** Wenn derselbe macOS-Prozess den Keychain-Wert
   migriert, direkt Security.framework verwenden. Das ist für Profil-Rename der
   richtige Pfad.
2. **Keychain-Handle:** Ein Kind erhält Service/Account beziehungsweise einen
   opaken Handle und liest das Secret nur, wenn seine Signatur/ACL es darf. Der
   Handle ist nicht geheim; der Wert bleibt im Keychain-Vertrag.
3. **stdin/Pipe:** Für kurzlebige, erwartete Einmalwerte. Git `credential`
   akzeptiert den Credential-Datensatz auf stdin statt argv
   (`<git>/builtin/credential.c:12-50`). WhisperM8 nutzt dasselbe Muster bereits
   korrekt für Codex-Prompts: `-` aktiviert stdin und ein `Pipe` schreibt den
   Prompt nach dem Spawn (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:86-97,160-167,203-219,288-298`).
4. **Geerbter File Descriptor / Socket:** Für langlebige oder interaktive
   Broker einen restriktiven Pipe-/Socket-FD vererben; Nummer/Handle darf im
   Environment stehen, nicht das Secret. Ownership, Close-on-exec für alle
   anderen FDs und genau ein Consumer sind Pflicht.
5. **0600-Datei:** Nur wenn die Ziel-CLI weder stdin noch FD/Keychain kann;
   exklusiv erzeugen, nach Open sofort unlinken oder sicher löschen, Pfad statt
   Inhalt übergeben. Crash-Restdaten und Backups machen dies zur letzten Wahl.

Git zeigt die vollständige Kombination aus stdin und Keychain: der
`osxkeychain`-Helper parst Felder einschließlich `password` zeilenweise von
stdin, ruft `SecItemAdd`/`SecItemUpdate` auf und erhält im argv nur die Operation
`get|store|erase` (`<git>/contrib/credential/osxkeychain/git-credential-osxkeychain.c:334-388,391-463,480-510`).

### 7.2 Konkreter Rename-Ablauf

`ClaudeAccountProfiles.securityRunner` entfällt für den Migrationspfad. Ein
kleiner injizierbarer `KeychainItemMoving`-Adapter über Security.framework führt
aus:

1. Altes Item mit `SecItemCopyMatching`, `kSecReturnData` und
   `kSecReturnAttributes` lesen; nicht nur String, sondern `Data` und benötigte
   Attribute halten.
2. Zielquery aus Service/Account/Label plus bewusst erhaltener Accessibility-
   Policy aufbauen. Keine blinde Übernahme query-only Attribute.
3. Ziel per `SecItemAdd` schreiben. Ein bestehendes Ziel ist ein Konflikt, kein
   Grund für `-U`-Überschreiben.
4. Ziel per separatem `SecItemCopyMatching` zurücklesen und `Data` bytegenau
   vergleichen.
5. Erst jetzt Profilordner und Sessionstempel umbenennen.
6. Altes Keychain-Item löschen. Scheitert nur dieses Delete, bleiben zwei
   gültige Kopien; Cleanup wird retrybar protokolliert, der Login geht nicht
   verloren.
7. Secret-`Data` und temporäre Referenzen so früh wie möglich freigeben; Wert
   nie loggen, nie in `String` konvertieren, nie in argv/Environment schreiben.

## 8. N06: transaktionale Keychain-Migration

KeychainAccess zeigt den erforderlichen Fehlerkanal: `set` wirft bei
Konvertierungs-, Copy-, Update- und Add-Fehlern; `remove` wirft bei jedem Delete-
Fehler außer „nicht gefunden“
(`<KeychainAccess>/Lib/KeychainAccess/Keychain.swift:658-740,808-827`). Runic
zeigt außerdem das minimale Delete-Gate einer echten Credential-Migration: der
Legacy-Wert wird nur nach erfolgreichem `SecItemAdd` gelöscht; gesperrte und
fehlgeschlagene Accounts werden separat ausgewiesen
(`<Runic>/Sources/RunicCore/ProviderCredentialKeychainMigration.swift:41-71,122-165,168-184`).

WhisperM8 sollte diesen Vertrag noch um einen Readback erweitern:

```text
legacy read
    └─ write destination
          └─ destination readback == source bytes
                └─ delete legacy
```

Für `KeychainManager` folgt daraus:

- `save` wird `throws` oder liefert einen typisierten `Result`, statt `Void`.
- `load` entfernt `UserDefaults` nur nach erfolgreichem Write **und**
  bytegleichem Keychain-Readback.
- Bei Write/Readback-Fehler bleibt UserDefaults unverändert; für den aktuellen
  Lauf darf der Legacy-Wert weitergegeben werden, aber mit begrenztem,
  wertfreiem Diagnoseevent.
- Cache erst nach bestätigtem Keychain-Erfolg aktualisieren; Tests verwenden
  einen injizierten Security-Adapter und erzwingen Fehler für Add, Update,
  Readback und Delete einzeln.
- Delete-Fehler nach erfolgreicher Kopie ist kein Datenverlust: beide Kopien
  bleiben, Migration bleibt „cleanup pending“ und wird später idempotent
  wiederholt.

## 9. Priorisierte Umsetzung und Gates

| Priorität | Maßnahme | Finding | Erfolgskriterium |
|---:|---|---|---|
| **W0/P0** | MetricKit-Subscriber + lokaler JSON-Store + dSYM-Manifeste | C01/C02 | Signierter Direct-Build-Crash wird nach Neustart empfangen und bis Datei:Zeile symbolisiert. |
| **W0/P0** | KSCrash `Recording` local-only hinter Kill-Switch | C01/C02 | NSException, SIGABRT und Bad-Access erzeugen je genau einen privacy-armen Report; kein Request verlässt den Mac. |
| **W0/P0** | `KeychainManager.save` fehlerfähig; copy→readback→delete | N06 | Add/Update/Readback-Fehler lassen Legacy-Wert unangetastet; Delete-Fehler lässt mindestens eine bestätigte Kopie. |
| **W0/P0** | Profil-Rename auf Security.framework umstellen | N10 | Prozessliste enthält zu keinem Zeitpunkt Secret/Prompt; Ziel wird vor Quell-Delete bytegenau verifiziert. |
| **W1/P1** | `.agent`/`.helper` von leerem Env, `.interactiveShell` separat | N09 | Sentinel-Secrets und Capability-Sockets fehlen in Agent/MCP-Kindern; Login, Profile, PATH, Locale und TUI-Farbe bleiben erhalten. |
| **Watch** | Sentry Self-Hosted erst bei Flotten-/Team-Triage neu bewerten | — | Eigene Datenschutz-, Betriebs-, Backup-, dSYM- und Retention-RFC statt stiller SDK-Aktivierung. |

### Release-Gates

1. **Observability ist output-only:** kein Prompt, Transcript, Clipboard,
   Environment, Keychain-Wert oder Terminal-Scrollback im Report.
2. **Kein Auto-Upload:** Export erfordert explizite Nutzeraktion; Netzwerk-Test
   beweist null Crash-Traffic.
3. **Handler-Korrektheit:** kein paralleler PLCrashReporter-/SentryCrash-Handler;
   KSCrash-Kill-Switch getestet.
4. **Secrets bleiben außerhalb argv:** automatisierter Test inspiziert
   `Process.arguments` aller Rename-/Helper-Pfade.
5. **Migration ist fehlertolerant:** jeder Security-`OSStatus`-Fehler wird in
   Tests injiziert; niemals werden Quelle und Ziel im selben Fehlerpfad
   unbestätigt gelöscht.
6. **Feature-Erhalt:** Claude-/Codex-Profile, Resume, Background-Agents,
   Postprocessing, Git/SSH-Opt-in und normale interaktive Shell-Tabs bleiben als
   getrennte Regression-Suites erhalten.

## Webquelle

- [Apple Developer Forums: MetricKit] —
  <https://developer.apple.com/forums/tags/metrickit>

[Apple Developer Forums: MetricKit]: https://developer.apple.com/forums/tags/metrickit
