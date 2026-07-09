---
status: aktiv
updated: 2026-07-09
---

# Transcription — Speech-to-Text-Engine

Die Transcription-Schicht wandelt lokale Audio-Dateien in Text um und kapselt
dafür zwei Provider: OpenAI und Groq. Sie wird von zwei Pfaden genutzt: dem
GUI-Diktat nach einer Hotkey-Aufnahme und dem CLI-Befehl `whisperm8
transcribe` für Audio- oder Videodateien.

Gemeinsam sind Provider-Auswahl, Modellnamen, API-Key-Bezug aus Keychain und
der Multipart-Upload. Unterschiede liegen im Konsumenten: Das GUI-Diktat
erwartet einen einfachen Text und liefert ihn danach an Clipboard,
Auto-Paste, OutputMode-Post-Processing und Run-Report aus; die CLI ruft
denselben Multipart-Client auf, führt Datei- und Chunk-Orchestrierung aber im
CLI-Feature aus.

## Provider und Modelle

`TranscriptionProvider` kennt `openai` und `groq`. Groq ist im aktuellen Code
der empfohlene Default und wird in der Anzeige vor OpenAI einsortiert. Jeder
Provider besitzt eigene Keychain-Keys, API-Key-Links, statische Preisinfos,
eine Modellliste und ein Default-Modell.

| Provider | Modelle | Default im Provider-Modell |
|----------|---------|----------------------------|
| OpenAI | `gpt-4o-transcribe`, `whisper-1` | `gpt-4o-transcribe` |
| Groq | `whisper-large-v3`, `whisper-large-v3-turbo` | `whisper-large-v3` |

Die GUI-Settings speichern Provider und Modell getrennt in Preferences. Beim
Provider-Wechsel wird ein Modell, das nicht zum neuen Provider gehört, auf
dessen Default zurückgesetzt. Alte Werte wie `openai_gpt4o`,
`openai_whisper` und `groq` werden durch `TranscriptionSettings.migrateIfNeeded`
in das aktuelle Provider-plus-Modell-Format überführt. CLI-spezifische
Parser-Defaults gehören zur CLI-Dokumentation unter [../../cli/](../../cli/).

## Sprache und Prompt-Hints

Die STT-Requests senden immer das Modell und die Audio-Datei. Ein
`language`-Feld wird nur gesetzt, wenn ein nicht leerer Sprachcode vorliegt;
in den Settings sind `de`, `en` und Auto-Detect als leerer Wert verdrahtet.

Ein STT-Prompt-Hint-Feld existiert in der aktuellen Multipart-Schicht nicht.
`response_format` wird im GUI-Diktat nicht gesetzt; der Code dekodiert die
Antwort danach als `TranscriptionResponse` mit `text`. Dass die externen
Provider ohne dieses Feld genau diese JSON-Form liefern, ist
API-Laufzeitverhalten außerhalb des Swift-Codes. Die CLI setzt im aktuellen
Transcribe-Pfad entweder `verbose_json` für segmentfähige Modelle oder `json`
für `gpt-4o-transcribe`.

## API-Key-Verwaltung

API-Keys liegen unter dem Keychain-Service `com.whisperm8.app`. Die Accounts
sind `groq_apikey` und `openai_apikey`, abgeleitet aus
`TranscriptionProvider.keychainKey`.

Die Settings-Seite speichert einen neu getippten Key sofort in der Keychain,
zeigt gespeicherte Keys nur maskiert an und kann den Key des aktuellen
Providers löschen. Der echte gespeicherte Key wird nicht in das Textfeld
zurückgeladen. `KeychainManager.load` migriert alte UserDefaults-Werte beim
Lesen in die Keychain und entfernt danach den alten UserDefaults-Eintrag.

Das GUI-Diktat lädt den Key über den Provider-Keychain-Key. Fehlt er, endet der
Lauf mit `TranscriptionError.missingAPIKey`. Die CLI sucht in dieser
Reihenfolge: `--api-key`, `GROQ_API_KEY` beziehungsweise `OPENAI_API_KEY`,
danach WhisperM8-Keychain.

## GUI-Diktat

Nach dem Stoppen einer Aufnahme ruft `RecordingCoordinator` den
Transcription-Service mit Audio-URL, Audio-Dauer und optionaler Sprache auf.
Provider, Modell und API-Key kommen über Resolver, deren Produktions-Defaults
auf `TranscriptionSettings` und `KeychainManager` zeigen.

Der Service liefert Rohtext zurück. Danach normalisiert das Diktat den Text,
speichert ihn als letzte Rohtranskription, führt je nach OutputMode optionales
Post-Processing aus, kopiert das finale Ergebnis in die Zwischenablage und
führt bei aktivierter Auto-Paste-Einstellung die Auslieferung an die vorherige
App aus. Der Run-Report speichert unter anderem Provider, Modell, Sprache,
Audio-Dauer, Rohtext und finales Ergebnis.

## CLI-Transkription

`whisperm8 transcribe` nutzt denselben `MultipartTranscriptionClient`, ruft
aber `transcribeDetailed` auf. Der aktuelle CLI-Pfad fordert `verbose_json`
für segmentfähige Modelle und `json` für `gpt-4o-transcribe` an. Wenn ein
aufgelöster OutputMode tatsächlich Post-Processing nutzt, erzeugt die CLI
Fließtext und verwirft danach Segmente; Raw-Modes ohne Post-Processing
behalten Segmente.

Audio-Extraktion, Chunking, Ausgabeformate, CLI-Defaults und Retry-Details
gehören zum CLI-Feature: [../../cli/](../../cli/). Aus Sicht der
Transcription-Schicht ist nur der Vertrag relevant: Die CLI übergibt dem
Multipart-Client pro Upload eine Audiodatei, optional Sprache,
`response_format` und Audio-Dauer.

## Grenzen

Die von `ProviderConfig.openAI(model:)` und `ProviderConfig.groq(model:)`
erzeugten Konfigurationen setzen jeweils ein Upload-Limit von 25 MiB.
`MultipartTranscriptionClient` prüft die Datei-Attribute vor dem Upload und
wirft `TranscriptionError.fileTooLarge`, wenn die Datei zu groß ist. Eine
HTTP-413-Antwort wird ebenfalls als zu große Audiodatei beschrieben.

Der GUI-Diktatpfad chunked nicht: Die aufgenommene Datei muss direkt unter das
Provider-Limit passen. Der CLI-Pfad kann Dateien vor der Transkription
chunked vorbereiten; die Details liegen in [../../cli/](../../cli/). Jeder
Chunk wird anschließend erneut durch den Multipart-Client gegen das
Provider-Limit geprüft.

Timeouts werden aus der Audio-Dauer berechnet: mindestens 180 Sekunden, Basis
180 Sekunden plus 120 Sekunden pro Audiominute und maximal 900 Sekunden. Pro
Upload wird eine eigene `URLSession` mit diesen Timeouts erzeugt und nach dem
Call invalidiert.

Das Laufzeitverhalten von OpenAI und Groq liegt außerhalb des Swift-Codes.
WhisperM8 kontrolliert Request-Body, Timeout-Konfiguration, Datei-Limit und
HTTP-Fehler-Mapping des Multipart-Clients, aber nicht Provider-Verfügbarkeit
oder Modellantworten.

## Schlüsseldateien

- `WhisperM8/Services/Dictation/TranscriptionService.swift` definiert das gemeinsame `TranscriptionServiceProtocol` für einfache Text-Transkription.
- `WhisperM8/Services/Dictation/TranscriptionProviders.swift` implementiert die OpenAI- und Groq-Service-Wrapper über denselben Multipart-Client.
- `WhisperM8/Services/Dictation/TranscriptionModels.swift` definiert Response-Modelle, detaillierte CLI-Ergebnisse, Response-Formate und `TranscriptionError`.
- `WhisperM8/Services/Dictation/MultipartTranscriptionClient.swift` baut Multipart-Uploads, prüft Größenlimits, berechnet Timeouts und dekodiert einfache oder detaillierte Antworten.
- `WhisperM8/Models/TranscriptionProvider.swift` beschreibt Provider, verfügbare Modelle, Defaults, Keychain-Keys, Preisinfos und Settings-Migration.
- `WhisperM8/Services/Shared/KeychainManager.swift` speichert, lädt, cached, migriert und löscht Provider-API-Keys im macOS-Keychain.
- `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift` ist der GUI-Diktat-Konsument für Transkription, optionales Post-Processing, Delivery und Run-Report.
- `WhisperM8/CLI/CLITranscribe.swift` ist der CLI-Konsument des Multipart-Clients und ist unter [../../cli/](../../cli/) fachlich dokumentiert.
- `WhisperM8/CLI/CLIAudioChunker.swift` erzeugt CLI-eigene Chunks vor dem Upload und gehört fachlich zu [../../cli/](../../cli/).

## Keywords

Transkription, Speech-to-Text, STT, Diktat, Audio transkribieren, Video
transkribieren, Whisper, OpenAI, Groq, GPT-4o Transcribe, Whisper Large v3,
Whisper Large v3 Turbo, API-Key, Keychain, Sprache, Auto-Detect,
Sprachcode, Multipart Upload, Upload-Limit, 25 MB, Datei zu groß, Chunking,
CLI-Chunking, silence-aware Chunking, Untertitel, SRT, VTT, JSON,
Segment-Timestamps, OutputMode, Post-Processing, `TranscriptionServiceProtocol`,
`OpenAITranscriptionService`, `GroqTranscriptionService`,
`MultipartTranscriptionClient`, `ProviderConfig`, `TranscriptionProvider`,
`TranscriptionModel`, `TranscriptionSettings`, `TranscriptionResponseFormat`,
`DetailedTranscription`, `TranscriptionSegment`, `TranscriptionError`,
`MultipartFormDataFileWriter`, `calculateTimeout`, `KeychainManager`,
`RecordingCoordinator.transcribeAndDeliver`, `CLITranscribeCommand`,
`CLIKeyResolver`, `CLIAudioChunker`, `whisperm8 transcribe`,
`GROQ_API_KEY`, `OPENAI_API_KEY`, `groq_apikey`, `openai_apikey`.
