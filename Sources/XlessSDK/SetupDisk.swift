import Foundation

/// The free space `xless setup` asks for before it runs anything, in two places: the cache (the SDK export, which xtool
/// expands the .xip into) and Docker's data root (the four images and their build cache). Each figure is per
/// architecture, from versions.env (`XLESS_SETUP_CACHE_GB`, `XLESS_SETUP_DOCKER_GB`); an environment variable of the same
/// name wins. The cache figure counts only the architectures whose SDK is exported in this run.
public enum SetupDisk {
    public static let cacheKey = "XLESS_SETUP_CACHE_GB"
    public static let dockerKey = "XLESS_SETUP_DOCKER_GB"
    /// A native setup (no Docker): the Swift toolchain, xtool, rcodesign and the installed SDK, for this machine's
    /// architecture only.
    public static let nativeKey = "XLESS_SETUP_NATIVE_GB"
    /// When versions.env has no value (an older share): the figures measured for Xcode 26.2 and 27.0.
    public static let fallback = [cacheKey: 17, dockerKey: 40, nativeKey: 10]

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

    /// What a native run needs: the cache for the export (when it runs), and the native home for one architecture.
    public static func nativeNeeds(exporting: Bool, env: [String: String], table: [String: String]) -> (cache: Need, native: Need) {
        (Need(key: cacheKey, perArchGB: perArchGB(cacheKey, env: env, table: table), archs: exporting ? 1 : 0),
         Need(key: nativeKey, perArchGB: perArchGB(nativeKey, env: env, table: table), archs: 1))
    }

    /// The refusal when `freeGB` under `path` is short of `need`: nil when there is room.
    public static func shortfall(freeGB: Int64, path: String, what: String, need: Need) -> String? {
        guard freeGB < Int64(need.totalGB) else { return nil }
        return "\(freeGB) GB free under \(path) for \(what); xless setup needs about \(need.spoken) there"
    }
}
