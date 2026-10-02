import AppKit
import SwiftUI
import UniformTypeIdentifiers

let shelfPalette: [(key: String, color: Color)] = [
    ("blue", Color(red: 0.36, green: 0.62, blue: 0.98)),
    ("teal", Color(red: 0.30, green: 0.78, blue: 0.76)),
    ("green", Color(red: 0.55, green: 0.80, blue: 0.40)),
    ("yellow", Color(red: 0.96, green: 0.78, blue: 0.30)),
    ("orange", Color(red: 0.98, green: 0.58, blue: 0.30)),
    ("red", Color(red: 0.95, green: 0.40, blue: 0.42)),
    ("pink", Color(red: 0.94, green: 0.48, blue: 0.75)),
    ("purple", Color(red: 0.66, green: 0.52, blue: 0.96)),
]
let shelfIcons = ["folder.fill", "globe", "briefcase.fill", "building.2.fill", "building.columns.fill", "cart.fill", "paintbrush.pointed.fill", "chevron.left.forwardslash.chevron.right", "iphone", "puzzlepiece.extension.fill", "chart.line.uptrend.xyaxis", "megaphone.fill", "sparkles", "camera.fill", "doc.text.fill", "server.rack", "bolt.fill", "heart.fill", "star.fill", "leaf.fill", "graduationcap.fill", "house.fill", "fork.knife", "gamecontroller.fill"]
let offlineGrey = Color(white: 0.45)

func shelfColor(_ key: String) -> Color { shelfPalette.first { $0.key == key }?.color ?? shelfPalette[0].color }

func statusColor(_ status: ProjectStatus) -> Color {
    switch status {
    case .active: return accent
    case .waiting: return Color(red: 0.96, green: 0.78, blue: 0.30)
    case .onHold: return Color(red: 0.66, green: 0.52, blue: 0.96)
    case .done: return Color(red: 0.30, green: 0.78, blue: 0.76)
    }
}

struct StatusPill: View {
    let status: ProjectStatus
    var body: some View {
        Label(status.title, systemImage: status.symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor(status)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4).background(statusColor(status).opacity(0.12), in: Capsule())
    }
}

enum FileIcons {
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func icon(_ url: URL) -> NSImage {
        let key = url.pathExtension.lowercased()
        if let image = cache[key] { return image }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        cache[key] = image
        return image
    }
}

extension AppState {
    /// A binding to a preference that saves as soon as it changes.
    func pref<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.prefs[keyPath: key] }, set: { self.prefs[keyPath: key] = $0; self.savePrefs() })
    }
    func dropBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.dropTarget == key }, set: { inside in
            if inside { self.dropTarget = key } else if self.dropTarget == key { self.dropTarget = nil }
        })
    }
    func togglePin(_ row: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            if pinnedRows.contains(row) { pinnedRows.remove(row); if peekingRow == row { peekingRow = nil } } else { pinnedRows.insert(row) }
        }
    }
    /// Opens the hovered row after a short pause, so passing over rows doesn't flicker.
    func hoverRow(_ row: String, inside: Bool) {
        if inside { hoveredRow = row } else if hoveredRow == row { hoveredRow = nil }
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            guard let delay = self.prefs.peekDelay else { return }
            try? await Task.sleep(nanoseconds: inside ? delay : 250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.peekingRow = self.hoveredRow.flatMap { self.pinnedRows.contains($0) ? nil : $0 } }
        }
    }
}

struct ShelfIcon: View {
    let project: ShelfProject
    let active: Bool
    var size: CGFloat = 40
    var body: some View {
        let color = active ? shelfColor(project.color) : offlineGrey
        Image(systemName: project.icon).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(active ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: size * 0.27))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27).stroke(color.opacity(active ? 0.40 : 0.20)))
    }
}

struct LocationChip: View {
    let location: FolderLocation
    let status: LocationStatus
    var body: some View {
        let color: Color = status == .missing ? .orange : !status.isActive ? offlineGrey : location.onDrive ? accent : Color.white.opacity(0.7)
        HStack(spacing: 5) {
            Image(systemName: location.onDrive ? "externaldrive.fill" : "laptopcomputer")
            Text(location.onDrive ? (location.volumeName ?? "Drive") : "This Mac")
            if status == .missing { Text("· missing") } else if !status.isActive { Text("· unplugged") }
        }.font(.system(size: 10, weight: .medium)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.12), in: Capsule())
            .help(status.url?.path ?? location.path)
    }
}

struct ShelfProjectMenu: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    var body: some View {
        let url = state.browseURL(project)
        Button("Open project") { state.navigate("shelf:" + project.id) }
        Button("Edit…") { state.editProject(project) }
        Divider()
        Button("Add files…") { if let url { state.chooseFiles(into: url, projectRoot: url) } }.disabled(url == nil)
        Button("Add scanned folders…") { state.beginAddScanned(project) }.disabled(url == nil)
        Button("New folder…") { if let url { state.newFolder(in: url) } }.disabled(url == nil)
        Button("Show in Finder") { if let url { state.open(url) } }.disabled(url == nil)
        Button("Open in \(state.editorName)") { if let url { state.openEditor(path: url.path) } }.disabled(url == nil)
        Button("Open Terminal here") { if let url { state.terminal(path: url.path) } }.disabled(url == nil)
        Button("Copy path") { if let url { state.copyPath(url) } }.disabled(url == nil)
        Divider()
        Button("Add login…") { state.newLogin(project) }
        Divider()
        Button("Zip & share…") { if let url { state.beginZip(url) } }.disabled(url == nil)
        Button("Transfer to drive…") { state.beginTransfer(project) }.disabled(url == nil)
        Button("Save as template…") { state.saveAsTemplate(project) }.disabled(url == nil)
        Button("Find duplicates…") { state.beginDuplicates(project) }.disabled(url == nil)
        Button("Remove from DevShelf") { state.removeFromShelf(project) }
    }
}

// MARK: - Projects home

struct ShelfHome: View {
    @ObservedObject var state: AppState
    var drive: String? = nil
    var body: some View {
        let projects = state.shelfProjects(onDrive: drive)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button { state.newProject() } label: { Label("New project", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(canvas)
                Button { state.addExistingFolders() } label: { Label("Add existing folder…", systemImage: "folder.badge.plus") }.buttonStyle(.bordered)
                if !state.shelf.projects.isEmpty {
                    Button { state.beginDuplicates() } label: { Label("Find duplicates", systemImage: "square.on.square") }.buttonStyle(.bordered).help("Find identical files that use extra disk space")
                }
                Spacer()
                if drive == nil && !state.shelf.projects.isEmpty {
                    Picker("", selection: state.pref(\.sortProjects)) { Text("Name").tag("name"); Text("Newest").tag("newest") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 140).help("Sort projects")
                }
            }.font(.system(size: 11))
            if drive == nil && !state.shelf.projects.isEmpty {
                HStack(spacing: 6) {
                    ForEach([("open", "Open"), ("active", "In progress"), ("waiting", "Waiting"), ("onHold", "On hold"), ("done", "Done"), ("all", "All")], id: \.0) { key, title in
                        let count = state.shelf.projects.filter { key == "all" || (key == "open" ? $0.status != .done : $0.status.rawValue == key) }.count
                        let selected = state.statusFilter == key
                        if count > 0 || key == "open" || key == "all" {
                            Button { state.statusFilter = key } label: {
                                Text("\(title) \(count)").font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? canvas : Color.white.opacity(0.7))
                                    .padding(.horizontal, 10).padding(.vertical, 5).background(selected ? accent : panel, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    Text(state.prefs.hoverPeek == "off" ? "Click a project to peek inside" : "Hover to peek · click to keep open · drop files on any folder").font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            if state.shelf.projects.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 44)).foregroundStyle(accent)
                    Text("All your project files, in one place").font(.system(size: 18, weight: .semibold))
                    Text("Create a project, pick the folders it needs — code, design, documents, images, videos — and drop everything in. No more files scattered across Downloads and Desktop.")
                        .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center).frame(maxWidth: 440)
                    Button("Create your first project") { state.newProject() }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(canvas).padding(.top, 4)
                }.frame(maxWidth: .infinity).padding(.vertical, 50).background(panel, in: RoundedRectangle(cornerRadius: 14))
            } else if projects.isEmpty {
                Text(drive != nil ? "No projects on this drive yet. Open a project and choose Transfer to drive." : state.search.isEmpty ? "No projects with this status." : "No projects match your search.").font(.system(size: 12)).foregroundStyle(muted).padding(20)
            }
            VStack(spacing: 8) {
                ForEach(projects) { project in ShelfProjectRow(state: state, project: project, drive: drive) }
            }
        }
    }
}

struct ShelfProjectRow: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    var drive: String? = nil
    var rowID: String { (drive ?? "all") + ":" + project.id }

    /// The project's top-level folders, e.g. "Code · Design · Images · +2".
    func folderSummary(_ url: URL) -> String {
        let folders = ShelfFiles.children(of: url).filter(\.isFolder).map(\.name)
        if folders.isEmpty { return project.notes.isEmpty ? "No folders yet" : project.notes }
        return folders.prefix(4).joined(separator: " · ") + (folders.count > 4 ? " · +\(folders.count - 4)" : "")
    }

    var body: some View {
        let url = state.browseURL(project, onDrive: drive)
        let active = url != nil
        let color = active ? shelfColor(project.color) : offlineGrey
        let open = state.pinnedRows.contains(rowID) || state.peekingRow == rowID
        let hovering = state.hoveredRow == rowID
        let dropKey = "row:" + rowID
        let border: Color = state.dropTarget == dropKey ? color : open ? color.opacity(0.45) : Color.white.opacity(hovering ? 0.12 : 0.05)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(muted)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                ShelfIcon(project: project, active: active)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white.opacity(active ? 0.95 : 0.5)).lineLimit(1)
                    Text(url.map(folderSummary) ?? state.offlineMessage(project, onDrive: drive)).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                }
                Spacer(minLength: 10)
                HStack(spacing: 5) {
                    if let infos = state.gitInfo[project.id] { GitChip(infos: infos) }
                    if project.status != .active { StatusPill(status: project.status) }
                    if !project.tasks.isEmpty {
                        Label("\(project.tasks.count - project.openTasks)/\(project.tasks.count)", systemImage: "checklist").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Color.white.opacity(0.05), in: Capsule()).help("\(project.openTasks) to-dos left")
                    }
                    ForEach(project.allLocations, id: \.self) { LocationChip(location: $0, status: state.status(of: $0)) }
                }
                if let url, hovering {
                    Button { state.chooseFiles(into: url, projectRoot: url) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add files to this project")
                    Button { state.open(url) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Open in Finder")
                }
                Menu { ShelfProjectMenu(state: state, project: project) } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture { state.togglePin(rowID) }
            .contextMenu { ShelfProjectMenu(state: state, project: project) }
            if open {
                Divider().opacity(0.25)
                if let url {
                    FileTree(state: state, folder: url, projectRoot: url, tint: color, depth: 0, limit: 40).padding(.vertical, 6)
                } else {
                    Label(state.offlineMessage(project, onDrive: drive), systemImage: "externaldrive.badge.xmark").font(.system(size: 11)).foregroundStyle(muted).padding(16)
                }
                HStack {
                    Button("Open project") { state.navigate("shelf:" + project.id) }.buttonStyle(.borderless).foregroundStyle(color)
                    Spacer()
                    if let url { Text(shortPath(url.path)).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle) }
                }.font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 10).padding(.top, 2)
            }
        }
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 3).padding(.vertical, 14) }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: state.dropTarget == dropKey ? 2 : 1))
        .opacity(active ? 1 : 0.75)
        .onHover { state.hoverRow(rowID, inside: $0) }
        .onAppear { state.refreshGit(project) }
        .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding(dropKey)) { providers in
            guard let url else { return false }
            state.receiveDrop(providers, into: url, projectRoot: url)
            return true
        }
    }
}

// MARK: - File tree

struct FileTree: View {
    @ObservedObject var state: AppState
    let folder: URL
    let projectRoot: URL
    let tint: Color
    let depth: Int
    var limit = 300
    var body: some View {
        let _ = state.fileTick
        let items = state.pinnedFirst(ShelfFiles.children(of: folder, showHidden: state.prefs.showHiddenFiles))
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(depth == 0 ? "Empty. Drop files here, or use Add files." : "Empty folder").font(.system(size: 11)).foregroundStyle(muted)
                    .padding(.leading, CGFloat(depth) * 18 + 34).padding(.vertical, 5)
            }
            ForEach(items.prefix(limit)) { item in FileTreeRow(state: state, item: item, projectRoot: projectRoot, tint: tint, depth: depth) }
            if items.count > limit {
                Button("+ \(items.count - limit) more items · Show in Finder") { state.open(folder) }.buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(muted)
                    .padding(.leading, CGFloat(depth) * 18 + 34).padding(.vertical, 5)
            }
        }
    }
}

struct FileTreeRow: View {
    @ObservedObject var state: AppState
    let item: FileItem
    let projectRoot: URL
    let tint: Color
    let depth: Int
    var expanded: Bool { state.expandedFiles.contains(item.url.path) }
    var detail: String {
        if item.isFolder { return "" }
        return item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 10).opacity(item.isFolder ? 1 : 0)
                let mark = item.isFolder ? state.folderMark(item.url) : nil
                if item.isFolder { Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(mark?.color.map(shelfColor) ?? tint).frame(width: 17) }
                else { Image(nsImage: FileIcons.icon(item.url)).resizable().frame(width: 16, height: 16).frame(width: 17) }
                Text(item.name).font(.system(size: 12)).foregroundStyle(item.broken ? muted : .white).lineLimit(1).truncationMode(.middle)
                MarkBadges(mark: mark)
                if let original = item.link {
                    Image(systemName: item.broken ? "exclamationmark.triangle.fill" : "link").font(.system(size: 9)).foregroundStyle(item.broken ? Color.orange : muted)
                        .help(item.broken ? "Original not found (was at \(shortPath(original.path))). Right-click → Relink." : "Linked from \(shortPath(original.path)) — the original stays there.")
                }
                Spacer(minLength: 8)
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
            }
            .padding(.leading, CGFloat(depth) * 18 + 16).padding(.trailing, 16).padding(.vertical, 5)
            .background(state.dropTarget == item.url.path ? tint.opacity(0.20) : Color.clear)
            .contentShape(Rectangle())
            .help(item.modified.map { "Modified " + $0.formatted(date: .abbreviated, time: .shortened) } ?? item.name)
            .onTapGesture(count: item.isFolder ? 1 : 2) {
                if item.broken { state.explainBroken(item) }
                else if item.isFolder { withAnimation(.easeOut(duration: 0.12)) { state.toggleExpanded(item.url) } } else { state.openFile(item.url) }
            }
            .onDrag { NSItemProvider(object: item.url as NSURL) }
            .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding(item.url.path)) { providers in
                state.receiveDrop(providers, into: item.isFolder ? item.url : item.url.deletingLastPathComponent(), projectRoot: projectRoot)
                return true
            }
            .contextMenu { FileItemMenu(state: state, item: item, projectRoot: projectRoot) }
            if item.isFolder && expanded {
                FileTree(state: state, folder: item.url, projectRoot: projectRoot, tint: tint, depth: depth + 1)
            }
        }
    }
}

// MARK: - Project page

struct ShelfProjectPage: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    var body: some View {
        let url = state.browseURL(project)
        let active = url != nil
        let color = active ? shelfColor(project.color) : offlineGrey
        VStack(alignment: .leading, spacing: 22) {
            Button { state.navigate("Projects") } label: { Label("All projects", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11))
            HStack(alignment: .center, spacing: 18) {
                ShelfIcon(project: project, active: active, size: 62)
                VStack(alignment: .leading, spacing: 7) {
                    Text(project.name).font(.system(size: 28, weight: .semibold)).tracking(-0.5).textSelection(.enabled)
                    HStack(spacing: 5) {
                        Menu { ForEach(ProjectStatus.allCases) { status in Button { state.setStatus(project, status) } label: { Label(status.title, systemImage: status.symbol) } } } label: { StatusPill(status: project.status) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Change status")
                        ForEach(project.allLocations, id: \.self) { LocationChip(location: $0, status: state.status(of: $0)) }
                    }
                }
                Spacer()
                Button { state.editProject(project) } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(.bordered)
            }
            if !project.notes.isEmpty {
                Text(project.notes).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.75)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let url {
                HStack(spacing: 8) {
                    Button { state.chooseFiles(into: url, projectRoot: url) } label: { Label("Add files", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(color).foregroundStyle(canvas)
                    Button { state.beginAddScanned(project) } label: { Label("Add scanned folders", systemImage: "square.stack.3d.down.right") }
                    Button { state.newFolder(in: url) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    let current = state.currentFolder(project, root: url)
                    let inside = current.path == url.standardizedFileURL.path || current.path == url.path ? "" : " · " + current.lastPathComponent
                    Button { state.open(current) } label: { Label("Finder" + inside, systemImage: "folder") }.help("Open “\(current.lastPathComponent)” in Finder")
                    Button { state.openEditor(path: current.path) } label: { Label(state.editorName + inside, systemImage: "chevron.left.forwardslash.chevron.right") }.help("Open “\(current.lastPathComponent)” in \(state.editorName)")
                    Button { state.terminal(path: current.path) } label: { Label("Terminal" + inside, systemImage: "terminal") }.help("Open Terminal in “\(current.lastPathComponent)”")
                    Spacer()
                    Button { state.beginZip(url) } label: { Label("Zip & share…", systemImage: "doc.zipper") }
                    Button { state.beginTransfer(project) } label: { Label("Transfer to drive…", systemImage: "externaldrive.badge.plus") }
                }.font(.system(size: 11)).buttonStyle(.bordered)
                PinnedFoldersBar(state: state, project: project, root: url, color: color)
                FilesSection(state: state, project: project, root: url, color: color)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.xmark").font(.system(size: 30)).foregroundStyle(offlineGrey)
                    Text(state.offlineMessage(project)).font(.system(size: 12)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity).padding(36).background(panel, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CHECKLIST").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                    Spacer()
                    if !project.tasks.isEmpty { Text("\(project.tasks.count - project.openTasks) of \(project.tasks.count) done").font(.system(size: 10)).foregroundStyle(muted) }
                }
                VStack(spacing: 0) {
                    ForEach(project.tasks) { task in
                        HStack(spacing: 10) {
                            Button { state.toggleTask(project, task) } label: { Image(systemName: task.done ? "checkmark.circle.fill" : "circle").font(.system(size: 14)).foregroundStyle(task.done ? color : muted) }.buttonStyle(.plain)
                            Text(task.title).font(.system(size: 12)).strikethrough(task.done).foregroundStyle(task.done ? muted : Color.white.opacity(0.9)).textSelection(.enabled)
                            Spacer()
                            Button { state.removeTask(project, task) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.borderless).foregroundStyle(muted).help("Delete to-do")
                        }.padding(.horizontal, 14).padding(.vertical, 7)
                        Divider().opacity(0.15)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(muted).frame(width: 14)
                        TextField("Add a to-do and press Return, e.g. Export final logo files", text: $state.newTaskText).textFieldStyle(.plain).font(.system(size: 12)).onSubmit { state.addTask(project) }
                    }.padding(.horizontal, 14).padding(.vertical, 9)
                }.background(panel, in: RoundedRectangle(cornerRadius: 12))
            }
            LoginsSection(state: state, project: project, color: color)
            if let url { GitSection(state: state, project: project, root: url) }
            VStack(alignment: .leading, spacing: 8) {
                Text("LOCATIONS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                ForEach(project.allLocations, id: \.self) { location in
                    let status = state.status(of: location)
                    HStack(spacing: 10) {
                        Image(systemName: location.onDrive ? "externaldrive.fill" : "laptopcomputer").foregroundStyle(status.isActive ? (location.onDrive ? accent : .white) : offlineGrey).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((location.onDrive ? (location.volumeName ?? "Drive") : "This Mac") + (location == project.location ? " · main folder" : " · copy")).font(.system(size: 12, weight: .medium))
                            Text(status.isActive ? shortPath(status.url!.path) : status == .missing ? "Folder not found at " + shortPath(location.path) : "Drive unplugged. Connect it to open this copy.").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let synced = location.synced { Text("Synced " + synced.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(muted) }
                        if location.onDrive, location != project.location, status.isActive, active {
                            Button("Sync now") { state.beginTransfer(project, drive: location.volumeUUID) }.font(.system(size: 11))
                        }
                        if let path = status.url { Button { state.open(path) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Open in Finder") }
                    }.padding(12).background(panel, in: RoundedRectangle(cornerRadius: 9)).opacity(status.isActive ? 1 : 0.7)
                }
            }
        }
    }
}

// MARK: - New project / edit

struct ShelfEditor: View {
    @ObservedObject var state: AppState
    func heading(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(muted) }
    var body: some View {
        let tint = shelfColor(state.draft.color)
        let catalog = ShelfFiles.folderOptions.map(\.name)
        let custom = Array(NSOrderedSet(array: state.draftFolders.map { String($0.split(separator: "/").first ?? "") }.filter { !$0.isEmpty && !catalog.contains($0) })) as? [String] ?? []
        let nested = state.draftFolders.filter { $0.contains("/") }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(state.draftIsNew ? "New project" : "Edit project").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button { state.showShelfEditor = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            HStack(alignment: .center, spacing: 14) {
                ShelfIcon(project: state.draft, active: true, size: 52)
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Project name, e.g. Portfolio website", text: $state.draft.name).textFieldStyle(.roundedBorder).font(.system(size: 13))
                    HStack(spacing: 9) {
                        ForEach(shelfPalette, id: \.key) { option in
                            Button { state.draft.color = option.key } label: {
                                Circle().fill(option.color).frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(Color.white, lineWidth: state.draft.color == option.key ? 2 : 0).padding(-3))
                            }.buttonStyle(.plain).help(option.key.capitalized)
                        }
                        Spacer()
                        Menu {
                            ForEach(shelfIcons, id: \.self) { icon in Button { state.draft.icon = icon } label: { Image(systemName: icon) } }
                        } label: { Label("Icon", systemImage: state.draft.icon) }.fixedSize().font(.system(size: 11))
                    }
                }
            }
            if state.draftIsNew && state.draftFolder == nil {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        heading("FOLDERS")
                        Spacer()
                        Text("\(state.draftFolders.count) selected").font(.system(size: 10)).foregroundStyle(muted)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach([("starter", "Default", "star.fill"), ("none", "Empty", "square.dashed")] + state.allTemplates.map { ($0.id, $0.name, $0.icon) }, id: \.0) { id, name, icon in
                                let selected = state.draftTemplate == id
                                Button { state.applyPreset(id) } label: {
                                    Label(name, systemImage: icon).font(.system(size: 10, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? canvas : Color.white.opacity(0.75))
                                        .padding(.horizontal, 9).padding(.vertical, 5).background(selected ? tint : panel, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                        ForEach(ShelfFiles.folderOptions.map { ($0.name, $0.symbol) } + custom.map { ($0, "folder.fill") }, id: \.0) { name, symbol in
                            let on = state.draftHasFolder(name)
                            Button { state.toggleDraftFolder(name) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(on ? canvas : tint).frame(width: 22, height: 22)
                                        .background(on ? tint : tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                    Text(name).font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color.white : Color.white.opacity(0.65)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(tint) }
                                }.padding(7).contentShape(Rectangle())
                                    .background(on ? tint.opacity(0.12) : panel, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? tint.opacity(0.55) : Color.white.opacity(0.04)))
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Add your own folder…", text: $state.draftCustomFolder).textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 200).onSubmit { state.addCustomDraftFolder() }
                        Button("Add") { state.addCustomDraftFolder() }.font(.system(size: 11)).disabled(state.draftCustomFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                        if !nested.isEmpty { Text("Also creates " + nested.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1).truncationMode(.tail) }
                    }
                }
                HStack {
                    Picker("Save in", selection: $state.draftSaveIn) {
                        Text("This Mac · " + shortPath(state.shelf.rootURL.path)).tag("mac")
                        ForEach(state.volumes.filter(\.external)) { drive in Text(drive.name + " · DevShelf Projects").tag(drive.uuid) }
                    }.font(.system(size: 11)).frame(maxWidth: 360)
                    Spacer()
                    Text(ShelfFiles.folderName(state.draft.name)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    heading("NOTES")
                    TextEditor(text: $state.draft.notes).font(.system(size: 12)).frame(height: 70).padding(6).background(panel, in: RoundedRectangle(cornerRadius: 8))
                    if let folder = state.draftFolder { Text("Uses the existing folder " + shortPath(folder.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted) }
                }
            }
            if let error = state.editorError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { state.showShelfEditor = false }.keyboardShortcut(.cancelAction)
                Button(state.draftIsNew ? "Create project" : "Save") { state.saveDraft() }.keyboardShortcut(.defaultAction)
                    .disabled(state.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 580).background(canvas).preferredColorScheme(.dark)
    }
}

// MARK: - Transfer to drive

struct TransferSheet: View {
    @ObservedObject var state: AppState
    var body: some View {
        let project = state.shelf.projects.first { $0.id == state.transferProjectID }
        let drives = state.volumes.filter(\.external)
        VStack(alignment: .leading, spacing: 18) {
            Label("Transfer to drive", systemImage: "externaldrive.fill.badge.plus").font(.system(size: 23, weight: .semibold))
            if let project {
                Text("Copy “\(project.title)” and all its files to an external drive. It shows in colour while the drive is plugged in and grey once it’s removed.").font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                if drives.isEmpty {
                    Label("Plug in an external drive. It will appear here automatically.", systemImage: "cable.connector").font(.system(size: 12)).foregroundStyle(muted)
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 8) {
                        ForEach(drives) { drive in
                            Button { state.transferVolumeID = drive.uuid } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive.fill").font(.system(size: 20)).foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(drive.name).font(.system(size: 13, weight: .semibold))
                                        Text(drive.freeSpace.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free" } ?? "Connected").font(.system(size: 10)).foregroundStyle(muted)
                                    }
                                    Spacer()
                                    if project.allLocations.contains(where: { $0.volumeUUID == drive.uuid }) { Pill(title: "Already has a copy", color: accent) }
                                    Image(systemName: state.transferVolumeID == drive.uuid ? "checkmark.circle.fill" : "circle").foregroundStyle(state.transferVolumeID == drive.uuid ? accent : muted)
                                }.padding(12).contentShape(Rectangle())
                                    .background(state.transferVolumeID == drive.uuid ? accent.opacity(0.10) : panel, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }.disabled(state.transferring)
                    Picker("", selection: $state.transferMove) {
                        Text("Copy — keep it on this Mac too").tag(false)
                        Text("Move — keep it only on the drive (the Mac folder goes to the Trash)").tag(true)
                    }.pickerStyle(.radioGroup).labelsHidden().disabled(state.transferring || project.location.volumeUUID == state.transferVolumeID).font(.system(size: 12))
                    Text("If this drive already has a copy, only new and changed files are copied. Nothing on the drive is ever deleted. Linked files and folders are copied with their real contents, so the drive copy is complete.").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                if state.transferring {
                    ProgressView(value: Double(state.transferDone), total: Double(max(1, state.transferTotal))).tint(accent)
                }
                if !state.transferStatus.isEmpty { Text(state.transferStatus).font(.system(size: 11)).foregroundStyle(state.transferring ? muted : .white).fixedSize(horizontal: false, vertical: true) }
            }
            HStack {
                Spacer()
                if state.transferring { Button("Stop") { state.cancelTransfer() } }
                else {
                    Button("Close") { state.transferProjectID = nil }.keyboardShortcut(.cancelAction)
                    Button(state.transferMove ? "Move to drive" : "Copy to drive") { state.startTransfer() }.keyboardShortcut(.defaultAction)
                        .disabled(!drives.contains { $0.uuid == state.transferVolumeID })
                }
            }
        }.padding(28).frame(width: 560).background(canvas).preferredColorScheme(.dark)
    }
}

// MARK: - Finder service: add selected items to a project

struct AddToProjectSheet: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Add to a project", systemImage: "tray.and.arrow.down.fill").font(.system(size: 23, weight: .semibold))
            Text("Add " + (state.incomingFiles.count == 1 ? "“" + state.incomingFiles[0].lastPathComponent + "”" : "\(state.incomingFiles.count) items") + " to a project." + (state.prefs.addMode == "link" ? " They stay where they are and appear in the project as links." : state.prefs.addMode == "move" ? " They are moved into the project." : " They are copied; the originals stay where they are.")).font(.system(size: 12)).foregroundStyle(muted)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(state.shelf.projects.filter { state.browseURL($0) != nil }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { project in
                        Button { state.finishIncoming(into: project) } label: {
                            HStack(spacing: 12) {
                                ShelfIcon(project: project, active: true, size: 30)
                                Text(project.name).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Image(systemName: "arrow.right").foregroundStyle(muted)
                            }.padding(10).contentShape(Rectangle()).background(panel, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 260)
            HStack {
                Button("New project with these files…") { state.showAddToProject = false; state.newProject(keepIncoming: true) }
                Spacer()
                Button("Cancel") { state.incomingFiles = []; state.showAddToProject = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 520).background(canvas).preferredColorScheme(.dark)
    }
}

// MARK: - Scanned folders into a project

/// "Add to project" items for a scanned folder.
struct AddToProjectMenu: View {
    @ObservedObject var state: AppState
    let folder: URL
    var body: some View {
        let projects = state.shelf.projects.filter { state.browseURL($0) != nil }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        Menu("Add to project") {
            ForEach(projects) { project in Button(project.title) { state.addScanned(folder, to: project) } }
            if !projects.isEmpty { Divider() }
            Button("Choose a folder inside a project…") { state.pickProjectFolder(for: folder) }.disabled(projects.isEmpty)
        }
        Button("Make it a new project") { state.importFolders([folder]) }
    }
}

struct AddScannedSheet: View {
    @ObservedObject var state: AppState
    var body: some View {
        let root = state.scannedRoot
        let destinations = root.map { [$0] + ShelfFiles.children(of: $0).filter(\.isFolder).map(\.url) } ?? []
        VStack(alignment: .leading, spacing: 16) {
            Label("Add scanned folders", systemImage: "square.stack.3d.down.right.fill").font(.system(size: 23, weight: .semibold))
            Text("Pick folders DevShelf found on your Mac and put them in this project. You can also drag them from the Scanned library onto a project.").font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            TextField("Search scanned folders by name, path or framework…", text: $state.scannedQuery).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(state.scannedMatches) { project in
                        Toggle(isOn: Binding(get: { state.scannedPick.contains(project.path) }, set: { if $0 { state.scannedPick.insert(project.path) } else { state.scannedPick.remove(project.path) } })) {
                            HStack(spacing: 10) {
                                ProjectIcon(project: project, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name).font(.system(size: 12, weight: .medium))
                                    Text(shortPath(project.path)).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Pill(title: project.framework, color: projectColor(project))
                            }
                        }.toggleStyle(.checkbox).padding(8).background(panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if state.scannedMatches.isEmpty { Text(state.inventory.projects.isEmpty ? "Nothing scanned yet. Press ⌘R to scan your Mac." : "No scanned folders match.").font(.system(size: 12)).foregroundStyle(muted).padding(16) }
                }
            }.frame(height: 260)
            Picker("Put into", selection: $state.scannedTargetPath) {
                ForEach(destinations, id: \.path) { url in Text(url == root ? "Top of the project" : url.lastPathComponent).tag(url.path) }
            }.frame(maxWidth: 360)
            Picker("", selection: $state.scannedMode) {
                Text("Link — the folder stays where it is and appears in this project (recommended)").tag("link")
                Text("Move — the folder itself moves into this project").tag("move")
                Text("Copy — a duplicate is made (uses extra space; node_modules and caches are skipped)").tag("copy")
            }.pickerStyle(.radioGroup).labelsHidden().font(.system(size: 12))
            HStack {
                Text("\(state.scannedPick.count) selected").font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Button("Cancel") { state.showAddScanned = false }.keyboardShortcut(.cancelAction)
                Button((state.scannedMode == "link" ? "Link " : state.scannedMode == "move" ? "Move " : "Copy ") + (state.scannedPick.count == 1 ? "1 folder" : "\(state.scannedPick.count) folders")) { state.finishAddScanned() }
                    .keyboardShortcut(.defaultAction).disabled(state.scannedPick.isEmpty)
            }
        }.padding(28).frame(width: 620).background(canvas).preferredColorScheme(.dark)
    }
}
