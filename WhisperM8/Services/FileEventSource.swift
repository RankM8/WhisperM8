import Foundation

/// Wiederverwendbarer vnode-DispatchSource-Wrapper (P2): beobachtet EINE
/// Datei auf Writes/Extends bzw. Delete/Rename. Exakt das erprobte Muster
/// der ClaudeHookBridge (DispatchSourceFileSystemObject auf O_EVTONLY-FD) —
/// die Bridge selbst bleibt unangetastet.
@MainActor
final class FileEventSource {
    private let url: URL
    private let openFile: (String) -> Int32
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    /// Feuert bei .write/.extend — die Datei hat neuen Inhalt.
    var onChange: (() -> Void)?
    /// Feuert bei .delete/.rename — die Source ist dann bereits abgebaut;
    /// der Aufrufer entscheidet über Re-Arm (Datei kann neu erscheinen).
    var onFileGone: (() -> Void)?

    init(url: URL, openFile: @escaping (String) -> Int32 = { open($0, O_EVTONLY) }) {
        self.url = url
        self.openFile = openFile
    }

    deinit {
        // Sicherheitsnetz analog ClaudeHookBridge.Entry.deinit: cancel()
        // schließt den FD über den CancelHandler.
        source?.cancel()
    }

    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }

        let fd = openFile(url.path)
        guard fd >= 0 else { return false }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = source.data
                if event.contains(.delete) || event.contains(.rename) {
                    self.stop()
                    self.onFileGone?()
                } else {
                    self.onChange?()
                }
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    var isActive: Bool { source != nil }
}
