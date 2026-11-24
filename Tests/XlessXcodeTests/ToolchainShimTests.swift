import Foundation
import Testing
import XlessMachO
import XlessCore
@testable import XlessXcode

// MARK: strip

@Test func stripMapsSwiftBuildCallsToLLVMStrip() throws {
    // The Strip task of an installed product (STRIP_STYLE debugging, STRIP_SWIFT_SYMBOLS) and the copy phase's strip.
    let task = try StripShim.llvmArguments(["-D", "-S", "-T", "/p/F.framework/F"])
    #expect(task.input == "/p/F.framework/F" && task.arguments == ["-D", "-S", "-T", "/p/F.framework/F"])
    let copy = try StripShim.llvmArguments(["-D", "-S", "-no_atom_info", "/p/E.appex/E", "-o", "/a/E.appex/E"])
    #expect(copy.input == "/p/E.appex/E" && copy.arguments == ["-D", "-S", "/p/E.appex/E", "-o", "/a/E.appex/E"])
    #expect(task.output == "/p/F.framework/F" && copy.output == "/a/E.appex/E")
    // Options in any order.
    #expect(try StripShim.llvmArguments(["-T", "/p/F", "-S", "-D"]).arguments == ["-D", "-S", "-T", "/p/F"])
    #expect(try StripShim.llvmArguments(["-no_atom_info", "-o", "/q", "-S", "/p", "-D"]).arguments == ["-D", "-S", "/p", "-o", "/q"])
}

/// Only the two measured option sets: anything else, even a subset or a mix of the two, is refused.
@Test(arguments: [["-x", "/b"], ["-D", "-S", "-x", "/b"], ["-D", "-x", "-T", "/b"], ["-D", "/b"], ["-S", "/b"], ["-D", "-S", "/b"],
                  ["-D", "-S", "-T", "/b", "-o", "/c"], ["-D", "-S", "-no_atom_info", "/b"], ["-D", "-S", "-T", "-no_atom_info", "/b"],
                  ["-D", "-D", "-S", "-T", "/b"], ["-u", "-r", "/b"], ["-S", "/a", "/b"], ["-S"], ["-S", "/b", "-o"],
                  ["-s", "syms", "-S", "/b"]])
func stripRefusesUnmeasuredCalls(_ args: [String]) {
    #expect(throws: ToolShimUnsupported.self) { try StripShim.llvmArguments(args) }
}

/// A thin arm64 MH_DYLIB with the given load command types (each 16 bytes).
private func machO(_ commands: [UInt32]) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(6); u32(UInt32(commands.count)); u32(UInt32(commands.count * 16)); u32(0); u32(0)
    for c in commands { u32(c); u32(16); u32(0); u32(0) }
    return d
}

@Test func stripChecksItsInput() throws {
    let args = ["-D", "-S", "-no_atom_info", "/p/x", "-o", "/q/x"]
    try StripShim.checkInput(machO([0x32, 0x2]), path: "/p/x", args: args)
    #expect(throws: ToolShimUnsupported.self) { try StripShim.checkInput(machO([0x32, 0x36]), path: "/p/x", args: args) }   // LC_ATOM_INFO
    #expect(throws: ToolShimUnsupported.self) { try StripShim.checkInput(Data("#!/bin/sh\n".utf8), path: "/p/x", args: args) }
    try StripShim.checkInput(machO([0x36]), path: "/p/x", args: ["-D", "-S", "-T", "/p/x"])   // nothing to drop
    try StripShim.checkInput(Data("!<arch>\n__.SYMDEF".utf8), path: "/p/libX.a", args: ["-D", "-S", "-T", "/p/libX.a"])
    // Archives were only measured with -D -S -T.
    #expect(throws: ToolShimUnsupported.self) {
        try StripShim.checkInput(Data("!<arch>\n__.SYMDEF".utf8), path: "/p/libX.a", args: ["-D", "-S", "-no_atom_info", "/p/libX.a", "-o", "/q"])
    }
}

/// A thin arm64 dylib as `llvm-strip` lays it out: `__LINKEDIT` at 0x4000 holds `nindirect` indirect symbols, then the
/// string pool right after them (4 bytes off the 8-byte boundary when `nindirect` is odd), then `tail`.
private func strippedImage(nindirect: Int, tail: Data = Data()) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func seg(_ name: String, _ off: Int, _ size: Int) {
        u32(0x19); u32(72); d.append(contentsOf: Array(name.utf8)); d.append(Data(count: 16 - name.utf8.count))
        u64(UInt64(off)); u64(0x4000); u64(UInt64(off)); u64(UInt64(size)); u32(1); u32(1); u32(0); u32(0)
    }
    let strings = Data("\0_f\0\0".utf8), ind = 0x4000, str = ind + 4 * nindirect
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(6); u32(4); u32(72 * 2 + 24 + 80); u32(0); u32(0)
    seg("__TEXT", 0, 0x4000); seg("__LINKEDIT", 0x4000, str + strings.count + tail.count - 0x4000)
    u32(0x2); u32(24); u32(UInt32(ind)); u32(0); u32(UInt32(str)); u32(UInt32(strings.count))
    u32(0xb); u32(80); for v in [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt32(ind), UInt32(nindirect), 0, 0, 0, 0] as [UInt32] { u32(v) }
    d.append(Data(count: 0x4000 - d.count))
    for i in 0..<nindirect { u32(UInt32(i)) }
    return d + strings + tail
}

/// A fat (cafebabe) wrapper of arm64 slices, each at a 0x4000 boundary.
private func fat(_ slices: [Data]) -> Data {
    var d = Data()
    func be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    be(0xcafebabe); be(UInt32(slices.count))
    var offset = 0x4000
    for s in slices { be(0x0100000c); be(0); be(UInt32(offset)); be(UInt32(s.count)); be(14); offset += (s.count + 0x3fff) & ~0x3fff }
    for s in slices { d.append(Data(count: ((d.count + 0x3fff) & ~0x3fff) - d.count)); d.append(s) }
    return d
}

@Test func stripAlignsLLVMStripOutput() throws {
    let args = ["-D", "-S", "-T", "/p/F"]
    let bad = strippedImage(nindirect: 3)
    #expect(try MachO.linkeditAlignmentProblems(in: bad).count == 1)
    let fixed = try #require(try StripShim.alignOutput(bad, path: "/p/F", args: args))
    #expect(try MachO.linkeditAlignmentProblems(in: fixed).isEmpty)
    #expect(try StripShim.alignOutput(strippedImage(nindirect: 2), path: "/p/F", args: args) == nil)        // already aligned
    #expect(try StripShim.alignOutput(Data("!<arch>\n__.SYMDEF".utf8), path: "/p/libX.a", args: args) == nil)   // archive
    // A universal static archive (fat magic, an `ar` slice) passes checkInput with -T, and is no image to align.
    let fatArchive = fat([Data("!<arch>\nx.o/            0           0     0     100644  4         `\nabcd".utf8)])
    try StripShim.checkInput(fatArchive, path: "/p/libX.a", args: args)
    #expect(try StripShim.alignOutput(fatArchive, path: "/p/libX.a", args: args) == nil)
    let fixedInFat = try #require(try StripShim.alignOutput(fat([bad]), path: "/p/F", args: args))       // a fat image is aligned
    #expect(try MachO.linkeditAlignmentProblems(in: fixedInFat).isEmpty)
    #expect(throws: ToolShimUnsupported.self) {                                                              // images mixed with archives
        try StripShim.alignOutput(fat([bad, Data("!<arch>\n__.SYMDEF".utf8)]), path: "/p/F", args: args)
    }
    #expect(throws: ToolShimUnsupported.self) {                                                              // unknown tail
        try StripShim.alignOutput(strippedImage(nindirect: 3, tail: Data([0xde, 0xad])), path: "/p/F", args: args)
    }
}

@Test func stripRunsLLVMStripThenAlignsItsOutput() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("strip-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func script(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ExecutableFile.write("#!/bin/sh\n" + body + "\n", to: url, stage: .build)
        return url.path
    }
    // A stand-in llvm-strip: copies for `-o` (the copy phase), leaves the file for `-T` (in place).
    let fake = try script("llvm-strip", #"if [ "$4" = -o ]; then cp "$3" "$5"; fi"#)
    let src = dir.appendingPathComponent("E"), dst = dir.appendingPathComponent("out/E")
    try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try strippedImage(nindirect: 3).write(to: src)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path)

    #expect(try StripShim.run(["-D", "-S", "-no_atom_info", src.path, "-o", dst.path], llvmStrip: fake) == 0)
    #expect(try MachO.linkeditAlignmentProblems(in: Data(contentsOf: dst)).isEmpty)
    #expect(try MachO.linkeditAlignmentProblems(in: Data(contentsOf: src)).count == 1)   // the input is not touched
    #expect((try FileManager.default.attributesOfItem(atPath: dst.path)[.posixPermissions] as? Int) == 0o755)

    #expect(try StripShim.run(["-D", "-S", "-T", src.path], llvmStrip: fake) == 0)
    #expect(try MachO.linkeditAlignmentProblems(in: Data(contentsOf: src)).isEmpty)
    #expect((try FileManager.default.attributesOfItem(atPath: src.path)[.posixPermissions] as? Int) == 0o755)

    // A failed llvm-strip: its status, nothing re-laid.
    try strippedImage(nindirect: 3).write(to: src)
    #expect(try StripShim.run(["-D", "-S", "-T", src.path], llvmStrip: try script("failing", "exit 3")) == 3)
    #expect(try Data(contentsOf: src) == strippedImage(nindirect: 3))
    // An output the post-pass does not understand is refused.
    try strippedImage(nindirect: 3, tail: Data([1])).write(to: src)
    #expect(throws: ToolShimUnsupported.self) { try StripShim.run(["-D", "-S", "-T", src.path], llvmStrip: fake) }
}

// MARK: linker

@Test func linkerForceLoadsArchivesStandingForObjects() throws {
    let archives: Set<String> = ["/d/Products/Kit.o", "/d/Products/Kit-Cxx.o"]
    var written: [String: [String]] = [:]
    let args = try LinkerShim.arguments(
        ["-arch", "arm64", "-dylib", "-o", "/d/Products/Kit.framework/Kit", "/d/Products/Kit.o", "/d/obj/main.o",
         "-filelist", "/d/list", "-lc++"],
        isArchive: archives.contains, readFileList: { _ in ["/d/Products/Kit-Cxx.o", "/d/obj/a.o", ""] },
        writeFileList: { path, lines in written[path] = lines; return path + ".xless" })
    #expect(args == ["-arch", "arm64", "-dylib", "-o", "/d/Products/Kit.framework/Kit", "-force_load", "/d/Products/Kit.o", "/d/obj/main.o",
                     "-force_load", "/d/Products/Kit-Cxx.o", "-filelist", "/d/list.xless", "-lc++"])
    #expect(written == ["/d/list": ["/d/obj/a.o"]])
    // The prelink itself (-r) goes to the trampoline unchanged; an output path is never rewritten.
    let r = ["-r", "-filelist", "/d/l", "-o", "/d/Products/Kit.o"]
    #expect(try LinkerShim.arguments(r, isArchive: { _ in true }, readFileList: { _ in [] }, writeFileList: { p, _ in p }) == r)
    #expect(try LinkerShim.arguments(["-o", "/d/x.o", "/d/y.o"], isArchive: { _ in true }, readFileList: { _ in [] },
                                     writeFileList: { p, _ in p }) == ["-o", "/d/x.o", "-force_load", "/d/y.o"])
}

/// A thin arm64 Mach-O header of the given file type and flags.
private func header(filetype: UInt32, flags: UInt32) -> Data {
    var d = Data()
    for v: UInt32 in [0xfeedfacf, 0x0100000c, 0, filetype, 0, 0, flags, 0] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    return d
}

@Test func linkerKeepsPointerMethodListsForObjectsWithoutSubsections() throws {
    let prelinked = header(filetype: 1, flags: 0), compiled = header(filetype: 1, flags: 0x2000), dylib = header(filetype: 6, flags: 0x00100085)
    #expect(LinkerShim.isObjectWithoutSubsections(prelinked))
    #expect(!LinkerShim.isObjectWithoutSubsections(compiled) && !LinkerShim.isObjectWithoutSubsections(dylib))
    #expect(LinkerShim.isObjectWithoutSubsections(try MachO.makeFat([prelinked])))
    let files = ["/p/A/MLKit.framework/MLKit": prelinked, "/p/B/React.framework/React": dylib, "/p/A/React.framework/React": prelinked,
                 "/p/C/React.framework/React": compiled]
    func link(_ args: [String]) throws -> [String] {
        try LinkerShim.arguments(args, isArchive: { _ in false }, readFileList: { _ in [] }, writeFileList: { p, _ in p },
                                 fileExists: { files[$0] != nil }, readFile: { files[$0] })
    }
    #expect(try link(["-F/p/A", "-F", "/p/B", "-framework", "MLKit", "-o", "/x"]).last == "-no_objc_relative_method_lists")
    // The first -F directory with the framework wins: A's React is prelinked without subsections, B's is a dylib.
    #expect(try link(["-F/p/B", "-F/p/A", "-framework", "React", "-o", "/x"]) == ["-F/p/B", "-F/p/A", "-framework", "React", "-o", "/x"])
    #expect(try link(["-F/p/A", "-F/p/B", "-framework", "React", "-o", "/x"]).last == "-no_objc_relative_method_lists")
    #expect(try link(["-F/p/C", "-weak_framework", "React", "-o", "/x"]).last == "/x")
    // Already there: not added twice.
    let given = ["-F/p/A", "-framework", "MLKit", "-no_objc_relative_method_lists", "-o", "/x"]
    #expect(try link(given) == given)
    #expect(try link(["-F/p/A", "-framework", "Missing", "-o", "/x"]).last == "/x")
}

@Test func archiveDetectionReadsTheMagic() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ld64-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("!<arch>\n/               0".utf8).write(to: dir.appendingPathComponent("a.o"))
    try machO([]).write(to: dir.appendingPathComponent("b.o"))
    #expect(LinkerShim.isArchive(dir.appendingPathComponent("a.o").path))
    #expect(!LinkerShim.isArchive(dir.appendingPathComponent("b.o").path))
    #expect(!LinkerShim.isArchive(dir.appendingPathComponent("missing.o").path))
}

// MARK: embeddedBinaryValidationUtility

private func bundles(app: [String: String], ext: [String: String]) throws -> (appPlist: String, appex: String, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ebvu-\(UUID().uuidString)")
    let appex = root.appendingPathComponent("A.app/PlugIns/E.appex")
    try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
    // Swift Build validates the built (binary) Info.plists.
    try PropertyListSerialization.data(fromPropertyList: app, format: .binary, options: 0).write(to: root.appendingPathComponent("A.app/Info.plist"))
    try PropertyListSerialization.data(fromPropertyList: ext, format: .binary, options: 0).write(to: appex.appendingPathComponent("Info.plist"))
    return (root.appendingPathComponent("A.app/Info.plist").path, appex.path, { try? FileManager.default.removeItem(at: root) })
}

@Test func embeddedBinaryValidationMatchesXcode() throws {
    let app = ["CFBundleIdentifier": "com.example.app", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0"]
    func check(_ ext: [String: String]) throws -> EmbeddedBinaryValidation.Result {
        let b = try bundles(app: app, ext: ext)
        defer { b.cleanup() }
        return try EmbeddedBinaryValidation.run([b.appex, "-info-plist-path", b.appPlist])
    }
    #expect(try check(app.merging(["CFBundleIdentifier": "com.example.app.Ext"]) { $1 }) == .init(stderr: "", exitCode: 0))
    // A plain string prefix, as Xcode's (no dot required).
    #expect(try check(app.merging(["CFBundleIdentifier": "com.example.appX"]) { $1 }).exitCode == 0)
    #expect(try check(app.merging(["CFBundleIdentifier": "com.other.Ext"]) { $1 }) == .init(stderr:
        "error: Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier.\n\n"
        + "\t\tEmbedded Binary Bundle Identifier:\tcom.other.Ext\n\t\tParent App Bundle Identifier:\t\tcom.example.app\n\n\n", exitCode: 1))
    #expect(try check(app.merging(["CFBundleIdentifier": "com.example.app.Ext", "CFBundleVersion": "9"]) { $1 }) == .init(stderr:
        "warning: The CFBundleVersion of an app extension ('9') must match that of its containing parent app ('1').\n", exitCode: 0))
    // Only the first mismatch is reported; a missing value prints (null).
    #expect(try check(["CFBundleIdentifier": "com.example.app.Ext", "CFBundleVersion": "9", "CFBundleShortVersionString": "9.9"]).stderr
        == "warning: The CFBundleVersion of an app extension ('9') must match that of its containing parent app ('1').\n")
    #expect(try check(["CFBundleIdentifier": "com.example.app.Ext", "CFBundleVersion": "1"]).stderr
        == "warning: The CFBundleShortVersionString of an app extension (null) must match that of its containing parent app ('1.0.0').\n")
}

@Test func embeddedBinaryValidationRefusesUnmeasuredCalls() throws {
    let b = try bundles(app: ["CFBundleIdentifier": "a"], ext: ["CFBundleIdentifier": "a.b"])
    defer { b.cleanup() }
    for args in [[b.appex, "-info-plist-path", b.appPlist, "-signing-cert", "Apple Distribution: X"], [b.appex],
                 [b.appex.replacingOccurrences(of: ".appex", with: ".framework"), "-info-plist-path", b.appPlist],
                 [b.appex, "-info-plist-path", b.appPlist + ".missing"], [b.appex, "-verbose", "-info-plist-path", b.appPlist]] {
        #expect(throws: ToolShimUnsupported.self) { try EmbeddedBinaryValidation.run(args) }
    }
    #expect(try EmbeddedBinaryValidation.run([b.appex, "-signing-cert", "", "-info-plist-path", b.appPlist]).exitCode == 0)
}

// MARK: strip: the indirect symbol table

/// A thin arm64 dylib with a symbol table (name, value) and an indirect symbol table of the given entries.
private func imageWithSymbols(_ symbols: [(String, UInt64)], indirect: [UInt32]) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    var strings = Data("\0".utf8), strx: [UInt32] = []
    for (name, _) in symbols { strx.append(UInt32(strings.count)); strings.append(Data((name + "\0").utf8)) }
    let symoff = 0x200, indoff = symoff + 16 * symbols.count, stroff = indoff + 4 * indirect.count
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(6); u32(2); u32(24 + 80); u32(0); u32(0)
    u32(0x2); u32(24); u32(UInt32(symoff)); u32(UInt32(symbols.count)); u32(UInt32(stroff)); u32(UInt32(strings.count))
    u32(0xb); u32(80)
    for v in [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt32(indoff), UInt32(indirect.count), 0, 0, 0, 0] as [UInt32] { u32(v) }
    d.append(Data(count: symoff - d.count))
    for (i, s) in symbols.enumerated() { u32(strx[i]); d.append(contentsOf: [0x0e, 1, 0, 0]); u64(s.1) }
    for e in indirect { u32(e) }
    return d + strings
}

private func indirectEntries(_ d: Data, count: Int) -> [UInt32] {
    func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(d[d.startIndex + o + $1]) << (8 * UInt32($1)) } }
    let off = Int(u32(32 + 24 + 56))
    return (0..<count).map { u32(off + 4 * $0) }
}

/// `llvm-strip -S` drops local symbols and writes an arbitrary value (0 in an arm64 build, 0x5555 in an amd64 one) for
/// each indirect symbol table entry that named one; every such entry becomes INDIRECT_SYMBOL_LOCAL, whatever it held.
@Test(arguments: [UInt32(0), 0x5555, 0x7777_7777]) func strippedIndirectEntriesOfDroppedSymbolsBecomeLocal(garbage: UInt32) throws {
    let original = imageWithSymbols([("_keep", 0x10), ("GCC_except_table13", 0x20), ("_other", 0x30), ("ltmp1", 0x40)],
                                    indirect: [1, 0, 0x8000_0000, 3, 2, 0x4000_0000])
    // The strip kept _keep and _other (now indices 0 and 1); the entries for the other two hold garbage.
    let stripped = imageWithSymbols([("_keep", 0x10), ("_other", 0x30)], indirect: [garbage, 0, 0x8000_0000, garbage, 1, 0x4000_0000])
    let out = try #require(try MachO.normalizeStrippedIndirectSymbols(original: original, stripped: stripped))
    #expect(indirectEntries(out, count: 6) == [0x8000_0000, 0, 0x8000_0000, 0x8000_0000, 1, 0x4000_0000])
}

@Test func theNormalizedImageDoesNotDependOnTheGarbage() throws {
    let original = imageWithSymbols([("_keep", 0x10), ("L1", 0x20)], indirect: [1, 0])
    let arm = imageWithSymbols([("_keep", 0x10)], indirect: [0, 0])
    let amd = imageWithSymbols([("_keep", 0x10)], indirect: [0x5555, 0])
    #expect(try MachO.normalizeStrippedIndirectSymbols(original: original, stripped: arm)
            == MachO.normalizeStrippedIndirectSymbols(original: original, stripped: amd))
}

@Test func indirectEntriesAreLeftAloneWhenNoSymbolWasDropped() throws {
    let original = imageWithSymbols([("_a", 1), ("_b", 2)], indirect: [1, 0x8000_0000, 0])
    #expect(try MachO.normalizeStrippedIndirectSymbols(original: original, stripped: original) == nil)
    // Not an image: nothing to do.
    #expect(try MachO.normalizeStrippedIndirectSymbols(original: Data("!<arch>\n".utf8), stripped: Data("!<arch>\n".utf8)) == nil)
}

@Test func anIndirectTableOutsideItsImageIsRefused() throws {
    var bad = imageWithSymbols([("_a", 1)], indirect: [0])
    withUnsafeBytes(of: UInt32(1_000_000).littleEndian) { bad.replaceSubrange((32 + 24 + 60)..<(32 + 24 + 64), with: $0) }   // nindirectsyms
    #expect(throws: MachOError.self) { try MachO.normalizeStrippedIndirectSymbols(original: bad, stripped: bad) }
}
