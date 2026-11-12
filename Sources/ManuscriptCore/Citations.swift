import Foundation

// Citations are kept in the Markdown as they read; citations.yml maps each
// one to QDVC Bibliotheca records and caches the reference list, so the
// manuscript stays readable (and complete) without the library.

/// One entry of the reference list, as inline Markdown.
public struct ReferenceEntry: Equatable, Hashable, Sendable {
    public var source: String
    public var entry: String

    public init(source: String, entry: String) {
        self.source = source
        self.entry = entry
    }
}

/// citations.yml.
public struct CitationRegistry: Equatable, Sendable {
    public var citations: [Citation] = []
    public var references: [ReferenceEntry] = []

    public init(citations: [Citation] = [], references: [ReferenceEntry] = []) {
        self.citations = citations
        self.references = references
    }

    public static func parse(_ text: String, warnings: inout [String]) -> CitationRegistry {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return CitationRegistry() }
        let root: YAMLNode
        do {
            root = try YAML.parse(text)
        } catch {
            warnings.append("citations.yml isn't valid YAML (\(error)); citations are shown as plain text.")
            return CitationRegistry()
        }
        var registry = CitationRegistry()
        for item in root["citations"]?.items ?? [] {
            guard let text = item["text"]?.string, !text.isEmpty else { continue }
            let sources = item["sources"]?.strings ?? []
            guard !sources.isEmpty else { continue }
            registry.citations.append(Citation(sources: sources, narrative: item["narrative"]?.bool ?? false,
                                               locator: item["locator"]?.string ?? "", text: text))
        }
        for item in root["references"]?.items ?? [] {
            guard let source = item["source"]?.string, let entry = item["entry"]?.string else { continue }
            registry.references.append(ReferenceEntry(source: source, entry: entry))
        }
        return registry
    }

    /// The registry for a manuscript: each distinct citation once, sorted by
    /// text so the file diffs calmly.
    public static func from(_ m: Manuscript, references: [ReferenceEntry]) -> CitationRegistry {
        var seen = Set<String>()
        var citations: [Citation] = []
        for c in m.citations where !c.text.isEmpty && !seen.contains(c.text) {
            seen.insert(c.text)
            citations.append(c)
        }
        citations.sort { $0.text.lowercased() == $1.text.lowercased() ? $0.text < $1.text : $0.text.lowercased() < $1.text.lowercased() }
        return CitationRegistry(citations: citations, references: references)
    }

    public func emit() -> String {
        let citationNodes: [YAMLNode] = citations.map { c in
            var pairs: [(String, YAMLNode)] = [("text", .str(c.text)), ("sources", .list(c.sources))]
            if c.narrative { pairs.append(("narrative", .flag(true))) }
            if !c.locator.isEmpty { pairs.append(("locator", .str(c.locator))) }
            return .map(pairs)
        }
        let referenceNodes: [YAMLNode] = references.map { .map([("source", .str($0.source)), ("entry", .str($0.entry))]) }
        return YAML.emit(.map([("citations", .sequence(citationNodes)), ("references", .sequence(referenceNodes))]))
    }

    /// The cached reference entry for a source.
    public func entry(for source: String) -> String? {
        references.first { $0.source == source }?.entry
    }
}

// MARK: - A QDVC Bibliotheca library

public struct LibraryRecord: Sendable, Identifiable, Hashable {
    public var id: String
    public var entry: BibEntry
    public var authors: String
    public var year: String
    public var title: String
    public var outlet: String
    var haystack: String

    public static func == (a: LibraryRecord, b: LibraryRecord) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(id: String, entry: BibEntry) {
        self.id = id
        self.entry = entry
        authors = Builtin.clean(entry.first("author", "editor"))
        year = Builtin.bareYear(entry)
        title = Builtin.clean(entry["title"])
        outlet = Builtin.clean(entry.first("journal", "journaltitle", "booktitle"))
        haystack = [id, authors, year, title, outlet].joined(separator: " ").lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
    }

    /// "Smith & Jones (2025)": for lists.
    public var shortLabel: String {
        let names = Builtin.authorTokens(entry.first("author", "editor")).map(\.surname)
        let who: String
        switch names.count {
        case 0: who = title.pyWords.prefix(3).joined(separator: " ")
        case 1: who = names[0]
        case 2: who = "\(names[0]) & \(names[1])"
        default: who = "\(names[0]) et al."
        }
        return "\(who) (\(year.isEmpty ? "n.d." : year))"
    }
}

/// The records of a QDVC Bibliotheca workspace (read only: the app never
/// writes to the library).
public struct BibliothecaLibrary: Sendable {
    public var root: URL?
    public var records: [String: LibraryRecord] = [:]
    /// Sorted by author, year, title.
    public var ordered: [LibraryRecord] = []

    public init() {}

    public init(records list: [LibraryRecord], root: URL? = nil) {
        self.root = root
        for r in list { records[r.id] = r }
        ordered = list.sorted { a, b in
            let ka = a.authors.lowercased(), kb = b.authors.lowercased()
            if ka != kb { return ka < kb }
            if a.year != b.year { return a.year < b.year }
            return a.title.lowercased() < b.title.lowercased()
        }
    }

    public var isEmpty: Bool { records.isEmpty }

    /// A folder is a library if it has `bibtex/` (docs/FILE_FORMAT.md of
    /// QDVC Bibliotheca).
    public static func isLibrary(_ url: URL) -> Bool {
        directoryExists(url.appendingPathComponent("bibtex"))
    }

    /// Reads every `bibtex/<shard>/<id>.bib`.
    public static func load(_ url: URL) -> BibliothecaLibrary {
        let bibtex = url.appendingPathComponent("bibtex", isDirectory: true)
        var list: [LibraryRecord] = []
        let fm = FileManager.default
        let shards = (try? fm.contentsOfDirectory(atPath: bibtex.path)) ?? []
        for shard in shards where !shard.hasPrefix(".") {
            let dir = bibtex.appendingPathComponent(shard, isDirectory: true)
            guard directoryExists(dir) else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".bib") && !name.hasPrefix(".") {
                guard let entry = BibTeX.parse(fileAt: dir.appendingPathComponent(name)) else { continue }
                list.append(LibraryRecord(id: String(name.dropLast(4)), entry: entry))
            }
        }
        return BibliothecaLibrary(records: list, root: url)
    }

    /// Records matching every word of `query` (author, year, title, outlet
    /// or ID), in library order.
    public func search(_ query: String, limit: Int = 200) -> [LibraryRecord] {
        let words = query.lowercased().folding(options: [.diacriticInsensitive], locale: nil).pyWords
        guard !words.isEmpty else { return Array(ordered.prefix(limit)) }
        var out: [LibraryRecord] = []
        for r in ordered where words.allSatisfy({ r.haystack.contains($0) }) {
            out.append(r)
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Formatting

/// Writes in-text citations and the reference list in the manuscript's
/// style, from the library where it has the records and from what was last
/// written otherwise.
public struct CitationFormatter: Sendable {
    public var style: CitationStyle
    public var library: BibliothecaLibrary
    /// Source → year letter ("a", "b") among the cited sources.
    public var disambiguators: [String: String] = [:]

    public init(style: CitationStyle, library: BibliothecaLibrary, cited: [String]) {
        self.style = style
        self.library = library
        disambiguators = Self.disambiguate(cited.compactMap { library.records[$0] })
    }

    /// Same authors and year → "a", "b"… in title order (APA 7 §8.19).
    static func disambiguate(_ records: [LibraryRecord]) -> [String: String] {
        struct Key: Hashable {
            var surnames: [String]
            var year: String
        }
        var groups: [Key: [LibraryRecord]] = [:]
        for r in records {
            let key = Key(surnames: Builtin.authorTokens(r.entry.first("author", "editor")).map { $0.surname.lowercased() },
                          year: r.year)
            groups[key, default: []].append(r)
        }
        var out: [String: String] = [:]
        for members in groups.values where members.count > 1 {
            let sorted = members.sorted { a, b in
                a.title.lowercased() != b.title.lowercased() ? a.title.lowercased() < b.title.lowercased() : a.id < b.id
            }
            for (k, r) in sorted.enumerated() { out[r.id] = ACIS.letter(k) }
        }
        return out
    }

    /// Whether every source is in the library.
    public func canFormat(_ c: Citation) -> Bool {
        !c.sources.isEmpty && c.sources.allSatisfy { library.records[$0] != nil }
    }

    /// The citation's text: freshly formatted, or as last written.
    public func text(for c: Citation) -> String {
        guard canFormat(c) else { return c.text.isEmpty ? "(?)" : c.text }
        let records = c.sources.compactMap { library.records[$0] }
        switch style {
        case .apa7: return apaText(records, c)
        case .acis: return acisText(records, c)
        }
    }

    func label(_ r: LibraryRecord, ampersand: Bool) -> String {
        let names = Builtin.authorTokens(r.entry.first("author", "editor")).map(\.surname)
        switch names.count {
        case 0:
            let words = r.title.pyWords
            return words.isEmpty ? r.id : words.prefix(4).joined(separator: " ")
        case 1: return names[0]
        case 2: return ampersand ? "\(names[0]) & \(names[1])" : "\(names[0]) and \(names[1])"
        default: return "\(names[0]) et al."
        }
    }

    func stamp(_ r: LibraryRecord) -> String {
        let d = disambiguators[r.id] ?? ""
        return r.year.isEmpty ? (d.isEmpty ? "n.d." : "n.d.-\(d)") : r.year + d
    }

    func apaText(_ records: [LibraryRecord], _ c: Citation) -> String {
        let locator = c.locator.trimmingCharacters(in: .whitespaces)
        if c.narrative {
            let parts = records.enumerated().map { k, r -> String in
                let loc = (k == records.count - 1 && !locator.isEmpty) ? ", \(locator)" : ""
                return "\(label(r, ampersand: false)) (\(stamp(r))\(loc))"
            }
            return Self.joinNarrative(parts)
        }
        let sorted = records.count > 1
            ? records.sorted { label($0, ampersand: true).lowercased() < label($1, ampersand: true).lowercased() }
            : records
        let inner = sorted.map { "\(label($0, ampersand: true)), \(stamp($0))" }.joined(separator: "; ")
        return "(\(inner)\(locator.isEmpty ? "" : ", \(locator)"))"
    }

    func acisText(_ records: [LibraryRecord], _ c: Citation) -> String {
        let locator = c.locator.trimmingCharacters(in: .whitespaces)
        if c.narrative {
            let parts = records.enumerated().map { k, r -> String in
                let loc = (k == records.count - 1 && !locator.isEmpty) ? ", \(locator)" : ""
                return "\(label(r, ampersand: false)) (\(stamp(r))\(loc))"
            }
            return Self.joinNarrative(parts)
        }
        let inner = records.map { "\(label($0, ampersand: false)) \(stamp($0))" }.joined(separator: "; ")
        return "(\(inner)\(locator.isEmpty ? "" : ", \(locator)"))"
    }

    static func joinNarrative(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        }
    }

    /// The reference list for `sources`, alphabetical, as inline Markdown;
    /// sources missing from the library keep their cached entry.
    public func referenceEntries(for sources: [String], cached: CitationRegistry) -> [ReferenceEntry] {
        var entries: [ReferenceEntry] = []
        var sortKeys: [String: String] = [:]
        for source in Set(sources) {
            if let r = library.records[source] {
                let markup: String
                switch style {
                case .apa7: markup = APA7.markup(r.entry, disambiguator: disambiguators[source] ?? "")
                case .acis: markup = ACIS.markup(r.entry, disambiguator: disambiguators[source] ?? "")
                }
                entries.append(ReferenceEntry(source: source, entry: Self.markdown(fromMarkup: markup)))
                let first = Builtin.authorTokens(r.entry.first("author", "editor")).first?.surname ?? r.title
                sortKeys[source] = "\(first.lowercased())\u{1}\(r.authors.lowercased())\u{1}\(stamp(r))\u{1}\(r.title.lowercased())"
            } else if let cachedEntry = cached.entry(for: source) {
                entries.append(ReferenceEntry(source: source, entry: cachedEntry))
                sortKeys[source] = InlineMarkdown.parse(cachedEntry).plainText { _ in "" }.lowercased()
            }
        }
        return entries.sorted { (sortKeys[$0.source] ?? "") < (sortKeys[$1.source] ?? "") }
    }

    /// Bibliotheca's formatter markup (`<i>`, `<b>`, entities) as inline
    /// Markdown.
    public static func markdown(fromMarkup markup: String) -> String {
        InlineMarkdown.emit(inlines(fromMarkup: markup)) { _ in "" }
    }

    public static func inlines(fromMarkup markup: String) -> [Inline] {
        var out: [Inline] = []
        var style = InlineStyle()
        var buffer = ""
        var i = markup.startIndex
        func flush() {
            if !buffer.isEmpty { out.append(.text(Builtin.markupToPlain(buffer), style)) }
            buffer = ""
        }
        while i < markup.endIndex {
            if markup[i] == "<", let close = markup[i...].firstIndex(of: ">") {
                let tag = markup[markup.index(after: i)..<close].lowercased()
                flush()
                switch tag {
                case "i", "em": style.italic = true
                case "/i", "/em": style.italic = false
                case "b", "strong": style.bold = true
                case "/b", "/strong": style.bold = false
                default: break
                }
                i = markup.index(after: close)
                continue
            }
            buffer.append(markup[i])
            i = markup.index(after: i)
        }
        flush()
        return out.coalesced
    }
}
