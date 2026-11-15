import Foundation

/// Führt einen Block einmal aus, nachdem der laufende Runloop-Durchgang des
/// Main Threads fertig ist — also nach dem Commit von Core Animation, in dem
/// SwiftUI den Body auswertet, AppKit das Layout macht und gezeichnet wird.
///
/// Ein `DispatchQueue.main.async` reicht dafür nicht: Die Main-Queue wird im
/// selben Durchgang VOR den `beforeWaiting`-Beobachtern geleert, der Block
/// liefe also vor dem teuren Teil. Der Beobachter hier hat die höchste
/// Ordnungszahl und kommt damit nach dem Commit von Core Animation (2.000.000).
@MainActor
enum MainRunLoopCommit {
    static func afterNextCommit(_ block: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// Misst einen Chatwechsel: vom Auswahlwechsel im Fenster-Store bis nach dem
/// nächsten Commit (`PerfBudgets.chatSwitch`, WM8-101). Ein Wechsel, der
/// eintrifft, während der vorige noch gemessen wird, gehört zum selben Bild
/// und startet keine zweite Messung.
@MainActor
enum ChatSwitchMeasurement {
    private static var pending: PerformanceBudget.Token?

    static func selectionChanged() {
        guard pending == nil, PerfBudgets.chatSwitch.isActive else { return }
        let token = PerfBudgets.chatSwitch.begin()
        pending = token
        MainRunLoopCommit.afterNextCommit {
            PerfBudgets.chatSwitch.end(token)
            pending = nil
        }
    }

    /// Unterscheiden sich die Auswahlen zweier Stände? Billig: ein Eintrag je
    /// Fenster plus die globale Auswahl.
    nonisolated static func selectionDiffers(_ lhs: AgentUIState, _ rhs: AgentUIState) -> Bool {
        lhs.selectedSessionID != rhs.selectedSessionID
            || lhs.windows.map(\.selectedSessionID) != rhs.windows.map(\.selectedSessionID)
    }
}

/// Misst den Start bis zum ersten Agent-Chats-Fenster
/// (`PerfBudgets.launchFirstWindow`). Erscheint das Fenster nicht binnen
/// `maximumWait` (App ohne offenes Fenster gestartet), wird die Messung
/// verworfen statt mit einer erfundenen Dauer gemeldet.
@MainActor
enum LaunchMeasurement {
    static let maximumWait: TimeInterval = 30
    private static var token: PerformanceBudget.Token?
    private static var startedAt: Date?

    static func didFinishLaunching() {
        guard token == nil, startedAt == nil else { return }
        token = PerfBudgets.launchFirstWindow.begin()
        startedAt = Date()
    }

    static func agentWindowAppeared() {
        guard let token, let startedAt else { return }
        self.token = nil
        if Date().timeIntervalSince(startedAt) > maximumWait {
            PerfBudgets.launchFirstWindow.cancel(token)
            return
        }
        MainRunLoopCommit.afterNextCommit {
            PerfBudgets.launchFirstWindow.end(token)
        }
    }
}
