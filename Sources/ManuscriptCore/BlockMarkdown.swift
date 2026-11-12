import Foundation

/// Block-level Markdown: frontmatter, headings, paragraphs (one sentence per
/// line), block quotes, lists, figures and footnote definitions
/// (docs/FILE_FORMAT.md §Markdown).
public enum BlockMarkdown {
    // MARK: Frontmatter

    /// Splits "---\n<yaml>\n---\n<body>". The YAML is nil when absent; a
    /// malformed block is reported and treated as absent.
    public static func splitFrontmatter(_ text: String) -> (yaml: YAMLNode?, body: String, error: String?) {
        let t = text.normalisedNewlines
        guard t.hasPrefix("---\n") else { return (nil, t, nil) }
        let lines = t.components(separatedBy: "\n")
        var end: Int?
        for i in 1..<lines.count where lines[i] == "---" || lines[i] == "..." {
            end = i
            break
        }
        guard let end else { return (nil, t, nil) }
        let yamlText = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        do {
            return (try YAML.parse(yamlText), body, nil)
        } catch {
            return (nil, body, "the frontmatter isn't valid YAML (\(error))")
        }
    }

    // MARK: Parsing

    /// What one file holds, before citations and cross-references are
    /// recognised.
    public struct Parsed {
        public var blocks: [Block] = []
        /// "Figure 3" / "Table 2" as written in captions → figure path.
        public var figureLabels: [String: String] = [:]
    }

    static let atxHeading = Rx("^ {0,3}(#{1,6})(?:[ \\t]+(.*?))?[ \\t]*$")
    static let bulletItem = Rx("^( {0,3})([-*+])[ \\t]+(.*)$")
    static let orderedItem = Rx("^( {0,3})(\\d{1,9})[.)][ \\t]+(.*)$")
    static let footnoteDefinition = Rx("^ {0,3}\\[\\^([^\\]\\s]+)\\]:[ \\t]?(.*)$")
    static let image = Rx("^!\\[((?:\\\\.|[^\\]\\\\])*)\\]\\(\\s*<?([^)>]+?)>?\\s*(?:\"[^\"]*\")?\\s*\\)\\s*(\\{[^}]*\\})?$")
    static let captionLabel = Rx("^(Figure|Fig\\.|Table)[ \\u00A0]+(\\d+)[.:]?\\s*")
    static let headingAttributes = Rx("\\s*\\{([^}]*)\\}\\s*$")
    static let thematicBreak = Rx("^ {0,3}((\\*[ \\t]*){3,}|(-[ \\t]*){3,}|(_[ \\t]*){3,})$")
    static let setextUnderline = Rx("^ {0,3}(=+|-+)[ \\t]*$")

    public static func parse(_ body: String) -> Parsed {
        var lines = body.normalisedNewlines.components(separatedBy: "\n")
        let footnotes = extractFootnotes(&lines)
        var parsed = Parsed()
        var i = 0

        func isBlank(_ l: String) -> Bool { l.trimmingCharacters(in: .whitespaces).isEmpty }
        func startsBlock(_ l: String) -> Bool {
            atxHeading.matches(l) || l.trimmingCharacters(in: .whitespaces).hasPrefix(">")
                || bulletItem.matches(l) || orderedItem.matches(l) || thematicBreak.matches(l)
        }
        func inline(_ text: String) -> [Inline] {
            InlineMarkdown.parse(text, footnotes: footnotes).trimmed
        }

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }
            // Headings.
            if let m = atxHeading.firstMatch(line) {
                let hashes = atxHeading.group(m, 1, in: line) ?? "#"
                var text = atxHeading.group(m, 2, in: line) ?? ""
                // A closing run of #s.
                if let r = text.range(of: "[ \\t]+#+$", options: .regularExpression) { text.removeSubrange(r) }
                if text.allSatisfy({ $0 == "#" }) { text = "" }
                var unnumbered = false
                if let am = headingAttributes.firstMatch(text), let attrs = headingAttributes.group(am, 1, in: text),
                   let r = Range(am.range, in: text) {
                    let parts = attrs.pyWords
                    unnumbered = parts.contains("-") || parts.contains(".unnumbered")
                    text.removeSubrange(r)
                }
                parsed.blocks.append(.heading(Heading(level: min(hashes.count, 4), inlines: inline(text),
                                                      unnumbered: unnumbered)))
                i += 1
                continue
            }
            if thematicBreak.matches(line) {
                i += 1
                continue
            }
            // Block quotes: each paragraph inside becomes a quote block.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var paragraph: [String] = []
                func flushQuote() {
                    let text = paragraph.joined(separator: " ")
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { parsed.blocks.append(.quote(inline(text))) }
                    paragraph = []
                }
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var content = String(t.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        // Nested quote markers are flattened.
                        while content.hasPrefix(">") {
                            content.removeFirst()
                            if content.hasPrefix(" ") { content.removeFirst() }
                        }
                        if content.trimmingCharacters(in: .whitespaces).isEmpty {
                            flushQuote()
                        } else {
                            paragraph.append(content.trimmingCharacters(in: .whitespaces))
                        }
                        i += 1
                    } else if !isBlank(l), !paragraph.isEmpty, !startsBlock(l) {
                        paragraph.append(t)   // lazy continuation
                        i += 1
                    } else {
                        break
                    }
                }
                flushQuote()
                continue
            }
            // Lists.
            if bulletItem.matches(line) || orderedItem.matches(line) {
                while i < lines.count {
                    let l = lines[i]
                    let ordered: Bool
                    let first: String
                    if let m = bulletItem.firstMatch(l) {
                        ordered = false
                        first = bulletItem.group(m, 3, in: l) ?? ""
                    } else if let m = orderedItem.firstMatch(l) {
                        ordered = true
                        first = orderedItem.group(m, 3, in: l) ?? ""
                    } else {
                        break
                    }
                    var itemLines = [first]
                    i += 1
                    while i < lines.count {
                        let next = lines[i]
                        if isBlank(next) {
                            // A blank line continues the item only if indented text follows.
                            var j = i + 1
                            while j < lines.count, isBlank(lines[j]) { j += 1 }
                            if j < lines.count, lines[j].hasPrefix("  "), !bulletItem.matches(lines[j]),
                               !orderedItem.matches(lines[j]) {
                                i = j
                                continue
                            }
                            break
                        }
                        if bulletItem.matches(next) || orderedItem.matches(next) || atxHeading.matches(next) { break }
                        if next.trimmingCharacters(in: .whitespaces).hasPrefix(">") && !next.hasPrefix("  ") { break }
                        itemLines.append(next.trimmingCharacters(in: .whitespaces))
                        i += 1
                    }
                    let content = inline(itemLines.joined(separator: " "))
                    parsed.blocks.append(ordered ? .numbered(content) : .bullet(content))
                    // A blank line followed by another item keeps the list going.
                    var j = i
                    while j < lines.count, isBlank(lines[j]) { j += 1 }
                    if j < lines.count, bulletItem.matches(lines[j]) || orderedItem.matches(lines[j]) {
                        i = j
                    } else {
                        break
                    }
                }
                continue
            }
            // A note on lines of its own.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("<!--"), !line.contains("-->") {
                var text = line.trimmingCharacters(in: .whitespaces)
                i += 1
                while i < lines.count {
                    text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if text.contains("-->") { break }
                }
                parsed.blocks.append(.paragraph(inline(text)))
                continue
            }
            // Fenced code: kept as plain paragraphs.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = String(line.prefix(3))
                var text: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix(fence) {
                    text.append(lines[i])
                    i += 1
                }
                i += 1
                let joined = text.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty { parsed.blocks.append(.paragraph([.text(joined, .plain)])) }
                continue
            }
            // A paragraph (or a setext heading).
            var paragraph: [String] = [line.trimmingCharacters(in: .whitespaces)]
            i += 1
            var setextLevel: Int?
            while i < lines.count {
                let l = lines[i]
                if isBlank(l) { break }
                if paragraph.count == 1, let m = setextUnderline.firstMatch(l) {
                    setextLevel = (setextUnderline.group(m, 1, in: l) ?? "=").hasPrefix("=") ? 1 : 2
                    i += 1
                    break
                }
                if atxHeading.matches(l) || l.trimmingCharacters(in: .whitespaces).hasPrefix(">") { break }
                if bulletItem.matches(l) || orderedItem.matches(l) { break }
                paragraph.append(l.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            let text = paragraph.map(stripHardBreak).joined(separator: " ")
            if let level = setextLevel {
                parsed.blocks.append(.heading(Heading(level: level, inlines: inline(text))))
            } else if let figure = figure(text, footnotes: footnotes, labels: &parsed.figureLabels) {
                parsed.blocks.append(.figure(figure))
            } else {
                parsed.blocks.append(.paragraph(inline(text)))
            }
        }
        return parsed
    }

    static func stripHardBreak(_ line: String) -> String {
        var l = line
        if l.hasSuffix("\\") { l.removeLast() }
        while l.hasSuffix(" ") { l.removeLast() }
        return l
    }

    /// Removes footnote definitions (and their indented continuation lines)
    /// and returns their parsed contents by label.
    static func extractFootnotes(_ lines: inout [String]) -> [String: [Inline]] {
        var out: [String: [Inline]] = [:]
        var kept: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let m = footnoteDefinition.firstMatch(line), let label = footnoteDefinition.group(m, 1, in: line) else {
                kept.append(line)
                i += 1
                continue
            }
            var text = [footnoteDefinition.group(m, 2, in: line) ?? ""]
            i += 1
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty {
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count, lines[j].hasPrefix("    ") || lines[j].hasPrefix("\t") {
                        i = j
                        continue
                    }
                    break
                }
                if footnoteDefinition.matches(l) { break }
                if !(l.hasPrefix(" ") || l.hasPrefix("\t")) && atxHeading.matches(l) { break }
                text.append(l.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            out[label] = InlineMarkdown.parse(text.joined(separator: " ")).trimmed
            kept.append("")
        }
        lines = kept
        return out
    }

    /// A paragraph that is just an image: a figure or table.
    static func figure(_ text: String, footnotes: [String: [Inline]], labels: inout [String: String]) -> Figure? {
        guard let m = image.firstMatch(text), let alt = image.group(m, 1, in: text),
              let rawPath = image.group(m, 2, in: text) else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespaces).removingPercentEncoding ?? rawPath
        var kind: FigureKind = path.lowercased().hasPrefix("tables/") ? .table : .figure
        var caption = alt
        if let lm = captionLabel.firstMatch(alt), let word = captionLabel.group(lm, 1, in: alt),
           let number = captionLabel.group(lm, 2, in: alt), let r = Range(lm.range, in: alt) {
            kind = word == "Table" ? .table : .figure
            caption.removeSubrange(r)
            labels["\(kind.label) \(number)"] = path
        }
        return Figure(path: path, kind: kind, caption: InlineMarkdown.parse(caption, footnotes: footnotes).trimmed)
    }

    // MARK: Writing

    /// What writing needs to know about the manuscript as a whole.
    public struct WriteContext {
        public var numbering: Numbering
        /// A token's text as it reads (citations, cross-references).
        public var tokenText: (Token) -> String
        /// The reference list's entries, as inline Markdown.
        public var referenceEntries: [String]
        /// Footnotes are numbered through the whole manuscript.
        public var footnoteCounter = 0

        public init(numbering: Numbering, tokenText: @escaping (Token) -> String, referenceEntries: [String]) {
            self.numbering = numbering
            self.tokenText = tokenText
            self.referenceEntries = referenceEntries
        }
    }

    /// The Markdown for a run of blocks (one file's body), footnote
    /// definitions at the end.
    public static func write(_ blocks: [Block], context: inout WriteContext) -> String {
        var out: [String] = []
        var footnotes: [(Int, [Inline])] = []
        var previous: Block?
        var number = 0

        func tokenMarkdown(_ t: Token) -> String {
            switch t {
            case .variable(let name):
                return "{{\(name)}}"
            case .footnote(let inner):
                context.footnoteCounter += 1
                footnotes.append((context.footnoteCounter, inner))
                return "[^\(context.footnoteCounter)]"
            case .note(let text):
                let clean = text.replacingOccurrences(of: "-->", with: "—>").replacingOccurrences(of: "\n", with: " ")
                return "<!-- \(clean) -->"
            case .citation, .figureRef, .sectionRef:
                return InlineMarkdown.escapeText(context.tokenText(t))
            }
        }

        for block in blocks {
            let tight: Bool
            switch (previous, block) {
            case (.bullet?, .bullet), (.numbered?, .numbered): tight = true
            default: tight = false
            }
            if !out.isEmpty && !tight { out.append("") }
            if case .numbered = block {
                if case .numbered? = previous { number += 1 } else { number = 1 }
            }
            switch block {
            case .heading(let h):
                var line = String(repeating: "#", count: max(1, min(h.level, 6))) + " "
                    + escapeLineStart(InlineMarkdown.emit(h.inlines, token: tokenMarkdown), allowHash: true)
                if h.unnumbered && !Numbering.isUnnumberedByDefault(h.inlines.plainText { _ in "" }) { line += " {-}" }
                out.append(line)
            case .paragraph(let inlines):
                out += sentenceLines(inlines, token: tokenMarkdown)
            case .quote(let inlines):
                out += sentenceLines(inlines, token: tokenMarkdown).map { "> " + $0 }
            case .bullet(let inlines):
                let lines = sentenceLines(inlines, token: tokenMarkdown)
                for (k, l) in lines.enumerated() { out.append((k == 0 ? "- " : "  ") + l) }
                if lines.isEmpty { out.append("-") }
            case .numbered(let inlines):
                let marker = "\(number). "
                let lines = sentenceLines(inlines, token: tokenMarkdown)
                for (k, l) in lines.enumerated() {
                    out.append((k == 0 ? marker : String(repeating: " ", count: marker.count)) + l)
                }
                if lines.isEmpty { out.append("\(number).") }
            case .figure(let f):
                let n = context.numbering.figures[f.path].map(String.init) ?? "?"
                let caption = InlineMarkdown.emit(f.caption, token: tokenMarkdown)
                let alt = "\(f.kind.label) \(n). " + caption
                out.append("![\(InlineMarkdown.escapeCaption(alt.trimmingCharacters(in: .whitespaces)))](\(f.path))")
            case .referenceList:
                for (k, entry) in context.referenceEntries.enumerated() {
                    if k > 0 { out.append("") }
                    out.append(escapeLineStart(entry))
                }
                if context.referenceEntries.isEmpty, !out.isEmpty, out.last == "" { out.removeLast() }
            }
            previous = block
        }
        if !footnotes.isEmpty {
            out.append("")
            for (n, inner) in footnotes {
                // Footnotes inside footnotes aren't supported; their markers vanish.
                let lines = sentenceLines(inner) { t in
                    if case .footnote = t { return "" }
                    return tokenMarkdown(t)
                }
                for (k, l) in lines.enumerated() { out.append((k == 0 ? "[^\(n)]: " : "    ") + l) }
                if lines.isEmpty { out.append("[^\(n)]:") }
            }
        }
        while out.last == "" { out.removeLast() }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    /// A paragraph's inlines as Markdown, one sentence per line.
    public static func sentenceLines(_ inlines: [Inline], token: (Token) -> String) -> [String] {
        let content = inlines.trimmed
        guard !content.isEmpty else { return [] }
        let (units, attachable) = utf16Atoms(content)
        let ranges = Sentences.split(utf16: units, attachable: { attachable.contains($0) })
        return ranges.map { r in
            escapeLineStart(InlineMarkdown.emit(slice(content, utf16: r).trimmed, token: token))
        }.filter { !$0.isEmpty }
    }

    /// The paragraph as UTF-16, each token one U+FFFC; and the offsets of
    /// tokens that may hang after a full stop (footnotes, notes).
    public static func utf16Atoms(_ inlines: [Inline]) -> ([UInt16], Set<Int>) {
        var units: [UInt16] = []
        var attachable = Set<Int>()
        for inline in inlines {
            switch inline {
            case .text(let t, _):
                units += Array(t.utf16)
            case .token(let t, _):
                switch t {
                case .footnote, .note: attachable.insert(units.count)
                default: break
                }
                units.append(Sentences.placeholder)
            }
        }
        return (units, attachable)
    }

    /// The inlines covering a UTF-16 range of `utf16Atoms`.
    public static func slice(_ inlines: [Inline], utf16 range: Range<Int>) -> [Inline] {
        var out: [Inline] = []
        var offset = 0
        for inline in inlines {
            switch inline {
            case .text(let t, let s):
                let units = Array(t.utf16)
                let lo = max(range.lowerBound, offset), hi = min(range.upperBound, offset + units.count)
                if lo < hi {
                    out.append(.text(String(decoding: units[(lo - offset)..<(hi - offset)], as: UTF16.self), s))
                }
                offset += units.count
            case .token:
                if range.contains(offset) { out.append(inline) }
                offset += 1
            }
        }
        return out
    }

    /// Escapes the start of a line that Markdown would read as structure.
    static func escapeLineStart(_ line: String, allowHash: Bool = false) -> String {
        guard let first = line.first else { return line }
        if (first == "#" && !allowHash) || first == ">" || first == "+" || first == "=" || first == ":" || first == "|"
            || first == "%" || first == "~" {
            return "\\" + line
        }
        if first == "-" {
            return "\\" + line
        }
        if first == "!" && line.dropFirst().hasPrefix("[") { return "\\" + line }
        // "1. " or "1) " would start a numbered list.
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let rest = line.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")" {
                let after = rest.dropFirst()
                if after.isEmpty || after.first == " " || after.first == "\t" {
                    return String(digits) + "\\" + String(rest)
                }
            }
        }
        return line
    }
}
