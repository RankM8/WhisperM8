import Foundation

struct BoundedJSONLReader {
    static func firstLine(from fileURL: URL, maxBytes: Int) -> (line: String, bytesRead: Int)? {
        guard let data = readPrefix(from: fileURL, maxBytes: maxBytes) else { return nil }
        let bytes = data.count
        let lineData: Data
        if let newlineIndex = data.firstIndex(of: 10) {
            lineData = data[..<newlineIndex]
        } else {
            lineData = data
        }
        guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
            return nil
        }
        return (line, bytes)
    }

    static func lines(from fileURL: URL, maxLines: Int, maxBytes: Int) -> (lines: [String], bytesRead: Int)? {
        guard var data = readPrefix(from: fileURL, maxBytes: maxBytes) else { return nil }
        let bytesRead = data.count
        // Das Leselimit kann mitten in einer Zeile (und in einem Mehrbyte-Zeichen)
        // enden: die angeschnittene Schlusszeile verwerfen, statt den ganzen
        // Prefix an der UTF-8-Dekodierung scheitern zu lassen (LR-AK-008).
        if bytesRead >= maxBytes, data.last != 10 {
            if let lastNewline = data.lastIndex(of: 10) {
                data = data[..<lastNewline]
            } else {
                data = Data()
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map(String.init)
        return (lines, bytesRead)
    }

    private static func readPrefix(from fileURL: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }
}
