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
        guard let data = readPrefix(from: fileURL, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map(String.init)
        return (lines, data.count)
    }

    private static func readPrefix(from fileURL: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }
}
