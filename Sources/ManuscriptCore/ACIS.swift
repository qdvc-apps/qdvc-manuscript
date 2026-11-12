import Foundation

/// The built-in ACIS formatter and in-text citation renderer — from QDVC
/// Bibliotheca for macOS (BibliothecaCore), a port of `qdvc/builtin_acis.py`.
///
/// ACIS escapes markup with quotes off, so apostrophes stay literal. The
/// year-disambiguation letter ("2025a") is supplied by the caller; the
/// workspace computes it with `disambiguatorMap`.
public enum ACIS {
    private static let doiPrefix = Rx("^https?://(dx\\.)?doi\\.org/", [.caseInsensitive])
    private static let isoDate = Rx("^(\\d{4})-(\\d{1,2})-(\\d{1,2})")
    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]

    // MARK: Reference list

    public static func markup(_ entry: BibEntry, disambiguator: String = "") -> String {
        Builtin.collapseArtefacts(pickRenderer(entry)(entry, disambiguator))
    }

    public static func plain(_ entry: BibEntry, disambiguator: String = "") -> String {
        Builtin.markupToPlain(markup(entry, disambiguator: disambiguator))
    }

    /// "Smith, A., Jones, B. C., and Carter, D." — surname-first throughout.
    public static func formatAuthorList(_ raw: String?) -> String {
        let authors = Builtin.splitAuthors(raw).map(Builtin.surnameInitials).filter { !$0.isEmpty }
        guard !authors.isEmpty else { return "" }
        if authors.count == 1 { return authors[0] }
        return authors.dropLast().joined(separator: ", ") + ", and " + authors[authors.count - 1]
    }

    // MARK: In-text citation

    /// "(Smith and Jones 2026)", or "Smith and Jones (2026)" when narrative.
    public static func inTextPlain(_ entry: BibEntry, disambiguator: String = "",
                                   narrative: Bool = false) -> String {
        let label = authorLabel(entry)
        let year = Builtin.bareYear(entry)
        let stamp = year.isEmpty ? "n.d." : "\(year)\(disambiguator)"
        if label.isEmpty { return "(\(stamp))" }
        return narrative ? "\(label) (\(stamp))" : "(\(label) \(stamp))"
    }

    public static func inTextMarkup(_ entry: BibEntry, disambiguator: String = "",
                                    narrative: Bool = false) -> String {
        esc(inTextPlain(entry, disambiguator: disambiguator, narrative: narrative))
    }

    // MARK: Disambiguation

    /// 0 → "a", 25 → "z", 26 → "aa", …
    public static func letter(_ index: Int) -> String {
        var letters = ""
        var n = index + 1
        while n > 0 {
            let rem = (n - 1) % 26
            n = (n - 1) / 26
            letters = String(UnicodeScalar(UInt8(97 + rem))) + letters
        }
        return letters
    }

    // MARK: Helpers

    private static func esc(_ s: String) -> String { Builtin.escape(s, quote: false) }
    private static func ital(_ s: String) -> String { Builtin.italic(s, quote: false) }

    private static func surnames(_ raw: String?) -> [String] {
        Builtin.authorTokens(raw ?? "").map { $0.surname }
    }

    static func authorLabel(_ e: BibEntry) -> String {
        let names = surnames(e.first("author", "editor"))
        if names.isEmpty {
            let title = Builtin.clean(e["title"])
            return title.pyWords.first ?? ""
        }
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) et al."
        }
    }

    private static func accessedDate(_ e: BibEntry) -> String {
        let raw = Builtin.clean(e.first("urldate", "accessed"))
        guard !raw.isEmpty else { return "" }
        guard let m = isoDate.firstMatch(raw),
              let y = isoDate.group(m, 1, in: raw).flatMap({ Int($0) }),
              let mo = isoDate.group(m, 2, in: raw).flatMap({ Int($0) }),
              let d = isoDate.group(m, 3, in: raw).flatMap({ Int($0) }) else { return raw }
        guard (1...12).contains(mo) else { return raw }
        return "\(d) \(months[mo - 1]) \(y)"
    }

    private static func doi(_ e: BibEntry) -> String {
        let d = Builtin.clean(e["doi"])
        return d.isEmpty ? "" : doiPrefix.replace(d, with: "")
    }

    /// Curly-quote a title with the closing punctuation inside the quote.
    private static func quotedTitle(_ title: String, closing: String = ",") -> String {
        title.isEmpty ? "" : "\u{201C}\(esc(title))\(closing)\u{201D}"
    }

    private static func lead(_ e: BibEntry, _ disambiguator: String) -> String {
        let authors = formatAuthorList(e.first("author", "editor"))
        let year = Builtin.bareYear(e)
        let stamp = year.isEmpty ? "n.d." : "\(year)\(disambiguator)"
        return authors.isEmpty ? "\(esc(stamp))." : "\(esc(authors)) \(esc(stamp))."
    }

    private static func pickRenderer(_ e: BibEntry) -> (BibEntry, String) -> String {
        let type = e.entryType.isEmpty ? "misc" : e.entryType.lowercased()
        if type == "incollection",
           Builtin.clean(e["booktitle"]).lowercased().hasPrefix("proceedings of") {
            return renderInproceedings
        }
        switch type {
        case "article": return renderArticle
        case "inproceedings", "conference", "proceedings": return renderInproceedings
        case "book": return renderBook
        case "inbook", "incollection": return renderInbook
        default: return renderOnline
        }
    }

    // MARK: Renderers

    private static func renderArticle(_ e: BibEntry, _ disambiguator: String) -> String {
        let title = Builtin.clean(e["title"])
        let journal = Builtin.clean(e.first("journal", "journaltitle"))
        let volume = Builtin.clean(e["volume"])
        let issue = Builtin.clean(e.first("number", "issue"))
        let pageRange = Builtin.clean(e["pages"]).replacingOccurrences(of: "--", with: "-")
        let doiValue = doi(e)

        var parts = [lead(e, disambiguator)]
        if !title.isEmpty { parts.append(quotedTitle(title, closing: ",")) }
        var tail = ""
        if !journal.isEmpty {
            tail = ital(journal)
            if !volume.isEmpty {
                var vi = esc(volume)
                if !issue.isEmpty { vi += ":\(esc(issue))" }
                tail += " (\(vi))"
            }
            if !pageRange.isEmpty {
                tail += ", pp. \(esc(pageRange))"
                if !doiValue.isEmpty { tail += " (doi:\(esc(doiValue)))" }
                tail += "."
            } else if !doiValue.isEmpty {
                tail += " (doi:\(esc(doiValue)))"
            } else {
                tail += "."
            }
        }
        if !tail.isEmpty { parts.append(tail) }
        return parts.joined(separator: " ")
    }

    private static func renderInproceedings(_ e: BibEntry, _ disambiguator: String) -> String {
        let title = Builtin.clean(e["title"])
        let book = Builtin.clean(e["booktitle"])
        let address = Builtin.clean(e.first("address", "location"))

        var parts = [lead(e, disambiguator)]
        if !title.isEmpty { parts.append(quotedTitle(title, closing: ",")) }
        if !book.isEmpty { parts.append("\(ital(book)).") }
        if !address.isEmpty { parts.append("\(esc(address)).") }
        return parts.joined(separator: " ")
    }

    private static func renderBook(_ e: BibEntry, _ disambiguator: String) -> String {
        let title = Builtin.clean(e["title"])
        let edition = Builtin.clean(e["edition"])
        let publisher = Builtin.clean(e["publisher"])
        let address = Builtin.clean(e.first("address", "location"))

        var parts = [lead(e, disambiguator)]
        var t = title.isEmpty ? "" : ital(title)
        if !edition.isEmpty { t += " (\(esc(edition)) ed.)" }
        if !t.isEmpty { parts.append(t + ".") }
        if !address.isEmpty, !publisher.isEmpty {
            parts.append("\(esc(address)): \(esc(publisher)).")
        } else if !publisher.isEmpty {
            parts.append("\(esc(publisher)).")
        } else if !address.isEmpty {
            parts.append("\(esc(address)).")
        }
        return parts.joined(separator: " ")
    }

    private static func renderInbook(_ e: BibEntry, _ disambiguator: String) -> String {
        let title = Builtin.clean(e["title"])
        let book = Builtin.clean(e["booktitle"])
        let editor = formatAuthorList(e["editor"])
        let pageRange = Builtin.clean(e["pages"]).replacingOccurrences(of: "--", with: "-")
        let publisher = Builtin.clean(e["publisher"])
        let address = Builtin.clean(e.first("address", "location"))

        var parts = [lead(e, disambiguator)]
        if !title.isEmpty { parts.append(quotedTitle(title, closing: ",")) }
        var seg = "in "
        if !editor.isEmpty { seg += "\(esc(editor)) (ed.), " }
        if !book.isEmpty {
            seg += ital(book)
            if !pageRange.isEmpty { seg += ", pp. \(esc(pageRange))" }
            parts.append(seg + ".")
        }
        if !address.isEmpty, !publisher.isEmpty {
            parts.append("\(esc(address)): \(esc(publisher)).")
        } else if !publisher.isEmpty {
            parts.append("\(esc(publisher)).")
        }
        return parts.joined(separator: " ")
    }

    private static func renderOnline(_ e: BibEntry, _ disambiguator: String) -> String {
        let title = Builtin.clean(e["title"])
        var url = Builtin.clean(e["url"])
        if url.isEmpty { url = Builtin.clean(e["howpublished"]) }
        let accessed = accessedDate(e)

        var parts = [lead(e, disambiguator)]
        if !title.isEmpty { parts.append(quotedTitle(title, closing: ".")) }
        if !url.isEmpty {
            var inner = esc(url)
            if !accessed.isEmpty { inner += ", accessed \(esc(accessed))" }
            parts.append("(\(inner)).")
        } else if !accessed.isEmpty {
            parts.append("(accessed \(esc(accessed))).")
        }
        return parts.joined(separator: " ")
    }
}
