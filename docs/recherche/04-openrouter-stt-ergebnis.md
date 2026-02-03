# Recherche-Ergebnis: OpenRouter Speech-to-Text

# OpenRouter STT support and transcription alternatives

**OpenRouter does not offer a dedicated Speech-to-Text endpoint**, making it unsuitable as a drop-in replacement for OpenAI's `/v1/audio/transcriptions` API. However, **Groq provides full OpenAI API compatibility** for audio transcription at significantly lower cost and faster speeds. For those needing alternatives, local Whisper implementations offer zero ongoing costs, while specialized STT providers like Deepgram and AssemblyAI deliver superior features at competitive pricing—though none match OpenAI's API format.

## OpenRouter lacks a Whisper-style transcription endpoint

OpenRouter is fundamentally an **LLM routing service**, not a dedicated audio transcription platform. Community users attempting to call `/v1/audio/transcriptions` receive 405 "method undefined" errors. The platform does not host Whisper models or expose any STT-specific endpoints.

**However, OpenRouter does support audio input through multimodal chat completions.** Audio-capable models like `openai/gpt-4o-audio-preview` (**$40/M input tokens**) and `openai/gpt-audio-mini` (**$0.60/M input**) can process base64-encoded audio files via the standard `/api/v1/chat/completions` endpoint. Users must explicitly prompt these models to transcribe, making this a workaround rather than a true transcription service. Supported formats include WAV, MP3, FLAC, OGG, AAC, and M4A.

This approach has significant limitations: audio must be base64-encoded (no direct URLs), pricing is token-based rather than duration-based making cost unpredictable, and transcription quality depends on prompting rather than a purpose-built model.

## Groq delivers OpenAI-compatible transcription at 189x real-time speed

For developers needing a **true drop-in replacement**, Groq's transcription API stands out. The endpoint at `https://api.groq.com/openai/v1/audio/transcriptions` accepts the same request format as OpenAI's API—simply change the base URL and API key in existing code:

```python
from openai import OpenAI
client = OpenAI(base_url="https://api.groq.com/openai/v1", api_key="GROQ_KEY")
```

Two models are available: **whisper-large-v3** at $0.111/hour with 10.3% word error rate and full translation support, and **whisper-large-v3-turbo** at **$0.04/hour** offering the best price-performance ratio. Both achieve **189-299x real-time processing**—a 10-minute audio file transcribes in 2-3 seconds. This represents 70% cost savings over OpenAI's $0.36/hour while delivering dramatically faster results.

File size limits are 25MB for direct uploads and **100MB via URL** on paid tiers. The batch API offers an additional 50% discount for non-urgent workloads. The main limitations are a 10-second minimum billing increment and 224-token prompt cap for vocabulary hints.

## Local Whisper implementations eliminate ongoing costs

Self-hosted options provide unlimited transcription without API fees, ideal for high-volume processing or data-sensitive applications.

**whisper.cpp** is the most versatile option—a C/C++ implementation with **46,000 GitHub stars** that runs across macOS, Linux, Windows, iOS, Android, and even WebAssembly. On Apple Silicon, Metal acceleration achieves real-time transcription with the base model. NVIDIA GPUs with CUDA provide **5-10x speedup** over CPU. Critically, whisper.cpp includes **whisper-server**, an HTTP server exposing an OpenAI-compatible `/v1/audio/transcriptions` endpoint out of the box.

**faster-whisper** targets Python developers with a CTranslate2-based implementation achieving **4x faster processing** than OpenAI's original Python code. With batched inference enabled, speeds reach **12.5x faster**—processing a 13-minute file in just 17 seconds on an RTX 3070. INT8 quantization reduces memory requirements to ~3GB VRAM while maintaining accuracy.

Resource requirements vary by model: the **large-v3** model needs approximately 4GB VRAM (GPU) or 4GB RAM (CPU), while the base model runs comfortably on 2GB. Modern consumer GPUs like RTX 3060 handle production workloads effectively. CPU-only operation is viable but 5-10x slower than GPU-accelerated inference.

## Cloud STT providers offer advanced features but require code changes

None of the major cloud STT providers—AssemblyAI, Deepgram, or Google Cloud—offer OpenAI API format compatibility, requiring integration code modifications.

**AssemblyAI** delivers the **lowest base pricing at $0.15/hour** ($0.0025/minute) for their Universal model, with 99 language support at a flat rate. Their standout feature is **LeMUR**, an integrated framework for applying LLMs directly to transcripts for summarization, Q&A, and analysis. Speaker diarization, sentiment analysis, and PII redaction are available as add-ons ($0.02-0.08/hour each). Setup is straightforward with API-key authentication.

**Deepgram** emphasizes **speed and developer experience**, with sub-300ms streaming latency and claims of 3x faster processing than OpenAI's Whisper API. Their Nova-3 model achieves a **47% reduction in word error rate** versus competitors at $0.0077/minute. Uniquely, Deepgram offers Whisper Cloud—managed hosting of OpenAI's Whisper model—though using Deepgram's response format rather than OpenAI's. Enterprise customers can deploy Deepgram on-premises.

**Google Cloud Speech-to-Text** offers the broadest language support (**125+ languages**) and specialized medical transcription models, but at higher cost ($0.016-0.024/minute) and with significantly more complex setup requiring GCP projects, service accounts, and credential management. The 15-second billing granularity also inflates costs for short audio clips.

## Comparison of STT options

| Provider | Model | OpenAI API Compatible | Price | Speed | Best For |
|----------|-------|----------------------|-------|-------|----------|
| **Groq** | whisper-large-v3-turbo | ✅ Yes (drop-in) | $0.04/hr ($0.0007/min) | 189-299x RT | OpenAI replacement, fastest cloud |
| **Groq** | whisper-large-v3 | ✅ Yes (drop-in) | $0.111/hr ($0.0019/min) | 189-299x RT | Highest accuracy cloud option |
| **OpenRouter** | GPT-4o Audio (workaround) | ❌ Chat endpoint only | $40/M tokens | Varies | Already using OpenRouter for LLMs |
| **whisper.cpp** | large-v3 | ✅ Server mode | Free (hardware costs) | GPU: ~50x RT | Privacy, self-hosted, cross-platform |
| **faster-whisper** | large-v3 (batched) | ❌ Python API | Free (hardware costs) | ~50x RT (batched) | Python integration, high throughput |
| **AssemblyAI** | Universal | ❌ Proprietary | $0.15/hr ($0.0025/min) | ~300ms stream | LLM analysis, 99 languages |
| **Deepgram** | Nova-3 | ❌ Proprietary | $0.0077/min | <300ms stream | Real-time apps, voice agents |
| **Google Cloud** | Chirp | ❌ SDK-based | $0.016/min | Moderate | GCP ecosystem, medical |

## Conclusion

For developers seeking **direct OpenAI API compatibility**, Groq is the clear winner—offering whisper-large-v3-turbo as a drop-in replacement at **$0.04/hour** (82% cheaper than OpenAI) with industry-leading 189-299x real-time speed. Simply swap the base URL and API key in existing code.

For **self-hosted deployments**, whisper.cpp with its built-in server provides an OpenAI-compatible endpoint at zero ongoing cost, making it ideal for high-volume or privacy-sensitive applications. Python developers may prefer faster-whisper for its simpler integration and batched processing capabilities.

If advanced features like speaker diarization, sentiment analysis, or LLM-powered transcript analysis are priorities, AssemblyAI and Deepgram offer compelling capabilities—but require rewriting integration code due to incompatible API formats. OpenRouter's multimodal approach remains a workaround rather than a solution, best suited only for users already committed to the OpenRouter ecosystem for other reasons.
---

## Unterstützt OpenRouter STT?

<!-- Nach der Recherche ausfüllen -->

## Alternative Anbieter

<!-- Nach der Recherche ausfüllen -->

## Empfehlung

<!-- Nach der Recherche ausfüllen -->

## Preisvergleich

<!-- Nach der Recherche ausfüllen -->
