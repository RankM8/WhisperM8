# Recherche-Prompt: Whisper Prompts & Custom Vocabulary

## Kontext

Wir entwickeln eine macOS Speech-to-Text App (WhisperM8), die verschiedene Transkriptions-APIs unterstützt:
- **OpenAI Whisper API** (whisper-1)
- **OpenAI gpt-4o-transcribe** (neueres Modell)
- **Groq Whisper** (whisper-large-v3, whisper-large-v3-turbo, distil-whisper-large-v3-en)

Unsere Hauptzielgruppe arbeitet in einem **Denglisch-Umfeld** (Deutsch-Englisch gemischt):
- Softwareentwicklung/Programmierung
- SEO (Suchmaschinenoptimierung)
- Online-Marketing & Paid Ads
- Agenturarbeit

## Forschungsfragen

### 1. Prompt-Parameter bei Whisper APIs

**Für jede API (OpenAI Whisper, gpt-4o-transcribe, Groq Whisper) bitte recherchieren:**

a) Gibt es einen `prompt`-Parameter in der API?
b) Wie genau funktioniert dieser Prompt?
c) Welche Auswirkungen hat der Prompt auf die Transkription?
d) Gibt es Längenbeschränkungen für den Prompt?
e) Wie zuverlässig beeinflusst der Prompt die Ausgabe?

### 2. Custom Vocabulary / Wortlisten

**Können wir eigene Wortlisten definieren, die korrekt transkribiert werden?**

a) Unterstützt die jeweilige API Custom Vocabulary nativ?
b) Kann der Prompt genutzt werden, um eine Wortliste mitzugeben?
c) Wie formatiert man eine solche Wortliste im Prompt optimal?
d) Gibt es Limits (Anzahl Wörter, Zeichenlänge)?
e) Wie zuverlässig werden die definierten Wörter dann erkannt?

### 3. Denglisch-spezifische Herausforderungen

**Unser Use-Case: Deutsch mit vielen englischen Fachbegriffen**

Beispiel-Wörter die korrekt erkannt werden müssen:
- **Programmierung**: API, Repository, Commit, Pull Request, Merge, Deploy, Container, Kubernetes, TypeScript, React, Swift, Xcode, GitHub, CI/CD, Endpoint, Webhook, Middleware
- **SEO**: Keyword, Ranking, Backlink, SERP, Crawling, Indexierung, Meta-Tags, Canonical, Sitemap, Schema Markup, Core Web Vitals, PageSpeed
- **Marketing**: Funnel, Lead, Conversion, CTR, CPC, CPM, ROAS, A/B-Test, Landing Page, CTA, Retargeting, Lookalike Audience
- **Agentur**: Briefing, Pitch, Kick-off, Deadline, Milestone, Sprint, Stakeholder, Deliverable

a) Wie gut funktioniert die Spracherkennung bei Code-Switching (Wechsel zwischen Deutsch und Englisch)?
b) Welche Sprach-Einstellung (`language`-Parameter) ist optimal für Denglisch?
c) Hilft es, die Sprache auf "de" zu setzen und englische Begriffe im Prompt zu definieren?
d) Oder ist "en" mit deutschen Begriffen besser?
e) Gibt es eine Multilingual-Option?

### 4. Best Practices für Prompts

**Wie sollte ein optimaler Prompt für unseren Use-Case aussehen?**

a) Beispiele für effektive Prompts bei gemischtsprachiger Eingabe
b) Sollte der Prompt selbst Deutsch oder Englisch sein?
c) Wie strukturiert man eine Wortliste im Prompt (Komma-separiert, Zeilenumbrüche, etc.)?
d) Gibt es empfohlene Prompt-Templates von OpenAI/Groq?
e) Funktioniert ein "Beispieltext" im Prompt-Stil? (z.B. "Der Developer hat den Commit gepusht und das Deployment getriggert.")

### 5. Unterschiede zwischen den Modellen

**Direkter Vergleich:**

| Feature | OpenAI whisper-1 | gpt-4o-transcribe | Groq Whisper |
|---------|------------------|-------------------|--------------|
| Prompt-Parameter | ? | ? | ? |
| Custom Vocabulary | ? | ? | ? |
| Multilingual | ? | ? | ? |
| Denglisch-Qualität | ? | ? | ? |

### 6. Alternativen und Workarounds

Falls keine native Custom-Vocabulary-Funktion existiert:

a) Gibt es Post-Processing-Ansätze (z.B. Suchen/Ersetzen von häufigen Fehlern)?
b) Kann man Fine-Tuning für Whisper machen?
c) Gibt es andere APIs mit besserer Custom-Vocabulary-Unterstützung?
d) Lohnt sich ggf. ein Hybrid-Ansatz (Whisper + LLM-Korrektur)?

### 7. Praktische Implementierung

**Für unsere Swift/macOS-App:**

a) Wie senden wir den Prompt technisch mit (welcher API-Parameter)?
b) Code-Beispiele für multipart/form-data mit Prompt
c) Sollte der Prompt pro Anfrage angepasst werden oder ist ein statischer Prompt ausreichend?
d) Performance-Impact durch lange Prompts?

## Gewünschtes Ergebnis-Format

Bitte strukturiere deine Antwort nach den obigen Abschnitten (1-7) und gib:
- Klare Ja/Nein-Antworten wo möglich
- Code-Beispiele für API-Aufrufe mit Prompt
- Konkrete Prompt-Beispiele für unseren Denglisch-Use-Case
- Empfehlungen welches Modell/welche API für unseren Use-Case am besten geeignet ist
- Quellen/Links zur offiziellen Dokumentation

## Zusätzliche Informationen

- Wir nutzen bereits die OpenAI und Groq APIs in unserer App
- Die App läuft auf macOS 14+ (Sonoma)
- Audio-Format: M4A (16kHz mono AAC)
- Durchschnittliche Aufnahmelänge: 5-60 Sekunden
