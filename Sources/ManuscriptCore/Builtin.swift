import Foundation

/// Style-agnostic building blocks for the built-in reference formatters —
/// from QDVC Bibliotheca for macOS (BibliothecaCore), a port of
/// `qdvc/builtin.py`; keep the two in step.
///
/// Formatters produce a tiny markup language (the Pango subset the Python app
/// uses): `<i>…</i>`, `<b>…</b>` and the entities `&amp; &lt; &gt; &quot;
/// &#x27;`. `Markup` turns it into AttributedString / RTF / HTML for display
/// and the clipboard.
public enum Builtin {
    private static let andSeparator = Rx("\\s+and\\s+")
    private static let initialSeparator = Rx("[\\s\\-]+")
    private static let whitespaceRun = Rx("\\s+")
    private static let tag = Rx("<[^>]+>")
    private static let spaceBeforePeriod = Rx("\\s+\\.")
    private static let doublePeriod = Rx("\\.\\.")
    private static let multiSpace = Rx("\\s{2,}")

    // MARK: Authors

    /// Split a BibTeX author/editor string on " and ".
    public static func splitAuthors(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return andSeparator.split(raw.pyStrip).map(\.pyStrip).filter { !$0.isEmpty }
    }

    /// Split one author token into (surname, given names). Handles both
    /// "Surname, Given" and "Given Surname".
    public static func splitName(_ name: String) -> (surname: String, given: String) {
        let n = name.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "").pyStrip
        guard !n.isEmpty else { return ("", "") }
        if let comma = n.firstIndex(of: ",") {
            return (String(n[..<comma]).pyStrip, String(n[n.index(after: comma)...]).pyStrip)
        }
        let bits = n.pyWords
        if bits.count == 1 { return (bits[0], "") }
        return (bits[bits.count - 1], bits.dropLast().joined(separator: " "))
    }

    /// (surname, given names) for every author in `raw`.
    public static func authorTokens(_ raw: String?) -> [(surname: String, given: String)] {
        splitAuthors(raw).compactMap { token in
            let parts = splitName(token)
            return parts.surname.isEmpty ? nil : parts
        }
    }

    /// "Bernard Charles" → "B. C."
    public static func initials(_ first: String) -> String {
        var out: [String] = []
        for piece in initialSeparator.split(first.pyStrip) {
            let token = piece.pyStrip(".")
            guard let c = token.first else { continue }
            out.append("\(String(c).uppercased()).")
        }
        return out.joined(separator: " ")
    }

    /// "Surname, F. M." for a single author token.
    public static func surnameInitials(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "").pyStrip
        guard !n.isEmpty else { return "" }
        let last: String
        let first: String
        if let comma = n.firstIndex(of: ",") {
            last = String(n[..<comma]).pyStrip
            first = String(n[n.index(after: comma)...]).pyStrip
        } else {
            let bits = n.pyWords
            last = bits[bits.count - 1]
            first = bits.dropLast().joined(separator: " ")
        }
        let inits = initials(first)
        return inits.isEmpty ? last : "\(last), \(inits)"
    }

    // MARK: Fields

    /// Strip braces and collapse whitespace in a raw BibTeX value.
    public static func clean(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let v = value.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        return whitespaceRun.replace(v, with: " ").pyStrip
    }

    /// `html.escape` for markup content; `quote` also escapes `"` and `'`.
    public static func escape(_ text: String?, quote: Bool = false) -> String {
        var t = (text ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quote {
            t = t.replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#x27;")
        }
        return t
    }

    /// `<i>escaped</i>`, or "" for empty text.
    public static func italic(_ text: String, quote: Bool = false) -> String {
        text.isEmpty ? "" : "<i>\(escape(text, quote: quote))</i>"
    }

    // MARK: Type labels (load-bearing UI strings)

    public static let typeLabels: [String: String] = [
        "article": "Journal article",
        "inproceedings": "Proceedings",
        "conference": "Proceedings",
        "proceedings": "Proceedings",
        "book": "Book",
        "inbook": "Book chapter",
        "incollection": "Book chapter",
        "online": "Webpage",
        "electronic": "Webpage",
        "webpage": "Webpage",
        "misc": "Other",
    ]

    /// The sidebar's "By type" order.
    public static let typeOrder = ["Journal article", "Proceedings", "Book chapter",
                                   "Book", "Webpage", "Other"]

    /// Map an entry type to its human label. An `incollection` whose
    /// booktitle starts with "Proceedings of" counts as "Proceedings".
    public static func typeLabel(_ entryType: String?, booktitle: String? = nil) -> String {
        let et = (entryType ?? "").lowercased()
        if et == "incollection", let booktitle, !booktitle.isEmpty,
           clean(booktitle).lowercased().hasPrefix("proceedings of") {
            return "Proceedings"
        }
        return typeLabels[et] ?? "Other"
    }

    // MARK: Markup → plain

    /// Strip tags and unescape entities (same replacement order as Python).
    public static func markupToPlain(_ markup: String) -> String {
        var text = tag.replace(markup, with: "")
        for (entity, ch) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                             ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'")] {
            text = text.replacingOccurrences(of: entity, with: ch)
        }
        return text
    }

    /// Tidy doubled spaces/periods left behind by empty fields.
    public static func collapseArtefacts(_ markup: String) -> String {
        var m = spaceBeforePeriod.replace(markup, with: ".")
        m = doublePeriod.replace(m, with: ".")
        m = multiSpace.replace(m, with: " ").pyStrip
        return m
    }

    /// Year field, or the leading four digits of `date`.
    public static func bareYear(_ e: BibEntry) -> String {
        let y = clean(e["year"])
        if !y.isEmpty { return y }
        let date = clean(e["date"])
        if let m = leadingYear.firstMatch(date), let g = leadingYear.group(m, 1, in: date) {
            return g
        }
        return ""
    }

    private static let leadingYear = Rx("^(\\d{4})")
}
