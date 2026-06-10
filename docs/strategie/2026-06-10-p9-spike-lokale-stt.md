# GO/NO-GO-Report: Lokale Transkription via FluidAudio/Parakeet (P9-Spike)

**Stand:** 10. Juni 2026 · Recherche gegen echten Quellcode/GitHub-API/HF-API verifiziert.

**Empfehlung: GO mit Auflagen** (Apple-Silicon-only-Gating, Toolchain-Check, Deutsch-Validierung im ersten Meilenstein)

---

## 1. FluidAudio: Lizenz, SwiftPM, Pflege — ✅ alles grün

- **Lizenz: Apache-2.0**, via GitHub-API bestätigt (`spdx_id: Apache-2.0`). Die Parakeet-CoreML-Modelle selbst sind **CC-BY-4.0** (NVIDIA) — kommerziell nutzbar mit Attribution.
- **SwiftPM-tauglich: ja**, offizieller Weg: `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")`. Plattformen: macOS 14+ / iOS 17+ — passt exakt zu WhisperM8.
- **Aktiv gepflegt: ja, sehr.** Releases via GitHub-API verifiziert: v0.15.2 (07.06.2026), v0.15.1 (05.06.2026), v0.15.0 (04.06.2026), v0.14.8 (31.05.2026); letzter Push 10.06.2026, ~2.160 Stars.
- ⚠️ **Auflage:** FluidAudios `Package.swift` ist `swift-tools-version: 6.0` — WhisperM8s Manifest ist 5.9. Das Root-Manifest kann bei 5.9 bleiben, aber die **Build-Toolchain muss Xcode 16+/Swift 6 sein** (lokal: Xcode 26.2 ✓, CI: macos-26 ✓).

Quellen: github.com/FluidInference/FluidAudio (README, Releases)

## 2. API-Verifikation — ✅ beide Plan-Annahmen bestätigt (Code gelesen)

Aus `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift`:

**(a) Progress-Callback: JA.** Exakte API:

```swift
public static func downloadAndLoad(
    to directory: URL? = nil,
    configuration: MLModelConfiguration? = nil,
    version: AsrModelVersion = .v3,
    encoderPrecision: ParakeetEncoderPrecision = .int8,   // .int8 | .int4
    encoderComputeUnits: MLComputeUnits? = nil,
    progressHandler: DownloadUtils.ProgressHandler? = nil
) async throws -> AsrModels
```

`ProgressHandler = @Sendable (DownloadProgress) -> Void` mit `fractionCompleted: Double` (0–1) und `phase` (DownloadUtils.swift:136–153). Auch `download()`, `load()`, `loadFromCache()` haben den Handler.

**(b) Modell-Verzeichnis: konfigurierbar** via `to directory: URL?`. Default: `~/Library/Application Support/FluidAudio/Models/<repo>/` — App-Support, nicht `~/.cache`.

**Modellgrößen** (HF-API, nur die tatsächlich geladenen Dateien):
- **v3 int8 (Default): ~483 MB** (Encoder 446 + Decoder 23,6 + Joint 12,7 + Rest)
- **v3 int4: ~336 MB** · **v2 (English-only): ~480 MB**

## 3. Deutsch-Qualität — ✅ gut, mit einem Vorbehalt

- **Parakeet v3 unterstützt Deutsch nativ** (offizielle 25-Sprachen-Liste der NVIDIA-Modellkarte). **v2 ist English-only** → nur v3 relevant.
- **WER Deutsch (NVIDIA-Modellkarte): ~5,0 % FLEURS, ~4,8 % CoVoST** — eine der stärksten Sprachen des Modells, Whisper-large-v3-Niveau.
- VoiceInk nutzt seit v1.20 exakt FluidAudio/Parakeet; Issue #561 bestätigt korrekte deutsche Erkennung.
- ⚠️ **Vorbehalt:** v3 detektiert die Sprache selbst (kein `language=de`-Forcieren wie bei Whisper). App-Store-Reviews berichten bei gemischtsprachiger Nutzung gelegentlich falsche Sprachwahl — **für Deutsch-Englisch-Code-Switching (typisch bei Dev-Diktaten!) ist Whisper robuster.** Genau das ist der Akzeptanztest in Meilenstein 1.

Quellen: huggingface.co/nvidia/parakeet-tdt-0.6b-v3, FluidAudio Benchmarks.md, VoiceInk #561

## 4. Latenz — ✅ exzellent

- FluidAudio-Benchmarks: **RTFx ~155–210x** (M1 bis M4 Pro, Neural Engine).
- Hochgerechnet: **30-s-Audio ≈ 0,2–0,5 s**, **5-min-Audio ≈ 1,5–3 s**. Dictation-Apps berichten ~80 ms für kurze Äußerungen.
- ⚠️ Einmaliger **Cold-Start** (Modell-Laden/CoreML-Kompilierung, Sekundenbereich, danach gecacht) → Modelle beim App-Start vorladen, nicht beim ersten Hotkey.

## 5. Intel-Macs — ❌ NEIN, im Code hart geblockt

Verifiziert: `AsrModels.swift:604` → `guard SystemInfo.isAppleSilicon else { throw ASRError.unsupportedPlatform(...) }`. Kompiliert für x86_64, wirft aber zur Laufzeit.

**Gating:** Lokale Transkription nur bei `#if arch(arm64)` bzw. Laufzeit-Check anbieten; auf Intel die Settings-Option ausblenden, Cloud bleibt einziger Pfad.

## 6. Alternativen kurz

**WhisperKit (argmax):** MIT, seit Mai 2026 im Argmax-OSS-SDK v1.0.0, macOS 14+. 99 Sprachen inkl. erzwingbarem Deutsch + robustes Code-Switching — aber deutlich langsamer als Parakeet (RTF einstellig vs. 150x+) und größere Modelle. → Plan B, falls der Code-Switching-Akzeptanztest scheitert.

**Apple SpeechAnalyzer (macOS 26):** Kostenlos, on-device, Deutsch enthalten, sehr schnell — aber **Mindest-OS macOS 26** (WhisperM8 targetet 14) und API jung. Später als Zusatz-Provider denkbar, nicht als Erstlösung.

---

## Kleinster sinnvoller erster Meilenstein

Hinter dem bestehenden `TranscriptionServiceProtocol` (`transcribe(audioURL:language:audioDuration:)`):

1. FluidAudio als SwiftPM-Dependency (`from: "0.15.2"`); Toolchain-Check Xcode 16+.
2. Neuer `LocalParakeetTranscriptionService: TranscriptionServiceProtocol` — nur `arch(arm64)`: M4A via `AVAudioFile` zu 16-kHz-Float-Samples dekodieren → `AsrManager.transcribe(samples)` (v3, int8, Default-Cache-Dir). Inferenz NICHT MainActor-geerbt laufen lassen; Cancel-UX beachten (Overlay darf nach ESC nicht bis Inferenz-Ende hängen).
3. Settings: dritter Provider „Lokal (Parakeet)" mit Download-Button + Fortschrittsbalken via `progressHandler` (~483 MB); auf Intel ausgeblendet.
4. Fallback: wirft der lokale Pfad, automatisch auf den konfigurierten Cloud-Provider zurückfallen (Aufnahme bleibt dank FailedRecordingsStore erhalten).
5. **Akzeptanztest vor Rollout:** 10 echte deutsche Diktate (inkl. deutsch-englischem Code-Switching) gegen GPT-4o-Transcribe vergleichen — das einzige verbliebene Restrisiko.
