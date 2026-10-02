import AppKit
import SwiftUI

struct FolderTreeList: View {
    @ObservedObject var state: AppState
    let projects: [Project]
    var roots: [FolderTreeNode] { FolderTree.build(projects) }
    private func revealSearchMatches() {
        if !state.search.isEmpty { state.expandedFolderPaths.formUnion(roots.reduce(Set<String>()) { $0.union($1.branchPaths) }) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if roots.contains(where: { !$0.children.isEmpty }) {
                HStack {
                    Button("Expand all") { state.expandedFolderPaths.formUnion(roots.reduce(Set<String>()) { $0.union($1.branchPaths) }) }
                    Button("Collapse all") { state.expandedFolderPaths.removeAll() }
                    Spacer()
                    Text("One entry per folder").foregroundStyle(muted)
                }.font(.system(size: 10)).buttonStyle(.borderless)
            }
            LazyVStack(spacing: 1) {
                ForEach(roots) { node in
                    FolderTreeBranch(state: state, node: node, expanded: $state.expandedFolderPaths, depth: 0)
                }
            }.background(panel, in: RoundedRectangle(cornerRadius: 10))
        }.onAppear { revealSearchMatches() }
            .onChange(of: state.search) { _ in revealSearchMatches() }
            .onChange(of: projects.map(\.path)) { _ in revealSearchMatches() }
    }
}

struct FolderTreeBranch: View {
    @ObservedObject var state: AppState
    let node: FolderTreeNode
    @Binding var expanded: Set<String>
    let depth: Int
    var isExpanded: Bool { expanded.contains(node.path) }
    func toggle() {
        if isExpanded { expanded.remove(node.path) } else { expanded.insert(node.path) }
    }
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                if !node.children.isEmpty {
                    Button(action: toggle) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted).frame(width: 25, height: 42).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel((isExpanded ? "Collapse " : "Expand ") + node.name)
                        .help("\(node.projectCount) project folders")
                } else { Color.clear.frame(width: 25, height: 1) }
                if let project = node.project {
                    VStack(alignment: .leading, spacing: 0) {
                        JevResultRow(state: state, project: project)
                        if !node.children.isEmpty { Text("\(node.children.reduce(0) { $0 + $1.projectCount }) nested project folders").font(.system(size: 10)).foregroundStyle(muted).padding(.leading, 55).padding(.bottom, 10) }
                    }
                } else {
                    Button(action: toggle) {
                        HStack(spacing: 13) {
                            Image(systemName: "folder.fill").font(.system(size: 28)).foregroundStyle(.cyan)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(node.name).font(.system(size: 13, weight: .semibold))
                                Text(shortPath(node.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text("\(node.projectCount) project folders").font(.system(size: 10)).foregroundStyle(muted)
                        }.padding(14).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)]) }
                    }
                }
            }.padding(.leading, CGFloat(depth) * 20 + 5)
            if isExpanded {
                ForEach(node.children) { child in
                    FolderTreeBranch(state: state, node: child, expanded: $expanded, depth: depth + 1)
                }
            }
        }
    }
}

struct JevResultsView: View {
    @ObservedObject var state: AppState
    var saved: [Project] { state.projects.filter { state.purposeResults[$0.path] != nil } }
    var reviewCount: Int { saved.filter { state.assignment($0).source != "Manual" && state.purposeResults[$0.path]?.purpose == .review }.count }
    var matchedCount: Int { saved.filter { state.assignment($0).purpose != .review }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Spacer()
                Button("Classify with Jev") { state.showOrganizer = true }.buttonStyle(.bordered)
            }
            HStack(spacing: 14) {
                Metric(title: "Saved results", count: saved.count, icon: "checkmark.circle")
                Metric(title: "Needs review", count: reviewCount, icon: "questionmark.folder")
                Metric(title: "Categorized", count: matchedCount, icon: "folder")
            }
            if state.organizing || state.organizerTotal > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(state.organizerStatus).font(.system(size: 12)); Spacer(); if state.organizing { Button("Stop") { state.cancelOrganization() } } }
                    if state.organizing { ProgressView(value: Double(state.organizedCount), total: Double(max(1, state.organizerTotal))).tint(accent) }
                    if state.organizedCount > 0 && state.costAvailable { Text(String(format: "Reported cost this run: $%.5f", state.organizerCost)).font(.system(size: 10)).foregroundStyle(muted) }
                }.padding(16).background(panel, in: RoundedRectangle(cornerRadius: 10))
            } else if let date = state.organization.lastRun { Text("Last Jev run: \(date.formatted())").font(.system(size: 11)).foregroundStyle(muted) }
            Text("Suggestions are shown even when confidence is low. Accepting a suggestion saves your manual choice.").font(.system(size: 11)).foregroundStyle(muted)
            if saved.isEmpty { Text(state.search.isEmpty ? "No saved results yet. Choose Classify with Jev to start." : "No results match your search.").font(.system(size: 13)).foregroundStyle(muted).padding(20) }
            FolderTreeList(state: state, projects: saved)
        }
    }
}

struct JevResultRow: View {
    @ObservedObject var state: AppState
    let project: Project
    var label: Assignment? { state.purposeResults[project.path] }
    var result: String {
        if state.assignment(project).source == "Manual" { return "Your category: " + state.assignment(project).purpose.title }
        return (label?.purpose == .review ? "Suggested: " : "Classified: ") + (label?.suggestedPurpose ?? label?.purpose ?? .review).title
    }
    var stale: Bool { label?.fingerprint != Categorizer.fingerprint(project) }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill").font(.system(size: 26)).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 5) {
                Button(URL(fileURLWithPath: project.path).lastPathComponent) { state.selection = project }.buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                if project.name != URL(fileURLWithPath: project.path).lastPathComponent { Text(project.name).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1) }
                Text(shortPath(project.path)).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                Text(result).font(.system(size: 11)).foregroundStyle(accent)
                if stale { Text("Metadata changed · reclassify to update").font(.system(size: 9)).foregroundStyle(.orange) }
            }
            Spacer()
            Text("\(Int((label?.confidence ?? 0) * 100))% confidence").font(.system(size: 10)).foregroundStyle(muted)
            if let purpose = label?.suggestedPurpose, purpose != .review, !stale, state.assignment(project).source != "Manual" { Button("Accept") { state.setPurpose(project, purpose) }.disabled(state.organizing) }
            Menu("Category") { ForEach(Purpose.allCases) { purpose in Button(purpose.title) { state.setPurpose(project, purpose) } } }.disabled(state.organizing).fixedSize()
        }.padding(14)
    }
}
