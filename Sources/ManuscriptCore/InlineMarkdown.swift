import Foundation

/// Inline Markdown: emphasis, `{{variables}}`, `[^footnote]` markers and
/// `<!-- notes -->`, read and written in the subset pandoc reads the same
/// way (docs/FILE_FORMAT.md §Inline). Citations and cross-references are
/// plain text in the file; `Recognizer` finds them after parsing.
public enum InlineMarkdown {
    // MARK: Parsing

    private enum Seg {
        case text(String)
        case token(Token)
        case delim(char: Character, count: Int, canOpen: Bool, canClose: Bool)
    }

    private struct Span {
        var from: Int
        var to: Int
        var strong: Bool
    }

    /// Parses one paragraph's worth of inline Markdown (lines already
    /// joined). `footnotes` resolves `[^label]` markers.
    public static func parse(_ s: String, footnotes: [String: [Inline]] = [:]) -> [Inline] {
        let chars = Array(s)
        var segs: [Seg] = []
        var buffer = ""

        func flush() {
            if !buffer.isEmpty {
                segs.append(.text(buffer))
                buffer = ""
            }
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "{", let (name, end) = variable(chars, at: i) {
                flush()
                segs.append(.token(.variable(name)))
                i = end
                continue
            }
            if c == "[", i + 1 < chars.count, chars[i + 1] == "^", let (label, end) = footnoteLabel(chars, at: i),
               let content = footnotes[label] {
                flush()
                segs.append(.token(.footnote(content)))
                i = end
                continue
            }
            if c == "<", let (note, end) = htmlComment(chars, at: i) {
                flush()
                segs.append(.token(.note(note)))
                i = end
                continue
            }
            if c == "*" || c == "_" {
                var j = i
                while j < chars.count, chars[j] == c { j += 1 }
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                let next: Character? = j < chars.count ? chars[j] : nil
                let prevSpace = prev.map(\.isWhitespace) ?? true
                let nextSpace = next.map(\.isWhitespace) ?? true
                let prevPunct = prev.map(isPunctuation) ?? false
                let nextPunct = next.map(isPunctuation) ?? false
                let left = !nextSpace && (!nextPunct || prevSpace || prevPunct)
                let right = !prevSpace && (!prevPunct || nextSpace || nextPunct)
                let canOpen: Bool
                let canClose: Bool
                if c == "*" {
                    canOpen = left
                    canClose = right
                } else {
                    canOpen = left && (!right || prevPunct)
                    canClose = right && (!left || nextPunct)
                }
                flush()
                segs.append(.delim(char: c, count: j - i, canOpen: canOpen, canClose: canClose))
                i = j
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return resolveEmphasis(segs)
    }

    private static func resolveEmphasis(_ input: [Seg]) -> [Inline] {
        var segs = input
        var remaining: [Int: Int] = [:]
        var original: [Int: Int] = [:]
        for (k, seg) in segs.enumerated() {
            if case .delim(_, let count, _, _) = seg {
                remaining[k] = count
                original[k] = count
            }
        }
        var spans: [Span] = []
        var openers: [Int] = []
        for k in segs.indices {
            guard case .delim(let ch, _, let canOpen, let canClose) = segs[k] else { continue }
            if canClose {
                var si = openers.count - 1
                while (remaining[k] ?? 0) > 0 && si >= 0 {
                    let o = openers[si]
                    guard case .delim(let och, _, let oCanOpen, let oCanClose) = segs[o], och == ch,
                          (remaining[o] ?? 0) > 0, oCanOpen else {
                        si -= 1
                        continue
                    }
                    // CommonMark's "rule of three".
                    if (oCanClose || canOpen), ((original[o] ?? 0) + (original[k] ?? 0)) % 3 == 0,
                       !((original[o] ?? 0) % 3 == 0 && (original[k] ?? 0) % 3 == 0) {
                        si -= 1
                        continue
                    }
                    let use = ((remaining[o] ?? 0) >= 2 && (remaining[k] ?? 0) >= 2) ? 2 : 1
                    spans.append(Span(from: o, to: k, strong: use == 2))
                    remaining[o] = (remaining[o] ?? 0) - use
                    remaining[k] = (remaining[k] ?? 0) - use
                    if si + 1 < openers.count { openers.removeSubrange((si + 1)...) }
                    if (remaining[o] ?? 0) == 0 {
                        openers.remove(at: si)
                        si -= 1
                    }
                }
            }
            if canOpen && (remaining[k] ?? 0) > 0 { openers.append(k) }
        }
        var out: [Inline] = []
        for k in segs.indices {
            var style = InlineStyle()
            for span in spans where span.from < k && k < span.to {
                if span.strong { style.bold = true } else { style.italic = true }
            }
            switch segs[k] {
            case .text(let t):
                out.append(.text(t, style))
            case .token(let t):
                out.append(.token(t, style))
            case .delim(let ch, _, _, _):
                let left = remaining[k] ?? 0
                if left > 0 { out.append(.text(String(repeating: ch, count: left), style)) }
            }
        }
        segs.removeAll()
        return out.coalesced
    }

    private static func variable(_ chars: [Character], at i: Int) -> (String, Int)? {
        guard i + 1 < chars.count, chars[i + 1] == "{" else { return nil }
        var j = i + 2
        let triple = j < chars.count && chars[j] == "{"
        if triple { j += 1 }
        var name = ""
        while j < chars.count, chars[j] != "}" {
            name.append(chars[j])
            j += 1
            if name.count > 80 { return nil }
        }
        let closing = triple ? 3 : 2
        guard j + closing <= chars.count, chars[j..<(j + closing)].allSatisfy({ $0 == "}" }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard Variable.isValidName(trimmed) else { return nil }
        return (trimmed, j + closing)
    }

    private static func footnoteLabel(_ chars: [Character], at i: Int) -> (String, Int)? {
        var j = i + 2
        var label = ""
        while j < chars.count, chars[j] != "]" {
            if chars[j].isWhitespace || chars[j] == "[" { return nil }
            label.append(chars[j])
            j += 1
        }
        guard j < chars.count, !label.isEmpty else { return nil }
        return (label, j + 1)
    }

    private static func htmlComment(_ chars: [Character], at i: Int) -> (String, Int)? {
        guard i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" else { return nil }
        var j = i + 4
        while j + 2 < chars.count {
            if chars[j] == "-", chars[j + 1] == "-", chars[j + 2] == ">" {
                let inner = String(chars[(i + 4)..<j]).trimmingCharacters(in: .whitespaces)
                return (inner, j + 3)
            }
            j += 1
        }
        return nil
    }

    static func isASCIIPunctuation(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        return (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v)
    }

    static func isPunctuation(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    // MARK: Writing

    /// Writes inlines as Markdown. `token` gives each token's Markdown
    /// (already escaped where that matters).
    public static func emit(_ inlines: [Inline], token: (Token) -> String) -> String {
        struct Piece {
            var text: String
            var style: InlineStyle
        }
        var pieces: [Piece] = []
        for inline in inlines.coalesced {
            switch inline {
            case .text(let t, let s): pieces.append(Piece(text: escapeText(t), style: s))
            case .token(let t, let s): pieces.append(Piece(text: token(t), style: s))
            }
        }
        // Group by bold, then by italic inside each bold group.
        var out = ""
        var k = 0
        while k < pieces.count {
            let bold = pieces[k].style.bold
            var group: [Piece] = []
            while k < pieces.count, pieces[k].style.bold == bold {
                group.append(pieces[k])
                k += 1
            }
            var inner = ""
            var m = 0
            while m < group.count {
                let italic = group[m].style.italic
                var text = ""
                while m < group.count, group[m].style.italic == italic {
                    text += group[m].text
                    m += 1
                }
                if italic {
                    // "_" never runs into a bold "**"; "*" works inside a word.
                    let before = (inner.last ?? out.last).map { $0.isLetter || $0.isNumber } ?? false
                    let after = m < group.count ? (group[m].text.first.map { $0.isLetter || $0.isNumber } ?? false)
                        : (k < pieces.count ? (pieces[k].text.first.map { $0.isLetter || $0.isNumber } ?? false) : false)
                    inner += wrap(text, with: before || after ? "*" : "_")
                } else {
                    inner += text
                }
            }
            out += bold ? wrap(inner, with: "**") : inner
        }
        return out
    }

    /// `marker` + text + `marker`, with surrounding whitespace moved outside
    /// (emphasis can't start or end with a space).
    static func wrap(_ text: String, with marker: String) -> String {
        let lead = text.prefix(while: { $0.isWhitespace })
        let rest = text.dropFirst(lead.count)
        var core = String(rest)
        var trail = ""
        while let last = core.last, last.isWhitespace {
            trail = String(last) + trail
            core.removeLast()
        }
        if core.isEmpty { return text }
        return String(lead) + marker + core + marker + trail
    }

    /// Escapes what Markdown (or pandoc) would otherwise read as syntax.
    public static func escapeText(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let prevWord = prev.map { $0.isLetter || $0.isNumber } ?? false
            let nextWord = next.map { $0.isLetter || $0.isNumber } ?? false
            switch c {
            case "\\", "*", "`":
                out += "\\" + String(c)
            case "_":
                out += (prevWord && nextWord) ? "_" : "\\_"
            case "[":
                out += next == "^" ? "\\[" : "["
            case "<":
                if let next, next.isLetter || next == "/" || next == "!" { out += "\\<" } else { out += "<" }
            case "@":
                out += prevWord ? "@" : "\\@"
            case "{":
                out += next == "{" ? "\\{" : "{"
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Escapes for an image's alt text (a figure caption), where brackets
    /// must balance.
    public static func escapeCaption(_ markdown: String) -> String {
        var out = ""
        var previous: Character = " "
        for c in markdown {
            if (c == "[" || c == "]") && previous != "\\" {
                out += "\\" + String(c)
            } else {
                out.append(c)
            }
            previous = c
        }
        return out
    }
}
