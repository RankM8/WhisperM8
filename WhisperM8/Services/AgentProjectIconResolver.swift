import Foundation

/// Sucht im lokalen Projekt-Verzeichnis nach einem Web-Icon, das wir als
/// Sidebar-Avatar verwenden können — typischerweise ein Favicon, App-Icon
/// oder Logo, wie es Web-Frameworks (Next.js, Vite, SvelteKit, Astro …)
/// und Native-/Mobile-Stacks ablegen.
///
/// Bewusst rein lokal: kein HTTP-Fetch, kein DNS-Lookup. Wenn der User Privacy-
/// sensible Repos hat, würde ein "Web-Favicon-aus-Domain-fetchen" überraschen.
/// Wir lesen nur Files, die ohnehin im Repo liegen.
enum AgentProjectIconResolver {
    /// Such-Reihenfolge nach Vorrang: erste übereinstimmende Datei gewinnt.
    /// Innerhalb eines Verzeichnisses prüfen wir mehrere Dateinamen-Varianten;
    /// PNG schlägt SVG schlägt ICO (Auflösungs-/Render-Qualität in NSImage).
    private static let searchDirectories: [String] = [
        ".",                  // repo root
        "public",             // Next.js / Vite / CRA
        "static",             // SvelteKit / Astro / Hugo
        "src/assets",         // Vite / Vue
        "assets",             // Astro / generic
        "web/static",         // Phoenix / Django
        "app/static",         // Flask / Django
        "resources",          // Laravel / generic
        "Resources",          // Xcode-style (case sensitivity matters auf Linux-fs)
        "docs",               // GitHub Pages
        "site"                // Hugo / Jekyll fallback
    ]

    /// Gewichtete Dateinamen-Liste — höher == bevorzugt.
    /// - Hochauflösende PNGs zuerst (apple-touch-icon ist meist 180×180)
    /// - SVG wenn vorhanden (skaliert sauber)
    /// - ICO als Fallback (oft 16×16, schlecht in NSImage)
    private static let candidateFilenames: [String] = [
        "apple-touch-icon.png",
        "apple-touch-icon-precomposed.png",
        "icon-512.png",
        "icon-256.png",
        "icon.png",
        "logo.png",
        "favicon-256x256.png",
        "favicon-192x192.png",
        "favicon-180x180.png",
        "favicon-128x128.png",
        "favicon.png",
        "logo.svg",
        "icon.svg",
        "favicon.svg",
        "favicon.ico"
    ]

    /// Finde ein Icon in `projectPath`. Liefert den **relativen** Pfad zum
    /// Projekt-Root, sodass der Wert direkt in `AgentProject.iconRelativePath`
    /// landen kann. Liefert `nil`, wenn nichts gefunden wurde.
    ///
    /// Maximale Filesystem-Cost: ~10–15 Verzeichnisse × ~15 Dateinamen ≈ 200
    /// `fileExists`-Calls. Auf einem warmen Filesystem unter 20 ms — okay für
    /// einmaligen Lookup pro Projekt.
    static func findIconRelativePath(in projectPath: String) -> String? {
        let projectURL = URL(fileURLWithPath: projectPath)
        guard isDirectory(at: projectURL) else { return nil }

        for directory in searchDirectories {
            let baseURL = directory == "." ? projectURL : projectURL.appendingPathComponent(directory)
            guard isDirectory(at: baseURL) else { continue }

            for filename in candidateFilenames {
                let candidate = baseURL.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return relativePath(of: candidate, relativeTo: projectURL)
                }
            }
        }
        return nil
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    /// Liefert `child.path` ohne den Prefix `parent.path + "/"`. Stellt sicher,
    /// dass wir keinen führenden Slash mitschleppen.
    private static func relativePath(of child: URL, relativeTo parent: URL) -> String {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        if childPath.hasPrefix(prefix) {
            return String(childPath.dropFirst(prefix.count))
        }
        return childPath
    }
}
