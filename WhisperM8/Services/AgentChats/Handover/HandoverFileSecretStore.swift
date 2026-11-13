import Darwin
import Foundation

// MARK: - Geheimnis als Datei (Option A)

/// Legt das Einmal-Geheimnis als Datei im Ordner des Aufbewahrers ab, nur für
/// die Sekunden zwischen Abgabe und Übernahme (Option A, Urteil Vic
/// 13.11.2026). Der Schlüsselbund band den Eintrag ohne Team-ID an den
/// cdhash des Builds; über zwei Builds (make dev, Brew-Update) ging die
/// Übernahme deshalb nie. Diese Ablage hängt an keiner Signatur.
///
/// Schutz: Datei 0600 im 0700-Ordner des Benutzers. Andere Benutzer und
/// Verwechslungen zwischen Instanzen hält sie ab, ein gezieltes Programm
/// desselben Benutzers nicht (das gilt mit Schlüsselbund ohne gehärtete
/// Laufzeit genauso, siehe `neustart-aufbewahrer.md`, „Wovor schützen wir“).
///
/// Regeln (Vics Auflagen): exklusiv anlegen, 0600, nie einem Symlink folgen,
/// nach dem Lesen löschen (die neue App), beim Ende löschen (der
/// Aufbewahrer), nie ins Log. Kein Schlüsselbund-Aufruf, also nie ein Dialog.
/// Der Schlüsselbund-Weg (`HandoverSecretStore`) bleibt für eine spätere
/// Signatur mit Team-ID (Option C) erhalten; gewählt wird in `HandoverSecretStores.live`.
struct HandoverFileSecretStore: HandoverSecretStoring {
    let paths: HandoverPaths

    func store(_ secret: String) -> Bool {
        guard HandoverSecret.isWellFormed(secret),
              AgentControlServer.prepareOwnedDirectory(at: paths.directory) else { return false }
        let url = paths.secretFileURL
        // Ein liegengebliebenes Geheimnis eines früheren Laufs: nur eine
        // eigene, gewöhnliche Datei entfernen.
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == getuid() else { return false }
            unlink(url.path)
        }
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let bytes = Array(secret.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count, fsync(fd) == 0 else {
            unlink(url.path)
            return false
        }
        return true
    }

    func load() -> HandoverSecretLookup {
        let fd = open(paths.secretFileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .denied(status: errno) }
        defer { close(fd) }
        var st = stat()
        // Nur eine eigene, gewöhnliche Datei, die niemand sonst lesen kann.
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              st.st_mode & 0o077 == 0, st.st_size > 0, st.st_size <= 256 else {
            return .denied(status: -1)
        }
        var buffer = [UInt8](repeating: 0, count: Int(st.st_size))
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == buffer.count, let text = String(bytes: buffer, encoding: .utf8),
              HandoverSecret.isWellFormed(text) else { return .denied(status: -2) }
        return .found(text)
    }

    func remove() {
        Self.remove(at: paths)
    }

    /// Auch für den Aufbewahrer beim Ende: nur eine eigene, gewöhnliche Datei.
    static func remove(at paths: HandoverPaths) {
        var st = stat()
        guard lstat(paths.secretFileURL.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return }
        unlink(paths.secretFileURL.path)
    }
}

/// Welche Ablage die App für das Geheimnis nimmt. Heute die Datei (Option A);
/// mit einer Signatur samt Team-ID (Option C) wäre hier der Schlüsselbund
/// wieder einzusetzen (`HandoverSecretStore.live`).
enum HandoverSecretStores {
    static func live(paths: HandoverPaths = .default) -> HandoverSecretStoring {
        HandoverFileSecretStore(paths: paths)
    }
}
