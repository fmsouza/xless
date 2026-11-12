import Testing
import Foundation
@testable import XlessBuild
@testable import XlessMachO
import XlessCore

/// A thin arm64 executable with LC_UUID (16 times `uuid`) and, with `objects`, a symbol table whose N_OSO stabs name
/// them: the debug map a build with debug info leaves.
private func executable(uuid: UInt8, objects: [String] = []) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    var strings = Data([0x20, 0]), nlist = Data()
    for o in objects {
        withUnsafeBytes(of: UInt32(strings.count).littleEndian) { nlist.append(contentsOf: $0) }
        nlist.append(contentsOf: [0x66, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
        strings.append(contentsOf: Array(o.utf8) + [0])
    }
    let tables = 32 + 24 + 24
    u32(0xfeedfacf); u32(0x0100000c); u32(0); u32(2); u32(2); u32(48); u32(0); u32(0)
    u32(0x1b); u32(24); d.append(Data(repeating: uuid, count: 16))
    u32(0x2); u32(24); u32(UInt32(tables)); u32(UInt32(objects.count)); u32(UInt32(tables + nlist.count)); u32(UInt32(strings.count))
    d.append(nlist); d.append(strings)
    return d
}

private var fm: FileManager { .default }

/// What `xtool dev build` leaves: `xtool/<Product>.app` with the executable, and Swift Build's products under the
/// project's `.build`.
private func project() throws -> (root: URL, app: URL) {
    // Resolved with realpath: FileManager lists entries of macOS's temporary directory under `/private/var`, not the
    // `/var` link (and `resolvingSymlinksInPath()` would strip `/private` again).
    let tmp = fm.temporaryDirectory.path
    let real = realpath(tmp, nil).map { defer { free($0) }; return String(cString: $0) } ?? tmp
    let root = URL(fileURLWithPath: real, isDirectory: true).appendingPathComponent("xtool-\(UUID().uuidString)", isDirectory: true)
    let app = root.appendingPathComponent("xless-build/Hello.app", isDirectory: true)
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Hello"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Info.plist"))
    return (root, app)
}

private func dSYM(_ bundle: URL, uuid: UInt8) throws {
    let dwarf = bundle.appendingPathComponent("Contents/Resources/DWARF")
    try fm.createDirectory(at: dwarf, withIntermediateDirectories: true)
    try executable(uuid: uuid).write(to: dwarf.appendingPathComponent(bundle.deletingPathExtension().lastPathComponent))
}

@Suite struct IOSBuilderDSYMTests {
    /// Swift Build (xtool's build system from Swift 6.4) runs dsymutil itself: its `<target>.dSYM` with the UUID of the
    /// app's executable is the one.
    @Test func swiftBuildsDSYMOfTheAppsExecutableIsUsed() throws {
        let (root, app) = try project(); defer { try? fm.removeItem(at: root) }
        try executable(uuid: 0x11, objects: ["/p/.build/out/x.o"]).write(to: app.appendingPathComponent("Hello"))
        let products = root.appendingPathComponent(".build/out/Products/Release-iphoneos")
        try dSYM(products.appendingPathComponent("Old-App.dSYM"), uuid: 0x22)
        try dSYM(products.appendingPathComponent("Hello-App.dSYM"), uuid: 0x11)
        var ran = false
        let source = IOSBuilder.dSYM(of: app, project: root) { _, _ in ran = true }
        #expect(source == .found(products.appendingPathComponent("Hello-App.dSYM")))
        #expect(!ran)
    }

    /// No dSYM from the build (SwiftPM's native build system, before Swift 6.4), but a debug map: dsymutil on the
    /// executable, while the build's objects are still there.
    @Test func withoutOneDsymutilMakesItFromTheDebugMap() throws {
        let (root, app) = try project(); defer { try? fm.removeItem(at: root) }
        try executable(uuid: 0x11, objects: ["/p/.build/arm64-apple-ios/release/x.o"]).write(to: app.appendingPathComponent("Hello"))
        var calls: [(URL, URL)] = []
        let source = IOSBuilder.dSYM(of: app, project: root) { exe, out in
            calls.append((exe, out))
            try dSYM(out, uuid: 0x11)
        }
        let made = root.appendingPathComponent(".xless/dsym/ios/Hello.dSYM")
        #expect(calls.map(\.0) == [app.appendingPathComponent("Hello")])
        #expect(calls.map(\.1) == [made])
        #expect(source == .found(made))
    }

    @Test func noDebugMapNoDSYM() throws {
        let (root, app) = try project(); defer { try? fm.removeItem(at: root) }
        try executable(uuid: 0x11).write(to: app.appendingPathComponent("Hello"))
        let source = IOSBuilder.dSYM(of: app, project: root) { _, _ in Issue.record("ran dsymutil") }
        guard case .missing(let reason) = source else { Issue.record("found a dSYM"); return }
        #expect(reason.contains("no debug map"))
    }

    @Test func dsymutilThatWritesNothingIsReported() throws {
        let (root, app) = try project(); defer { try? fm.removeItem(at: root) }
        try executable(uuid: 0x11, objects: ["/p/x.o"]).write(to: app.appendingPathComponent("Hello"))
        let source = IOSBuilder.dSYM(of: app, project: root) { _, _ in }
        guard case .missing(let reason) = source else { Issue.record("found a dSYM"); return }
        #expect(reason.contains("dsymutil"))
    }

    /// A missing or failing dsymutil, or an app without its executable, is the reason there is no dSYM, not a failed build.
    @Test func failuresAreReasonsNotErrors() throws {
        let (root, app) = try project(); defer { try? fm.removeItem(at: root) }
        guard case .missing = IOSBuilder.dSYM(of: app, project: root, dsymutil: { _, _ in }) else { Issue.record("found a dSYM"); return }
        try executable(uuid: 0x11, objects: ["/p/x.o"]).write(to: app.appendingPathComponent("Hello"))
        let source = IOSBuilder.dSYM(of: app, project: root) { _, _ in
            throw XlessError(.build, "the SDK's toolset has no dsymutil (/sdk/toolset/bin/dsymutil)", fix: "reinstall the SDK")
        }
        #expect(source == .missing("the SDK's toolset has no dsymutil (/sdk/toolset/bin/dsymutil)"))
    }
}
