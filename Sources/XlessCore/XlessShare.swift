import Foundation

/// Where xless's data files live (versions.env, docker/, the Dockerfiles, …).
public enum XlessShare {
    /// The variable that lets xless go on, with a warning, when its share directory is from another release.
    public static let allowMismatchVariable = "XLESS_ALLOW_SHARE_MISMATCH"

    /// The share directory, checked to be from this binary's release (`checkRelease`). Every command that reads the share
    /// (setup, run, docker, sdk) finds it here; the stage commands never read it, so they run without one (in the images).
    public static func root(env: [String: String], executable: URL, binary: String = XlessVersion.current,
                            warn: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }) throws -> URL {
        let share = try locate(env: env, executable: executable)
        if let warning = try checkRelease(share: share, binary: binary, env: env) { warn(warning) }
        return share
    }

    /// The share directory: `XLESS_SHARE`, else `<prefix>/share/xless` beside `<prefix>/bin/xless` (an install), else the
    /// first directory above the executable holding versions.env and docker/Dockerfile.base (a source checkout).
    public static func locate(env: [String: String], executable: URL) throws -> URL {
        let fm = FileManager.default
        if let s = env["XLESS_SHARE"], !s.isEmpty { return URL(fileURLWithPath: s) }
        let exe = executable.resolvingSymlinksInPath()
        let installed = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/xless")
        if fm.fileExists(atPath: installed.appendingPathComponent("versions.env").path) { return installed }
        var dir = exe.deletingLastPathComponent()
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("versions.env").path),
               fm.fileExists(atPath: dir.appendingPathComponent("docker/Dockerfile.base").path) { return dir }
            // Stop at the root: past it, Foundation can return "/.." (and "/../..", …) instead of "/" again.
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if dir.path == "/" || parent.path == dir.path { break }
            dir = parent
        }
        throw XlessError(.sdk, "cannot find xless's share directory", fix: "reinstall xless (see README) or set XLESS_SHARE")
    }

    /// The release a share directory is from: its VERSION file (written into every release's share by
    /// scripts/package-release.sh), else XLESS_VERSION in its versions.env (a source checkout: 0.0.0-dev). Nil when it
    /// records neither.
    public static func release(of share: URL) -> String? {
        if let text = try? String(contentsOf: share.appendingPathComponent("VERSION"), encoding: .utf8) {
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        guard let text = try? String(contentsOf: share.appendingPathComponent("versions.env"), encoding: .utf8),
              let v = KnownXcodes.parseEnv(text)["XLESS_VERSION"], !v.isEmpty else { return nil }
        return v
    }

    /// Refuses a share directory from another release than `binary`: its scripts, Dockerfiles and pinned versions would
    /// not be the ones this binary was released with. With XLESS_ALLOW_SHARE_MISMATCH=1 it returns the warning to print
    /// instead; nil when the releases match.
    public static func checkRelease(share: URL, binary: String, env: [String: String]) throws -> String? {
        let fromEnv = !(env["XLESS_SHARE"] ?? "").isEmpty
        let named = fromEnv ? "\(share.path) (XLESS_SHARE)" : share.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: share.path, isDirectory: &isDir), isDir.boolValue else {
            throw XlessError(.sdk, "xless's share directory \(named) does not exist",
                             fix: fromEnv ? "point XLESS_SHARE at xless \(binary)'s share directory, or unset it" : "reinstall xless (see README)")
        }
        let found = release(of: share)
        if found == binary { return nil }
        let cause = "this xless is \(binary), but its share directory \(named) "
            + (found.map { "is from xless \($0)" } ?? "records no release (no VERSION file, no XLESS_VERSION in versions.env)")
        if env[allowMismatchVariable] == "1" {
            return "warning: \(cause); going on because \(allowMismatchVariable)=1 (its scripts, Dockerfiles and pins may not match this binary)"
        }
        let use: String
        if binary == XlessVersion.development {
            use = "a source build uses the files of its own checkout: set XLESS_SHARE=<the checkout it was built from>"
        } else if fromEnv {
            use = "unset XLESS_SHARE to use the share installed with this xless, or point it at xless \(binary)'s share directory"
        } else {
            use = "install xless \(binary) again, binary and share together: curl -fsSL https://github.com/fmsouza/xless/releases/latest/download/install.sh | XLESS_VERSION=\(binary)\(prefixAssignment(share: share, env: env)) sh"
        }
        throw XlessError(.sdk, cause, fix: "\(use); or set \(allowMismatchVariable)=1 to go on anyway")
    }

    /// ` XLESS_PREFIX=<prefix>` for a share installed at `<prefix>/share/xless` under another prefix than install.sh's
    /// default (`$HOME/.local`), so the suggested reinstall replaces that install instead of adding a second one.
    private static func prefixAssignment(share: URL, env: [String: String]) -> String {
        let s = share.standardizedFileURL
        guard s.lastPathComponent == "xless", s.deletingLastPathComponent().lastPathComponent == "share" else { return "" }
        let prefix = s.deletingLastPathComponent().deletingLastPathComponent()
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".local")
        if prefix.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path { return "" }
        let p = prefix.path
        let quoted = p.contains(where: { " \t'\"$`\\;&|()<>*?".contains($0) }) ? "'\(p.replacingOccurrences(of: "'", with: "'\\''"))'" : p
        return " XLESS_PREFIX=\(quoted)"
    }
}
