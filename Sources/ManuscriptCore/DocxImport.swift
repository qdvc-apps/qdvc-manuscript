import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads a Word document into a manuscript: the title, headings, paragraphs,
/// quotes, lists, bold and italic, footnotes, and pictures with their
/// captions (as figures and tables). Everything else (fields, comments,
/// tracked deletions, Word tables' layout) is left behind.
public enum DocxImport {
    public struct Result {
        public var manuscript: Manuscript
        /// Workspace path → image file contents, for the figures.
        public var images: [(path: String, data: Data)]
        /// What the user should know about the import.
        public var notes: [String]
    }

    enum RawInline {
        case text(String, InlineStyle)
        case footnote(String)
    }

    struct RawParagraph {
        var styleID = ""
        var numID = ""
        var outlineLevel: Int?
        var content: [RawInline] = []
        var imageRel: String?
        var inTable = false
        var footnoteID: String?
    }

    public static func read(_ data: Data) throws -> Result {
        let zip = try ZipReader(data: data)
        guard let documentXML = try zip.data("word/document.xml") else { throw ZipReader.ZipError.notAZip }
        var notes: [String] = []

        // Style names ("heading 1", "Title", "Quote"), whatever the language.
        var styleNames: [String: String] = [:]
        var styleLevels: [String: Int] = [:]
        if let stylesXML = try? zip.data("word/styles.xml") {
            let collector = StylesCollector()
            let parser = XMLParser(data: stylesXML)
            parser.delegate = collector
            parser.parse()
            styleNames = collector.names
            styleLevels = collector.levels
        }
        // Numbering: which lists are bulleted.
        var bulletNums = Set<String>()
        if let numberingXML = try? zip.data("word/numbering.xml") {
            let collector = NumberingCollector()
            let parser = XMLParser(data: numberingXML)
            parser.delegate = collector
            parser.parse()
            for (num, abstract) in collector.numToAbstract where collector.bulletAbstracts.contains(abstract) {
                bulletNums.insert(num)
            }
        }
        // Relationships: picture files.
        var rels: [String: String] = [:]
        if let relsXML = try? zip.data("word/_rels/document.xml.rels") {
            let collector = RelsCollector()
            let parser = XMLParser(data: relsXML)
            parser.delegate = collector
            parser.parse()
            rels = collector.targets
        }
        // Footnotes.
        var footnotes: [String: [Inline]] = [:]
        if let footnotesXML = try? zip.data("word/footnotes.xml") {
            let collector = ParagraphCollector()
            let parser = XMLParser(data: footnotesXML)
            parser.delegate = collector
            parser.parse()
            for p in collector.paragraphs {
                guard let id = p.footnoteID, let n = Int(id), n > 0 else { continue }
                let inlines = resolve(p.content, footnotes: [:])
                if let existing = footnotes[id], !existing.isEmpty {
                    footnotes[id] = existing + [.text(" ", .plain)] + inlines
                } else {
                    footnotes[id] = inlines
                }
            }
            for (id, inlines) in footnotes { footnotes[id] = inlines.trimmed }
        }

        let collector = ParagraphCollector()
        let parser = XMLParser(data: documentXML)
        parser.delegate = collector
        guard parser.parse() || !collector.paragraphs.isEmpty else { throw ZipReader.ZipError.corrupt("word/document.xml") }

        enum Raw {
            case block(Block)
            case image(Data, String)
            case caption([Inline])
        }
        var raws: [Raw] = []
        var title: [Inline] = []
        var sawTable = false
        var skippedImages = 0
        for p in collector.paragraphs {
            if p.inTable { sawTable = true }
            let name = (styleNames[p.styleID] ?? p.styleID).lowercased()
            if let rel = p.imageRel, let target = rels[rel] {
                let path = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
                if let image = try? zip.data(path) {
                    let ext = (target.split(separator: ".").last.map(String.init) ?? "png").lowercased()
                    if ["png", "jpg", "jpeg", "gif", "tif", "tiff"].contains(ext) {
                        raws.append(.image(image, ext == "jpg" ? "jpeg" : ext))
                    } else {
                        skippedImages += 1
                    }
                }
            }
            let inlines = resolve(p.content, footnotes: footnotes).trimmed
            if inlines.isEmpty { continue }
            let level = name.hasPrefix("heading ") ? Int(name.dropFirst(8)) : (p.outlineLevel ?? styleLevels[p.styleID]).map { $0 + 1 }
            if name == "title" {
                if title.isEmpty { title = inlines } else { raws.append(.block(.heading(Heading(level: 1, inlines: inlines)))) }
            } else if let level, level >= 1, level <= 9 {
                raws.append(.block(.heading(Heading(level: min(level, 4), inlines: inlines))))
            } else if name == "caption" {
                raws.append(.caption(inlines))
            } else if name.hasPrefix("quote") || name == "intense quote" || name == "block text" {
                raws.append(.block(.quote(inlines)))
            } else if name.hasPrefix("list bullet") {
                raws.append(.block(.bullet(inlines)))
            } else if name.hasPrefix("list number") {
                raws.append(.block(.numbered(inlines)))
            } else if !p.numID.isEmpty, p.numID != "0" {
                raws.append(.block(bulletNums.contains(p.numID) ? .bullet(inlines) : .numbered(inlines)))
            } else {
                raws.append(.block(.paragraph(inlines)))
            }
        }

        // Pair pictures with captions: a caption above makes a table, below a figure.
        var blocks: [Block] = []
        var images: [(path: String, data: Data)] = []
        var counts: [FigureKind: Int] = [.figure: 0, .table: 0]
        func addFigure(_ data: Data, _ ext: String, caption: [Inline], captionAbove: Bool) {
            var kind: FigureKind = captionAbove ? .table : .figure
            var text = caption
            if case .text(let t, let s)? = text.first,
               let m = BlockMarkdown.captionLabel.firstMatch(t), let r = Range(m.range, in: t) {
                let word = BlockMarkdown.captionLabel.group(m, 1, in: t) ?? "Figure"
                kind = word == "Table" ? .table : .figure
                text[0] = .text(String(t[r.upperBound...]), s)
                text = text.trimmed
            }
            counts[kind, default: 0] += 1
            let path = "\(kind.folder)/\(kind.label.lowercased())-\(counts[kind] ?? 1).\(ext)"
            images.append((path, data))
            blocks.append(.figure(Figure(path: path, kind: kind, caption: text)))
        }
        var k = 0
        while k < raws.count {
            switch raws[k] {
            case .block(let b):
                blocks.append(b)
                k += 1
            case .image(let data, let ext):
                if k + 1 < raws.count, case .caption(let c) = raws[k + 1] {
                    addFigure(data, ext, caption: c, captionAbove: false)
                    k += 2
                } else {
                    addFigure(data, ext, caption: [], captionAbove: false)
                    k += 1
                }
            case .caption(let c):
                if k + 1 < raws.count, case .image(let data, let ext) = raws[k + 1] {
                    addFigure(data, ext, caption: c, captionAbove: true)
                    k += 2
                } else {
                    blocks.append(.paragraph(c))
                    k += 1
                }
            }
        }
        if sawTable {
            notes.append("Word tables were turned into plain paragraphs; consider replacing each with a screenshot (Insert › Table).")
        }
        if skippedImages > 0 {
            notes.append("\(skippedImages) picture(s) in a format QDVC Manuscript can't show (such as EMF) were left out.")
        }
        notes.append("Citations and the reference list came in as plain text; re-insert citations from QDVC Bibliotheca to manage them.")
        let manuscript = Manuscript(title: title, blocks: blocks)
        return Result(manuscript: manuscript, images: images, notes: notes)
    }

    static func resolve(_ raw: [RawInline], footnotes: [String: [Inline]]) -> [Inline] {
        var out: [Inline] = []
        for r in raw {
            switch r {
            case .text(let t, let s): out.append(.text(t, s))
            case .footnote(let id):
                if let content = footnotes[id] { out.append(.token(.footnote(content), .plain)) }
            }
        }
        return out.coalesced
    }

    static func localName(_ qualified: String) -> String {
        if let colon = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: colon)...]) }
        return qualified
    }

    static func attribute(_ attrs: [String: String], _ name: String) -> String? {
        if let v = attrs["w:" + name] { return v }
        for (k, v) in attrs where localName(k) == name { return v }
        return nil
    }

    static func isOn(_ attrs: [String: String]) -> Bool {
        guard let v = attribute(attrs, "val")?.lowercased() else { return true }
        return !(v == "0" || v == "false" || v == "off" || v == "none")
    }

    // MARK: XML collectors

    final class ParagraphCollector: NSObject, XMLParserDelegate {
        var paragraphs: [RawParagraph] = []
        private var stack: [RawParagraph] = []
        private var inRun = false
        private var inRunProperties = false
        private var inParagraphProperties = false
        private var inText = false
        private var bold = false
        private var italic = false
        private var fallbackDepth = 0
        private var tableDepth = 0
        private var footnoteID: String?

        private func append(_ text: String) {
            guard !stack.isEmpty, !text.isEmpty else { return }
            stack[stack.count - 1].content.append(.text(text, InlineStyle(bold: bold, italic: italic)))
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = DocxImport.localName(elementName)
            switch name {
            case "p":
                var p = RawParagraph()
                p.inTable = tableDepth > 0
                p.footnoteID = footnoteID
                stack.append(p)
            case "pPr":
                inParagraphProperties = true
            case "pStyle":
                if inParagraphProperties, !stack.isEmpty { stack[stack.count - 1].styleID = DocxImport.attribute(attributeDict, "val") ?? "" }
            case "numId":
                if inParagraphProperties, !stack.isEmpty { stack[stack.count - 1].numID = DocxImport.attribute(attributeDict, "val") ?? "" }
            case "outlineLvl":
                if inParagraphProperties, !stack.isEmpty, let v = DocxImport.attribute(attributeDict, "val").flatMap({ Int($0) }), v < 9 {
                    stack[stack.count - 1].outlineLevel = v
                }
            case "r":
                inRun = true
                bold = false
                italic = false
            case "rPr":
                inRunProperties = true
            case "b":
                if inRun && inRunProperties { bold = DocxImport.isOn(attributeDict) }
            case "i":
                if inRun && inRunProperties { italic = DocxImport.isOn(attributeDict) }
            case "t":
                inText = inRun
            case "tab", "br", "cr", "noBreakHyphen":
                if inRun && !inRunProperties { append(name == "noBreakHyphen" ? "-" : " ") }
            case "footnoteReference":
                if let id = DocxImport.attribute(attributeDict, "id"), !stack.isEmpty {
                    stack[stack.count - 1].content.append(.footnote(id))
                }
            case "blip":
                if fallbackDepth == 0, !stack.isEmpty, stack[stack.count - 1].imageRel == nil {
                    stack[stack.count - 1].imageRel = attributeDict["r:embed"]
                        ?? attributeDict.first(where: { DocxImport.localName($0.key) == "embed" })?.value
                }
            case "Fallback":
                fallbackDepth += 1
            case "tbl":
                tableDepth += 1
            case "footnote":
                footnoteID = DocxImport.attribute(attributeDict, "id")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch DocxImport.localName(elementName) {
            case "p":
                if let p = stack.popLast() { paragraphs.append(p) }
            case "pPr": inParagraphProperties = false
            case "r": inRun = false
            case "rPr": inRunProperties = false
            case "t": inText = false
            case "Fallback": fallbackDepth = max(0, fallbackDepth - 1)
            case "tbl": tableDepth = max(0, tableDepth - 1)
            case "footnote": footnoteID = nil
            default: break
            }
        }
    }

    final class StylesCollector: NSObject, XMLParserDelegate {
        var names: [String: String] = [:]
        var levels: [String: Int] = [:]
        private var current: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch DocxImport.localName(elementName) {
            case "style":
                current = DocxImport.attribute(attributeDict, "styleId")
            case "name":
                if let current, let v = DocxImport.attribute(attributeDict, "val") { names[current] = v }
            case "outlineLvl":
                if let current, let v = DocxImport.attribute(attributeDict, "val").flatMap({ Int($0) }), v < 9 { levels[current] = v }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if DocxImport.localName(elementName) == "style" { current = nil }
        }
    }

    final class NumberingCollector: NSObject, XMLParserDelegate {
        var bulletAbstracts = Set<String>()
        var numToAbstract: [String: String] = [:]
        private var abstract: String?
        private var level: String?
        private var num: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch DocxImport.localName(elementName) {
            case "abstractNum": abstract = DocxImport.attribute(attributeDict, "abstractNumId")
            case "lvl": level = DocxImport.attribute(attributeDict, "ilvl")
            case "numFmt":
                if let abstract, level == "0", DocxImport.attribute(attributeDict, "val") == "bullet" { bulletAbstracts.insert(abstract) }
            case "num": num = DocxImport.attribute(attributeDict, "numId")
            case "abstractNumId":
                if let num, let v = DocxImport.attribute(attributeDict, "val") { numToAbstract[num] = v }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch DocxImport.localName(elementName) {
            case "abstractNum": abstract = nil
            case "lvl": level = nil
            case "num": num = nil
            default: break
            }
        }
    }

    final class RelsCollector: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if DocxImport.localName(elementName) == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"] {
                targets[id] = target
            }
        }
    }
}
