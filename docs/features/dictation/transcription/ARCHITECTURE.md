---
status: aktiv
updated: 2026-07-09
---

# Transcription — Architektur

Die Transcription-Architektur besteht aus einer kleinen Provider-Abstraktion,
einem gemeinsamen Multipart-Upload-Client und zwei Konsumenten. Das
GUI-Diktat nutzt die Schicht als einfachen Text-Service. Die CLI nutzt
denselben Client über einen detaillierteren Ergebnis-Pfad; Audio-Extraktion,
Chunking, Stitching und Rendering gehören zur CLI-Dokumentation unter
[../../cli/](../../cli/).

## Komponenten

`TranscriptionServiceProtocol` ist die gemeinsame Schnittstelle für
`transcribe(audioURL:language:audioDuration:)`. `TranscriptionService.swift`
enthält nur dieses Protokoll; konkrete Provider-Logik lebt in
`TranscriptionProviders.swift` und im Multipart-Client.

`OpenAITranscriptionService` und `GroqTranscriptionService` sind dünne
Adapter. Sie rufen `ProviderConfig.openAI(model:)` beziehungsweise
`ProviderConfig.groq(model:)` mit dem Modellnamen auf und delegieren jeden
Call an `MultipartTranscriptionClient`.

`TranscriptionProvider` ist das fachliche Provider-Modell für Preferences,
Settings und Service-Erzeugung. Es kennt Display-Namen, empfohlene Anzeige,
Keychain-Account, API-Key-Link, Preisinfo, verfügbare Modelle, Default-Modell
und das Mapping von `TranscriptionModel` auf konkrete Provider-Services.

`TranscriptionModel` ist das appweite Modell-Enum. Es ordnet jedes Modell
einem Provider zu und liefert Display-Texte. `TranscriptionSettings` kapselt
Migration, Laden und Speichern der Provider-/Modell-Auswahl über
`AppPreferences`.

`MultipartTranscriptionClient` ist die technische Upload-Schicht. Er baut eine
`multipart/form-data`-Anfrage, prüft das 25-MiB-Limit aus `ProviderConfig`,
schreibt den Body in eine temporäre Datei und lädt diese Datei mit einer
dauerabhängigen `URLSession` hoch.

`MultipartFormDataFileWriter` schreibt den Multipart-Body auf Disk und kopiert
die Audiodaten in 1-MiB-Schritten. Dadurch werden Audio-Datei und Multipart-
Envelope nicht vollständig im Arbeitsspeicher gehalten.

`KeychainManager` ist die gemeinsame Keychain-Anbindung für GUI und CLI. Die
Transcription-Schicht nutzt es über die Provider-Keys `groq_apikey` und
`openai_apikey`; alte UserDefaults-Werte werden beim Laden migriert.

## Provider-Konfiguration

`ProviderConfig.openAI(model:)` erzeugt eine Konfiguration für
`https://api.openai.com/v1/audio/transcriptions`;
`ProviderConfig.groq(model:)` erzeugt eine Konfiguration für
`https://api.groq.com/openai/v1/audio/transcriptions`. Beide Factory-
Funktionen übernehmen den Modellnamen, verwenden Bearer-Auth, denselben
Multipart-Aufbau und ein konfiguriertes Limit von 25 MiB.

Der Request-Body enthält immer `model` und `file`. Der Datei-Part schreibt im
Envelope fest `Content-Type: audio/m4a`. `language` wird nur bei nicht leerem
Sprachcode geschrieben. `response_format` wird nur gesetzt, wenn der Aufrufer
es explizit anfordert; das GUI-Diktat übergibt `nil`, der aktuelle CLI-
Transcribe-Pfad übergibt nur `verbose_json` für segmentfähige Modelle oder
`json` für `gpt-4o-transcribe`.

## Datenfluss: GUI-Diktat

1. `RecordingCoordinator` stoppt die Aufnahme und ruft
   `transcribeAndDeliver` mit Audio-URL, Dauer, OutputMode und Kontextbundle.
2. Der Provider-Resolver führt bei Bedarf die Settings-Migration aus und lädt
   den aktuellen Provider; der Modell-Resolver lädt das aktuelle Modell.
3. Der API-Key-Resolver lädt `provider.keychainKey` aus `KeychainManager`.
4. `provider.createService(apiKey:model:)` erzeugt den passenden Provider-
   Adapter und damit einen `MultipartTranscriptionClient`.
5. `transcribe` lädt die Datei hoch und dekodiert die JSON-Antwort als
   `TranscriptionResponse`.
6. Der Coordinator normalisiert den Text, führt optionales Post-Processing aus,
   kopiert das finale Ergebnis in die Zwischenablage, paste-t es optional und
   schreibt einen `TranscriptRunReport`.

Ein Cancel vor oder während des Uploads cancelt den umgebenden Task; der
Kommentar im Client beschreibt, dass der async `URLSession`-Upload dadurch
kooperativ abbricht. Nach Eintreffen der Response setzt der Coordinator
`isDeliveringTranscription`, damit ein später Cancel die Delivery nicht mehr
zerstört.

## Schnittstelle: CLI

Der CLI-Konsument bereitet Eingabedateien außerhalb dieser Schicht vor und
übergibt dem Multipart-Client pro Upload eine Audiodatei, optional Sprache,
`response_format` und Audio-Dauer. Für segmentfähige Modelle nutzt er
`transcribeDetailed` mit `verbose_json`; für `gpt-4o-transcribe` nutzt er
`json`.

`CLIAudioChunker` gehört architektonisch zum CLI-Feature, nicht zur STT-
Basisschicht. Wenn der CLI-Pfad Chunks erzeugt, sieht der Upload-Client jeden
Chunk als normale Audiodatei und prüft weiterhin pro Datei das 25-MiB-Limit.
Details zu Audio-Extraktion, Chunking-Algorithmus, Stitching, Ausgabeformaten
und CLI-Retry stehen unter [../../cli/](../../cli/).

## Fehler und Limits

`MultipartTranscriptionClient` unterscheidet invaliden Response-Typ,
Nicht-200-HTTP-Antworten und zu große Dateien als `TranscriptionError`. Die
`LocalizedError`-Texte behandeln HTTP 401 als ungültigen API-Key, HTTP 429 als
Rate-Limit und HTTP 413 als zu große Audiodatei.

Fehlende API-Keys werden vor dem Upload behandelt: Das GUI wirft vor der
Service-Erzeugung `TranscriptionError.missingAPIKey`, die CLI bricht vor dem
Upload mit Konfigurationsfehler ab. `TranscriptionError.timeout` existiert im
Error-Enum, wird im geprüften Upload-Code aber nicht geworfen; URLSession-
Fehler wie `URLError(.timedOut)` laufen aus dem Upload direkt weiter.

Die Größenprüfung basiert auf Datei-Attributen vor dem Body-Aufbau. Wird das
Limit überschritten, findet kein Upload statt. Der Multipart-Body wird als
temporäre Datei erzeugt und per `defer` entfernt, auch wenn das Schreiben oder
der Upload fehlschlägt.

Timeouts berechnet `calculateTimeout`: Mindestwert 180 Sekunden, Basis
180 Sekunden plus 120 Sekunden pro Audiominute, Höchstwert 900 Sekunden. Der
Request-Timeout nutzt diesen Wert; der Resource-Timeout der erzeugten Session
ist doppelt so hoch.

## Invarianten und Gotchas

- Die Provider-Adapter enthalten keine eigene HTTP-Logik; alle Uploads laufen über `MultipartTranscriptionClient`.
- Das GUI-Diktat setzt kein `response_format`; der Code erwartet anschließend eine dekodierbare JSON-Antwort mit `text`, das konkrete Provider-Default-Verhalten ist externe API-Laufzeit.
- `language` ist optional; Auto-Detect bedeutet im Code ein leeres Settings-Feld und deshalb kein Multipart-Feld.
- Der Datei-Part im Multipart-Envelope schreibt unabhängig vom Ursprung immer `Content-Type: audio/m4a`.
- Der GUI-Pfad chunked nicht und ist deshalb direkt an das 25-MiB-Limit der gewählten Provider-Konfiguration gebunden.
- Der CLI-Pfad chunked vor dem Upload, aber jeder einzelne Chunk wird trotzdem vom Multipart-Client gegen das gleiche Limit geprüft.
- `gpt-4o-transcribe` gilt im CLI-Code als nicht segmentfähig; SRT/VTT brauchen Whisper-Modelle.
- Post-Processing im CLI-Pfad verwirft Segmente nur bei Modes mit `usesPostProcessing`; Raw-Modes ohne Post-Processing behalten Segmente.
- `KeychainManager.exists` kann bei `errSecInteractionNotAllowed` trotzdem `true` liefern, weil ein Key vorhanden sein kann, obwohl gerade keine UI-Interaktion erlaubt ist.
- `KeychainManager.load` hat einen In-Memory-Cache und migriert alte UserDefaults-Keys beim ersten erfolgreichen Lesen.

## Schlüsseldateien

- `WhisperM8/Services/Dictation/TranscriptionService.swift` enthält das gemeinsame Transkriptionsprotokoll für einfache Text-Ergebnisse.
- `WhisperM8/Services/Dictation/TranscriptionProviders.swift` enthält die OpenAI- und Groq-Adapter, die ProviderConfig und Modellnamen an den Multipart-Client übergeben.
- `WhisperM8/Services/Dictation/TranscriptionModels.swift` enthält Response-DTOs, CLI-Detailmodelle, Segmenttypen, Response-Formate und Transkriptionsfehler.
- `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift` enthält Timeout-Berechnung, Multipart-Datei-Writer, Größenprüfung, Upload, Fehler-Mapping und Response-Dekodierung.
- `WhisperM8/Models/TranscriptionProvider.swift` enthält Provider-/Modell-Auswahl, Defaults, Keychain-Keys, Service-Erzeugung und Settings-Migration.
- `WhisperM8/Services/Shared/KeychainManager.swift` enthält die macOS-Keychain-Anbindung mit Cache, Legacy-Migration, Existenzprüfung und Löschen.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift` enthält den GUI-Diktat-Datenfluss von Service-Aufruf bis Delivery und Run-Report.
- `WhisperM8/CLI/CLITranscribe.swift` ist der CLI-Konsument des Multipart-Clients und ist unter [../../cli/](../../cli/) fachlich dokumentiert.
- `WhisperM8/CLI/CLIAudioChunker.swift` erzeugt CLI-eigene Chunks vor dem Upload und gehört fachlich zu [../../cli/](../../cli/).

## Test-Cluster

- `Tests/WhisperM8Tests/MultipartTranscriptionClientTests.swift` deckt erfolgreiche JSON-Antworten und Nicht-200-Fehler-Mapping über eine injizierte URLSession ab.
- `Tests/WhisperM8Tests/TranscriptionUtilityTests.swift` deckt Timeout-Berechnung, Multipart-Envelope, Sprachfeld-Auslassung, Streaming großer Body-Dateien und Modell-Provider-Mapping ab.
- `Tests/WhisperM8Tests/RecordingCoordinatorTranscriptionTests.swift` deckt API-Key-Fehler und Resolver-/Factory-Wiring des GUI-Diktatpfads ohne Keychain oder Netzwerk ab.
- `Tests/WhisperM8Tests/CLITranscriptionTests.swift` deckt den CLI-Konsumenten ab, darunter Segmentfähigkeit und `response_format` im Multipart-Body; Parser-, Formatter-, Stitching- und Chunk-Details gehören zum Test-Cluster der CLI-Dokumentation.
