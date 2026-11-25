import Foundation
import XlessCore

/// The resource bundles that `swift build` leaves next to the executable: all of them go into the app, so there has to be every one
/// that the app's packages have, and none of a package that the app no longer has.
enum ResourceBundles {
    static func of(_ products: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bundle" }.sorted { $0.path < $1.path }
    }

    /// Runs `build` without the bundles of earlier builds, which makes those again that the app has. When one of them is not there
    /// afterwards, its package is gone, or Swift Build took what it had for done: then everything is built again from nothing, which
    /// leaves the app's and no others. Until a build ended well, what the last one had is kept in mind (in `scratch`).
    /// - Parameter products: where the bundles are, or may be.
    static func fresh(scratch: URL, products: () -> [URL], note: (String) -> Void, build: () throws -> Void) throws {
        let fm = FileManager.default, record = scratch.appendingPathComponent("xless-bundles")
        func names() -> Set<String> { Set(products().flatMap(of).map(\.lastPathComponent)) }
        let recorded = (try? String(contentsOf: record, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let before = names().union(recorded)
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
            where !["checkouts", "repositories", "artifacts", "workspace-state.json", record.lastPathComponent].contains(item.lastPathComponent) {
                try fm.removeItem(at: item)
            }
            try build()
        }
        try write(names())
    }
}
