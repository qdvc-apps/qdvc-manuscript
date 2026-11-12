import AppKit
import ManuscriptCore

/// One window's layout of the shared text: it draws heading numbers in the
/// margin, list markers and quote bars, and knows this window's Focus,
/// Collapse and variable-name state (which attachment cells ask about).
final class ManuscriptLayoutManager: NSLayoutManager {
    let info: DisplayInfo
    /// Show `{{name}}` rather than values.
    var showVariableNames = false
    /// Focus mode: everything but `focusRange` is faded.
    var focusRange: NSRange?
    var focusActive = false
    /// Collapse mode: characters not laid out.
    var hidden = IndexSet()
    /// Character positions after which a "⋯" shows that text is folded away.
    var foldMarks: [Int] = []

    init(info: DisplayInfo) {
        self.info = info
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func isHidden(_ charIndex: Int) -> Bool { !hidden.isEmpty && hidden.contains(charIndex) }

    func isDimmed(_ charIndex: Int) -> Bool {
        guard focusActive else { return false }
        guard let r = focusRange else { return true }
        return !NSLocationInRange(charIndex, r)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let string = storage.string as NSString
        let padding = container.lineFragmentPadding
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, usedRect, _, glyphRange, _ in
            let ci = self.characterIndexForGlyph(at: glyphRange.location)
            guard ci < storage.length else { return }
            let kind = (storage.attribute(.msKind, at: ci, effectiveRange: nil) as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
            let startsParagraph = ci == 0 || string.character(at: ci - 1) == 10
            let dimmed = self.isDimmed(ci)
            let markerColor = dimmed ? EditorStyle.fadedText : NSColor.secondaryLabelColor
            // Baseline of the line's first glyph.
            let baseline = origin.y + rect.minY + self.location(forGlyphAt: glyphRange.location).y
            switch kind {
            case .h1, .h2, .h3, .h4:
                guard startsParagraph, self.info.headingNumbersVisible,
                      let id = storage.attribute(.msHeadingID, at: ci, effectiveRange: nil) as? String,
                      let number = self.info.numbering.headings[id] else { return }
                let font = EditorStyle.font(kind, bold: false, italic: false)
                let label = Numbering.headingLabel(number) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: markerColor]
                let width = label.size(withAttributes: attrs).width
                let x = origin.x + rect.minX + padding - 14 - width
                label.draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: attrs)
            case .bullet, .numbered:
                guard startsParagraph else { return }
                let font = EditorStyle.serif(EditorStyle.size)
                let indent = EditorStyle.size * 1.7
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: markerColor]
                let label: NSString = kind == .bullet ? "\u{2022}" : "\(self.info.listNumbers[ci] ?? 1)." as NSString
                let width = label.size(withAttributes: attrs).width
                let x = origin.x + rect.minX + padding + indent - 8 - width
                label.draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: attrs)
            case .quote:
                let bar = NSRect(x: origin.x + rect.minX + padding + EditorStyle.size * 0.55, y: origin.y + rect.minY + 2,
                                 width: 3, height: rect.height - 4)
                (dimmed ? EditorStyle.fadedText : NSColor.tertiaryLabelColor).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            default:
                break
            }
            _ = usedRect
        }
        drawFoldMarks(glyphsToShow, origin: origin)
    }

    private func drawFoldMarks(_ glyphsToShow: NSRange, origin: NSPoint) {
        guard !foldMarks.isEmpty, let container = textContainers.first, let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for mark in foldMarks where NSLocationInRange(mark, charRange) && mark < storage.length {
            let glyph = glyphIndexForCharacter(at: mark)
            let r = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let pill = NSRect(x: origin.x + r.maxX + 5, y: origin.y + r.midY - 7, width: 26, height: 14)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let dots = "\u{22EF}" as NSString
            let size = dots.size(withAttributes: attrs)
            dots.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

/// Collapse mode, as the layout manager's delegate: hidden characters get
/// null glyphs, and newlines inside a folded run take no space, so only
/// headings and topic sentences are laid out (like code folding).
final class CollapseHider: NSObject, NSLayoutManagerDelegate {
    var active = false
    var hidden = IndexSet()
    var zeroAdvance = IndexSet()

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard active, !hidden.isEmpty else { return 0 }
        let count = glyphRange.length
        var modified = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
        var any = false
        for i in 0..<count {
            if hidden.contains(charIndexes[i]) {
                modified[i] = .null
                any = true
            } else {
                modified[i] = props[i]
            }
        }
        guard any else { return 0 }
        modified.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                layoutManager.setGlyphs(glyphs, properties: base, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            }
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if active && zeroAdvance.contains(charIndex) { return .zeroAdvancement }
        return action
    }

    /// Works out what to hide: everything but the title, headings and the
    /// first sentence of each body paragraph.
    func compute(paragraphs: [ParagraphInfo], length: Int) -> (hidden: IndexSet, zero: IndexSet, marks: [Int]) {
        var hidden = IndexSet()
        var zero = IndexSet()
        var marks: [Int] = []
        // Newline of the last paragraph shown, to fold a hidden run after it.
        var previousNewline: Int?
        var previousVisibleEnd: Int?
        var inHiddenRun = false
        var lastHiddenNewline: Int?
        for p in paragraphs {
            let newline = p.range.location + p.range.length < length ? p.range.location + p.range.length : nil
            let visibleWhole = p.kind == .title || p.kind.isHeading
            let topic = p.kind == .body ? p.sentences.first : nil
            if visibleWhole || topic != nil {
                // A hidden run before this paragraph: its last newline stays a break.
                if inHiddenRun, let last = lastHiddenNewline { zero.remove(last) }
                inHiddenRun = false
                if let topic, p.sentences.count > 1 {
                    let start = topic.range.location + topic.range.length
                    let end = p.range.location + p.range.length
                    if end > start { hidden.insert(integersIn: start..<end) }
                    marks.append(start - 1)
                }
                previousNewline = newline
                previousVisibleEnd = topic.map { $0.range.location + $0.range.length - 1 } ?? (p.range.location + p.range.length - 1)
            } else {
                // A paragraph folded away entirely.
                if p.range.length > 0 { hidden.insert(integersIn: p.range.location..<(p.range.location + p.range.length)) }
                if !inHiddenRun {
                    if let previousNewline { zero.insert(previousNewline) }
                    if let end = previousVisibleEnd, !marks.contains(end) { marks.append(end) }
                }
                if let newline { zero.insert(newline) }
                lastHiddenNewline = newline
                inHiddenRun = true
            }
        }
        if inHiddenRun, let last = lastHiddenNewline { zero.remove(last) }
        return (hidden, zero, marks)
    }
}
