import AppKit
import SwiftUI

// MARK: - Klick-Catcher über der Terminal-Pane

/// Fängt Linksklicks NUR im Auswahlmodus ab (`isArmed`) — außerhalb ist die
/// View für das Hit-Testing unsichtbar und alles verhält sich exakt wie
/// vorher (Hover, Drag, Rechtsklick, Scroll-Weiterleitung).
///
/// Warum eine `NSView` statt `contentShape` + `onTapGesture`: SwiftTerm hat
/// bei laufenden Claude-/Codex-TUIs Mouse-Tracking aktiv (die App schreibt
/// selbst SGR-Sequenzen ins PTY, siehe `AgentTerminalView.forwardWheelToTerminal`).
/// Fiele der Hit-Test in irgendeinem Zustand zugunsten der
/// `LocalProcessTerminalView` aus, landete ein Auswahl-Klick als
/// Maus-Escape-Sequenz im laufenden Agenten — ein stiller Nebeneffekt in
/// einem Modus, in dem man mehrfach in Terminals klickt. Muster und
/// Begründung wie bei `MiddleClickNSView` (AgentChatChromeViews.swift).
private final class PaneClickCaptureNSView: NSView {
    var isArmed = false
    var onClick: () -> Void = {}

    /// Auch der aktivierende Klick auf ein nicht-fokussiertes Fenster soll
    /// zählen — sonst bräuchte es im Auswahlmodus zwei Klicks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isArmed }

    /// `nil` = Event fällt komplett an die darunterliegende View durch.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isArmed ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        // Down beanspruchen (NICHT an den nächsten Responder geben), damit
        // das zugehörige Up hier ankommt.
        guard isArmed else { super.mouseDown(with: event); return }
    }

    override func mouseUp(with event: NSEvent) {
        guard isArmed else { super.mouseUp(with: event); return }
        onClick()
    }
}

/// Transparenter Klick-Catcher; bleibt dauerhaft montiert, nur `isArmed`
/// wechselt — ein struktureller View-Wechsel würde die Pane-Identität
/// ändern und das Terminal remounten.
struct GridPaneClickCatcher: NSViewRepresentable {
    var isArmed: Bool
    var onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PaneClickCaptureNSView()
        view.isArmed = isArmed
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PaneClickCaptureNSView else { return }
        view.isArmed = isArmed
        view.onClick = onClick
    }
}

// MARK: - Anbindung an den Workspace-Zustand

/// Hält eine laufende Auswahl am Zustand des Workspace fest: Stufenwechsel
/// von außen macht die Zielstufe unlesbar, ein Workspace-Wechsel im Fenster
/// beendet sie ganz. (Slot-Änderungen behandelt der bestehende
/// `onChange(of: entity.slots)` in `gridWorkspaceContent`.)
///
/// Bewusst als eigener `ViewModifier` statt zweier weiterer `.onChange` in
/// der ohnehin sehr langen Kette von `gridWorkspaceContent` — die brachte den
/// Type-Checker an seine Grenze.
struct GridShrinkSelectionSync: ViewModifier {
    let workspaceID: UUID
    let capacity: Int
    let onCapacityChanged: () -> Void
    let onWorkspaceChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: capacity) { _, _ in onCapacityChanged() }
            .onChange(of: workspaceID) { _, _ in onWorkspaceChanged() }
    }
}

// MARK: - Aktionsleiste in der Workspace-Header-Zeile

/// Ersetzt während der Auswahl den Kapazitäts-Picker: Frage, Zähler und die
/// beiden Entscheidungen. Eigener View-Typ, damit ein Markierungswechsel nur
/// diese Leiste re-rendert, nicht den `AgentChatsView`-Body.
struct GridShrinkActionBar: View {
    let selection: GridShrinkSelection
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let retained = selection.retainedIDs.count
        let leaving = selection.candidateIDs.count - retained
        return HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AgentTheme.accent)
            Text("Welche \(selection.targetCapacity) Chats bleiben?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
            Text(counterLabel(retained: retained, leaving: leaving))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(
                    selection.isCommitEnabled ? AgentTheme.textTertiary : AgentTheme.statusError
                )

            Button(action: onCommit) {
                Text(leaving == 1
                    ? "Verkleinern — 1 Chat verlässt"
                    : "Verkleinern — \(leaving) Chats verlassen")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        AgentTheme.accent.opacity(selection.isCommitEnabled ? 0.9 : 0.3),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selection.isCommitEnabled)
            .help(selection.isCommitEnabled
                ? "Nur die markierten Chats bleiben im Workspace — Tabs und Prozesse laufen weiter"
                : "Erst \(selection.overflowCount) Chat(s) abwählen")

            Button(action: onCancel) {
                Text("Abbrechen")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Kapazität unverändert lassen")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(AgentTheme.header.opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(AgentTheme.accent.opacity(0.55), lineWidth: 1)
        }
    }

    private func counterLabel(retained: Int, leaving: Int) -> String {
        guard selection.isCommitEnabled else {
            return "\(retained)/\(selection.targetCapacity) — \(selection.overflowCount) zu viel"
        }
        return "\(retained)/\(selection.targetCapacity) gewählt"
    }
}

// MARK: - Markierung auf dem Slot

/// Auswahl-Overlay eines Grid-Slots: Markierung + Klick-Catcher.
///
/// Sitzt auf Slot-Ebene (nicht in `gridPane`), damit auch Orphan-Slots —
/// Chats, deren Tab in einem anderen Fenster lebt — markierbar sind: sie
/// belegen einen Slot und müssen deshalb evakuierbar sein.
///
/// Der Modifier wird UNBEDINGT angewandt; die Fallunterscheidung steckt hier
/// im Body. Ein `if` am Aufrufer würde die View-Identität des Slots ändern
/// und das Terminal remounten.
struct GridSlotSelectionOverlay: View {
    let selection: GridShrinkSelection?
    let workspaceID: UUID
    /// `nil` = leerer Slot (kein Kandidat, kein Catcher).
    let sessionID: UUID?
    let sessionTitle: String?
    let onToggle: () -> Void

    var body: some View {
        if let selection, selection.workspaceID == workspaceID {
            content(selection)
        }
    }

    @ViewBuilder
    private func content(_ selection: GridShrinkSelection) -> some View {
        if let sessionID, selection.candidateIDs.contains(sessionID) {
            let retained = selection.isRetained(sessionID)
            ZStack {
                if retained {
                    Rectangle().fill(AgentTheme.accentTint)
                    Rectangle()
                        .strokeBorder(AgentTheme.accent, lineWidth: 2.5)
                } else {
                    // Abdunkeln statt Akzent: der Akzent ist an der Pane
                    // bereits doppelt belegt (Fokus-Rahmen, Drop-Füllung).
                    Rectangle().fill(Color.black.opacity(0.5))
                }
                VStack {
                    HStack {
                        badge(
                            retained: retained,
                            slotNumber: selection.retentionSlotNumber(of: sessionID)
                        )
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                GridPaneClickCatcher(isArmed: true, onClick: onToggle)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                "\(sessionTitle ?? "Chat") — \(retained ? "bleibt im Workspace" : "verlässt den Workspace")"
            )
            .accessibilityHint("Auswählen zum Umschalten")
            .accessibilityAction(.default, onToggle)
        } else {
            // Leerer Slot: zurücknehmen, aber kein Catcher — hier gibt es
            // nichts zu entscheiden.
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .allowsHitTesting(false)
        }
    }

    private func badge(retained: Bool, slotNumber: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: retained ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.system(size: 10, weight: .bold))
            Text(retained ? "Bleibt\(slotNumber.map { " · Slot \($0)" } ?? "")" : "Verlässt")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            retained ? AgentTheme.accentStrong : AgentTheme.statusError,
            in: RoundedRectangle(cornerRadius: 5)
        )
    }
}
