import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AppState {
    /// Groups a project's files by type in the background; refreshed when files change.
    func refreshTypes(_ project: ShelfProject) {
        guard let url = browseURL(project), !typeLoading.contains(project.id) else { return }
        if typeTick[project.id] == fileTick, typeGroups[project.id] != nil { return }
        typeLoading.insert(project.id)
        let id = project.id, tick = fileTick
        Task {
            let groups = await Task.detached(priority: .utility) { FileKinds.scan(url) }.value
            typeGroups[id] = groups
            typeTick[id] = tick
            typeLoading.remove(id)
            // Files changed again while scanning: scan once more.
            if fileTick != tick { refreshTypes(project) }
        }
    }

    /// The folder shown in a project's grid, kept inside the project.
    func gridFolder(_ project: ShelfProject, root: URL) -> URL {
        guard let path = gridFolders[project.id], ShelfFiles.contains(path, in: root.path), FileManager.default.fileExists(atPath: path) else { return root }
        return URL(fileURLWithPath: path)
    }
}

/// Right-click actions shared by the tree, the grid and type lists.
/// The small link mark on items that live elsewhere and only appear in the project.
struct LinkBadge: View {
    let item: FileItem
    var body: some View {
        if let original = item.link {
            Image(systemName: item.broken ? "exclamationmark.triangle.fill" : "link")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(item.broken ? Color.orange : Color.white.opacity(0.85))
                .padding(3).background(item.broken ? Color.orange.opacity(0.18) : Color.black.opacity(0.55), in: Circle())
                .help(item.broken ? "Original not found (was at \(shortPath(original.path))). Right-click → Relink." : "Linked from \(shortPath(original.path)) — the original stays there; nothing was copied or moved.")
        }
    }
}

extension AppState {
    func explainBroken(_ item: FileItem) {
        message = "The original of “\(item.name)” was moved, deleted, or is on an unplugged drive" + (item.link.map { " (it was at \(shortPath($0.path)))" } ?? "") + ". Right-click it and choose Relink… to point to its new location."
    }
}

struct FileItemMenu: View {
    @ObservedObject var state: AppState
    let item: FileItem
    let projectRoot: URL
    var body: some View {
        if let original = item.link {
            if item.broken {
                Button("Relink…") { state.relink(item.url) }
                Button("Remove broken link") { state.removeLink(item.url) }
                Divider()
            } else {
                Button("Show original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([original.resolvingSymlinksInPath()]) }
            }
        }
        Button(item.isFolder ? "Open in Finder" : "Open") { item.isFolder ? state.open(item.url) : state.openFile(item.url) }.disabled(item.broken)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Open in \(state.editorName)") { state.openEditor(path: item.url.path) }
        if item.isFolder { Button("Open Terminal here") { state.terminal(path: item.url.path) } }
        Button("Copy path") { state.copyPath(item.url) }
        if item.isFolder {
            Divider()
            Button("Add files here…") { state.chooseFiles(into: item.url, projectRoot: projectRoot) }
            Button("Add scanned folders here…") { state.beginAddScanned(into: item.url, projectRoot: projectRoot) }
            Button("New folder here…") { state.newFolder(in: item.url) }
            Button("Zip & share…") { state.beginZip(item.url) }
            Divider()
            FolderMarkMenu(state: state, url: item.url)
        }
        Divider()
        Button("Rename…") { state.rename(item.url) }
        if item.link != nil { Button("Remove link (original stays)") { state.removeLink(item.url) } }
        else { Button(ShelfFiles.storedInside(item.url, projectRoot: projectRoot) ? "Move to Trash" : "Move original to Trash") { state.trash(item.url) } }
    }
}

struct FilesSection: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    let root: URL
    let color: Color
    var body: some View {
        let groups = state.typeGroups[project.id] ?? []
        let selected = state.typeFilter[project.id].flatMap { id in groups.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FILES").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                if state.typeLoading.contains(project.id) { ProgressView().controlSize(.mini) }
                Spacer()
                Text("Drag in to add · drag out to share").font(.system(size: 10)).foregroundStyle(muted)
                Picker("", selection: state.pref(\.fileView)) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "list.bullet.indent").tag("tree")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 80).help("Grid or tree view")
            }
            if !groups.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 8)], spacing: 8) {
                    ForEach(groups) { group in
                        let on = selected?.id == group.id
                        Button { state.typeFilter[project.id] = on ? nil : group.id } label: {
                            HStack(spacing: 9) {
                                Image(systemName: group.symbol).font(.system(size: 14)).foregroundStyle(on ? canvas : color).frame(width: 26, height: 26)
                                    .background(on ? color : color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Text("\(group.files.count) · " + ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file)).font(.system(size: 9)).foregroundStyle(muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.padding(8).contentShape(Rectangle())
                                .background(on ? color.opacity(0.14) : panel, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? color.opacity(0.6) : Color.white.opacity(0.05)))
                        }.buttonStyle(.plain).help(on ? "Show all files" : "Show only " + group.title.lowercased())
                    }
                }
            }
            Group {
                if let selected {
                    TypeFileList(state: state, group: selected, root: root, color: color) { state.typeFilter[project.id] = nil }
                } else if state.prefs.fileView == "tree" {
                    FileTree(state: state, folder: root, projectRoot: root, tint: color, depth: 0).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(panel, in: RoundedRectangle(cornerRadius: 12))
                        .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding("page:" + project.id)) { providers in state.receiveDrop(providers, into: root, projectRoot: root); return true }
                } else {
                    FileGrid(state: state, project: project, root: root, color: color)
                }
            }
        }
        .onAppear { state.refreshTypes(project) }
        .onChange(of: state.fileTick) { _ in state.refreshTypes(project) }
    }
}

struct FileGrid: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    let root: URL
    let color: Color
    var body: some View {
        let _ = state.fileTick
        let current = state.gridFolder(project, root: root)
        let items = state.pinnedFirst(ShelfFiles.children(of: current, showHidden: state.prefs.showHiddenFiles))
        let trail = current.path == root.path ? [] : String(current.path.dropFirst(root.path.count + 1)).components(separatedBy: "/")
        let dropKey = "grid:" + current.path
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Button { state.gridFolders[project.id] = nil } label: { Label(root.lastPathComponent, systemImage: "house.fill").lineLimit(1) }.buttonStyle(.plain).foregroundStyle(trail.isEmpty ? .white : color)
                ForEach(Array(trail.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(muted)
                    Button(name) { state.gridFolders[project.id] = root.appendingPathComponent(trail[0...index].joined(separator: "/")).path }
                        .buttonStyle(.plain).foregroundStyle(index == trail.count - 1 ? .white : color).lineLimit(1)
                }
                Spacer()
                if !trail.isEmpty {
                    Button { state.gridFolders[project.id] = current.deletingLastPathComponent().path == root.path ? nil : current.deletingLastPathComponent().path } label: { Label("Up", systemImage: "arrow.up") }.buttonStyle(.borderless)
                }
                Button { state.openEditor(path: current.path) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }.buttonStyle(.borderless).help("Open “\(current.lastPathComponent)” in \(state.editorName)")
                Button { state.terminal(path: current.path) } label: { Image(systemName: "terminal") }.buttonStyle(.borderless).help("Open Terminal in “\(current.lastPathComponent)”")
                Button { state.newFolder(in: current) } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.borderless).help("New folder here")
                Button { state.chooseFiles(into: current, projectRoot: root) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add files here")
            }.font(.system(size: 11))
            if items.isEmpty {
                Text("Empty. Drop files here, or use + to add them.").font(.system(size: 11)).foregroundStyle(muted).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 10)], spacing: 12) {
                    ForEach(items) { item in FileTile(state: state, project: project, item: item, root: root, color: color) }
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(state.dropTarget == dropKey ? color : Color.white.opacity(0.05), lineWidth: state.dropTarget == dropKey ? 2 : 1))
            .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding(dropKey)) { providers in state.receiveDrop(providers, into: current, projectRoot: root); return true }
    }
}

struct FileTile: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    let item: FileItem
    let root: URL
    let color: Color
    var body: some View {
        let targeted = state.dropTarget == item.url.path
        let mark = item.isFolder ? state.folderMark(item.url) : nil
        let tint = mark?.color.map(shelfColor) ?? color
        VStack(spacing: 6) {
            ZStack {
                if item.isFolder {
                    Image(systemName: "folder.fill").font(.system(size: 36)).foregroundStyle(tint)
                    if let symbol = ShelfFiles.symbol(forFolder: item.name) { Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(canvas.opacity(0.85)).offset(y: 3) }
                }
                else { Image(nsImage: FileIcons.icon(item.url)).resizable().frame(width: 42, height: 42) }
            }.frame(height: 46)
                .overlay(alignment: .topTrailing) { MarkBadges(mark: mark, size: 9).offset(x: 12, y: -2) }
                .overlay(alignment: .bottomLeading) { LinkBadge(item: item).offset(x: -6, y: 2) }
            Text(item.name).font(.system(size: 11)).foregroundStyle(item.broken ? muted : .white).multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle).frame(height: 28, alignment: .top)
            Text(item.isFolder ? itemCount : item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "").font(.system(size: 9)).foregroundStyle(muted)
        }.padding(8).frame(maxWidth: .infinity)
            .background(targeted ? color.opacity(0.2) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture(count: 2) { if item.broken { state.explainBroken(item) } else if item.isFolder { state.gridFolders[project.id] = item.url.path } else { state.openFile(item.url) } }
            .onDrag { NSItemProvider(object: item.url as NSURL) }
            .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding(item.url.path)) { providers in
                state.receiveDrop(providers, into: item.isFolder ? item.url : item.url.deletingLastPathComponent(), projectRoot: root)
                return true
            }
            .contextMenu { FileItemMenu(state: state, item: item, projectRoot: root) }
            .help(item.name + (item.isFolder ? " · double-click to open" : item.modified.map { " · modified " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
    }
    var itemCount: String {
        let count = (try? FileManager.default.contentsOfDirectory(atPath: item.url.resolvingSymlinksInPath().path).filter { !$0.hasPrefix(".") }.count) ?? 0
        return count == 1 ? "1 item" : "\(count) items"
    }
}

/// Every file of one type in a project, wherever it is stored.
struct TypeFileList: View {
    @ObservedObject var state: AppState
    let group: FileGroup
    let root: URL
    let color: Color
    let close: () -> Void
    var body: some View {
        let files = group.files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("\(group.title) · \(group.files.count) files · " + ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file), systemImage: group.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                Spacer()
                Button { close() } label: { Label("All files", systemImage: "xmark") }.buttonStyle(.borderless).font(.system(size: 11))
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider().opacity(0.2)
            ForEach(files.prefix(400)) { file in
                HStack(spacing: 10) {
                    Image(nsImage: FileIcons.icon(file.url)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.system(size: 12)).lineLimit(1)
                        Text(String(file.url.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfEmpty ?? "Top of the project").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let modified = file.modified { Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(muted) }
                    Text(file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).frame(width: 70, alignment: .trailing)
                }.padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
                    .onTapGesture(count: 2) { state.openFile(file.url) }
                    .onDrag { NSItemProvider(object: file.url as NSURL) }
                    .contextMenu { FileItemMenu(state: state, item: file, projectRoot: root) }
            }
            if files.count > 400 { Text("+ \(files.count - 400) more").font(.system(size: 10)).foregroundStyle(muted).padding(14) }
        }.background(panel, in: RoundedRectangle(cornerRadius: 12))
    }
}


