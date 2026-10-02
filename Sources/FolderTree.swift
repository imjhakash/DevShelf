import Foundation

struct FolderTreeNode: Identifiable {
    let path: String
    let project: Project?
    let children: [FolderTreeNode]
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var projectCount: Int { (project == nil ? 0 : 1) + children.reduce(0) { $0 + $1.projectCount } }
    var branchPaths: Set<String> {
        children.reduce(children.isEmpty ? [] : [path]) { $0.union($1.branchPaths) }
    }
}

enum FolderTree {
    private final class Branch {
        let path: String
        var project: Project?
        var children: [String: Branch] = [:]
        init(_ path: String) { self.path = path }
        func displayed() -> FolderTreeNode {
            let nodes = children.values.map { $0.displayed() }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return FolderTreeNode(path: path, project: project, children: nodes)
        }
    }

    static func contains(_ path: String, in folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    static func build(_ projects: [Project], locations: [String]? = nil) -> [FolderTreeNode] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let canonical = projects.map { ($0, URL(fileURLWithPath: $0.path).standardizedFileURL.path) }
        let projectPaths = Set(canonical.map { $0.1 })
        let boundaries = (locations ?? [home, home + "/Downloads", home + "/Documents", home + "/Desktop"])
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { boundary in !projectPaths.contains { contains(boundary, in: $0) } }
            .sorted { $0.count > $1.count }
        var roots: [String: Branch] = [:]
        var seen: Set<String> = []
        for (project, path) in canonical where seen.insert(path).inserted {
            let boundary = boundaries.first { contains(path, in: $0) } ?? "/"
            let root = roots[boundary] ?? Branch(boundary)
            roots[boundary] = root
            let components = URL(fileURLWithPath: path).pathComponents.dropFirst(URL(fileURLWithPath: boundary).pathComponents.count)
            var branch = root
            for component in components {
                let childPath = URL(fileURLWithPath: branch.path).appendingPathComponent(component).path
                let child = branch.children[component] ?? Branch(childPath)
                branch.children[component] = child
                branch = child
            }
            branch.project = project
        }
        return roots.values.flatMap { root in
            root.project == nil ? root.children.values.map { $0.displayed() } : [root.displayed()]
        }.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.path < b.path : order == .orderedAscending
        }
    }
}
