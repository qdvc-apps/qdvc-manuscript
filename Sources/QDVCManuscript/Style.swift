import AppKit
import ManuscriptCore
import SwiftUI

// MARK: - Paragraph kinds and attributes

/// What a paragraph in the editor is. Stored on every character of the
/// paragraph (its newline included) as `.msKind`.
enum ParaKind: String, CaseIterable {
    case body = "p"
    case title
    case h1, h2, h3, h4
    case quote
    case bullet
    case numbered
    case figure
    case refs

    var headingLevel: Int? {
        switch self {
        case .h1: return 1
        case .h2: return 2
        case .h3: return 3
        case .h4: return 4
        default: return nil
        }
    }

    static func heading(_ level: Int) -> ParaKind {
        switch level {
        case ...1: return .h1
        case 2: return .h2
        case 3: return .h3
        default: return .h4
        }
    }

    var isHeading: Bool { headingLevel != nil }

    /// Kinds the next paragraph continues after Return.
    var continuesAfterReturn: Bool { self == .body || self == .quote || self == .bullet || self == .numbered }

    var menuTitle: String {
        switch self {
        case .body: return "Body Text"
        case .title: return "Title"
        case .h1: return "Heading 1"
        case .h2: return "Heading 2"
        case .h3: return "Heading 3"
        case .h4: return "Heading 4"
        case .quote: return "Block Quote"
        case .bullet: return "Bulleted List"
        case .numbered: return "Numbered List"
        case .figure: return "Figure"
        case .refs: return "Reference List"
        }
    }
}

extension NSAttributedString.Key {
    static let msKind = NSAttributedString.Key("org.qdvc.ms.kind")
    static let msBold = NSAttributedString.Key("org.qdvc.ms.bold")
    static let msItalic = NSAttributedString.Key("org.qdvc.ms.italic")
    static let msHeadingID = NSAttributedString.Key("org.qdvc.ms.heading")
    static let msUnnumbered = NSAttributedString.Key("org.qdvc.ms.unnumbered")
}

extension NSPasteboard.PasteboardType {
    /// The selection as manuscript Markdown, so copy and paste inside the
    /// app keeps formatting, tokens and figures.
    static let manuscriptMarkdown = NSPasteboard.PasteboardType("org.qdvc.manuscript.markdown")
}

// MARK: - Editor typography

/// The editor's look: New York, the serif of QDVC Empirics' reading view,
/// generous leading, and a gap between paragraphs instead of empty lines.
enum EditorStyle {
    /// Text size in the text storage; windows zoom with magnification.
    static let size: CGFloat = 17
    static let lineHeightMultiple: CGFloat = 1.38

    static func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func font(_ kind: ParaKind, bold: Bool, italic: Bool) -> NSFont {
        switch kind {
        case .title: return serif(size * 1.7, bold: true, italic: italic)
        case .h1: return serif(size * 1.38, bold: true, italic: italic)
        case .h2: return serif(size * 1.18, bold: true, italic: italic)
        case .h3: return serif(size * 1.04, bold: true, italic: italic)
        case .h4: return serif(size, bold: true, italic: !italic)
        case .quote: return serif(size * 0.96, bold: bold, italic: italic)
        case .refs: return serif(size * 0.94, bold: bold, italic: italic)
        default: return serif(size, bold: bold, italic: italic)
        }
    }

    static func paragraphStyle(_ kind: ParaKind) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeightMultiple
        p.paragraphSpacing = size * 0.9
        switch kind {
        case .title:
            p.lineHeightMultiple = 1.1
            p.paragraphSpacing = size * 1.6
        case .h1:
            p.lineHeightMultiple = 1.15
            p.paragraphSpacingBefore = size * 1.3
            p.paragraphSpacing = size * 0.55
        case .h2, .h3, .h4:
            p.lineHeightMultiple = 1.15
            p.paragraphSpacingBefore = size * 0.9
            p.paragraphSpacing = size * 0.45
        case .quote:
            p.firstLineHeadIndent = size * 1.8
            p.headIndent = size * 1.8
            p.tailIndent = -size * 1.2
        case .bullet, .numbered:
            p.firstLineHeadIndent = size * 1.7
            p.headIndent = size * 1.7
            p.paragraphSpacing = size * 0.35
        case .figure, .refs:
            p.lineHeightMultiple = 1
            p.paragraphSpacingBefore = size * 0.4
            p.paragraphSpacing = size * 1.0
            p.alignment = kind == .figure ? .center : .natural
        case .body:
            break
        }
        return p
    }

    /// The attributes of text in a paragraph of `kind`.
    static func attributes(_ kind: ParaKind, bold: Bool = false, italic: Bool = false,
                           headingID: String? = nil, unnumbered: Bool = false) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .font: font(kind, bold: bold, italic: italic),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle(kind),
            .msKind: kind.rawValue,
            .msBold: bold,
            .msItalic: italic,
        ]
        if kind.isHeading {
            a[.msHeadingID] = headingID ?? TextTools.randomID(prefix: "h-")
            if unnumbered { a[.msUnnumbered] = true }
        }
        return a
    }

    // MARK: Colours

    static let topicColor = NSColor(name: "topic") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.62, green: 0.74, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.22, blue: 0.62, alpha: 1)
    }
    static let topicBackground = NSColor(name: "topicBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.25, green: 0.35, blue: 0.75, alpha: 0.28)
            : NSColor(srgbRed: 0.85, green: 0.89, blue: 1.0, alpha: 0.85)
    }
    static let fadedText = NSColor(name: "faded") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.26)
            : NSColor(white: 0, alpha: 0.22)
    }
    static let mutedText = NSColor(name: "muted") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.55)
            : NSColor(white: 0, alpha: 0.5)
    }
}

/// How wide the text column is.
enum MarginPreset: String, CaseIterable, Identifiable {
    case narrow, medium, wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .narrow: return "Narrow Margins"
        case .medium: return "Medium Margins"
        case .wide: return "Wide Margins"
        }
    }

    /// The text column's width, in points of unmagnified text.
    var columnWidth: CGFloat {
        switch self {
        case .narrow: return 860
        case .medium: return 700
        case .wide: return 580
        }
    }
}

enum TopicMode: String, CaseIterable, Identifiable {
    case off, accentuate, collapse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .accentuate: return "Accentuate Topic Sentences"
        case .collapse: return "Collapse to Topic Sentences"
        }
    }
}

// MARK: - Preferences (this Mac)

enum Prefs {
    static let margins = "margins"
    static let longSentenceWords = "longSentenceWords"
    static let spellChecking = "spellChecking"
    static let smartQuotes = "smartQuotes"
    static let typewriterPosition = "typewriterPosition"
    static let exportFont = "exportFont"
    static let exportSize = "exportSize"
    static let exportSpacing = "exportSpacing"
    static let exportPage = "exportPage"
    static let showWelcome = "showWelcomeAtLaunch"

    static func register() {
        UserDefaults.standard.register(defaults: [
            margins: MarginPreset.medium.rawValue,
            longSentenceWords: 40,
            spellChecking: true,
            smartQuotes: true,
            typewriterPosition: 0.42,
            exportFont: "Times New Roman",
            exportSize: 12.0,
            exportSpacing: 1.5,
            exportPage: DocxOptions.PageSize.a4.rawValue,
            showWelcome: true,
            "NSQuitAlwaysKeepsWindows": false,
        ])
    }

    static var docxOptions: DocxOptions {
        let d = UserDefaults.standard
        return DocxOptions(fontName: d.string(forKey: exportFont) ?? "Times New Roman",
                           fontSize: max(8, d.double(forKey: exportSize)),
                           lineSpacing: max(1, d.double(forKey: exportSpacing)),
                           pageSize: DocxOptions.PageSize(rawValue: d.string(forKey: exportPage) ?? "") ?? .a4)
    }
}

// MARK: - Small shared views

/// A transient message across the top of a window.
struct NoticeBanner: View {
    var text: String
    var isWarning = true
    var actions: [(String, () -> Void)] = []
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isWarning ? Color.orange : Color.accentColor)
            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action.0) { action.1() }.controlSize(.small)
            }
            Button("Dismiss", action: dismiss).buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Turns off Writing Tools (macOS 15 and later) for everything inside, so
/// no text is ever offered to a model or service from this app.
struct NoWritingTools: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            content.writingToolsBehavior(.disabled)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

enum Platform {
    @MainActor
    static func openSettings() {
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }

    /// Removes context-menu items that hand text to other apps or online
    /// services (Look Up, Translate, Search With…, Share, Services, Writing
    /// Tools), so nothing from the manuscript leaves the app that way.
    @MainActor
    static func stripOutsideServices(_ menu: NSMenu) {
        let titles = ["Look Up", "Translate", "Search With", "Share", "Services", "Writing Tools", "Show Writing Tools",
                      "AutoFill", "Font", "Layout Orientation", "Proofread", "Rewrite", "Summarize", "Make Table",
                      "Make List", "Compose"]
        let actions = ["lookUp", "translate", "search", "share", "service", "writingTools", "_rtfd", "orderFrontFontPanel"]
        for item in menu.items.reversed() {
            let title = item.title
            let action = item.action.map { NSStringFromSelector($0) } ?? ""
            if titles.contains(where: { title.hasPrefix($0) }) || actions.contains(where: { action.localizedCaseInsensitiveContains($0) }) {
                menu.removeItem(item)
            }
        }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var previousWasSeparator = false
        for item in menu.items.reversed() {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
