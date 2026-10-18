import Foundation
import XCTest
@testable import WhisperM8

/// LR-GPT-008: Request-Body wird hoechstens einmal voll geparst; der
/// Byte-Scan fuer `model` liefert dasselbe wie der volle Parse.
final class ClaudeGPTMixRouterBodyTests: XCTestCase {
    private func fullParseModel(_ body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body))
            .flatMap { $0 as? [String: Any] }
            .flatMap { $0["model"] as? String }
    }

    private let backslash = "\\"

    private var fixtures: [String] {
        [
            #"{"model":"  GPT-5.6-SOL-FAST[1M]  "}"#,
            #"{"model":"claude-fable-5"}"#,
            #"{"messages":[]}"#,
            "kaputt",
            "",
            "[]",
            #"{"model":"gpt-6-astra","messages":[],"tools":[{"name":"X","input_schema":{"properties":{"model":{"type":"string"}}}}]}"#,
            #"{"messages":[{"role":"user","content":"{\"model\":\"gpt-evil\"}"}],"model":"claude-opus-4-8"}"#,
            #"{"tools":[{"name":"a","model":"gpt-nested"}],"model":"gpt-5.6-sol"}"#,
            #"{"tools":[{"name":"a","model":"gpt-nested"}]}"#,
            #"{ "model" : "gpt-5.6-sol" , "x" : 1 }"#,
            "{\n  \"model\":\n \"claude-sonnet-5-5\"\n}",
            #"{"model":"gpt-a","model":"claude-b"}"#,
            #"{"model":42}"#,
            #"{"model":null,"x":"y"}"#,
            #"{"model":"gpt-"# + backslash + #"u0036"}"#,
            #"{"mod"# + backslash + #"u0065l":"gpt-esc"}"#,
            #"{"model":"gpt-ü-é"}"#,
            #"{"a":"\\","model":"gpt-after-backslash"}"#,
            #"{"a":"\"","model":"gpt-after-quote"}"#,
            #"{"model":"gpt-5.6-sol""#,
            #"{"model":"auto","messages":[]}"#,
        ]
    }

    func testByteScanEqualsFullParseForAllFixtures() {
        for text in fixtures {
            let body = Data(text.utf8)
            XCTAssertEqual(ClaudeGPTMixRouter.model(in: body), fullParseModel(body), text)
        }
    }

    func testByteScanSkipsFullParseForCommonBodies() {
        let before = ClaudeGPTMixRouter.bodyParseCounter.count
        let body = Data(#"{"model":"gpt-5.6-sol","messages":[{"role":"user","content":"hi"}],"tools":[{"name":"Read","input_schema":{"type":"object"}}]}"#.utf8)
        XCTAssertEqual(ClaudeGPTMixRouter.model(in: body), "gpt-5.6-sol")
        XCTAssertEqual(ClaudeGPTMixRouter.bodyParseCounter.count, before, "Byte-Scan genuegt, kein voller Parse")
    }

    func testBodyWithoutHitIsParsedAtMostOnce() {
        let body = Data(#"{"model":"gpt-5.6-sol","messages":[{"role":"user","content":"hi"}],"tools":[{"name":"Read","input_schema":{"type":"object","properties":{"p":{"type":"string","pattern":"^[a-z]+$"}}}}]}"#.utf8)
        let before = ClaudeGPTMixRouter.bodyParseCounter.count
        let prepared = ClaudeGPTMixRouter.prepareRequestBody(body)
        let parses = ClaudeGPTMixRouter.bodyParseCounter.count - before
        XCTAssertLessThanOrEqual(parses, 1)
        XCTAssertEqual(prepared.body, body, "ohne Treffer byte-identisch")
        XCTAssertEqual(prepared.model, "gpt-5.6-sol")
        XCTAssertEqual(prepared.upstream, .codexProxy)
        XCTAssertNil(prepared.sanitization)
    }

    func testAutoAndSanitizerBodiesParseOnceEachAndStayCorrect() throws {
        let auto = Data(#"{"model":"auto","messages":[],"tools":[{"name":"A","input_schema":{"pattern":"^[\\p{Cc}]$"}}]}"#.utf8)
        let before = ClaudeGPTMixRouter.bodyParseCounter.count
        let prepared = ClaudeGPTMixRouter.prepareRequestBody(auto)
        let parses = ClaudeGPTMixRouter.bodyParseCounter.count - before
        XCTAssertEqual(parses, 2, "Auto-Umschreibung + Sanitizer, je einmal")
        XCTAssertEqual(prepared.upstream, .codexProxy)
        let expected = try XCTUnwrap(ClaudeGPTMixRouter.resolvedAutoModel(for: "auto"))
        XCTAssertEqual(prepared.model, expected)
        XCTAssertEqual(prepared.sanitization?.removedPatterns, 1)
        XCTAssertEqual(fullParseModel(prepared.body), expected)
    }

    func testAnthropicBodySkipsSanitizerAndRewrite() {
        let body = Data(#"{"model":"claude-opus-4-8","tools":[{"input_schema":{"pattern":"^[\\p{Cc}]$"}}]}"#.utf8)
        let before = ClaudeGPTMixRouter.bodyParseCounter.count
        let prepared = ClaudeGPTMixRouter.prepareRequestBody(body)
        XCTAssertEqual(ClaudeGPTMixRouter.bodyParseCounter.count, before)
        XCTAssertEqual(prepared.upstream, .anthropic)
        XCTAssertEqual(prepared.body, body)
    }

    func testSanitizerPrefilterNeverMissesMaskedBackslash() {
        // Pattern ueber Unicode-Escapes maskiert: Vorfilter muss trotzdem greifen.
        // JSON-Text: "^[" + \\ + p + "{Cc}]$"  -> dekodiert `^[\p{Cc}]$`.
        let masked = Data((#"{"model":"gpt-6-astra","tools":[{"name":"M","input_schema":{"pattern":"^[\\"# + backslash + #"u0070{Cc}]$"}}]}"#).utf8)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: masked), "Fixture muss gueltiges JSON sein")
        XCTAssertEqual(ClaudeGPTMixRouter.sanitizingToolSchemas(in: masked).removedPatterns, 1)
    }

    /// Vertrag des Vorfilters: Wo der Sanitizer etwas entfernen würde, darf
    /// `mayContainUnsupportedPattern` nie `false` liefern — auch nicht, wenn
    /// Backslash, `p` oder `{` per Unicode-Escape maskiert sind.
    func testPrefilterIsTrueWheneverSanitizerWouldRemoveSomething() {
        let u = backslash + "u"
        let patterns = [
            #"\\p{Cc}"#,                       // roh: \p{Cc}
            #"\\P{L}"#,
            u + "005cp{Cc}",                      // Backslash maskiert
            #"\\"# + u + "0070{Cc}",            // p maskiert
            #"\\p"# + u + "007bCc}",            // { maskiert
            #"\\p"# + u + "007BCc}",
        ]
        for pattern in patterns {
            let body = Data((#"{"model":"gpt-6-astra","tools":[{"name":"M","input_schema":{"pattern":"^["# + pattern + #"]$"}}]}"#).utf8)
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: body), "Fixture muss gueltiges JSON sein: \(pattern)")
            XCTAssertEqual(ClaudeGPTMixRouter.sanitizingToolSchemas(in: body).removedPatterns, 1, "Sanitizer greift nicht: \(pattern)")
            XCTAssertTrue(ClaudeGPTMixRouter.mayContainUnsupportedPattern(body), "Vorfilter verfehlt: \(pattern)")
        }
    }
}
