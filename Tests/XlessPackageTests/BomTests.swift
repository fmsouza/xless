import Testing
import Foundation
@testable import XlessPackage
@testable import XlessCore

// Fixtures (Tests/XlessPackageTests/Fixtures/, like the other test targets): reference.bom is the
// `mkbom -s` path-only Bom from the deterministic reference tree, reference-full.bom the
// metadata-bearing `mkbom` of the same tree (see Fixtures/README.md). The tree's three files are
// MacOS/LightCraft (17 bytes, "hello-lightcraft\n"), Resources/data.bin (4096 bytes of 0..255 x16)
// and Resources/sub/readme.txt (7 bytes); every mtime is 2026-01-01 00:00 UTC.
private var fixturesDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }

private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixturesDir.appendingPathComponent(name)) }

private func treeFile(_ relative: String) throws -> Data {
    try Data(contentsOf: fixturesDir.appendingPathComponent("reference-tree/Contents").appendingPathComponent(relative))
}

/// 2026-01-01T00:00:00Z, the mtime every reference entry carries.
private let referenceDate = Date(timeIntervalSince1970: 1767225600)

private func referenceDir(_ path: String, _ size: UInt64) -> Bom.Entry {
    Bom.Entry(path: path, kind: .directory, mode: 0o040755, userID: 501, groupID: 0,
              modificationDate: referenceDate, size: size, checksum: 0, linkTarget: nil)
}

private func referenceFile(_ path: String, _ size: UInt64, _ checksum: UInt32) -> Bom.Entry {
    Bom.Entry(path: path, kind: .file, mode: 0o100644, userID: 501, groupID: 0,
              modificationDate: referenceDate, size: size, checksum: checksum, linkTarget: nil)
}

/// Writer entries that reproduce the reference tree: full metadata, preorder in the directory
/// order mkbom scanned it (its readdir listed `sub` before `data.bin`, which the ids show).
private func referenceEntries() -> [Bom.Entry] {
    [
        referenceDir(".", 128),
        referenceDir("./MacOS", 96),
        referenceFile("./MacOS/LightCraft", 17, 2857111842),
        referenceDir("./Resources", 128),
        referenceDir("./Resources/sub", 96),
        referenceFile("./Resources/sub/readme.txt", 7, 3050726777),
        referenceFile("./Resources/data.bin", 4096, 300014538),
    ]
}

@Test func parsePathOnlyReferenceBom() throws {
    let bom = try Bom(fixture("reference.bom"))
    let records = bom.records
    // `mkbom -s` on a directory holding `Contents` plus the output of an earlier run records all
    // nine paths; the leaf is sorted by (parent id, name) so reference.bom lands right after
    // ./Contents, and ./Contents/Resources precedes ./Contents/MacOS/LightCraft.
    #expect(records.map(\.path) == [
        ".", "./Contents", "./reference.bom", "./Contents/MacOS", "./Contents/Resources",
        "./Contents/MacOS/LightCraft", "./Contents/Resources/data.bin", "./Contents/Resources/sub",
        "./Contents/Resources/sub/readme.txt",
    ])
    let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
    // Tree shape: every record links to its directory.
    #expect(byPath["./Contents/MacOS/LightCraft"]?.parentID == byPath["./Contents/MacOS"]?.id)
    #expect(byPath["./Contents/Resources/data.bin"]?.parentID == byPath["./Contents/Resources"]?.id)
    #expect(byPath["./reference.bom"]?.parentID == byPath["."]?.id)
    #expect(records.allSatisfy { $0.parentID != $0.id })
    // Path-only (-s) Boms carry kinds only — no sizes, mtimes or digests.
    #expect(byPath["./Contents/MacOS/LightCraft"]?.kind == .file)
    #expect(byPath["./Contents"]?.kind == .directory)
    #expect(byPath["./Contents/MacOS/LightCraft"]?.size == nil)
    #expect(byPath["./Contents/MacOS/LightCraft"]?.modificationDate == nil)
}

@Test func parseFullReferenceBomFields() throws {
    let bom = try Bom(fixture("reference-full.bom"))
    let records = bom.records
    // Leaf order (parent id, name); ids follow mkbom's preorder scan, which readdir'd `sub`
    // before `data.bin`, so ./Resources/sub/readme.txt sorts before ./Resources/data.bin.
    #expect(records.map(\.path) == [
        ".", "./MacOS", "./Resources", "./MacOS/LightCraft", "./Resources/data.bin",
        "./Resources/sub", "./Resources/sub/readme.txt",
    ])
    let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
    // Sizes byte-exact (directories store their st_size exactly like the files' byte counts).
    #expect(byPath["./MacOS/LightCraft"]?.size == UInt64(try treeFile("MacOS/LightCraft").count))
    #expect(byPath["./Resources/data.bin"]?.size == UInt64(try treeFile("Resources/data.bin").count))
    #expect(byPath["./Resources/sub/readme.txt"]?.size == UInt64(try treeFile("Resources/sub/readme.txt").count))
    #expect(byPath["./MacOS"]?.size == 96 && byPath["."].map { $0.size == 128 } == true)
    // Modes, owner, group, the 2026-01-01 mtime: this macOS mkbom stores Unix-epoch seconds.
    let file = try #require(byPath["./MacOS/LightCraft"])
    #expect(file.mode == 0o100644 && file.userID == 501 && file.groupID == 0)
    #expect(file.modificationDate == referenceDate)
    let dir = try #require(byPath["./MacOS"])
    #expect(dir.mode == 0o040755 && dir.modificationDate == referenceDate && dir.checksum == 0)
    // Digests: mkbom stores the cksum(1) CRC-32, not sha256. The values below are Apple's own
    // lsbom output for the fixture tree, and must equal our cksum of the actual file bytes.
    #expect(byPath["./MacOS/LightCraft"]?.checksum == 2857111842)
    #expect(byPath["./Resources/data.bin"]?.checksum == 300014538)
    #expect(byPath["./Resources/sub/readme.txt"]?.checksum == 3050726777)
    #expect(file.checksum == Bom.cksum(try treeFile("MacOS/LightCraft")))
    #expect(byPath["./Resources/data.bin"]?.checksum == Bom.cksum(try treeFile("Resources/data.bin")))
    #expect(byPath["./Resources/sub/readme.txt"]?.checksum == Bom.cksum(try treeFile("Resources/sub/readme.txt")))
    // The tree file's contents are what the digests say they are.
    let bytes = try treeFile("MacOS/LightCraft")
    #expect(bytes.count == 17 && String(decoding: bytes, as: UTF8.self) == "hello-lightcraft\n")
}

@Test func writerProducesMkbomEquivalentBom() throws {
    // Byte identity was tried first: mkbom leaves scratch-buffer junk in the free gaps between
    // blocks (see Task 2 report), so matching its bytes would mean emulating its allocation
    // history. What the format guarantees is the parsed structure — assert that, and on macOS
    // that Apple's own lsbom accepts our byte stream.
    let bom = try Bom(Bom.data(for: referenceEntries()))
    let reference = try Bom(fixture("reference-full.bom"))
    #expect(bom.records == reference.records)   // paths, tree shape, kinds, sizes, modes, mtimes, digests
    #if os(macOS)
    if FileManager.default.fileExists(atPath: "/usr/bin/lsbom") {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("xless-bom-\(UUID()).bom")
        defer { try? FileManager.default.removeItem(at: out) }
        try Bom.data(for: referenceEntries()).write(to: out)
        let listing = try Shell.run("/usr/bin/lsbom", [out.path], stage: .package).stdout
        #expect(listing.contains("./MacOS/LightCraft\t100644\t501/0\t17\t2857111842"))
        #expect(listing.contains("./Resources/sub\t40755\t501/0"))
        #expect(listing.split(separator: "\n").count == 7)
    }
    #endif
}

@Test func writerRoundTripsMetadata() throws {
    let entries = referenceEntries() + [
        referenceDir("./Links", 96),
        Bom.Entry(path: "./Links/alias", kind: .symlink, mode: 0o120755, userID: 501, groupID: 0,
                  modificationDate: referenceDate, size: 16, checksum: Bom.cksum(Data("MacOS/LightCraft".utf8)),
                  linkTarget: "MacOS/LightCraft"),
    ]
    let byPath = Dictionary(uniqueKeysWithValues: try Bom(Bom.data(for: entries)).records.map { ($0.path, $0) })
    #expect(byPath["./Links"].map { $0.kind == .directory && $0.size == 96 } == true)
    let alias = try #require(byPath["./Links/alias"])
    #expect(alias.kind == .symlink && alias.linkTarget == "MacOS/LightCraft")
    #expect(alias.mode == 0o120755 && alias.size == 16)
    #expect(alias.checksum == Bom.cksum(Data("MacOS/LightCraft".utf8)))
    #expect(alias.modificationDate == referenceDate)
    // Sizes and digests survive writing (writer input carries them; no file bytes needed).
    #expect(byPath["./MacOS/LightCraft"].map { $0.size == 17 && $0.checksum == 2857111842 } == true)
}

@Test func writerSplitsLargeTreesIntoChainedLeaves() throws {
    // > 510 entries forces several 4096-byte leaves chained through forward/back links, with a
    // branch root holding one entry per non-final leaf: the shape mkbom emits for thousands of files.
    var entries = referenceEntries()
    for i in 1...1200 {
        entries.append(referenceFile(String(format: "./Resources/payload%04d.bin", i), UInt64(i), 0))
    }
    let bom = try Bom(try Bom.data(for: entries))
    #expect(bom.records.count == 1207)
    let byPath = Dictionary(uniqueKeysWithValues: bom.records.map { ($0.path, $0) })
    let payload1 = try #require(byPath["./Resources/payload0001.bin"])
    let payload1200 = try #require(byPath["./Resources/payload1200.bin"])
    let resources = try #require(byPath["./Resources"])
    #expect(payload1.parentID == resources.id && payload1200.parentID == resources.id)
    #expect(payload1200.size == 1200)
    // Deterministic: writing the same entries again produces the same records.
    let again = try Bom(try Bom.data(for: entries))
    #expect(again.records == bom.records)
}

@Test func writerRejectsHostileInput() throws {
    do { _ = try Bom.data(for: []); Issue.record("expected throw") } catch {}
    // A child whose parent has not been listed yet.
    do {
        _ = try Bom.data(for: [Bom.Entry(path: ".", kind: .directory, mode: 0o040755, userID: 0,
                                         groupID: 0, modificationDate: referenceDate, size: 0,
                                         checksum: 0, linkTarget: nil),
                               referenceFile("./Orphan/child", 0, 0)])
        Issue.record("expected throw")
    } catch {}
    // Root must be a directory, and paths must be unique.
    do {
        _ = try Bom.data(for: [referenceFile(".", 1, 0)])
        Issue.record("expected throw")
    } catch {}
    do {
        _ = try Bom.data(for: [referenceDir(".", 0), referenceFile("./A/B", 1, 0), referenceFile("./A/B", 2, 0)])
        Issue.record("expected throw")
    } catch {}
    // The format's size field is 32-bit: a bigger entry must error, never silently truncate.
    do {
        _ = try Bom.data(for: [referenceDir(".", 0), referenceFile("./big", UInt64(UInt32.max) + 1, 1)])
        Issue.record("expected throw")
    } catch {}
}

@Test func parseRejectsMalformedArchives() throws {
    let good = try fixture("reference-full.bom")
    for broken in [Data(), Data("nope".utf8), Data("BOMStore00".utf8), good.prefix(120), good.prefix(512)] {
        do { _ = try Bom(Data(broken)); Issue.record("expected throw") } catch {}
    }
    // Dangling references inside an otherwise well-formed store must error, not crash: point the
    // Paths var (4 header fields, then the second var entry's index) past the pointer table.
    var mutated = [UInt8](good)
    let varsOffset = (Int(mutated[24]) << 24) | (Int(mutated[25]) << 16) | (Int(mutated[26]) << 8) | Int(mutated[27])
    mutated[varsOffset + 16] = 0xFC
    do { _ = try Bom(Data(mutated)); Issue.record("expected throw") } catch {}
}