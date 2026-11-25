import Testing
import Foundation
@testable import XlessSign
@testable import XlessCore
import XlessMachO

func onPath(_ tool: String) -> Bool {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)")
    }
}

/// Smallest arm64 Mach-O that rcodesign accepts: a __TEXT segment with one section plus an empty __LINKEDIT.
func miniMachO(filetype: UInt32) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func name(_ s: String) { d.append(Data(s.utf8)); d.append(Data(count: 16 - s.utf8.count)) }
    let cmdsSize: UInt32 = (72 + 80) + 72
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(filetype); u32(2); u32(cmdsSize); u32(0); u32(0)
    u32(0x19); u32(72 + 80); name("__TEXT"); u64(0); u64(0x4000); u64(0); u64(0x4000); u32(5); u32(5); u32(1); u32(0)
    name("__text"); name("__TEXT"); u64(0x1000); u64(4); u32(0x1000); u32(2); u32(0); u32(0); u32(0x80000400); u32(0); u32(0); u32(0)
    u32(0x19); u32(72); name("__LINKEDIT"); u64(0x4000); u64(0x4000); u64(0x4000); u64(0); u32(1); u32(1); u32(0); u32(0)
    d.append(Data(count: 0x4000 - d.count))
    return d
}

@Test(.enabled(if: onPath("rcodesign"))) func rcodesignSignsNestedFrameworks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("X.app", isDirectory: true)
    let fw = app.appendingPathComponent("Frameworks/x.framework", isDirectory: true)
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": "a.b"], to: app.appendingPathComponent("Info.plist"), stage: .sign)
    try Plist.write(["CFBundleExecutable": "x", "CFBundleIdentifier": "a.b.x"], to: fw.appendingPathComponent("Info.plist"), stage: .sign)
    try miniMachO(filetype: 2).write(to: app.appendingPathComponent("X"))
    try miniMachO(filetype: 6).write(to: fw.appendingPathComponent("x"))

    let key = try SigningKey.generate()
    let der = try selfSigned(key)
    let keyURL = root.appendingPathComponent("key.pem"), certURL = root.appendingPathComponent("cert.pem"), entURL = root.appendingPathComponent("ent.plist")
    try key.pem.write(to: keyURL, atomically: true, encoding: .utf8)
    try "-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        .write(to: certURL, atomically: true, encoding: .utf8)
    try Plist.write([String: Any](), to: entURL, format: .xml, stage: .sign)

    try Shell.run("rcodesign", RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: .appStore), stage: .sign)
    try Shell.run("rcodesign", ["verify", app.appendingPathComponent("X").path], stage: .sign)
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
    #expect(FileManager.default.fileExists(atPath: fw.appendingPathComponent("_CodeSignature/CodeResources").path))
    try Shell.run("rcodesign", ["verify", fw.appendingPathComponent("x").path], stage: .sign)
}


/// Fat (cafebabe) wrapper with one arm64 slice that is an `ar` static archive, as shipped by the onnxruntime-c pod.
func fatWrappedArchive() -> Data {
    var slice = Data("!<arch>\n".utf8)
    slice.append(Data("x.o/            0           0     0     100644  4         `\nabcd".utf8))
    var d = Data()
    func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    be(0xcafebabe); be(1); be(0x0100000c); be(0); be(0x4000); be(UInt32(slice.count)); be(14)
    d.append(Data(count: 0x4000 - d.count)); d.append(slice)
    return d
}

@Test(.enabled(if: onPath("rcodesign"))) func rcodesignSignsFrameworkWithStaticArchiveExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("X.app", isDirectory: true)
    let fw = app.appendingPathComponent("Frameworks/x.framework", isDirectory: true)
    try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": "a.b"], to: app.appendingPathComponent("Info.plist"), stage: .sign)
    try Plist.write(["CFBundleExecutable": "x", "CFBundleIdentifier": "a.b.x"], to: fw.appendingPathComponent("Info.plist"), stage: .sign)
    try miniMachO(filetype: 2).write(to: app.appendingPathComponent("X"))
    try fatWrappedArchive().write(to: fw.appendingPathComponent("x"))

    let key = try SigningKey.generate()
    let der = try selfSigned(key)
    let keyURL = root.appendingPathComponent("key.pem"), certURL = root.appendingPathComponent("cert.pem"), entURL = root.appendingPathComponent("ent.plist")
    try key.pem.write(to: keyURL, atomically: true, encoding: .utf8)
    try "-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        .write(to: certURL, atomically: true, encoding: .utf8)
    try Plist.write([String: Any](), to: entURL, format: .xml, stage: .sign)

    // Known rcodesign 0.29.0 limitation: signing the framework panics ("index out of bounds" in macho_signing.rs) when its
    // executable is a fat-wrapped `ar` archive. withKnownIssue fails this test once rcodesign signs it, so the gap is revisited.
    withKnownIssue {
        try Shell.run("rcodesign", RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: .appStore), stage: .sign)
    }
}

/// A Developer ID (hardened runtime) sign of a macOS app with a dynamic library in Contents/Resources (a Tauri
/// `bundle.resources` Mach-O, ruling R4): the app verifies, and the library carries its own signature with the runtime flag
/// (rcodesign signs it as a loose Mach-O, but its unscoped --code-signature-flags reaches only the main executable).
@Test(.enabled(if: onPath("rcodesign"))) func rcodesignSignsResourcesMachOWithHardenedRuntime() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("resources-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("X.app", isDirectory: true), contents = app.appendingPathComponent("Contents")
    for d in ["MacOS", "Resources/lib"] { try FileManager.default.createDirectory(at: contents.appendingPathComponent(d), withIntermediateDirectories: true) }
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": "a.b", "CFBundlePackageType": "APPL"], to: contents.appendingPathComponent("Info.plist"), stage: .sign)
    try miniMachO(filetype: 2).write(to: contents.appendingPathComponent("MacOS/X"))
    // Universal, as merged from the per-target copies: an arm64 and an x86_64 slice.
    let dylib = contents.appendingPathComponent("Resources/lib/lib.dylib")
    var x86 = miniMachO(filetype: 6)
    x86.replaceSubrange(4..<8, with: [0x07, 0x00, 0x00, 0x01])
    try MachO.makeFat([x86, miniMachO(filetype: 6)]).write(to: dylib)
    try Data("text".utf8).write(to: contents.appendingPathComponent("Resources/lib/notes.txt"))

    let key = try SigningKey.generate()
    let der = try selfSigned(key)
    let keyURL = root.appendingPathComponent("key.pem"), certURL = root.appendingPathComponent("cert.pem"), entURL = root.appendingPathComponent("ent.plist")
    try key.pem.write(to: keyURL, atomically: true, encoding: .utf8)
    try "-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        .write(to: certURL, atomically: true, encoding: .utf8)
    try Plist.write([String: Any](), to: entURL, format: .xml, stage: .sign)

    // xless's Developer ID arguments, minus --for-notarization (it refuses a self-signed certificate) and with no timestamp
    // server (no network in tests).
    let nested = try RCodesign.hardenedRuntimePaths(in: app, mainExecutable: "Contents/MacOS/X")
    #expect(nested == ["Contents/Resources/lib/lib.dylib"])
    var args = RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: .developerID, runtimePaths: nested)
    #expect(args.contains("--for-notarization") && args.contains("runtime"))
    args.removeAll { $0 == "--for-notarization" }
    args.insert(contentsOf: ["--timestamp-url", "none"], at: args.count - 1)
    try Shell.run("rcodesign", args, stage: .sign)
    try Shell.run("rcodesign", ["verify", contents.appendingPathComponent("MacOS/X").path], stage: .sign)
    try Shell.run("rcodesign", ["verify", dylib.path], stage: .sign)
    let info = try Shell.run("rcodesign", ["print-signature-info", dylib.path], stage: .sign).stdout
    #expect(info.components(separatedBy: "flags: CodeSignatureFlags(RUNTIME)").count - 1 >= 2, "\(info)")   // both slices
    #expect(!info.contains("flags: CodeSignatureFlags(0x0)"), "\(info)")
    let main = try Shell.run("rcodesign", ["print-signature-info", contents.appendingPathComponent("MacOS/X").path], stage: .sign).stdout
    #expect(main.contains("CodeSignatureFlags(RUNTIME)"))
    let resources = try String(contentsOf: contents.appendingPathComponent("_CodeSignature/CodeResources"), encoding: .utf8)
    #expect(resources.contains("Resources/lib/lib.dylib"))
}

/// A Developer ID sign of a macOS app embedding a dynamic framework (Tauri bundle.macOS.frameworks) in the versioned
/// layout (Versions/A + Current symlinks): the framework's binary carries the hardened runtime too.
@Test(.enabled(if: onPath("rcodesign"))) func rcodesignSignsEmbeddedFrameworkWithHardenedRuntime() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("framework-\(UUID())", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let app = root.appendingPathComponent("X.app", isDirectory: true), contents = app.appendingPathComponent("Contents")
    let fw = contents.appendingPathComponent("Frameworks/Y.framework"), versionA = fw.appendingPathComponent("Versions/A")
    for d in ["MacOS", "Frameworks/Y.framework/Versions/A/Resources"] { try fm.createDirectory(at: contents.appendingPathComponent(d), withIntermediateDirectories: true) }
    try Plist.write(["CFBundleExecutable": "X", "CFBundleIdentifier": "a.b", "CFBundlePackageType": "APPL"], to: contents.appendingPathComponent("Info.plist"), stage: .sign)
    try miniMachO(filetype: 2).write(to: contents.appendingPathComponent("MacOS/X"))
    try Plist.write(["CFBundleExecutable": "Y", "CFBundleIdentifier": "a.b.y", "CFBundlePackageType": "FMWK"], to: versionA.appendingPathComponent("Resources/Info.plist"), stage: .sign)
    try miniMachO(filetype: 6).write(to: versionA.appendingPathComponent("Y"))
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Y").path, withDestinationPath: "Versions/Current/Y")
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")

    let key = try SigningKey.generate()
    let der = try selfSigned(key)
    let keyURL = root.appendingPathComponent("key.pem"), certURL = root.appendingPathComponent("cert.pem"), entURL = root.appendingPathComponent("ent.plist")
    try key.pem.write(to: keyURL, atomically: true, encoding: .utf8)
    try "-----BEGIN CERTIFICATE-----\n\(Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        .write(to: certURL, atomically: true, encoding: .utf8)
    try Plist.write([String: Any](), to: entURL, format: .xml, stage: .sign)

    let paths = try RCodesign.hardenedRuntimePaths(in: app, mainExecutable: "Contents/MacOS/X")
    #expect(paths == ["Contents/Frameworks/Y.framework/Versions/A/Y"])
    var args = RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: .developerID, runtimePaths: paths)
    args.removeAll { $0 == "--for-notarization" }   // needs an Apple-issued certificate
    args.insert(contentsOf: ["--timestamp-url", "none"], at: args.count - 1)
    try Shell.run("rcodesign", args, stage: .sign)
    try Shell.run("rcodesign", ["verify", versionA.appendingPathComponent("Y").path], stage: .sign)
    #expect(fm.fileExists(atPath: versionA.appendingPathComponent("_CodeSignature/CodeResources").path))
    let info = try Shell.run("rcodesign", ["print-signature-info", versionA.appendingPathComponent("Y").path], stage: .sign).stdout
    #expect(info.contains("flags: CodeSignatureFlags(RUNTIME)") && !info.contains("flags: CodeSignatureFlags(0x0)"), "\(info)")
}
