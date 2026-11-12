import Foundation

/// Word export settings (Settings › Export, remembered per Mac).
public struct DocxOptions: Equatable, Sendable {
    public enum PageSize: String, CaseIterable, Sendable {
        case a4, letter

        public var label: String { self == .a4 ? "A4" : "US Letter" }
    }

    public var fontName: String
    public var fontSize: Double
    /// 1 = single, 1.5, 2 = double.
    public var lineSpacing: Double
    public var pageSize: PageSize

    public init(fontName: String = "Times New Roman", fontSize: Double = 12, lineSpacing: Double = 1.5,
                pageSize: PageSize = .a4) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.pageSize = pageSize
    }
}

/// Writes the manuscript as a .docx, with Word styles (Title, Heading 1–4,
/// Quote, List Bullet, List Number, Caption, Bibliography), real footnotes
/// and embedded figures. Notes to self are left out; variables, citations
/// and cross-references are written as they read.
public enum DocxExport {
    static let margin = 1440

    /// `display` renders citations, cross-references and variables;
    /// `image` returns a figure's file contents by workspace path.
    public static func document(_ m: Manuscript, display: @escaping (Token) -> String, referenceEntries: [String],
                                image: (String) -> Data?, options: DocxOptions = DocxOptions(),
                                date: Date = Date()) -> Data {
        let numbering = Numbering(blocks: m.blocks)
        let pageWidth = options.pageSize == .a4 ? 11906 : 12240
        let pageHeight = options.pageSize == .a4 ? 16838 : 15840
        var w = Writer(display: display, textWidthTwips: pageWidth - 2 * margin)
        var body = ""
        let titleText = m.title.plainText(display)
        if !m.title.isEmpty {
            let runs = w.runs(m.title)
            body += Writer.paragraph(runs, properties: "<w:pStyle w:val=\"Title\"/>")
        }
        var previous: Block?
        for block in m.blocks {
            switch block {
            case .heading(let h):
                var runs = ""
                if m.settings.headingNumbers, let n = numbering.headings[h.id] {
                    runs += Writer.run(Numbering.headingLabel(n) + " ")
                }
                runs += w.runs(h.inlines)
                body += Writer.paragraph(runs, properties: "<w:pStyle w:val=\"Heading\(max(1, min(h.level, 4)))\"/>")
            case .paragraph(let inlines):
                if inlines.allSatisfy({ if case .token(.note, _) = $0 { return true } else { return false } }) { break }
                let runs = w.runs(inlines)
                body += Writer.paragraph(runs)
            case .quote(let inlines):
                let runs = w.runs(inlines)
                body += Writer.paragraph(runs, properties: "<w:pStyle w:val=\"Quote\"/>")
            case .bullet(let inlines):
                let runs = w.runs(inlines)
                body += Writer.paragraph(runs, properties: "<w:pStyle w:val=\"ListBullet\"/>")
            case .numbered(let inlines):
                if case .numbered? = previous {} else { w.startNumberedList() }
                let runs = w.runs(inlines)
                body += Writer.paragraph(runs, properties: "<w:pStyle w:val=\"ListNumber\"/>"
                                         + "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(w.currentNumId)\"/></w:numPr>")
            case .figure(let f):
                let label = "\(f.kind.label) \(numbering.figures[f.path] ?? 0)."
                let captionRuns = Writer.run(label, bold: true) + Writer.run(" ") + w.runs(f.caption)
                let caption = Writer.paragraph(captionRuns, properties: "<w:pStyle w:val=\"Caption\"/>"
                                               + (f.kind == .table ? "<w:keepNext/>" : ""))
                var picture = ""
                if let data = image(f.path) {
                    let name = f.path.split(separator: "/").last.map(String.init) ?? f.path
                    let drawing = w.picture(data, name: name)
                    picture = Writer.paragraph(drawing, properties: "<w:pStyle w:val=\"Figure\"/>"
                                               + (f.kind == .figure ? "<w:keepNext/>" : ""))
                } else {
                    picture = Writer.paragraph(Writer.run("[Missing image: \(f.path)]", italic: true),
                                               properties: "<w:pStyle w:val=\"Figure\"/>")
                }
                body += f.kind == .table ? caption + picture : picture + caption
            case .referenceList:
                for entry in referenceEntries {
                    let runs = w.runs(InlineMarkdown.parse(entry))
                    body += Writer.paragraph(runs, properties: "<w:pStyle w:val=\"Bibliography\"/>")
                }
            }
            previous = block
        }
        let sect = "<w:sectPr><w:footerReference w:type=\"default\" r:id=\"rId4\"/>"
            + "<w:pgSz w:w=\"\(pageWidth)\" w:h=\"\(pageHeight)\"/>"
            + "<w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" "
            + "w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>"
        let document = header + "<w:document xmlns:w=\"\(wNS)\" xmlns:r=\"\(rNS)\" xmlns:wp=\"\(wpNS)\" "
            + "xmlns:a=\"\(aNS)\" xmlns:pic=\"\(picNS)\"><w:body>" + body + sect + "</w:body></w:document>"

        var zip = ZipWriter(date: date)
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRels)
        zip.add("docProps/core.xml", coreProperties(title: titleText, date: date))
        zip.add("docProps/app.xml", appProperties)
        zip.add("word/document.xml", document)
        zip.add("word/styles.xml", styles(options))
        zip.add("word/numbering.xml", w.numberingXML())
        zip.add("word/settings.xml", settingsXML)
        zip.add("word/footer1.xml", footer)
        zip.add("word/footnotes.xml", w.footnotesXML())
        var rels = "<Relationship Id=\"rId1\" Type=\"\(relType)/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(relType)/numbering\" Target=\"numbering.xml\"/>"
            + "<Relationship Id=\"rId3\" Type=\"\(relType)/settings\" Target=\"settings.xml\"/>"
            + "<Relationship Id=\"rId4\" Type=\"\(relType)/footer\" Target=\"footer1.xml\"/>"
            + "<Relationship Id=\"rId5\" Type=\"\(relType)/footnotes\" Target=\"footnotes.xml\"/>"
        for media in w.media {
            zip.add("word/media/\(media.fileName)", media.data)
            rels += "<Relationship Id=\"\(media.relID)\" Type=\"\(relType)/image\" Target=\"media/\(media.fileName)\"/>"
        }
        zip.add("word/_rels/document.xml.rels", header
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + rels + "</Relationships>")
        return zip.finish()
    }

    // MARK: - Writer

    struct Media {
        var fileName: String
        var relID: String
        var data: Data
    }

    struct Writer {
        var display: (Token) -> String
        var textWidthTwips: Int
        var footnotes: [String] = []
        var media: [Media] = []
        var numberedLists = 0
        var drawingID = 0

        init(display: @escaping (Token) -> String, textWidthTwips: Int) {
            self.display = display
            self.textWidthTwips = textWidthTwips
        }

        var currentNumId: Int { numberedLists + 1 }

        mutating func startNumberedList() { numberedLists += 1 }

        static func escape(_ s: String) -> String {
            var out = ""
            out.reserveCapacity(s.count)
            for scalar in s.unicodeScalars {
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                default:
                    let v = scalar.value
                    if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out
        }

        static func run(_ text: String, bold: Bool = false, italic: Bool = false) -> String {
            guard !text.isEmpty else { return "" }
            var props = ""
            if bold { props += "<w:b/><w:bCs/>" }
            if italic { props += "<w:i/><w:iCs/>" }
            var out = "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>")
            let parts = text.replacingOccurrences(of: "\n", with: " ").components(separatedBy: "\t")
            for (j, part) in parts.enumerated() {
                if j > 0 { out += "<w:tab/>" }
                if !part.isEmpty { out += "<w:t xml:space=\"preserve\">\(Self.escape(part))</w:t>" }
            }
            return out + "</w:r>"
        }

        mutating func runs(_ inlines: [Inline], inFootnote: Bool = false) -> String {
            var out = ""
            for inline in inlines {
                switch inline {
                case .text(let t, let s):
                    out += Self.run(t, bold: s.bold, italic: s.italic)
                case .token(.note, _):
                    continue
                case .token(.footnote(let inner), _):
                    guard !inFootnote else { continue }
                    let id = footnotes.count + 1
                    footnotes.append("")   // reserve the number before nested runs
                    let content = "<w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>"
                        + "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r>"
                        + Self.run(" ") + runs(inner.trimmed, inFootnote: true) + "</w:p>"
                    footnotes[id - 1] = "<w:footnote w:id=\"\(id)\">\(content)</w:footnote>"
                    out += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(id)\"/></w:r>"
                case .token(let t, let s):
                    out += Self.run(display(t), bold: s.bold, italic: s.italic)
                }
            }
            return out
        }

        static func paragraph(_ runs: String, properties: String = "") -> String {
            "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs + "</w:p>"
        }

        mutating func picture(_ data: Data, name: String) -> String {
            drawingID += 1
            let n = drawingID
            let info = ImageInfo(data)
            let ext = info?.format ?? "png"
            let relID = "rIdImage\(n)"
            media.append(Media(fileName: "image\(n).\(ext)", relID: relID, data: data))
            // Size: the image's own resolution, at most the text width and 8 inches tall.
            let emuPerInch = 914_400.0
            var widthIn = Double(info?.width ?? 600) / (info?.dpiX ?? 144)
            var heightIn = Double(info?.height ?? 400) / (info?.dpiY ?? 144)
            let maxWidth = Double(textWidthTwips) / 1440
            if widthIn > maxWidth {
                heightIn *= maxWidth / widthIn
                widthIn = maxWidth
            }
            if heightIn > 8 {
                widthIn *= 8 / heightIn
                heightIn = 8
            }
            let cx = Int(widthIn * emuPerInch), cy = Int(heightIn * emuPerInch)
            let safeName = Self.escape(name)
            return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
                + "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(n)\" name=\"Picture \(n)\" descr=\"\(safeName)\"/>"
                + "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
                + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(n)\" name=\"\(safeName)\"/><pic:cNvPicPr/></pic:nvPicPr>"
                + "<pic:blipFill><a:blip r:embed=\"\(relID)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
                + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
                + "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        }

        func numberingXML() -> String {
            var out = header + "<w:numbering xmlns:w=\"\(wNS)\">"
                + "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"singleLevel\"/>"
                + "<w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\u{2022}\"/>"
                + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
                + "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"singleLevel\"/>"
                + "<w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/>"
                + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
                + "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
            if numberedLists > 0 {
                for k in 1...numberedLists {
                    out += "<w:num w:numId=\"\(k + 1)\"><w:abstractNumId w:val=\"1\"/>"
                        + "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
                }
            }
            return out + "</w:numbering>"
        }

        func footnotesXML() -> String {
            let separatorSpacing = "<w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>"
            return header + "<w:footnotes xmlns:w=\"\(wNS)\" xmlns:r=\"\(rNS)\">"
                + "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p>\(separatorSpacing)<w:r><w:separator/></w:r></w:p></w:footnote>"
                + "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p>\(separatorSpacing)<w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
                + footnotes.joined() + "</w:footnotes>"
        }
    }

    // MARK: - Package parts

    static let wNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let rNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let wpNS = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    static let aNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let picNS = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    static let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static let contentTypes = header + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="png" ContentType="image/png"/>\
    <Default Extension="jpeg" ContentType="image/jpeg"/>\
    <Default Extension="gif" ContentType="image/gif"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
    <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
    <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>\
    <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
    </Types>
    """

    static let rootRels = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """

    static let appProperties = header + """
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">\
    <Application>QDVC Manuscript</Application></Properties>
    """

    static func coreProperties(title: String, date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: date)
        return header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>\(Writer.escape(title))</dc:title><dc:creator>QDVC Manuscript</dc:creator>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
            + "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>"
            + "</cp:coreProperties>"
    }

    static let settingsXML = header + """
    <w:settings xmlns:w="\(wNS)"><w:defaultTabStop w:val="720"/>\
    <w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr>\
    <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat>\
    </w:settings>
    """

    static let footer = header + """
    <w:ftr xmlns:w="\(wNS)" xmlns:r="\(rNS)"><w:p><w:pPr><w:jc w:val="center"/></w:pPr>\
    <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>\
    <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>\
    </w:p></w:ftr>
    """

    static func styles(_ o: DocxOptions) -> String {
        let font = Writer.escape(o.fontName)
        let size = Int((o.fontSize * 2).rounded())
        let line = Int((240 * o.lineSpacing).rounded())
        func sz(_ halfPoints: Int) -> String { "<w:sz w:val=\"\(halfPoints)\"/><w:szCs w:val=\"\(halfPoints)\"/>" }
        func heading(_ level: Int, run: String) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/>"
                + "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(level == 1 ? 360 : 240)\" w:after=\"120\"/>"
                + "<w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr>\(run)</w:rPr></w:style>"
        }
        return header + "<w:styles xmlns:w=\"\(wNS)\">"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\" w:eastAsia=\"\(font)\" w:cs=\"\(font)\"/>"
            + sz(size) + "<w:lang w:val=\"en-GB\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"\(line)\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/>"
            + "<w:uiPriority w:val=\"1\"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:jc w:val=\"center\"/><w:spacing w:after=\"360\"/></w:pPr>"
            + "<w:rPr><w:b/><w:bCs/>\(sz(size + 8))</w:rPr></w:style>"
            + heading(1, run: "<w:b/><w:bCs/>" + sz(size + 4))
            + heading(2, run: "<w:b/><w:bCs/>" + sz(size + 2))
            + heading(3, run: "<w:b/><w:bCs/><w:i/><w:iCs/>" + sz(size))
            + heading(4, run: "<w:i/><w:iCs/>" + sz(size))
            + "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
            + "<w:pPr><w:ind w:left=\"720\" w:right=\"720\"/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"ListBullet\"><w:name w:val=\"List Bullet\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr><w:spacing w:after=\"80\"/><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"ListNumber\"><w:name w:val=\"List Number\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:pPr><w:spacing w:after=\"80\"/><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Figure\"><w:name w:val=\"Figure\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:pPr><w:jc w:val=\"center\"/><w:spacing w:before=\"120\" w:after=\"120\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Caption\"><w:name w:val=\"caption\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:after=\"240\"/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"Bibliography\"><w:name w:val=\"Bibliography\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:pPr><w:ind w:left=\"720\" w:hanging=\"720\"/></w:pPr></w:style>"
            + "<w:style w:type=\"paragraph\" w:styleId=\"FootnoteText\"><w:name w:val=\"footnote text\"/><w:basedOn w:val=\"Normal\"/>"
            + "<w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr>\(sz(max(16, size - 4)))</w:rPr></w:style>"
            + "<w:style w:type=\"character\" w:styleId=\"FootnoteReference\"><w:name w:val=\"footnote reference\"/>"
            + "<w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr></w:style>"
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/>"
            + "<w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar>"
            + "<w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/>"
            + "<w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
            + "</w:styles>"
    }
}

// MARK: - Image sizes

/// Pixel size, resolution and format of a PNG or JPEG, read from its header.
public struct ImageInfo: Equatable {
    public var width: Int
    public var height: Int
    public var dpiX: Double
    public var dpiY: Double
    /// "png" or "jpeg".
    public var format: String

    public init?(_ data: Data) {
        let b = [UInt8](data.prefix(256 * 1024))
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
            width = be32(16)
            height = be32(20)
            format = "png"
            dpiX = 72
            dpiY = 72
            // pHYs: pixels per metre.
            var p = 8
            var found = false
            while p + 8 <= b.count {
                let length = be32(p)
                let type = String(decoding: b[(p + 4)..<(p + 8)], as: UTF8.self)
                if type == "pHYs", p + 17 <= b.count, b[p + 16] == 1 {
                    dpiX = max(1, Double(be32(p + 8)) * 0.0254)
                    dpiY = max(1, Double(be32(p + 12)) * 0.0254)
                    found = true
                    break
                }
                if type == "IDAT" || type == "IEND" || length < 0 { break }
                p += 12 + length
            }
            if !found {
                dpiX = 72
                dpiY = 72
            }
            return
        }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 {
            format = "jpeg"
            dpiX = 72
            dpiY = 72
            var p = 2
            var w = 0, h = 0
            while p + 9 < b.count {
                guard b[p] == 0xFF else { p += 1; continue }
                let marker = b[p + 1]
                let length = Int(b[p + 2]) << 8 | Int(b[p + 3])
                if marker == 0xE0, p + 16 < b.count, b[p + 4] == 0x4A, b[p + 5] == 0x46 {   // JFIF
                    let units = b[p + 11]
                    let xd = Double(Int(b[p + 12]) << 8 | Int(b[p + 13]))
                    let yd = Double(Int(b[p + 14]) << 8 | Int(b[p + 15]))
                    if units == 1, xd > 0, yd > 0 { dpiX = xd; dpiY = yd }
                    if units == 2, xd > 0, yd > 0 { dpiX = xd * 2.54; dpiY = yd * 2.54 }
                }
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    h = Int(b[p + 5]) << 8 | Int(b[p + 6])
                    w = Int(b[p + 7]) << 8 | Int(b[p + 8])
                    break
                }
                p += 2 + max(length, 2)
            }
            guard w > 0, h > 0 else { return nil }
            width = w
            height = h
            return
        }
        return nil
    }
}
