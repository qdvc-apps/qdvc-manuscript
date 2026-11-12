import AppKit
import ManuscriptCore
import SwiftUI

/// One window's editor: its own layout manager, text view and scroll view
/// over the manuscript's shared text storage, with this window's Focus,
/// topic-sentence, typewriter, long-sentence and margin settings.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate {
    let session: ManuscriptSession
    let layoutManager: ManuscriptLayoutManager
    let textContainer: NSTextContainer
    let textView: ManuscriptTextView
    let scrollView: NSScrollView
    let hostView = EditorHostView()
    private let hider = CollapseHider()
    private let observerID = UUID()
    weak var state: EditorWindowState?
    private var popover: NSPopover?
    private var detached = false
    private var lastFocusRange: NSRange?
    private var magnificationObserver: NSObjectProtocol?

    var storage: NSTextStorage { session.storage }

    var focus = false {
        didSet {
            guard oldValue != focus else { return }
            layoutManager.focusActive = focus
            refreshDecorations()
        }
    }

    var topicMode: TopicMode = .off {
        didSet { if oldValue != topicMode { applyTopicMode() } }
    }

    var typewriter = false {
        didSet {
            guard oldValue != typewriter else { return }
            updateInsets()
            scrollCaretIfTypewriter()
        }
    }

    var longSentences = false {
        didSet { if oldValue != longSentences { refreshDecorations() } }
    }

    var showVariableNames = false {
        didSet {
            guard oldValue != showVariableNames else { return }
            layoutManager.showVariableNames = showVariableNames
            let full = NSRange(location: 0, length: storage.length)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: full)
        }
    }

    var margins: MarginPreset = .medium {
        didSet { if oldValue != margins { updateInsets() } }
    }

    init(session: ManuscriptSession) {
        self.session = session
        let lm = ManuscriptLayoutManager(info: session.info)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 6
        lm.addTextContainer(container)
        layoutManager = lm
        textContainer = container
        textView = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        layoutManager.allowsNonContiguousLayout = false
        layoutManager.delegate = hider
        session.storage.addLayoutManager(layoutManager)
        let d = UserDefaults.standard
        margins = MarginPreset(rawValue: d.string(forKey: Prefs.margins) ?? "") ?? .medium

        textView.controller = self
        textView.delegate = self
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = d.bool(forKey: Prefs.smartQuotes)
        textView.isAutomaticDashSubstitutionEnabled = d.bool(forKey: Prefs.smartQuotes)
        textView.isContinuousSpellCheckingEnabled = d.bool(forKey: Prefs.spellChecking)
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = true
        textView.textContainerInset = NSSize(width: 60, height: 44)
        textView.typingAttributes = EditorStyle.attributes(.body)
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        #endif

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.6
        scrollView.maxMagnification = 2.5
        scrollView.autoresizingMask = [.width, .height]
        scrollView.findBarPosition = .aboveContent
        hostView.addSubview(scrollView)
        hostView.onLayout = { [weak self] in self?.updateInsets() }
        magnificationObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateInsets() }
        }

        session.observeAnalysis(observerID) { [weak self] in self?.analysisChanged() }
    }

    /// Stops sharing the text (the window closed).
    func detach() {
        guard !detached else { return }
        detached = true
        popover?.close()
        session.stopObserving(observerID)
        if let magnificationObserver { NotificationCenter.default.removeObserver(magnificationObserver) }
        textView.delegate = nil
        textView.controller = nil
        session.storage.removeLayoutManager(layoutManager)
    }

    // MARK: Layout

    func updateInsets() {
        let clip = scrollView.contentView.bounds
        guard clip.width > 0 else { return }
        let insetW = max(40, floor((clip.width - margins.columnWidth) / 2))
        let position = CGFloat(UserDefaults.standard.double(forKey: Prefs.typewriterPosition))
        let insetH: CGFloat = typewriter ? floor(clip.height * max(0.2, min(0.7, position))) : 44
        let inset = NSSize(width: insetW, height: insetH)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
    }

    func zoom(by factor: CGFloat?) {
        let target = factor.map { scrollView.magnification * $0 } ?? 1
        scrollView.magnification = max(scrollView.minMagnification, min(scrollView.maxMagnification, target))
        updateInsets()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: Moving around

    /// Puts the insertion point at `location` and shows it near the top.
    func reveal(_ location: Int, select length: Int = 0) {
        let loc = max(0, min(location, storage.length))
        textView.setSelectedRange(NSRange(location: loc, length: min(length, storage.length - loc)))
        if storage.length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(loc, storage.length - 1))
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let clip = scrollView.contentView
            let y = max(0, rect.minY + textView.textContainerOrigin.y - 60)
            let maxY = max(0, textView.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(y, maxY)))
            scrollView.reflectScrolledClipView(clip)
        }
        textView.window?.makeFirstResponder(textView)
    }

    func scrollCaretIfTypewriter() {
        guard typewriter, textView.window != nil, storage.length > 0 else { return }
        let sel = textView.selectedRange()
        var rect: NSRect
        if sel.location >= storage.length, !layoutManager.extraLineFragmentRect.isEmpty {
            rect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(sel.location, storage.length - 1))
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let position = CGFloat(UserDefaults.standard.double(forKey: Prefs.typewriterPosition))
        let clip = scrollView.contentView
        let y = rect.midY + textView.textContainerOrigin.y
        let target = y - clip.bounds.height * max(0.2, min(0.7, position))
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let point = NSPoint(x: clip.bounds.origin.x, y: min(max(0, target), maxY))
        if abs(clip.bounds.origin.y - point.y) > 1 {
            clip.scroll(to: point)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: Analysis, decorations, collapse

    private func analysisChanged() {
        guard !detached else { return }
        if topicMode == .collapse { computeCollapse() }
        refreshDecorations()
        updateLiveInfo()
    }

    /// Topic-sentence accents, long-sentence flags and Focus mode, as this
    /// layout manager's temporary attributes (other windows aren't affected).
    func refreshDecorations() {
        guard !detached else { return }
        let length = storage.length
        let full = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: full)
        }
        lastFocusRange = nil
        guard length > 0 else { return }
        func clamp(_ r: NSRange) -> NSRange? {
            let c = NSIntersectionRange(r, full)
            return c.length > 0 ? c : nil
        }
        let paragraphs = session.analysis.paragraphs
        if topicMode == .accentuate {
            for p in paragraphs where p.kind == .body {
                guard let first = p.sentences.first, let topic = clamp(first.range) else { continue }
                layoutManager.addTemporaryAttributes([.foregroundColor: EditorStyle.topicColor,
                                                      .backgroundColor: EditorStyle.topicBackground], forCharacterRange: topic)
                let restStart = NSMaxRange(first.range)
                if let rest = clamp(NSRange(location: restStart, length: NSMaxRange(p.range) - restStart)) {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: EditorStyle.mutedText, forCharacterRange: rest)
                }
            }
        }
        if longSentences {
            let threshold = max(10, UserDefaults.standard.integer(forKey: Prefs.longSentenceWords))
            for p in paragraphs {
                for s in p.sentences where s.words > threshold {
                    guard let r = clamp(s.range) else { continue }
                    layoutManager.addTemporaryAttributes([
                        .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                        .underlineColor: NSColor.systemOrange,
                    ], forCharacterRange: r)
                }
            }
        }
        if focus {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: EditorStyle.fadedText, forCharacterRange: full)
            updateFocus(force: true)
        }
        layoutManager.invalidateDisplay(forCharacterRange: full)
    }

    /// Focus mode follows the insertion point, sentence by sentence.
    private func updateFocus(force: Bool = false) {
        guard focus else { return }
        let current = currentSentenceRange()
        if !force, current == lastFocusRange { return }
        let full = NSRange(location: 0, length: storage.length)
        if let last = lastFocusRange {
            let r = NSIntersectionRange(last, full)
            if r.length > 0 {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: EditorStyle.fadedText, forCharacterRange: r)
                layoutManager.invalidateDisplay(forCharacterRange: r)
            }
        }
        layoutManager.focusRange = current
        if let current {
            let r = NSIntersectionRange(current, full)
            if r.length > 0 {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
                if topicMode == .accentuate, isTopicSentence(r) {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: EditorStyle.topicColor, forCharacterRange: r)
                }
                layoutManager.invalidateDisplay(forCharacterRange: r)
            }
        }
        lastFocusRange = current
    }

    private func isTopicSentence(_ r: NSRange) -> Bool {
        session.analysis.paragraphs.contains { $0.kind == .body && $0.sentences.first?.range == r }
    }

    /// The sentence at the insertion point, worked out from the text now.
    func currentSentenceRange() -> NSRange? {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return nil }
        let loc = min(textView.selectedRange().location, ns.length)
        var para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        if para.length > 0, NSMaxRange(para) <= ns.length, ns.character(at: NSMaxRange(para) - 1) == 10 { para.length -= 1 }
        guard para.length > 0 else { return nil }
        let kind = DocumentReader.kind(storage, at: para.location)
        if kind == .figure || kind == .refs { return para }
        var units = [UInt16](repeating: 0, count: para.length)
        ns.getCharacters(&units, range: para)
        var attachable = Set<Int>()
        storage.enumerateAttribute(.attachment, in: para, options: []) { value, r, _ in
            if let a = value as? TokenAttachment {
                switch a.token {
                case .footnote, .note: attachable.insert(r.location - para.location)
                default: break
                }
            }
        }
        let ranges = Sentences.split(utf16: units, attachable: { attachable.contains($0) })
        guard let s = Sentences.sentence(at: loc - para.location, in: ranges) else { return nil }
        return NSRange(location: para.location + s.lowerBound, length: s.count)
    }

    private func applyTopicMode() {
        switch topicMode {
        case .collapse:
            session.analyze()
            textView.isEditable = false
            hider.active = true
            computeCollapse(force: true)
        case .off, .accentuate:
            textView.isEditable = true
            if hider.active {
                hider.active = false
                hider.hidden = IndexSet()
                hider.zeroAdvance = IndexSet()
                layoutManager.hidden = IndexSet()
                layoutManager.foldMarks = []
                invalidateGlyphs()
            }
        }
        refreshDecorations()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    private func computeCollapse(force: Bool = false) {
        let result = hider.compute(paragraphs: session.analysis.paragraphs, length: storage.length)
        guard force || result.hidden != hider.hidden || result.zero != hider.zeroAdvance else { return }
        hider.hidden = result.hidden
        hider.zeroAdvance = result.zero
        layoutManager.hidden = result.hidden
        layoutManager.foldMarks = result.marks
        invalidateGlyphs()
    }

    private func invalidateGlyphs() {
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        textView.needsDisplay = true
    }

    /// Leaves Collapse mode with the insertion point at `index`.
    func expand(at index: Int) {
        topicMode = .off
        state?.topicMode = .off
        reveal(index)
    }

    // MARK: Live information for the status bar and outline

    func updateLiveInfo() {
        guard let state else { return }
        let sel = textView.selectedRange()
        let sentence = currentSentenceRange()
        state.sentenceWords = sentence.map { WordCount.count(session.displayString($0)) } ?? 0
        state.selectionWords = sel.length > 0 ? WordCount.count(session.displayString(sel)) : 0
        state.caretLocation = sel.location
        state.currentHeadingID = session.analysis.outline.last(where: { $0.location <= sel.location })?.id
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        session.undoManager
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !detached else { return }
        fixTypingAttributes()
        updateLiveInfo()
        updateFocus()
        scrollCaretIfTypewriter()
    }

    func textDidChange(_ notification: Notification) {
        guard !detached else { return }
        normaliseParagraph()
        updateFocus(force: true)
        scrollCaretIfTypewriter()
    }

    /// Keeps figures and the reference list in paragraphs of their own, and
    /// the reference list read-only.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text else { return true }
        if text.contains("\n") && !text.contains(where: { $0 != "\n" }) { return true }
        let ns = storage.string as NSString
        guard NSMaxRange(range) <= ns.length else { return true }
        let startPara = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let endPara = ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
        let prefix = NSRange(location: startPara.location, length: range.location - startPara.location)
        var suffixEnd = NSMaxRange(endPara)
        if suffixEnd > NSMaxRange(range), suffixEnd > 0, ns.character(at: suffixEnd - 1) == 10 { suffixEnd -= 1 }
        let suffix = NSRange(location: NSMaxRange(range), length: max(0, suffixEnd - NSMaxRange(range)))
        let blocks = blockAttachments(in: prefix) + blockAttachments(in: suffix)
        guard !blocks.isEmpty else { return true }
        let other = hasOtherContent(prefix) || hasOtherContent(suffix) || !text.isEmpty || blocks.count > 1
        guard other else { return true }
        if text.isEmpty, range.length == 1, range.location < ns.length, ns.character(at: range.location) == 10, let block = blocks.first {
            // Joining a paragraph to a figure: select the figure, so the next delete removes it.
            textView.setSelectedRange(NSRange(location: block, length: 1))
        } else {
            NSSound.beep()
        }
        return false
    }

    private func blockAttachments(in range: NSRange) -> [Int] {
        guard range.length > 0 else { return [] }
        var out: [Int] = []
        storage.enumerateAttribute(.attachment, in: range, options: []) { value, r, _ in
            if value is BlockAttachment { out.append(r.location) }
        }
        return out
    }

    private func hasOtherContent(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        let ns = storage.string as NSString
        var found = false
        storage.enumerateAttribute(.attachment, in: range, options: []) { value, r, stop in
            if value is BlockAttachment { return }
            let text = ns.substring(with: r)
            if text.contains(where: { !$0.isWhitespace }) || value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func textView(_ view: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let attachment = cell.attachment else { return }
        if let t = attachment as? TokenAttachment {
            switch t.token {
            case .footnote, .note:
                editNote(t, at: cellFrame)
            case .citation:
                editCitation(t, at: cellFrame)
            case .variable(let name):
                editVariable(name, at: cellFrame)
            case .figureRef(let path):
                if let f = session.analysis.figures.first(where: { $0.path == path }) { reveal(f.location, select: 1) }
            case .sectionRef(let id):
                if let h = session.analysis.outline.first(where: { $0.id == id }) { reveal(h.location) }
            }
        } else if attachment is FigureAttachment {
            textView.setSelectedRange(NSRange(location: charIndex, length: 1))
        }
    }

    func textView(_ view: NSTextView, doubleClickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        if let f = cell.attachment as? FigureAttachment {
            editCaption(f, at: cellFrame)
        }
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        Platform.stripOutsideServices(menu)
        guard textView.isEditable else { return menu }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Insert Citation…") { [weak self] in self?.state?.sheet = .cite })
        menu.addItem(ClosureMenuItem(title: "Insert Footnote") { [weak self] in self?.insertFootnote() })
        menu.addItem(ClosureMenuItem(title: "Insert Note") { [weak self] in self?.insertNote() })
        if textView.selectedRange().length > 0 {
            menu.addItem(ClosureMenuItem(title: "New Variable from Selection…") { [weak self] in self?.beginVariableFromSelection() })
        }
        return menu
    }

    // MARK: Typing attributes and Return

    /// Typing attributes that suit the paragraph at the insertion point:
    /// after a heading a new paragraph is body text; lists and quotes go on.
    func fixTypingAttributes() {
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return }
        let ns = storage.string as NSString
        let loc = min(sel.location, ns.length)
        let paraStart = ns.length == 0 ? 0 : ns.paragraphRange(for: NSRange(location: loc, length: 0)).location
        let atStart = loc == paraStart
        let emptyParagraph = atStart && (loc >= ns.length || ns.character(at: loc) == 10)
        var kind = ParaKind.body
        var bold = false
        var italic = false
        var source: Int?
        if !atStart {
            source = loc - 1
        } else if !emptyParagraph {
            source = loc
        } else if loc < ns.length {
            kind = DocumentReader.kind(storage, at: loc)
            if kind == .figure || kind == .refs || (kind == .title && loc != 0) { kind = .body }
        } else if loc > 0 {
            let previous = DocumentReader.kind(storage, at: loc - 1)
            kind = previous.continuesAfterReturn ? previous : .body
        }
        var headingID: String?
        var unnumbered = false
        if let source {
            kind = DocumentReader.kind(storage, at: source)
            if kind == .figure || kind == .refs { kind = .body }
            bold = storage.attribute(.msBold, at: source, effectiveRange: nil) as? Bool ?? false
            italic = storage.attribute(.msItalic, at: source, effectiveRange: nil) as? Bool ?? false
        }
        if kind.isHeading {
            let probe = source ?? loc
            if probe < storage.length {
                headingID = storage.attribute(.msHeadingID, at: probe, effectiveRange: nil) as? String
                unnumbered = storage.attribute(.msUnnumbered, at: probe, effectiveRange: nil) as? Bool ?? false
            }
        }
        let current = textView.typingAttributes
        if (current[.msKind] as? String) == kind.rawValue, (current[.msBold] as? Bool ?? false) == bold,
           (current[.msItalic] as? Bool ?? false) == italic, current[.font] != nil {
            if !kind.isHeading || (current[.msHeadingID] as? String) == headingID || headingID == nil { return }
        }
        textView.typingAttributes = EditorStyle.attributes(kind, bold: bold, italic: italic, headingID: headingID, unnumbered: unnumbered)
    }

    /// Return in an empty list item or quote ends the list or quote.
    func handleReturn() -> Bool {
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = storage.string as NSString
        let loc = min(sel.location, ns.length)
        let kind: ParaKind
        if ns.length == 0 {
            kind = (textView.typingAttributes[.msKind] as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
        } else {
            var para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if para.length > 0, ns.character(at: NSMaxRange(para) - 1) == 10 { para.length -= 1 }
            guard para.length == 0 else { return false }
            kind = (textView.typingAttributes[.msKind] as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
        }
        guard kind == .bullet || kind == .numbered || kind == .quote else { return false }
        setKind(.body)
        return true
    }

    /// After Return: a new, empty paragraph after a heading (or title, or
    /// figure) is body text.
    func didInsertNewline() {
        let ns = storage.string as NSString
        let loc = textView.selectedRange().location
        guard loc > 0, loc <= ns.length else { return }
        let previous = DocumentReader.kind(storage, at: loc - 1)
        guard !previous.continuesAfterReturn else { return }
        let attrs = EditorStyle.attributes(.body)
        if loc < ns.length, ns.character(at: loc) == 10 {
            storage.setAttributes(attrs, range: NSRange(location: loc, length: 1))
        }
        textView.typingAttributes = attrs
    }

    /// A paragraph marked as a figure that lost its figure is body text again.
    private func normaliseParagraph() {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let loc = min(textView.selectedRange().location, ns.length - 1)
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        guard para.length > 0 else { return }
        let kind = DocumentReader.kind(storage, at: para.location)
        guard kind == .figure || kind == .refs else { return }
        guard blockAttachments(in: para).isEmpty else { return }
        storage.beginEditing()
        storage.addAttributes(EditorStyle.attributes(.body), range: para)
        storage.endEditing()
        fixTypingAttributes()
    }

    // MARK: Formatting

    private func paragraphRanges(in range: NSRange) -> [NSRange] {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return [] }
        let full = ns.paragraphRange(for: range)
        var out: [NSRange] = []
        var start = full.location
        while start < NSMaxRange(full) {
            let p = ns.paragraphRange(for: NSRange(location: start, length: 0))
            out.append(p)
            start = NSMaxRange(p)
            if p.length == 0 { break }
        }
        return out
    }

    func currentKind() -> ParaKind {
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        guard ns.length > 0 else { return (textView.typingAttributes[.msKind] as? String).flatMap(ParaKind.init(rawValue:)) ?? .body }
        let p = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        if p.length == 0 || (sel.location >= ns.length && sel.location > 0 && ns.character(at: ns.length - 1) == 10) {
            return (textView.typingAttributes[.msKind] as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
        }
        return DocumentReader.kind(storage, at: p.location)
    }

    /// Makes the selected paragraphs `kind` (keeping bold and italic).
    func setKind(_ kind: ParaKind) {
        guard textView.isEditable else { return NSSound.beep() }
        let sel = textView.selectedRange()
        let ns = storage.string as NSString
        if kind == .title, ns.length > 0 {
            // Only the first paragraph can be the title.
            let first = ns.paragraphRange(for: NSRange(location: 0, length: 0))
            guard NSMaxRange(sel) <= NSMaxRange(first) else { return NSSound.beep() }
        }
        let paragraphs = paragraphRanges(in: sel)
        // At the very end (an empty last paragraph), only the typing attributes change.
        let atEnd = ns.length == 0 || (sel.location == ns.length && ns.character(at: ns.length - 1) == 10)
        if paragraphs.isEmpty || atEnd {
            textView.typingAttributes = EditorStyle.attributes(kind)
            return
        }
        guard let full = paragraphs.first.map({ NSUnionRange($0, paragraphs.last ?? $0) }),
              textView.shouldChangeText(in: full, replacementString: nil) else { return }
        storage.beginEditing()
        for p in paragraphs {
            guard blockAttachments(in: p).isEmpty else { continue }
            let existingID = p.length > 0 ? storage.attribute(.msHeadingID, at: p.location, effectiveRange: nil) as? String : nil
            let headingID = kind.isHeading ? (existingID ?? TextTools.randomID(prefix: "h-")) : nil
            let unnumbered = p.length > 0 ? (storage.attribute(.msUnnumbered, at: p.location, effectiveRange: nil) as? Bool ?? false) : false
            var runs: [(NSRange, Bool, Bool)] = []
            storage.enumerateAttributes(in: p, options: []) { attrs, r, _ in
                runs.append((r, attrs[.msBold] as? Bool ?? false, attrs[.msItalic] as? Bool ?? false))
            }
            for (r, b, i) in runs {
                storage.addAttributes(EditorStyle.attributes(kind, bold: b, italic: i, headingID: headingID,
                                                             unnumbered: kind.isHeading && unnumbered), range: r)
            }
            if !kind.isHeading {
                storage.removeAttribute(.msHeadingID, range: p)
                storage.removeAttribute(.msUnnumbered, range: p)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        textView.typingAttributes = EditorStyle.attributes(kind)
        fixTypingAttributes()
    }

    /// Lists and quotes toggle back to body text.
    func toggleKind(_ kind: ParaKind) {
        setKind(currentKind() == kind ? .body : kind)
    }

    func toggleUnnumbered() {
        let sel = textView.selectedRange()
        let headings = paragraphRanges(in: sel).filter { $0.length > 0 && DocumentReader.kind(storage, at: $0.location).isHeading }
        guard let first = headings.first, let last = headings.last else { return NSSound.beep() }
        let allUnnumbered = headings.allSatisfy { storage.attribute(.msUnnumbered, at: $0.location, effectiveRange: nil) as? Bool ?? false }
        let full = NSUnionRange(first, last)
        guard textView.shouldChangeText(in: full, replacementString: nil) else { return }
        storage.beginEditing()
        for p in headings {
            if allUnnumbered { storage.removeAttribute(.msUnnumbered, range: p) } else { storage.addAttribute(.msUnnumbered, value: true, range: p) }
        }
        storage.endEditing()
        textView.didChangeText()
        session.changed()
    }

    var isUnnumberedHeading: Bool {
        let loc = textView.selectedRange().location
        guard loc < storage.length, DocumentReader.kind(storage, at: loc).isHeading else { return false }
        return storage.attribute(.msUnnumbered, at: loc, effectiveRange: nil) as? Bool ?? false
    }

    /// Bold (`bold`) or italic, on the selection or for what's typed next.
    func toggleStyle(bold: Bool) {
        guard textView.isEditable else { return NSSound.beep() }
        let key: NSAttributedString.Key = bold ? .msBold : .msItalic
        let sel = textView.selectedRange()
        if sel.length == 0 {
            var t = textView.typingAttributes
            let kind = (t[.msKind] as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
            var b = t[.msBold] as? Bool ?? false
            var i = t[.msItalic] as? Bool ?? false
            if bold { b.toggle() } else { i.toggle() }
            t[.msBold] = b
            t[.msItalic] = i
            t[.font] = EditorStyle.font(kind, bold: b, italic: i)
            textView.typingAttributes = t
            return
        }
        var all = true
        storage.enumerateAttributes(in: sel, options: []) { attrs, r, stop in
            let text = (self.storage.string as NSString).substring(with: r)
            if text.allSatisfy({ $0 == "\n" }) { return }
            if !(attrs[key] as? Bool ?? false) {
                all = false
                stop.pointee = true
            }
        }
        let newValue = !all
        guard textView.shouldChangeText(in: sel, replacementString: nil) else { return }
        var runs: [(NSRange, ParaKind, Bool, Bool)] = []
        storage.enumerateAttributes(in: sel, options: []) { attrs, r, _ in
            let kind = (attrs[.msKind] as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
            runs.append((r, kind, attrs[.msBold] as? Bool ?? false, attrs[.msItalic] as? Bool ?? false))
        }
        storage.beginEditing()
        for (r, kind, b, i) in runs {
            let nb = bold ? newValue : b
            let ni = bold ? i : newValue
            storage.addAttributes([.font: EditorStyle.font(kind, bold: nb, italic: ni), key: newValue], range: r)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    var selectionIsBold: Bool { styleFlag(.msBold) }
    var selectionIsItalic: Bool { styleFlag(.msItalic) }

    private func styleFlag(_ key: NSAttributedString.Key) -> Bool {
        let sel = textView.selectedRange()
        if sel.length == 0 { return textView.typingAttributes[key] as? Bool ?? false }
        return storage.attribute(key, at: sel.location, effectiveRange: nil) as? Bool ?? false
    }

    // MARK: Inserting

    private func typingKindAndStyle() -> (ParaKind, InlineStyle, String?) {
        let t = textView.typingAttributes
        var kind = (t[.msKind] as? String).flatMap(ParaKind.init(rawValue:)) ?? .body
        if kind == .figure || kind == .refs { kind = .body }
        return (kind, InlineStyle(bold: t[.msBold] as? Bool ?? false, italic: t[.msItalic] as? Bool ?? false),
                t[.msHeadingID] as? String)
    }

    private func insert(_ attr: NSAttributedString, at range: NSRange? = nil) {
        guard textView.isEditable else { return NSSound.beep() }
        let r = range ?? textView.selectedRange()
        guard textView.shouldChangeText(in: r, replacementString: attr.string) else { return }
        storage.replaceCharacters(in: r, with: attr)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: r.location + attr.length, length: 0))
    }

    func insertToken(_ token: Token) {
        let (kind, style, id) = typingKindAndStyle()
        insert(DocumentBuilder.token(token, kind: kind, style: style, info: session.info, headingID: id))
    }

    func insertFootnote() {
        insertToken(.footnote([]))
        let loc = textView.selectedRange().location - 1
        if loc >= 0, let t = storage.attribute(.attachment, at: loc, effectiveRange: nil) as? TokenAttachment {
            session.analyze()
            editNote(t, at: rect(forCharacter: loc))
        }
    }

    func insertNote() {
        insertToken(.note(""))
        let loc = textView.selectedRange().location - 1
        if loc >= 0, let t = storage.attribute(.attachment, at: loc, effectiveRange: nil) as? TokenAttachment {
            editNote(t, at: rect(forCharacter: loc))
        }
    }

    func insertCitation(_ citation: Citation) {
        let undo = session.undoManager
        undo.beginUndoGrouping()
        insertToken(.citation(citation))
        session.analyze()
        if session.analysis.referencesHeadingLocation != nil && !session.analysis.hasReferenceList {
            insertReferenceList()
        }
        undo.endUndoGrouping()
    }

    /// The reference list, under the References heading (made at the end if missing).
    func insertReferenceList() {
        session.analyze()
        let selection = textView.selectedRange()
        let info = session.info
        let list = DocumentBuilder.paragraph(.referenceList, info: info).0
        let ns = storage.string as NSString
        if let headingLocation = session.analysis.referencesHeadingLocation {
            var para = ns.paragraphRange(for: NSRange(location: headingLocation, length: 0))
            if para.length > 0, ns.character(at: NSMaxRange(para) - 1) == 10 { para.length -= 1 }
            let s = NSMutableAttributedString(string: "\n", attributes: storage.attributes(at: para.location, effectiveRange: nil))
            s.removeAttribute(.attachment, range: NSRange(location: 0, length: 1))
            s.append(list)
            insert(s, at: NSRange(location: NSMaxRange(para), length: 0))
        } else {
            let s = NSMutableAttributedString()
            if ns.length > 0 { s.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(.body))) }
            s.append(DocumentBuilder.inlines([.text("References", .plain)], kind: .h1, info: info))
            s.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(.h1)))
            s.append(list)
            insert(s, at: NSRange(location: ns.length, length: 0))
        }
        textView.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
    }

    /// Inserts a figure or table after the current paragraph (or in place of
    /// an empty one).
    func insertFigure(_ figure: Figure) {
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        let block = DocumentBuilder.paragraph(.figure(figure), info: session.info).0
        guard ns.length > 0 else {
            insert(block, at: NSRange(location: 0, length: 0))
            return
        }
        var para = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let atEndEmpty = sel.location >= ns.length && ns.character(at: ns.length - 1) == 10
        if para.length > 0, NSMaxRange(para) <= ns.length, ns.character(at: NSMaxRange(para) - 1) == 10 { para.length -= 1 }
        if atEndEmpty {
            insert(block, at: NSRange(location: ns.length, length: 0))
        } else if para.length == 0 {
            insert(block, at: NSRange(location: para.location, length: 0))
        } else {
            let s = NSMutableAttributedString(string: "\n", attributes: EditorStyle.attributes(DocumentReader.kind(storage, at: para.location)))
            s.append(block)
            insert(s, at: NSRange(location: NSMaxRange(para), length: 0))
        }
    }

    func insertMarkdown(_ markdown: String) -> Bool {
        let recognizer = session.pasteRecognizer()
        let blocks = BlockMarkdown.parse(markdown).blocks.map { block in block.mappingInlines { recognizer.recognize($0) } }
        return insertBlocks(blocks)
    }

    func insertBlocks(_ blocks: [Block]) -> Bool {
        guard !blocks.isEmpty else { return false }
        let (kind, _, id) = typingKindAndStyle()
        if blocks.count == 1, case .paragraph(let inlines) = blocks[0] {
            insert(DocumentBuilder.inlines(inlines, kind: kind, info: session.info, headingID: id))
            return true
        }
        let s = NSMutableAttributedString(attributedString: DocumentBuilder.blocks(blocks, info: session.info))
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        let para = ns.length == 0 ? NSRange(location: 0, length: 0) : ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let atStart = sel.location == para.location
        let atEnd = NSMaxRange(sel) >= ns.length || ns.character(at: NSMaxRange(sel)) == 10
        if case .figure? = blocks.first, !atStart {
            s.insert(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(kind)), at: 0)
        }
        if case .figure? = blocks.last, !atEnd {
            s.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(.body)))
        }
        insert(s)
        return true
    }

    func insertPlainText(_ text: String) -> Bool {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs: [String]
        if t.contains("\n\n") {
            paragraphs = t.components(separatedBy: "\n\n").map {
                $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        } else {
            paragraphs = t.components(separatedBy: "\n")
        }
        let (kind, style, id) = typingKindAndStyle()
        let s = NSMutableAttributedString()
        for (k, p) in paragraphs.enumerated() {
            let pk: ParaKind = k == 0 ? kind : .body
            if k > 0 { s.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(k == 1 ? kind : .body, headingID: id))) }
            s.append(NSAttributedString(string: p, attributes: EditorStyle.attributes(pk, bold: k == 0 && style.bold,
                                                                                      italic: k == 0 && style.italic,
                                                                                      headingID: k == 0 ? id : nil)))
        }
        guard s.length > 0 else { return false }
        insert(s)
        return true
    }

    /// Rich text from another app: bold and italic come along, nothing else.
    func insertForeignText(_ attr: NSAttributedString) -> Bool {
        let text = attr.string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        guard text.count == attr.string.count else { return insertPlainText(attr.string) }
        let (kind, _, id) = typingKindAndStyle()
        let s = NSMutableAttributedString()
        var paragraphIndex = 0
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length), options: []) { value, r, _ in
            let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let piece = (text as NSString).substring(with: r)
            for (k, line) in piece.components(separatedBy: "\n").enumerated() {
                if k > 0 {
                    s.append(NSAttributedString(string: "\n", attributes: EditorStyle.attributes(paragraphIndex == 0 ? kind : .body,
                                                                                                  headingID: id)))
                    paragraphIndex += 1
                }
                let pk: ParaKind = paragraphIndex == 0 ? kind : .body
                s.append(NSAttributedString(string: line, attributes: EditorStyle.attributes(
                    pk, bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask),
                    headingID: paragraphIndex == 0 ? id : nil)))
            }
        }
        guard s.length > 0 else { return false }
        insert(s)
        return true
    }

    func insertImageData(_ data: Data, name: String, kind: FigureKind = .figure) -> Bool {
        do {
            let path = try session.addImage(data, preferredName: name, kind: kind)
            insertFigure(Figure(path: path, kind: kind))
            session.analyze()
            if let loc = locationOfFigure(path), let f = storage.attribute(.attachment, at: loc, effectiveRange: nil) as? FigureAttachment {
                editCaption(f, at: rect(forCharacter: loc))
            }
            return true
        } catch {
            state?.errorMessage = "Couldn’t add the picture: \(error.localizedDescription)"
            return false
        }
    }

    func insertImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "tif", "tiff", "gif", "heic"].contains(ext), let data = try? Data(contentsOf: url) else {
            return insertPlainText(url.path)
        }
        return insertImageData(data, name: url.deletingPathExtension().lastPathComponent)
    }

    private func locationOfFigure(_ path: String) -> Int? {
        var found: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, r, stop in
            if let f = value as? FigureAttachment, f.figure.path == path {
                found = r.location
                stop.pointee = true
            }
        }
        return found
    }

    func beginVariableFromSelection() {
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return NSSound.beep() }
        let text = session.displayString(sel).trimmingCharacters(in: .whitespacesAndNewlines)
        state?.sheet = .newVariable(text)
    }

    /// Replaces the selection with a new variable holding its text.
    func makeVariableFromSelection(name: String, value: String) {
        let finalName = session.addVariable(name: name, value: value)
        insertToken(.variable(finalName))
    }

    // MARK: Copying

    func markdownForSelection() -> String {
        let sub = storage.attributedSubstring(from: textView.selectedRange())
        let read = DocumentReader.read(sub)
        var blocks = read.blocks
        if !read.title.isEmpty { blocks.insert(.paragraph(read.title), at: 0) }
        let info = session.info
        var context = BlockMarkdown.WriteContext(numbering: info.numbering, tokenText: { info.plainText($0) }, referenceEntries: [])
        return BlockMarkdown.write(blocks, context: &context)
    }

    func plainTextForSelection() -> String {
        let sel = textView.selectedRange()
        var out = ""
        let ns = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: sel, options: []) { value, r, _ in
            switch value {
            case let t as TokenAttachment:
                out += session.info.plainText(t.token)
            case let f as FigureAttachment:
                out += "[\(session.info.numbering.figureLabel(f.figure.path) ?? f.figure.kind.label)]"
            case is ReferenceListAttachment:
                out += session.info.referenceEntries.map(\.string).joined(separator: "\n")
            default:
                out += ns.substring(with: r)
            }
        }
        return out
    }

    // MARK: Popover editors

    private func rect(forCharacter index: Int) -> NSRect {
        guard index < storage.length else { return .zero }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        var r = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        r.origin.x += textView.textContainerOrigin.x
        r.origin.y += textView.textContainerOrigin.y
        return r
    }

    private func present<V: View>(_ view: V, at rect: NSRect) {
        popover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: view.modifier(NoWritingTools()))
        p.show(relativeTo: rect.isEmpty ? NSRect(x: rect.minX, y: rect.minY, width: 1, height: 1) : rect, of: textView, preferredEdge: .maxY)
        popover = p
    }

    private func closePopover() {
        popover?.close()
        popover = nil
    }

    func editNote(_ attachment: TokenAttachment, at rect: NSRect) {
        let isFootnote: Bool
        let text: String
        switch attachment.token {
        case .footnote(let inner):
            isFootnote = true
            text = InlineMarkdown.emit(inner) { t in
                if case .variable(let n) = t { return "{{\(n)}}" }
                return InlineMarkdown.escapeText(self.session.info.plainText(t))
            }
        case .note(let t):
            isFootnote = false
            text = t
        default:
            return
        }
        let number = session.info.footnoteNumbers[ObjectIdentifier(attachment)] ?? 0
        let view = NoteEditor(title: isFootnote ? "Footnote \(number > 0 ? String(number) : "")" : "Note to self",
                              detail: isFootnote ? "Use *italic* and **bold**; {{name}} for a variable."
                                  : "Notes are never exported or counted.",
                              text: text,
                              onDone: { [weak self] newText in
                                  guard let self else { return }
                                  if isFootnote {
                                      attachment.token = .footnote(InlineMarkdown.parse(newText).trimmed)
                                  } else {
                                      attachment.token = .note(newText.trimmingCharacters(in: .whitespacesAndNewlines))
                                  }
                                  self.session.changed()
                                  self.closePopover()
                              },
                              onDelete: { [weak self] in self?.deleteAttachment(attachment) })
        present(view, at: rect)
    }

    func editCitation(_ attachment: TokenAttachment, at rect: NSRect) {
        guard case .citation(let c) = attachment.token else { return }
        let library = session.library
        let sources = c.sources.map { id -> (String, String) in
            if let r = library?.records[id] { return (id, "\(r.shortLabel) \(r.title)") }
            return (id, id + (library == nil ? "" : " (not in the library)"))
        }
        let view = CitationEditor(sources: sources, narrative: c.narrative, locator: c.locator,
                                  onDone: { [weak self] narrative, locator in
                                      guard let self else { return }
                                      var updated = c
                                      updated.narrative = narrative
                                      updated.locator = locator.trimmingCharacters(in: .whitespaces)
                                      attachment.token = .citation(updated)
                                      self.session.changed()
                                      self.closePopover()
                                  },
                                  onDelete: { [weak self] in self?.deleteAttachment(attachment) })
        present(view, at: rect)
    }

    func editVariable(_ name: String, at rect: NSRect) {
        let value = session.variables.first(where: { $0.name == name })?.value
        let view = VariableValueEditor(name: name, value: value ?? "", exists: value != nil) { [weak self] newValue in
            guard let self else { return }
            if value == nil {
                self.session.setVariables(self.session.variables + [Variable(name: name, value: newValue)])
            } else {
                self.session.setValue(newValue, of: name)
            }
            self.closePopover()
        }
        present(view, at: rect)
    }

    func editCaption(_ attachment: FigureAttachment, at rect: NSRect) {
        let caption = InlineMarkdown.emit(attachment.figure.caption) { t in
            if case .variable(let n) = t { return "{{\(n)}}" }
            return InlineMarkdown.escapeText(self.session.info.plainText(t))
        }
        let view = CaptionEditor(kind: attachment.figure.kind, path: attachment.figure.path, caption: caption,
                                 onDone: { [weak self] kind, newCaption in
                                     guard let self else { return }
                                     let recognizer = self.session.pasteRecognizer()
                                     attachment.figure.kind = kind
                                     attachment.figure.caption = recognizer.recognize(InlineMarkdown.parse(newCaption).trimmed)
                                     self.session.changed()
                                     self.closePopover()
                                 },
                                 onDelete: { [weak self] in self?.deleteAttachment(attachment) })
        present(view, at: rect)
    }

    private func deleteAttachment(_ attachment: NSTextAttachment) {
        closePopover()
        var location: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, r, stop in
            if (value as? NSTextAttachment) === attachment {
                location = r.location
                stop.pointee = true
            }
        }
        guard let location else { return }
        var range = NSRange(location: location, length: 1)
        // A figure takes its paragraph break with it.
        if attachment is BlockAttachment {
            let ns = storage.string as NSString
            if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) == 10 {
                range.length += 1
            } else if range.location > 0, ns.character(at: range.location - 1) == 10 {
                range = NSRange(location: range.location - 1, length: 2)
            }
        }
        insert(NSAttributedString(string: ""), at: range)
    }
}
