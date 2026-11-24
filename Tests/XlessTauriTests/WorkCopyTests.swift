import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

private var fm: FileManager { .default }

private func git(_ dir: URL, _ args: String...) throws -> String {
    try Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir.path] + args, stage: .prepare).stdout
}

private func write(_ root: URL, _ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func tmp() -> URL {
    fm.temporaryDirectory.appendingPathComponent("workcopy-\(UUID().uuidString)", isDirectory: true)
}

/// A repo with a.txt and dir/b.txt committed, ignored/ gitignored and present, and an untracked u.txt.
private func makeRepo() throws -> URL {
    let src = tmp()
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    _ = try git(src, "init", "-q")
    try write(src, "a.txt", "a")
    try write(src, "dir/b.txt", "b")
    try write(src, ".gitignore", "ignored/\n")
    try write(src, "ignored/i.txt", "i")
    try write(src, "u.txt", "u")
    _ = try git(src, "add", "a.txt", "dir/b.txt", ".gitignore")
    _ = try git(src, "commit", "-q", "-m", "init")
    return src
}

private func read(_ root: URL, _ path: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func exists(_ root: URL, _ path: String) -> Bool {
    (try? fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)) != nil
}

@Test func syncsOnlyTrackedFiles() throws {
    let src = try makeRepo(), work = tmp()
    let n = try WorkCopy.sync(source: src, to: work)
    #expect(n == 3)
    #expect(read(work, "a.txt") == "a" && read(work, "dir/b.txt") == "b")
    #expect(!exists(work, "u.txt") && !exists(work, "ignored"))
    let a = try fm.attributesOfItem(atPath: src.appendingPathComponent("a.txt").path)[.modificationDate] as? Date
    let b = try fm.attributesOfItem(atPath: work.appendingPathComponent("a.txt").path)[.modificationDate] as? Date
    // Whole seconds: rsync 2.6.x-compatible builds do not carry sub-second mtimes.
    #expect(a != nil && b != nil && Int(a!.timeIntervalSince1970) == Int(b!.timeIntervalSince1970))
}

@Test func copiesUncommittedEdits() throws {
    let src = try makeRepo(), work = tmp()
    _ = try WorkCopy.sync(source: src, to: work)
    try write(src, "a.txt", "edited")
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(read(work, "a.txt") == "edited")
}

@Test func removesDeletedFilesButKeepsBuildOutputs() throws {
    let src = try makeRepo(), work = tmp()
    _ = try WorkCopy.sync(source: src, to: work)
    try write(work, "target/x", "built")
    try write(work, "node_modules/m/index.js", "m")
    // Committed deletion, and a tracked file deleted from disk without committing.
    _ = try git(src, "rm", "-q", "dir/b.txt")
    _ = try git(src, "commit", "-q", "-m", "rm")
    try fm.removeItem(at: src.appendingPathComponent("a.txt"))
    let n = try WorkCopy.sync(source: src, to: work)
    #expect(n == 1)
    #expect(!exists(work, "dir/b.txt") && !exists(work, "a.txt"))
    #expect(read(work, "target/x") == "built" && read(work, "node_modules/m/index.js") == "m")
    #expect(exists(work, ".xless/tracked.txt"))
}

@Test func syncsASubdirectoryWithRelativePaths() throws {
    let src = try makeRepo(), work = tmp()
    try write(src, "dir/sub/c.txt", "c")
    try write(src, "dir/untracked.txt", "u")
    _ = try git(src, "add", "dir/sub/c.txt")
    _ = try git(src, "commit", "-q", "-m", "c")
    let n = try WorkCopy.sync(source: src.appendingPathComponent("dir"), to: work)
    #expect(n == 2)
    #expect(read(work, "b.txt") == "b" && read(work, "sub/c.txt") == "c")
    #expect(!exists(work, "a.txt") && !exists(work, "dir") && !exists(work, "untracked.txt") && !exists(work, ".gitignore"))
}

@Test func refusesDirectoryOutsideAnyRepository() throws {
    let src = tmp(), work = tmp()
    try write(src, "a.txt", "a")
    do {
        _ = try WorkCopy.sync(source: src, to: work)
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .prepare)
        #expect(e.cause == "\(src.path) is not inside a git repository")
    }
}

@Test func refusesSubmodules() throws {
    let src = try makeRepo(), work = tmp()
    let sub = try makeRepo()
    _ = try git(src, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.path, "sub")
    do {
        _ = try WorkCopy.sync(source: src, to: work)
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .prepare)
        #expect(e.cause.contains("submodule"))
    }
}

@Test func copiesSymlinksWithoutFollowing() throws {
    let src = try makeRepo(), work = tmp(), outside = tmp()
    try write(outside, "secret.txt", "s")
    try fm.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: outside)
    _ = try git(src, "add", "link")
    _ = try git(src, "commit", "-q", "-m", "link")
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(try fm.destinationOfSymbolicLink(atPath: work.appendingPathComponent("link").path) == outside.path)
}

@Test func leavesSourceUntouched() throws {
    let src = try makeRepo(), work = tmp()
    let before = try git(src, "status", "--porcelain", "--ignored")
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(try git(src, "status", "--porcelain", "--ignored") == before)
}

@Test func fileBecomesDirectory() throws {
    let src = try makeRepo(), work = tmp()
    try write(src, "foo", "file")
    _ = try git(src, "add", "foo"); _ = try git(src, "commit", "-q", "-m", "foo")
    _ = try WorkCopy.sync(source: src, to: work)
    _ = try git(src, "rm", "-q", "foo"); try write(src, "foo/bar", "bar")
    _ = try git(src, "add", "foo/bar"); _ = try git(src, "commit", "-q", "-m", "foo dir")
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(read(work, "foo/bar") == "bar")
}

@Test func directoryBecomesFileAndLaterSyncsWork() throws {
    let src = try makeRepo(), work = tmp()
    try write(src, "foo/bar", "bar")
    _ = try git(src, "add", "foo/bar"); _ = try git(src, "commit", "-q", "-m", "foo dir")
    _ = try WorkCopy.sync(source: src, to: work)
    try write(work, "target/x", "built")
    _ = try git(src, "rm", "-q", "foo/bar"); try write(src, "foo", "file")
    _ = try git(src, "add", "foo"); _ = try git(src, "commit", "-q", "-m", "foo file")
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(read(work, "foo") == "file" && read(work, "target/x") == "built")
    _ = try WorkCopy.sync(source: src, to: work)
}

@Test func prunesEmptiedParentsButNotBuildOutputs() throws {
    let src = try makeRepo(), work = tmp()
    try write(src, "p/q/c.txt", "c"); try write(src, "p/keep.txt", "k")
    _ = try git(src, "add", "p"); _ = try git(src, "commit", "-q", "-m", "p")
    _ = try WorkCopy.sync(source: src, to: work)
    try write(work, "dir/target/x", "built")
    _ = try git(src, "rm", "-q", "p/q/c.txt", "dir/b.txt"); _ = try git(src, "commit", "-q", "-m", "rm")
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(!exists(work, "p/q") && exists(work, "p/keep.txt"))
    #expect(read(work, "dir/target/x") == "built")
}

// MARK: git errors

/// A PATH holding a fake `git` (`script` is its body), then the real PATH, so rsync still resolves.
private func fakeGitEnv(_ script: String) throws -> [String: String] {
    let bin = tmp()
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try ExecutableFile.write("#!/bin/sh\n" + script, to: bin.appendingPathComponent("git"), stage: .prepare)
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = bin.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    return env
}

private func realGit() throws -> String {
    try Shell.run("sh", ["-c", "command -v git"], stage: .prepare).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func readsSourcesOwnedByAnotherUser() throws {
    // Docker on Linux: the source belongs to the host user, xless runs as root, and git refuses the repository unless
    // safe.directory allows it. The fake git behaves like that git.
    let src = try makeRepo(), work = tmp()
    let env = try fakeGitEnv("""
        case "$*" in *"safe.directory=*"*) exec "\(try realGit())" "$@" ;; esac
        echo "fatal: detected dubious ownership in repository at '$PWD'" >&2; exit 128
        """)
    #expect(try WorkCopy.sync(source: src, to: work, baseEnvironment: env) == 3)
}

@Test func otherGitErrorsAreReportedNotMistakenForAMissingRepository() throws {
    let src = try makeRepo(), work = tmp()
    let env = try fakeGitEnv("echo 'fatal: detected dubious ownership in repository' >&2; exit 128\n")
    do {
        _ = try WorkCopy.sync(source: src, to: work, baseEnvironment: env)
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .prepare)
        #expect(e.cause.contains("cannot read the git checkout") && e.cause.contains("dubious ownership"), "\(e.cause)")
        #expect(!e.cause.contains("is not inside a git repository"))
    }
}

// MARK: stale entries stay inside the work copy

@Test func staleEntryBehindADirectoryThatBecameASymlinkIsNotFollowed() throws {
    let src = try makeRepo(), work = tmp(), outside = tmp()
    _ = try WorkCopy.sync(source: src, to: work)   // tracks dir/b.txt
    // The work copy's dir/ is now a symlink to a directory outside it holding a b.txt.
    try write(outside, "b.txt", "keep")
    try fm.removeItem(at: work.appendingPathComponent("dir"))
    try fm.createSymbolicLink(at: work.appendingPathComponent("dir"), withDestinationURL: outside)
    _ = try git(src, "rm", "-q", "dir/b.txt"); _ = try git(src, "commit", "-q", "-m", "rm")
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(read(outside, "b.txt") == "keep")
}

@Test func manifestEntriesOutsideTheWorkCopyAreIgnored() throws {
    let src = try makeRepo(), work = tmp(), outside = tmp()
    _ = try WorkCopy.sync(source: src, to: work)
    try write(outside, "victim.txt", "keep")
    let rel = "../" + outside.lastPathComponent + "/victim.txt"
    let manifest = work.appendingPathComponent(".xless/tracked.txt")
    let entries = try String(contentsOf: manifest, encoding: .utf8) + "\(rel)\0\(outside.path)/victim.txt\0"
    try entries.write(to: manifest, atomically: true, encoding: .utf8)
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(read(outside, "victim.txt") == "keep")
}

// MARK: one source per work copy

@Test func recordsTheSourceAndRefusesAnother() throws {
    let src = try makeRepo(), other = try makeRepo(), work = tmp()
    _ = try WorkCopy.sync(source: src, to: work)
    #expect(read(work, ".xless/source") == src.resolvingSymlinksInPath().standardizedFileURL.path + "\n")
    _ = try WorkCopy.sync(source: src, to: work)   // the same source again is fine
    do {
        _ = try WorkCopy.sync(source: other, to: work)
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .prepare)
        #expect(e.cause.contains("was synced from") && e.fix.contains("rename"), "\(e.cause)")
        #expect(!e.fix.contains("docker"))
    }
    // in a docker volume (scripts/testflight.sh): the fix says how to delete the work copy there
    var env = ProcessInfo.processInfo.environment; env["XLESS_WORK_VOLUME"] = "xless-rn-work-o-12345678"
    do {
        _ = try WorkCopy.sync(source: other, to: work, baseEnvironment: env)
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.fix.hasSuffix("(it is in the docker volume xless-rn-work-o-12345678: docker run --rm -v xless-rn-work-o-12345678:/w alpine rm -rf /w/\(work.lastPathComponent))"), "\(e.fix)")
    }
}

@Test func anExplicitOriginIdentifiesTheSource() throws {
    // In docker every source is /source; the host path tells two overlays' sources apart.
    let src = try makeRepo(), work = tmp()
    _ = try WorkCopy.sync(source: src, to: work, origin: "/host/a")
    _ = try WorkCopy.sync(source: src, to: work, origin: "/host/a")
    #expect(throws: XlessError.self) { try WorkCopy.sync(source: src, to: work, origin: "/host/b") }
}
