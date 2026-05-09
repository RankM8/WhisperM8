import Foundation

struct AgentLaunchCommand: Equatable {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: String
}

enum AgentCommandError: LocalizedError, Equatable {
    case commandNotFound(String)
    case missingProject(String)
    case missingExternalSessionID(String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            return "\(command) CLI is not installed."
        case .missingProject(let path):
            return "Project folder does not exist: \(path)"
        case .missingExternalSessionID(let title):
            return "Cannot resume \(title): the original agent session ID was not indexed yet. Refresh sessions or start a new chat explicitly."
        }
    }
}

struct AgentCommandBuilder {
    var commandResolver: (String) -> String? = { command in
        if command == "codex" {
            return CodexStatusProbe().commandPath(command)
        }
        return Self.which(command)
    }

    func command(for session: AgentChatSession, project: AgentProject) throws -> AgentLaunchCommand {
        guard FileManager.default.fileExists(atPath: project.path) else {
            throw AgentCommandError.missingProject(project.path)
        }

        switch session.provider {
        case .codex:
            return try codexCommand(for: session, project: project)
        case .claude:
            return try claudeCommand(for: session, project: project)
        }
    }

    private func codexCommand(for session: AgentChatSession, project: AgentProject) throws -> AgentLaunchCommand {
        guard let executable = commandResolver("codex") else {
            throw AgentCommandError.commandNotFound("Codex")
        }

        if let externalSessionID = session.externalSessionID,
           session.hasLaunchedInitialPrompt || session.initialPrompt == nil {
            return AgentLaunchCommand(
                executablePath: executable,
                arguments: [
                    "resume",
                    "-C", project.path,
                    "-m", session.model,
                    "-c", "model_reasoning_effort=\(session.reasoningEffort)",
                    externalSessionID
                ],
                workingDirectory: project.path
            )
        }

        if session.hasLaunchedInitialPrompt && session.initialPrompt == nil {
            throw AgentCommandError.missingExternalSessionID(session.title)
        }

        var arguments = [
            "-C", project.path,
            "-m", session.model,
            "-c", "model_reasoning_effort=\(session.reasoningEffort)"
        ]
        for imagePath in session.imagePaths {
            arguments.append(contentsOf: ["--image", imagePath])
        }
        if let initialPrompt = session.initialPrompt, !initialPrompt.isEmpty {
            arguments.append(initialPrompt)
        }

        return AgentLaunchCommand(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: project.path
        )
    }

    private func claudeCommand(for session: AgentChatSession, project: AgentProject) throws -> AgentLaunchCommand {
        guard let executable = commandResolver("claude") else {
            throw AgentCommandError.commandNotFound("Claude")
        }

        var arguments: [String] = []
        if let externalSessionID = session.externalSessionID,
           session.hasLaunchedInitialPrompt || session.initialPrompt == nil {
            arguments.append(contentsOf: ["--resume", externalSessionID])
        } else if session.hasLaunchedInitialPrompt && session.initialPrompt == nil {
            throw AgentCommandError.missingExternalSessionID(session.title)
        } else if let initialPrompt = session.initialPrompt, !initialPrompt.isEmpty {
            arguments.append(initialPrompt)
        }

        return AgentLaunchCommand(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: project.path
        )
    }

    private static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
}
