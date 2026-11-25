import Foundation
import XlessCore

/// The released Linux xless binaries `xless setup` puts into the image for an arch it is not running on (Ruling R1):
/// `xless-<version>-linux-<x86_64|arm64>.tar.gz` (top directory `xless-<version>-linux-<arch>/`, binary at `bin/xless`)
/// with `SHA256SUMS` beside it in the GitHub release `v<version>`.
public enum XlessRelease {
    public static let downloadBase = "https://github.com/fmsouza/xless/releases/download"

    /// Docker's arch name to the release's (uname's): amd64 → x86_64, arm64 → arm64.
    public static func releaseArch(dockerArch: String) -> String { dockerArch == "amd64" ? "x86_64" : dockerArch }

    public static func tarballName(version: String, dockerArch: String) -> String {
        "xless-\(version)-linux-\(releaseArch(dockerArch: dockerArch)).tar.gz"
    }

    public static func url(version: String, file: String) -> URL {
        URL(string: "\(downloadBase)/v\(version)/\(file)")!
    }

    /// Checks the tarball against its `SHA256SUMS` line (`<hex>  <name>`, as sha256sum writes it).
    public static func verify(tarball: URL, name: String, sums: String) throws {
        let want = sums.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count == 2, f[1] == name || f[1] == "*\(name)" else { return nil }
            return f[0].lowercased()
        }.first
        guard let want else {
            throw XlessError(.sdk, "SHA256SUMS of the release does not list \(name)", fix: "check the release, or set XLESS_BIN_<ARCH> to a Linux xless")
        }
        let got = try XcodeSource.sha256(of: tarball)
        guard got == want else {
            throw XlessError(.sdk, "\(name) does not match the release's SHA256SUMS (got \(got), want \(want))",
                             fix: "download it again; if it keeps failing, report it (the release may have been tampered with)")
        }
    }

    /// Extracts `xless-<version>-linux-<arch>/bin/xless` and returns it as `<into>/xless`.
    public static func extractBinary(tarball: URL, version: String, dockerArch: String, into dir: URL) throws -> URL {
        let top = "xless-\(version)-linux-\(releaseArch(dockerArch: dockerArch))"
        let unpack = dir.appendingPathComponent("unpack")
        try? FileManager.default.removeItem(at: unpack)
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        try Shell.run("tar", ["-xzf", tarball.path, "-C", unpack.path, "\(top)/bin/xless"], stage: .sdk)
        let bin = dir.appendingPathComponent("xless")
        try? FileManager.default.removeItem(at: bin)
        try FileManager.default.moveItem(at: unpack.appendingPathComponent("\(top)/bin/xless"), to: bin)
        try? FileManager.default.removeItem(at: unpack)
        return bin
    }

    /// The Docker arch of a Linux ELF binary, from its e_machine (183 aarch64 → arm64, 62 x86-64 → amd64); nil otherwise.
    public static func elfDockerArch(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 20), d.count == 20, Array(d.prefix(4)) == [0x7f, 0x45, 0x4c, 0x46] else { return nil }
        switch UInt16(d[18]) | UInt16(d[19]) << 8 {
        case 183: return "arm64"
        case 62: return "amd64"
        default: return nil
        }
    }
}
