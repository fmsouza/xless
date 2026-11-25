import Foundation
import Testing
@testable import XlessBuild
@testable import XlessCore
import XlessMachO

private let yaml = """
bundleID: app.example.helloship
teamID: ABCDE12345
version: 1.2.3
build: 7
platforms:
  ios: { minimumOS: "17.0", product: HelloShip }
  macos: { minimumOS: "14.0", product: HelloShip, distribution: developer-id }
"""

/// A thin Mach-O executable (arm64's) that loads `libraries`.
private func image(loading libraries: [String], runPaths: [String] = [], uuid: UInt8? = nil, cpu: UInt32 = 0x0100000c) -> Data {
    func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    var commands = Data()
    for name in libraries {
        var text = Data(name.utf8) + [0]
        while (24 + text.count) % 8 != 0 { text.append(0) }
        commands += u32(0xc) + u32(UInt32(24 + text.count)) + u32(24) + u32(0) + u32(0) + u32(0) + text
    }
    for path in runPaths {
        var text = Data(path.utf8) + [0]
        while (12 + text.count) % 8 != 0 { text.append(0) }
        commands += u32(0x8000001c) + u32(UInt32(12 + text.count)) + u32(12) + text
    }
    if let uuid { commands += u32(0x1b) + u32(24) + Data(repeating: uuid, count: 16) }
    let count = libraries.count + runPaths.count + (uuid == nil ? 0 : 1)
    return u32(0xfeedfacf) + u32(cpu) + u32(0) + u32(2) + u32(UInt32(count)) + u32(UInt32(commands.count)) + u32(0) + u32(0) + commands
}

private func temporary() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-xcpkg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func theXcodeWrapperPackageLinksTheAppsLibrary() {
    let ios = XcodePackageBuilder.wrapperPackage(product: "HelloShip", minimumOS: "17.0", platform: .ios)
    #expect(ios.contains(#"platforms: [.iOS("17.0")]"#) && ios.contains(#".executableTarget(name: "HelloShipApp""#))
    #expect(ios.contains(#".package(name: "RootPackage", path: "../..")"#) && ios.contains(#""@executable_path/Frameworks""#))
    let mac = XcodePackageBuilder.wrapperPackage(product: "HelloShip", minimumOS: "14.0", platform: .macos)
    #expect(mac.contains(#"platforms: [.macOS("14.0")]"#) && mac.contains(#""@executable_path/../Frameworks""#))
}

@Test func theAppsPackageResolvedIsWhatItIsBuiltWith() throws {
    let project = try temporary(), wrapper = project.appendingPathComponent(".xless/xcode-pkg-ios"), fm = FileManager.default
    defer { try? fm.removeItem(at: project) }
    func write() throws { try XcodePackageBuilder.writeWrapper(wrapper, project: project, product: "X", minimumOS: "17.0", platform: .ios) }
    func resolved(_ pins: [(String, String)]) -> String {
        "{\"pins\":[" + pins.map { "{\"identity\":\"\($0.0)\",\"state\":{\"revision\":\"r\($0.1)\",\"version\":\"\($0.1)\"}}" }.joined(separator: ",") + "],\"version\":3}"
    }
    let own = project.appendingPathComponent("Package.resolved"), built = wrapper.appendingPathComponent("Package.resolved")
    try write()
    #expect(fm.fileExists(atPath: wrapper.path + "/Package.swift") && fm.fileExists(atPath: wrapper.path + "/Sources/XApp/stub.c") && !fm.fileExists(atPath: built.path))
    #expect(PackageResolved.unpinnedNote(project: project, wrapper: wrapper) == nil) // no packages
    try resolved([("dep", "1.1.0")]).write(to: built, atomically: true, encoding: .utf8)
    #expect(PackageResolved.unpinnedNote(project: project, wrapper: wrapper)?.hasPrefix("the project has no Package.resolved, which would hold these packages to a version: dep 1.1.0 (") == true)

    try resolved([("dep", "1.0.0")]).write(to: own, atomically: true, encoding: .utf8)
    try write()
    #expect(try Data(contentsOf: built) == Data(contentsOf: own))
    #expect(PackageResolved.unpinnedNote(project: project, wrapper: wrapper) == nil)
    try resolved([("new", "2.0.0"), ("dep", "1.0.0")]).write(to: built, atomically: true, encoding: .utf8)
    #expect(PackageResolved.unpinnedNote(project: project, wrapper: wrapper)?.hasPrefix("Package.resolved does not name these, which were built: new 2.0.0 (") == true)
    try resolved([("dep", "1.1.0")]).write(to: built, atomically: true, encoding: .utf8)
    #expect(PackageResolved.unpinnedNote(project: project, wrapper: wrapper)?.contains("dep 1.1.0") == true)

    try fm.removeItem(at: own)
    try fm.createDirectory(at: own, withIntermediateDirectories: false)
    #expect(throws: XlessError.self) { try write() } // not built without it
}

@Test func swiftBuildOfXcodesKeepsItsSandboxAndLeavesTheKeychain() {
    let w = URL(fileURLWithPath: "/p/w"), s = URL(fileURLWithPath: "/p/s")
    let base = ["build", "--package-path", "/p/w", "--scratch-path", "/p/s", "-c", "release", "--build-system", "swiftbuild", "--disable-keychain", "--product", "XApp"]
    func arguments(_ d: XcodePackageBuilder.Destination) -> [String] { XcodePackageBuilder.arguments(d, wrapper: w, scratch: s, product: "X", minimumOS: "17.0") }
    #expect(arguments(.device) == base + ["--triple", "arm64-apple-ios17.0"])
    #expect(arguments(.simulator) == base + ["--triple", "arm64-apple-ios17.0-simulator"])
    #expect(arguments(.mac) == base + ["--arch", "arm64", "--arch", "x86_64"])
    for d in [XcodePackageBuilder.Destination.device, .simulator, .mac] { #expect(!arguments(d).contains("--disable-sandbox")) }
}

@Test func onlyTheSystemsAndTheAppsOwnRunPathsStay() {
    #expect(XcodePackageBuilder.isForeign("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/iphoneos"))
    #expect(XcodePackageBuilder.isForeign("/var/run/com.apple.security.cryptexd/mnt/x"))
    for path in ["/usr/lib/swift", "@loader_path", "@executable_path/Frameworks"] { #expect(!XcodePackageBuilder.isForeign(path)) }
    // of a library in Frameworks, only what names this Mac's Xcode
    let xcode = InstalledXcode(app: URL(fileURLWithPath: "/Applications/Xcode.app"), version: "27.2", build: "27B52", source: "-")
    for path in ["/Applications/Xcode.app/Contents/Developer/x", "/var/run/com.apple.security.cryptexd/mnt/x"] { #expect(XcodePackageBuilder.isOfXcode(path, xcode)) }
    for path in ["/Applications/Xcode.app.other/x", "/vendor/lib", "/usr/lib/swift", "@loader_path"] { #expect(!XcodePackageBuilder.isOfXcode(path, xcode)) }
}

@Test func aRunPathOfOneArchitectureIsTakenOutOfThatOneOnly() throws {
    let dir = try temporary(), library = dir.appendingPathComponent("V")
    defer { try? FileManager.default.removeItem(at: dir) }
    func slices(_ paths: [[String]]) throws -> Data { try MachO.makeFat([image(loading: [], runPaths: paths[0]), image(loading: [], runPaths: paths[1], cpu: 0x01000007)]) }
    var calls: [[String]] = []
    /// As `install_name_tool`: an image in which a path is not in each architecture is an error.
    func delete(_ paths: [String], _ file: URL) throws {
        calls.append(paths)
        let data = try Data(contentsOf: file)
        let left = try MachO.sliceArchitectures(in: data).map { slice in
            let has = try MachO.rpaths(in: data, slice: slice.range)
            for path in paths where !has.contains(path) { throw XlessError(.build, "no LC_RPATH load command with path: \(path)", fix: "-") }
            return image(loading: [], runPaths: has.filter { !paths.contains($0) }, cpu: UInt32(bitPattern: slice.cpuType))
        }
        try (left.count == 1 ? left[0] : MachO.makeFat(left)).write(to: file)
    }
    for (paths, kept, expected) in [
        ([["/x", "/y", "@a"], ["@b"]], [["@a"], ["@b"]], [["/x", "/y"]]),
        ([["/x", "@a"], ["/y", "/x"]], [["@a"], []], [["/x"], ["/x", "/y"]]),
        ([["/x", "@a"], ["@b", "/x"]], [["@a"], ["@b"]], [["/x"]]), // the same of both: at once
        ([["@a"], []], [["@a"], []], []),
    ] as [([[String]], [[String]], [[String]])] {
        calls = []
        try slices(paths).write(to: library)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.path)
        try XcodePackageBuilder.removeRunPaths(of: library, where: { $0.hasPrefix("/") }) { paths, file in
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try delete(paths, file)
        }
        let left = try Data(contentsOf: library), want = try slices(kept)
        #expect(calls == expected && left == want, "\(paths)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["V"] && FileManager.default.isExecutableFile(atPath: library.path))
        try FileManager.default.removeItem(at: library)
    }
}

@Test func theDSYMOfALibraryIsKeptOnlyWhenItIsOfThatBuild() throws {
    let products = try temporary(), item = products.appendingPathComponent("PackageFrameworks/B.framework")
    defer { try? FileManager.default.removeItem(at: products) }
    func write(_ path: String, uuid: UInt8?) throws {
        let url = products.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image(loading: [], uuid: uuid).write(to: url)
    }
    func dSYM() -> String? { XcodePackageBuilder.dSYM(ofLibrary: "B.framework/B", item: item, products: products)?.lastPathComponent }
    try write("PackageFrameworks/B.framework/B", uuid: 1)
    #expect(dSYM() == nil)
    try write("B.framework.dSYM/Contents/Resources/DWARF/B", uuid: 1)
    #expect(dSYM() == "B.framework.dSYM")
    try write("B.framework.dSYM/Contents/Resources/DWARF/B", uuid: 2)
    #expect(dSYM() == nil)
    try write("B.framework.dSYM/Contents/Resources/DWARF/B", uuid: nil)
    try write("PackageFrameworks/B.framework/B", uuid: nil)
    #expect(dSYM() == nil)
}

@Test func theFrameworksAnAppLoadsAreEmbeddedWithWhatTheyLoad() throws {
    let products = try temporary()
    defer { try? FileManager.default.removeItem(at: products) }
    func write(_ path: String, _ libraries: [String]) throws -> URL {
        let url = products.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image(loading: libraries).write(to: url)
        return url
    }
    let exe = try write("XApp", ["/usr/lib/libSystem.B.dylib", "@rpath/A.framework/A", "@rpath/libC.dylib"])
    _ = try write("A.framework/A", ["@rpath/B.framework/Versions/A/B", "@rpath/A.framework/A"])
    _ = try write("PackageFrameworks/B.framework/Versions/A/B", [])
    _ = try write("libC.dylib", [])
    _ = try write("Unused.framework/Unused", [])
    #expect(try XcodePackageBuilder.embedded(exe, products: products).map(\.item.lastPathComponent).sorted() == ["A.framework", "B.framework", "libC.dylib"])

    #expect(try XcodePackageBuilder.embedded(exe, products: products).map(\.library).sorted() == ["A.framework/A", "B.framework/Versions/A/B", "libC.dylib"])

    for library in ["", "/", "/A", "../A.framework/A", "./libC.dylib", "A.framework//A", "A.framework/../libC.dylib", "..", "libC.dylib/"] {
        let bad = try write("Bad", ["@rpath/\(library)"])
        do {
            _ = try XcodePackageBuilder.embedded(bad, products: products)
            Issue.record("not refused: \(library)")
        } catch let e as XlessError { #expect(e.cause == "Bad loads @rpath/\(library), which is no place in the app") }
    }
    for (library, fix) in [("libswift_Concurrency.dylib", "minimumOS"), ("Gone.framework/Gone", "binaryTarget")] {
        let bad = try write("Bad", ["@rpath/\(library)"])
        do {
            _ = try XcodePackageBuilder.embedded(bad, products: products)
            Issue.record("not refused")
        } catch let e as XlessError { #expect(e.cause.contains("@rpath/\(library)") && e.fix.contains(fix)) }
    }
}

@Test func anIOSAppIsAssembledFlat() throws {
    let dir = try temporary()
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = try ProjectConfig.parse(yaml: yaml + "\nprivacyManifest: P.xcprivacy\ninfoPlist: I.plist\n")
    try Data("<plist/>".utf8).write(to: dir.appendingPathComponent("P.xcprivacy"))
    try Plist.write(["UIDeviceFamily": [1], "Own": "x"], to: dir.appendingPathComponent("I.plist"), stage: .build)
    let resources = dir.appendingPathComponent("Pkg_Target.bundle"), framework = dir.appendingPathComponent("A.framework")
    for made in [resources, framework] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
    let app = try PackageApp.assemble(in: dir.appendingPathComponent("out"), executable: Data("exe".utf8), resources: [resources], frameworks: [framework],
                                      project: dir, config: config, platform: .ios)
    #expect(app.lastPathComponent == "HelloShip.app")
    #expect(try FileManager.default.contentsOfDirectory(atPath: app.path).sorted() == ["Frameworks", "HelloShip", "Info.plist", "PkgInfo", "Pkg_Target.bundle", "PrivacyInfo.xcprivacy"])
    #expect(FileManager.default.isExecutableFile(atPath: app.path + "/HelloShip"))
    let info = try Plist.read(app.appendingPathComponent("Info.plist"), stage: .build)
    #expect(info["CFBundleIdentifier"] as? String == "app.example.helloship" && info["CFBundleExecutable"] as? String == "HelloShip")
    #expect(info["LSRequiresIPhoneOS"] as? Bool == true && info["MinimumOSVersion"] as? String == "17.0" && info["UILaunchScreen"] != nil)
    #expect(info["UIDeviceFamily"] as? [Int] == [1] && info["Own"] as? String == "x")
}

@Test func aMacAppIsAssembledInContents() throws {
    let dir = try temporary()
    defer { try? FileManager.default.removeItem(at: dir) }
    let app = try PackageApp.assemble(in: dir, executable: Data("exe".utf8), resources: [], project: dir, config: ProjectConfig.parse(yaml: yaml), platform: .macos)
    #expect(try FileManager.default.contentsOfDirectory(atPath: app.path + "/Contents").sorted() == ["Info.plist", "MacOS", "PkgInfo", "Resources"])
    #expect(FileManager.default.isExecutableFile(atPath: app.path + "/Contents/MacOS/HelloShip"))
}
