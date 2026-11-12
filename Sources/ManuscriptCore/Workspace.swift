import Foundation

/// A manuscript's workspace folder (docs/FILE_FORMAT.md):
///
///     manuscript.md              the whole text, when it has no sections
///     00-manuscript.md           …or the frontmatter and text before the first heading,
///     01-introduction.md         then one file per top-level section
///     variables.yml              pandoc-mustache variables
///     citations.yml              what each in-text citation stands for in QDVC Bibliotheca
///     figures/*.png, tables/*.png
public enum Workspace {
    public static let singleFile = "manuscript.md"
    public static let frontFile = "00-manuscript.md"
    public static let variablesFile = "variables.yml"
    public static let citationsFile = "citations.yml"
    static let sectionFile = Rx("^(\\d{2,4})-[A-Za-z0-9._-]*\\.md$")
    static let settingsKey = "qdvc-manuscript"

    public struct Loaded {
        public var manuscript: Manuscript
        public var variables: [Variable]
        public var registry: CitationRegistry
        /// Where the variables live (from `mustache:`, else variables.yml).
        public var variablesPath: String
        /// Things worth telling the user (unreadable files and the like).
        public var warnings: [String]
    }

    public enum WorkspaceError: Error, LocalizedError {
        case noManuscript(String)
        case notAFolder(String)

        public var errorDescription: String? {
            switch self {
            case .noManuscript(let name):
                return "“\(name)” has no manuscript.md or 00-manuscript.md, so it isn't a QDVC Manuscript workspace."
            case .notAFolder(let name):
                return "“\(name)” isn't a folder."
            }
        }
    }

    // MARK: Finding the files

    public static func isWorkspace(_ url: URL) -> Bool {
        !manuscriptFiles(url).isEmpty
    }

    /// The manuscript's Markdown files, in order.
    public static func manuscriptFiles(_ url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let numbered = names.filter { sectionFile.matches($0) }.sorted(by: fileOrder)
        if !numbered.isEmpty { return numbered }
        return names.contains(singleFile) ? [singleFile] : []
    }

    static func fileOrder(_ a: String, _ b: String) -> Bool {
        let na = Int(a.prefix(while: \.isNumber)) ?? 0
        let nb = Int(b.prefix(while: \.isNumber)) ?? 0
        return na != nb ? na < nb : a < b
    }

    /// The title, for lists of recent manuscripts; nil if it isn't a workspace.
    public static func summary(_ url: URL) -> String? {
        guard let first = manuscriptFiles(url).first,
              let text = readTextLossy(url.appendingPathComponent(first)) else { return nil }
        let (yaml, _, _) = BlockMarkdown.splitFrontmatter(text)
        let title = yaml?["title"]?.string ?? ""
        return InlineMarkdown.parse(title).plainText { t in
            if case .variable(let name) = t { return "{{\(name)}}" }
            return ""
        }
    }

    // MARK: Loading

    public static func load(_ url: URL) throws -> Loaded {
        guard directoryExists(url) else { throw WorkspaceError.notAFolder(url.lastPathComponent) }
        let names = manuscriptFiles(url)
        guard !names.isEmpty else { throw WorkspaceError.noManuscript(url.lastPathComponent) }
        var warnings: [String] = []
        let all = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if names.first != singleFile, all.contains(singleFile) {
            warnings.append("Both manuscript.md and numbered section files are present; manuscript.md was ignored.")
        }
        var files: [(String, String)] = []
        for name in names {
            guard let text = readTextLossy(url.appendingPathComponent(name)) else {
                warnings.append("Couldn't read \(name).")
                continue
            }
            files.append((name, text))
        }
        // Variables: from the frontmatter's `mustache:` if it names a file.
        let front = files.first.map { BlockMarkdown.splitFrontmatter($0.1).yaml } ?? nil
        var variablesPath = variablesFile
        if let m = front?["mustache"] {
            if let s = m.string, !s.isEmpty {
                variablesPath = s
            } else if let first = m.strings.first {
                variablesPath = first
                if m.strings.count > 1 {
                    warnings.append("Only the first of the frontmatter's mustache files (\(first)) is shown and edited.")
                }
            }
        }
        if variablesPath.hasPrefix("./") { variablesPath.removeFirst(2) }
        let variablesText = readTextLossy(url.appendingPathComponent(variablesPath))
        let citationsText = readTextLossy(url.appendingPathComponent(citationsFile))
        var loaded = parse(files: files, variablesYAML: variablesText, citationsYAML: citationsText)
        loaded.variablesPath = variablesPath
        loaded.warnings = warnings + loaded.warnings
        return loaded
    }

    /// Builds the manuscript from file contents (pure, for tests).
    public static func parse(files: [(String, String)], variablesYAML: String?, citationsYAML: String?) -> Loaded {
        var warnings: [String] = []
        var manuscript = Manuscript()
        var blocks: [Block] = []
        var figureLabels: [String: String] = [:]
        for (index, (name, text)) in files.enumerated() {
            let (yaml, body, error) = BlockMarkdown.splitFrontmatter(text)
            if let error { warnings.append("\(name): \(error).") }
            if index == 0, let yaml {
                readFrontmatter(yaml, into: &manuscript)
            }
            let parsed = BlockMarkdown.parse(body)
            blocks += parsed.blocks
            figureLabels.merge(parsed.figureLabels) { first, _ in first }
        }
        let variables = Variables.parse(variablesYAML ?? "", warnings: &warnings)
        let registry = CitationRegistry.parse(citationsYAML ?? "", warnings: &warnings)

        // Heading ids, for Section cross-references.
        var headingIndex = 0
        blocks = blocks.map { block in
            guard case .heading(var h) = block else { return block }
            headingIndex += 1
            h.id = "h\(headingIndex)"
            return .heading(h)
        }
        let numbering = Numbering(blocks: blocks)
        // Figures whose captions had no "Figure n." are known by their place.
        for (path, n) in numbering.figures {
            let label = "\(numbering.kinds[path]?.label ?? "Figure") \(n)"
            if figureLabels[label] == nil, !figureLabels.values.contains(path) { figureLabels[label] = path }
        }
        var sections: [String: String] = [:]
        for (id, number) in numbering.headings { sections[number] = id }
        let recognizer = Recognizer(citations: registry.citations, figures: figureLabels, sections: sections)
        manuscript.title = recognizer.recognize(manuscript.title)
        blocks = blocks.map { block in block.mappingInlines { recognizer.recognize($0) } }

        // The reference list: the paragraphs under the References heading,
        // once there are references from Bibliotheca to generate it from.
        if !registry.references.isEmpty {
            var out: [Block] = []
            var k = 0
            while k < blocks.count {
                let block = blocks[k]
                out.append(block)
                k += 1
                if case .heading(let h) = block, Numbering.isReferencesHeading(h.inlines.plainText { _ in "" }) {
                    while k < blocks.count, case .paragraph = blocks[k] { k += 1 }
                    out.append(.referenceList)
                }
            }
            blocks = out
        }
        manuscript.blocks = blocks
        return Loaded(manuscript: manuscript, variables: variables, registry: registry,
                      variablesPath: variablesFile, warnings: warnings)
    }

    static func readFrontmatter(_ yaml: YAMLNode, into m: inout Manuscript) {
        for pair in yaml.pairs {
            switch pair.key {
            case "title":
                m.title = InlineMarkdown.parse(pair.value.string ?? "").trimmed
            case settingsKey:
                let s = pair.value
                if let b = s["heading-numbers"]?.bool { m.settings.headingNumbers = b }
                if let n = s["word-limit"]?.int, n > 0 { m.settings.wordLimit = n }
                if let style = s["citation-style"]?.string.flatMap(CitationStyle.init(rawValue:)) {
                    m.settings.citationStyle = style
                }
            default:
                m.extraFrontmatter.append(pair)
            }
        }
    }

    // MARK: Writing

    /// Everything the workspace's text files should contain.
    public struct Rendered: Equatable {
        /// Markdown files by name.
        public var files: [String: String]
        public var variablesPath: String
        public var variablesYAML: String
        public var citationsYAML: String
    }

    /// The token text written to Markdown and shown to readers by default.
    public static func defaultText(_ t: Token, numbering: Numbering, headings: [String: Heading]) -> String {
        switch t {
        case .citation(let c):
            return c.text
        case .figureRef(let path):
            return numbering.figureLabel(path) ?? "Figure ??"
        case .sectionRef(let id):
            if let label = numbering.sectionLabel(id) { return label }
            if let h = headings[id] { return "\u{201C}" + h.inlines.plainText { _ in "" } + "\u{201D}" }
            return "Section ??"
        case .variable(let name):
            return "{{\(name)}}"
        case .footnote, .note:
            return ""
        }
    }

    public static func render(_ m: Manuscript, variables: [Variable], variablesPath: String = variablesFile,
                              referenceEntries: [ReferenceEntry]) -> Rendered {
        let numbering = Numbering(blocks: m.blocks)
        var headings: [String: Heading] = [:]
        for h in m.headings { headings[h.id] = h }
        var context = BlockMarkdown.WriteContext(
            numbering: numbering,
            tokenText: { defaultText($0, numbering: numbering, headings: headings) },
            referenceEntries: referenceEntries.map(\.entry))

        // Split at top-level headings.
        var preamble: [Block] = []
        var sections: [[Block]] = []
        for block in m.blocks {
            if case .heading(let h) = block, h.level == 1 {
                sections.append([block])
            } else if sections.isEmpty {
                preamble.append(block)
            } else {
                sections[sections.count - 1].append(block)
            }
        }
        var files: [String: String] = [:]
        let front = frontmatter(m, hasVariables: !variables.isEmpty, variablesPath: variablesPath,
                                tokenText: context.tokenText)
        let preambleText = BlockMarkdown.write(preamble, context: &context)
        let first = front + (preambleText.isEmpty ? "" : "\n" + preambleText)
        if sections.isEmpty {
            files[singleFile] = first
        } else {
            files[frontFile] = first
            let width = sections.count >= 99 ? 3 : 2
            for (k, section) in sections.enumerated() {
                var slug = ""
                if case .heading(let h)? = section.first {
                    slug = h.inlines.plainText { context.tokenText($0) }.slug()
                }
                if slug.isEmpty { slug = "section" }
                let number = String(k + 1)
                let name = String(repeating: "0", count: max(0, width - number.count)) + number + "-" + slug + ".md"
                files[name] = BlockMarkdown.write(section, context: &context)
            }
        }
        return Rendered(files: files, variablesPath: variablesPath,
                        variablesYAML: Variables.emit(variables),
                        citationsYAML: CitationRegistry.from(m, references: referenceEntries).emit())
    }

    static func frontmatter(_ m: Manuscript, hasVariables: Bool, variablesPath: String,
                            tokenText: @escaping (Token) -> String) -> String {
        var pairs: [YAMLPair] = []
        let title = InlineMarkdown.emit(m.title) { t in
            if case .variable(let name) = t { return "{{\(name)}}" }
            if case .footnote = t { return "" }
            if case .note = t { return "" }
            return InlineMarkdown.escapeText(tokenText(t))
        }
        pairs.append(YAMLPair("title", .scalar(title)))
        pairs += m.extraFrontmatter.filter { $0.key != "title" && $0.key != settingsKey }
        if hasVariables, !m.extraFrontmatter.contains(where: { $0.key == "mustache" }) {
            pairs.append(YAMLPair("mustache", .scalar(variablesPath)))
        }
        var settings: [YAMLPair] = [YAMLPair("heading-numbers", .flag(m.settings.headingNumbers))]
        if let limit = m.settings.wordLimit { settings.append(YAMLPair("word-limit", .num(limit))) }
        settings.append(YAMLPair("citation-style", .scalar(m.settings.citationStyle.rawValue)))
        pairs.append(YAMLPair(settingsKey, .mapping(settings)))
        return "---\n" + YAML.emit(.mapping(pairs)) + "---\n"
    }

    public struct SaveReport: Equatable {
        public var written: [String] = []
        public var removed: [String] = []
    }

    /// Writes what changed, and removes section files that no longer exist
    /// (only files named like section files are ever removed).
    @discardableResult
    public static func save(_ rendered: Rendered, to url: URL) throws -> SaveReport {
        var report = SaveReport()
        func write(_ name: String, _ text: String) throws {
            let fileURL = url.appendingPathComponent(name)
            if let existing = try? String(contentsOf: fileURL, encoding: .utf8), existing == text { return }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            report.written.append(name)
        }
        for name in rendered.files.keys.sorted() {
            try write(name, rendered.files[name] ?? "")
        }
        let variablesURL = url.appendingPathComponent(rendered.variablesPath)
        if rendered.variablesYAML != "{}\n" || fileExists(variablesURL) {
            try write(rendered.variablesPath, rendered.variablesYAML)
        }
        let citationsURL = url.appendingPathComponent(citationsFile)
        if rendered.citationsYAML != CitationRegistry().emit() || fileExists(citationsURL) {
            try write(citationsFile, rendered.citationsYAML)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where (sectionFile.matches(name) || name == singleFile) && rendered.files[name] == nil {
            try FileManager.default.removeItem(at: url.appendingPathComponent(name))
            report.removed.append(name)
        }
        return report
    }

    /// Makes a new workspace in an empty (or new) folder.
    public static func create(at url: URL, title: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var m = Manuscript()
        m.title = title.isEmpty ? [] : [.text(title, .plain)]
        let rendered = render(m, variables: [], referenceEntries: [])
        try save(rendered, to: url)
        let gitignore = url.appendingPathComponent(".gitignore")
        if !fileExists(gitignore) {
            try Data(".DS_Store\n".utf8).write(to: gitignore, options: .atomic)
        }
    }

    /// Modification dates of the files the app reads, to notice changes
    /// made elsewhere (a `git pull`, another editor).
    public static func signature(_ url: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where name.hasSuffix(".md") || name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)
            out[name] = attrs?[.modificationDate] as? Date ?? .distantPast
        }
        return out
    }
}

// MARK: - Mapping

extension Block {
    /// The same block with every inline run (captions included) passed
    /// through `f`.
    public func mappingInlines(_ f: ([Inline]) -> [Inline]) -> Block {
        switch self {
        case .heading(var h):
            h.inlines = f(h.inlines)
            return .heading(h)
        case .paragraph(let i): return .paragraph(f(i))
        case .quote(let i): return .quote(f(i))
        case .bullet(let i): return .bullet(f(i))
        case .numbered(let i): return .numbered(f(i))
        case .figure(var fig):
            fig.caption = f(fig.caption)
            return .figure(fig)
        case .referenceList: return .referenceList
        }
    }
}

extension Array where Element == Inline {
    /// Every token (footnote contents included) passed through `f`.
    public func mappingTokens(_ f: (Token) -> Token) -> [Inline] {
        map { inline in
            guard case .token(let t, let s) = inline else { return inline }
            if case .footnote(let inner) = t { return .token(f(.footnote(inner.mappingTokens(f))), s) }
            return .token(f(t), s)
        }
    }
}

extension Manuscript {
    /// The manuscript with every token passed through `f`.
    public func mappingTokens(_ f: (Token) -> Token) -> Manuscript {
        var m = self
        m.title = title.mappingTokens(f)
        m.blocks = blocks.map { $0.mappingInlines { $0.mappingTokens(f) } }
        return m
    }
}
