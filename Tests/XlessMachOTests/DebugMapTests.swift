import Testing
import Foundation
@testable import XlessMachO

/// A thin arm64 executable as `ld64.lld` lays it out: the header and load commands, then `__TEXT,__text` holding
/// `code` at 0x1000 (vmaddr 0x100001000), `__DATA,__bss` (zero-fill), and `__LINKEDIT` with the symbol table
/// (`symbols`: name, n_type, value) and its strings. With `uuid`, an LC_UUID of 16 times that byte.
struct ExecutableImage {
    static let nOSO: UInt8 = 0x66, nFUN: UInt8 = 0x24, nSO: UInt8 = 0x64, nSect: UInt8 = 0x0e, nExt: UInt8 = 0x01

    var data = Data()
    var uuidOffset: Int?

    init(code: [UInt8] = [0xc0, 0x03, 0x5f, 0xd6], textAddr: UInt64 = 0x1_0000_1000, symbols: [(String, UInt8, UInt64)] = [],
         uuid: UInt8? = 0x11, bssSize: UInt64 = 0x40) {
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func name16(_ s: String, _ d: inout Data) { d.append(contentsOf: Array(s.utf8)); d.append(Data(count: 16 - s.utf8.count)) }
        let textOff = 0x1000, linkeditOff = 0x2000
        var strings = Data([0x20, 0])   // " \0": index 0 is the empty name, as ld64 writes it
        var nlist = Data()
        for (name, type, value) in symbols {
            u32(UInt32(strings.count), &nlist); nlist.append(type); nlist.append(type & 0x0e == 0x0e ? 1 : 0); nlist.append(contentsOf: [0, 0])
            u64(value, &nlist)
            strings.append(contentsOf: Array(name.utf8)); strings.append(0)
        }
        var cmds = Data(), n: UInt32 = 0
        // __TEXT with __text
        u32(0x19, &cmds); u32(72 + 80, &cmds); name16("__TEXT", &cmds)
        u64(0x1_0000_0000, &cmds); u64(0x2000, &cmds); u64(0, &cmds); u64(UInt64(linkeditOff), &cmds)
        u32(5, &cmds); u32(5, &cmds); u32(1, &cmds); u32(0, &cmds)
        name16("__text", &cmds); name16("__TEXT", &cmds); u64(textAddr, &cmds); u64(UInt64(code.count), &cmds)
        u32(UInt32(textOff), &cmds); u32(2, &cmds); u32(0, &cmds); u32(0, &cmds); u32(0x8000_0400, &cmds); u32(0, &cmds); u32(0, &cmds); u32(0, &cmds)
        n += 1
        // __DATA with a zero-fill __bss
        u32(0x19, &cmds); u32(72 + 80, &cmds); name16("__DATA", &cmds)
        u64(0x1_0000_2000, &cmds); u64(0x4000, &cmds); u64(0, &cmds); u64(0, &cmds)
        u32(3, &cmds); u32(3, &cmds); u32(1, &cmds); u32(0, &cmds)
        name16("__bss", &cmds); name16("__DATA", &cmds); u64(0x1_0000_2000, &cmds); u64(bssSize, &cmds)
        u32(0, &cmds); u32(3, &cmds); u32(0, &cmds); u32(0, &cmds); u32(0x1, &cmds); u32(0, &cmds); u32(0, &cmds); u32(0, &cmds)
        n += 1
        // __LINKEDIT
        let linkeditSize = nlist.count + strings.count
        u32(0x19, &cmds); u32(72, &cmds); name16("__LINKEDIT", &cmds)
        u64(0x1_0000_6000, &cmds); u64(0x4000, &cmds); u64(UInt64(linkeditOff), &cmds); u64(UInt64(linkeditSize), &cmds)
        u32(1, &cmds); u32(1, &cmds); u32(0, &cmds); u32(0, &cmds)
        n += 1
        u32(0x2, &cmds); u32(24, &cmds); u32(UInt32(linkeditOff), &cmds); u32(UInt32(symbols.count), &cmds)
        u32(UInt32(linkeditOff + nlist.count), &cmds); u32(UInt32(strings.count), &cmds)
        n += 1
        if let uuid {
            uuidOffset = 32 + cmds.count + 8
            u32(0x1b, &cmds); u32(24, &cmds); cmds.append(Data(repeating: uuid, count: 16))
            n += 1
        }
        u32(0xfeedfacf, &data); u32(0x0100000c, &data); u32(0, &data); u32(2, &data)
        u32(n, &data); u32(UInt32(cmds.count), &data); u32(0, &data); u32(0, &data)
        data.append(cmds)
        data.append(Data(count: textOff - data.count))
        data.append(contentsOf: code)
        data.append(Data(count: linkeditOff - data.count))
        data.append(nlist)
        data.append(strings)
    }
}

/// What `-Wl,-x` changes: the local symbols go, the code stays.
private let unstrippedSymbols: [(String, UInt8, UInt64)] = [
    ("/w/target/release/deps/hello-1.hello.abc-cgu.0.rcgu.o", ExecutableImage.nOSO, 0),
    ("__ZN5hello7private17h1E", ExecutableImage.nFUN, 0x1_0000_1000),
    ("__ZN5hello7private17h1E", ExecutableImage.nSect, 0x1_0000_1000),
    ("_main", ExecutableImage.nSect | ExecutableImage.nExt, 0x1_0000_1000),
]
private let strippedSymbols = [unstrippedSymbols[0], unstrippedSymbols[3]]

@Test func debugMapObjectsAreTheOSOStabsInOrder() throws {
    let img = ExecutableImage(symbols: [
        ("/w/src/", ExecutableImage.nSO, 0),
        ("/w/target/aarch64-apple-ios/release/deps/libapp.a(app-0f.app.1a-cgu.0.rcgu.o)", ExecutableImage.nOSO, 0),
        ("_app_main", ExecutableImage.nFUN, 0x1_0000_1000),
        ("/r/lib/rustlib/aarch64-apple-ios/lib/libstd-9a.rlib(std-9a.std.2b-cgu.0.rcgu.o)", ExecutableImage.nOSO, 0),
        ("_main", ExecutableImage.nSect | ExecutableImage.nExt, 0x1_0000_1000),
    ])
    #expect(try MachO.debugMapObjects(in: img.data) == [
        "/w/target/aarch64-apple-ios/release/deps/libapp.a(app-0f.app.1a-cgu.0.rcgu.o)",
        "/r/lib/rustlib/aarch64-apple-ios/lib/libstd-9a.rlib(std-9a.std.2b-cgu.0.rcgu.o)",
    ])
    #expect(try MachO.debugMapObjects(in: ExecutableImage(symbols: [("_main", 0x0f, 0x1_0000_1000)]).data) == [])
    let fat = try MachO.makeFat([img.data, ExecutableImage().data])
    #expect(try MachO.debugMapObjects(in: fat).count == 2)
}

/// The executable `-Wl,-x` links and the one linked without it share every byte of code and data, and differ in their
/// symbol tables and UUIDs.
@Test func sameCodeIgnoresTheSymbolTableAndTheUUID() throws {
    let stripped = ExecutableImage(symbols: strippedSymbols, uuid: 0x11).data
    let unstripped = ExecutableImage(symbols: unstrippedSymbols, uuid: 0x22).data
    #expect(stripped != unstripped)
    #expect(try MachO.sameCode(stripped, unstripped))
}

@Test func sameCodeComparesSectionContentsAddressesAndSizes() throws {
    let a = ExecutableImage(symbols: strippedSymbols).data
    #expect(try !MachO.sameCode(a, ExecutableImage(code: [0x1f, 0x20, 0x03, 0xd5], symbols: strippedSymbols).data))
    #expect(try !MachO.sameCode(a, ExecutableImage(textAddr: 0x1_0000_1004, symbols: strippedSymbols).data))
    #expect(try !MachO.sameCode(a, ExecutableImage(symbols: strippedSymbols, bssSize: 0x80).data))
    #expect(try !MachO.sameCode(a, MachO.makeFat([a])))
}

/// The image's own fields are read from build outputs: a malformed one throws, it never traps.
@Test func malformedImagesThrow() throws {
    let good = ExecutableImage(symbols: strippedSymbols).data
    // __TEXT,__text's size (the first section: header 32 + segment command 72 + 40) close to UInt64.max.
    var hugeSection = good
    try hugeSection.setU64LE(32 + 72 + 40, 0xffff_ffff_ffff_fff0)
    #expect(throws: MachOError.self) { try MachO.sameCode(hugeSection, good) }
    // LC_SYMTAB (after the three segment commands, 152 + 152 + 72 bytes) claiming more symbols than the file holds.
    var manySymbols = good
    try manySymbols.setU32LE(32 + 376 + 12, 0x7fff_ffff)
    #expect(throws: MachOError.self) { try MachO.debugMapObjects(in: manySymbols) }
    // A string index past the string table.
    var badString = good
    try badString.setU32LE(0x2000, 0xffff)
    #expect(throws: MachOError.self) { try MachO.debugMapObjects(in: badString) }
}

@Test func setUUIDRewritesTheLoadCommand() throws {
    var d = ExecutableImage(uuid: 0x11).data
    try MachO.setUUID(in: &d, to: "22222222-2222-2222-2222-222222222222")
    #expect(try MachO.uuids(in: d) == ["22222222-2222-2222-2222-222222222222"])
    #expect(d.count == ExecutableImage(uuid: 0x11).data.count)

    var none = ExecutableImage(uuid: nil).data
    #expect(throws: MachOError.self) { try MachO.setUUID(in: &none, to: "22222222-2222-2222-2222-222222222222") }
    var thin = ExecutableImage(uuid: 0x11).data
    #expect(throws: MachOError.self) { try MachO.setUUID(in: &thin, to: "not-a-uuid") }
}
