import Foundation

let appVersion = "3.5.0"

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
/// Colour names a project can use (the app's palette).
let shelfColorKeys = ["blue", "teal", "green", "yellow", "orange", "red", "pink", "purple"]

// A project is a real folder on disk that holds all of a project's files. Its metadata is kept both in the app's
// index and in a small `.devshelf.json` inside the folder, so it travels with copies.

enum ProjectStatus: String, Codable, CaseIterable, Identifiable {
    case active, waiting, onHold, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: return "In progress"
        case .waiting: return "Waiting"
        case .onHold: return "On hold"
        case .done: return "Done"
        }
    }
    var symbol: String {
        switch self {
        case .active: return "hammer.fill"
        case .waiting: return "hourglass"
        case .onHold: return "pause.circle.fill"
        case .done: return "checkmark.seal.fill"
        }
    }
}

/// Pin, favourite and colour for a folder inside a project, keyed by its path relative to the project.
struct FolderMark: Codable, Hashable {
    var pinned = false
    var favorite = false
    var color: String? = nil
    var isEmpty: Bool { !pinned && !favorite && color == nil }
}

extension FolderMark {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}

struct ProjectTask: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title: String
    var done = false
}

/// A folder location that can be found again after a drive is unplugged and mounted elsewhere.
struct FolderLocation: Codable, Hashable {
    var path: String
    var volumeUUID: String? = nil
    var volumeName: String? = nil
    var relativePath: String? = nil
    var synced: Date? = nil
    var onDrive: Bool { volumeUUID != nil }
}

enum LocationStatus: Equatable {
    case active(URL)
    case offline(String)
    case missing
    var url: URL? { if case .active(let url) = self { return url }; return nil }
    var isActive: Bool { url != nil }
}

struct ShelfProject: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var color = "blue"
    var icon = "folder.fill"
    var notes = ""
    var created = Date()
    var location: FolderLocation
    var copies: [FolderLocation] = []
    var status = ProjectStatus.active
    var tasks: [ProjectTask] = []
    var logins: [LoginItem] = []
    var folderMarks: [String: FolderMark] = [:]
    var title: String { name }
    var openTasks: Int { tasks.filter { !$0.done }.count }
    var allLocations: [FolderLocation] { [location] + copies }

    /// Keeps folder marks attached when a folder is renamed or moved (`to: nil` drops them, e.g. after trashing).
    mutating func moveMarks(from old: String, to new: String?) {
        guard !old.isEmpty else { return }
        var result: [String: FolderMark] = [:]
        for (key, mark) in folderMarks {
            if key == old || key.hasPrefix(old + "/") { if let new, !new.isEmpty { result[new + key.dropFirst(old.count)] = mark } }
            else { result[key] = mark }
        }
        folderMarks = result
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || ([name, notes, location.path, status.title] + tasks.map(\.title) + logins.flatMap { [$0.label, $0.username, $0.url] }).joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

/// Keys written by DevShelf 2.0–2.2 that are no longer used.
private enum LegacyKeys: String, CodingKey { case client }

/// Version 2.x kept a separate client name; it now becomes part of the project name,
/// matching the folder name DevShelf created ("Client - Project").
private func mergedName(_ name: String, legacy decoder: Decoder) -> String {
    let client = ((try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .client)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return client.isEmpty ? name : ShelfFiles.folderName(client + " - " + name)
}

// Fields added later are optional when reading, so older shelf files keep loading.
extension ShelfProject {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = mergedName(try c.decode(String.self, forKey: .name), legacy: decoder)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder.fill"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        location = try c.decode(FolderLocation.self, forKey: .location)
        copies = try c.decodeIfPresent([FolderLocation].self, forKey: .copies) ?? []
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status) ?? .active
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        logins = try c.decodeIfPresent([LoginItem].self, forKey: .logins) ?? []
        folderMarks = try c.decodeIfPresent([String: FolderMark].self, forKey: .folderMarks) ?? [:]
    }
}

/// The part of a project that is written into its folder.
struct PortableMetadata: Codable {
    var id: String
    var name: String
    var color: String
    var icon: String
    var notes: String
    var created: Date
    var status: ProjectStatus
    var tasks: [ProjectTask]
    var logins: [LoginItem]
    var folderMarks: [String: FolderMark]
    init(_ project: ShelfProject) {
        id = project.id; name = project.name; color = project.color; icon = project.icon; notes = project.notes
        created = project.created; status = project.status; tasks = project.tasks; logins = project.logins; folderMarks = project.folderMarks
    }
    func project(at location: FolderLocation) -> ShelfProject {
        ShelfProject(id: id, name: name, color: color, icon: icon, notes: notes, created: created, location: location, status: status, tasks: tasks, logins: logins, folderMarks: folderMarks)
    }
}

extension PortableMetadata {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = mergedName(try c.decode(String.self, forKey: .name), legacy: decoder)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder.fill"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status) ?? .active
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        logins = try c.decodeIfPresent([LoginItem].self, forKey: .logins) ?? []
        folderMarks = try c.decodeIfPresent([String: FolderMark].self, forKey: .folderMarks) ?? [:]
    }
}

/// App-wide tweaks. Every field is optional when reading so new settings never reset old ones.
struct Preferences: Codable, Equatable {
    var starterFolders = ShelfFiles.starterFolders
    var editor = "auto"
    var hoverPeek = "normal"
    var skipDependencies = true
    var showHiddenFiles = false
    var sortProjects = "name"
    var fileView = "grid"
    /// "link" (default): the original stays where it is and appears in the project as a link —
    /// no copy, no move, no extra space. "move": items move into the project. "copy": copied in.
    var addMode = "link"
    var peekDelay: UInt64? {
        switch hoverPeek {
        case "off": return nil
        case "fast": return 120_000_000
        case "slow": return 700_000_000
        default: return 350_000_000
        }
    }
}

extension Preferences {
    /// The client-oriented default folders of version 2.0–2.2.
    static let legacyStarterFolders = ["Brief & notes", "Client files", "Design", "Code", "Deliverables"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        starterFolders = try c.decodeIfPresent([String].self, forKey: .starterFolders) ?? defaults.starterFolders
        if starterFolders == Self.legacyStarterFolders { starterFolders = defaults.starterFolders }
        editor = try c.decodeIfPresent(String.self, forKey: .editor) ?? defaults.editor
        hoverPeek = try c.decodeIfPresent(String.self, forKey: .hoverPeek) ?? defaults.hoverPeek
        skipDependencies = try c.decodeIfPresent(Bool.self, forKey: .skipDependencies) ?? defaults.skipDependencies
        showHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? defaults.showHiddenFiles
        sortProjects = try c.decodeIfPresent(String.self, forKey: .sortProjects) ?? defaults.sortProjects
        if sortProjects == "deadline" { sortProjects = "name" }
        fileView = try c.decodeIfPresent(String.self, forKey: .fileView) ?? defaults.fileView
        addMode = try c.decodeIfPresent(String.self, forKey: .addMode) ?? defaults.addMode
    }
}

struct ShelfLibrary: Codable, Equatable {
    var projects: [ShelfProject] = []
    var root: String?
    var rootURL: URL { URL(fileURLWithPath: root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("DevShelf Projects").path) }

    /// Three-way merge used when another process (the MCP server) saved the shelf while the
    /// app had it open: projects the app changed since `base` keep the app's version
    /// (including additions and removals); every other project takes the version on disk.
    static func merge(base: ShelfLibrary, ours: ShelfLibrary, theirs: ShelfLibrary) -> ShelfLibrary {
        let baseByID = Dictionary(base.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oursByID = Dictionary(ours.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirsIDs = Set(theirs.projects.map(\.id))
        var result: [ShelfProject] = []
        for project in theirs.projects {
            let mine = oursByID[project.id]
            if mine != baseByID[project.id] { if let mine { result.append(mine) } } else { result.append(project) }
        }
        for project in ours.projects where !theirsIDs.contains(project.id) && project != baseByID[project.id] { result.append(project) }
        return ShelfLibrary(projects: result, root: ours.root != base.root ? ours.root : theirs.root)
    }
}

struct Volume: Hashable, Identifiable {
    let url: URL
    let uuid: String
    let name: String
    let external: Bool
    var id: String { uuid }
    var freeSpace: Int64? { (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage }
}

enum Volumes {
    static let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey]

    static func mounted() -> [Volume] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).compactMap(volume)
    }

    static func volume(_ url: URL) -> Volume? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), let uuid = values.volumeUUIDString else { return nil }
        let external = values.volumeIsRootFileSystem != true && (values.volumeIsInternal == false || values.volumeIsEjectable == true || values.volumeIsRemovable == true)
        return Volume(url: url.standardizedFileURL, uuid: uuid, name: values.volumeName ?? url.lastPathComponent, external: external)
    }

    /// Records the drive a folder lives on; folders on this Mac only keep their path.
    static func location(for url: URL) -> FolderLocation {
        let folder = url.standardizedFileURL
        guard let root = (try? folder.resourceValues(forKeys: [.volumeURLKey]))?.volume, let volume = volume(root), volume.external else {
            return FolderLocation(path: folder.path)
        }
        return location(for: folder, on: volume)
    }

    static func location(for folder: URL, on volume: Volume) -> FolderLocation {
        let relative = String(folder.standardizedFileURL.path.dropFirst(volume.url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return FolderLocation(path: folder.standardizedFileURL.path, volumeUUID: volume.uuid, volumeName: volume.name, relativePath: relative)
    }

    static func resolve(_ location: FolderLocation, mounted: [Volume]) -> LocationStatus {
        guard let uuid = location.volumeUUID else {
            return FileManager.default.fileExists(atPath: location.path) ? .active(URL(fileURLWithPath: location.path)) : .missing
        }
        guard let volume = mounted.first(where: { $0.uuid == uuid }) else { return .offline(location.volumeName ?? "External drive") }
        let url = location.relativePath.map { $0.isEmpty ? volume.url : volume.url.appendingPathComponent($0) } ?? URL(fileURLWithPath: location.path)
        return FileManager.default.fileExists(atPath: url.path) ? .active(url) : .missing
    }
}

/// Turns a detail value into something clickable: web addresses, bare domains, or email.
func detailLink(_ value: String) -> URL? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(" ") else { return nil }
    if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") { return URL(string: text) }
    if text.range(of: #"^[^@/]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil { return URL(string: "mailto:" + text) }
    if text.range(of: #"^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:[0-9]+)?(/.*)?$"#, options: .regularExpression) != nil { return URL(string: "https://" + text) }
    return nil
}

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let size: Int64?
    let modified: Date?
    /// For a linked item: where the original lives. The link itself is what's in the project.
    var link: URL? = nil
    /// A link whose original was moved, deleted, or is on an unplugged drive.
    var broken = false
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct SyncReport {
    var copied = 0
    var unchanged = 0
    var bytes: Int64 = 0
}

enum ShelfFiles {
    static let metadataName = ".devshelf.json"
    static let starterFolders = ["Code", "Design", "Documents", "Images", "Notes", "Deliverables"]

    /// Folder types offered as a grid when creating a project.
    static let folderOptions: [(name: String, symbol: String)] = [
        ("Code", "chevron.left.forwardslash.chevron.right"), ("Design", "paintbrush.pointed.fill"), ("Documents", "doc.text.fill"), ("Images", "photo.fill"),
        ("Videos", "film.fill"), ("Audio", "waveform"), ("Fonts", "textformat"), ("Brand", "seal.fill"),
        ("Database", "cylinder.split.1x2.fill"), ("Backups", "clock.arrow.circlepath"), ("Notes", "note.text"), ("Research", "magnifyingglass"),
        ("Screenshots", "camera.viewfinder"), ("Builds", "shippingbox.fill"), ("Deliverables", "paperplane.fill"), ("Archive", "archivebox.fill"),
    ]

    static func symbol(forFolder name: String) -> String? {
        folderOptions.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.symbol
    }
    static let ignored: Set<String> = [".DS_Store", metadataName]
    /// Dependency and cache folders that can be rebuilt, skipped when copying code into a project.
    static let regenerable: Set<String> = ["node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".cache", "__pycache__", ".venv", "venv", ".pnpm-store"]

    static func folderName(_ name: String) -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = String(clean.prefix(120)).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Untitled project" : clean
    }

    /// Returns `url`, or "name 2.ext", "name 3.ext"… when something already exists there.
    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        let parent = url.deletingLastPathComponent()
        for number in 2... {
            let candidate = parent.appendingPathComponent(base + " \(number)" + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    static func writeMetadata(_ project: ShelfProject, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PortableMetadata(project)).write(to: folder.appendingPathComponent(metadataName), options: .atomic)
    }

    static func readMetadata(in folder: URL) -> PortableMetadata? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(metadataName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PortableMetadata.self, from: data)
    }

    /// Creates the project's folder inside `parent` and returns the folder it chose.
    static func create(_ project: ShelfProject, in parent: URL, starterFolders: [String]) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = uniqueURL(parent.appendingPathComponent(folderName(project.name)))
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try createFolders(starterFolders, in: folder)
        try writeMetadata(project, to: folder)
        return folder
    }

    /// Creates folders, possibly nested ("Code/theme"). Hidden, empty or ".." parts are skipped.
    @discardableResult static func createFolders(_ paths: [String], in folder: URL) throws -> [String] {
        var made: [String] = []
        for name in paths {
            let parts = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "-") }
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { continue }
            let path = parts.joined(separator: "/")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(path), withIntermediateDirectories: true)
            made.append(path)
        }
        return made
    }

    /// Where a link points (absolute), or nil if `url` isn't a link.
    static func linkDestination(_ url: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        return URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    /// Items in a folder. Linked items are listed under the project, describing their originals;
    /// folders reached through a link are listed too (URL listing can't pass through a link).
    static func children(of folder: URL, showHidden: Bool = false) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let real = folder.resolvingSymlinksInPath()
        let urls = (try? FileManager.default.contentsOfDirectory(at: real, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        return urls.filter { !ignored.contains($0.lastPathComponent) }.map { item in
            let shown = folder.appendingPathComponent(item.lastPathComponent)
            var values = try? item.resourceValues(forKeys: Set(keys))
            var link: URL?, broken = false
            if values?.isSymbolicLink == true {
                link = linkDestination(item)
                if FileManager.default.fileExists(atPath: item.path) { values = try? item.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)) } else { broken = true }
            }
            let isFolder = !broken && values?.isDirectory == true && values?.isPackage != true
            return FileItem(url: shown, isFolder: isFolder, size: broken ? nil : values?.fileSize.map(Int64.init), modified: values?.contentModificationDate, link: link, broken: broken)
        }.sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Walks a folder like FileManager's enumerator, but also enters linked folders (each real folder
    /// once, so link loops can't repeat). Items are reported under the path they have in `folder`.
    /// `skip` decides whether to leave out a folder; `visit` gets every file and returns false to stop.
    static func walk(_ folder: URL, keys: [URLResourceKey] = [], skip: (URL) -> Bool = { _ in false }, onLink: (URL, URL) -> Void = { _, _ in }, visit: (URL, URLResourceValues) -> Bool) {
        let allKeys = Set(keys + [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        var visited: Set<String> = []
        var stopped = false
        func walkFolder(_ shown: URL) {
            let real = shown.resolvingSymlinksInPath()
            guard !stopped, visited.insert(real.path).inserted,
                  let enumerator = FileManager.default.enumerator(at: real, includingPropertiesForKeys: Array(allKeys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            // The enumerator may spell the folder differently (/var vs /private/var), so take the
            // prefix from the first item, which is always a direct child of the folder.
            var base: String?
            for case let url as URL in enumerator {
                if stopped { return }
                if base == nil { base = url.deletingLastPathComponent().path }
                let relative = url.path.hasPrefix(base! + "/") ? String(url.path.dropFirst(base!.count + 1)) : url.lastPathComponent
                let item = shown.appendingPathComponent(relative)
                guard var values = try? url.resourceValues(forKeys: allKeys) else { continue }
                if values.isSymbolicLink == true {
                    let target = url.resolvingSymlinksInPath()
                    guard FileManager.default.fileExists(atPath: url.path), let targetValues = try? target.resourceValues(forKeys: allKeys) else { continue }
                    if targetValues.isDirectory == true && targetValues.isPackage != true {
                        if !skip(item) { onLink(item, target); walkFolder(item) }
                        continue
                    }
                    values = targetValues
                }
                if values.isDirectory == true && values.isPackage != true {
                    if skip(item) { enumerator.skipDescendants() }
                    continue
                }
                if !visit(item, values) { stopped = true; return }
            }
        }
        walkFolder(folder)
    }

    /// Real folders that linked folders in `root` point to (for live updates).
    static func linkedFolders(in root: URL) -> [URL] {
        var targets: [URL] = []
        walk(root, skip: { regenerable.contains($0.lastPathComponent) }, onLink: { _, target in targets.append(target) }) { _, _ in true }
        return targets
    }

    /// Whether `url` itself is stored inside the project, rather than reached through a linked folder.
    static func storedInside(_ url: URL, projectRoot: URL) -> Bool {
        if url.standardizedFileURL.path == projectRoot.standardizedFileURL.path { return true }
        return contains(url.deletingLastPathComponent().resolvingSymlinksInPath().path, in: projectRoot.resolvingSymlinksInPath().path)
    }

    static func contains(_ path: String, in folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

    /// Copies a file or folder, leaving out folders named in `skipping`.
    static func copyTree(from source: URL, to destination: URL, skipping: Set<String>) throws {
        let fm = FileManager.default
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true, !skipping.isEmpty else { try fm.copyItem(at: source, to: destination); return }
        guard let enumerator = fm.enumerator(atPath: source.path) else { throw OrganizerError.message("Could not read “\(source.lastPathComponent)”.") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        while let relative = enumerator.nextObject() as? String {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                if skipping.contains((relative as NSString).lastPathComponent) { enumerator.skipDescendants(); continue }
                try fm.createDirectory(at: destination.appendingPathComponent(relative), withIntermediateDirectories: true)
            } else {
                try fm.copyItem(at: source.appendingPathComponent(relative), to: destination.appendingPathComponent(relative))
            }
        }
    }

    /// Copies items into `folder`, or moves them with `move`. Items already inside `projectRoot`
    /// are always moved, so dragging within a project reorganizes it. Existing names are never overwritten.
    @discardableResult static func add(_ sources: [URL], into folder: URL, projectRoot: URL, move: Bool = false, sameDiskMoves: Bool = false, skipping: Set<String> = regenerable) throws -> [URL] {
        try transfer(sources, into: folder, projectRoot: projectRoot, move: move, sameDiskMoves: sameDiskMoves, skipping: skipping).map(\.destination)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let first = (try? a.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
              let second = (try? b.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject else { return false }
        return first.isEqual(second)
    }

    /// Like `add`, but reports where each item went, so folder marks can follow moves.
    /// With `sameDiskMoves`, items on the destination's disk are moved (as Finder does) and items from
    /// other disks are copied, so adding never leaves a duplicate behind on the same disk.
    /// With `link`, items from outside the project stay exactly where they are and appear in the
    /// project as links (nothing is copied or moved). Items already stored in the project are moved.
    static func transfer(_ sources: [URL], into folder: URL, projectRoot: URL, move: Bool = false, sameDiskMoves: Bool = false, link: Bool = false, skipping: Set<String> = regenerable) throws -> [(source: URL, destination: URL)] {
        let fm = FileManager.default
        let target = folder.standardizedFileURL.path, realTarget = folder.resolvingSymlinksInPath().path
        var added: [(source: URL, destination: URL)] = []
        for source in sources.map(\.standardizedFileURL) {
            guard !contains(target, in: source.path), !contains(realTarget, in: source.resolvingSymlinksInPath().path) else {
                throw OrganizerError.message("“\(source.lastPathComponent)” can’t be placed inside itself.")
            }
            if source.deletingLastPathComponent().path == target || source.deletingLastPathComponent().resolvingSymlinksInPath().path == realTarget { continue }
            let destination = uniqueURL(folder.appendingPathComponent(source.lastPathComponent))
            if storedInside(source, projectRoot: projectRoot) || move || (!link && sameDiskMoves && sameVolume(source, folder)) { try fm.moveItem(at: source, to: destination) }
            else if link { try fm.createSymbolicLink(at: destination, withDestinationURL: linkDestination(source) ?? source) }
            else { try copyTree(from: source, to: destination, skipping: skipping) }
            added.append((source, destination))
        }
        return added
    }

    /// Copies new and changed files from `source` to `destination`. Nothing on the
    /// destination is ever deleted, so syncing repeatedly is safe.
    /// Linked items are copied with their real contents, so a drive copy is complete on its own.
    static func sync(from source: URL, to destination: URL, progress: (Int, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws -> SyncReport {
        var visited: Set<String> = []
        return try sync(from: source, to: destination, visited: &visited, progress: progress, cancelled: cancelled)
    }

    private static func sync(from source: URL, to destination: URL, visited: inout Set<String>, progress: (Int, Int) -> Void, cancelled: () -> Bool) throws -> SyncReport {
        let fm = FileManager.default
        guard visited.insert(source.resolvingSymlinksInPath().path).inserted else { return SyncReport() }
        guard let enumerator = fm.enumerator(atPath: source.resolvingSymlinksInPath().path) else { throw OrganizerError.message("Could not read “\(source.lastPathComponent)”.") }
        var entries: [(String, [FileAttributeKey: Any])] = []
        while let relative = enumerator.nextObject() as? String {
            if URL(fileURLWithPath: relative).lastPathComponent == ".DS_Store" { continue }
            entries.append((relative, enumerator.fileAttributes ?? [:]))
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var report = SyncReport()
        for (index, (relative, linkAttributes)) in entries.enumerated() {
            if cancelled() { throw CancellationError() }
            var from = source.resolvingSymlinksInPath().appendingPathComponent(relative)
            let to = destination.appendingPathComponent(relative)
            var attributes = linkAttributes
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // Copy what the link points to; skip links whose original is gone.
                guard fm.fileExists(atPath: from.path), let real = try? fm.attributesOfItem(atPath: from.resolvingSymlinksInPath().path) else { progress(index + 1, entries.count); continue }
                if real[.type] as? FileAttributeType == .typeDirectory {
                    if (try? fm.destinationOfSymbolicLink(atPath: to.path)) != nil { try fm.removeItem(at: to) }
                    let nested = try sync(from: from, to: to, visited: &visited, progress: { _, _ in }, cancelled: cancelled)
                    report.copied += nested.copied; report.unchanged += nested.unchanged; report.bytes += nested.bytes
                    progress(index + 1, entries.count)
                    continue
                }
                from = from.resolvingSymlinksInPath()
                attributes = real
            }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeDirectory {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            } else {
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let existing = try? fm.attributesOfItem(atPath: to.path)
                let sameSize = (existing?[.size] as? NSNumber)?.int64Value == size
                let current = ((existing?[.modificationDate] as? Date) ?? .distantPast) >= ((attributes[.modificationDate] as? Date) ?? .distantFuture)
                if existing != nil && sameSize && current { report.unchanged += 1 }
                else {
                    if existing != nil || (try? fm.destinationOfSymbolicLink(atPath: to.path)) != nil { try fm.removeItem(at: to) }
                    try fm.copyItem(at: from, to: to)
                    report.copied += 1; report.bytes += size
                }
            }
            progress(index + 1, entries.count)
        }
        return report
    }
}
