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
        let names = (try? Data(contentsOf: exe)).flatMap { try? MachO.sliceArchitectures(in: $0).map(\.name) } ?? []
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
        let img = work.appendingPathComponent("img.hfs").path, stage = stageDir(work).path
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
    /// executables 755, other files 644, because `addall` copies each `st_mode` as is), then builds `<outputDir>/<name>.dmg`.
    /// `architectures` name the DMG (`fileName`).
    @discardableResult
    public static func build(signedApp: URL, volumeName: String, version: String, architectures: [MacArchitecture] = MacArchitecture.allCases,
                             outputDir: URL, run: ([String]) throws -> Void = DmgBuilder.shell) throws -> URL {
        try Files.atomicOutput(outputDir) { out in
            try buildInto(out, signedApp: signedApp, volumeName: volumeName, version: version, architectures: architectures, run: run)
        }
    }

    static func buildInto(_ out: URL, signedApp: URL, volumeName: String, version: String, architectures: [MacArchitecture],
                          run: ([String]) throws -> Void) throws -> URL {
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
            do { try run(argv) } catch {
                if "\(error)".contains("cannot start "), ["dmg", "hfsplus", "mkfs.hfsplus"].contains(argv[0]) {
                    throw XlessError(.package, "cannot start \(argv[0]) to build the DMG",
                                     fix: "install libdmg-hfsplus and hfsprogs (use the xless-tauri image)")
                }
                throw error
            }
        }
        return dmg
    }

    /// Builds the DMG, signs it with the Developer ID key (a DMG is signed after imaging; the app was signed before), submits
    /// it to the notary service, waits, staples the ticket in place and checks that the ticket is there. The DMG is named
    /// after the architectures of the app's executable (`architectures(ofApp:)`).
    public static func notarizedDMG(signedApp: URL, outputDir: URL, config: ProjectConfig, secrets: Secrets) async throws -> URL {
        let product = try config.platform(.macos).product
        let built = try architectures(ofApp: signedApp)
        let kind = CertificateKind.developerID
        let key = try SigningKey(pem: secrets.required(kind.secretName, stage: .package))
        let client = ASCClient(credentials: try ASCCredentials.fromSecrets(secrets, stage: .package))
        let cert = try await CertificateService(client: client).find(matching: key, kind: kind)
        guard let der = cert.attributes.certificateContent.flatMap({ Data(base64Encoded: $0) }) else {
            throw XlessError(.package, "certificate \(cert.id) has no content", fix: "re-run; if it persists, check the certificate in App Store Connect")
        }
        return try Files.atomicOutput(outputDir) { out in
            let dmg = try buildInto(out, signedApp: signedApp, volumeName: product, version: config.version, architectures: built,
                                    run: DmgBuilder.shell)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-notary-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: tmp) }
            let keyURL = tmp.appendingPathComponent("key.pem"), certURL = tmp.appendingPathComponent("cert.pem")
            let p8 = tmp.appendingPathComponent("key.p8"), keyJSON = tmp.appendingPathComponent("key.json")
            guard FileManager.default.createFile(atPath: keyURL.path, contents: Data(key.pem.utf8), attributes: [.posixPermissions: 0o600]),
                  FileManager.default.createFile(atPath: p8.path, contents: try Packager.p8Contents(secrets), attributes: [.posixPermissions: 0o600]) else {
                throw XlessError(.package, "cannot write temporary key files", fix: "check free space and permissions of the temp directory")
            }
            let certPEM = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
            try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
            try Shell.run("rcodesign", RCodesign.encodeKeyArguments(issuerID: secrets.identifier("ASC_ISSUER_ID", stage: .package),
                                                                    keyID: secrets.identifier("ASC_KEY_ID", stage: .package),
                                                                    p8: p8, out: keyJSON), stage: .package)
            try Shell.run("rcodesign", signArguments(dmg: dmg, keyPEM: keyURL, certPEM: certURL), stage: .package)
            try notarize(dmg: dmg, apiKeyJSON: keyJSON)
            try checkStapled(dmg: dmg)
            return dmg
        }
    }

    /// The DMG's signature: Developer ID key and certificate, no entitlements, no runtime flag (those belong to the app).
    static func signArguments(dmg: URL, keyPEM: URL, certPEM: URL) -> [String] {
        ["sign", "--pem-file", keyPEM.path, "--pem-file", certPEM.path, dmg.path]
    }

    /// One `rcodesign notary-submit` run: its full output and, when it exited non-zero, the error.
    struct NotaryRun { var log: String; var failure: XlessError? }

    static func runNotary(_ args: [String]) throws -> NotaryRun {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("xless-notary-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        do {
            try Shell.run("rcodesign", args, stage: .package, captureTo: logURL)
            return NotaryRun(log: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "", failure: nil)
        } catch let e as XlessError where !e.cause.hasPrefix("cannot start ") {
            return NotaryRun(log: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "", failure: e)
        }
    }

    /// rcodesign streams its output to the terminal (see `runNotary`); this logs the submission id and the final status, and
    /// reports a rejection only when Rejected/Invalid was parsed. Any other failure (network, auth, wait timeout, staple after
    /// Accepted) is rethrown as it is, with the id when known.
    static func notarize(dmg: URL, apiKeyJSON: URL, run: ([String]) throws -> NotaryRun = runNotary) throws {
        let r = try run(RCodesign.notarizeArguments(bundle: dmg, apiKeyJSON: apiKeyJSON))
        let id = submissionID(in: r.log), status = notaryStatus(in: r.log)
        FileHandle.standardError.write(Data("notary submission \(id ?? "unknown"): \(status ?? (r.failure == nil ? "status unknown (rcodesign exited 0)" : "status unknown"))\n".utf8))
        if let status, status == "Rejected" || status == "Invalid" { throw rejection(file: dmg.lastPathComponent, status: status) }
        if let f = r.failure {
            throw XlessError(f.stage, f.cause + (id.map { " (notary submission \($0))" } ?? ""), fix: f.fix)
        }
    }

    /// Fails unless the DMG's signature carries a stapled notarization ticket (read back with `rcodesign print-signature-info`).
    static func checkStapled(dmg: URL, signatureInfo: (URL) throws -> String = { try Shell.run("rcodesign", ["print-signature-info", $0.path], stage: .package).stdout }) throws {
        let info = try signatureInfo(dmg)
        guard hasStapledTicket(signatureInfo: info) else {
            throw XlessError(.package, "\(dmg.lastPathComponent) has no stapled notarization ticket after notary-submit --staple",
                             fix: "re-run from package; if notarization was accepted, `rcodesign staple \(dmg.lastPathComponent)` staples the ticket")
        }
        FileHandle.standardError.write(Data("notarization ticket stapled to \(dmg.lastPathComponent)\n".utf8))
    }

    /// A stapled DMG's embedded signature has a `Ticket` blob (slot 65538), listed by `rcodesign print-signature-info` as
    /// `- slot: Ticket (65538)` among the superblob's blobs; an unstapled one has CodeDirectory, RequirementSet and CMS only
    /// (rcodesign 0.29.0, checked against the spike's stapled and unstapled DMGs).
    static func hasStapledTicket(signatureInfo: String) -> Bool {
        signatureInfo.contains(/(?m)^\s*-\s*slot:\s*Ticket\s*\(65538\)\s*$/)
    }

    static func rejection(file: String, status: String) -> XlessError {
        XlessError(.package, "notarization of \(file) was rejected (\(status))",
                   fix: "read the notary log printed above, fix the reported binaries, then re-run from package")
    }

    /// The first "submission ID" in rcodesign's output.
    static func submissionID(in text: String) -> String? {
        text.firstMatch(of: /(?i)submission ID[: ]+([0-9a-f-]{36})/).map { String($0.1).lowercased() }
    }

    /// The last status from rcodesign's poll or status lines (`poll state after …: Accepted`, `status: Invalid`), never from
    /// words inside the notary log's issue text.
    static func notaryStatus(in text: String) -> String? {
        text.matches(of: /(?im)^\s*(?:poll state after[^\n]*?|status)[: ]+(Accepted|Rejected|Invalid|InProgress)\s*$/).last.map { String($0.1) }
    }
}
