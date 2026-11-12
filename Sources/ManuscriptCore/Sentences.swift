import Foundation

/// Splits a paragraph into sentences: for one-sentence-per-line Markdown,
/// Focus mode, topic sentences, long-sentence flags and counts. The same
/// rules everywhere, so what Focus mode calls a sentence is what goes on one
/// line in the file.
///
/// Works on UTF-16 offsets (so ranges map straight onto NSString). The
/// object replacement character U+FFFC stands for a token: a citation,
/// cross-reference or variable reads like a word; a footnote marker or note
/// (`attachable`) may hang after a sentence's full stop.
public enum Sentences {
    static let terminators: Set<UInt16> = [0x2E, 0x21, 0x3F, 0x2026]           // . ! ? …
    static let closers: Set<UInt16> = [0x22, 0x27, 0x29, 0x5D, 0x201D, 0x2019, 0x00BB, 0x203A, 0x2A, 0x5F]  // " ' ) ] ” ’ » › * _
    static let openers: Set<UInt16> = [0x22, 0x27, 0x28, 0x5B, 0x201C, 0x2018, 0x00AB, 0x2039, 0x2A, 0x5F]
    public static let placeholder: UInt16 = 0xFFFC

    /// Words after which a full stop doesn't end a sentence (lower case,
    /// without the stop).
    static let abbreviations: Set<String> = [
        "e.g", "i.e", "cf", "vs", "viz", "al", "approx", "ca", "c", "resp", "incl", "esp",
        "fig", "figs", "tab", "eq", "eqs", "no", "nos", "nr", "p", "pp", "para", "paras", "vol", "vols", "ed", "eds",
        "ch", "chap", "sec", "secs", "app", "ref", "refs", "n.d", "rev", "trans", "repr", "orig",
        "dr", "mr", "mrs", "ms", "prof", "st", "jr", "sr", "mt", "inc", "ltd", "co", "corp", "dept", "univ",
        "u.s", "u.k", "u.s.a", "ph.d", "m.sc", "b.sc", "m.a", "b.a", "m.b.a", "jan", "feb", "mar", "apr", "jun",
        "jul", "aug", "sep", "sept", "oct", "nov", "dec", "est", "min", "max", "avg", "std", "op", "loc", "ibid",
    ]

    /// Sentence ranges (UTF-16 offsets into `text`). Whitespace between
    /// sentences belongs to none of them; leading and trailing whitespace is
    /// excluded.
    public static func split(_ text: String, attachable: (Int) -> Bool = { _ in false }) -> [Range<Int>] {
        split(utf16: Array(text.utf16), attachable: attachable)
    }

    public static func split(utf16 u: [UInt16], attachable: (Int) -> Bool = { _ in false }) -> [Range<Int>] {
        let n = u.count
        var out: [Range<Int>] = []
        var start = 0
        while start < n, isSpace(u[start]) { start += 1 }
        var i = start
        while i < n {
            let c = u[i]
            guard terminators.contains(c) else {
                i += 1
                continue
            }
            var j = i + 1
            while j < n, terminators.contains(u[j]) { j += 1 }
            while j < n, closers.contains(u[j]) || (u[j] == placeholder && attachable(j)) { j += 1 }
            guard j < n, isSpace(u[j]) else {
                i = max(j, i + 1)
                continue
            }
            var k = j
            while k < n, isSpace(u[k]) { k += 1 }
            if k >= n { break }
            if isBoundary(u, terminatorAt: i, nextAt: k, start: start) {
                out.append(start..<j)
                start = k
                i = k
                continue
            }
            i = k
        }
        var end = n
        while end > start, isSpace(u[end - 1]) { end -= 1 }
        if end > start { out.append(start..<end) }
        return out
    }

    /// The sentence containing UTF-16 offset `location` (or the one just
    /// before it, if it falls between sentences).
    public static func sentence(at location: Int, in ranges: [Range<Int>]) -> Range<Int>? {
        var best: Range<Int>?
        for r in ranges {
            if r.contains(location) || r.upperBound == location { return r }
            if r.lowerBound > location { return best ?? r }
            best = r
        }
        return best
    }

    static func isSpace(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 || c == 0x2028 || c == 0x2029
            || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x3000
    }

    static func isLetter(_ c: UInt16) -> Bool {
        guard let s = Unicode.Scalar(c) else { return true }  // surrogates: treat as letters
        return s.properties.isAlphabetic
    }

    static func isUpper(_ c: UInt16) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return s.properties.isUppercase || (s.properties.isAlphabetic && !s.properties.isLowercase && !s.properties.isUppercase)
    }

    static func isLower(_ c: UInt16) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return s.properties.isLowercase
    }

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    static func isBoundary(_ u: [UInt16], terminatorAt i: Int, nextAt k: Int, start: Int) -> Bool {
        let next = u[k]
        // A lower-case word continues the sentence ("e.g. the", "p. vii").
        if isLower(next) { return false }
        let startsSentence = isUpper(next) || isDigit(next) || openers.contains(next) || next == placeholder
            || !isLetter(next)
        guard startsSentence else { return false }
        if u[i] != 0x2E { return true }   // ! ? … end sentences
        // A full stop after an abbreviation or an initial doesn't.
        var w = i
        while w > start, !isSpace(u[w - 1]), !openers.contains(u[w - 1]) { w -= 1 }
        let wordUnits = Array(u[w..<i])
        let word = String(decoding: wordUnits, as: UTF16.self)
        if word.isEmpty { return true }
        let lower = word.lowercased()
        if abbreviations.contains(lower) { return false }
        // A single capital letter: an initial ("J. Smith").
        if wordUnits.count == 1, isUpper(wordUnits[0]) { return false }
        // Dotted abbreviations such as "U.S" or "e.g" not in the list.
        if lower.count >= 3, lower.contains("."),
           lower.split(separator: ".").allSatisfy({ $0.count <= 2 && $0.allSatisfy(\.isLetter) }) {
            return false
        }
        return true
    }
}

// MARK: - Words

public enum WordCount {
    /// Words in plain text: runs of letters and digits, with apostrophes
    /// and hyphens inside a word, and points and commas inside a number,
    /// counting once.
    public static func count(_ text: String) -> Int {
        var count = 0
        var inWord = false
        var pendingJoiner = false
        var lastWasDigit = false
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if !inWord { count += 1 }
                inWord = true
                pendingJoiner = false
                lastWasDigit = ch.isNumber
            } else if inWord && !pendingJoiner
                        && (ch == "'" || ch == "\u{2019}" || ch == "-" || ch == "\u{2010}" || ch == "\u{2011}"
                            || (lastWasDigit && (ch == "." || ch == ","))) {
                // "don't", "well-being", "3.5" and "10,000" are one word each.
                pendingJoiner = true
            } else {
                inWord = false
                pendingJoiner = false
            }
        }
        return count
    }
}
