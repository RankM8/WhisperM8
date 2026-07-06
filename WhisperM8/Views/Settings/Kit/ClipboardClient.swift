import AppKit

protocol ClipboardClient {
    func copy(_ string: String)
}

struct DefaultClipboardClient: ClipboardClient {
    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct ClosureClipboardClient: ClipboardClient {
    let copyHandler: (String) -> Void

    init(_ copyHandler: @escaping (String) -> Void) {
        self.copyHandler = copyHandler
    }

    func copy(_ string: String) {
        copyHandler(string)
    }
}
