import Foundation
import XlessCore
import XlessTauri

/// Build inputs (`CargoInput`): extra read-only directories a Cargo app's build.rs reads through an environment
/// variable. A git input is a clone at a pinned commit, kept in a cache directory across builds; a path input is a
/// directory on the host (mounted at `mounted/<name>` in docker).
public enum CargoInputs {
    /// Runs git with the given arguments and returns its stdout.
    typealias GitRunner = ([String]) throws -> String

    /// Added to git's environment: a private or mistyped https repo must fail, not prompt for credentials on the terminal.
    static let gitEnvironment: [String: String?] = ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "true"]

    /// `env-var → absolute path` for every input. `sourceRoot` resolves relative path inputs; `cache` holds the git
    /// clones (`<name>-<rev>`); `mounted`, when set, is where docker mounts the path inputs (`mounted/<name>`).
    public static func materialize(_ inputs: [CargoInput], sourceRoot: URL, cache: URL, mounted: URL?, env: [String: String]) throws -> [String: String] {
        try materialize(inputs, sourceRoot: sourceRoot, cache: cache, mounted: mounted, env: env, allowFileURLs: false, git: nil)
    }

    /// The path inputs, resolved on the host (what docker mounts at `/inputs/<name>`).
    public static func hostMounts(_ inputs: [CargoInput], sourceRoot: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> [(name: String, path: URL)] {
        inputs.compactMap { input in
            guard case .path(let name, let path, _) = input else { return nil }
            return (name, resolve(path, sourceRoot: sourceRoot, env: env))
        }
    }

    /// What `xless cargo inputs` prints for the overlay at `url`: `name<TAB>absolute host path` for every path input
    /// (`hostMounts`), the directories `xless run` mounts read-only at `/inputs/<name>`. Git inputs need no mount.
    public static func hostMountLines(overlayAt url: URL, sourceOverride: String?,
                                      env: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        let (overlay, sourceRoot, _) = try CargoOverlay.load(from: url, sourceOverride: sourceOverride, env: env)
        return hostMounts(overlay.inputs, sourceRoot: sourceRoot, env: env).map { "\($0.name)\t\($0.path.path)" }
    }

    /// Absolute, `~`-prefixed (with `env`'s HOME) or relative to the source root; may leave the source root.
    static func resolve(_ path: String, sourceRoot: URL, env: [String: String]) -> URL {
        var path = path
        if path == "~" || path.hasPrefix("~/"), let home = env["HOME"], !home.isEmpty {
            path = home + path.dropFirst()
        }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : sourceRoot.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    static func materialize(_ inputs: [CargoInput], sourceRoot: URL, cache: URL, mounted: URL?, env: [String: String],
                            allowFileURLs: Bool, git runner: GitRunner?) throws -> [String: String] {
        let git: GitRunner = runner ?? { args in
            try Shell.run("git", args, env: gitEnvironment, baseEnvironment: env, stage: .prepare).stdout
        }
        var result: [String: String] = [:]
        for input in inputs {
            let directory: URL
            switch input {
            case .path(let name, let path, _):
                directory = mounted.map { $0.appendingPathComponent(name) } ?? resolve(path, sourceRoot: sourceRoot, env: env)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw XlessError(.prepare, "input '\(name)': \(directory.path) is not a directory",
                                     fix: mounted == nil ? "create it, or fix the input's path: in the overlay (relative paths start at the source root)"
                                                         : "xless cargo inputs lists the directories to mount at \(mounted?.path ?? "/inputs")/<name>")
                }
            case .git(let name, let url, let rev, _):
                directory = try checkout(name: name, url: url, rev: rev, cache: cache, allowFileURLs: allowFileURLs, git: git)
            }
            result[input.env] = directory.path
        }
        return result
    }

    /// `cache/<name>-<rev>`: a clone at `rev`, made in `….partial` and renamed once verified.
    private static func checkout(name: String, url: String, rev: String, cache: URL, allowFileURLs: Bool, git: GitRunner) throws -> URL {
        let fm = FileManager.default
        func fail(_ what: String, fix: String = "check the input's git url and that the commit exists there") -> XlessError {
            XlessError(.prepare, "input '\(name)' (\(url) at \(rev)): \(what)", fix: fix)
        }
        guard url.hasPrefix("https://") || (allowFileURLs && url.hasPrefix("file://")) else {
            throw fail("the git url must be https://", fix: "host the input at an https:// URL")
        }
        guard rev.wholeMatch(of: /[0-9a-f]{40}/) != nil, name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) != nil else {
            throw fail("the name or rev is not valid", fix: "pin the exact 40-character commit")
        }
        let final = cache.appendingPathComponent("\(name)-\(rev)"), partial = cache.appendingPathComponent("\(name)-\(rev).partial")
        func head(_ dir: URL) -> String? {
            (try? git(WorkCopy.gitArguments(dir, ["rev-parse", "HEAD"])))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if fm.fileExists(atPath: final.path) {
            if head(final) == rev { return final }
            try? fm.removeItem(at: final)   // another commit, or not a clone
        }
        do {
            try? fm.removeItem(at: partial)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            _ = try git(["clone", "-q", "--no-checkout", "--", url, partial.path])
            _ = try git(WorkCopy.gitArguments(partial, ["-c", "advice.detachedHead=false", "checkout", "-q", rev]))
            guard head(partial) == rev else { throw fail("the checkout is not at the pinned commit") }
            try fm.moveItem(at: partial, to: final)
        } catch let error as XlessError where error.stage == .prepare && error.cause.hasPrefix("input '") {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            let cause = (error as? XlessError)?.cause ?? "\(error)"
            throw fail("cannot clone: \(cause)")
        }
        return final
    }
}
