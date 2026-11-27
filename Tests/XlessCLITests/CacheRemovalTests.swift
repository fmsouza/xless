import Foundation
import Testing
@testable import xless

/// What `xless clean --cache` removes of the cache when a store of packs (XLESS_XCODES) is kept inside it: everything but the
/// store, the directories that lead to it, and the links that its path, as given, goes through.
@Suite struct CacheRemovalTests {
    let cache: URL
    init() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("cache-removal-\(UUID().uuidString)").resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: cache.appendingPathComponent("real/xcodes/26.2-17C52-arm64"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache.appendingPathComponent("real/work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache.appendingPathComponent("sdk/xcode26.2-17C52"), withIntermediateDirectories: true)
        // XLESS_XCODES goes through `via`; `other` leads to the same place, and is no part of that path.
        try fm.createSymbolicLink(at: cache.appendingPathComponent("via"), withDestinationURL: cache.appendingPathComponent("real"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("other"), withDestinationURL: cache.appendingPathComponent("real"))
    }

    private var given: URL { cache.appendingPathComponent("via/xcodes") }
    private var kept: [String] { [given.resolvingSymlinksInPath().standardizedFileURL.path] }

    @Test func aLinkThatTheKeptStoresPathGoesThroughStays() throws {
        defer { try? FileManager.default.removeItem(at: cache) }
        try CleanCommand.removeCache(cache, keeping: kept, through: [given])
        let fm = FileManager.default
        #expect((try? fm.destinationOfSymbolicLink(atPath: cache.appendingPathComponent("via").path)) != nil)
        #expect(fm.fileExists(atPath: given.appendingPathComponent("26.2-17C52-arm64").path))
        #expect(!fm.fileExists(atPath: cache.appendingPathComponent("sdk").path))
        #expect(!fm.fileExists(atPath: cache.appendingPathComponent("real/work").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: cache.appendingPathComponent("other").path)) == nil)
    }

    /// What a failed removal tells to remove as root: only what clean meant to remove, never the kept store.
    @Test func theRemovalsNameNeitherTheStoreNorWhatLeadsToIt() {
        defer { try? FileManager.default.removeItem(at: cache) }
        let paths = CleanCommand.cacheRemovals(cache, keeping: kept, through: [given]).map(\.path).sorted()
        #expect(paths == ["other", "real/work", "sdk"].map { cache.appendingPathComponent($0).path })
        #expect(CleanCommand.cacheRemovals(cache, keeping: [], through: []).map(\.path) == [cache.path])
    }
}
