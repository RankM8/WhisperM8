import Foundation

struct PostProcessingTemplate: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var description: String
    var instruction: String
    var createdAt: Date
    var updatedAt: Date
    var isBuiltIn: Bool

    func render(rawTranscript: String, language: String, date: Date = Date()) -> String {
        let renderedDate = Self.dateFormatter.string(from: date)
        return instruction
            .replacingOccurrences(of: "{rawTranscript}", with: rawTranscript)
            .replacingOccurrences(of: "{language}", with: language.isEmpty ? "auto" : language)
            .replacingOccurrences(of: "{date}", with: renderedDate)
    }

    func duplicated(now: Date = Date()) -> PostProcessingTemplate {
        PostProcessingTemplate(
            id: UUID().uuidString,
            name: "\(name) Copy",
            description: description,
            instruction: instruction,
            createdAt: now,
            updatedAt: now,
            isBuiltIn: false
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension PostProcessingTemplate {
    static let cleanID = "template.clean"
    static let techCleanID = "template.tech-clean"
    static let emailID = "template.email"
    static let notesID = "template.notes"

    static let builtInTemplates: [PostProcessingTemplate] = {
        let referenceDate = Date(timeIntervalSince1970: 0)
        return [
            PostProcessingTemplate(
                id: cleanID,
                name: "Clean transcript",
                description: "Glättet Grammatik, Satzzeichen und Absätze, ohne Bedeutung zu ändern.",
                instruction: """
                Improve this transcript for readability.

                Rules:
                - Output only the final text.
                - Do not explain your changes.
                - Preserve the original meaning strictly.
                - Fix punctuation, casing, obvious speech artifacts, and paragraph breaks.
                - Do not invent facts or add new information.

                Language: {language}

                Transcript:
                {rawTranscript}
                """,
                createdAt: referenceDate,
                updatedAt: referenceDate,
                isBuiltIn: true
            ),
            PostProcessingTemplate(
                id: techCleanID,
                name: "Tech/Denglisch clean transcript",
                description: "Räumt deutsche/englische AI-, Software-, IT- und Design-Diktate auf und korrigiert offensichtliche Fachbegriff-Verhörer.",
                instruction: """
                Clean up this transcript for a technical German/English mixed work context.

                Goal:
                Produce a polished transcript that preserves exactly what the speaker meant, while fixing obvious speech-to-text mistakes, punctuation, casing, paragraph breaks, and malformed technical terms.

                Hard rules:
                - Output only the final cleaned transcript.
                - Do not explain your changes.
                - Preserve the speaker's meaning, tone, intent, order, and level of detail.
                - Do not summarize, shorten, expand, or restructure into notes unless the speaker explicitly asked for that.
                - Do not invent facts, names, dates, decisions, links, files, tools, or requirements.
                - Keep German, English, and Denglisch naturally mixed when the transcript is mixed.
                - Keep casual spoken wording when it carries intent, but remove filler only when it is clearly accidental.
                - If a term is ambiguous, prefer the original wording instead of guessing.

                Technical cleanup focus:
                - Correct obvious AI/software/design/IT terms that speech-to-text often mishears.
                - Prefer established spellings and casing for tools, frameworks, models, and engineering terms.
                - Keep product and model names precise when context makes them clear.
                - Fix split or phonetically transcribed terms such as API, CLI, SDK, OAuth, JSON, SwiftUI, Xcode, GitHub, GitLab, TypeScript, JavaScript, React, Next.js, Tailwind, Supabase, PostgreSQL, backend, frontend, full stack, dashboard, template, prompt, model, reasoning, Keychain, onboarding, Spotlight, Finder, menu bar, auto-paste, clipboard, transcription, post-processing, Codex, ChatGPT, OpenAI, Groq, Whisper, Claude, Claude Code, Cursor, Figma, Linear, Slack.
                - Example: if context clearly points to Anthropic's coding tool, correct "Cloud Code", "Cloth Code", or similar variants to "Claude Code".
                - Example: correct "open AI" to "OpenAI" when referring to the company/API, and "chat GPT" to "ChatGPT".
                - Example: correct "front end" or "back end" to "frontend" or "backend" when used as engineering nouns/adjectives.

                Formatting:
                - Use readable paragraphs.
                - Add punctuation and capitalization.
                - Keep lists as lists only if the speaker dictated a list-like structure.

                Language: {language}

                Transcript:
                {rawTranscript}
                """,
                createdAt: referenceDate,
                updatedAt: referenceDate,
                isBuiltIn: true
            ),
            PostProcessingTemplate(
                id: emailID,
                name: "Professional email",
                description: "Formt das Diktat in eine klare professionelle Nachricht um.",
                instruction: """
                Turn this transcript into a concise professional message or email.

                Rules:
                - Output only the final text.
                - Keep the user's intent and factual content.
                - Be polite and professional without exaggerating.
                - Do not invent missing details.
                - Do not add dates, names, greetings, signatures, subjects, or placeholders unless they are present or explicitly requested in the transcript.
                - If the transcript asks for an email, write the email body directly.

                Language: {language}

                Transcript:
                {rawTranscript}
                """,
                createdAt: referenceDate,
                updatedAt: referenceDate,
                isBuiltIn: true
            ),
            PostProcessingTemplate(
                id: notesID,
                name: "Structured notes",
                description: "Erzeugt strukturierte Notizen, Bulletpoints und To-dos.",
                instruction: """
                Convert this transcript into structured notes.

                Rules:
                - Output only the final notes.
                - Keep all factual content grounded in the transcript.
                - Use short bullet points.
                - Include a To-dos section only when actions are present.
                - Do not invent actions or facts.

                Language: {language}

                Transcript:
                {rawTranscript}
                """,
                createdAt: referenceDate,
                updatedAt: referenceDate,
                isBuiltIn: true
            )
        ]
    }()

    static func builtInTemplate(id: String?) -> PostProcessingTemplate? {
        guard let id else { return nil }
        return builtInTemplates.first { $0.id == id }
    }
}
