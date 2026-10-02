import CryptoKit
import Darwin
import Foundation

/// One copy of a duplicated file.
struct DuplicateFile: Identifiable, Hashable {
    let url: URL
    let place: String          // project name, "DevShelf Projects" or an outside folder name
    let inProject: Bool
    let modified: Date?
    let block: Int64?          // where the data starts on disk; equal blocks mean an APFS clone
    var id: String { url.path }
}

/// Files with identical contents.
struct DuplicateGroup: Identifiable, Hashable {
    let hash: String
    let size: Int64
    var files: [DuplicateFile]
    var id: String { hash }
    var name: String { files.first?.url.lastPathComponent ?? "" }
    /// Separate physical copies; clones of each other share one.
    var physicalCopies: Int { Set(files.map { $0.block.map(String.init) ?? $0.id }).count }
    var wastedBytes: Int64 { Int64(max(0, physicalCopies - 1)) * size }
    func sharesSpace(_ file: DuplicateFile) -> Bool { file.block != nil && files.filter { $0.block == file.block }.count > 1 }

    /// The copy to keep: inside a project, not in a backup/archive folder, without a " 2" / "copy"
    /// suffix, in the shallowest folder, oldest; then by path so the choice is stable.
    var suggestedKeeper: DuplicateFile? {
        files.min { a, b in
            let rank = { (file: DuplicateFile) -> (Int, Int, Int, Int, Date, String) in
                let stem = file.url.deletingPathExtension().lastPathComponent.lowercased()
                let copyLike = stem.range(of: #"( \d+| copy( \d+)?|-\d+|\(\d+\))$"#, options: .regularExpression) != nil
                let archived = file.url.deletingLastPathComponent().pathComponents.contains { ["backup", "backups", "archive", "archives", "old"].contains($0.lowercased()) }
                return (file.inProject ? 0 : 1, archived ? 1 : 0, copyLike ? 1 : 0, file.url.pathComponents.count, file.modified ?? .distantFuture, file.url.path)
            }
            return rank(a) < rank(b)
        }
    }

    /// Bytes freed by trashing `removing`: physical copies that no kept file still uses.
    func freedBytes(removing: Set<String>) -> Int64 {
        let kept = files.filter { !removing.contains($0.id) }
        guard !kept.isEmpty else { return Int64(physicalCopies) * size }
        let keptBlocks = Set(kept.map { $0.block.map(String.init) ?? $0.id })
        return Int64(physicalCopies - keptBlocks.count) * size
    }
}

enum Duplicates {
    static let minimumSize: Int64 = 256 * 1024

    /// The disk position of a file's first block (APFS clones share it), or nil when unknown.
    static func block(_ url: URL) -> Int64? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = log2phys()
        info.l2p_contigbytes = 1 << 20
        info.l2p_devoffset = 0
        guard fcntl(fd, F_LOG2PHYS_EXT, &info) != -1 else { return nil }
        return info.l2p_devoffset
    }

    static func hash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Regular files of at least `minimumSize`, skipping dependencies, Git data, packages and `excluded` folders.
    static func files(in root: URL, excluding excluded: [String] = []) -> [(URL, Int64, Date?)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, Int64, Date?)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                let path = url.standardizedFileURL.path
                if ShelfFiles.regenerable.contains(url.lastPathComponent) || excluded.contains(where: { ShelfFiles.contains(path, in: $0) }) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize.map(Int64.init), size >= minimumSize else { continue }
            found.append((url.standardizedFileURL, size, values.contentModificationDate))
        }
        return found
    }

    /// Finds identical files. `places` are scanned in full; `outside` folders only contribute copies of
    /// files that are in `places` (e.g. originals left behind in Downloads).
    static func scan(places: [(name: String, url: URL)], outside: [(name: String, url: URL)] = [], progress: (Int, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws -> [DuplicateGroup] {
        var candidates: [(URL, Int64, Date?, String, Bool)] = []
        var seen: Set<String> = []
        let placePaths = places.map { $0.url.standardizedFileURL.path }
        for place in places {
            // A project inside another scanned place is listed under its own name only.
            let nested = placePaths.filter { $0 != place.url.standardizedFileURL.path && ShelfFiles.contains($0, in: place.url.standardizedFileURL.path) }
            for (url, size, modified) in files(in: place.url, excluding: nested) where seen.insert(url.path).inserted {
                candidates.append((url, size, modified, place.name, true))
            }
        }
        let sizes = Set(candidates.map(\.1))
        for folder in outside {
            for (url, size, modified) in files(in: folder.url, excluding: placePaths) where sizes.contains(size) && seen.insert(url.path).inserted {
                candidates.append((url, size, modified, folder.name, false))
            }
        }
        let bySize = Dictionary(grouping: candidates, by: \.1).filter { $0.value.count > 1 && $0.value.contains { $0.4 } }
        let total = bySize.values.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        for (size, sameSize) in bySize {
            var byHash: [String: [DuplicateFile]] = [:]
            for (url, _, modified, place, inProject) in sameSize {
                if cancelled() { throw CancellationError() }
                done += 1
                progress(done, total)
                guard let digest = hash(url) else { continue }
                byHash[digest, default: []].append(DuplicateFile(url: url, place: place, inProject: inProject, modified: modified, block: block(url)))
            }
            for (digest, copies) in byHash where copies.count > 1 && copies.contains(where: \.inProject) {
                groups.append(DuplicateGroup(hash: digest, size: size, files: copies.sorted { $0.url.path < $1.url.path }))
            }
        }
        return groups.sorted { ($0.wastedBytes, $0.size) > ($1.wastedBytes, $1.size) }
    }
}
