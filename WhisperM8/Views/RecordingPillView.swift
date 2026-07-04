import SwiftUI

// MARK: - Metriken

/// Zentrale Maße der Pill — Höhe und Kern sind in ALLEN Zuständen identisch,
/// es animiert ausschließlich die Breite (eine Easing-Kurve, s. `pillAnimation`).
enum PillMetrics {
    static let height: CGFloat = 40
    static let horizontalPadding: CGFloat = 6
    static let coreHeight: CGFloat = 28
    static let coreMinWidth: CGFloat = 46
    static let chipHeight: CGFloat = 26
    static let iconButtonSize: CGFloat = 26
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2.5
}

/// Die eine Easing-Kurve der Pill (≈ cubic-bezier(.32,.72,0,1), Apple-artig).
extension Animation {
    static let pill = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.35)
}

// MARK: - Pill

/// Die Recording-Pill: die Waveform IST der Status (Atmen = Aufnahme,
/// Scan-Lauflicht = Transkription, Puls = Codex-Improve). Kein dauerhaftes
/// „Recording…"-Label. Im Mini-Stil kollabiert alles außer Kern, Timer,
/// optional Mode-Chip, vorhandenem Kontext und ✓/✕ — Hover expandiert.
struct RecordingPillView: View {
    @ObservedObject var controller: OverlayController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: OverlayPhase { controller.phase }

    /// Voll-Stil ist permanent expandiert; Mini expandiert per Hover
    /// (Grace-Period und Menü-Halt regelt der Controller).
    private var isExpanded: Bool {
        controller.overlayStyle == .full || controller.isHoverExpanded
    }

    private var isFullStyle: Bool { controller.overlayStyle == .full }

    var body: some View {
        // Zwei Anordnungen, ein Prinzip:
        // - Full (permanent expandiert): klassische Anatomie, Kern links außen.
        // - Mini: ALLE Hover-Zusätze (Grip/Kamera/Clip) klappen LINKS außen
        //   auf; der kollabierte Block ist rechts verankert und in beiden
        //   Zuständen identisch — nichts rutscht beim Expandieren unter der
        //   Maus weg (z. B. der Mode-Chip, den man gerade anklicken wollte).
        HStack(spacing: 0) {
            if isFullStyle {
                fullLayout
            } else {
                miniLayout
            }

            if phase == .recording && controller.showConfirmButton {
                PillConfirmButton(action: controller.stopAndTranscribe)
                    .transition(.opacity)
            }

            PillCancelButton(phase: phase, controller: controller)
        }
        .padding(.horizontal, PillMetrics.horizontalPadding)
        .frame(height: PillMetrics.height)
        .background {
            // Dunkles Glas wie im Prototyp (rgba(19,22,27,.86)): Material
            // liefert den Blur, die Tönung drückt es Richtung Fast-Schwarz.
            Capsule()
                .fill(.thinMaterial)
                .overlay(Capsule().fill(OverlayPalette.glassTint))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
        }
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 3)
        .animation(reduceMotion ? nil : .pill, value: isExpanded)
        .animation(reduceMotion ? nil : .pill, value: phase)
        .animation(reduceMotion ? nil : .pill, value: controller.contextBundle.isEmpty)
        .animation(reduceMotion ? nil : .pill, value: controller.isScreenClipRecording)
        .animation(reduceMotion ? nil : .pill, value: controller.showModePickerInMiniOverlay)
        .animation(reduceMotion ? nil : .pill, value: controller.showConfirmButton)
        .animation(reduceMotion ? nil : .pill, value: controller.overlayStyle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(phase.accessibilityLabel)
    }

    // Bewusst KEIN Status-Text neben dem Kern (auch nicht bei
    // Transcribing/Improving): abgeschnittene Labels und der Breiten-Tanz
    // beim Phasenwechsel stören mehr, als der Text nützt — die Bewegungsart
    // + Farbe des Kerns trägt den Zustand, der Tooltip die Details.
    private var coreView: some View {
        PillCoreView(
            levelModel: controller.levelModel,
            phase: phase,
            isClipping: controller.isScreenClipRecording,
            reduceMotion: reduceMotion
        )
        .help(phase.statusLabel(postProcessingStatusText: controller.postProcessingStatusText) ?? "Recording")
    }

    private var modeChip: some View {
        PillOutputModeChip(
            modes: controller.outputModes,
            selectedMode: controller.selectedOutputMode,
            isDisabled: phase.isBusy,
            action: controller.setOutputMode
        )
    }

    /// Full: klassische Anatomie, permanent expandiert.
    @ViewBuilder
    private var fullLayout: some View {
        PillGrip()

        coreView

        PillClockView(clockModel: controller.clockModel)

        modeChip
            .padding(.trailing, 5)

        PillContextChip(controller: controller)
            .padding(.trailing, 5)

        PillVisualContextButtons(controller: controller)

        PillSeparator()
    }

    /// Mini: Der kollabierte Block [Kern·Timer·Mode·Ctx·✓·✕] ist rechts
    /// verankert und in beiden Zuständen identisch — die Hover-Zusätze
    /// (Grip, Kamera, Clip) klappen ausschließlich LINKS außen auf. Dadurch
    /// steht jedes bereits sichtbare Element beim Expandieren pixelgenau
    /// still (kein Wegrutschen des Mode-Chips unter der Maus).
    @ViewBuilder
    private var miniLayout: some View {
        if isExpanded {
            PillGrip()
                .transition(.opacity)
            PillCameraButton(controller: controller)
                .transition(.opacity)
        }

        // Läuft ein Screen-Clip, bleibt das Stop-Icon auch kollabiert
        // erreichbar — sonst müsste man zum Stoppen erst hovern.
        if isExpanded || controller.isScreenClipRecording {
            PillScreenClipButton(controller: controller)
                .padding(.trailing, 2)
                .transition(.opacity)
        }

        coreView
            .padding(.leading, isExpanded ? 0 : 2)

        // Timer ist in Mini IMMER sichtbar (auch busy): kompakteste Info,
        // und er hält den Block über alle Zustände formstabil.
        PillClockView(clockModel: controller.clockModel)

        // Pref an: Chip permanent (busy disabled) — stabil. Pref aus: nur
        // im Hover; er ERSCHEINT dann links neben ✓/✕, nichts rutscht weg.
        if controller.showModePickerInMiniOverlay || isExpanded {
            modeChip
                .padding(.trailing, 5)
                .transition(.opacity)
        }

        // Kontext ist Inhalt, keine Deko: mit Inhalt in BEIDEN Zuständen
        // sichtbar (formstabil). Der leere „No Ctx"-Chip entfällt in Mini —
        // er würde beim Expandieren den Mode-Chip verschieben.
        if !controller.contextBundle.isEmpty {
            PillContextChip(controller: controller)
                .padding(.trailing, 5)
                .transition(.opacity)
        }
    }
}

// MARK: - Grip

/// Drag-Affordanz — die GANZE Pill zieht (isMovableByWindowBackground),
/// der Grip macht es nur sichtbar. Doppelklick auf freie Fläche = Reset.
private struct PillGrip: View {
    var body: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(0.28))
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .frame(height: PillMetrics.height)
        .contentShape(Rectangle())
        .help("Ziehen zum Verschieben · Doppelklick: Standardposition")
        .accessibilityHidden(true)
    }
}

// MARK: - Kern (Waveform = Status)

/// Der Kern: 5 Level-Bars in einer Kapsel. Bewegungsart und Farbe codieren
/// die Phase; der rote Ring markiert einen laufenden Screen-Clip.
/// Tick-Isolation: NUR diese View observiert das 10-Hz-Audio-Level; die
/// Animationen laufen über eine lokale TimelineView mit 30 fps.
struct PillCoreView: View {
    @ObservedObject var levelModel: OverlayLevelModel
    let phase: OverlayPhase
    let isClipping: Bool
    let reduceMotion: Bool

    private var tint: Color { OverlayPalette.tint(for: phase) }

    var body: some View {
        Group {
            if phase == .recording {
                // Aufnahme: KEINE Eigenbewegung — die Bars folgen ausschließlich
                // dem echten Audio-Level (Stille = ruhige flache Linie). Deko-
                // Atmen würde das Kern-Konzept „Bewegung = Signal" kaputtmachen.
                bars { index, _ in recordingBarState(index: index) }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: levelModel.level)
            } else if reduceMotion {
                // Statische Silhouette — bleibt ohne Bewegung lesbar.
                bars { index, _ in staticBarState(index: index) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    bars { index, _ in barState(index: index, time: t) }
                }
            }
        }
        .frame(minWidth: PillMetrics.coreMinWidth)
        .frame(height: PillMetrics.coreHeight)
        .background {
            Capsule().fill(tint.opacity(0.16))
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 1)
        }
        .overlay {
            // Screen-Clip aktiv: roter Ring um den Kern.
            if isClipping {
                Capsule()
                    .strokeBorder(OverlayPalette.clip.opacity(0.55), lineWidth: 1)
                Capsule()
                    .stroke(OverlayPalette.clip.opacity(0.18), lineWidth: 3)
                    .padding(-2.5)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isClipping)
        .accessibilityLabel(phase.accessibilityLabel)
    }

    private struct BarState {
        var height: CGFloat
        var opacity: Double
        /// Pegel-Ampel im Recording (grau/Mint/Amber); nil = Phasen-Tint.
        var color: Color?

        init(height: CGFloat, opacity: Double, color: Color? = nil) {
            self.height = height
            self.opacity = opacity
            self.color = color
        }
    }

    private func bars(state: @escaping (Int, Int) -> BarState) -> some View {
        HStack(spacing: PillMetrics.barSpacing) {
            ForEach(0..<5, id: \.self) { index in
                let bar = state(index, 5)
                Capsule()
                    .fill(bar.color ?? tint)
                    .frame(width: PillMetrics.barWidth, height: bar.height)
                    .opacity(bar.opacity)
            }
        }
        .padding(.horizontal, 10)
    }

    private func barState(index: Int, time: TimeInterval) -> BarState {
        switch phase {
        case .recording:
            return recordingBarState(index: index)
        case .transcribing:
            return transcribingBarState(index: index, time: time)
        case .improving:
            return improvingBarState(index: index, time: time)
        }
    }

    /// Aufnahme: rein level-getrieben, mit der Dynamik + Pegel-Ampel der
    /// alten Bar (vor dem Pill-Neubau) — dünne graue Ruhelinie bei Stille,
    /// voller Hub bis 20 px in der Kapsel, Mint bei normalem Sprechen,
    /// Amber als Zu-laut-Warnung. Beantwortet „spreche ich? zu leise?"
    /// auf einen Blick (Farbe), nicht erst über die Höhen.
    private func recordingBarState(index: Int) -> BarState {
        // Steilere Kurve als früher (0.5 statt 0.6): leise Sprache wird
        // früher sichtbar, Sättigung bleibt bei 1.
        let eased = pow(CGFloat(max(0, min(levelModel.level, 1))), 0.5)
        let boosts: [CGFloat] = [0.75, 0.95, 1.1, 0.95, 0.75]  // Mitte betont
        let maxHeights: [CGFloat] = [13, 17, 20, 17, 13]
        let intensity = min(1, eased * boosts[index])

        let base: CGFloat = 3
        let height = base + (maxHeights[index] - base) * intensity

        // Pegel-Ampel wie in der alten AudioLevelBars: grau = kein Signal.
        if intensity < 0.08 {
            return BarState(height: height, opacity: 1, color: Color.primary.opacity(0.28))
        }
        if intensity > 0.72 {
            return BarState(height: height, opacity: 0.95, color: OverlayPalette.levelLoud)
        }
        return BarState(height: height, opacity: 0.6 + 0.4 * Double(intensity))
    }

    /// Transkription: Scan-Lauflicht (Höhe konstant, Helligkeit wandert).
    private func transcribingBarState(index: Int, time: TimeInterval) -> BarState {
        let period = 1.0
        let raw = (time - Double(index) * 0.12).truncatingRemainder(dividingBy: period) / period
        let progress = raw < 0 ? raw + 1 : raw
        // Schmale Spitze bei 18 % der Periode (wie das CSS-Lauflicht).
        let peak = max(0, 1 - abs(progress - 0.18) / 0.18)
        return BarState(height: 10, opacity: 0.3 + 0.7 * peak)
    }

    /// Improve: sanftes gemeinsames Pulsieren, gerade/ungerade in Gegenphase.
    private func improvingBarState(index: Int, time: TimeInterval) -> BarState {
        let offset = index.isMultiple(of: 2) ? 0.5 : 0.0
        let pulse = (sin((time / 1.7 + offset) * 2 * .pi) + 1) / 2  // 0…1
        return BarState(height: 7 + CGFloat(pulse) * 5, opacity: 0.45 + 0.55 * pulse)
    }

    private func staticBarState(index: Int) -> BarState {
        switch phase {
        case .recording:
            // Nicht erreichbar (Recording ist immer level-getrieben) —
            // konsistent zur Ruhelinie, falls sich die Verzweigung ändert.
            return BarState(height: 3, opacity: 1, color: Color.primary.opacity(0.28))
        case .transcribing:
            return BarState(height: 10, opacity: 1)
        case .improving:
            return BarState(height: 9, opacity: 1)
        }
    }
}

// MARK: - Timer

/// Eigene View, damit der 1-Hz-Timer-String nur diesen Text invalidiert.
private struct PillClockView: View {
    @ObservedObject var clockModel: OverlayClockModel

    var body: some View {
        Text(clockModel.timeText)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .accessibilityLabel("Recording duration \(clockModel.timeText)")
    }
}

// MARK: - Mode-Chip

private struct PillOutputModeChip: View {
    let modes: [OutputMode]
    let selectedMode: OutputMode
    let isDisabled: Bool
    let action: (OutputMode) -> Void

    var body: some View {
        Menu {
            ForEach(modes) { mode in
                Button {
                    action(mode)
                } label: {
                    if mode.id == selectedMode.id {
                        Label(mode.name, systemImage: "checkmark")
                    } else {
                        Text(mode.name)
                    }
                }
                .disabled(!mode.isEnabled)
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedMode.shortLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(isDisabled ? Color.secondary.opacity(0.7) : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: PillMetrics.chipHeight)
            // Bewusst KEIN .frame(min/maxWidth:): der würde auf das Angebot
            // expandieren statt auf Inhaltsbreite — der Chip wäre immer
            // maximal breit. Text nimmt seine ideale Breite; bei echtem
            // Platzmangel truncated lineLimit(1) am 560-pt-Pill-Deckel.
            .background {
                Capsule().fill(Color.primary.opacity(0.08))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help("Output mode")
        .accessibilityLabel("Output mode \(selectedMode.name)")
    }
}

// MARK: - Kontext-Chip

private struct PillContextChip: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        Menu {
            ContextMenuContent(controller: controller)
        } label: {
            HStack(spacing: 4) {
                if controller.isScreenClipRecording {
                    // Laufender Screen-Clip: rotes Record-Icon vorne im Chip
                    // (das Blinken übernimmt der Clip-Button rechts).
                    Image(systemName: "record.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OverlayPalette.clip)
                }

                if segments.isEmpty {
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.7)
                    Text("No Ctx")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                } else {
                    // Icon-Segmente mit „+" verbunden — Chat, Text, Shots,
                    // Marks, Clips getrennt erkennbar, Anzahl ab 2 Stück;
                    // wird nie truncated (User-Entscheidung Variante B).
                    ForEach(Array(segments.enumerated()), id: \.element.systemImage) { index, segment in
                        if index > 0 {
                            Text("+")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.35))
                        }
                        HStack(spacing: 2.5) {
                            Image(systemName: segment.systemImage)
                                .font(.system(size: 11, weight: .semibold))
                            if let count = segment.count {
                                Text("\(count)")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityLabel(segment.accessibilityLabel)
                    }
                }
            }
            .foregroundStyle(hasContext ? OverlayPalette.recording : Color.secondary.opacity(0.75))
            .padding(.horizontal, 10)
            .frame(height: PillMetrics.chipHeight)
            .background {
                Capsule().fill(Color.primary.opacity(0.08))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(controller.phase.isBusy)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var segments: [ContextChipSegment] { controller.contextBundle.chipSegments }

    private var hasContext: Bool { !controller.contextBundle.isEmpty }

    private var helpText: String {
        if controller.contextBundle.isEmpty {
            return "No context was captured for this recording."
        }
        return "Context captured for this recording: \(controller.contextBundle.displaySummary)."
    }
}

// MARK: - Kamera & Screen-Clip

private struct PillVisualContextButtons: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        HStack(spacing: 2) {
            PillCameraButton(controller: controller)
            PillScreenClipButton(controller: controller)
        }
    }
}

/// Interaktiver Bereichs-Screenshot — eigenständig, damit Mini ihn in die
/// links aufklappende Hover-Gruppe stecken kann.
private struct PillCameraButton: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        Button {
            controller.captureScreenshot()
        } label: {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: PillMetrics.iconButtonSize, height: PillMetrics.iconButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isVisualContextEnabled ? Color.secondary : Color.secondary.opacity(0.45))
        .disabled(!isVisualContextEnabled || controller.phase.isBusy || controller.isScreenClipRecording)
        .help(isVisualContextEnabled ? "Take a screenshot (select an area)" : "Visual context capture is disabled")
        .accessibilityLabel("Take a screenshot to add as context")
    }

    private var isVisualContextEnabled: Bool {
        AppPreferences.shared.isVisualContextCaptureEnabled
    }
}

/// Screen-Clip Start/Stop — eigenständig, weil das Stop-Icon bei laufendem
/// Clip auch in der kollabierten Mini-Pill sichtbar bleibt.
private struct PillScreenClipButton: View {
    @ObservedObject var controller: OverlayController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBlinkDimmed = false

    var body: some View {
        Button {
            if PermissionService.hasScreenRecordingPermission {
                controller.toggleScreenClip()
            } else {
                _ = PermissionService.requestScreenRecordingPermission()
                PermissionService.openScreenRecordingPrivacySettings()
            }
        } label: {
            Image(systemName: controller.isScreenClipRecording ? "stop.circle.fill" : "record.circle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: PillMetrics.iconButtonSize, height: PillMetrics.iconButtonSize)
                .contentShape(Circle())
                .opacity(isBlinkDimmed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            controller.isScreenClipRecording
                ? OverlayPalette.clip
                : (canRecordScreenClip ? Color.secondary : Color.secondary.opacity(0.45))
        )
        .disabled(
            controller.phase.isBusy
                || (!isVisualContextEnabled && !controller.isScreenClipRecording)
        )
        .help(
            controller.isScreenClipRecording
                ? "Stop screen clip context"
                : (PermissionService.hasScreenRecordingPermission
                    ? "Start screen clip context"
                    : "Grant Screen Recording permission")
        )
        .accessibilityLabel(controller.isScreenClipRecording ? "Stop screen clip context" : "Start screen clip context")
        .onChange(of: controller.isScreenClipRecording, initial: true) { _, isClipping in
            guard isClipping, !reduceMotion else {
                isBlinkDimmed = false
                return
            }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                isBlinkDimmed = true
            }
        }
    }

    private var isVisualContextEnabled: Bool {
        AppPreferences.shared.isVisualContextCaptureEnabled
    }

    private var canRecordScreenClip: Bool {
        isVisualContextEnabled && PermissionService.hasScreenRecordingPermission
    }
}

// MARK: - Separator, ✓ und ✕

private struct PillSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}

/// ✓ — bewusst dezent: gleiche Familie wie ✕, nur einen Hauch präsenter.
private struct PillConfirmButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: PillMetrics.iconButtonSize, height: PillMetrics.iconButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Aufnahme beenden & transkribieren")
        .accessibilityLabel("Stop recording and transcribe")
    }
}

/// Ein ✕, drei Semantiken — Tooltip und Aktion wechseln mit der Phase.
private struct PillCancelButton: View {
    let phase: OverlayPhase
    @ObservedObject var controller: OverlayController

    var body: some View {
        Button {
            switch phase {
            case .recording:
                controller.cancelRecording()
            case .transcribing:
                controller.cancelTranscription()
            case .improving:
                controller.cancelPostProcessing()
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: PillMetrics.iconButtonSize, height: PillMetrics.iconButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(phase.cancelHelp)
        .accessibilityLabel(phase.cancelAccessibilityLabel)
    }
}
