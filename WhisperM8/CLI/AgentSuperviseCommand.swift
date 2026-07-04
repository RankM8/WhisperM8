import Foundation

/// Interner Detach-Modus: `whisperm8 agent-supervise <short-id>`.
/// Wird ausschließlich von `AgentSupervisorLauncher` gestartet — nie von
/// Hand. Löst sich vom Terminal (setsid, SIGHUP ignorieren) und fährt genau
/// einen Turn über den `AgentJobSupervisor`.
enum AgentSuperviseCommand {
    static func run(arguments: [String]) async -> Int32 {
        guard let shortId = arguments.first, !shortId.isEmpty else {
            CLIIO.err("Usage: whisperm8 agent-supervise <short-id> (interner Modus)")
            return AgentCLIExit.usage
        }

        // Vom Parent/Terminal lösen — der Supervisor überlebt das Schließen
        // des Terminals, aus dem `agent run` aufgerufen wurde. setsid()
        // klappt, weil ein frisch gespawnter Process-Kindprozess kein
        // Prozessgruppen-Leader ist.
        setsid()
        signal(SIGHUP, SIG_IGN)
        // SIGTERM nicht default-tödlich, sondern als sauberer Stop:
        // codex-Kind terminieren → Turn endet als `stopped`.
        signal(SIGTERM, SIG_IGN)

        let supervisor = AgentJobSupervisor(store: AgentJobStore())

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        sigterm.setEventHandler {
            supervisor.requestStop()
        }
        sigterm.resume()
        defer { sigterm.cancel() }

        return await supervisor.superviseCurrentTurn(shortId: shortId)
    }
}
