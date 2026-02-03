# Recherche-Prompt: OpenRouter Speech-to-Text

## Kontext

WhisperM8 soll neben OpenAI auch OpenRouter unterstützen, um alternative Speech-to-Text Modelle nutzen zu können. Wir müssen herausfinden, ob und wie OpenRouter STT unterstützt.

## Was wir wissen müssen

### 1. Unterstützt OpenRouter Speech-to-Text?

- Hat OpenRouter einen Audio/Transcription-Endpunkt?
- Oder nur Text-basierte LLMs?
- Falls nein: Welche Alternativen gibt es?

### 2. Falls ja: API-Details

- Welcher Endpunkt?
- Welche Modelle sind verfügbar?
- Request/Response Format
- Preise

### 3. Alternative Ansätze

Falls OpenRouter kein STT unterstützt:
- Könnte man lokale Whisper-Modelle nutzen? (whisper.cpp)
- Andere STT-APIs (AssemblyAI, Deepgram, Google Cloud Speech)?
- Groq API für Whisper?

### 4. Groq als Alternative

- Groq bietet Whisper large-v3 an
- API-kompatibel mit OpenAI?
- Geschwindigkeit und Preise?

## Recherche-Quellen

- OpenRouter Documentation (https://openrouter.ai/docs)
- OpenRouter Model List
- Groq Documentation
- Vergleich verschiedener STT-Anbieter

## Erwartetes Ergebnis

1. Klärung ob OpenRouter STT unterstützt
2. Falls ja: Integrations-Details
3. Falls nein: Empfehlung für Alternative (z.B. Groq)
4. Übersicht der STT-Optionen mit Preisen
