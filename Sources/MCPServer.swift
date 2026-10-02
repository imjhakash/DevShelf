import Foundation

// DevShelf's Model Context Protocol server. `DevShelf --mcp` speaks JSON-RPC 2.0 over
// stdin/stdout (one message per line), so assistants such as Claude, Codex, Windsurf and
// Cursor can organize projects. Only JSON-RPC messages may be written to stdout.

struct MCPLogEntry: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var date = Date()
    var client: String
    var tool: String
    var summary: String
}

enum MCPLog {
    static let file = "mcp-log.json"
    static func read() -> [MCPLogEntry] { Persistence.read(file, as: [MCPLogEntry].self) ?? [] }
    static func append(_ entry: MCPLogEntry) { Persistence.write(Array((read() + [entry]).suffix(60)), to: file) }
}

struct MCPToolError: Error { let message: String }

enum MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    DevShelf organizes software projects. Each project is a real folder (by default ~/DevShelf Projects/<name>) that holds all of the project's files, usually in typed folders such as Code, Design, Documents, Images, Videos, Database, Backups and Deliverables.
    Start with list_projects. Refer to a project by its id or name. Paths in tools are relative to the project's folder.
    add_files follows the user's setting. By default it LINKS: the original file or folder stays exactly where it is and appears inside the project as a link — nothing is copied or moved, no space is used, and the project always shows the original's current contents. Only use mode "move" or "copy" when the user explicitly asks to move or copy. Items reached through a linked folder are the user's originals: these tools won't rename, move or trash them (remove the link itself instead). Use find_duplicates to find identical files that waste space.
    Nothing is deleted permanently: trash_items moves items to the macOS Trash. Login passwords are never available through these tools.
    Projects can live on external drives; a project on an unplugged drive is reported as unavailable. Changes show up in the DevShelf app straight away.
    """

    static func run() {
        let session = MCPSession()
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let reply = session.handle(line) { write(reply) }
        }
    }

    static func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

final class MCPSession {
    var client = "AI assistant"
    let tools = MCPTools()

    func handle(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            return error(NSNull(), -32700, "Parse error")
        }
        guard let message = json as? [String: Any], let method = message["method"] as? String else {
            return error((json as? [String: Any])?["id"] ?? NSNull(), -32600, "Invalid request")
        }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String, !name.isEmpty { client = MCPSession.friendlyName(name) }
            let requested = params["protocolVersion"] as? String ?? ""
            result = [
                "protocolVersion": MCPServer.protocolVersions.contains(requested) ? requested : MCPServer.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "devshelf", "title": "DevShelf", "version": appVersion],
                "instructions": MCPServer.instructions,
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": MCPTools.definitions]
        case "tools/call":
            guard let name = params["name"] as? String, MCPTools.definitions.contains(where: { $0["name"] as? String == name }) else {
                return error(id ?? NSNull(), -32602, "Unknown tool: \(params["name"] ?? "")")
            }
            do {
                let text = try tools.call(name, MCPArgs(params["arguments"] as? [String: Any] ?? [:]), client: client)
                result = ["content": [["type": "text", "text": text]], "isError": false]
            } catch let failure as MCPToolError {
                result = ["content": [["type": "text", "text": failure.message]], "isError": true]
            } catch {
                result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default:
            if id == nil { return nil }   // notifications need no reply
            return error(id!, -32601, "Method not found: \(method)")
        }
        guard let id else { return nil }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func friendlyName(_ name: String) -> String {
        let key = name.lowercased()
        if key.contains("claude-code") || key.contains("claude code") { return "Claude Code" }
        for (needle, title) in [("claude", "Claude"), ("codex", "Codex"), ("windsurf", "Windsurf"), ("cursor", "Cursor")] where key.contains(needle) { return title }
        return name
    }

    func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

struct MCPArgs {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    func string(_ key: String) -> String? {
        guard let text = values[key] as? String else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    func require(_ key: String) throws -> String {
        guard let value = string(key) else { throw MCPToolError(message: "Missing “\(key)”.") }
        return value
    }
    func strings(_ key: String) -> [String] {
        if let list = values[key] as? [Any] { return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        return string(key).map { [$0] } ?? []
    }
    func bool(_ key: String) -> Bool? { values[key] as? Bool }
    func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
}

/// Reads and writes the same files as the app, fresh for every tool call.
final class ShelfStore {
    var library = ShelfLibrary()
    var volumes: [Volume] = []
    var prefs = Preferences()

    func load() {
        library = Persistence.read("shelf.json", as: ShelfLibrary.self) ?? ShelfLibrary()
        prefs = Persistence.read("preferences.json", as: Preferences.self) ?? Preferences()
        volumes = Volumes.mounted()
    }

    func save() { Persistence.write(library, to: "shelf.json") }

    var templates: [ProjectTemplate] { ProjectTemplate.builtIn + (Persistence.read("templates.json", as: [ProjectTemplate].self) ?? []) }

    func status(_ location: FolderLocation) -> LocationStatus { Volumes.resolve(location, mounted: volumes) }
    func folder(_ project: ShelfProject) -> URL? { project.allLocations.lazy.compactMap { self.status($0).url }.first }

    /// Finds a project by id, exact name, or a unique part of its name.
    func index(_ reference: String) throws -> Int {
        let projects = library.projects
        if let index = projects.firstIndex(where: { $0.id == reference }) { return index }
        if let index = projects.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }) { return index }
        let partial = projects.indices.filter { projects[$0].name.localizedCaseInsensitiveContains(reference) }
        if partial.count == 1 { return partial[0] }
        let names = (partial.isEmpty ? projects.indices.map { $0 } : partial).map { "“\(projects[$0].name)”" }.joined(separator: ", ")
        throw MCPToolError(message: partial.isEmpty ? "No project called “\(reference)”. Projects: \(names.isEmpty ? "none yet" : names)." : "“\(reference)” matches several projects: \(names). Use the exact name or id.")
    }

    func availableFolder(_ index: Int) throws -> URL {
        let project = library.projects[index]
        guard let url = folder(project) else {
            let drive = project.allLocations.first { if case .offline = status($0) { return true }; return false }?.volumeName
            throw MCPToolError(message: drive.map { "“\(project.name)” is on \($0), which is unplugged. Ask the user to connect it." } ?? "The folder of “\(project.name)” was moved or deleted.")
        }
        return url
    }

    /// Resolves a path given relative to the project (or absolute inside it), refusing anything outside.
    func inside(_ root: URL, _ path: String?) throws -> URL {
        let rootPath = root.standardizedFileURL.path
        var text = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(rootPath) { text = String(text.dropFirst(rootPath.count)) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = (text.isEmpty || text == "." ? root : root.appendingPathComponent(text)).standardizedFileURL
        guard ShelfFiles.contains(url.path, in: rootPath) else { throw MCPToolError(message: "“\(path ?? "")” is outside the project folder.") }
        return url
    }

    /// Items reached through a linked folder are the user's originals; assistants may only manage the links.
    func refuseOriginals(_ items: [URL], root: URL, action: String) throws {
        if let original = items.first(where: { !ShelfFiles.storedInside($0, projectRoot: root) }) {
            throw MCPToolError(message: "“\(relative(original, to: root))” is inside a linked folder, so it's the user's original file and stays where it is. DevShelf won't \(action) originals; you can \(action == "trash" ? "remove" : action) the link itself instead.")
        }
    }

    func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path == base ? "" : String(path.dropFirst(base.count + 1))
    }

    func writeMetadata(_ index: Int) {
        let project = library.projects[index]
        for location in project.allLocations { if let url = status(location).url { try? ShelfFiles.writeMetadata(project, to: url) } }
    }

    func summary(_ project: ShelfProject) -> [String: Any] {
        let url = folder(project)
        return [
            "id": project.id, "name": project.name, "status": project.status.rawValue, "available": url != nil,
            "path": url?.path ?? project.location.path, "color": project.color, "icon": project.icon,
            "folders": url.map { ShelfFiles.children(of: $0).filter(\.isFolder).map(\.name) } ?? [],
            "open_tasks": project.openTasks,
            "locations": project.allLocations.map { location -> [String: Any] in
                let state = status(location)
                return ["where": location.onDrive ? (location.volumeName ?? "Drive") : "This Mac", "role": location == project.location ? "main" : "copy",
                        "connected": state.isActive, "path": state.url?.path ?? location.path]
            },
        ]
    }
}

final class MCPTools {
    let store = ShelfStore()

    // MARK: Definitions

    static func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any], required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": readOnly, "openWorldHint": false]]
    }
    static func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func list(_ description: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": description] }
    static func flag(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    static func choice(_ values: [String], _ description: String) -> [String: Any] { ["type": "string", "enum": values, "description": description] }
    static let projectArg = text("Project id or name (from list_projects).")

    static let definitions: [[String: Any]] = [
        tool("list_projects", "List projects", "List DevShelf projects with their folders, status, location (this Mac or an external drive) and whether they are available now.",
             ["query": text("Only projects whose name, notes, checklist or path contain this text."), "include_done": flag("Include projects marked Done (default true).")], readOnly: true),
        tool("get_project", "Project details", "Full details of one project: folders and files (two levels), files grouped by type, checklist, notes, saved login names (never passwords) and Git status of repositories inside it.",
             ["project": projectArg, "include_git": flag("Check Git repositories (default true).")], required: ["project"], readOnly: true),
        tool("create_project", "Create project", "Create a new project folder with typed sub-folders. Without folders or template, the user's default folders are used. Folders may be nested, e.g. \"Code/theme\".",
             ["name": text("Project name; also the folder name."), "folders": list("Folders to create, e.g. [\"Code\", \"Design\", \"Images\", \"Documents\"]."),
              "template": text("Template id or name instead of folders (see list_templates)."), "color": choice(shelfColorKeys, "Colour in DevShelf."),
              "icon": text("SF Symbol name, e.g. globe, iphone, cart.fill, paintbrush.pointed.fill."), "notes": text("Short description."),
              "location": text("\"mac\" (default, ~/DevShelf Projects) or the name of a connected external drive.")], required: ["name"]),
        tool("update_project", "Update project", "Rename a project or change its colour, icon, notes or status. Renaming also renames its folder when DevShelf created it.",
             ["project": projectArg, "name": text("New name."), "color": choice(shelfColorKeys, "New colour."), "icon": text("New SF Symbol name."), "notes": text("New notes."),
              "status": choice(ProjectStatus.allCases.map(\.rawValue), "active, waiting, onHold or done.")], required: ["project"]),
        tool("create_folders", "Create folders", "Create folders inside a project. Paths are relative to the project and may be nested.",
             ["project": projectArg, "paths": list("e.g. [\"Design/Logos\", \"Documents/Contracts\"].")], required: ["project", "paths"]),
        tool("list_files", "List files", "List the folders and files of a project (or a folder inside it) as a tree with sizes.",
             ["project": projectArg, "path": text("Folder inside the project (default: the top)."), "depth": ["type": "integer", "minimum": 1, "maximum": 5, "description": "Levels to show (default 2)."],
              "show_hidden": flag("Include hidden files such as .env (default false).")], required: ["project"], readOnly: true),
        tool("find_files", "Find files", "Find files by name and/or type in one project or in all available projects.",
             ["query": text("Part of the file name."), "kind": choice(FileKinds.kinds.map(\.id) + [FileKinds.other.id], "File type."),
              "project": text("Limit to this project (id or name).")], readOnly: true),
        tool("add_files", "Add files", "Put files and folders from anywhere on the Mac into a project folder. By default (the user's setting) each item is LINKED: the original stays where it is and shows up in the project, with no copy, no move and no extra space. mode move/copy moves or copies instead (copies skip rebuildable folders such as node_modules). Existing names are never overwritten.",
             ["project": projectArg, "sources": list("Absolute paths, e.g. [\"~/Downloads/logo.png\"]."), "destination": text("Folder inside the project (created if missing; default: the top)."),
              "mode": choice(["auto", "link", "copy", "move"], "auto (default): the user's setting, normally link; link keeps the original in place; copy duplicates it (extra space); move moves it."), "skip_dependencies": flag("Skip node_modules, .next, .venv and caches when copying (default: the user's setting).")],
             required: ["project", "sources"]),
        tool("move_items", "Move items", "Move files or folders within a project into another folder of the same project, e.g. to sort loose files into typed folders.",
             ["project": projectArg, "items": list("Paths inside the project."), "destination": text("Destination folder inside the project (created if missing).")], required: ["project", "items", "destination"]),
        tool("rename_item", "Rename item", "Rename a file or folder inside a project.",
             ["project": projectArg, "path": text("Path inside the project."), "new_name": text("New name (no slashes).")], required: ["project", "path", "new_name"]),
        tool("trash_items", "Move to Trash", "Move files or folders inside a project to the macOS Trash (recoverable). Never deletes permanently.",
             ["project": projectArg, "paths": list("Paths inside the project.")], required: ["project", "paths"], destructive: true),
        tool("mark_folder", "Pin, favourite or colour a folder", "Pin a folder inside a project to the top of its file view, add it to the sidebar's Favorite folders, or give it a colour.",
             ["project": projectArg, "path": text("Folder inside the project."), "pinned": flag("Pin (true) or unpin (false)."), "favorite": flag("Add to (true) or remove from (false) Favorite folders."),
              "color": choice(shelfColorKeys + ["none"], "Folder colour, or none for the project's colour.")], required: ["project", "path"]),
        tool("update_checklist", "Update checklist", "Add, complete, reopen or remove to-dos in a project's checklist. Existing to-dos are matched by title (case-insensitive) or id.",
             ["project": projectArg, "add": list("New to-dos."), "complete": list("To-dos to tick off."), "reopen": list("To-dos to untick."), "remove": list("To-dos to delete.")], required: ["project"]),
        tool("add_existing_folder", "Add existing folder", "Put an existing folder on the DevShelf shelf as a project, without moving it.",
             ["path": text("Absolute path of the folder."), "name": text("Project name (default: the folder name)."), "color": choice(shelfColorKeys, "Colour."), "icon": text("SF Symbol name.")], required: ["path"]),
        tool("remove_from_shelf", "Remove from DevShelf", "Remove a project from DevShelf. Its folder and files stay on disk.", ["project": projectArg], required: ["project"]),
        tool("find_duplicates", "Find duplicate files", "Find identical files (256 KB and larger) in one project or all projects, optionally including leftover copies in Downloads, Desktop and Documents. Reports which copies really use extra disk space and which are space-sharing APFS clones, and suggests which copy to keep. Use trash_items to remove extras (only inside projects).",
             ["project": text("Limit to this project (id or name); default: all projects and the DevShelf Projects folder."), "include_outside": flag("Also look in ~/Downloads, ~/Desktop and ~/Documents for copies of project files.")], readOnly: true),
        tool("list_drives", "List drives", "List external drives (connected or known) and which projects have copies on them.", [:], readOnly: true),
        tool("transfer_to_drive", "Transfer to drive", "Copy a project with all its files to an external drive (only new and changed files on later runs; nothing on the drive is deleted). With mode \"move\" the Mac folder goes to the Trash afterwards.",
             ["project": projectArg, "drive": text("Drive name from list_drives."), "mode": choice(["copy", "move"], "copy (default) or move.")], required: ["project", "drive"]),
        tool("list_scanned_projects", "List scanned folders", "Search the development projects DevShelf found by scanning the Mac (Node, PHP, Python, WordPress, Git…), e.g. to bring a code folder into a project with add_files.",
             ["query": text("Part of the name, path or framework."), "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Maximum results (default 50)."]], readOnly: true),
        tool("list_templates", "List templates", "List folder templates, the standard folder types and the user's default folders for new projects.", [:], readOnly: true),
        tool("zip_folder", "Zip folder", "Create a .zip of a project or a folder inside it, for sharing. Leaves out node_modules and caches, .git, .env files and DevShelf details unless asked.",
             ["project": projectArg, "path": text("Folder inside the project (default: the whole project)."), "output": text("Where to save the .zip (default: ~/Desktop)."),
              "include_git": flag("Include .git."), "include_env": flag("Include .env files."), "include_dependencies": flag("Include node_modules and caches.")], required: ["project"]),
    ]

    // MARK: Calls

    func call(_ name: String, _ a: MCPArgs, client: String) throws -> String {
        store.load()
        switch name {
        case "list_projects":
            let query = a.string("query") ?? "", done = a.bool("include_done") ?? true
            let projects = store.library.projects.filter { $0.matches(query) && (done || $0.status != .done) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return json(["projects": projects.map(store.summary), "projects_folder": store.library.rootURL.path])

        case "get_project":
            let project = store.library.projects[try store.index(try a.require("project"))]
            var details = store.summary(project)
            details["notes"] = project.notes
            details["checklist"] = project.tasks.map { ["id": $0.id, "title": $0.title, "done": $0.done] }
            details["folder_marks"] = project.folderMarks.map { path, mark -> [String: Any] in ["folder": path, "pinned": mark.pinned, "favorite": mark.favorite, "color": mark.color ?? "project colour"] }
            details["logins"] = project.logins.map { ["label": $0.label, "username": $0.username, "url": $0.url, "password": "stored in the macOS Keychain; not available"] }
            if let root = store.folder(project) {
                details["files"] = tree(root, depth: 2, hidden: false, limit: 250)
                details["file_types"] = FileKinds.scan(root).map { ["type": $0.title, "files": $0.files.count, "bytes": $0.bytes] }
                if a.bool("include_git") ?? true {
                    details["git"] = Git.repositories(in: root).map(Git.status).map { info -> [String: Any] in
                        ["repository": store.relative(URL(fileURLWithPath: info.path), to: root).nilIfEmpty ?? ".", "branch": info.branch, "uncommitted_changes": info.changes,
                         "commits_not_pushed": info.ahead, "commits_behind": info.behind, "has_remote": info.upstream, "error": info.error ?? ""]
                    }
                }
            }
            return json(details)

        case "create_project":
            let projectName = ShelfFiles.folderName(try a.require("name"))
            let template = try a.string("template").map { reference -> ProjectTemplate in
                guard let match = store.templates.first(where: { $0.id == reference || $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }) else {
                    throw MCPToolError(message: "No template “\(reference)”. Templates: " + store.templates.map(\.name).joined(separator: ", ") + ".")
                }
                return match
            }
            let folders = !a.strings("folders").isEmpty ? a.strings("folders") : template?.folders ?? store.prefs.starterFolders
            let parent: URL
            let place = a.string("location") ?? "mac"
            if place.lowercased() == "mac" || place.lowercased() == "this mac" { parent = store.library.rootURL }
            else {
                guard let drive = store.volumes.first(where: { $0.external && ($0.name.localizedCaseInsensitiveCompare(place) == .orderedSame || $0.uuid == place) }) else {
                    throw MCPToolError(message: "No connected drive called “\(place)”. Connected drives: " + (store.volumes.filter(\.external).map(\.name).joined(separator: ", ").nilIfEmpty ?? "none") + ".")
                }
                parent = drive.url.appendingPathComponent("DevShelf Projects")
            }
            var project = ShelfProject(name: projectName, color: color(a.string("color")) ?? shelfColorKeys[store.library.projects.count % shelfColorKeys.count],
                                       icon: a.string("icon") ?? template?.icon ?? "folder.fill", notes: a.string("notes") ?? "", location: FolderLocation(path: ""))
            let folder = try ShelfFiles.create(project, in: parent, starterFolders: folders)
            project.location = Volumes.location(for: folder)
            store.library.projects.append(project)
            store.save()
            log(client, name, "Created project “\(project.name)” with \(ShelfFiles.children(of: folder).filter(\.isFolder).count) folders")
            return json(["created": store.summary(project)])

        case "update_project":
            let index = try store.index(try a.require("project"))
            let old = store.library.projects[index]
            var project = old
            if let newName = a.string("name") { project.name = ShelfFiles.folderName(newName) }
            if let value = a.string("color") { guard let key = color(value) else { throw MCPToolError(message: "Colours: " + shelfColorKeys.joined(separator: ", ") + ".") }; project.color = key }
            if let icon = a.string("icon") { project.icon = icon }
            if let notes = a.values["notes"] as? String { project.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value = a.string("status") {
                guard let status = ProjectStatus(rawValue: value) else { throw MCPToolError(message: "Status must be active, waiting, onHold or done.") }
                project.status = status
            }
            if project.name != old.name, let url = store.status(old.location).url, url.lastPathComponent == ShelfFiles.folderName(old.name) {
                let renamed = ShelfFiles.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(ShelfFiles.folderName(project.name)))
                try FileManager.default.moveItem(at: url, to: renamed)
                project.location = Volumes.location(for: renamed)
                project.location.synced = old.location.synced
            }
            store.library.projects[index] = project
            store.save(); store.writeMetadata(index)
            log(client, name, "Updated “\(project.name)”")
            return json(["updated": store.summary(project)])

        case "create_folders":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            let made = try ShelfFiles.createFolders(a.strings("paths"), in: root)
            guard !made.isEmpty else { throw MCPToolError(message: "No valid folder paths were given.") }
            log(client, name, "Created \(made.count) folder\(made.count == 1 ? "" : "s") in “\(store.library.projects[index].name)”")
            return json(["created": made])

        case "list_files":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            let folder = try store.inside(root, a.string("path"))
            guard FileManager.default.fileExists(atPath: folder.path) else { throw MCPToolError(message: "“\(a.string("path") ?? "")” doesn't exist in this project.") }
            return tree(folder, depth: min(5, max(1, a.int("depth") ?? 2)), hidden: a.bool("show_hidden") ?? false, limit: 500).nilIfEmpty ?? "(empty folder)"

        case "find_files":
            let query = a.string("query"), kind = a.string("kind")
            guard query != nil || kind != nil else { throw MCPToolError(message: "Give a query, a kind, or both.") }
            let indices = try a.string("project").map { [try store.index($0)] } ?? Array(store.library.projects.indices)
            var found: [[String: Any]] = []
            for index in indices {
                guard let root = store.folder(store.library.projects[index]) else { continue }
                for group in FileKinds.scan(root) where kind == nil || group.id == kind {
                    for file in group.files where query.map({ file.name.localizedCaseInsensitiveContains($0) }) ?? true {
                        found.append(["project": store.library.projects[index].name, "path": store.relative(file.url, to: root), "type": group.title,
                                      "bytes": file.size ?? 0, "modified": file.modified.map { ISO8601DateFormatter().string(from: $0) } ?? ""])
                        if found.count >= 200 { return json(["files": found, "truncated": true]) }
                    }
                }
            }
            return json(["files": found])

        case "add_files":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            let destination = try store.inside(root, a.string("destination"))
            let sources = a.strings("sources").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL }
            guard !sources.isEmpty else { throw MCPToolError(message: "Give at least one source path.") }
            if let missing = sources.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) { throw MCPToolError(message: "“\(missing.path)” doesn't exist.") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let mode = a.string("mode") ?? "auto"
            let skip = (a.bool("skip_dependencies") ?? store.prefs.skipDependencies) ? ShelfFiles.regenerable : []
            let effective = mode == "auto" ? store.prefs.addMode : mode
            let moves = try ShelfFiles.transfer(sources, into: destination, projectRoot: root, move: effective == "move", link: effective == "link", skipping: skip)
            func how(_ item: (source: URL, destination: URL)) -> String {
                ShelfFiles.linkDestination(item.destination) != nil && ShelfFiles.linkDestination(item.source) == nil ? "linked" : FileManager.default.fileExists(atPath: item.source.path) ? "copied" : "moved"
            }
            let hows = Set(moves.map(how))
            let verb = hows.count == 1 ? hows.first!.capitalized : "Added"
            log(client, name, "\(verb) \(moves.count) item\(moves.count == 1 ? "" : "s") to “\(store.library.projects[index].name)”" + (destination.path == root.standardizedFileURL.path ? "" : " › " + store.relative(destination, to: root)))
            return json(["added": moves.map { ["path": store.relative($0.destination, to: root), "how": how($0)] }])

        case "move_items":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            let destination = try store.inside(root, try a.require("destination"))
            let items = try a.strings("items").map { try store.inside(root, $0) }
            guard !items.isEmpty else { throw MCPToolError(message: "Give at least one item.") }
            try store.refuseOriginals(items, root: root, action: "move")
            if items.contains(where: { $0.path == root.standardizedFileURL.path }) { throw MCPToolError(message: "The project folder itself can't be moved.") }
            if let missing = items.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) { throw MCPToolError(message: "“\(store.relative(missing, to: root))” doesn't exist.") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let moves = try ShelfFiles.transfer(items, into: destination, projectRoot: root)
            let moved = moves.map(\.destination)
            for item in moves { store.library.projects[index].moveMarks(from: store.relative(item.source, to: root), to: store.relative(item.destination, to: root)) }
            store.save(); store.writeMetadata(index)
            log(client, name, "Moved \(moved.count) item\(moved.count == 1 ? "" : "s") in “\(store.library.projects[index].name)” to \(store.relative(destination, to: root).nilIfEmpty ?? "the top")")
            return json(["moved": moved.map { store.relative($0, to: root) }])

        case "rename_item":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            let item = try store.inside(root, try a.require("path"))
            guard item.path != root.standardizedFileURL.path else { throw MCPToolError(message: "Use update_project to rename the project.") }
            guard FileManager.default.fileExists(atPath: item.path) || ShelfFiles.linkDestination(item) != nil else { throw MCPToolError(message: "“\(a.string("path")!)” doesn't exist.") }
            try store.refuseOriginals([item], root: root, action: "rename")
            let newName = try a.require("new_name").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            guard newName != ".", newName != ".." else { throw MCPToolError(message: "That name isn't allowed.") }
            let target = item.deletingLastPathComponent().appendingPathComponent(newName)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw MCPToolError(message: "Something named “\(newName)” already exists there.") }
            try FileManager.default.moveItem(at: item, to: target)
            store.library.projects[index].moveMarks(from: store.relative(item, to: root), to: store.relative(target, to: root))
            store.save(); store.writeMetadata(index)
            log(client, name, "Renamed “\(item.lastPathComponent)” to “\(newName)” in “\(store.library.projects[index].name)”")
            return json(["renamed": store.relative(target, to: root)])

        case "trash_items":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            var trashed: [String] = []
            for path in a.strings("paths") {
                let item = try store.inside(root, path)
                guard item.path != root.standardizedFileURL.path else { throw MCPToolError(message: "The project folder itself can't be trashed here.") }
                guard item.lastPathComponent != ShelfFiles.metadataName, FileManager.default.fileExists(atPath: item.path) || ShelfFiles.linkDestination(item) != nil else { continue }
                try store.refuseOriginals([item], root: root, action: "trash")
                // A link is simply removed; the original it points to is never trashed.
                if ShelfFiles.linkDestination(item) != nil { try FileManager.default.removeItem(at: item) }
                else { try FileManager.default.trashItem(at: item, resultingItemURL: nil) }
                trashed.append(store.relative(item, to: root))
                store.library.projects[index].moveMarks(from: store.relative(item, to: root), to: nil)
            }
            if !trashed.isEmpty { store.save(); store.writeMetadata(index) }
            if !trashed.isEmpty { log(client, name, "Moved \(trashed.count) item\(trashed.count == 1 ? "" : "s") from “\(store.library.projects[index].name)” to the Trash") }
            return json(["trashed": trashed])

        case "mark_folder":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            let folder = try store.inside(root, try a.require("path"))
            var isFolder: ObjCBool = false
            guard folder.path != root.standardizedFileURL.path, FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw MCPToolError(message: "“\(a.string("path")!)” isn't a folder inside the project.")
            }
            let key = store.relative(folder, to: root)
            var mark = store.library.projects[index].folderMarks[key] ?? FolderMark()
            if let pinned = a.bool("pinned") { mark.pinned = pinned }
            if let favorite = a.bool("favorite") { mark.favorite = favorite }
            if let value = a.string("color") {
                if value == "none" { mark.color = nil }
                else { guard let colour = color(value) else { throw MCPToolError(message: "Colours: " + shelfColorKeys.joined(separator: ", ") + ", none.") }; mark.color = colour }
            }
            store.library.projects[index].folderMarks[key] = mark.isEmpty ? nil : mark
            store.save(); store.writeMetadata(index)
            log(client, name, "Marked “\(folder.lastPathComponent)” in “\(store.library.projects[index].name)”" + [mark.pinned ? " · pinned" : "", mark.favorite ? " · favourite" : "", mark.color.map { " · " + $0 } ?? ""].joined())
            return json(["folder": key, "pinned": mark.pinned, "favorite": mark.favorite, "color": mark.color ?? "project colour"])

        case "update_checklist":
            let index = try store.index(try a.require("project"))
            var tasks = store.library.projects[index].tasks
            func find(_ reference: String) -> Int? { tasks.firstIndex { $0.id == reference || $0.title.localizedCaseInsensitiveCompare(reference) == .orderedSame } }
            var notFound: [String] = []
            for title in a.strings("add") where find(title) == nil { tasks.append(ProjectTask(title: title)) }
            for reference in a.strings("complete") { if let i = find(reference) { tasks[i].done = true } else { notFound.append(reference) } }
            for reference in a.strings("reopen") { if let i = find(reference) { tasks[i].done = false } else { notFound.append(reference) } }
            for reference in a.strings("remove") { if let i = find(reference) { tasks.remove(at: i) } else { notFound.append(reference) } }
            store.library.projects[index].tasks = tasks
            store.save(); store.writeMetadata(index)
            log(client, name, "Updated the checklist of “\(store.library.projects[index].name)”")
            return json(["checklist": tasks.map { ["id": $0.id, "title": $0.title, "done": $0.done] }, "not_found": notFound])

        case "add_existing_folder":
            let url = URL(fileURLWithPath: NSString(string: try a.require("path")).expandingTildeInPath).standardizedFileURL
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { throw MCPToolError(message: "“\(url.path)” isn't a folder.") }
            if let existing = store.library.projects.first(where: { $0.allLocations.contains { self.store.status($0).url?.standardizedFileURL.path == url.path } }) {
                return json(["already_on_shelf": store.summary(existing)])
            }
            let location = Volumes.location(for: url)
            var project: ShelfProject
            if let metadata = ShelfFiles.readMetadata(in: url), !store.library.projects.contains(where: { $0.id == metadata.id }) { project = metadata.project(at: location) }
            else { project = ShelfProject(name: url.lastPathComponent, color: shelfColorKeys[store.library.projects.count % shelfColorKeys.count], location: location) }
            if let newName = a.string("name") { project.name = newName }
            if let key = color(a.string("color")) { project.color = key }
            if let icon = a.string("icon") { project.icon = icon }
            try? ShelfFiles.writeMetadata(project, to: url)
            store.library.projects.append(project)
            store.save()
            log(client, name, "Added “\(project.name)” to DevShelf")
            return json(["added": store.summary(project)])

        case "remove_from_shelf":
            let index = try store.index(try a.require("project"))
            let project = store.library.projects.remove(at: index)
            store.save()
            log(client, name, "Removed “\(project.name)” from DevShelf (files kept)")
            return json(["removed": project.name, "folder_kept_at": project.location.path])

        case "find_duplicates":
            var places: [(name: String, url: URL)] = []
            if let reference = a.string("project") {
                let index = try store.index(reference)
                places = [(store.library.projects[index].name, try store.availableFolder(index))]
            } else {
                places = store.library.projects.compactMap { project in store.folder(project).map { (project.name, $0) } }
                if FileManager.default.fileExists(atPath: store.library.rootURL.path) { places.append(("DevShelf Projects", store.library.rootURL)) }
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let outside = (a.bool("include_outside") ?? false) ? ["Downloads", "Desktop", "Documents"].map { ($0, home.appendingPathComponent($0)) } : []
            let groups = try Duplicates.scan(places: places, outside: outside)
            let wasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
            return json(["wasted_bytes": wasted, "groups": groups.prefix(150).map { group -> [String: Any] in
                ["file": group.name, "bytes_each": group.size, "copies": group.files.count, "wasted_bytes": group.wastedBytes,
                 "keep": group.suggestedKeeper?.url.path ?? "",
                 "paths": group.files.map { ["path": $0.url.path, "where": $0.place, "in_project": $0.inProject, "shares_space_with_another_copy": group.sharesSpace($0)] }]
            }, "truncated": groups.count > 150])

        case "list_drives":
            var drives: [[String: Any]] = store.volumes.filter(\.external).map { drive in
                ["name": drive.name, "connected": true, "path": drive.url.path, "free_bytes": drive.freeSpace ?? 0,
                 "projects": store.library.projects.filter { $0.allLocations.contains { $0.volumeUUID == drive.uuid } }.map(\.name)]
            }
            let connected = Set(store.volumes.map(\.uuid))
            var offline: [String: String] = [:]
            for project in store.library.projects { for location in project.allLocations { if let id = location.volumeUUID, !connected.contains(id) { offline[id] = location.volumeName ?? "Drive" } } }
            for (id, driveName) in offline {
                drives.append(["name": driveName, "connected": false, "projects": store.library.projects.filter { $0.allLocations.contains { $0.volumeUUID == id } }.map(\.name)])
            }
            return json(["drives": drives])

        case "transfer_to_drive":
            let index = try store.index(try a.require("project"))
            let source = try store.availableFolder(index)
            let driveName = try a.require("drive")
            guard let volume = store.volumes.first(where: { $0.external && ($0.name.localizedCaseInsensitiveCompare(driveName) == .orderedSame || $0.uuid == driveName) }) else {
                throw MCPToolError(message: "No connected drive called “\(driveName)”. Connected: " + (store.volumes.filter(\.external).map(\.name).joined(separator: ", ").nilIfEmpty ?? "none") + ".")
            }
            var project = store.library.projects[index]
            let existing = project.allLocations.first { $0.volumeUUID == volume.uuid }
            if existing == project.location { throw MCPToolError(message: "“\(project.name)” already lives on \(volume.name).") }
            let destination = existing.flatMap { store.status($0).url } ?? ShelfFiles.uniqueURL(volume.url.appendingPathComponent("DevShelf Projects").appendingPathComponent(source.lastPathComponent))
            guard !ShelfFiles.contains(destination.path, in: source.path), !ShelfFiles.contains(source.path, in: destination.path) else { throw MCPToolError(message: "The project and the drive copy overlap.") }
            let report = try ShelfFiles.sync(from: source, to: destination)
            var location = Volumes.location(for: destination, on: volume)
            location.synced = Date()
            project.copies.removeAll { $0.volumeUUID == volume.uuid }
            project.copies.append(location)
            var moved = false
            if a.string("mode") == "move", store.status(project.location).url == source, (try? FileManager.default.trashItem(at: source, resultingItemURL: nil)) != nil {
                project.copies.removeAll { $0.volumeUUID == volume.uuid }
                project.location = location
                moved = true
            }
            try? ShelfFiles.writeMetadata(project, to: destination)
            store.library.projects[index] = project
            store.save()
            log(client, name, "\(moved ? "Moved" : "Copied") “\(project.name)” to \(volume.name) (\(report.copied) files)")
            return json(["drive": volume.name, "path": destination.path, "copied_files": report.copied, "unchanged_files": report.unchanged, "bytes": report.bytes, "moved": moved])

        case "list_scanned_projects":
            let query = a.string("query") ?? ""
            let inventory = Persistence.read("inventory.json", as: Inventory.self) ?? Inventory()
            let matches = inventory.projects.filter { query.isEmpty || ($0.name + " " + $0.path + " " + $0.framework + " " + $0.kind).localizedCaseInsensitiveContains(query) }
            return json(["scanned_at": ISO8601DateFormatter().string(from: inventory.scannedAt),
                         "projects": matches.prefix(min(200, max(1, a.int("limit") ?? 50))).map { ["name": $0.name, "path": $0.path, "kind": $0.kind, "framework": $0.framework, "summary": $0.summary] }])

        case "list_templates":
            return json(["templates": store.templates.map { ["id": $0.id, "name": $0.name, "folders": $0.folders] },
                         "folder_types": ShelfFiles.folderOptions.map(\.name), "default_folders": store.prefs.starterFolders])

        case "zip_folder":
            let index = try store.index(try a.require("project"))
            let root = try store.availableFolder(index)
            let folder = try store.inside(root, a.string("path"))
            var options = ZipOptions()
            options.skipGit = !(a.bool("include_git") ?? false)
            options.skipSecrets = !(a.bool("include_env") ?? false)
            options.skipDependencies = !(a.bool("include_dependencies") ?? false)
            let base = folder.path == root.standardizedFileURL.path ? root.lastPathComponent : root.lastPathComponent + " - " + folder.lastPathComponent
            var archive = a.string("output").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(base + ".zip")
            if archive.pathExtension.lowercased() != "zip" { archive = archive.appendingPathComponent(base + ".zip") }
            archive = ShelfFiles.uniqueURL(archive)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder.deletingLastPathComponent()
            process.arguments = options.arguments(item: folder.lastPathComponent, archive: archive)
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            guard ZipOptions.succeeded(process.terminationStatus) else { throw MCPToolError(message: "zip failed (status \(process.terminationStatus)).") }
            log(client, name, "Zipped “\(folder.lastPathComponent)” to \(archive.lastPathComponent)")
            return json(["zip": archive.path, "bytes": (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0])

        default:
            throw MCPToolError(message: "Unknown tool \(name).")
        }
    }

    // MARK: Helpers

    func color(_ value: String?) -> String? {
        guard let value else { return nil }
        return shelfColorKeys.first { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    func log(_ client: String, _ tool: String, _ summary: String) { MCPLog.append(MCPLogEntry(client: client, tool: tool, summary: summary)) }

    func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// An indented listing; rebuildable folders are shown but not opened.
    func tree(_ folder: URL, depth: Int, hidden: Bool, limit: Int) -> String {
        var lines: [String] = []
        func walk(_ url: URL, _ level: Int) {
            for item in ShelfFiles.children(of: url, showHidden: hidden) {
                if lines.count >= limit { return }
                let indent = String(repeating: "  ", count: level)
                if item.isFolder {
                    let skipped = ShelfFiles.regenerable.contains(item.name) || item.name == ".git"
                    let count = (try? FileManager.default.contentsOfDirectory(atPath: item.url.path).filter { hidden || !$0.hasPrefix(".") }.count) ?? 0
                    lines.append(indent + item.name + "/  (\(count) item\(count == 1 ? "" : "s")\(skipped ? ", not listed" : ""))")
                    if level + 1 < depth && !skipped { walk(item.url, level + 1) }
                } else {
                    lines.append(indent + item.name + "  " + ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                }
            }
        }
        walk(folder, 0)
        if lines.count >= limit { lines.append("… more items not shown; use list_files with a path or smaller depth.") }
        return lines.joined(separator: "\n")
    }
}
