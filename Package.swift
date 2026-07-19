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
        // Fork von SwiftTerm v1.14.0 (Branch whisperm8-v1.14-patches, Basis-Tag
        // 849e8a4): v1.14.0 bringt Resize-Fix #573, PTY-Backpressure #574,
        // Metal-Reparenting #548, Shift-Selection #536 und Scroll-Lock #587
        // upstream mit — von unseren frueheren 4 Patches bleiben nur die 2
        // Selection-Patches (Selektion ueberlebt Streaming: feedPrepare +
        // linefeed, feuert pro '\n'). Upstream-PR-faehig — bei Merge zurueck
        // auf migueldeicaza/SwiftTerm + Version-Bump. Pin auf Commit fuer
        // reproduzierbare Builds.
        .package(url: "https://github.com/GiulianoCosta71/SwiftTerm", revision: "27f06d7e506511e2826d08175665a13e76ccf5f2"),
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
                .copy("Resources/whisperm8-cli-skill.md"),
                .copy("Resources/whisperm8-agent-skill.md"),
                .copy("Resources/whisperm8-chats-skill.md"),
                .copy("Resources/whisperm8-agent-skill-ref-playwright-browser-qa.md"),
                .copy("Resources/whisperm8-agent-skill-ref-1password-cli.md"),
                .copy("Resources/whisperm8-agent-skill-ref-claude-workflows.md"),
                .copy("Resources/whisperm8-statusline.sh"),
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
