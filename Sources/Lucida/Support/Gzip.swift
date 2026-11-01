import Foundation

/// RFC 1952 gzip. Apple's `.zlib` algorithm produces a raw DEFLATE stream, so the header and
/// CRC32/ISIZE trailer are added here.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let raw = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(raw)
        out.append(le32(crc32(data)))
        out.append(le32(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
}
