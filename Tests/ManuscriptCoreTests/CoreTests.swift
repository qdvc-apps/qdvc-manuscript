import Foundation
import XCTest
@testable import ManuscriptCore

final class SentenceTests: XCTestCase {
    func split(_ s: String) -> [String] {
        let u = Array(s.utf16)
        return Sentences.split(s).map { String(decoding: u[$0], as: UTF16.self) }
    }

    func testBasicSentences() {
        XCTAssertEqual(split("One sentence. Two sentences! Three? Four."),
                       ["One sentence.", "Two sentences!", "Three?", "Four."])
    }

    func testAbbreviationsAndInitials() {
        XCTAssertEqual(split("As shown by Smith et al. (2020), e.g. in Fig. 3, J. Smith agreed. Then it ended."),
                       ["As shown by Smith et al. (2020), e.g. in Fig. 3, J. Smith agreed.", "Then it ended."])
        XCTAssertEqual(split("Section 3.2 shows it. The U.S. Government agreed."),
                       ["Section 3.2 shows it.", "The U.S. Government agreed."])
    }

    func testQuotesAndLowercase() {
        XCTAssertEqual(split("He said \u{201C}stop.\u{201D} Then he left. etc. and more"),
                       ["He said \u{201C}stop.\u{201D}", "Then he left. etc. and more"])
    }

    func testAttachableFootnoteMarker() {
        let s = "First.\u{FFFC} Second."
        let ranges = Sentences.split(s, attachable: { $0 == 6 })
        XCTAssertEqual(ranges, [0..<7, 8..<15])
    }

    func testWordCount() {
        XCTAssertEqual(WordCount.count("Don't count well-being twice — or 3.5 things."), 7)
        XCTAssertEqual(WordCount.count(""), 0)
    }
}

final class MarkdownTests: XCTestCase {
    func roundTrip(_ inlines: [Inline]) -> [Inline] {
        InlineMarkdown.parse(InlineMarkdown.emit(inlines) { t in
            if case .variable(let n) = t { return "{{\(n)}}" }
            return ""
        })
    }

    func testEmphasisRoundTrip() {
        let cases: [[Inline]] = [
            [.text("Hello ", .plain), .text("bold", InlineStyle(bold: true)), .text(" and ", .plain),
             .text("italic", InlineStyle(italic: true)), .text(".", .plain)],
            [.text("un", .plain), .text("believ", InlineStyle(italic: true)), .text("able", .plain)],
            [.text("x", InlineStyle(bold: true, italic: true))],
            [.text("Bold ", InlineStyle(bold: true)), .text("both", InlineStyle(bold: true, italic: true)),
             .text(" end", InlineStyle(bold: true))],
            [.text("snake_case, 5 * 3 and [sic]", .plain)],
        ]
        for c in cases { XCTAssertEqual(roundTrip(c), c.coalesced, "\(c)") }
    }

    func testTokensParse() {
        let parsed = InlineMarkdown.parse("N = {{sample_size}} people<!-- check --> here[^1].",
                                          footnotes: ["1": [.text("A note.", .plain)]])
        XCTAssertEqual(parsed, [
            .text("N = ", .plain), .token(.variable("sample_size"), .plain), .text(" people", .plain),
            .token(.note("check"), .plain), .text(" here", .plain),
            .token(.footnote([.text("A note.", .plain)]), .plain), .text(".", .plain),
        ])
    }

    func testSentencePerLineAndBlocks() {
        let blocks: [Block] = [
            .heading(Heading(level: 1, inlines: [.text("Introduction", .plain)], id: "h1")),
            .paragraph([.text("First sentence. Second sentence with ", .plain),
                        .text("emphasis", InlineStyle(italic: true)), .text(". 1. Not a list.", .plain)]),
            .bullet([.text("One.", .plain)]),
            .bullet([.text("Two. Still two.", .plain)]),
            .quote([.text("A quote.", .plain)]),
        ]
        var ctx = BlockMarkdown.WriteContext(numbering: Numbering(blocks: blocks), tokenText: { _ in "" }, referenceEntries: [])
        let md = BlockMarkdown.write(blocks, context: &ctx)
        XCTAssertEqual(md, """
        # Introduction

        First sentence.
        Second sentence with _emphasis_.
        1\\.
        Not a list.

        - One.
        - Two.
          Still two.

        > A quote.

        """)
        let back = BlockMarkdown.parse(md).blocks.map { $0.mappingInlines { $0 } }
        XCTAssertEqual(back.count, blocks.count)
        XCTAssertEqual(back[1], .paragraph([.text("First sentence. Second sentence with ", .plain),
                                            .text("emphasis", InlineStyle(italic: true)),
                                            .text(". 1. Not a list.", .plain)]))
    }
}

final class WorkspaceTests: XCTestCase {
    func sample() -> Manuscript {
        var m = Manuscript()
        m.title = [.text("Digital Twins at Work", .plain)]
        let fig = Figure(path: "figures/model.png", kind: .figure, caption: [.text("Research model", .plain)])
        let citation = Citation(sources: ["SmithJones2025_MISQ"], text: "(Smith & Jones, 2025)")
        m.blocks = [
            .paragraph([.text("Abstract text.", .plain)]),
            .heading(Heading(level: 1, inlines: [.text("Introduction", .plain)], id: "a")),
            .paragraph([.text("Prior work ", .plain), .token(.citation(citation), .plain), .text(" is shown in ", .plain),
                        .token(.figureRef("figures/model.png"), .plain), .text(" and ", .plain),
                        .token(.sectionRef("b"), .plain), .text(".", .plain)]),
            .heading(Heading(level: 1, inlines: [.text("Research Design", .plain)], id: "c")),
            .heading(Heading(level: 2, inlines: [.text("Data Collection", .plain)], id: "b")),
            .figure(fig),
            .paragraph([.text("We interviewed {{n}} people.", .plain)]),
            .heading(Heading(level: 1, inlines: [.text("References", .plain)], id: "d")),
            .referenceList,
        ]
        return m
    }

    func testRenderSplitsSectionsAndRoundTrips() throws {
        let m = sample()
        let refs = [ReferenceEntry(source: "SmithJones2025_MISQ", entry: "Smith, J., & Jones, A. (2025). Title. _MIS Quarterly_.")]
        let r = Workspace.render(m, variables: [Variable(name: "n", value: "47")], referenceEntries: refs)
        XCTAssertEqual(Set(r.files.keys), ["00-manuscript.md", "01-introduction.md", "02-research-design.md", "03-references.md"])
        XCTAssertTrue(r.files["01-introduction.md"]?.contains("(Smith & Jones, 2025) is shown in Figure 1 and Section 2.1.") == true)
        XCTAssertTrue(r.files["02-research-design.md"]?.contains("![Figure 1. Research model](figures/model.png)") == true)
        XCTAssertTrue(r.files["00-manuscript.md"]?.hasPrefix("---\ntitle: Digital Twins at Work\nmustache: variables.yml\n") == true)

        let files = r.files.keys.sorted().map { ($0, r.files[$0] ?? "") }
        let loaded = Workspace.parse(files: files, variablesYAML: r.variablesYAML, citationsYAML: r.citationsYAML)
        XCTAssertEqual(loaded.variables, [Variable(name: "n", value: "47")])
        XCTAssertEqual(loaded.manuscript.title, m.title)
        // Tokens come back.
        guard case .paragraph(let inlines) = loaded.manuscript.blocks[2] else { return XCTFail("paragraph") }
        XCTAssertTrue(inlines.contains { if case .token(.citation(let c), _) = $0 { return c.sources == ["SmithJones2025_MISQ"] }; return false })
        XCTAssertTrue(inlines.contains { if case .token(.figureRef("figures/model.png"), _) = $0 { return true }; return false })
        XCTAssertTrue(inlines.contains { if case .token(.sectionRef(let id), _) = $0 { return id == "h3" }; return false })
        XCTAssertEqual(loaded.manuscript.blocks.last, .referenceList)
        // And it writes back identically.
        let again = Workspace.render(loaded.manuscript, variables: loaded.variables, referenceEntries: loaded.registry.references)
        XCTAssertEqual(again.files, r.files)
    }

    func testVariablesQuoteNumbers() {
        XCTAssertEqual(Variables.emit([Variable(name: "mean", value: "7.40"), Variable(name: "name", value: "Smith")]),
                       "mean: \"7.40\"\nname: Smith\n")
    }

    func testSaveRemovesStaleSectionFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qdvc-ms-\(UUID().uuidString)")
        try Workspace.create(at: dir, title: "T")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("manuscript.md").path))
        let r = Workspace.render(sample(), variables: [], referenceEntries: [])
        let report = try Workspace.save(r, to: dir)
        XCTAssertTrue(report.removed.contains("manuscript.md"))
        let loaded = try Workspace.load(dir)
        XCTAssertEqual(loaded.manuscript.headings.count, 4)
        try? FileManager.default.removeItem(at: dir)
    }
}

final class CitationTests: XCTestCase {
    func testAPAInText() {
        let a = BibTeX.parseFallback("@article{a, author={Smith, Jane and Jones, Al}, year={2025}, title={T}, journal={MISQ}}")!
        let b = BibTeX.parseFallback("@article{b, author={Lee, K. and Park, M. and Kim, S.}, year={2021}, title={U}}")!
        let lib = BibliothecaLibrary(records: [LibraryRecord(id: "A", entry: a), LibraryRecord(id: "B", entry: b)])
        let f = CitationFormatter(style: .apa7, library: lib, cited: ["A", "B"])
        XCTAssertEqual(f.text(for: Citation(sources: ["A"])), "(Smith & Jones, 2025)")
        XCTAssertEqual(f.text(for: Citation(sources: ["A"], narrative: true, locator: "p. 4")), "Smith and Jones (2025, p. 4)")
        XCTAssertEqual(f.text(for: Citation(sources: ["B", "A"])), "(Lee et al., 2021; Smith & Jones, 2025)")
        let acis = CitationFormatter(style: .acis, library: lib, cited: ["A"])
        XCTAssertEqual(acis.text(for: Citation(sources: ["A"])), "(Smith and Jones 2025)")
        let entries = f.referenceEntries(for: ["B", "A"], cached: CitationRegistry())
        XCTAssertEqual(entries.map(\.source), ["B", "A"])
    }
}

final class ZipTests: XCTestCase {
    func testStoredRoundTrip() throws {
        var w = ZipWriter()
        w.add("a.txt", "hello")
        w.add("dir/b.xml", "<x/>")
        let reader = try ZipReader(data: w.finish())
        XCTAssertEqual(try reader.text("a.txt"), "hello")
        XCTAssertEqual(try reader.text("dir/b.xml"), "<x/>")
    }

    func testInflateFixedHuffman() throws {
        // "hello hello hello" deflated (raw, fixed Huffman) by zlib.
        let bytes: [UInt8] = [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x90, 0x00]
        XCTAssertEqual(String(decoding: try Inflate.inflate(bytes), as: UTF8.self), "hello hello hello")
    }

    func testDocxExportImportRoundTrip() throws {
        var m = Manuscript()
        m.title = [.text("A Title", .plain)]
        m.blocks = [
            .heading(Heading(level: 1, inlines: [.text("Intro", .plain)], id: "x")),
            .paragraph([.text("Some ", .plain), .text("bold", InlineStyle(bold: true)), .text(" text", .plain),
                        .token(.footnote([.text("Foot.", .plain)]), .plain), .text(".", .plain)]),
            .bullet([.text("Item", .plain)]),
        ]
        let data = DocxExport.document(m, display: { _ in "" }, referenceEntries: [], image: { _ in nil })
        let back = try DocxImport.read(data)
        XCTAssertEqual(back.manuscript.title, m.title)
        XCTAssertEqual(back.manuscript.blocks.first?.heading?.inlines, [.text("1. Intro", .plain)])
        guard case .paragraph(let inlines)? = back.manuscript.blocks.dropFirst().first else { return XCTFail("paragraph") }
        XCTAssertTrue(inlines.contains(.text("bold", InlineStyle(bold: true))))
        XCTAssertTrue(inlines.contains(.token(.footnote([.text("Foot.", .plain)]), .plain)))
    }
}

/// Nothing in the app may touch the network (docs/MAINTENANCE.md §Network):
/// no networking API appears anywhere in the sources, and there are no
/// package dependencies.
final class NetworkTests: XCTestCase {
    func testNoNetworkingAPIs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let forbidden = ["URLSession", "URLRequest", "import Network", "NWConnection", "NWPathMonitor", "import WebKit",
                         "WKWebView", "NSURLConnection", "CFNetwork", "CFSocket", "openURL", "NSWorkspace.shared.open(",
                         "Link(", "import Combine", "socket(", "getaddrinfo", "NSSharingService", "ShareLink",
                         "contentsOf: URL(string", "NSAppleScript", "Process()"]
        var offences: [String] = []
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for f in forbidden where code.contains(f) {
                    offences.append("\(url.lastPathComponent):\(n + 1): \(f)")
                }
            }
        }
        XCTAssertEqual(offences, [], "Networking APIs found in the sources")
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertFalse(manifest.contains(".package("), "Package.swift must not declare dependencies")
    }
}
