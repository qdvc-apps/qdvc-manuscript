import AppKit
import ManuscriptCore
import Observation
import UniformTypeIdentifiers

/// Which manuscript a window shows. Each window has its own `instance`, so
/// several windows can show the same manuscript.
struct EditorWindowRef: Codable, Hashable {
    var path: String
    var instance = UUID()
    /// Where the new window starts (another window's insertion point).
    var location: Int?
}

/// What this Mac remembers, outside any workspace (UserDefaults): recent
/// manuscripts and, per manuscript, its QDVC Bibliotheca library. The app is
/// sandboxed, so folders are remembered as security-scoped bookmarks.
@MainActor
enum DeviceStore {
    static var defaults: UserDefaults { .standard }

    static func bookmark(_ url: URL, readOnly: Bool) -> Data? {
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        if let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        // Not sandboxed (swift run): a plain bookmark is enough.
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark and starts access to it.
    static func resolve(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    struct Recent: Equatable, Hashable {
        var path: String
        var bookmark: Data
    }

    private static let recentKey = "recentWorkspaces"

    static var recents: [Recent] {
        let list = defaults.array(forKey: recentKey) as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard let path = d["path"] as? String, let data = d["bookmark"] as? Data else { return nil }
            return Recent(path: path, bookmark: data)
        }
    }

    static func setRecents(_ list: [Recent]) {
        defaults.set(list.prefix(12).map { ["path": $0.path, "bookmark": $0.bookmark] as [String: Any] }, forKey: recentKey)
    }

    static func addRecent(_ url: URL) {
        guard let data = bookmark(url, readOnly: false) else { return }
        var list = recents.filter { $0.path != url.path }
        list.insert(Recent(path: url.path, bookmark: data), at: 0)
        setRecents(list)
    }

    static func removeRecent(path: String) {
        setRecents(recents.filter { $0.path != path })
    }

    // The QDVC Bibliotheca library of a manuscript, on this Mac (read only).
    private static func libraryKey(_ workspace: URL) -> String { "library.\(workspace.path)" }

    static func library(for workspace: URL) -> URL? {
        guard let data = defaults.data(forKey: libraryKey(workspace)) else { return nil }
        return resolve(data)
    }

    static func setLibrary(_ url: URL, for workspace: URL) {
        guard let data = bookmark(url, readOnly: true) else { return }
        defaults.set(data, forKey: libraryKey(workspace))
    }

    static func forgetLibrary(for workspace: URL) {
        defaults.removeObject(forKey: libraryKey(workspace))
    }
}

/// The app: recent manuscripts, the open manuscripts (shared by their
/// windows), and the panels for creating, opening and importing.
@Observable
@MainActor
final class AppModel {
    private(set) var recents: [DeviceStore.Recent] = DeviceStore.recents
    var errorMessage: String?
    var welcomeRequested = false
    var showWelcomeAtLaunch: Bool = UserDefaults.standard.bool(forKey: Prefs.showWelcome) {
        didSet { UserDefaults.standard.set(showWelcomeAtLaunch, forKey: Prefs.showWelcome) }
    }
    /// Open manuscripts, by path, with the number of windows showing each.
    @ObservationIgnored private var sessions: [String: (session: ManuscriptSession, windows: Int)] = [:]
    /// Things to tell the user when a manuscript's first window opens.
    @ObservationIgnored private var pendingNotes: [String: [String]] = [:]
    private(set) var openCount = 0

    var openSessions: [ManuscriptSession] { sessions.values.map(\.session) }

    // MARK: Sessions

    /// The manuscript at `path`, loading it if no window shows it yet.
    func acquireSession(_ path: String) throws -> ManuscriptSession {
        if let entry = sessions[path] {
            sessions[path] = (entry.session, entry.windows + 1)
            return entry.session
        }
        let session = try ManuscriptSession(url: URL(fileURLWithPath: path, isDirectory: true))
        if let notes = pendingNotes.removeValue(forKey: path) { session.warnings += notes }
        sessions[path] = (session, 1)
        openCount = sessions.count
        return session
    }

    func releaseSession(_ session: ManuscriptSession) {
        let path = session.url.path
        guard let entry = sessions[path] else { return }
        if entry.windows <= 1 {
            session.flush()
            sessions[path] = nil
        } else {
            sessions[path] = (entry.session, entry.windows - 1)
        }
        openCount = sessions.count
    }

    func flushAll() {
        for s in openSessions { s.flush() }
    }

    func checkAllForOutsideChanges() {
        for s in openSessions { s.checkForOutsideChanges() }
    }

    // MARK: Opening

    func refresh() { recents = DeviceStore.recents }

    /// Checks a folder and remembers it; the window to open, or nil.
    func prepareToOpen(_ url: URL) -> EditorWindowRef? {
        guard Workspace.isWorkspace(url) else {
            errorMessage = "“\(url.lastPathComponent)” isn’t a QDVC Manuscript workspace: it has no manuscript.md or 00-manuscript.md.\n\nUse File › New Manuscript to start one, or File › Import to bring in a Markdown or Word file."
            return nil
        }
        DeviceStore.addRecent(url)
        refresh()
        return EditorWindowRef(path: url.path)
    }

    func open(_ recent: DeviceStore.Recent) -> EditorWindowRef? {
        if sessions[recent.path] != nil { return EditorWindowRef(path: recent.path) }
        guard let url = DeviceStore.resolve(recent.bookmark) else {
            errorMessage = "“\((recent.path as NSString).lastPathComponent)” couldn’t be found. It may have been moved or deleted."
            return nil
        }
        return prepareToOpen(url)
    }

    func removeRecent(_ recent: DeviceStore.Recent) {
        DeviceStore.removeRecent(path: recent.path)
        refresh()
    }

    func clearRecents() {
        DeviceStore.setRecents([])
        refresh()
    }

    func chooseWorkspace() -> EditorWindowRef? {
        let panel = NSOpenPanel()
        panel.title = "Open Manuscript"
        panel.message = "Choose a manuscript’s workspace folder."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return prepareToOpen(url)
    }

    /// Asks where to make a new workspace folder.
    private func chooseNewFolder(title: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.message = "QDVC Manuscript makes a new folder for the manuscript: its Markdown files, variables and figures. Track it with Git."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if Workspace.isWorkspace(url) { return url }
            if !contents.filter({ !$0.hasPrefix(".") }).isEmpty {
                errorMessage = "“\(url.lastPathComponent)” already exists and isn’t empty. Choose a new name."
                return nil
            }
        }
        return url
    }

    func newManuscript() -> EditorWindowRef? {
        guard let url = chooseNewFolder(title: "New Manuscript", suggestedName: "My Manuscript") else { return nil }
        if Workspace.isWorkspace(url) { return prepareToOpen(url) }
        do {
            try Workspace.create(at: url, title: "")
        } catch {
            errorMessage = "Couldn’t create the manuscript.\n\n\(error.localizedDescription)"
            return nil
        }
        return prepareToOpen(url)
    }

    /// Makes a new workspace from a Markdown file, a folder of Markdown
    /// files, or a Word document.
    func importDocument() -> EditorWindowRef? {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.message = "Choose a Markdown file, a folder of Markdown files, or a Word document (.docx)."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText,
                                     UTType(filenameExtension: "docx") ?? .data, .plainText, .folder]
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        var manuscript = Manuscript()
        var variables: [Variable] = []
        var images: [(path: String, data: Data)] = []
        var notes: [String] = []
        do {
            if source.pathExtension.lowercased() == "docx" {
                let result = try DocxImport.read(try Data(contentsOf: source))
                manuscript = result.manuscript
                images = result.images
                notes = result.notes
            } else {
                var files: [(String, String)] = []
                var folder = source.deletingLastPathComponent()
                if directoryExists(source) {
                    folder = source
                    let names = ((try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? [])
                        .filter { $0.hasSuffix(".md") || $0.hasSuffix(".markdown") }
                        .sorted { a, b in
                            let na = Int(a.prefix(while: \.isNumber)) ?? Int.max, nb = Int(b.prefix(while: \.isNumber)) ?? Int.max
                            return na != nb ? na < nb : a < b
                        }
                    for name in names {
                        files.append((name, try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8)))
                    }
                    guard !files.isEmpty else {
                        errorMessage = "“\(source.lastPathComponent)” has no Markdown files."
                        return nil
                    }
                } else {
                    files = [(source.lastPathComponent, String(decoding: try Data(contentsOf: source), as: UTF8.self))]
                }
                let variablesText = try? String(contentsOf: folder.appendingPathComponent(Workspace.variablesFile), encoding: .utf8)
                let loaded = Workspace.parse(files: files, variablesYAML: variablesText, citationsYAML: nil)
                manuscript = loaded.manuscript
                variables = loaded.variables
                notes = loaded.warnings
                // Pictures beside the Markdown, where the sandbox allows reading them.
                var missing = 0
                for f in manuscript.figures {
                    if let data = try? Data(contentsOf: folder.appendingPathComponent(f.path)) {
                        images.append((f.path, data))
                    } else {
                        missing += 1
                    }
                }
                if missing > 0 {
                    notes.append("\(missing) picture(s) couldn’t be read. Copy them into the workspace’s figures or tables folder; to import pictures too, import the whole folder.")
                }
            }
        } catch {
            errorMessage = "Couldn’t import “\(source.lastPathComponent)”.\n\n\(error.localizedDescription)"
            return nil
        }
        let titleText = manuscript.title.plainText { _ in "" }
        let suggested = titleText.isEmpty ? source.deletingPathExtension().lastPathComponent : String(titleText.prefix(60))
        guard let target = chooseNewFolder(title: "Import as New Manuscript", suggestedName: suggested) else { return nil }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for image in images {
                let url = target.appendingPathComponent(image.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try image.data.write(to: url, options: .atomic)
            }
            let rendered = Workspace.render(manuscript, variables: variables, referenceEntries: [])
            try Workspace.save(rendered, to: target)
            let gitignore = target.appendingPathComponent(".gitignore")
            if !FileManager.default.fileExists(atPath: gitignore.path) {
                try Data(".DS_Store\n".utf8).write(to: gitignore, options: .atomic)
            }
        } catch {
            errorMessage = "Couldn’t write the new manuscript.\n\n\(error.localizedDescription)"
            return nil
        }
        if !notes.isEmpty { pendingNotes[target.path] = ["Imported from “\(source.lastPathComponent)”."] + notes }
        return prepareToOpen(target)
    }
}
