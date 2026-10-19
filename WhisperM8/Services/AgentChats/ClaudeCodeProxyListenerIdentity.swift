import Darwin
import Foundation

/// Wer lauscht tatsaechlich auf dem Proxy-Port? (LR-GPT-002)
///
/// `/healthz` mit `{"ok":true}` kann jeder Prozess nachahmen; der Upstream-Proxy
/// (`raine/claude-code-proxy`) kennt kein Instanz-Token. Deshalb wird zusaetzlich
/// der lauschende Prozess selbst geprueft (libproc, kein Subprozess):
/// gleiche UID wie die App und Programmname `claude-code-proxy`. Ein Listener
/// eines anderen Benutzers ist fuer libproc gar nicht einsehbar und gilt damit
/// als fremd. Ein Prozess derselben UID, der sich so nennt, liegt innerhalb der
/// Vertrauensgrenze (er erreicht ohnehin `~/.gpt-profiles` und die Keychain).
enum ClaudeCodeProxyListenerIdentity {
    enum Verdict: Equatable {
        /// Einsehbarer Listener der eigenen UID mit dem erwarteten Programm.
        case trusted
        /// Auf dem Port lauscht niemand, den wir einsehen koennen.
        case noVisibleListener
        /// Ein Listener der eigenen UID, aber ein anderes Programm.
        case foreignProgram(String)
    }

    static let expectedProgramName = "claude-code-proxy"

    /// Rein: Entscheidung aus dem Programmpfad des Listeners.
    static func verdict(forListenerPath path: String?) -> Verdict {
        guard let path, !path.isEmpty else { return .noVisibleListener }
        let name = (path as NSString).lastPathComponent
        return name == expectedProgramName ? .trusted : .foreignProgram(name)
    }

    /// Fuer die Erreichbarkeit: nur ein nachgewiesener Proxy zaehlt.
    static func isTrustedListener(port: Int) -> Bool {
        verdict(forListenerPath: listenerPath(port: port)) == .trusted
    }

    /// Fuer den Direktweg (Audio an bekannten Port): nur ein nachweislich
    /// FREMDER Listener blockt; ohne einsehbaren Listener bleibt der
    /// „Connection refused"-Pfad (ein Start + ein Retry) unveraendert.
    static func isForeignListener(port: Int) -> Bool {
        if case .foreignProgram = verdict(forListenerPath: listenerPath(port: port)) { return true }
        return false
    }

    /// Pfad des Programms, das auf dem TCP-Port lauscht (nur Prozesse der
    /// eigenen UID sind einsehbar). `nil` = keiner gefunden.
    static func listenerPath(port: Int) -> String? {
        guard (1...65_535).contains(port) else { return nil }
        let ownUID = getuid()

        let pidBytes = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0))
        guard pidBytes > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: pidBytes / MemoryLayout<pid_t>.size + 16)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard infoSize == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == ownUID else { continue }
            guard listens(pid: pid, port: port) else { continue }
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            return String(cString: pathBuffer)
        }
        return nil
    }

    private static func listens(pid: pid_t, port: Int) -> Bool {
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return false }
        let fdCount = Int(listSize) / MemoryLayout<proc_fdinfo>.size + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fdCount * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, Int32(MemoryLayout<socket_fdinfo>.size))
            guard size == Int32(MemoryLayout<socket_fdinfo>.size),
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP),
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN)
            else { continue }
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
            if Int(localPort) == port { return true }
        }
        return false
    }
}
