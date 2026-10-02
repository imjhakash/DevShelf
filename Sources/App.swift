import AppKit
import SwiftUI
import UniformTypeIdentifiers

let canvas = Color(red: 0.065, green: 0.073, blue: 0.090)
let panel = Color(red: 0.094, green: 0.106, blue: 0.129)
let muted = Color(red: 0.52, green: 0.56, blue: 0.63)
let accent = Color(red: 0.65, green: 0.79, blue: 0.40)

@MainActor final class AppState: ObservableObject {
    @Published var inventory = Persistence.read("inventory.json", as: Inventory.self) ?? Inventory()
    @Published var settings = Persistence.read("settings.json", as: Settings.self) ?? .defaults
    @Published var scanning = false
    @Published var search = ""
    @Published var dependencyQuery = ""
    @Published var section = "Projects"
    @Published var sort = "Recently modified"
    @Published var selection: Project?
    @Published var showFolders = false
    @Published var showOrganizer = false
    @Published var organization = Persistence.read("organization.json", as: Organization.self) ?? Organization()
    @Published var openedFamily: String?
    @Published var expandedFolderPaths: Set<String> = []
    @Published var openRouterKey = ""
    @Published var keySaved = false
    @Published var organizing = false
    @Published var organizerStatus = "Ready to organize your projects with Jev."
    @Published var organizedCount = 0
    @Published var organizerTotal = 0
    @Published var organizerCost: Double = 0
    @Published var costAvailable = true
    @Published var organizeScope = "New projects"
    @Published var purposeResults: [String: Assignment] = Persistence.read("jev-results.json", as: [String: Assignment].self) ?? [:]
    private var organizerTask: Task<Void, Never>?
    @Published var message: String?

    // Project shelf (see ShelfState.swift)
    @Published var shelf = Persistence.read("shelf.json", as: ShelfLibrary.self) ?? ShelfLibrary()
    @Published var volumes = Volumes.mounted()
    @Published var fileTick = 0
    @Published var expandedFiles: Set<String> = []
    @Published var showShelfEditor = false
    @Published var draft = ShelfProject(name: "", location: FolderLocation(path: ""))
    @Published var draftFolders: [String] = []
    @Published var draftCustomFolder = ""
    @Published var draftIsNew = true
    @Published var draftFolder: URL?
    @Published var draftSaveIn = "mac"
    @Published var editorError: String?
    @Published var transferProjectID: String?
    @Published var transferVolumeID = ""
    @Published var transferMove = false
    @Published var transferring = false
    @Published var transferDone = 0
    @Published var transferTotal = 0
    @Published var transferStatus = ""
    var transferCancel: CancelFlag?
    @Published var incomingFiles: [URL] = []
    @Published var showAddToProject = false
    var volumeObservers: [NSObjectProtocol] = []
    // Row state lives here because these views are built without SwiftUI's @State macro.
    @Published var hoveredRow: String?
    @Published var peekingRow: String?
    @Published var pinnedRows: Set<String> = []
    @Published var dropTarget: String?
    var hoverTask: Task<Void, Never>?
    @Published var notice: String?
    @Published var prefs = Persistence.read("preferences.json", as: Preferences.self) ?? Preferences()
    @Published var showPreferences = false
    @Published var statusFilter = "open"
    @Published var newTaskText = ""
    @Published var templates = Persistence.read("templates.json", as: [ProjectTemplate].self) ?? []
    @Published var draftTemplate = "starter"
    // Files section: type groups, the grid's current folder, and a type filter, per project.
    @Published var typeGroups: [String: [FileGroup]] = [:]
    @Published var typeLoading: Set<String> = []
    var typeTick: [String: Int] = [:]
    @Published var gridFolders: [String: String] = [:]
    @Published var typeFilter: [String: String] = [:]
    var editorLookup: (choice: String, editor: CodeEditor, app: URL)?
    /// The last folder opened in each project's tree, keyed by the project folder's path.
    @Published var treeFolders: [String: String] = [:]
    @Published var gitInfo: [String: [GitInfo]] = [:]
    @Published var gitLoading: Set<String> = []
    var gitChecked: [String: Date] = [:]
    @Published var activity: [ActivityItem] = []
    @Published var activityDays = 7
    @Published var activityLoading = false
    @Published var zipSource: URL?
    @Published var zipOptions = ZipOptions()
    @Published var zipRunning = false
    @Published var zipResult: URL?
    @Published var zipStatus = ""
    @Published var showLoginEditor = false
    @Published var loginDraft = LoginItem(label: "")
    @Published var loginPassword = ""
    @Published var loginProjectID = ""
    @Published var loginIsNew = true
    @Published var revealed: [String: String] = [:]
    // AI assistants (MCP) and syncing with changes they make
    @Published var showAssistants = false
    @Published var assistantStates: [String: MCPConnect.State] = [:]
    @Published var assistantBusy: String?
    @Published var assistantMessage = ""
    @Published var mcpLog: [MCPLogEntry] = []
    @Published var mcpTest = ""
    var shelfBase = ShelfLibrary()
    var shelfStamp: Date?
    var mcpLogStamp: Date?
    var syncTimer: Timer?
    // Live refresh when files change outside DevShelf
    var folderWatcher: FolderWatcher?
    // Find duplicates
    @Published var showDuplicates = false
    @Published var duplicateScope = "all"
    @Published var duplicateIncludeOutside = false
    @Published var duplicateScanning = false
    @Published var duplicateScanned = false
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var duplicateSelection: Set<String> = []
    @Published var duplicateStatus = ""
    var duplicateCancel: CancelFlag?
    var pendingFileChanges: Set<String> = []
    var linkedTargets: [String] = []
    var watchedRoots: [String] = []
    var linkScanRunning = false
    var linkScanPending = false
    var lastLinkScan = Date.distantPast
    var fileRefreshScheduled = false
    @Published var showAddScanned = false
    @Published var scannedRoot: URL?
    @Published var scannedTargetPath = ""
    @Published var scannedPick: Set<String> = []
    @Published var scannedQuery = ""
    @Published var scannedMode = "link"

    init() {
        keySaved = KeyVault.hasSavedKey()
        for (path, result) in organization.assignments where result.source == "Jev" && purposeResults[path] == nil { purposeResults[path] = result }
        Persistence.write(purposeResults, to: "jev-results.json")
    }
    var selectedPurpose: Purpose? {
        section.hasPrefix("purpose:") ? Purpose(rawValue: String(section.dropFirst(8))) : nil
    }
    var pageTitle: String {
        if section == "Projects" { return "Projects" }
        if section == "Activity" { return "Activity" }
        if let drive = selectedDrive { return drive.name }
        return selectedPurpose?.title ?? (section == "Overview" ? "Find your next project." : section)
    }
    var pageSubtitle: String {
        if section == "Projects" { return "Every file of every project — code, designs, documents and media — organized in one place." }
        if section == "Activity" { return "Files added or changed across all your projects. Double-click to open, drag to share." }
        if let drive = selectedDrive { return drive.connected ? "Connected. Projects in colour are ready to open." : "Unplugged. Plug the drive back in and these projects light up again." }
        if section == "AI results" { return "Every saved Jev purpose result, including suggestions that need review." }
        return selectedPurpose?.explanation ?? (section == "Overview" ? "Projects found by scanning your Mac, sorted by purpose. Everything stays in its original folder." : "Your scanned projects, grouped so each copy is easy to find.")
    }
    func assignment(_ project: Project) -> Assignment { Categorizer.assignment(project, organization: organization) }
    func inPurpose(_ purpose: Purpose) -> [Project] { inventory.projects.filter { assignment($0).purpose == purpose } }
    var families: [ProjectFamily] { Categorizer.families(projects) }
    var familyProjects: [Project] { families.first { $0.id == openedFamily }?.projects ?? [] }
    func navigate(_ destination: String) { section = destination; openedFamily = nil; expandedFolderPaths = []; selection = nil; search = "" }
    func setPurpose(_ project: Project, _ purpose: Purpose) {
        organization.assignments[project.path] = Assignment(purpose: purpose, source: "Manual", confidence: nil, suggestedPurpose: nil, fingerprint: Categorizer.fingerprint(project))
        saveOrganization()
    }
    func resetPurpose(_ project: Project) { organization.assignments.removeValue(forKey: project.path); saveOrganization() }
    func saveOrganization() { Persistence.write(organization, to: "organization.json") }
    func saveKey() {
        let key = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { message = "Enter your OpenRouter API key first."; return }
        do { try KeyVault.save(key); openRouterKey = ""; keySaved = true; organizerStatus = "API key saved in macOS Keychain." }
        catch { message = error.localizedDescription }
    }
    func removeKey() {
        do { try KeyVault.remove(); keySaved = false; openRouterKey = "" }
        catch { message = error.localizedDescription }
    }
    var classificationProjects: [Project] {
        let eligible = inventory.projects.filter {
            let label = assignment($0)
            return label.source != "Manual" && (organizeScope == "All projects" || label.source != "Jev" || label.purpose == .review)
        }
        return organizeScope == "First 3 projects" ? Array(eligible.prefix(3)) : eligible
    }
    var metadataPreview: String {
        guard let data = try? JSONSerialization.data(withJSONObject: Array(classificationProjects.prefix(3).map(JevClient.metadata)), options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    func organize() {
        guard !organizing else { return }
        guard keySaved else { message = "Save your OpenRouter API key in AI Settings first."; return }
        let candidates = classificationProjects
        guard !candidates.isEmpty else { organizerStatus = "All eligible projects already have categories. Manual choices are preserved."; return }
        let model = organization.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.hasPrefix("typesafe/jev-") || model.hasPrefix("~typesafe/jev-") else { message = "Use a Jev model ID, such as typesafe/jev-1.13."; return }
        saveOrganization()
        organizing = true; organizedCount = 0; organizerTotal = candidates.count; organizerCost = 0; costAvailable = true
        organizerStatus = "Accessing your saved API key. Respond to macOS if it asks for Keychain access."
        showOrganizer = false; navigate("AI results")
        organizerTask = Task {
            defer { organizing = false; organizerTask = nil }
            do {
                let savedKey = await Task.detached { KeyVault.load() }.value
                try Task.checkCancellation()
                guard let key = savedKey, !key.isEmpty else { throw OrganizerError.message("The saved key could not be accessed. Allow DevShelf in the macOS Keychain dialog, or save your key again in AI Settings.") }
                organizerStatus = "Classifying project purposes…"
                for offset in stride(from: 0, to: candidates.count, by: 4) {
                    try Task.checkCancellation()
                    let batch = Array(candidates[offset..<min(offset + 4, candidates.count)])
                    let result = try await JevClient.classify(batch, key: key, model: model)
                    try Task.checkCancellation()
                    for (path, label) in result.assignments {
                        purposeResults[path] = label
                        if organization.assignments[path]?.source != "Manual" { organization.assignments[path] = label }
                    }
                    Persistence.write(purposeResults, to: "jev-results.json")
                    organizedCount += batch.count
                    if let cost = result.cost { organizerCost += cost } else { costAvailable = false }
                    organization.lastRun = Date(); saveOrganization()
                    organizerStatus = "Organized \(organizedCount) of \(organizerTotal) projects."
                }
                organizerStatus = "Finished: \(organizedCount) projects classified. Suggestions are ready to review below."
            } catch {
                if Task.isCancelled { organizerStatus = "Stopped. Categories from completed batches were saved." }
                else { organizerStatus = error.localizedDescription + " Completed batches were saved." }
            }
        }
    }
    func cancelOrganization() { organizerTask?.cancel() }

    var projects: [Project] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let result = inventory.projects.filter { p in
            let categoryMatches: Bool
            switch section {
            case "Favorites": categoryMatches = settings.favorites.contains(p.path)
            case "Recently opened": categoryMatches = settings.lastOpened[p.path] != nil
            default: categoryMatches = selectedPurpose.map { assignment(p).purpose == $0 } ?? true
            }
            let haystack = [p.name, p.packageName ?? "", p.path, p.framework, p.kind, p.summary, assignment(p).purpose.title] + p.dependencies.map(\.name)
            return categoryMatches && (query.isEmpty || haystack.joined(separator: " ").lowercased().contains(query))
        }
        if section == "Recently opened" { return result.sorted { (settings.lastOpened[$0.path] ?? .distantPast) > (settings.lastOpened[$1.path] ?? .distantPast) } }
        return sort == "Name A–Z" ? result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : result.sorted { $0.modified > $1.modified }
    }

    var tools: [InstalledTool] {
        inventory.tools.filter { search.isEmpty || ($0.name + " " + $0.category + " " + $0.path).localizedCaseInsensitiveContains(search) }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let roots = settings.roots
        DispatchQueue.global(qos: .userInitiated).async {
            let scannedInventory = ProjectScanner.scan(roots: roots)
            DispatchQueue.main.async {
                self.inventory = scannedInventory
                Persistence.write(self.inventory, to: "inventory.json")
                self.scanning = false
                if let selected = self.selection { self.selection = self.inventory.projects.first { $0.path == selected.path } }
            }
        }
    }

    func saveSettings() { Persistence.write(settings, to: "settings.json") }
    func toggleFavorite(_ project: Project) {
        if settings.favorites.contains(project.path) { settings.favorites.remove(project.path) }
        else { settings.favorites.insert(project.path) }
        saveSettings()
    }
    func markOpened(_ project: Project) { settings.lastOpened[project.path] = Date(); saveSettings() }
    func reveal(_ project: Project) {
        guard FileManager.default.fileExists(atPath: project.path) else { message = "This folder has moved or been deleted. Refresh the library to update it."; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
        markOpened(project)
    }
    func openEditor(_ project: Project) {
        guard FileManager.default.fileExists(atPath: project.path) else { message = "The project folder no longer exists. Refresh the library."; return }
        openEditor(path: project.path) { self.markOpened(project) }
    }
    /// The editor chosen in Settings, or the first one installed.
    var preferredEditor: (editor: CodeEditor, app: URL)? {
        // Cached per editor choice: looking apps up is too slow to repeat on every redraw.
        if let cached = editorLookup, cached.choice == prefs.editor, FileManager.default.fileExists(atPath: cached.app.path) { return (cached.editor, cached.app) }
        let preferred = Self.editors.filter { $0.id == prefs.editor }
        guard let found = (preferred + Self.editors).lazy.compactMap({ editor in NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundle).map { (editor, $0) } }).first else { return nil }
        editorLookup = (prefs.editor, found.0, found.1)
        return found
    }
    var editorName: String { preferredEditor?.editor.name ?? "Code editor" }

    /// Opens a folder (or file) in the code editor. VS Code–style editors are opened through the
    /// command-line tool inside their app, which reliably opens the folder itself as the workspace.
    func openEditor(path: String, opened: @escaping () -> Void = {}) {
        guard let (editor, app) = preferredEditor else {
            message = "Install a code editor such as Visual Studio Code or Cursor, then choose it in Settings. You can still open the folder in Finder."; return
        }
        guard FileManager.default.fileExists(atPath: path) else { message = "“\((path as NSString).lastPathComponent)” no longer exists."; return }
        let target = URL(fileURLWithPath: path)
        let bin = app.appendingPathComponent("Contents/Resources/app/bin")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []
        let cli = ([editor.id == "vscode" ? "code" : editor.id, "code"] + names.sorted()).first { name in
            names.contains(name) && !name.contains("tunnel") && FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent(name).path)
        }.map { bin.appendingPathComponent($0) }
        let fallback = {
            NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async { if let error { self.message = error.localizedDescription } else { opened() } }
            }
        }
        guard let cli else { fallback(); return }
        Task {
            let worked = await Task.detached(priority: .userInitiated) { () -> Bool in
                let process = Process()
                process.executableURL = cli
                process.arguments = [target.path]
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
                process.environment = environment
                process.standardOutput = Pipe(); process.standardError = Pipe()
                do { try process.run() } catch { return false }
                process.waitUntilExit()
                return process.terminationStatus == 0
            }.value
            if worked { opened() } else { fallback() }
        }
    }
    func terminal(_ project: Project) {
        guard FileManager.default.fileExists(atPath: project.path) else { message = "The project folder no longer exists. Refresh the library."; return }
        if terminal(path: project.path) { markOpened(project) }
    }
    @discardableResult func terminal(path: String) -> Bool {
        let shellPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "cd -- " + shellPath
        let appleString = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(appleString)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { message = "Terminal could not open: \(error[NSAppleScript.errorMessage] ?? "Check macOS Automation permission in System Settings.")"; return false }
        return true
    }
    func addFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true
        picker.prompt = "Add to library"
        if picker.runModal() == .OK {
            for url in picker.urls where !settings.roots.contains(url.path) { settings.roots.append(url.path) }
            saveSettings(); refresh()
        }
    }
    func export() {
        let picker = NSSavePanel()
        picker.nameFieldStringValue = "DevShelf-inventory.json"
        if picker.runModal() == .OK, let url = picker.url {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(inventory).write(to: url, options: .atomic)
            } catch { message = error.localizedDescription }
        }
    }
}

func projectColor(_ project: Project) -> Color {
    if project.kind.hasPrefix("WordPress") { return Color(red: 0.40, green: 0.66, blue: 0.91) }
    if project.framework == "React" || project.framework == "Next.js" { return Color(red: 0.47, green: 0.77, blue: 0.84) }
    if project.framework == "Python" { return Color(red: 0.89, green: 0.75, blue: 0.42) }
    if project.framework == "PHP" || project.framework == "Laravel" { return Color(red: 0.70, green: 0.58, blue: 0.88) }
    return accent
}

struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: project.symbol).font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(projectColor(project)).frame(width: size, height: size)
            .background(projectColor(project).opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Pill: View {
    let title: String
    var color: Color = muted
    var body: some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.10), in: Capsule())
    }
}

struct Sidebar: View {
    @ObservedObject var state: AppState
    let library = [("Overview", "Discover", "square.grid.2x2"), ("Favorites", "Favorites", "star"), ("Recently opened", "Recently opened", "clock"), ("All scanned", "All scanned", "folder"), ("AI results", "AI results", "sparkles"), ("Installed tools", "Installed tools", "wrench.and.screwdriver")]
    func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(muted).padding(.leading, 23).padding(.bottom, 6)
    }
    func item(_ key: String, _ label: String, _ icon: String, count: Int? = nil) -> some View {
        let selected = state.section == key
        return Button { state.navigate(key) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10, design: .monospaced)) }
            }.foregroundStyle(selected ? accent : Color.white.opacity(0.65))
                .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                .background(selected ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.horizontal, 10)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DevShelf").font(.system(size: 22, weight: .bold))
                    Text("Project organizer").font(.system(size: 10)).foregroundStyle(muted)
                }
            }.padding(.top, 40).padding(.bottom, 26).padding(.horizontal, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    heading("PROJECTS")
                    item("Projects", "All projects", "folder.fill", count: state.shelf.projects.count)
                    item("Activity", "Activity", "clock.arrow.circlepath")
                    ForEach(state.shelf.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { project in
                        let active = state.browseURL(project) != nil
                        let selected = state.section == "shelf:" + project.id
                        Button { state.navigate("shelf:" + project.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: project.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(active ? shelfColor(project.color) : offlineGrey).frame(width: 16)
                                Text(project.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if !active { Image(systemName: "externaldrive.badge.xmark").font(.system(size: 9)) }
                            }.font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundStyle(active ? Color.white.opacity(selected ? 0.95 : 0.7) : offlineGrey)
                                .padding(.leading, 26).padding(.trailing, 12).padding(.vertical, 6).contentShape(Rectangle())
                                .background(selected || state.dropTarget == "side:" + project.id ? shelfColor(project.color).opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).padding(.horizontal, 10).help(project.title + (active ? " · drop folders here to add them" : ""))
                            .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding("side:" + project.id)) { providers in
                                guard let url = state.browseURL(project) else { return false }
                                state.receiveDrop(providers, into: url, projectRoot: url)
                                return true
                            }
                    }
                    Button { state.newProject() } label: {
                        Label("New project", systemImage: "plus").font(.system(size: 11)).foregroundStyle(accent).padding(.leading, 26).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 10)
                    FavoriteFoldersSidebar(state: state)
                    if !state.knownDrives.isEmpty {
                        heading("DRIVES").padding(.top, 16)
                        ForEach(state.knownDrives) { drive in
                            let selected = state.section == "drive:" + drive.id
                            Button { state.navigate("drive:" + drive.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "externaldrive.fill").foregroundStyle(drive.connected ? accent : offlineGrey).frame(width: 18)
                                    Text(drive.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                                    Spacer()
                                    Text(drive.connected ? "\(drive.projects)" : "off").font(.system(size: 10, design: .monospaced))
                                }.foregroundStyle(drive.connected ? Color.white.opacity(0.75) : offlineGrey)
                                    .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                                    .background(selected ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).padding(.horizontal, 10).help(drive.connected ? "Connected" : "Unplugged")
                        }
                    }
                    heading("SCANNED LIBRARY").padding(.top, 16)
                    ForEach(library, id: \.0) { key, label, icon in
                        item(key, label, icon, count: key == "All scanned" ? state.inventory.projects.count : key == "Favorites" ? state.inventory.projects.filter { state.settings.favorites.contains($0.path) }.count : nil)
                    }
                }.padding(.bottom, 12)
            }
            Divider().opacity(0.3)
            Button { state.showAssistants = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").frame(width: 18)
                    Text("Connect AI").font(.system(size: 12))
                    Spacer()
                    if state.assistantStates.values.contains(.connected) { Circle().fill(accent).frame(width: 6, height: 6) }
                }.foregroundStyle(accent).padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 8).help("Connect Claude, Codex, Windsurf or Cursor to DevShelf")
            Button { state.showPreferences = true } label: {
                HStack(spacing: 10) { Image(systemName: "gearshape").frame(width: 18); Text("Settings").font(.system(size: 12)); Spacer(); Text("⌘,").font(.system(size: 10)).foregroundStyle(muted) }
                    .foregroundStyle(Color.white.opacity(0.75)).padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 8)
            Button { state.showOrganizer = true } label: {
                HStack(spacing: 10) { Image(systemName: "sparkles").frame(width: 18); Text("AI Settings").font(.system(size: 12)); Spacer(); if state.organizing { ProgressView().controlSize(.mini) } }
                    .foregroundStyle(accent).padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10)
            Button { NSWorkspace.shared.open(developerGitHub) } label: {
                Text("Developed by " + developerName).font(.system(size: 9)).foregroundStyle(muted.opacity(0.8)).lineLimit(1).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 23).padding(.top, 6).padding(.bottom, 18).help("github.com/imjhakash")
        }.frame(width: 232).background(Color(red: 0.078, green: 0.086, blue: 0.104))
    }
}

struct Metric: View {
    let title: String
    let count: Int
    let icon: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon).foregroundStyle(muted).font(.system(size: 17)).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count)").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text(title).font(.system(size: 10)).foregroundStyle(muted)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity).background(panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.045)))
    }
}

struct PurposeCard: View {
    @ObservedObject var state: AppState
    let purpose: Purpose
    var body: some View {
        let projects = state.inPurpose(purpose)
        let families = Categorizer.families(projects)
        Button { state.navigate("purpose:" + purpose.rawValue) } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: purpose.symbol).font(.system(size: 24)).foregroundStyle(accent)
                        .frame(width: 52, height: 52).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(muted).font(.system(size: 12))
                }
                Text(purpose.title).font(.system(size: 17, weight: .semibold))
                Text(purpose.explanation).font(.system(size: 11)).foregroundStyle(muted).lineLimit(2).frame(height: 32, alignment: .top)
                HStack { Text("\(families.count) projects").foregroundStyle(accent); Spacer(); Text("\(projects.count) folders").foregroundStyle(muted) }.font(.system(size: 10, weight: .medium))
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.05)))
        }.buttonStyle(.plain)
    }
}

struct FamilyCard: View {
    @ObservedObject var state: AppState
    let family: ProjectFamily
    var body: some View {
        // A family of several copies is opened first; only single folders can be dragged.
        card.onDrag { family.projects.count == 1 ? NSItemProvider(object: URL(fileURLWithPath: family.latest.path) as NSURL) : NSItemProvider() }
            .contextMenu { if family.projects.count == 1 { AddToProjectMenu(state: state, folder: URL(fileURLWithPath: family.latest.path)) } }
    }
    var card: some View {
        Button { state.openedFamily = family.id; state.selection = family.projects.count == 1 ? family.latest : nil } label: {
            VStack(alignment: .leading, spacing: 15) {
                HStack { ProjectIcon(project: family.latest); Spacer(); Image(systemName: family.projects.count > 1 ? "folder.fill" : "arrow.up.right").font(.system(size: 12)).foregroundStyle(muted) }
                Text(family.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(family.latest.summary.isEmpty ? state.assignment(family.latest).purpose.explanation : family.latest.summary).font(.system(size: 11)).foregroundStyle(muted).lineLimit(2).frame(height: 32, alignment: .top)
                HStack {
                    Pill(title: family.latest.framework, color: projectColor(family.latest))
                    Spacer(minLength: 0)
                    Text(family.projects.count > 1 ? "\(family.projects.count) folders" : "1 folder").font(.system(size: 10)).foregroundStyle(accent)
                }
            }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05)))
        }.buttonStyle(.plain)
    }
}

struct OrganizedProjects: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let familyID = state.openedFamily, let family = state.families.first(where: { $0.id == familyID }) {
                HStack {
                    Button { state.openedFamily = nil; state.selection = nil } label: { Label("Back to projects", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(accent)
                    Spacer()
                    Text("\(family.projects.count) folders · \(family.name)").foregroundStyle(muted)
                }.font(.system(size: 11))
                Text("Choose the copy you want to work on. Each folder remains separate on your Mac.").font(.system(size: 12)).foregroundStyle(muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 14)], spacing: 14) {
                    ForEach(family.projects) { project in ProjectCard(state: state, project: project) }
                }
            } else {
                HStack { Text("\(state.families.count) PROJECTS · \(state.projects.count) FOLDERS").tracking(1).foregroundStyle(muted); Spacer() }.font(.system(size: 10, weight: .semibold))
                if state.projects.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark").font(.system(size: 32)).foregroundStyle(muted)
                        Text(state.scanning ? "Finding your projects…" : "No projects in this category").font(.system(size: 16, weight: .semibold))
                        Text(state.search.isEmpty ? "Assign a project here from its details, or refine your categories with Jev." : "Try a different project name or package.").font(.system(size: 12)).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 44)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 14)], spacing: 14) {
                        ForEach(state.families) { family in FamilyCard(state: state, family: family) }
                    }
                }
            }
        }
    }
}

struct AISettings: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("AI Settings").font(.system(size: 23, weight: .semibold)); Text("Organize by purpose with Jev").font(.system(size: 12)).foregroundStyle(muted) }
                Spacer()
                Button { state.showOrganizer = false; state.openRouterKey = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(state.keySaved ? "OpenRouter key saved in Keychain" : "OpenRouter API key", systemImage: state.keySaved ? "checkmark.shield.fill" : "key.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(state.keySaved ? accent : .white)
                        SecureField(state.keySaved ? "Enter a replacement key…" : "Paste your OpenRouter key…", text: $state.openRouterKey).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save key") { state.saveKey() }.disabled(state.openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.organizing)
                            if state.keySaved { Button("Remove saved key") { state.removeKey() }.disabled(state.organizing) }
                            Spacer()
                        }
                        Text("Your key is stored in macOS Keychain. It is kept out of project files and inventory exports.").font(.system(size: 11)).foregroundStyle(muted)
                    }.padding(16).background(panel, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Jev classification model").font(.system(size: 12, weight: .semibold))
                        TextField("typesafe/jev-1.13", text: $state.organization.model).textFieldStyle(.roundedBorder).disabled(state.organizing).onSubmit { state.saveOrganization() }
                        Text("Results appear in AI results as each batch completes. Uncertain suggestions can be accepted there. Manual choices are preserved.").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Projects to classify", selection: $state.organizeScope) { Text("New or changed projects").tag("New projects"); Text("Reclassify all eligible projects").tag("All projects"); Text("Test on 3 projects").tag("First 3 projects") }.disabled(state.organizing)
                        Text("\(state.classificationProjects.count) projects ready").font(.system(size: 12, weight: .semibold))
                        Text("This sends scanned project names, descriptions, framework and dependency names to OpenRouter and its TypeSafe provider. Projects on your shelf are never sent. Source code, full folder paths, scripts, and .env files stay on your Mac. Requests use your OpenRouter credits.").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("Preview the metadata (first 3 projects)") {
                            Text(state.metadataPreview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 6))
                        }.font(.system(size: 11))
                    }
                    if state.organizing {
                        ProgressView(value: Double(state.organizedCount), total: Double(max(state.organizerTotal, 1))).tint(accent)
                    }
                    Text(state.organizerStatus).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    if state.organizedCount > 0 {
                        Text(state.costAvailable ? String(format: "Reported cost this run: $%.5f", state.organizerCost) : "OpenRouter did not report cost for every batch. Check your OpenRouter usage for the total.").font(.system(size: 10)).foregroundStyle(muted)
                    }
                }
            }.frame(maxHeight: 510)
            HStack {
                if state.organizing { Button("Stop") { state.cancelOrganization() } }
                else { Button("Send metadata & organize") { state.organize() }.disabled(!state.keySaved || state.scanning || state.classificationProjects.isEmpty).buttonStyle(.borderedProminent).tint(accent).foregroundStyle(canvas) }
                Button("View saved results") { state.showOrganizer = false; state.navigate("AI results") }
                Spacer()
                Button("Done") { state.saveOrganization(); state.showOrganizer = false; state.openRouterKey = "" }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 600).background(canvas).preferredColorScheme(.dark)
    }
}

struct ProjectCard: View {
    @ObservedObject var state: AppState
    let project: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProjectIcon(project: project)
                Spacer()
                Button { state.toggleFavorite(project) } label: {
                    Image(systemName: state.settings.favorites.contains(project.path) ? "star.fill" : "star")
                        .foregroundStyle(state.settings.favorites.contains(project.path) ? accent : muted)
                }.buttonStyle(.plain).help("Favorite this project")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(project.name)
                Text(project.summary.isEmpty ? project.kind : project.summary).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
            }
            HStack(spacing: 5) {
                Pill(title: project.framework, color: projectColor(project))
                if project.git { Pill(title: "Git") }
                if !project.dependencies.isEmpty { Pill(title: "\(project.dependencies.count) packages") }
                Spacer(minLength: 0)
            }
            Text(shortPath(project.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted.opacity(0.75)).lineLimit(1).truncationMode(.middle).help(project.path)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            HStack {
                Text(project.modified, style: .date).font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Button { state.reveal(project) } label: { Image(systemName: "folder").font(.system(size: 12)) }.buttonStyle(.plain).foregroundStyle(muted).help("Show in Finder")
                Button { state.openEditor(project) } label: { HStack(spacing: 4) { Text("Open"); Image(systemName: "arrow.up.right").font(.system(size: 9)) }.font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).foregroundStyle(accent).help("Open in VS Code or Cursor")
            }
        }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(state.selection?.id == project.id ? accent.opacity(0.65) : Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture { state.selection = project }
            .onDrag { NSItemProvider(object: URL(fileURLWithPath: project.path) as NSURL) }
            .contextMenu {
                Button("Open in editor") { state.openEditor(project) }
                Button("Show in Finder") { state.reveal(project) }
                Button("Open Terminal here") { state.terminal(project) }
                Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.path, forType: .string) }
                Menu("Move to category") { ForEach(Purpose.allCases) { purpose in Button(purpose.title) { state.setPurpose(project, purpose) } } }
                AddToProjectMenu(state: state, folder: URL(fileURLWithPath: project.path))
                Button(state.settings.favorites.contains(project.path) ? "Remove favorite" : "Add favorite") { state.toggleFavorite(project) }
            }
    }
}

func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

struct DetailPanel: View {
    @ObservedObject var state: AppState
    let project: Project
    var dependencies: [Dependency] {
        project.dependencies.filter { state.dependencyQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(state.dependencyQuery) }
    }
    func installedVersion(_ dependency: Dependency) -> String? {
        ProjectScanner.json(URL(fileURLWithPath: project.path).appendingPathComponent("node_modules").appendingPathComponent(dependency.name).appendingPathComponent("package.json"))?["version"] as? String
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("PROJECT DETAILS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(muted); Spacer(); Button { state.selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(muted).help("Close details") }
                ProjectIcon(project: project, size: 58)
                VStack(alignment: .leading, spacing: 9) {
                    Text(project.name).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    Pill(title: project.kind, color: projectColor(project))
                    if !project.summary.isEmpty { Text(project.summary).font(.system(size: 12)).foregroundStyle(muted).textSelection(.enabled) }
                }
                Text(project.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button { state.openEditor(project) } label: { Label("Open in editor", systemImage: "arrow.up.right").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10).foregroundStyle(canvas).background(accent, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                HStack {
                    Button { state.reveal(project) } label: { Label("Finder", systemImage: "folder").frame(maxWidth: .infinity) }
                    Button { state.terminal(project) } label: { Label("Terminal", systemImage: "terminal").frame(maxWidth: .infinity) }
                }.font(.system(size: 11)).buttonStyle(.bordered)
                Divider().overlay(Color.white.opacity(0.05))
                VStack(alignment: .leading, spacing: 10) {
                    Text("PURPOSE").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(muted)
                    Picker("Category", selection: Binding(get: { state.assignment(project).purpose }, set: { state.setPurpose(project, $0) })) {
                        ForEach(Purpose.allCases) { purpose in Text(purpose.title).tag(purpose) }
                    }.labelsHidden().font(.system(size: 11))
                    Text(state.assignment(project).purpose.explanation).font(.system(size: 11)).foregroundStyle(muted)
                    HStack {
                        Text(state.assignment(project).source)
                        if let confidence = state.assignment(project).confidence { Text("· \(Int(confidence * 100))% confidence") }
                    }.font(.system(size: 10)).foregroundStyle(muted)
                    if let suggestion = state.assignment(project).suggestedPurpose { Text("Jev suggests: \(suggestion.title)").font(.system(size: 10)).foregroundStyle(accent) }
                    if state.assignment(project).source == "Manual" { Button("Use automatic category again") { state.resetPurpose(project) }.font(.system(size: 10)) }
                }
                Divider().overlay(Color.white.opacity(0.05))
                Menu { AddToProjectMenu(state: state, folder: URL(fileURLWithPath: project.path)) } label: { Label("Add to a project", systemImage: "folder.badge.plus") }
                    .font(.system(size: 11)).help("Copy this folder into one of your projects, or make it a project of its own.")
                Divider().overlay(Color.white.opacity(0.05))
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("Framework", project.framework)
                    detailRow("Last modified", project.modified.formatted(date: .abbreviated, time: .omitted))
                    detailRow("Git repository", project.git ? "Yes" : "No")
                    if let name = project.packageName { detailRow("Package name", name) }
                }
                if !project.scripts.isEmpty {
                    Text("NPM SCRIPTS").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(muted)
                    ForEach(project.scripts.keys.sorted(), id: \.self) { name in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                            Text(project.scripts[name] ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(canvas, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !project.dependencies.isEmpty {
                    HStack { Text("PACKAGES").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(muted); Spacer(); Text("\(project.dependencies.count)").font(.system(size: 10)).foregroundStyle(muted) }
                    Text("Requested versions come from package.json. Installed versions appear when available in node_modules.").font(.system(size: 10)).foregroundStyle(muted)
                    TextField("Find a package…", text: $state.dependencyQuery).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(dependencies) { dependency in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Image(systemName: "shippingbox").foregroundStyle(muted); Text(dependency.name).font(.system(size: 11, weight: .medium)).textSelection(.enabled); Spacer(minLength: 0); if dependency.development { Text("dev").font(.system(size: 9)).foregroundStyle(muted) } }
                                HStack { Text("Requested \(dependency.requested)"); Spacer(minLength: 0); Text(installedVersion(dependency).map { "Installed \($0)" } ?? "Not found").foregroundStyle(installedVersion(dependency) == nil ? muted : accent) }.font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                            }
                        }
                    }
                }
            }.padding(22)
        }.frame(width: 310).background(panel.opacity(0.65)).id(project.id).onAppear { state.dependencyQuery = "" }
    }
    func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(muted); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.system(size: 11))
    }
}

struct ToolsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(["Global npm package", "Developer tool"], id: \.self) { category in
                let tools = state.tools.filter { $0.category == category }
                if !tools.isEmpty {
                    Text(category == "Global npm package" ? "GLOBAL NPM PACKAGES" : "DEVELOPER TOOLS").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(muted).padding(.top, 12).padding(.bottom, 4)
                    ForEach(tools) { tool in
                        HStack(spacing: 16) {
                            Image(systemName: category == "Global npm package" ? "shippingbox.fill" : "terminal.fill").font(.system(size: 20)).foregroundStyle(accent).frame(width: 44, height: 44).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(tool.name).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                                Text(shortPath(tool.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer()
                            Pill(title: tool.version, color: accent)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tool.path)]) } label: { Image(systemName: "folder") }.buttonStyle(.plain).foregroundStyle(muted).help("Show installation in Finder")
                        }.padding(16).background(panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.04)))
                    }
                }
            }
            Text("Global packages are read from common npm, Homebrew, custom-prefix, and nvm installation folders. Developer tools are detected on disk; package versions are read from their manifests.").font(.system(size: 11)).foregroundStyle(muted).padding(.top, 8)
            if state.tools.isEmpty { Text("No matching tools found.").foregroundStyle(muted).padding(24) }
        }
    }
}

struct FolderSettings: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Your scan folders").font(.system(size: 23, weight: .semibold)); Spacer(); Button { state.showFolders = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text("DevShelf looks inside these folders for web projects, WordPress plugins, package manifests, and Git repositories. Your code stays where it is.").font(.system(size: 12)).foregroundStyle(muted)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.settings.roots, id: \.self) { path in
                        HStack { Image(systemName: "folder").foregroundStyle(accent); Text(path).font(.system(size: 11, design: .monospaced)).lineLimit(2); Spacer(); Button { state.settings.roots.removeAll { $0 == path }; state.saveSettings(); state.refresh() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove scan folder").disabled(state.scanning) }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: 170)
            Button { state.addFolder() } label: { Label("Add folder", systemImage: "plus") }.disabled(state.scanning)
            Text("Skipped: node_modules, vendor, caches, build output, symlinked folders, app bundles, credentials, and ~/Library. Nested projects and Codex worktrees are included. Projects inside skipped folders can be added directly above.").font(.system(size: 11)).foregroundStyle(muted)
            if !state.inventory.warnings.isEmpty {
                DisclosureGroup("\(state.inventory.warnings.count) scan warnings") {
                    ScrollView { Text(state.inventory.warnings.joined(separator: "\n\n")).font(.system(size: 10)).foregroundStyle(muted).textSelection(.enabled) }.frame(height: 100)
                }
            }
            HStack { Button("Export inventory…") { state.export() }; Spacer(); Button("Done") { state.showFolders = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 540).background(canvas).preferredColorScheme(.dark)
    }
}

struct Dashboard: View {
    @ObservedObject var state: AppState
    @FocusState private var searchFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(state: state)
            Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 9) { Image(systemName: "magnifyingglass").foregroundStyle(muted); TextField(state.section == "Projects" || state.section.hasPrefix("drive:") ? "Search projects, notes, and logins…" : "Search projects, paths, or packages…", text: $state.search).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused); Text("⌘ F").font(.system(size: 10)).foregroundStyle(muted) }.padding(11).frame(maxWidth: 450).background(panel, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    if state.scanning { ProgressView().controlSize(.small); Text("Scanning…").font(.system(size: 11)).foregroundStyle(muted) }
                    Button { state.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)) }.buttonStyle(.plain).disabled(state.scanning).help("Refresh library (⌘R)")
                    Button { state.showFolders = true } label: { Label("Scan folders", systemImage: "plus").font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9).background(panel, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).padding(.leading, 10)
                }.padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 24)
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if let project = state.selectedShelfProject {
                                ShelfProjectPage(state: state, project: project)
                            } else {
                            VStack(alignment: .leading, spacing: 8) {
                                if state.selectedPurpose != nil {
                                    Button { state.navigate("Overview") } label: { Label("All categories", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11)).padding(.bottom, 5)
                                }
                                Text(state.pageTitle).font(.system(size: 30, weight: .semibold)).tracking(-0.7)
                                Text(state.section == "Installed tools" ? "The tools and global packages that power your workspace." : state.pageSubtitle).font(.system(size: 12)).foregroundStyle(muted)
                            }
                            if state.section == "Overview" && state.search.isEmpty {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.badge.gearshape").foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(Purpose.allCases.count) categories · \(state.inventory.projects.count) project folders").font(.system(size: 12, weight: .medium))
                                        Text(state.organization.assignments.values.contains { $0.source == "Jev" } ? "Jev categories are saved. Review or change them in project details." : "Local suggestions are ready. Add your OpenRouter key to refine them with Jev.").font(.system(size: 11)).foregroundStyle(muted)
                                    }
                                    Spacer()
                                    Button("AI Settings") { state.showOrganizer = true }.font(.system(size: 11)).buttonStyle(.bordered)
                                }.padding(16).background(panel, in: RoundedRectangle(cornerRadius: 10))
                            }
                            if state.section == "Projects" { ShelfHome(state: state) }
                            else if state.section == "Activity" { ActivityView(state: state) }
                            else if let drive = state.selectedDrive { ShelfHome(state: state, drive: drive.id) }
                            else if state.section == "Installed tools" { ToolsView(state: state) }
                            else if state.section == "AI results" { JevResultsView(state: state) }
                            else if state.section == "Overview" && state.search.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 265), spacing: 16)], spacing: 16) {
                                    ForEach(Purpose.allCases) { purpose in PurposeCard(state: state, purpose: purpose) }
                                }
                            } else { OrganizedProjects(state: state) }
                            }
                        }.padding(.horizontal, 28).padding(.bottom, 28)
                    }
                    if let selected = state.selection { DetailPanel(state: state, project: selected) }
                }
                HStack(spacing: 6) {
                    Circle().fill(state.scanning ? Color.orange : accent).frame(width: 5, height: 5)
                    Text(state.scanning ? "Reading project metadata…" : "\(state.inventory.scannedFolders.formatted()) folders scanned · Updated \(state.inventory.scannedAt.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    if let notice = state.notice { Label(notice, systemImage: "tray.and.arrow.down.fill").foregroundStyle(accent).lineLimit(1) }
                    if !state.inventory.warnings.isEmpty { Button("\(state.inventory.warnings.count) scan warnings") { state.showFolders = true }.buttonStyle(.plain).foregroundStyle(.orange) }
                    if state.organizing { Button("Jev: \(state.organizedCount)/\(state.organizerTotal)") { state.showOrganizer = true }.buttonStyle(.plain).foregroundStyle(accent) }
                    Text("LOCAL LIBRARY").font(.system(size: 8, weight: .medium)).tracking(1.3)
                }.font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 28).padding(.vertical, 12).background(Color.white.opacity(0.015))
            }
        }.background(canvas).foregroundStyle(Color.white.opacity(0.9)).preferredColorScheme(.dark)
            .sheet(isPresented: $state.showFolders) { FolderSettings(state: state) }
            .sheet(isPresented: $state.showOrganizer) { AISettings(state: state) }
            .sheet(isPresented: $state.showShelfEditor) { ShelfEditor(state: state) }
            .sheet(isPresented: Binding(get: { state.transferProjectID != nil }, set: { if !$0 && !state.transferring { state.transferProjectID = nil } })) { TransferSheet(state: state) }
            .sheet(isPresented: $state.showAddToProject) { AddToProjectSheet(state: state) }
            .sheet(isPresented: $state.showAddScanned) { AddScannedSheet(state: state) }
            .sheet(isPresented: $state.showPreferences) { PreferencesView(state: state) }
            .sheet(isPresented: $state.showLoginEditor) { LoginEditor(state: state) }
            .sheet(isPresented: $state.showAssistants) { AssistantsSheet(state: state) }
            .sheet(isPresented: $state.showDuplicates) { DuplicatesSheet(state: state) }
            .sheet(isPresented: Binding(get: { state.zipSource != nil }, set: { if !$0 && !state.zipRunning { state.zipSource = nil } })) { ZipSheet(state: state) }
            .alert("DevShelf", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) { Button("OK") { state.message = nil } } message: { Text(state.message ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DevShelfFocusSearch"))) { _ in searchFocused = true }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1320, screen.width - 60), height: min(850, screen.height - 60)), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "DevShelf"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.065, green: 0.073, blue: 0.090, alpha: 1)
        window.minSize = NSSize(width: 950, height: 620)
        window.contentView = NSHostingView(rootView: Dashboard(state: state))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        menu()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        state.startVolumeMonitoring()
        state.startShelfSync()
        state.refresh()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func menu() {
        let bar = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; bar.addItem(appItem)
        appMenu.addItem(withTitle: "About DevShelf", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(preferences), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Scan folders…", action: #selector(folders), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "AI Settings…", action: #selector(aiSettings), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DevShelf", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit DevShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit"); let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; bar.addItem(editItem)
        for (name, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: name, action: action, keyEquivalent: key) }
        let library = NSMenu(title: "Library"); let libraryItem = NSMenuItem(title: "Library", action: nil, keyEquivalent: ""); libraryItem.submenu = library; bar.addItem(libraryItem)
        library.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        library.addItem(withTitle: "Search", action: #selector(search), keyEquivalent: "f").target = self
        library.addItem(withTitle: "Export inventory…", action: #selector(exportInventory), keyEquivalent: "e").target = self
        let projects = NSMenu(title: "Projects"); let projectsItem = NSMenuItem(title: "Projects", action: nil, keyEquivalent: ""); projectsItem.submenu = projects; bar.addItem(projectsItem)
        projects.addItem(withTitle: "New project…", action: #selector(newProject), keyEquivalent: "n").target = self
        projects.addItem(withTitle: "Add existing folder…", action: #selector(addExistingFolder), keyEquivalent: "o").target = self
        projects.addItem(withTitle: "Show projects", action: #selector(showProjects), keyEquivalent: "1").target = self
        NSApp.mainMenu = bar
    }
    @objc func addToProject(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] { urls = paths.map { URL(fileURLWithPath: $0) } }
        guard !urls.isEmpty else { error.pointee = "Select one or more files or folders."; return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        state.receiveIncoming(urls)
    }
    @objc func refresh() { state.refresh() }
    @objc func search() { NotificationCenter.default.post(name: Notification.Name("DevShelfFocusSearch"), object: nil) }
    @objc func folders() { state.showFolders = true }
    @objc func preferences() { state.showPreferences = true }
    @objc func aiSettings() { state.showOrganizer = true }
    @objc func newProject() { state.newProject() }
    @objc func addExistingFolder() { state.addExistingFolders() }
    @objc func showProjects() { state.navigate("Projects") }
    @objc func exportInventory() { state.export() }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DevShelf", .applicationVersion: appVersion, .credits: NSAttributedString(string: appTagline + "\n\nDeveloped by " + developerName + "\ngithub.com/imjhakash")]) }
}

@main struct DevShelfLauncher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
            return
        }
        if CommandLine.arguments.contains("--scan-only") {
            var roots: [String] = []
            let args = CommandLine.arguments
            for index in args.indices where args[index] == "--root" && index + 1 < args.count { roots.append(args[index + 1]) }
            let result = ProjectScanner.scan(roots: roots.isEmpty ? Settings.defaults.roots : roots)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(result) { FileHandle.standardOutput.write(data) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
