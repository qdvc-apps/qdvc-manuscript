import Foundation

/// Reads ZIP archives (a .docx is one): stored and deflated entries, found
/// through the central directory. No ZIP64, no encryption: Word files need
/// neither.
public struct ZipReader {
    public struct Entry {
        public var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
    }

    public enum ZipError: Error, LocalizedError {
        case notAZip
        case unsupported(String)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip: return "The file isn't a ZIP archive (or a Word document)."
            case .unsupported(let what): return "Unsupported ZIP feature: \(what)."
            case .corrupt(let what): return "The archive is damaged (\(what))."
            }
        }
    }

    let bytes: [UInt8]
    public private(set) var entries: [Entry] = []

    public init(data: Data) throws {
        bytes = [UInt8](data)
        try readDirectory()
    }

    func u16(_ at: Int) -> Int {
        guard at + 1 < bytes.count else { return 0 }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    func u32(_ at: Int) -> Int {
        guard at + 3 < bytes.count else { return 0 }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }

    mutating func readDirectory() throws {
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        // The end-of-central-directory record, within the last 64 KB.
        var eocd = -1
        var p = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while p >= stop {
            if bytes[p] == 0x50, bytes[p + 1] == 0x4B, bytes[p + 2] == 0x05, bytes[p + 3] == 0x06 {
                eocd = p
                break
            }
            p -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4B50 else {
                throw ZipError.corrupt("central directory")
            }
            let method = UInt16(u16(offset + 10))
            let compressed = u32(offset + 20)
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else { throw ZipError.corrupt("entry name") }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size,
                                 localHeaderOffset: local))
            offset = nameStart + nameLength + extraLength + commentLength
        }
    }

    public func entry(_ name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The uncompressed contents of an entry.
    public func data(_ name: String) throws -> Data? {
        guard let e = entry(name) else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= bytes.count, u32(h) == 0x0403_4B50 else { throw ZipError.corrupt(name) }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        guard start + e.compressedSize <= bytes.count else { throw ZipError.corrupt(name) }
        let raw = Array(bytes[start..<(start + e.compressedSize)])
        switch e.method {
        case 0: return Data(raw)
        case 8: return Data(try Inflate.inflate(raw, expectedSize: e.size))
        default: throw ZipError.unsupported("compression method \(e.method)")
        }
    }

    public func text(_ name: String) throws -> String? {
        guard let d = try data(name) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

/// DEFLATE (RFC 1951) decompression, after Mark Adler's puff.c: small and
/// plain rather than fast, which is plenty for a Word document.
public enum Inflate {
    public enum InflateError: Error {
        case truncated
        case badBlockType
        case badStoredLength
        case badCode
        case badDistance
        case badLengths
    }

    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) throws {
            for l in lengths {
                guard l >= 0 && l < 16 else { throw InflateError.badLengths }
                counts[l] += 1
            }
            // Offsets of each length's first symbol in `symbols`.
            var off = [Int](repeating: 0, count: 16)
            for len in 1..<15 { off[len + 1] = off[len] + counts[len] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, l) in lengths.enumerated() where l != 0 {
                symbols[off[l]] = symbol
                off[l] += 1
            }
        }
    }

    struct State {
        let input: [UInt8]
        var pos = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []

        mutating func bits(_ need: Int) throws -> Int {
            var val = bitBuffer
            while bitCount < need {
                guard pos < input.count else { throw InflateError.truncated }
                val |= Int(input[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            bitBuffer = val >> need
            bitCount -= need
            return val & ((1 << need) - 1)
        }

        mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.counts[len]
                if code - count < first { return h.symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw InflateError.badCode
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
                             131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                           2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    public static func inflate(_ input: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        var s = State(input: input)
        s.output.reserveCapacity(max(expectedSize, input.count * 3))
        var last = 0
        repeat {
            last = try s.bits(1)
            let type = try s.bits(2)
            switch type {
            case 0: try stored(&s)
            case 1: try codes(&s, try fixedLengths(), try fixedDistances())
            case 2:
                let (l, d) = try dynamic(&s)
                try codes(&s, l, d)
            default: throw InflateError.badBlockType
            }
        } while last == 0
        return s.output
    }

    static func stored(_ s: inout State) throws {
        s.bitBuffer = 0
        s.bitCount = 0
        guard s.pos + 4 <= s.input.count else { throw InflateError.truncated }
        let len = Int(s.input[s.pos]) | Int(s.input[s.pos + 1]) << 8
        let nlen = Int(s.input[s.pos + 2]) | Int(s.input[s.pos + 3]) << 8
        s.pos += 4
        guard len == (~nlen & 0xFFFF) else { throw InflateError.badStoredLength }
        guard s.pos + len <= s.input.count else { throw InflateError.truncated }
        s.output.append(contentsOf: s.input[s.pos..<(s.pos + len)])
        s.pos += len
    }

    static func fixedLengths() throws -> Huffman {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return try Huffman(lengths: lengths)
    }

    static func fixedDistances() throws -> Huffman {
        try Huffman(lengths: [Int](repeating: 5, count: 30))
    }

    static func dynamic(_ s: inout State) throws -> (Huffman, Huffman) {
        let nlen = try s.bits(5) + 257
        let ndist = try s.bits(5) + 1
        let ncode = try s.bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw InflateError.badLengths }
        var codeLengths = [Int](repeating: 0, count: 19)
        for k in 0..<ncode { codeLengths[order[k]] = try s.bits(3) }
        let lencode = try Huffman(lengths: codeLengths)
        var lengths = [Int](repeating: 0, count: nlen + ndist)
        var index = 0
        while index < nlen + ndist {
            var symbol = try s.decode(lencode)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
            } else {
                var len = 0
                if symbol == 16 {
                    guard index > 0 else { throw InflateError.badLengths }
                    len = lengths[index - 1]
                    symbol = 3 + (try s.bits(2))
                } else if symbol == 17 {
                    symbol = 3 + (try s.bits(3))
                } else {
                    symbol = 11 + (try s.bits(7))
                }
                guard index + symbol <= nlen + ndist else { throw InflateError.badLengths }
                for _ in 0..<symbol {
                    lengths[index] = len
                    index += 1
                }
            }
        }
        guard lengths[256] != 0 else { throw InflateError.badLengths }
        return (try Huffman(lengths: Array(lengths[0..<nlen])), try Huffman(lengths: Array(lengths[nlen...])))
    }

    static func codes(_ s: inout State, _ lencode: Huffman, _ distcode: Huffman) throws {
        while true {
            var symbol = try s.decode(lencode)
            if symbol < 256 {
                s.output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw InflateError.badCode }
                let len = lengthBase[symbol] + (try s.bits(lengthExtra[symbol]))
                let dsym = try s.decode(distcode)
                guard dsym < 30 else { throw InflateError.badDistance }
                let dist = distBase[dsym] + (try s.bits(distExtra[dsym]))
                guard dist <= s.output.count else { throw InflateError.badDistance }
                let start = s.output.count - dist
                for k in 0..<len { s.output.append(s.output[start + k]) }
            }
        }
    }
}
