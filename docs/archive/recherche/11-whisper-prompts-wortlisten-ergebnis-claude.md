# Recherche-Ergebnis: Whisper Prompts & Custom Vocabulary

**Quelle:** Claude (Anthropic)
**Datum:** ___________
**Modell:** ___________

---

<!-- Paste Claude's research result below this line -->

# Whisper API Prompt Parameters and Custom Vocabulary for Denglisch Transcription

**Bottom line**: All major Whisper APIs (OpenAI and Groq) support a `prompt` parameter limited to **224 tokens** that can guide transcription style and vocabulary spelling, but this approach is explicitly "not especially reliable" according to OpenAI. For a macOS app handling Denglisch (German-English code-switching), the optimal strategy combines setting `language="de"`, using example-sentence prompts with embedded English tech terms, and implementing GPT-4 post-processing for critical applications. Native custom vocabulary is not supported—the prompt parameter is a workaround with significant limitations.

---

## 1. Prompt parameter support across Whisper APIs

The prompt parameter exists across all major Whisper APIs with consistent behavior and limitations. This parameter **conditions the decoder** rather than providing instructions—Whisper follows the *style* of the prompt, not commands within it.

### OpenAI whisper-1

| Attribute | Value |
|-----------|-------|
| **Prompt supported** | ✅ Yes |
| **Parameter name** | `prompt` (string, optional) |
| **Maximum length** | 224 tokens (~892 characters) |
| **Behavior** | Only final 224 tokens used; earlier tokens silently ignored |
| **Tokenizer** | Multilingual Whisper tokenizer (German/English); GPT-2 for English-only |

The prompt's technical mechanism works by conditioning the sequence-to-sequence Transformer's decoder. OpenAI's documentation explicitly states: "Prompting Whisper is not the same as prompting GPT. If you submit an instruction like 'Format lists in Markdown format', the model will not comply, as it follows the style of the prompt, rather than any instructions contained within."

### OpenAI gpt-4o-transcribe

| Attribute | Value |
|-----------|-------|
| **Prompt supported** | ✅ Yes |
| **Architecture** | GPT-4o-based (closed source) |
| **Key difference** | Accepts "detailed prompts" vs whisper-1's keyword-based approach |
| **Limitation** | No native timestamp support; no translation endpoint |

Developer observations suggest gpt-4o-transcribe handles prompts more flexibly than whisper-1, with lower word error rates on multilingual benchmarks. However, the **gpt-4o-transcribe-diarize** variant does **not** support prompts.

### Groq Whisper models

All three Groq models support prompts identically:

| Model | Prompt Support | Language Support | Speed | Cost |
|-------|---------------|------------------|-------|------|
| `whisper-large-v3` | ✅ 224 tokens | Multilingual (50+) | 189x real-time | $0.111/hr |
| `whisper-large-v3-turbo` | ✅ 224 tokens | Multilingual (50+) | 216x real-time | $0.04/hr |
| `distil-whisper-large-v3-en` | ✅ 224 tokens | **English only** | 250x+ real-time | $0.02/hr |

Groq's API is OpenAI-compatible, so prompt behavior mirrors OpenAI's implementation. Key guideline from Groq: "Use the same language as the audio file" for the prompt in transcription mode.

### Prompt reliability assessment

OpenAI states directly: **"These techniques are not especially reliable, but can be useful in some situations."**

Factors affecting reliability:
- **Longer prompts** (multiple sentences) work better than short ones
- **Typical transcript styles** are followed more reliably than unusual formatting
- **Larger models** (large-v3) follow prompts more consistently
- **Audio clarity** significantly impacts prompt adherence

---

## 2. Custom vocabulary capabilities and word list formatting

**No native custom vocabulary parameter exists** in any Whisper API. The prompt parameter serves as the only workaround, with significant constraints.

### Using prompts for vocabulary guidance

The prompt can accept word lists to guide spellings. Three formats have proven effective:

**Glossary format (comma-separated)**:
```python
prompt = "Glossary: API, Repository, Commit, Pull Request, Deploy, Kubernetes, CI/CD, Endpoint, Webhook"
```

**Example sentence format (most effective)**:
```python
prompt = "Der Developer hat den Commit gepusht und das Deployment getriggert. Die API-Endpoints sind dokumentiert."
```

**Contextual narrative**:
```python
prompt = "The following is a German conversation about software development, which includes terms like Repository, Kubernetes, TypeScript, and marketing terms like Funnel, Conversion, CTR."
```

### Practical limits

| Constraint | Impact |
|------------|--------|
| **224 tokens maximum** | Approximately 50-100 vocabulary terms feasible |
| **Truncation behavior** | Only final tokens considered; beginning of long prompts ignored |
| **Segment limitation** | `initial_prompt` only applies to first 30-second segment by default |
| **Recognition reliability** | Model "considers" but doesn't guarantee usage of provided terms |

For audio longer than 30 seconds, Whisper processes in segments. The prompt applies only to the first segment—subsequent segments use the previous segment's decoded output as context, overwriting the original prompt. Some implementations offer `carry_initial_prompt=True` to maintain vocabulary across segments.

---

## 3. Denglisch code-switching: challenges and optimal settings

Whisper was **explicitly not designed for code-switching**. An OpenAI maintainer stated: "It's intended for monolingual audio inputs, and --language should specify the language used. Whisper doesn't support code-switching inputs very well."

### Observed behavior with mixed language

Whisper detects language from the first 30 seconds and applies that setting to the entire audio. When encountering German-English mixing:
- Sometimes preserves both languages correctly
- Sometimes translates everything to the detected language
- Sometimes produces nonsensical transcriptions
- Behavior is inconsistent and described as "random" by developers

### Optimal language configuration for Denglisch

**Recommendation: Set `language="de"` explicitly**

Rationale:
1. Auto-detect uses only first 30 seconds—German start locks to German anyway
2. Explicit setting prevents misdetection in ambiguous audio
3. When language is German, Whisper often **preserves common English terms** (especially tech vocabulary) rather than translating them
4. One user reported: "Setting the Language Argument to 'de' produced the correct transcription, preserving all three languages"

### Does setting German + English terms in prompt work?

**Yes, this combination shows the best results for Denglisch**:

```python
result = client.audio.transcriptions.create(
    file=audio_file,
    model="whisper-large-v3",
    language="de",  # Set German as base
    prompt="Im Sprint Planning besprechen wir das Deployment der neuen API. Der Commit ist im GitHub Repository."
)
```

The German language setting tells Whisper the primary language, while the prompt with embedded English technical terms conditions the model to expect and preserve those terms.

### Why not set language to English with German terms?

Setting `language="en"` for predominantly German audio causes more problems—German words get anglicized or mistranscribed. English terms naturally occurring in German speech (common in tech contexts) are typically preserved better when German is the base language.

---

## 4. Best practices for Denglisch prompt construction

The most effective approach combines example sentences in Denglisch style with a glossary list, all in German base text with English vocabulary naturally embedded.

### Optimized prompt template for tech/SEO/marketing

```python
denglisch_prompt = """
Im heutigen Meeting besprechen wir das Deployment der neuen API.
Der Developer hat seinen Branch erstellt und den Pull Request submitted.
Wir reviewen den Code und mergen nach dem Approval.
Das Deployment geht automatisch über die CI/CD Pipeline.

Die SEO-Performance zeigt Verbesserungen. Das Keyword-Ranking ist gestiegen.
Die SERP-Visibility hat sich erhöht durch besseres Schema Markup.
Im Marketing sehen wir gute Conversion-Rates im Upper Funnel.

Glossary: API, Repository, Commit, Pull Request, Deploy, Kubernetes, TypeScript, React, Swift, Xcode, GitHub, CI/CD, Endpoint, Webhook, Keyword, Ranking, Backlink, SERP, Crawling, Meta-Tags, Schema Markup, Funnel, Lead, Conversion, CTR, CPC, ROAS, Landing Page, CTA
"""
```

### Prompt language choice

**Use German base text with English terms naturally embedded**—matching the dominant spoken language. Research indicates:
- English prompts may slightly outperform on technical accuracy
- For style matching, use the same language as the audio
- The "example text" style (demonstrating how Denglisch actually sounds) works best

### Structural recommendations

| Element | Recommendation |
|---------|---------------|
| **Sentence structure** | German grammar with English nouns/verbs inline |
| **Length** | 100-200 tokens (multiple sentences, more reliable than short) |
| **Glossary position** | At end of prompt (final tokens get most attention) |
| **Avoid** | Starting prompts with greetings or phrases likely at audio start (may appear in output) |

### Known failure cases to avoid

The prompt text itself sometimes gets output instead of actual transcription. Mitigation: Don't use phrases like "Guten Tag" or common conversation starters that could occur naturally at the audio's beginning.

---

## 5. Model comparison table

| Feature | OpenAI whisper-1 | OpenAI gpt-4o-transcribe | Groq whisper-large-v3 | Groq whisper-large-v3-turbo |
|---------|-----------------|-------------------------|----------------------|---------------------------|
| **Prompt parameter** | ✅ 224 tokens | ✅ Yes (detailed prompts) | ✅ 224 tokens | ✅ 224 tokens |
| **Custom vocabulary** | ⚠️ Via prompt only | ⚠️ Via prompt only | ⚠️ Via prompt only | ⚠️ Via prompt only |
| **Multilingual capability** | ✅ 99+ languages | ✅ 100+ languages | ✅ 50+ languages | ✅ 50+ languages |
| **Denglisch quality** | ⭐⭐⭐ Moderate | ⭐⭐⭐⭐ Better | ⭐⭐⭐⭐ Good | ⭐⭐⭐ Moderate |
| **Timestamps** | ✅ verbose_json | ❌ Not native | ✅ verbose_json | ✅ verbose_json |
| **Streaming** | ❌ No | ✅ Yes | ❌ No | ❌ No |
| **Translation** | ✅ Yes | ❌ No | ✅ Yes | ❌ No |
| **Speed** | ~6x real-time | ~8x real-time | 189x real-time | 216x real-time |
| **Relative cost** | Baseline | Higher | Lower | Lowest |

**Recommendation for WhisperM8**: Use **Groq whisper-large-v3** for best Denglisch handling at lower cost and dramatically faster speed, or **OpenAI gpt-4o-transcribe** if accuracy is paramount and cost is less critical. Avoid `distil-whisper-large-v3-en` as it's English-only and unsuitable for German content.

---

## 6. Alternatives and workarounds

### APIs with native custom vocabulary support

| API | Custom Vocabulary | Implementation | Max Terms | Reliability |
|-----|-------------------|----------------|-----------|-------------|
| **Google Cloud STT** | ✅ Native "Phrase Hints" + Boost | `SpeechContext` with phrases array, boost values 0-20 | 1000+ | ⭐⭐⭐⭐⭐ Very High |
| **AssemblyAI** | ✅ Native "Word Boost" | `word_boost` array + `boost_param` (low/default/high) | 1000 terms, 6 words/phrase | ⭐⭐⭐⭐ High |
| **Deepgram** | ✅ "Keywords" + "Keyterm Prompting" | Query param `keywords=WORD:INTENSIFIER` | 100/request | ⭐⭐⭐⭐ High |
| **Amazon Transcribe** | ✅ Custom Vocabulary tables | Upload vocabulary file to S3, reference in request | No explicit limit | ⭐⭐⭐⭐⭐ Very High |
| **Whisper APIs** | ⚠️ Prompt only | 224-token prompt parameter | ~50-100 effective | ⭐⭐⭐ Moderate |

For Denglisch with extensive vocabulary needs, **AssemblyAI** or **Google Cloud Speech-to-Text** offer significantly more reliable custom vocabulary enforcement than Whisper's soft prompting approach.

### Whisper fine-tuning availability

**Yes, Whisper can be fine-tuned** via Hugging Face Transformers with `Seq2SeqTrainer`, but with significant requirements:
- Minimum **4+ hours** of domain-specific audio with transcripts
- **20-40 GB VRAM** for optimal training
- Learning rate ~40x smaller than pre-training (~1e-5)
- Risk of catastrophic forgetting with small datasets

Fine-tuning mainly improves recognition patterns rather than vocabulary expansion—the pre-trained tokenizer already covers vast vocabulary for 96 languages.

### Hybrid approach: Whisper + LLM correction

**Highly recommended by OpenAI Cookbook**—this dual strategy overcomes prompt limitations:

```python
# Step 1: Whisper transcription with prompt (224 token limit)
transcript = client.audio.transcriptions.create(
    file=audio_file,
    model="whisper-1",
    prompt="API, Repository, Commit, Pull Request, Deploy, Kubernetes",
    language="de"
)

# Step 2: GPT-4 post-processing (no practical token limit)
system_prompt = """You are a transcription assistant. Correct any spelling 
discrepancies in this German transcript. Preserve English technical terms 
exactly as spelled: API, Repository, Commit, Pull Request, Deploy, Kubernetes, 
TypeScript, React, Swift, Xcode, GitHub, CI/CD, Endpoint, Webhook, Keyword, 
Ranking, Backlink, SERP, Crawling, Meta-Tags, Schema Markup, Funnel, Lead, 
Conversion, CTR, CPC, ROAS, Landing Page, CTA.
Only fix spelling errors. Do not change meaning or add content."""

corrected = client.chat.completions.create(
    model="gpt-4",
    temperature=0,
    messages=[
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": transcript.text}
    ]
)
```

Benefits: GPT-4's context window handles thousands of terms versus Whisper's 224-token constraint. Trade-off: additional API cost and latency—best for batch processing, not real-time.

---

## 7. Swift/macOS implementation for WhisperM8

### Available Swift libraries

| Library | Type | Prompt Support | Best For |
|---------|------|----------------|----------|
| **WhisperKit** (argmaxinc) | On-device CoreML | ✅ `promptText` | macOS/iOS native, offline |
| **SwiftWhisper** (exPHAT) | On-device whisper.cpp | ✅ `initialPrompt` | Cross-platform Swift |
| **URLSession** | Cloud API | ✅ Via multipart form | Cloud-based transcription |

### Complete Swift implementation with multipart/form-data

```swift
import Foundation

class WhisperAPIService {
    private let apiKey: String
    private let endpoint = "https://api.openai.com/v1/audio/transcriptions"
    
    // Denglisch prompt for tech/SEO/marketing context
    private let denglischPrompt = """
    Im Sprint Planning besprechen wir das Deployment der neuen API.
    Der Developer hat den Commit gepusht und den Pull Request erstellt.
    Die SEO-Metrics zeigen gute Keyword-Rankings und Conversion-Rates.
    
    Glossary: API, Repository, Commit, Pull Request, Deploy, Kubernetes, 
    TypeScript, React, Swift, Xcode, GitHub, CI/CD, Endpoint, Webhook, 
    Keyword, Ranking, Backlink, SERP, Funnel, Conversion, CTR, CPC, ROAS
    """
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func transcribe(
        audioData: Data,
        filename: String,
        customPrompt: String? = nil,
        language: String = "de"
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Model parameter
        body.append(multipartField(name: "model", value: "whisper-1", boundary: boundary))
        
        // Prompt parameter - use custom or default Denglisch prompt
        let effectivePrompt = customPrompt ?? denglischPrompt
        body.append(multipartField(name: "prompt", value: effectivePrompt, boundary: boundary))
        
        // Language parameter - "de" for Denglisch
        body.append(multipartField(name: "language", value: language, boundary: boundary))
        
        // Response format
        body.append(multipartField(name: "response_format", value: "json", boundary: boundary))
        
        // Audio file
        body.append(multipartFileField(
            name: "file",
            filename: filename,
            mimeType: mimeType(for: filename),
            data: audioData,
            boundary: boundary
        ))
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw WhisperError.requestFailed
        }
        
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }
    
    private func multipartField(name: String, value: String, boundary: String) -> Data {
        var field = Data()
        field.append("--\(boundary)\r\n".data(using: .utf8)!)
        field.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        field.append("\(value)\r\n".data(using: .utf8)!)
        return field
    }
    
    private func multipartFileField(name: String, filename: String, mimeType: String, data: Data, boundary: String) -> Data {
        var field = Data()
        field.append("--\(boundary)\r\n".data(using: .utf8)!)
        field.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        field.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        field.append(data)
        field.append("\r\n".data(using: .utf8)!)
        return field
    }
    
    private func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "webm": return "audio/webm"
        default: return "audio/mpeg"
        }
    }
}

struct TranscriptionResponse: Codable {
    let text: String
}

enum WhisperError: Error {
    case requestFailed
}
```

### Static vs. dynamic prompts

| Strategy | Use Case | Performance Impact |
|----------|----------|-------------------|
| **Static prompt** | Consistent vocabulary (general Denglisch tech talk) | Minimal—tokenization cached |
| **Dynamic per session** | Context varies (SEO meeting vs. dev standup) | Minimal—simple string concatenation |
| **User-defined additions** | Power users adding custom terms | Minimal if under 224 tokens total |

**Performance impact of long prompts**: Negligible. Whisper only considers final 224 tokens—prompt tokenization adds approximately 1-2ms. API latency is dominated by audio processing, not prompt handling.

### Groq API adaptation

For Groq's faster, cheaper API, change only the endpoint and model:

```swift
private let endpoint = "https://api.groq.com/openai/v1/audio/transcriptions"

// In transcribe method:
body.append(multipartField(name: "model", value: "whisper-large-v3", boundary: boundary))
```

---

## Final recommendations for WhisperM8

**Optimal configuration for Denglisch transcription**:

1. **Primary model**: Groq `whisper-large-v3` (best accuracy/cost/speed balance for multilingual)
2. **Language setting**: Always `language="de"` for Denglisch content
3. **Prompt strategy**: Example sentences in Denglisch style + glossary at end
4. **Prompt length**: 100-200 tokens for reliable style transfer
5. **Critical applications**: Implement GPT-4 post-processing for guaranteed vocabulary accuracy
6. **Fallback consideration**: If vocabulary requirements exceed Whisper's capabilities, evaluate AssemblyAI's Word Boost feature

**Key limitations to accept**: Code-switching is an unsupported edge case. Even with optimal prompts, expect some inconsistency. The combination of German language setting + contextual prompts + larger models provides the best practical results, but not perfect reliability.

