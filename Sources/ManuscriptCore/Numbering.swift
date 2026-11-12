import Foundation

/// Heading, figure and table numbers, worked out from the order of things
/// (never stored apart from the text that shows them).
public struct Numbering: Equatable, Sendable {
    /// Heading id → "3.1" (numbered headings only).
    public var headings: [String: String] = [:]
    /// Figure path → its number among figures (or among tables).
    public var figures: [String: Int] = [:]
    /// Figure path → kind.
    public var kinds: [String: FigureKind] = [:]

    public init() {}

    public init(blocks: [Block]) {
        var counters = [0, 0, 0, 0, 0, 0, 0]
        var figureCount = 0
        var tableCount = 0
        for block in blocks {
            switch block {
            case .heading(let h):
                guard !Numbering.isUnnumbered(h) else { continue }
                let level = max(1, min(h.level, 6))
                counters[level] += 1
                for deeper in (level + 1)..<counters.count { counters[deeper] = 0 }
                headings[h.id] = (1...level).map { String(counters[$0]) }.joined(separator: ".")
            case .figure(let f):
                if f.kind == .figure {
                    figureCount += 1
                    figures[f.path] = figureCount
                } else {
                    tableCount += 1
                    figures[f.path] = tableCount
                }
                kinds[f.path] = f.kind
            default:
                break
            }
        }
    }

    /// "1." for a top-level heading, "3.1" below it.
    public static func headingLabel(_ number: String) -> String {
        number.contains(".") ? number : number + "."
    }

    /// The text of a cross-reference to a figure or table.
    public func figureLabel(_ path: String) -> String? {
        guard let n = figures[path], let kind = kinds[path] else { return nil }
        return "\(kind.label) \(n)"
    }

    public func sectionLabel(_ headingID: String) -> String? {
        headings[headingID].map { "Section \($0)" }
    }

    /// Headings that aren't numbered: marked `{-}`, or with a title that
    /// never is (References, Abstract, Appendix…).
    public static func isUnnumbered(_ h: Heading) -> Bool {
        h.unnumbered || isUnnumberedByDefault(h.inlines.plainText { _ in "" })
    }

    public static func isUnnumberedByDefault(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        let names: Set<String> = ["references", "reference list", "bibliography", "abstract", "acknowledgements",
                                  "acknowledgments", "acknowledgement", "acknowledgment", "keywords", "works cited",
                                  "literature cited", "notes", "endnotes"]
        return names.contains(t) || t.hasPrefix("appendix") || t.hasPrefix("appendices")
    }

    /// The heading that holds the reference list.
    public static func isReferencesHeading(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return ["references", "reference list", "bibliography", "works cited", "literature cited"].contains(t)
    }
}

/// Finds citations and cross-references in text read from Markdown, where
/// they are plain words ("(Smith & Jones, 2025)", "Figure 3", "Section
/// 3.2"), and turns them back into tokens.
public struct Recognizer {
    /// Citation texts, longest first, so "(Smith, 2020; Lee, 2021)" wins
    /// over "(Smith, 2020)".
    var citations: [(text: String, citation: Citation)]
    /// "Figure 3" / "Table 2" as last written → figure path.
    var figures: [String: String]
    /// "3.2" → heading id.
    var sections: [String: String]

    static let xref = Rx("\\b(Figure|Table|Section)[ \\u00A0]+(\\d+(?:\\.\\d+)*)\\b")

    public init(citations: [Citation], figures: [String: String], sections: [String: String]) {
        self.citations = citations.filter { !$0.text.isEmpty }.map { (text: $0.text, citation: $0) }
            .sorted { $0.text.count > $1.text.count }
        self.figures = figures
        self.sections = sections
    }

    public var isEmpty: Bool { citations.isEmpty && figures.isEmpty && sections.isEmpty }

    public func recognize(_ inlines: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for inline in inlines {
            switch inline {
            case .text(let t, let s):
                out += recognize(text: t, style: s)
            case .token(.footnote(let inner), let s):
                out.append(.token(.footnote(recognize(inner)), s))
            case .token:
                out.append(inline)
            }
        }
        return out.coalesced
    }

    func recognize(text: String, style: InlineStyle) -> [Inline] {
        guard !isEmpty, !text.isEmpty else { return [.text(text, style)] }
        var found: [(range: Range<String.Index>, token: Token)] = []
        func overlaps(_ r: Range<String.Index>) -> Bool {
            found.contains { $0.range.overlaps(r) }
        }
        for (citationText, citation) in citations {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let r = text.range(of: citationText, range: searchStart..<text.endIndex) {
                if !overlaps(r) { found.append((r, .citation(citation))) }
                searchStart = r.upperBound
            }
        }
        for m in Recognizer.xref.allMatches(text) {
            guard let r = Range(m.range, in: text),
                  let word = Recognizer.xref.group(m, 1, in: text),
                  let number = Recognizer.xref.group(m, 2, in: text), !overlaps(r) else { continue }
            if word == "Section" {
                if let id = sections[number] { found.append((r, .sectionRef(id))) }
            } else if !number.contains("."), let path = figures["\(word) \(number)"] {
                found.append((r, .figureRef(path)))
            }
        }
        guard !found.isEmpty else { return [.text(text, style)] }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out: [Inline] = []
        var cursor = text.startIndex
        for f in found {
            if cursor < f.range.lowerBound { out.append(.text(String(text[cursor..<f.range.lowerBound]), style)) }
            out.append(.token(f.token, style))
            cursor = f.range.upperBound
        }
        if cursor < text.endIndex { out.append(.text(String(text[cursor...]), style)) }
        return out
    }
}
