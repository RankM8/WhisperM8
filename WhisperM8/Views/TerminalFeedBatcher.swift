import Foundation

/// Feed-Drosselung nicht-fokussierter Panes (Plan F11, Blaupause ff489fdb):
/// puffert PTY-Bytes und verarbeitet sie gebündelt mit ~12,5 Hz statt pro
/// Chunk — Parser-/Render-Scheduling skaliert damit nicht mehr linear mit
/// jedem PTY-Paket. Regeln:
///
/// - **Nie Byte-Verlust, striktes FIFO**: die harte Puffergrenze führt zu
///   einem vorgezogenen Flush des ÄLTEREN Prefixes, nie zu Drop/Truncation;
///   ein übergroßer Einzel-Chunk wird nach dem Prefix-Flush direkt verarbeitet.
/// - **Fokus-Flush**: Abschalten der Drosselung verarbeitet den kompletten
///   Puffer sofort (VOR dem Fokuswechsel, damit der User den echten Stand sieht).
/// - Scheduling ist injiziert (Tests feuern manuell; die View hängt einen
///   phasenversetzten 80-ms-Timer dran, damit acht Hintergrund-Panes nicht
///   synchron feuern).
///
/// Alle Aufrufe auf der Main Queue (SwiftTerm liefert `dataReceived` dort).
final class TerminalFeedBatcher {
    /// Harte Puffergrenze je Pane (256 KiB × 9 Panes ≈ 2,25 MiB Zusatzspeicher —
    /// klein halten, sonst hebelt der Puffer SwiftTerms PTY-Backpressure #574 aus).
    let maxPendingBytes: Int
    /// Verarbeitet Bytes wirklich (`super.dataReceived`). `batched` = kam aus
    /// dem Puffer (die View misst dann `grid.streamingFrame`).
    private let feed: (ArraySlice<UInt8>, _ batched: Bool) -> Void
    /// Plant genau EINEN Flush; Rückgabe ist die Cancel-Closure.
    private let scheduleFlush: (@escaping () -> Void) -> () -> Void

    private var pending = ContiguousArray<UInt8>()
    private var cancelScheduled: (() -> Void)?

    /// `true` = Bytes puffern (Hintergrund-Pane). Abschalten flusht sofort.
    var isThrottling = false {
        didSet {
            guard oldValue, !isThrottling else { return }
            flushPending()
        }
    }

    init(
        maxPendingBytes: Int = 256 * 1024,
        feed: @escaping (ArraySlice<UInt8>, _ batched: Bool) -> Void,
        scheduleFlush: @escaping (@escaping () -> Void) -> () -> Void
    ) {
        self.maxPendingBytes = maxPendingBytes
        self.feed = feed
        self.scheduleFlush = scheduleFlush
    }

    var pendingByteCount: Int { pending.count }

    func receive(_ slice: ArraySlice<UInt8>) {
        guard isThrottling else {
            // Direkter Pfad — defensiv erst Puffer-Reste (Reihenfolge!).
            flushPending()
            feed(slice, false)
            return
        }
        if pending.count + slice.count > maxPendingBytes {
            // Erst den älteren Prefix verarbeiten: kein Drop, keine Umordnung.
            flushPending()
        }
        if slice.count >= maxPendingBytes {
            feed(slice, false)
            return
        }
        pending.append(contentsOf: slice)
        if cancelScheduled == nil {
            cancelScheduled = scheduleFlush { [weak self] in
                self?.cancelScheduled = nil
                self?.flushPending()
            }
        }
    }

    /// Puffer sofort verarbeiten (Fokuswechsel, Teardown, High-Water).
    func flushPending() {
        cancelScheduled?()
        cancelScheduled = nil
        guard !pending.isEmpty else { return }
        let bytes = Array(pending)
        pending.removeAll(keepingCapacity: true)
        feed(bytes[...], true)
    }
}
