import Foundation
import XCTest
@testable import WhisperM8

/// Phase-3 Test-Seam: deckt das HTTP-Response-Mapping von
/// MultipartTranscriptionClient ab — via injizierter URLSession mit
/// URLProtocol-Stub, ohne echten Netzwerk-Call.
final class MultipartTranscriptionClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func client() -> MultipartTranscriptionClient {
        let session = stubbedSession()
        return MultipartTranscriptionClient(
            apiKey: "test-key",
            config: .openAI(model: "test-model"),
            sessionProvider: { _ in session }
        )
    }

    private func tempAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtc-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    func testTranscribeReturnsTextOn200() async throws {
        let audio = try tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"hallo welt"}"#.utf8))
        }

        let text = try await client().transcribe(audioURL: audio, language: nil)
        XCTAssertEqual(text, "hallo welt")
    }

    func testTranscribeThrowsApiErrorOnNon200() async throws {
        let audio = try tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }

        do {
            _ = try await client().transcribe(audioURL: audio, language: nil)
            XCTFail("Expected TranscriptionError.apiError")
        } catch let TranscriptionError.apiError(statusCode, _) {
            XCTAssertEqual(statusCode, 401)
        }
    }
}

/// Minimaler URLProtocol-Stub: liefert die vom `handler` definierte Antwort.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
