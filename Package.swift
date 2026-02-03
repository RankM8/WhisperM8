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
    ],
    targets: [
        .executableTarget(
            name: "WhisperM8",
            dependencies: [
                "KeyboardShortcuts",
                "Defaults",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "WhisperM8",
            exclude: ["Info.plist", "WhisperM8.entitlements"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
