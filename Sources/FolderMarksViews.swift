import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A pinned or favourite folder, resolved to its current location.
struct MarkedFolder: Identifiable {
    let project: ShelfProject
    let relative: String
    let mark: FolderMark
    let url: URL?          // nil while the project's drive is unplugged
    var id: String { project.id + "/" + relative }
    var name: String { (relative as NSString).lastPathComponent }
}

extension AppState {
    /// The project holding `url`, its folder, and `url`'s path relative to it.
    func projectContaining(_ url: URL) -> (index: Int, root: URL, relative: String)? {
        let path = url.standardizedFileURL.path
        for (index, project) in shelf.projects.enumerated() {
            guard let root = browseURL(project)?.standardizedFileURL, ShelfFiles.contains(path, in: root.path) else { continue }
            return (index, root, path == root.path ? "" : String(path.dropFirst(root.path.count + 1)))
        }
        return nil
    }

    func folderMark(_ url: URL) -> FolderMark? {
        guard let place = projectContaining(url), !place.relative.isEmpty else { return nil }
        return shelf.projects[place.index].folderMarks[place.relative]
    }

    func changeMark(_ url: URL, _ change: (inout FolderMark) -> Void) {
        guard let place = projectContaining(url), !place.relative.isEmpty else { return }
        updateProject(shelf.projects[place.index].id) { project in
            var mark = project.folderMarks[place.relative] ?? FolderMark()
            change(&mark)
            project.folderMarks[place.relative] = mark.isEmpty ? nil : mark
        }
    }

    func toggleFolderPin(_ url: URL) {
        changeMark(url) { $0.pinned.toggle() }
        showNotice((folderMark(url)?.pinned == true ? "Pinned “" : "Unpinned “") + url.lastPathComponent + "”.")
    }

    func toggleFolderFavorite(_ url: URL) {
        changeMark(url) { $0.favorite.toggle() }
        showNotice((folderMark(url)?.favorite == true ? "Added “\(url.lastPathComponent)” to Favorite folders." : "Removed “\(url.lastPathComponent)” from Favorite folders."))
    }

    func setFolderColor(_ url: URL, _ key: String?) { changeMark(url) { $0.color = key } }

    func folderTint(_ url: URL, fallback: Color) -> Color {
        folderMark(url)?.color.map(shelfColor) ?? fallback
    }

    /// Keeps marks on a folder that moved or was renamed; `to: nil` removes them (trashed).
    func followMarks(from source: URL, to destination: URL?) {
        // A copy leaves the original (and its marks) where it was.
        guard !FileManager.default.fileExists(atPath: source.path), let from = projectContaining(source), !from.relative.isEmpty,
              shelf.projects[from.index].folderMarks.keys.contains(where: { $0 == from.relative || $0.hasPrefix(from.relative + "/") }) else { return }
        let to = destination.flatMap(projectContaining)
        let marks = shelf.projects[from.index].folderMarks.filter { $0.key == from.relative || $0.key.hasPrefix(from.relative + "/") }
        updateProject(shelf.projects[from.index].id) { $0.moveMarks(from: from.relative, to: to?.index == from.index ? to?.relative : nil) }
        // Moved into another project: the marks go with it.
        if let to, to.index != from.index, !to.relative.isEmpty {
            updateProject(shelf.projects[to.index].id) { project in
                for (key, mark) in marks { project.folderMarks[to.relative + key.dropFirst(from.relative.count)] = mark }
            }
        }
    }

    /// Pinned folders first (in their natural order), then everything else.
    func pinnedFirst(_ items: [FileItem]) -> [FileItem] {
        guard let first = items.first, let place = projectContaining(first.url.deletingLastPathComponent()), !shelf.projects[place.index].folderMarks.isEmpty else { return items }
        let marks = shelf.projects[place.index].folderMarks
        let prefix = place.relative.isEmpty ? "" : place.relative + "/"
        let pinned = items.filter { $0.isFolder && marks[prefix + $0.name]?.pinned == true }
        return pinned + items.filter { item in !pinned.contains { $0.id == item.id } }
    }

    func markedFolders(_ project: ShelfProject, _ include: (FolderMark) -> Bool) -> [MarkedFolder] {
        let root = browseURL(project)
        return project.folderMarks.filter { include($0.value) }.compactMap { relative, mark in
            let url = root?.appendingPathComponent(relative)
            if let url, !FileManager.default.fileExists(atPath: url.path) { return nil }
            return MarkedFolder(project: project, relative: relative, mark: mark, url: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var favoriteFolders: [MarkedFolder] {
        shelf.projects.flatMap { markedFolders($0) { $0.favorite } }
    }

    /// Opens a project at one of its folders, in the grid or by expanding the tree.
    func revealFolder(_ folder: MarkedFolder) {
        guard let url = folder.url else { message = offlineMessage(folder.project); return }
        if section != "shelf:" + folder.project.id { navigate("shelf:" + folder.project.id) }
        typeFilter[folder.project.id] = nil
        gridFolders[folder.project.id] = url.path
        var path = ""
        for part in folder.relative.split(separator: "/") {
            path += (path.isEmpty ? "" : "/") + part
            if let root = browseURL(folder.project) { expandedFiles.insert(root.appendingPathComponent(path).path) }
        }
    }
}

/// Pin, favourite and colour actions for a folder's right-click menu.
struct FolderMarkMenu: View {
    @ObservedObject var state: AppState
    let url: URL
    var body: some View {
        let mark = state.folderMark(url)
        Button(mark?.pinned == true ? "Unpin folder" : "Pin to top") { state.toggleFolderPin(url) }
        Button(mark?.favorite == true ? "Remove from Favorite folders" : "Add to Favorite folders") { state.toggleFolderFavorite(url) }
        Menu("Folder colour") {
            Button((mark?.color == nil ? "✓ " : "") + "Project colour") { state.setFolderColor(url, nil) }
            Divider()
            ForEach(shelfColorKeys, id: \.self) { key in Button((mark?.color == key ? "✓ " : "") + key.capitalized) { state.setFolderColor(url, key) } }
        }
    }
}

/// Small pin / star badges shown next to marked folders.
struct MarkBadges: View {
    let mark: FolderMark?
    var size: CGFloat = 8
    var body: some View {
        HStack(spacing: 3) {
            if mark?.pinned == true { Image(systemName: "pin.fill").font(.system(size: size)).foregroundStyle(muted).rotationEffect(.degrees(35)).help("Pinned") }
            if mark?.favorite == true { Image(systemName: "star.fill").font(.system(size: size)).foregroundStyle(Color(red: 0.96, green: 0.78, blue: 0.30)).help("Favorite folder") }
        }
    }
}

/// The "Pinned" strip at the top of a project page.
struct PinnedFoldersBar: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    let root: URL
    let color: Color
    var body: some View {
        let _ = state.fileTick
        let pinned = state.markedFolders(project) { $0.pinned }
        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PINNED").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(pinned) { folder in
                        let tint = folder.mark.color.map(shelfColor) ?? color
                        let key = "pin:" + folder.id
                        let count = folder.url.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.resolvingSymlinksInPath().path).filter { !$0.hasPrefix(".") }.count } ?? 0
                        Button { state.revealFolder(folder) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(tint)
                                    .overlay { if let symbol = ShelfFiles.symbol(forFolder: folder.name) { Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(canvas.opacity(0.85)).offset(y: 2) } }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(folder.relative.contains("/") ? (folder.relative as NSString).deletingLastPathComponent : "\(count) item\(count == 1 ? "" : "s")").font(.system(size: 9)).foregroundStyle(muted).lineLimit(1).truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                                MarkBadges(mark: FolderMark(pinned: false, favorite: folder.mark.favorite))
                            }.padding(10).contentShape(Rectangle())
                                .background(state.dropTarget == key ? tint.opacity(0.22) : tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(state.dropTarget == key ? 0.9 : 0.35)))
                        }.buttonStyle(.plain).help("Open " + folder.relative)
                            .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding(key)) { providers in
                                guard let url = folder.url else { return false }
                                state.receiveDrop(providers, into: url, projectRoot: root); return true
                            }
                            .contextMenu {
                                if let url = folder.url {
                                    Button("Open in Finder") { state.open(url) }
                                    Button("Add files here…") { state.chooseFiles(into: url, projectRoot: root) }
                                    Divider()
                                    FolderMarkMenu(state: state, url: url)
                                }
                            }
                    }
                }
            }
        }
    }
}

/// The sidebar's Favorite folders section, across all projects.
struct FavoriteFoldersSidebar: View {
    @ObservedObject var state: AppState
    var body: some View {
        let favorites = state.favoriteFolders
        if !favorites.isEmpty {
            Text("FAVORITE FOLDERS").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(muted).padding(.leading, 23).padding(.bottom, 6).padding(.top, 16)
            ForEach(favorites) { folder in
                let available = folder.url != nil
                let tint = available ? (folder.mark.color.map(shelfColor) ?? shelfColor(folder.project.color)) : offlineGrey
                let key = "fav:" + folder.id
                Button { state.revealFolder(folder) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name).font(.system(size: 11)).lineLimit(1)
                            Text(folder.project.name).font(.system(size: 9)).foregroundStyle(muted).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if !available { Image(systemName: "externaldrive.badge.xmark").font(.system(size: 9)) }
                    }.foregroundStyle(available ? Color.white.opacity(0.75) : offlineGrey)
                        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 5).contentShape(Rectangle())
                        .background(state.dropTarget == key ? tint.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.horizontal, 10).help(folder.project.name + " › " + folder.relative + (available ? " · drop files here to add them" : ""))
                    .onDrop(of: [UTType.fileURL], isTargeted: state.dropBinding(key)) { providers in
                        guard let url = folder.url, let root = state.browseURL(folder.project) else { return false }
                        state.receiveDrop(providers, into: url, projectRoot: root); return true
                    }
                    .contextMenu {
                        if let url = folder.url {
                            Button("Open in Finder") { state.open(url) }
                            Divider()
                            FolderMarkMenu(state: state, url: url)
                        }
                    }
            }
        }
    }
}
