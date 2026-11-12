import AppKit
import ManuscriptCore

/// The manuscript model as the editor's attributed string, and back.
@MainActor
enum DocumentBuilder {
    /// The whole manuscript: the title (if any) as the first paragraph.
    static func attributedString(_ m: Manuscript, info: DisplayInfo) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func newline(_ kind: ParaKind, headingID: String? = nil, unnumbered: Bool = false) {
            out.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(kind, headingID: headingID,
                                                                                            unnumbered: unnumbered)))
        }
        if !m.title.isEmpty {
            out.append(inlines(m.title, kind: .title, info: info))
            if !m.blocks.isEmpty { newline(.title) }
        }
        for (k, block) in m.blocks.enumerated() {
            let (para, kind, id, unnumbered) = paragraph(block, info: info)
            out.append(para)
            if k < m.blocks.count - 1 { newline(kind, headingID: id, unnumbered: unnumbered) }
        }
        if out.length == 0 {
            return NSAttributedString(string: "", attributes: EditorStyle.attributes(.body))
        }
        return out
    }

    /// One block as a paragraph (without its newline).
    static func paragraph(_ block: Block, info: DisplayInfo) -> (NSAttributedString, ParaKind, String?, Bool) {
        switch block {
        case .heading(let h):
            let kind = ParaKind.heading(h.level)
            let id = h.id.isEmpty ? TextTools.randomID(prefix: "h-") : h.id
            return (inlines(h.inlines, kind: kind, info: info, headingID: id, unnumbered: h.unnumbered), kind, id, h.unnumbered)
        case .paragraph(let i): return (inlines(i, kind: .body, info: info), .body, nil, false)
        case .quote(let i): return (inlines(i, kind: .quote, info: info), .quote, nil, false)
        case .bullet(let i): return (inlines(i, kind: .bullet, info: info), .bullet, nil, false)
        case .numbered(let i): return (inlines(i, kind: .numbered, info: info), .numbered, nil, false)
        case .figure(let f):
            let s = NSMutableAttributedString(attachment: FigureAttachment(figure: f, info: info))
            s.addAttributes(EditorStyle.attributes(.figure), range: NSRange(location: 0, length: s.length))
            return (s, .figure, nil, false)
        case .referenceList:
            let s = NSMutableAttributedString(attachment: ReferenceListAttachment(info: info))
            s.addAttributes(EditorStyle.attributes(.refs), range: NSRange(location: 0, length: s.length))
            return (s, .refs, nil, false)
        }
    }

    /// Inlines as text in a paragraph of `kind`.
    static func inlines(_ inlines: [Inline], kind: ParaKind, info: DisplayInfo, headingID: String? = nil,
                        unnumbered: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let id = kind.isHeading ? (headingID ?? TextTools.randomID(prefix: "h-")) : nil
        for inline in inlines {
            switch inline {
            case .text(let t, let s):
                out.append(NSAttributedString(string: t, attributes: EditorStyle.attributes(
                    kind, bold: s.bold, italic: s.italic, headingID: id, unnumbered: unnumbered)))
            case .token(let t, let s):
                out.append(token(t, kind: kind, style: s, info: info, headingID: id, unnumbered: unnumbered))
            }
        }
        return out
    }

    static func token(_ t: Token, kind: ParaKind, style: InlineStyle, info: DisplayInfo, headingID: String? = nil,
                      unnumbered: Bool = false) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: TokenAttachment(token: t, info: info))
        s.addAttributes(EditorStyle.attributes(kind, bold: style.bold, italic: style.italic, headingID: headingID,
                                               unnumbered: unnumbered),
                        range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Blocks for pasting: paragraphs joined by newlines.
    static func blocks(_ blocks: [Block], info: DisplayInfo) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (k, block) in blocks.enumerated() {
            let (para, kind, id, unnumbered) = paragraph(block, info: info)
            out.append(para)
            if k < blocks.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(kind, headingID: id, unnumbered: unnumbered)))
            }
        }
        return out
    }
}

/// Reads the editor's attributed string back into the model.
@MainActor
enum DocumentReader {
    struct Span {
        var block: Block
        /// The paragraph's text, without its newline.
        var range: NSRange
    }

    struct Result {
        var title: [Inline] = []
        var titleRange: NSRange?
        var spans: [Span] = []

        var blocks: [Block] { spans.map(\.block) }
    }

    static func kind(_ s: NSAttributedString, at index: Int) -> ParaKind {
        guard index >= 0, index < s.length else { return .body }
        return (s.attribute(.msKind, at: index, effectiveRange: nil) as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
    }

    /// Paragraph content ranges (without newlines), in order.
    static func paragraphRanges(_ s: NSAttributedString) -> [NSRange] {
        let ns = s.string as NSString
        var out: [NSRange] = []
        var start = 0
        let length = ns.length
        while start <= length {
            let nl = ns.range(of: "\n", options: [], range: NSRange(location: start, length: length - start))
            let end = nl.location == NSNotFound ? length : nl.location
            out.append(NSRange(location: start, length: end - start))
            if nl.location == NSNotFound { break }
            start = end + 1
        }
        return out
    }

    static func read(_ s: NSAttributedString) -> Result {
        var result = Result()
        var seenIDs = Set<String>()
        for (index, range) in paragraphRanges(s).enumerated() {
            guard range.length > 0 else { continue }
            let kind = self.kind(s, at: range.location)
            // A block attachment makes its paragraph a figure or the reference list.
            var blockAttachment: NSTextAttachment?
            s.enumerateAttribute(.attachment, in: range, options: []) { value, _, stop in
                if let a = value as? NSTextAttachment, a is BlockAttachment {
                    blockAttachment = a
                    stop.pointee = true
                }
            }
            if let f = blockAttachment as? FigureAttachment {
                result.spans.append(Span(block: .figure(f.figure), range: range))
                continue
            }
            if blockAttachment is ReferenceListAttachment {
                result.spans.append(Span(block: .referenceList, range: range))
                continue
            }
            let content = inlines(s, range: range).trimmed
            if content.isEmpty { continue }
            switch kind {
            case .title:
                if index == 0 {
                    result.title = content
                    result.titleRange = range
                } else {
                    result.spans.append(Span(block: .paragraph(content), range: range))
                }
            case .h1, .h2, .h3, .h4:
                var id = (s.attribute(.msHeadingID, at: range.location, effectiveRange: nil) as? String) ?? ""
                if id.isEmpty || seenIDs.contains(id) { id = "p\(range.location)" }
                seenIDs.insert(id)
                let unnumbered = s.attribute(.msUnnumbered, at: range.location, effectiveRange: nil) as? Bool ?? false
                result.spans.append(Span(block: .heading(Heading(level: kind.headingLevel ?? 1, inlines: content,
                                                                 unnumbered: unnumbered, id: id)), range: range))
            case .quote: result.spans.append(Span(block: .quote(content), range: range))
            case .bullet: result.spans.append(Span(block: .bullet(content), range: range))
            case .numbered: result.spans.append(Span(block: .numbered(content), range: range))
            case .body, .figure, .refs: result.spans.append(Span(block: .paragraph(content), range: range))
            }
        }
        return result
    }

    /// The inlines of a range of text.
    static func inlines(_ s: NSAttributedString, range: NSRange) -> [Inline] {
        var out: [Inline] = []
        let ns = s.string as NSString
        s.enumerateAttributes(in: range, options: []) { attrs, sub, _ in
            let style = InlineStyle(bold: attrs[.msBold] as? Bool ?? false, italic: attrs[.msItalic] as? Bool ?? false)
            if let token = attrs[.attachment] as? TokenAttachment {
                // A run of identical attributes can't hold two attachments, but be safe.
                for _ in 0..<sub.length { out.append(.token(token.token, style)) }
                return
            }
            if attrs[.attachment] != nil { return }
            let text = ns.substring(with: sub).replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{2028}", with: " ").replacingOccurrences(of: "\u{2029}", with: " ")
            if !text.isEmpty { out.append(.text(text, style)) }
        }
        return out.coalesced
    }
}
