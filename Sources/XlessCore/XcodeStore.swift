import Foundation

/// How Xcode versions are spelled and compared, for the packs and for a project's pin.
public enum XcodeVersion {
    /// As scripts/build-images.sh and a project's pin spell it: major.minor, plus the patch when it is not 0.
    public static func canonical(_ v: String) -> String {
        let p = v.split(separator: ".").map { Int($0) ?? 0 }
        var s = "\(p.first ?? 0).\(p.count > 1 ? p[1] : 0)"
        if p.count > 2, p[2] != 0 { s += ".\(p[2])" }
        return s
    }

    /// `a` is an older Xcode version than `b` (numeric, so 26.9 is older than 26.10).
    public static func isOlder(_ a: String, than b: String) -> Bool {
        let a = a.split(separator: ".").map { Int($0) ?? 0 }, b = b.split(separator: ".").map { Int($0) ?? 0 }
        return a.lexicographicallyPrecedes(b)
    }
}

/// Why no Xcode pack can be used, and the command that fixes it.
public struct XcodeProblem: Error, Equatable, CustomStringConvertible {
    public let cause: String
    public let fix: String

    public init(_ cause: String, fix: String) { self.cause = cause; self.fix = fix }

    public var description: String { "\(cause); \(fix)" }
}

/// A directory of Xcode packs, one directory per pack, named `<version>-<build>-<arch>`.
public struct XcodeStore: Sendable {
    public let root: URL

    /// `XLESS_XCODES`, else `<NativeLayout root>/xcodes`.
    public init(env: [String: String] = ProcessInfo.processInfo.environment) {
        if let r = env["XLESS_XCODES"], !r.isEmpty { root = URL(fileURLWithPath: r) }
        else { root = NativeLayout(env: env).root.appendingPathComponent("xcodes") }
    }

    public init(root: URL) { self.root = root }

    /// The directories that open as packs. Others (no `pack.json`, an unreadable one) are skipped, so one bad directory
    /// does not stop every command; `XcodeResolver.resolve` names it when it is the pack that would have been chosen.
    public func packs() -> [XcodePack] {
        subdirectories().compactMap { (try? XcodePack.open($0)) ?? nil }
    }

    public func directory(xcode: String, build: String, arch: String) -> URL {
        root.appendingPathComponent(XcodePack.name(xcode: xcode, build: build, arch: arch))
    }

    /// The pack directories: not a pack being prepared (`<name>.partial`, which has a `pack.json` before it is complete) or
    /// being replaced (`<name>.old`).
    func subdirectories() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls.filter { !$0.lastPathComponent.hasSuffix(".partial") && !$0.lastPathComponent.hasSuffix(".old") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Directories that have a `pack.json` that cannot be read, with the version, build and architecture their name says.
    func broken() -> [(directory: URL, xcode: String, build: String, arch: String)] {
        subdirectories().compactMap { dir in
            guard (try? XcodePack.open(dir)) == nil, FileManager.default.fileExists(atPath: dir.appendingPathComponent("pack.json").path) else { return nil }
            let p = dir.lastPathComponent.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 3 else { return nil }
            return (dir, p[0], p[1], p[2])
        }
    }
}

public enum XcodeResolver {
    public enum Need { case sdk, swiftBuild }

    /// The setup that prepares a pack of `pin` (any Xcode without one).
    static func setUp(_ pin: String?) -> String {
        "xless setup (it prepares the pack from the SDK export in the cache when there is one), else xless setup --xcode <path to Xcode \(pin.map(XcodeVersion.canonical) ?? "<version>")'s .app or .xip>"
    }

    /// The setup that prepares `pack` again, part by part, from its Xcode's SDK export in the cache (`$XDG_CACHE_HOME/xless/sdk`,
    /// else `~/.cache/xless/sdk`), and what to do in a container, where the pack is mounted read-only.
    static func prepareAgain(_ pack: XcodePack, env: [String: String]) -> String {
        let m = pack.manifest
        return "xless setup --sdk \(export(pack, env: env)) prepares it (without that SDK export: xless setup --xcode <path to Xcode \(m.xcode)'s .app or .xip>); "
            + "in a container, whose pack is read-only, run xless setup --docker --sdk <that export> on the host instead, then start the container again"
    }

    /// The fix for a pack without Swift Build: a native setup prepares none (docs/native-install.md); only a pack prepared in
    /// xless's image has it. `pack`: the one without it, nil when there is none to name.
    public static func swiftBuildFix(_ pack: XcodePack?, env: [String: String]) -> String {
        "only a pack prepared in xless's image has Swift Build: xless setup --docker --sdk \(pack.map { export($0, env: env) } ?? "<the Xcode's SDK export>") "
            + "prepares it; then build with xless run --docker, or in a container of that image (docs/images.md#using-the-image-directly)"
    }

    /// The SDK export of `pack`'s Xcode in the cache.
    private static func export(_ pack: XcodePack, env: [String: String]) -> String {
        let cache = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? ((env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()) + "/.cache")
        return "\(cache)/xless/sdk/xcode\(pack.manifest.xcode)-\(pack.manifest.build)"
    }

    /// The pack to use: `XLESS_XCODE`'s, else the store's (`XLESS_XCODES`) chosen by `pin` or the newest.
    /// `expected`: the recipe hash this xless computes for a pack's part (`PackRecipe.hash`); nil when there is none to compare
    /// with (no share, or an Xcode this xless has no recipe for): then nothing is stale. It throws (an `XcodeProblem`) when
    /// the share cannot tell: whether the pack is current is not known then.
    /// `order`: the builds of versions.env's Xcode table, in its order.
    public static func resolve(env: [String: String], pin: String?, arch: String, order: [String], needs: Set<Need> = [.sdk],
                               expected: (XcodePack, PackPart) throws -> String?) throws -> XcodePack {
        let pack: XcodePack
        if let explicit = env["XLESS_XCODE"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            do {
                guard let opened = try XcodePack.open(url) else {
                    throw XcodeProblem("XLESS_XCODE names \(explicit), which is no Xcode pack (it has no pack.json)",
                                       fix: "point it at a pack made by `xless setup`, or unset it to use the store")
                }
                pack = opened
            } catch let problem as XcodeProblem {
                throw problem
            } catch let e as XlessError {
                throw XcodeProblem("XLESS_XCODE names \(explicit), which cannot be used as an Xcode pack: \(e.cause)",
                                   fix: "make its pack.json readable, or remove the pack and run `xless setup` again, or unset XLESS_XCODE to use the store")
            } catch {
                throw XcodeProblem("XLESS_XCODE names \(explicit), which cannot be used as an Xcode pack: \(error)",
                                   fix: "remove the pack and run `xless setup` again, or unset XLESS_XCODE to use the store")
            }
            guard pack.manifest.arch == arch else {
                throw XcodeProblem("XLESS_XCODE names \(explicit), a pack for \(pack.manifest.arch), which this \(arch) machine cannot use",
                                   fix: "point it at a pack for \(arch), or unset it to use the store")
            }
        } else {
            let store = XcodeStore(env: env)
            pack = try choose(store.packs(), pin: pin, arch: arch, order: order, store: store)
        }
        return try checked(pack, needs: needs, env: env, expected: expected)
    }

    /// The pack of `pin` (else the newest) among `packs`, before any staleness check: what the run's Docker side uses too.
    public static func choose(_ packs: [XcodePack], pin: String?, arch: String, order: [String]) throws -> XcodePack {
        try choose(packs, pin: pin, arch: arch, order: order, store: nil)
    }

    private static func better(_ a: (xcode: String, build: String), _ b: (xcode: String, build: String), order: [String]) -> Bool {
        if a.xcode != b.xcode { return XcodeVersion.isOlder(b.xcode, than: a.xcode) }
        let ia = order.firstIndex(of: a.build) ?? -1, ib = order.firstIndex(of: b.build) ?? -1
        return ia != ib ? ia > ib : a.build > b.build
    }

    private static func choose(_ packs: [XcodePack], pin: String?, arch: String, order: [String], store: XcodeStore?) throws -> XcodePack {
        let wanted = pin.map(XcodeVersion.canonical)
        // (as versions: a pack.json may spell 26.2 as 26.2.0)
        func fits(_ xcode: String) -> Bool { wanted == nil || XcodeVersion.canonical(xcode) == wanted }
        let found = packs.filter { fits($0.manifest.xcode) && $0.manifest.arch == arch }
            .sorted { better(($0.manifest.xcode, $0.manifest.build), ($1.manifest.xcode, $1.manifest.build), order: order) }
        let hurt = (store?.broken() ?? []).filter { fits($0.xcode) && $0.arch == arch }
            .sorted { better(($0.xcode, $0.build), ($1.xcode, $1.build), order: order) }
        if let bad = hurt.first, found.first.map({ better((bad.xcode, bad.build), ($0.manifest.xcode, $0.manifest.build), order: order) }) ?? true {
            throw XcodeProblem("the pack \(bad.directory.lastPathComponent) in \(bad.directory.deletingLastPathComponent().path) cannot be used: its pack.json cannot be read",
                               fix: "remove \(bad.directory.path) and run `xless setup` again")
        }
        if let first = found.first { return first }
        let what = wanted.map { "Xcode \($0)" } ?? "any Xcode"
        let elsewhere = Set(packs.filter { fits($0.manifest.xcode) && $0.manifest.arch != arch }.map(\.manifest.arch)).sorted()
        if !elsewhere.isEmpty {
            throw XcodeProblem("there is no pack for \(what) for \(arch) (the store has one for \(elsewhere.joined(separator: ", ")), which this machine cannot use)",
                               fix: "\(setUp(pin)), on this \(arch) machine")
        }
        let where_ = store.map { " in \($0.root.path)" } ?? ""
        throw XcodeProblem("there is no pack for \(what) (\(arch))\(where_)", fix: setUp(pin))
    }

    private static func checked(_ pack: XcodePack, needs: Set<Need>, env: [String: String], expected: (XcodePack, PackPart) throws -> String?) throws -> XcodePack {
        guard pack.manifest.format == PackRecipe.format else {
            throw XcodeProblem("the pack \(pack.name) is of pack format \(pack.manifest.format), and this xless uses format \(PackRecipe.format)",
                               fix: prepareAgain(pack, env: env))
        }
        let parts: [(Need, PackPart, String)] = [(.sdk, .sdk, "Darwin SDK"), (.swiftBuild, .swiftBuild, "Swift Build")]
        for (need, part, label) in parts where needs.contains(need) {
            guard let have = pack.manifest.parts[part.rawValue] else {
                throw XcodeProblem("the pack \(pack.name) has no \(label)", fix: part == .swiftBuild ? swiftBuildFix(pack, env: env) : prepareAgain(pack, env: env))
            }
            if let want = try expected(pack, part), want != have {
                throw XcodeProblem("the \(label) of the pack \(pack.name) was prepared by another recipe than this xless uses",
                                   fix: prepareAgain(pack, env: env))
            }
        }
        return pack
    }
}
