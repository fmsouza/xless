import Foundation

/// The free space `xless setup` asks for before it runs anything, in two places: the cache (the SDK export, which xtool
/// expands the .xip into; with --docker the image's setup exports into the host's cache too) and Docker's data root (the
/// image, its kits, their build cache, and the pack volumes). Each figure is per architecture, from versions.env
/// (`XLESS_SETUP_CACHE_GB`, `XLESS_SETUP_DOCKER_GB`); an environment variable of the same name wins. The cache figure counts
/// only the architectures whose SDK is exported in this run. The setup in the image checks the store it prepares the pack
/// in against `XLESS_SETUP_NATIVE_GB` (the host's value, when it sets one, goes into its container).
public enum SetupDisk {
    public static let cacheKey = "XLESS_SETUP_CACHE_GB"
    public static let dockerKey = "XLESS_SETUP_DOCKER_GB"
    /// A native setup (no Docker): the Xcode pack it prepares in the store (`XcodeStore`: the Swift toolchain and its
    /// download, the installed SDK), for this machine's architecture only. xtool and rcodesign, in the native home, are
    /// small enough not to be counted.
    public static let nativeKey = "XLESS_SETUP_NATIVE_GB"
    /// When versions.env has no value (an older share): the figures measured for Xcode 26.2 and 27.0.
    public static let fallback = [cacheKey: 17, dockerKey: 30, nativeKey: 10]

    public struct Need: Equatable, Sendable {
        /// The variable that sets (and overrides) `perArchGB`.
        public let key: String
        public let perArchGB: Int
        public let archs: Int
        public var totalGB: Int { perArchGB * archs }

        /// "34 GB (17 GB per architecture × 2)", or "17 GB" for one architecture.
        public var spoken: String { archs > 1 ? "\(totalGB) GB (\(perArchGB) GB per architecture × \(archs))" : "\(totalGB) GB" }
    }

    /// The per-architecture figure of `key`: the environment's when it is a whole number, else versions.env's, else the fallback.
    public static func perArchGB(_ key: String, env: [String: String], table: [String: String]) -> Int {
        if let v = env[key].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), v >= 0 { return v }
        if let v = table[key].flatMap({ Int($0) }), v >= 0 { return v }
        return fallback[key] ?? 0
    }

    /// What this run needs: the cache for `exporting` architectures, Docker's data root for `archs` architectures.
    public static func needs(archs: Int, exporting: Int, env: [String: String], table: [String: String]) -> (cache: Need, docker: Need) {
        (Need(key: cacheKey, perArchGB: perArchGB(cacheKey, env: env, table: table), archs: exporting),
         Need(key: dockerKey, perArchGB: perArchGB(dockerKey, env: env, table: table), archs: archs))
    }

    /// What a native run needs: the cache for the export (when it runs), and the store for the pack (when one is prepared).
    public static func nativeNeeds(exporting: Bool, preparing: Bool, env: [String: String], table: [String: String]) -> (cache: Need, store: Need) {
        (Need(key: cacheKey, perArchGB: perArchGB(cacheKey, env: env, table: table), archs: exporting ? 1 : 0),
         Need(key: nativeKey, perArchGB: perArchGB(nativeKey, env: env, table: table), archs: preparing ? 1 : 0))
    }

    /// The refusal when `freeGB` under `path` is short of `need`: nil when there is room.
    public static func shortfall(freeGB: Int64, path: String, what: String, need: Need) -> String? {
        guard freeGB < Int64(need.totalGB) else { return nil }
        return "\(freeGB) GB free under \(path) for \(what); xless setup needs about \(need.spoken) there"
    }
}
