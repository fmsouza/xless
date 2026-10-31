import Testing
import Foundation
@testable import XlessPackage
@testable import XlessCore

private func onPath(_ tool: String) -> Bool {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
        FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)")
    }
}

private let mtime = Date(timeIntervalSince1970: 1_700_000_000)   // fixture files and directories carry this

private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID())") }

private func clean(root: URL) { try? FileManager.default.removeItem(at: root) }

/// A bundle with an executable, a versioned framework (`Versions/Current` and `F` are symlinks) and a name with a
/// space — the same shape DmgBuilderTests build — plus a resource file. Modes and mtimes are set explicitly so
/// every Bom field is expectable (chmod does not change mtime; directory mtimes are set last, after the
/// children). Symlink mtimes cannot be set portably (they are the link's own, read back like the walk does).
private func makeApp(_ root: URL, name: String = "Hello Tauri") throws -> (app: URL, symlinks: [String: Date]) {
    let fm = FileManager.default
    let app = root.appendingPathComponent("\(name).app")
    let fw = app.appendingPathComponent("Contents/Frameworks/F.framework")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: fw.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
    try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try touch(app.appendingPathComponent("Contents/MacOS/x"), data: Data("bin".utf8), mode: 0o700)
    try touch(fw.appendingPathComponent("Versions/A/F"), data: Data("fw".utf8), mode: 0o644)
    try touch(app.appendingPathComponent("Contents/Resources/res.bin"), data: Data("res".utf8), mode: 0o644)
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("F").path, withDestinationPath: "Versions/Current/F")
    var symlinkDates: [String: Date] = [:]
    for (rel, link) in [("F", "\(fw.path)/F"), ("Current", "\(fw.path)/Versions/Current")] {
        let attrs = try FileManager.default.attributesOfItem(atPath: link)
        symlinkDates[rel] = attrs[.modificationDate] as? Date ?? mtime
    }
    var directories = (try fm.subpathsOfDirectory(atPath: app.path)).map { app.appendingPathComponent($0) }
    directories.append(app)
    for d in directories {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { continue }
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: d.path)
    }
    return (app, symlinkDates)
}

private func touch(_ url: URL, data: Data, mode: mode_t) throws {
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: mtime], ofItemAtPath: url.path)
}

private func modeOf(_ path: String) throws -> String {
    let m = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    return String(m, radix: 8)
}

private nonisolated(unsafe) var modes: [String: String] = [:]   // the staging tree's modes, captured mid-build

private let yaml = """
    bundleID: app.example.helloship
    teamID: ABCDE12345
    version: "1.2.3"
    build: 42
    platforms:
      macos: { minimumOS: "14.0", product: Hello Tauri, distribution: app-store }
    """

private func config() throws -> ProjectConfig { try ProjectConfig.parse(yaml: yaml) }

private let component = "app.example.helloship.pkg"

private func staged(_ cwd: URL, _ path: String) throws -> Data {
    try Data(contentsOf: cwd.appendingPathComponent(path))
}

/// The app tree's Bom entries as PkgBuilder must list them: preorder, "." first, mkbom-shaped
/// `./` paths, children sorted byte-wise in each directory, normalized modes (755 dirs and
/// executables, 644 others, 777 symlinks), uid 0, gid 80 (root:admin, the /Applications group),
/// digests from the contents (cksum CRC-32; the target string for symlinks), and the tree's mtimes.
private func expectedEntries(app: URL, symlinks: [String: Date]) -> [Bom.Entry] {
    let base = "./\(app.lastPathComponent)"
    let fw = "\(base)/Contents/Frameworks/F.framework"
    func entry(_ path: String, _ kind: Bom.Kind, _ mode: UInt16, _ size: UInt64, _ checksum: UInt32,
               linkTarget: String? = nil, date: Date = mtime) -> Bom.Entry {
        Bom.Entry(path: path, kind: kind, mode: mode, userID: 0, groupID: 80,
                  modificationDate: date, size: size, checksum: checksum, linkTarget: linkTarget)
    }
    func cksum(_ text: String) -> UInt32 { Bom.cksum(Data(text.utf8)) }
    return [
        entry(".", .directory, 0o755, 0, 0),
        entry(base, .directory, 0o755, 0, 0),
        entry("\(base)/Contents", .directory, 0o755, 0, 0),
        entry("\(base)/Contents/Frameworks", .directory, 0o755, 0, 0),
        entry("\(fw)", .directory, 0o755, 0, 0),
        entry("\(fw)/F", .symlink, 0o777, UInt64("Versions/Current/F".utf8.count),
              cksum("Versions/Current/F"), linkTarget: "Versions/Current/F", date: symlinks["F"] ?? mtime),
        entry("\(fw)/Versions", .directory, 0o755, 0, 0),
        entry("\(fw)/Versions/A", .directory, 0o755, 0, 0),
        entry("\(fw)/Versions/A/F", .file, 0o644, UInt64("fw".utf8.count), cksum("fw")),
        entry("\(fw)/Versions/Current", .symlink, 0o777, UInt64("A".utf8.count),
              cksum("A"), linkTarget: "A", date: symlinks["Current"] ?? mtime),
        entry("\(base)/Contents/MacOS", .directory, 0o755, 0, 0),
        entry("\(base)/Contents/MacOS/x", .file, 0o755, UInt64("bin".utf8.count), cksum("bin")),
        entry("\(base)/Contents/Resources", .directory, 0o755, 0, 0),
        entry("\(base)/Contents/Resources/res.bin", .file, 0o644, UInt64("res".utf8.count), cksum("res")),
    ]
}

@Test func pkgFileNameMatchesProduct() {
    #expect(PkgBuilder.fileName(product: "Hello Tauri") == "Hello Tauri.pkg")
}

/// The cpio pipeline and the xar invocation, with the fixture tree: the argv runs, their working
/// directories, and the TOC order (Distribution first, then the component's Bom, Payload, PackageInfo).
@Test func buildRunsThePayloadPipelineThenXarInOrder() throws {
    let root = scratch(); defer { clean(root: root) }
    let (app, _) = try makeApp(root)
    nonisolated(unsafe) var ran: [(argv: [String], cwd: URL)] = []
    let pkgURL = try PkgBuilder.build(signedApp: app, outputDir: root.appendingPathComponent("out"), config: try config()) { argv, cwd in
        ran.append((argv, cwd))
        // Simulate the tools: the pipeline writes the Payload it was asked to write; xar writes the pkg file.
        if argv[0] == "sh" { FileManager.default.createFile(atPath: cwd.deletingLastPathComponent()
            .appendingPathComponent("\(component)/Payload").path, contents: Data("payload".utf8)) }
        if argv[0] == "xar" { try Data("pkg".utf8).write(to: URL(fileURLWithPath: argv[2])) }
    }
    #expect(pkgURL.lastPathComponent == "Hello Tauri.pkg")
    #expect(pkgURL.deletingLastPathComponent().lastPathComponent == "out")
    #expect(ran.map { $0.argv[0] } == ["chmod", "sh", "xar"])
    // The pipeline: preorder find (never the app name — the cwd holds the app), odc cpio, gzip, junk excluded.
    let pipeline = ran[1].argv
    #expect(pipeline[0] == "sh" && pipeline[1] == "-c")
    #expect(pipeline[2].contains("find .") && pipeline[2].contains("cpio -o -H odc") && pipeline[2].contains("gzip"))
    #expect(pipeline[2].contains("DS_Store") && pipeline[2].contains("._*"))
    #expect(pipeline[3] == "sh" && pipeline[4].hasSuffix("\(component)/Payload"))
    #expect(ran[1].cwd.lastPathComponent == "payload")
    // The xar call writes into the staging root, output first as the atomic output's partial path
    // (Files.atomicOutput rebases the returned URL once the stage succeeded).
    #expect(ran[2].argv == ["xar", "-cf", pkgURL.path.replacingOccurrences(of: "/out/", with: "/out.partial/"),
                            "Distribution", "\(component)/Bom", "\(component)/Payload", "\(component)/PackageInfo"])
    #expect(ran[2].cwd.path.contains("xless-pkg-"))
}

/// The Bom xar packs must be byte-identical with `Bom.data(for:)` over the tree's entries, and
/// parse back to the same preorder paths.
@Test func theBomSlotIsTheWriterOutputForTheTree() throws {
    let root = scratch(); defer { clean(root: root) }
    let (app, symlinks) = try makeApp(root)
    nonisolated(unsafe) var bom: Data?
    _ = try PkgBuilder.build(signedApp: app, outputDir: root.appendingPathComponent("out"), config: try config()) { argv, cwd in
        // The chmod step runs for real: the Bom must describe the staged, normalized tree.
        if argv[0] == "chmod" { try Shell.run(argv[0], Array(argv.dropFirst()), stage: .package) }
        if argv[0] == "xar" { bom = try staged(cwd, "\(component)/Bom") }
        if argv[0] == "sh" { FileManager.default.createFile(atPath: cwd.deletingLastPathComponent()
            .appendingPathComponent("\(component)/Payload").path, contents: Data("payload".utf8)) }
    }
    let wanted = expectedEntries(app: app, symlinks: symlinks)
    let wantedBytes = try Bom.data(for: wanted)
    #expect(bom == wantedBytes)
    // Parsing gives mkbom's listing order ((parent, name)-sorted leaves, not the input preorder); the set
    // must be the walked paths, and the byte equality above already pinned the preorder structure.
    #expect(try Bom(bom ?? Data()).records.map { $0.path }.sorted() == wanted.map { $0.path }.sorted())
}

/// Payload staging: the cpio pipeline runs in a directory that holds the app copy, modes normalized
/// (755 on directories and the executable, 644 on the resource — the staging copy, not the source).
@Test func thePayloadPipelineRunsOverANormalizedAppCopy() throws {
    let root = scratch(); defer { clean(root: root) }
    let (app, _) = try makeApp(root)
    modes = [:]
    nonisolated(unsafe) var appCopy = ""
    _ = try PkgBuilder.build(signedApp: app, outputDir: root.appendingPathComponent("out"), config: try config()) { argv, cwd in
        // The chmod step runs for real, so the modes the walk/manifest see are the staged ones.
        if argv[0] == "chmod" { try Shell.run(argv[0], Array(argv.dropFirst()), stage: .package) }
        if argv[0] == "sh" {
            let contents = try FileManager.default.contentsOfDirectory(atPath: cwd.path).sorted()
            #expect(contents == ["Hello Tauri.app"])
            appCopy = contents.first ?? ""
            // Modes during the pipeline (the staging tree is removed once the build ends): normalized.
            if let copy = contents.first {
                let a = cwd.appendingPathComponent(copy)
                modes[copy + "/"] = try modeOf(a.path)
                modes[copy + "/Contents"] = try modeOf(a.appendingPathComponent("Contents").path)
                modes[copy + "/Contents/MacOS/x"] = try modeOf(a.appendingPathComponent("Contents/MacOS/x").path)
                modes[copy + "/Contents/Resources/res.bin"] = try modeOf(a.appendingPathComponent("Contents/Resources/res.bin").path)
            }
        }
        if argv[0] == "xar" { try Data("pkg".utf8).write(to: URL(fileURLWithPath: argv[2])) }
    }
    #expect(appCopy == "Hello Tauri.app")
    #expect(modes["Hello Tauri.app/"] == "755")
    #expect(modes["Hello Tauri.app/Contents"] == "755")
    #expect(modes["Hello Tauri.app/Contents/MacOS/x"] == "755")       // source mode was 700
    #expect(modes["Hello Tauri.app/Contents/Resources/res.bin"] == "644")
}

/// Distribution: the App Store distribution Apple's own productbuild synthesizes (verified against
/// `productbuild --synthesize --component <app> /Applications` on 2026-10-31), with the component
/// href rewritten the way productbuild rewrites it (`#<bundle-id>.pkg`).
@Test func distributionIsTheAppStoreTemplate() throws {
    let root = scratch(); defer { clean(root: root) }
    let (app, _) = try makeApp(root)
    nonisolated(unsafe) var distribution = ""
    _ = try PkgBuilder.build(signedApp: app, outputDir: root.appendingPathComponent("out"), config: try config()) { argv, cwd in
        if argv[0] == "xar" { distribution = String(decoding: try staged(cwd, "Distribution"), as: UTF8.self) }
        if argv[0] == "sh" { FileManager.default.createFile(atPath: cwd.deletingLastPathComponent()
            .appendingPathComponent("\(component)/Payload").path, contents: Data()) }
    }
    let id = "app.example.helloship"
    let want = """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="2">
            <pkg-ref id="\(id)"/>
            <product id="\(id)" version="1.2.3"/>
            <title>Hello Tauri</title>
            <options customize="never" require-scripts="false"/>
            <choices-outline>
                <line choice="default">
                    <line choice="\(id)"/>
                </line>
            </choices-outline>
            <choice id="default" title="Hello Tauri" versStr="1.2.3"/>
            <choice id="\(id)" title="Hello Tauri" visible="false" customLocation="/Applications">
                <pkg-ref id="\(id)"/>
            </choice>
            <pkg-ref id="\(id)" version="1.2.3" onConclusion="none">#\(id).pkg</pkg-ref>
        </installer-gui-script>
        """
    #expect(distribution == want + "\n")
}

/// PackageInfo: productbuild's component summary; version/build come from the config — the same
/// values the finalize stage of this run stamped into the app's Info.plist — not from a re-read.
@Test func packageInfoSummarizesTheComponent() throws {
    let root = scratch(); defer { clean(root: root) }
    let (app, _) = try makeApp(root)
    nonisolated(unsafe) var packageInfo = ""
    _ = try PkgBuilder.build(signedApp: app, outputDir: root.appendingPathComponent("out"), config: try config()) { argv, cwd in
        if argv[0] == "xar" {
            packageInfo = String(decoding: try staged(cwd, "\(component)/PackageInfo"), as: UTF8.self)
        }
        if argv[0] == "sh" { FileManager.default.createFile(atPath: cwd.deletingLastPathComponent()
            .appendingPathComponent("\(component)/Payload").path, contents: Data()) }
    }
    let id = "app.example.helloship"
    let want = """
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info format-version="2" identifier="\(id)" version="1.2.3" install-location="/Applications" auth="root">
            <payload installKBytes="1" numberOfFiles="14"/>
            <bundle path="./Hello Tauri.app" id="\(id)" CFBundleShortVersionString="1.2.3" CFBundleVersion="42"/>
            <bundle-version>
                <bundle id="\(id)"/>
            </bundle-version>
            <upgrade-bundle>
                <bundle id="\(id)"/>
            </upgrade-bundle>
            <update-bundle/>
            <atomic-update-bundle/>
            <strict-identifier>
                <bundle id="\(id)"/>
            </strict-identifier>
            <relocate/>
        </pkg-info>
        """
    #expect(packageInfo == want + "\n")
}

/// The XML the installer reads is escaped: a title, id or version with `<` must not break the distribution.
@Test func distributionEscapesXMLSpecials() {
    #expect(PkgBuilder.escape("A & B < C > D \" E") == "A &amp; B &lt; C &gt; D &quot; E")
}

/// A hostile (or accidental) runaway nesting is refused, never walked to a stack overflow.
@Test func deepNestingIsRefused() throws {
    let root = scratch(); defer { clean(root: root) }
    let bundle = try makeApp(root).app
    var dir = bundle
    let fm = FileManager.default
    for _ in 0...(PkgBuilder.maxDepth + 2) {
        dir = dir.appendingPathComponent("d")   // one character: the fixture must stay under the FS path limit
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
    }
    #expect(throws: XlessError.self) {
        try PkgBuilder.build(signedApp: bundle, outputDir: root.appendingPathComponent("out"), config: try config())
    }
}

/// The pkg signature: the Apple Distribution key and certificate, the way the DMG is signed; no
/// notarization step (App Store builds are processed by ASC, not the notary service).
@Test func signArgumentsMatchTheRcodesignSeam() {
    let pkg = URL(fileURLWithPath: "/o/Hello Tauri.pkg")
    #expect(PkgBuilder.signArguments(pkg: pkg, keyPEM: URL(fileURLWithPath: "/k.pem"), certPEM: URL(fileURLWithPath: "/c.pem"))
        == ["sign", "--pem-file", "/k.pem", "--pem-file", "/c.pem", "/o/Hello Tauri.pkg"])
}

/// Runs only where the tools exist (the xless-tauri image, or this Mac): a real cpio/xar assembly
/// whose artifacts Apple's own tools parse back (xar TOC and extraction, the odc cpio listing).
@Test(.enabled(if: onPath("xar") && onPath("cpio") && onPath("gzip")))
func realAssemblyIsParsedByAppleTools() throws {
    let root = scratch(); defer { clean(root: root) }
    let (app, symlinks) = try makeApp(root)
    let pkgURL = try PkgBuilder.build(signedApp: app, outputDir: root.appendingPathComponent("out"), config: try config())
    #expect(FileManager.default.fileExists(atPath: pkgURL.path))
    let toc = try Shell.run("xar", ["-tf", pkgURL.path], stage: .package).stdout.split(separator: "\n").map(String.init)
    #expect(toc == ["Distribution", component, "\(component)/Bom", "\(component)/Payload", "\(component)/PackageInfo"])
    let expand = root.appendingPathComponent("expand")
    try FileManager.default.createDirectory(at: expand, withIntermediateDirectories: true)
    try Shell.run("xar", ["-x", "-f", pkgURL.path], cwd: expand, stage: .package)
    let archivedBom = try Data(contentsOf: expand.appendingPathComponent("\(component)/Bom"))
    let wantedBom = try Bom.data(for: expectedEntries(app: app, symlinks: symlinks))
    #expect(archivedBom == wantedBom)
    // The payload: odc cpio, gzipped, listing every Bom path (including the root dot) as its own line.
    let payload = expand.appendingPathComponent("\(component)/Payload").path
    let listing = try Shell.run("sh", ["-c", "exec gzip -dc \"$1\" | cpio -it", "sh", payload], cwd: expand, stage: .package).stdout
    let lines = listing.split(separator: "\n").map(String.init)
    let wanted = expectedEntries(app: app, symlinks: symlinks).map { $0.path }   // "." is the list's head
    if lines != wanted { print("DBGL", lines) }   // TEMP
    #expect(lines == wanted)
}