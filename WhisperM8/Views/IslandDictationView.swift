import SwiftUI

/// Diktat und Schnellaktion an der Kamera-Insel. Zugeklappt eine kleine Kapsel in der
/// Menüleiste neben der Insel: Wellenform (Bewegung und Farbe tragen den
/// Zustand, wie in der Pille) und Zeit; ist es eng, nur die Wellenform. Ein
/// Klick klappt sie zur großen Form auf (`NotchIslandLargeGeometry`): Die
/// Kapsel selbst wächst zur Fläche um die Kamera, es gibt keine zweite
/// Wellenform daneben. Ein Klick auf Kopf oder Wellenform, ein Klick daneben
/// oder das Ende des Diktats klappt sie wieder zu. Bei einer Aufnahme per
/// Controller steht die große Form von selbst offen (mit Ziel-Chat); eine
/// Schnellaktion ist eine Kapsel mit Beschriftung und klappt nicht auf.
///
/// Die Ansicht reicht symmetrisch um die Kamera (ihre Mittellinie) und
/// beginnt an der Oberkante der großen Form; Klicks nimmt das Fenster nur
/// auf der Kapsel bzw. der offenen Form an (`islandInteractiveParts`).
struct IslandDictationView: View {
    @ObservedObject var controller: OverlayController
    let capsule: NotchIslandDictationCapsule
    let band: NotchIslandBand

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: OverlayPhase { controller.phase }

    /// Offen per Klick, bei einer Aufnahme per Controller von selbst; nur
    /// mit Maßen für die große Form (ohne Bildschirm keine).
    private var openForm: NotchIslandLargeForm? {
        controller.showsIslandLargeForm ? controller.islandDictationForm : nil
    }

    var body: some View {
        let closed = NotchIslandLargeOutline(
            centerOffset: capsule.offset, top: band.topGap, width: capsule.width, height: band.capsuleHeight,
            radius: band.capsuleHeight / 2)
        let outline = openForm.map(NotchIslandLargeGeometry.openOutline) ?? closed
        let extent = max(abs(capsule.offset) + capsule.width / 2, (controller.islandDictationForm?.size.width ?? 0) / 2)
        let shape = NotchIslandLargeShape(outline: outline)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if let form = openForm {
                IslandDictationLargeContent(controller: controller, form: form)
                    .frame(width: form.size.width, height: form.size.height, alignment: .top)
                    .transition(contentTransition)
            } else {
                Group {
                    if let label = controller.quickActionLabel {
                        quickActionCapsule(label)
                    } else {
                        capsuleButton
                    }
                }
                .frame(width: capsule.width, height: band.capsuleHeight)
                .offset(x: capsule.offset, y: band.topGap)
                .transition(contentTransition)
            }
        }
        .frame(
            width: 2 * extent, height: openForm?.size.height ?? band.topGap + band.capsuleHeight, alignment: .top)
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
        .animation(NotchIslandLargeMotion.shapeAnimation(reduceMotion: reduceMotion), value: outline)
    }

    /// Inhalt von Kapsel und Form tauschen per Überblenden: der alte geht
    /// zuerst, der neue kommt, wenn die Form fast steht. Keine Bewegung.
    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(NotchIslandLargeMotion.contentInAnimation(reduceMotion: reduceMotion)),
            removal: .opacity.animation(NotchIslandLargeMotion.contentOut))
    }

    /// Schnellaktion: Zeichen im Puls der Nachbearbeitung, die Beschriftung
    /// („Korrigiere…“) und ✕ zum Abbrechen; als Hinweis („Erst Text
    /// markieren“) ein ruhiges Symbol und kein ✕. Wie in der Pille, nur in
    /// der Kapsel neben der Insel.
    private func quickActionCapsule(_ label: String) -> some View {
        HStack(spacing: 0) {
            if controller.isQuickActionHint {
                Image(systemName: "text.cursor")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 38, height: 24)
                    .padding(.leading, 5)
            } else {
                PillCoreView(
                    levelModel: controller.levelModel, phase: .improving, isClipping: false, reduceMotion: reduceMotion)
                    .scaleEffect(0.8)
                    .frame(width: 38, height: 24)
                    .padding(.leading, 5)
            }
            // Passt die Beschriftung nicht ins Fenster, wird sie gekürzt
            // (die Kapsel ist dann schon so breit wie möglich); der ganze
            // Text steht als Tooltip und für VoiceOver bereit.
            Text(verbatim: label)
                .font(.system(size: OverlayController.quickActionLabelSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 7)
                .help(label)
                .accessibilityLabel(Text(verbatim: label))
            Spacer(minLength: 0)
            if !controller.isQuickActionHint {
                Button(action: controller.cancelPostProcessing) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(
                            width: OverlayController.quickActionCancelSize, height: OverlayController.quickActionCancelSize)
                        .background { Circle().fill(Color.white.opacity(0.16)) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Cancel. The selection stays as it is (Esc)"))
                .accessibilityLabel(OverlayPhase.improving.cancelAccessibilityLabel)
                .padding(.trailing, 5)
            }
        }
        .frame(width: capsule.width, height: band.capsuleHeight)
    }

    private var capsuleButton: some View {
        Button(action: controller.toggleIslandExpanded) {
            HStack(spacing: 0) {
                if let badge = controller.statusBadge {
                    // Wartende Chats bzw. Fehler als kleines Zeichen; die
                    // Zahl steht aufgeklappt in der Kopfzeile.
                    NotchStatusDot(status: badge.waiting > 0 ? .awaitingInput : .errored, palette: .notch, size: 8)
                        .frame(width: NotchIslandGeometry.dictationBadgeWidth, alignment: .trailing)
                        .transition(.opacity)
                }
                PillCoreView(
                    levelModel: controller.levelModel, phase: phase,
                    isClipping: controller.isScreenClipRecording, reduceMotion: reduceMotion)
                    .scaleEffect(0.8)
                    .frame(width: 38, height: 24)
                    .padding(.leading, 5)
                if capsule.showsClock {
                    PillCompactClock(clockModel: controller.clockModel)
                        .frame(maxWidth: .infinity)
                        .padding(.trailing, 4)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: capsule.width, height: band.capsuleHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(phase.statusLabel(postProcessingStatusText: controller.postProcessingStatusText) ?? "Recording")
        .accessibilityLabel(phase.accessibilityLabel)
        .accessibilityHint(Text("Shows the dictation controls"))
    }
}

/// Inhalt der großen Form beim Diktat. Kopfzeile: links wartende Chats und
/// Fehler mit Zahl, in der Mitte Apples Mikrofon-Hinweis, rechts der Zustand
/// in Worten. Darunter die Aufnahme (Wellenform, Zeit, Bildschirmfoto, Clip)
/// und was mit ihr geschieht (Ausgabemodus, Kontext, abbrechen, fertig).
/// Alles, was die Pille zeigt, ist hier erreichbar; die Knöpfe sind 44 pt groß.
struct IslandDictationLargeContent: View {
    @ObservedObject var controller: OverlayController
    let form: NotchIslandLargeForm

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: OverlayPhase { controller.phase }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: controller.toggleIslandExpanded) {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(phase.accessibilityLabel)
            .accessibilityHint(Text("Hides the dictation controls"))

            if let target = controller.controllerTargetLabel {
                // Aufnahme per Controller: wohin der Text geht, ohne Klick sichtbar.
                Text(verbatim: "→ \(target)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotchPalette.notch.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NotchIslandLargeGeometry.padding + 2)
                    .frame(height: NotchIslandLargeGeometry.dictationTargetRowHeight, alignment: .bottom)
                    .accessibilityLabel(Text("Dictation target: \(target)"))
            }
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Button(action: controller.toggleIslandExpanded) {
                        HStack(spacing: 14) {
                            IslandDictationWaveform(
                                levelModel: controller.levelModel, phase: phase,
                                isClipping: controller.isScreenClipRecording, reduceMotion: reduceMotion)
                                .frame(maxWidth: .infinity)
                            IslandDictationClock(clockModel: controller.clockModel)
                        }
                        .frame(height: NotchIslandLargeGeometry.controlSize)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Hides the dictation controls"))
                    PillCameraButton(controller: controller, large: true)
                    PillScreenClipButton(controller: controller, large: true)
                }
                HStack(spacing: 10) {
                    PillOutputModeChip(
                        modes: controller.outputModes, selectedMode: controller.selectedOutputMode,
                        isDisabled: phase.isBusy, large: true, action: controller.setOutputMode)
                    PillContextChip(controller: controller, large: true)
                    Spacer(minLength: 0)
                    PillCancelButton(phase: phase, controller: controller, large: true)
                    // Wer aufklappt, will alle Knöpfe sehen: „fertig“ steht
                    // hier unabhängig von der Einstellung, die es in der
                    // Pille ausblendet.
                    if phase == .recording {
                        PillConfirmButton(large: true, action: controller.stopAndTranscribe)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, NotchIslandLargeGeometry.padding)
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        NotchIslandLargeHeader(form: form) {
            if let badge = controller.statusBadge {
                let font = Font.system(size: 14, weight: .semibold)
                HStack(spacing: 12) {
                    if badge.waiting > 0 { NotchChip(kind: .waiting, count: badge.waiting, palette: .notch, font: font) }
                    if badge.errored > 0 { NotchChip(kind: .errored, count: badge.errored, palette: .notch, font: font) }
                }
            }
        } trailing: {
            phaseText
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NotchPalette.notch.secondary)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var phaseText: some View {
        switch phase {
        case .connecting: Text("Connecting microphone…")
        case .recording: Text("Recording")
        case .transcribing: Text("Transcribing…")
        case .improving:
            if let text = controller.postProcessingStatusText {
                Text(verbatim: text)
            } else {
                Text("Improving…")
            }
        }
    }
}

/// Breite Wellenform der großen Form. Während der Aufnahme folgt sie allein
/// dem echten Pegel (Stille = flache graue Linie, lautes Sprechen = Amber),
/// wie der Kern der Pille, nur mit mehr Balken; jeder Balken hat einen festen
/// Anteil, damit es nach Sprache aussieht und nicht nach einem Block. In den
/// anderen Phasen zeigt sie den Kern der Pille (dieselbe Bewegung, dieselbe
/// Farbe wie überall), statt eine zweite Fassung jeder Bewegung zu pflegen.
///
/// Kosten: Diese Ansicht hängt am Pegel (10 Hz) und zeichnet dann 22 Balken
/// neu, nur solange die große Form offen ist.
struct IslandDictationWaveform: View {
    @ObservedObject var levelModel: OverlayLevelModel
    let phase: OverlayPhase
    let isClipping: Bool
    let reduceMotion: Bool

    /// Fester Anteil je Balken (Mitte betont, unregelmäßig).
    static let weights: [CGFloat] = [
        0.34, 0.52, 0.71, 0.88, 0.62, 0.80, 1.0, 0.68, 0.45, 0.76, 0.95,
        0.58, 0.40, 0.66, 0.86, 0.54, 0.36, 0.60, 0.78, 0.48, 0.32, 0.26,
    ]
    static let maxBarHeight: CGFloat = 36

    var body: some View {
        if phase == .recording {
            HStack(spacing: 4) {
                ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                    let bar = Self.bar(level: levelModel.level, weight: weight)
                    Capsule()
                        .fill(bar.color)
                        .frame(width: 4, height: bar.height)
                }
            }
            .frame(height: Self.maxBarHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: levelModel.level)
            .overlay(alignment: .leading) {
                if isClipping {
                    // Bildschirm-Clip läuft: roter Punkt wie der Ring am Kern.
                    Circle().fill(OverlayPalette.clip).frame(width: 7, height: 7).offset(x: -12)
                }
            }
            .accessibilityHidden(true)
        } else {
            PillCoreView(levelModel: levelModel, phase: phase, isClipping: isClipping, reduceMotion: reduceMotion)
                .scaleEffect(1.25)
                .frame(height: Self.maxBarHeight)
        }
    }

    /// Höhe und Farbe eines Balkens aus dem Pegel: dieselbe Ampel wie im
    /// Kern der Pille (grau ohne Signal, Mint beim Sprechen, Amber zu laut).
    static func bar(level: Float, weight: CGFloat) -> (height: CGFloat, color: Color) {
        let eased = pow(CGFloat(max(0, min(level, 1))), 0.5)
        let intensity = min(1, eased * (0.55 + 0.6 * weight))
        let base: CGFloat = 4
        let height = base + (maxBarHeight * weight - base) * intensity
        if intensity < 0.08 { return (max(base, height), Color.white.opacity(0.28)) }
        if intensity > 0.72 { return (height, OverlayPalette.levelLoud) }
        return (height, OverlayPalette.recording.opacity(0.6 + 0.4 * Double(intensity)))
    }
}

/// Zeit in der großen Form (eigene Ansicht: Der Sekundentakt zeichnet nur
/// diesen Text neu).
struct IslandDictationClock: View {
    @ObservedObject var clockModel: OverlayClockModel

    var body: some View {
        Text(clockModel.timeText)
            .font(.system(size: 24, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.94))
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Recording duration \(clockModel.timeText)")
    }
}
