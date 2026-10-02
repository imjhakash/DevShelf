import CoreServices
import Foundation

/// Watches project folders with FSEvents, so files added from Finder, an editor, a download or
/// the Terminal show up in DevShelf straight away. Events arrive on the main queue.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private(set) var paths: [String] = []
    private let onChange: ([String]) -> Void

    init(onChange: @escaping ([String]) -> Void) { self.onChange = onChange }
    deinit { stop() }

    /// Starts (or restarts) watching exactly these folders; does nothing if they haven't changed.
    func watch(_ folders: [String]) {
        let wanted = Array(Set(folders)).sorted()
        guard wanted != paths else { return }
        stop()
        paths = wanted
        guard !wanted.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            watcher.onChange(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, wanted as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { paths = []; return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        paths = []
    }

    /// Changes worth refreshing for: not dependency or cache folders, Git internals, or DevShelf's own files.
    static func isRelevant(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last, !ShelfFiles.ignored.contains(last) else { return false }
        return !parts.contains { ShelfFiles.regenerable.contains($0) || $0 == ".git" }
    }
}
