import Foundation
import XCTest
@testable import WhisperM8

// MARK: - Fixtures

private func message(_ role: AgentChatMessage.Role, _ blocks: [AgentChatBlock]) -> AgentChatMessage {
    AgentChatMessage(id: UUID(), role: role, timestamp: nil, blocks: blocks)
}

private func transcript(_ messages: [AgentChatMessage]) -> AgentChatTranscript {
    AgentChatTranscript(messages: messages, isLiveSourcePossible: false)
}

private func render(_ messages: [AgentChatMessage],
                    limits: TranscriptTextRenderer.Limits = .default) -> [TranscriptTextLine] {
    TranscriptTextRenderer.render(transcript(messages), limits: limits)
}

/// Alle Textzeilen als ein String — bequem für Enthaltensein-Prüfungen.
private func joined(_ lines: [TranscriptTextLine]) -> String {
    lines.map(\.text).joined(separator: "\n")
}

final class TranscriptTextRendererTests: XCTestCase {

    // MARK: - Rollen und Marker

    func testUserPromptBekommtPromptMarker() {
        let lines = render([message(.user, [.text("Bitte prüfe den Stand.")])])
        XCTAssertEqual(lines.first?.style, .prompt)
        XCTAssertEqual(lines.first?.text, "❯ Bitte prüfe den Stand.")
    }

    func testAssistantAntwortBekommtAntwortMarker() {
        let lines = render([message(.assistant, [.text("Erledigt.")])])
        XCTAssertEqual(lines.first?.style, .answer)
        XCTAssertEqual(lines.first?.text, "⏺ Erledigt.")
    }

    func testSystemNachrichtWirdAlsMetaGerendert() {
        let lines = render([message(.system, [.text("Kontext neu geladen")])])
        XCTAssertEqual(lines.first?.style, .meta)
        XCTAssertEqual(lines.first?.text, "· Kontext neu geladen")
    }

    /// Folgezeilen rücken auf Markerbreite ein, damit der Block optisch
    /// zusammenbleibt — sonst zerfällt ein mehrzeiliger Absatz.
    func testMehrzeiligerTextWirdEingerueckt() {
        let lines = render([message(.assistant, [.text("Zeile eins\nZeile zwei")])])
        XCTAssertEqual(lines.map(\.text), ["⏺ Zeile eins", "  Zeile zwei"])
        XCTAssertTrue(lines.allSatisfy { $0.style == .answer })
    }

    func testThinkingBekommtEigenenStil() {
        let lines = render([message(.assistant, [.thinking("wägt Optionen ab")])])
        XCTAssertEqual(lines.first?.style, .thinking)
        XCTAssertEqual(lines.first?.text, "✻ wägt Optionen ab")
    }

    // MARK: - Tool-Aufrufe

    func testToolAufrufZeigtKlassifiziertesSubject() {
        let input = #"{"file_path":"/repo/WhisperM8/Views/AgentChatsView.swift"}"#
        let lines = render([message(.assistant, [.toolUse(name: "Read", input: input)])])
        XCTAssertEqual(lines.first?.style, .tool)
        XCTAssertTrue(lines.first?.text.hasPrefix("⏺ Read(") == true, "war: \(lines.first?.text ?? "-")")
        XCTAssertTrue(lines.first?.text.contains("AgentChatsView.swift") == true)
    }

    /// Ein mehrzeiliges Bash-Kommando darf die Zeilenstruktur nicht sprengen.
    func testMehrzeiligesToolSubjectBleibtEineZeile() {
        let input = #"{"command":"swift build\nswift test"}"#
        let lines = render([message(.assistant, [.toolUse(name: "Bash", input: input)])])
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].text.contains("\n"))
    }

    func testToolErgebnisWirdEingerueckt() {
        let lines = render([message(.user, [.toolResult(content: "Build complete!", isError: false)])])
        XCTAssertEqual(lines.first?.style, .toolOutput)
        XCTAssertEqual(lines.first?.text, "  ⎿  Build complete!")
    }

    func testFehlerhaftesToolErgebnisBekommtFehlerstil() {
        let lines = render([message(.user, [.toolResult(content: "1 Test fehlgeschlagen", isError: true)])])
        XCTAssertEqual(lines.first?.style, .toolError)
    }

    /// Lange Tool-Ausgaben werden wie in der CLI gerafft — mit Zählung, damit
    /// erkennbar bleibt, wie viel nicht gezeigt wird.
    func testLangesToolErgebnisWirdMitZaehlungGekuerzt() {
        let content = (1...40).map { "Zeile \($0)" }.joined(separator: "\n")
        let limits = TranscriptTextRenderer.Limits(toolOutputLines: 5, toolOutputChars: 10_000)
        let lines = render([message(.user, [.toolResult(content: content, isError: false)])], limits: limits)

        XCTAssertEqual(lines.filter { $0.style == .toolOutput }.count, 5)
        XCTAssertTrue(joined(lines).contains("+35 Zeilen"), "war: \(joined(lines))")
    }

    func testZeichenDeckelWirdGemeldet() {
        let content = String(repeating: "x", count: 500)
        let limits = TranscriptTextRenderer.Limits(toolOutputLines: 12, toolOutputChars: 100)
        let lines = render([message(.user, [.toolResult(content: content, isError: false)])], limits: limits)
        XCTAssertTrue(joined(lines).contains("+400 Zeichen"), "war: \(joined(lines))")
    }

    /// Antworttexte werden NICHT gekürzt — die alten Deckel mitten im
    /// Fließtext („… 2000 Zeichen abgeschnitten") sind ersatzlos weg.
    func testAntworttextWirdNiemalsGekuerzt() {
        let long = String(repeating: "Sehr langer Absatz. ", count: 2_000)
        let lines = render([message(.assistant, [.text(long)])])
        XCTAssertEqual(lines.filter { $0.style == .answer }.count, 1)
        XCTAssertTrue(lines[0].text.count > 30_000)
        XCTAssertFalse(joined(lines).contains("abgeschnitten"))
    }

    func testBildWirdAlsPlatzhalterGezeigt() {
        let lines = render([message(.user, [.imagePlaceholder(mediaType: "image/png", byteSize: 245_000)])])
        XCTAssertEqual(lines.first?.style, .meta)
        XCTAssertTrue(lines.first?.text.contains("image/png") == true)
    }

    // MARK: - Struktur

    func testLeereBloeckeErzeugenKeineLeerzeilen() {
        let lines = render([
            message(.assistant, [.text("   \n  ")]),
            message(.assistant, [.text("Da.")])
        ])
        XCTAssertEqual(lines.map(\.text), ["⏺ Da."])
    }

    func testNachrichtenWerdenDurchLeerzeileGetrennt() {
        let lines = render([
            message(.user, [.text("Frage")]),
            message(.assistant, [.text("Antwort")])
        ])
        XCTAssertEqual(lines.map(\.style), [.prompt, .blank, .answer])
    }

    func testLeeresTranscriptErgibtKeineZeilen() {
        XCTAssertTrue(TranscriptTextRenderer.render(.empty).isEmpty)
    }

    // MARK: - Härtetest

    /// Der Grund für den ganzen Umbau: Ein sehr großer Verlauf darf die App
    /// nicht mehr blockieren. Gemessen wird der Pfad, dessen Kosten noch mit
    /// der Menge wachsen (Rendern + Attributieren) — er läuft in der App
    /// off-main, muss aber trotzdem in vertretbarer Zeit fertig werden.
    /// Alles Weitere (Layout) hängt danach nur noch am sichtbaren Ausschnitt.
    func testSehrGrosserVerlaufBleibtInnerhalbDesBudgets() throws {
        let absatz = String(repeating: "Ein Satz mit etwas Inhalt. ", count: 60)
        let ausgabe = (1...30).map { "  Ausgabezeile \($0)" }.joined(separator: "\n")
        var messages: [AgentChatMessage] = []
        messages.reserveCapacity(12_000)
        for index in 0..<3_000 {
            messages.append(message(.user, [.text("Auftrag \(index): \(absatz)")]))
            messages.append(message(.assistant, [.thinking("prüft \(index)")]))
            messages.append(message(.assistant, [
                .text(absatz),
                .toolUse(name: "Bash", input: #"{"command":"swift test"}"#)
            ]))
            messages.append(message(.user, [.toolResult(content: ausgabe, isError: false)]))
        }
        let big = transcript(messages)
        let zeichen = messages.reduce(0) { sum, msg in
            sum + msg.blocks.reduce(0) { inner, block in
                if case .text(let text) = block { return inner + text.count }
                return inner
            }
        }
        XCTAssertGreaterThan(zeichen, 5_000_000, "Fixture soll wirklich groß sein")

        let startRender = Date()
        let lines = TranscriptTextRenderer.render(big)
        let renderDauer = Date().timeIntervalSince(startRender)

        let startDoc = Date()
        let document = TranscriptTextDocument.make(lines: lines)
        let docDauer = Date().timeIntervalSince(startDoc)

        XCTAssertGreaterThan(lines.count, 30_000)
        XCTAssertGreaterThan(document.length, 5_000_000)
        // Großzügig gewählt: Der Test soll eine ECHTE Regression fangen
        // (etwa eine versehentlich quadratische Schleife), nicht bei
        // Maschinen-Schwankungen rot werden.
        XCTAssertLessThan(renderDauer, 5.0, "Rendern dauerte \(renderDauer)s")
        XCTAssertLessThan(docDauer, 10.0, "Attributieren dauerte \(docDauer)s")
    }
}
