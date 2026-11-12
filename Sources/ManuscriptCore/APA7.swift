import Foundation

/// The built-in APA 7 formatter — from QDVC Bibliotheca for macOS
/// (BibliothecaCore), a port of `qdvc/builtin_apa7.py`, with the year's
/// disambiguation letter ("2025a") added.
///
/// A pragmatic formatter for the common source types in an academic
/// collection, not a full CSL engine. APA escapes markup content with quotes
/// on (its historical Python behaviour); `Builtin.markupToPlain` undoes that.
public enum APA7 {
    private static let doiPrefix = Rx("^https?://(dx\\.)?doi\\.org/")

    public static func markup(_ entry: BibEntry, disambiguator: String = "") -> String {
        let render: (BibEntry, String) -> String
        switch entry.entryType.isEmpty ? "misc" : entry.entryType.lowercased() {
        case "article": render = renderArticle
        case "inproceedings", "conference", "proceedings": render = renderInproceedings
        case "book": render = renderBook
        case "inbook", "incollection": render = renderInbook
        default: render = renderOnline
        }
        return Builtin.collapseArtefacts(render(entry, disambiguator))
    }

    public static func plain(_ entry: BibEntry, disambiguator: String = "") -> String {
        Builtin.markupToPlain(markup(entry, disambiguator: disambiguator))
    }

    /// "Smith, J., & Jones, A." with up to 20 authors, then the ellipsis rule.
    public static func formatAuthorList(_ raw: String?) -> String {
        let authors = Builtin.splitAuthors(raw).map(Builtin.surnameInitials).filter { !$0.isEmpty }
        guard !authors.isEmpty else { return "" }
        if authors.count == 1 { return authors[0] }
        if authors.count <= 20 {
            return authors.dropLast().joined(separator: ", ") + ", & " + authors[authors.count - 1]
        }
        let head = authors.prefix(19).joined(separator: ", ")
        return "\(head), . . . \(authors[authors.count - 1])"
    }

    // MARK: Helpers

    private static func esc(_ s: String) -> String { Builtin.escape(s, quote: true) }
    private static func ital(_ s: String) -> String { Builtin.italic(s, quote: true) }

    private static func year(_ e: BibEntry, _ d: String) -> String {
        let y = Builtin.bareYear(e)
        return y.isEmpty ? (d.isEmpty ? "(n.d.)" : "(n.d.-\(d))") : "(\(y)\(d))"
    }

    private static func doiURL(_ e: BibEntry) -> String {
        let doi = Builtin.clean(e["doi"])
        if !doi.isEmpty {
            return "https://doi.org/\(doiPrefix.replace(doi, with: ""))"
        }
        return Builtin.clean(e["url"])
    }

    private static func pageRange(_ e: BibEntry) -> String {
        Builtin.clean(e["pages"]).replacingOccurrences(of: "--", with: "\u{2013}")
    }

    private static func lead(_ authors: String, _ year: String) -> String {
        authors.isEmpty ? "\(esc(year))." : "\(esc(authors)) \(esc(year))."
    }

    // MARK: Renderers

    private static func renderArticle(_ e: BibEntry, _ d: String) -> String {
        let authors = formatAuthorList(e["author"])
        let title = Builtin.clean(e["title"])
        let journal = Builtin.clean(e.first("journal", "journaltitle"))
        let volume = Builtin.clean(e["volume"])
        let issue = Builtin.clean(e.first("number", "issue"))
        let pages = pageRange(e)
        let url = doiURL(e)

        var parts = [lead(authors, year(e, d))]
        if !title.isEmpty { parts.append("\(esc(title)).") }
        var tail = ""
        if !journal.isEmpty {
            tail = ital(journal)
            if !volume.isEmpty {
                tail += ", \(ital(volume))"
                if !issue.isEmpty { tail += "(\(esc(issue)))" }
            }
            if !pages.isEmpty { tail += ", \(esc(pages))" }
            tail += "."
        }
        if !tail.isEmpty { parts.append(tail) }
        if !url.isEmpty { parts.append(esc(url)) }
        return parts.joined(separator: " ")
    }

    private static func renderInproceedings(_ e: BibEntry, _ d: String) -> String {
        let authors = formatAuthorList(e["author"])
        let title = Builtin.clean(e["title"])
        let book = Builtin.clean(e["booktitle"])
        let pages = pageRange(e)
        let url = doiURL(e)

        var parts = [lead(authors, year(e, d))]
        if !title.isEmpty { parts.append("\(esc(title)).") }
        if !book.isEmpty {
            var seg = "In " + ital(book)
            if !pages.isEmpty { seg += " (pp. \(esc(pages)))" }
            parts.append(seg + ".")
        }
        if !url.isEmpty { parts.append(esc(url)) }
        return parts.joined(separator: " ")
    }

    private static func renderBook(_ e: BibEntry, _ d: String) -> String {
        let authors = formatAuthorList(e.first("author", "editor"))
        let title = Builtin.clean(e["title"])
        let edition = Builtin.clean(e["edition"])
        let publisher = Builtin.clean(e["publisher"])
        let url = doiURL(e)

        var parts = [lead(authors, year(e, d))]
        var t = title.isEmpty ? "" : ital(title)
        if !edition.isEmpty { t += " (\(esc(edition)) ed.)" }
        if !t.isEmpty { parts.append(t + ".") }
        if !publisher.isEmpty { parts.append("\(esc(publisher)).") }
        if !url.isEmpty { parts.append(esc(url)) }
        return parts.joined(separator: " ")
    }

    private static func renderInbook(_ e: BibEntry, _ d: String) -> String {
        let authors = formatAuthorList(e["author"])
        let title = Builtin.clean(e["title"])
        let book = Builtin.clean(e["booktitle"])
        let editor = formatAuthorList(e["editor"])
        let pages = pageRange(e)
        let publisher = Builtin.clean(e["publisher"])
        let url = doiURL(e)

        var parts = [lead(authors, year(e, d))]
        if !title.isEmpty { parts.append("\(esc(title)).") }
        var seg = "In "
        if !editor.isEmpty { seg += "\(esc(editor)) (Ed.), " }
        if !book.isEmpty {
            seg += ital(book)
            if !pages.isEmpty { seg += " (pp. \(esc(pages)))" }
            parts.append(seg + ".")
        }
        if !publisher.isEmpty { parts.append("\(esc(publisher)).") }
        if !url.isEmpty { parts.append(esc(url)) }
        return parts.joined(separator: " ")
    }

    private static func renderOnline(_ e: BibEntry, _ d: String) -> String {
        let authors = formatAuthorList(e["author"])
        let title = Builtin.clean(e["title"])
        let site = Builtin.clean(e.first("organization", "publisher", "howpublished"))
        let url = doiURL(e)

        var parts = [lead(authors, year(e, d))]
        if !title.isEmpty { parts.append("\(ital(title)).") }
        if !site.isEmpty { parts.append("\(esc(site)).") }
        if !url.isEmpty { parts.append(esc(url)) }
        return parts.joined(separator: " ")
    }
}
