import Foundation
import Crypto

/// The recipe hash of each part of an Xcode pack: a digest of exactly what the part is made from, so a pack is prepared
/// again when one of those inputs changes and never because the xless version did. Nothing here reads `XLESS_VERSION`.
public enum PackRecipe {
    /// The pack layout version. Part of every hash: changing it prepares every pack again.
    public static let format = 1

    /// `.own` when the Xcode's Swift is the image's own (`SWIFT_VERSION`), `.separate` otherwise.
    public static func mode(swift: String, table: [String: String]) -> FitMode {
        swift == table["SWIFT_VERSION"] ? .own : .separate
    }

    /// The open-source Swift release that Xcode build maps to (`XCODE_SWIFT_<build>`).
    public static func swiftVersion(build: String, table: [String: String]) throws -> String {
        guard let v = table["XCODE_SWIFT_\(build)"], !v.isEmpty else {
            throw XlessError(.sdk, "versions.env maps Xcode build \(build) to no Swift toolchain (XCODE_SWIFT_\(build))",
                             fix: "use a supported Xcode")
        }
        return v
    }

    /// `table`: versions.env, parsed (`KnownXcodes.parseEnv`). `share`: the share directory (`scripts/`, `docker/toolchain/`).
    ///
    /// The order of the inputs is fixed, since changing it changes every hash. Each is fed as `name\0length\0bytes`:
    /// - both parts: `format`
    /// - `.sdk`: the files `scripts/fit-toolchain.sh`, `docker/toolchain/clang-driver`, `target-os-check`, `record-flags.py`,
    ///   `target-os/derived.txt`, `target-os/<build>.txt`; the toolchain's `…_URL_<ARCH>` then `…_SHA256_<ARCH>`; `mode`;
    ///   every table entry whose key ends in `_<build>` but the .xip checksums (`XCODE_XIP_SHA256_<build>`), by key;
    ///   `XTOOL_VERSION`; `build`
    /// - `.swiftBuild`: `SWB_TAG`; every `SWB_*` entry by key; the toolchain's `…_SHA256_<ARCH>`; the distribution of
    ///   `SWIFT_IMAGE` (`jammy`); the file `scripts/pack-swift-build.sh`
    public static func hash(_ part: PackPart, build: String, arch: String, table: [String: String], share: URL) throws -> String {
        var sha = SHA256()
        func feed(_ name: String, _ bytes: Data) {
            sha.update(data: Data("\(name)\0\(bytes.count)\0".utf8))
            sha.update(data: bytes)
        }
        func feed(_ name: String, _ text: String) { feed(name, Data(text.utf8)) }
        func file(_ path: String) throws {
            let url = share.appendingPathComponent(path)
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw XlessError(.sdk, "xless's \(path) is missing from \(share.path)", fix: "install xless again, or set XLESS_SHARE to its share directory")
                }
                throw XlessError(.sdk, "xless's \(path) in \(share.path) cannot be read: \(error.localizedDescription)",
                                 fix: "make it readable (its permissions), or install xless again")
            }
            feed(path, data)
        }
        func pin(_ key: String) throws -> String {
            guard let v = table[key], !v.isEmpty else {
                throw XlessError(.sdk, "versions.env has no \(key)", fix: "use a supported Xcode, or update xless")
            }
            return v
        }

        let swift = try swiftVersion(build: build, table: table)
        let toolchain = "SWIFT_TOOLCHAIN_\(swift.replacingOccurrences(of: ".", with: "_"))"
        let a = tableArch(arch)

        feed("format", String(format))
        switch part {
        case .sdk:
            for path in ["scripts/fit-toolchain.sh", "docker/toolchain/clang-driver", "docker/toolchain/target-os-check",
                         "docker/toolchain/record-flags.py", "docker/toolchain/target-os/derived.txt",
                         "docker/toolchain/target-os/\(build).txt"] { try file(path) }
            for key in ["\(toolchain)_URL_\(a)", "\(toolchain)_SHA256_\(a)"] { feed(key, try pin(key)) }
            feed("mode", mode(swift: swift, table: table).rawValue)
            // The .xip checksums are left out: another vetted .xip of the same Xcode makes the same pack.
            for key in table.keys.filter({ $0.hasSuffix("_\(build)") && !$0.hasPrefix(xipChecksumPrefix) }).sorted() { feed(key, table[key]!) }
            feed("XTOOL_VERSION", try pin("XTOOL_VERSION"))
            feed("build", build)
        case .swiftBuild:
            feed("SWB_TAG", try pin("SWB_TAG"))
            for key in table.keys.filter({ $0.hasPrefix("SWB_") }).sorted() { feed(key, table[key]!) }
            let sha256 = "\(toolchain)_SHA256_\(a)"
            feed(sha256, try pin(sha256))
            let image = try pin("SWIFT_IMAGE")
            guard let at = image.firstIndex(of: "@"), let dash = image[..<at].lastIndex(of: "-") else {
                throw XlessError(.sdk, "versions.env's SWIFT_IMAGE (\(image)) is not <name>-<distribution>@<digest>", fix: "update xless")
            }
            feed("distribution", String(image[image.index(after: dash)..<at]))
            try file("scripts/pack-swift-build.sh")
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The key of an Xcode's vetted .xip checksums (`XCODE_XIP_SHA256_<build>`): no input of a pack.
    static let xipChecksumPrefix = "XCODE_XIP_SHA256_"

    /// versions.env's spelling of an architecture: AARCH64 / X86_64 (and the downloads' aarch64 / x86_64).
    public static func tableArch(_ arch: String) -> String { arch == "arm64" ? "AARCH64" : "X86_64" }
}
