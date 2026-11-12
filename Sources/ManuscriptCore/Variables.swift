import Foundation

/// variables.yml: a flat YAML mapping of names to values, as pandoc-mustache
/// reads it (`{{name}}` in the text). Values that a YAML reader would take
/// for numbers, booleans or dates are quoted, so "7.40" stays "7.40".
public enum Variables {
    public static func parse(_ text: String, warnings: inout [String]) -> [Variable] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let root: YAMLNode
        do {
            root = try YAML.parse(text)
        } catch {
            warnings.append("The variables file isn't valid YAML (\(error)).")
            return []
        }
        var out: [Variable] = []
        var skipped: [String] = []
        for pair in root.pairs {
            switch pair.value {
            case .scalar(let s): out.append(Variable(name: pair.key, value: s))
            case .null: out.append(Variable(name: pair.key, value: ""))
            default: skipped.append(pair.key)
            }
        }
        if !skipped.isEmpty {
            warnings.append("Nested variables aren't supported and were skipped: \(skipped.joined(separator: ", ")).")
        }
        return out
    }

    public static func emit(_ variables: [Variable]) -> String {
        guard !variables.isEmpty else { return "{}\n" }
        return YAML.emit(.mapping(variables.map { YAMLPair($0.name, .scalar($0.value)) }), quoteTyped: true)
    }
}

// MARK: - Counting

/// Word counts, as the status bar and the outline show them.
public struct WordCounts: Equatable, Sendable {
    /// Everything a reader reads: title, text, captions, footnotes, and the
    /// reference list. Notes to self never count.
    public var total = 0
    /// The same without the reference list.
    public var withoutReferences = 0
    /// Per heading id: the words from that heading up to the next heading of
    /// the same or a higher level.
    public var sections: [String: Int] = [:]

    public init() {}

    /// `display` renders tokens (citations, cross-references, variables).
    public init(_ m: Manuscript, display: (Token) -> String, referenceEntries: [String]) {
        func words(_ inlines: [Inline]) -> Int {
            var n = WordCount.count(inlines.plainText(display))
            for t in inlines.allTokens {
                if case .footnote(let inner) = t { n += WordCount.count(inner.plainText(display)) }
            }
            return n
        }
        let referenceWords = referenceEntries.reduce(0) { $0 + WordCount.count(InlineMarkdown.parse($1).plainText { _ in "" }) }
        var perBlock: [Int] = []
        for block in m.blocks {
            switch block {
            case .referenceList: perBlock.append(referenceWords)
            case .figure(let f): perBlock.append(WordCount.count(f.kind.label) + 1 + words(f.caption))
            default: perBlock.append(words(block.inlines))
            }
        }
        let titleWords = words(m.title)
        total = titleWords + perBlock.reduce(0, +)
        var referenceSection = 0
        var open: [(id: String, level: Int, isReferences: Bool)] = []
        for (k, block) in m.blocks.enumerated() {
            if case .heading(let h) = block {
                while let last = open.last, last.level >= h.level { open.removeLast() }
                open.append((h.id, h.level, Numbering.isReferencesHeading(h.inlines.plainText { _ in "" })))
            }
            for o in open { sections[o.id, default: 0] += perBlock[k] }
            if open.contains(where: \.isReferences) { referenceSection += perBlock[k] }
        }
        withoutReferences = total - referenceSection
    }
}
