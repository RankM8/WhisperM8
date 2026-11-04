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
        XCTAssertEqual(masked("password=hunter22!"), "password=[REDACTED:secret]")
        XCTAssertEqual(masked("API_KEY: \"abc123xyz\""), "API_KEY: \"[REDACTED:secret]\"")
        XCTAssertEqual(masked("token = a1b2c3"), "token = [REDACTED:secret]")
    }

    func testShortAssignmentValuesStay() {
        XCTAssertEqual(masked("password=abc"), "password=abc")
    }

    func testLongHexAndMixedTokens() {
        let hex = String(repeating: "deadbeef", count: 5)
        XCTAssertEqual(masked("sha \(hex) ok"), "sha [REDACTED:hex-token] ok")
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

    func testMaskingIsIdempotent() {
        let once = masked("sk-abcdefghijklmnopqrstuvwx")
        XCTAssertEqual(masked(once), once)
    }
}
