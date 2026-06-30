import Foundation

/// Reine, testbare Routing-Logik für Terminal-Link-Klicks.
///
/// SwiftTerm erkennt beim Cmd-Klick nicht nur `https://`-URLs, sondern auch
/// **nackte Dateipfade** (absolut `/…`, relativ `./` `../`, Tilde `~/`,
/// `wort/wort`) und übergibt den **rohen String** an `requestOpenLink`. Der
/// SwiftTerm-Default jagt den durch `URL(string:) + NSWorkspace.open` — was bei
/// schemelosen Pfaden bzw. Leerzeichen/Umlauten in `-50` (paramErr) oder einem
/// stillen No-op endet. (Browser-Links funktionieren nur zufällig, weil
/// `https://…` als absolute URL wohlgeformt ist.)
///
/// Dieser Resolver entscheidet rein, WAS passieren soll; der
/// `AgentTerminalController` führt die Aktion mit den richtigen AppKit-APIs aus
/// (`URL(fileURLWithPath:)` statt `URL(string:)`, `NSWorkspace`, `NSAlert`).
enum TerminalLinkResolver {
    /// Datei-Existenz + -Typ. Als Closure injizierbar, damit Tests ohne echtes
    /// Dateisystem laufen.
    struct FileStatus: Equatable {
        let exists: Bool
        let isDirectory: Bool
        static let missing = FileStatus(exists: false, isDirectory: false)
    }

    /// Was der Controller mit dem Link tun soll. Datei/Ordner/Web lösen alle
    /// `NSWorkspace.open` aus — getrennt gehalten, damit die *Entscheidung*
    /// (Routing) testbar ist.
    enum Action: Equatable {
        /// http/https/mailto/ssh/… → an den Standard-Handler (Browser/Mail).
        case openWeb(URL)
        /// Code-/Text-/Markdown-Datei → im Editor (PhpStorm) öffnen.
        case openInEditor(URL)
        /// Sonstige Datei (Bild, PDF, Archiv, …) → mit der Standard-App öffnen.
        case openFile(URL)
        /// Existierender Ordner → im Finder öffnen.
        case openFolder(URL)
        /// Cmd+Alt → Datei/Ordner nur im Finder markieren statt öffnen.
        case revealInFinder(URL)
        /// Aufgelöst, aber nicht vorhanden → klare Meldung statt `-50`.
        case notFound(path: String)
        /// Nicht auflösbar (relativ ohne Arbeitsverzeichnis, leer, kaputt).
        case reject(reason: String)
    }

    /// Schemelose Sonderfälle ohne `://`-Autorität, die trotzdem an den
    /// System-Handler gehören.
    private static let bareSchemes = ["mailto:", "tel:", "news:", "magnet:"]

    /// Routet einen vom Terminal gelieferten Link-String.
    /// - Parameters:
    ///   - link: Roher String aus SwiftTerm (URL **oder** Dateipfad).
    ///   - workingDirectory: Arbeitsverzeichnis der Session, Basis für relative Pfade.
    ///   - revealInFinder: `true` ⇒ im Finder zeigen statt öffnen (Cmd+Alt-Klick).
    ///   - fileStatus: Existenz-/Typ-Probe (injiziert).
    static func resolve(
        link rawLink: String,
        workingDirectory: String?,
        revealInFinder: Bool,
        fileStatus: (String) -> FileStatus
    ) -> Action {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return .reject(reason: "Leerer Link") }

        // 1. file:-URL → in einen reinen Pfad zerlegen, dann lokal behandeln.
        if link.lowercased().hasPrefix("file:") {
            guard let path = filePath(fromFileURL: link) else {
                return .reject(reason: "Ungültige file-URL: \(link)")
            }
            return resolveLocalPath(path, workingDirectory: workingDirectory,
                                    revealInFinder: revealInFinder, fileStatus: fileStatus)
        }

        // 2. Echte URL mit Autorität (`scheme://…`) oder bekanntes schemeloses
        //    Scheme (mailto:/tel:/…) → unverändert an den System-Handler.
        if hasAuthorityScheme(link)
            || bareSchemes.contains(where: { link.lowercased().hasPrefix($0) }) {
            if let url = URL(string: link) { return .openWeb(url) }
            return .reject(reason: "Ungültige URL: \(link)")
        }

        // 3. Alles andere = lokaler Pfad (absolut, ~, relativ, wort/wort, path:line).
        return resolveLocalPath(link, workingDirectory: workingDirectory,
                                revealInFinder: revealInFinder, fileStatus: fileStatus)
    }

    // MARK: - Lokale Pfade

    private static func resolveLocalPath(
        _ rawPath: String,
        workingDirectory: String?,
        revealInFinder: Bool,
        fileStatus: (String) -> FileStatus
    ) -> Action {
        guard let absolute = absolutePath(for: rawPath, workingDirectory: workingDirectory) else {
            return .reject(reason: "Relativer Pfad ohne Arbeitsverzeichnis: \(rawPath)")
        }

        // Direkter Treffer.
        let status = fileStatus(absolute)
        if status.exists {
            return action(forPath: absolute, isDirectory: status.isDirectory, revealInFinder: revealInFinder)
        }

        // Fallback: `path:line` / `path:line:col` (häufig in Agent-/Grep-Ausgabe)
        // — Zeilen-Suffix abschneiden und die reine Datei erneut prüfen.
        if let stripped = strippingLineSuffix(absolute), stripped != absolute {
            let s = fileStatus(stripped)
            if s.exists {
                return action(forPath: stripped, isDirectory: s.isDirectory, revealInFinder: revealInFinder)
            }
        }

        return .notFound(path: absolute)
    }

    private static func action(forPath path: String, isDirectory: Bool, revealInFinder: Bool) -> Action {
        let url = URL(fileURLWithPath: path)
        if revealInFinder { return .revealInFinder(url) }
        if isDirectory { return .openFolder(url) }
        return isEditorFile(url) ? .openInEditor(url) : .openFile(url)
    }

    /// Heuristik: Code/Text/Markdown gehört in den Editor (PhpStorm), Medien/
    /// Archive/Office/Binaries in die Standard-App. Unbekannte oder fehlende
    /// Endungen (Makefile, Dockerfile, LICENSE, Dotfiles wie `.gitignore`) gelten
    /// im Coding-Kontext als Text ⇒ Editor.
    static func isEditorFile(_ url: URL) -> Bool {
        !nonEditorExtensions.contains(url.pathExtension.lowercased())
    }

    private static let nonEditorExtensions: Set<String> = [
        // Bilder
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "icns", "ico",
        // Design / PDF
        "pdf", "sketch", "fig", "psd", "ai", "xd",
        // Audio / Video
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "wav", "aiff", "aif", "flac", "m4a", "aac", "ogg",
        // Archive / Pakete / Binaries
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "app", "ipa", "jar", "war",
        "exe", "dll", "so", "dylib", "o", "a", "class", "wasm", "bin",
        // Office
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        // Fonts
        "woff", "woff2", "ttf", "otf", "eot",
    ]

    /// `~`-Expansion + Auflösung relativer Pfade gegen `workingDirectory`, danach
    /// Normalisierung (`..`/`.` auflösen). `nil` ⇒ relativ ohne Basis.
    /// Symlinks werden **nicht** aufgelöst (der angezeigte Pfad bleibt erhalten).
    private static func absolutePath(for rawPath: String, workingDirectory: String?) -> String? {
        let path: String
        if rawPath.hasPrefix("~") {
            path = (rawPath as NSString).expandingTildeInPath
        } else if rawPath.hasPrefix("/") {
            path = rawPath
        } else {
            guard let base = workingDirectory, !base.isEmpty else { return nil }
            path = URL(fileURLWithPath: base).appendingPathComponent(rawPath).path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Entfernt ein nachgestelltes `:<zahl>` bzw. `:<zahl>:<zahl>` (Editor-/Grep-
    /// Stil `Datei.swift:42`). Gibt den unveränderten Pfad zurück, wenn keins da ist.
    private static func strippingLineSuffix(_ path: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(:\d+){1,2}$"#) else { return nil }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let m = regex.firstMatch(in: path, options: [], range: range),
              m.range.length > 0,
              let r = Range(m.range, in: path) else { return path }
        return String(path[path.startIndex..<r.lowerBound])
    }

    // MARK: - Scheme-Erkennung

    /// `true` für `scheme://…` (http, https, ssh, ftp, git, …).
    private static func hasAuthorityScheme(_ link: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^[a-zA-Z][a-zA-Z0-9+.\-]*://"#) else { return false }
        let range = NSRange(link.startIndex..<link.endIndex, in: link)
        return regex.firstMatch(in: link, options: [], range: range) != nil
    }

    /// Zerlegt eine `file:`-URL in einen reinen, percent-decodierten Pfad — egal
    /// ob `file:/p`, `file://host/p` oder `file:///p`.
    private static func filePath(fromFileURL link: String) -> String? {
        if let url = URL(string: link), url.isFileURL, !url.path.isEmpty {
            return url.path
        }
        // Fallback für nicht-escapte Sonderzeichen, an denen `URL(string:)` scheitert.
        var rest = String(link.dropFirst("file:".count))
        if rest.hasPrefix("//") {
            rest.removeFirst(2)
            if let slash = rest.firstIndex(of: "/") {
                rest = String(rest[slash...])            // optionalen Host verwerfen
            } else {
                rest = "/" + rest
            }
        }
        let decoded = rest.removingPercentEncoding ?? rest
        return decoded.isEmpty ? nil : decoded
    }
}
