import Foundation

@main struct OrganizationChecks {
    static func project(_ name: String, path: String = "/Users/example/Projects/example", kind: String = "Node project", summary: String = "") -> Project {
        Project(name: name, packageName: name, path: path, kind: kind, framework: "Node.js", summary: summary, modified: Date(), git: true, dependenciesInstalled: false, dependencies: [Dependency(name: "react", requested: "^19", development: false)], scripts: ["dev": "SECRET_SCRIPT_SHOULD_STAY_LOCAL"])
    }
    static func main() throws {
        let seo = project("Rank tracker", summary: "SEO audit dashboard")
        let marketing = project("Lead-Manager", path: "/different/lead-manager")
        let automation = project("Apify System")
        let customPlugin = project("My custom forms", path: "/Users/example/Sites/wp-content/plugins/custom-forms", kind: "WordPress plugin")
        let vendorPlugin = project("Elementor", path: "/Users/example/Sites/wp-content/plugins/elementor", kind: "WordPress plugin")
        precondition(Categorizer.inferred(seo).purpose == .seo)
        precondition(Categorizer.inferred(marketing).purpose == .marketing)
        precondition(Categorizer.inferred(automation).purpose == .automation)
        precondition(Categorizer.inferred(customPlugin).purpose == .wordpress)
        precondition(Categorizer.inferred(vendorPlugin).purpose == .libraries)
        let copies = [project("Lexclaro"), project("Lexclaro 2", path: "/different/copy"), project("Lexclaro DEV", path: "/different/dev")]
        precondition(Categorizer.families(copies).count == 1)
        precondition(Categorizer.families(copies)[0].projects.count == 3)
        let request = JevClient.payload([seo, marketing], model: "typesafe/jev-1.13")
        let wire = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        precondition(!wire.contains("/Users/") && !wire.contains("SECRET_SCRIPT"))
        precondition((request["questions"] as! [String: Any]).count == 2)
        let response = Data(#"{"answers":{"project_0":{"type":"choice","choice":"seo","confidence":0.92},"project_1":{"type":"choice","choice":"marketing","confidence":0.54}},"usage":{"cost":0.001}}"#.utf8)
        let labels = try JevClient.parse(response, projects: [seo, marketing])
        precondition(labels.assignments[seo.path]!.purpose == .seo)
        precondition(labels.assignments[marketing.path]!.purpose == .review)
        precondition(labels.assignments[marketing.path]!.suggestedPurpose == .marketing)
        precondition(labels.cost == 0.001)
        for invalid in [#"{"answers":{}}"#, #"{"answers":{"project_0":{"type":"choice","choice":"made_up","confidence":1}}}"#, #"{"answers":{"project_0":{"type":"choice","choice":"seo","confidence":true}}}"#] {
            do { _ = try JevClient.parse(Data(invalid.utf8), projects: [seo]); fatalError("Invalid result accepted") }
            catch { }
        }
        var organization = Organization()
        organization.assignments[seo.path] = Assignment(purpose: .design, source: "Manual", confidence: nil, suggestedPurpose: nil, fingerprint: "older-metadata")
        precondition(Categorizer.assignment(seo, organization: organization).purpose == .design)
        organization.assignments[seo.path] = Assignment(purpose: .design, source: "Jev", confidence: 0.9, suggestedPurpose: nil, fingerprint: "older-metadata")
        precondition(Categorizer.assignment(seo, organization: organization).purpose == .seo)
        let roundTrip = try JSONDecoder().decode(Organization.self, from: JSONEncoder().encode(organization))
        precondition(roundTrip.assignments.count == 1)
        try checkShelf()
        checkFolderTree()
        try checkMCP()
        try checkFolderWatch()
        try checkDuplicatesAndMoves()
        try checkLinks()
        print("Organization checks passed: classification, grouping, payload privacy, response validation, low-confidence review, manual overrides, and stale-label handling.")
    }

    static func checkShelf() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devshelf-shelf-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Folder names are safe on disk and readable.
        precondition(ShelfFiles.folderName(" Law/claro Site: v2 ") == "Law-claro Site- v2")
        precondition(ShelfFiles.folderName("Portal") == "Portal")
        precondition(ShelfFiles.folderName("  ") == "Untitled project")
        precondition(ShelfFiles.folderName(".hidden") == "hidden")
        precondition(ShelfFiles.symbol(forFolder: "images") == "photo.fill" && ShelfFiles.symbol(forFolder: "Random") == nil)

        // Creating a project makes a real folder with starter folders and portable metadata.
        var project = ShelfProject(name: "Website", color: "purple", icon: "globe", notes: "Brief arrives Monday", location: FolderLocation(path: ""))
        let shelfRoot = root.appendingPathComponent("DevShelf Projects")
        let folder = try ShelfFiles.create(project, in: shelfRoot, starterFolders: ShelfFiles.starterFolders + ["  ", ".secret"])
        precondition(folder.lastPathComponent == "Website")
        precondition(ShelfFiles.starterFolders.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) } && !fm.fileExists(atPath: folder.appendingPathComponent(".secret").path))
        let metadata = ShelfFiles.readMetadata(in: folder)!
        precondition(metadata.id == project.id && metadata.name == "Website" && metadata.notes == "Brief arrives Monday" && metadata.color == "purple")
        let second = try ShelfFiles.create(project, in: shelfRoot, starterFolders: [])
        precondition(second.lastPathComponent == "Website 2")
        project.location = FolderLocation(path: folder.path)
        precondition(project.matches("website") && project.matches("monday") && !project.matches("unrelated"))

        // The tree lists folders first, in natural order, without DevShelf's own files.
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try Data("logo".utf8).write(to: folder.appendingPathComponent("logo 10.png"))
        try Data("logo".utf8).write(to: folder.appendingPathComponent("logo 9.png"))
        let listed = ShelfFiles.children(of: folder)
        precondition(listed.prefix(5).allSatisfy(\.isFolder) && listed.map(\.name).suffix(2) == ["logo 9.png", "logo 10.png"])
        precondition(!listed.contains { $0.name.hasPrefix(".") })

        // Outside items are copied in; items already in the project are moved; names never collide.
        let downloads = root.appendingPathComponent("Downloads")
        try fm.createDirectory(at: downloads.appendingPathComponent("Brand kit"), withIntermediateDirectories: true)
        try Data("brief".utf8).write(to: downloads.appendingPathComponent("brief.pdf"))
        try Data("svg".utf8).write(to: downloads.appendingPathComponent("Brand kit/logo.svg"))
        let clientFiles = folder.appendingPathComponent("Documents")
        try ShelfFiles.add([downloads.appendingPathComponent("brief.pdf"), downloads.appendingPathComponent("Brand kit")], into: clientFiles, projectRoot: folder)
        try ShelfFiles.add([downloads.appendingPathComponent("brief.pdf")], into: clientFiles, projectRoot: folder)
        precondition(fm.fileExists(atPath: downloads.appendingPathComponent("brief.pdf").path))
        precondition(fm.fileExists(atPath: clientFiles.appendingPathComponent("brief.pdf").path) && fm.fileExists(atPath: clientFiles.appendingPathComponent("brief 2.pdf").path))
        precondition(fm.fileExists(atPath: clientFiles.appendingPathComponent("Brand kit/logo.svg").path))
        try ShelfFiles.add([clientFiles.appendingPathComponent("Brand kit")], into: folder.appendingPathComponent("Design"), projectRoot: folder)
        precondition(fm.fileExists(atPath: folder.appendingPathComponent("Design/Brand kit/logo.svg").path) && !fm.fileExists(atPath: clientFiles.appendingPathComponent("Brand kit").path))
        do { try ShelfFiles.add([folder.appendingPathComponent("Design")], into: folder.appendingPathComponent("Design/Brand kit"), projectRoot: folder); fatalError("Folder moved into itself") } catch { }

        // Scanned code folders are copied without rebuildable dependencies, or moved on request.
        let scanned = root.appendingPathComponent("Sites/client-portal")
        try fm.createDirectory(at: scanned.appendingPathComponent("node_modules/react"), withIntermediateDirectories: true)
        try fm.createDirectory(at: scanned.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: scanned.appendingPathComponent("package.json"))
        try Data("x".utf8).write(to: scanned.appendingPathComponent("src/app.js"))
        try Data("x".utf8).write(to: scanned.appendingPathComponent("node_modules/react/index.js"))
        try Data("KEY=1".utf8).write(to: scanned.appendingPathComponent(".env"))
        let code = folder.appendingPathComponent("Code")
        try ShelfFiles.add([scanned], into: code, projectRoot: folder)
        precondition(fm.fileExists(atPath: code.appendingPathComponent("client-portal/src/app.js").path) && fm.fileExists(atPath: code.appendingPathComponent("client-portal/.env").path))
        precondition(!fm.fileExists(atPath: code.appendingPathComponent("client-portal/node_modules").path) && fm.fileExists(atPath: scanned.appendingPathComponent("node_modules/react/index.js").path))
        try ShelfFiles.add([scanned], into: code, projectRoot: folder, move: true)
        precondition(!fm.fileExists(atPath: scanned.path) && fm.fileExists(atPath: code.appendingPathComponent("client-portal 2/node_modules/react/index.js").path))
        try fm.removeItem(at: code.appendingPathComponent("client-portal 2"))

        // Syncing to a drive copies everything, then only changes, and never deletes drive files.
        try Data("SECRET=1".utf8).write(to: folder.appendingPathComponent("Code/.env"))
        let drive = root.appendingPathComponent("Drive")
        let copy = drive.appendingPathComponent("DevShelf Projects/Website")
        var reported: (Int, Int) = (0, 0)
        let first = try ShelfFiles.sync(from: folder, to: copy, progress: { reported = ($0, $1) })
        precondition(first.copied >= 6 && first.unchanged == 0 && reported.0 == reported.1)
        precondition(fm.fileExists(atPath: copy.appendingPathComponent("Code/.env").path) && fm.fileExists(atPath: copy.appendingPathComponent(ShelfFiles.metadataName).path))
        precondition(!fm.fileExists(atPath: copy.appendingPathComponent(".DS_Store").path))
        precondition(fm.fileExists(atPath: copy.appendingPathComponent("Deliverables").path))
        let unchanged = try ShelfFiles.sync(from: folder, to: copy)
        precondition(unchanged.copied == 0 && unchanged.unchanged == first.copied)
        try Data("brief v2 is longer".utf8).write(to: clientFiles.appendingPathComponent("brief.pdf"))
        try Data("only on drive".utf8).write(to: copy.appendingPathComponent("drive-notes.txt"))
        let changed = try ShelfFiles.sync(from: folder, to: copy)
        let updatedBrief = try Data(contentsOf: copy.appendingPathComponent("Documents/brief.pdf"))
        precondition(changed.copied == 1 && String(data: updatedBrief, encoding: .utf8) == "brief v2 is longer")
        precondition(fm.fileExists(atPath: copy.appendingPathComponent("drive-notes.txt").path))
        do { _ = try ShelfFiles.sync(from: folder, to: drive.appendingPathComponent("other"), cancelled: { true }); fatalError("Cancelled sync finished") } catch is CancellationError { }

        // Drive copies are found by volume ID, wherever the drive mounts, and show as unplugged otherwise.
        let volume = Volume(url: drive, uuid: "TEST-UUID", name: "Extend XX", external: true)
        let location = Volumes.location(for: copy, on: volume)
        precondition(location.relativePath == "DevShelf Projects/Website" && location.onDrive)
        precondition(Volumes.resolve(location, mounted: [volume]).url?.path == copy.path)
        let remounted = Volume(url: root, uuid: "TEST-UUID", name: "Extend XX 1", external: true)
        try fm.createDirectory(at: root.appendingPathComponent("DevShelf Projects/Website"), withIntermediateDirectories: true)
        precondition(Volumes.resolve(location, mounted: [remounted]).url?.path == root.appendingPathComponent("DevShelf Projects/Website").path)
        precondition(Volumes.resolve(location, mounted: []) == .offline("Extend XX"))
        precondition(Volumes.resolve(FolderLocation(path: folder.path), mounted: []) == .active(URL(fileURLWithPath: folder.path)))
        precondition(Volumes.resolve(FolderLocation(path: root.appendingPathComponent("gone").path), mounted: []) == .missing)
        precondition(Volumes.location(for: folder).volumeUUID == nil)

        project.copies = [location]
        var library = ShelfLibrary(projects: [project])
        library.root = shelfRoot.path
        let decoded = try JSONDecoder().decode(ShelfLibrary.self, from: JSONEncoder().encode(library))
        precondition(decoded.projects.first?.copies.first?.volumeUUID == "TEST-UUID" && decoded.rootURL.path == shelfRoot.path)
        precondition(metadata.project(at: location).copies.isEmpty && metadata.project(at: location).location == location)
        // Data saved by version 2.x still loads: the client name joins the project name (matching
        // the folder DevShelf created), and removed fields (deadline, details, time, budget) are ignored.
        let old = #"{"projects":[{"id":"A","client":"Lawclaro","name":"Site","color":"red","icon":"globe","notes":"","fields":[{"id":"f","key":"Deadline","value":"1 Nov"}],"due":0,"timeEntries":[],"hourlyRate":40,"created":0,"location":{"path":"/tmp/x"},"copies":[]}]}"#
        let upgraded = try JSONDecoder().decode(ShelfLibrary.self, from: Data(old.utf8)).projects[0]
        precondition(upgraded.name == "Lawclaro - Site" && upgraded.status == .active && upgraded.tasks.isEmpty && upgraded.color == "red")
        let noClient = try JSONDecoder().decode(ShelfProject.self, from: Data(#"{"id":"B","client":"","name":"Portal","location":{"path":"/p"}}"#.utf8))
        precondition(noClient.name == "Portal" && noClient.color == "blue")
        let oldFolderFile = try JSONDecoder().decode(PortableMetadata.self, from: Data(#"{"id":"C","client":"Quasara","name":"Shop","color":"teal","icon":"cart.fill","notes":"","fields":[],"created":0}"#.utf8))
        precondition(oldFolderFile.name == "Quasara - Shop" && oldFolderFile.status == .active)
        var tracked = upgraded
        tracked.status = .waiting; tracked.tasks = [ProjectTask(title: "Get hosting login"), ProjectTask(title: "Send invoice", done: true)]
        let reread = try JSONDecoder().decode(ShelfProject.self, from: JSONEncoder().encode(tracked))
        precondition(reread.status == .waiting && reread.openTasks == 1 && reread.matches("hosting") && reread.matches("waiting") && reread.name == "Lawclaro - Site")
        try ShelfFiles.writeMetadata(tracked, to: second)
        let carried = ShelfFiles.readMetadata(in: second)!.project(at: FolderLocation(path: second.path))
        precondition(carried.status == .waiting && carried.tasks.count == 2 && carried.name == "Lawclaro - Site")
        let oldPrefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"starterFolders":["Brief & notes","Client files","Design","Code","Deliverables"],"sortProjects":"deadline"}"#.utf8))
        precondition(oldPrefs.starterFolders == ShelfFiles.starterFolders && oldPrefs.sortProjects == "name" && oldPrefs.fileView == "grid")
        let customPrefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"starterFolders":["Assets"]}"#.utf8))
        precondition(customPrefs.starterFolders == ["Assets"])
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"editor":"zed"}"#.utf8))
        precondition(preferences.editor == "zed" && preferences.skipDependencies && preferences.starterFolders == ShelfFiles.starterFolders && preferences.peekDelay != nil)
        precondition(Preferences(hoverPeek: "off").peekDelay == nil)

        // Details become links only when they really are addresses.
        precondition(detailLink("https://lawclaro.com/admin")?.absoluteString == "https://lawclaro.com/admin")
        precondition(detailLink("staging.lawclaro.com")?.absoluteString == "https://staging.lawclaro.com")
        precondition(detailLink("github.com/imjhakash/devshelf")?.absoluteString == "https://github.com/imjhakash/devshelf")
        precondition(detailLink("client@lawclaro.com")?.absoluteString == "mailto:client@lawclaro.com")
        precondition(detailLink("1 Nov") == nil && detailLink("$2,500") == nil && detailLink("v2.0") == nil && detailLink("Call Rahim at 5pm") == nil)

        try checkDevTools(root: root)
        print("Shelf checks passed: folder names, starter folders, portable metadata, tree order, copy/move/no-overwrite adds, scanned folders without node_modules, safe drive sync, cancellation, status/checklist, upgrades from 2.x, preferences, detail links, and drive detection by volume ID.")
    }

    static func checkDevTools(root: URL) throws {
        let fm = FileManager.default
        // Git status lines.
        var info = Git.parse("## main...origin/main [ahead 2, behind 1]\n M src/app.js\n?? notes.md\n", path: "/r")
        precondition(info.branch == "main" && info.upstream && info.ahead == 2 && info.behind == 1 && info.changes == 2 && info.needsAttention)
        info = Git.parse("## main...origin/main\n", path: "/r")
        precondition(info.upstream && info.changes == 0 && !info.needsAttention)
        info = Git.parse("## feature/login\n", path: "/r")
        precondition(info.branch == "feature/login" && !info.upstream && info.needsAttention)
        info = Git.parse("## No commits yet on main\n?? index.html\n", path: "/r")
        precondition(info.noCommits && info.branch == "main" && info.changes == 1)
        info = Git.parse("## main...origin/main [gone]\n", path: "/r")
        precondition(!info.upstream)
        info = Git.parse("## HEAD (no branch)\n", path: "/r")
        precondition(info.detached && !info.needsAttention)

        // Real repository inside a project's Code folder.
        let project = root.appendingPathComponent("GitProject")
        let repo = project.appendingPathComponent("Code/site")
        try fm.createDirectory(at: repo.appendingPathComponent("node_modules/pkg/.git"), withIntermediateDirectories: true)
        let git = Process(); git.executableURL = URL(fileURLWithPath: ProjectScanner.executable("git")!); git.arguments = ["-C", repo.path, "init", "-q", "-b", "main"]
        try git.run(); git.waitUntilExit()
        try Data("hello".utf8).write(to: repo.appendingPathComponent("index.html"))
        let repos = Git.repositories(in: project)
        precondition(repos.map(\.lastPathComponent) == ["site"])
        let live = Git.status(repos[0])
        precondition(live.error == nil && live.noCommits && live.changes >= 1 && live.branch == "main")

        // Logins are saved with the project; passwords never are.
        var tracked = ShelfProject(name: "B", location: FolderLocation(path: "/x"))
        tracked.logins = [LoginItem(label: "WP admin", username: "akash", url: "example.com/wp-admin")]
        let back = try JSONDecoder().decode(ShelfProject.self, from: JSONEncoder().encode(tracked))
        precondition(back.logins.first?.username == "akash" && back.matches("wp admin"))
        let portable = PortableMetadata(tracked).project(at: FolderLocation(path: "/y"))
        precondition(portable.logins.count == 1)
        let wire = String(data: try JSONEncoder().encode(PortableMetadata(tracked)), encoding: .utf8)!
        precondition(!wire.lowercased().contains("password"))

        // Templates are folder layouts: nested folders are created, and a project's layout can be captured.
        let wordpress = ProjectTemplate.builtIn.first { $0.id == "wordpress" }!
        let templated = ShelfProject(name: "Shop", location: FolderLocation(path: ""))
        let made = try ShelfFiles.create(templated, in: root.appendingPathComponent("Templated"), starterFolders: wordpress.folders + ["Code/../x", " /Bad"])
        precondition(fm.fileExists(atPath: made.appendingPathComponent("Code/theme").path) && fm.fileExists(atPath: made.appendingPathComponent("Code/plugins").path) && fm.fileExists(atPath: made.appendingPathComponent("Images").path))
        precondition(!fm.fileExists(atPath: made.appendingPathComponent("x").path) && !fm.fileExists(atPath: made.appendingPathComponent("Bad").path))
        try fm.createDirectory(at: made.appendingPathComponent("Code/theme/node_modules"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: made.appendingPathComponent("Code/theme/package.json"))
        let captured = ProjectTemplate.capture(templated, folder: made, name: "Mine")
        precondition(captured.folders.contains("Code/plugins") && captured.folders.contains("Images") && !captured.folders.contains("Code/theme"))
        precondition(ProjectTemplate.builtIn.allSatisfy { !$0.folders.isEmpty } && Set(ProjectTemplate.builtIn.map(\.id)).count == ProjectTemplate.builtIn.count)
        let savedTemplate = try JSONDecoder().decode(ProjectTemplate.self, from: Data(#"{"id":"t","name":"Old","icon":"globe","folders":["Code"],"tasks":["x"],"fields":["y"]}"#.utf8))
        precondition(savedTemplate.folders == ["Code"])

        // Activity finds recent files and skips dependencies and old files.
        let recent = made.appendingPathComponent("Deliverables/handover.pdf")
        try Data("pdf".utf8).write(to: recent)
        try Data("dep".utf8).write(to: made.appendingPathComponent("Code/theme/node_modules/x.js"))
        let old = made.appendingPathComponent("Backups/old.sql")
        try Data("sql".utf8).write(to: old)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 86400)], ofItemAtPath: old.path)
        let activity = Activity.recentFiles(in: made, projectID: "p", since: Date(timeIntervalSinceNow: -7 * 86400))
        precondition(activity.contains { $0.url.lastPathComponent == "handover.pdf" } && !activity.contains { $0.url.lastPathComponent == "x.js" || $0.url.lastPathComponent == "old.sql" })
        precondition(!activity.contains { $0.url.lastPathComponent == ShelfFiles.metadataName })

        // Files are grouped by type, without dependencies or DevShelf's own files.
        try Data("png".utf8).write(to: made.appendingPathComponent("Images/logo.PNG"))
        try Data("fig".utf8).write(to: made.appendingPathComponent("Design/home.fig"))
        try Data("??".utf8).write(to: made.appendingPathComponent("Design/readme.unknownext"))
        let groups = FileKinds.scan(made)
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        precondition(byID["images"]?.files.map(\.name) == ["logo.PNG"] && byID["design"]?.files.count == 1 && byID["documents"]?.files.map(\.name) == ["handover.pdf"])
        precondition(byID["other"]?.files.contains { $0.name == "readme.unknownext" } == true && byID["code"]?.files.contains { $0.name == "package.json" } == true)
        precondition(!groups.flatMap(\.files).contains { $0.name == "x.js" || $0.name == ShelfFiles.metadataName })
        precondition(groups.map(\.id).last == "other" && byID["images"]!.bytes == 3)

        // Zip leaves out dependencies, git, secrets and DevShelf details by default.
        try Data("SECRET=1".utf8).write(to: made.appendingPathComponent("Code/theme/.env"))
        try fm.createDirectory(at: made.appendingPathComponent("Code/theme/.git"), withIntermediateDirectories: true)
        try Data("ref".utf8).write(to: made.appendingPathComponent("Code/theme/.git/HEAD"))
        let archive = root.appendingPathComponent("out.zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = made.deletingLastPathComponent()
        zip.arguments = ZipOptions().arguments(item: made.lastPathComponent, archive: archive); zip.standardOutput = Pipe()
        try zip.run(); zip.waitUntilExit()
        precondition(zip.terminationStatus == 0)
        let list = Process(); list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo"); list.arguments = ["-1", archive.path]
        let out = Pipe(); list.standardOutput = out; try list.run()
        let names = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!; list.waitUntilExit()
        precondition(names.contains("Deliverables/handover.pdf") && names.contains("Code/theme/package.json"))
        precondition(!names.contains("node_modules") && !names.contains(".git/") && !names.contains(".env") && !names.contains(ShelfFiles.metadataName))
        var keepAll = ZipOptions(); keepAll.skipGit = false; keepAll.skipSecrets = false; keepAll.skipDevShelfDetails = false; keepAll.skipDependencies = false
        precondition(keepAll.exclusions == ["*.DS_Store", "*/__MACOSX/*"])
        print("Developer tool checks passed: git status parsing and live repos, logins without passwords, folder templates, activity, file types, and zip exclusions.")
    }

    static func checkMCP() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("devshelf-home-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let binary = "/Applications/Dev Shelf.app/Contents/MacOS/DevShelf"
        let apps = Dictionary(uniqueKeysWithValues: MCPConnect.apps.map { ($0.id, $0) })

        // JSON configs keep every other setting and get a one-time backup.
        let claude = apps["claude-desktop"]!
        let claudeConfig = MCPConnect.configURL(claude, home: home)
        try fm.createDirectory(at: claudeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"other":{"command":"/bin/other"}},"theme":"dark"}"#.utf8).write(to: claudeConfig)
        precondition(MCPConnect.state(claude, home: home, binary: binary) == .disconnected)
        try MCPConnect.connect(claude, home: home, binary: binary)
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeConfig)) as! [String: Any]
        var servers = root["mcpServers"] as! [String: Any]
        precondition(root["theme"] as? String == "dark" && servers["other"] != nil)
        precondition((servers["devshelf"] as! [String: Any])["args"] as! [String] == ["--mcp"])
        precondition(MCPConnect.state(claude, home: home, binary: binary) == .connected)
        precondition(MCPConnect.state(claude, home: home, binary: "/elsewhere/DevShelf") == .outdated(binary))
        precondition(fm.fileExists(atPath: claudeConfig.path + ".before-devshelf"))
        try MCPConnect.disconnect(claude, home: home)
        root = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeConfig)) as! [String: Any]
        servers = root["mcpServers"] as! [String: Any]
        precondition(servers["devshelf"] == nil && servers["other"] != nil && root["theme"] as? String == "dark")

        // Missing config folders are created; broken JSON is never overwritten.
        let windsurf = apps["windsurf"]!
        try MCPConnect.connect(windsurf, home: home, binary: binary)
        precondition(MCPConnect.state(windsurf, home: home, binary: binary) == .connected)
        let cursorConfig = MCPConnect.configURL(apps["cursor"]!, home: home)
        try fm.createDirectory(at: cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cursorConfig)
        do { try MCPConnect.connect(apps["cursor"]!, home: home, binary: binary); fatalError("Broken JSON overwritten") } catch { }
        let untouched = try Data(contentsOf: cursorConfig)
        precondition(String(data: untouched, encoding: .utf8) == "{ not json")
        try MCPConnect.connect(apps["claude-code"]!, home: home, binary: binary)
        let code = try JSONSerialization.jsonObject(with: Data(contentsOf: MCPConnect.configURL(apps["claude-code"]!, home: home))) as! [String: Any]
        precondition(((code["mcpServers"] as! [String: Any])["devshelf"] as! [String: Any])["type"] as? String == "stdio")

        // Codex TOML: replaces an older DevShelf block (with sub-tables) and keeps the rest.
        let codex = apps["codex"]!
        let toml = MCPConnect.configURL(codex, home: home)
        try fm.createDirectory(at: toml.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"o4\"\n\n[mcp_servers.devshelf]\ncommand = \"/old/DevShelf\"\nargs = [\"--mcp\"]\n\n[mcp_servers.devshelf.env]\nX = \"1\"\n\n[mcp_servers.other]\ncommand = \"other\"\n".write(to: toml, atomically: true, encoding: .utf8)
        precondition(MCPConnect.state(codex, home: home, binary: binary) == .outdated("/old/DevShelf"))
        try MCPConnect.connect(codex, home: home, binary: binary)
        var text = try String(contentsOf: toml, encoding: .utf8)
        precondition(MCPConnect.state(codex, home: home, binary: binary) == .connected)
        precondition(text.contains("model = \"o4\"") && text.contains("[mcp_servers.other]") && !text.contains("/old/DevShelf") && !text.contains("devshelf.env"))
        precondition(text.components(separatedBy: "[mcp_servers.devshelf]").count == 2)
        try MCPConnect.disconnect(codex, home: home)
        text = try String(contentsOf: toml, encoding: .utf8)
        precondition(!text.contains("devshelf") && text.contains("[mcp_servers.other]") && text.contains("model"))
        precondition(MCPConnect.tomlCommand(MCPConnect.tomlBlock(binary: #"/a "quoted" \ path"#)) == #"/a "quoted" \ path"#)
        precondition(MCPConnect.snippet(binary: binary).contains("\"devshelf\"") && MCPConnect.snippet(binary: binary).contains("--mcp"))

        // Folder marks: saved, carried in the folder's metadata, and moved with renames.
        var marked = ShelfProject(name: "Marks", location: FolderLocation(path: "/m"))
        marked.folderMarks = ["Design": FolderMark(pinned: true), "Design/Logos": FolderMark(favorite: true, color: "pink"), "Designers": FolderMark(color: "red"), "Code": FolderMark(favorite: true)]
        let markedBack = try JSONDecoder().decode(ShelfProject.self, from: JSONEncoder().encode(marked))
        precondition(markedBack.folderMarks == marked.folderMarks && PortableMetadata(marked).project(at: marked.location).folderMarks == marked.folderMarks)
        marked.moveMarks(from: "Design", to: "Art/Design")
        precondition(marked.folderMarks["Art/Design"]?.pinned == true && marked.folderMarks["Art/Design/Logos"]?.color == "pink")
        precondition(marked.folderMarks["Design"] == nil && marked.folderMarks["Designers"]?.color == "red", "a similar name is not affected")
        marked.moveMarks(from: "Code", to: nil)
        precondition(marked.folderMarks["Code"] == nil && marked.folderMarks.count == 3)
        let partialMark = try JSONDecoder().decode(FolderMark.self, from: Data(#"{"pinned":true}"#.utf8))
        precondition(partialMark == FolderMark(pinned: true))
        precondition(FolderMark().isEmpty && !FolderMark(color: "red").isEmpty)
        let unmarked = try JSONDecoder().decode(PortableMetadata.self, from: Data(#"{"id":"u","name":"Old","color":"blue","icon":"globe","notes":"","created":0}"#.utf8))
        precondition(unmarked.folderMarks.isEmpty)
        let moveRoot = home.appendingPathComponent("MoveProject")
        try fm.createDirectory(at: moveRoot.appendingPathComponent("Inbox/Logos"), withIntermediateDirectories: true)
        try fm.createDirectory(at: moveRoot.appendingPathComponent("Design"), withIntermediateDirectories: true)
        let pairs = try ShelfFiles.transfer([moveRoot.appendingPathComponent("Inbox/Logos")], into: moveRoot.appendingPathComponent("Design"), projectRoot: moveRoot)
        precondition(pairs.count == 1 && pairs[0].source.lastPathComponent == "Logos" && pairs[0].destination.path.hasSuffix("Design/Logos"))

        // Three-way merge between the app and an assistant editing the shelf at the same time.
        let a = ShelfProject(name: "A", location: FolderLocation(path: "/a"))
        let b = ShelfProject(name: "B", location: FolderLocation(path: "/b"))
        let c = ShelfProject(name: "C", location: FolderLocation(path: "/c"))
        let base = ShelfLibrary(projects: [a, b, c])
        var ours = base
        ours.projects[0].status = .done              // the app changed A
        ours.projects.remove(at: 2)                   // and removed C
        let mine = ShelfProject(name: "Mine", location: FolderLocation(path: "/m"))
        ours.projects.append(mine)                    // and added Mine
        var theirs = base
        theirs.projects[1].notes = "from Claude"      // the assistant changed B
        let made = ShelfProject(name: "Made by AI", location: FolderLocation(path: "/n"))
        theirs.projects.append(made)                  // and created a project
        let merged = ShelfLibrary.merge(base: base, ours: ours, theirs: theirs)
        precondition(merged.projects.map(\.name) == ["A", "B", "Made by AI", "Mine"])
        precondition(merged.projects[0].status == .done && merged.projects[1].notes == "from Claude")
        var removedByAI = base; removedByAI.projects.remove(at: 1)
        precondition(ShelfLibrary.merge(base: base, ours: base, theirs: removedByAI).projects.map(\.name) == ["A", "C"])
        precondition(ShelfLibrary.merge(base: base, ours: base, theirs: theirs) == theirs)
        print("MCP checks passed: config connect/disconnect for JSON and TOML apps, backups, broken-config safety, outdated paths, folder marks, and app/assistant merges.")
    }

    static func checkFolderWatch() throws {
        precondition(FolderWatcher.isRelevant("/p/Videos/intro.mp4") && FolderWatcher.isRelevant("/p/Design"))
        precondition(!FolderWatcher.isRelevant("/p/Code/site/node_modules/react/index.js") && !FolderWatcher.isRelevant("/p/Code/site/.git/index"))
        precondition(!FolderWatcher.isRelevant("/p/.DS_Store") && !FolderWatcher.isRelevant("/p/" + ShelfFiles.metadataName))
        precondition(FolderWatcher.isRelevant("/p/Builds/app.zip"), "the Builds folder type is not a cache")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devshelf-watch-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("Videos"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var seen: [String] = []
        let watcher = FolderWatcher { seen += $0 }
        watcher.watch([root.path, root.path])
        precondition(watcher.paths == [root.path])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try Data("video".utf8).write(to: root.appendingPathComponent("Videos/intro.mp4"))
        let deadline = Date().addingTimeInterval(6)
        while !seen.contains(where: { $0.hasSuffix("Videos/intro.mp4") }) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        precondition(seen.contains { $0.hasSuffix("Videos/intro.mp4") }, "FSEvents reported the new file")
        watcher.watch([])
        precondition(watcher.paths.isEmpty)
        seen = []
        try Data("later".utf8).write(to: root.appendingPathComponent("Videos/after-stop.mp4"))
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        precondition(!seen.contains { $0.hasSuffix("after-stop.mp4") }, "a stopped watcher stays quiet")
        print("Folder watch checks passed: new files are reported live, dependency/git/DevShelf noise is ignored, and stopping works.")
    }

    static func checkDuplicatesAndMoves() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devshelf-dupes-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("Project"), downloads = root.appendingPathComponent("Downloads")
        for folder in ["Design", "Videos", "Backups"] { try fm.createDirectory(at: project.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let video = Data((0..<600_000).map { UInt8($0 % 251) })

        // Same disk: moved like Finder (no duplicate); forcing a copy keeps the original.
        try video.write(to: downloads.appendingPathComponent("intro.mp4"))
        precondition(ShelfFiles.sameVolume(downloads, project))
        try ShelfFiles.add([downloads.appendingPathComponent("intro.mp4")], into: project.appendingPathComponent("Videos"), projectRoot: project, sameDiskMoves: true)
        precondition(!fm.fileExists(atPath: downloads.appendingPathComponent("intro.mp4").path) && fm.fileExists(atPath: project.appendingPathComponent("Videos/intro.mp4").path))
        try Data("brief".utf8).write(to: downloads.appendingPathComponent("brief.pdf"))
        try ShelfFiles.add([downloads.appendingPathComponent("brief.pdf")], into: project, projectRoot: project)
        precondition(fm.fileExists(atPath: downloads.appendingPathComponent("brief.pdf").path), "without sameDiskMoves the original stays")

        // Duplicates: a clone shares space, a real copy wastes it, and a leftover in Downloads is found.
        try fm.copyItem(at: project.appendingPathComponent("Videos/intro.mp4"), to: project.appendingPathComponent("Backups/intro.mp4"))          // APFS clone
        try video.write(to: project.appendingPathComponent("Videos/intro 2.mp4"))                                                                // separate copy
        try video.write(to: downloads.appendingPathComponent("intro-old.mp4"))                                                                  // leftover outside
        let unique = Data((0..<400_000).map { UInt8($0 % 13) })
        try unique.write(to: project.appendingPathComponent("Design/only-once.psd"))
        let twin = Data((0..<400_000).map { UInt8($0 % 7) })   // same size as a project file, different contents
        try twin.write(to: downloads.appendingPathComponent("unrelated-twin-a.bin")); try twin.write(to: downloads.appendingPathComponent("unrelated-twin-b.bin"))
        try Data(repeating: 1, count: 1000).write(to: project.appendingPathComponent("Design/small-a.txt"))
        try Data(repeating: 1, count: 1000).write(to: project.appendingPathComponent("Design/small-b.txt"))
        let inside = try Duplicates.scan(places: [("Project", project)])
        precondition(inside.count == 1 && inside[0].files.count == 3, "small files and unique files are ignored")
        let group = inside[0]
        let clone = group.files.first { $0.url.path.hasSuffix("Backups/intro.mp4") }!, separate = group.files.first { $0.url.lastPathComponent == "intro 2.mp4" }!
        precondition(group.sharesSpace(clone) && !group.sharesSpace(separate))
        precondition(group.physicalCopies == 2 && group.wastedBytes == Int64(video.count))
        precondition(group.suggestedKeeper?.url.lastPathComponent == "intro.mp4" && group.suggestedKeeper?.url.path.contains("Videos") == true)
        precondition(group.freedBytes(removing: [separate.id]) == Int64(video.count) && group.freedBytes(removing: [clone.id]) == 0)
        let withOutside = try Duplicates.scan(places: [("Project", project)], outside: [("Downloads", downloads)])
        let videos = withOutside.first { $0.size == Int64(video.count) }!
        precondition(videos.files.count == 4 && videos.files.contains { !$0.inProject && $0.place == "Downloads" } && videos.suggestedKeeper?.inProject == true)
        precondition(withOutside.allSatisfy { $0.files.contains(where: \.inProject) } && !withOutside.contains { $0.size == Int64(unique.count) }, "outside-only twins aren't reported")
        precondition(Duplicates.block(project.appendingPathComponent("Videos/intro.mp4")) != nil)
        print("Duplicate and move checks passed: Finder-style same-disk moves, copies on request, clone vs real-copy detection, leftovers outside projects, keeper choice, and freed-space estimates.")
    }

    static func checkLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devshelf-links-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("Project"), downloads = root.appendingPathComponent("Downloads")
        try fm.createDirectory(at: project.appendingPathComponent("Code"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent("Videos"), withIntermediateDirectories: true)
        try fm.createDirectory(at: downloads.appendingPathComponent("site/src"), withIntermediateDirectories: true)
        try Data("<h1>".utf8).write(to: downloads.appendingPathComponent("site/index.html"))
        try Data("js".utf8).write(to: downloads.appendingPathComponent("site/src/app.js"))
        try Data(repeating: 7, count: 2048).write(to: downloads.appendingPathComponent("intro.mp4"))

        // Linking: originals stay exactly where they are; the project gets links, no copies.
        let moves = try ShelfFiles.transfer([downloads.appendingPathComponent("site"), downloads.appendingPathComponent("intro.mp4")], into: project.appendingPathComponent("Code"), projectRoot: project, link: true)
        precondition(moves.count == 2 && fm.fileExists(atPath: downloads.appendingPathComponent("site/index.html").path) && fm.fileExists(atPath: downloads.appendingPathComponent("intro.mp4").path))
        let siteLink = project.appendingPathComponent("Code/site")
        precondition(ShelfFiles.linkDestination(siteLink)?.path == downloads.appendingPathComponent("site").path)
        let listed = ShelfFiles.children(of: project.appendingPathComponent("Code"))
        let site = listed.first { $0.name == "site" }!, intro = listed.first { $0.name == "intro.mp4" }!
        precondition(site.isFolder && site.link != nil && !site.broken && !intro.isFolder && intro.size == 2048)
        precondition(ShelfFiles.children(of: siteLink).map(\.name) == ["src", "index.html"], "a linked folder can be browsed")
        precondition(ShelfFiles.children(of: siteLink).allSatisfy { $0.url.path.hasPrefix(siteLink.path) }, "items keep their path inside the project")
        precondition(!ShelfFiles.storedInside(siteLink.appendingPathComponent("index.html"), projectRoot: project) && ShelfFiles.storedInside(siteLink, projectRoot: project))

        // Changes to the original show up through the link straight away.
        try Data("new".utf8).write(to: downloads.appendingPathComponent("site/README.md"))
        precondition(ShelfFiles.children(of: siteLink).contains { $0.name == "README.md" })

        // Scans see inside links; a link loop is visited once instead of forever.
        try fm.createSymbolicLink(at: downloads.appendingPathComponent("site/loop"), withDestinationURL: project)
        let groups = Dictionary(uniqueKeysWithValues: FileKinds.scan(project).map { ($0.id, $0) })
        precondition(groups["code"]?.files.contains { $0.url.path == siteLink.appendingPathComponent("src/app.js").path } == true)
        precondition(groups["video"]?.files.map(\.name) == ["intro.mp4"])
        precondition(Set(ShelfFiles.linkedFolders(in: project).map(\.path)).contains(downloads.appendingPathComponent("site").path))
        let recent = Activity.recentFiles(in: project, projectID: "p", since: Date(timeIntervalSinceNow: -60))
        precondition(recent.contains { $0.url.lastPathComponent == "README.md" })
        try fm.removeItem(at: downloads.appendingPathComponent("site/loop"))

        // Moving a file that lives inside a linked folder links it instead: originals never move.
        let again = try ShelfFiles.transfer([siteLink.appendingPathComponent("index.html")], into: project.appendingPathComponent("Videos"), projectRoot: project, link: true)
        precondition(fm.fileExists(atPath: downloads.appendingPathComponent("site/index.html").path) && ShelfFiles.linkDestination(again[0].destination) != nil)
        // Items stored in the project (including links themselves) are still moved when reorganizing.
        let linkMove = try ShelfFiles.transfer([project.appendingPathComponent("Code/intro.mp4")], into: project.appendingPathComponent("Videos"), projectRoot: project, link: true)
        precondition(!fm.fileExists(atPath: project.appendingPathComponent("Code/intro.mp4").path) && ShelfFiles.linkDestination(linkMove[0].destination)?.lastPathComponent == "intro.mp4")
        precondition(fm.fileExists(atPath: downloads.appendingPathComponent("intro.mp4").path))
        do { _ = try ShelfFiles.transfer([project], into: siteLink, projectRoot: project, link: true); fatalError("A project was linked inside itself") } catch { }

        // Drive sync and zip contain the real files, not links.
        let drive = root.appendingPathComponent("Drive/Project")
        let report = try ShelfFiles.sync(from: project, to: drive)
        precondition(report.copied >= 4 && ShelfFiles.linkDestination(drive.appendingPathComponent("Code/site")) == nil)
        let syncedFile = try Data(contentsOf: drive.appendingPathComponent("Code/site/src/app.js"))
        precondition(String(data: syncedFile, encoding: .utf8) == "js")
        let synced = try ShelfFiles.sync(from: project, to: drive)
        precondition(synced.copied == 0, "a second sync copies nothing")
        let archive = root.appendingPathComponent("p.zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = root
        zip.arguments = ZipOptions().arguments(item: "Project", archive: archive); zip.standardOutput = Pipe(); zip.standardError = Pipe()
        try zip.run(); zip.waitUntilExit()
        precondition(ZipOptions.succeeded(zip.terminationStatus))
        let info = Process(); info.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); info.arguments = ["-p", archive.path, "Project/Code/site/src/app.js"]
        let out = Pipe(); info.standardOutput = out; try info.run(); info.waitUntilExit()
        precondition(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "js", "the zip holds the linked file's contents")

        // Broken links are reported, and removing a link never touches the original.
        try fm.createSymbolicLink(at: project.appendingPathComponent("Code/gone"), withDestinationURL: downloads.appendingPathComponent("nothing-here"))
        let gone = ShelfFiles.children(of: project.appendingPathComponent("Code")).first { $0.name == "gone" }!
        precondition(gone.broken && !gone.isFolder && gone.link != nil)
        try fm.removeItem(at: siteLink)
        precondition(fm.fileExists(atPath: downloads.appendingPathComponent("site/src/app.js").path))
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        precondition(prefs.addMode == "link")
        print("Link checks passed: originals stay in place, links browse and scan, live contents, loops, reorganizing, drive sync and zip with real files, broken links, and safe link removal.")
    }

    static func checkFolderTree() {
        let root = "/workspace/Lexclaro"
        let parent = project("Lexclaro PDF Simpler", path: root)
        let children = ["Lexclaro DEV", "Lexclaro 7", "Lexclaro 2"].map { project("Lexclaro PDF Simpler", path: root + "/" + $0) }
        let duplicate = project("Duplicate metadata", path: root + "/../Lexclaro")
        let similar = project("Separate project", path: "/workspace/Lexclaro-other")
        let forest = FolderTree.build([parent, duplicate, similar] + children, locations: ["/workspace"])
        precondition(forest.count == 2)
        let lexclaro = forest.first { $0.path == root }!
        precondition(lexclaro.project?.name == parent.name && lexclaro.projectCount == 4)
        precondition(lexclaro.children.map(\.name) == ["Lexclaro 2", "Lexclaro 7", "Lexclaro DEV"])
        precondition(lexclaro.branchPaths == [root])
        let containers = FolderTree.build([
            project("API", path: "/workspace/bundle/packages/api"),
            project("Web", path: "/workspace/bundle/packages/web")
        ], locations: ["/workspace"])
        precondition(containers.count == 1 && containers[0].name == "bundle" && containers[0].project == nil)
        precondition(containers[0].children[0].name == "packages" && containers[0].projectCount == 2)
        // A configured location inside a detected parent must not detach children.
        let overlapping = FolderTree.build([parent] + children, locations: ["/workspace", root])
        precondition(overlapping.count == 1 && overlapping[0].projectCount == 4)
        let separateLocations = FolderTree.build([
            parent, project("Same display name", path: "/other/Lexclaro")
        ], locations: ["/workspace", "/other"])
        precondition(separateLocations.count == 2 && Set(separateLocations.map(\.path)).count == 2)
        precondition(FolderTree.build([], locations: ["/workspace"]).isEmpty)
        print("Folder tree checks passed: nested projects, duplicate paths, natural folder ordering, synthetic parents, overlapping roots, separate locations, and empty results.")
    }
}
