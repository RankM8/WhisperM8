# Recherche-Ergebnis: Whisper Prompts & Custom Vocabulary

**Quelle:** OpenAI (ChatGPT)
**Datum:** 2026-02-05
**Modell:** GPT-4o

---

## 1. Prompt-Parameter bei Whisper APIs

Alle drei genannten Transkriptions-APIs unterstützen einen Prompt-Parameter, aber mit leicht unterschiedlichen Eigenschaften:

### a) Gibt es einen prompt-Parameter?
**Ja.** Sowohl die OpenAI Audio Transcription API (für whisper-1 und gpt-4o-transcribe) als auch die Groq Whisper API bieten ein optionales `prompt` Feld. Man kann also bei jeder Anfrage einen Text-Prompt mitsenden, der als Kontext dient.

### b) Wie funktioniert dieser Prompt genau?
Der Prompt wird von den Modellen als **vorhergehender Kontext** behandelt, nicht als direkte Anweisung. Das heißt, er hilft dem Modell zu erkennen, in welchem Stil oder Thema transkribiert werden soll, oder setzt einen Text fort. Ursprünglich ist das gedacht, um mehrere Audiostücke zusammenhängend zu transkribieren – man gibt das vorherige Transkript als Prompt, damit das nächste Segment konsistent weitergeschrieben wird. Allerdings kann man auch fiktive Prompts nutzen, um das Modell zu bestimmten Schreibweisen oder einem bestimmten Stil zu lenken.

**Wichtiger Unterschied zu ChatGPT:** Whisper ignoriert explizite Befehle im Prompt; es imitiert eher den **Stil** des Prompts, statt Befehle darin auszuführen.

### c) Welche Auswirkungen hat der Prompt auf die Transkription?
Vor allem beeinflusst er **Stil und bestimmte Wortschreibungen**. Das Modell versucht, Formatierung, Groß/Kleinschreibung und Interpunktion des Prompts fortzuführen. Man kann damit z.B. erreichen, dass durchgängig kleingeschrieben wird oder dass Umgangssprache beibehalten wird.

Außerdem kann ein Prompt helfen, schwer erkennbare Wörter korrekt zu transkribieren – etwa Eigennamen, Fachbegriffe oder Akronyme. OpenAI zeigt z.B., dass ein Prompt mit dem Satz "... OpenAI which makes technology like DALL·E, GPT-3, and ChatGPT..." dazu führt, dass diese Begriffe korrekt erkannt werden, anstatt fälschlich als "DALI" oder "GDP 3" transkribiert zu werden.

**Wichtig:** Der Prompt beeinflusst nur die Transkription; er erzwingt keine garantierte Ausgabe, sondern bietet dem Modell Hinweise (eine Art Bias).

### d) Gibt es Längenbeschränkungen?
**Ja.**

| Modell | Prompt-Limit |
|--------|--------------|
| Whisper-1 | 224 Token (~150-200 Wörter) |
| Groq Whisper | 224 Token |
| GPT-4o-transcribe | ~16.000 Token (Gesamtkontext) |

Ist der Prompt länger, berücksichtigt Whisper nur die **letzten 224 Token** und ignoriert den Rest stillschweigend. In der Praxis sollte man Prompts kurz halten – idealerweise ein bis drei Sätze oder eine kleine Liste.

### e) Wie zuverlässig beeinflusst der Prompt die Ausgabe?
**Nur mäßig zuverlässig.** Der Prompt kann die Transkription verbessern, ist aber kein Allheilmittel. OpenAI selbst schreibt, diese Techniken seien **„nicht besonders zuverlässig"** und bieten nur begrenzte Kontrolle.

**Wichtiger Hinweis:** Die Position eines Wortes im Prompt kann eine Rolle spielen. Ein Nutzerbericht zeigte, dass Whisper einen im Prompt enthaltenen Nachnamen nur dann korrekt übernahm, wenn dieser **am Ende des Prompts** stand. Das deutet darauf hin, dass Whisper den Prompt eher als fortzusetzenden Text auffasst; die letzten Wörter darin prägen den Stil der folgenden Transkription am stärksten.

---

## 2. Custom Vocabulary / Wortlisten

### a) Unterstützt die API Custom Vocabulary nativ?
**Nein**, keine der genannten APIs hat eine native Custom-Vocabulary-Funktion. Weder OpenAIs Whisper/gpt-4o-Modelle noch Groq Whisper erlauben es, separat eine Wortliste zu hinterlegen.

### b) Kann der Prompt genutzt werden, um eine Wortliste mitzugeben?
**Ja**, im Prinzip ist das der einzige Weg. Man kann relevante Wörter im Prompt unterbringen:

**Beispiel:**
```
"In diesem Gespräch geht es um Cloud-Themen (Kubernetes, Container, Deployments)."
```

### c) Formatierung einer Wortliste im Prompt

**Kommagetrennte Liste:**
```
"Begriffe: API, Repository, Commit, Pull Request, Merge, Deploy, Container, Kubernetes, TypeScript, React, Swift, Xcode, GitHub, CI/CD, Endpoint, Webhook, Middleware."
```

**Stichwort-Satz:**
```
"In der Aufnahme kommen viele Fachwörter aus IT und Marketing vor, z.B. React, TypeScript, SEO, Backlink und Conversion Rate."
```

**Entscheidend:** Relevanz und Sprache. Geben Sie nur Wörter, die tatsächlich im Gespräch erwartet werden, und formulieren Sie den Prompt (bis auf die speziellen Begriffe selbst) in der Sprache des Audios.

### d) Limits (Anzahl Wörter)
Es gibt kein hartes Limit in Anzahl der Wörter, sondern nur in Prompt-Länge. Praktisch kann man vielleicht ein paar Dutzend Wörter problemlos übergeben, aber man sollte unter ~224 Token bleiben (~150 Wörter).

**Empfehlung:** Limitieren Sie die Wortliste auf die wichtigsten **~10–20 Begriffe** für die aktuelle Sitzung.

### e) Zuverlässigkeit der Erkennung
Die Trefferquote für definierte Wörter **steigt, aber es gibt keine Garantie**. Besonders Eigennamen mit ungewöhnlicher Schreibweise profitieren stark davon – Whisper kann z.B. "Whatagraph" korrekt schreiben, wenn dieser Begriff im Prompt stand.

---

## 3. Denglisch-spezifische Herausforderungen

### a) Erkennung bei Code-Switching
Whisper ist zwar multilingual trainiert, aber es wurde primär für **monolinguale Segmente** konzipiert. In Nutzerberichten zeigt sich, dass Whisper ohne Sprachangabe oft versucht, alles in eine Sprache zu übersetzen (oft Englisch).

**GPT-4o-Transcribe** hingegen scheint laut Berichten robuster mit gemischten Eingaben umgehen zu können.

### b) Optimale Sprach-Einstellung für Denglisch
**Empfehlung: `language="de"`**

Wenn Sie Deutsch einstellen, transkribiert Whisper deutschsprachige Passagen korrekt und belässt englische Begriffe in der Regel im Original. Ein Beispiel aus einer Whisper-Diskussion: Ein Audio mit Deutsch, Englisch und Spanisch wurde bei `language="de"` tatsächlich dreisprachig transkribiert.

Mit `language="de"` schalten Sie auch Whisper's Übersetzungsneigung aus – es übersetzt dann nicht, sondern transkribiert wortgetreu.

### c) Deutsch einstellen und englische Begriffe im Prompt definieren?
**Ja, das ist genau der empfohlene Ansatz.**

```python
prompt = "Das Meeting handelt vom neuen React-Projekt. Es geht um Components, State Management und Deployment."
```

Diese Methode – Hauptsprache Deutsch, Fachbegriffe im Prompt – bietet die beste Balance, um beide Sprachen sauber abzubilden.

### d) Oder besser language="en" mit deutschen Begriffen?
**Nein**, das wäre in der Regel kontraproduktiv. Wenn Sie die Sprache auf Englisch festlegen, versucht das Modell alles Englische beizubehalten und deutsch Gesprochenes ins Englische zu übersetzen.

### e) Multilingual-Option?
Es gibt **keine spezielle Einstellung wie "multilingual"**, die mehrere Sprachen gleichzeitig gleichberechtigt behandelt. Auto-Detection kann theoretisch mehrsprachigen Input erkennen, aber praktisch wählt Whisper dann oft eine Sprache für die Ausgabe.

---

## 4. Best Practices für Prompts

### a) Beispiele für effektive Prompts bei gemischtsprachiger Eingabe

**Kontextueller Ansatz:**
```
"Das folgende Gespräch ist ein Team-Meeting eines Software-Projekts. Es werden sowohl deutschsprachige Sätze als auch Begriffe wie API, Code Review und Deployment verwendet."
```

**Fiktiver Dialog im Prompt:**
```
"Alice: Ich habe den Container bereits gepusht. Bob: Super, dann starte ich das Deployment."
```

### b) Sollte der Prompt selbst Deutsch oder Englisch sein?
**Überwiegend Deutsch.** Der Prompt sollte in der Hauptsprache des Audios gehalten sein.

```
"Meeting-Notiz: Das Team diskutiert die aktuelle Sprint-Planung. Es fallen Begriffe wie Code Freeze, Pull Requests und UI/UX-Updates."
```

### c) Struktur einer Wortliste im Prompt
- Halten Sie den Prompt **kurz und bündig**
- Verwenden Sie Trennzeichen (Kommata, Punkt)
- Kontextualisieren Sie die Liste: "Begriffe:" oder "Technologien:"
- **Keine Übersetzungen** angeben (nicht "API = Programmierschnittstelle")

**Strukturiertes Beispiel:**
```
"Fachbegriffe im Gespräch: Kubernetes, Docker-Container, Load Balancer, Microservices, Staging-Environment."
```

### d) Empfohlene Prompt-Templates

**Template:**
```
"[Kontextsatz über das Gespräch]. Erwähnte Begriffe: [Wort1], [Wort2], [Wort3]…"
```

**Beispiel für Marketing:**
```
"Das Gespräch handelt von Online-Marketing-Kampagnen auf Englisch und Deutsch. Wichtige Begriffe: Funnel, Conversion Rate, CTR, CPC, Landing Page."
```

### e) Funktioniert ein "Beispieltext" als Prompt?
**Ja.** Ihr Beispiel "Der Developer hat den Commit gepusht und das Deployment getriggert." ist genau richtig. Es demonstriert, wie in einem deutschen Satz englische Wörter benutzt werden.

**Wichtig:** Der Prompt sollte keine falschen Informationen enthalten – das könnte das Modell zur Halluzination verleiten.

---

## 5. Unterschiede zwischen den Modellen

| Feature | OpenAI whisper-1 | OpenAI gpt-4o-transcribe | Groq Whisper (Large v3) |
|---------|------------------|--------------------------|-------------------------|
| **Prompt-Parameter** | Ja, max. 224 Token | Ja, bis ~16k Token | Ja, max. 224 Token |
| **Custom Vocabulary** | Nein, nur via Prompt | Nein, nur via Prompt | Nein, nur via Prompt |
| **Multilingual** | ~100 Sprachen | 100+ Sprachen | 99+ Sprachen |
| **Denglisch-Qualität** | Gut, mit Einschränkungen | **Sehr gut** | Gut |
| **Code-Switching** | Offiziell nicht unterstützt | Robuster | Wie Whisper |
| **Timestamps** | Ja (verbose_json) | Nicht nativ | Ja (verbose_json) |

**Anmerkung:** GPT-4o-transcribe zeigt insgesamt niedrigere Fehlerquoten in Deutsch und Englisch als Whisper. Fachbegriffe und Akronyme werden tendenziell treffender erkannt.

---

## 6. Alternativen und Workarounds

### a) Post-Processing (Suchen/Ersetzen häufiger Fehler)
Ein pragmatischer Ansatz: Das rohe Transkript durchsuchen und bekannte Fehler korrigieren.

**Beispiel:** "Full Request" → "Pull Request"

```swift
let correctedText = transcript
    .replacingOccurrences(of: "Full Request", with: "Pull Request")
    .replacingOccurrences(of: "Cubernetties", with: "Kubernetes")
```

### b) Fine-Tuning von Whisper
OpenAI bietet für die API-Version kein Fine-Tuning an. Wenn gewünscht, müsste man das lokal mit dem open-source Whisper tun (erfordert ML-Erfahrung und GPU-Ressourcen).

### c) Andere APIs mit besserer Custom-Vocabulary-Unterstützung

| API | Custom Vocabulary | Beschreibung |
|-----|-------------------|--------------|
| **Google Cloud STT** | ✅ Phrase Hints | Wörter/Phrasen, die bevorzugt erkannt werden |
| **Microsoft Azure** | ✅ Custom Phrase List | Ähnliches Konzept |
| **Amazon Transcribe** | ✅ Custom Vocabulary | CSV von speziellen Wörtern hochladen |
| **AssemblyAI** | ✅ Word Boost | Liste mit Gewichtung (low/medium/high) |

### d) Hybrid-Ansatz (Whisper + LLM-Korrektur)
**Sehr vielversprechend und von OpenAI empfohlen:**

```python
# Schritt 1: Whisper Transkription
transcript = client.audio.transcriptions.create(
    file=audio_file,
    model="whisper-1",
    language="de",
    prompt="Kubernetes, TypeScript, CI/CD..."
)

# Schritt 2: GPT-4 Korrektur
system_prompt = """Du bist ein KI-Assistent, der Transkripte Korrektur liest.
Stelle sicher, dass folgende Begriffe korrekt geschrieben sind:
Kubernetes, TypeScript, CI/CD, Pull Request, Deployment..."""

corrected = client.chat.completions.create(
    model="gpt-4",
    temperature=0,
    messages=[
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": transcript.text}
    ]
)
```

**Vorteil:** GPT-4's Kontextfenster handhabt tausende von Begriffen (vs. 224 Token bei Whisper).

---

## 7. Praktische Implementierung

### a) Senden des Prompts (API-Parameter)
Der Prompt wird als zusätzliches Feld im Multipart-Form Data mitgeschickt:

```bash
curl --request POST \
  --url https://api.openai.com/v1/audio/transcriptions \
  --header "Authorization: Bearer $OPENAI_API_KEY" \
  --header "Content-Type: multipart/form-data" \
  --form file=@"/Pfad/zu/audio.m4a" \
  --form model="whisper-1" \
  --form prompt="Das folgende Gespräch ist ein Kick-off-Meeting für ein neues Projekt mit Fokus auf SEO, Keywords und Google Ads." \
  --form language="de"
```

### b) Prompt pro Anfrage angepasst oder statisch?
**Nach Möglichkeit pro Anfrage anpassen.** Ein statischer Prompt funktioniert, schöpft aber nicht das Potential aus.

**Optionen:**
- Nutzer wählt Themengebiet ("Softwareentwicklung", "Marketing")
- Automatische Erkennung basierend auf ersten Sekunden
- Statischer Basis-Prompt + dynamische Begriffe

### c) Performance-Impact durch lange Prompts
**Praktisch keiner.** Ein kurzer Prompt (~1-2 Sätze) hat keinen spürbaren Einfluss auf die Verarbeitungszeit. Die meiste Rechenzeit verbringt das Modell mit dem Audio-Processing.

---

## Quellen

- [Audio | OpenAI API Reference](https://platform.openai.com/docs/api-reference/audio)
- [Speech to Text - Groq Docs](https://console.groq.com/docs/speech-to-text)
- [Whisper prompting guide | OpenAI Cookbook](https://cookbook.openai.com/examples/whisper_prompting_guide)
- [Speech to text | OpenAI API](https://platform.openai.com/docs/guides/speech-to-text)
- [GPT-4o Transcribe Model | OpenAI API](https://platform.openai.com/docs/models/gpt-4o-transcribe)
- [Multi-Language Audio Discussion | GitHub](https://github.com/openai/whisper/discussions/2009)
- [GPT-4o-transcribe vs Whisper | Reddit](https://www.reddit.com/r/OpenAI/comments/1jvdqty/gpt4otranscribe_outperforms_whisperlarge/)
- [AssemblyAI Custom Speech Recognition](https://www.assemblyai.com/blog/do-i-need-a-custom-speech-recognition-model)
