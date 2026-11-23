import Foundation

/// A screenshot's size and format, read from its header (PNG IHDR, JPEG SOFn): no image library, no Apple tool.
public struct ImageInfo: Sendable, Equatable {
    public enum Format: String, Sendable { case png, jpeg }

    public var width: Int
    public var height: Int
    public var format: Format
    /// PNG with an alpha channel (colour type 4 or 6) or a transparency chunk (tRNS): App Store Connect refuses both.
    public var hasAlpha: Bool

    public init(width: Int, height: Int, format: Format, hasAlpha: Bool = false) {
        self.width = width; self.height = height; self.format = format; self.hasAlpha = hasAlpha
    }

    /// The header of a PNG or JPEG file; nil for anything else or a truncated header.
    public static func read(_ data: Data) -> ImageInfo? {
        let bytes = [UInt8](data.prefix(1 << 20))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return png(bytes) }
        if bytes.starts(with: [0xFF, 0xD8]) { return jpeg(bytes) }
        return nil
    }

    /// Reads at most the first megabyte of `url` (headers sit at the start; a JPEG's SOF follows its EXIF block).
    public static func read(contentsOf url: URL) -> ImageInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return read((try? handle.read(upToCount: 1 << 20)) ?? Data())
    }

    static func be32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
    static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }

    static func png(_ b: [UInt8]) -> ImageInfo? {
        // Signature (8), IHDR length (4), "IHDR" (4), width (4), height (4), bit depth (1), colour type (1).
        guard b.count >= 26, Array(b[12..<16]) == Array("IHDR".utf8) else { return nil }
        let colorType = b[25]
        var alpha = colorType == 4 || colorType == 6
        // Chunks after IHDR, up to IDAT: a tRNS chunk makes a colour transparent.
        var i = 8
        while !alpha, i + 8 <= b.count {
            let length = be32(b, i)
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if type == "tRNS" { alpha = true }
            if type == "IDAT" || type == "IEND" || length < 0 { break }
            i += 12 + length
        }
        return ImageInfo(width: be32(b, 16), height: be32(b, 20), format: .png, hasAlpha: alpha)
    }

    static func jpeg(_ b: [UInt8]) -> ImageInfo? {
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }               // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }   // end of image / start of scan before any SOF
            let length = be16(b, i + 2)
            // SOF0…SOF15 except DHT (C4), JPG (C8) and DAC (CC).
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard i + 9 <= b.count else { return nil }
                return ImageInfo(width: be16(b, i + 7), height: be16(b, i + 5), format: .jpeg)
            }
            guard length >= 2 else { return nil }
            i += 2 + length
        }
        return nil
    }
}
