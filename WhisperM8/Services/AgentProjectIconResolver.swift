import Foundation

/// Sucht im lokalen Projekt-Verzeichnis nach einem Web-Icon, das wir als
/// Sidebar-Avatar verwenden können — typischerweise ein Favicon, App-Icon
/// oder Logo, wie es Web-Frameworks (Next.js, Vite, SvelteKit, Astro …) und
/// Native-/Mobile-Stacks ablegen.
///
/// Browser-artiger Ansatz: Statt blind feste Dateinamen zu raten, lesen wir
/// — wie ein Browser — das **Web-Manifest** (`manifest.json` /
/// `site.webmanifest`) und nehmen das dort deklarierte, größte Icon. Erst
/// danach greift ein bewerteter Datei-Scan, der Konventions-Pfade abdeckt
/// (Next.js App Router `app/`/`src/app/`, `public/`, `static/`, Monorepo-
/// Unterordner, `dist/`-Builds) und dekorative Feature-Icons
/// (`standort-icon.svg`, `google-review-icon.png`, …) bewusst aussortiert.
///
/// Bewusst rein lokal: kein HTTP-Fetch, kein DNS-Lookup. Wir lesen nur
/// Files, die ohnehin im Repo liegen — ein "Favicon aus der Live-Domain
/// holen" würde bei Privacy-sensiblen Repos überraschen.
enum AgentProjectIconResolver {
    /// Resolver-Generation. Wird hochgezählt, wenn die Erkennungslogik
    /// verbessert wird — die App re-resolved dann beim nächsten Start die
    /// Icons aller Projekte ohne manuell gewähltes Icon (siehe
    /// `AgentChatsView.migrateIconDetectionIfNeeded`). v2 = browser-artiger
    /// Resolver (Manifest + bewerteter Scan); v3 = Tiefen-Grenze gegen
    /// fremde, tief vergrabene Assets; v4 = tiefenbegrenzter Walk + Schnellpfad
    /// (direkte Probe der Web-Root-Orte je Repo-/Monorepo-Ebene), damit große
    /// Repos wie ListM8 (Symfony api/ + client/public) schnell & korrekt ein
    /// Icon bekommen (Juni 2026).
    static let version = 4

    /// Verzeichnisse, die wir beim rekursiven Scan überspringen (Build-Caches,
    /// Dependencies). `dist`/`build`/`out` bleiben drin — manche Repos legen
    /// das einzige aufgelöste Manifest/Icon nur im Build-Output ab.
    private static let prunedDirectories: Set<String> = [
        "node_modules", ".git", ".next", ".nuxt", ".svelte-kit", ".turbo",
        ".parcel-cache", ".cache", "vendor", "coverage", ".angular", "tmp",
        ".venv", "venv", "__pycache__", ".gradle", "Pods", "DerivedData", ".idea",
    ]

    private static let imageExtensions: Set<String> = [
        "png", "svg", "ico", "jpg", "jpeg", "webp", "gif",
    ]

    /// Mindest-Score, ab dem ein gescanntes Bild als echtes Brand-Icon zählt.
    /// Darunter (dekorative Feature-Icons, winzige Sizes) liefern wir lieber
    /// `nil` → farbige Initiale statt falschem Icon.
    private static let minimumScore = 80

    private static let maxScannedEntries = 20000
    /// Der Walk steigt nur bis Tiefe 3 ab — genau die Grenze, ab der ein
    /// Pfad ohnehin kein Kandidat mehr ist (siehe Score-Tiefen-Grenze). So
    /// verschwendet er kein Budget in tiefen Quell-/Test-Bäumen (api/src/…)
    /// und erreicht sicher flache Icon-Ordner wie `client/public/`.
    private static let maxScanDepth = 4

    /// Findet ein Icon in `projectPath`. Liefert den **relativen** Pfad zum
    /// Projekt-Root, sodass der Wert direkt in `AgentProject.iconRelativePath`
    /// landen kann. Liefert `nil`, wenn nichts Brauchbares gefunden wurde.
    static func findIconRelativePath(in projectPath: String) -> String? {
        let projectURL = URL(fileURLWithPath: projectPath)
        guard isDirectory(at: projectURL) else { return nil }

        // Schnellpfad: häufige Web-Root-Orte (auch je erster Unterordner-Ebene
        // für Monorepos / client/) direkt per fileExists prüfen — meist <20 ms
        // statt eines Sekunden langen rekursiven Walks in großen Repos.
        if let quick = quickProbe(projectURL: projectURL) {
            return quick
        }

        let collected = collectCandidates(in: projectURL)

        // 1. Browser-like: deklariertes Icon aus einem Web-Manifest.
        if let fromManifest = bestManifestIcon(
            manifests: collected.manifests,
            projectURL: projectURL
        ) {
            return fromManifest
        }

        // 2. Bewerteter Datei-Scan über alle gefundenen Bilder.
        return bestScored(images: collected.images, projectURL: projectURL)
    }

    // MARK: - Schnellpfad

    /// Häufige Favicon-Namen für die direkte fileExists-Probe.
    private static let commonIconFilenames: [String] = [
        "favicon.ico", "favicon.svg", "favicon.png",
        "favicon-512x512.png", "favicon-256x256.png", "favicon-192x192.png", "favicon-32x32.png",
        "apple-touch-icon.png", "apple-touch-icon-precomposed.png", "apple-icon.png",
        "android-chrome-512x512.png", "android-chrome-192x192.png",
        "android-icon-192x192.png", "mstile-150x150.png",
        "icon.png", "icon.svg", "icon-512.png", "icon-512x512.png",
        "logo.png", "logo.svg",
    ]

    /// Web-Root-Unterordner, in denen Favicons üblicherweise liegen — relativ
    /// zu jeder Basis (Repo-Root + erste Unterordner-Ebene).
    private static let webRootSubdirectories: [String] = [
        "", "public", "static", "dist", "build", "out", "app", "src/app",
        "assets", "www", "web", "site", "wwwroot",
    ]

    private static let manifestFilenames: [String] = [
        "site.webmanifest", "manifest.json", "manifest.webmanifest",
    ]

    /// Prüft die häufigen Web-Root-Orte direkt (ohne Verzeichnis-Walk). Deckt
    /// Standard-Layouts und einfache Monorepos (client/, frontend/, podomedica/
    /// …) ab. Liefert `nil`, wenn dort nichts liegt → dann übernimmt der
    /// rekursive Scan die ungewöhnlichen Fälle (verschachtelte Icon-Ordner).
    static func quickProbe(projectURL: URL) -> String? {
        let fm = FileManager.default
        var baseDirs: [URL] = [projectURL]
        if let subs = try? fm.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for sub in subs {
                let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir, !prunedDirectories.contains(sub.lastPathComponent) {
                    baseDirs.append(sub)
                }
            }
        }

        var manifests: [URL] = []
        var imageCandidates: [URL] = []
        for base in baseDirs {
            for subdir in webRootSubdirectories {
                let dir = subdir.isEmpty ? base : base.appendingPathComponent(subdir)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                for name in manifestFilenames {
                    let m = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: m.path) { manifests.append(m) }
                }
                for name in commonIconFilenames {
                    let f = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: f.path) { imageCandidates.append(f) }
                }
            }
        }

        if let fromManifest = bestManifestIcon(manifests: manifests, projectURL: projectURL) {
            return fromManifest
        }
        return bestScored(images: imageCandidates, projectURL: projectURL)
    }

    /// Höchstbewertetes Bild ≥ `minimumScore`; bei Gleichstand lexikografisch
    /// erstes (deterministisch). Geteilt von Schnellpfad und Voll-Scan.
    private static func bestScored(images: [URL], projectURL: URL) -> String? {
        images
            .compactMap { url -> (path: String, score: Int)? in
                let relative = relativePath(of: url, relativeTo: projectURL)
                let score = score(forImageRelativePath: relative)
                return score >= minimumScore ? (relative, score) : nil
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
            .first?.path
    }

    // MARK: - Manifest (browser-like)

    /// Parst alle gefundenen Web-Manifests, nimmt pro Manifest das größte
    /// deklarierte Icon, dessen Datei tatsächlich existiert, und liefert über
    /// alle Manifests hinweg das insgesamt größte. `src` wird relativ zum
    /// Verzeichnis DES MANIFESTS aufgelöst — das deckt sowohl `/icon.png`
    /// (root-absolut, neben dem Manifest) als auch `icon.png` (relativ) ab.
    static func bestManifestIcon(manifests: [URL], projectURL: URL) -> String? {
        var best: (path: String, size: Int)?
        for manifestURL in manifests {
            // Tiefe Manifests (vendored Sub-Apps, Build-Artefakte in
            // versehentlichen Home-/Downloads-Projekten) ignorieren — ein
            // Projekt-Manifest liegt im Web-Root, nicht tief verschachtelt.
            let manifestDepth = relativePath(of: manifestURL, relativeTo: projectURL)
                .split(separator: "/").count - 1
            guard manifestDepth <= 3 else { continue }
            guard let resolved = largestResolvableIcon(in: manifestURL) else { continue }
            if best == nil || resolved.size > best!.size {
                best = (relativePath(of: resolved.url, relativeTo: projectURL), resolved.size)
            }
        }
        return best?.path
    }

    private static func largestResolvableIcon(in manifestURL: URL) -> (url: URL, size: Int)? {
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = root["icons"] as? [[String: Any]] else {
            return nil
        }
        let manifestDir = manifestURL.deletingLastPathComponent()
        var best: (url: URL, size: Int)?
        for icon in icons {
            guard let src = icon["src"] as? String, !src.isEmpty else { continue }
            let size = parseManifestSize(icon["sizes"] as? String)
            // `src` relativ zum Manifest-Ordner auflösen (führendes "/" bzw.
            // "./" strippen — beides meint "neben dem Manifest").
            let cleaned = src.hasPrefix("/") ? String(src.dropFirst()) : src
            let candidate = manifestDir.appendingPathComponent(cleaned).standardizedFileURL
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            if best == nil || size > best!.size {
                best = (candidate, size)
            }
        }
        return best
    }

    /// "512x512" → 512, "any" → 1024 (skalierbar, hoch gewichtet), sonst 0.
    private static func parseManifestSize(_ sizes: String?) -> Int {
        guard let sizes = sizes?.lowercased() else { return 0 }
        if sizes.contains("any") { return 1024 }
        let dims = sizes.split(whereSeparator: { $0 == "x" || $0 == " " }).compactMap { Int($0) }
        return dims.max() ?? 0
    }

    // MARK: - Scoring (pure, testbar)

    /// Bewertet einen relativen Bildpfad als Brand-Icon-Kandidat. Höher ==
    /// besser; dekorative Feature-Icons und winzige Sizes landen unter
    /// `minimumScore`. Pure Funktion — Kern der Resolver-Tests.
    static func score(forImageRelativePath relativePath: String) -> Int {
        let components = relativePath.lowercased().split(separator: "/").map(String.init)
        guard let file = components.last else { return 0 }
        let directories = Array(components.dropLast())
        let ext = (file as NSString).pathExtension
        let base = (file as NSString).deletingPathExtension

        // Namens-Klasse. Reihenfolge zählt: spezifische Brand-Namen VOR der
        // "-icon"-Dekorativ-Erkennung prüfen (apple-touch-icon ist Brand).
        let nameScore: Int
        if base == "favicon" || base.hasPrefix("favicon-") || base.hasPrefix("favicon.") {
            nameScore = 100
        } else if base.contains("apple-touch-icon") || base.contains("apple-icon") {
            nameScore = 95
        } else if base.contains("android-chrome") || base.contains("android-icon") || base.hasPrefix("mstile") {
            nameScore = 88
        } else if base == "icon" || base.hasPrefix("icon-") {
            nameScore = 82
        } else if base.contains("maskable") {
            nameScore = 70
        } else if base == "logo" || base.hasPrefix("logo-") || base.hasPrefix("logo_") {
            // Logos sind oft große Marketing-Bilder — niedriger als ein echtes
            // Favicon, das den Avatar besser repräsentiert.
            nameScore = 64
        } else if base.hasSuffix("-icon") || base.contains("-icon-") {
            nameScore = 0 // dekorative Feature-Icons (standort-icon, …)
        } else if base.contains("favicon") {
            nameScore = 60
        } else {
            nameScore = 0 // kein icon-/logo-artiger Name → kein Kandidat
        }
        guard nameScore > 0 else { return 0 }

        // Tiefen-Grenze: das EIGENE Favicon eines Projekts liegt flach
        // (public/, src/app/, public/img/favicons/ …). Tiefer (Tiefe > 3)
        // sind es fast immer fremde Assets — vendored Clients, Docs-Handoffs,
        // Sub-Sub-Projekte oder (bei versehentlich als Projekt registrierten
        // Home-/Downloads-Ordnern) komplett unbeteiligte Repos.
        guard directories.count <= 3 else { return 0 }

        var score = nameScore

        switch ext {
        case "png": score += 24
        case "webp": score += 20
        case "svg": score += 18
        case "jpg", "jpeg": score += 14
        case "ico": score += 10 // ein favicon.ico IST ein echtes Favicon
        case "gif": score += 6
        default: break
        }

        let webRoots: Set<String> = ["public", "static", "dist", "build", "out", "www", "web", "app", "src"]
        if let top = directories.first, webRoots.contains(top) { score += 10 }

        // Source vor Build: identische Icons in src/public schlagen die Kopie
        // im Build-Output.
        let buildRoots: Set<String> = ["dist", "build", "out", ".output", ".next", "target"]
        if let top = directories.first, buildRoots.contains(top) { score -= 3 }

        let iconFolders: Set<String> = ["favicons", "icons", "icon", "brand", "img", "images", "assets", "media"]
        if directories.contains(where: { iconFolders.contains($0) }) { score += 6 }

        // Dekorative/Content-Ordner stark abwerten — dort liegen Feature-Bilder,
        // keine App-Favicons.
        let decorativeFolders: Set<String> = [
            "features", "services", "counters", "sections", "components", "content",
            "blog", "posts", "team", "gallery", "products", "partners", "logos",
        ]
        if directories.contains(where: { decorativeFolders.contains($0) }) { score -= 60 }

        // Tiefe Pfade abwerten — Favicons liegen im Web-Root, nicht tief in
        // Marketing-Asset-Ordnern (public/images/brand/berlin/…).
        if directories.count > 2 { score -= (directories.count - 2) * 8 }

        // Hash-Suffixe (Build-Artefakte / generierte Marken-Assets) abwerten:
        // "logo-colorful-qnqyfsnj8uxa13ldbvzhrhrfkdtm26…" ist kein Favicon.
        if base.range(of: #"[-_][a-z0-9]{16,}$"#, options: .regularExpression) != nil {
            score -= 40
        }

        if let size = parseSizeHint(base) {
            if size <= 32 { score -= 18 } else { score += min(size, 512) / 32 }
        }

        return score
    }

    /// "favicon-512x512" → 512, "icon-192" → 192, sonst nil.
    static func parseSizeHint(_ base: String) -> Int? {
        if let range = base.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) {
            return base[range].split(separator: "x").compactMap { Int($0) }.max()
        }
        if let range = base.range(of: #"[-_](\d{2,4})$"#, options: .regularExpression) {
            return Int(base[range].dropFirst())
        }
        return nil
    }

    // MARK: - Filesystem-Walk

    /// Sammelt in EINEM Durchlauf alle Manifest- und Bild-Dateien des Repos —
    /// gepruned (node_modules, Caches), tiefen- und mengenbegrenzt. Läuft
    /// einmal pro Projekt off-main (siehe `attemptAutoDetectProjectIcons`).
    private static func collectCandidates(in projectURL: URL) -> (manifests: [URL], images: [URL]) {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var manifests: [URL] = []
        var images: [URL] = []
        var count = 0
        let projectDepth = projectURL.standardizedFileURL.pathComponents.count

        for case let url as URL in enumerator {
            count += 1
            if count > maxScannedEntries { break }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let depth = url.standardizedFileURL.pathComponents.count - projectDepth
                if prunedDirectories.contains(url.lastPathComponent) || depth >= maxScanDepth {
                    enumerator.skipDescendants()
                }
                continue
            }

            let lower = url.lastPathComponent.lowercased()
            if lower == "manifest.json" || lower.hasSuffix(".webmanifest") {
                manifests.append(url)
            } else if imageExtensions.contains((lower as NSString).pathExtension) {
                images.append(url)
            }
        }
        return (manifests, images)
    }

    // MARK: - Helpers

    private static func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    /// Liefert `child.path` ohne den Prefix `parent.path + "/"`.
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
