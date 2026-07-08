import Foundation

// MARK: - Exit-Code-Vertrag

/// Der `agent`-Namensraum nutzt eigene, maschinenfreundliche Exit-Codes
/// (0–4) statt der sysexits der übrigen CLI — Claude Code entscheidet
/// darüber ohne Text-Parsing. Im Hilfetext dokumentiert.
enum AgentCLIExit {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let jobFailed: Int32 = 2
    static let stateConflict: Int32 = 3
    static let environment: Int32 = 4
}

// MARK: - Optionen

struct AgentRunOptions: Equatable {
    var prompt = ""
    /// nil → aktuelles Arbeitsverzeichnis des Aufrufers.
    var cd: String?
    var model: String?
    var effort: String?
    var sandbox: CodexSandboxMode = .workspaceWrite
    /// Opt-in (beschlossen): Job in frischem Git-Worktree statt in-place.
    var worktree = false
    /// Opt-in: Netzwerk in der Sandbox (u.a. git push).
    var allowNetwork = false
    /// Optionaler Playwright-MCP Auth-State. Wenn gesetzt, startet Codex den
    /// Playwright-MCP isoliert mit genau dieser storageState-Datei.
    var playwrightStorageStatePath: String?
    /// Generische Codex-Config-Overrides (`--config key=value`, wiederholbar) —
    /// werden 1:1 als `-c` an codex exec durchgereicht und gelten für alle
    /// Turns des Jobs.
    var configOverrides: [String] = []
    /// Claude-Session-ID des Spawners — verknüpft den Job in der App mit
    /// seiner Parent-Session.
    var parentSessionID: String?
    var wait = false
    var json = false
}

struct AgentSendOptions: Equatable {
    var shortId = ""
    var prompt = ""
    var wait = false
    var json = false
}

// MARK: - Parser

enum AgentCLIParser {
    enum ParseError: LocalizedError, Equatable {
        case missingValue(String)
        case unknownFlag(String)
        case invalidValue(flag: String, value: String, allowed: String)
        case missingPrompt
        case multiplePrompts
        case missingShortID
        case tooManyPositionals

        var errorDescription: String? {
            switch self {
            case .missingValue(let flag):
                return "Option \(flag) erwartet einen Wert."
            case .unknownFlag(let flag):
                return "Unbekannte Option: \(flag)"
            case .invalidValue(let flag, let value, let allowed):
                return "Ungültiger Wert '\(value)' für \(flag). Erlaubt: \(allowed)."
            case .missingPrompt:
                return "Kein Prompt angegeben."
            case .multiplePrompts:
                return "Mehrere Prompt-Argumente — den Prompt bitte als EIN (gequotetes) Argument übergeben."
            case .missingShortID:
                return "Keine Job-ID angegeben."
            case .tooManyPositionals:
                return "Zu viele Argumente."
            }
        }
    }

    static func parseRun(_ arguments: [String]) throws -> AgentRunOptions {
        var options = AgentRunOptions()
        var prompts: [String] = []
        var index = 0

        func nextValue(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(flag) }
            return arguments[index]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--cd":
                options.cd = try nextValue(for: arg)
            case "--model":
                options.model = try nextValue(for: arg)
            case "--effort":
                options.effort = try nextValue(for: arg)
            case "--sandbox":
                let raw = try nextValue(for: arg)
                guard let sandbox = CodexSandboxMode(rawValue: raw) else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "read-only, workspace-write")
                }
                options.sandbox = sandbox
            case "--worktree":
                options.worktree = true
            case "--allow-network":
                options.allowNetwork = true
            case "--playwright-storage-state":
                options.playwrightStorageStatePath = try nextValue(for: arg)
            case "--config":
                let raw = try nextValue(for: arg)
                // Minimalvalidierung "key=value" — den Rest validiert codex
                // selbst (TOML-Parsing des value-Teils). Ein führendes "-"
                // MUSS hier scheitern: der Wert wird als eigenes argv-Element
                // hinter `-c` gereicht, und codex läse ihn dann als Flag
                // ("unexpected argument '-f'") statt als Config-Override.
                guard let equalsIndex = raw.firstIndex(of: "="),
                      equalsIndex != raw.startIndex,
                      !raw.hasPrefix("-") else {
                    throw ParseError.invalidValue(
                        flag: arg, value: raw,
                        allowed: "key=value ohne führendes '-' (Codex-Config-Override, z.B. tools.web_search=true)"
                    )
                }
                options.configOverrides.append(raw)
            case "--parent":
                options.parentSessionID = try nextValue(for: arg)
            case "--wait":
                options.wait = true
            case "--json":
                options.json = true
            default:
                if arg.hasPrefix("-") {
                    throw ParseError.unknownFlag(arg)
                }
                prompts.append(arg)
            }
            index += 1
        }

        guard !prompts.isEmpty else { throw ParseError.missingPrompt }
        guard prompts.count == 1 else { throw ParseError.multiplePrompts }
        options.prompt = prompts[0]
        return options
    }

    /// `agent send <short-id> [--wait] [--json] "<prompt>"`
    static func parseSend(_ arguments: [String]) throws -> AgentSendOptions {
        var options = AgentSendOptions()
        var positionals: [String] = []
        for arg in arguments {
            switch arg {
            case "--wait": options.wait = true
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
        }
        guard !positionals.isEmpty else { throw ParseError.missingShortID }
        guard positionals.count >= 2 else { throw ParseError.missingPrompt }
        guard positionals.count == 2 else { throw ParseError.multiplePrompts }
        options.shortId = positionals[0]
        options.prompt = positionals[1]
        return options
    }

    /// `agent status|stop|rm <short-id> [--json]`
    static func parseIDCommand(_ arguments: [String]) throws -> (shortId: String, json: Bool) {
        var json = false
        var positionals: [String] = []
        for arg in arguments {
            switch arg {
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
        }
        guard positionals.count == 1 else {
            throw positionals.isEmpty ? ParseError.missingShortID : ParseError.tooManyPositionals
        }
        return (positionals[0], json)
    }

    /// `agent list [--json]`
    static func parseList(_ arguments: [String]) throws -> Bool {
        var json = false
        for arg in arguments {
            switch arg {
            case "--json": json = true
            default: throw ParseError.unknownFlag(arg)
            }
        }
        return json
    }

    /// `agent logs <short-id> [--tail N]`
    static func parseLogs(_ arguments: [String]) throws -> (shortId: String, tail: Int) {
        var tail = 50
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--tail":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue("--tail") }
                guard let value = Int(arguments[index]), value > 0 else {
                    throw ParseError.invalidValue(flag: "--tail", value: arguments[index], allowed: "positive Ganzzahl")
                }
                tail = value
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count == 1 else {
            throw positionals.isEmpty ? ParseError.missingShortID : ParseError.tooManyPositionals
        }
        return (positionals[0], tail)
    }
}
