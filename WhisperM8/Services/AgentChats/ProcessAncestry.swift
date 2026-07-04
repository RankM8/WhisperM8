import Darwin
import Foundation

/// Prozessbaum-Abstammung via sysctl. Damit findet das agent-CLI beim Spawn
/// den `claude`-Vorfahren (Claude Code exportiert KEINE Session-ID in die
/// Bash-Umgebung — `$CLAUDE_SESSION_ID` ist leer): die gefundene PID landet
/// in state.json, und die App matcht sie gegen die shellPids ihrer laufenden
/// PTY-Sessions → der Job hängt in der Sidebar unter dem richtigen Chat.
enum ProcessAncestry {
    struct ProcessInfoEntry: Equatable {
        let pid: Int32
        let ppid: Int32
        /// p_comm — auf 16 Zeichen gekürzt ("claude" passt vollständig).
        let name: String
    }

    /// Liest ppid + Prozessname über sysctl(KERN_PROC_PID). nil wenn der
    /// Prozess nicht (mehr) existiert.
    static func info(for pid: Int32) -> ProcessInfoEntry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { mibPointer in
            sysctl(mibPointer.baseAddress, 4, &proc, &size, nil, 0)
        }
        guard result == 0, size > 0, proc.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafePointer(to: proc.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
        return ProcessInfoEntry(pid: pid, ppid: proc.kp_eproc.e_ppid, name: name)
    }

    /// Läuft die Eltern-Kette hoch und liefert die PID des ersten Vorfahren
    /// mit dem gegebenen Prozessnamen. `maxDepth` als Endlosschleifen-Schutz
    /// (PID-Zyklen gibt es nicht, aber defensiv bleiben).
    static func findAncestor(
        named target: String,
        from pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        maxDepth: Int = 32,
        infoProvider: (Int32) -> ProcessInfoEntry? = { ProcessAncestry.info(for: $0) }
    ) -> Int32? {
        var current = pid
        for _ in 0..<maxDepth {
            guard let entry = infoProvider(current), entry.ppid > 1 else { return nil }
            guard let parent = infoProvider(entry.ppid) else { return nil }
            if parent.name == target {
                return parent.pid
            }
            current = parent.pid
        }
        return nil
    }
}
