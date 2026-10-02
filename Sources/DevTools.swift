import Foundation
import Security

// MARK: - Logins

/// A saved login. Only the label, username and address are stored with the project;
/// the password lives in the macOS Keychain on this Mac.
struct LoginItem: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var label: String
    var username = ""
    var url = ""
    var notes = ""
}

enum CredentialVault {
    static let service = "com.local.devshelf.logins"

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    static func save(_ password: String, for id: String, label: String) throws {
        let data = Data(password.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "DevShelf · " + label]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id).merging(attributes) { $1 }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw OrganizerError.message("The password could not be saved in macOS Keychain (\(status)).") }
    }

    static func load(_ id: String) -> String? {
        var item = query(id)
        item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

// MARK: - Templates

/// A reusable set of folders for new projects.
struct ProjectTemplate: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var icon = "folder.fill"
    var folders: [String] = []

    static let builtIn: [ProjectTemplate] = [
        ProjectTemplate(id: "web", name: "Web app", icon: "globe", folders: ["Code", "Design", "Documents", "Images", "Fonts", "Database", "Deliverables"]),
        ProjectTemplate(id: "wordpress", name: "WordPress", icon: "puzzlepiece.extension.fill", folders: ["Code/theme", "Code/plugins", "Design", "Images", "Database", "Backups", "Deliverables"]),
        ProjectTemplate(id: "mobile", name: "Mobile app", icon: "iphone", folders: ["Code", "Design", "Images", "Screenshots", "Documents", "Builds"]),
        ProjectTemplate(id: "design", name: "Design", icon: "paintbrush.pointed.fill", folders: ["Design", "Images", "Fonts", "Brand", "Documents", "Deliverables"]),
        ProjectTemplate(id: "media", name: "Video & media", icon: "film.fill", folders: ["Videos", "Audio", "Images", "Documents", "Deliverables"]),
    ]

    /// Captures a project's folder layout: two levels, without the inside of code repositories.
    static func capture(_ project: ShelfProject, folder: URL, name: String) -> ProjectTemplate {
        var folders: [String] = []
        for item in ShelfFiles.children(of: folder) where item.isFolder && !ShelfFiles.regenerable.contains(item.name) {
            folders.append(item.name)
            if Git.isCodeFolder(item.url) { continue }
            for child in ShelfFiles.children(of: item.url) where child.isFolder && !Git.isCodeFolder(child.url) && !ShelfFiles.regenerable.contains(child.name) {
                folders.append(item.name + "/" + child.name)
            }
        }
        return ProjectTemplate(name: name, icon: project.icon, folders: folders)
    }
}

// MARK: - File types

struct FileGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var files: [FileItem] = []
    var bytes: Int64 = 0
}

/// Sorts a project's files into types (images, documents, code…) wherever they are stored.
enum FileKinds {
    static let kinds: [(id: String, title: String, symbol: String, extensions: Set<String>)] = [
        ("images", "Images", "photo.fill", ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "tif", "tiff", "bmp", "ico", "avif", "raw"]),
        ("design", "Design files", "paintbrush.pointed.fill", ["fig", "sketch", "psd", "ai", "xd", "afdesign", "afphoto", "indd", "eps", "procreate"]),
        ("documents", "Documents", "doc.text.fill", ["pdf", "doc", "docx", "pages", "txt", "rtf", "md", "markdown", "odt"]),
        ("sheets", "Spreadsheets", "tablecells.fill", ["xls", "xlsx", "csv", "tsv", "numbers", "ods"]),
        ("slides", "Presentations", "rectangle.on.rectangle.angled", ["ppt", "pptx", "key", "odp"]),
        ("code", "Code", "chevron.left.forwardslash.chevron.right", ["js", "jsx", "mjs", "cjs", "ts", "tsx", "php", "py", "rb", "go", "rs", "swift", "java", "kt", "c", "cpp", "h", "hpp", "cs", "html", "htm", "css", "scss", "sass", "less", "vue", "svelte", "astro", "json", "yml", "yaml", "toml", "xml", "sh", "zsh", "dart", "lua"]),
        ("database", "Databases", "cylinder.split.1x2.fill", ["sql", "sqlite", "sqlite3", "db", "dump"]),
        ("video", "Videos", "film.fill", ["mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv"]),
        ("audio", "Audio", "waveform", ["mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff"]),
        ("fonts", "Fonts", "textformat", ["ttf", "otf", "woff", "woff2", "eot"]),
        ("archives", "Archives", "archivebox.fill", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "dmg", "iso"]),
    ]
    static let other = (id: "other", title: "Other", symbol: "doc.fill")

    static func kind(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return kinds.first { $0.extensions.contains(ext) }?.id ?? other.id
    }

    /// Groups every file in `root`, skipping hidden files, dependencies and build output.
    static func scan(_ root: URL, maxFiles: Int = 50_000) -> [FileGroup] {
        var groups: [String: FileGroup] = [:]
        var seen = 0
        // Linked folders are included: their files belong to the project even though they live elsewhere.
        ShelfFiles.walk(root, keys: [.fileSizeKey, .contentModificationDateKey], skip: { ShelfFiles.regenerable.contains($0.lastPathComponent) || ["dist", "build", "vendor"].contains($0.lastPathComponent) }) { url, values in
            if ShelfFiles.ignored.contains(url.lastPathComponent) { return true }
            seen += 1
            if seen > maxFiles { return false }
            let id = kind(of: url)
            let size = values.fileSize.map(Int64.init)
            if groups[id] == nil {
                let info = kinds.first { $0.id == id }
                groups[id] = FileGroup(id: id, title: info?.title ?? other.title, symbol: info?.symbol ?? other.symbol)
            }
            groups[id]!.files.append(FileItem(url: url, isFolder: false, size: size, modified: values.contentModificationDate))
            groups[id]!.bytes += size ?? 0
            return true
        }
        let order = kinds.map(\.id) + [other.id]
        return order.compactMap { groups[$0] }
    }
}

// MARK: - Git

struct GitInfo: Identifiable, Equatable {
    var path: String
    var branch = ""
    var changes = 0
    var ahead = 0
    var behind = 0
    var upstream = false
    var detached = false
    var noCommits = false
    var error: String?
    var id: String { path }
    var needsAttention: Bool { error == nil && (changes > 0 || ahead > 0 || (!upstream && !noCommits && !detached)) }
}

enum Git {
    static func isCodeFolder(_ url: URL) -> Bool {
        ["package.json", "composer.json", "pyproject.toml", ".git"].contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    /// Git repositories inside `root`, a few levels deep. Repositories are not searched inside.
    static func repositories(in root: URL, depth: Int = 3) -> [URL] {
        var found: [URL] = []
        var queue = [(root, 0)]
        while !queue.isEmpty {
            let (folder, level) = queue.removeFirst()
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { found.append(folder); continue }
            guard level < depth else { continue }
            for item in ShelfFiles.children(of: folder) where item.isFolder && !ShelfFiles.regenerable.contains(item.name) && !ProjectScanner.excluded.contains(item.name) {
                queue.append((item.url, level + 1))
            }
        }
        return found
    }

    static func parse(_ output: String, path: String) -> GitInfo {
        var info = GitInfo(path: path)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if var header = lines.first, header.hasPrefix("## ") {
            header.removeFirst(3)
            if header.hasPrefix("No commits yet on ") { info.noCommits = true; info.branch = String(header.dropFirst("No commits yet on ".count)); header = "" }
            else if header.hasPrefix("HEAD (no branch)") { info.detached = true; info.branch = "detached HEAD"; header = "" }
            if let range = header.range(of: "...") {
                info.branch = String(header[..<range.lowerBound])
                let rest = header[range.upperBound...]
                info.upstream = !rest.contains("[gone]")
                if let match = rest.firstMatch(of: #/ahead (\d+)/#) { info.ahead = Int(match.1) ?? 0 }
                if let match = rest.firstMatch(of: #/behind (\d+)/#) { info.behind = Int(match.1) ?? 0 }
            } else if !header.isEmpty { info.branch = header }
        }
        info.changes = lines.dropFirst().filter { !$0.isEmpty }.count
        return info
    }

    static func status(_ repo: URL) -> GitInfo {
        guard let git = ProjectScanner.executable("git") else { return GitInfo(path: repo.path, error: "Git is not installed.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repo.path, "status", "--porcelain=v1", "-b", "--untracked-files=normal"]
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { return GitInfo(path: repo.path, error: error.localizedDescription) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return GitInfo(path: repo.path, error: errorText.split(separator: "\n").first.map(String.init) ?? "git status failed")
        }
        return parse(String(data: data, encoding: .utf8) ?? "", path: repo.path)
    }
}

// MARK: - Activity

struct ActivityItem: Identifiable, Hashable {
    let url: URL
    let projectID: String
    let modified: Date
    let size: Int64?
    var id: String { url.path }
}

enum Activity {
    /// Files changed since `since`, newest first. Skips hidden files, dependencies and caches.
    static func recentFiles(in root: URL, projectID: String, since: Date, limit: Int = 300, maxScanned: Int = 60_000) -> [ActivityItem] {
        var items: [ActivityItem] = []
        var scanned = 0
        ShelfFiles.walk(root, keys: [.contentModificationDateKey, .fileSizeKey], skip: { ShelfFiles.regenerable.contains($0.lastPathComponent) || ["dist", "build", "vendor"].contains($0.lastPathComponent) }) { url, values in
            scanned += 1
            if scanned > maxScanned { return false }
            guard let modified = values.contentModificationDate, modified >= since, !ShelfFiles.ignored.contains(url.lastPathComponent) else { return true }
            items.append(ActivityItem(url: url, projectID: projectID, modified: modified, size: values.fileSize.map(Int64.init)))
            return true
        }
        return Array(items.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}

// MARK: - Zip

struct ZipOptions: Equatable {
    var skipDependencies = true
    var skipGit = true
    var skipSecrets = true
    var skipDevShelfDetails = true

    var exclusions: [String] {
        var patterns = ["*.DS_Store", "*/__MACOSX/*"]
        if skipDependencies { patterns += ShelfFiles.regenerable.sorted().flatMap { ["*/\($0)/*", "\($0)/*"] } }
        if skipGit { patterns += ["*/.git/*", ".git/*"] }
        if skipSecrets { patterns += ["*/.env", "*/.env.*", ".env", ".env.*"] }
        if skipDevShelfDetails { patterns += ["*/" + ShelfFiles.metadataName, ShelfFiles.metadataName] }
        return patterns
    }

    /// zip exits with 18 when some files couldn't be read (e.g. a link whose original is gone); the zip is still made.
    static func succeeded(_ status: Int32) -> Bool { status == 0 || status == 18 }

    /// Arguments for /usr/bin/zip, run from the item's parent folder.
    func arguments(item: String, archive: URL) -> [String] {
        // Without -y, zip stores what links point to, so linked originals are included.
        ["-r", "-q", "-X", archive.path, item, "-x"] + exclusions
    }
}
