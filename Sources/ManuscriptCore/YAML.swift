import Foundation

// A small, self-contained YAML reader and writer, enough for the workspace
// files (docs/FILE_FORMAT.md §YAML). It reads the block style that the app
// writes, plus the things people tend to type when editing by hand:
//
//   - mappings and sequences nested by indentation (spaces, not tabs),
//     including "- key: value" items and "key:" followed by "- item" at the
//     same indentation;
//   - plain, 'single-quoted' and "double-quoted" scalars (with \n, \t, \",
//     \\, \uXXXX escapes), and # comments;
//   - literal (|) and folded (>) block scalars with the -, + chomping
//     indicators and an optional indentation indicator;
//   - one-line flow sequences of scalars ([a, b, "c, d"]) and the empty
//     flow collections [] and {}.
//
// Not supported (an error, never a silent misreading): anchors and aliases,
// tags, multiple documents, flow mappings with content, nested flow
// collections, and complex keys. Scalars are not typed: everything is a
// string until a caller asks for an Int or a Bool.

/// A parsed YAML value.
public indirect enum YAMLNode: Equatable, Sendable {
    case null
    case scalar(String)
    case sequence([YAMLNode])
    case mapping([YAMLPair])

    /// The value for `key` in a mapping (the first, if repeated).
    public subscript(key: String) -> YAMLNode? {
        guard case .mapping(let pairs) = self else { return nil }
        return pairs.first(where: { $0.key == key })?.value
    }

    public var string: String? {
        if case .scalar(let s) = self { return s }
        return nil
    }

    public var int: Int? {
        guard let s = string?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(s)
    }

    public var double: Double? {
        guard let s = string?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Double(s)
    }

    public var bool: Bool? {
        switch string?.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    /// Items of a sequence; a lone scalar reads as a one-item sequence and
    /// null as an empty one, which forgives a common hand-editing slip.
    public var items: [YAMLNode] {
        switch self {
        case .sequence(let items): return items
        case .null: return []
        case .scalar: return [self]
        case .mapping: return []
        }
    }

    /// The strings in a sequence (non-scalars are skipped).
    public var strings: [String] { items.compactMap(\.string) }

    public var pairs: [YAMLPair] {
        if case .mapping(let pairs) = self { return pairs }
        return []
    }

    public var isNull: Bool { self == .null }
}

public struct YAMLPair: Equatable, Sendable {
    public var key: String
    public var value: YAMLNode

    public init(_ key: String, _ value: YAMLNode) {
        self.key = key
        self.value = value
    }
}

public struct YAMLError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 1-based line number.
    public let line: Int
    public let message: String

    public var description: String { "line \(line): \(message)" }
}

public enum YAML {
    /// Parses a document. An empty document is `.null`.
    public static func parse(_ text: String) throws -> YAMLNode {
        var parser = YAMLParser(text: text)
        return try parser.parseDocument()
    }

    /// Writes a node as a block-style document ending in a newline. Values
    /// of `blockKeys` are always written in block style: strings as literal
    /// blocks (|), lists one item per line.
    /// `quoteTyped`: also quote strings a YAML 1.1 reader (PyYAML, which
    /// pandoc-mustache uses) would read as numbers, booleans or dates, so
    /// "7.40" isn't read as 7.4.
    public static func emit(_ node: YAMLNode, blockKeys: Set<String> = [], quoteTyped: Bool = false) -> String {
        var lines: [String] = []
        let emitter = YAMLEmitter(blockKeys: blockKeys, quoteTyped: quoteTyped)
        switch node {
        case .mapping(let pairs):
            emitter.emitMapping(pairs, indent: 0, into: &lines)
        case .sequence(let items):
            emitter.emitSequence(items, indent: 0, into: &lines)
        case .scalar(let s):
            lines.append(emitter.text(s))
        case .null:
            break
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Convenience builders

extension YAMLNode {
    public static func str(_ s: String) -> YAMLNode { .scalar(s) }
    public static func num(_ n: Int) -> YAMLNode { .scalar(String(n)) }
    public static func flag(_ b: Bool) -> YAMLNode { .scalar(b ? "true" : "false") }
    public static func list(_ strings: [String]) -> YAMLNode { .sequence(strings.map { .scalar($0) }) }
    public static func map(_ pairs: [(String, YAMLNode)]) -> YAMLNode {
        .mapping(pairs.map { YAMLPair($0.0, $0.1) })
    }
}

// MARK: - Parser

private struct YAMLParser {
    var lines: [String]
    var i = 0

    init(text: String) {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        lines = t.components(separatedBy: "\n")
    }

    // MARK: Line helpers

    static func indent(of line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else { break }
        }
        return n
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func isIgnorable(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#") || t == "---" || t == "..."
    }

    func error(_ message: String, line: Int? = nil) -> YAMLError {
        YAMLError(line: (line ?? i) + 1, message: message)
    }

    /// Moves `i` to the next line with content; returns false at the end.
    mutating func skipIgnorable() -> Bool {
        while i < lines.count, Self.isIgnorable(lines[i]) { i += 1 }
        return i < lines.count
    }

    func content(_ line: String) -> String {
        String(line.dropFirst(Self.indent(of: line)))
    }

    mutating func checkTabs(_ line: String) throws {
        let lead = line.prefix(while: { $0 == " " || $0 == "\t" })
        if lead.contains("\t") { throw error("tabs cannot be used for indentation") }
    }

    // MARK: Structure

    mutating func parseDocument() throws -> YAMLNode {
        guard skipIgnorable() else { return .null }
        let node = try parseNode(minIndent: 0)
        if skipIgnorable() {
            throw error("unexpected content (check the indentation)")
        }
        return node
    }

    static func isSequenceEntry(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ")
    }

    /// Parses the node starting at the next content line, which must be
    /// indented at least `minIndent`; `.null` if it is not.
    mutating func parseNode(minIndent: Int) throws -> YAMLNode {
        guard skipIgnorable() else { return .null }
        let line = lines[i]
        try checkTabs(line)
        let n = Self.indent(of: line)
        guard n >= minIndent else { return .null }
        let c = content(line)
        if Self.isSequenceEntry(c) { return try parseSequence(indent: n) }
        if Self.splitKey(c) != nil { return try parseMapping(indent: n) }
        // A lone scalar (or block scalar) as the node.
        i += 1
        return try parseValueText(c, parentIndent: max(minIndent - 1, 0), lineIndex: i - 1)
    }

    mutating func parseMapping(indent n: Int) throws -> YAMLNode {
        var pairs: [YAMLPair] = []
        while skipIgnorable() {
            let line = lines[i]
            try checkTabs(line)
            let ind = Self.indent(of: line)
            if ind < n { break }
            if ind > n { throw error("unexpected indentation") }
            let c = content(line)
            if Self.isSequenceEntry(c) {
                throw error("a list item cannot appear here (expected \"key: value\")")
            }
            guard let (key, rest) = Self.splitKey(c) else {
                throw error("expected \"key: value\"")
            }
            let lineIndex = i
            i += 1
            let value = try parseValue(rest, parentIndent: n, lineIndex: lineIndex)
            pairs.append(YAMLPair(key, value))
        }
        return .mapping(pairs)
    }

    mutating func parseSequence(indent n: Int) throws -> YAMLNode {
        var items: [YAMLNode] = []
        while skipIgnorable() {
            let line = lines[i]
            try checkTabs(line)
            let ind = Self.indent(of: line)
            if ind < n { break }
            if ind > n { throw error("unexpected indentation") }
            let c = content(line)
            guard Self.isSequenceEntry(c) else { break }
            let afterDash = c.dropFirst()
            let gap = afterDash.prefix(while: { $0 == " " }).count
            let rest = String(afterDash.dropFirst(gap))
            if rest.isEmpty || rest.hasPrefix("#") {
                i += 1
                items.append(try parseNode(minIndent: n + 1))
            } else {
                // Replace "- " with spaces and parse what follows as a node
                // indented at the item's content column: this handles
                // "- key: value" mappings, "- - nested" and plain items alike.
                lines[i] = String(repeating: " ", count: n + 1 + gap) + rest
                items.append(try parseNode(minIndent: n + 1))
            }
        }
        return .sequence(items)
    }

    /// The value after "key:".
    mutating func parseValue(_ rest: String, parentIndent n: Int, lineIndex: Int) throws -> YAMLNode {
        let r = Self.stripComment(rest).trimmingCharacters(in: .whitespaces)
        if r.isEmpty {
            guard skipIgnorable() else { return .null }
            let next = lines[i]
            let ind = Self.indent(of: next)
            if ind > n { return try parseNode(minIndent: n + 1) }
            if ind == n, Self.isSequenceEntry(content(next)) { return try parseSequence(indent: n) }
            return .null
        }
        return try parseValueText(r, parentIndent: n, lineIndex: lineIndex)
    }

    /// A scalar, block scalar or flow sequence given as text on one line;
    /// block scalar content follows from line `i`.
    mutating func parseValueText(_ raw: String, parentIndent n: Int, lineIndex: Int) throws -> YAMLNode {
        let r = Self.stripComment(raw).trimmingCharacters(in: .whitespaces)
        if let first = r.first, first == "|" || first == ">" {
            return .scalar(try parseBlockScalar(header: r, parentIndent: n, lineIndex: lineIndex))
        }
        if r.hasPrefix("[") { return try parseFlowSequence(r, lineIndex: lineIndex) }
        if r.hasPrefix("{") {
            if r.replacingOccurrences(of: " ", with: "") == "{}" { return .mapping([]) }
            throw error("flow mappings ({…}) are not supported", line: lineIndex)
        }
        if r.hasPrefix("&") || r.hasPrefix("*") || r.hasPrefix("!") {
            throw error("anchors, aliases and tags are not supported", line: lineIndex)
        }
        if r.hasPrefix("\"") || r.hasPrefix("'") {
            var text = r
            // A double-quoted scalar may continue onto following lines.
            while Self.quotedEnd(text) == nil, i < lines.count {
                let next = lines[i].trimmingCharacters(in: .whitespaces)
                i += 1
                text += next.isEmpty ? "\\n" : " " + next
            }
            guard let end = Self.quotedEnd(text) else {
                throw error("unterminated quoted string", line: lineIndex)
            }
            let after = Self.stripComment(String(text[end...])).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { throw error("unexpected text after a quoted string", line: lineIndex) }
            return .scalar(try Self.unquote(String(text[..<end]), line: lineIndex + 1))
        }
        switch r {
        case "~", "null", "Null", "NULL": return .null
        default: return .scalar(r)
        }
    }

    mutating func parseBlockScalar(header: String, parentIndent n: Int, lineIndex: Int) throws -> String {
        let folded = header.first == ">"
        var chomp: Character = " "
        var indicator: Int?
        for ch in header.dropFirst() {
            if ch == "-" || ch == "+" { chomp = ch }
            else if let d = ch.wholeNumberValue, d > 0 { indicator = d }
            else if ch == " " { break }
            else { throw error("bad block scalar header \"\(header)\"", line: lineIndex) }
        }
        var contentIndent: Int
        if let indicator {
            contentIndent = n + indicator
        } else {
            var j = i
            while j < lines.count, Self.isBlank(lines[j]) { j += 1 }
            guard j < lines.count else { return "" }
            contentIndent = Self.indent(of: lines[j])
            if contentIndent <= n { contentIndent = n + 1 }
        }
        var body: [String] = []
        while i < lines.count {
            let line = lines[i]
            if Self.isBlank(line) {
                body.append(line.count > contentIndent ? String(line.dropFirst(contentIndent)) : "")
                i += 1
                continue
            }
            if Self.indent(of: line) < contentIndent { break }
            body.append(String(line.dropFirst(contentIndent)))
            i += 1
        }
        // Trailing blank lines are governed by chomping.
        var trailing = 0
        while let last = body.last, last.isEmpty {
            body.removeLast()
            trailing += 1
        }
        var text: String
        if folded {
            // Line breaks between ordinary lines become spaces; a blank line
            // stands for one line break; more-indented lines keep theirs.
            enum Previous { case start, blank, text, more }
            text = ""
            var previous = Previous.start
            for line in body {
                if line.isEmpty {
                    text += "\n"
                    previous = .blank
                } else if line.hasPrefix(" ") {
                    if previous == .text || previous == .more { text += "\n" }
                    text += line
                    previous = .more
                } else {
                    if previous == .text { text += " " } else if previous == .more { text += "\n" }
                    text += line
                    previous = .text
                }
            }
        } else {
            text = body.joined(separator: "\n")
        }
        if body.isEmpty { return chomp == "+" ? String(repeating: "\n", count: trailing) : "" }
        switch chomp {
        case "-": return text
        case "+": return text + "\n" + String(repeating: "\n", count: trailing)
        default: return text + "\n"
        }
    }

    mutating func parseFlowSequence(_ start: String, lineIndex: Int) throws -> YAMLNode {
        var text = start
        while Self.flowEnd(text) == nil, i < lines.count {
            text += " " + lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
        }
        guard let end = Self.flowEnd(text) else {
            throw error("unterminated [ … ] list", line: lineIndex)
        }
        let after = Self.stripComment(String(text[text.index(after: end)...])).trimmingCharacters(in: .whitespaces)
        if !after.isEmpty { throw error("unexpected text after a [ … ] list", line: lineIndex) }
        let inner = text[text.index(after: text.startIndex)..<end]
        var items: [YAMLNode] = []
        var current = ""
        var quote: Character?
        var escaped = false
        func flush() throws {
            let t = current.trimmingCharacters(in: .whitespaces)
            current = ""
            if t.isEmpty { return }
            if t.hasPrefix("[") || t.hasPrefix("{") {
                throw error("nested [ … ] lists are not supported", line: lineIndex)
            }
            if t.hasPrefix("\"") || t.hasPrefix("'") {
                items.append(.scalar(try Self.unquote(t, line: lineIndex + 1)))
            } else if t == "~" || t == "null" {
                items.append(.null)
            } else {
                items.append(.scalar(t))
            }
        }
        var pendingSingle = false
        for ch in inner {
            if pendingSingle {
                // After a ' in a single-quoted item: '' continues the item.
                pendingSingle = false
                if ch == "'" { current.append(ch); quote = "'"; continue }
            }
            if let q = quote {
                current.append(ch)
                if q == "\"" && ch == "\\" && !escaped { escaped = true; continue }
                if ch == q && !escaped {
                    quote = nil
                    if q == "'" { pendingSingle = true }
                }
                escaped = false
            } else if (ch == "\"" || ch == "'") && current.trimmingCharacters(in: .whitespaces).isEmpty {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                try flush()
            } else {
                current.append(ch)
            }
        }
        try flush()
        return .sequence(items)
    }

    // MARK: Scalars

    /// Splits "key: rest" (or "key:"), with a plain or quoted key.
    static func splitKey(_ c: String) -> (String, String)? {
        if c.hasPrefix("\"") || c.hasPrefix("'") {
            guard let end = quotedEnd(c), let key = try? unquote(String(c[..<end]), line: 0) else { return nil }
            let after = c[end...]
            guard after.hasPrefix(":") else { return nil }
            let rest = after.dropFirst()
            guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
            return (key, String(rest))
        }
        if let first = c.first, "[{|>#&*!%@`\"'".contains(first) { return nil }
        if isSequenceEntry(c) { return nil }
        var idx = c.startIndex
        while idx < c.endIndex {
            if c[idx] == ":" {
                let next = c.index(after: idx)
                if next == c.endIndex || c[next] == " " {
                    let key = String(c[..<idx]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    return (key, String(c[next...]))
                }
            }
            if c[idx] == "#", idx > c.startIndex, c[c.index(before: idx)] == " " { return nil }
            idx = c.index(after: idx)
        }
        return nil
    }

    /// Removes a trailing "# comment" outside quotes.
    static func stripComment(_ s: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character = " "
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if let q = quote {
                if q == "\"" && ch == "\\" && !escaped { escaped = true; previous = ch; idx = s.index(after: idx); continue }
                if ch == q && !escaped { quote = nil }
                escaped = false
            } else if (ch == "\"" || ch == "'") && (previous == " " || previous == "[" || previous == ",") {
                quote = ch
            } else if ch == "#" && (previous == " " || previous == "\t") {
                return String(s[..<idx])
            }
            previous = ch
            idx = s.index(after: idx)
        }
        return s
    }

    /// The index just past the closing quote of a quoted scalar at the start
    /// of `s`, or nil if it is not closed.
    static func quotedEnd(_ s: String) -> String.Index? {
        guard let q = s.first, q == "\"" || q == "'" else { return nil }
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            let ch = s[idx]
            if q == "\"" && ch == "\\" {
                idx = s.index(after: idx)
                if idx < s.endIndex { idx = s.index(after: idx) }
                continue
            }
            if ch == q {
                let next = s.index(after: idx)
                if q == "'" && next < s.endIndex && s[next] == "'" {
                    idx = s.index(after: next)
                    continue
                }
                return next
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    /// The index of the "]" that closes a flow sequence at the start of `s`.
    static func flowEnd(_ s: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        var atItemStart = true
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            let ch = s[idx]
            if let q = quote {
                if q == "\"" && ch == "\\" && !escaped { escaped = true; idx = s.index(after: idx); continue }
                if ch == q && !escaped {
                    // '' inside a single-quoted item is an escaped quote.
                    let next = s.index(after: idx)
                    if q == "'" && next < s.endIndex && s[next] == "'" {
                        idx = s.index(after: next)
                        continue
                    }
                    quote = nil
                }
                escaped = false
            } else if (ch == "\"" || ch == "'") && atItemStart {
                quote = ch
            } else if ch == "]" {
                return idx
            }
            if quote == nil {
                if ch == "," { atItemStart = true } else if ch != " " { atItemStart = false }
            } else {
                atItemStart = false
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    static func unquote(_ s: String, line: Int) throws -> String {
        guard let q = s.first, s.count >= 2, s.last == q else {
            throw YAMLError(line: line, message: "bad quoted string")
        }
        let inner = s.dropFirst().dropLast()
        if q == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = ""
        var it = inner.makeIterator()
        while let ch = it.next() {
            guard ch == "\\" else { out.append(ch); continue }
            guard let e = it.next() else { throw YAMLError(line: line, message: "bad escape at end of string") }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case " ": out.append(" ")
            case "u", "U", "x":
                let count = e == "x" ? 2 : (e == "u" ? 4 : 8)
                var hex = ""
                for _ in 0..<count { if let h = it.next() { hex.append(h) } }
                guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                    throw YAMLError(line: line, message: "bad \\\(e) escape")
                }
                out.unicodeScalars.append(scalar)
            default:
                throw YAMLError(line: line, message: "unknown escape \\\(e)")
            }
        }
        return out
    }
}

// MARK: - Emitter

struct YAMLEmitter {
    var blockKeys: Set<String> = []
    var quoteTyped = false

    /// A scalar as written, honouring `quoteTyped`.
    func text(_ s: String, flow: Bool = false, forceSingleLine: Bool = false) -> String {
        if quoteTyped && Self.looksTyped(s) { return Self.doubleQuoted(s) }
        return Self.scalar(s, flow: flow, forceSingleLine: forceSingleLine)
    }

    static func spaces(_ n: Int) -> String { String(repeating: " ", count: n) }

    func emitMapping(_ pairs: [YAMLPair], indent: Int, into lines: inout [String]) {
        let pad = Self.spaces(indent)
        for pair in pairs {
            let key = Self.keyText(pair.key)
            let block = blockKeys.contains(pair.key)
            switch pair.value {
            case .null:
                lines.append("\(pad)\(key):")
            case .scalar(let s):
                if s.contains("\n") || s.contains("\r") || (block && !s.isEmpty) {
                    lines.append("\(pad)\(key): \(Self.blockHeader(s))")
                    lines.append(contentsOf: Self.blockLines(s, indent: indent + 2))
                } else {
                    lines.append("\(pad)\(key): \(text(s))")
                }
            case .sequence(let items):
                if items.isEmpty {
                    lines.append("\(pad)\(key): []")
                } else if !block, let flow = flowText(items) {
                    lines.append("\(pad)\(key): \(flow)")
                } else {
                    lines.append("\(pad)\(key):")
                    emitSequence(items, indent: indent + 2, into: &lines)
                }
            case .mapping(let inner):
                if inner.isEmpty {
                    lines.append("\(pad)\(key): {}")
                } else {
                    lines.append("\(pad)\(key):")
                    emitMapping(inner, indent: indent + 2, into: &lines)
                }
            }
        }
    }

    func emitSequence(_ items: [YAMLNode], indent: Int, into lines: inout [String]) {
        let pad = Self.spaces(indent)
        for item in items {
            switch item {
            case .null:
                lines.append("\(pad)- ~")
            case .scalar(let s):
                lines.append("\(pad)- \(text(s, forceSingleLine: true))")
            case .sequence(let inner):
                if inner.isEmpty {
                    lines.append("\(pad)- []")
                } else {
                    var sub: [String] = []
                    emitSequence(inner, indent: indent + 2, into: &sub)
                    sub[0] = pad + "- " + sub[0].dropFirst(indent + 2)
                    lines.append(contentsOf: sub)
                }
            case .mapping(let inner):
                if inner.isEmpty {
                    lines.append("\(pad)- {}")
                } else {
                    var sub: [String] = []
                    emitMapping(inner, indent: indent + 2, into: &sub)
                    sub[0] = pad + "- " + sub[0].dropFirst(indent + 2)
                    lines.append(contentsOf: sub)
                }
            }
        }
    }

    /// A short list of short scalars goes on one line; anything else (or a
    /// list long enough to make diffs noisy) is written one item per line.
    func flowText(_ items: [YAMLNode]) -> String? {
        var parts: [String] = []
        for item in items {
            guard case .scalar(let s) = item, !s.contains("\n") else { return nil }
            parts.append(text(s, flow: true, forceSingleLine: true))
        }
        let text = "[" + parts.joined(separator: ", ") + "]"
        return (text.count <= 60 && items.count <= 6) ? text : nil
    }

    static func keyText(_ key: String) -> String {
        let plain = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
            && !key.hasPrefix("-")
        return plain ? key : doubleQuoted(key)
    }

    static func needsQuotes(_ s: String, flow: Bool) -> Bool {
        if s.isEmpty { return true }
        if s.first == " " || s.last == " " { return true }
        if let first = s.first, "-?:,[]{}#&*!|>'\"%@`~".contains(first) {
            // "-x" is fine as plain YAML, but quoting every leading indicator
            // keeps the rule simple and the reader forgiving.
            return true
        }
        if s.contains(": ") || s.contains(" #") || s.hasSuffix(":") { return true }
        if flow && (s.contains(",") || s.contains("[") || s.contains("]") || s.contains("{") || s.contains("}")) {
            return true
        }
        if ["null", "Null", "NULL", "~"].contains(s) { return true }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\u{FEFF}" }) {
            return true
        }
        return false
    }

    /// True for strings a YAML 1.1 reader types: booleans, numbers, dates.
    static func looksTyped(_ s: String) -> Bool {
        let bools: Set<String> = ["true", "false", "yes", "no", "on", "off", "y", "n"]
        if bools.contains(s.lowercased()) { return true }
        if s.range(of: "^[-+]?(\\d[\\d_]*)?(\\.\\d*)?([eE][-+]?\\d+)?$", options: .regularExpression) != nil,
           s.contains(where: { $0.isNumber }) {
            return true
        }
        if s.range(of: "^0[xX][0-9a-fA-F_]+$|^0o?[0-7_]+$|^[-+]?\\.(inf|Inf|INF|nan|NaN|NAN)$", options: .regularExpression) != nil {
            return true
        }
        if s.range(of: "^\\d{4}-\\d{1,2}-\\d{1,2}", options: .regularExpression) != nil { return true }
        if s.range(of: "^[-+]?\\d+(:[0-5]?\\d)+(\\.\\d*)?$", options: .regularExpression) != nil { return true }
        return false
    }

    static func scalar(_ s: String, flow: Bool = false, forceSingleLine: Bool = false) -> String {
        needsQuotes(s, flow: flow) || (forceSingleLine && s.contains("\n")) ? doubleQuoted(s) : s
    }

    static func doubleQuoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\u{FEFF}" {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Block scalars

    static func split(_ s: String) -> (body: [String], trailingNewlines: Int) {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var trailing = 0
        while t.hasSuffix("\n") {
            t.removeLast()
            trailing += 1
        }
        return (t.components(separatedBy: "\n"), trailing)
    }

    static func blockHeader(_ s: String) -> String {
        let (body, trailing) = split(s)
        var header = "|"
        // An indentation indicator is needed when the first line would
        // otherwise set the wrong indentation: it starts with a space, or
        // it is blank (the reader would look past it).
        if let first = body.first, first.hasPrefix(" ") || first.allSatisfy({ $0 == " " || $0 == "\t" }) {
            header += "2"
        }
        switch trailing {
        case 0: header += "-"
        case 1: break
        default: header += "+"
        }
        return header
    }

    static func blockLines(_ s: String, indent: Int) -> [String] {
        let (body, trailing) = split(s)
        let pad = spaces(indent)
        var lines = body.map { $0.isEmpty ? "" : pad + $0 }
        if trailing > 1 {
            lines.append(contentsOf: Array(repeating: "", count: trailing - 1))
        }
        return lines
    }
}
