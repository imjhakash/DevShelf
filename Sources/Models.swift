import Foundation

struct Dependency: Codable, Identifiable {
    var id: String { name }
    let name: String
    let requested: String
    let development: Bool
}

struct Project: Codable, Identifiable {
    var id: String { path }
    let name: String
    let packageName: String?
    let path: String
    let kind: String
    let framework: String
    let summary: String
    let modified: Date
    let git: Bool
    let dependenciesInstalled: Bool
    let dependencies: [Dependency]
    let scripts: [String: String]
    var symbol: String {
        switch kind {
        case "WordPress plugin": return "puzzlepiece.extension.fill"
        case "WordPress site": return "globe"
        case "Node project": return "curlybraces"
        case "Python project": return "terminal.fill"
        case "PHP project": return "chevron.left.forwardslash.chevron.right"
        case "Website": return "safari.fill"
        case "Folder": return "folder.fill"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct InstalledTool: Codable, Identifiable {
    var id: String { path }
    let name: String
    let version: String
    let path: String
    let category: String
}

struct Inventory: Codable {
    var projects: [Project] = []
    var tools: [InstalledTool] = []
    var warnings: [String] = []
    var scannedFolders = 0
    var scannedAt = Date()
}

struct Settings: Codable {
    var roots: [String]
    var favorites: Set<String> = []
    var lastOpened: [String: Date] = [:]
    static var defaults: Settings {
        Settings(roots: [FileManager.default.homeDirectoryForCurrentUser.path])
    }
}

enum Persistence {
    static var directory: URL {
        // DEVSHELF_DATA_DIR lets tests (and the MCP server's checks) use a separate data folder.
        if let custom = ProcessInfo.processInfo.environment["DEVSHELF_DATA_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DevShelf")
    }
    static func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, to name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch { NSLog("DevShelf could not save %@: %@", name, error.localizedDescription) }
    }
}

enum ProjectScanner {
    // Never crawl dependencies, credentials, build output, app bundles, or OS caches.
    static let excluded: Set<String> = ["node_modules", "vendor", ".git", ".svn", ".hg", ".next", ".nuxt", ".svelte-kit", "dist", "build", ".build", "coverage", "__pycache__", ".venv", "venv", "env", ".npm", ".pnpm-store", ".yarn", ".cache", ".Trash", ".ssh", ".gnupg", ".aws", ".azure", ".config", ".vscode", ".vscode-insiders", ".cursor", ".antigravity", ".antigravity-ide", ".windsurf", ".rustup", ".cargo", ".nvm", ".volta", ".bun", ".gradle", ".m2", "wp-includes", "wp-admin"]

    static func json(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func scan(roots: [String]) -> Inventory {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var result = Inventory()
        var visited: Set<String> = []
        var stack = roots.map { (URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath(), false) }
        // Codex worktrees are real projects, even though the rest of .codex is app data.
        if stack.contains(where: { $0.0.path == home }) {
            let worktrees = URL(fileURLWithPath: home).appendingPathComponent(".codex/worktrees")
            if fm.fileExists(atPath: worktrees.path) { stack.append((worktrees, false)) }
        }
        while let (pendingFolder, insideProject) = stack.popLast() {
            let folder = pendingFolder.resolvingSymlinksInPath()
            if !visited.insert(folder.path).inserted { continue }
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [])
            } catch {
                if result.warnings.count < 30 { result.warnings.append("Could not read \(folder.path): \(error.localizedDescription)") }
                continue
            }
            result.scannedFolders += 1
            let names = Set(children.map(\.lastPathComponent))
            let project = detect(folder, names: names, children: children, allowStatic: !insideProject)
            if let project { result.projects.append(project) }
            for child in children {
                let name = child.lastPathComponent
                if excluded.contains(name) || [".codex", ".claude", ".gemini"].contains(name) { continue }
                if [".app", ".photoslibrary", ".framework", ".bundle", ".xcassets"].contains(where: { name.hasSuffix($0) }) { continue }
                if child.path == home + "/Library" { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                // A package's public/docs folder is part of that project. Independent
                // nested manifests and WordPress plugin headers still create cards.
                stack.append((child, insideProject || (project != nil && folder.path != home)))
            }
        }
        result.projects.sort { $0.modified > $1.modified }
        result.tools = tools()
        result.scannedAt = Date()
        return result
    }

    static func detect(_ folder: URL, names: Set<String>, children: [URL], allowStatic: Bool = true) -> Project? {
        var kind = "", framework = "", summary = ""
        var displayName = folder.lastPathComponent
        var packageName: String?
        var deps: [Dependency] = []
        var scripts: [String: String] = [:]
        let package = names.contains("package.json") ? json(folder.appendingPathComponent("package.json")) : nil
        if let package {
            packageName = package["name"] as? String
            summary = package["description"] as? String ?? ""
            for field in ["dependencies", "devDependencies"] {
                if let map = package[field] as? [String: String] {
                    let alreadyAdded = Set(deps.map(\.name))
                    deps += map.filter { !alreadyAdded.contains($0.key) }.map { Dependency(name: $0.key, requested: $0.value, development: field == "devDependencies") }
                }
            }
            scripts = package["scripts"] as? [String: String] ?? [:]
            let all = Set(deps.map(\.name))
            framework = [("next", "Next.js"), ("nuxt", "Nuxt"), ("@sveltejs/kit", "SvelteKit"), ("astro", "Astro"), ("@angular/core", "Angular"), ("react", "React"), ("vue", "Vue"), ("svelte", "Svelte"), ("express", "Express"), ("vite", "Vite")].first(where: { all.contains($0.0) })?.1 ?? "Node.js"
            kind = "Node project"
        }
        if names.contains("composer.json") {
            kind = kind.isEmpty ? "PHP project" : kind
            if let composer = json(folder.appendingPathComponent("composer.json")) {
                if summary.isEmpty { summary = composer["description"] as? String ?? "" }
                if let require = composer["require"] as? [String: String], require["laravel/framework"] != nil { framework = "Laravel" }
            }
            if framework.isEmpty { framework = "PHP" }
        }
        if names.contains("pyproject.toml") || names.contains("requirements.txt") || names.contains("setup.py") {
            if kind.isEmpty { kind = "Python project"; framework = "Python" }
        }
        if allowStatic && (names.contains("index.html") || names.contains("index.htm")) {
            if kind.isEmpty { kind = "Website"; framework = "HTML / CSS" }
        }
        if names.contains("wp-config.php") || names.contains("wp-load.php") {
            kind = "WordPress site"; framework = "WordPress"
            if ["public_html", "htdocs", "www"].contains(displayName) { displayName = folder.deletingLastPathComponent().lastPathComponent }
        } else {
            for file in children where file.pathExtension.lowercased() == "php" {
                guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory != true, values.isSymbolicLink != true,
                      let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let data = try? handle.read(upToCount: 8192)
                try? handle.close()
                guard let data, let header = String(data: data, encoding: .utf8),
                      let range = header.range(of: #"(?im)^[ \t/*#]*Plugin Name:[ \t]*(.+)$"#, options: .regularExpression) else { continue }
                let line = String(header[range])
                if let colon = line.firstIndex(of: ":") {
                    displayName = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*/", with: "").trimmingCharacters(in: .whitespaces)
                }
                kind = "WordPress plugin"; framework = "WordPress"
                if let descriptionRange = header.range(of: #"(?im)^[ \t/*#]*Description:[ \t]*(.+)$"#, options: .regularExpression) {
                    let descriptionLine = String(header[descriptionRange])
                    if let colon = descriptionLine.firstIndex(of: ":") { summary = String(descriptionLine[descriptionLine.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                break
            }
        }
        if kind.isEmpty && names.contains(".git") { kind = "Git repository"; framework = "Git" }
        guard !kind.isEmpty else { return nil }
        let metadata = ["package.json", "composer.json", "pyproject.toml", "index.html"].filter(names.contains).map { folder.appendingPathComponent($0) }
        let modification = ([folder] + metadata).compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? Date.distantPast
        return Project(name: displayName, packageName: packageName, path: folder.path, kind: kind, framework: framework, summary: summary, modified: modification, git: names.contains(".git"), dependenciesInstalled: names.contains("node_modules"), dependencies: deps.sorted { $0.name < $1.name }, scripts: scripts)
    }

    static func executable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.bun/bin", home + "/.volta/bin", "/usr/bin", "/bin"]
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        let nvm = URL(fileURLWithPath: home + "/.nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) { directories += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { $0.appendingPathComponent("bin").path } }
        return directories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func tools() -> [InstalledTool] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var tools: [InstalledTool] = []
        for name in ["node", "npm", "pnpm", "yarn", "bun", "git", "php", "python3", "composer", "docker", "code", "cursor"] {
            if let path = executable(name) { tools.append(InstalledTool(name: name, version: "Available", path: path, category: "Developer tool")) }
        }
        var moduleRoots: Set<String> = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules", home + "/.npm-global/lib/node_modules", home + "/.local/lib/node_modules"]
        if let npm = executable("npm") {
            var parent = URL(fileURLWithPath: npm).resolvingSymlinksInPath().deletingLastPathComponent()
            while parent.path != "/" {
                if parent.lastPathComponent == "node_modules" { moduleRoots.insert(parent.path); break }
                parent.deleteLastPathComponent()
            }
        }
        if let data = try? String(contentsOfFile: home + "/.npmrc", encoding: .utf8) {
            for line in data.components(separatedBy: .newlines) where line.trimmingCharacters(in: .whitespaces).hasPrefix("prefix=") {
                let prefix = String(line.dropFirst(line.firstIndex(of: "=")!.utf16Offset(in: line) + 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                moduleRoots.insert(NSString(string: prefix).expandingTildeInPath + "/lib/node_modules")
            }
        }
        if let versions = try? fm.contentsOfDirectory(atPath: home + "/.nvm/versions/node") { moduleRoots.formUnion(versions.map { home + "/.nvm/versions/node/" + $0 + "/lib/node_modules" }) }
        for root in moduleRoots.sorted() {
            guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            var packages: [URL] = []
            for entry in entries {
                if entry.lastPathComponent.hasPrefix("@") { packages += (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [] }
                else { packages.append(entry) }
            }
            for package in packages {
                guard let manifest = json(package.appendingPathComponent("package.json")), let name = manifest["name"] as? String else { continue }
                tools.append(InstalledTool(name: name, version: manifest["version"] as? String ?? "Unknown version", path: package.path, category: "Global npm package"))
            }
        }
        return tools.sorted { ($0.category, $0.name, $0.path) < ($1.category, $1.name, $1.path) }
    }
}
