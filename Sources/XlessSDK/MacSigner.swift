import Foundation
import XlessCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// rcodesign on a Mac, the program that gets the signing key: a copy of xless's own, started by its path and never found on PATH. It is
/// fetched once, by the first command that signs, and kept with the archive that it is from. Each command that signs compares the
/// archive with its pin in versions.env, and the program with the archive's, and refuses a place that somebody else can write.
public struct MacSigner: Sendable {
    public let download: NativeDownload

    public init(download: NativeDownload) { self.download = download }

    public init(env: [String: String], arch: String, table: [String: String]) throws {
        let layout = NativeLayout(env: env)
        for name in ["XLESS_NATIVE_HOME", "XDG_DATA_HOME", "HOME"] {
            guard let place = env[name], !place.isEmpty else { continue }
            guard place.hasPrefix("/") else { // (another place in each directory that a command runs in)
                throw XlessError(.sdk, "\(name)=\(place) is no absolute path", fix: "set it to one")
            }
            break
        }
        self.init(download: try NativeSetupPlan.rcodesign(arch: arch, mac: true, table: table, layout: layout))
    }

    private var directory: URL { download.final }
    public var program: URL { directory.appendingPathComponent("rcodesign") }
    private var archive: URL { directory.appendingPathComponent(download.url.lastPathComponent) }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: program.path) }

    /// The program, there and as it is pinned. `fetch` downloads what is at a URL into a file.
    public func prepare(fetch: (_ from: URL, _ into: URL) throws -> Void) throws -> URL {
        try Self.makePrivate(directory)
        try refuseSharedPlace(directory)
        try withLock {
            if try !isPinned(archive) { try fetchArchive(fetch) }
            try placeProgram()
        }
        for file in [archive, program] { try refuseSharedPlace(file) }
        return program
    }

    private func isPinned(_ file: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try XcodeSource.sha256(of: file) == download.sha256.lowercased()
    }

    private func fetchArchive(_ fetch: (URL, URL) throws -> Void) throws {
        let new = try temporary()
        defer { try? FileManager.default.removeItem(at: new) }
        let file = new.appendingPathComponent("download")
        try fetch(download.url, file)
        guard try isPinned(file) else {
            throw XlessError(.sdk, "\(download.url.absoluteString) has sha256 \(try XcodeSource.sha256(of: file)), not versions.env's \(download.sha256): nothing was installed",
                             fix: "run it again; if it persists, report it (the download changed upstream)")
        }
        try Self.put(file, at: archive, mode: 0o600)
    }

    /// The archive's program, where another one, or none, is in its place.
    private func placeProgram() throws {
        let fm = FileManager.default, new = try temporary()
        defer { try? fm.removeItem(at: new) }
        try Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", new.path], stage: .sdk)
        func isRegular(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular }
        guard let found = fm.enumerator(at: new, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "rcodesign" && isRegular($0) }) else {
            throw XlessError(.sdk, "\(download.url.lastPathComponent) holds no rcodesign", fix: "report it: the release's layout changed")
        }
        if isRegular(program), fm.contentsEqual(atPath: found.path, andPath: program.path) {
            guard chmod(program.path, 0o700) == 0 else { throw cannot("change the mode of \(program.path)") }
        } else { try Self.put(found, at: program, mode: 0o700) }
    }

    private func refuseSharedPlace(_ url: URL) throws {
        guard let problem = TrustedPath.problem(url.path) else { return }
        throw XlessError(.sdk, "rcodesign, which signs, is not used from \(download.final.path): \(problem)",
                         fix: "let only yourself write there (chmod go-w <that directory>), or set XLESS_NATIVE_HOME to a directory that only you can write")
    }

    private func temporary() throws -> URL {
        let new = directory.appendingPathComponent(".new-\(UUID().uuidString)")
        guard mkdir(new.path, 0o700) == 0 else { throw cannot("make \(new.path)") }
        return new
    }

    /// Each directory that is not there yet is made for this user alone, whatever the umask.
    private static func makePrivate(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try makePrivate(directory.deletingLastPathComponent())
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw cannot("make \(directory.path)") }
    }

    private static func put(_ file: URL, at place: URL, mode: mode_t) throws {
        guard chmod(file.path, mode) == 0, rename(file.path, place.path) == 0 else { throw cannot("write \(place.path)") }
    }

    private static func cannot(_ what: String) -> XlessError {
        XlessError(.sdk, "cannot \(what): \(String(cString: strerror(errno)))", fix: "check the directory's permissions")
    }

    private func cannot(_ what: String) -> XlessError { Self.cannot(what) }

    /// One run at a time: another one's fetch is waited for.
    private func withLock(_ body: () throws -> Void) throws {
        #if os(macOS)
        let file = directory.deletingLastPathComponent().appendingPathComponent("rcodesign.lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw cannot("open \(file.path)") }
        defer { close(fd) } // which unlocks it
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        #endif
        try body()
    }
}
