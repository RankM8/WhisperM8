import XCTest
@testable import WhisperM8

/// Die komplette Router-Suite noch einmal gegen den BSD-Lauscher des
/// Router-Dienstes: gleiche HTTP-Logik, andere Ein- und Ausgabe.
final class ClaudeGPTMixRouterSocketListenerTests: ClaudeGPTMixRouterTests {
    override class var listenerKind: ClaudeGPTMixRouter.ListenerKind { .bsdSockets }
}
