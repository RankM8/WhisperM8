# Speech-to-Text Modelle - Recherche Stand 4. Februar 2026

> Diese Recherche dient als Grundlage für die Auswahl der besten Transkriptions-Modelle für WhisperM8.

---

## Executive Summary

**Top 3 für unseren Use-Case (Diktier-App):**

1. **Deepgram Nova-3** - Beste Balance aus Geschwindigkeit, Genauigkeit und Preis
2. **OpenAI GPT-4o-transcribe** - Höchste Genauigkeit, aber Timeout-Probleme bei langen Audios
3. **Groq Whisper Large v3 Turbo** - Extrem schnell (216x Echtzeit), gutes Preis-Leistungs-Verhältnis

---

## Benchmark-Übersicht (Word Error Rate - niedriger = besser)

| Modell | WER | Latenz | Preis | Streaming |
|--------|-----|--------|-------|-----------|
| **GPT-4o-transcribe** | 8.9% | 320ms | $0.006/min | Nein |
| **Deepgram Nova-3** | 5.26% | <300ms | $0.0043/min | Ja |
| **AssemblyAI Universal-2** | 8.4% | 300ms | ~$0.01/min | Ja |
| **Whisper Large v3** | 10.6% | - | $0.006/min | Nein |
| **Whisper Large v3 Turbo** | 12% | - | - | Nein |
| **Groq Whisper v3** | ~10% | 299x RT | $0.002/min | Nein |
| **Groq Whisper v3 Turbo** | ~12% | 216x RT | $0.002/min | Nein |
| **NVIDIA Canary Qwen 2.5B** | 5.63% | - | Self-hosted | Nein |

*Quellen: [Artificial Analysis](https://artificialanalysis.ai/speech-to-text), [Deepgram Benchmarks](https://deepgram.com/learn/speech-to-text-benchmarks), [Northflank](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)*

---

## Detailanalyse der Top-Modelle

### 1. OpenAI GPT-4o-transcribe

**Stärken:**
- Höchste Genauigkeit (8.9% WER) unter kommerziellen APIs
- Bessere Erkennung von Akzenten, Hintergrundgeräuschen, variablen Sprechgeschwindigkeiten
- 100+ Sprachen

**Schwächen:**
- **Timeout-Probleme bei langen Audios** (>60 Sekunden problematisch)
- Kein Streaming
- "Glättet" Transkripte (weniger wortgetreu bei unstrukturierter Sprache)
- Max 25 MB Dateigröße, max 25 Minuten

**Preis:** $0.006/min

*Quelle: [OpenAI Audio Models](https://openai.com/index/introducing-our-next-generation-audio-models/)*

---

### 2. OpenAI Whisper-1 (API) / Whisper Large v3

**Stärken:**
- Bewährtes Modell, stabil
- 99+ Sprachen
- Gute Performance bei internationalen Akzenten

**Schwächen:**
- Höhere WER als GPT-4o-transcribe (10.6%)
- Langsamer als neuere Modelle
- Kein Streaming

**Preis:** $0.006/min (OpenAI API)

---

### 3. Whisper Large v3 Turbo

**Stärken:**
- 6x schneller als Large v3
- Nur 809M Parameter (vs 1.55B bei Large v3)
- Genauigkeit nur 1-2% schlechter als Large v3

**Schwächen:**
- Nicht für Translation trainiert
- Etwas höhere WER (12% vs 10%)

**Verfügbarkeit:**
- Hugging Face (Self-hosted)
- [Groq](https://console.groq.com/docs/model/whisper-large-v3-turbo) - 216x Echtzeit-Speed
- [Cloudflare Workers AI](https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/)
- DeepInfra

*Quelle: [Groq Blog](https://groq.com/blog/whisper-large-v3-turbo-now-available-on-groq-combining-speed-quality-for-speech-recognition)*

---

### 4. Deepgram Nova-3

**Stärken:**
- **Beste Genauigkeit** (5.26% WER)
- **Niedrigste Latenz** (<300ms)
- Echtzeit-Streaming
- Self-serve Customization (Vokabular-Anpassung ohne Retraining)
- PII-Redaktion eingebaut
- Domain-spezifische Modelle (z.B. Nova-3 Medical: 1-10% WER)

**Schwächen:**
- Kein Whisper-kompatibles API-Format
- Eigene SDK erforderlich

**Preis:** $0.0043/min (günstigster Top-Tier)

**Besonderheit:** Erste Voice-AI mit Self-serve Customization

*Quelle: [Deepgram Docs](https://developers.deepgram.com/docs/model), [Deepgram Learn](https://deepgram.com/learn/best-speech-to-text-apis-2026)*

---

### 5. AssemblyAI Universal-2

**Stärken:**
- Höchste Streaming-Genauigkeit (14.5% WER streaming, 8.4% batch)
- 99+ Sprachen
- Integrierte Speech Intelligence:
  - Sentiment Analysis
  - PII Detection
  - Speaker Diarization
  - Content Moderation

**Schwächen:**
- Teurer als Alternativen
- Nicht das schnellste

**Preis:** ~$0.01/min

*Quelle: [AssemblyAI Blog](https://www.assemblyai.com/blog/best-api-models-for-real-time-speech-recognition-and-transcription)*

---

### 6. Groq (Whisper Large v3 / v3 Turbo)

**Stärken:**
- **Extrem schnell**: 299x Echtzeit (v3), 216x Echtzeit (v3 Turbo)
- **Günstigster Preis**: $0.002/min
- Whisper-kompatibles API-Format
- Bis 100 MB Dateigröße (via URL, Paid Tier)

**Schwächen:**
- Keine eigene Modellentwicklung (nutzt OpenAI Whisper)
- 25 MB Limit für Direct Upload
- Rate-Limited auf Free Tier

**Preis:** $0.002/min

*Quelle: [Groq Blog](https://groq.com/blog/groq-runs-whisper-large-v3-at-a-164x-speed-factor-according-to-new-artificial-analysis-benchmark)*

---

## Open-Source Alternativen (Self-Hosted)

### NVIDIA Canary Qwen 2.5B
- **#1 auf Hugging Face Open ASR Leaderboard**
- 5.63% WER
- Kombiniert ASR mit LLM (Speech-Augmented Language Model)
- Benötigt GPU-Infrastruktur

### NVIDIA Parakeet TDT 1.1B
- Fokus auf Inference-Speed
- RTFx >2000 (extrem schnell)
- Rang 23 in Genauigkeit, aber 6.5x schneller als Canary Qwen

### Useful Sensors Moonshine
- Nur 27M Parameter
- Für Mobile/Embedded
- Übertrifft Whisper Tiny/Small trotz kleinerer Größe

*Quelle: [Northflank Benchmarks](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)*

---

## Empfehlung für WhisperM8

### Primär-Provider (nach Priorität):

1. **Deepgram Nova-3** - Falls wir einen neuen Provider integrieren
   - Beste Genauigkeit + Geschwindigkeit + Preis
   - Erfordert eigene SDK-Integration

2. **Groq Whisper v3 Turbo** - Für bestehende Whisper-API-Kompatibilität
   - Extrem schnell, günstig
   - Drop-in Replacement für aktuelle Groq-Integration

3. **OpenAI GPT-4o-transcribe** - Für beste Qualität bei kurzen Aufnahmen
   - Bereits integriert
   - Probleme bei >60s müssen mit erhöhten Timeouts gelöst werden

### Modell-Auswahl basierend auf Audio-Länge:

| Audio-Länge | Empfohlenes Modell | Grund |
|-------------|-------------------|--------|
| < 60 Sekunden | GPT-4o-transcribe | Beste Qualität, schnell |
| 60s - 5 Minuten | Groq Whisper v3 Turbo | Schnell, zuverlässig |
| > 5 Minuten | Deepgram Nova-3 | Streaming, keine Timeouts |

---

## API-Kompatibilität

| Provider | API-Format | Drop-in für Whisper API |
|----------|------------|------------------------|
| OpenAI | OpenAI Whisper | Ja |
| Groq | OpenAI Whisper | Ja |
| Deepgram | Eigenes Format | Nein (SDK nötig) |
| AssemblyAI | Eigenes Format | Nein (SDK nötig) |

---

## Preisvergleich (pro Minute)

| Provider | Preis/min | 1 Stunde | 10 Stunden |
|----------|-----------|----------|------------|
| Groq | $0.002 | $0.12 | $1.20 |
| Deepgram Nova-3 | $0.0043 | $0.26 | $2.58 |
| OpenAI (Whisper/GPT-4o) | $0.006 | $0.36 | $3.60 |
| AssemblyAI | ~$0.01 | $0.60 | $6.00 |

---

## Nächste Schritte

1. **Sofort:** Groq Whisper v3 Turbo als Option hinzufügen (bereits API-kompatibel)
2. **Mittelfristig:** Deepgram Nova-3 Integration evaluieren
3. **Optional:** Automatische Modellauswahl basierend auf Audio-Länge

---

## Quellen

- [Artificial Analysis - Speech to Text Leaderboard](https://artificialanalysis.ai/speech-to-text)
- [Deepgram - Best Speech-to-Text APIs 2026](https://deepgram.com/learn/best-speech-to-text-apis-2026)
- [AssemblyAI - Top APIs for Real-Time STT 2026](https://www.assemblyai.com/blog/best-api-models-for-real-time-speech-recognition-and-transcription)
- [Northflank - Best Open Source STT 2026](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [Groq - Whisper Large v3 Turbo](https://groq.com/blog/whisper-large-v3-turbo-now-available-on-groq-combining-speed-quality-for-speech-recognition)
- [OpenAI - Next Generation Audio Models](https://openai.com/index/introducing-our-next-generation-audio-models/)
- [Hugging Face - Whisper Large v3 Turbo](https://huggingface.co/openai/whisper-large-v3-turbo)
- [Index.dev - Whisper vs AssemblyAI vs Deepgram 2026](https://www.index.dev/skill-vs-skill/ai-whisper-vs-assemblyai-vs-deepgram)
