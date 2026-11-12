import Foundation

/// One parsed BibTeX entry: the lower-cased entry type, the citation key, and
/// the fields keyed by lower-cased name (values verbatim, braces included).
///
/// This mirrors the normalised dict the Python app passes around, where the
/// entry type lives under `ENTRYTYPE` and the key under `ID`.
public struct BibEntry: Equatable, Sendable {
    public var entryType: String
    public var citationKey: String?
    public var fields: [String: String]

    public init(entryType: String = "misc", citationKey: String? = nil,
                fields: [String: String] = [:]) {
        self.entryType = entryType
        self.citationKey = citationKey
        self.fields = fields
    }

    public subscript(_ name: String) -> String? { fields[name] }

    /// The first of `names` whose value is non-empty — Python's
    /// `e.get("a") or e.get("b") or …`.
    public func first(_ names: String...) -> String? {
        for n in names {
            if let v = fields[n], !v.isEmpty { return v }
        }
        return nil
    }
}

/// BibTeX parsing — from QDVC Bibliotheca for macOS (BibliothecaCore), a port
/// of `qdvc/bibtex.py`; keep the two in step.
///
/// The Python app prefers `bibtexparser` when installed and falls back to a
/// small brace-aware parser otherwise. The Mac app always uses (a port of) the
/// fallback parser, which is exactly right for the one-entry-per-file
/// workspace convention. The parser works on Unicode scalars so that indices
/// behave like Python string indices (Swift would treat "\r\n" as one
/// Character).
public enum BibTeX {
    typealias Scalars = [Unicode.Scalar]

    public struct SplitEntry: Equatable {
        public var text: String
        public var key: String
    }

    // MARK: - Public API

    /// Parse a single-entry `.bib` file. Returns nil if it cannot be read or
    /// contains no entry.
    public static func parse(fileAt url: URL) -> BibEntry? {
        guard let text = readTextLossy(url) else { return nil }
        return parseFallback(text)
    }

    /// Minimal single-entry parser handling brace- and quote-delimited values,
    /// nested braces and bare values (numbers, macros).
    public static func parseFallback(_ text: String) -> BibEntry? {
        let s = Array(text.unicodeScalars)
        let n = s.count
        guard let head = searchEntry(s, from: 0) else { return nil }
        var entry = BibEntry(entryType: head.type.lowercased())
        var i = head.afterBrace
        guard let keyEnd = index(of: ",", in: s, from: i) else { return entry }
        entry.citationKey = string(s, i..<keyEnd).pyStrip
        i = keyEnd + 1
        while i < n {
            guard let field = searchField(s, from: i) else { break }
            let name = field.name.lowercased()
            var j = field.valueStart
            while j < n, isLayoutSpace(s[j]) { j += 1 }
            if j >= n { break }
            let value: String
            if s[j] == "{" {
                var depth = 0
                let start = j + 1
                var k = j
                while k < n {
                    if s[k] == "{" {
                        depth += 1
                    } else if s[k] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    k += 1
                }
                value = string(s, start..<max(start, k))
                i = k + 1
            } else if s[j] == "\"" {
                let start = j + 1
                var k = start
                while k < n, s[k] != "\"" { k += 1 }
                value = string(s, start..<k)
                i = k + 1
            } else {
                var k = j
                while k < n, s[k] != ",", s[k] != "}", s[k] != "\n" { k += 1 }
                value = string(s, j..<k).pyStrip
                i = k
            }
            entry.fields[name] = value.pyStrip
            while i < n, isLayoutSpace(s[i]) { i += 1 }
            if i < n, s[i] == "," {
                i += 1
            } else if i < n, s[i] == "}" {
                break
            }
        }
        return entry
    }

    /// Split multi-entry BibTeX text into `(entry text, citation key)` pairs,
    /// brace-balancing each `@type{…}` block and skipping `@string`,
    /// `@preamble` and `@comment`.
    public static func splitEntries(_ text: String) -> [SplitEntry] {
        let s = Array(text.unicodeScalars)
        let n = s.count
        var out: [SplitEntry] = []
        var i = 0
        while i < n {
            guard let at = index(of: "@", in: s, from: i) else { break }
            guard let head = matchEntry(s, at: at) else {
                i = at + 1
                continue
            }
            let braceOpen = head.afterBrace - 1
            var depth = 0
            var j = braceOpen
            while j < n {
                if s[j] == "{" {
                    depth += 1
                } else if s[j] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            let entryScalars = Array(s[at..<min(j + 1, n)])
            i = j + 1
            if ["string", "preamble", "comment"].contains(head.type.lowercased()) {
                continue
            }
            guard let comma = entryScalars.firstIndex(of: ","),
                  let brace = entryScalars.firstIndex(of: "{") else { continue }
            let key = brace + 1 <= comma ? string(entryScalars, (brace + 1)..<comma).pyStrip : ""
            out.append(SplitEntry(text: string(entryScalars, 0..<entryScalars.count), key: key))
        }
        return out
    }

    // MARK: - Scanner helpers

    /// Python's `\w` (Unicode letters, digits and underscore).
    static func isWord(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c.properties.isAlphabetic || c.properties.numericType != nil
    }

    /// Python's `\s`.
    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c.properties.isWhitespace
    }

    /// The explicit `" \t\r\n"` set the Python parser skips between tokens.
    static func isLayoutSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\r" || c == "\n"
    }

    static func string(_ s: Scalars, _ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[range])
        return String(view)
    }

    static func index(of target: Unicode.Scalar, in s: Scalars, from start: Int) -> Int? {
        var i = start
        while i < s.count {
            if s[i] == target { return i }
            i += 1
        }
        return nil
    }

    /// `@(\w+)\s*\{` matched exactly at `p`.
    static func matchEntry(_ s: Scalars, at p: Int) -> (type: String, afterBrace: Int)? {
        guard p < s.count, s[p] == "@" else { return nil }
        var q = p + 1
        let wordStart = q
        while q < s.count, isWord(s[q]) { q += 1 }
        guard q > wordStart else { return nil }
        var k = q
        while k < s.count, isSpace(s[k]) { k += 1 }
        guard k < s.count, s[k] == "{" else { return nil }
        return (string(s, wordStart..<q), k + 1)
    }

    /// `re.search(r"@(\w+)\s*\{", text)`.
    static func searchEntry(_ s: Scalars, from start: Int) -> (type: String, afterBrace: Int)? {
        var p = start
        while let at = index(of: "@", in: s, from: p) {
            if let m = matchEntry(s, at: at) { return m }
            p = at + 1
        }
        return nil
    }

    /// `re.compile(r"(\w+)\s*=\s*").search(text, i)`: returns the field name
    /// and the index just past the `=` and any following whitespace.
    static func searchField(_ s: Scalars, from start: Int) -> (name: String, valueStart: Int)? {
        let n = s.count
        var p = start
        while p < n {
            guard isWord(s[p]) else {
                p += 1
                continue
            }
            var q = p
            while q < n, isWord(s[q]) { q += 1 }
            var k = q
            while k < n, isSpace(s[k]) { k += 1 }
            if k < n, s[k] == "=" {
                k += 1
                while k < n, isSpace(s[k]) { k += 1 }
                return (string(s, p..<q), k)
            }
            // Any match starting inside this word would end at the same place
            // and fail the same way, so skip the whole word.
            p = q
        }
        return nil
    }
}
