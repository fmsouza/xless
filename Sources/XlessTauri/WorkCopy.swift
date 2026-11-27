import Foundation
import XlessCore

/// The tracked files of a source checkout, mirrored into a work copy that keeps its own build outputs between syncs.
public enum WorkCopy {
    /// Returns the number of tracked files. `source` is a git work tree's root or a directory inside one (an app in a
    /// monorepo); only the tracked files under it are copied, with paths relative to it.
    /// Untracked and ignored files are never copied; uncommitted edits to tracked files are.
    /// Files that were tracked by the previous sync but no longer exist are deleted; anything else in `work` (`target/`, `node_modules/`, `.xless/`) is left alone.
    ///
    /// `origin` identifies the source in `<work>/.xless/source` (default: its resolved path; in docker, where every source
    /// is mounted at the same path, the host path): a work copy is named after the overlay file, so two overlays with the
    /// same file name would otherwise share one. `baseEnvironment` is git's and rsync's environment.
    public static func sync(source: URL, to work: URL, origin: String? = nil,
                            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> Int {
        let fm = FileManager.default
        try gitCheckout(source, baseEnvironment: baseEnvironment)
        try checkOrigin(origin ?? source.resolvingSymlinksInPath().standardizedFileURL.path, work: work, volume: baseEnvironment["XLESS_WORK_VOLUME"])

        // Entries look like `<mode> <sha> <stage>\t<path>`, NUL-separated; run in `source`, paths are relative to it.
        let listing = try git(source, ["ls-files", "-s", "-z", "--", "."], baseEnvironment: baseEnvironment, stage: .prepare)
        var tracked: [String] = []
        var seen = Set<String>()
        for entry in listing.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let path = String(entry[entry.index(after: tab)...])
            if entry.hasPrefix("160000") {
                throw XlessError(.prepare, "\(path) is a git submodule; submodules are not supported", fix: "vendor the submodule's files into the repository")
            }
            guard seen.insert(path).inserted else { continue }  // merge conflicts list a path once per stage
            // A tracked file deleted from disk but not yet from the index would make rsync fail; it must end up absent in the work copy.
            if (try? fm.attributesOfItem(atPath: source.appendingPathComponent(path).path)) != nil { tracked.append(path) }
        }

        let manifest = work.appendingPathComponent(".xless/tracked.txt")
        let previous = (try? String(contentsOf: manifest, encoding: .utf8))?.split(separator: "\0").map(String.init) ?? []
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeManifest(_ paths: [String]) throws {
            try paths.map { "\($0)\0" }.joined().write(to: manifest, atomically: true, encoding: .utf8)
        }

        // Union first, so a failure part-way through can't orphan files that the next sync should clean up.
        let current = Set(tracked)
        try writeManifest(tracked + previous.filter { !current.contains($0) })

        // Stale entries go before rsync, so file<->directory transitions can make way. Only entries that are not directories
        // are removed (a path that is a directory now holds other content, or tracked files below it); removeItem on a
        // symlink removes the link itself, never its target. An entry is only removed when its parent directory, symlinks
        // resolved, is inside the work copy: a directory that became a symlink must not lead the removal outside it.
        let workRoot = work.standardizedFileURL.path
        let resolvedRoot = work.resolvingSymlinksInPath().standardizedFileURL.path
        for path in previous where !current.contains(path) {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
            let url = work.appendingPathComponent(path)
            let parentDir = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            guard parentDir == resolvedRoot || parentDir.hasPrefix(resolvedRoot + "/") else { continue }
            guard let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType, type != .typeDirectory else { continue }
            try fm.removeItem(at: url)
            // Prune parents left empty, stopping at the first one that still holds anything (e.g. a build output).
            var parent = url.deletingLastPathComponent()
            while parent.standardizedFileURL.path != workRoot, parent.standardizedFileURL.path.hasPrefix(workRoot + "/"),
                  (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }

        let list = Files.temporary.appendingPathComponent("xless-files-\(UUID().uuidString)")
        try Data(tracked.map { "\($0)\0" }.joined().utf8).write(to: list)
        defer { try? fm.removeItem(at: list) }
        // -a copies symlinks as symlinks (never follows them) and preserves mtimes. `--delete` does nothing with `--files-from`; removals are the manifest pass above.
        try Shell.run("rsync", ["-a", "--from0", "--files-from=\(list.path)", source.path + "/", work.path + "/"], baseEnvironment: baseEnvironment, stage: .prepare)

        try writeManifest(tracked)
        return tracked.count
    }

    /// What git says about `source`, read-only. Reading the index runs no program that the repository's configuration names:
    /// `core.fsmonitor=false`, and nothing is fetched (a partial clone fetches what it lacks, over `core.sshCommand` say):
    /// `GIT_NO_LAZY_FETCH`, and for a git that does not know it, no protocol. Nothing is written to the repository.
    public static func git(_ source: URL, _ args: [String], baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                           stage: Stage) throws -> String {
        try Shell.run("git", gitArguments(source, args), env: ["GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "none"],
                      baseEnvironment: baseEnvironment, stage: stage).stdout
    }

    /// `safe.directory=*`: in docker the source belongs to the host user, not to root, and git would otherwise refuse it
    /// ("detected dubious ownership").
    public static func gitArguments(_ source: URL, _ args: [String]) -> [String] {
        ["-c", "safe.directory=*", "-c", "core.fsmonitor=false", "-C", source.path] + args
    }

    /// Refuses a `source` outside any git work tree; any other git failure is reported with git's own message.
    static func gitCheckout(_ source: URL, baseEnvironment: [String: String]) throws {
        let inside: String
        do {
            inside = try git(source, ["rev-parse", "--is-inside-work-tree"], baseEnvironment: baseEnvironment, stage: .prepare)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as XlessError where e.cause.contains("not a git repository") {
            throw XlessError(.prepare, "\(source.path) is not inside a git repository", fix: "point --source (or the overlay's source:) at a directory of a git checkout")
        } catch let e as XlessError {
            throw XlessError(.prepare, "cannot read the git checkout at \(source.path): \(e.cause)", fix: "fix the git error above (run `git status` in the source), then re-run")
        }
        guard inside == "true" else {
            throw XlessError(.prepare, "\(source.path) is not inside a git work tree", fix: "point --source (or the overlay's source:) at a directory of a git checkout, not inside .git")
        }
    }

    /// `<work>/.xless/source` names the source a work copy was first synced from; a different one is refused. `volume`
    /// (`XLESS_WORK_VOLUME`, set by `xless run`) is the docker volume the work copy lives in.
    static func checkOrigin(_ origin: String, work: URL, volume: String? = nil) throws {
        let file = work.appendingPathComponent(".xless/source")
        if let recorded = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .newlines), !recorded.isEmpty {
            guard recorded == origin else {
                throw XlessError(.prepare, "the work copy \(work.path) was synced from \(recorded), not from \(origin)",
                                 fix: "the work copy is named after the overlay file: rename one of the overlay files, or delete \(work.path)"
                                    + (volume.flatMap { $0.isEmpty ? nil : $0 }.map {
                                        " (it is in the docker volume \($0): docker run --rm -v \($0):/w alpine rm -rf /w/\(work.lastPathComponent))"
                                    } ?? ""))
            }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((origin + "\n").utf8).write(to: file, options: .atomic)
    }
}

/// Build outputs that a work copy keeps between builds (cargo's `target/<triple>`, the Swift packages' build directory)
/// and that depend on the Xcode pack: its SDK and its toolchain. cargo and SwiftPM track sources, flags and the files a
/// compile read by path, and a pack prepared again by another recipe has the same paths; so the pack is recorded beside
/// them, and they are removed when another one builds.
public enum PackOutputs {
    /// What builds the outputs: with `xcode` (a Mac's own Xcode) "(xcode)", which native and --docker runs that share a work
    /// copy tell apart; else the pack in `env`.
    public static func identity(env: [String: String], xcode: Bool) -> String { xcode ? "(xcode)" : identity(env: env) }

    /// The pack in `env` (`XcodePack.identity`), or "(no pack)" (an image's own SDK, or none).
    public static func identity(env: [String: String]) -> String {
        guard let found = try? XcodeEnvironment.lookup(env: env), let pack = found.pack else { return "(no pack)" }
        return pack.identity
    }

    /// Where the work copy records the pack its outputs were built with.
    public static func record(work: URL) -> URL { work.appendingPathComponent(".xless/pack") }

    /// What a build keeps in the work copy `work` that the pack made, for every platform (an iOS and a macOS build of
    /// one overlay share the work copy and its record): cargo's outputs for the Apple targets in `targetDir`, which hold
    /// its build scripts' outputs too (C code compiled against the SDK; the host's `target/release` stays), the Swift
    /// packages' build directories, the dSYM debug links and the macOS staging.
    public static func outputs(work: URL, targetDir: URL) -> [URL] {
        ([RustApple.iosTarget] + TauriMacEnvironment.targets).map { targetDir.appendingPathComponent($0, isDirectory: true) }
            + [".xless/swift", ".xless/dsym", ".xless/mac", ".xless/cargo-mac"].map { work.appendingPathComponent($0, isDirectory: true) }
    }

    /// Removes those of `outputs` that exist when `record` does not name `identity` (no record counts as another pack:
    /// a work copy of an xless that did not record it), then records `identity`. Returns what it removed.
    @discardableResult
    public static func reset(_ outputs: [URL], record: URL, identity: String) throws -> [URL] {
        let fm = FileManager.default
        let line = identity + "\n"
        guard (try? String(contentsOf: record, encoding: .utf8)) != line else { return [] }
        let removed = outputs.filter { fm.fileExists(atPath: $0.path) }
        do {
            for url in removed { try fm.removeItem(at: url) }
            try fm.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(line.utf8).write(to: record, options: .atomic)
        } catch {
            throw XlessError(.build, "cannot remove the build outputs of another Xcode pack: \(error.localizedDescription)",
                             fix: "remove the work copy (its volume with --docker), then build again")
        }
        return removed
    }
}
