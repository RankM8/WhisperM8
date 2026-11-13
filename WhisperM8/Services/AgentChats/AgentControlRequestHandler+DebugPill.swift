import AppKit
import Foundation

// MARK: - debug.pill (`whisperm8 debug pill [--hold <ms>] [--busy <ms>] [--busy-after <ms>]`)

/// Übergang der vereinten Pille ohne Aufnahme durchspielen: Diktat-Pille
/// zeigen, stehen lassen, ausblenden, wie beim echten Diktat (`show`/`hide`
/// des `OverlayController`), aber ohne Mikrofon. Währenddessen schneidet
/// `UnifiedPillWindowTracer` die Fensterliste mit; die Antwort nennt, wann
/// welches Fenster stand, und ob es eine Lücke oder einen Versatz gab.
///
/// `busy` blockiert den Main Thread nach dem Aufbau des Diktat-Fensters
/// (sofort im selben Lauf oder `busyAfter` ms später), wie ein schwerer
/// Diktatstart. Läuft ein Diktat, lehnt der Befehl ab.
extension AgentControlRequestHandler {
    func debugPill(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let hold = min(max(request.params["holdMs"]?.intValue ?? 1500, 200), 5000)
        let busy = min(max(request.params["busyMs"]?.intValue ?? 0, 0), 1000)
        let busyAfter = min(max(request.params["busyAfterMs"]?.intValue ?? 0, 0), 300)
        let result = await Task { @MainActor () -> [String: Any]? in
            let appState = AppState.shared
            let overlay = appState.overlayControllerForDebug
            guard !appState.isRecording, !appState.isTranscribing, !overlay.isPresented, overlay.panel == nil else {
                return nil
            }
            let tracer = UnifiedPillWindowTracer()
            var dictationWindow: Int?
            overlay.debugEvent = { name in
                tracer.mark(name)
                guard name.hasPrefix("installed:") else { return }
                dictationWindow = Int(name.dropFirst("installed:".count))
                guard busy > 0 else { return }
                let block = {
                    tracer.mark("busyStart")
                    usleep(useconds_t(busy * 1000))
                    tracer.mark("busyEnd")
                }
                if busyAfter == 0 { return block() }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(busyAfter)) { block() }
            }
            defer { overlay.debugEvent = nil }
            try? await Task.sleep(for: .milliseconds(250))
            let statusBefore = Self.statusPillWindows()
            tracer.mark("show")
            overlay.show(
                appState: appState, onCancel: {}, onCancelTranscription: {}, onCancelPostProcessing: {},
                onStopAndTranscribe: {}, onOutputModeChange: { _ in }, onAddScreenshot: {}, onCaptureScreenshot: {},
                onToggleScreenClip: {}, onClearContext: {}, onContextAction: { _ in })
            try? await Task.sleep(for: .milliseconds(hold))
            tracer.mark("hide")
            overlay.hide()
            try? await Task.sleep(for: .milliseconds(900))
            let (samples, events) = tracer.stop()
            let statusWindows = statusBefore.union(Self.statusPillWindows())
            let verdict = UnifiedPillTraceVerdict.evaluate(
                samples: samples, dictationWindow: dictationWindow, statusWindows: statusWindows)
            return Self.pillTraceJSON(
                samples: samples, events: events, dictationWindow: dictationWindow,
                statusWindows: statusWindows, verdict: verdict)
        }.value
        guard let result else {
            return .failure(requestID: request.requestID, code: .conflict, message: "Diktat oder Pille läuft gerade — später erneut.")
        }
        return .success(requestID: request.requestID, result: .object(result))
    }

    @MainActor
    private static func statusPillWindows() -> Set<Int> {
        Set(NotchStatusController.shared.slots.values.compactMap { $0.panel?.windowNumber }.filter { $0 > 0 })
    }

    private static func pillTraceJSON(
        samples: [UnifiedPillWindowSample], events: [UnifiedPillTraceEvent],
        dictationWindow: Int?, statusWindows: Set<Int>, verdict: UnifiedPillTraceVerdict
    ) -> [String: Any] {
        func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        func frame(_ window: UnifiedPillWindowSample.Window?) -> Any {
            guard let window else { return NSNull() }
            let b = window.bounds
            return "\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height))"
        }
        // Nur die beiden Pillen-Fenster, nur Änderungen.
        var rows: [[String: Any]] = []
        var last: (Any, Any)?
        for sample in samples {
            let status = frame(sample.windows.first { statusWindows.contains($0.number) })
            let dictation = frame(sample.windows.first { $0.number == dictationWindow })
            if let last, "\(last.0)" == "\(status)", "\(last.1)" == "\(dictation)" { continue }
            last = (status, dictation)
            rows.append(["t": rounded(sample.time), "status": status, "dictation": dictation])
        }
        func optional(_ value: Double?) -> Any { value.map(rounded) ?? NSNull() }
        return [
            "seamless": verdict.isSeamless,
            "longestGapMs": rounded(verdict.longestGapMs),
            "maxCenterOffset": rounded(verdict.maxCenterOffset),
            "overlapMs": rounded(verdict.overlapMs),
            "dictationAppearedMs": optional(verdict.dictationAppearedMs),
            "statusHiddenMs": optional(verdict.statusHiddenMs),
            "statusBackMs": optional(verdict.statusBackMs),
            "dictationGoneMs": optional(verdict.dictationGoneMs),
            "events": events.map { ["t": rounded($0.time), "name": $0.name] as [String: Any] },
            "windows": rows,
        ]
    }
}
