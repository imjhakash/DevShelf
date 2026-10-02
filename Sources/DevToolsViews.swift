import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - State

extension AppState {
    // Templates

    var allTemplates: [ProjectTemplate] { ProjectTemplate.builtIn + templates }
    func saveTemplates() { Persistence.write(templates, to: "templates.json") }

    /// Folders a new project gets for the editor's template choice.
    func templateFolders(_ id: String) -> [String] {
        if id == "starter" { return prefs.starterFolders }
        return allTemplates.first { $0.id == id }?.folders ?? []
    }

    func saveAsTemplate(_ project: ShelfProject) {
        guard let url = browseURL(project),
              let name = ask("Save as template", detail: "New projects can start with this project’s folder layout. Files are not copied.", value: project.name + " folders", button: "Save template") else { return }
        templates.append(ProjectTemplate.capture(project, folder: url, name: name))
        saveTemplates()
        showNotice("Saved template “\(name)”.")
    }

    func deleteTemplate(_ template: ProjectTemplate) {
        templates.removeAll { $0.id == template.id }
        saveTemplates()
    }

    // Git

    func refreshGit(_ project: ShelfProject, force: Bool = false) {
        guard let url = browseURL(project), !gitLoading.contains(project.id) else { return }
        if !force, let last = gitChecked[project.id], Date().timeIntervalSince(last) < 30 { return }
        gitChecked[project.id] = Date()
        gitLoading.insert(project.id)
        let id = project.id
        Task {
            let infos = await Task.detached(priority: .utility) { Git.repositories(in: url).map(Git.status) }.value
            gitInfo[id] = infos
            gitLoading.remove(id)
        }
    }

    // Logins

    func newLogin(_ project: ShelfProject) {
        loginProjectID = project.id; loginDraft = LoginItem(label: ""); loginPassword = ""; loginIsNew = true; showLoginEditor = true
    }

    func editLogin(_ project: ShelfProject, _ login: LoginItem) {
        loginProjectID = project.id; loginDraft = login; loginPassword = ""; loginIsNew = false; showLoginEditor = true
    }

    func saveLogin() {
        var login = loginDraft
        login.label = login.label.trimmingCharacters(in: .whitespacesAndNewlines)
        login.username = login.username.trimmingCharacters(in: .whitespacesAndNewlines)
        login.url = login.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if login.label.isEmpty { login.label = login.url.isEmpty ? "Login" : login.url }
        do {
            if !loginPassword.isEmpty { try CredentialVault.save(loginPassword, for: login.id, label: login.label) }
            updateProject(loginProjectID) { item in
                if let index = item.logins.firstIndex(where: { $0.id == login.id }) { item.logins[index] = login } else { item.logins.append(login) }
            }
            loginPassword = ""; revealed[login.id] = nil; showLoginEditor = false
        } catch { message = error.localizedDescription }
    }

    func deleteLogin(_ project: ShelfProject, _ login: LoginItem) {
        let alert = NSAlert()
        alert.messageText = "Delete the login “\(login.label)”?"
        alert.informativeText = "Its password is removed from the macOS Keychain on this Mac. This can’t be undone."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CredentialVault.remove(login.id)
        revealed[login.id] = nil
        updateProject(project.id) { $0.logins.removeAll { $0.id == login.id } }
    }

    /// Copies text; secrets are marked concealed and cleared from the clipboard after a minute.
    func copy(_ text: String, secret: Bool = false) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        guard secret else { return }
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if board.changeCount == change { board.clearContents() } }
    }

    func copyPassword(_ login: LoginItem) {
        guard let password = CredentialVault.load(login.id) else { message = "No password is saved for “\(login.label)” on this Mac. Edit the login to add one."; return }
        copy(password, secret: true)
        showNotice("Password for “\(login.label)” copied. The clipboard clears in 60 seconds.")
    }

    func toggleReveal(_ login: LoginItem) {
        if revealed[login.id] != nil { revealed[login.id] = nil; return }
        guard let password = CredentialVault.load(login.id) else { message = "No password is saved for “\(login.label)” on this Mac."; return }
        revealed[login.id] = password
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.revealed[login.id] = nil }
    }

    // Activity

    func loadActivity() {
        guard !activityLoading else { return }
        activityLoading = true
        let roots = shelf.projects.compactMap { project in browseURL(project).map { (project.id, $0) } }
        let since = Calendar.current.date(byAdding: .day, value: -activityDays, to: Date()) ?? Date()
        Task {
            let items = await Task.detached(priority: .utility) {
                roots.flatMap { Activity.recentFiles(in: $0.1, projectID: $0.0, since: since) }.sorted { $0.modified > $1.modified }.prefix(400).map { $0 }
            }.value
            activity = items
            activityLoading = false
        }
    }

    // Zip & share

    func beginZip(_ url: URL) {
        zipSource = url; zipResult = nil; zipStatus = ""; zipOptions = ZipOptions()
    }

    func runZip() {
        guard let source = zipSource, !zipRunning else { return }
        let root = shelf.projects.compactMap { browseURL($0) }.first { ShelfFiles.contains(source.path, in: $0.path) && $0.path != source.path }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (root.map { $0.lastPathComponent + " - " } ?? "") + source.lastPathComponent + ".zip"
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        let arguments = zipOptions.arguments(item: source.lastPathComponent, archive: archive)
        zipRunning = true; zipResult = nil; zipStatus = "Creating “\(archive.lastPathComponent)”…"
        Task {
            let result: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    // The save panel already confirmed replacing; zip would otherwise add to the old archive.
                    if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    process.currentDirectoryURL = source.deletingLastPathComponent()
                    process.arguments = arguments
                    let errors = Pipe(); process.standardError = errors; process.standardOutput = Pipe()
                    try process.run()
                    let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    process.waitUntilExit()
                    guard ZipOptions.succeeded(process.terminationStatus) else { throw OrganizerError.message("zip failed: " + errorText.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    return .success((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
                } catch { return .failure(error) }
            }.value
            zipRunning = false
            switch result {
            case .success(let size):
                zipResult = archive
                zipStatus = "Created “\(archive.lastPathComponent)” (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))."
            case .failure(let error): zipStatus = error.localizedDescription
            }
        }
    }

    func shareZip() {
        guard let archive = zipResult, let view = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [archive]).show(relativeTo: NSRect(x: view.bounds.maxX - 150, y: 30, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }
}

// MARK: - Project page sections

struct SectionHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack { Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(muted); Spacer(); trailing() }
    }
}

struct LoginsSection: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "LOGINS") {
                Label("Passwords stay in this Mac’s Keychain", systemImage: "lock.fill").font(.system(size: 10)).foregroundStyle(muted)
                Button("Add login…") { state.newLogin(project) }.buttonStyle(.borderless).font(.system(size: 10))
            }
            VStack(spacing: 0) {
                if project.logins.isEmpty {
                    Button { state.newLogin(project) } label: {
                        Label("Save hosting, WordPress, FTP or admin logins here. Passwords never go into the project folder.", systemImage: "key.fill").font(.system(size: 11)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading).padding(14).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                ForEach(project.logins) { login in
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").foregroundStyle(color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(login.label).font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 8) {
                                if !login.username.isEmpty { Text(login.username).textSelection(.enabled) }
                                if let link = detailLink(login.url) { Button(login.url) { NSWorkspace.shared.open(link) }.buttonStyle(.plain).foregroundStyle(color).lineLimit(1) }
                                else if !login.url.isEmpty { Text(login.url).lineLimit(1) }
                            }.font(.system(size: 10)).foregroundStyle(muted)
                            if let password = state.revealed[login.id] { Text(password).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        }
                        Spacer()
                        if !login.username.isEmpty { Button("Copy user") { state.copy(login.username) }.font(.system(size: 10)) }
                        Button("Copy password") { state.copyPassword(login) }.font(.system(size: 10))
                        Button { state.toggleReveal(login) } label: { Image(systemName: state.revealed[login.id] == nil ? "eye" : "eye.slash") }.buttonStyle(.borderless).help(state.revealed[login.id] == nil ? "Show password for 20 seconds" : "Hide password")
                        Menu {
                            Button("Edit…") { state.editLogin(project, login) }
                            Button("Delete…") { state.deleteLogin(project, login) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                    Divider().opacity(0.12)
                }
            }.background(panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct GitSection: View {
    @ObservedObject var state: AppState
    let project: ShelfProject
    let root: URL
    var body: some View {
        let infos = state.gitInfo[project.id] ?? []
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "GIT") {
                if state.gitLoading.contains(project.id) { ProgressView().controlSize(.mini) }
                Button("Refresh") { state.refreshGit(project, force: true) }.buttonStyle(.borderless).font(.system(size: 10))
            }
            VStack(spacing: 0) {
                if infos.isEmpty {
                    Text(state.gitLoading.contains(project.id) ? "Looking for repositories…" : "No Git repositories in this project yet. Put your code in it (for example in Code) and it shows up here.")
                        .font(.system(size: 11)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(infos) { info in
                    let name = info.path == root.path ? root.lastPathComponent : String(info.path.dropFirst(root.path.count + 1))
                    HStack(spacing: 12) {
                        Image(systemName: info.error != nil ? "exclamationmark.triangle.fill" : info.needsAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(info.error != nil ? Color.red : info.needsAttention ? Color.orange : accent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(name).font(.system(size: 12, weight: .semibold))
                                Label(info.branch.isEmpty ? "unknown" : info.branch, systemImage: "arrow.triangle.branch").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                            }
                            Text(gitSummary(info)).font(.system(size: 10)).foregroundStyle(info.needsAttention || info.error != nil ? .orange : muted)
                        }
                        Spacer()
                        Button { state.terminal(path: info.path) } label: { Image(systemName: "terminal") }.buttonStyle(.borderless).help("Open Terminal here")
                        Button { state.openEditor(path: info.path) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }.buttonStyle(.borderless).help("Open in code editor")
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                    Divider().opacity(0.12)
                }
            }.background(panel, in: RoundedRectangle(cornerRadius: 12))
        }.onAppear { state.refreshGit(project) }
    }

    func gitSummary(_ info: GitInfo) -> String {
        if let error = info.error { return error }
        var parts: [String] = []
        if info.changes > 0 { parts.append("\(info.changes) uncommitted change\(info.changes == 1 ? "" : "s")") }
        if info.ahead > 0 { parts.append("\(info.ahead) commit\(info.ahead == 1 ? "" : "s") not pushed") }
        if info.behind > 0 { parts.append("\(info.behind) behind remote — pull first") }
        if info.noCommits { parts.append("No commits yet") }
        else if !info.upstream && !info.detached { parts.append("Not pushed to any remote — no backup") }
        return parts.isEmpty ? "Clean and pushed" : parts.joined(separator: " · ")
    }
}

/// A compact warning for project rows when a repository needs attention.
struct GitChip: View {
    let infos: [GitInfo]
    var body: some View {
        let changes = infos.reduce(0) { $0 + $1.changes }, ahead = infos.reduce(0) { $0 + $1.ahead }
        let unbacked = infos.contains { !$0.upstream && !$0.noCommits && !$0.detached && $0.error == nil }
        if changes > 0 || ahead > 0 || unbacked {
            Label([changes > 0 ? "\(changes) changed" : nil, ahead > 0 ? "\(ahead) unpushed" : nil, unbacked && changes == 0 && ahead == 0 ? "no remote" : nil].compactMap { $0 }.joined(separator: " · "), systemImage: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Color.orange.opacity(0.12), in: Capsule())
                .help("Git: uncommitted or unpushed work")
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @ObservedObject var state: AppState
    var body: some View {
        let projects = Dictionary(uniqueKeysWithValues: state.shelf.projects.map { ($0.id, $0) })
        let query = state.search.trimmingCharacters(in: .whitespaces)
        let items = state.activity.filter { query.isEmpty || $0.url.path.localizedCaseInsensitiveContains(query) || (projects[$0.projectID]?.title.localizedCaseInsensitiveContains(query) ?? false) }
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.modified) }
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("", selection: Binding(get: { state.activityDays }, set: { state.activityDays = $0; state.loadActivity() })) {
                    Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                if state.activityLoading { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(items.count) files").font(.system(size: 11)).foregroundStyle(muted)
                Button { state.loadActivity() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.font(.system(size: 11)).buttonStyle(.bordered)
            }
            if items.isEmpty && !state.activityLoading {
                Text(state.shelf.projects.isEmpty ? "Create a project to see its activity here." : "No files changed in this period.").font(.system(size: 12)).foregroundStyle(muted).padding(20)
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                VStack(alignment: .leading, spacing: 6) {
                    Text(Calendar.current.isDateInToday(day) ? "TODAY" : Calendar.current.isDateInYesterday(day) ? "YESTERDAY" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(muted)
                    VStack(spacing: 0) {
                        ForEach(days[day] ?? []) { item in
                            let project = projects[item.projectID]
                            let root = project.flatMap { state.browseURL($0) }
                            HStack(spacing: 10) {
                                Image(nsImage: FileIcons.icon(item.url)).resizable().frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.url.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                                    Text(root.map { String(item.url.deletingLastPathComponent().path.dropFirst($0.path.count)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if let project {
                                    Button { state.navigate("shelf:" + project.id) } label: {
                                        HStack(spacing: 5) { Circle().fill(shelfColor(project.color)).frame(width: 6, height: 6); Text(project.name).lineLimit(1) }
                                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.white.opacity(0.75)).padding(.horizontal, 8).padding(.vertical, 3).background(Color.white.opacity(0.05), in: Capsule())
                                    }.buttonStyle(.plain).help("Open project")
                                }
                                Text(item.modified.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).frame(width: 64, alignment: .trailing)
                            }.padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
                                .onTapGesture(count: 2) { state.openFile(item.url) }
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                .contextMenu {
                                    Button("Open") { state.openFile(item.url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    Button("Copy path") { state.copyPath(item.url) }
                                    if let project { Button("Open project") { state.navigate("shelf:" + project.id) } }
                                }
                            Divider().opacity(0.1)
                        }
                    }.background(panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.onAppear { state.loadActivity() }
    }
}

// MARK: - Sheets

struct LoginEditor: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(state.loginIsNew ? "Add login" : "Edit login", systemImage: "key.fill").font(.system(size: 21, weight: .semibold))
            TextField("Label, e.g. WordPress admin, cPanel, FTP, database", text: $state.loginDraft.label).textFieldStyle(.roundedBorder)
            TextField("Address, e.g. example.com/wp-admin", text: $state.loginDraft.url).textFieldStyle(.roundedBorder)
            TextField("Username or email", text: $state.loginDraft.username).textFieldStyle(.roundedBorder)
            SecureField(state.loginIsNew ? "Password" : "New password (leave empty to keep the saved one)", text: $state.loginPassword).textFieldStyle(.roundedBorder)
            Text("The password is stored only in the macOS Keychain on this Mac. It is never written to the project folder, copied to drives, or included in zips. Labels, usernames and addresses are saved with the project.")
                .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { state.loginPassword = ""; state.showLoginEditor = false }.keyboardShortcut(.cancelAction)
                Button("Save login") { state.saveLogin() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 480).background(canvas).preferredColorScheme(.dark)
    }
}

struct ZipSheet: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Zip & share", systemImage: "doc.zipper").font(.system(size: 23, weight: .semibold))
            if let source = state.zipSource {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text(shortPath(source.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Leave out node_modules, .next, .venv and other rebuildable folders", isOn: $state.zipOptions.skipDependencies)
                Toggle("Leave out .git history", isOn: $state.zipOptions.skipGit)
                Toggle("Leave out .env files (secrets and API keys)", isOn: $state.zipOptions.skipSecrets)
                Toggle("Leave out DevShelf details (notes, to-dos, login names)", isOn: $state.zipOptions.skipDevShelfDetails)
            }.font(.system(size: 12)).disabled(state.zipRunning)
            Text("Saved logins’ passwords are never included — they live only in this Mac’s Keychain.").font(.system(size: 10)).foregroundStyle(muted)
            if state.zipRunning { ProgressView().controlSize(.small) }
            if !state.zipStatus.isEmpty { Text(state.zipStatus).font(.system(size: 11)).foregroundStyle(state.zipResult == nil && !state.zipRunning ? .orange : .white) }
            HStack {
                if let result = state.zipResult {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([result]) } label: { Label("Show in Finder", systemImage: "folder") }
                    Button { state.shareZip() } label: { Label("Share…", systemImage: "square.and.arrow.up") }.help("AirDrop, Mail, Messages and more")
                }
                Spacer()
                Button("Close") { state.zipSource = nil }.keyboardShortcut(.cancelAction).disabled(state.zipRunning)
                Button(state.zipResult == nil ? "Create zip…" : "Create another…") { state.runZip() }.keyboardShortcut(.defaultAction).disabled(state.zipRunning)
            }
        }.padding(28).frame(width: 560).background(canvas).preferredColorScheme(.dark)
    }
}
