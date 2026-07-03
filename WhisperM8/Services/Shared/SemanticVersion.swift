import Foundation

/// Minimales Semver-Modell für den Update-Check: `Major.Minor.Patch`,
/// tolerant gegenüber `v`-Prefix (Release-Tags wie `v2.5.0`) und fehlenden
/// Komponenten (`2.6` == `2.6.0`). Bewusst KEINE Prerelease-/Build-Suffixe —
/// die Release-Pipeline erzeugt reine X.Y.Z-Tags; alles andere parst zu `nil`
/// und wird vom Checker still ignoriert.
struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed = String(trimmed.dropFirst())
        }
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }

        self.major = numbers[0]
        self.minor = numbers[1]
        self.patch = numbers[2]
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
