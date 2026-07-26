import Foundation

// MARK: - Anomalien (wm8.anomaly/1)

/// Ein widersprüchlicher oder handlungsbedürftiger Zustand.
///
/// Anomalien werden NIE in einen Gesamtstatus eingerechnet. Ein Chat mit
/// verwaistem Prozess bleibt „idle" — die Anomalie steht daneben. Sonst würde
/// genau der Filter, den man zum Aufräumen setzt, das verstecken, was man
/// sucht.
struct ChatsAnomaly: Equatable {
    enum Severity: String, Equatable { case info, warning, critical }

    var code: String
    var severity: Severity
    var ref: String?
    /// Belege, aus denen die Anomalie folgt — macht sie nachprüfbar statt
    /// behauptet.
    var evidence: [String]
    var recommendedAction: String?

    var json: [String: Any] {
        var dict: [String: Any] = [
            "code": code,
            "severity": severity.rawValue,
            "evidence": evidence,
        ]
        if let ref { dict["ref"] = ref }
        if let recommendedAction { dict["recommendedAction"] = recommendedAction }
        return dict
    }
}

/// Reine Erkennung aus den Zustandsachsen. Kein I/O — jede Kombination ist
/// testbar, auch die, die im Alltag selten auftritt.
enum ChatsAnomalyDetector {
    /// Gültige, aber erklärungsbedürftige Kombinationen.
    ///
    /// Ausdrücklich KEINE Anomalie: ein Hintergrund-Agent ohne Tab und ohne
    /// PTY — das ist der Normalfall von `claude --bg`.
    static func detect(sessions: [ChatsSnapshotSession], appReachable: Bool) -> [ChatsAnomaly] {
        var found: [ChatsAnomaly] = []

        for session in sessions {
            let axes = session.axes

            // Meldet Arbeit, es läuft aber nachweislich kein Prozess.
            // Bewusst unabhängig vom Katalog: Der Widerspruch besteht auch bei
            // einer geschlossenen Session — dort sogar besonders deutlich,
            // weil ein `working` ohne Worker dann rein geschätzt ist.
            if axes.execution.worker == .missing, axes.conversation.state == .working {
                let inactive = axes.catalog != .active
                found.append(ChatsAnomaly(
                    code: "workingWithoutWorker",
                    // Geschätzt und inaktiv ist ein Anzeigefehler (warning);
                    // bei aktiver Session mit Beleg ist es kritisch.
                    severity: (inactive || axes.evidence.quality == .inferred) ? .warning : .critical,
                    ref: session.ref,
                    evidence: ["conversation=working", "worker=missing",
                               "catalog=\(axes.catalog.rawValue)",
                               "evidence=\(axes.evidence.quality.rawValue)"],
                    recommendedAction: inactive ? nil : "resume"))
            }

            // Aufträge warten, aber es gibt keinen Prozess, der sie annehmen
            // könnte — sie liegen unbegrenzt.
            if session.queued > 0, axes.execution.worker == .missing || axes.execution.worker == .exited {
                found.append(ChatsAnomaly(
                    code: "queuedWithoutWorker",
                    severity: .warning,
                    ref: session.ref,
                    evidence: ["queued=\(session.queued)", "worker=\(axes.execution.worker.rawValue)"],
                    recommendedAction: "resume"))
            }

            // Aussage beruht nur auf einer Schätzung, obwohl die App läuft.
            if appReachable, axes.evidence.quality == .inferred,
               axes.conversation.state == .working {
                found.append(ChatsAnomaly(
                    code: "estimatedWhileAppRunning",
                    severity: .info,
                    ref: session.ref,
                    evidence: ["evidence=inferred", "appReachable=true"],
                    recommendedAction: nil))
            }
        }

        if !appReachable {
            found.append(ChatsAnomaly(
                code: "appUnreachable",
                severity: .warning,
                ref: nil,
                evidence: ["liveMerge=unavailable"],
                recommendedAction: "WhisperM8 starten — Lesebefehle laufen weiter, Status ist geschätzt"))
        }
        return found
    }
}
