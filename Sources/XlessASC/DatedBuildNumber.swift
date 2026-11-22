import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// `build: dated` build numbers: `<version>.<yyyyMMdd><NN>`, chosen so they never sort below a build App Store Connect already has.
public enum DatedBuildNumber {
    /// The next number for `version` today (UTC). `existing` is every CFBundleVersion of this app and version, in any state.
    public static func next(version: String, today: Date, existing: [String]) throws -> String {
        let prefix = "\(version).\(dateString(today))"
        var maxNN = 0
        for v in existing where v.hasPrefix(prefix) {
            let tail = v.dropFirst(prefix.count)
            if tail.count == 2, tail.utf8.allSatisfy({ (48...57).contains($0) }), let nn = Int(tail) { maxNN = max(maxNN, nn) }
        }
        let nn = maxNN + 1
        guard nn <= 99 else {
            throw XlessError(.config, "99 builds already uploaded for \(version) today", fix: "wait until tomorrow (UTC) or bump the version")
        }
        let candidate = "\(prefix)\(nn < 10 ? "0" : "")\(nn)"
        if let highest = existing.max(by: { compare($0, $1) < 0 }), compare(candidate, highest) <= 0 {
            throw XlessError(.config, "build \(candidate) would not sort after existing build \(highest) of version \(version)",
                             fix: "bump the version; App Store Connect never frees a build number")
        }
        return candidate
    }

    /// A macOS (Developer ID) dated build: `<version>.<yyyyMMddHHmm>` in UTC. No App Store Connect holds these builds, so the clock is the only input.
    public static func macOS(version: String, now: Date) -> String {
        "\(version).\(format(now, "yyyyMMddHHmm"))"
    }

    /// Dotted-integer comparison; missing components count as 0 and non-numeric ones as 0.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let y = b.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    static func dateString(_ d: Date) -> String { format(d, "yyyyMMdd") }

    private static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// Whether `build: dated` is resolved by xless at all: not for fixed builds, and not when a build number was given explicitly.
    public static func shouldResolve(scheme: BuildScheme, override: String?) -> Bool {
        scheme == .dated && override == nil
    }

    /// Whether a command starts a run (and so chooses a new build number). `ship` starts one when it begins at `build` or earlier
    /// (`prepare` included); `prepare` and `build` always do; every later stage reads the recorded number.
    public static func isFreshRun(command: String, from: Stage? = nil) -> Bool {
        switch command {
        case "prepare", "build": return true
        case "ship": return (from ?? .build) <= .build
        default: return false
        }
    }

    struct AppAttributes: Codable, Sendable { var bundleId: String? }
    struct BuildAttributes: Codable, Sendable { var version: String? }
    struct List<D: Codable & Sendable>: Codable, Sendable { var data: [D] }

    /// Every CFBundleVersion App Store Connect holds for this app and version (read-only). No app record yet means no
    /// builds: the first run then registers the bundle ID at `sign` and `upload` reports the missing record.
    public static func existingBuilds(client: ASCClient, bundleID: String, version: String) async throws -> [String] {
        let apps: List<ASCResource<AppAttributes>> = try await client.get("/v1/apps", query: [("filter[bundleId]", bundleID)])
        guard let app = apps.data.first(where: { $0.attributes.bundleId == bundleID }) else { return [] }
        let query = ASCQuery(filters: [("app", app.id), ("preReleaseVersion.version", version)], fields: [("builds", ["version"])])
        do {
            return try await ASCResources(client: client).list("/v1/builds", query: query, as: ASCResource<BuildAttributes>.self).items.compactMap(\.attributes.version)
        } catch ASCPagingError.didNotTerminate {
            // A partial list could let the ordering check pass wrongly, so running out of pages is an error, never a truncation.
            throw XlessError(.config, "too many App Store Connect build pages for \(bundleID) \(version); pagination did not terminate",
                             fix: "report this as an xless bug; set --build-number to bypass the query")
        }
    }

    /// Credentials-backed query + compute; used by `inspect` (never persists) and by `resolve`.
    public static func compute(version: String, bundleID: String, secrets: Secrets, today: Date = Date(),
                               makeClient: (ASCCredentials) -> ASCClient = { ASCClient(credentials: $0) }) async throws -> String {
        let creds: ASCCredentials
        do { creds = try ASCCredentials.fromSecrets(secrets, stage: .config) } catch let e as XlessError {
            throw XlessError(.config, "build: dated needs App Store Connect credentials (\(e.cause))",
                             fix: "set ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_P8 (or *_FILE)")
        }
        let existing = try await existingBuilds(client: makeClient(creds), bundleID: bundleID, version: version)
        return try next(version: version, today: today, existing: existing)
    }

    /// `--build-number`/`XLESS_BUILD_NUMBER`: replaces `build` and keeps the scheme. For `build: dated` the override must
    /// itself be `<version>.<YYYYMMDDNN>`: a bare number would sort above every dated build and block the version.
    public static func applyOverride(_ override: String, to config: inout ProjectConfig) throws {
        config.build = override
        try config.validate()
    }

    /// Settles the build number of a run on `config` (`Context.load`). Runs as the `config` stage, so App Store Connect,
    /// network and decoding failures print `[config] cause — fix` and exit 10. An override is applied (`applyOverride`)
    /// and, for a dated run that starts, recorded in `file` so that later stages run without it read the same number;
    /// otherwise `build: dated` is resolved (`resolve`) and fixed builds are left alone. `local` (a build that is never
    /// uploaded: React Native simulator builds) resolves `dated` without App Store Connect (`resolveLocal`).
    public static func settle(_ config: inout ProjectConfig, override: String?, file: URL, secrets: Secrets, fresh: Bool, today: Date = Date(),
                              local: Bool = false,
                              makeClient: (ASCCredentials) -> ASCClient = { ASCClient(credentials: $0) }) async throws {
        config = try await withStage(.config) { [config] in
            var c = config
            if let override {
                try applyOverride(override, to: &c)
                if fresh, c.buildScheme == .dated { try record(override, in: file) }
            } else if c.buildScheme == .dated, local {
                c.build = try resolveLocal(version: c.version, fresh: fresh, file: file, today: today)
            } else if c.buildScheme == .dated, ProjectConfig.isMacOnly(c.platforms) {
                c.build = try resolveMac(version: c.version, fresh: fresh, file: file, now: today)
            } else if c.buildScheme == .dated {
                c.build = try await resolve(version: c.version, bundleID: c.bundleID(for: .ios), fresh: fresh, file: file,
                                            secrets: secrets, today: today, makeClient: makeClient)
            }
            return c
        }
    }

    /// The build number of a `build: dated` run. `fresh` (a run starting) queries and records it in `file`; otherwise the record is read.
    public static func resolve(version: String, bundleID: String, fresh: Bool, file: URL, secrets: Secrets, today: Date = Date(),
                               makeClient: (ASCCredentials) -> ASCClient = { ASCClient(credentials: $0) }) async throws -> String {
        guard fresh else { return try recorded(file) }
        let v = try await compute(version: version, bundleID: bundleID, secrets: secrets, today: today, makeClient: makeClient)
        try record(v, in: file)
        return v
    }

    /// The build number of a dated macOS run: from the clock when a run starts (recorded in `file`), else the record.
    public static func resolveMac(version: String, fresh: Bool, file: URL, now: Date = Date()) throws -> String {
        guard fresh else { return try recorded(file) }
        let v = macOS(version: version, now: now)
        try record(v, in: file)
        return v
    }

    /// The build number of a dated run that is never uploaded: `<version>.<YYYYMMDD>01` when a run starts (recorded in
    /// `file`), else the record. No App Store Connect query, so no credentials.
    public static func resolveLocal(version: String, fresh: Bool, file: URL, today: Date = Date()) throws -> String {
        guard fresh else { return try recorded(file) }
        let v = try next(version: version, today: today, existing: [])
        try record(v, in: file)
        return v
    }

    static func recorded(_ file: URL) throws -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              case let v = text.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            throw XlessError(.config, "no build number recorded for this work copy", fix: "run `xless ship` (or `xless build`) first")
        }
        return v
    }

    static func record(_ build: String, in file: URL) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((build + "\n").utf8).write(to: file, options: .atomic)
        } catch {
            throw XlessError(.config, "cannot record the build number at \(file.path): \(error.localizedDescription)", fix: "check the work copy is writable")
        }
    }
}
