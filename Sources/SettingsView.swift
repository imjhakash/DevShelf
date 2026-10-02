import AppKit
import SwiftUI

let appTagline = "Every project. Every file. One place."
let developerName = "Johirul Hoq Akash"
let developerGitHub = URL(string: "https://github.com/imjhakash")!

struct PreferencesView: View {
    @ObservedObject var state: AppState
    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    func note(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
    /// Closes Settings first, so the next sheet can open.
    func then(_ action: @escaping () -> Void) {
        state.showPreferences = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }
    var body: some View {
        let installed = state.installedEditors
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button { state.showPreferences = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("PROJECTS") {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("New projects are created in").font(.system(size: 12))
                                Text(shortPath(state.shelf.rootURL.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                            }
                            Spacer()
                            Button("Show") { try? FileManager.default.createDirectory(at: state.shelf.rootURL, withIntermediateDirectories: true); state.open(state.shelf.rootURL) }
                            Button("Change…") { state.chooseProjectsFolder() }
                        }.font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Folders ticked by default in a new project, one per line (use / for sub-folders, e.g. Code/theme)").font(.system(size: 11)).foregroundStyle(muted)
                            TextEditor(text: Binding(get: { state.prefs.starterFolders.joined(separator: "\n") }, set: { state.prefs.starterFolders = $0.components(separatedBy: "\n"); state.savePrefs() }))
                                .font(.system(size: 12, design: .monospaced)).frame(height: 96).padding(6).background(canvas, in: RoundedRectangle(cornerRadius: 8))
                            Button("Reset to defaults") { state.prefs.starterFolders = ShelfFiles.starterFolders; state.savePrefs() }.buttonStyle(.borderless).font(.system(size: 10))
                        }
                        Picker("Sort projects by", selection: state.pref(\.sortProjects)) {
                            Text("Name").tag("name"); Text("Newest first").tag("newest")
                        }.font(.system(size: 12)).frame(maxWidth: 320)
                    }
                    section("FILES") {
                        Picker("When adding files and folders", selection: state.pref(\.addMode)) {
                            Text("Link — originals stay where they are (no copy, no move · recommended)").tag("link")
                            Text("Move them into the project").tag("move")
                            Text("Copy them into the project (uses extra space)").tag("copy")
                        }.font(.system(size: 12)).frame(maxWidth: 520)
                        note("Applies to dropping, Add files, the Finder service and AI assistants. A link shows the original inside the project and always reflects its latest contents. Hold Option while dropping to copy, or Command to move.")
                        HStack {
                            Button { then { state.beginDuplicates() } } label: { Label("Find duplicate files…", systemImage: "square.on.square") }.font(.system(size: 11))
                            Spacer()
                        }
                        Picker("Peek inside on hover", selection: state.pref(\.hoverPeek)) {
                            Text("Off").tag("off"); Text("Fast").tag("fast"); Text("Normal").tag("normal"); Text("Slow").tag("slow")
                        }.pickerStyle(.segmented).font(.system(size: 12)).frame(maxWidth: 420)
                        note("Off means projects open only when you click them.")
                        Toggle("Show hidden files (.env, .gitignore…) in folder trees", isOn: state.pref(\.showHiddenFiles)).font(.system(size: 12))
                        Toggle("Skip rebuildable folders when copying code into a project", isOn: state.pref(\.skipDependencies)).font(.system(size: 12))
                        note("Skipped: " + ShelfFiles.regenerable.sorted().joined(separator: ", ") + ". Moving a folder or transferring to a drive always keeps everything.")
                    }
                    section("TEMPLATES") {
                        Text("Built in: " + ProjectTemplate.builtIn.map(\.name).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        ForEach(state.templates) { template in
                            HStack {
                                Label(template.name, systemImage: template.icon).font(.system(size: 12))
                                Text("\(template.folders.count) folders").font(.system(size: 10)).foregroundStyle(muted)
                                Spacer()
                                Button { state.deleteTemplate(template) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete template")
                            }
                        }
                        note("Templates are folder layouts. Make your own from a project’s ⋯ menu → Save as template, then pick it in the New project sheet.")
                    }
                    section("CODE EDITOR") {
                        Picker("Open projects in", selection: state.pref(\.editor)) {
                            Text("Automatic (first one installed)").tag("auto")
                            ForEach(AppState.editors.filter { editor in installed.contains { $0.id == editor.id } || state.prefs.editor == editor.id }, id: \.id) { editor in
                                Text(editor.name + (installed.contains { $0.id == editor.id } ? "" : " (not installed)")).tag(editor.id)
                            }
                        }.font(.system(size: 12)).frame(maxWidth: 380)
                        note(installed.isEmpty ? "No supported editor found. Install Visual Studio Code, Cursor, Zed or another editor." : "Installed: " + installed.map(\.name).joined(separator: ", "))
                    }
                    section("LIBRARY & AI") {
                        HStack {
                            Button { then { state.showAssistants = true } } label: { Label("Connect AI assistants…", systemImage: "point.3.connected.trianglepath.dotted") }
                            Button { then { state.showFolders = true } } label: { Label("Scan folders…", systemImage: "slider.horizontal.3") }
                            Button { then { state.showOrganizer = true } } label: { Label("AI Settings…", systemImage: "sparkles") }
                            Spacer()
                        }.font(.system(size: 11))
                    }
                    AboutCard()
                }.padding(.trailing, 8)
            }.frame(height: 520)
            HStack {
                note("Settings are saved automatically.")
                Spacer()
                Button("Done") { state.showPreferences = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 620).background(canvas).preferredColorScheme(.dark)
    }
}

struct AboutCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("DevShelf").font(.system(size: 17, weight: .bold))
                    Text("Project Organizer").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                    Text("v" + appVersion).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                }
                Text(appTagline).font(.system(size: 12)).foregroundStyle(accent)
                Text("Developed by " + developerName).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.75))
            }
            Spacer()
            Button { NSWorkspace.shared.open(developerGitHub) } label: {
                Label("GitHub · imjhakash", systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.bordered).help(developerGitHub.absoluteString)
        }.padding(16).background(LinearGradient(colors: [accent.opacity(0.10), panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.20)))
    }
}
