import AppKit
import ManuscriptCore

/// The editor's text view: Return, copy and paste, drops and clicks are
/// passed to its EditorController; everything else is plain NSTextView.
final class ManuscriptTextView: NSTextView {
    weak var controller: EditorController?

    // MARK: Return

    override func insertNewline(_ sender: Any?) {
        if controller?.handleReturn() == true { return }
        super.insertNewline(sender)
        controller?.didInsertNewline()
    }

    override func insertLineBreak(_ sender: Any?) {
        // No soft line breaks: a manuscript has paragraphs, one sentence per line in the file.
        insertNewline(sender)
    }

    // MARK: Collapse mode

    override func mouseDown(with event: NSEvent) {
        if let controller, controller.topicMode == .collapse, event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            controller.expand(at: characterIndexForInsertion(at: point))
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Copy

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.manuscriptMarkdown, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let controller, selectedRange().length > 0 else { return super.writeSelection(to: pboard, type: type) }
        switch type {
        case .manuscriptMarkdown:
            return pboard.setString(controller.markdownForSelection(), forType: type)
        case .string:
            return pboard.setString(controller.plainTextForSelection(), forType: .string)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else {
            NSSound.beep()
            return
        }
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.declareTypes([.manuscriptMarkdown, .string], owner: nil)
        _ = writeSelection(to: pboard, type: .manuscriptMarkdown)
        _ = writeSelection(to: pboard, type: .string)
    }

    override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, isEditable else { return }
        copy(sender)
        insertText("", replacementRange: range)
    }

    // MARK: Paste and drop

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.manuscriptMarkdown, .fileURL, .png, .tiff, .rtf, .string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let controller, isEditable else { return false }
        switch type {
        case .manuscriptMarkdown:
            guard let s = pboard.string(forType: type) else { return false }
            return controller.insertMarkdown(s)
        case .fileURL:
            guard let s = pboard.string(forType: .fileURL), let url = URL(string: s), url.isFileURL else { return false }
            return controller.insertImageFile(url)
        case .png, .tiff:
            guard let data = pboard.data(forType: type) else { return false }
            return controller.insertImageData(data, name: "pasted-figure")
        case .rtf:
            guard let data = pboard.data(forType: .rtf),
                  let attr = NSAttributedString(rtf: data, documentAttributes: nil) else { return false }
            return controller.insertForeignText(attr)
        case .string:
            guard let s = pboard.string(forType: .string) else { return false }
            return controller.insertPlainText(s)
        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        _ = controller?.insertPlainText(s)
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    // MARK: Font panel and rulers stay out of the way

    override func changeFont(_ sender: Any?) {}
}

/// Hosts the scroll view, and tells the controller when its size changes
/// (the margins follow the window's width).
final class EditorHostView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for sub in subviews { sub.frame = bounds }
        onLayout?()
    }
}
