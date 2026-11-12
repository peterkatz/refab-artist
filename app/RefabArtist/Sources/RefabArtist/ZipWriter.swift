import Foundation

/// A minimal RFC 1950 / PKZIP-compatible ZIP writer used by the EPS
/// per-sheet export (NEO-109). Does not compress entries (STORED method,
/// deflate = 0) — EPS is already ASCII text and the goal is multi-file
/// packaging, not size reduction.
enum ZipWriter {
    struct Entry {
        var name: String
        var data: Data
    }

    static func write(entries: [Entry], to url: URL) throws {
        var output = Data()
        var records: [(nameData: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc32value = crc32(of: entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            output.appendLE(UInt32(0x04034b50)) // local file header signature
            output.appendLE(UInt16(20))          // version needed: 2.0
            output.appendLE(UInt16(0))           // general purpose bit flag
            output.appendLE(UInt16(0))           // compression method: STORED
            output.appendLE(UInt16(0))           // last mod file time
            output.appendLE(UInt16(0))           // last mod file date
            output.appendLE(crc32value)          // crc-32
            output.appendLE(size)                // compressed size
            output.appendLE(size)                // uncompressed size
            output.appendLE(UInt16(nameData.count)) // file name length
            output.appendLE(UInt16(0))           // extra field length
            output.append(nameData)
            output.append(entry.data)

            records.append((nameData: nameData, crc: crc32value, size: size, offset: offset))
        }

        let cdOffset = UInt32(output.count)
        for record in records {
            output.appendLE(UInt32(0x02014b50)) // central directory signature
            output.appendLE(UInt16(20))          // version made by
            output.appendLE(UInt16(20))          // version needed
            output.appendLE(UInt16(0))           // general purpose bit flag
            output.appendLE(UInt16(0))           // compression method: STORED
            output.appendLE(UInt16(0))           // last mod file time
            output.appendLE(UInt16(0))           // last mod file date
            output.appendLE(record.crc)
            output.appendLE(record.size)
            output.appendLE(record.size)
            output.appendLE(UInt16(record.nameData.count))
            output.appendLE(UInt16(0))           // extra field length
            output.appendLE(UInt16(0))           // file comment length
            output.appendLE(UInt16(0))           // disk number start
            output.appendLE(UInt16(0))           // internal file attributes
            output.appendLE(UInt32(0))           // external file attributes
            output.appendLE(record.offset)       // relative offset of local header
            output.append(record.nameData)
        }
        let cdSize = UInt32(output.count) - cdOffset

        // End of central directory record
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))               // disk number
        output.appendLE(UInt16(0))               // disk with start of CD
        output.appendLE(UInt16(records.count))
        output.appendLE(UInt16(records.count))
        output.appendLE(cdSize)
        output.appendLE(cdOffset)
        output.appendLE(UInt16(0))               // comment length

        try output.write(to: url, options: .atomic)
    }

    // MARK: - CRC-32 (PKZIP polynomial 0xEDB88320)

    private static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}

// MARK: - Data extensions for little-endian append

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
