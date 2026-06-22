// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperM8",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WhisperM8", targets: ["WhisperM8"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.16.1"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "8.0.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),
        // Fork von SwiftTerm 1.13.0 mit Terminal-UX-Patches (Branch whisperm8-patches):
        // P1 Scroll-Lock bei Wheel/Trackpad-Scroll, P2 Selektion ueberlebt Streaming
        // (feedPrepare UND linefeed — linefeed feuert pro '\n' und war der eigentliche
        // Killer fuers Kopieren), P3 Shift erzwingt lokale Selektion bei aktivem
        // Mouse-Reporting. Patches sind upstream-PR-faehig — bei Merge zurueck auf
        // migueldeicaza/SwiftTerm + Version-Bump. Pin auf Commit fuer reproduzierbare Builds.
        .package(url: "https://github.com/GiulianoCosta71/SwiftTerm", revision: "7906ba8e010c26f39f14ddb07ff801e32f8d1dd8"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperM8",
            dependencies: [
                "KeyboardShortcuts",
                "Defaults",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                "SwiftTerm",
            ],
            path: "WhisperM8",
            exclude: ["Info.plist", "WhisperM8.entitlements", "Resources/AppIcon.icns"],
            resources: [
                .process("Resources/MenuBarIcon.png"),
                .process("Resources/MenuBarIcon@2x.png"),
                .process("Resources/AppLogo.png"),
                .process("Resources/AppLogo@2x.png"),
                .process("Resources/ProviderClaude.png"),
                .process("Resources/ProviderClaude@2x.png"),
                .process("Resources/ProviderCodex.png"),
                .process("Resources/ProviderCodex@2x.png"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "WhisperM8Tests",
            dependencies: ["WhisperM8"]
        )
    ]
)
