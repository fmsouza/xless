import Testing
import Foundation
@testable import XlessMachO

/// A thin 64-bit Mach-O of `filetype` (MH_EXECUTE 2, MH_DSYM 0xa) whose LC_UUID is 16 bytes of `uuid`.
private func image(cpu: UInt32 = 0x0100000c, uuid: UInt8, filetype: UInt32 = 2) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    u32(0xfeedfacf); u32(cpu); u32(0); u32(filetype); u32(1 /*ncmds*/); u32(24); u32(0); u32(0)
    u32(0x1b); u32(24); d.append(Data(repeating: uuid, count: 16))
    d.append(Data(repeating: 0, count: 32))
    return d
}

private func uuid(_ byte: UInt8) -> String {
    let h = String(format: "%02X", byte)
    return [8, 4, 4, 4, 12].map { String(repeating: h, count: $0 / 2) }.joined(separator: "-")
}

private var fm: FileManager { .default }

/// `url` with every symbolic link resolved. On macOS the temporary directory is under `/var`, a link to `/private/var`,
/// and FileManager lists a directory's entries under the latter; `resolvingSymlinksInPath()` would strip `/private` again.
private func realPath(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
}

private func tmp() throws -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("dsym-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return realPath(url)
}

private func write(_ data: Data, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

/// `<name>.app` with its Info.plist naming `executable`: at the bundle's root (iOS) or under `Contents/` (macOS).
private func app(in root: URL, name: String = "Hello", executable: String = "Hello", mac: Bool) throws -> URL {
    let app = root.appendingPathComponent("\(name).app", isDirectory: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable], format: .xml, options: 0)
    try write(plist, app.appendingPathComponent(mac ? "Contents/Info.plist" : "Info.plist"))
    return app
}

/// `<bin>.dSYM` as dsymutil writes it: an Info.plist and one DWARF file named after the binary.
private func dSYM(in dir: URL, bin: String, dwarf: Data) throws -> URL {
    let bundle = dir.appendingPathComponent("\(bin).dSYM", isDirectory: true)
    try write(Data("<plist/>".utf8), bundle.appendingPathComponent("Contents/Info.plist"))
    try write(dwarf, bundle.appendingPathComponent("Contents/Resources/DWARF/\(bin)"))
    return bundle
}

@Test func uuidsOfThinAndFatImages() throws {
    #expect(try MachO.uuids(in: image(uuid: 0x11)) == [uuid(0x11)])
    let fat = try MachO.makeFat([image(cpu: 0x01000007, uuid: 0x22), image(uuid: 0x11)])
    #expect(try MachO.uuids(in: fat) == [uuid(0x22), uuid(0x11)])
    #expect(throws: (any Error).self) { try MachO.uuids(in: Data("not a mach-o".utf8)) }
}

/// As cargo leaves it: rustc's dSYM is `deps/<crate>-<hash>.dSYM` (DWARF file `<crate>-<hash>`), and cargo uplifts it as
/// `<bin>.dSYM`, a symbolic link to that directory.
@Test func keepRenamesTheDSYMOfAThinExecutableAfterTheApp() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let exe = root.appendingPathComponent("target/release/hello-bin")
    try write(image(uuid: 0x11), exe)
    let dwarf = image(uuid: 0x11, filetype: 0xa)
    _ = try dSYM(in: exe.deletingLastPathComponent().appendingPathComponent("deps"), bin: "hello_bin-0123abcd", dwarf: dwarf)
    try fm.createSymbolicLink(atPath: exe.path + ".dSYM", withDestinationPath: "deps/hello_bin-0123abcd.dSYM")
    let out = root.appendingPathComponent("build/dSYMs")
    try write(Data("old".utf8), out.appendingPathComponent("Stale.app.dSYM/x"))

    let outcome = try DSYM.keep(executables: [exe], app: try app(in: root, mac: false), into: out)
    #expect(outcome == .kept(out.appendingPathComponent("Hello.app.dSYM")))
    #expect(try fm.contentsOfDirectory(atPath: out.path) == ["Hello.app.dSYM"])
    // A copy, not a link into cargo's target directory.
    #expect(try out.appendingPathComponent("Hello.app.dSYM").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    #expect(try fm.contentsOfDirectory(atPath: out.appendingPathComponent("Hello.app.dSYM/Contents/Resources/DWARF").path) == ["Hello"])
    #expect(fm.contents(atPath: out.appendingPathComponent("Hello.app.dSYM/Contents/Resources/DWARF/Hello").path) == dwarf)
    #expect(fm.fileExists(atPath: out.appendingPathComponent("Hello.app.dSYM/Contents/Info.plist").path))
}

@Test func keepMergesOneDSYMPerArchitectureIntoAUniversalOne() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    var exes: [URL] = []
    for (triple, cpu, byte) in [("x86_64-apple-darwin", UInt32(0x01000007), UInt8(0x22)), ("aarch64-apple-darwin", 0x0100000c, 0x11)] {
        let exe = root.appendingPathComponent("target/\(triple)/release/hello")
        try write(image(cpu: cpu, uuid: byte), exe)
        _ = try dSYM(in: exe.deletingLastPathComponent(), bin: "hello", dwarf: image(cpu: cpu, uuid: byte, filetype: 0xa))
        exes.append(exe)
    }
    let out = root.appendingPathComponent("dSYMs")
    let outcome = try DSYM.keep(executables: exes, app: try app(in: root, name: "Hello World", executable: "hello", mac: true), into: out)
    #expect(outcome == .kept(out.appendingPathComponent("Hello World.app.dSYM")))
    let merged = try Data(contentsOf: out.appendingPathComponent("Hello World.app.dSYM/Contents/Resources/DWARF/hello"))
    #expect(MachO.isFat(merged))
    #expect(try MachO.uuids(in: merged) == [uuid(0x22), uuid(0x11)])
    #expect(DSYM.uuids(ofDSYM: out.appendingPathComponent("Hello World.app.dSYM")) == [uuid(0x11), uuid(0x22)])
}

@Test func keepRefusesADSYMOfAnotherBuild() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let exe = root.appendingPathComponent("release/hello")
    try write(image(uuid: 0x11), exe)
    _ = try dSYM(in: exe.deletingLastPathComponent(), bin: "hello", dwarf: image(uuid: 0x33, filetype: 0xa))
    let out = root.appendingPathComponent("dSYMs")
    try write(Data("old".utf8), out.appendingPathComponent("Hello.app.dSYM/x"))

    let outcome = try DSYM.keep(executables: [exe], app: try app(in: root, mac: false), into: out)
    guard case .none(let reason) = outcome else { Issue.record("kept a stale dSYM"); return }
    #expect(reason.contains("UUID"))
    #expect(!fm.fileExists(atPath: out.path))
}

@Test func keepWithoutTheDSYMOfOneArchitectureKeepsNone() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let arm = root.appendingPathComponent("arm/hello"), x86 = root.appendingPathComponent("x86/hello")
    try write(image(uuid: 0x11), arm)
    try write(image(cpu: 0x01000007, uuid: 0x22), x86)
    _ = try dSYM(in: arm.deletingLastPathComponent(), bin: "hello", dwarf: image(uuid: 0x11, filetype: 0xa))
    let out = root.appendingPathComponent("dSYMs")

    let outcome = try DSYM.keep(executables: [arm, x86], app: try app(in: root, mac: true), into: out)
    guard case .none(let reason) = outcome else { Issue.record("kept half a universal dSYM"); return }
    #expect(reason.contains("hello.dSYM"))
    #expect(!fm.fileExists(atPath: out.path))
}

/// Each refusal says what is wrong: two DWARF files in one dSYM, an executable without LC_UUID.
@Test func keepNamesWhyADSYMCannotBeUsed() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let exe = root.appendingPathComponent("release/hello")
    try write(image(uuid: 0x11), exe)
    let bundle = try dSYM(in: exe.deletingLastPathComponent(), bin: "hello", dwarf: image(uuid: 0x11, filetype: 0xa))
    try write(image(uuid: 0x11, filetype: 0xa), bundle.appendingPathComponent("Contents/Resources/DWARF/other"))
    let out = root.appendingPathComponent("dSYMs")
    let app = try app(in: root, mac: false)
    #expect(try DSYM.keep(executables: [exe], app: app, into: out) == .none("\(bundle.path) holds 2 DWARF files, not one"))

    try fm.removeItem(at: bundle.appendingPathComponent("Contents/Resources/DWARF/other"))
    var noUUID = image(uuid: 0x11)
    noUUID.replaceSubrange(32..<36, with: [0x19, 0, 0, 0])   // LC_SEGMENT_64 in place of LC_UUID
    try noUUID.write(to: exe)
    #expect(try DSYM.keep(executables: [exe], app: app, into: out) == .none("\(exe.path) has no LC_UUID"))
}

@Test func imageUUIDsAreThoseOfEveryMachOInTheBundle() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let app = try app(in: root, mac: false)
    try write(image(uuid: 0x11), app.appendingPathComponent("Hello"))
    try write(try MachO.makeFat([image(cpu: 0x01000007, uuid: 0x22), image(uuid: 0x33)]), app.appendingPathComponent("Frameworks/F.framework/F"))
    try write(Data("console.log(1)".utf8), app.appendingPathComponent("main.jsbundle"))
    try write(Data([0xcf]), app.appendingPathComponent("tiny"))
    #expect(DSYM.imageUUIDs(in: app) == [uuid(0x11), uuid(0x22), uuid(0x33)])
}

// MARK: dSYMs of Rust executables linked by cargo (the linker wrapper's debug link)

/// A dSYM's DWARF file stand-in: an image whose LC_UUID is 16 times `byte`, as dsymutil writes it (MH_DSYM).
private func dwarf(_ byte: UInt8) -> Data { image(uuid: byte, filetype: 0xa) }

private let localSymbols: [(String, UInt8, UInt64)] = [
    ("/w/target/release/deps/hello-1.hello.abc-cgu.0.rcgu.o", ExecutableImage.nOSO, 0),
    ("__ZN5hello7private17h1E", ExecutableImage.nSect, 0x1_0000_1000),
    ("_main", ExecutableImage.nSect | ExecutableImage.nExt, 0x1_0000_1000),
]

/// The wrapper links `deps/<crate>-<hash>` with -Wl,-x for cargo, and again without it into its debug directory, where
/// dsymutil writes `<crate>-<hash>.dSYM`. The executable cargo uplifts (`release/<bin>`) is the -x link: same code, other
/// UUID. The debug directory can also hold the link of another binary of the package.
@Test func debugLinkDSYMIsTheOneOfTheUnstrippedLinkWithTheShippedCode() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let shipped = root.appendingPathComponent("target/aarch64-apple-darwin/release/hello")
    try write(ExecutableImage(symbols: [localSymbols[0], localSymbols[2]], uuid: 0x11).data, shipped)
    let debug = root.appendingPathComponent("debug", isDirectory: true)
    try write(ExecutableImage(code: [0x1f, 0x20, 0x03, 0xd5], symbols: localSymbols, uuid: 0x33).data, debug.appendingPathComponent("helper-9"))
    _ = try dSYM(in: debug, bin: "helper-9", dwarf: dwarf(0x33))
    try write(ExecutableImage(symbols: localSymbols, uuid: 0x22).data, debug.appendingPathComponent("hello-2"))
    let bundle = try dSYM(in: debug, bin: "hello-2", dwarf: dwarf(0x22))

    let found = DSYM.debugLinkDSYM(of: shipped, in: debug)
    #expect(found == .found(bundle))
    // Its UUID is now the shipped executable's, which crash reporters match on.
    #expect(DSYM.uuids(ofDSYM: bundle) == [uuid(0x11)])
    // The other links (another binary, an older build) are removed; the directory is kept for a build cargo does not relink.
    #expect(try fm.contentsOfDirectory(atPath: debug.path).sorted() == ["hello-2", "hello-2.dSYM"])
    #expect(DSYM.debugLinkDSYM(of: shipped, in: debug) == .found(bundle))

    let out = root.appendingPathComponent("dSYMs")
    let outcome = try DSYM.keep([(executable: shipped, dSYM: found)], app: try app(in: root, executable: "hello", mac: true), into: out)
    #expect(outcome == .kept(out.appendingPathComponent("Hello.app.dSYM")))
    let kept = try Data(contentsOf: out.appendingPathComponent("Hello.app.dSYM/Contents/Resources/DWARF/hello"))
    #expect(try MachO.uuids(in: kept) == [uuid(0x11)])
}

@Test func debugLinkDSYMSaysWhyThereIsNone() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let shipped = root.appendingPathComponent("release/hello")
    try write(ExecutableImage(symbols: [localSymbols[2]], uuid: 0x11).data, shipped)
    let debug = root.appendingPathComponent("debug", isDirectory: true)

    // Nothing at all: the wrapper did not link it (xless forces a link in that case, so this is unexpected).
    guard case .missing(let unlinked) = DSYM.debugLinkDSYM(of: shipped, in: debug) else { Issue.record("found a dSYM"); return }
    #expect(unlinked.contains("did not link"))

    // The wrapper's record of a link whose objects had no DWARF.
    try write(Data(), debug.appendingPathComponent("hello-1.nodebug"))
    guard case .missing(let none) = DSYM.debugLinkDSYM(of: shipped, in: debug) else { Issue.record("found a dSYM"); return }
    #expect(none.contains("without debug info"))

    // The wrapper's record of a failed second link or dsymutil.
    try fm.removeItem(at: debug.appendingPathComponent("hello-1.nodebug"))
    try write(Data(), debug.appendingPathComponent("hello-1.failed"))
    guard case .missing(let failedLink) = DSYM.debugLinkDSYM(of: shipped, in: debug) else { Issue.record("found a dSYM"); return }
    #expect(failedLink.contains("failed"))

    // A shipped executable that cannot be read is a reason, not an error that fails the build.
    guard case .missing(let unreadable) = DSYM.debugLinkDSYM(of: root.appendingPathComponent("missing"), in: debug) else { Issue.record("found a dSYM"); return }
    #expect(!unreadable.isEmpty)

    // A debug link of other code only.
    try write(ExecutableImage(code: [0x1f, 0x20, 0x03, 0xd5], symbols: localSymbols, uuid: 0x33).data, debug.appendingPathComponent("helper-9"))
    _ = try dSYM(in: debug, bin: "helper-9", dwarf: dwarf(0x33))
    guard case .missing(let other) = DSYM.debugLinkDSYM(of: shipped, in: debug) else { Issue.record("found a dSYM"); return }
    #expect(other.contains("no unstripped link"))

    // The unstripped link, but dsymutil left no dSYM.
    try write(ExecutableImage(symbols: localSymbols, uuid: 0x22).data, debug.appendingPathComponent("hello-2"))
    guard case .missing(let failed) = DSYM.debugLinkDSYM(of: shipped, in: debug) else { Issue.record("found a dSYM"); return }
    #expect(failed.contains("dsymutil"))
}

/// One architecture without a dSYM: the universal app keeps none, and says why.
@Test func keepWithAMissingSliceKeepsNoneAndGivesItsReason() throws {
    let root = try tmp(); defer { try? fm.removeItem(at: root) }
    let arm = root.appendingPathComponent("arm/hello"), x86 = root.appendingPathComponent("x86/hello")
    try write(image(uuid: 0x11), arm)
    try write(image(cpu: 0x01000007, uuid: 0x22), x86)
    let armDSYM = try dSYM(in: root.appendingPathComponent("elsewhere"), bin: "hello-1", dwarf: dwarf(0x11))
    let out = root.appendingPathComponent("dSYMs")
    try write(Data("old".utf8), out.appendingPathComponent("Hello.app.dSYM/x"))

    let outcome = try DSYM.keep([(executable: arm, dSYM: .found(armDSYM)), (executable: x86, dSYM: .missing("x86_64 was built without debug info"))],
                                app: try app(in: root, mac: true), into: out)
    #expect(outcome == .none("x86_64 was built without debug info"))
    #expect(!fm.fileExists(atPath: out.path))
}
