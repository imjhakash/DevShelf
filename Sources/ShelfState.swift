import AppKit
import Foundation

final class CancelFlag: @unchecked Sendable { var cancelled = false }

struct KnownDrive: Identifiable {
    let id: String
    let name: String
    let connected: Bool
    let projects: Int
}

struct CodeEditor {
    let id: String
    let name: String
    let bundle: String
}

extension AppState {
    static let editors = [
        CodeEditor(id: "vscode", name: "Visual Studio Code", bundle: "com.microsoft.VSCode"),
        CodeEditor(id: "cursor", name: "Cursor", bundle: "com.todesktop.230313mzl4w4u92"),
        CodeEditor(id: "windsurf", name: "Windsurf", bundle: "com.exafunction.windsurf"),
        CodeEditor(id: "zed", name: "Zed", bundle: "dev.zed.Zed"),
        CodeEditor(id: "sublime", name: "Sublime Text", bundle: "com.sublimetext.4"),
        CodeEditor(id: "webstorm", name: "WebStorm", bundle: "com.jetbrains.WebStorm"),
        CodeEditor(id: "phpstorm", name: "PhpStorm", bundle: "com.jetbrains.PhpStorm"),
        CodeEditor(id: "xcode", name: "Xcode", bundle: "com.apple.dt.Xcode"),
    ]
    var installedEditors: [CodeEditor] { Self.editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil } }

    /// Saves the shelf, first merging in changes another process (an AI assistant) made meanwhile.
    func saveShelf() {
        if let stamp = dataFileDate("shelf.json"), stamp != shelfStamp, let disk = Persistence.read("shelf.json", as: ShelfLibrary.self) {
            shelf = ShelfLibrary.merge(base: shelfBase, ours: shelf, theirs: disk)
        }
        Persistence.write(shelf, to: "shelf.json")
        shelfBase = shelf
        shelfStamp = dataFileDate("shelf.json")
    }
    func savePrefs() { Persistence.write(prefs, to: "preferences.json") }
    var nextColor: String { shelfPalette[shelf.projects.count % shelfPalette.count].key }

    // MARK: Locations and drives

    func status(of location: FolderLocation) -> LocationStatus { Volumes.resolve(location, mounted: volumes) }

    /// The folder to browse: the main folder, or any connected copy. With `drive`, only that drive's copy.
    func browseURL(_ project: ShelfProject, onDrive drive: String? = nil) -> URL? {
        let locations = drive.map { id in project.allLocations.filter { $0.volumeUUID == id } } ?? project.allLocations
        return locations.lazy.compactMap { self.status(of: $0).url }.first
    }

    func offlineMessage(_ project: ShelfProject, onDrive drive: String? = nil) -> String {
        let locations = drive.map { id in project.allLocations.filter { $0.volumeUUID == id } } ?? project.allLocations
        if let unplugged = locations.first(where: { if case .offline = status(of: $0) { return true }; return false }) {
            return "Plug in \(unplugged.volumeName ?? "the drive") to open this project."
        }
        return "The folder was moved or deleted. Use Add existing folder to point DevShelf to it again."
    }

    var selectedShelfProject: ShelfProject? { section.hasPrefix("shelf:") ? shelf.projects.first { $0.id == String(section.dropFirst(6)) } : nil }
    var selectedDrive: KnownDrive? { section.hasPrefix("drive:") ? knownDrives.first { $0.id == String(section.dropFirst(6)) } : nil }

    var knownDrives: [KnownDrive] {
        var names: [String: String] = [:]
        for volume in volumes where volume.external { names[volume.uuid] = volume.name }
        for project in shelf.projects {
            for location in project.allLocations { if let id = location.volumeUUID, names[id] == nil { names[id] = location.volumeName ?? "Drive" } }
        }
        return names.map { id, name in
            KnownDrive(id: id, name: name, connected: volumes.contains { $0.uuid == id }, projects: shelf.projects.filter { $0.allLocations.contains { $0.volumeUUID == id } }.count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func matchesStatusFilter(_ project: ShelfProject) -> Bool {
        switch statusFilter {
        case "all": return true
        case "open": return project.status != .done
        default: return project.status.rawValue == statusFilter
        }
    }

    func shelfProjects(onDrive drive: String?) -> [ShelfProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let byName: (ShelfProject, ShelfProject) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let matches = shelf.projects.filter { project in
            project.matches(query) && (drive == nil ? matchesStatusFilter(project) : project.allLocations.contains { $0.volumeUUID == drive })
        }
        switch prefs.sortProjects {
        case "newest": return matches.sorted { $0.created > $1.created }
        default: return matches.sorted(by: byName)
        }
    }

    // MARK: Status and checklist

    /// Applies a change to a saved project and writes its portable metadata.
    func updateProject(_ id: String, _ change: (inout ShelfProject) -> Void) {
        guard let index = shelf.projects.firstIndex(where: { $0.id == id }) else { return }
        change(&shelf.projects[index])
        saveShelf()
        let project = shelf.projects[index]
        for location in project.allLocations { if let url = status(of: location).url { try? ShelfFiles.writeMetadata(project, to: url) } }
    }

    func setStatus(_ project: ShelfProject, _ status: ProjectStatus) { updateProject(project.id) { $0.status = status } }

    func addTask(_ project: ShelfProject) {
        let title = newTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        updateProject(project.id) { $0.tasks.append(ProjectTask(title: title)) }
        newTaskText = ""
    }

    func toggleTask(_ project: ShelfProject, _ task: ProjectTask) {
        updateProject(project.id) { item in
            if let index = item.tasks.firstIndex(where: { $0.id == task.id }) { item.tasks[index].done.toggle() }
        }
    }

    func removeTask(_ project: ShelfProject, _ task: ProjectTask) { updateProject(project.id) { $0.tasks.removeAll { $0.id == task.id } } }

    func chooseProjectsFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
        picker.directoryURL = shelf.rootURL.deletingLastPathComponent()
        picker.prompt = "Use this folder"
        picker.message = "New projects will be created here. Existing projects stay where they are."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        shelf.root = url.standardizedFileURL.path
        saveShelf()
    }

    func startVolumeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.volumesChanged() }
            })
        }
    }

    func volumesChanged() {
        volumes = Volumes.mounted()
        // Keep drive names current when a drive is renamed.
        var renamed = false
        for index in shelf.projects.indices {
            for volume in volumes {
                if shelf.projects[index].location.volumeUUID == volume.uuid && shelf.projects[index].location.volumeName != volume.name {
                    shelf.projects[index].location.volumeName = volume.name; renamed = true
                }
                for copy in shelf.projects[index].copies.indices where shelf.projects[index].copies[copy].volumeUUID == volume.uuid && shelf.projects[index].copies[copy].volumeName != volume.name {
                    shelf.projects[index].copies[copy].volumeName = volume.name; renamed = true
                }
            }
        }
        if renamed { saveShelf() }
        fileTick += 1
    }

    // MARK: Creating and editing projects

    func newProject(keepIncoming: Bool = false) {
        if !keepIncoming { incomingFiles = [] }
        draft = ShelfProject(name: "", color: nextColor, location: FolderLocation(path: ""))
        draftIsNew = true; draftFolder = nil; draftSaveIn = "mac"; editorError = nil
        applyPreset("starter")
        showShelfEditor = true
    }

    // MARK: Folder grid in the new-project sheet

    /// Fills the folder grid from Settings' default folders, a template, or nothing.
    func applyPreset(_ id: String) {
        draftTemplate = id
        draftFolders = id == "none" ? [] : templateFolders(id).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func draftHasFolder(_ name: String) -> Bool { draftFolders.contains { $0 == name || $0.hasPrefix(name + "/") } }

    func toggleDraftFolder(_ name: String) {
        if draftHasFolder(name) { draftFolders.removeAll { $0 == name || $0.hasPrefix(name + "/") } } else { draftFolders.append(name) }
        draftTemplate = ""
    }

    func addCustomDraftFolder() {
        let name = draftCustomFolder.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "-")
        draftCustomFolder = ""
        guard !name.isEmpty, !name.hasPrefix("."), !draftFolders.contains(name) else { return }
        draftFolders.append(name); draftTemplate = ""
    }

    func editProject(_ project: ShelfProject) {
        draft = project; draftIsNew = false; draftFolder = nil; editorError = nil
        showShelfEditor = true
    }

    func saveDraft() {
        var project = draft
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.notes = project.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.name.isEmpty else { editorError = "Give the project a name."; return }
        do {
            if draftIsNew {
                if let folder = draftFolder {
                    project.location = Volumes.location(for: folder)
                } else {
                    let parent: URL
                    if draftSaveIn == "mac" { parent = shelf.rootURL }
                    else {
                        guard let drive = volumes.first(where: { $0.uuid == draftSaveIn }) else { throw OrganizerError.message("That drive is no longer connected. Choose another location.") }
                        parent = drive.url.appendingPathComponent("DevShelf Projects")
                    }
                    project.location = Volumes.location(for: try ShelfFiles.create(project, in: parent, starterFolders: draftFolders))
                }
                shelf.projects.append(project)
            } else {
                guard let index = shelf.projects.firstIndex(where: { $0.id == project.id }) else { throw OrganizerError.message("This project was removed from DevShelf.") }
                let old = shelf.projects[index]
                // Rename the main folder only if it still carries the name DevShelf gave it.
                if let url = status(of: old.location).url, url.lastPathComponent == ShelfFiles.folderName(old.name) {
                    let name = ShelfFiles.folderName(project.name)
                    if name != url.lastPathComponent {
                        let renamed = ShelfFiles.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(name))
                        if (try? FileManager.default.moveItem(at: url, to: renamed)) != nil {
                            project.location = Volumes.location(for: renamed)
                            project.location.synced = old.location.synced
                            expandedFiles = []
                        }
                    }
                }
                shelf.projects[index] = project
            }
            for location in project.allLocations { if let url = status(of: location).url { try? ShelfFiles.writeMetadata(project, to: url) } }
            saveShelf(); showShelfEditor = false; fileTick += 1
            if draftIsNew {
                if !incomingFiles.isEmpty, let url = status(of: project.location).url {
                    addItems(incomingFiles, into: url, projectRoot: url)
                    incomingFiles = []
                }
                navigate("shelf:" + project.id)
            }
        } catch { editorError = error.localizedDescription }
    }

    func removeFromShelf(_ project: ShelfProject) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(project.title)” from DevShelf?"
        alert.informativeText = "The folder and all its files stay on disk. You can add it back any time with Add existing folder, and its details will be restored."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        shelf.projects.removeAll { $0.id == project.id }
        saveShelf()
        if section == "shelf:" + project.id { navigate("Projects") }
    }

    func addExistingFolders() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true
        picker.prompt = "Add to DevShelf"
        picker.message = "Choose project folders. They stay where they are. Folders that came from DevShelf keep their name, colour and details."
        if picker.runModal() == .OK { importFolders(picker.urls) }
    }

    /// Adds folders without moving them. A folder holding `.devshelf.json` restores its
    /// project, or becomes another copy of a project that is already on the shelf.
    func importFolders(_ urls: [URL]) {
        var plain: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            if shelf.projects.contains(where: { $0.allLocations.contains { self.status(of: $0).url?.standardizedFileURL.path == url.path } }) { continue }
            let location = Volumes.location(for: url)
            if let metadata = ShelfFiles.readMetadata(in: url) {
                if let index = shelf.projects.firstIndex(where: { $0.id == metadata.id }) {
                    if status(of: shelf.projects[index].location) == .missing { shelf.projects[index].location = location }
                    else {
                        shelf.projects[index].copies.removeAll { $0.volumeUUID != nil && $0.volumeUUID == location.volumeUUID }
                        shelf.projects[index].copies.append(location)
                    }
                } else { shelf.projects.append(metadata.project(at: location)) }
            } else { plain.append(url) }
        }
        if plain.count == 1 {
            draft = ShelfProject(name: plain[0].lastPathComponent, color: nextColor, location: Volumes.location(for: plain[0]))
            draftIsNew = true; draftFolder = plain[0]; editorError = nil; showShelfEditor = true
        } else {
            for url in plain {
                let project = ShelfProject(name: url.lastPathComponent, color: nextColor, location: Volumes.location(for: url))
                try? ShelfFiles.writeMetadata(project, to: url)
                shelf.projects.append(project)
            }
        }
        saveShelf(); fileTick += 1
    }

    // MARK: Files

    func toggleExpanded(_ url: URL) {
        let opening = !expandedFiles.contains(url.path)
        if opening { expandedFiles.insert(url.path) } else { expandedFiles.remove(url.path) }
        // Remember it as the tree's current folder (collapsing goes back to its parent).
        if let place = projectContaining(url) {
            treeFolders[place.root.path] = opening ? url.path : (place.relative.contains("/") ? url.deletingLastPathComponent().path : nil)
        }
    }

    // MARK: Live refresh

    /// Watches every project folder that is available now (new projects and plugged-in drives included).
    func updateWatchedFolders() {
        let roots = shelf.projects.compactMap { browseURL($0)?.standardizedFileURL.path }.sorted()
        if roots != watchedRoots { watchedRoots = roots; linksChanged() }
        // Linked originals live outside the project folders, so they are watched too.
        folderWatcher?.watch(roots + linkedTargets)
    }

    /// Finds the originals that projects link to (in the background), so changes to them show up live.
    func linksChanged() {
        guard !linkScanRunning else { linkScanPending = true; return }
        linkScanRunning = true
        lastLinkScan = Date()
        let roots = shelf.projects.compactMap { browseURL($0) }
        Task {
            let targets = await Task.detached(priority: .utility) { Set(roots.flatMap { ShelfFiles.linkedFolders(in: $0) }.map(\.path)).sorted() }.value
            linkScanRunning = false
            if targets != linkedTargets { linkedTargets = targets; updateWatchedFolders() }
            if linkScanPending { linkScanPending = false; linksChanged() }
        }
    }

    /// Collects file-system changes and refreshes once they settle, so a big copy or
    /// download doesn't redraw the window hundreds of times.
    func filesChanged(_ paths: [String]) {
        let relevant = paths.filter(FolderWatcher.isRelevant)
        guard !relevant.isEmpty else { return }
        pendingFileChanges.formUnion(relevant)
        guard !fileRefreshScheduled else { return }
        fileRefreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            applyFileChanges()
        }
    }

    func applyFileChanges() {
        fileRefreshScheduled = false
        let changed = pendingFileChanges
        pendingFileChanges = []
        guard !changed.isEmpty else { return }
        fileTick += 1
        for project in shelf.projects {
            guard let root = browseURL(project)?.standardizedFileURL.path, changed.contains(where: { ShelfFiles.contains($0, in: root) }) else { continue }
            gitChecked[project.id] = nil
            if section == "shelf:" + project.id { refreshGit(project, force: true) }
        }
        if section == "Activity" { loadActivity() }
        // New links may have appeared (e.g. made in Finder); look again now and then.
        if Date().timeIntervalSince(lastLinkScan) > 15 { linksChanged() }
    }

    /// The folder the user is looking at: the grid's folder, or the last folder opened in the tree.
    func currentFolder(_ project: ShelfProject, root: URL) -> URL {
        if prefs.fileView == "grid" { return gridFolder(project, root: root) }
        guard let path = treeFolders[root.path], ShelfFiles.contains(path, in: root.path), expandedFiles.contains(path),
              FileManager.default.fileExists(atPath: path) else { return root }
        return URL(fileURLWithPath: path)
    }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func openFile(_ url: URL) { NSWorkspace.shared.open(url) }
    func copyPath(_ url: URL) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }

    func chooseFiles(into folder: URL, projectRoot: URL) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
        picker.prompt = "Add"
        picker.message = prefs.addMode == "link" ? "The files you choose stay where they are and appear in “\(folder.lastPathComponent)” as links — nothing is copied or moved." : prefs.addMode == "move" ? "The files you choose are moved into “\(folder.lastPathComponent)”." : "Files and folders are copied into “\(folder.lastPathComponent)”. The originals stay where they are."
        if picker.runModal() == .OK { addItems(picker.urls, into: folder, projectRoot: projectRoot) }
    }

    func receiveDrop(_ providers: [NSItemProvider], into folder: URL, projectRoot: URL) {
        Task { @MainActor in
            var urls: [URL] = []
            // Like Finder: hold Option to copy, or Command to move, instead of the usual setting.
            let flags = NSEvent.modifierFlags
            let mode: String? = flags.contains(.option) ? "copy" : flags.contains(.command) ? "move" : nil
            for provider in providers { if let url = await Self.fileURL(from: provider) { urls.append(url) } }
            addItems(urls, into: folder, projectRoot: projectRoot, mode: mode)
        }
    }

    nonisolated static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// Puts items into a project folder. With the default "link" setting, items from outside the
    /// project stay exactly where they are and appear in the project as links — nothing is copied
    /// or moved. `mode` overrides the setting ("link", "move" or "copy"). Items already stored in
    /// the project are always moved (reorganizing).
    func addItems(_ urls: [URL], into folder: URL, projectRoot: URL, mode: String? = nil) {
        guard !urls.isEmpty else { return }
        let skipping = prefs.skipDependencies ? ShelfFiles.regenerable : []
        let effective = mode ?? prefs.addMode
        let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
        showNotice((effective == "link" ? "Adding " : effective == "move" ? "Moving " : "Copying ") + what + " to “\(folder.lastPathComponent)”…", clear: false)
        Task {
            do {
                let moves = try await Task.detached(priority: .userInitiated) {
                    try ShelfFiles.transfer(urls, into: folder, projectRoot: projectRoot, move: effective == "move", link: effective == "link", skipping: skipping)
                }.value
                let added = moves.map(\.destination)
                for item in moves { followMarks(from: item.source, to: item.destination) }
                if folder.standardizedFileURL.path != projectRoot.standardizedFileURL.path { expandedFiles.insert(folder.path) }
                let linked = moves.filter { ShelfFiles.linkDestination($0.destination) != nil && ShelfFiles.linkDestination($0.source) == nil && FileManager.default.fileExists(atPath: $0.source.path) }.count
                let moved = moves.filter { !FileManager.default.fileExists(atPath: $0.source.path) }.count
                let verb = linked == added.count ? "Linked" : moved == added.count ? "Moved" : moved + linked == 0 ? "Copied" : "Added"
                showNotice(added.isEmpty ? "Already in “\(folder.lastPathComponent)”." : verb + " \(added.count == 1 ? "“" + added[0].lastPathComponent + "”" : "\(added.count) items") to “\(folder.lastPathComponent)”" + (linked == added.count ? " — the original stays where it is." : "."))
                if linked > 0 { linksChanged() }
                // Scanned folders that moved need the library rescanned.
                let root = projectRoot.standardizedFileURL.path
                if moved > 0 && moves.contains(where: { item in !ShelfFiles.contains(item.source.path, in: root) && inventory.projects.contains { ShelfFiles.contains($0.path, in: item.source.path) } }) { refresh() }
            } catch { notice = nil; message = error.localizedDescription }
            fileTick += 1
        }
    }

    func showNotice(_ text: String, clear: Bool = true) {
        notice = text
        guard clear else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if notice == text { notice = nil }
        }
    }

    // MARK: Scanned folders

    func beginAddScanned(into folder: URL, projectRoot: URL) {
        scannedRoot = projectRoot; scannedTargetPath = folder.path
        scannedPick = []; scannedQuery = ""; scannedMode = prefs.addMode
        showAddScanned = true
    }

    /// Opens the picker for a project, aiming at its Code folder when it has one.
    func beginAddScanned(_ project: ShelfProject) {
        guard let url = browseURL(project) else { return }
        let code = url.appendingPathComponent("Code")
        beginAddScanned(into: FileManager.default.fileExists(atPath: code.path) ? code : url, projectRoot: url)
    }

    var scannedMatches: [Project] {
        let root = scannedRoot?.standardizedFileURL.path ?? ""
        let query = scannedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return inventory.projects.filter { project in
            !ShelfFiles.contains(project.path, in: root) && !ShelfFiles.contains(root, in: project.path)
                && (query.isEmpty || (project.name + " " + project.path + " " + project.framework).localizedCaseInsensitiveContains(query))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func finishAddScanned() {
        guard let root = scannedRoot, !scannedPick.isEmpty else { return }
        showAddScanned = false
        addItems(scannedPick.sorted().map { URL(fileURLWithPath: $0) }, into: URL(fileURLWithPath: scannedTargetPath), projectRoot: root, mode: scannedMode)
    }

    /// Lets the user pick any folder inside a project as the destination for a scanned folder.
    func pickProjectFolder(for folder: URL) {
        let roots = shelf.projects.compactMap { browseURL($0)?.standardizedFileURL }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.directoryURL = roots.count == 1 ? roots[0] : shelf.rootURL
        picker.prompt = "Add here"
        picker.message = "Choose where to copy “\(folder.lastPathComponent)” inside one of your projects."
        guard picker.runModal() == .OK, let target = picker.url?.standardizedFileURL else { return }
        guard let root = roots.first(where: { ShelfFiles.contains(target.path, in: $0.path) }) else { message = "Choose a folder inside one of your projects."; return }
        addItems([folder], into: target, projectRoot: root)
    }

    /// Copies a scanned folder into a project's Code folder (or its top level).
    func addScanned(_ folder: URL, to project: ShelfProject) {
        guard let url = browseURL(project) else { return }
        let code = url.appendingPathComponent("Code")
        addItems([folder], into: FileManager.default.fileExists(atPath: code.path) ? code : url, projectRoot: url)
    }

    func newFolder(in folder: URL) {
        guard let name = ask("New folder", detail: "Create a folder inside “\(folder.lastPathComponent)”.", value: "New folder", button: "Create") else { return }
        do {
            try FileManager.default.createDirectory(at: ShelfFiles.uniqueURL(folder.appendingPathComponent(name)), withIntermediateDirectories: false)
            expandedFiles.insert(folder.path); fileTick += 1
        } catch { message = error.localizedDescription }
    }

    func rename(_ url: URL) {
        guard let name = ask("Rename “\(url.lastPathComponent)”", detail: "", value: url.lastPathComponent, button: "Rename"), name != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { message = "Something named “\(name)” already exists here."; return }
        do { try FileManager.default.moveItem(at: url, to: target); followMarks(from: url, to: target); fileTick += 1 } catch { message = error.localizedDescription }
    }

    /// Removes a link from the project. The original it points to is never touched.
    func removeLink(_ url: URL) {
        guard ShelfFiles.linkDestination(url) != nil else { return }
        do { try FileManager.default.removeItem(at: url); followMarks(from: url, to: nil); fileTick += 1; linksChanged() }
        catch { message = error.localizedDescription }
    }

    /// Points a link whose original was moved or deleted at a new location.
    func relink(_ url: URL) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Link to this"
        picker.message = "Choose the new location of “\(url.lastPathComponent)”. It stays where it is; the project links to it."
        guard picker.runModal() == .OK, let original = picker.url else { return }
        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original.standardizedFileURL)
            fileTick += 1; linksChanged()
        } catch { message = error.localizedDescription }
    }

    func trash(_ url: URL) {
        // A link goes away on its own; the original is never sent to the Trash this way.
        if ShelfFiles.linkDestination(url) != nil { removeLink(url); return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.message = error.localizedDescription } else { self?.followMarks(from: url, to: nil) }
                self?.fileTick += 1
            }
        }
    }

    func ask(_ title: String, detail: String, value: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return text.isEmpty || text == "." || text == ".." ? nil : text
    }

    // MARK: Transfer to drive

    func beginTransfer(_ project: ShelfProject, drive: String? = nil) {
        transferVolumeID = drive ?? project.copies.first { $0.onDrive && status(of: $0).isActive }?.volumeUUID ?? volumes.first(where: \.external)?.uuid ?? ""
        transferMove = false; transferStatus = ""; transferDone = 0; transferTotal = 0
        transferProjectID = project.id
    }

    func startTransfer() {
        guard !transferring, let project = shelf.projects.first(where: { $0.id == transferProjectID }),
              let volume = volumes.first(where: { $0.uuid == transferVolumeID && $0.external }) else { return }
        guard let source = browseURL(project) else { transferStatus = "The project folder isn’t available right now."; return }
        let existing = project.allLocations.first { $0.volumeUUID == volume.uuid }
        if let existing, existing == project.location { transferStatus = "This project already lives on \(volume.name)."; return }
        // Re-use an earlier copy on this drive so only new and changed files are copied.
        let destination = existing.flatMap { status(of: $0).url } ?? ShelfFiles.uniqueURL(volume.url.appendingPathComponent("DevShelf Projects").appendingPathComponent(source.lastPathComponent))
        guard !ShelfFiles.contains(destination.path, in: source.path), !ShelfFiles.contains(source.path, in: destination.path) else {
            transferStatus = "The project folder and the drive copy overlap. Choose another drive."; return
        }
        let move = transferMove && status(of: project.location).url == source
        let flag = CancelFlag()
        transferCancel = flag
        transferring = true; transferDone = 0; transferTotal = 0
        transferStatus = "Copying to \(volume.name)…"
        let progress: (Int, Int) -> Void = { [weak self] done, total in
            if done == total || done % 40 == 0 { Task { @MainActor in self?.transferDone = done; self?.transferTotal = total } }
        }
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try ShelfFiles.sync(from: source, to: destination, progress: progress, cancelled: { flag.cancelled })
                }.value
                var location = Volumes.location(for: destination, on: volume)
                location.synced = Date()
                if var updated = shelf.projects.first(where: { $0.id == project.id }) {
                    updated.copies.removeAll { $0.volumeUUID == volume.uuid }
                    updated.copies.append(location)
                    var trashed = false
                    if move, (try? FileManager.default.trashItem(at: source, resultingItemURL: nil)) != nil {
                        updated.copies.removeAll { $0.volumeUUID == volume.uuid }
                        updated.location = location
                        trashed = true
                    }
                    try? ShelfFiles.writeMetadata(updated, to: destination)
                    if let index = shelf.projects.firstIndex(where: { $0.id == project.id }) { shelf.projects[index] = updated }
                    saveShelf()
                    let size = ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)
                    transferStatus = (trashed ? "Moved to " : "Copied to ") + volume.name + ": \(report.copied) files (\(size))" + (report.unchanged > 0 ? ", \(report.unchanged) already up to date." : ".")
                    if move && !trashed { transferStatus += " The Mac folder could not be moved to the Trash, so it was kept." }
                }
            } catch is CancellationError {
                transferStatus = "Stopped. Files copied so far stay on the drive; transfer again to finish."
            } catch { transferStatus = error.localizedDescription }
            transferring = false; transferCancel = nil; fileTick += 1
        }
    }

    func cancelTransfer() { transferCancel?.cancelled = true }

    // MARK: Finder service

    func receiveIncoming(_ urls: [URL]) {
        incomingFiles = urls.map(\.standardizedFileURL)
        guard !incomingFiles.isEmpty else { return }
        showShelfEditor = false; transferProjectID = nil; showOrganizer = false; showFolders = false
        if shelf.projects.contains(where: { browseURL($0) != nil }) { showAddToProject = true } else { newProject(keepIncoming: true) }
    }

    func finishIncoming(into project: ShelfProject) {
        guard let url = browseURL(project) else { return }
        addItems(incomingFiles, into: url, projectRoot: url)
        incomingFiles = []; showAddToProject = false
        navigate("shelf:" + project.id)
    }
}
