import AppKit
import SwiftUI

enum OverlayStyle: String, CaseIterable {
    case full
    case mini

    var displayName: String {
        switch self {
        case .full:
            return "Full"
        case .mini:
            return "Mini"
        }
    }

    /// Panel-Größen der alten Bar (vor dem Pill-Neubau) — nur noch für die
    /// einmalige Migration der persistierten Position gebraucht.
    var legacyPanelSize: NSSize {
        switch self {
        case .full:
            return NSSize(width: 590, height: 56)
        case .mini:
            return NSSize(width: 220, height: 46)
        }
    }

    /// Erwartete Pill-Breite im Ruhezustand des Stils — nur für die
    /// Default-Zentrierung VOR dem ersten echten Layout; danach re-zentriert
    /// der Controller exakt anhand der gemessenen Breite.
    var estimatedPillWidth: CGFloat {
        switch self {
        case .full:
            return 470
        case .mini:
            return 210
        }
    }
}

// MARK: - Positions-Persistenz (Anker-Schema)

struct OverlayPositionStore {
    static let styleKey = "overlayStyle"
    /// Legacy-Keys der alten Bar (Panel-Origin) — werden einmalig migriert.
    static let xKey = "overlayPositionX"
    static let yKey = "overlayPositionY"
    /// Neues Schema: Kanten der SICHTBAREN Pill (siehe `PillAnchor`).
    static let anchorMaxXKey = "overlayAnchorMaxX"
    static let anchorMinXKey = "overlayAnchorMinX"
    static let anchorYKey = "overlayAnchorY"

    static func loadStyle() -> OverlayStyle {
        let raw = AppPreferences.shared.overlayStyleRaw
        return OverlayStyle(rawValue: raw) ?? .full
    }

    static func saveAnchor(_ anchor: PillAnchor) {
        AppPreferences.shared.set(anchor.maxX, for: anchorMaxXKey)
        AppPreferences.shared.set(anchor.minX, for: anchorMinXKey)
        AppPreferences.shared.set(anchor.y, for: anchorYKey)
    }

    static func clearPosition() {
        AppPreferences.shared.removeObject(for: xKey)
        AppPreferences.shared.removeObject(for: yKey)
        AppPreferences.shared.removeObject(for: anchorMaxXKey)
        AppPreferences.shared.removeObject(for: anchorMinXKey)
        AppPreferences.shared.removeObject(for: anchorYKey)
    }

    /// Lädt den Pill-Anker; migriert beim ersten Zugriff die alte
    /// Origin-Persistenz (Panel-Origin der 590/220er-Bar) ins Anker-Schema.
    /// Korrupte (non-finite) Anker-Keys werden bereinigt und der Legacy-Zweig
    /// bekommt trotzdem seine Chance — `nil` heißt verlässlich „keine
    /// Custom-Position".
    static func loadAnchor() -> PillAnchor? {
        if AppPreferences.shared.objectExists(for: anchorMaxXKey),
           AppPreferences.shared.objectExists(for: anchorYKey) {
            let maxX = AppPreferences.shared.double(for: anchorMaxXKey)
            let minX = AppPreferences.shared.double(for: anchorMinXKey)
            let y = AppPreferences.shared.double(for: anchorYKey)
            if maxX.isFinite, minX.isFinite, y.isFinite {
                return PillAnchor(maxX: maxX, minX: minX, y: y)
            }
            AppPreferences.shared.removeObject(for: anchorMaxXKey)
            AppPreferences.shared.removeObject(for: anchorMinXKey)
            AppPreferences.shared.removeObject(for: anchorYKey)
        }

        guard AppPreferences.shared.objectExists(for: xKey),
              AppPreferences.shared.objectExists(for: yKey) else {
            return nil
        }

        let x = AppPreferences.shared.double(for: xKey)
        let y = AppPreferences.shared.double(for: yKey)
        guard x.isFinite, y.isFinite else { return nil }

        let anchor = OverlayFrameResolver.migrateLegacyOrigin(
            NSPoint(x: x, y: y),
            legacyPanelSize: loadStyle().legacyPanelSize
        )
        saveAnchor(anchor)
        AppPreferences.shared.removeObject(for: xKey)
        AppPreferences.shared.removeObject(for: yKey)
        return anchor
    }

    static func defaultResolution(for style: OverlayStyle, on screen: NSScreen) -> OverlayFrameResolver.Resolution {
        let anchor = OverlayFrameResolver.defaultAnchor(
            estimatedPillWidth: style.estimatedPillWidth,
            visibleFrame: screen.visibleFrame
        )
        return OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: screen.visibleFrame)
    }

    static var activeScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    static func screenContaining(anchor: PillAnchor) -> NSScreen? {
        let rect = NSRect(
            x: anchor.minX,
            y: anchor.y,
            width: max(anchor.maxX - anchor.minX, 1),
            height: OverlayFrameResolver.pillHeight
        )
        return screenContainingRect(origin: rect.origin, size: rect.size)
    }

    /// Screen mit der GRÖSSTEN Überlappung — nicht der erste Treffer:
    /// straddlet die Pill beim Multi-Monitor-Drag die Grenze, würde der
    /// erste intersectende Screen sie sonst je nach Array-Reihenfolge
    /// entgegen der Drag-Richtung zurückklemmen.
    static func screenContainingRect(origin: NSPoint, size: NSSize) -> NSScreen? {
        let rect = NSRect(origin: origin, size: size)
        return NSScreen.screens
            .map { screen in (screen, screen.frame.intersection(rect)) }
            .filter { !$0.1.isEmpty }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0
    }
}

// MARK: - Panel

/// Das Overlay-Fenster: fixe Größe in ALLEN Zuständen — nur die SwiftUI-Pill
/// darin animiert ihre Breite (eine Animationsquelle, kein Fenster-Resize-Jank).
/// Geclampt wird die SICHTBARE Pill, nicht das Panel: der Schattenrand darf
/// über die Screen-Kante überstehen.
class RecordingPanel: NSPanel, NSWindowDelegate {
    /// Feuert nach jedem User-Drag mit dem neuen Pill-Anker.
    var onMoveAnchor: ((PillAnchor) -> Void)?
    /// Sichtbarer Pill-Frame in Panel-Koordinaten (AppKit, bottom-left);
    /// vom Controller aus dem SwiftUI-Layout gemeldet.
    var pillFrameInPanel: NSRect = .zero
    private var suppressMoveCallback = false

    init(initialOrigin: NSPoint) {
        super.init(
            contentRect: NSRect(origin: initialOrigin, size: OverlayFrameResolver.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.hasShadow = false  // Schatten zeichnet die SwiftUI-Pill selbst
        self.isOpaque = false
        self.delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Setzt den Frame ohne Move-Callback (programmatische Positionierung).
    func setOriginSilently(_ origin: NSPoint) {
        suppressMoveCallback = true
        setFrameOrigin(origin)
        suppressMoveCallback = false
    }

    /// Animierte Rückkehr (Doppelklick-Reset) — dieselbe Easing-Familie wie
    /// die SwiftUI-Breitenanimation der Pill.
    func animateOrigin(to origin: NSPoint, completion: (() -> Void)? = nil) {
        suppressMoveCallback = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            animator().setFrame(NSRect(origin: origin, size: frame.size), display: true)
        }, completionHandler: { [weak self] in
            self?.suppressMoveCallback = false
            completion?()
        })
    }

    func windowDidMove(_ notification: Notification) {
        guard !suppressMoveCallback else { return }
        guard pillFrameInPanel.width > 0 else { return }

        let pillOnScreen = pillFrameInPanel.offsetBy(dx: frame.origin.x, dy: frame.origin.y)
        guard let screen = OverlayPositionStore.screenContainingRect(
            origin: pillOnScreen.origin, size: pillOnScreen.size
        ) ?? OverlayPositionStore.activeScreen else {
            return
        }

        let clamped = OverlayFrameResolver.clampedPanelOrigin(
            panelOrigin: frame.origin,
            pillFrameInPanel: pillFrameInPanel,
            visibleFrame: screen.visibleFrame
        )
        if clamped != frame.origin {
            setOriginSilently(clamped)
        }

        onMoveAnchor?(OverlayFrameResolver.anchor(
            panelOrigin: frame.origin,
            pillFrameInPanel: pillFrameInPanel
        ))
    }
}

// MARK: - Hit-Test-Hosting-View

/// NSHostingView, das nur die sichtbare Pill interaktiv macht: Klicks auf die
/// transparente Restfläche des (fixen Maximal-)Panels liefern `nil` — zusammen
/// mit den Alpha-0-Pixeln reicht der Window-Server sie ans Fenster darunter
/// weiter, und `isMovableByWindowBackground` greift nur auf der Pill selbst.
/// Trägt außerdem das Hover-Tracking (`.activeAlways` — funktioniert im
/// non-activating Panel ohne Key-Status, anders als SwiftUIs `.onHover`).
final class PillHitTestHostingView<Content: View>: NSHostingView<Content> {
    /// Interaktiver Bereich im EIGENEN Koordinatensystem der View.
    private var interactiveFrame: NSRect = .zero {
        didSet {
            guard interactiveFrame != oldValue else { return }
            updateTrackingAreas()
        }
    }

    /// Nimmt den Pill-Frame im SwiftUI-System (top-left) entgegen und
    /// konvertiert ihn selbst anhand `isFlipped` — hitTest und TrackingArea
    /// hängen so an keiner Annahme über NSHostingViews Flip-Verhalten.
    func setInteractive(swiftUIFrame: CGRect) {
        if isFlipped {
            interactiveFrame = swiftUIFrame
        } else {
            interactiveFrame = NSRect(
                x: swiftUIFrame.minX,
                y: bounds.height - swiftUIFrame.maxY,
                width: swiftUIFrame.width,
                height: swiftUIFrame.height
            )
        }
    }
    var onHoverChange: ((Bool) -> Void)?
    /// Doppelklick auf freie Pill-Fläche → Rückkehr zur Default-Position.
    /// Hier (nicht im Panel) abgefangen: NSHostingView ist der Event-Einstieg
    /// für SwiftUI — Buttons/Menüs konsumieren ihren ersten Klick selbst und
    /// erreichen diesen Pfad praktisch nie mit clickCount == 2.
    var onDoubleClick: (() -> Void)?

    private var hoverArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveFrame.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        guard interactiveFrame.width > 0 else {
            hoverArea = nil
            return
        }
        let area = NSTrackingArea(
            rect: interactiveFrame,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

// MARK: - Tick-isolierte Modelle

/// Nur der Waveform-Kern observiert das Audio-Level — der 10-Hz-Tick
/// invalidiert damit nicht die restliche Pill (Tick-Diät).
@MainActor
final class OverlayLevelModel: ObservableObject {
    @Published var level: Float = 0
}

/// Der Timer-Text publisht nur bei echtem Sekundenwechsel (1 Hz statt 10 Hz).
@MainActor
final class OverlayClockModel: ObservableObject {
    @Published var timeText: String = "00:00"

    func update(duration: TimeInterval) {
        let text = OverlayClockFormatter.format(duration)
        if text != timeText {
            timeText = text
        }
    }
}

// MARK: - Overlay Controller

/// Granulare Bearbeitungs-Aktion auf dem laufenden Recording-Kontext-Bundle.
/// Wird vom Overlay-Menu ausgelöst und vom RecordingCoordinator in die einzelnen
/// Bundle-Slots übersetzt.
enum ContextAction {
    case removeAgentChat
    case removeSelectedText
    case removeAttachment(id: UUID)
}

@MainActor
class OverlayController: ObservableObject {
    private var panel: RecordingPanel?
    private var hostingView: PillHitTestHostingView<RecordingOverlayView>?
    private var previousApp: NSRunningApplication?
    private var modesObserver: NSObjectProtocol?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var hoverCollapseWork: DispatchWorkItem?
    private var recenterWork: DispatchWorkItem?
    private var onCancel: (() -> Void)?
    private var onCancelTranscription: (() -> Void)?
    private var onCancelPostProcessing: (() -> Void)?
    /// ✓-Button: Aufnahme beenden & transkribieren — derselbe Pfad wie der Hotkey-Stop.
    private var onStopAndTranscribe: (() -> Void)?
    private var onOutputModeChange: ((OutputMode) -> Void)?
    private var onAddScreenshot: (() -> Void)?
    private var onCaptureScreenshot: (() -> Void)?
    private var onToggleScreenClip: (() -> Void)?
    private var onClearContext: (() -> Void)?
    /// Vereinte Schiene für granulare Kontext-Bearbeitung pro Item.
    private var onContextAction: ((ContextAction) -> Void)?

    /// Tick-isoliert: Kern-Bars und Timer haben eigene Modelle (siehe oben).
    let levelModel = OverlayLevelModel()
    let clockModel = OverlayClockModel()

    @Published var isTranscribing: Bool = false
    @Published var isPostProcessing: Bool = false
    @Published var overlayStyle: OverlayStyle = .full
    @Published var selectedOutputMode: OutputMode = OutputMode.defaultMode()
    @Published var outputModes: [OutputMode] = OutputMode.availableBuiltInModes()
    @Published var showModePickerInMiniOverlay: Bool = true
    @Published var showConfirmButton: Bool = true
    @Published var selectedContext: SelectedContext = .empty
    @Published var contextBundle: TranscriptContextBundle = .empty
    @Published var isScreenClipRecording: Bool = false
    @Published var postProcessingStatusText: String?
    /// Wachstumsrichtung der Pill im Panel (Rechts-Anker bzw. Spiegel-Fall).
    @Published var pillAlignment: PillAlignment = .trailing
    /// Mini-Stil: Hover (mit Grace-Period) expandiert zur vollen Pill.
    @Published var isHoverExpanded: Bool = false

    /// Hat der User die Pill je bewegt? Ohne Custom-Position folgt der
    /// Default dem aktiven Screen und wird nach dem ersten Layout exakt
    /// zentriert (statt die Schätzbreite einzufrieren).
    private var hasCustomPosition = false
    private var didPreciseCenter = false
    private var isResettingPosition = false
    /// Offene PILL-Menüs (Mode/Kontext) halten die Mini-Pill expandiert.
    /// Nur Menüs, deren Tracking mit der Maus über der Pill begann — die
    /// Notifications sind app-global und würden sonst jedes Menübar-/
    /// Agent-Chats-Menü mitzählen.
    private var trackedPillMenus = Set<ObjectIdentifier>()
    /// Letzte Button-/Menü-Aktion an der Pill: Ein schneller Doppelklick auf
    /// ✓/Kamera landet mit clickCount == 2 auf inzwischen „freier" Fläche —
    /// der Positions-Reset darf dann NICHT feuern.
    private var lastPillActionAt = Date.distantPast

    var phase: OverlayPhase {
        OverlayPhase.resolve(isTranscribing: isTranscribing, isPostProcessing: isPostProcessing)
    }

    func show(
        appState: AppState,
        onCancel: @escaping () -> Void,
        onCancelTranscription: @escaping () -> Void,
        onCancelPostProcessing: @escaping () -> Void,
        onStopAndTranscribe: @escaping () -> Void,
        onOutputModeChange: @escaping (OutputMode) -> Void,
        onAddScreenshot: @escaping () -> Void,
        onCaptureScreenshot: @escaping () -> Void,
        onToggleScreenClip: @escaping () -> Void,
        onClearContext: @escaping () -> Void,
        onContextAction: @escaping (ContextAction) -> Void
    ) {
        // Capture the frontmost app BEFORE showing our panel
        previousApp = NSWorkspace.shared.frontmostApplication
        Logger.focus.info("Captured previousApp: \(self.previousApp?.localizedName ?? "nil", privacy: .public)")

        hide()  // Cleanup any existing panel first
        self.onCancel = onCancel
        self.onCancelTranscription = onCancelTranscription
        self.onCancelPostProcessing = onCancelPostProcessing
        self.onStopAndTranscribe = onStopAndTranscribe
        self.onOutputModeChange = onOutputModeChange
        self.onAddScreenshot = onAddScreenshot
        self.onCaptureScreenshot = onCaptureScreenshot
        self.onToggleScreenClip = onToggleScreenClip
        self.onClearContext = onClearContext
        self.onContextAction = onContextAction

        // Initialize state from appState
        self.levelModel.level = appState.audioLevel
        self.clockModel.update(duration: appState.recordingDuration)
        self.isTranscribing = appState.isTranscribing
        self.isPostProcessing = appState.isPostProcessing
        self.selectedOutputMode = appState.selectedOutputMode
        self.outputModes = OutputMode.availableBuiltInModes()
        self.showModePickerInMiniOverlay = AppPreferences.shared.showModePickerInMiniOverlay
        self.showConfirmButton = AppPreferences.shared.showConfirmButtonInOverlay
        self.selectedContext = appState.selectedContext
        self.contextBundle = appState.contextBundle
        self.isScreenClipRecording = appState.isScreenClipRecording
        self.postProcessingStatusText = appState.postProcessingStatusText
        self.overlayStyle = OverlayPositionStore.loadStyle()
        self.isHoverExpanded = false
        self.didPreciseCenter = false
        self.isResettingPosition = false
        self.trackedPillMenus = []
        self.lastPillActionAt = .distantPast

        // Anker laden entscheidet zugleich über „Custom-Position": nur eine
        // valide gespeicherte Position zählt (loadAnchor bereinigt Korruptes).
        let storedAnchor = OverlayPositionStore.loadAnchor()
        self.hasCustomPosition = storedAnchor != nil

        let resolution: OverlayFrameResolver.Resolution
        if let storedAnchor,
           let screen = OverlayPositionStore.screenContaining(anchor: storedAnchor)
               ?? OverlayPositionStore.activeScreen {
            resolution = OverlayFrameResolver.resolve(anchor: storedAnchor, visibleFrame: screen.visibleFrame)
        } else if let screen = OverlayPositionStore.activeScreen {
            resolution = OverlayPositionStore.defaultResolution(for: overlayStyle, on: screen)
        } else {
            resolution = OverlayFrameResolver.Resolution(panelOrigin: .zero, alignment: .trailing)
        }
        self.pillAlignment = resolution.alignment

        let panel = RecordingPanel(initialOrigin: resolution.panelOrigin)
        panel.onMoveAnchor = { [weak self] anchor in
            guard let self, !self.isResettingPosition else { return }
            self.hasCustomPosition = true
            OverlayPositionStore.saveAnchor(anchor)
        }

        // Create view with bindings (ONCE) - view will update via bindings
        let view = RecordingOverlayView(controller: self)

        let hostingView = PillHitTestHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: OverlayFrameResolver.panelSize)
        hostingView.onHoverChange = { [weak self] hovering in
            self?.setHovering(hovering)
        }
        hostingView.onDoubleClick = { [weak self] in
            self?.resetToDefaultPosition()
        }

        // Configure hosting view for full transparency
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // Die Pill ist IMMER dunkel (fast schwarz, wie Agent-Chats im Dark
        // Mode) — unabhängig vom System-Theme: helle Schrift auf dunklem Glas
        // ist auf jedem Wallpaper am besten lesbar. Erzwungenes darkAqua
        // schaltet Material, .primary/.secondary und die OverlayPalette
        // konsistent auf ihre Dark-Varianten.
        hostingView.appearance = NSAppearance(named: .darkAqua)

        // Referenzen VOR contentView/orderFront setzen — der erste
        // Geometry-Report aus SwiftUI darf nicht an nil-Guards verpuffen.
        self.panel = panel
        self.hostingView = hostingView
        panel.contentView = hostingView
        panel.orderFront(nil)

        // Event-getriebener Mode-Reload statt Tick-Polling. show() ruft oben
        // hide() auf, das den alten Observer entfernt — re-entrantes show()
        // (z. B. Transkriptions-Retry) registriert also nie doppelt.
        modesObserver = NotificationCenter.default.addObserver(
            forName: OutputModeStore.modesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.outputModes = OutputMode.availableBuiltInModes()
            }
        }

        // Offene SwiftUI-Menüs (Mode/Kontext) melden sich nicht selbst —
        // NSMenu-Tracking-Notifications halten die Mini-Pill solange offen.
        // Die Notifications sind app-global: gezählt wird nur, was mit der
        // Maus ÜBER der Pill aufging (Menübar & Co. bleiben außen vor).
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                MainActor.assumeIsolated {
                    guard let self, self.isMouseOverPill() else { return }
                    self.trackedPillMenus.insert(ObjectIdentifier(menu))
                }
            },
            center.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.trackedPillMenus.remove(ObjectIdentifier(menu)) != nil else { return }
                    self.notePillAction()
                    if self.trackedPillMenus.isEmpty {
                        // Menü zu: kollabieren, falls die Maus die Pill
                        // inzwischen verlassen hat.
                        self.scheduleHoverCollapse()
                    }
                }
            },
        ]
    }

    func hide() {
        if let modesObserver {
            NotificationCenter.default.removeObserver(modesObserver)
            self.modesObserver = nil
        }
        for observer in menuTrackingObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuTrackingObservers = []
        hoverCollapseWork?.cancel()
        hoverCollapseWork = nil
        recenterWork?.cancel()
        recenterWork = nil
        // Default-Position bleibt Default: gespeichert wird nur, was der
        // User selbst bewegt hat (onMoveAnchor persistiert live).
        panel?.close()
        panel = nil
        hostingView = nil
        onCancel = nil
        onCancelTranscription = nil
        onCancelPostProcessing = nil
        onStopAndTranscribe = nil
        onOutputModeChange = nil
        onAddScreenshot = nil
        onCaptureScreenshot = nil
        onToggleScreenClip = nil
        onClearContext = nil
        onContextAction = nil
    }

    func getPreviousApp() -> NSRunningApplication? {
        return previousApp
    }

    func cancelRecording() {
        notePillAction()
        onCancel?()
    }

    func cancelTranscription() {
        notePillAction()
        onCancelTranscription?()
    }

    func cancelPostProcessing() {
        notePillAction()
        onCancelPostProcessing?()
    }

    /// ✓: Aufnahme beenden & transkribieren (nur in der Recording-Phase sichtbar).
    func stopAndTranscribe() {
        notePillAction()
        onStopAndTranscribe?()
    }

    func setOutputMode(_ mode: OutputMode) {
        notePillAction()
        selectedOutputMode = mode
        onOutputModeChange?(mode)
    }

    func addScreenshot() {
        notePillAction()
        onAddScreenshot?()
    }

    func captureScreenshot() {
        notePillAction()
        onCaptureScreenshot?()
    }

    func toggleScreenClip() {
        notePillAction()
        onToggleScreenClip?()
    }

    func clearContext() {
        notePillAction()
        onClearContext?()
    }

    func performContextAction(_ action: ContextAction) {
        notePillAction()
        onContextAction?(action)
    }

    /// Merkt Button-/Menü-Interaktionen an der Pill — der Doppelklick-Reset
    /// hält danach kurz still (schneller Doppelklick auf ✓/Kamera trifft
    /// sonst mit dem zweiten Klick „freie" Fläche).
    private func notePillAction() {
        lastPillActionAt = Date()
    }

    func update(appState: AppState) {
        // Only update properties - view stays the same, SwiftUI handles animations.
        //
        // Tick-Diät: update() läuft im 100-ms-Timer. Die volatilen Felder
        // fließen in eigene, klein observierte Modelle (Kern-Bars 10 Hz,
        // Timer-String 1 Hz); alles andere published nur bei echter Änderung,
        // damit der Tick keinen objectWillChange-Churn in der Pill erzeugt.
        levelModel.level = appState.audioLevel
        clockModel.update(duration: appState.recordingDuration)
        setIfChanged(\.isTranscribing, to: appState.isTranscribing)
        setIfChanged(\.isPostProcessing, to: appState.isPostProcessing)
        setIfChanged(\.selectedOutputMode, to: appState.selectedOutputMode)
        setIfChanged(\.outputModes, to: OutputMode.availableBuiltInModes())
        setIfChanged(\.showModePickerInMiniOverlay, to: AppPreferences.shared.showModePickerInMiniOverlay)
        setIfChanged(\.showConfirmButton, to: AppPreferences.shared.showConfirmButtonInOverlay)
        setIfChanged(\.selectedContext, to: appState.selectedContext)
        setIfChanged(\.contextBundle, to: appState.contextBundle)
        setIfChanged(\.isScreenClipRecording, to: appState.isScreenClipRecording)
        setIfChanged(\.postProcessingStatusText, to: appState.postProcessingStatusText)
        setIfChanged(\.overlayStyle, to: OverlayPositionStore.loadStyle())
    }

    // MARK: - Pill-Geometrie (aus dem SwiftUI-Layout gemeldet)

    /// SwiftUI meldet den sichtbaren Pill-Frame (Koordinaten des Hosting-Views,
    /// top-left origin) — hier wird er in AppKit-Koordinaten gedreht und an
    /// hitTest/Tracking/Clamp/Persistenz verteilt.
    func reportPillFrame(_ swiftUIFrame: CGRect) {
        guard let panel, let hostingView else { return }
        guard swiftUIFrame.width > 0, swiftUIFrame.height > 0 else { return }

        // Fenster-Koordinaten sind immer bottom-left; die Hosting-View
        // konvertiert für hitTest/Tracking selbst anhand ihres isFlipped.
        let panelHeight = OverlayFrameResolver.panelSize.height
        let appKitFrame = NSRect(
            x: swiftUIFrame.minX,
            y: panelHeight - swiftUIFrame.maxY,
            width: swiftUIFrame.width,
            height: swiftUIFrame.height
        )

        hostingView.setInteractive(swiftUIFrame: swiftUIFrame)
        panel.pillFrameInPanel = appKitFrame

        // Ohne Custom-Position: nach dem ersten ECHTEN Layout einmalig exakt
        // zentrieren (die Default-Position basierte auf einer Schätzbreite).
        // Läuft vor dem ersten sichtbaren Frame — kein wahrnehmbarer Sprung.
        if !hasCustomPosition, !didPreciseCenter,
           let screen = panel.screen ?? OverlayPositionStore.activeScreen {
            didPreciseCenter = true
            let anchor = OverlayFrameResolver.defaultAnchor(
                estimatedPillWidth: appKitFrame.width,
                visibleFrame: screen.visibleFrame
            )
            let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: screen.visibleFrame)
            pillAlignment = resolution.alignment
            panel.setOriginSilently(resolution.panelOrigin)
            return
        }

        // Breitenänderungen OHNE Fenster-Move (Hover-Expand an der Kante,
        // langes Codex-Label, Live-Style-Wechsel) müssen selbst re-clampen —
        // windowDidMove sieht sie nicht.
        if !isResettingPosition,
           let screen = panel.screen ?? OverlayPositionStore.activeScreen {
            let clamped = OverlayFrameResolver.clampedPanelOrigin(
                panelOrigin: panel.frame.origin,
                pillFrameInPanel: appKitFrame,
                visibleFrame: screen.visibleFrame
            )
            if clamped != panel.frame.origin {
                panel.setOriginSilently(clamped)
            }
        }

        // Die Default-Position hält sich selbst zentriert (debounced,
        // animiert, nie während Hover) — z. B. nach Doppelklick-Reset mit
        // expandierter Breite oder wenn der Kontext-Chip erscheint.
        if !hasCustomPosition {
            scheduleDefaultRecenter()
        }
    }

    /// Sanftes Nachzentrieren an der Default-Position, sobald die Pill-Breite
    /// 0,3 s stabil ist. Nie während Hover-Expand — dort gilt die
    /// Rechts-Anker-Regel (✓/✕ bleiben unter dem Cursor stehen).
    private func scheduleDefaultRecenter() {
        recenterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            guard !self.hasCustomPosition, !self.isHoverExpanded, !self.isResettingPosition else { return }
            // Nie unter dem Cursor wegrutschen — auch im Full-Stil nicht.
            guard !self.isMouseOverPill() else { return }
            guard let screen = panel.screen ?? OverlayPositionStore.activeScreen else { return }
            let width = panel.pillFrameInPanel.width
            guard width > 0 else { return }

            let anchor = OverlayFrameResolver.defaultAnchor(
                estimatedPillWidth: width,
                visibleFrame: screen.visibleFrame
            )
            let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: screen.visibleFrame)
            let current = panel.frame.origin
            guard abs(resolution.panelOrigin.x - current.x) > 1
                || abs(resolution.panelOrigin.y - current.y) > 1 else { return }

            self.pillAlignment = resolution.alignment
            panel.animateOrigin(to: resolution.panelOrigin)
        }
        recenterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Hover (Mini-Stil)

    private func setHovering(_ hovering: Bool) {
        if hovering {
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
            if !isHoverExpanded {
                isHoverExpanded = true
            }
            return
        }
        scheduleHoverCollapse()
    }

    /// Collapse mit Grace-Period gegen Flackern an der Pill-Kante; kollabiert
    /// nie unter einem offenen Menü und verifiziert die Mausposition, weil
    /// Tracking-Areas während der Breitenanimation neu aufgebaut werden.
    private func scheduleHoverCollapse() {
        hoverCollapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.trackedPillMenus.isEmpty else { return }
            if self.isMouseOverPill() { return }
            self.isHoverExpanded = false
        }
        hoverCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func isMouseOverPill() -> Bool {
        guard let panel else { return false }
        let pillOnScreen = panel.pillFrameInPanel.offsetBy(
            dx: panel.frame.origin.x, dy: panel.frame.origin.y
        )
        return pillOnScreen.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: - Doppelklick-Reset

    /// Animiert die Pill zurück zur Default-Position (unten mittig auf dem
    /// aktuellen Screen) und löscht die gespeicherte Custom-Position.
    func resetToDefaultPosition() {
        guard let panel, !isResettingPosition else { return }
        // Doppelklick-Schutz: Kam gerade eine Button-/Menü-Aktion von der
        // Pill, ist dieser clickCount == 2 der Nachklapp eines schnellen
        // Doppelklicks auf ein Control (✓ verschwindet nach Klick 1!) —
        // die Pill darf dann nicht quer über den Screen springen.
        guard Date().timeIntervalSince(lastPillActionAt) > 0.6 else { return }
        guard let screen = panel.screen ?? OverlayPositionStore.activeScreen else { return }

        OverlayPositionStore.clearPosition()
        hasCustomPosition = false

        let pillWidth = panel.pillFrameInPanel.width
        let anchor = OverlayFrameResolver.defaultAnchor(
            estimatedPillWidth: pillWidth > 0 ? pillWidth : overlayStyle.estimatedPillWidth,
            visibleFrame: screen.visibleFrame
        )
        let resolution = OverlayFrameResolver.resolve(anchor: anchor, visibleFrame: screen.visibleFrame)

        isResettingPosition = true
        pillAlignment = resolution.alignment
        panel.animateOrigin(to: resolution.panelOrigin) { [weak self] in
            self?.isResettingPosition = false
        }
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<OverlayController, Value>,
        to newValue: Value
    ) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }
}
