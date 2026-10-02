import AppKit
import SwiftUI

extension AppState {
    func beginDuplicates(_ project: ShelfProject? = nil) {
        duplicateScope = project?.id ?? "all"
        duplicateGroups = []; duplicateSelection = []; duplicateStatus = ""; duplicateScanned = false
        showDuplicates = true
        scanDuplicates()
    }

    func scanDuplicates() {
        guard !duplicateScanning else { return }
        var places: [(name: String, url: URL)] = []
        if let project = shelf.projects.first(where: { $0.id == duplicateScope }) {
            if let url = browseURL(project) { places = [(project.name, url)] }
        } else {
            places = shelf.projects.compactMap { project in browseURL(project).map { (project.name, $0) } }
            if FileManager.default.fileExists(atPath: shelf.rootURL.path) { places.append(("DevShelf Projects", shelf.rootURL)) }
        }
        let home = homeURL
        let outside = duplicateIncludeOutside ? ["Downloads", "Desktop", "Documents"].map { ($0, home.appendingPathComponent($0)) } : []
        let flag = CancelFlag()
        duplicateCancel = flag
        duplicateScanning = true; duplicateGroups = []; duplicateSelection = []
        duplicateStatus = "Looking for identical files…"
        let report: (Int, Int) -> Void = { [weak self] done, total in
            if done == total || done % 25 == 0 { Task { @MainActor in self?.duplicateStatus = "Comparing \(done) of \(total) files…" } }
        }
        Task {
            do {
                let groups = try await Task.detached(priority: .userInitiated) { try Duplicates.scan(places: places, outside: outside, progress: report, cancelled: { flag.cancelled }) }.value
                duplicateGroups = groups
                // Pre-select every copy except the one to keep, in groups that really waste space.
                duplicateSelection = Set(groups.filter { $0.wastedBytes > 0 }.flatMap { group in group.files.filter { $0.id != group.suggestedKeeper?.id }.map(\.id) })
                let wasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
                duplicateStatus = groups.isEmpty ? "No duplicate files found." : "\(groups.count) sets of identical files · " + ByteCountFormatter.string(fromByteCount: wasted, countStyle: .file) + " used by extra copies."
            } catch is CancellationError {
                duplicateStatus = "Stopped."
            } catch { duplicateStatus = error.localizedDescription }
            duplicateScanning = false; duplicateScanned = true; duplicateCancel = nil
        }
    }

    var duplicateFreedBytes: Int64 { duplicateGroups.reduce(0) { $0 + $1.freedBytes(removing: duplicateSelection) } }

    func trashSelectedDuplicates() {
        let files = duplicateGroups.flatMap(\.files).filter { duplicateSelection.contains($0.id) }
        guard !files.isEmpty else { return }
        // Never remove every copy of a file.
        if let group = duplicateGroups.first(where: { group in group.files.allSatisfy { duplicateSelection.contains($0.id) } }) {
            message = "Keep at least one copy of “\(group.name)”. Untick one of its copies first."; return
        }
        let alert = NSAlert()
        alert.messageText = "Move \(files.count) duplicate file\(files.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "One copy of each file is kept. This frees about " + ByteCountFormatter.string(fromByteCount: duplicateFreedBytes, countStyle: .file) + " once you empty the Trash. You can put files back from the Trash until then."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failed: [String] = []
        for file in files {
            do { try FileManager.default.trashItem(at: file.url, resultingItemURL: nil); followMarks(from: file.url, to: nil) }
            catch { failed.append(file.url.lastPathComponent) }
        }
        fileTick += 1
        let freed = duplicateFreedBytes
        duplicateGroups = duplicateGroups.compactMap { group in
            var group = group
            group.files.removeAll { duplicateSelection.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
            return group.files.count > 1 ? group : nil
        }
        duplicateSelection = []
        duplicateStatus = "Moved \(files.count - failed.count) files to the Trash · about " + ByteCountFormatter.string(fromByteCount: freed, countStyle: .file) + " freed after emptying the Trash." + (failed.isEmpty ? "" : " Could not move: " + failed.joined(separator: ", ") + ".")
    }
}

struct DuplicatesSheet: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Find duplicates", systemImage: "square.on.square").font(.system(size: 22, weight: .semibold))
                    Text("Identical files (256 KB and larger). Copies marked “shares space” are APFS clones and use no extra disk space.").font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Button { state.duplicateCancel?.cancelled = true; state.showDuplicates = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                Picker("Look in", selection: $state.duplicateScope) {
                    Text("All projects").tag("all")
                    Divider()
                    ForEach(state.shelf.projects.filter { state.browseURL($0) != nil }) { project in Text(project.name).tag(project.id) }
                }.frame(width: 260)
                Toggle("Also Downloads, Desktop & Documents", isOn: $state.duplicateIncludeOutside).font(.system(size: 11))
                Spacer()
                if state.duplicateScanning { Button("Stop") { state.duplicateCancel?.cancelled = true } }
                else { Button { state.scanDuplicates() } label: { Label("Scan", systemImage: "magnifyingglass") } }
            }.font(.system(size: 11)).disabled(false)
            HStack(spacing: 8) {
                if state.duplicateScanning { ProgressView().controlSize(.small) }
                Text(state.duplicateStatus).font(.system(size: 11)).foregroundStyle(muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.duplicateGroups) { group in DuplicateGroupView(state: state, group: group) }
                    if state.duplicateScanned && state.duplicateGroups.isEmpty && !state.duplicateScanning {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(accent)
                            Text("No duplicates — every file is stored once.").font(.system(size: 12)).foregroundStyle(muted)
                        }.frame(maxWidth: .infinity).padding(40)
                    }
                }
            }.frame(height: 430)
            HStack {
                Button("Select extra copies") {
                    state.duplicateSelection = Set(state.duplicateGroups.filter { $0.wastedBytes > 0 }.flatMap { group in group.files.filter { $0.id != group.suggestedKeeper?.id }.map(\.id) })
                }.disabled(state.duplicateGroups.isEmpty)
                Button("Select none") { state.duplicateSelection = [] }.disabled(state.duplicateSelection.isEmpty)
                Spacer()
                Button("Done") { state.duplicateCancel?.cancelled = true; state.showDuplicates = false }.keyboardShortcut(.cancelAction)
                Button("Move \(state.duplicateSelection.count) to Trash · frees " + ByteCountFormatter.string(fromByteCount: state.duplicateFreedBytes, countStyle: .file)) { state.trashSelectedDuplicates() }
                    .buttonStyle(.borderedProminent).tint(.orange).disabled(state.duplicateSelection.isEmpty || state.duplicateScanning)
            }.font(.system(size: 11))
        }.padding(24).frame(width: 760).background(canvas).preferredColorScheme(.dark)
    }
}

struct DuplicateGroupView: View {
    @ObservedObject var state: AppState
    let group: DuplicateGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.icon(group.files[0].url)).resizable().frame(width: 20, height: 20)
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("\(group.files.count) copies · " + ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file) + " each").font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                if group.wastedBytes > 0 { Pill(title: ByteCountFormatter.string(fromByteCount: group.wastedBytes, countStyle: .file) + " extra", color: .orange) }
                else { Pill(title: "Clones · no extra space", color: accent) }
            }.padding(.horizontal, 12).padding(.vertical, 9)
            Divider().opacity(0.15)
            ForEach(group.files) { file in
                let selected = state.duplicateSelection.contains(file.id)
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { selected }, set: { if $0 { state.duplicateSelection.insert(file.id) } else { state.duplicateSelection.remove(file.id) } })).labelsHidden().toggleStyle(.checkbox)
                    Text(file.place).font(.system(size: 10, weight: .semibold)).foregroundStyle(file.inProject ? accent : .orange).frame(width: 110, alignment: .leading).lineLimit(1)
                    Text(shortPath(file.url.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(selected ? muted : Color.white.opacity(0.85)).strikethrough(selected).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if file.id == group.suggestedKeeper?.id { Text("keep").font(.system(size: 9, weight: .semibold)).foregroundStyle(accent) }
                    if group.sharesSpace(file) { Text("shares space").font(.system(size: 9)).foregroundStyle(muted).help("This copy is an APFS clone: it shares disk blocks with another copy, so removing it frees little or nothing.") }
                    if let modified = file.modified { Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 9)).foregroundStyle(muted) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Show in Finder")
                }.padding(.horizontal, 12).padding(.vertical, 5)
            }
        }.background(panel, in: RoundedRectangle(cornerRadius: 10))
    }
}
