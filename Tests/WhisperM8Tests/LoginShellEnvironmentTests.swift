import Foundation
import XCTest
@testable import WhisperM8

final class LoginShellEnvironmentTests: XCTestCase {
    // MARK: - Login Shell Environment

    func testLoginShellEnvironmentMergesUserPathWithFallback() {
        let env = LoginShellEnvironment(pathLoader: {
            "/Users/test/.mise/shims:/Users/test/bin:/opt/homebrew/bin:/usr/bin:/bin"
        })
        let path = env.path
        // User-spezifische Pfade müssen vorne stehen (mise/asdf-shims gewinnen).
        XCTAssertTrue(path.hasPrefix("/Users/test/.mise/shims:/Users/test/bin"))
        // Fallback-Pfade dürfen nur einmal vorkommen (Dedup).
        let occurrences = path.components(separatedBy: "/usr/bin").count - 1
        XCTAssertEqual(occurrences, 1)
        // Fallback-Pfade müssen vorhanden sein, auch wenn nicht im User-PATH.
        XCTAssertTrue(path.contains("/usr/sbin"))
        XCTAssertTrue(path.contains("/sbin"))
    }

    func testLoginShellEnvironmentFallsBackOnEmptyResult() {
        let env = LoginShellEnvironment(pathLoader: { "" })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
    }

    func testLoginShellEnvironmentFallsBackOnNil() {
        let env = LoginShellEnvironment(pathLoader: { nil })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
    }

    func testLoginShellEnvironmentCachesResult() {
        var calls = 0
        let env = LoginShellEnvironment(pathLoader: {
            calls += 1
            return "/opt/homebrew/bin:/usr/bin"
        })
        _ = env.path
        _ = env.path
        _ = env.path
        XCTAssertEqual(calls, 1, "PATH-Loader darf nur einmal aufgerufen werden (Cache)")
    }

    func testLoginShellEnvironmentProcessEnvironmentInjectsPath() {
        let env = LoginShellEnvironment(pathLoader: { "/opt/homebrew/bin:/usr/bin" })
        let envDict = env.processEnvironment(base: ["HOME": "/Users/test", "PATH": "/old"])
        XCTAssertEqual(envDict["HOME"], "/Users/test", "Andere ENV-Vars bleiben erhalten")
        XCTAssertTrue(envDict["PATH"]?.contains("/opt/homebrew/bin") == true)
        XCTAssertNotEqual(envDict["PATH"], "/old", "Alter PATH wird ersetzt")
    }

    func testLoginShellEnvironmentTerminalEnvironmentArrayHasPathKey() {
        let env = LoginShellEnvironment(pathLoader: { "/opt/homebrew/bin:/usr/bin" })
        let array = env.terminalEnvironmentArray(base: ["HOME": "/Users/test"])
        XCTAssertTrue(array.contains { $0.hasPrefix("PATH=") && $0.contains("/opt/homebrew/bin") })
        XCTAssertTrue(array.contains("HOME=/Users/test"))
    }

    func testLoginShellEnvironmentSetsTerminalColorDefaults() {
        // Regression: ohne TERM/COLORTERM rendern Claude Code & Codex CLI monochrom,
        // weil GUI-Apps diese Vars nicht von launchd erben.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [:])
        XCTAssertEqual(envDict["TERM"], "xterm-256color")
        XCTAssertEqual(envDict["COLORTERM"], "truecolor")
        XCTAssertEqual(envDict["CLICOLOR"], "1")
        XCTAssertEqual(envDict["LANG"], "en_US.UTF-8")
    }

    func testLoginShellEnvironmentRepairsMonochromeLauncherEnvironment() {
        // Regression: `make dev` aus Codex kann die App mit TERM=dumb und
        // NO_COLOR=1 starten. Diese Werte dürfen nicht an SwiftTerm-Child-
        // Prozesse weitergereicht werden, sonst rendert Claude/Codex grau.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "TERM": "dumb",
            "COLORTERM": "",
            "NO_COLOR": "1"
        ])

        XCTAssertEqual(envDict["TERM"], "xterm-256color")
        XCTAssertEqual(envDict["COLORTERM"], "truecolor")
        XCTAssertEqual(envDict["CLICOLOR"], "1")
        XCTAssertNil(envDict["NO_COLOR"])
    }

    func testLoginShellEnvironmentReplacesStarterTerminalTypeButKeepsLocale() {
        // TERM kommt nie aus dem User-Profil (nur PATH und Netzwerk-Variablen
        // werden aus der Login-Shell übernommen), sondern vom Terminal, aus dem
        // die App gestartet wurde. Unsere Chats laufen in SwiftTerm.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "TERM": "xterm-kitty",
            "COLORTERM": "24bit",
            "LC_ALL": "de_DE.UTF-8"
        ])
        XCTAssertEqual(envDict["TERM"], "xterm-256color")
        XCTAssertEqual(envDict["COLORTERM"], "truecolor")
        XCTAssertEqual(envDict["LC_ALL"], "de_DE.UTF-8")
        XCTAssertNil(envDict["LANG"], "LANG nicht gesetzt, weil LC_ALL bereits eine Locale liefert")
    }

    /// Befund 13.11.2026: `make dev` aus iTerm, alle Chats erbten die
    /// iTerm-Variablen, iTerm-Hooks griffen in jedem Chat.
    func testStripsVariablesOfTheStartingTerminal() {
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let base: [String: String] = [
            "ITERM_SESSION_ID": "w0t0p0:ABC", "ITERM_PROFILE": "Default",
            "TERM_PROGRAM": "iTerm.app", "TERM_PROGRAM_VERSION": "3.7.7",
            "TERM_SESSION_ID": "w0t0p0:ABC", "LC_TERMINAL": "iTerm2", "LC_TERMINAL_VERSION": "3.7.7",
            "SHELL_SESSION_ID": "x", "TERMINFO": "/Applications/Ghostty.app/Contents/Resources/terminfo",
            "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app", "KITTY_WINDOW_ID": "1", "KITTY_PID": "2",
            "WEZTERM_PANE": "0", "WARP_IS_LOCAL_SHELL_SESSION": "1", "TMUX": "/tmp/tmux-501/default,1,0",
            "TMUX_PANE": "%1", "STY": "1.tty", "ZELLIJ": "0", "ZELLIJ_SESSION_NAME": "s",
            "ALACRITTY_WINDOW_ID": "1", "VTE_VERSION": "7000", "WINDOW": "0",
            "COLORFGBG": "7;0", "TERM_FEATURES": "T3LrMSc7UUw9Ts3BFGsSyHNoSxF", "ITERM2_SQUELCH_MARK": "1",
            "TERMCAP": "SC|screen", "TERMINAL_EMULATOR": "JetBrains-JediTerm", "ZED_TERM": "true",
            "INSIDE_EMACS": "29.1,vterm", "CURSOR_TRACE_ID": "x", "KONSOLE_DBUS_SESSION": "/Sessions/1",
            "VSCODE_GIT_IPC_HANDLE": "/tmp/vscode-git.sock", "VSCODE_INJECTION": "1",
            "GIT_ASKPASS": "/Applications/Visual Studio Code.app/askpass.sh",
            // bleiben:
            "HOME": "/Users/u", "SSH_AUTH_SOCK": "/tmp/agent", "LANG": "de_DE.UTF-8", "EDITOR": "vim",
        ]
        let result = env.processEnvironment(base: base)
        for key in base.keys where !["HOME", "SSH_AUTH_SOCK", "LANG", "EDITOR"].contains(key) {
            XCTAssertNil(result[key], "\(key) darf nicht an Chats gehen")
        }
        XCTAssertEqual(result["HOME"], "/Users/u")
        XCTAssertEqual(result["SSH_AUTH_SOCK"], "/tmp/agent")
        XCTAssertEqual(result["LANG"], "de_DE.UTF-8")
        XCTAssertEqual(result["EDITOR"], "vim")
        XCTAssertEqual(result["TERM"], "xterm-256color")
    }

    /// Vic, 13.11.2026: Die laufende App erbte auch von make und vom startenden Agenten.
    func testStripsVariablesOfMakeAndTheStartingAgent() {
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let base: [String: String] = [
            "MAKEFLAGS": "FORCE=1", "MFLAGS": "", "MAKELEVEL": "2", "MAKEOVERRIDES": "${-*-command-variables-*-}",
            "AI_AGENT": "claude-code_2-1-323_agent", "CLAUDE_EFFORT": "high", "CLAUDE_PID": "87451",
            "COREPACK_ENABLE_AUTO_PIN": "0", "GIT_EDITOR": "true",
            "ENABLE_TOOL_SEARCH": "true",
        ]
        let result = env.processEnvironment(base: base)
        for key in base.keys where key != "ENABLE_TOOL_SEARCH" {
            XCTAssertNil(result[key], "\(key) darf nicht an Chats gehen")
        }
        XCTAssertEqual(result["ENABLE_TOOL_SEARCH"], "true", "Einstellung des Users bleibt")
    }

    /// Ein echter Editor in GIT_EDITOR bleibt, nur `true` (Claude Code) fällt.
    func testKeepsRealGitEditor() {
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        XCTAssertEqual(env.processEnvironment(base: ["GIT_EDITOR": "vim"])["GIT_EDITOR"], "vim")
    }

    /// `WINDOW` ohne screen-Sitzung ist nicht von screen und bleibt.
    func testKeepsWindowWithoutScreenSession() {
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        XCTAssertEqual(env.processEnvironment(base: ["WINDOW": "main"])["WINDOW"], "main")
    }

    /// Ein eigenes `GIT_ASKPASS` (ohne VS Code) bleibt.
    func testKeepsOwnGitAskpassWithoutVSCode() {
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let result = env.processEnvironment(base: ["GIT_ASKPASS": "/usr/local/bin/my-askpass"])
        XCTAssertEqual(result["GIT_ASKPASS"], "/usr/local/bin/my-askpass")
    }

    func testFallbackPathContainsCommonLocations() {
        // Sanity-Check: alle wichtigen Pfade abgedeckt für Apple Silicon + Intel
        let fallback = LoginShellEnvironment.fallbackPath
        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            XCTAssertTrue(fallback.contains(expected), "fallbackPath muss \(expected) enthalten")
        }
        // Regression: der native Claude-Code-Installer legt das Binary unter
        // ~/.local/bin ab — dieser Pfad landet nur via .zshrc im PATH und
        // fehlt deshalb in der nicht-interaktiven Login-Shell.
        XCTAssertTrue(
            fallback.contains("\(NSHomeDirectory())/.local/bin"),
            "fallbackPath muss ~/.local/bin enthalten (nativer Claude-Installer)"
        )
    }

    func testStripsInheritedClaudeCodeEnvSoSpawnedSessionsAreTopLevel() {
        // WURZEL-Regression: Wird WhisperM8 aus einem Claude-Code-Kontext gestartet,
        // erbt es CLAUDE_CODE_CHILD_SESSION=1 + CLAUDE_CODE_SESSION_ID=<parent>.
        // Diese dürfen NICHT an gespawnte Agenten durchgereicht werden — sonst hält
        // sich der `claude` für eine verschachtelte Child-Session und persistiert
        // KEIN eigenes Transkript ("No conversation found" beim Resume).
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_SESSION_ID": "c8c80b0f-c61e-4efa-812c-c4760f72c073",
            "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
            "CLAUDE_CODE_OAUTH_SCOPES": "user:inference",
            "CLAUDECODE": "1",
            "HOME": "/Users/test"
        ])
        XCTAssertNil(envDict["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(envDict["CLAUDE_CODE_SESSION_ID"])
        XCTAssertNil(envDict["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertNil(envDict["CLAUDE_CODE_OAUTH_SCOPES"])
        XCTAssertNil(envDict["CLAUDECODE"])
        // Nicht-CLAUDE-Variablen bleiben unangetastet.
        XCTAssertEqual(envDict["HOME"], "/Users/test")
        XCTAssertTrue(envDict["PATH"]?.contains("/usr/bin") ?? false)
    }

    func testStripsInheritedClaudeConfigDirSoAccountRoutingStaysExplicit() {
        // WURZEL-Regression (2026-07-13): Wird die App aus einem Terminal
        // gestartet, in dem ccs.zsh das aktive Account-Profil exportiert hat
        // (CLAUDE_CONFIG_DIR=~/.claude-profiles/<name>), erben ALLE gespawnten
        // `claude`-Prozesse diesen Profil-Root. Main-gestempelte Sessions
        // (claudeProfileName=nil) bekommen keinen Override — ihr `--resume`
        // sucht dann im falschen projects/-Root und meldet „No conversation
        // found". Account-Routing darf NUR über explizite per-Launch-Overrides
        // laufen, nie über geerbtes Env.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "CLAUDE_CONFIG_DIR": "/Users/test/.claude-profiles/PowerUser",
            "HOME": "/Users/test"
        ])
        XCTAssertNil(envDict["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(envDict["HOME"], "/Users/test")
    }

    func testStripsInheritedGPTAccountRoutingVariables() {
        // Dieselbe Regel fuer die GPT-Konto-Profile: `make dev` aus einer auf
        // `ai` gestempelten Shell darf nicht alle main-Sessions auf ai ziehen,
        // und ein geerbtes CCP_CONFIG_DIR keinen Proxy-Store umhaengen.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "ANTHROPIC_CUSTOM_HEADERS": "X-WhisperM8-GPT-Profile: ai",
            "CCP_CONFIG_DIR": "/Users/test/.gpt-profiles/ai",
            "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL": "1",
            "HOME": "/Users/test"
        ])
        XCTAssertNil(envDict["ANTHROPIC_CUSTOM_HEADERS"])
        XCTAssertNil(envDict["CCP_CONFIG_DIR"])
        XCTAssertNil(envDict["_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL"])
        XCTAssertEqual(envDict["HOME"], "/Users/test")
    }
}
