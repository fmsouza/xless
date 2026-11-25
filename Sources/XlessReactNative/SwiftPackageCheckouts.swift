import Foundation
import XlessCore
import XlessXcode

/// The Swift packages a workspace references, made ready for the PIF (contract doc, "Swift packages"): a remote package
/// pinned to a revision is cloned at that revision into a directory named by its identity, a local one is used where
/// it is; each is dumped with SwiftPM as the dependency of an empty root package, which also resolves (and pins, in
/// the root's `Package.resolved`) the package's own dependencies. Version, branch and range requirements are refused
/// (`XcodePackageList`).
public enum SwiftPackageCheckouts {
    /// What `packages.json` records for one package.
    public struct Record: Codable, Equatable, Sendable {
        public struct Pin: Codable, Equatable, Sendable {
            public var identity: String
            public var location: String
            public var revision: String?
            public var version: String?
            public var branch: String?
        }
        public var identity: String
        /// The URL of a remote package, the path of a local one.
        public var location: String
        /// The revision the project pins (nil for a local package).
        public var revision: String?
        /// The package's dependencies as SwiftPM resolved them (identity order).
        public var resolved: [Pin]
    }

    /// One `XcodePackageList` line.
    struct Reference: Equatable {
        var identity: String
        var location: String
        var revision: String?
    }

    /// The workspace's packages, each checked before anything touches the disk: the identity names a directory (no
    /// separators, not `.`/`..`), the revision is a full commit hash (git would take a branch or an option otherwise).
    static func references(_ workspace: Workspace) throws -> [Reference] {
        try restage(.build) { try XcodePackageList.lines(workspace) }.map { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let ref = Reference(identity: f[0], location: f[1], revision: f.count > 2 ? f[2] : nil)
            guard ref.identity.wholeMatch(of: /[a-z0-9][a-z0-9._-]*/) != nil, ref.identity != ".", ref.identity != ".." else {
                throw XlessError(.build, "Swift package identity '\(ref.identity)' (\(ref.location)) cannot name a checkout directory",
                                 fix: "reference the package by a URL or path whose last component is a plain name")
            }
            if let r = ref.revision, r.wholeMatch(of: /[0-9a-f]{40}/) == nil {
                throw XlessError(.build, "Swift package \(ref.identity) is pinned to '\(r)', which is not a full commit hash",
                                 fix: "pin the package to a 40-character revision in the Xcode project")
            }
            return ref
        }
    }

    /// The root package that depends on `checkout` (`.package(path:)`), whose `dump-pif` describes the checkout as a
    /// dependency: its library products are then `packageProduct`s, linked from the package's objects as Xcode does
    /// (dumped as the root itself, SwiftPM would materialize them as static archives).
    static func rootManifest(checkout: URL) -> String {
        let escaped = checkout.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        // swift-tools-version: 5.9
        // Written by xless: the empty root package whose dependency is \(checkout.lastPathComponent), for `swift package dump-pif`.
        import PackageDescription
        let package = Package(name: "root", dependencies: [.package(path: "\(escaped)")], targets: [.target(name: "Root")])

        """
    }

    /// Writes that root package. The workspace's Package.resolved (where Xcode keeps it) pins the package's dependencies, when there is
    /// one: SwiftPM takes those it names. It fetches every repository that the file names, for each package, and checks out those that
    /// this one needs.
    static func writeRoot(_ identity: String, checkout: URL, workspace: Workspace, in directory: URL) throws -> URL {
        let root = directory.appendingPathComponent(".root-\(identity)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Root"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Sources/Root/Root.swift"))
        try Data(rootManifest(checkout: checkout).utf8).write(to: root.appendingPathComponent("Package.swift"), options: .atomic)
        try PackageResolved.copy(from: workspace.path.appendingPathComponent("xcshareddata/swiftpm"), to: root)
        return root
    }

    /// `Package.resolved` pins (of version 1, a project's older file that SwiftPM had no reason to write again).
    static func pins(resolvedFile data: Data) throws -> [Record.Pin] {
        struct File: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { var revision: String?; var version: String?; var branch: String? }
                var identity: String; var location: String; var state: State
            }
            struct Old: Decodable {
                struct Pin: Decodable { var repositoryURL: String; var state: File.Pin.State }
                var pins: [Pin]
            }
            var pins: [Pin]?
            var object: Old?
        }
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch {
            throw XlessError(.build, "cannot read a Package.resolved SwiftPM wrote: \(error)", fix: "report this as an xless bug")
        }
        let old = file.object?.pins.map { File.Pin(identity: PackageResolved.identity(ofURL: $0.repositoryURL), location: $0.repositoryURL, state: $0.state) }
        guard let pins = file.pins ?? old else {
            throw XlessError(.build, "cannot read a Package.resolved SwiftPM wrote: it has no pins", fix: "report this as an xless bug")
        }
        return pins.map { Record.Pin(identity: $0.identity, location: $0.location, revision: $0.state.revision, version: $0.state.version, branch: $0.state.branch) }
            .sorted { $0.identity < $1.identity }
    }

    /// `<directory>/<identity>`, a clone of `ref.location` at `revision`: an existing clone of the same URL is reused
    /// (fetched when it lacks the revision), a clone of another URL with the same identity is replaced.
    static func clone(_ ref: Reference, revision: String, in directory: URL, env: [String: String]) throws -> URL {
        let fm = FileManager.default
        let checkout = directory.appendingPathComponent(ref.identity)
        let origin = try? Shell.run("git", ["-C", checkout.path, "config", "--get", "remote.origin.url"], baseEnvironment: env, stage: .build)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fm.fileExists(atPath: checkout.appendingPathComponent(".git").path) || origin != ref.location {
            try? fm.removeItem(at: checkout)   // none yet, or a clone of another URL with the same identity
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            log("cloning \(ref.location)")
            try Shell.run("git", ["clone", "-q", "--", ref.location, checkout.path], baseEnvironment: env, stage: .build)
        }
        let checkoutArgs = ["-C", checkout.path, "-c", "advice.detachedHead=false", "checkout", "-q", revision]
        if (try? Shell.run("git", checkoutArgs, baseEnvironment: env, stage: .build)) == nil {
            try Shell.run("git", ["-C", checkout.path, "fetch", "-q", "origin"], baseEnvironment: env, stage: .build)
            try Shell.run("git", checkoutArgs, baseEnvironment: env, stage: .build)
        }
        return checkout
    }

    /// Clones (or reuses) and dumps every package of `workspace` under `directory`; returns them for the PIF writer with
    /// what `packages.json` records. `env` is the environment of `git` and `swift`.
    public static func resolve(_ workspace: Workspace, in directory: URL, env: [String: String]) throws -> (packages: [ResolvedPackage], records: [Record]) {
        var packages: [ResolvedPackage] = [], records: [Record] = []
        // The build engine's SwiftPM: its PIF is read by the image's swbuild (Ruling R10 keeps both on the image's Swift).
        let swift = SwiftToolchain.engineSwift(try SwiftToolchain.load(env: env))
        for ref in try references(workspace) {
            let checkout = try ref.revision.map { try clone(ref, revision: $0, in: directory, env: env) } ?? URL(fileURLWithPath: ref.location)
            let root = try writeRoot(ref.identity, checkout: checkout, workspace: workspace, in: directory)
            log("Swift package \(ref.identity) at \(ref.revision ?? checkout.path)")
            let pif = try Shell.run(swift, XcodebuildShim.dumpPIFArguments, cwd: root, baseEnvironment: env, stage: .build).stdout
            try Data(pif.utf8).write(to: directory.appendingPathComponent("\(ref.identity).pif.json"), options: .atomic)
            packages.append(try ResolvedPackage(identity: ref.identity, dumpPIF: Data(pif.utf8)))
            var resolved: [Record.Pin] = []
            if let data = try? Data(contentsOf: root.appendingPathComponent("Package.resolved")) { resolved = try pins(resolvedFile: data) }
            records.append(Record(identity: ref.identity, location: ref.location, revision: ref.revision, resolved: resolved))
        }
        return (packages, records)
    }
}
