import Foundation
import Testing
@testable import XlessASC

/// The `gzip` binary's output for `data` (nil when there is no gzip on this machine).
func gzipped(_ data: Data, level: Int = 6, name: Bool = false) throws -> Data? {
    let gzip = ["/usr/bin/gzip", "/bin/gzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let gzip else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-gzip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("report.txt")
    try data.write(to: file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gzip)
    process.arguments = ["-\(level)"] + (name ? [] : ["-n"]) + [file.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return try Data(contentsOf: dir.appendingPathComponent("report.txt.gz"))
}

/// Decodes `data` fed `chunk` bytes at a time.
func gunzip(_ data: Data, chunk: Int = 4096) throws -> Data {
    var out = Data()
    var decoder = GzipDecoder { out.append($0) }
    var i = 0
    while i < data.count {
        try decoder.write(data.subdata(in: i..<min(i + chunk, data.count)))
        i += chunk
    }
    try decoder.finish()
    #expect(decoder.bytesOut == out.count)
    return out
}

/// A gzip member built by hand, its deflate data in stored blocks (no compression), with optional header fields.
func storedGzip(_ payload: Data, name: String? = nil, comment: String? = nil, extra: Data? = nil, headerCRC: Bool = false,
                blockSize: Int = 65535, crc: UInt32? = nil) -> Data {
    var flags: UInt8 = 0
    if headerCRC { flags |= 0x02 }
    if extra != nil { flags |= 0x04 }
    if name != nil { flags |= 0x08 }
    if comment != nil { flags |= 0x10 }
    var out = Data([0x1F, 0x8B, 8, flags, 0, 0, 0, 0, 0, 3])
    func le16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func le32(_ v: UInt32) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    if let extra { le16(extra.count); out += extra }
    if let name { out += Data(name.utf8) + [0] }
    if let comment { out += Data(comment.utf8) + [0] }
    if headerCRC { le16(0) }
    var offset = 0
    repeat {
        let size = min(blockSize, payload.count - offset)
        let final = offset + size >= payload.count
        out.append(final ? 1 : 0)
        le16(size); le16(~size & 0xFFFF)
        out += payload.subdata(in: offset..<offset + size)
        offset += size
    } while offset < payload.count
    le32(crc ?? CRC32.checksum(payload)); le32(UInt32(truncatingIfNeeded: payload.count))
    return out
}

/// Report-like text: repetitive (long matches, dynamic blocks) with varying numbers.
func reportText(lines: Int) -> Data {
    var text = "Provider\tProvider Country\tSKU\tDeveloper\tTitle\tVersion\tProduct Type Identifier\tUnits\n"
    var seed: UInt64 = 42
    for i in 0..<lines {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        text += "APPLE\tUS\tcom.example.app\tExample Ltd\tExample \(i % 7)\t1.\(seed % 9)\t1F\t\(seed >> 40 % 1000)\n"
    }
    return Data(text.utf8)
}

@Test func crc32MatchesTheKnownCheckValue() {
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    #expect(CRC32.checksum(Data()) == 0)
}

@Test func storedBlocksWithEveryHeaderFieldDecode() throws {
    let payload = reportText(lines: 200)
    let gz = storedGzip(payload, name: "S_D_123.txt", comment: "hello", extra: Data([1, 2, 3, 4]), headerCRC: true, blockSize: 1000)
    #expect(try gunzip(gz) == payload)
    #expect(try gunzip(gz, chunk: 1) == payload)
}

@Test func anEmptyMemberDecodesToNothing() throws {
    #expect(try gunzip(storedGzip(Data())) == Data())
}

@Test func membersOneAfterAnotherDecodeAsOneStream() throws {
    let a = Data("first\n".utf8), b = Data("second\n".utf8)
    #expect(try gunzip(storedGzip(a) + storedGzip(b), chunk: 3) == a + b)
}

@Test func fixedHuffmanBlocksDecode() throws {
    // zlib with Z_FIXED on "hello hello hello hello\n": one fixed-Huffman block with a back-reference.
    let gz = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xC8, 0x40,
                   0x27, 0xB9, 0x00, 0x00, 0x88, 0x59, 0x0B, 0x18, 0x00, 0x00, 0x00])
    #expect(try gunzip(gz) == Data("hello hello hello hello\n".utf8))
    #expect(try gunzip(gz, chunk: 1) == Data("hello hello hello hello\n".utf8))
}

@Test func whatGzipMakesDecodesWhateverTheChunkSize() throws {
    let payload = reportText(lines: 3000)
    for level in [1, 6, 9] {
        guard let gz = try gzipped(payload, level: level, name: true) else { return }
        #expect(gz.count < payload.count / 3)
        for chunk in [1, 7, 4096, gz.count] where chunk > 1 || level == 6 {
            #expect(try gunzip(gz, chunk: chunk) == payload)
        }
    }
}

@Test func aLargeReportIsHandedOutInPiecesNotAllAtOnce() throws {
    let payload = reportText(lines: 40000) // ~2.5 MB
    guard let gz = try gzipped(payload, level: 9) else { return }
    var largest = 0, total = Data()
    var decoder = GzipDecoder { largest = max(largest, $0.count); total.append($0) }
    try decoder.write(gz) // in one piece: still handed out in bounded pieces
    try decoder.finish()
    #expect(total == payload)
    #expect(largest <= GzipDecoder.flushThreshold + 258)
}

@Test func aCorruptChecksumIsRefused() throws {
    let gz = storedGzip(Data("abc".utf8), crc: 0x1234_5678)
    #expect(throws: GzipError("the gzip data is corrupt (CRC-32 mismatch)")) { try gunzip(gz) }
}

@Test func truncatedDataIsRefusedAtTheEnd() throws {
    let payload = reportText(lines: 500)
    let gz = try gzipped(payload) ?? storedGzip(payload)
    for cut in [1, 5, 12, gz.count / 2, gz.count - 1] {
        #expect(throws: GzipError.self) { try gunzip(gz.prefix(cut)) }
    }
    #expect(throws: GzipError("the gzip data is empty")) { try gunzip(Data()) }
}

@Test func dataThatIsNotGzipIsRefused() throws {
    #expect(throws: GzipError("the data is not gzip")) { try gunzip(Data("Provider\tUnits\n".utf8)) }
    #expect(throws: GzipError("the gzip data has something that is not gzip after its end")) { try gunzip(storedGzip(Data("a".utf8)) + Data("junk".utf8)) }
    #expect(GzipDecoder.isGzip(Data([0x1F, 0x8B, 8])))
    #expect(!GzipDecoder.isGzip(Data([0x1F])))
}

@Test func aBackReferenceBeforeTheStartIsRefused() throws {
    // Fixed block: literal 'a', then length 3 at distance 2 (only one byte written so far), end of block.
    // Bits (LSB first): BFINAL=1, BTYPE=01, 'a'=0x91 (8 bits 10010001), len 257 (0000001), dist 1 (00001), 256 (0000000).
    var bits: [Int] = [1, 1, 0]
    func code(_ value: Int, _ length: Int) { for i in (0..<length).reversed() { bits.append(value >> i & 1) } }
    code(0x30 + 0x61, 8); code(1, 7); code(1, 5); code(0, 7)
    var bytes: [UInt8] = []
    for (i, bit) in bits.enumerated() { if i % 8 == 0 { bytes.append(0) }; bytes[i / 8] |= UInt8(bit) << UInt8(i % 8) }
    let gz = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + bytes + [0, 0, 0, 0, 0, 0, 0, 0])
    #expect(throws: GzipError("the gzip data is corrupt (distance too far back)")) { try gunzip(gz) }
}

@Test func aDynamicHuffmanBlockDecodesWithoutTheGzipBinary() throws {
    // zlib level 9 on report-like lines: one dynamic-Huffman block (BTYPE 2), 2752 bytes decompressed.
    let gz = try #require(Data(base64Encoded: "H4sIAAAAAAACA43VMW7DQAxE0Vo+RU5gLMndJVm6cKoUBoIcwAjcxYjLHD/a4QE0hQAVUwjvQ+Dldvu4bl+f2/fv8/z4uz9fP4/z/fXarvX+1jY578/71k6Xo63sW1nblDxe677WtQ6L47Xta1trH3687vu6r/X0ebwe+3qs9chxvJ77emIt/Xi9/HytuxknGGttQzlBtFEXThB1JBsniDrSkhNEHQ0OEHGyOweIODEnB4g4HoMDRBxvnQNEnKnGASLO6MoBIk6fwgkijkXjBCtOJieIOirBCaKOmHOC9etMDhBx0gcHiDiRnQNEnBDjABHHTTlAxJlDOEDEGd44QMTpkZwg4vQWnCDimDoniDraJyeIOjIHJ1h1OgeIOMbxIU2qcnxWnyEcH9L4bBzfqAOVHF/9Nxkcn9eBcs4v6kBNTrDVgRqcoNSB6pxgnZw0ThB1RJQTRB0TDhBxcjQOcNaBSg6wTk4EBxh1oJwDbHWgJgcodaAGB6h1oDonaHWgjBOsOE05QdRRldM/hmBKHsAKAAA="))
    let text = try gunzip(gz)
    #expect(text.count == 2752)
    #expect(try gunzip(gz, chunk: 1) == text)
    #expect(String(decoding: text.prefix(30), as: UTF8.self).hasPrefix("APPLE\tUS\tcom.example.app\t"))
}

@Test func zeroPaddingAfterTheLastMemberIsAccepted() throws {
    let payload = Data("abc\n".utf8)
    #expect(try gunzip(storedGzip(payload) + Data(repeating: 0, count: 9), chunk: 2) == payload)
    #expect(throws: GzipError.self) { try gunzip(storedGzip(payload) + Data([0, 0, 7])) }
}
