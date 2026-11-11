import Foundation
import Crypto
import XlessCore

/// The Xcode `xless setup` builds images from: a downloaded `.xip`, identified by its content (SHA-256 against the
/// supported-Xcode table; the file name is ignored), or an `Xcode.app`, identified by its `Contents/version.plist`.
/// Nothing is executed and the archive is never expanded here: xtool reads it inside the base image.
/// Or, in place of the Xcode, an SDK export an earlier setup left (`export`, the directory holding `<arch>/darwin.xtoolsdk`
/// and toolchain-meta.json): reused as is, so neither the .xip nor the Xcode.app is needed again.
public enum XcodeSource {
    /// `export`: the url is an SDK export, not an Xcode; nothing can be exported from it.
    public enum Kind: Equatable, Sendable { case xip, app, export }
    public typealias Identified = (xcode: KnownXcode, kind: Kind, url: URL)

    public static let architectures = ["arm64", "amd64"]

    /// An SDK export, identified by its toolchain-meta.json's `xcodeBuild` (without one, by its directory name,
    /// `xcode<V>-<B>`), which must be a supported Xcode's.
    public static func identifyExport(path: String, known: [KnownXcode], cwd: URL, home: URL) throws -> Identified {
        let url = absolute(path, cwd: cwd, home: home)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw XlessError(.sdk, "\(url.path) does not exist", fix: "pass the directory xless setup exported the SDK into with --sdk (under ~/.cache/xless/sdk/)")
        }
        guard isDir.boolValue, !exportedArchs(url).isEmpty else {
            // The architecture's directory or its darwin.xtoolsdk: name the export it belongs to.
            let parent = [url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent()]
                .first { !exportedArchs($0).isEmpty }
            throw XlessError(.sdk, "\(url.path) holds no SDK export (<arch>/darwin.xtoolsdk)",
                             fix: parent.map { "pass the export itself: --sdk \($0.path)" }
                                ?? "pass the directory xless setup exported the SDK into (e.g. ~/.cache/xless/sdk/xcode<V>-<B>), or the Xcode with --xcode")
        }
        let build = (try? ToolchainMeta.load(from: url.appendingPathComponent("toolchain-meta.json")))?.xcodeBuild
            ?? exportBuild(directoryName: url.lastPathComponent)
        guard let build else {
            throw XlessError(.sdk, "\(url.path) has no toolchain-meta.json naming its Xcode",
                             fix: "export it again: xless setup --xcode <Xcode .xip or Xcode.app> --reexport")
        }
        guard let x = known.first(where: { $0.build == build }) else {
            let list = known.map { "Xcode \($0.shortVersion) (\($0.build))" }.joined(separator: ", ")
            throw XlessError(.sdk, "\(url.path) is an SDK export of Xcode build \(build), not a supported Xcode (supported: \(list))",
                             fix: "use an export of a supported Xcode, or pass that Xcode with --xcode")
        }
        return (x, .export, url)
    }

    /// The architectures `dir` holds a complete export for (`<arch>/darwin.xtoolsdk`; never an `<arch>.partial`).
    public static func exportedArchs(_ dir: URL) -> [String] {
        architectures.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0)/darwin.xtoolsdk").path) }
            .sorted()
    }

    /// Refuses an export that lacks one of `archs`: nothing could export it without the Xcode.
    public static func checkExport(_ dir: URL, holds archs: [String]) throws {
        let has = exportedArchs(dir)
        let missing = archs.filter { !has.contains($0) }
        guard missing.isEmpty else {
            throw XlessError(.sdk, "the SDK export \(dir.path) holds no \(missing.joined(separator: " or ")) SDK (it holds \(has.joined(separator: ", ")))",
                             fix: "pass the Xcode to export it: xless setup --xcode <Xcode .xip or Xcode.app>")
        }
    }

    /// With no `--xcode` and no `--sdk`: the one export under `<cacheRoot>/sdk` of a supported Xcode that holds every
    /// architecture in `archs`. None, or several, is refused, naming what to pass.
    public static func findExport(cacheRoot: URL, known: [KnownXcode], archs: [String]) throws -> Identified {
        let sdk = cacheRoot.appendingPathComponent("sdk")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sdk.path)) ?? []).sorted()
        var exports: [Identified] = [], skipped: [String] = []
        for name in names {
            let dir = sdk.appendingPathComponent(name)
            if let e = try? identifyExport(path: dir.path, known: known, cwd: sdk, home: sdk) { exports.append(e) }
            else if !exportedArchs(dir).isEmpty { skipped.append(name) }   // an export, of an Xcode no longer supported
        }
        let fit = exports.filter { e in archs.allSatisfy(exportedArchs(e.url).contains) }
        let wanted = archs.joined(separator: " and ")
        if fit.count == 1 { return fit[0] }
        if fit.count > 1 {
            throw XlessError(.sdk, "\(sdk.path) holds \(fit.count) SDK exports for \(wanted) (\(fit.map(\.url.lastPathComponent).joined(separator: ", ")))",
                             fix: "pick one: xless setup --sdk \(fit.last!.url.path) (or --xcode <Xcode .xip or Xcode.app>)")
        }
        let pass = "xless setup --xcode <Xcode .xip or Xcode.app> (the Universal Xcode .xip from https://developer.apple.com/download/all/, free Apple ID)"
        guard !exports.isEmpty else {
            let note = skipped.isEmpty ? "" : " (skipped \(skipped.joined(separator: ", ")): not a supported Xcode)"
            throw XlessError(.sdk, "no --xcode, and no SDK export under \(sdk.path) to reuse\(note)", fix: "pass the Xcode: \(pass)")
        }
        let held = exports.map { "\($0.url.lastPathComponent) holds \(exportedArchs($0.url).joined(separator: ", "))" }.joined(separator: "; ")
        throw XlessError(.sdk, "no SDK export under \(sdk.path) holds \(wanted) (\(held))", fix: "pass the Xcode to export it: \(pass)")
    }

    /// `xcode<V>-<B>` (SetupPlan.sdkDir's name) → B.
    static func exportBuild(directoryName name: String) -> String? {
        guard name.hasPrefix("xcode"), let dash = name.lastIndex(of: "-") else { return nil }
        let b = name[name.index(after: dash)...]
        return b.isEmpty ? nil : String(b)
    }

    public static func identify(path: String, known: [KnownXcode], cwd: URL, home: URL) throws -> Identified {
        let url = absolute(path, cwd: cwd, home: home)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw XlessError(.sdk, "\(url.path) does not exist", fix: "pass the path to an Xcode .xip or Xcode.app with --xcode")
        }
        if isDir.boolValue {
            let plist = try? Plist.read(url.appendingPathComponent("Contents/version.plist"), stage: .sdk)
            if let build = plist?["ProductBuildVersion"] as? String, let x = known.first(where: { $0.build == build }) {
                return (x, .app, url)
            }
        } else {
            let hashes = Set(known.flatMap(\.xipSHA256).map { $0.lowercased() })
            if !hashes.isEmpty {
                let sum = try sha256(of: url)
                if let x = known.first(where: { $0.xipSHA256.contains { $0.lowercased() == sum } }) { return (x, .xip, url) }
            }
        }
        throw unsupported(url.path, known: known)
    }

    /// `~` and `~/…` against `home`, a relative path against `cwd`; `.` and `..` resolved, symlinks kept.
    public static func absolute(_ path: String, cwd: URL, home: URL) -> URL {
        var p = path
        if p == "~" { p = home.path } else if p.hasPrefix("~/") { p = home.path + String(p.dropFirst(1)) }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : cwd.appendingPathComponent(p)
        return url.standardizedFileURL
    }

    public static func unsupported(_ path: String, known: [KnownXcode]) -> XlessError {
        let list = known.map { "Xcode \($0.shortVersion) (\($0.build))" }.joined(separator: ", ")
        let versions = known.map(\.shortVersion)
        let spoken = versions.count <= 1 ? versions.joined()
            : versions.dropLast().joined(separator: ", ") + " or " + versions.last!
        return XlessError(.sdk, "\(path) is not a supported Xcode (supported: \(list))",
                          fix: "download the Universal Xcode \(spoken) .xip from https://developer.apple.com/download/all/ (free Apple ID)")
    }

    /// The file's SHA-256 (lowercase hex), read in chunks: an Xcode .xip is several GB. read(2) into one reused buffer
    /// keeps memory flat; FileHandle.read(upToCount:) returns autoreleased Data on Darwin, which piles up to the file's size.
    public static func sha256(of url: URL, chunkSize: Int = 8 << 20) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw XlessError(.sdk, "cannot read \(url.path): \(String(cString: strerror(errno)))", fix: "check the file's permissions")
        }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
            if n < 0 {
                if errno == EINTR { continue }
                throw XlessError(.sdk, "cannot read \(url.path): \(String(cString: strerror(errno)))", fix: "check the file and the disk")
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(n))) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
