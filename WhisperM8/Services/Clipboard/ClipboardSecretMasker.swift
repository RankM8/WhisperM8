import Foundation

// MARK: - Geheimnisse in Ausgaben für Agents maskieren

/// Ersetzt typische Geheimnisse (API-Keys, Tokens, private Schlüssel) durch
/// Platzhalter, bevor ein Agent den Text sieht. Reine Logik, kein I/O.
/// Bewusst grob: lieber ein Treffer zu viel als ein Schlüssel im Chat-Verlauf.
enum ClipboardSecretMasker {
    struct Result: Equatable {
        var text: String
        var maskedCount: Int
    }

    private struct Rule {
        let label: String
        let regex: NSRegularExpression
        /// Wenn gesetzt, wird nur diese Capture-Gruppe ersetzt.
        let group: Int?
        let validate: ((String) -> Bool)?
    }

    private static func rule(_ label: String, _ pattern: String, options: NSRegularExpression.Options = [],
                             group: Int? = nil, validate: ((String) -> Bool)? = nil) -> Rule {
        // Muster sind Konstanten; ein Tippfehler fiele sofort im Test auf.
        Rule(label: label, regex: try! NSRegularExpression(pattern: pattern, options: options),
             group: group, validate: validate)
    }

    /// Reihenfolge zählt: spezifische Formate zuerst, damit der Platzhalter
    /// sagt, was es war; die groben Regeln am Ende fangen den Rest.
    private static let rules: [Rule] = [
        rule("private-key", #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\z)"#),
        rule("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#),
        rule("github-token", #"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})"#),
        rule("slack-token", #"\bxox[abeoprs]-[A-Za-z0-9-]{10,}|\bxapp-[0-9]-[A-Za-z0-9-]{10,}"#),
        rule("aws-key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        rule("google-key", #"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])"#),
        // Stripe: geheime und eingeschränkte Schlüssel, nicht die öffentlichen pk_.
        rule("stripe-key", #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#),
        // OpenAI (sk-…, sk-proj-…), Anthropic (sk-ant-…) und ähnliche.
        rule("api-key", #"\bsk-[A-Za-z0-9_-]{20,}"#),
        // Groq (gsk_…). Die grobe Regel am Ende fängt ihn meist auch, aber nur, wenn
        // Groß-, Kleinbuchstabe und Ziffer zufällig alle vorkommen.
        rule("api-key", #"\bgsk_[A-Za-z0-9]{40,}"#),
        // Linear: persönliche Schlüssel, OAuth-Tokens und Webhook-Geheimnisse.
        rule("linear-key", #"\blin_(?:api|oauth|wh)_[A-Za-z0-9]{32,}"#),
        // GitLab: persönliche, Deploy-, Runner-, Trigger- und Feed-Tokens. Neuere Tokens
        // tragen dahinter noch eine Prüfsumme (`.01.` plus sieben bis zwölf Zeichen); die
        // gehört mit dazu, eine Dateiendung wie `.json` nicht.
        rule("gitlab-token", #"\bgl(?:pat|dt|rt|ptt|ft|cbt|soat|imt|agent)-[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9]{2}\.[A-Za-z0-9]{7,12}(?![A-Za-z0-9]))?"#),
        rule("npm-token", #"\bnpm_[A-Za-z0-9]{36}(?![A-Za-z0-9])"#),
        rule("pypi-token", #"\bpypi-AgE[A-Za-z0-9_-]{50,}"#),
        rule("huggingface-token", #"\bhf_[A-Za-z0-9]{30,}(?![A-Za-z0-9])"#, validate: hasUpperAndLower),
        // Reine Hex-Schlüssel mit festem Präfix: die grobe Regel lässt Hex absichtlich stehen.
        rule("digitalocean-token", #"\bdo[opr]_v1_[a-f0-9]{64}(?![A-Za-z0-9])"#),
        rule("shopify-token", #"\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}(?![A-Za-z0-9])"#),
        rule("supabase-key", #"\bsbp_[a-f0-9]{40}(?![A-Za-z0-9])"#),
        // Neue Supabase-Schlüssel: Der Rest muss zufällig aussehen, sonst wäre
        // `sb_secret_key_for_the_project` ein Treffer.
        rule("supabase-key", #"\bsb_secret_[A-Za-z0-9_-]{20,}"#, validate: { looksLikeRandomToken(String($0.dropFirst(10))) }),
        // Nur freistehend: `cache-key-<md5>` ist eine Prüfsumme, kein Schlüssel.
        rule("mailgun-key", #"(?<![A-Za-z0-9_-])key-[a-f0-9]{32}(?![A-Za-z0-9])"#),
        rule("postman-key", #"\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}(?![A-Za-z0-9])"#),
        // Schlüssel mit Punkten: die grobe Regel setzt nach einem Punkt nicht an.
        rule("sendgrid-key", #"\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"#),
        // Nach dem optionalen Umgebungs-Teil (`dp.st.prd.`) mindestens 40 Zeichen ohne Punkt;
        // `dp.st.session_state.attribut…` ist Code.
        rule("doppler-token", #"\bdp\.(?:st|ct|sa|scim|audit|pt)\.(?:[a-z0-9_-]{1,32}\.)?[A-Za-z0-9]{40,}"#),
        rule("airtable-token", #"\bpat[A-Za-z0-9]{14}\.[a-f0-9]{64}(?![A-Za-z0-9])"#),
        // Google OAuth: Client-Secret, Access- und Refresh-Token.
        rule("google-oauth", #"\bGOCSPX-[A-Za-z0-9_-]{28}(?![A-Za-z0-9_-])|\bya29\.[A-Za-z0-9_-]{30,}|\b1//0[A-Za-z0-9_-]{30,}"#),
        rule("telegram-token", #"\b[0-9]{8,10}:AA[A-Za-z0-9_-]{33}(?![A-Za-z0-9_-])"#),
        rule("tailscale-key", #"\btskey-[a-z]+-[A-Za-z0-9]{6,}-[A-Za-z0-9]{20,}"#),
        rule("age-key", #"\bAGE-SECRET-KEY-1[0-9A-Z]{58}(?![0-9A-Z])"#),
        // Webhook-Adressen: wer sie kennt, kann in den Kanal schreiben. Maskiert wird
        // nur der geheime Teil, der Dienst bleibt lesbar.
        rule("webhook-url", #"\bhttps://hooks\.slack\.com/(?:services|workflows|triggers)/([A-Za-z0-9/_-]{20,})"#, group: 1),
        rule("webhook-url", #"\bhttps://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/([0-9]+/[A-Za-z0-9_-]{20,})"#, group: 1),
        rule("bearer", #"\b[Bb]earer\s+([A-Za-z0-9._~+/=-]{16,})"#, group: 1),
        rule("basic-auth", #"\b[Bb]asic\s+([A-Za-z0-9+/]{12,}={0,2})(?![A-Za-z0-9+/=])"#, group: 1, validate: looksLikeBase64),
        // Passwort in einer URL: scheme://user:passwort@host
        rule("url-password", #"\b[a-z][a-z0-9+.-]*://[^\s/:@]+:([^\s/@]+)@"#, group: 1),
        // .env-Zeilen: OPENAI_API_KEY=…, DB_PASSWORD="…", export GITHUB_TOKEN=…
        rule("env-secret", #"(?m)^[ \t]*(?:export[ \t]+)?[A-Za-z0-9_]*(?i:PASSWORD|PASSWD|PASSPHRASE|SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Za-z0-9_]*[ \t]*=[ \t]*["']?([^\s"'#]{4,})"#, group: 1, validate: isSecretValue),
        // password=…, token: …, api_key = …, "client_secret": "…" (Wert ab sechs Zeichen).
        // Angesetzt wird nur am Anfang einer Bezeichner-Kette, mit höchstens 64 Zeichen
        // vor dem Schlüsselwort. Vorher setzte die Regel nach jedem `_` oder `-` neu an
        // und lief bis zum Ende der Kette: quadratisch, Sekunden bis Minuten bei langen
        // Ketten. Längere Präfixe in `.env`-Zeilen fängt `env-secret`.
        rule("secret", #"(?i)(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{0,64}(?:password|passwd|passphrase|passwort|kennwort|secret|token|api[_-]?key|access[_-]?key)["']?\s*[:=]\s*["']?([^\s"',;]{6,})"#, group: 1, validate: isSecretValue),
        // Gesprochen oder geschrieben: „das Passwort ist Sommer2024“, „Kennwort lautet …“,
        // „meine PIN ist 4711“, „the password is …“. Auch reine Zahlen (PIN) zählen.
        rule("spoken-secret", #"(?i)\b(?:passwort|kennwort|password|passcode|passphrase|pin|pin-code|pincode|geheimzahl|zugangscode)\b[ \t]*(?:ist|lautet|wäre|heißt|is)[ \t]+(?:(?:der|die|das|einfach|nur|just)[ \t]+)?["„'‚]?([^\s"“'‘,;]{3,})"#, group: 1, validate: { value in
            !isPlaceholderValue(value.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")))
        }),
        // Lange Base64-/URL-safe-Ketten mit Ziffer, Groß- und Kleinbuchstabe.
        // Reine Hex-Ketten (Git-Hashes, SHA-256, MD5) bleiben bewusst stehen:
        // ohne Zusammenhang sind sie fast immer Prüfsummen, keine Geheimnisse.
        rule("token", #"(?<![A-Za-z0-9+_=/.-])[A-Za-z0-9+_=-]{40,}(?![A-Za-z0-9+_=/.-])"#, validate: looksLikeRandomToken),
    ]

    /// Ein Wert in `KEY=…` ist ein Geheimnis, wenn er kein Platzhalter und keine reine Zahl ist
    /// (`MAX_TOKENS=4096` bleibt stehen).
    static func isSecretValue(_ value: String) -> Bool {
        !isPlaceholderValue(value) && !value.allSatisfy(\.isNumber)
    }

    /// Base64 nach `Basic`: Großbuchstaben mitten im Wort, eine Ziffer oder `=`.
    /// „Basic Configuration“ ist Text, „dXNlcjpwYXNz“ nicht.
    static func looksLikeBase64(_ value: String) -> Bool {
        if value.contains(where: { $0.isNumber || $0 == "=" || $0 == "+" || $0 == "/" }) { return true }
        return value.dropFirst().contains(where: \.isUppercase)
    }

    /// Werte wie `null`, `<your-key>`, `${API_KEY}` oder `xxxxxx` sind keine Geheimnisse.
    static func isPlaceholderValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        if ["null", "nil", "none", "undefined", "true", "false", "changeme", "redacted"].contains(lower) { return true }
        if value.hasPrefix("<") || value.hasPrefix("${") || value.hasPrefix("$(") || value.hasPrefix("{{") { return true }
        if Set(lower).count <= 2 { return true }
        return false
    }

    /// Hugging-Face-Tokens mischen Groß- und Kleinbuchstaben; Bezeichner wie
    /// `hf_downloadmodelfromhubwithretries…` nicht.
    static func hasUpperAndLower(_ value: String) -> Bool {
        value.contains(where: \.isUppercase) && value.contains(where: \.isLowercase)
    }

    static func looksLikeRandomToken(_ value: String) -> Bool {
        var upper = false, lower = false, digit = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: upper = true
            case 0x61...0x7A: lower = true
            case 0x30...0x39: digit = true
            default: break
            }
        }
        return upper && lower && digit
    }

    static func placeholder(for label: String) -> String { "[REDACTED:\(label)]" }

    static func mask(_ input: String) -> Result {
        var text = input
        var count = 0
        for rule in rules {
            let ns = text as NSString
            let matches = rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = ""
            var cursor = 0
            for match in matches {
                let target = rule.group.map { match.range(at: $0) } ?? match.range
                guard target.location != NSNotFound, target.location >= cursor else { continue }
                let value = ns.substring(with: target)
                if value.hasPrefix("[REDACTED:") { continue }
                if let validate = rule.validate, !validate(value) { continue }
                result += ns.substring(with: NSRange(location: cursor, length: target.location - cursor))
                result += placeholder(for: rule.label)
                cursor = target.location + target.length
                count += 1
            }
            result += ns.substring(from: cursor)
            text = result
        }
        return Result(text: text, maskedCount: count)
    }
}
