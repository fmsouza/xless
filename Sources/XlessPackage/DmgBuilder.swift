import Foundation
import XlessASC
import XlessCore
import XlessMachO
import XlessSign

/// Builds, signs, notarizes and staples a macOS DMG on Linux, without hdiutil: an HFS+ volume (mkfs.hfsplus + libdmg-hfsplus's
/// `hfsplus`) compressed by `dmg`. The sequence is the one proven by the m2c Task 3 spike (docs/research/tauri-ios-contract.md,
/// "macOS DMG — spike findings"). Every tool runs from an argv array, never a shell, so volume names with spaces or non-ASCII
/// characters are safe.
public enum DmgBuilder {
    /// Tauri's bundle name: `<productName>_<version>_<arch>.dmg`, where `<arch>` is `universal` for both architectures,
    /// else Tauri's name for the one: `aarch64` or `x64`.
    public static func fileName(product: String, version: String, architectures: [MacArchitecture] = MacArchitecture.allCases) -> String {
        let arch = switch Set(architectures) {
        case [.arm64]: "aarch64"
        case [.x86_64]: "x64"
        default: "universal"
        }
        return "\(product)_\(version)_\(arch).dmg"
    }

    /// The architectures of the app's main executable (`Contents/MacOS/<CFBundleExecutable>`): what the app was built for,
    /// whatever the overlay says now (`--from package` reuses a signed app).
    public static func architectures(ofApp app: URL) throws -> [MacArchitecture] {
        let info = try Plist.read(app.appendingPathComponent("Contents/Info.plist"), stage: .package)
        let name = info["CFBundleExecutable"] as? String ?? app.deletingPathExtension().lastPathComponent
        let exe = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        let names = (name.contains("/") ? nil : try? Data(contentsOf: exe)).flatMap { try? MachO.sliceArchitectures(in: $0).map(\.name) } ?? []
        let found = names.compactMap(MacArchitecture.init(rawValue:))
        guard !found.isEmpty, found.count == names.count else {
            let listed = names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
            throw XlessError(.package, "cannot read the architectures of \(app.lastPathComponent)'s executable \(name)\(listed)",
                             fix: "re-run from build: the executable must be an arm64 and/or x86_64 Mach-O")
        }
        return MacArchitecture.allCases.filter(found.contains)
    }

    /// What `build` runs after the stage is ready (modes normalised): zeroed image, filesystem, contents, `/Applications` link, DMG.
    /// `--symlinks clone_link` keeps symlinks inside the .app (framework `Versions/Current`); `--special-modes no` stops hfsplus
    /// from applying its iOS-restore chmod rules; modes come from the staged files.
    public static func commands(app: URL, volumeName: String, work: URL, out: URL, sizeKB: Int) -> [[String]] {
        let img = imageFile(work).path, stage = stageDir(work).path
        _ = app   // the app is copied into `stage` by `build`; `addall` reads it from there
        return [
            ["dd", "if=/dev/zero", "of=\(img)", "bs=1k", "count=\(sizeKB)", "status=none"],
            ["mkfs.hfsplus", "-v", volumeName, img],
            ["hfsplus", "--symlinks", "clone_link", "--special-modes", "no", img, "addall", stage],
            ["hfsplus", img, "symlink", "/Applications", "/Applications"],
            ["dmg", "-c", "zlib", "build", img, out.path],
        ]
    }

    static func stageDir(_ work: URL) -> URL { work.appendingPathComponent("stage", isDirectory: true) }
    static func imageFile(_ work: URL) -> URL { work.appendingPathComponent("img.hfs") }

    /// Content size + 30 % + 4 MiB for the catalog/extents B-trees and the volume headers, in KiB. Content is counted in
    /// 4 KiB blocks per entry (files, directories and symlinks), which never undercounts.
    static func sizeKB(of dir: URL) -> Int {
        var blocks = 0
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [])
        while let url = e?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            blocks += max(1, (size + 4095) / 4096)
        }
        return blocks * 4 * 13 / 10 + 4096
    }

    public static func shell(_ argv: [String]) throws {
        try Shell.run(argv[0], Array(argv.dropFirst()), stage: .package)
    }

    /// Copies the signed app into a container-local stage (modes normalised the way create-dmg ends up: directories and
    /// executables 755, other files 644, because `addall` copies each `st_mode` as is; the whole stage, so the builder's
    /// umask never shows), then builds `<outputDir>/<name>.dmg`. Before the volume is compressed, `pin` gives it the app's
    /// own dates and a volume UUID from its content (`pinDates`), so the same app makes the same DMG bytes at any time.
    /// `architectures` name the DMG (`fileName`). The dSYMs (`dSYMs`, when there are any) are zipped next to it
    /// (`Packager.zipDSYMs`).
    @discardableResult
    public static func build(signedApp: URL, volumeName: String, version: String, architectures: [MacArchitecture] = MacArchitecture.allCases,
                             outputDir: URL, dSYMs: URL? = nil, pin: (_ image: URL, _ app: URL) throws -> Void = DmgBuilder.pinDates,
                             run: ([String]) throws -> Void = DmgBuilder.shell) throws -> URL {
        try Files.atomicOutput(outputDir) { out in
            try buildInto(out, signedApp: signedApp, volumeName: volumeName, version: version, architectures: architectures, dSYMs: dSYMs,
                          pin: pin, run: run)
        }
    }

    /// mkfs.hfsplus and libdmg's `hfsplus` date the volume and every entry with the time of the run (libdmg never reads
    /// the source's mtimes), and mkfs draws a random volume UUID: pins each entry to its date in the signed app
    /// (`sourceDate`), everything else to the app's own date (`HFSPlusDates.pin`).
    public static func pinDates(image: URL, app: URL) throws {
        let appDate = try PkgBuilder.lstatInfo(app.path).date
        try HFSPlusDates.pin(image: image, fallback: appDate) { sourceDate($0, app: app) }
    }

    /// The modification date (a symlink's own) of the volume entry at `path` (relative to the volume root, where the
    /// stage puts the app under its own name), read from the signed app; nil for a path outside the app or not in it.
    static func sourceDate(_ path: String, app: URL) -> Date? {
        let name = app.lastPathComponent
        guard path == name || path.hasPrefix(name + "/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return try? PkgBuilder.lstatInfo(parts.reduce(app) { $0.appendingPathComponent(String($1)) }.path).date
    }

    static func buildInto(_ out: URL, signedApp: URL, volumeName: String, version: String, architectures: [MacArchitecture],
                          dSYMs: URL? = nil, pin: (_ image: URL, _ app: URL) throws -> Void = DmgBuilder.pinDates,
                          run: ([String]) throws -> Void) throws -> URL {
        try Packager.zipDSYMs(dSYMs, app: signedApp, into: out)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("xless-dmg-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let stage = stageDir(work)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.copyItem(at: signedApp, to: stage.appendingPathComponent(signedApp.lastPathComponent))
        let dmg = out.appendingPathComponent(fileName(product: volumeName, version: version, architectures: architectures))
        let steps = [["chmod", "-R", "u=rwX,go=rX", stage.path]]
            + commands(app: signedApp, volumeName: volumeName, work: work, out: dmg, sizeKB: sizeKB(of: stage))
        for argv in steps {
            if argv[0] == "dmg" { try pin(imageFile(work), signedApp) }
            do { try run(argv) } catch {
                if "\(error)".contains("cannot start "), ["dmg", "hfsplus", "mkfs.hfsplus"].contains(argv[0]) {
                    throw XlessError(.package, "cannot start \(argv[0]) to build the DMG",
                                     fix: "install libdmg-hfsplus and hfsprogs (xless's Docker images have them)")
                }
                throw error
            }
        }
        return dmg
    }

    /// Builds the DMG, signs it with the Developer ID key (a DMG is signed after imaging; the app was signed before), submits
    /// it to the notary service, waits, staples the ticket in place and checks that the ticket is there. The DMG is named
    /// after the architectures of the app's executable (`architectures(ofApp:)`); the dSYMs are zipped next to it.
    public static func notarizedDMG(signedApp: URL, outputDir: URL, config: ProjectConfig, secrets: Secrets, dSYMs: URL? = nil) async throws -> URL {
        let product = try config.platform(.macos).product
        let built = try architectures(ofApp: signedApp)
        let kind = CertificateKind.developerID
        let key = try SigningKey(pem: secrets.required(kind.secretName, stage: .package))
        let client = ASCClient(credentials: try ASCCredentials.fromSecrets(secrets, stage: .package))
        let cert = try await ASCCertificates(resources: ASCResources(client: client)).find(for: key, kind: kind)
        return try Files.atomicOutput(outputDir) { out in
            let dmg = try buildInto(out, signedApp: signedApp, volumeName: product, version: config.version, architectures: built,
                                    dSYMs: dSYMs, run: DmgBuilder.shell)
            try PrivateFiles.with(stage: .package) { files in
                let signer = try files.signer(key: key, certificate: cert.der)
                try RCodesign.run(signArguments(dmg: dmg, keyPEM: signer.key, certPEM: signer.certificate), stage: .package)
            }
            try Notary.notarize(dmg, secrets: secrets)
            try Notary.checkStapled(dmg: dmg)
            return dmg
        }
    }

    /// The DMG's signature: Developer ID key and certificate, no entitlements, no runtime flag (those belong to the app).
    static func signArguments(dmg: URL, keyPEM: URL, certPEM: URL) -> [String] {
        ["sign", "--pem-file", keyPEM.path, "--pem-file", certPEM.path, dmg.path]
    }
}
