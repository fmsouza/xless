import Foundation
import XlessCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One build of a project at a time: another one's would take away the bundles that this one is about to copy. Held until it is
/// released, or its process ends.
final class BuildLock {
    private let fd: Int32

    init(project: URL, note: (String) -> Void) throws {
        let directory = project.appendingPathComponent(".xless", isDirectory: true), file = directory.appendingPathComponent("build.lock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            throw XlessError(.build, "cannot open \(file.path): \(String(cString: strerror(errno)))", fix: "check the permissions of \(directory.path)")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) != 0 else { return }
        note("another build of this project is running: waiting for it")
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let why = String(cString: strerror(errno))
            close(fd)
            throw XlessError(.build, "cannot lock \(file.path): \(why)", fix: "run it again")
        }
    }

    func release() { close(fd) }
}

/// The resource bundles that `swift build` leaves next to the executable: all of them go into the app, so there has to be every one
/// that the app's packages have, and none of a package that the app no longer has.
enum ResourceBundles {
    static func of(_ products: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bundle" }.sorted { $0.path < $1.path }
    }

    /// The directories in `scratch` that hold bundles, however its SwiftPM lays them out.
    static func directories(in scratch: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil) else { return [] }
        var found: Set<URL> = []
        for case let item as URL in walk {
            if walk.level == 1, fetched.contains(item.lastPathComponent) { walk.skipDescendants() }
            guard item.pathExtension == "bundle" else { continue }
            found.insert(item.deletingLastPathComponent())
            walk.skipDescendants()
        }
        return Array(found)
    }

    private static let fetched = ["checkouts", "repositories", "artifacts", "workspace-state.json"]

    /// What the last build had, of a small file that is one: the project's directory may hold anything by that name.
    private static func recorded(_ record: URL) -> [String] {
        guard let about = try? FileManager.default.attributesOfItem(atPath: record.path), about[.type] as? FileAttributeType == .typeRegular,
              (about[.size] as? NSNumber)?.intValue ?? .max <= 1 << 20, let text = try? String(contentsOf: record, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { name in
            name.hasSuffix(".bundle") && !name.contains("/") && TerminalText.escaped(name) == name
        }
    }

    /// Runs `build` without the bundles of earlier builds, which makes those again that the app has. When one of them is not there
    /// afterwards, its package is gone, or Swift Build took what it had for done: then everything is built again from nothing, which
    /// leaves the app's and no others. Until a build ended well, what the last one had is kept in mind (in `scratch`).
    /// - Parameter products: where the bundles are, or may be.
    static func fresh(scratch: URL, products: () -> [URL], note: (String) -> Void, build: () throws -> Void) throws {
        let fm = FileManager.default, record = scratch.appendingPathComponent("xless-bundles")
        if let type = (try? fm.attributesOfItem(atPath: scratch.path))?[.type] as? FileAttributeType, type != .typeDirectory {
            throw XlessError(.build, "\(scratch.path), where it is built, is not a directory of its own", fix: "remove it: xless empties that directory now and then")
        }
        func names() -> Set<String> { Set(products().flatMap(of).map(\.lastPathComponent)) }
        let before = names().union(recorded(record))
        func write(_ names: Set<String>) throws {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data(names.sorted().map { "\($0)\n" }.joined().utf8).write(to: record, options: .atomic)
        }
        if !before.isEmpty { try write(before) }
        for bundle in products().flatMap(of) { try fm.removeItem(at: bundle) }
        try build()
        let missing = before.subtracting(names()).sorted()
        if !missing.isEmpty {
            note("\(missing.joined(separator: ", ")) was not built again (its package is no longer the app's, perhaps): everything is")
            // (what is fetched is kept)
            for item in try fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
            where !(fetched + [record.lastPathComponent]).contains(item.lastPathComponent) {
                try fm.removeItem(at: item)
            }
            try build()
        }
        try write(names())
    }
}
