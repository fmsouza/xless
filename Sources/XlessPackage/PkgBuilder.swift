import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import XlessASC
import XlessCore
import XlessSign

/// Assembles and signs the macOS **flat distribution package** (`.pkg`) of an App-Store-signed app on Linux —
/// the App Store distribution the DMG path never covers (TestFlight for macOS uploads an App Store flat
/// package, uti `com.apple.pkg`). The shape is the one Apple's own tooling and every Linux packager produce
/// (verified 2026-10-31 against `productbuild --component/--synthesize` runs on macOS, the `xar -tf` dumps of
/// real signed product packages, and the apple-flat-package format docs — Amendment A of
/// docs/superpowers/specs/2026-10-31-mac-testflight-design.md):
///
/// ```
/// <xar>
///   Distribution                          ← productbuild's synthesized App Store distribution
///   <bundle-id>.pkg/                      ← the component package the Distribution references by href `#…`
///     Bom                                 ← `Bom.data(for:)` over the app tree
///     Payload                             ← `find . | cpio -o -H odc | gzip` of the app (odc, the cpio format
///                                           Apple's own payloads carry — not newc)
///     PackageInfo                         ← the component summary (install location /Applications)
/// ```
///
/// No `Scripts` archive and no `<scripts>` in the distribution: xless ships no installer scripts, and the
/// distribution declares `require-scripts="false"`. The app arrives App-Store-signed (the sign stage did it);
/// the package itself is signed with the Apple Distribution certificate (rcodesign signs flat packages) after
/// the `xar` assembly — no notarization: App Store builds are processed by ASC, not the notary service.
///
/// File names inside the payload come from the staging tree alone; the `find | cpio | gzip` pipeline's command
/// line is constant (the out path is `$1`), so file names with spaces or non-ASCII characters are safe.
public enum PkgBuilder {
    /// The mac App Store artifact: `<product>.pkg` next to the DMG.
    public static func fileName(product: String) -> String { "\(product).pkg" }

    public static func shell(_ argv: [String], cwd: URL) throws {
        try Shell.run(argv[0], Array(argv.dropFirst()), cwd: cwd, stage: .package)
    }

    /// One `rcodesign sign` run over the finished package (an App Store pkg is signed with the Apple
    /// Distribution certificate only; no notary submit — ITMS processes it).
    static func signArguments(pkg: URL, keyPEM: URL, certPEM: URL) -> [String] {
        ["sign", "--pem-file", keyPEM.path, "--pem-file", certPEM.path, pkg.path]
    }

    /// Builds `<outputDir>/<product>.pkg`. `run` receives each external command and its working directory
    /// (the test seam: real runs use `PkgBuilder.shell`, tests record the argv and stage files by hand).
    @discardableResult
    public static func build(signedApp: URL, outputDir: URL, config: ProjectConfig,
                             run: (_ command: [String], _ cwd: URL) throws -> Void = shell) throws -> URL {
        try Files.atomicOutput(outputDir) { out in try buildInto(out, signedApp: signedApp, config: config, run: run) }
    }

    // MARK: - Assembly

    static func buildInto(_ out: URL, signedApp: URL, config: ProjectConfig,
                          run: (_ command: [String], _ cwd: URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let pc = try config.platform(.macos)
        let bundleID = config.bundleID(for: .macos)
        let component = "\(bundleID).pkg"
        let appName = "\(pc.product).app"

        // The staging tree: `payload/` holds the app copy the cpio pipeline walks; `<component>/` collects the
        // Bom, Payload and PackageInfo the xar call packs next to the Distribution.
        let work = fm.temporaryDirectory.appendingPathComponent("xless-pkg-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try? fm.removeItem(at: work)                       // a stale work dir from a crashed run must not survive
        let payloadStage = work.appendingPathComponent("payload", isDirectory: true)
        let componentDir = work.appendingPathComponent(component, isDirectory: true)
        try fm.createDirectory(at: payloadStage, withIntermediateDirectories: true)
        try fm.createDirectory(at: componentDir, withIntermediateDirectories: true)

        // The payload staging tree with normalized modes, as the DMG stage ends up: directories and
        // executables 755, other files 644 (the installed files land in /Applications owned root:admin, the
        // value the Bom below records). copyItem keeps the tree's mtimes, which the Bom and cpio then agree
        // on; the staging root's own mtime is taken from the app's, so the walk's "." entry is deterministic.
        try fm.copyItem(at: signedApp, to: payloadStage.appendingPathComponent(appName, isDirectory: true))
        if let mtime = (try? fm.attributesOfItem(atPath: signedApp.path)[.modificationDate]) as? Date {
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: payloadStage.path)
        }
        // copyItem keeps the whole tree's mtimes on macOS but drops the files' on Linux: apply the
        // source tree's own dates back over the copy, deepest first (so a directory is dated after
        // its children), skipping symlinks — a symlink's date is its own and copyItem preserves it.
        // Without this the Bom and the cpio payload carry the copy's wall clock, not the tree's.
        let stagedApp = payloadStage.appendingPathComponent(appName, isDirectory: true)
        for node in try walk(signedApp, checksums: false).reversed() {
            let path = node.path == "." ? stagedApp : stagedApp.appendingPathComponent(String(node.path.dropFirst("./".count)))
            guard node.kind != .symlink else { continue }
            try fm.setAttributes([.modificationDate: node.modificationDate], ofItemAtPath: path.path)
        }
        try run(["chmod", "-R", "u=rwX,go=rX", payloadStage.appendingPathComponent(appName).path], work)

        // The Payload: odc cpio.gz of the app tree, junk excluded the way every other archive is.
        let pkg = out.appendingPathComponent(fileName(product: pc.product))
        let payload = componentDir.appendingPathComponent("Payload")
        try run(["sh", "-c", cpioPipeline, "sh", payload.path], payloadStage)

        // The Bom from the staged tree, then the two XMLs, all written into the staging tree.
        let tree = try walk(payloadStage)
        try Bom.data(for: bomEntries(tree)).write(to: componentDir.appendingPathComponent("Bom"))
        let bytes = tree.filter { $0.kind == .file }.map(\.size).reduce(0, +)
        let t = Template(bundleID: bundleID, version: config.version, build: config.build, title: pc.product,
                         appPath: "./\(appName)", numberOfFiles: tree.count, installKBytes: (bytes + 1023) / 1024)
        try Data(distributionXML(t).utf8).write(to: work.appendingPathComponent("Distribution"))
        try Data(packageInfoXML(t).utf8).write(to: componentDir.appendingPathComponent("PackageInfo"))

        // The flat package: Apple's xar container, Distribution first, then the component's files in Apple's
        // order (Bom, Payload, PackageInfo — file arguments, so the TOC order is fixed regardless of readdir).
        try run(["xar", "-cf", pkg.path, "Distribution", "\(component)/Bom", "\(component)/Payload",
                 "\(component)/PackageInfo"], work)
        return pkg
    }

    /// `find . | sort | cpio -o -H odc | gzip`, the exact payload format Apple's own packages carry (odc magic
    /// `070707`, `./`-relative paths, TRAILER). Sorted byte-wise (LC_ALL=C): deterministic on every host and
    /// parents-before-children, which cpio's extraction requires. Constant text — every path stays in the cwd
    /// or `$1`, never in the command string, so arbitrary file names are safe; the exclusions are Packager's
    /// junk list.
    static let cpioPipeline =
        #"find . \( ! -name '*.DS_Store' ! -name '._*' ! -path '*/._*' \) -print | LC_ALL=C sort | cpio -o -H odc | gzip -c > "$1""#

    // MARK: - XML templates (productbuild's own output, verified 2026-10-31 · Build 26B123)

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The App Store distribution productbuild synthesizes from the component: the default choice, the
    /// component choice at `/Applications`, and the `#<bundle-id>.pkg` href productbuild writes when it
    /// flattens. Apple's synth also derives `volume-check`/`hostArchitectures` from the app's Info.plist —
    /// this template leaves them out (any OS, any architecture), the true productbuild minimum.
    private static func distributionXML(_ t: Template) -> String {
        let i = escape(t.bundleID), v = escape(t.version), title = escape(t.title)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="2">
            <pkg-ref id="\(i)"/>
            <product id="\(i)" version="\(v)"/>
            <title>\(title)</title>
            <options customize="never" require-scripts="false"/>
            <choices-outline>
                <line choice="default">
                    <line choice="\(i)"/>
                </line>
            </choices-outline>
            <choice id="default" title="\(title)" versStr="\(v)"/>
            <choice id="\(i)" title="\(title)" visible="false" customLocation="/Applications">
                <pkg-ref id="\(i)"/>
            </choice>
            <pkg-ref id="\(i)" version="\(v)" onConclusion="none">#\(i).pkg</pkg-ref>
        </installer-gui-script>
        """ + "\n"
    }

    /// The component summary productbuild's PackageInfo carries: what the payload installs (the bundle, at
    /// /Applications as root), the size and file count the installer reports, and the bundle the next build's
    /// package replaces (`upgrade-bundle` + `strict-identifier` — productbuild's component fields).
    private static func packageInfoXML(_ t: Template) -> String {
        let i = escape(t.bundleID), v = escape(t.version), b = escape(t.build)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info format-version="2" identifier="\(i)" version="\(v)" install-location="/Applications" auth="root">
            <payload installKBytes="\(t.installKBytes)" numberOfFiles="\(t.numberOfFiles)"/>
            <bundle path="\(escape(t.appPath))" id="\(i)" CFBundleShortVersionString="\(v)" CFBundleVersion="\(b)"/>
            <bundle-version>
                <bundle id="\(i)"/>
            </bundle-version>
            <upgrade-bundle>
                <bundle id="\(i)"/>
            </upgrade-bundle>
            <update-bundle/>
            <atomic-update-bundle/>
            <strict-identifier>
                <bundle id="\(i)"/>
            </strict-identifier>
            <relocate/>
        </pkg-info>
        """ + "\n"
    }

    struct Template {
        var bundleID: String
        var version: String
        var build: String
        var title: String
        var appPath: String              // `./Hello Tauri.app`, the payload component path
        var numberOfFiles: Int
        var installKBytes: UInt64
    }

    // MARK: - The tree walk (Bom entries and the PackageInfo counts)

    /// One staged-tree path, with what both the Bom and the PackageInfo counts need.
    struct TreeNode {
        var path: String                 // `.` then `./Hello Tauri.app/...`, the mkbom path shape
        var kind: Bom.Kind
        var mode: UInt16                 // permission bits only; the writer adds the kind's type bits
        var modificationDate: Date
        var size: UInt64                 // file bytes; symlinks size from their target like mkbom
        var checksum: UInt32
        var linkTarget: String?
    }

    /// Walks the staged app preorder, children sorted byte-wise in every directory (readdir order is not
    /// deterministic, and the Bom writer pins entry ids from the input order). A symlinked directory is a
    /// leaf: a bundle's `Versions/Current` is never descended into. Recursion is bounded: a bundle nested
    /// deeper than `maxDepth` directories is refused, not walked to stack exhaustion.
    static let maxDepth = 256

    /// One file's own metadata, `lstat`-read: mkbom records the entry's own stat (a symlink keeps its own
    /// mode bits and mtime, not its target's). Foundation's stat wrappers end in CarbonCore on macOS, which
    /// crashes (SIGBUS) on very deep paths — the very input the depth guard below exists for — so this goes
    /// straight to the C call, like `SigningKey` already does for `open`/`fchmod`.
    struct FileStat {
        var mode: UInt16                // permission bits
        var date: Date
        var size: UInt64
        var isDirectory: Bool
        var isSymlink: Bool
    }

    static func lstatInfo(_ path: String) throws -> FileStat {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw XlessError(.package, "cannot stat \(path)", fix: "re-run from package")
        }
        let mode = st.st_mode, size = UInt64(st.st_size), typeBits = mode & S_IFMT
        let date: Date
        // Linux (Glibc and Musl) has st_mtim; Darwin names the field st_mtimespec.
        #if canImport(Glibc) || canImport(Musl)
        date = Date(timeIntervalSince1970: Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9)
        #else
        date = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        #endif
        return FileStat(mode: UInt16(truncatingIfNeeded: mode) & 0o7777, date: date, size: size,
                        isDirectory: typeBits == S_IFDIR, isSymlink: typeBits == S_IFLNK)
    }

    /// The directory's entry names via `readdir` (sorted by the caller). Foundation's `contentsOfDirectory`
    /// enumerates through CarbonCore on macOS, which crashes (SIGBUS) on very deep paths — the input the
    /// depth guard exists for — so the walk stays on the C level throughout.
    static func listNames(_ path: String) throws -> [String] {
        guard let dir = opendir(path) else {
            throw XlessError(.package, "cannot read \(path)", fix: "re-run from package")
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    /// The symlink's target via `readlink`. Empty or over-long targets are refused.
    static func linkTarget(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = readlink(path, &buffer, buffer.count)
        guard n > 0, n < buffer.count else {
            throw XlessError(.package, "cannot read the target of the link \(path)",
                             fix: "re-run from package")
        }
        return String(decoding: buffer.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The file's bytes via `open`/`read` (Foundation's file reads go through FileHandle/CarbonCore on macOS).
    static func readFile(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw XlessError(.package, "cannot read \(path)", fix: "re-run from package") }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 18)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw XlessError(.package, "cannot read \(path)", fix: "re-run from package")
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0 ..< n])
            if n < buffer.count { break }   // short read: end of a regular file
        }
        return data
    }

    static func walk(_ root: URL, checksums: Bool = true) throws -> [TreeNode] {
        var tree: [TreeNode] = []
        let rootStat = try lstatInfo(root.path)
        tree.append(TreeNode(path: ".", kind: .directory, mode: rootStat.mode, modificationDate: rootStat.date,
                             size: 0, checksum: 0, linkTarget: nil))

        func walk(directory dirPath: String, prefix: String, depth: Int) throws {
            guard depth <= maxDepth else {
                throw XlessError(.package, "\(prefix) is nested deeper than \(maxDepth) directories",
                                 fix: "check the app bundle for runaway or hostile nesting")
            }
            // Children sorted byte-wise: readdir order is not deterministic, and the Bom writer pins entry
            // ids from the input order. String paths throughout: URL path math (CFURL) also crashes deep.
            let names = try listNames(dirPath).sorted {
                Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
            }
            for name in names {
                let path = dirPath + "/" + name
                let rel = prefix.isEmpty ? "./\(name)" : "\(prefix)/\(name)"
                let s = try lstatInfo(path)
                if s.isSymlink {
                    let target = try linkTarget(path)
                    // Symlink: a leaf, mode normalized to 777 (the builders' convention — the hosts' own
                    // link bits differ between macOS and Linux), its own stat for the record, size and
                    // digest from the target like mkbom.
                    tree.append(TreeNode(path: rel, kind: .symlink, mode: 0o777, modificationDate: s.date,
                                         size: UInt64(target.utf8.count), checksum: Bom.cksum(Data(target.utf8)),
                                         linkTarget: target))
                } else if s.isDirectory {
                    tree.append(TreeNode(path: rel, kind: .directory, mode: s.mode, modificationDate: s.date,
                                         size: 0, checksum: 0, linkTarget: nil))
                    try walk(directory: path, prefix: rel, depth: depth + 1)
                } else {
                    // The checksum walk reads every file; the date walk (`checksums: false`) only stats.
                    let data = checksums ? try readFile(path) : Data()
                    tree.append(TreeNode(path: rel, kind: .file, mode: s.mode, modificationDate: s.date,
                                         size: s.size, checksum: checksums ? Bom.cksum(data) : 0, linkTarget: nil))
                }
            }
        }
        try walk(directory: root.path, prefix: "", depth: 0)
        return tree
    }

    /// The walked tree as Bom entries, with the ownership the package installs: root:admin (0/80), the
    /// /Applications group Apple's own App-Store payloads carry — mkbom would keep the builder's uid, which
    /// differs between runners.
    static func bomEntries(_ tree: [TreeNode]) -> [Bom.Entry] {
        tree.map {
            Bom.Entry(path: $0.path, kind: $0.kind, mode: $0.mode, userID: 0, groupID: 80,
                      modificationDate: $0.modificationDate, size: $0.size, checksum: $0.checksum,
                      linkTarget: $0.linkTarget)
        }
    }

    // MARK: - The stage: fetch the certificate, assemble, sign

    /// Fetches the Apple Distribution certificate, assembles the package (`build`) and signs it with the
    /// same certificate (`rcodesign sign`, the seam the DMG path uses). The key is the Apple Distribution
    /// PEM (`XLESS_DIST_KEY`) the sign stage already used to sign the app.
    public static func appStore(signedApp: URL, outputDir: URL, config: ProjectConfig, secrets: Secrets,
                                run: (_ command: [String], _ cwd: URL) throws -> Void = shell) async throws -> URL {
        let kind = CertificateKind.distribution
        let key = try SigningKey(pem: secrets.required(kind.secretName, stage: .package))
        let client = ASCClient(credentials: try ASCCredentials.fromSecrets(secrets, stage: .package))
        let cert = try await CertificateService(client: client).find(matching: key, kind: kind)
        guard let der = cert.attributes.certificateContent.flatMap({ Data(base64Encoded: $0) }) else {
            throw XlessError(.package, "certificate \(cert.id) has no content",
                             fix: "re-run; if it persists, check the certificate in App Store Connect")
        }
        return try Files.atomicOutput(outputDir) { out in
            let pkg = try buildInto(out, signedApp: signedApp, config: config, run: run)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-pkg-sign-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: tmp) }
            let keyURL = tmp.appendingPathComponent("key.pem"), certURL = tmp.appendingPathComponent("cert.pem")
            guard FileManager.default.createFile(atPath: keyURL.path, contents: Data(key.pem.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw XlessError(.package, "cannot write temporary key files",
                                 fix: "check free space and permissions of the temp directory")
            }
            let certPEM = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
            try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
            try run(["rcodesign"] + signArguments(pkg: pkg, keyPEM: keyURL, certPEM: certURL), tmp)
            return pkg
        }
    }
}