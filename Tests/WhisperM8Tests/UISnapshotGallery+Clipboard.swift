import AppKit
import SwiftUI
@testable import WhisperM8

/// Fixtures für Verlaufs-Fenster und Einstellungsseite des Zwischenablage-Verlaufs.
extension UISnapshotGallery {
    @MainActor
    static func clipboardFixtures() -> [Fixture] {
        let now = Date(timeIntervalSince1970: 1_792_000_000)

        func entry(_ id: String, _ text: String, ago: TimeInterval, app: String?, pinned: Bool = false) -> ClipboardEntry {
            ClipboardEntry(
                id: id, kind: .text, createdAt: now.addingTimeInterval(-ago), lastCopiedAt: now.addingTimeInterval(-ago),
                copyCount: 1, isPinned: pinned, sourceBundleID: nil, sourceName: app,
                contentHash: id, preview: ClipboardEntry.makePreview(from: text), text: text
            )
        }
        func demoImage() -> NSImage {
            let image = NSImage(size: NSSize(width: 320, height: 180))
            image.lockFocus()
            NSGradient(colors: [NSColor.systemTeal, NSColor.systemIndigo])?
                .draw(in: NSRect(x: 0, y: 0, width: 320, height: 180), angle: 35)
            image.unlockFocus()
            return image
        }

        var image = entry("img", "", ago: 360, app: "Vorschau")
        image.kind = .image
        image.text = nil
        image.preview = "Image 1280 × 720"
        image.imageWidth = 1280
        image.imageHeight = 720
        image.imageFile = "img.png"
        var files = entry("files", "", ago: 720, app: "Finder")
        files.kind = .files
        files.text = nil
        files.filePaths = ["/Users/demo/Angebote/angebot-2026-11.pdf"]
        files.preview = "angebot-2026-11.pdf"

        var dictation = entry("dict", "Klar, ich schaue mir den PR heute Abend an und melde mich danach bei dir.", ago: 30, app: "Slack")
        dictation.dictationMode = "Slack"

        let entries: [ClipboardEntry] = [
            entry("pin1", "ssh deploy@staging.example.com -p 2222", ago: 90_000, app: "Terminal", pinned: true),
            entry("pin2", "Mit freundlichen Grüßen, Giuliano Costa", ago: 200_000, app: "Mail", pinned: true),
            dictation,
            entry("err", "TypeError: Cannot read properties of undefined (reading 'map')\n    at renderList (app.js:128:22)\n    at App (app.js:40:9)", ago: 60, app: "Safari"),
            image,
            files,
            entry("url", "https://github.com/rankm8/whisperm8/pull/42", ago: 1_500, app: "Safari"),
            entry("code", "func paste(_ entry: ClipboardEntry, plain: Bool) async", ago: 3_600, app: "Xcode"),
            entry("team", "Das Team trifft sich um 10 Uhr zum Meeting, Agenda folgt.", ago: 7_200, app: "Slack"),
        ]

        func model(selected: String, query: String = "") -> ClipboardHistoryViewModel {
            let model = ClipboardHistoryViewModel(
                loaders: .init(fullText: { $0.text }, image: { _, _ in nil }, appIcon: { _ in nil }),
                now: { now }
            )
            model.setEntries(entries)
            model.preload(thumbnails: ["img": demoImage()])
            model.query = query
            model.select(selected)
            return model
        }

        let size = CGSize(width: 760, height: 460)
        return [
            Fixture(name: "clipboard-verlauf", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "err"), now: now))
            },
            Fixture(name: "clipboard-verlauf-suche", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "team", query: "team"), now: now))
            },
            Fixture(name: "clipboard-verlauf-bild", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "img"), now: now))
            },
            Fixture(name: "clipboard-verlauf-leer", size: size) {
                let empty = ClipboardHistoryViewModel(
                    loaders: .init(fullText: { _ in nil }, image: { _, _ in nil }, appIcon: { _ in nil }), now: { now }
                )
                return AnyView(ClipboardHistoryView(model: empty, now: now))
            },
            Fixture(
                name: "clipboard-einstellungen", size: CGSize(width: 700, height: 1000),
                storage: [ClipboardPreferenceKeys.enabled: true]
            ) {
                AnyView(ClipboardSettingsPage(dependencies: ClipboardSettingsDependencies(
                    entryCount: { 137 },
                    clearHistory: {},
                    runningApps: { [ClipboardRunningApp(bundleID: "com.apple.Safari", name: "Safari")] }
                )))
            },
            Fixture(name: "clipboard-einstellungen-aus", size: CGSize(width: 700, height: 1000)) {
                AnyView(ClipboardSettingsPage(dependencies: ClipboardSettingsDependencies(
                    entryCount: { 0 }, clearHistory: {}, runningApps: { [] }
                )))
            },
        ]
    }
}
