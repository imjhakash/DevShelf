import Foundation

/// An app that can use DevShelf's MCP server, and where it keeps its MCP settings.
struct AssistantApp: Identifiable {
    enum Format { case json, toml, claudeCode }
    let id: String
    let name: String
    let symbol: String
    let bundleIDs: [String]
    let configPath: String   // relative to the home folder
    let format: Format
    let restartNote: String
}

/// Adds or removes DevShelf in assistants' MCP settings. Every edit keeps a one-time backup
/// ("<file>.before-devshelf") and leaves all other settings in place.
enum MCPConnect {
    static let serverName = "devshelf"

    static let apps: [AssistantApp] = [
        AssistantApp(id: "claude-desktop", name: "Claude Desktop", symbol: "sparkle", bundleIDs: ["com.anthropic.claudefordesktop"],
                     configPath: "Library/Application Support/Claude/claude_desktop_config.json", format: .json, restartNote: "Quit and reopen Claude to load DevShelf."),
        AssistantApp(id: "claude-code", name: "Claude Code", symbol: "terminal.fill", bundleIDs: [],
                     configPath: ".claude.json", format: .claudeCode, restartNote: "Start a new Claude Code session; /mcp lists DevShelf."),
        AssistantApp(id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", bundleIDs: ["com.openai.codex"],
                     configPath: ".codex/config.toml", format: .toml, restartNote: "Restart Codex to load DevShelf."),
        AssistantApp(id: "windsurf", name: "Windsurf", symbol: "wind", bundleIDs: ["com.exafunction.windsurf"],
                     configPath: ".codeium/windsurf/mcp_config.json", format: .json, restartNote: "In Windsurf, refresh MCP servers in Cascade or restart it."),
        AssistantApp(id: "cursor", name: "Cursor", symbol: "cursorarrow.rays", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
                     configPath: ".cursor/mcp.json", format: .json, restartNote: "Cursor picks it up in Settings → MCP; restart if it doesn't appear."),
    ]

    enum State: Equatable {
        case connected
        case outdated(String)   // connected, but to a DevShelf at another path
        case disconnected
    }

    static func configURL(_ app: AssistantApp, home: URL) -> URL { home.appendingPathComponent(app.configPath) }

    static func state(_ app: AssistantApp, home: URL, binary: String) -> State {
        guard let command = configuredCommand(app, home: home) else { return .disconnected }
        return command == binary ? .connected : .outdated(command)
    }

    static func configuredCommand(_ app: AssistantApp, home: URL) -> String? {
        let url = configURL(app, home: home)
        switch app.format {
        case .json, .claudeCode:
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any], let entry = servers[serverName] as? [String: Any] else { return nil }
            return entry["command"] as? String
        case .toml:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return tomlCommand(text)
        }
    }

    static func entry(binary: String, claudeCode: Bool = false) -> [String: Any] {
        var entry: [String: Any] = ["command": binary, "args": ["--mcp"]]
        if claudeCode { entry["type"] = "stdio" }
        return entry
    }

    /// The snippet for apps without a Connect button.
    static func snippet(binary: String) -> String {
        let object: [String: Any] = ["mcpServers": [serverName: entry(binary: binary)]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func connect(_ app: AssistantApp, home: URL, binary: String) throws {
        let url = configURL(app, home: home)
        switch app.format {
        case .json, .claudeCode:
            try updateJSON(url) { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers[serverName] = entry(binary: binary, claudeCode: app.format == .claudeCode)
                root["mcpServers"] = servers
            }
        case .toml:
            try updateText(url) { text in
                var clean = removingTOMLBlock(text)
                while clean.hasSuffix("\n\n") { clean.removeLast() }
                if !clean.isEmpty && !clean.hasSuffix("\n") { clean += "\n" }
                return clean + (clean.isEmpty ? "" : "\n") + tomlBlock(binary: binary)
            }
        }
    }

    static func disconnect(_ app: AssistantApp, home: URL) throws {
        let url = configURL(app, home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        switch app.format {
        case .json, .claudeCode:
            try updateJSON(url) { root in
                guard var servers = root["mcpServers"] as? [String: Any] else { return }
                servers.removeValue(forKey: serverName)
                root["mcpServers"] = servers
            }
        case .toml:
            try updateText(url) { removingTOMLBlock($0) }
        }
    }

    // MARK: Claude Code's own command line (preferred over editing ~/.claude.json)

    static func claudeCLI(home: URL) -> String? {
        let candidates = [home.appendingPathComponent(".claude/local/claude").path, home.appendingPathComponent(".local/bin/claude").path, home.appendingPathComponent(".npm-global/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ProjectScanner.executable("claude")
    }

    /// Runs `claude mcp …`; returns the combined output, throwing when it fails.
    @discardableResult static func runClaude(_ cli: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OrganizerError.message(text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "claude mcp failed.") }
        return text
    }

    // MARK: File editing

    static func backup(_ url: URL) {
        let copy = url.appendingPathExtension("before-devshelf")
        if FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: copy.path) { try? FileManager.default.copyItem(at: url, to: copy) }
    }

    static func updateJSON(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OrganizerError.message("\(url.lastPathComponent) isn’t valid JSON, so DevShelf left it unchanged. Fix or remove it, then try again.")
            }
            root = object
        }
        change(&root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        backup(url)
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: url, options: .atomic)
    }

    static func updateText(_ url: URL, _ change: (String) -> String) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        backup(url)
        try change(text).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: TOML (Codex)

    static func tomlString(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    static func tomlBlock(binary: String) -> String { "[mcp_servers.\(serverName)]\ncommand = \(tomlString(binary))\nargs = [\"--mcp\"]\n" }

    static func isOwnHeader(_ line: String) -> Bool {
        let header = line.trimmingCharacters(in: .whitespaces)
        return header == "[mcp_servers.\(serverName)]" || header.hasPrefix("[mcp_servers.\(serverName).")
    }

    static func removingTOMLBlock(_ text: String) -> String {
        var kept: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { inside = isOwnHeader(line) }
            if !inside { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    static func tomlCommand(_ text: String) -> String? {
        var inside = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inside = trimmed == "[mcp_servers.\(serverName)]"; continue }
            guard inside, trimmed.hasPrefix("command"), let equals = trimmed.firstIndex(of: "=") else { continue }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.count >= 2 else { return value }
            value.removeFirst()
            var result = "", escaped = false
            for character in value {
                if escaped { result.append(character); escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { break }
                else { result.append(character) }
            }
            return result
        }
        return nil
    }
}
