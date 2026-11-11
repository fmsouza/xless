import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore
import XlessMachO

private var fm: FileManager { .default }

/// The repository root (Tests/XlessTauriTests/<this file> → ../..).
private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func write(_ text: String, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func scratch(_ tag: String) -> URL {
    fm.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
}

/// samples/HelloTauri resolved for macOS as `xless ship --config … --platform macos` does, with the cargo binary name
/// (`hello-tauri`) that `buildMac` learns from `cargo metadata`.
private func helloTauriMac() throws -> ResolvedTauriMac {
    let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.hellotauri\nteamID: ABCDE12345\n", name: "hello")
    var r = try TauriProject.resolveMac(overlay: overlay, source: repo.appendingPathComponent("samples/HelloTauri"))
    r.mainBinaryName = r.mainBinaryName ?? "hello-tauri"
    return r
}

/// A desktop Tauri app with `conf` as tauri.conf.json (merged over a minimal base).
private func resolvedMac(_ bundle: String, extraTop: String = "", overlayExtra: String = "") throws -> (ResolvedTauriMac, URL) {
    let root = scratch("macapp"), dir = root.appendingPathComponent("src-tauri")
    try write(#"{"productName":"Demo","version":"1.2.3","identifier":"com.example.demo"\#(extraTop),"bundle":\#(bundle)}"#, dir.appendingPathComponent("tauri.conf.json"))
    let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.demo\nteamID: ABCDE12345\n\(overlayExtra)", name: "demo")
    var r = try TauriProject.resolveMac(overlay: overlay, source: root)
    r.mainBinaryName = r.mainBinaryName ?? "demo"
    return (r, root)
}

/// A thin 64-bit Mach-O header (no load commands) for `cpu`, followed by `tag`.
private func thin(_ cpu: UInt32, _ tag: String = "") -> Data {
    var d = Data()
    for v: UInt32 in [0xfeedfacf, cpu, 0, 6, 0, 0, 0, 0] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    return d + Data(tag.utf8)
}
private let arm64: UInt32 = 0x0100000c, x86_64: UInt32 = 0x01000007

private func files(under dir: URL) -> [String] {
    let base = dir.standardizedFileURL.path
    return Files.regularFiles(under: dir).map { String($0.standardizedFileURL.path.dropFirst(base.count + 1)) }.sorted()
}

@Suite struct TauriMacInfoPlistTests {
    /// The generated Info.plist equals the reference's `infoPlist` section (rendered canonically; CFBundleVersion is
    /// volatile and not in the reference, DT* keys come from finalize and are not generated here).
    @Test func helloTauriMatchesTheMacReference() throws {
        let info = try TauriMacBundler.infoPlist(resolved: helloTauriMac(), workRoot: repo.appendingPathComponent("samples/HelloTauri"))
        let ref = try JSONDecoder().decode(BundleReport.self, from: Data(contentsOf: repo.appendingPathComponent("samples/HelloTauri/reference/macos/reference.json")))
        var rendered: [String: String] = [:]
        for (k, v) in info where !BundleReport.volatilePlistKeys.contains(k) { rendered[k] = BundleReport.canonical(v, top: true) }
        #expect(rendered == ref.infoPlist)
        #expect(info["CFBundleVersion"] as? String == "1.0.0")
    }

    /// tauri-bundler `category.rs`: input lower-cased, `public.app-category.` prefix, spaces and hyphens dropped, then
    /// looked up in the alias table.
    @Test(arguments: [
        ("DeveloperTool", "public.app-category.developer-tools"),
        ("Photography", "public.app-category.photography"),
        ("Utility", "public.app-category.utilities"),
        ("Graphics and Design", "public.app-category.graphics-design"),
        ("public.app-category.social-networking", "public.app-category.social-networking"),
        ("rpg", "public.app-category.role-playing-games"),
        ("Game", "public.app-category.games"),
    ])
    func categoryMapping(_ input: String, _ uti: String) throws {
        #expect(try TauriMacBundler.categoryType(input) == uti)
    }

    @Test func unknownCategoryIsABuildError() {
        do { _ = try TauriMacBundler.categoryType("Gardening"); Issue.record("accepted") } catch let e as XlessError {
            #expect(e.stage == .build && e.cause.contains("Gardening"))
        } catch { Issue.record("\(error)") }
    }

    /// `tauri_utils::config::file_associations_plist`: name defaults to the first extension, role Editor, rank Default;
    /// a leading dot is dropped; LSItemContentTypes = explicit contentTypes then the UTIs inferred from extensions.
    @Test func fileAssociationsWithoutContentTypes() throws {
        let plist = try TauriMacBundler.fileAssociationsPlist([["ext": ["hello"], "name": "Hello document", "role": "Editor"]])
        #expect(BundleReport.canonical(plist["CFBundleDocumentTypes"] as Any, top: true)
                == #"[{"CFBundleTypeExtensions":["hello"],"CFBundleTypeName":"Hello document","CFBundleTypeRole":"Editor","LSHandlerRank":"Default"}]"#)
        #expect(plist["UTExportedTypeDeclarations"] == nil)
        let bare = try TauriMacBundler.fileAssociationsPlist([["ext": [".txt"], "role": "Viewer", "rank": "Owner"]])
        #expect(BundleReport.canonical(bare["CFBundleDocumentTypes"] as Any, top: true)
                == #"[{"CFBundleTypeExtensions":["txt"],"CFBundleTypeName":"txt","CFBundleTypeRole":"Viewer","LSHandlerRank":"Owner","LSItemContentTypes":["public.plain-text"]}]"#)
    }

    @Test func fileAssociationsWithContentTypesAndExportedType() throws {
        let plist = try TauriMacBundler.fileAssociationsPlist([
            ["ext": ["png", "jpg", "jpeg"], "contentTypes": ["public.image"], "name": "Image"],
            ["ext": ["demo"], "description": "Demo file", "exportedType": ["identifier": "com.example.demo.doc", "conformsTo": ["public.data"]]],
        ])
        #expect(BundleReport.canonical(plist["CFBundleDocumentTypes"] as Any, top: true) == "["
                + #"{"CFBundleTypeExtensions":["png","jpg","jpeg"],"CFBundleTypeName":"Image","CFBundleTypeRole":"Editor","LSHandlerRank":"Default","LSItemContentTypes":["public.image","public.png","public.jpeg"]},"#
                + #"{"CFBundleTypeExtensions":["demo"],"CFBundleTypeName":"demo","CFBundleTypeRole":"Editor","LSHandlerRank":"Default","LSItemContentTypes":["com.example.demo.doc"]}]"#)
        #expect(BundleReport.canonical(plist["UTExportedTypeDeclarations"] as Any, top: true)
                == #"[{"UTTypeConformsTo":["public.data"],"UTTypeDescription":"Demo file","UTTypeIdentifier":"com.example.demo.doc","UTTypeTagSpecification":{"public.filename-extension":["demo"]}}]"#)
        #expect(try TauriMacBundler.fileAssociationsPlist(nil).isEmpty)
    }

    /// Optional bundle keys Tauri writes: bundleName, copyright, exceptionDomain; then Info.plist next to the config and
    /// bundle.macOS.infoPlist, merged over the generated keys. bundleVersion is not honoured: the overlay's `build:` is
    /// CFBundleVersion (stamped at finalize), so the generated value stays Tauri's default, the version.
    @Test func optionalKeysAndUserPlistMerge() throws {
        let (r, root) = try resolvedMac(#"{"icon":["icons/icon.icns"],"copyright":"(c) Demo","macOS":{"bundleName":"DemoApp","bundleVersion":"42","exceptionDomain":"localhost","infoPlist":"extra.plist"}}"#)
        try Plist.write(["NSCameraUsageDescription": "camera", "CFBundleName": "FromInfo"], to: root.appendingPathComponent("src-tauri/Info.plist"), stage: .build)
        try Plist.write(["NSMicrophoneUsageDescription": "mic"], to: root.appendingPathComponent("src-tauri/extra.plist"), stage: .build)
        let info = try TauriMacBundler.infoPlist(resolved: r, workRoot: root)
        #expect(info["CFBundleName"] as? String == "FromInfo")
        #expect(info["CFBundleVersion"] as? String == "1.2.3")
        #expect(info["NSHumanReadableCopyright"] as? String == "(c) Demo")
        #expect(info["NSCameraUsageDescription"] as? String == "camera")
        #expect(info["NSMicrophoneUsageDescription"] as? String == "mic")
        #expect(info["LSMinimumSystemVersion"] as? String == "10.13")
        #expect(BundleReport.canonical(info["NSAppTransportSecurity"] as Any, top: true)
                == #"{"NSExceptionDomains":{"localhost":{"NSExceptionAllowsInsecureHTTPLoads":true,"NSIncludesSubdomains":true}}}"#)
        #expect(info["LSApplicationCategoryType"] == nil)
    }
}

extension TauriMacInfoPlistTests {
    /// The overlay's `macos.infoPlist` is merged last, after an inline `bundle.macOS.infoPlist`.
    @Test func overlayInfoPlistMergesLast() throws {
        let extra = scratch("overlay-plist").appendingPathComponent("Info.plist")
        try fm.createDirectory(at: extra.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Plist.write(["NSCameraUsageDescription": "from overlay"], to: extra, stage: .build)
        let (r, root) = try resolvedMac(#"{"icon":["icons/icon.icns"],"macOS":{"infoPlist":{"NSCameraUsageDescription":"inline","NSMicrophoneUsageDescription":"inline"}}}"#,
                                        overlayExtra: "macos: { infoPlist: \(extra.path) }\n")
        let info = try TauriMacBundler.infoPlist(resolved: r, workRoot: root)
        #expect(info["NSCameraUsageDescription"] as? String == "from overlay")
        #expect(info["NSMicrophoneUsageDescription"] as? String == "inline")
    }

    /// The executable name becomes `Contents/MacOS/<name>`: anything but one plain file name is a build error.
    @Test(arguments: ["../evil", "a/b", ".", "..", ""])
    func unsafeExecutableNameIsABuildError(_ name: String) throws {
        var (r, root) = try resolvedMac(#"{"icon":["icons/icon.icns"]}"#)
        r.mainBinaryName = name
        do { _ = try TauriMacBundler.infoPlist(resolved: r, workRoot: root); Issue.record("accepted '\(name)'") } catch let e as XlessError {
            #expect(e.stage == .build && e.cause.contains("is not a single file name"))
        }
    }

    /// A merged Info.plist's CFBundleExecutable is checked too.
    @Test func unsafeExecutableNameFromAMergedPlistIsABuildError() throws {
        let (r, root) = try resolvedMac(#"{"icon":["icons/icon.icns"],"macOS":{"infoPlist":{"CFBundleExecutable":"../../x"}}}"#)
        #expect(throws: XlessError.self) { try TauriMacBundler.infoPlist(resolved: r, workRoot: root) }
        #expect(TauriMacBundler.isFileName("hello-tauri") && TauriMacBundler.isFileName("Hello Tauri"))
    }

    /// The top-level `infoPlist` is the iOS target's (Xcode placeholders, UIKit keys); none of it reaches the macOS plist.
    @Test func topLevelInfoPlistStaysOutOfTheMacPlist() throws {
        let ios = scratch("ios-plist").appendingPathComponent("Info.plist")
        try fm.createDirectory(at: ios.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Plist.write(["CFBundleExecutable": "$(EXECUTABLE_NAME)", "UILaunchStoryboardName": "LaunchScreen"], to: ios, stage: .build)
        let (r, root) = try resolvedMac(#"{"icon":["icons/icon.icns"]}"#, overlayExtra: "infoPlist: \(ios.path)\n")
        #expect(r.config.infoPlist == nil)
        let info = try TauriMacBundler.infoPlist(resolved: r, workRoot: root)
        #expect(info["CFBundleExecutable"] as? String == "demo")
        #expect(info["UILaunchStoryboardName"] == nil)
    }

    /// A reversed range in a glob bracket (`[z-a]`) matches nothing instead of trapping.
    @Test func reversedBracketRangeMatchesNothing() {
        #expect(!TauriMacBundler.wildcard(Array("[z-a].txt"), Array("m.txt")))
        #expect(TauriMacBundler.wildcard(Array("[a-z].txt"), Array("m.txt")))
        #expect(TauriMacBundler.wildcard(Array("[!z-a].txt"), Array("m.txt")))
    }
}

@Suite struct TauriMacResourceTests {
    private func tauriDir() throws -> URL {
        let root = scratch("resources"), dir = root.appendingPathComponent("app/src-tauri")
        for f in ["resources/a.txt", "resources/sub/b.txt", "resources/.hidden/c.txt", "data/x.json", "data/y.json", "data/z.txt",
                  "single.txt", "./dot/d.txt"] {
            try write(f, dir.appendingPathComponent(f))
        }
        try write("shared", root.appendingPathComponent("app/shared/s.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        return dir
    }

    private func pairs(_ m: [(source: URL, target: String)], _ dir: URL) -> [String] {
        m.map { "\($0.source.standardizedFileURL.path.replacingOccurrences(of: dir.deletingLastPathComponent().standardizedFileURL.path + "/", with: "")) -> \($0.target)" }
    }

    /// String entries keep their path relative to the Tauri dir; directories are walked (dot files included), `..` → `_up_`,
    /// `.` is dropped, globs expand (files only, sorted); an empty directory adds nothing.
    @Test func stringEntries() throws {
        let dir = try tauriDir()
        let m = try TauriMacBundler.resourceMappings(resources: ["resources/", "./single.txt", "../shared/s.txt", "data/*.json", "empty", "dot/./d.txt"], tauriDir: dir)
        #expect(pairs(m, dir) == [
            "src-tauri/resources/.hidden/c.txt -> resources/.hidden/c.txt",
            "src-tauri/resources/a.txt -> resources/a.txt",
            "src-tauri/resources/sub/b.txt -> resources/sub/b.txt",
            "src-tauri/single.txt -> single.txt",
            "shared/s.txt -> _up_/shared/s.txt",
            "src-tauri/data/x.json -> data/x.json",
            "src-tauri/data/y.json -> data/y.json",
            "src-tauri/dot/d.txt -> dot/d.txt",
        ])
    }

    /// Map entries: a file goes to its target (an empty target keeps the file name), a directory's tree goes under the
    /// target, a glob's matches go under the target by file name.
    @Test func mapEntries() throws {
        let dir = try tauriDir()
        let m = try TauriMacBundler.resourceMappings(resources: ["single.txt": "docs/readme.txt", "resources": "res", "data/*.json": "json", "../shared/s.txt": ""], tauriDir: dir)
        #expect(Set(pairs(m, dir)) == [
            "src-tauri/single.txt -> docs/readme.txt",
            "src-tauri/resources/.hidden/c.txt -> res/.hidden/c.txt",
            "src-tauri/resources/a.txt -> res/a.txt",
            "src-tauri/resources/sub/b.txt -> res/sub/b.txt",
            "src-tauri/data/x.json -> json/x.json",
            "src-tauri/data/y.json -> json/y.json",
            "shared/s.txt -> s.txt",
        ])
    }

    @Test(arguments: ["missing.txt", "data/*.png"]) func missingEntryIsABuildError(_ entry: String) throws {
        let dir = try tauriDir()
        do { _ = try TauriMacBundler.resourceMappings(resources: [entry], tauriDir: dir); Issue.record("accepted") } catch let e as XlessError {
            #expect(e.stage == .build)
            #expect(e.cause == "bundle.resources entry '\(entry)' not found under \(dir.path) (checked after cargo)")
        }
    }

    /// Two entries that map to the same bundle path are refused (Tauri would silently keep the last copy).
    @Test func duplicateTargetsAreABuildError() throws {
        let dir = try tauriDir()
        do { _ = try TauriMacBundler.resourceMappings(resources: ["single.txt", "./single.txt"], tauriDir: dir); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("'single.txt'") && e.cause.contains("./single.txt")) }
        do { _ = try TauriMacBundler.resourceMappings(resources: ["resources/a.txt": "x.txt", "single.txt": "x.txt"], tauriDir: dir); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("'x.txt'")) }
    }

    /// Per-target snapshots: identical files are kept once, differing thin Mach-Os of each target's architecture are
    /// merged into a universal file, any other difference is refused (spike B rule).
    @Test func mergesPerTargetSnapshots() throws {
        let root = scratch("merge")
        let a = root.appendingPathComponent("aarch64-apple-darwin"), x = root.appendingPathComponent("x86_64-apple-darwin")
        try write("same", a.appendingPathComponent("r/lic.txt")); try write("same", x.appendingPathComponent("r/lic.txt"))
        try fm.createDirectory(at: a.appendingPathComponent("r"), withIntermediateDirectories: true)
        try thin(arm64, "a").write(to: a.appendingPathComponent("r/lib.dylib")); try thin(x86_64, "x").write(to: x.appendingPathComponent("r/lib.dylib"))
        let out = root.appendingPathComponent("universal")
        let merged = try TauriMacBundler.mergeResources([("aarch64-apple-darwin", a), ("x86_64-apple-darwin", x)], targets: ["r/lib.dylib", "r/lic.txt"], into: out)
        #expect(merged.map(\.target) == ["r/lib.dylib", "r/lic.txt"])
        #expect(try String(contentsOf: out.appendingPathComponent("r/lic.txt"), encoding: .utf8) == "same")
        let fat = try Data(contentsOf: out.appendingPathComponent("r/lib.dylib"))
        #expect(MachO.isFat(fat))
        #expect(try MachO.sliceArchitectures(in: fat).map(\.name) == ["x86_64", "arm64"])

        try write("arm text", a.appendingPathComponent("r/lic.txt"))
        do {
            _ = try TauriMacBundler.mergeResources([("aarch64-apple-darwin", a), ("x86_64-apple-darwin", x)], targets: ["r/lic.txt"], into: root.appendingPathComponent("u2"))
            Issue.record("differing text accepted")
        } catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("r/lic.txt")) }
        // Two arm64 copies that differ cannot be merged either.
        try thin(arm64, "other").write(to: x.appendingPathComponent("r/lib.dylib"))
        do {
            _ = try TauriMacBundler.mergeResources([("aarch64-apple-darwin", a), ("x86_64-apple-darwin", x)], targets: ["r/lib.dylib"], into: root.appendingPathComponent("u3"))
            Issue.record("two arm64 copies accepted")
        } catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("'r/lib.dylib'") && e.cause.contains("x86_64-apple-darwin")) }
        // A file one target's build did not leave.
        try fm.removeItem(at: x.appendingPathComponent("r/lib.dylib"))
        do {
            _ = try TauriMacBundler.mergeResources([("aarch64-apple-darwin", a), ("x86_64-apple-darwin", x)], targets: ["r/lib.dylib"], into: root.appendingPathComponent("u4"))
            Issue.record("missing copy accepted")
        } catch let e as XlessError {
            #expect(e.stage == .build && e.cause == "bundle.resources file 'r/lib.dylib' is missing after the x86_64-apple-darwin build")
        }
    }

    /// After a target's cargo run, each resource is taken from cargo's per-target copy (`target/<t>/release/<target>`,
    /// written by tauri-build) when there is one, else from its source.
    @Test func snapshotPrefersCargoPerTargetCopies() throws {
        let root = scratch("snap"), release = root.appendingPathComponent("target/aarch64-apple-darwin/release")
        try write("shared-last", root.appendingPathComponent("src/lib.dylib"))
        try write("per-target", release.appendingPathComponent("res/lib.dylib"))
        try write("plain", root.appendingPathComponent("src/a.txt"))
        let out = root.appendingPathComponent("snap")
        let targets = try TauriMacBundler.snapshotResources([(root.appendingPathComponent("src/lib.dylib"), "res/lib.dylib"), (root.appendingPathComponent("src/a.txt"), "a.txt")],
                                                           cargoRelease: release, into: out)
        #expect(targets == ["res/lib.dylib", "a.txt"])
        #expect(try String(contentsOf: out.appendingPathComponent("res/lib.dylib"), encoding: .utf8) == "per-target")
        #expect(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8) == "plain")
    }
}

@Suite struct TauriMacAssembleTests {
    /// `<Product>.app/Contents/{Info.plist, MacOS/<main binary>, Resources/<icon>.icns, Resources/<resources>, Frameworks}`;
    /// a framework whose binary is a static archive is linked, not embedded.
    @Test func layout() throws {
        let (r, root) = try resolvedMac(#"{"icon":["icons/32x32.png","icons/icon.icns"],"resources":["resources/"],"macOS":{"frameworks":["Vendor/Dyn.framework","Vendor/Static.framework","libs/libx.dylib"]}}"#)
        let dir = root.appendingPathComponent("src-tauri")
        try write("icns", dir.appendingPathComponent("icons/icon.icns"))
        try write("png", dir.appendingPathComponent("icons/32x32.png"))
        try write("hello", dir.appendingPathComponent("resources/hello.txt"))
        try fm.createDirectory(at: dir.appendingPathComponent("Vendor/Dyn.framework/Versions/A"), withIntermediateDirectories: true)
        try thin(arm64).write(to: dir.appendingPathComponent("Vendor/Dyn.framework/Versions/A/Dyn"))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("Vendor/Dyn.framework/Dyn").path, withDestinationPath: "Versions/A/Dyn")
        try fm.createDirectory(at: dir.appendingPathComponent("Vendor/Static.framework"), withIntermediateDirectories: true)
        try Data("!<arch>\n".utf8).write(to: dir.appendingPathComponent("Vendor/Static.framework/Static"))
        try write("dylib", dir.appendingPathComponent("libs/libx.dylib"))
        let exe = root.appendingPathComponent("exe")
        try MachO.makeFat([thin(x86_64), thin(arm64)]).write(to: exe)

        let out = root.appendingPathComponent("out")
        let app = try TauriMacBundler.assemble(resolved: r, workRoot: root, universalExecutable: exe, into: out)
        #expect(app.lastPathComponent == "Demo.app")
        #expect(files(under: app) == [
            "Contents/Frameworks/Dyn.framework/Versions/A/Dyn", "Contents/Frameworks/libx.dylib", "Contents/Info.plist",
            "Contents/MacOS/demo", "Contents/Resources/icon.icns", "Contents/Resources/resources/hello.txt",
        ])
        #expect((try? fm.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Contents/Frameworks/Dyn.framework/Dyn").path)) == "Versions/A/Dyn")
        let mode = try fm.attributesOfItem(atPath: app.appendingPathComponent("Contents/MacOS/demo").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let info = try Plist.read(app.appendingPathComponent("Contents/Info.plist"), stage: .build)
        #expect(info["CFBundleExecutable"] as? String == "demo" && info["CFBundleIconFile"] as? String == "icon.icns")
    }

    @Test func noIcnsIsABuildError() throws {
        let (r, root) = try resolvedMac(#"{"icon":["icons/32x32.png"]}"#)
        let exe = root.appendingPathComponent("exe"); try thin(arm64).write(to: exe)
        do { _ = try TauriMacBundler.assemble(resolved: r, workRoot: root, universalExecutable: exe, into: root.appendingPathComponent("out")); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains(".icns")) }
    }

    /// Bundle keys xless does not implement are refused, not silently dropped.
    @Test func unsupportedBundleKeysAreRefused() throws {
        let (r, root) = try resolvedMac(#"{"icon":["icons/icon.icns"],"externalBin":["bin/tool"]}"#)
        try write("icns", root.appendingPathComponent("src-tauri/icons/icon.icns"))
        let exe = root.appendingPathComponent("exe"); try thin(arm64).write(to: exe)
        do { _ = try TauriMacBundler.assemble(resolved: r, workRoot: root, universalExecutable: exe, into: root.appendingPathComponent("out")); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("externalBin")) }
    }
}

@Suite struct TauriMacUniversalTests {
    private func exe(_ data: Data?) throws -> URL {
        let url = scratch("exe")
        if let data { try data.write(to: url) }
        return url
    }

    @Test func combinesBothSlices() throws {
        let fat = try TauriBuilder.universalExecutable([("aarch64-apple-darwin", exe(thin(arm64))), ("x86_64-apple-darwin", exe(thin(x86_64)))], binary: "demo")
        #expect(try MachO.sliceArchitectures(in: fat).map(\.name) == ["x86_64", "arm64"])
    }

    @Test func refusesAMissingSlice() throws {
        for inputs in [[("aarch64-apple-darwin", try exe(thin(arm64))), ("x86_64-apple-darwin", try exe(nil))],
                       [("aarch64-apple-darwin", try exe(thin(arm64)))]] {
            do { _ = try TauriBuilder.universalExecutable(inputs, binary: "demo"); Issue.record("accepted") }
            catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("x86_64")) }
        }
    }

    @Test func oneTargetGivesItsThinExecutable() throws {
        let data = thin(arm64, "a")
        #expect(try RustApple.macExecutable([("aarch64-apple-darwin", exe(data))], binary: "demo") == data)
        let fat = try RustApple.macExecutable([("aarch64-apple-darwin", exe(thin(arm64))), ("x86_64-apple-darwin", exe(thin(x86_64)))], binary: "demo")
        #expect(try MachO.sliceArchitectures(in: fat).map(\.name) == ["x86_64", "arm64"])
    }

    @Test func oneTargetRefusesTheWrongArchitectureOrNoExecutable() throws {
        do { _ = try RustApple.macExecutable([("x86_64-apple-darwin", exe(thin(arm64)))], binary: "demo"); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("x86_64")) }
        do { _ = try RustApple.macExecutable([("aarch64-apple-darwin", exe(nil))], binary: "demo"); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("arm64")) }
        do { _ = try RustApple.macExecutable([("aarch64-apple-darwin", exe(MachO.makeFat([thin(x86_64), thin(arm64)])))], binary: "demo"); Issue.record("accepted") }
        catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("thin")) }
    }

    @Test func refusesTheSameArchitectureTwice() throws {
        do {
            _ = try TauriBuilder.universalExecutable([("aarch64-apple-darwin", exe(thin(arm64))), ("x86_64-apple-darwin", exe(thin(arm64)))], binary: "demo")
            Issue.record("accepted")
        } catch let e as XlessError { #expect(e.stage == .build && e.cause.contains("arm64")) }
    }
}

/// A Darwin SDK stand-in with the MacOSX 27.0 SDK and libclang_rt.osx.a (what buildMac's environment and wrapper read).
private func fakeMacSDK() throws -> DarwinSDK {
    let bundle = scratch("sdk").appendingPathComponent("darwin.xtoolsdk", isDirectory: true)
    try write(#"{"Version":"27.0"}"#, bundle.appendingPathComponent("Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/SDKSettings.json"))
    try write("", bundle.appendingPathComponent("Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.osx.a"))
    return DarwinSDK(bundle: bundle)
}

/// `buildMac` end to end with a fake `cargo` on PATH: `metadata` answers fixed JSON; `build --target <t>` writes a thin
/// Mach-O of <t>'s architecture as the binary and (re)creates the `staged/` resource dir, which does not exist before
/// cargo, the way an app's build.rs stages per-target files into a shared directory (spike B).
@Suite struct TauriBuildMacTests {
    private func run(dylibForBothTargets: Bool) async throws -> URL {
        let root = scratch("buildmac"), tauriDir = root.appendingPathComponent("src-tauri"), bin = root.appendingPathComponent("bin")
        try write(#"{"productName":"Demo","version":"1.2.3","identifier":"com.example.demo","bundle":{"icon":["icons/icon.icns"],"resources":["staged/"]}}"#,
                  tauriDir.appendingPathComponent("tauri.conf.json"))
        try write("icns", tauriDir.appendingPathComponent("icons/icon.icns"))
        try write("[package]\nname = \"demo\"\n", tauriDir.appendingPathComponent("Cargo.toml"))
        try write(#"{"packages":[{"name":"demo","manifest_path":"\#(tauriDir.path)/Cargo.toml","default_run":null,"targets":[{"name":"demo","kind":["bin"]}]}],"target_directory":"\#(tauriDir.path)/target"}"#,
                  bin.appendingPathComponent("metadata.json"))
        try write("""
            #!/bin/sh
            set -e
            case "$1" in
            metadata) cat "$(dirname "$0")/metadata.json" ;;
            build)
              t=""; prev=""
              for a in "$@"; do [ "$prev" = "--target" ] && t="$a"; prev="$a"; done
              case "$t" in
                aarch64-apple-darwin) cpu='\\014\\000\\000\\001' ;;
                x86_64-apple-darwin) cpu='\\007\\000\\000\\001' ;;
                *) echo "unexpected target $t" >&2; exit 1 ;;
              esac
              macho() { printf '\\317\\372\\355\\376'; printf "$cpu"; head -c 24 /dev/zero; printf '%s' "$1"; }
              mkdir -p "target/$t/release"; macho exe > "target/$t/release/demo"
              rm -rf staged; mkdir -p staged; echo same > staged/notes.txt
              if [ "$t" = aarch64-apple-darwin ] || [ "\(dylibForBothTargets ? "yes" : "no")" = yes ]; then macho lib > staged/lib.dylib; fi
              ;;
            *) echo "unexpected cargo $*" >&2; exit 1 ;;
            esac

            """, bin.appendingPathComponent("cargo"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("cargo").path)

        let overlay = try TauriOverlay.parse(yaml: "type: tauri\nbundleID: com.example.demo\nteamID: ABCDE12345\n", name: "demo")
        let resolved = try TauriProject.resolveMac(overlay: overlay, source: root)
        let env = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path, "CARGO_HOME": root.appendingPathComponent("cargo-home").path]
        let ctx = TauriMacBuildContext(overlay: overlay, resolved: resolved, sourceRoot: root, workRoot: root,
                                       paths: StagePaths(project: root, platform: .macos), sdk: try fakeMacSDK(), env: env)
        return try await TauriBuilder.buildMac(ctx: ctx)
    }

    /// Variant A: each target stages its own dylib into the shared dir; the app gets the universal merge of the two
    /// snapshots (the shared dir only holds the x86_64 copy at the end), the identical text file once.
    @Test func mergesPerTargetResourcesIntoTheApp() async throws {
        let app = try await run(dylibForBothTargets: true)
        #expect(app.lastPathComponent == "Demo.app")
        #expect(files(under: app) == ["Contents/Info.plist", "Contents/MacOS/demo", "Contents/Resources/icon.icns",
                                      "Contents/Resources/staged/lib.dylib", "Contents/Resources/staged/notes.txt"])
        let lib = try Data(contentsOf: app.appendingPathComponent("Contents/Resources/staged/lib.dylib"))
        #expect(MachO.isFat(lib))
        #expect(try MachO.sliceArchitectures(in: lib).map(\.name) == ["x86_64", "arm64"])
        let exe = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/demo"))
        #expect(try MachO.sliceArchitectures(in: exe).map(\.name) == ["x86_64", "arm64"])
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/Resources/staged/notes.txt"), encoding: .utf8) == "same\n")
    }

    /// Variant B: only the arm64 build stages the dylib → `[build]` naming the file and the target that lacks it.
    @Test func refusesAResourceOnlyOneTargetStaged() async throws {
        do { _ = try await run(dylibForBothTargets: false); Issue.record("accepted") }
        catch let e as XlessError {
            #expect(e.stage == .build)
            #expect(e.cause == "bundle.resources file 'staged/lib.dylib' exists after the aarch64-apple-darwin build but not after the x86_64-apple-darwin build", "\(e.cause)")
        }
    }
}
