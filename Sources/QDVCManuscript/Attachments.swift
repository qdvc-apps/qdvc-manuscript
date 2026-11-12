import AppKit
import ManuscriptCore

// Tokens (variables, citations, cross-references, footnotes, notes),
// figures and the reference list are text attachments whose cells draw
// themselves from DisplayInfo, so renumbering or reformatting needs only a
// re-layout, never an edit of the text (docs/MAINTENANCE.md §Editor).

/// What the attachments show, shared by every window on a manuscript.
/// Updated by ManuscriptSession after each analysis.
final class DisplayInfo {
    var variables: [String: String] = [:]
    var numbering = Numbering()
    var headingNumbersVisible = true
    var headingTitles: [String: String] = [:]
    var citationTexts: [CitationKey: String] = [:]
    /// Footnote number by attachment.
    var footnoteNumbers: [ObjectIdentifier: Int] = [:]
    /// Paragraph start → its number in a numbered list.
    var listNumbers: [Int: Int] = [:]
    var referenceEntries: [NSAttributedString] = []
    var workspaceURL: URL?
    private var imageCache: [String: NSImage] = [:]

    func image(_ path: String) -> NSImage? {
        if let cached = imageCache[path] { return cached }
        guard let url = workspaceURL?.appendingPathComponent(path), let image = NSImage(contentsOf: url) else { return nil }
        imageCache[path] = image
        return image
    }

    func forgetImages() { imageCache.removeAll() }

    /// A token as plain text (captions, copying, counting).
    func plainText(_ token: Token, showNames: Bool = false) -> String {
        switch token {
        case .variable(let name):
            if showNames { return "{{\(name)}}" }
            return variables[name] ?? "{{\(name)}}"
        case .citation(let c):
            return citationTexts[c.key] ?? (c.text.isEmpty ? "(?)" : c.text)
        case .figureRef(let path):
            return numbering.figureLabel(path) ?? "Figure ??"
        case .sectionRef(let id):
            if let label = numbering.sectionLabel(id) { return label }
            if let title = headingTitles[id] { return "\u{201C}\(title)\u{201D}" }
            return "Section ??"
        case .footnote, .note:
            return ""
        }
    }

    enum Look {
        case variable, citation, reference, broken, footnote, note
    }

    func look(_ token: Token, attachment: NSTextAttachment?, showNames: Bool) -> (text: String, look: Look, help: String) {
        switch token {
        case .variable(let name):
            guard let value = variables[name] else { return ("{{\(name)}}", .broken, "No variable called “\(name)”") }
            return (showNames ? "{{\(name)}}" : (value.isEmpty ? "{{\(name)}}" : value), .variable, "{{\(name)}} = \(value)")
        case .citation(let c):
            let text = plainText(token)
            return (text, text == "(?)" ? .broken : .citation, c.sources.joined(separator: "; "))
        case .figureRef(let path):
            guard let label = numbering.figureLabel(path) else { return ("Figure ??", .broken, "The figure or table was removed") }
            return (label, .reference, path)
        case .sectionRef(let id):
            let text = plainText(token)
            return (text, text == "Section ??" ? .broken : .reference, headingTitles[id] ?? "")
        case .footnote(let inner):
            let n = attachment.flatMap { footnoteNumbers[ObjectIdentifier($0)] } ?? 0
            return (n > 0 ? String(n) : "*", .footnote, inner.plainText { self.plainText($0) })
        case .note(let text):
            return ("\u{270E} " + TextTools.excerpt(text.isEmpty ? "Note" : text, limit: 22), .note, text)
        }
    }
}

// MARK: - Inline tokens

final class TokenAttachment: NSTextAttachment {
    var token: Token
    let info: DisplayInfo

    init(token: Token, info: DisplayInfo) {
        self.token = token
        self.info = info
        super.init(data: nil, ofType: nil)
        attachmentCell = TokenCell()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class TokenCell: NSTextAttachmentCell {
    private var tokenAttachment: TokenAttachment? { attachment as? TokenAttachment }

    private func styleFlags(_ storage: NSTextStorage?, _ index: Int) -> (bold: Bool, italic: Bool) {
        guard let storage, index >= 0, index < storage.length else { return (false, false) }
        return (storage.attribute(.msBold, at: index, effectiveRange: nil) as? Bool ?? false,
                storage.attribute(.msItalic, at: index, effectiveRange: nil) as? Bool ?? false)
    }

    private func font(for look: DisplayInfo.Look, bold: Bool, italic: Bool) -> NSFont {
        switch look {
        case .footnote: return EditorStyle.serif(EditorStyle.size * 0.68, bold: true)
        case .note: return NSFont.systemFont(ofSize: EditorStyle.size * 0.66, weight: .medium)
        default: return EditorStyle.serif(EditorStyle.size, bold: bold, italic: italic)
        }
    }

    private func measure(showNames: Bool, bold: Bool, italic: Bool) -> (text: String, look: DisplayInfo.Look, font: NSFont, size: NSSize) {
        guard let a = tokenAttachment else { return ("?", .broken, EditorStyle.serif(EditorStyle.size), NSSize(width: 10, height: 10)) }
        let l = a.info.look(a.token, attachment: a, showNames: showNames)
        let f = font(for: l.look, bold: bold, italic: italic)
        let w = ceil((l.text as NSString).size(withAttributes: [.font: f]).width)
        let pad: CGFloat = l.look == .footnote ? 1.5 : (l.look == .note ? 6 : 3)
        return (l.text, l.look, f, NSSize(width: w + 2 * pad, height: ceil(f.ascender - f.descender) + 2))
    }

    override func cellSize() -> NSSize {
        measure(showNames: false, bold: false, italic: false).size
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: floor(EditorStyle.serif(EditorStyle.size).descender) - 1)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let lm = textContainer.layoutManager as? ManuscriptLayoutManager
        if lm?.isHidden(charIndex) == true { return .zero }
        let flags = styleFlags(textContainer.layoutManager?.textStorage, charIndex)
        let m = measure(showNames: lm?.showVariableNames ?? false, bold: flags.bold, italic: flags.italic)
        switch m.look {
        case .footnote:
            return NSRect(x: 0, y: EditorStyle.size * 0.32, width: m.size.width, height: m.size.height)
        case .note:
            return NSRect(x: 0, y: -2, width: m.size.width + 2, height: m.size.height)
        default:
            return NSRect(x: 0, y: floor(m.font.descender) - 1, width: m.size.width, height: m.size.height)
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        render(cellFrame, characterIndex: NSNotFound, layoutManager: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        render(cellFrame, characterIndex: charIndex, layoutManager: layoutManager)
    }

    private func render(_ cellFrame: NSRect, characterIndex charIndex: Int, layoutManager: NSLayoutManager?) {
        guard cellFrame.width > 0 else { return }
        let lm = layoutManager as? ManuscriptLayoutManager
        let dimmed = charIndex != NSNotFound && (lm?.isDimmed(charIndex) ?? false)
        let flags = styleFlags(layoutManager?.textStorage, charIndex)
        let m = measure(showNames: lm?.showVariableNames ?? false, bold: flags.bold, italic: flags.italic)
        let textColor = dimmed ? EditorStyle.fadedText : NSColor.textColor
        switch m.look {
        case .footnote:
            let attrs: [NSAttributedString.Key: Any] = [.font: m.font,
                                                        .foregroundColor: dimmed ? EditorStyle.fadedText : NSColor.controlAccentColor]
            (m.text as NSString).draw(at: NSPoint(x: cellFrame.minX + 1.5, y: cellFrame.minY), withAttributes: attrs)
        case .note:
            let rect = cellFrame.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.systemYellow.withAlphaComponent(dimmed ? 0.15 : 0.38).setFill()
            path.fill()
            NSColor.systemOrange.withAlphaComponent(dimmed ? 0.2 : 0.5).setStroke()
            path.lineWidth = 0.75
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: m.font, .foregroundColor: dimmed ? EditorStyle.fadedText : NSColor.textColor]
            (m.text as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 0.5), withAttributes: attrs)
        default:
            let tint: NSColor
            switch m.look {
            case .variable: tint = .systemTeal
            case .citation: tint = .systemGreen
            case .reference: tint = .systemIndigo
            default: tint = .systemRed
            }
            let rect = cellFrame.insetBy(dx: 0.5, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            tint.withAlphaComponent(dimmed ? 0.05 : (m.look == .broken ? 0.22 : 0.12)).setFill()
            path.fill()
            if m.look == .broken {
                NSColor.systemRed.withAlphaComponent(0.6).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: m.font, .foregroundColor: textColor]
            (m.text as NSString).draw(at: NSPoint(x: cellFrame.minX + 3, y: cellFrame.minY + 1), withAttributes: attrs)
        }
    }
}

// MARK: - Block attachments

/// An attachment that is a paragraph of its own (a figure, the reference list).
protocol BlockAttachment: AnyObject {}

final class FigureAttachment: NSTextAttachment, BlockAttachment {
    var figure: Figure
    let info: DisplayInfo

    init(figure: Figure, info: DisplayInfo) {
        self.figure = figure
        self.info = info
        super.init(data: nil, ofType: nil)
        attachmentCell = FigureCell()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class FigureCell: NSTextAttachmentCell {
    private var figureAttachment: FigureAttachment? { attachment as? FigureAttachment }
    static let gap: CGFloat = 8

    private func available(_ textContainer: NSTextContainer?, _ lineFrag: NSRect) -> CGFloat {
        let padding = textContainer?.lineFragmentPadding ?? 5
        return max(120, lineFrag.width - 2 * padding - 2)
    }

    /// The caption, "Figure 3." in bold, then the text.
    func caption() -> NSAttributedString {
        guard let a = figureAttachment else { return NSAttributedString() }
        let size = EditorStyle.size * 0.9
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.alignment = .center
        let out = NSMutableAttributedString()
        let number = a.info.numbering.figures[a.figure.path].map(String.init) ?? "?"
        out.append(NSAttributedString(string: "\(a.figure.kind.label) \(number).",
                                      attributes: [.font: EditorStyle.serif(size, bold: true), .foregroundColor: NSColor.textColor,
                                                   .paragraphStyle: style]))
        let text = a.figure.caption.isEmpty ? [Inline.text(" Double-click to add a caption", InlineStyle(italic: true))]
            : [Inline.text(" ", .plain)] + a.figure.caption
        for inline in text {
            switch inline {
            case .text(let t, let s):
                let color: NSColor = a.figure.caption.isEmpty ? .secondaryLabelColor : .textColor
                out.append(NSAttributedString(string: t, attributes: [.font: EditorStyle.serif(size, bold: s.bold, italic: s.italic),
                                                                      .foregroundColor: color, .paragraphStyle: style]))
            case .token(let t, let s):
                out.append(NSAttributedString(string: a.info.plainText(t), attributes: [
                    .font: EditorStyle.serif(size, bold: s.bold, italic: s.italic), .foregroundColor: NSColor.textColor,
                    .paragraphStyle: style]))
            }
        }
        return out
    }

    private func imageSize(width: CGFloat) -> NSSize {
        guard let a = figureAttachment, let image = a.info.image(a.figure.path), image.size.width > 0 else {
            return NSSize(width: min(width, 360), height: 120)
        }
        var w = min(image.size.width, width)
        var h = image.size.height * w / image.size.width
        let maxHeight: CGFloat = 820
        if h > maxHeight {
            w *= maxHeight / h
            h = maxHeight
        }
        return NSSize(width: w, height: h)
    }

    private func layout(width: CGFloat) -> (image: NSSize, captionHeight: CGFloat) {
        let img = imageSize(width: width)
        let captionWidth = max(min(width, 640), img.width)
        let rect = caption().boundingRect(with: NSSize(width: captionWidth, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return (img, ceil(rect.height))
    }

    override func cellSize() -> NSSize {
        let l = layout(width: 600)
        return NSSize(width: 600, height: l.image.height + l.captionHeight + 3 * Self.gap)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if (textContainer.layoutManager as? ManuscriptLayoutManager)?.isHidden(charIndex) == true { return .zero }
        let width = available(textContainer, lineFrag)
        let l = layout(width: width)
        return NSRect(x: 0, y: 0, width: width, height: l.image.height + l.captionHeight + 3 * Self.gap)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, dimmed: false)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(cellFrame, dimmed: (layoutManager as? ManuscriptLayoutManager)?.isDimmed(charIndex) ?? false)
    }

    private func draw(_ frame: NSRect, dimmed: Bool) {
        guard frame.width > 0, let a = figureAttachment else { return }
        let l = layout(width: frame.width)
        let captionWidth = max(min(frame.width, 640), l.image.width)
        let isTable = a.figure.kind == .table
        let imageY = isTable ? frame.minY + 2 * Self.gap + l.captionHeight : frame.minY + Self.gap
        let captionY = isTable ? frame.minY + Self.gap : imageY + l.image.height + Self.gap
        let imageRect = NSRect(x: frame.midX - l.image.width / 2, y: imageY, width: l.image.width, height: l.image.height)
        if let image = a.info.image(a.figure.path) {
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.3 : 1, respectFlipped: true, hints: nil)
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(rect: imageRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 0.5
            border.stroke()
        } else {
            let path = NSBezierPath(roundedRect: imageRect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            let text = "Image not found: \(a.figure.path)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2), withAttributes: attrs)
        }
        let caption = NSMutableAttributedString(attributedString: caption())
        if dimmed {
            caption.addAttribute(.foregroundColor, value: EditorStyle.fadedText, range: NSRange(location: 0, length: caption.length))
        }
        caption.draw(with: NSRect(x: frame.midX - captionWidth / 2, y: captionY, width: captionWidth, height: l.captionHeight + 4),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

final class ReferenceListAttachment: NSTextAttachment, BlockAttachment {
    let info: DisplayInfo

    init(info: DisplayInfo) {
        self.info = info
        super.init(data: nil, ofType: nil)
        attachmentCell = ReferenceListCell()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class ReferenceListCell: NSTextAttachmentCell {
    static let spacing: CGFloat = 10

    private var entries: [NSAttributedString] {
        guard let a = attachment as? ReferenceListAttachment else { return [] }
        if a.info.referenceEntries.isEmpty {
            return [NSAttributedString(string: "The works you cite from QDVC Bibliotheca will be listed here.",
                                       attributes: [.font: EditorStyle.serif(EditorStyle.size * 0.92, italic: true),
                                                    .foregroundColor: NSColor.secondaryLabelColor])]
        }
        return a.info.referenceEntries
    }

    private func heights(width: CGFloat) -> [CGFloat] {
        entries.map {
            ceil($0.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
    }

    override func cellSize() -> NSSize {
        let h = heights(width: 600)
        return NSSize(width: 600, height: h.reduce(0, +) + Self.spacing * CGFloat(max(0, h.count - 1)) + 4)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if (textContainer.layoutManager as? ManuscriptLayoutManager)?.isHidden(charIndex) == true { return .zero }
        let width = max(120, lineFrag.width - 2 * textContainer.lineFragmentPadding - 2)
        let h = heights(width: width)
        return NSRect(x: 0, y: 0, width: width, height: h.reduce(0, +) + Self.spacing * CGFloat(max(0, h.count - 1)) + 4)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, dimmed: false)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        draw(cellFrame, dimmed: (layoutManager as? ManuscriptLayoutManager)?.isDimmed(charIndex) ?? false)
    }

    private func draw(_ frame: NSRect, dimmed: Bool) {
        guard frame.width > 0 else { return }
        var y = frame.minY + 2
        let list = entries
        let h = heights(width: frame.width)
        for (k, entry) in list.enumerated() {
            let e = NSMutableAttributedString(attributedString: entry)
            if dimmed { e.addAttribute(.foregroundColor, value: EditorStyle.fadedText, range: NSRange(location: 0, length: e.length)) }
            e.draw(with: NSRect(x: frame.minX, y: y, width: frame.width, height: h[k] + 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += h[k] + Self.spacing
        }
    }
}

extension DisplayInfo {
    /// A reference entry (inline Markdown) for the list: hanging indent.
    static func referenceString(_ markdown: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = EditorStyle.size * 1.8
        style.lineHeightMultiple = 1.25
        let size = EditorStyle.size * 0.94
        let out = NSMutableAttributedString()
        for inline in InlineMarkdown.parse(markdown) {
            if case .text(let t, let s) = inline {
                out.append(NSAttributedString(string: t, attributes: [.font: EditorStyle.serif(size, bold: s.bold, italic: s.italic),
                                                                      .foregroundColor: NSColor.textColor, .paragraphStyle: style]))
            }
        }
        return out
    }
}
