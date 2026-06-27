import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics

enum PermissionService {
    static var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var hasMicrophonePermission: Bool {
        microphoneAuthorizationStatus == .authorized
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openMicrophonePrivacySettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    static func openAccessibilityPrivacySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    static func openScreenRecordingPrivacySettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
