import Foundation
import os.log

enum Logger {
    private static let subsystem = "com.whisperm8.app"

    static let paste = os.Logger(subsystem: subsystem, category: "AutoPaste")
    static let focus = os.Logger(subsystem: subsystem, category: "Focus")
    static let permission = os.Logger(subsystem: subsystem, category: "Permission")
}
