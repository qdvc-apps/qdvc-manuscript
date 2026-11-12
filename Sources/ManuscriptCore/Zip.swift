import Foundation

/// Writes a ZIP archive with uncompressed ("stored") entries, which is all
/// a .docx needs. Word, Pages, LibreOffice and Google Docs all read them.
public struct ZipWriter {
    private struct Entry {
        var name: Data
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private var entries: [Entry] = []
    private var output = Data()
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, min(c.year ?? 1980, 2107)) - 1980
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let datePart: Int = (year << 9) | (month << 5) | day
        let timePart: Int = (hour << 11) | (minute << 5) | (second / 2)
        dosDate = UInt16(truncatingIfNeeded: datePart)
        dosTime = UInt16(truncatingIfNeeded: timePart)
    }

    public mutating func add(_ name: String, _ data: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let entry = Entry(name: nameData, crc: crc, size: UInt32(data.count), offset: UInt32(output.count))
        output.append(le32: 0x0403_4B50)
        output.append(le16: 20)          // version needed
        output.append(le16: 0x0800)      // flags: UTF-8 names
        output.append(le16: 0)           // stored
        output.append(le16: dosTime)
        output.append(le16: dosDate)
        output.append(le32: crc)
        output.append(le32: entry.size)  // compressed size
        output.append(le32: entry.size)  // uncompressed size
        output.append(le16: UInt16(nameData.count))
        output.append(le16: 0)           // extra length
        output.append(nameData)
        output.append(data)
        entries.append(entry)
    }

    public mutating func add(_ name: String, _ text: String) {
        add(name, Data(text.utf8))
    }

    public func finish() -> Data {
        var out = output
        let directoryOffset = UInt32(out.count)
        for e in entries {
            out.append(le32: 0x0201_4B50)
            out.append(le16: 20)         // version made by
            out.append(le16: 20)         // version needed
            out.append(le16: 0x0800)
            out.append(le16: 0)
            out.append(le16: dosTime)
            out.append(le16: dosDate)
            out.append(le32: e.crc)
            out.append(le32: e.size)
            out.append(le32: e.size)
            out.append(le16: UInt16(e.name.count))
            out.append(le16: 0)          // extra
            out.append(le16: 0)          // comment
            out.append(le16: 0)          // disk number
            out.append(le16: 0)          // internal attributes
            out.append(le32: 0)          // external attributes
            out.append(le32: e.offset)
            out.append(e.name)
        }
        let directorySize = UInt32(out.count) - directoryOffset
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: directorySize)
        out.append(le32: directoryOffset)
        out.append(le16: 0)
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func append(le16 v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func append(le32 v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
}
