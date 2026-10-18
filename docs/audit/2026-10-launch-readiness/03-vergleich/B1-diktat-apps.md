---
status: roh
updated: 2026-10-17
description: Workflow B, B1 Diktat-Apps — Vergleich mit anderen Projekten und Rahmenbedingungen (aus der strukturierten Agent-Rückgabe erzeugt).
---

# B1 Diktat-Apps

## Kurzfazit

B1 Diktat-Apps: Recherche abgeschlossen, Stand 17.10.2026. Vier Open-Source-Projekte anhand gepinnter Quellstände untersucht; Superwhisper, Wispr Flow und MacWhisper ausschließlich anhand öffentlicher Doku. Keine fremden Programme ausgeführt, keine Builds/Tests und keine Projektänderungen. Die angeforderte Berichtsdatei wurde wegen der übergeordneten Vorgabe, keine Bericht-.md-Dateien zu schreiben, nicht angelegt; die Inhalte stehen vollständig in dieser strukturierten Ausgabe.

Kurzfazit: Für den beschlossenen Cloud-Launch sind sichere Textzustellung, verständliche Rechte-Reparatur, transparente Datenflüsse und wiederauffindbare Aufnahmen wichtiger als zusätzliche Provider. Lokale STT ist ein starkes Produktargument, aber kein automatisch hinzuzufügender Launch-Blocker. Developer-ID/Notarisierung bleibt gemäß E4 verbindlich; Brew bleibt alleiniger Installations-/Updatekanal.

Korrekturen zur Juli-Analyse: Der vermeintlich fehlende CoreAudio-Geräte-Listener existiert bereits in AudioDeviceManager.swift. installTap ist inzwischen durch ObjCException.catching abgesichert; die damalige pauschale Crash-Aussage ist veraltet. Handys aktuelle Hauptentwicklung verwendet handy-recorder und durchgehend transcribe-cpp, nicht mehr die im Juli beschriebenen internen Recorder-/ONNX-Pfade. Whispering ist auf aktuellem main ein ausdrücklich unveröffentlichter Voice-Notes-Neuaufbau ohne Diktat in fremde Apps; das veröffentlichte v7.11.0 stammt vom 27.12.2025. Aktive Monorepo-Entwicklung darf nicht mit einer aktuellen Whispering-Auslieferung gleichgesetzt werden. Die Juli-Aussage, kein anderer Kandidat könne vergleichbaren Kontext, ist spätestens mit OpenWhisprs Screenshot-/Assistant-Pipeline zu relativieren.

Was WhisperM8 schon gut macht: profilabhängiger Einstieg; Bildschirmrecht nicht im Basis-Onboarding; echte Codex-CLI statt zusätzlichem eigenen Agent-Runtime-Stack; differenzierte Kontext-/Attachment-Pipeline; vorhandener vollständiger PasteboardSnapshot für Selektions-Erfassung; dauerhaft gesicherte fehlgeschlagene Transkriptionen mit begrenzter Aufbewahrung; gezielter ObjC-Exception-Schutz und bestehende Regressionstests. Das sind belegte Stärken, kein pauschaler Vorsprung gegenüber allen Wettbewerbern.

Offene Fragen: Rechte-/Update-Matrix auf frischen macOS-14/15/26-Systemen und nach verweigerten Rechten praktisch prüfen; tatsächliche Release-Binaries wurden nicht auf Apple-Tickets untersucht. Erreichbarkeit alter FailedRecordings nach App-Neustart verifizieren. Für lokale STT fehlen aktuelle eigene Deutsch-/Code-Switching-, Speicher- und Cold-Start-Messungen. Konkurrierende Zwischenablageänderungen, mehrere Fenster derselben Ziel-App sowie langsame Clipboard-Verbraucher brauchen gezielte Zustellungs-QA. MacWhispers ältere Supportartikel sind für heutige Preise und Providerumfang nicht belastbar.

## Untersuchte Projekte und Quellen

| Name | URL | Lizenz | Geprüft über | Relevanz |
|---|---|---|---|---|
| VoiceInk | https://github.com/Beingpax/VoiceInk | GPL-3.0 laut LICENSE; GitHub-API meldet NOASSERTION | code | Nächste native Swift-/SwiftUI-Referenz. Gelesener Commit 9ce98ec81f96517868717d7a7a47818b71281d3f vom 16.10.2026; jüngstes Release v2.21 vom 28.09.2026. Rund 6.842 Sterne nur als Kontext. Besonders relevant: OnboardingPermissionController, CursorPaster, CoreAudioRecorder, ScreenCaptureService und Sparkle-Anbindung. Architekturideen übernehmen, nicht ungeprüft GPL-Code transplantieren. |
| Handy | https://github.com/cjpais/Handy | MIT | code | Rust/Tauri-/React-App, kein Swift-native Vorbild und kein Anlass zum Stack-Wechsel. Commit 9e57a0d7929fcc6417ea0d6e54c1b57f62635edd vom 15.10.2026; Release v0.9.8 vom 03.10.2026; rund 34.012 Sterne. Besonders relevant: lokale Modellverwaltung, Recorder-Fehlerklassifikation, Clipboard-Restore und experimentelle receipt-basierte Paste-Transaktionen. |
| OpenWhispr | https://github.com/OpenWhispr/openwhispr | MIT | code | Electron-/React-App. Commit 3577e5c9b2b06f7667a4b9d489935addba488341 vom 16.10.2026; Release v1.10.3 vom 12.10.2026; rund 9.501 Sterne. Relevant: persistenter Onboarding-Zustand, optionale Bildschirmfreigabe, lokale/cloudbasierte Verarbeitung, Clipboard-Schutz und Crash-Recovery-Spool. Kein Architekturvorbild für Dateigrößen oder Stack. |
| Whispering / Epicenter | https://github.com/EpicenterHQ/epicenter | Aktueller Stand AGPL-3.0-or-later, auch apps/whispering/package.json | code | Commit 7cc869b4a1295e2566b61e1a4d5967a89f413b9b vom 17.10.2026. Aktuelles apps/whispering ist laut README ein unveröffentlichter Voice-Notes-Neuaufbau ohne Cross-App-Diktat; jüngstes veröffentlichtes Release v7.11.0 vom 27.12.2025. Relevant sind explizite Datenhaltung und präzise Fehler-/Übertragungssemantik; ergänzend wurde Epicenters native Clipboard-Implementierung gelesen. Keine Gleichsetzung dieser unterschiedlichen Produktpfade. |
| Whispering, altes Repository | https://github.com/braden-w/whispering | — | doku | Archiviert; letzter Push 25.09.2025, rund 291 Sterne. Nicht als aktuell gepflegte Konkurrenz zählen; Entwicklung und Veröffentlichungen über Epicenter getrennt betrachten. |
| Superwhisper | https://superwhisper.com/docs/llms-full.txt | Proprietär; kein Quellcode untersucht | doku | Offizielle Doku zu drei getrennten Kontextarten, lokal/cloudbasierter Verarbeitung, Clipboard-Wiederherstellung, History und Wiederverarbeitung. Homebrew-Cask am Recherchetag bei 3.0.1. Dokumentierte Produktfunktionen, keine Laufzeitverifikation. |
| Wispr Flow | https://docs.wisprflow.ai/articles/7682075140-how-to-install-wispr-flow-on-mac | Proprietär; kein Quellcode untersucht | doku | Offizielle Installations-, Rechte-Reparatur- und Datenschutzdoku. Sehr relevant: verständliche Rechtebegründungen und getrennte Schalter für Kontext, Training und Cloud-Speicherung. Aktuelle Kontextdoku sagt ausdrücklich: keine Screenshots. Homebrew-Cask am Recherchetag bei 1.6.1174. |
| MacWhisper | https://docs.macwhisper.com/ | Proprietär; kein Quellcode untersucht | doku | Offizielle Dictation- und WhisperKit-Doku sowie offizieller Homebrew-Cask. Relevant: geführter Diktat-Einstieg, Modell-Download und Erklärung einmaliger Modellvorbereitung. Supportartikel teilweise alt; keine aktuellen Preis-/Providerzusagen daraus ableiten. Cask am Recherchetag bei 15.6,1553. |
| FluidAudio | https://github.com/FluidInference/FluidAudio | — | code | Ergänzender Aktualitätscheck zum vorhandenen lokalen-STT-Spike: aktuelles Package.swift und README sowie Release-Metadaten gelesen; jüngstes Release v0.17.7 vom 08.10.2026. Swift-6-Manifest und macOS-14-Basis weiterhin vorhanden. Keine erneute vollständige API-, Modelllizenz- oder Benchmarkverifikation. |

## Antworten auf die Fragestellungen

### 1. Onboarding: Reihenfolge, Rechte, Ablehnung und Bedienungshilfen-Neustart

**Konfidenz:** hoch

VoiceInks aktueller Ablauf ist Rechte → Mikrofonwahl → Transkriptionsmodell → API-Einrichtung für Enhancement → Übungen → Kontext → Datenschutz/Vertrauen → Lizenz. Mikrofon und Bedienungshilfen sind erforderlich, Bildschirmaufnahme ist optional. Rechte haben eigene Zustände einschließlich denied/restricted; bei verweigertem Mikrofon öffnet der nächste Versuch die Systemeinstellungen statt denselben wirkungslosen Dialog. Der Controller prüft nach einer Aktion zeitlich begrenzt erneut. Ein eigener automatischer Accessibility-Neustart wurde dort nicht gefunden.

Handy zeigt zuerst Mikrofon/Accessibility und danach die Modellauswahl; es prüft auch bei zurückkehrenden Nutzern fehlende Rechte. Status-Polling und Fehler-Toast sind vorhanden, aber kein belegter spezieller Accessibility-Neustartablauf in den gelesenen Komponenten. Bildschirmaufnahme gehört nicht zu diesem Basisablauf.

OpenWhispr verzweigt nach Konto/Gast: Gäste erhalten Rechte → Hotkey → Cloud/BYOK/lokal; der Kontopfad ergänzt Sprache, Einsatzfälle und Übungen. Bildschirmkontext ist optional. Ein ausstehender Screen-Opt-in bleibt ausdrücklich über den von macOS verlangten Neustart erhalten. Accessibility-Checks überschreiben veraltete gespeicherte Zustände; nach wiederholt fehlender Freigabe erscheinen Hilfen.

Wispr Flow erklärt Accessibility als Einfügen gesprochener Wörter und fragt danach Mikrofon; Fortfahren erscheint erst nach beiden Freigaben. Die Reparaturdoku nach Updates empfiehlt Beenden, Rechte erneut freigeben und Wiederöffnen. Das ist eine Reparaturstrategie, kein Beleg dafür, dass jedes neue Accessibility-Recht generell einen Neustart verlangt. Superwhisper verweist bei Paste-Problemen auf Accessibility. MacWhispers offizielle Dictation-Seite bietet einen geführten Einstieg, dokumentiert aber die genaue Rechte-/Neustartfolge nicht.

WhisperM8 hat bereits Mikrofon + Accessibility und lässt Screen Capture aus dem Basis-Onboarding heraus. Die konkrete Lücke: PermissionsStep unterscheidet verweigert/eingeschränkt nicht und bietet keinen geführten Reparaturpfad. Empfehlung: F-APP-01/07, explizite Zustandsmaschine, Einstellungen öffnen, erneut prüfen und bedarfsweiser Neustart mit gespeicherter Position; Abschluss durch ein echtes externes Testdiktat. Kein automatischer Neustart bei laufenden Agent-Chats.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Features/Onboarding/State/OnboardingPermissionModels.swift, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Features/Onboarding/State/OnboardingPermissionController.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src/App.tsx, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src/components/onboarding/AccessibilityOnboarding.tsx, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/components/onboarding/flow.ts, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/hooks/usePermissions.ts, https://docs.wisprflow.ai/articles/7682075140-how-to-install-wispr-flow-on-mac, https://docs.wisprflow.ai/articles/5510622673-re-verify-wispr-flow-permissions-after-updating, https://superwhisper.com/docs/common-issues/pasting-issues, https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/OnboardingView.swift

### 2. Einfügen: Mechanismus, Zwischenablage und Zielbindung

**Konfidenz:** hoch

VoiceInk bietet CGEvent-Cmd+V, AppleScript und inzwischen zusätzlich Direct Typing. Sein Restore sichert alle materialisierten Typen aller Pasteboard-Items, markiert die eigene Paste-Session und restauriert nur, wenn Text und Session-Marker noch passen. Direct Typing wird nach teilweiser Zustellung bewusst nicht blind wiederholt. Der gelesene CursorPaster verwendet die zum Zustellungszeitpunkt aktive App; eine Aufnahmebeginn-Bindung an ein bestimmtes Fenster ist darin nicht belegt.

Handys regulärer Pfad verwendet Enigo für Paste-Tastenkombinationen oder direktes Tippen. Restore sichert Text beziehungsweise ein Bild, aber nicht sämtliche Formate; der reguläre Timer-Restore hat keinen entsprechenden Ownership-Guard. Neu ist ein standardmäßig ausgeschalteter, debug-gesteuerter Pfad mit NSPasteboard-Promise, Leseereignissen und changeCount. Ein Leseereignis identifiziert jedoch nicht sicher die Ziel-App; auch andere Clipboard-Verbraucher können lesen. Kein fertiges Zustellungsprotokoll ungeprüft übernehmen.

OpenWhispr verwendet einen nativen CGEvent-Helper mit Tastaturlayout-Auflösung beziehungsweise AppleScript. Es sichert Text/HTML/RTF/Bild und restauriert nur bei unverändertem erwartetem Text; das ist schwächer als eine Transaktionskennung. Der macOS-Helper pastet in die aktuell aktive App. Whispering-main unterstützt ausdrücklich kein Einfügen in fremde Apps; Epicenters separater Desktop-Clipboard-Code sichert dagegen native Items/Formate. Superwhisper dokumentiert Restore als Standard und einen Umschalter für langsam lesende Ziel-Apps.

WhisperM8 bindet nur die vorherige NSRunningApplication, nicht das konkrete Fenster/Feld. Nach Aktivierungs-Timeout wird trotzdem gepastet; außerdem meldet postPasteEvent lediglich erfolgreich erstellte/gepostete Events, nicht angekommenen Text. Der Coordinator überschreibt die Zwischenablage bereits vor PasteService. Ein Snapshot erst im PasteService käme deshalb zu spät. Empfehlung F-DIK-01: Snapshot vor dem ersten eigenen Write; vorhandenen PasteboardSnapshot wiederverwenden; Ownership-/changeCount-Guard, serialisierte Zustellungen, Timeout-Abbruch mit manuellem Kopieren statt blindem Paste. Fenster-/Fokuswechsel unmittelbar vor jeder Zustellung prüfen. AppleScript/AX-Schreiben sind keine universell sichere Lösung und brauchen appbezogene QA.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/clipboard.rs, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/paste_tx/macos.rs, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/settings.rs, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/helpers/clipboard.js, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/resources/macos-fast-paste.swift, https://github.com/EpicenterHQ/epicenter/blob/7cc869b4a1295e2566b61e1a4d5967a89f413b9b/apps/whispering/README.md, https://github.com/EpicenterHQ/epicenter/blob/7cc869b4a1295e2566b61e1a4d5967a89f413b9b/apps/epicenter/src-tauri/src/clipboard.rs, https://superwhisper.com/docs/common-issues/pasting-issues, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PasteService.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/SelectedContextService.swift

### 3. Provider, Kosten und lokale STT als Launch-Faktor

**Konfidenz:** mittel

VoiceInk stellt im Onboarding lokales Parakeet und Cloud gegenüber und zeigt einen Download mit Fortschritt und Abbruch. Handy ist für STT lokal ausgerichtet; Modellkarten zeigen Sprachen, Größe und Zustände wie downloading/verifying/switching. Wichtig gegenüber Juli: aktuelles Cargo.toml nennt handy-recorder und transcribe-cpp für sämtliche Modelle. Optionales LLM-Postprocessing kann dennoch Netzaufrufe machen; lokale STT bedeutet nicht automatisch eine vollständig lokale Gesamtpipeline.

OpenWhispr unterscheidet gehostete Cloud, eigene API-Schlüssel und lokale Modelle. Das ist für Laien verständlicher als eine lange technische Providerliste, kann mit zwei getrennten STT-/Assistant-Konfigurationen aber auch überfordern. Superwhisper trennt Sprachmodell und nachgelagertes KI-Modell; die Dokumentation erklärt lokale Downloads und Funktionsgrenzen. MacWhisper erläutert den einmaligen WhisperKit-Vorbereitungsschritt, der bei großen Modellen Minuten dauern kann, sowie M-Series-Beschränkung. Seine ältere Aussage über API-Key versus ChatGPT-Plus ist als Begriffsaufklärung brauchbar, nicht als aktuelle Preis-/Providerliste. Whispering-main nutzt einen konfigurierbaren OpenAI-kompatiblen Endpoint, keine im gelesenen App-Pfad integrierte lokale Modellbibliothek.

Bewertung für WhisperM8: Ein Start ohne API-Konto ist ein erheblicher Vorteil lokaler STT; Offline-/Datenschutz-Zielgruppen erreicht eine reine Cloud-App nicht. Die beschlossene Definition W2 verlangt aber ausdrücklich API-Key-Onboarding. Aus dem Vergleich folgt daher kein neuer Launch-Blocker ohne Produktentscheidung. Erst den Cloud-Einstieg mit Kostenverantwortung, Key-Prüfung und klarer Trennung 'API-Abrechnung' versus 'Codex/ChatGPT-Login' fertigstellen.

Der bestehende FluidAudio-Spike bleibt eine sinnvolle Grundlage, nicht ein heute verifizierter Implementierungsplan. Aktuell ist v0.17.7, nicht v0.15.2; Swift 6 und macOS 14 stehen weiterhin im Manifest. Modellgrößen, APIs, Modelllizenzen und Leistungszahlen aus Juni müssen neu geprüft werden. Besonders korrigieren: Ein lokaler Fehler darf nicht still auf Cloud umschalten. Für ein Datenschutzversprechen muss Cloud-Fallback eine ausdrückliche Handlung sein. Aufwand für produktionsreife lokale STT einschließlich Download, Cancel, Warmup und Hardware-/Sprachtests: L, nicht nur ein zusätzlicher API-Adapter.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Features/Onboarding/State/OnboardingPermissionModels.swift, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Features/Onboarding/Components/TranscriptionModelDownloadCard.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src/components/onboarding/ModelCard.tsx, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/Cargo.toml, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/actions.rs, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/components/onboarding/flow.ts, https://superwhisper.com/docs/billing/plans, https://docs.macwhisper.com/article/29-switching-to-a-whisperkit-model, https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature, https://github.com/EpicenterHQ/epicenter/blob/7cc869b4a1295e2566b61e1a4d5967a89f413b9b/apps/whispering/src/lib/transcription.ts, https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.7, https://github.com/FluidInference/FluidAudio/blob/main/Package.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/plans/lokale-stt-spike.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md

### 4. KI-Modi, Kontext-Erfassung und Datenschutz

**Konfidenz:** hoch

VoiceInk nutzt Modi und appabhängige Auswahl. Sein ScreenCaptureService erfasst das aktive Fenster und extrahiert lokal mit Vision OCR-Text; das ist vom Versand eines Roh-Screenshots zu unterscheiden. Lokale Extraktion garantiert allerdings noch nicht, dass der extrahierte Text bei gewähltem Cloud-Enhancement lokal bleibt. Eine eigene Trust-Seite erklärt die lokale Verarbeitungsoption. Handy bietet frei konfigurierbares Postprocessing, darunter API-Aufrufe und Apple-Intelligence-Pfad; eine WhisperM8-gleichwertige Screenshot-/Agent-Chat-Kontextpipeline wurde in den gelesenen Stellen nicht belegt.

OpenWhispr unterstützt Bildschirmkontext und aktive Zielinformationen. Die gelesene Capture-Implementierung kann einen ganzen Display-Screenshot erzeugen; dieser darf laut Code bei Fehlern nicht das Diktat scheitern lassen. Das ist keine datensparsame Entsprechung zu einer bewusst ausgewählten Region. Die optionale Freigabe im Onboarding ist ein gutes Muster; ein README-Claim 'no telemetry' ersetzt keine Prüfung einzelner Datenflüsse.

Superwhisper erklärt Selected Text, Clipboard und Application Context separat, einschließlich unterschiedlicher Erfassungszeitpunkte. History zeigt den an die KI gesendeten Prompt. Wispr Flows aktuelle offizielle Seite sagt ausdrücklich 'does not take screenshots'; ältere Screenshot-Beschreibungen dürfen nicht als aktueller Ist-Stand weitergetragen werden. Gleichzeitig ist Kontext standardmäßig an, und bei ausgeschaltetem Kontext gehen weiterhin App-Name und Website-Domain mit. Kontext, Modellverbesserung und Cloud-Speicherung sind getrennte Einstellungen. Die Doku weist selbst auf Grenzen bei benutzerdefinierten/webbasierten Passwortfeldern hin.

WhisperM8 sammelt markierten Text, visuelle Anhänge und Agent-Chat-Tails. Zusätzlich importiert der Clipboard-Monitor Kopiertes während Aufnahme und Verarbeitung. Empfehlung F-DIK-06/07/08/09: sichtbar machen, welche Daten an welchen Verarbeitungsschritt gehen; pro Lauf abwählbare Kontextbausteine und leicht erreichbares 'ohne Kontext'. Bildschirmaufnahme-Recht ist keine Zustimmung zum Cloud-Versand. Keine pauschalen Aussagen 'privat', 'lokal' oder 'Kontext aus', solange weitere Übertragungen bestehen. F-DIK-10 mit Projektzugriff getrennt erklären; dafür nicht den echten Codex durch eine neue eigene Runtime ersetzen.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Infrastructure/SystemIntegration/ScreenCapture/ScreenCaptureService.swift, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Features/Onboarding/Views/OnboardingTrustScreen.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/actions.rs, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/llm_client.rs, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/helpers/screenContextCapture.js, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/components/onboarding/CompactPermissionsStep.tsx, https://superwhisper.com/docs/common-issues/context, https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PromptPackageBuilder.swift

### 5. Verteilung, Updates, Homebrew und Quarantäne

**Konfidenz:** mittel

Alle vier Open-Source-Namen haben offizielle Homebrew/homebrew-cask-Einträge; ebenso die drei kommerziellen Vergleichsprodukte. 'Offizieller Cask' bezeichnet dabei das Homebrew-Repository, nicht zwingend Pflege durch die App-Entwickler. Handy und OpenWhispr kennzeichnen ihre Casks ausdrücklich als Community-gepflegt.

VoiceInk integriert Sparkle; sein Release-Skript enthält Developer-ID-Signatur, notarytool, Stapling und Validierung. Handy verwendet den Tauri-Updater mit öffentlichem Signatur-Prüfschlüssel; seine Build-Pipeline unterstützt Apple-Signing-/Notarisierungszugangsdaten. OpenWhispr verwendet electron-updater; electron-builder verlangt Hardened Runtime, eine benannte Developer Identity und notarize=true. Das belegt implementierte Release-Verfahren, nicht das Apple-Ticket jedes heruntergeladenen Artefakts. Eine solche Binärprüfung fand nicht statt.

Wichtig bei Whispering: Der Cask verteilt das alte v7.11.0. Die aktuelle Entwicklungs-App hat nur app als Bundleziel und ad-hoc signingIdentity='-'; daraus darf keine heutige notarisiert ausgelieferte Whispering-Version behauptet werden. Superwhisper-/MacWhisper-Casks verweisen auf Sparkle-Feeds; Wispr Flow hat einen eigenen Release-Feed. Details der proprietären Signatur-/Updater-Implementierung wurden nicht untersucht.

Die gelesenen Vergleichs-Casks enthalten keinen Quarantäne-Entfernungsschritt. Das ist kein individueller Notarisierungsbeweis. WhisperM8s eigener Cask-Generator entfernt dagegen ausdrücklich com.apple.quarantine. Gemäß E4 muss dieser Workaround nach Einführung der signierten/notarisierten Pipeline entfallen.

Übertragbar: Prüfen und Validieren der Auslieferung, nicht blind Sparkle übernehmen. Brew bleibt WhisperM8s einziger Kanal; ein zweiter Selbst-Updater würde Kanal-/Receipt-Konflikte schaffen. F-APP-04 braucht einen verständlichen, zustimmungsbasierten Brew-Updateablauf mit Rückmeldung und sicherem Umgang mit offenen Chats. Homebrew überspringt auto_updates=true bei regulärem brew upgrade ohne passende greedy-Optionen; deshalb diese Metadaten nicht aus konkurrierenden Selbst-Updater-Casks kopieren.

Quellen: https://github.com/Homebrew/homebrew-cask/blob/main/Casks/v/voiceink.rb, https://github.com/Homebrew/homebrew-cask/blob/main/Casks/h/handy.rb, https://github.com/Homebrew/homebrew-cask/blob/main/Casks/o/openwhispr.rb, https://github.com/Homebrew/homebrew-cask/blob/main/Casks/w/whispering.rb, https://github.com/Homebrew/homebrew-cask/blob/main/Casks/s/superwhisper.rb, https://github.com/Homebrew/homebrew-cask/blob/main/Casks/w/wispr-flow.rb, https://github.com/Homebrew/homebrew-cask/blob/main/Casks/m/macwhisper.rb, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/scripts/release.sh, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/App/Updates/UpdaterViewModel.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/tauri.conf.json, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/.github/workflows/build.yml, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/electron-builder.json, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/updater.js, https://github.com/EpicenterHQ/epicenter/blob/7cc869b4a1295e2566b61e1a4d5967a89f413b9b/apps/whispering/src-tauri/tauri.conf.json, https://docs.brew.sh/Manpage, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/scripts/update-cask.sh, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/AppUpdateChecker.swift

### 6. Gerätewechsel, Bluetooth, verlorene Aufnahmen und Fehlermeldungen

**Konfidenz:** hoch

VoiceInks AUHAL-Recorder bleibt die stärkste gelesene Referenz für Gerätewechsel mitten in der Aufnahme: vorbereiteter Recorder, Stop/Drain der Callbacks, neues Gerät/Format und Weiterführung derselben Datei; bei einem fehlgeschlagenen Device-Set versucht er Recovery zum alten Gerät. Das ist ein konkretes Muster, kein Beleg für Fehlerfreiheit.

Handys aktueller AudioRecordingManager verwendet strukturierte Recorder-Fehler wie PermissionDenied und DeviceUnavailable. Fehlende ausgewählte Mikrofone können auf Default fallen; stale Geräte werden neu aufgelöst und einmal erneut geöffnet. Ein fehlerhafter warmer Stream wird vor der nächsten Aufnahme neu aufgebaut. Bei laufendem Stream-Fehler bleibt bereits aufgenommenes Audio erhalten. Die Juli-Beschreibung bloßer String-Klassifikation ist für diesen Stand veraltet.

OpenWhispr spoolt Audio-Chunks bis zum gesicherten Ergebnis und bietet beim nächsten Start Recovery unterbrochener Aufnahmen. Der Recoverypfad unterscheidet leere/Header-only-Aufnahmen und lässt noch nicht erfolgreich gesicherte Recoverydaten für einen späteren Versuch bestehen. Superwhisper dokumentiert Schreiben auf Disk während der Aufnahme und Wiederverarbeitung aus History. Das sind bessere Referenzen als bloß 'Fehler anzeigen'. Für proprietäre Apps wurden keine eigenen Bluetooth-/Crashversuche durchgeführt.

WhisperM8 ist seit Juli deutlich besser: installTap liest das Live-Format erneut und läuft in ObjCException.catching. AudioDeviceManager hat bereits Geräte- und Default-Listener; den Juli-Vorschlag 'Listener hinzufügen' streichen. Verbleibend: AudioRecorders Configuration-Observer wird weiterhin nur im System-Default-Modus gesetzt. Erschöpfte Format-Retries setzen isRecording=false, ohne einen dort erkennbaren strukturierten Fehlercallback an den Coordinator.

FailedRecordingsStore schützt fehlgeschlagene beziehungsweise während der Transkription abgebrochene Aufnahmen bereits dauerhaft, maximal zehn beziehungsweise sieben Tage. Das ist nicht gleichbedeutend mit Crash-Recovery während der Aufnahme: die aktive M4A entsteht im temporären Verzeichnis, und der sichtbare Retry hängt an pendingRetry. Empfehlung: F-DIK-01/05 mit sichtbarem Geräteabbruch, verwertbarem Teil-Audio, persistenter Recoveryliste nach Neustart und konkreten Fehleraktionen absichern. AUHAL-Rewrite erst bei verbleibendem, nachgewiesenem Bedarf; nicht als reflexhaften Launch-Umbau.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Infrastructure/Audio/CoreAudioRecorder.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/audio.rs, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/helpers/audioManager.js, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/hooks/useAudioRecording.js, https://superwhisper.com/docs/common-issues/crashes, https://superwhisper.com/docs/common-issues/llm-processing-error, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/AudioRecorder.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/AudioDeviceManager.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/FailedRecordingsStore.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/RecordingCoordinator+Failure.swift

### 7. Code-Qualität: Dateigrößen, Architektur und Tests

**Konfidenz:** hoch

Statische Zeilenzählung der gelesenen Quellstände, keine ausgeführten Tests: VoiceInk hat als größte Swift-Datei CoreAudioRecorder.swift mit 1.353 Zeilen, danach DashboardContent.swift 1.035 und VoiceInkRefineModelDownloader.swift 950. Features und Infrastructure sind getrennt; das Onboarding nutzt MainActor-Coordinator/ObservableObject und getrennte Controller. Das ist eine passende native Referenz, aber die gelesenen UI-Tests bestehen im Wesentlichen aus Launch-Beispiel und Launch-Performance-Gerüst; Testreife nicht aus aufgeräumten Ordnern ableiten.

Handy trennt Manager, Engine-Supervisor und TranscriptionCoordinator; trotzdem haben model.rs 2.678, transcription.rs 2.233 und supervisor.rs 2.018 Zeilen. Im Rust-Anwendungssrc wurden 309 #[test]/#[tokio::test]-Attribute gezählt; das ist eine Quelltextzählung, weder Testlauf noch Coverage. Besonders gut übertragbar sind reine Zustandsentscheidungen und strukturierte Fehlerarten, nicht Rust/Tauri selbst.

OpenWhispr besitzt zahlreiche spezialisierte Regressionstestdateien, unter anderem für Clipboard-Restore, Permission Guides und Recording-Recovery. Gleichzeitig sind ipcHandlers.js mit 13.220, database.js mit 8.164 und audioManager.js mit 6.406 Zeilen klare Gegenbeispiele zum vorgeschlagenen WhisperM8-Limit. Hohe Featurezahl und Testdateizahl machen solche zentralen Dateien nicht zum Vorbild.

Beim aktuellen Whispering liegen im app-eigenen src die größten Dateien bei transformations.test.ts 1.280, library.svelte.ts 1.274 und workspace/desktop.test.ts 1.259 Zeilen. Aussagekräftig ist die explizite Fehlersemantik im Transkriptionsclient: 'nichts gesendet' wird von 'Ergebnis unbekannt' unterschieden; keine stille erneute Übertragung und keine Weitergabe von Credentials über Redirects. Diese Semantik ist übertragbar, der neue Git-Datei-Datenstack nicht erforderlich.

Für WhisperM8 vorhandene Coordinator-/Service-Splits und Closure-DI beibehalten; reine Permission-, Paste- und Recovery-Zustände gezielt testen. Performancebefund ungefragt: PasteService ist MainActor und blockiert pro Cmd+V mit usleep(20_000); SelectedContextService hat denselben synchronen Wait. Das sind mindestens 20 ms blockierte UI-Zeit pro Eventpaar, ohne System-/AX-Kosten. Asynchronisieren und gegen vorhandene Budgets messen; keine erfundenen End-to-End-Zeitgewinne behaupten.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Infrastructure/Audio/CoreAudioRecorder.swift, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Features/Onboarding/State/OnboardingCoordinator.swift, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/Tests/VoiceInkUITests/VoiceInkUITests.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/model.rs, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/transcription.rs, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/engine_supervisor/supervisor.rs, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/helpers/ipcHandlers.js, https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/test/helpers/clipboardRestore.test.js, https://github.com/EpicenterHQ/epicenter/blob/7cc869b4a1295e2566b61e1a4d5967a89f413b9b/apps/whispering/src/lib/transcription.ts, https://github.com/EpicenterHQ/epicenter/blob/7cc869b4a1295e2566b61e1a4d5967a89f413b9b/apps/whispering/src/lib/transformations.test.ts, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PasteService.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/SelectedContextService.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Tests/WhisperM8Tests/FailedRecordingsStoreTests.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Tests/WhisperM8Tests/AudioFormatDecisionTests.swift

## Übertragbar auf WhisperM8

### B1-R01 · Paste als sichere Transaktion statt blindes Tastensignal

*Priorität hoch · Aufwand M · Features F-DIK-01, F-DIK-06*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift vor dem ersten Clipboard-Write snapshotten; vorhandenen PasteboardSnapshot aus SelectedContextService.swift wiederverwenden. In PasteService.swift Zustellungen serialisieren, Ownership/changeCount beachten und bei fehlgeschlagener Aktivierung abbrechen statt 'pasting anyway'. App-/Fensterwechsel vor Text und Anhängen prüfen. Benutzeraktion 'Ergebnis kopieren' als sicheren Fallback bereitstellen. Selektions-Copy ebenfalls vor dem Überschreiben neuer Nutzerkopien schützen.

**Begründung:** Aktuell kann Nutzer-Clipboard verloren gehen und nach Aktivierungs-Timeout in die falsche App gepastet werden. Die Ziel-App-Bindung ist keine Zielfenster-Bindung. Event-Posting darf nicht als bestätigtes Einfügen bezeichnet werden.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PasteService.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift

### B1-R02 · Verweigerte Rechte mit geführter Reparatur behandeln

*Priorität hoch · Aufwand M · Features F-APP-01, F-APP-07, F-DIK-01, F-DIK-07 · Entscheidung E1*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/OnboardingView.swift und Services/Shared/PermissionService.swift denied/restricted/granted getrennt behandeln. Pro Recht erklären, welche Funktion es benötigt; verweigerte Rechte zu den passenden Systemeinstellungen führen, bei Rückkehr neu prüfen. Screen Capture erst bei bewusster Nutzung. Reparatur-Neustart nur bei Bedarf und mit Warnung vor laufenden Chats; Onboardingposition erhalten. Testdiktat in einer fremden App zum Abschluss.

**Begründung:** VoiceInks Zustandsmodell und Wispr Flows Reparaturdoku sind direkt übertragbar. Das bisherige wiederholte requestAccess plus Polling bietet bei Ablehnung keinen ausreichenden Ausweg für Laien.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Features/Onboarding/State/OnboardingPermissionController.swift, https://docs.wisprflow.ai/articles/5510622673-re-verify-wispr-flow-permissions-after-updating, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/OnboardingView.swift

### B1-R03 · Kontextversand vor dem Lauf verständlich offenlegen

*Priorität hoch · Aufwand M · Features F-DIK-06, F-DIK-07, F-DIK-08, F-DIK-09, F-DIK-10*

Auf Basis von /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PromptPackageBuilder.swift und RecordingCoordinator+Clipboard.swift Datenfluss je Stufe erklären: Audio → STT-Provider; Text/ausgewählte Kontextteile → Codex; Ergebnis/Anhänge → Ziel-App. Kontextchips mit Entfernen und 'ohne Kontext' anbieten; automatischen Clipboard-Import während Verarbeitung ausdrücklich nennen und abschaltbar machen. Projektzugriff separat kennzeichnen.

**Begründung:** WhisperM8s Funktionsumfang vergrößert die Datenschutz-Erklärpflicht. Ein erteiltes macOS-Recht und ein lokaler Verarbeitungsschritt sagen nichts darüber aus, was später an einen Cloud-Dienst geht.

Quellen: https://superwhisper.com/docs/common-issues/context, https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PromptPackageBuilder.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift

### B1-R04 · Aufnahmen auch nach Gerätefehler und Neustart wiederfinden

*Priorität hoch · Aufwand L · Features F-DIK-01, F-DIK-05*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/AudioRecorder.swift Hardwareabbrüche als strukturiertes Ereignis an den Coordinator melden und verwertbares Teil-Audio sichern. Vorhandenen FailedRecordingsStore um einen sichtbaren Wiederherstellen-/Löschen-Einstieg nach App-Neustart ergänzen. Anschließend gezielt Crash während Aufnahme/Upload und Bluetooth-Abbruch bei expliziter Gerätewahl testen. Geräte-Listener nicht neu bauen: AudioDeviceManager hat sie schon.

**Begründung:** Der bestehende Fehlerstore schützt den behandelten Transkriptionsfehler, aber nicht automatisch jeden Crash oder Hardwareabbruch. OpenWhisprs Chunk-Spool und Handys Erhalt von Teil-Audio liefern konkrete Referenzmuster.

Quellen: https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/helpers/audioManager.js, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/audio.rs, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/AudioRecorder.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/FailedRecordingsStore.swift

### B1-R05 · Notarisierung umsetzen, Brew als einzigen Updater behalten

*Priorität hoch · Aufwand M · Features F-APP-04 · Entscheidung E4*

Release-Pipeline mit Developer ID, Hardened Runtime, Notarisierung und Ticketvalidierung versehen; in /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/scripts/update-cask.sh den xattr-Quarantäne-Bypass entfernen. Den Updateablauf aus Services/Shared/AppUpdateChecker.swift für Laien führen und Erfolg/Fehler verständlich melden. Kein Sparkle als zweiten Kanal einbauen; keine auto_updates=true-Metadaten übernehmen, wenn Brew selbst aktualisieren soll.

**Begründung:** Erfüllt die bereits beschlossene Vertrauensanforderung, ohne die Brew-only-Vorgabe zu brechen. Konkurrierende Updater wären eine neue Fehlerquelle; die Fremdprojekte beweisen nur, dass Brew und Selbst-Updater koexistieren können, nicht dass WhisperM8 beides braucht.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/scripts/release.sh, https://docs.brew.sh/Manpage, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/scripts/update-cask.sh, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/AppUpdateChecker.swift

### B1-R06 · Cloud-Kosten und Codex-Abhängigkeit im Einstieg trennen

*Priorität hoch · Aufwand M · Features F-APP-01, F-DIK-02, F-DIK-03, F-DIK-09, F-DIK-12 · Entscheidung E2/E5*

Im Provider-/Onboarding-Subsystem einfache Wahl und Verbindungstest anbieten: Rohdiktat benötigt einen STT-API-Key mit eigener Abrechnung; Umformulierung zusätzlich die echte Codex-CLI mit Login. Geführte Codex-Installation gemäß E5, kein bloßer Terminalverweis. Inoffizielle ChatGPT-Abo-Transkription nicht als einfachen Onboarding-Ausweg vermarkten, sondern gemäß E2 in Labs belassen. Kostenangaben datieren und nicht aus veralteten Wettbewerberartikeln übernehmen.

**Begründung:** API-Konto, App-Lizenz und ChatGPT-Abo sind unterschiedliche Kosten-/Berechtigungsmodelle. Wettbewerber reduzieren Reibung durch einen lokalen oder gehosteten Einstieg; WhisperM8 muss seinen gewählten Cloud-Pfad zumindest verständlich und vollständig führen.

Quellen: https://github.com/OpenWhispr/openwhispr/blob/3577e5c9b2b06f7667a4b9d489935addba488341/src/components/onboarding/flow.ts, https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/OnboardingView.swift

### B1-R07 · Lokale STT separat entscheiden statt Launch-Scope still erweitern

*Priorität mittel · Aufwand L · Features F-DIK-02, F-DIK-12 · Entscheidung E6; zusätzliche Produktentscheidung nötig*

Den Spike unter /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/plans/lokale-stt-spike.md auf aktuelle FluidAudio-APIs und Modelllizenzen aktualisieren. Einen kuratierten lokalen Standard statt technischer Modellliste evaluieren, mit Downloadgröße, Fortschritt, Abbruch, Löschung und Warmup-Anzeige. Deutsch/Englisch-Code-Switching, unterstützte Hardware und Speicherkosten vor Integration messen. Kein automatischer Cloud-Fallback aus einem lokalen Datenschutzmodus.

**Begründung:** Lokale STT senkt API-Onboarding-Reibung und öffnet Offline-/Privacy-Zielgruppen, ist aber im beschlossenen Launch-Inventar kein zugesagtes Feature. Die produktionsreife Modellverwaltung ist deutlich größer als ein einfacher Provideradapter.

Quellen: https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.7, https://github.com/FluidInference/FluidAudio/blob/main/Package.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src/components/onboarding/ModelCard.tsx, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/plans/lokale-stt-spike.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md

### B1-R08 · MainActor-Pausen entfernen und Zustandslogik gezielt testen

*Priorität mittel · Aufwand S · Features F-DIK-01, F-DIK-06, F-APP-08*

Die synchronen 20-ms-usleep-Pausen in /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PasteService.swift und SelectedContextService.swift durch asynchrone Wartezeiten in einer serialisierten Transaktion ersetzen. Reine Tests für Ownership-Verlust, parallele Pastes, Aktivierungs-Timeout, Rechteablehnung und Gerätefehler ergänzen. Wirkung später mit vorhandenen Signposts und Stall-Watchdog messen.

**Begründung:** Bereits im Code belegte blockierte UI-Zeit: mindestens 20 ms pro Eventpaar, bei mehreren Attachments wiederholt. Das ist kein gemessener End-to-End-Benchmark. Vorhandene native DI-/Testarchitektur ist geeigneter als die großen Zentraldateien mancher Vergleichsprojekte.

Quellen: /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/PasteService.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Dictation/SelectedContextService.swift, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/paste_tx/mod.rs

### B1-R09 · AUHAL und erweiterte Paste-Verfahren nicht vorsorglich neu bauen

*Priorität niedrig · Aufwand L · Features F-DIK-01, F-DIK-05*

VoiceInks AUHAL-Recorder und Handys receipt-basierte Paste nur als spätere, messungsgetriebene Optionen behandeln. Zuerst vorhandenen ObjC-Schutz, Fehlerweiterleitung, Clipboard-Transaktion und Ziel-Fokus härten. Einen unabhängigen AUHAL-Spike nur bei danach weiterhin reproduzierbaren Audioproblemen starten; kein GPL-Code-Copy ohne Lizenzprüfung, kein Tauri-/Electron-Wechsel.

**Begründung:** Die Juli-Empfehlung beruhte teilweise auf inzwischen behobenen beziehungsweise falsch beschriebenen Lücken. Ein großer Recorder-Rewrite oder exotischer Paste-Pfad kurz vor Launch vergrößert die Regressionfläche ohne bereits belegten Zusatznutzen.

Quellen: https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/VoiceInk/Infrastructure/Audio/CoreAudioRecorder.swift, https://github.com/Beingpax/VoiceInk/blob/9ce98ec81f96517868717d7a7a47818b71281d3f/LICENSE, https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/paste_tx/mod.rs, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/adr/0001-kein-stack-wechsel.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/diktat-apps.md
