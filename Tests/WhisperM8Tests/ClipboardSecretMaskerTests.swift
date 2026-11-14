import XCTest
@testable import WhisperM8

final class ClipboardSecretMaskerTests: XCTestCase {
    private func masked(_ text: String) -> String { ClipboardSecretMasker.mask(text).text }

    func testPlainTextIsUntouched() {
        let text = "Das ist ein ganz normaler Satz mit /Users/demo/repos/whisperm8/WhisperM8/Services und Zahlen 12345."
        let result = ClipboardSecretMasker.mask(text)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.maskedCount, 0)
    }

    func testOpenAIAndAnthropicKeys() {
        XCTAssertEqual(masked("key sk-proj-abcdefghijklmnopqrstuvwxyz0123 ende"), "key [REDACTED:api-key] ende")
        XCTAssertEqual(masked("sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ_abc-123"), "[REDACTED:api-key]")
    }

    func testGitHubTokens() {
        XCTAssertEqual(masked("ghp_" + String(repeating: "a1", count: 18)), "[REDACTED:github-token]")
        XCTAssertEqual(masked("github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz0123456789"), "[REDACTED:github-token]")
    }

    func testSlackAWSAndGoogleKeys() {
        XCTAssertEqual(masked("xoxb-1234567890-abcdefghij"), "[REDACTED:slack-token]")
        XCTAssertEqual(masked("AKIAABCDEFGHIJKLMNOP"), "[REDACTED:aws-key]")
        XCTAssertEqual(masked("AIzaSyA-1234567890abcdefghijklmnopqrstu"), "[REDACTED:google-key]")
    }

    func testJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertEqual(masked("Authorization: \(jwt)"), "Authorization: [REDACTED:jwt]")
    }

    func testPrivateKeyBlockIncludingTruncatedOne() {
        let block = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(masked("vorher\n\(block)\nnachher"), "vorher\n[REDACTED:private-key]\nnachher")
        XCTAssertEqual(masked("-----BEGIN RSA PRIVATE KEY-----\nMIIEow"), "[REDACTED:private-key]")
    }

    func testBearerAndAssignments() {
        XCTAssertEqual(masked("Authorization: Bearer abcdef1234567890XYZ"), "Authorization: Bearer [REDACTED:bearer]")
        // Am Zeilenanfang greift die .env-Regel, mitten im Text die allgemeine.
        XCTAssertEqual(masked("password=hunter22!"), "password=[REDACTED:env-secret]")
        XCTAssertEqual(masked("login mit password=hunter22!"), "login mit password=[REDACTED:secret]")
        XCTAssertEqual(masked("API_KEY: \"abc123xyz\""), "API_KEY: \"[REDACTED:secret]\"")
        XCTAssertEqual(masked("token = a1b2c3"), "token = [REDACTED:env-secret]")
        XCTAssertEqual(masked("mit token: a1b2c3"), "mit token: [REDACTED:secret]")
    }

    func testShortAssignmentValuesStay() {
        XCTAssertEqual(masked("password=abc"), "password=abc")
    }

    func testLongMixedTokens() {
        let token = "Zm9vYmFyQmF6cXV4MTIzNDU2Nzg5MEFiQ2RFZkdoSWpLbE1u"
        XCTAssertEqual(masked("x \(token) y"), "x [REDACTED:token] y")
    }

    func testLongWordWithoutDigitsIsNotAToken() {
        let word = "ThisIsAVeryLongIdentifierNameWithoutAnyDigitsInIt"
        XCTAssertEqual(masked(word), word)
    }

    func testCountsAndMultipleSecrets() {
        let result = ClipboardSecretMasker.mask("a sk-abcdefghijklmnopqrstuvwx b AKIAABCDEFGHIJKLMNOP c")
        XCTAssertEqual(result.maskedCount, 2)
        XCTAssertEqual(result.text, "a [REDACTED:api-key] b [REDACTED:aws-key] c")
    }

    // MARK: Weitere Formate (Falsch-Negative vermeiden)

    func testStripeKeys() {
        XCTAssertEqual(masked("sk_live_51HxABCdefGHIjklMNOpqr"), "[REDACTED:stripe-key]")
        XCTAssertEqual(masked("rk_live_51HxABCdefGHIjklMNOpqr"), "[REDACTED:stripe-key]")
        XCTAssertEqual(masked("sk_test_4eC39HqLyjWDarjtT1zdp7dc"), "[REDACTED:stripe-key]")
        // Öffentliche Schlüssel sind kein Geheimnis.
        XCTAssertEqual(masked("pk_live_51HxABCdefGHI"), "pk_live_51HxABCdefGHI")
    }

    func testSlackAppAndUserTokens() {
        XCTAssertEqual(masked("xoxp-1234567890-1234567890-abcdef"), "[REDACTED:slack-token]")
        XCTAssertEqual(masked("xapp-1-A0123456789-abcdef0123"), "[REDACTED:slack-token]")
    }

    func testEnvFileLines() {
        let env = """
        OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123
        DATABASE_PASSWORD="hunter22"
        export GITHUB_TOKEN=abc123def456
        AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
        MAX_TOKENS=4096
        APP_NAME=WhisperM8
        STRIPE_SECRET=xxxxxx
        """
        let out = masked(env)
        XCTAssertFalse(out.contains("hunter22"))
        XCTAssertFalse(out.contains("abc123def456"))
        XCTAssertFalse(out.contains("wJalrXUtnFEMI"))
        XCTAssertFalse(out.contains("sk-proj-"))
        XCTAssertTrue(out.contains("MAX_TOKENS=4096"), "reine Zahl bleibt")
        XCTAssertTrue(out.contains("APP_NAME=WhisperM8"))
        XCTAssertTrue(out.contains("STRIPE_SECRET=xxxxxx"), "Platzhalter bleibt")
    }

    func testJSONSecretFieldsAndURLPasswords() {
        XCTAssertEqual(masked(#""client_secret": "s3cr3tValue""#), #""client_secret": "[REDACTED:secret]""#)
        XCTAssertEqual(masked("postgres://app:Sup3rGeheim@db.example.com:5432/x"),
                       "postgres://app:[REDACTED:url-password]@db.example.com:5432/x")
        XCTAssertEqual(masked("Authorization: Basic dXNlcjpwYXNz"), "Authorization: Basic [REDACTED:basic-auth]")
    }

    // MARK: Formate mit festem Präfix (WM8-68)

    /// Künstlicher Schlüsselrest: wiederholtes Muster, bewusst kein echter Schlüssel.
    private func fill(_ pattern: String, _ count: Int) -> String {
        String(String(repeating: pattern, count: count / pattern.count + 1).prefix(count))
    }

    func testLinearKeysAreMaskedWithTheirOwnLabel() {
        let key = "lin_api_" + fill("aB3", 40)
        XCTAssertEqual(masked(key), "[REDACTED:linear-key]")
        XCTAssertEqual(masked("Linear-Schlüssel: \(key) bitte eintragen"), "Linear-Schlüssel: [REDACTED:linear-key] bitte eintragen")
        XCTAssertEqual(masked("Authorization: \(key)"), "Authorization: [REDACTED:linear-key]")
        XCTAssertEqual(masked("lin_oauth_" + fill("x9Y", 64)), "[REDACTED:linear-key]")
        XCTAssertEqual(masked("lin_wh_" + fill("Q7r", 40)), "[REDACTED:linear-key]")
        XCTAssertFalse(masked("LINEAR_API_KEY=\(key)").contains(key))
    }

    func testLinearKeyWithoutDigitsOrUppercaseIsStillMasked() {
        // Die grobe Regel braucht Groß-, Kleinbuchstabe und Ziffer. Die eigene Regel nicht.
        XCTAssertEqual(masked("lin_api_" + fill("abc", 40)), "[REDACTED:linear-key]")
        XCTAssertEqual(masked("lin_api_" + fill("ab1", 40)), "[REDACTED:linear-key]")
    }

    func testFurtherPrefixedTokens() {
        let cases: [(String, String)] = [
            ("glpat-" + fill("Ab1_", 20), "gitlab-token"),
            ("glpat-" + fill("Ab1", 27) + ".01.0i" + fill("x1", 7), "gitlab-token"),
            ("npm_" + fill("aB3", 36), "npm-token"),
            ("pypi-AgEIcHlwaS5vcmc" + fill("aB3_", 60), "pypi-token"),
            ("hf_" + fill("aBcD", 34), "huggingface-token"),
            ("dop_v1_" + fill("0a1b2c", 64), "digitalocean-token"),
            ("shpat_" + fill("0a1b2c", 32), "shopify-token"),
            ("sbp_" + fill("0a1b2c", 40), "supabase-key"),
            ("sb_secret_" + fill("aB3_", 31), "supabase-key"),
            ("key-" + fill("0a1b2c", 32), "mailgun-key"),
            ("PMAK-" + fill("0a1b", 24) + "-" + fill("2c3d", 34), "postman-key"),
            ("SG." + fill("aB3", 22) + "." + fill("xY7", 43), "sendgrid-key"),
            ("dp.st.prd." + fill("aB3", 43), "doppler-token"),
            ("pat" + fill("aB3", 14) + "." + fill("0a1b2c", 64), "airtable-token"),
            ("GOCSPX-" + fill("aB3_", 28), "google-oauth"),
            ("ya29." + fill("aB3_", 60), "google-oauth"),
            ("1//0" + fill("aB3_", 60), "google-oauth"),
            ("123456789:AA" + fill("aB3_", 33), "telegram-token"),
            ("tskey-auth-" + fill("aB3", 11) + "-" + fill("xY7", 30), "tailscale-key"),
            ("AGE-SECRET-KEY-1" + fill("QZ7", 58), "age-key"),
            ("gsk_" + fill("aB3", 52), "api-key"),
        ]
        for (secret, label) in cases {
            XCTAssertEqual(masked("vorher \(secret) nachher"), "vorher [REDACTED:\(label)] nachher", label)
        }
    }

    func testWebhookURLsKeepTheServiceButHideTheSecret() {
        let slack = "https://hooks.slack.com/services/T0000/B0000/" + fill("aB3", 24)
        XCTAssertEqual(masked(slack), "https://hooks.slack.com/services/[REDACTED:webhook-url]")
        let discord = "https://discord.com/api/webhooks/123456789012345678/" + fill("aB3_", 68)
        XCTAssertEqual(masked(discord), "https://discord.com/api/webhooks/[REDACTED:webhook-url]")
    }

    func testPrefixLookalikesStay() {
        let text = """
        hf_hub_download und hf_transfer sind Python-Namen
        npm_config_cache=/tmp/x
        key-value store und key-abc
        sgd.step() und SG.short.value
        cache-key-d41d8cd98f00b204e9800998ecf8427e
        sb_secret_key_for_the_supabase_project
        dp.st.session_state.some_long_attribute_name.another_attribute
        """
        XCTAssertEqual(masked(text), text)
    }

    /// GitLab: Die Prüfsumme gehört zum Token, eine Dateiendung nicht.
    func testGitLabTokenKeepsAFileExtension() {
        XCTAssertEqual(masked("glpat-" + fill("Ab1_", 20) + ".json"), "[REDACTED:gitlab-token].json")
    }

    // MARK: Falsch-Positive vermeiden

    func testGitHashesUUIDsAndChecksumsStay() {
        let log = """
        commit 3b850d9e4f1c2a7b8e9d0c1f2a3b4c5d6e7f8a9b
        Merge: f40b82e7 51ee3682
        sha256: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
        md5 d41d8cd98f00b204e9800998ecf8427e
        id 6C7DAE08-C4DE-4397-A881-A569D9C1BB9F
        https://github.com/rankm8/whisperm8/commit/3b850d9e4f1c2a7b8e9d0c1f2a3b4c5d6e7f8a9b
        """
        XCTAssertEqual(masked(log), log)
    }

    func testOrdinaryTextWithKeywordsStays() {
        let text = """
        Basic Configuration für das Projekt
        max_tokens: 4096 und input_tokens: 120000
        Das Passwort-Feld ist leer. The token is valid.
        password: <your-password>
        token=${GITHUB_TOKEN}
        """
        XCTAssertEqual(masked(text), text)
    }

    func testMaskingIsIdempotent() {
        let once = masked("sk-abcdefghijklmnopqrstuvwx")
        XCTAssertEqual(masked(once), once)
    }
}
