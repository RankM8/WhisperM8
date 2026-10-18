---
status: roh
updated: 2026-10-17
description: Workflow B, B4 Verteilung + Rahmenbedingungen — Vergleich mit anderen Projekten und Rahmenbedingungen (aus der strukturierten Agent-Rückgabe erzeugt).
---

# B4 Verteilung + Rahmenbedingungen

## Kurzfazit

---
status: roh
updated: 2026-10-17
description: B4-Recherche zu Verteilung, CLI-Installation, Konten, inoffiziellen Upstreams und Datenschutz.
---

## Kurzfazit
E4 Developer ID/Notarisierung und E5 geführte Original-CLI-Installation sind mit dem bestehenden Stack sinnvoll umsetzbar. Keine zwingenden Claude-/Codex-Cask-Abhängigkeiten. E3 Mehrkontenbetrieb ist inzwischen ausdrücklich offiziell dokumentiert; externes OAuth-Token-Handling ist jedoch eine eigene, nicht dadurch freigegebene Frage. E2 Labs beibehalten, Coding-Proxy und nachgebildete ChatGPT-Transkription getrennt bewerten.

Drei besonders wichtige neue beziehungsweise bestätigte Befunde: (1) Der nachgeladene Proxy entfernt weiterhin selbst Quarantäne; App-Notarisierung allein beseitigt diesen zweiten Umgehungspfad nicht. (2) Profil-Rename und Promote geben OAuth-Secrets im aktuellen gelesenen Code an security-argv weiter. (3) Der vorhandene Developer-ID-Signing-Zweig kann beim fehlenden Frameworks-Verzeichnis unter pipefail abbrechen.

## Juli-Abgleich
Alle drei vorgegebenen Juli-Analysen zuerst gelesen. Weiterhin richtig: echte CLI im PTY hosten, Profile isolieren, Logs/Diagnose privacy-arm halten. Die dortige N10-Sicherheitswarnung ist im aktuellen Code weiterhin relevant. Die LiteLLM-Analyse liefert Protokollmuster, aber keinerlei Berechtigung zur Subscription-Nutzung; ihr damaliger Usage-Defekt wurde hier nicht erneut geprüft und wird nicht als aktueller Defekt übernommen. Aktualisiert: Anthropic dokumentiert ausdrücklich Native-CLI-Hosting und mehrere Accounts; Codex bietet inzwischen zusätzlich einen Standalone-Installer; Happy ist architektonisch nicht mehr unverändert mit dem Juli-Snapshot vergleichbar.

## Was WhisperM8 schon richtig macht
Original-CLIs statt Ersatzruntime, getrennte Config-Roots, API-Keys im Keychain, profilabhängiges Onboarding sowie Trennung von Kern und Labs bilden gute Voraussetzungen. Der Proxy-Installer hat gepinnte Known-good-Prüfsummen und einen serialisierten Austauschpfad. Diese Schutzmaßnahmen ersetzen allerdings weder Signer-Authentisierung noch die rechtliche Credential-Prüfung.

## Offene Fragen und Evidenzgrenzen
Keine signierten Builds, Installer oder fremden Programme ausgeführt. Aktuelle Proxy-Release-Binary-Signaturen nicht untersucht. OpenAI-EU-AGB beim Vollabruf HTTP 403, deshalb dort nur offizielle Suchindex-Auszüge plus klar getrennte weitere Primärquellen; abschließende Vertragsfreigabe offen. Anthropic-Ausnahme für lokale Credential-Migration/Usage-Abfragen, Herausgeber-Rollen unter DSGVO, TCC-Migration und W7-Prozesscleanup benötigen zusätzliche Klärung beziehungsweise Tests. Keine belastbaren Sperrquoten gefunden.

Die Ergebnisse stehen vollständig in answers/projects/recommendations. Wegen der übergeordneten Workflow-Vorgabe, keine Bericht-.md-Dateien zu schreiben, wurde keine Datei angelegt; report_path ist deshalb bewusst leer. Es gab keine Änderungen am Worktree und keine Veröffentlichung.

## Untersuchte Projekte und Quellen

| Name | URL | Lizenz | Geprüft über | Relevanz |
|---|---|---|---|---|
| Homebrew Cask | https://github.com/Homebrew/homebrew-cask | BSD-2-Clause; Lizenz betrifft Homebrew-Definitionen, nicht die installierten Hersteller-Binaries. | code | Offizielle Cask-Doku und Code gelesen. Claude-Code-Cask 2.1.292, dateibezogener Commit b3ca0d8 vom 14.10.2026; Codex-Cask 0.163.0, Commit 4706e3e vom 15.10.2026. Zentrale Evidenz für Abhängigkeiten, Update-Verhalten, Quit/Zap und Adopt. |
| Claude Code | https://github.com/anthropics/claude-code | CLI proprietär, Anthropic Consumer/Commercial Terms; LICENSE.md enthält All-rights-reserved-Hinweis. | doku | Offizielle Live-Doku zu Installation, Auth, mehreren Accounts, Entitlements-freier Host-Grenze und Legal gelesen; Repo-Lizenz gelesen. Repository-HEAD c017428 vom 16.10.2026. Besonders wichtig: ausdrückliche Native-CLI-Host-Ausnahme und gleichzeitige Beschränkung externen Token-Handlings. |
| OpenAI Codex CLI | https://github.com/openai/codex | Apache-2.0 für Codex-Code; OpenAI-Dienstnutzung separat geregelt. | doku | Offizielles README und Auth-Doku gelesen, Repository-HEAD ce0323f vom 17.10.2026. Unterstützt Brew, npm, Binär-Releases und inzwischen eigenen Standalone-Installer; Browser-Login und unterschiedliche Datenregeln je Auth-Modus. |
| raine/claude-code-proxy | https://github.com/raine/claude-code-proxy | MIT | code | README, Transkriptionscode und vollständige Release-Pipeline bei Commit 2e2975a vom 10.10.2026 sowie aktuelle Compatibility-Doku gelesen. Letztes Release v0.1.45 vom 10.10.2026. Explizite Kontorisiko-Warnung; Pipeline ohne explizite Developer-ID-/Notarisierungsschritte. Keine fremden Programme ausgeführt. |
| Zed | https://github.com/zed-industries/zed | Gemischt: GPL-3.0 und Apache-2.0, komponentenabhängig; beide Lizenzdateien geprüft. | doku | Aktuelle offizielle External-Agents- und Terminal-Threads-Doku gelesen; Repository-HEAD 56934ec vom 17.10.2026. Gutes Vorbild für Installationsführung und klare Trennung zwischen Host und CLI-eigener Authentifizierung; kein Vorschlag zur Übernahme von ACP statt PTY. |
| Happy | https://github.com/slopus/happy | MIT | doku | Aktuelles README bei Commit 55ab69f vom 17.10.2026 gelesen. Gegenüber Juli inzwischen klarer Split zwischen Original-CLI und eigenem Desktop/Harness; deshalb alte Architekturannahmen nicht unverändert übernehmen. Subscription-Werbung ist keine Rechtsfreigabe. |
| SwiftTerm, WhisperM8-Fork | https://github.com/GiulianoCosta71/SwiftTerm | MIT | code | Package-Pin 2671405 und Teile der LocalProcess-Implementierung gelesen; Fork zuletzt gepusht am 02.08.2026. Relevanz: native PTY-Subprozesse sind von in-process Plug-ins zu unterscheiden. Keine Ausführung und keine praktische Hardened-Runtime-Verifikation erfolgt. |

## Antworten auf die Fragestellungen

### 1. E4 Notarisierung: CI-Voraussetzungen, Entitlements, PTYs, nachgeladene Binaries, Kosten und Entfernung des Cask-xattr-Schritts?

**Konfidenz:** hoch

**Ergebnis:** E4 ist mit dem vorhandenen SwiftPM-Stack umsetzbar. Hardened Runtime ist nicht App Sandbox. PTYs und externe CLI-Prozesse sind grundsätzlich kein Grund für einen Stack-Wechsel oder weitreichende Runtime-Ausnahmen. Die konkrete Release-App wurde hier weder gebaut noch ausgeführt.

**Maßgebliche Apple-Vorgaben, Doku direkt gelesen:** „Enable the Hardened Runtime capability for your app and command line targets“ und „Include a secure timestamp with your code-signing signature.“ Apple verlangt Developer-ID-Signaturen, gültige Signaturen aller ausgelieferten Executables und kein aktiviertes `com.apple.security.get-task-allow`. Notarisierung ist ausdrücklich „not App Review“.

**Konkrete CI-Kette:**
1. Apple Developer Program, Developer ID Application-Zertifikat einschließlich privatem Schlüssel als passwortgeschütztes P12. GitHub-Secrets für Base64-P12, P12-Passwort, temporäres Keychain-Passwort sowie App-Store-Connect-P8-Key, Key-ID und bei einem Team-Key Issuer-ID. Identitätsname und Team-ID sind keine privaten Schlüssel. Für diesen unsandboxed Funktionsumfang ist nicht automatisch ein Provisioning Profile erforderlich; das allgemeine GitHub-Xcode-Beispiel enthält eines, darf aber nicht unbesehen übernommen werden.
2. Auf dem macOS-Runner temporäre Keychain erstellen/entsperren, Zertifikat importieren, Key-Partition-Liste für Codesigning setzen, Identität prüfen. Secrets nur im geschützten Release-Job, nicht bei fremden PRs; Dateien mit restriktiven Rechten und abschließender Bereinigung. Base64 ist keine Verschlüsselung.
3. SwiftPM-App wie bisher paketieren. Eigene eingebettete Mach-O-Komponenten innen nach außen signieren, danach App mit `codesign --force --options runtime --timestamp --entitlements … --sign …`. Kein pauschales `--deep` beim Signieren; zum rekursiven Verifizieren ist es weiterhin verwendbar. Signierte Inhalte anschließend nicht mehr verändern.
4. DMG erstellen und signieren; `xcrun notarytool submit <DMG> --key <P8-Datei> --key-id <ID> --issuer <Issuer> --wait --output-format json`. Das lokal gelesene Apple-notarytool-Handbuch unterscheidet Team- und Individual-Keys: bei Individual-Key `--issuer` weglassen. Explizit `status == Accepted` verlangen und Notary-Log auch bei Erfolg prüfen.
5. `xcrun stapler staple <DMG>` und `stapler validate`; App mit `codesign --verify --deep --strict` und Gatekeeper-Prüfung prüfen. Für eine unabhängig vom Image offline kopierte App ist zusätzliches App-Stapling sinnvoll; eine vorgeschaltete App-ZIP-Notarisierung ist dafür eine robuste, aber nicht bei jedem einfachen DMG zwingend nötige Variante.
6. Erst nach Stapling SHA256 des endgültigen DMG berechnen, GitHub-Asset veröffentlichen und Cask aktualisieren. Frisch heruntergeladenes, tatsächlich quarantänisiertes Release auf einem sauberen Mac testen, zusätzlich Offline-Start und Brew-Update. Ein lokales nicht-quarantänisiertes Build beweist Gatekeeper-Tauglichkeit nicht.

**Entitlement-Matrix:**
- Mikrofon/Core Audio: vorhandenes `com.apple.security.device.audio-input = true` beibehalten, mit verständlicher `NSMicrophoneUsageDescription` und tatsächlicher TCC-Freigabe. Apple beschreibt das Entitlement als Erlaubnis, „record audio using the built-in microphone“.
- Accessibility/CGEvent und normale Bildschirmaufnahme: TCC-Freigaben; kein allgemeines zusätzliches Hardened-Runtime-Entitlement für PTY, Accessibility oder Screen Recording ableiten. Apples Runtime-Liste enthält solche allgemeinen Schalter nicht. Insbesondere keine erfundenen `com.apple.security.screen-capture`-Keys hinzufügen. Apple Events Automation wäre nur für tatsächlich verwendete Apple-Events-Steuerung anderer Apps separat zu prüfen, nicht für CGEvent-Paste pauschal nötig.
- Netzwerk und Loopback-Listener: ohne App Sandbox keine Sandbox-Netzwerk-Entitlements notwendig. Das vorhandene `network.client` ist kein Ersatz für Sicherheit am lokalen Proxy/Socket. `app-sandbox = false` kann weggelassen werden; Apple empfiehlt, false-Entitlements nicht aufzunehmen.
- SwiftTerm und separate CLI-Prozesse: kein generelles `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation` oder Sandbox-`inherit` für den Host. Eine separat gestartete Node-/Bun-/Rust-CLI ist kein in den Host geladenes Plug-in und muss ihre eigenen Anforderungen erfüllen. SwiftTerm-PTY, Resize, Interrupt, Resume, OAuth-Callback und Metal-Opt-in müssen mit der final signierten App getestet werden.
- Library Validation eingeschaltet lassen. Apple beschränkt das Laden von Frameworks/Plug-ins/Libraries auf Apple oder dieselbe Team-ID. Das betrifft in-process geladenen Code, nicht pauschal jedes gestartete Fremdbinary. Audio-Plug-in-/Treiber-Sonderfälle erst anhand eines konkreten Befunds ausnehmen.

**Statisch verifizierte Lücken im eigenen Code:** `/Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/.github/workflows/release.yml:55` baut ausdrücklich ad hoc. `/Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/scripts/build-dmg.sh:103–119` erlaubt Notarisierung still zu überspringen; direkter API-Key-Pfad fehlt. Zusätzlich droht der erste Developer-ID-Lauf an Zeile 38 zu scheitern: `find Contents/Frameworks` läuft unter `set -euo pipefail`, der Makefile-Bundle-Schritt erstellt aber nur MacOS und Resources. Ein nicht vorhandenes Frameworks-Verzeichnis muss vor dem Scan abgefangen werden. Das ist statische Analyse, kein ausgeführter Repro.

**Wichtig: App-Notarisierung löst den Proxy-Fall nicht.** `/Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift:210–212,280–286` entfernt separat die Quarantäne nachgeladener Proxy-Binaries. Die gelesene Upstream-Release-Pipeline erzeugt Tarballs und SHA-Sidecars, enthält jedoch keinen Developer-ID-/Notarisierungsschritt; die tatsächlichen Release-Binary-Signaturen wurden nicht untersucht. Apple sagt zu Netzwerk-Installern: „separately notarize both the installer and the items it downloads“. Daher für F-GPT-03 einen eigenen Vertrauenspfad verlangen: notarisiertes Upstream-Asset mit geprüftem Signer oder kontrolliert selbst signiert/notarisiert bereitgestelltes, lizenzkonform attribuiertes Proxy-Asset. SHA und Sidecar aus demselben kompromittierbaren Release sind keine unabhängige Herausgeber-Authentisierung. Fehlende Quarantäne bei einem programmatischen Download ist ebenfalls kein Sicherheitsnachweis.

**Kosten/Aufwand:** Apple nennt 99 USD je Mitgliedschaftsjahr beziehungsweise lokalen Preis; CI-Nutzung kommt gegebenenfalls hinzu. Eigene Schätzung M, etwa 2–4 Entwicklungstage einschließlich CI-Härtung und signierter Smoke-Matrix, zuzüglich Enrollment und Zertifikatsfreigabe. Kein separater Notarisierungs-Einzelpreis in den gelesenen Quellen.

**Cask:** Ja, nach bestandenem Gatekeeper-Test kann und soll dessen postflight-xattr entfallen. Normale macOS-Erststart-Bestätigung ist nicht dasselbe wie eine Blockade wegen unbekannten Entwicklers. Beim einmaligen Wechsel von bisheriger Self-/Ad-hoc-Identität zu Developer ID können bestehende TCC-Freigaben neu nötig werden; W6 darf für diese Migration keine ungeprüfte Null-Rückfragen-Garantie geben.

Quellen: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution.md, https://developer.apple.com/documentation/security/customizing-the-notarization-workflow.md, https://developer.apple.com/documentation/security/hardened-runtime.md, https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input.md, https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation.md, https://developer.apple.com/programs/enroll/, https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications, https://github.com/raine/claude-code-proxy/blob/2e2975aee754fff176765bcc2f3e582a79191751/.github/workflows/release.yml, https://github.com/RankM8/WhisperM8/blob/a8e0f35/scripts/build-dmg.sh, https://github.com/RankM8/WhisperM8/blob/a8e0f35/scripts/update-cask.sh, https://github.com/RankM8/WhisperM8/blob/a8e0f35/Makefile, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift

### 2. Homebrew: Paket-Abhängigkeiten, aktuelle Claude-/Codex-Pakete, optionale Installation, auto_updates, zap, uninstall und Adopt?

**Konfidenz:** hoch

**Ja, ausdrücklich unterstützt:** Das offizielle Cask-Cookbook dokumentiert `depends_on cask: "…"` und `depends_on formula: "…"`. Für Formeln: „one or more names of formulae needed by the current cask“. Das funktioniert auch im eigenen Tap; es ist kein Grund für Installationsbefehle in postflight.

**Aktuell direkt gelesene Homebrew-Definitionen:**
- `brew install --cask claude-code`: Homebrew/homebrew-cask, Version 2.1.292, letzter dateibezogener Commit 14.10.2026. Download direkt von `downloads.claude.ai`; ARM/Intel-SHA256 und `binary "claude"`. Aktuell Stable-Kanal, nicht zwingend neuestes Anthropic-Release. Die offizielle Claude-Doku nennt zusätzlich `claude-code@latest` für Latest; die beiden kollidieren ausdrücklich.
- `brew install --cask codex`: ebenfalls Homebrew/homebrew-cask, Version 0.163.0, letzter dateibezogener Commit 15.10.2026. Download aus openai/codex-Releases, `binary "bin/codex"`, ARM/Intel-SHA256.
- Eine aktuelle `Homebrew/homebrew-core/Formula/c/codex.rb` war nicht vorhanden (GitHub 404). Für den Launch daher nicht die historische Codex-Formel oder `depends_on formula: "codex"` voraussetzen. Die verifizierten aktuellen Pakete sind Casks. Homebrew pflegt die Definitionen gemeinschaftlich; Hersteller-Herkunft der Binärdownloads ist von Herstellerpflege des Casks zu unterscheiden.

**Produktentscheidung:** E5 b beibehalten, beide CLIs optional und erst für das gewählte Profil nach Bestätigung installieren. Harte Cask-Abhängigkeiten würden bei `dictationRaw` unnötig beide Agenten installieren, vorhandene Native-/npm-Installationen nicht als erfüllte Brew-Abhängigkeit erkennen und Pfad-/Update-Konflikte begünstigen. Weil Homebrew bereits Voraussetzung für WhisperM8 ist, ist ein expliziter, in der App geführter Brew-Installationsschritt ein einfacher möglicher Backend-Pfad; das ist nicht dasselbe wie eine zwingende Cask-Abhängigkeit. Alternativ offiziellen Native-Installer anbieten. Bestehende Installationsart respektieren und keinen zweiten Paketmanager still daneben setzen.

**Lifecycle:**
- Kein `auto_updates true` für WhisperM8, solange die App nur einen Brew-Befehl/Link anzeigt. Offiziell muss der Updater Download UND Installation durchführen; ein bloßer Check zählt nicht. `auto_updates true` verändert außerdem die normale Upgrade-Auswahl, weshalb es hier kontraproduktiv wäre.
- `uninstall quit: "com.whisperm8.app"` ist der richtige deklarative Ansatz für normalen App-Quit. Das Cookbook sagt: „It runs during both brew uninstall and brew upgrade / brew reinstall.“ Deshalb aktive Chats vor einem geführten Upgrade klar benennen, nicht überraschend beenden. Ein Quit muss Stores flushen und eigene Proxy-/Socket-Ressourcen kontrolliert schließen.
- `launchctl:` bezeichnet tatsächliche launchd-Job-Labels. Keine erfundenen IDs, kein breit gefasstes Entfernen fremder Claude-Supervisoren oder aller Proxys. Direkt gestartete Child-Prozesse werden dadurch nicht automatisch erfasst; dafür braucht die App nachvollziehbare Prozess-Ownership.
- `zap` ist ausschließlich die explizite stärkere Löschaktion: „will never be performed by default“. Eigene Preferences/Caches/App-Daten sind Kandidaten; die Löschung von Chat-Historie muss klar angekündigt sein. Keine pauschale Löschung von `~/.claude`, `~/.codex`, fremden Logins, Projektdateien oder manuell angepassten Skills. Den eigenen `~/.local/bin/whisperm8`-Symlink und verwaltete Plugin-Verweise nur nach Eigentums-/Zielprüfung entfernen. Das heutige Cask enthält nur drei trash-Pfade und keine Quit-Regel; W7 ist damit nicht nachgewiesen.

**Adopt differenzieren:** Die Brew-Manpage sagt zu `--adopt`: „existing artifacts … identical to those being installed“; nicht mit `--force` kombinierbar. `/Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/AppUpdateChecker.swift:21–26` nennt einen `--force`-Installationsbefehl `brewAdoptCommand`. Das ist ein beabsichtigtes Ersetzen durch die Cask-Version, keine identische Übernahme im Sinne von `--adopt`. Für ältere DMG-/Developer-Builds unterscheiden: identische Release-App übernehmen oder vorhandenes Bundle nach ausdrücklicher Bestätigung ersetzen, Daten unverändert erhalten und TCC-Migration erklären. README und DMG-„LIES MICH“ widersprechen heute dem beschlossenen Brew-only-Endnutzerweg; Source-Build kann im Entwicklerabschnitt bleiben.

Quellen: https://docs.brew.sh/Cask-Cookbook#stanza-depends_on, https://docs.brew.sh/Cask-Cookbook#stanza-uninstall, https://docs.brew.sh/Cask-Cookbook#stanza-zap, https://docs.brew.sh/Manpage, https://github.com/Homebrew/homebrew-cask/blob/b3ca0d8828da6c99479b8be1fa35c6cf3feb1588/Casks/c/claude-code.rb, https://github.com/Homebrew/homebrew-cask/blob/4706e3e1f04e6794b2569d9da088274db2ce3cad/Casks/c/codex.rb, https://code.claude.com/docs/en/setup, https://github.com/RankM8/WhisperM8/blob/a8e0f35/scripts/update-cask.sh, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/Shared/AppUpdateChecker.swift, https://github.com/RankM8/WhisperM8/blob/a8e0f35/README.md

### 3. E5 Geführte CLI-Installation: offizielle Installationswege, Pfade, Node/sudo, Login und GUI-Host-Vorbilder?

**Konfidenz:** hoch

**Claude Code:** Die aktuelle offizielle Quickstart-/Setup-Doku stellt `curl -fsSL https://claude.ai/install.sh | bash` als Native-Installationsweg vor. Native Installationen aktualisieren sich selbst. Launcher `~/.local/bin/claude`, Versionen unter `~/.local/share/claude/versions/`; kein Node für diesen Weg und keine sudo-Installation ins Benutzerverzeichnis erforderlich. Hersteller-Binaries sind laut Setup-Doku auf macOS von Anthropic PBC signiert und Apple-notarisiert. Alternativ `brew install --cask claude-code` beziehungsweise bewusst Latest; Updates standardmäßig über Brew. Die Setup-Doku dokumentiert inzwischen optional vom Nutzer aktivierbare Package-Manager-Autoupdates; nicht still aktivieren.

npm existiert weiter: `npm install -g @anthropic-ai/claude-code`. Wichtiges Aktualitätsdetail gegenüber älteren Anleitungen: Die gelesene Oktober-Doku nennt Node.js 22+ für npm und erklärt, dass auch das npm-Paket dasselbe Native-Binary installiert; das Binary benötigt zur Laufzeit kein Node. Die tatsächliche npm-Binärposition hängt vom globalen npm-Prefix ab. Wörtlich: „Do NOT use sudo npm install -g“. Für Laien Native oder vorhandenes Brew bevorzugen, npm nicht zum Default machen. Die Live-Doku zeigt Native zuerst, aber kein ausgelesenes pauschales Verbot des npm-Wegs.

**Codex CLI:** Offiziell `npm install -g @openai/codex`, `brew install --cask codex` und plattformspezifische GitHub-Release-Binaries. Neu gegenüber dem Juli-Stand: Das aktuell gelesene offizielle README bietet zusätzlich `curl -fsSL https://chatgpt.com/codex/install.sh | sh`; Downloads kommen standardmäßig von `releases.openai.com/codex`, mit GitHub-Fallback. Native Release/Brew verlangen kein Node; npm schon für den Paketmanager. Brew verlinkt unter seinem Prefix/bin, manuelle Release-Installation hat keinen einzigen vorgeschriebenen Zielpfad. Nicht ungeprüft ARM/Intel-Archivnamen aus alten Anleitungen hardcoden.

**Login im eingebetteten Terminal:** Ja, den unveränderten Originalprozess starten und dessen eigenen Browser-/Callback-Flow benutzen. Claude startet beim ersten `claude` den Browser, bietet `/login` und bei Bedarf einen manuellen Code-Paste im Terminal. Codex startet seinen ChatGPT-Browser-Login über `codex` beziehungsweise den CLI-Login; API-Key ist eine andere Abrechnungsart. Die Codex-Doku bestätigt: „the browser returns your credentials to Codex“. CLI speichert und refresht selbst; WhisperM8 soll weder Passwortfelder noch eigenen OAuth-Client, Token-Import oder kopierte Browsercookies anbieten. Nicht Login-Ausgabe samt Codes in Diagnose-/Terminal-Mitschnitten persistieren. Das offizielle Login kann auch in einem PTY laufen; die genaue finale App-Konfiguration ist noch praktisch zu testen.

**Anthropic klärt die zentrale Vertragsgrenze inzwischen ausdrücklich:** Unverändertes Claude Code darf in Plattformen gehostet werden, während jeder Endnutzer selbst und auf eigene Rechnung authentifiziert. Die Legal-Doku verlangt für Anbieter, die Claude Code in ihren Produkten ausführen, Zustimmung zu den Commercial Terms; sie erlaubt zugleich ausdrücklich Nutzer-Login mit eigener Subscription im unveränderten Binary. Kurzzitat: „Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription“. Nicht daraus ableiten, eigene Subscription-OAuth-Integration sei ebenfalls erlaubt: Drittentwickler dürfen Claude.ai-Credentials oder Sessiontokens nicht sammeln, speichern oder intermediieren. Marken-/Namensregeln zusätzlich beachten.

**GUI-Vorbild, aktuelle Primärdoku:** Zed unterscheidet jetzt explizit External Agents/ACP und Terminal Threads. Bei Terminal Threads besitzt die CLI „authentication“, „subscriptions or API keys“ und native Konfiguration selbst. Das passt zu WhisperM8. Zeds ACP-Registry-Installation ist ein Vorbild für geführten Ablauf und getrennte Zuständigkeiten, nicht für einen Wechsel weg von echten PTYs. Happy ist kein belastbarer unveränderter Juli-Architekturvergleich mehr: Das heutige README trennt Original-CLI, Desktop und eigenen Happy Harness. Seine Subscription-Werbung ist keine Nutzungsfreigabe durch einen Provider.

**Übertragbarer Ablauf:** vorhandenes Binary/Installationsart entdecken → erklären, welches offizielle Paket benötigt wird und welche Kosten/Accounts separat bestehen → ausdrückliche Installation bestätigen → Installer im sichtbaren Terminal ausführen → Exitstatus, Signatur beziehungsweise Paketidentität und `--version` prüfen → Login in eigener Original-CLI → Funktionstest. Keine Root-Installation, kein stilles Überschreiben vorhandener CLIs, keine Paketmanager-Mischung, kein eigenes Auth-Backend. Umsetzung F-APP-01/F-AC-02/F-DIK-09, neue kleine Installationszustandsmaschine neben `AgentCommandBuilder`/`LoginShellEnvironment`, Aufwand M.

Quellen: https://code.claude.com/docs/en/quickstart, https://code.claude.com/docs/en/setup, https://code.claude.com/docs/en/authentication, https://code.claude.com/docs/en/legal-and-compliance, https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/README.md, https://developers.openai.com/codex/auth, https://zed.dev/docs/ai/terminal-threads, https://zed.dev/docs/ai/external-agents, https://github.com/slopus/happy/blob/55ab69f869d4b1b2cc0236a2c3f08e2f57a6701c/README.md

### 4. E3 Mehrere Claude-Konten: mehrere Abos, Kontowechsel, Automatisierung und Rate-Limit-Risiko?

**Konfidenz:** mittel

**Technisch ausdrücklich dokumentiert, nicht pauschal verboten:** Die heute direkt gelesene offizielle Authentication-Doku besitzt „Log in with multiple accounts“. Sie empfiehlt eigene `CLAUDE_CONFIG_DIR`s beispielsweise für berufliche und persönliche Accounts. Die Env-Doku sagt wörtlich: „Useful for running multiple accounts side by side“. Damit ist die entsprechende Kernaussage der Juli-Analyse weiterhin richtig. Eine Garantie, beliebig viele Max-Abos derselben Person zur additiven Dauerlast nutzen zu dürfen, ist das nicht. In den gelesenen Primärtexten wurde weder ein generelles Ein-Konto-pro-Person-Gebot noch eine umfassende Freigabe automatischer Abo-Rotation gefunden.

**Vertragsgrenzen:** Die abgerufenen Consumer Terms verbieten Account-/Credential-Sharing und nennen automatisierten Zugriff außerhalb API/ausdrücklicher Erlaubnis sowie „bypassing any of our systems or protective measures“. Die aktuelle Claude-Code-Legal-Doku ordnet Pro-/Max-Limits „ordinary, individual usage“ zu und enthält eine ausdrückliche Host-Ausnahme für den Nutzerlogin ins unveränderte CLI-Binary. Diese Ausnahme ist der sachgerechte Primärbeleg für WhisperM8; alte Meldungen, sämtliche externen Terminal-Hosts seien wegen OAuth verboten, sind dafür zu grob beziehungsweise veraltet.

**Unterscheidung für den Launch:**
- Nutzer wählt selbst ein getrennt angemeldetes berufliches/persönliches Konto, WhisperM8 startet das Original-CLI mit diesem Config-Root: durch Doku gestütztes Modell.
- Ein vom Nutzer vorgemerkter Wechsel nach Turn-Ende ist nicht automatisch dasselbe wie Rate-Limit-Umgehung. Die Doku genehmigt allerdings nicht ausdrücklich jede implementierte Automatik.
- Unbeaufsichtigtes Drehen zum nächsten Abo bei 429, Sperre oder Verbrauchsgrenze, Pooling/Weiterverkauf fremder Konten oder Werbung „Limits umgehen“: erheblich höheres Vertrags-/Sperrrisiko. Nicht als Launch-Versprechen anbieten. Keine belegte numerische Sperrwahrscheinlichkeit.

**Wichtiger neuer Prüfpunkt über die Anzahl der Konten hinaus:** Die aktuelle offizielle Legal-Doku sagt: „developers may not collect, store, or intermediate Claude.ai credentials or session tokens“. Die heute tatsächlich gelesene WhisperM8-Implementierung liest/verschiebt jedoch OAuth-Keychain-Secrets beim Profil-Rename und Promote. `/Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:460–477` liest per `security find-generic-password -w` und schreibt den Wert in argv von `security add-generic-password … -w`. `/Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeAccountProfiles+Promote.swift:91–112,219–221` hat denselben grundsätzlichen Umgang. Außerdem benennt `ClaudeAccountUsageFetcher.swift:87,213,236` den direkten inoffiziellen OAuth-Usage-Endpoint und verarbeitet das Token außerhalb der CLI.

Das ist sowohl eine konkrete Sicherheitsbaustelle als auch ein ernsthafter Klärungspunkt zur Credential-Grenze; keine abschließend juristisch festgestellte Vertragsverletzung. Den Juli-Befund N10 nicht als erledigt betrachten: Der gelesene aktuelle Code enthält das argv-Muster weiterhin, nun zusätzlich im Promote-Pfad. Ein Wechsel zu Security.framework würde argv-Exposition beheben, aber nicht automatisch die Vertragsfrage des externen Token-Handlings.

**Empfehlung für E3 a:** Erweitert beibehalten für getrennte, vom Nutzer gewählte Native-CLI-Profile. Öffentliches Release an zwei Nachweise knüpfen: secrets-freier Hostpfad beziehungsweise Klärung der Credential-Migrations-/Usage-Ausnahme mit Anthropic und keine automatische limitgetriebene Rotation. Offizielle Login-/Logout-Flows bevorzugen; Profile möglichst durch Anzeigenamen statt physische Credential-Migration umbenennen. F-KO-01/02/05 gezielt prüfen, F-KO-03/04 zusätzlich als Datenfreigabe zwischen Konten sichtbar machen. Allgemeine Mehrkonten-Doku allein reicht nicht zur Freigabe sämtlicher fünf Unterfunktionen.

Quellen: https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts, https://code.claude.com/docs/en/env-vars, https://code.claude.com/docs/en/legal-and-compliance, https://www.anthropic.com/legal/consumer-terms, https://www.anthropic.com/legal/commercial-terms, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/AgentChats/ClaudeAccountProfiles%2BPromote.swift, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift

### 5. E2 Inoffizielle OpenAI-Upstreams: Vertragslage, Nutzer-/Herausgeberrisiken und Kennzeichnung anderer Projekte?

**Konfidenz:** mittel

**Nicht gleichsetzen:** (a) offizielle Codex-CLI mit eigenem ChatGPT-Login, (b) fremder Coding-Harness mit Codex-Subscription-Anbindung und (c) selbst nachgebildeter ChatGPT-Transkriptionsendpoint sind unterschiedliche Fälle. Ein HTTP-Pfad `backend-api` beweist allein weder Erlaubnis noch Verbot. Die offene Apache-2.0-Lizenz des Codex-Codes lizenziert nicht automatisch jede Nutzung des gehosteten Dienstes.

**Quellenlage transparent:** Die aktuellen OpenAI-EU-Terms waren beim direkten Abruf durch HTTP 403 nicht vollständig lesbar. Der offizielle Suchindex lieferte kurze Klauseln, darunter „Automatically or programmatically extracting data or Output“ und das Recht, „restrict, suspend, or terminate“ bei Vertragsverletzungen/Risiken. Die Formulierung zur Umgehung von Rate-Limits war im offiziellen Dezember-2024-EU-Archiv indexiert; ihre unveränderte aktuelle Fassung konnte nicht volltextverifiziert werden. Deshalb keine abschließende Oktober-2026-Rechtsfreigabe oder pauschale Aussage „jeder Proxy verletzt nachweislich die AGB“.

**Wichtige Gegen-Evidenz zur pauschalen Verbotsbehauptung:** Codex-Verantwortlicher Thibault Sottiaux erklärte öffentlich, Entwickler könnten auf dem offenen Codex aufbauen, „which includes ChatGPT login and same usage as you get in codex“. Das ist eine zurechenbare öffentliche Primäräußerung, aber weder individuell erteilte Integrationserlaubnis noch Ersatz der Nutzungsbedingungen. Die offizielle Codex-Auth-Doku unterstützt selbst ChatGPT-Subscription-Login und beschreibt Proxy-/Custom-Provider-Konfigurationen. Daraus folgt keine automatische Freigabe des separaten ChatGPT-Transkriptionsendpoints.

**Proxy selbst geprüft:** `raine/claude-code-proxy`, MIT, gelesener Commit 2e2975a vom 10.10.2026, Release v0.1.45. README-Warnung: „Unofficial clients may carry account risk.“ Die Compatibility-Doku sagt ausdrücklich, öffentliche OpenAI-Aussagen garantierten keine künftige Policy oder Kontobehandlung. Der Code `src/providers/codex/transcription.rs` setzt `https://chatgpt.com/backend-api` als Transkriptionsbasis. Damit ist F-DIK-03 technisch klar von `/v1/audio/transcriptions` der dokumentierten OpenAI-API zu trennen.

**Risiken:**
- Nutzer: mögliche Einschränkung/Sperre bei beanstandeter Nutzung, widerrufene Tokens, laufende Retries/Quota-Verbrauch, jederzeitige Endpoint-Änderung, andere Speicher-/Trainingseinstellungen als bei API-Nutzung. Keine belastbare Sperrquote gefunden. Für normale Codex-Nutzung im fremden Coding-Harness ist das öffentliche Unterstützungssignal günstiger als für den nachgebildeten Transkriptionsendpoint.
- Herausgeber: kein belegter Automatismus, dass schon die Veröffentlichung des MIT-Proxy-Codes persönliche Haftung erzeugt. Relevant bleiben eigene Vertragsbindungen, konkrete Ausgestaltung und Werbung, Marken-/Lizenzpflichten, irreführende „offiziell unterstützt“-Zusagen, Datenschutz und die Sicherheit des ausgelieferten Download-/OAuth-Pfads. Ein Labs-Hinweis oder MIT-Haftungsausschluss beseitigt diese Pflichten nicht.
- Betriebsrisiko: aktuelles Proxy-README warnt vor fehlender Client-Authentifizierung am lokalen Listener; Loopback begrenzt Netzwerkzugriff, ersetzt aber keine Authentisierung gegenüber anderen lokalen Prozessen. Die Compatibility-Doku warnt außerdem, dass aktivierte Traffic-Captures Prompts und Tool-Inhalte erhalten können.

**E2 b ist richtig, aber mit getrennten Risikohinweisen:** F-GPT-01/02 und F-DIK-03 ausschließlich opt-in unter Labs, nicht im Onboarding. Vor Aktivierung kurz erklären: unabhängiges Projekt, keine Zusage von OpenAI/Anthropic, Konto-/Ausfallrisiko, verwendeter Dienst und Konto, Quota-/Kosten- und Datenschutzunterschiede, jederzeit ausschaltbar. Keine automatische Aktivierung, keine versteckte Übernahme des CLI-Logins und keine Limit-Rotation. Für F-DIK-03 keine pauschale Zusage „wie OpenAI API“ oder unbelegte serverseitige Löschfrist. Offizielle API-Transkription bleibt der dokumentierte Kernweg. Proxy-Downloadvertrauen und Kill-Switch müssen auch bei Labs das Sicherheitsniveau der Kern-App erfüllen.

Quellen: https://openai.com/policies/eu-terms-of-use/, https://openai.com/policies/dec-2024-eu-terms/, https://x.com/thsottiaux/status/2009714843587342393, https://developers.openai.com/codex/auth, https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/LICENSE, https://github.com/raine/claude-code-proxy/blob/2e2975aee754fff176765bcc2f3e582a79191751/README.md, https://github.com/raine/claude-code-proxy/blob/2e2975aee754fff176765bcc2f3e582a79191751/src/providers/codex/transcription.rs, https://claude-code-proxy.raine.dev/reference/compatibility-and-limitations/

### 6. Datenschutz-Pflichtangaben für Audio-, Screenshot- und Kontextübertragung aus EU-Perspektive?

**Konfidenz:** hoch

**Keine Rechtsberatung; übliche belastbare Praxis:** Open Source und BYOK ersetzen keine Transparenz. Zunächst pro Datenfluss die Rolle klären: Ein bloßer lokaler Softwareherausgeber ist nicht automatisch Auftragsverarbeiter sämtlicher direkt vom Nutzer an dessen Provider gesendeten Inhalte. Soweit der Herausgeber eigene Datenverarbeitungen bestimmt, etwa Telemetrie, Support oder eigene Server, gelten seine eigenen Pflichten. Geschäftliche Nutzer haben zusätzlich Verantwortung für Kunden-/Beschäftigten-/Drittpersonendaten. Nicht behaupten, ein allgemeiner Onboarding-Klick legalisiere jede Übertragung.

**Direkt gelesene Primärquellen:** Die irische Datenschutzaufsicht verlangt Informationen „At the time your personal data is collected“. Die EU-Kommission nennt „concise, transparent, intelligible“ und „clear and plain language“. DPC führt die Art.-13-/14-Informationen und die sechs möglichen Rechtsgrundlagen auf. Deren Anwendbarkeit bleibt verarbeitungsspezifisch; Einwilligung ist nicht stets die einzige oder richtige Rechtsgrundlage.

**Mindestens erklären, soweit einschlägig:**
1. Verantwortlicher und Kontakt; DSB/Vertreter nur wenn einschlägig. Rollen von WhisperM8-Herausgeber, Nutzer und Dienstanbietern verständlich trennen.
2. Welche Daten zu welchem Zweck erfasst und verschickt werden: Mikrofon-Audio zur Transkription; erkannter Text, markierter Text, ausgewählter Screenshot/Screen-Clip, aktiver Chat-Auszug und gegebenenfalls Projektinhalte zur Nachbearbeitung; eigene technische Update-/Diagnoseanfragen getrennt. Nicht pauschal „alles bleibt lokal“ schreiben.
3. Rechtsgrundlage pro eigener Verarbeitung; gegebenenfalls berechtigte Interessen, Freiwilligkeit/Pflicht und Folgen des Nichtbereitstellens. Screenshot/Kontext abschaltbar und ohne diese Erweiterung weiter diktieren können.
4. Empfänger konkret: OpenAI API oder Groq beim Audio; OpenAI/Codex mit ausgewähltem Login und Modell bei Nachbearbeitung; gegebenenfalls Anthropic bei Agent-Hilfsfunktionen sowie konfigurierte MCP-/Tool-Dienste. Ein lokaler Proxy ist keine lokale Modellverarbeitung. GitHub für Release-/Proxy-Downloads separat benennen, falls tatsächlich verwendet.
5. Drittlandübertragung, Zielräume und einschlägige Garantien/Verträge; keine EU-Residenz aus macOS oder deutschem UI ableiten. Geschäftliche Nutzung: anwendbare Auftragsverarbeitungs-/Transfervereinbarungen prüfen, nicht durch den MIT-Hinweis ersetzen.
6. Lokale und serverseitige Aufbewahrung/Löschung getrennt: temporäre Audiodateien/Screenshots, Fehlerfälle, App- und CLI-Transcripts, Archive, Logs/Backups; Provider-Retention und Trainingseinstellungen verlinken. App-Zap löscht nicht automatisch fremde CLI-Historie oder Cloud-Daten.
7. Auskunft, Berichtigung, Löschung, Einschränkung, Widerspruch und gegebenenfalls Übertragbarkeit; Einwilligungswiderruf soweit einschlägig; Beschwerderecht. Erklären, welche Löschung die App durchführen kann und wofür der Provider zuständig ist.
8. Automatisierte Entscheidungen/Profiling nur wenn tatsächlich relevant; Textumformulierung nicht pauschal als Art.-22-Entscheidung ausgeben. Auf sensible Inhalte und Rechte Dritter hinweisen; TCC-Zugriffserlaubnis ist keine generelle DSGVO-Freigabe für Datenabfluss.

**Aktuelle Providerdetails korrigieren vereinfachende Aussagen:**
- OpenAI API: Doku sagt „not used to train … unless you explicitly opt in“. Für `/v1/audio/transcriptions` und `/v1/audio/translations` nennt die aktuelle Endpoint-Tabelle sowohl Abuse Monitoring als auch Application State `None`. Die häufige pauschale Behauptung „OpenAI speichert jedes Audio 30 Tage“ ist für diesen API-Pfad falsch. Das ist keine Zusage, dass keinerlei Betriebsmetadaten existieren.
- Groq: „By default, Groq does not retain customer data for inference requests“, aber Ausnahme für Systemzuverlässigkeit/Missbrauch mit bis zu 30 Tagen; Nutzungsmetadaten bleiben. ZDR ist konfigurierbar. Doku nennt US-GCP-Speicherung. Daher weder generell „null Speicherung“ noch generell „jedes Audio 30 Tage“ behaupten.
- Codex: Offizielle Auth-Doku unterscheidet ChatGPT-Workspace-Regeln und API-Organisationsregeln. Die Nicht-Training-/Retention-Aussage des OpenAI-Audio-API-Pfads nicht auf ChatGPT-Login, Screenshots, Antworten oder den Proxy-Transkriptionsendpoint übertragen.

**Konkrete UX für WhisperM8:** Eine kurze Datenflusskarte im Onboarding, vollständige dauerhaft erreichbare Datenschutzseite und kontextbezogener Hinweis vor dem ersten Screenshot-/Chat-Kontext-Upload. Im Aufnahme-/Ergebnisablauf Provider, Nachbearbeitung und angehängte Kontextarten sichtbar machen, Auswahl vorher prüfbar. Diagnoseexport standardmäßig ohne Audio, Prompts, Tokens und Bilder; keine versteckten automatischen Uploads. Für F-DIK-02/03/06/07/08/09 und F-AC-07 Retention tatsächlich im Code inventarisieren, nicht nur Text ergänzen. Aufwand M für UX/Inventar, juristische Rollen-/Vertragsprüfung separat.

Quellen: https://www.dataprotection.ie/en/individuals/know-your-rights/right-be-informed-transparency-article-13-14-gdpr, https://commission.europa.eu/law/law-topic/data-protection/information-business-and-organisations/principles-gdpr/what-information-must-be-given-individuals-whose-data-collected_en, https://eur-lex.europa.eu/eli/reg/2016/679/oj/eng, https://platform.openai.com/docs/guides/your-data, https://console.groq.com/docs/your-data, https://developers.openai.com/codex/auth

## Übertragbar auf WhisperM8

### B4-R01 · Notarisierte Releases zwingend durchsetzen

*Priorität hoch · Aufwand M · Features F-APP-04, F-APP-07 · Entscheidung E4*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/.github/workflows/release.yml und /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/scripts/build-dmg.sh temporäre Signing-Keychain, API-Key-Notarisierung, Accepted-/Log-Prüfung und Stapling als zwingende Release-Gates integrieren; fehlendes Frameworks-Verzeichnis abfangen. Cask-xattr erst nach sauberem Gatekeeper-Smoke entfernen. TCC-Identitätsmigration separat prüfen.

**Begründung:** Der aktuelle Release-Job veröffentlicht ad hoc; der vorhandene optionale Notary-Pfad überspringt fehlende Credentials. Unter Developer ID droht zusätzlich der ungeschützte Frameworks-find-Scan zu scheitern. E4 und W1 sind damit noch nicht erfüllt.

Quellen: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution.md, https://developer.apple.com/documentation/security/customizing-the-notarization-workflow.md, https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications, https://github.com/RankM8/WhisperM8/blob/a8e0f35/scripts/build-dmg.sh

### B4-R02 · Proxy-Download eigenständig absichern

*Priorität hoch · Aufwand M · Features F-GPT-03 · Entscheidung E4/E2*

Für /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift einen separaten signierten/notarisierten Asset-Vertrag definieren, Signer/Integrität prüfen und automatisches xattr-Löschen beenden. Bis dahin keine Aussage, E4 habe sämtliche Gatekeeper-Umgehungen beseitigt; Labs-Download darf keinen Kern-Sicherheitsvorbehalt umgehen.

**Begründung:** Das Proxy-Installationsmodul entfernt unabhängig vom Cask die Quarantäne. Die App-Notarisierung deckt zukünftige Downloads nicht automatisch ab; SHA-Sidecar desselben Releases authentifiziert keinen unabhängigen Herausgeber.

Quellen: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow.md, https://github.com/raine/claude-code-proxy/blob/2e2975aee754fff176765bcc2f3e582a79191751/.github/workflows/release.yml, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/AgentChats/ClaudeCodeProxyBinaryInstaller.swift

### B4-R03 · OAuth-Secret-Migration separat sperren und klären

*Priorität hoch · Aufwand M · Features F-KO-01, F-KO-05 · Entscheidung E3*

Token-Umgang in /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeAccountProfiles+Promote.swift und /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/ClaudeAccountUsageFetcher.swift vor Launch gesondert freigeben lassen beziehungsweise CLI-eigene Alternativen entwerfen. argv-Secrets sofort als Sicherheitsbefund ins Register übernehmen. Security.framework alleine löst die Vertragsfrage nicht.

**Begründung:** Die aktuelle Legal-Doku erlaubt Native-CLI-Hosting, untersagt Drittentwicklern aber externes Credential-/Token-Intermediieren. Rename und Promote lesen OAuth-Secrets und geben sie in argv weiter; der Juli-N10-Befund ist im gelesenen aktuellen Code weiterhin vorhanden.

Quellen: https://code.claude.com/docs/en/legal-and-compliance, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/AgentChats/ClaudeAccountProfiles%2BPromote.swift

### B4-R04 · Geführte Installation ohne eigene Auth-Schicht

*Priorität hoch · Aufwand M · Features F-APP-01, F-AC-02, F-DIK-09 · Entscheidung E5*

Im Onboarding profilabhängig nur benötigte CLI anbieten. Installationsart entdecken, offiziellen Installer oder explizit bestätigtes Brew verwenden, Ergebnis prüfen und Original-CLI-Login im eingebetteten Terminal durchführen. Bestehende Installationen respektieren, kein sudo/npm-Default und kein Token-Import. Kleine testbare Installationszustandsmaschine beim bestehenden AgentCommandBuilder-/LoginShellEnvironment-Subsystem vorsehen.

**Begründung:** Beide Hersteller dokumentieren native Installations-/Browser-Login-Wege; zwingende Cask-Abhängigkeiten würden Raw-Diktat mit unnötigen CLIs belasten. Native CLI-Hosts sind gegenüber eigenen OAuth-Clients rechtlich und technisch deutlich besser abgegrenzt.

Quellen: https://code.claude.com/docs/en/setup, https://code.claude.com/docs/en/authentication, https://code.claude.com/docs/en/legal-and-compliance, https://github.com/openai/codex/blob/ce0323f2f2d3b25e82806cd555237da3db4e1897/README.md, https://developers.openai.com/codex/auth

### B4-R05 · Zwei verschiedene Labs-Risikoklassen erklären

*Priorität hoch · Aufwand S · Features F-GPT-01, F-GPT-02, F-GPT-03, F-DIK-03 · Entscheidung E2*

Labs-Einwilligung in den jeweiligen Settings getrennt für Coding-Proxy und Abo-Transkription formulieren: tatsächlicher Dienst, Konto, inoffizieller Integrationsstatus, Ausfall-/Kontorisiko, Datenschutz und Ausschalter. Aus Onboarding fernhalten; keine offizielle Unterstützung oder unbelegte Speicherfrist zusagen. Aktuelle OpenAI-EU-AGB vor Freigabe noch einmal vollständig und datiert prüfen.

**Begründung:** Codex-Harness-Unterstützung ist kein Nachweis für den ChatGPT-Transkriptionsendpoint. Ein gemeinsames pauschales Proxy-Verbot wäre ebenso unbelegt wie eine pauschale Freigabe.

Quellen: https://github.com/raine/claude-code-proxy/blob/2e2975aee754fff176765bcc2f3e582a79191751/README.md, https://claude-code-proxy.raine.dev/reference/compatibility-and-limitations/, https://openai.com/policies/eu-terms-of-use/, https://x.com/thsottiaux/status/2009714843587342393

### B4-R06 · Brew-Uninstall und Update sicher abschließen

*Priorität hoch · Aufwand M · Features F-APP-04, F-APP-05, F-APP-06, F-GPT-03, F-AUT-02*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/scripts/update-cask.sh deklarativen Quit und eigentumsbewusstes Cleanup definieren. App-Quit muss nur eigene Prozesse stoppen, Socket schließen und Stores flushen. Zap-Löschumfang mit Warnung und Eigentumsmanifest für Symlink/Plugin-Verweise testen; fremde CLIs und deren Histories nie pauschal löschen. Upgrade-Quit aktiver Chats vorher erklären.

**Begründung:** Das heutige Cask besitzt keinen Quit-Schritt. launchctl allein erfasst direkt gestartete Proxys nicht. W7 verlangt außerdem, fremde CLI-Konfiguration unbeschädigt zu lassen.

Quellen: https://docs.brew.sh/Cask-Cookbook#stanza-uninstall, https://docs.brew.sh/Cask-Cookbook#stanza-zap, https://github.com/RankM8/WhisperM8/blob/a8e0f35/scripts/update-cask.sh

### B4-R07 · Datenschutz an tatsächlichen Datenflüssen erklären

*Priorität hoch · Aufwand M · Features F-DIK-02, F-DIK-03, F-DIK-06, F-DIK-07, F-DIK-08, F-DIK-09, F-AC-07, F-APP-01*

Datenfluss-/Retention-Inventar für Dictation-, Context-, PostProcessing- und Summary-Subsystem erstellen. Daraus kurze Onboarding-Datenflusskarte, erste kontextspezifische Upload-Hinweise und dauerhaft erreichbare Datenschutzseite ableiten. Rechte, Provider, Konten, Drittlandtransfer, lokale Löschung und Provider-Einstellungen konkret erklären; keine generische Alles-lokal-/Kein-Training-Zusage.

**Begründung:** API, ChatGPT-Subscription, Codex und lokale Speicherung unterliegen unterschiedlichen Regeln. Insbesondere nennt OpenAI für API-Audiotranskription aktuell keine Inhaltsretention; pauschale 30-Tage-Aussagen wären falsch.

Quellen: https://www.dataprotection.ie/en/individuals/know-your-rights/right-be-informed-transparency-article-13-14-gdpr, https://platform.openai.com/docs/guides/your-data, https://console.groq.com/docs/your-data, https://developers.openai.com/codex/auth

### B4-R08 · Kontoverwaltung von Limit-Rotation abgrenzen

*Priorität mittel · Aufwand S · Features F-KO-01, F-KO-02, F-KO-03, F-KO-04 · Entscheidung E3*

E3 Erweitert beibehalten: Nutzer wählt Konto und Wechselziel selbst, kein 429-/Sperr-Failover und keine Werbung zur Limit-Umgehung. Profilisolation, vorgemerkten Wechsel und bewusst kontenübergreifend geteilte Daten getrennt erklären; keine Produktzusage über beliebig addierbare Abos machen.

**Begründung:** Mehrere Config-Roots sind offiziell dokumentiert; daraus folgt keine uneingeschränkte Freigabe automatisierter Kontingentrotation. Gemeinsames Memory/MCP überschreitet zusätzlich die sonst beworbene Kontentrennung.

Quellen: https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts, https://code.claude.com/docs/en/env-vars, https://code.claude.com/docs/en/legal-and-compliance, https://www.anthropic.com/legal/consumer-terms

### B4-R09 · Adopt-Semantik und Brew-only-Doku korrigieren

*Priorität mittel · Aufwand S · Features F-APP-04*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/AppUpdateChecker.swift Übernahme und Ersetzung verständlich unterscheiden. In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/README.md und /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/scripts/build-dmg.sh ausschließlich Brew als Endnutzerweg erklären; Entwickler-Builds separat lassen. Kein auto_updates true für einen bloßen Update-Hinweis.

**Begründung:** Der als Adopt bezeichnete Code verwendet --force; echtes --adopt setzt identische Artefakte voraus. README und DMG-Beipacktext bewerben weiterhin andere Endnutzer-Installationswege.

Quellen: https://docs.brew.sh/Manpage, https://docs.brew.sh/Cask-Cookbook, https://github.com/RankM8/WhisperM8/blob/a8e0f35/WhisperM8/Services/Shared/AppUpdateChecker.swift, https://github.com/RankM8/WhisperM8/blob/a8e0f35/README.md
