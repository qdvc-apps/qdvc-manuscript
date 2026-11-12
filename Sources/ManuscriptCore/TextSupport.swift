import Foundation

/// A thin wrapper around `NSRegularExpression` (as in QDVC Bibliotheca):
/// patterns are compiled once, kept in `static let`s; a bad pattern is a
/// programmer error.
struct Rx {
    let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            fatalError("Invalid regular expression \(pattern): \(error)")
        }
    }

    private func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..<s.endIndex, in: s)
    }

    func replace(_ s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, options: [], range: fullRange(s), withTemplate: template)
    }

    func matches(_ s: String) -> Bool {
        regex.firstMatch(in: s, options: [], range: fullRange(s)) != nil
    }

    func firstMatch(_ s: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: s, options: [], range: fullRange(s))
    }

    func allMatches(_ s: String) -> [NSTextCheckingResult] {
        regex.matches(in: s, options: [], range: fullRange(s))
    }

    func group(_ match: NSTextCheckingResult, _ index: Int, in s: String) -> String? {
        let r = match.range(at: index)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }

    func split(_ s: String) -> [String] {
        var parts: [String] = []
        var cursor = s.startIndex
        for m in regex.matches(in: s, options: [], range: fullRange(s)) {
            guard let r = Range(m.range, in: s) else { continue }
            parts.append(String(s[cursor..<r.lowerBound]))
            cursor = r.upperBound
        }
        parts.append(String(s[cursor...]))
        return parts
    }
}

extension String {
    /// Python's `str.strip()`.
    var pyStrip: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pyStrip(_ chars: String) -> String {
        trimmingCharacters(in: CharacterSet(charactersIn: chars))
    }

    /// Whitespace-separated words.
    var pyWords: [String] {
        split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// A file-name-friendly slug: lower case, runs of anything but a–z and
    /// 0–9 become "-", at most `limit` characters, cut at a word break.
    public func slug(limit: Int = 50) -> String {
        var out = ""
        var dash = false
        let folded = folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        for scalar in folded.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash && !out.isEmpty {
                out += "-"
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > limit {
            var cut = String(out.prefix(limit))
            if let dashIndex = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: dashIndex) > limit / 2 {
                cut = String(cut[..<dashIndex])
            }
            out = cut
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    /// Normalised line endings ("\r\n" and "\r" become "\n"), no BOM.
    var normalisedNewlines: String {
        var t = self
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

public enum TextTools {
    /// The first `limit` characters, cut at a word, with "…" if shortened.
    public static func excerpt(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        var cut = String(flat.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }

    /// A short random identifier ("a1b2c3d4").
    public static func randomID(prefix: String = "") -> String {
        let chars = Array("0123456789abcdef")
        return prefix + String((0..<8).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

/// Reads a file as UTF-8, replacing invalid sequences; nil if unreadable.
func readTextLossy(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

public func directoryExists(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

public func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}
