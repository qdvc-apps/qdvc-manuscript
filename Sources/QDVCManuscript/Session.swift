import AppKit
import ManuscriptCore
import Observation

struct OutlineEntry: Identifiable, Hashable {
    var id: String
    var level: Int
    var number: String?
    var title: String
    var location: Int
    var words: Int
}

struct FigureEntry: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var kind: FigureKind
    var label: String
    var caption: String
    var location: Int
}

struct NoteEntry: Identifiable, Hashable {
    var id: Int { location }
    var isFootnote: Bool
    var number: Int
    var text: String
    var location: Int
}

struct SentenceInfo {
    var range: NSRange
    var words: Int
}

struct ParagraphInfo {
    var range: NSRange
    var kind: ParaKind
    var sentences: [SentenceInfo]
}

/// Everything worked out from the text after each edit (debounced).
struct Analysis {
    var outline: [OutlineEntry] = []
    var figures: [FigureEntry] = []
    var notes: [NoteEntry] = []
    var counts = WordCounts()
    var paragraphs: [ParagraphInfo] = []
    var citedSources: [String] = []
    var citationCounts: [String: Int] = [:]
    var referencesHeadingLocation: Int?
    var hasReferenceList = false
    var missingSources: [String] = []
    var brokenReferences = 0
    var variableUses: [String: Int] = [:]
    var titleText = ""
    var version = 0
}

/// One open manuscript: its text (shared by all its windows, each with its
/// own layout manager), variables, citations and Bibliotheca library, and
/// the saving of it all back to the workspace.
@Observable
@MainActor
final class ManuscriptSession {
    let url: URL
    let storage = NSTextStorage()
    let undoManager = UndoManager()
    let info = DisplayInfo()
    @ObservationIgnored private var storageObserver: StorageObserver?

    var settings = ManuscriptSettings()
    var extraFrontmatter: [YAMLPair] = []
    private(set) var variables: [Variable] = []
    var variablesPath = Workspace.variablesFile
    private(set) var registry = CitationRegistry()
    private(set) var library: BibliothecaLibrary?
    private(set) var libraryURL: URL?
    private(set) var libraryLoading = false
    private(set) var analysis = Analysis()
    var warnings: [String] = []
    var saveError: String?
    /// The files changed on disk while there were unsaved edits here.
    var conflict = false

    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var signature: [String: Date] = [:]
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var analysisTimer: Timer?
    @ObservationIgnored private var analysisObservers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var referenceEntries: [ReferenceEntry] = []

    var title: String { analysis.titleText.isEmpty ? url.deletingPathExtension().lastPathComponent : analysis.titleText }

    init(url: URL) throws {
        self.url = url
        info.workspaceURL = url
        storageObserver = StorageObserver(session: self)
        storage.delegate = storageObserver
        try load()
        restoreLibrary()
    }

    // MARK: Loading

    func load() throws {
        let loaded = try Workspace.load(url)
        settings = loaded.manuscript.settings
        extraFrontmatter = loaded.manuscript.extraFrontmatter
        variables = loaded.variables
        variablesPath = loaded.variablesPath
        registry = loaded.registry
        warnings = loaded.warnings
        info.variables = Dictionary(loaded.variables.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        info.headingNumbersVisible = settings.headingNumbers
        info.forgetImages()
        loading = true
        storage.setAttributedString(DocumentBuilder.attributedString(loaded.manuscript, info: info))
        loading = false
        undoManager.removeAllActions()
        dirty = false
        conflict = false
        signature = Workspace.signature(url)
        analyze()
    }

    /// Discards edits here and reads the workspace again.
    func reload() {
        do {
            try load()
        } catch {
            saveError = "Couldn’t reload: \(error.localizedDescription)"
        }
    }

    // MARK: Edits

    fileprivate func storageEdited() {
        guard !loading else { return }
        dirty = true
        scheduleAnalysis()
        scheduleSave()
    }

    /// For changes the text storage doesn't see (token contents, settings).
    func changed(relayout: Bool = true) {
        dirty = true
        if relayout { invalidateAttachments() }
        scheduleAnalysis(delay: 0.05)
        scheduleSave()
    }

    func scheduleAnalysis(delay: TimeInterval = 0.3) {
        analysisTimer?.invalidate()
        analysisTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.analyze() }
        }
    }

    func scheduleSave(delay: TimeInterval = 1.0) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    func observeAnalysis(_ id: UUID, _ handler: @escaping () -> Void) { analysisObservers[id] = handler }
    func stopObserving(_ id: UUID) { analysisObservers[id] = nil }

    /// Re-lays out every attachment (numbers, citations and values changed).
    func invalidateAttachments() {
        let full = NSRange(location: 0, length: storage.length)
        for lm in storage.layoutManagers {
            lm.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            lm.invalidateDisplay(forCharacterRange: full)
        }
    }

    // MARK: Analysis

    func manuscript() -> Manuscript {
        let read = DocumentReader.read(storage)
        return Manuscript(title: read.title, blocks: read.blocks, settings: settings, extraFrontmatter: extraFrontmatter)
    }

    var formatterLibrary: BibliothecaLibrary { library ?? BibliothecaLibrary() }

    func analyze() {
        analysisTimer?.invalidate()
        let read = DocumentReader.read(storage)
        let m = Manuscript(title: read.title, blocks: read.blocks, settings: settings, extraFrontmatter: extraFrontmatter)
        let numbering = Numbering(blocks: m.blocks)
        let cited = m.citedSources
        let formatter = CitationFormatter(style: settings.citationStyle, library: formatterLibrary, cited: cited)
        var citationTexts: [CitationKey: String] = [:]
        var citationCounts: [String: Int] = [:]
        for c in m.citations {
            citationTexts[c.key] = formatter.text(for: c)
            for s in c.sources { citationCounts[s, default: 0] += 1 }
        }
        let entries = formatter.referenceEntries(for: cited, cached: registry)
        var headingTitles: [String: String] = [:]
        for h in m.headings { headingTitles[h.id] = h.inlines.plainText { self.info.plainText($0) } }

        // Footnote numbers and notes, in order.
        var footnoteNumbers: [ObjectIdentifier: Int] = [:]
        var notes: [NoteEntry] = []
        var brokenReferences = 0
        var variableUses: [String: Int] = [:]
        var footnoteCount = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let a = value as? TokenAttachment else { return }
            switch a.token {
            case .footnote(let inner):
                footnoteCount += 1
                footnoteNumbers[ObjectIdentifier(a)] = footnoteCount
                notes.append(NoteEntry(isFootnote: true, number: footnoteCount, text: inner.plainText { self.info.plainText($0) },
                                       location: range.location))
                for t in inner.allTokens { if case .variable(let n) = t { variableUses[n, default: 0] += 1 } }
            case .note(let text):
                notes.append(NoteEntry(isFootnote: false, number: 0, text: text, location: range.location))
            case .figureRef(let path):
                if numbering.figures[path] == nil { brokenReferences += 1 }
            case .sectionRef(let id):
                if numbering.headings[id] == nil && headingTitles[id] == nil { brokenReferences += 1 }
            case .variable(let n):
                variableUses[n, default: 0] += 1
            case .citation:
                break
            }
        }
        // Numbered list items.
        var listNumbers: [Int: Int] = [:]
        var n = 0
        var previousWasNumbered = false
        for span in read.spans {
            if case .numbered = span.block {
                n = previousWasNumbered ? n + 1 : 1
                listNumbers[span.range.location] = n
                previousWasNumbered = true
            } else {
                previousWasNumbered = false
            }
        }

        let referenceStrings = entries.map { DisplayInfo.referenceString($0.entry) }
        let needsRelayout = info.numbering != numbering || info.citationTexts != citationTexts
            || info.footnoteNumbers != footnoteNumbers || info.headingTitles != headingTitles
            || referenceEntries != entries || info.listNumbers != listNumbers
            || info.headingNumbersVisible != settings.headingNumbers
        info.numbering = numbering
        info.citationTexts = citationTexts
        info.footnoteNumbers = footnoteNumbers
        info.headingTitles = headingTitles
        info.listNumbers = listNumbers
        info.headingNumbersVisible = settings.headingNumbers
        info.referenceEntries = referenceStrings
        referenceEntries = entries
        if needsRelayout { invalidateAttachments() }

        var a = Analysis()
        a.version = analysis.version + 1
        a.titleText = m.title.plainText { self.info.plainText($0) }
        a.counts = WordCounts(m, display: { self.info.plainText($0) }, referenceEntries: entries.map(\.entry))
        for span in read.spans {
            switch span.block {
            case .heading(let h):
                let title = h.inlines.plainText { self.info.plainText($0) }
                a.outline.append(OutlineEntry(id: h.id, level: h.level, number: numbering.headings[h.id], title: title,
                                              location: span.range.location, words: a.counts.sections[h.id] ?? 0))
                if Numbering.isReferencesHeading(title), a.referencesHeadingLocation == nil {
                    a.referencesHeadingLocation = span.range.location
                }
            case .figure(let f):
                a.figures.append(FigureEntry(path: f.path, kind: f.kind,
                                             label: numbering.figureLabel(f.path) ?? f.kind.label,
                                             caption: f.caption.plainText { self.info.plainText($0) },
                                             location: span.range.location))
            case .referenceList:
                a.hasReferenceList = true
            default:
                break
            }
        }
        a.notes = notes
        a.citedSources = cited
        a.citationCounts = citationCounts
        if let library, !library.isEmpty {
            a.missingSources = cited.filter { library.records[$0] == nil }
        }
        a.brokenReferences = brokenReferences
        a.variableUses = variableUses
        a.paragraphs = paragraphInfo()
        analysis = a
        for handler in analysisObservers.values { handler() }
    }

    /// Paragraphs with their sentences, for Focus mode, topic sentences and
    /// long-sentence flags.
    private func paragraphInfo() -> [ParagraphInfo] {
        var out: [ParagraphInfo] = []
        let ns = storage.string as NSString
        for range in DocumentReader.paragraphRanges(storage) where range.length > 0 {
            let kind = DocumentReader.kind(storage, at: range.location)
            if kind == .figure || kind == .refs {
                out.append(ParagraphInfo(range: range, kind: kind, sentences: []))
                continue
            }
            var attachable = Set<Int>()
            storage.enumerateAttribute(.attachment, in: range, options: []) { value, r, _ in
                guard let a = value as? TokenAttachment else { return }
                switch a.token {
                case .footnote, .note: attachable.insert(r.location - range.location)
                default: break
                }
            }
            var units = [UInt16](repeating: 0, count: range.length)
            ns.getCharacters(&units, range: range)
            let sentences = Sentences.split(utf16: units, attachable: { attachable.contains($0) }).map { r -> SentenceInfo in
                let nr = NSRange(location: range.location + r.lowerBound, length: r.count)
                return SentenceInfo(range: nr, words: WordCount.count(displayString(nr)))
            }
            out.append(ParagraphInfo(range: range, kind: kind, sentences: sentences))
        }
        return out
    }

    /// The text of a range as it reads (tokens as they show; notes left out).
    func displayString(_ range: NSRange) -> String {
        var out = ""
        let ns = storage.string as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.attachment, in: safe, options: []) { value, r, _ in
            if let a = value as? TokenAttachment {
                out += info.plainText(a.token)
            } else if value == nil {
                out += ns.substring(with: r)
            }
        }
        return out
    }

    /// Finds citations and cross-references in pasted Markdown or a caption,
    /// by the text they show now.
    func pasteRecognizer() -> Recognizer {
        var citations = registry.citations
        for c in manuscript().citations {
            var current = c
            current.text = info.citationTexts[c.key] ?? c.text
            citations.append(current)
        }
        var figures: [String: String] = [:]
        for path in info.numbering.figures.keys {
            if let label = info.numbering.figureLabel(path) { figures[label] = path }
        }
        var sections: [String: String] = [:]
        for (id, number) in info.numbering.headings { sections[number] = id }
        return Recognizer(citations: citations, figures: figures, sections: sections)
    }

    // MARK: Saving

    /// The manuscript as it will be written: citations with their current text.
    func manuscriptForSaving() -> Manuscript {
        manuscript().mappingTokens { t in
            guard case .citation(var c) = t else { return t }
            c.text = info.citationTexts[c.key] ?? c.text
            return .citation(c)
        }
    }

    func save() {
        saveTimer?.invalidate()
        guard dirty, !conflict else { return }
        if analysisTimer?.isValid == true { analyze() }
        let m = manuscriptForSaving()
        let rendered = Workspace.render(m, variables: variables, variablesPath: variablesPath, referenceEntries: referenceEntries)
        do {
            try Workspace.save(rendered, to: url)
            registry = CitationRegistry.from(m, references: referenceEntries)
            dirty = false
            saveError = nil
            signature = Workspace.signature(url)
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    /// Saves now if anything is pending.
    func flush() { if dirty { save() } }

    /// After returning to the app: reload if the files changed elsewhere.
    func checkForOutsideChanges() {
        let now = Workspace.signature(url)
        guard now != signature else { return }
        if dirty {
            conflict = true
        } else {
            reload()
        }
    }

    /// Keep this window's version, overwriting the changed files.
    func keepMine() {
        conflict = false
        dirty = true
        save()
    }

    // MARK: Settings and variables

    func setHeadingNumbers(_ on: Bool) {
        settings.headingNumbers = on
        changed()
    }

    func setCitationStyle(_ style: CitationStyle) {
        settings.citationStyle = style
        changed()
    }

    func setWordLimit(_ limit: Int?) {
        settings.wordLimit = limit.flatMap { $0 > 0 ? $0 : nil }
        changed(relayout: false)
    }

    func setVariables(_ list: [Variable]) {
        variables = list
        info.variables = Dictionary(list.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        changed()
    }

    func setValue(_ value: String, of name: String) {
        guard let i = variables.firstIndex(where: { $0.name == name }) else { return }
        var list = variables
        list[i].value = value
        setVariables(list)
    }

    @discardableResult
    func addVariable(name: String? = nil, value: String) -> String {
        let taken = Set(variables.map(\.name))
        let finalName = name.flatMap { Variable.isValidName($0) && !taken.contains($0) ? $0 : nil }
            ?? Variable.suggestedName(value, avoiding: taken)
        setVariables(variables + [Variable(name: finalName, value: value)])
        return finalName
    }

    /// Renames a variable and every use of it.
    func renameVariable(_ old: String, to new: String) -> Bool {
        guard Variable.isValidName(new), !variables.contains(where: { $0.name == new }),
              let i = variables.firstIndex(where: { $0.name == old }) else { return false }
        var list = variables
        list[i].name = new
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            guard let a = value as? TokenAttachment else { return }
            a.token = Self.renamingVariable(a.token, old, new)
        }
        setVariables(list)
        return true
    }

    static func renamingVariable(_ t: Token, _ old: String, _ new: String) -> Token {
        switch t {
        case .variable(let n) where n == old: return .variable(new)
        case .footnote(let inner):
            return .footnote(inner.mappingTokens { if case .variable(let n) = $0, n == old { return .variable(new) }; return $0 })
        default: return t
        }
    }

    func removeVariable(_ name: String) {
        setVariables(variables.filter { $0.name != name })
    }

    // MARK: Figures

    /// Copies an image into figures/ or tables/ and returns its workspace path.
    func addImage(_ data: Data, preferredName: String, kind: FigureKind) throws -> String {
        var png = data
        if ImageInfo(data) == nil, let rep = NSBitmapImageRep(data: data), let converted = rep.representation(using: .png, properties: [:]) {
            png = converted
        }
        let ext = ImageInfo(png)?.format == "jpeg" ? "jpeg" : "png"
        let folder = url.appendingPathComponent(kind.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var base = preferredName.slug(limit: 40)
        if base.isEmpty { base = kind.label.lowercased() }
        var name = "\(base).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(n).\(ext)"
            n += 1
        }
        try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        return "\(kind.folder)/\(name)"
    }

    func imageData(_ path: String) -> Data? {
        try? Data(contentsOf: url.appendingPathComponent(path))
    }

    // MARK: Bibliotheca

    private func restoreLibrary() {
        if let url = DeviceStore.library(for: self.url) { loadLibrary(url) }
    }

    func setLibrary(_ url: URL) {
        DeviceStore.setLibrary(url, for: self.url)
        loadLibrary(url)
    }

    func forgetLibrary() {
        DeviceStore.forgetLibrary(for: url)
        library = nil
        libraryURL = nil
        changed()
    }

    func loadLibrary(_ url: URL) {
        libraryURL = url
        libraryLoading = true
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { BibliothecaLibrary.load(url) }.value
            guard let self else { return }
            self.library = loaded
            self.libraryLoading = false
            self.changed()
        }
    }

    func reloadLibrary() {
        if let libraryURL { loadLibrary(libraryURL) }
    }

    // MARK: Exports

    func docxData() -> Data {
        let m = manuscriptForSaving()
        let info = self.info
        return DocxExport.document(m, display: { info.plainText($0) }, referenceEntries: referenceEntries.map(\.entry),
                                   image: { [url] path in try? Data(contentsOf: url.appendingPathComponent(path)) },
                                   options: Prefs.docxOptions)
    }

    /// One self-contained Markdown file (variables filled in, notes left
    /// out), with its figures, written into `folder`.
    func exportMarkdown(to folder: URL) throws -> URL {
        let m = manuscriptForSaving()
        func resolve(_ inlines: [Inline]) -> [Inline] {
            var out: [Inline] = []
            for inline in inlines {
                switch inline {
                case .token(.variable(let name), let s): out.append(.text(info.variables[name] ?? "{{\(name)}}", s))
                case .token(.note, _): continue
                case .token(.footnote(let inner), let s): out.append(.token(.footnote(resolve(inner)), s))
                default: out.append(inline)
                }
            }
            return out.coalesced
        }
        var resolved = m
        resolved.extraFrontmatter = m.extraFrontmatter.filter { $0.key != "mustache" }
        resolved.title = resolve(m.title)
        resolved.blocks = m.blocks.map { $0.mappingInlines(resolve) }.filter {
            if case .paragraph(let i) = $0, i.trimmed.isEmpty { return false }
            return true
        }
        let rendered = Workspace.render(resolved, variables: [], referenceEntries: referenceEntries)
        // Join the files, dropping the section files' own frontmatter (only the first has one).
        let text = rendered.files.keys.sorted(by: { a, b in
            let na = Int(a.prefix(while: \.isNumber)) ?? 0, nb = Int(b.prefix(while: \.isNumber)) ?? 0
            return na != nb ? na < nb : a < b
        }).compactMap { rendered.files[$0] }.joined(separator: "\n")
        var name = title.slug()
        if name.isEmpty { name = "manuscript" }
        let file = folder.appendingPathComponent(name + ".md")
        try Data(text.utf8).write(to: file, options: .atomic)
        for f in resolved.figures {
            let source = url.appendingPathComponent(f.path)
            let target = folder.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: target) }
        }
        return file
    }
}

/// Tells the session about text edits (a separate object, so the delegate
/// callbacks needn't be main-actor isolated).
private final class StorageObserver: NSObject, NSTextStorageDelegate {
    weak var session: ManuscriptSession?

    init(session: ManuscriptSession) {
        self.session = session
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) || editedMask.contains(.editedAttributes) else { return }
        // Called on the main thread; the session only notes the edit and
        // schedules its work (it never edits the text from here).
        MainActor.assumeIsolated { session?.storageEdited() }
    }
}
