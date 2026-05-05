import AppKit
import SwiftUI

enum WindowRequest: String, Equatable {
    case settings
    case onboarding
    case outputDashboard = "output-dashboard"

    var windowID: String {
        switch self {
        case .settings, .outputDashboard:
            return "settings"
        case .onboarding:
            return rawValue
        }
    }
}

@MainActor
final class WindowRequestCenter: ObservableObject {
    static let shared = WindowRequestCenter()

    static let distributedNotificationName = Notification.Name("com.whisperm8.app.openSettings")
    static let localNotificationName = Notification.Name("WindowRequestCenter.request")

    @Published private(set) var latestRequest: WindowRequest?

    private var distributedObserver: NSObjectProtocol?

    private init() {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.distributedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                Self.shared.request(.settings)
            }
        }
    }

    deinit {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }

    func request(_ request: WindowRequest) {
        latestRequest = request
        NotificationCenter.default.post(name: Self.localNotificationName, object: request.rawValue)
    }

    static func notifyRunningInstanceToOpenSettings() {
        DistributedNotificationCenter.default().postNotificationName(
            distributedNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

struct WindowRequestHandler: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var requestCenter = WindowRequestCenter.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(requestCenter.$latestRequest.compactMap { $0 }) { request in
                openWindow(id: request.windowID)
                WindowActivationService.activateApp()
            }
    }
}

enum WindowActivationService {
    static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
