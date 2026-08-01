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
        // Fork von SwiftTerm v1.15.0 (Branch whisperm8-v1.15-patches, Basis-Tag
        // dd2fb8a): unveraendert unsere 2 Selection-Patches (Selektion
        // ueberlebt Streaming: feedPrepare + linefeed, feuert pro '\n'),
        // konfliktfrei von v1.14.0 rebased.
        //
        // v1.15.0 bringt drei Metal-Fixes mit, die Voraussetzung dafuer sind,
        // den GPU-Renderer ueberhaupt einzuschalten: #593 behebt einen Crash in
        // signierten .app-Bundles (Bundle.module-fatalError beim Laden der
        // Shader), #598 unbegrenztes BufferPool-Wachstum bei staendig
        // wechselndem Inhalt, dazu gehaerteter Glyph-Atlas-Overflow. Ausserdem
        // #599 (offizielle Subclass-Hooks fuer Link-/Key-Handling) und #600
        // (zeilengenaues Wheel-Scrolling).
        //
        // Upstream-PR-faehig — bei Merge zurueck auf migueldeicaza/SwiftTerm +
        // Version-Bump. Pin auf Commit fuer reproduzierbare Builds.
        .package(url: "https://github.com/GiulianoCosta71/SwiftTerm", revision: "2671405c3157ed259ee1051fb372ec5d9b44682d"),
    ],
    targets: [
        // Winziges Objective-C-Target, nur damit Swift eine NSException
        // ueberleben kann. AVFoundation meldet manche Fehler nicht per
        // NSError, sondern per Exception (`installTapOnBus` bei
        // Format-Mismatch) — Swift kann die nicht fangen, jede solche
        // Exception beendet den Prozess. Ohne dieses Target laesst sich der
        // Absturz vom 01.08.2026 nicht strukturell ausschliessen, nur
        // unwahrscheinlicher machen.
        .target(
            name: "ObjCExceptionBridge",
            path: "Sources/ObjCExceptionBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "WhisperM8",
            dependencies: [
                "KeyboardShortcuts",
                "Defaults",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                "SwiftTerm",
                "ObjCExceptionBridge",
            ],
            path: "WhisperM8",
            exclude: ["Info.plist", "WhisperM8.entitlements", "Resources/AppIcon.icns"],
            resources: [
                .copy("Resources/whisperm8-cli-skill.md"),
                .copy("Resources/whisperm8-agent-skill.md"),
                .copy("Resources/whisperm8-chats-skill.md"),
                .copy("Resources/whisperm8-gpt-coworker-skill.md"),
                .copy("Resources/whisperm8-gpt-workflow-skill.md"),
                .copy("Resources/whisperm8-gpt-workflow-example-code-review.js"),
                .copy("Resources/whisperm8-gpt-workflow-example-docs-review.js"),
                .copy("Resources/whisperm8-agent-skill-ref-playwright-browser-qa.md"),
                .copy("Resources/whisperm8-agent-skill-ref-1password-cli.md"),
                .copy("Resources/whisperm8-agent-skill-ref-claude-workflows.md"),
                .copy("Resources/whisperm8-statusline.sh"),
                .copy("Resources/whisperm8-subagent-statusline.sh"),
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
