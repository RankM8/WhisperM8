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
        dictation.dictationOriginal = "jo klar ich schau mir den PR heute abend an und meld mich danach bei dir"
        var dictation2 = entry("dict2", "Termin mit Jonas am Donnerstag um 14 Uhr, bitte Agenda vorher schicken.", ago: 5_400, app: "Mail")
        dictation2.dictationMode = "Email"

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
            dictation2,
        ]

        func model(
            selected: String, query: String = "",
            filter: ClipboardHistoryViewModel.Filter = .all, confirmingClear: Bool = false
        ) -> ClipboardHistoryViewModel {
            let model = ClipboardHistoryViewModel(
                loaders: .init(fullText: { $0.text }, image: { _, _ in nil }, appIcon: { _ in nil }),
                now: { now }
            )
            model.setEntries(entries)
            model.preload(thumbnails: ["img": demoImage()])
            model.query = query
            model.filter = filter
            model.select(selected)
            model.isConfirmingClear = confirmingClear
            return model
        }

        let size = ClipboardHistoryView.size
        return [
            Fixture(name: "clipboard-verlauf", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "err"), now: now))
            },
            Fixture(name: "clipboard-verlauf-suche", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "team", query: "team"), now: now))
            },
            Fixture(name: "clipboard-verlauf-diktat", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "dict"), now: now))
            },
            Fixture(name: "clipboard-verlauf-nur-diktate", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "dict2", filter: .dictations), now: now))
            },
            Fixture(name: "clipboard-verlauf-leeren", size: size) {
                AnyView(ClipboardHistoryView(model: model(selected: "err", confirmingClear: true), now: now))
            },
            Fixture(name: "clipboard-verlauf-bild-gross", size: size) {
                let zoomed = model(selected: "img")
                zoomed.openZoom()
                return AnyView(ClipboardHistoryView(model: zoomed, now: now))
            },
            Fixture(name: "clipboard-verlauf-markierung", size: size) {
                let marked = model(selected: "err")
                marked.quickActionsAvailable = true
                marked.correctShortcutLabel = "⇧⌘K"
                marked.selectionAppName = "Mail"
                marked.selectionProbe = .selected(preview: "Hallo Team, ich habe die Datein gestern hochgeladen und den Link im Ticket ergänzt, bitte schaut nochmal drüber")
                return AnyView(ClipboardHistoryView(model: marked, now: now))
            },
            Fixture(name: "clipboard-verlauf-markierung-unklar", size: size) {
                let marked = model(selected: "dict")
                marked.quickActionsAvailable = true
                marked.selectionAppName = "Slack"
                marked.selectionProbe = .unknown
                return AnyView(ClipboardHistoryView(model: marked, now: now))
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
                    entryCount: { $0(137) },
                    clearHistory: {},
                    runningApps: { [ClipboardRunningApp(bundleID: "com.apple.Safari", name: "Safari")] }
                )))
            },
            Fixture(name: "clipboard-einstellungen-aus", size: CGSize(width: 700, height: 1000)) {
                AnyView(ClipboardSettingsPage(dependencies: ClipboardSettingsDependencies(
                    entryCount: { $0(0) }, clearHistory: {}, runningApps: { [] }
                )))
            },
        ]
    }
}
