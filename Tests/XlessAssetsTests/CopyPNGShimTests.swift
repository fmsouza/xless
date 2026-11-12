import Crypto
import Foundation
import PNG
import Testing
@testable import XlessAssets

/// A non-interlaced PNG from raw rows (filter 0), with optional extra chunks before IDAT.
private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

private func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
    let t: [UInt8] = Array(type.utf8)
    let crc: UInt32 = CRC32.checksum(t + body)
    return be32(UInt32(body.count)) + t + body + be32(crc)
}

/// A zlib stream of stored (uncompressed) deflate blocks.
private func zlibStored(_ raw: [UInt8]) -> [UInt8] {
    var a: UInt32 = 1, b: UInt32 = 0
    for x in raw { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
    var z: [UInt8] = [0x78, 0x01]
    var i = 0
    repeat {
        let n = min(65535, raw.count - i)
        let last: UInt8 = i + n >= raw.count ? 1 : 0
        let len = UInt16(n), nlen = ~UInt16(n)
        z += [last, UInt8(len & 0xff), UInt8(len >> 8), UInt8(nlen & 0xff), UInt8(nlen >> 8)]
        z += raw[i..<(i + n)]
        i += n
    } while i < raw.count
    return z + be32((b << 16) | a)
}

private func png(width: Int, height: Int, colorType: UInt8, depth: UInt8 = 8, rows: [[UInt8]], extra: [(String, [UInt8])] = []) -> Data {
    var raw: [UInt8] = []
    for r in rows { raw.append(0); raw += r }
    var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    out += chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [depth, colorType, 0, 0, 0])
    for (t, body) in extra { out += chunk(t, body) }
    out += chunk("IDAT", zlibStored(raw))
    out += chunk("IEND", [])
    return Data(out)
}

private func chunkTypes(_ d: Data) -> [String] {
    let b = [UInt8](d); var i = 8, out: [String] = []
    while i + 8 <= b.count {
        let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        let t = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
        out.append(t == "CgBI" || t == "IHDR" ? t + "=" + b[(i + 8)..<(i + 8 + n)].map { String(format: "%02x", $0) }.joined() : t)
        i += 12 + n
    }
    return out
}

private func decode(_ d: Data) throws -> [PNG.RGBA<UInt8>] {
    var s = CopyPNGShim.Bytes(bytes: [UInt8](d))
    return try PNG.Image.decompress(stream: &s).unpack(as: PNG.RGBA<UInt8>.self)
}

/// Row y, column x of a 4x4 probe: (10x+y, 20y, 200, 60x). Expected values: Xcode 27.0's copypng output for the same
/// image, decoded (premultiplied with rounding, `(c·a + 127) / 255`).
private let rgbaRows: [[UInt8]] = (0..<4).map { (y: Int) -> [UInt8] in
    var row: [UInt8] = []
    for x in 0..<4 { row += [UInt8(10 * x + y), UInt8(20 * y), 200, UInt8(60 * x)] }
    return row
}

@Test func copypngWritesIPhoneOptimizedRGBA() throws {
    let input = png(width: 4, height: 4, colorType: 6, rows: rgbaRows, extra: [("tEXt", Array("Comment\0hi".utf8))])
    let r = try CopyPNGShim.convert(input, compress: true, stripText: true, argv: [])
    #expect(r.stderr.isEmpty)
    #expect(chunkTypes(r.output) == ["CgBI=50002002", "IHDR=00000004000000040806000000", "IDAT", "IEND"])
    let px = try decode(r.output)
    #expect(px.count == 16)
    // Spot values measured from Xcode's output: (11, 20, 200, 60) → (3, 5, 47, 60), (33, 60, 200, 180) → (23, 42, 141, 180).
    #expect(px[1 * 4 + 1] == .init(3, 5, 47, 60))
    #expect(px[3 * 4 + 3] == .init(23, 42, 141, 180))
    #expect(px[0] == .init(0, 0, 0, 0))
    // -strip-PNG-text alone gives the same file as both options.
    #expect(try CopyPNGShim.convert(input, compress: false, stripText: true, argv: []).output == r.output)
}

@Test func copypngTurnsRGBIntoOpaqueRGBA() throws {
    let rows: [[UInt8]] = [[0, 0, 200, 10, 0, 200], [1, 20, 200, 11, 20, 200]]
    let r = try CopyPNGShim.convert(png(width: 2, height: 2, colorType: 2, rows: rows), compress: true, stripText: true, argv: [])
    #expect(chunkTypes(r.output) == ["CgBI=50002006", "IHDR=00000002000000020806000000", "IDAT", "IEND"])
    #expect(try decode(r.output) == [.init(0, 0, 200, 255), .init(10, 0, 200, 255), .init(1, 20, 200, 255), .init(11, 20, 200, 255)])
}

@Test func copypngCopiesWithoutOptionsAndSixteenBitImages() throws {
    let rgba = png(width: 4, height: 4, colorType: 6, rows: rgbaRows)
    #expect(try CopyPNGShim.convert(rgba, compress: false, stripText: false, argv: []) == .init(output: rgba, stderr: ""))
    let wide = png(width: 1, height: 1, colorType: 2, depth: 16, rows: [[0, 1, 0, 2, 0, 3]])
    let r = try CopyPNGShim.convert(wide, compress: true, stripText: true, argv: [])
    #expect(r.output == wide && r.stderr.hasPrefix("libpng warning: Warning: Input PNG does not have an 8 bit input depth."))
    let wideText = png(width: 1, height: 1, colorType: 6, depth: 16, rows: [[0, 1, 0, 2, 0, 3, 0, 4]], extra: [("tEXt", Array("a\0b".utf8))])
    #expect(try CopyPNGShim.convert(wideText, compress: true, stripText: true, argv: []).output == wideText)
    // Measured only for RGB/RGBA without other ancillary chunks.
    let wideGray = png(width: 1, height: 1, colorType: 0, depth: 16, rows: [[0, 1]])
    let wideSRGB = png(width: 1, height: 1, colorType: 2, depth: 16, rows: [[0, 1, 0, 2, 0, 3]], extra: [("sRGB", [0])])
    #expect(throws: CopyPNGShim.Unsupported.self) { try CopyPNGShim.convert(wideGray, compress: true, stripText: true, argv: []) }
    #expect(throws: CopyPNGShim.Unsupported.self) { try CopyPNGShim.convert(wideSRGB, compress: true, stripText: true, argv: []) }
}

@Test func copypngRefusesWhatWasNotMeasured() throws {
    let gray = png(width: 1, height: 1, colorType: 0, rows: [[7]])
    let srgb = png(width: 1, height: 1, colorType: 2, rows: [[1, 2, 3]], extra: [("sRGB", [0])])
    let text = png(width: 1, height: 1, colorType: 2, rows: [[1, 2, 3]], extra: [("tEXt", Array("a\0b".utf8))])
    #expect(throws: CopyPNGShim.Unsupported.self) { try CopyPNGShim.convert(gray, compress: true, stripText: true, argv: []) }
    #expect(throws: CopyPNGShim.Unsupported.self) { try CopyPNGShim.convert(srgb, compress: true, stripText: true, argv: []) }
    #expect(throws: CopyPNGShim.Unsupported.self) { try CopyPNGShim.convert(text, compress: true, stripText: false, argv: []) }
    #expect(throws: CopyPNGShim.Unsupported.self) { try CopyPNGShim.parse(["-iphone", "a.png", "b.png"]) }
    #expect(throws: CopyPNGShim.Unsupported.self) { try CopyPNGShim.parse(["-compress", "a.png"]) }
    let p = try CopyPNGShim.parse(["-compress", "-strip-PNG-text", "/a.png", "/b.png"])
    #expect(p.compress && p.stripText && p.input == "/a.png" && p.output == "/b.png")
}

// MARK: - Against Xcode's copypng (Fixtures/copypng/<build>.json, scripts/copypng-golden.sh)

/// The PNG cases `scripts/copypng-golden.sh` runs Xcode's copypng on, built the same way.
private let goldenCases: [String: Data] = [
    "rgba-4x4-text": png(width: 4, height: 4, colorType: 6, rows: rgbaRows, extra: [("tEXt", Array("Comment\0hi".utf8))]),
    "rgba-4x4": png(width: 4, height: 4, colorType: 6, rows: rgbaRows),
    "rgb-2x2": png(width: 2, height: 2, colorType: 2, rows: [[0, 0, 200, 10, 0, 200], [1, 20, 200, 11, 20, 200]]),
    "rgb16-1x1": png(width: 1, height: 1, colorType: 2, depth: 16, rows: [[0, 1, 0, 2, 0, 3]]),
    "rgba16-1x1-text": png(width: 1, height: 1, colorType: 6, depth: 16, rows: [[0, 1, 0, 2, 0, 3, 0, 4]], extra: [("tEXt", Array("a\0b".utf8))]),
    "gray16-1x1": png(width: 1, height: 1, colorType: 0, depth: 16, rows: [[0, 1]]),
    "rgb16-1x1-srgb": png(width: 1, height: 1, colorType: 2, depth: 16, rows: [[0, 1, 0, 2, 0, 3]], extra: [("sRGB", [0])]),
    "gray-1x1": png(width: 1, height: 1, colorType: 0, rows: [[7]]),
    "rgb-1x1-srgb": png(width: 1, height: 1, colorType: 2, rows: [[1, 2, 3]], extra: [("sRGB", [0])]),
    "rgb-1x1-text": png(width: 1, height: 1, colorType: 2, rows: [[1, 2, 3]], extra: [("tEXt", Array("a\0b".utf8))]),
]

private let goldenOptions: [String: (compress: Bool, strip: Bool)] = [
    "compress-strip": (true, true), "compress": (true, false), "strip": (false, true), "none": (false, false),
]

/// Calls the shim refuses (exit 70) although Xcode's copypng handles them: it rewrites them in ways not reproduced
/// (gray without CgBI, gAMA/sRGB/cHRM added) or keeps chunks the shim has not measured with every option.
private let refusedGoldenCalls: Set<String> = [
    "gray-1x1/compress-strip", "gray-1x1/compress", "gray-1x1/strip",
    "rgb-1x1-srgb/compress-strip", "rgb-1x1-srgb/compress", "rgb-1x1-srgb/strip",
    "gray16-1x1/compress-strip", "gray16-1x1/compress", "gray16-1x1/strip",
    "rgb16-1x1-srgb/compress-strip", "rgb16-1x1-srgb/compress", "rgb16-1x1-srgb/strip",
    "rgba-4x4-text/compress", "rgb-1x1-text/compress",
]

private struct CopyPNGGolden: Decodable {
    struct Entry: Decodable {
        struct IHDR: Decodable, Equatable { var width, height, bitDepth, colorType, compression, filter, interlace: Int }
        var exit: Int32
        var stderr: String
        var identicalToInput: Bool?
        var ihdr: IHDR?
        var chunkOrder: [String]?
        var cgbi: String?
        var pixelsSha256: String?
    }
    var xcodeBuild: String
    var cases: [String: [String: Entry]]
}

private func chunkList(_ d: Data) -> [(type: String, data: [UInt8])] {
    let b = [UInt8](d); var i = 8, out: [(String, [UInt8])] = []
    while i + 12 <= b.count {
        let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        out.append((String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self), Array(b[(i + 8)..<(i + 8 + n)])))
        i += 12 + n
    }
    return out
}

/// copypng behaves the same in every measured Xcode (docs/research/xcode-tools-by-version.md, "copypng"), so the shim has
/// no profile field; it is still checked against each build's recording: every call it accepts gives Xcode's chunk
/// order, IHDR, CgBI bytes, stderr and pixels (scanlines as stored); every call it refuses is one listed above.
@Test(arguments: ["17A400", "17B55", "17C52", "27A266a", "27A9275", "27B52"])
func copypngMatchesXcodesCopypng(_ build: String) throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/copypng/\(build).json")
    let golden = try JSONDecoder().decode(CopyPNGGolden.self, from: Data(contentsOf: url))
    #expect(golden.xcodeBuild == build)
    #expect(Set(golden.cases.keys) == Set(goldenCases.keys))
    var refused = Set<String>()
    for (name, input) in goldenCases.sorted(by: { $0.key < $1.key }) {
        for (option, flags) in goldenOptions.sorted(by: { $0.key < $1.key }) {
            let call = "\(name)/\(option)"
            let want = try #require(golden.cases[name]?[option], "\(call) not recorded")
            #expect(want.exit == 0, "\(call)")
            let r: CopyPNGShim.Result
            do { r = try CopyPNGShim.convert(input, compress: flags.compress, stripText: flags.strip, argv: []) } catch is CopyPNGShim.Unsupported {
                refused.insert(call); continue
            }
            #expect(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == want.stderr, "\(call)")
            #expect((r.output == input) == want.identicalToInput, "\(call)")
            let chunks = chunkList(r.output)
            #expect(chunks.map(\.type) == want.chunkOrder, "\(call)")
            #expect(chunks.first { $0.type == "CgBI" }.map { $0.data.map { String(format: "%02x", $0) }.joined() } == want.cgbi, "\(call)")
            if let h = chunks.first(where: { $0.type == "IHDR" })?.data {
                func be(_ o: Int) -> Int { Int(h[o]) << 24 | Int(h[o + 1]) << 16 | Int(h[o + 2]) << 8 | Int(h[o + 3]) }
                let got = CopyPNGGolden.Entry.IHDR(width: be(0), height: be(4), bitDepth: Int(h[8]), colorType: Int(h[9]),
                                                   compression: Int(h[10]), filter: Int(h[11]), interlace: Int(h[12]))
                #expect(got == want.ihdr, "\(call)")
            }
            var source = CopyPNGShim.Bytes(bytes: [UInt8](r.output))
            let image = try PNG.Image.decompress(stream: &source)
            #expect(SHA256.hash(data: image.storage).map { String(format: "%02x", $0) }.joined() == want.pixelsSha256, "\(call)")
        }
    }
    #expect(refused == refusedGoldenCalls)
}
