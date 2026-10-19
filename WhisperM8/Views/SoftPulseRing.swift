import AppKit
import QuartzCore
import SwiftUI

/// Sanfter Status-Puls, der den Main Thread nicht beschäftigt.
///
/// Warum nicht SwiftUI: Ein `repeatForever`-Puls lässt SwiftUI jeden Frame neu
/// auswerten und hielt die Layout-Schleife des ganzen Fensters samt
/// WindowServer dauerhaft beschäftigt (LR-AU-002, gemessen ~36 % CPU). Hier
/// läuft eine `CAAnimation` auf einer eigenen Ebene: Core Animation spielt sie
/// im Render-Server ab, SwiftUI und der Main Thread rechnen pro Frame nichts.
///
/// Zusätzlich sparsam:
/// - Bildrate auf höchstens 15 fps gedrosselt — für ein langsames Atmen sieht
///   das gleich aus, kostet den Compositor aber ein Viertel.
/// - Pause, solange das Fenster verdeckt oder minimiert ist.
/// - Keine Bewegung bei „Bewegung reduzieren“ (Bedienungshilfen).
struct SoftPulseRing: NSViewRepresentable {
    let color: NSColor
    let maxScale: CGFloat
    let duration: CFTimeInterval
    let filled: Bool
    let startOpacity: Float

    func makeNSView(context: Context) -> SoftPulseRingView {
        SoftPulseRingView()
    }

    func updateNSView(_ view: SoftPulseRingView, context: Context) {
        view.configure(SoftPulseRingView.Style(
            color: color, maxScale: maxScale, duration: duration, filled: filled, startOpacity: startOpacity))
    }

    static func dismantleNSView(_ view: SoftPulseRingView, coordinator: ()) {
        view.stop()
    }
}

final class SoftPulseRingView: NSView {
    struct Style: Equatable {
        var color: NSColor
        var maxScale: CGFloat
        var duration: CFTimeInterval
        var filled: Bool
        var startOpacity: Float
    }

    static let animationKey = "whisperm8.softPulse"
    /// Obergrenze der Bildrate (siehe Typ-Kommentar).
    static let frameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)

    private let ring = CAShapeLayer()
    private var style: Style?
    private var occlusionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ newStyle: Style) {
        guard newStyle != style else { return }
        style = newStyle
        needsLayout = true
        restartIfPossible()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // bounds + position statt frame: `frame` ist bei skalierter Ebene
        // undefiniert, der Halo saß sonst neben dem Punkt.
        ring.bounds = CGRect(origin: .zero, size: bounds.size)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: bounds.size).insetBy(dx: 0.8, dy: 0.8), transform: nil)
        if let style {
            ring.fillColor = style.filled ? style.color.cgColor : nil
            ring.strokeColor = style.filled ? nil : style.color.cgColor
            ring.lineWidth = style.filled ? 0 : 1.6
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { stop(); return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfPossible() }
        }
        restartIfPossible()
    }

    /// Pur: soll die Animation gerade laufen?
    static func shouldAnimate(windowVisible: Bool, reduceMotion: Bool) -> Bool {
        windowVisible && !reduceMotion
    }

    private func restartIfPossible() {
        guard let style else { return }
        let visible = window?.occlusionState.contains(.visible) == true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ring.removeAnimation(forKey: Self.animationKey)
        guard Self.shouldAnimate(windowVisible: visible, reduceMotion: reduceMotion) else {
            // Ruhebild wie im statischen Modus: Halo ohne Bewegung.
            ring.transform = CATransform3DMakeScale(1.7, 1.7, 1)
            ring.opacity = 0.35
            return
        }
        ring.add(Self.makeAnimation(style), forKey: Self.animationKey)
    }

    static func makeAnimation(_ style: Style) -> CAAnimation {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = style.maxScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = style.startOpacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = style.duration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.preferredFrameRateRange = frameRateRange
        return group
    }

    func stop() {
        ring.removeAllAnimations()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }
}
