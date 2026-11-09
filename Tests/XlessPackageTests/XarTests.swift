import Testing
import Foundation
import Crypto
@testable import XlessPackage
@testable import XlessCore

private func onPath(_ tool: String) -> Bool {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)")
    }
}

private let date = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xar-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func file(_ dir: URL, _ name: String, _ bytes: Data) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
}

private func be32(_ d: Data, _ at: Int) -> UInt32 { d[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
private func be64(_ d: Data, _ at: Int) -> UInt64 { d[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
private func be16(_ d: Data, _ at: Int) -> UInt16 { d[at..<at + 2].reduce(0) { $0 << 8 | UInt16($1) } }

/// The bytes of a zlib stream made of stored (uncompressed) blocks, with its header and Adler-32 checked.
private func unstore(_ z: Data) throws -> Data {
    #expect(z[z.startIndex] == 0x78 && z[z.startIndex + 1] == 0x01)
    var out = Data(), i = z.startIndex + 2
    while true {
        let final = z[i] & 1 == 1
        #expect(z[i] & 0b110 == 0)   // BTYPE 00: stored
        let len = Int(z[i + 1]) | Int(z[i + 2]) << 8, nlen = Int(z[i + 3]) | Int(z[i + 4]) << 8
        #expect(len == (~nlen & 0xFFFF))
        out.append(z[(i + 5)..<(i + 5 + len)])
        i += 5 + len
        if final { break }
    }
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in out { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    #expect(be32(z, i) == (b << 16 | a))
    #expect(z.endIndex == i + 4)
    return out
}

@Test func writesAHeaderTocAndHeapThatAgree() throws {
    // Arrange
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let payload = Data((0..<200_000).map { UInt8($0 % 251) })   // more than one stored block (and one read chunk)
    let nodes: [Xar.Node] = [
        .file(name: "Distribution", source: try file(dir, "d.xml", Data("<installer-gui-script/>".utf8))),
        .directory(name: "a b.pkg", children: [.file(name: "Payload", source: try file(dir, "p", payload)),
                                               .file(name: "Bom", source: try file(dir, "b", Data()))]),
    ]
    let out = dir.appendingPathComponent("out.xar")

    // Act
    try Xar.write(nodes, to: out, modified: date)

    // Assert
    let xar = try Data(contentsOf: out)
    #expect(be32(xar, 0) == 0x7861_7221 && be16(xar, 4) == 28 && be16(xar, 6) == 1 && be32(xar, 24) == 1)   // "xar!", SHA-1
    let compressed = Int(be64(xar, 8)), plain = Int(be64(xar, 16))
    let toc = try unstore(xar[28..<(28 + compressed)])
    #expect(toc.count == plain)
    let heap = xar[(28 + compressed)...]
    #expect(Data(Insecure.SHA1.hash(data: xar[28..<(28 + compressed)])) == heap.prefix(20))   // the TOC checksum opens the heap
    let xml = String(decoding: toc, as: UTF8.self)
    #expect(xml.contains("<creation-time>2023-11-14T22:13:20Z</creation-time>"))
    #expect(xml.contains(#"<checksum style="sha1"><offset>0</offset><size>20</size></checksum>"#))
    // Ids follow the logical order and the heap holds the files in it, after the checksum; libxar lists the top
    // level in reverse XML order, so the XML has it reversed.
    let names = xml.matches(of: /<name>([^<]*)<\/name>/).map { String($0.1) }
    #expect(names == ["a b.pkg", "Payload", "Bom", "Distribution"])
    #expect(xml.contains(#"<file id="3"><name>Payload</name>"#) && xml.contains("<type>directory</type>"))
    let payloadOffset = 20 + "<installer-gui-script/>".utf8.count
    #expect(xml.contains("<offset>\(payloadOffset)</offset>") && xml.contains("<length>200000</length>"))
    #expect(heap.dropFirst(payloadOffset).prefix(payload.count) == payload)
    let sha = Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    #expect(xml.contains(#"<archived-checksum style="sha1">\#(sha)</archived-checksum>"#))
    #expect(xml.contains(#"<extracted-checksum style="sha1">\#(sha)</extracted-checksum>"#))
    #expect(xml.contains(#"<encoding style="application/octet-stream"/>"#))
}

@Test func isByteIdenticalWhenRunTwice() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let nodes: [Xar.Node] = [.file(name: "Distribution", source: try file(dir, "d", Data("x".utf8)))]
    try Xar.write(nodes, to: dir.appendingPathComponent("1.xar"), modified: date)
    try Xar.write(nodes, to: dir.appendingPathComponent("2.xar"), modified: date)
    #expect(try Data(contentsOf: dir.appendingPathComponent("1.xar")) == Data(contentsOf: dir.appendingPathComponent("2.xar")))
}

@Test func escapesNamesInTheToc() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("o.xar")
    try Xar.write([.file(name: "a&b<c>.txt", source: try file(dir, "f", Data("x".utf8)))], to: out, modified: date)
    let xar = try Data(contentsOf: out)
    let xml = String(decoding: try unstore(xar[28..<(28 + Int(be64(xar, 8)))]), as: UTF8.self)
    #expect(xml.contains("<name>a&amp;b&lt;c&gt;.txt</name>"))
}

/// Runs where Apple's xar exists (a Mac, or an image that has it): the real tool lists and extracts what we wrote.
@Test(.enabled(if: onPath("xar")))
func appleXarListsAndExtractsTheArchive() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let payload = Data((0..<70_000).map { UInt8($0 % 13) })
    let out = dir.appendingPathComponent("out.xar")
    try Xar.write([
        .file(name: "Distribution", source: try file(dir, "d", Data("dist".utf8))),
        .directory(name: "x.pkg", children: [.file(name: "Payload", source: try file(dir, "p", payload))]),
    ], to: out, modified: date)
    let listing = try Shell.run("xar", ["-tf", out.path], stage: .package).stdout.split(separator: "\n").map(String.init)
    #expect(listing == ["Distribution", "x.pkg", "x.pkg/Payload"])
    let expand = dir.appendingPathComponent("expand")
    try FileManager.default.createDirectory(at: expand, withIntermediateDirectories: true)
    try Shell.run("xar", ["-x", "-f", out.path], cwd: expand, stage: .package)   // verifies the checksums too
    #expect(try Data(contentsOf: expand.appendingPathComponent("x.pkg/Payload")) == payload)
    #expect(try String(contentsOf: expand.appendingPathComponent("Distribution"), encoding: .utf8) == "dist")
}
