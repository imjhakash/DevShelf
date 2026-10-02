import AppKit
import SwiftUI

extension AppState {
    var mcpBinary: String { Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0] }
    var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Assistants launch DevShelf from this path, so it should not move afterwards.
    var appLooksTemporary: Bool { ["/Downloads/", "/build/", "/Desktop/", "/private/", "/Volumes/"].contains { mcpBinary.contains($0) } }

    func assistantInstalled(_ app: AssistantApp) -> Bool {
        if app.bundleIDs.contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) { return true }
        switch app.id {
        case "claude-code": return MCPConnect.claudeCLI(home: homeURL) != nil
        case "codex": return ProjectScanner.executable("codex") != nil || FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(".codex").path)
        default: return FileManager.default.fileExists(atPath: MCPConnect.configURL(app, home: homeURL).deletingLastPathComponent().path)
        }
    }

    func refreshAssistants() {
        let home = homeURL, binary = mcpBinary
        Task {
            let states = await Task.detached(priority: .userInitiated) { Dictionary(uniqueKeysWithValues: MCPConnect.apps.map { ($0.id, MCPConnect.state($0, home: home, binary: binary)) }) }.value
            assistantStates = states
            mcpLog = MCPLog.read()
        }
    }

    func connectAssistant(_ app: AssistantApp, connect: Bool = true) {
        guard assistantBusy == nil else { return }
        assistantBusy = app.id
        assistantMessage = ""
        let home = homeURL, binary = mcpBinary
        Task {
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    // Claude Code manages ~/.claude.json itself, so use its command line when available.
                    if app.format == .claudeCode, let cli = MCPConnect.claudeCLI(home: home) {
                        try? MCPConnect.runClaude(cli, ["mcp", "remove", "--scope", "user", MCPConnect.serverName])
                        if connect { try MCPConnect.runClaude(cli, ["mcp", "add", "--scope", "user", MCPConnect.serverName, "--", binary, "--mcp"]) }
                    } else if connect {
                        try MCPConnect.connect(app, home: home, binary: binary)
                    } else {
                        try MCPConnect.disconnect(app, home: home)
                    }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            assistantBusy = nil
            assistantMessage = failure ?? (connect ? "Connected \(app.name). \(app.restartNote)" : "Disconnected \(app.name). Its other settings were left as they were.")
            refreshAssistants()
        }
    }

    /// Starts `DevShelf --mcp` the way an assistant would and checks that it answers.
    func testMCPServer() {
        mcpTest = "Testing…"
        let binary = mcpBinary
        Task {
            mcpTest = await Task.detached(priority: .userInitiated) { () -> String in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["--mcp"]
                let input = Pipe(), output = Pipe()
                process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
                do { try process.run() } catch { return "Could not start DevShelf: \(error.localizedDescription)" }
                let messages = [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"devshelf-self-test","version":"1"}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                ]
                input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))
                try? input.fileHandleForWriting.close()
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                let replies = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                guard let tools = replies.compactMap({ ($0["result"] as? [String: Any])?["tools"] as? [Any] }).first else { return "The server didn’t answer as expected." }
                return "Works · \(tools.count) tools ready"
            }.value
        }
    }

    // MARK: Changes made by assistants while the app is open

    func dataFileDate(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Persistence.directory.appendingPathComponent(name).path))?[.modificationDate] as? Date
    }

    func startShelfSync() {
        shelfBase = shelf
        shelfStamp = dataFileDate("shelf.json")
        mcpLogStamp = dataFileDate(MCPLog.file)
        mcpLog = MCPLog.read()
        folderWatcher = FolderWatcher { [weak self] paths in Task { @MainActor in self?.filesChanged(paths) } }
        updateWatchedFolders()
        linksChanged()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollExternalChanges() } }
    }

    func pollExternalChanges() {
        if let stamp = dataFileDate("shelf.json"), stamp != shelfStamp, let disk = Persistence.read("shelf.json", as: ShelfLibrary.self) {
            let merged = ShelfLibrary.merge(base: shelfBase, ours: shelf, theirs: disk)
            shelf = merged; shelfBase = disk; shelfStamp = stamp
            if merged != disk { saveShelf() }
            fileTick += 1
        }
        if let stamp = dataFileDate(MCPLog.file), stamp != mcpLogStamp {
            mcpLogStamp = stamp
            mcpLog = MCPLog.read()
            if let last = mcpLog.last { showNotice(last.client + ": " + last.summary) }
            fileTick += 1
        }
        updateWatchedFolders()
    }
}

struct AssistantsSheet: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Connect AI assistants", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 22, weight: .semibold))
                    Text("Let Claude, Codex, Windsurf or Cursor organize your projects for you through DevShelf’s MCP server.").font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer()
                Button { state.showAssistants = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.appLooksTemporary {
                        Label("DevShelf is running from \(shortPath(state.mcpBinary)). Assistants start DevShelf from this exact path — move DevShelf to Applications first, or press Reconnect after moving it.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(spacing: 8) {
                        ForEach(MCPConnect.apps) { app in AssistantRow(state: state, app: app) }
                    }
                    if !state.assistantMessage.isEmpty {
                        Text(state.assistantMessage).font(.system(size: 11)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHAT ASSISTANTS CAN DO").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                        Text("Ask in plain words, for example “Create a project called Portfolio with Code, Design and Images folders, and copy my Downloads/brand folder into Design”.").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(["Create projects & folders", "Add or move files from anywhere", "Sort loose files into folders", "Find files by name or type", "Rename & trash (recoverable)", "Update checklists & status", "Bring in scanned code folders", "Sync projects to a drive", "Zip folders to share", "Check Git status"], id: \.self) { item in
                                Label(item, systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.8))
                            }
                        }
                        Text("They can only change things inside your projects (files you add can come from anywhere). Nothing is deleted permanently, and saved passwords are never shared.").font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Button { state.testMCPServer() } label: { Label("Test server", systemImage: "stethoscope") }
                        if !state.mcpTest.isEmpty { Text(state.mcpTest).font(.system(size: 11)).foregroundStyle(state.mcpTest.hasPrefix("Works") ? accent : muted) }
                        Spacer()
                        Button { state.copy(MCPConnect.snippet(binary: state.mcpBinary)); state.showNotice("MCP setup copied.") } label: { Label("Copy setup for other apps", systemImage: "doc.on.doc") }
                    }.font(.system(size: 11))
                    if !state.mcpLog.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RECENT ASSISTANT ACTIONS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                            VStack(spacing: 0) {
                                ForEach(state.mcpLog.suffix(10).reversed()) { entry in
                                    HStack(spacing: 10) {
                                        Text(entry.client).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent).frame(width: 90, alignment: .leading).lineLimit(1)
                                        Text(entry.summary).font(.system(size: 11)).lineLimit(1)
                                        Spacer()
                                        Text(entry.date.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(muted)
                                    }.padding(.horizontal, 12).padding(.vertical, 6)
                                    Divider().opacity(0.1)
                                }
                            }.background(panel, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.padding(.trailing, 6)
            }.frame(height: 500)
            HStack {
                Text("DevShelf’s MCP server: " + shortPath(state.mcpBinary) + " --mcp").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { state.showAssistants = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 640).background(canvas).preferredColorScheme(.dark)
            .onAppear { state.refreshAssistants() }
    }
}

struct AssistantRow: View {
    @ObservedObject var state: AppState
    let app: AssistantApp
    var body: some View {
        let current = state.assistantStates[app.id] ?? .disconnected
        let installed = state.assistantInstalled(app)
        let busy = state.assistantBusy == app.id
        HStack(spacing: 12) {
            Image(systemName: app.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(accent).frame(width: 36, height: 36).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 13, weight: .semibold))
                Text(installed ? "~/" + app.configPath : "Not found on this Mac · you can still connect it for later").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            switch current {
            case .connected: Pill(title: "Connected", color: accent)
            case .outdated: Pill(title: "Needs reconnect", color: .orange).help("Connected to DevShelf at another location")
            case .disconnected: Pill(title: "Not connected")
            }
            if busy { ProgressView().controlSize(.small) }
            if current == .connected {
                Button("Disconnect") { state.connectAssistant(app, connect: false) }.disabled(busy)
            } else {
                Button(current == .disconnected ? "Connect" : "Reconnect") { state.connectAssistant(app) }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(canvas).disabled(busy)
            }
        }.font(.system(size: 11)).padding(12).background(panel, in: RoundedRectangle(cornerRadius: 10))
    }
}
