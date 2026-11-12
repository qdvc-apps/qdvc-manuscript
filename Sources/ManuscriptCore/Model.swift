import Foundation

// The manuscript as a tree of blocks and inlines: what the Markdown files
// hold (docs/FILE_FORMAT.md), independent of AppKit. The app turns it into
// an attributed string for editing and back again for saving.

/// Bold and italic, the only character formatting a manuscript has.
public struct InlineStyle: Hashable, Sendable {
    public var bold: Bool
    public var italic: Bool

    public init(bold: Bool = false, italic: Bool = false) {
        self.bold = bold
        self.italic = italic
    }

    public static let plain = InlineStyle()
}

/// An in-text citation of one or more QDVC Bibliotheca records, kept in the
/// Markdown exactly as it reads ("(Smith & Jones, 2025)"); citations.yml
/// remembers which records it stands for.
public struct Citation: Hashable, Sendable {
    /// Bibliotheca IDs, in the order cited.
    public var sources: [String]
    /// "Smith and Jones (2025)" rather than "(Smith & Jones, 2025)".
    public var narrative: Bool
    /// A page or other locator ("p. 12"), or "".
    public var locator: String
    /// The text as last written (used whenever the library isn't at hand).
    public var text: String

    public init(sources: [String], narrative: Bool = false, locator: String = "", text: String = "") {
        self.sources = sources
        self.narrative = narrative
        self.locator = locator
        self.text = text
    }

    /// Identity apart from the rendered text.
    public var key: CitationKey { CitationKey(sources: sources, narrative: narrative, locator: locator) }
}

public struct CitationKey: Hashable, Sendable {
    public var sources: [String]
    public var narrative: Bool
    public var locator: String
}

/// Something in the text that the app draws and keeps up to date.
public enum Token: Hashable, Sendable {
    /// A pandoc-mustache variable, `{{name}}`.
    case variable(String)
    /// An in-text citation.
    case citation(Citation)
    /// "Figure 3" / "Table 2": the target's path in the workspace.
    case figureRef(String)
    /// "Section 3.2": the target heading's id.
    case sectionRef(String)
    /// A footnote and its text, `[^1]`.
    case footnote([Inline])
    /// A note to self, `<!-- … -->`: never exported or counted.
    case note(String)
}

public enum Inline: Hashable, Sendable {
    case text(String, InlineStyle)
    case token(Token, InlineStyle)

    public var style: InlineStyle {
        switch self {
        case .text(_, let s), .token(_, let s): return s
        }
    }
}

public enum FigureKind: String, Hashable, Sendable, CaseIterable {
    case figure, table

    public var label: String { self == .figure ? "Figure" : "Table" }
    public var folder: String { self == .figure ? "figures" : "tables" }
}

/// A figure or a table, which for now is a picture (a PNG) with a caption.
public struct Figure: Hashable, Sendable {
    /// The image's path relative to the workspace ("figures/model.png"); it
    /// doubles as the figure's identity.
    public var path: String
    public var kind: FigureKind
    public var caption: [Inline]

    public init(path: String, kind: FigureKind, caption: [Inline] = []) {
        self.path = path
        self.kind = kind
        self.caption = caption
    }
}

public struct Heading: Hashable, Sendable {
    /// 1 to 4 (deeper Markdown headings are read as 4).
    public var level: Int
    public var inlines: [Inline]
    /// Not numbered, and skipped when counting (pandoc's `{-}`).
    public var unnumbered: Bool
    /// A working identity for Section cross-references; never stored.
    public var id: String

    public init(level: Int, inlines: [Inline], unnumbered: Bool = false, id: String = "") {
        self.level = level
        self.inlines = inlines
        self.unnumbered = unnumbered
        self.id = id
    }
}

public enum Block: Hashable, Sendable {
    case heading(Heading)
    case paragraph([Inline])
    case quote([Inline])
    case bullet([Inline])
    case numbered([Inline])
    case figure(Figure)
    /// The reference list, generated from the citations; it lives under the
    /// heading called "References".
    case referenceList

    public var inlines: [Inline] {
        switch self {
        case .heading(let h): return h.inlines
        case .paragraph(let i), .quote(let i), .bullet(let i), .numbered(let i): return i
        case .figure(let f): return f.caption
        case .referenceList: return []
        }
    }

    public var heading: Heading? {
        if case .heading(let h) = self { return h }
        return nil
    }
}

public enum CitationStyle: String, CaseIterable, Sendable {
    case apa7
    case acis

    public var label: String {
        switch self {
        case .apa7: return "APA 7th edition"
        case .acis: return "ACIS / AJIS"
        }
    }
}

/// Settings that belong to the manuscript (and so to every co-author): in
/// the frontmatter, under `qdvc-manuscript`.
public struct ManuscriptSettings: Equatable, Sendable {
    public var headingNumbers: Bool
    public var wordLimit: Int?
    public var citationStyle: CitationStyle

    public init(headingNumbers: Bool = true, wordLimit: Int? = nil, citationStyle: CitationStyle = .apa7) {
        self.headingNumbers = headingNumbers
        self.wordLimit = wordLimit
        self.citationStyle = citationStyle
    }
}

public struct Manuscript: Equatable, Sendable {
    public var title: [Inline]
    public var blocks: [Block]
    public var settings: ManuscriptSettings
    /// Frontmatter keys the app doesn't use (author, date…), kept as they were.
    public var extraFrontmatter: [YAMLPair]

    public init(title: [Inline] = [], blocks: [Block] = [], settings: ManuscriptSettings = ManuscriptSettings(),
                extraFrontmatter: [YAMLPair] = []) {
        self.title = title
        self.blocks = blocks
        self.settings = settings
        self.extraFrontmatter = extraFrontmatter
    }

    public var figures: [Figure] {
        blocks.compactMap { if case .figure(let f) = $0 { return f } else { return nil } }
    }

    public var headings: [Heading] { blocks.compactMap(\.heading) }
}

/// A pandoc-mustache variable.
public struct Variable: Hashable, Sendable, Identifiable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var id: String { name }

    /// Letters, digits and underscores, not starting with a digit.
    public static func isValidName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }
    }

    /// A valid name made from any text ("Sample size" → "sample_size").
    public static func suggestedName(_ text: String, avoiding taken: Set<String> = []) -> String {
        var out = ""
        var lastUnderscore = true
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastUnderscore = false
            } else if !lastUnderscore {
                out += "_"
                lastUnderscore = true
            }
            if out.count >= 30 { break }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty { out = "variable" }
        if let first = out.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { out = "v_" + out }
        var name = out
        var n = 2
        while taken.contains(name) {
            name = "\(out)_\(n)"
            n += 1
        }
        return name
    }
}

// MARK: - Plain text

extension Array where Element == Inline {
    /// The text as a reader sees it, with tokens as `display` renders them.
    public func plainText(_ display: (Token) -> String) -> String {
        var out = ""
        for inline in self {
            switch inline {
            case .text(let t, _): out += t
            case .token(let t, _): out += display(t)
            }
        }
        return out
    }

    /// Adjacent text runs with the same style merged; empty ones dropped.
    public var coalesced: [Inline] {
        var out: [Inline] = []
        for inline in self {
            if case .text(let t, let s) = inline {
                if t.isEmpty { continue }
                if case .text(let pt, let ps)? = out.last, ps == s {
                    out[out.count - 1] = .text(pt + t, s)
                    continue
                }
            }
            out.append(inline)
        }
        return out
    }

    /// Leading and trailing whitespace removed from the outer text runs.
    public var trimmed: [Inline] {
        var out = coalesced
        while case .text(let t, let s)? = out.first {
            let tt = String(t.drop(while: { $0.isWhitespace }))
            if tt.isEmpty { out.removeFirst() } else { out[0] = .text(tt, s); break }
        }
        while case .text(let t, let s)? = out.last {
            var tt = t
            while let last = tt.last, last.isWhitespace { tt.removeLast() }
            if tt.isEmpty { out.removeLast() } else { out[out.count - 1] = .text(tt, s); break }
        }
        return out
    }

    /// Every token, including those inside footnotes.
    public var allTokens: [Token] {
        var out: [Token] = []
        for inline in self {
            if case .token(let t, _) = inline {
                out.append(t)
                if case .footnote(let inner) = t { out += inner.allTokens }
            }
        }
        return out
    }
}

extension Manuscript {
    /// Every token in the manuscript, in reading order (title first).
    public var allTokens: [Token] {
        var out = title.allTokens
        for block in blocks { out += block.inlines.allTokens }
        return out
    }

    /// Every citation, in reading order.
    public var citations: [Citation] {
        allTokens.compactMap { if case .citation(let c) = $0 { return c } else { return nil } }
    }

    /// Bibliotheca IDs cited anywhere, in order of first citation.
    public var citedSources: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in citations {
            for s in c.sources where !seen.contains(s) {
                seen.insert(s)
                out.append(s)
            }
        }
        return out
    }
}
