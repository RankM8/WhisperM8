import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Debug-Steuerkanal (`whisperm8 debug …`): pure Bausteine, CLI-Parser,
/// Diktat-Plan/-Ablauf mit Stub-Service und das Fenster-Foto.
final class DebugControlTests: XCTestCase {
    // MARK: - open

    func testOpenTargetParsing() {
        XCTAssertEqual(DebugControl.OpenTarget.parse("settings"), .settings(page: nil))
        XCTAssertEqual(DebugControl.OpenTarget.parse("settings/transcription"), .settings(page: "transcription"))
        XCTAssertEqual(DebugControl.OpenTarget.parse("settings/gpt-backend"), .settings(page: "gpt-backend"))
        // Alt-Routen aus SettingsRouteTarget bleiben gültig.
        XCTAssertEqual(DebugControl.OpenTarget.parse("settings/api"), .settings(page: "api"))
        XCTAssertEqual(DebugControl.OpenTarget.parse(" agent-chats "), .agentChats)
        XCTAssertEqual(DebugControl.OpenTarget.parse("onboarding"), .onboarding)
        // Unbekannte Seite fällt NICHT still auf die Startseite.
        XCTAssertNil(DebugControl.OpenTarget.parse("settings/gibtsnicht"))
        XCTAssertNil(DebugControl.OpenTarget.parse("agent-chats/x"))
        XCTAssertNil(DebugControl.OpenTarget.parse("finder"))
        XCTAssertNil(DebugControl.OpenTarget.parse(""))
    }

    @MainActor
    func testSettingsRouteOverrideLivesUntilNextPlainRequest() {
        let center = WindowRequestCenter.shared
        center.requestSettings(routeID: "transcription")
        XCTAssertEqual(center.latestRequest, .settings)
        // Zweimal auswerten (onAppear + Publisher-Erstwert) → beide Male die Seite.
        XCTAssertEqual(center.settingsRouteID(for: .settings), "transcription")
        XCTAssertEqual(center.settingsRouteID(for: .settings), "transcription")
        // Andere Requests behalten ihren festen Einstieg.
        XCTAssertEqual(center.settingsRouteID(for: .settingsOutput), "outputOverview")

        center.request(.settings)
        XCTAssertEqual(center.settingsRouteID(for: .settings), "recording")
    }

    // MARK: - Fenster

    private func window(
        _ number: Int,
        title: String = "",
        identifier: String? = nil,
        className: String = "SwiftUI.AppKitWindow",
        isKey: Bool = false,
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        size: CGSize = CGSize(width: 800, height: 600)
    ) -> DebugControl.WindowInfo {
        DebugControl.WindowInfo(
            number: number, identifier: identifier, title: title, className: className,
            isKey: isKey, isVisible: isVisible, isMiniaturized: isMiniaturized,
            frame: CGRect(origin: .zero, size: size)
        )
    }

    func testWindowSelection() {
        let windows = [
            window(1, title: "WhisperM8 Settings", identifier: "settings", isKey: true),
            window(2, title: "Agent Chats", identifier: "agent-chats"),
            window(3, title: "Alt", isMiniaturized: true),
            window(4, title: "Versteckt", isVisible: false),
            window(5, className: "NSStatusBarWindow"),
            window(6, title: "Winzig", size: CGSize(width: 1, height: 1)),
            window(10, className: "NSToolTipPanel"),
            window(11, className: "TUINSWindow"),
        ]
        XCTAssertEqual(DebugControl.select(windows, selector: nil).map(\.number), [1, 2])
        XCTAssertEqual(DebugControl.select(windows, selector: "all").map(\.number), [1, 2])
        XCTAssertEqual(DebugControl.select(windows, selector: "key").map(\.number), [1])
        XCTAssertEqual(DebugControl.select(windows, selector: "SETTINGS").map(\.number), [1])
        XCTAssertEqual(DebugControl.select(windows, selector: "agent-chats").map(\.number), [2])
        XCTAssertEqual(DebugControl.select(windows, selector: "alt").map(\.number), [])
    }

    func testSnapshotFileNameIsSafeAndUnique() {
        let date = Date(timeIntervalSince1970: 1_791_500_000)
        let name = DebugControl.snapshotFileName(for: window(7, title: "Über / Einstellungen: GPT"), date: date)
        XCTAssertTrue(name.hasSuffix("-ber-einstellungen-gpt-7.png"), name)
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(DebugControl.snapshotFileName(for: window(8), date: date).hasSuffix("-fenster-8-8.png"))
        XCTAssertTrue(DebugControl.snapshotFileName(for: window(9, identifier: "agent-chats"), date: date)
            .hasSuffix("-agent-chats-9.png"))
    }

    // MARK: - Aufträge

    func testJobStoreLimitsRunningJobsAndPrunesFinished() throws {
        let store = DebugJobStore(maxRunning: 2, retention: 60)
        let start = Date()
        let first = try XCTUnwrap(store.start(now: start))
        let second = try XCTUnwrap(store.start(now: start))
        XCTAssertNil(store.start(now: start), "drittes gleichzeitiges Diktat wird abgelehnt")

        store.finish(first, result: ["text": "hallo"], now: start)
        XCTAssertNotNil(store.start(now: start), "Platz wieder frei")
        guard case .done(let result, _)? = store.state(first, now: start) else { return XCTFail("done erwartet") }
        XCTAssertEqual(result["text"] as? String, "hallo")

        store.fail(second, message: "kaputt", now: start)
        XCTAssertEqual(store.state(second, now: start)?.json["message"] as? String, "kaputt")
        // Nach Ablauf der Aufbewahrung weg.
        XCTAssertNil(store.state(first, now: start.addingTimeInterval(61)))
        XCTAssertNil(store.state("unbekannt"))
    }

    // MARK: - Diktat

    private final class StubService: TranscriptionServiceProtocol, @unchecked Sendable {
        var received: (URL, String?)?
        var text = " hallo welt "
        func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
            received = (audioURL, language)
            return text
        }
    }

    private func dependencies(
        provider: TranscriptionProvider = .groq,
        model: TranscriptionModel = .groq_whisper_v3_turbo,
        chatGPTEnabled: Bool = true,
        language: String = "de",
        keys: [TranscriptionProvider: String] = [.groq: "gsk", .openai: "sk"],
        service: StubService = StubService(),
        made: ((TranscriptionProvider, TranscriptionModel, String) -> Void)? = nil
    ) -> DebugDictation.Dependencies {
        DebugDictation.Dependencies(
            storedProvider: { provider },
            storedModel: { model },
            chatGPTEnabled: { chatGPTEnabled },
            language: { language },
            apiKey: { keys[$0] },
            makeService: { provider, model, key in
                made?(provider, model, key)
                return service
            }
        )
    }

    func testDictationPlanFollowsSettingsAndOverrides() throws {
        var plan = try DebugDictation.plan(providerOverride: nil, languageOverride: nil, dependencies: dependencies())
        XCTAssertEqual(plan, .init(provider: .groq, model: .groq_whisper_v3_turbo, language: "de"))

        // Override auf fremden Anbieter → dessen Default-Modell.
        plan = try DebugDictation.plan(providerOverride: "chatgpt", languageOverride: "auto", dependencies: dependencies())
        XCTAssertEqual(plan, .init(provider: .chatgpt, model: .chatgpt_transcribe, language: nil))

        plan = try DebugDictation.plan(providerOverride: "OpenAI", languageOverride: "en", dependencies: dependencies())
        XCTAssertEqual(plan, .init(provider: .openai, model: .openai_gpt4o, language: "en"))

        XCTAssertThrowsError(try DebugDictation.plan(providerOverride: "whisperx", languageOverride: nil, dependencies: dependencies())) {
            XCTAssertEqual($0 as? DebugDictation.Failure, .unknownProvider("whisperx"))
        }
        XCTAssertThrowsError(try DebugDictation.plan(
            providerOverride: "chatgpt", languageOverride: nil, dependencies: dependencies(chatGPTEnabled: false)
        )) {
            XCTAssertEqual($0 as? DebugDictation.Failure, .providerUnavailable("chatgpt"))
        }
        // Leere Spracheinstellung = automatisch.
        plan = try DebugDictation.plan(providerOverride: nil, languageOverride: nil, dependencies: dependencies(language: ""))
        XCTAssertNil(plan.language)
    }

    private func tempAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("debug-dictate-\(UUID()).m4a")
        try Data(repeating: 1, count: 128).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDictationRunUsesServiceFactoryAndNormalizes() async throws {
        let audio = try tempAudio()
        let service = StubService()
        var made: (TranscriptionProvider, TranscriptionModel, String)?
        let result = try await DebugDictation.run(
            audioURL: audio, providerOverride: nil, languageOverride: nil,
            dependencies: dependencies(service: service, made: { made = ($0, $1, $2) })
        )
        XCTAssertEqual(made?.0, .groq)
        XCTAssertEqual(made?.1, .groq_whisper_v3_turbo)
        XCTAssertEqual(made?.2, "gsk")
        XCTAssertEqual(service.received?.0, audio)
        XCTAssertEqual(service.received?.1, "de")
        XCTAssertEqual(result["rawText"] as? String, " hallo welt ")
        XCTAssertEqual(result["text"] as? String, TextNormalizer.normalizeTranscriptionText(" hallo welt "))
        XCTAssertEqual(result["audioBytes"] as? Int, 128)
        XCTAssertEqual(result["provider"] as? String, "groq")
    }

    func testDictationRunChecksKeyAndFile() async throws {
        let audio = try tempAudio()
        do {
            _ = try await DebugDictation.run(audioURL: audio, providerOverride: "openai", languageOverride: nil,
                                             dependencies: dependencies(keys: [:]))
            XCTFail("fehlender Key muss scheitern")
        } catch {
            XCTAssertEqual(error as? DebugDictation.Failure, .missingAPIKey("OpenAI"))
        }
        // ChatGPT-Abo braucht keinen Key.
        _ = try await DebugDictation.run(audioURL: audio, providerOverride: "chatgpt", languageOverride: nil,
                                         dependencies: dependencies(keys: [:]))
        let missing = URL(fileURLWithPath: "/tmp/gibt-es-nicht-\(UUID()).m4a")
        do {
            _ = try await DebugDictation.run(audioURL: missing, providerOverride: nil, languageOverride: nil,
                                             dependencies: dependencies())
            XCTFail("fehlende Datei muss scheitern")
        } catch {
            XCTAssertEqual(error as? DebugDictation.Failure, .fileMissing(missing.path))
        }
    }

    // MARK: - CLI

    func testCLIArgumentParsing() throws {
        let cwd = "/Users/x/proj"
        XCTAssertEqual(try DebugCLIArguments.parse([], cwd: cwd), .help)
        XCTAssertEqual(try DebugCLIArguments.parse(["state"], cwd: cwd), .state)
        XCTAssertEqual(try DebugCLIArguments.parse(["open", "settings/transcription"], cwd: cwd),
                       .open(target: "settings/transcription"))
        XCTAssertEqual(try DebugCLIArguments.parse(["snapshot"], cwd: cwd), .snapshot(window: nil, outputDir: nil))
        XCTAssertEqual(try DebugCLIArguments.parse(["snapshot", "--window", "key", "-o", "shots"], cwd: cwd),
                       .snapshot(window: "key", outputDir: "/Users/x/proj/shots"))
        XCTAssertEqual(
            try DebugCLIArguments.parse(["dictate", "../a.m4a", "--provider", "chatgpt", "-l", "auto", "--timeout", "30"], cwd: cwd),
            .dictate(audioPath: "/Users/x/a.m4a", provider: "chatgpt", language: "auto", timeoutSeconds: 30)
        )
        XCTAssertEqual(try DebugCLIArguments.parse(["dictate", "/abs/b.m4a"], cwd: cwd),
                       .dictate(audioPath: "/abs/b.m4a", provider: nil, language: nil,
                                timeoutSeconds: DebugCLIArguments.defaultDictateTimeout))
        XCTAssertEqual(try DebugCLIArguments.parse(["job", "abc"], cwd: cwd), .job(id: "abc"))

        for bad in [["state", "x"], ["open"], ["open", "settings/gibtsnicht"], ["dictate"], ["dictate", "a", "b"], ["dictate", "a", "--timeout", "0"],
                    ["snapshot", "--window"], ["job"], ["zaubern"]] {
            XCTAssertThrowsError(try DebugCLIArguments.parse(bad, cwd: cwd), "\(bad)")
        }
    }

    func testDebugIsRecognizedAsCLICommand() {
        XCTAssertTrue(CLIModeDetector.shouldRunCLI(["/Applications/WhisperM8.app/Contents/MacOS/WhisperM8", "debug", "state"]))
    }

    // MARK: - Fenster-Foto

    /// Derselbe Weg wie `debug.snapshot`: Theme-Frame (mit Titelleiste) eines
    /// echten Fensters, Fallback auf den Inhalt.
    @MainActor
    func testWindowSnapshotIncludesTitleBar() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Testfenster"
        window.contentView = NSHostingView(rootView: Text("Inhalt").frame(width: 300, height: 200))
        defer { window.close() }

        let content = try XCTUnwrap(window.contentView)
        let themeFrame = try XCTUnwrap(content.superview)
        let png = try ViewSnapshotRenderer.pngData(of: themeFrame)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, Int(themeFrame.bounds.width * 2))
        XCTAssertGreaterThan(themeFrame.bounds.height, content.bounds.height, "Titelleiste fehlt")
    }
}
